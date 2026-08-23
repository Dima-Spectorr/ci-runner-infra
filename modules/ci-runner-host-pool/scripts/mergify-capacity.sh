#!/usr/bin/env bash
# ci-runner-host-pool — how many hosts a merge-queue pool may grow to, read
# from the repository's own Mergify configuration.
#
# WHY THIS FILE EXISTS
#
# A merge-queue pool has an owner nobody configured it against. Mergify decides
# how much work the queue emits — `max_parallel_checks` speculative check runs
# at a time, per queue — and until now that number lived only in `.mergify.yml`
# while the pool's ceiling lived in a Terraform variable somebody typed. The two
# drift in both directions and both directions are quiet:
#
#   ceiling below the queue   the queue is throttled by runner capacity. This is
#                             the reported bottleneck: CI goes green, Mergify
#                             re-runs the same workflows, and there is nowhere
#                             to run them. Nothing is red — the checks are
#                             simply pending, for as long as it takes.
#   ceiling above the queue   the pool is authorised to buy hosts the queue can
#                             never keep busy. Only money, but money nobody
#                             chose to spend.
#
# So the ceiling is DERIVED, live, from the same file Mergify reads, and it is
# derived the same way for every repository in the fleet — which is what makes
# it a standard rather than eight hand-tuned numbers.
#
# WHY THE BATCH SIZE IS READ AND DOES NOT MULTIPLY
#
# The intuition "ten pull requests are queued, so the queue needs ten runners"
# is wrong twice over, and `batch_size` is the second half of why. In `parallel`
# mode Mergify validates a BATCH as ONE speculative pull request: a queue with
# `batch_size: 2` covers two pull requests with one check run, not two. And it
# runs at most `max_parallel_checks` of those at a time regardless of how deep
# the queue is. So the queue's concurrency is `max_parallel_checks`, summed over
# the queues that can run at once, and the batch size only says how much of the
# backlog each of those runs clears.
#
# It is still read and still published, precisely because the wrong intuition is
# the natural one: a number on a chart is what settles that argument, where a
# sentence in a comment settles nothing.
#
# The rule below is PURE — the caller owns the GitHub call, the YAML, and the
# clock — so scripts/ci/mergify-capacity.selftest.sh can exercise it. The one
# impure function here is the READER, kept in the same file because the facts it
# emits and the judgement made of them belong together; it does no judging.
#
# Tenancy-agnostic — no customer literals, no repository knowledge.

# --- the reader: facts, no judgement -------------------------------------------
#
# stdin: a Mergify configuration file. stdout: one record per queue,
#
#     <queue name>\t<max_parallel_checks>\t<batch_size>
#
# `0` for a parallel-checks column means THE FILE DID NOT SAY, and it is emitted
# as 0 rather than as Mergify's default of 1 on purpose: "the repository chose
# one" and "the repository chose nothing" are different facts, and only the
# second one is worth logging. The rule below turns both into 1.
#
# Exit 2 when the document cannot be parsed or is not a mapping. A caller must
# treat that as "unreadable" and NOT as "no queues" — see the rule.
MERGIFY_QUEUE_FACTS_PY='
import sys

try:
    import yaml
except ImportError:
    sys.exit(3)

# Bytes, not text-mode lines. On a platform whose text mode rewrites "\n" as
# "\r\n" the carriage return lands on the END of the last column, which is the
# batch size -- a numeric field that then reads as non-numeric and silently
# defaults to 1. The controller runs on Linux and would never see it; the
# self-test runs wherever it is run, and a rule that passes in CI and fails on a
# laptop teaches people to ignore the rule.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")

try:
    doc = yaml.safe_load(sys.stdin.read())
except Exception:
    sys.exit(2)
if not isinstance(doc, dict):
    sys.exit(2)


def positive(value, fallback):
    # `isinstance(True, int)` is True in Python, and a YAML `yes` is a bool. A
    # bool read as 1 here would report a repository that wrote
    # `max_parallel_checks: true` as having chosen a concurrency of one.
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return fallback
    return value


merge_queue = doc.get("merge_queue")
merge_queue = merge_queue if isinstance(merge_queue, dict) else {}
global_parallel = positive(merge_queue.get("max_parallel_checks"), 0)

rows = []
rules = doc.get("queue_rules")
if isinstance(rules, list):
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            continue
        name = rule.get("name") or "queue%d" % index
        # `speculative_checks` is the old spelling of the same knob. A repo that
        # has not migrated is not a repo without a queue.
        parallel = positive(
            rule.get("max_parallel_checks"),
            positive(rule.get("speculative_checks"), global_parallel),
        )
        rows.append((str(name), parallel, positive(rule.get("batch_size"), 1)))

# A `merge_queue:` section and no `queue_rules:` is a valid single-queue config.
if not rows and merge_queue:
    rows.append(("default", global_parallel, 1))

for name, parallel, batch in rows:
    clean = str(name).replace("\t", " ").replace("\n", " ")
    sys.stdout.write("%s\t%d\t%d\n" % (clean, parallel, batch))
'

# mergify_queue_facts — parse stdin, emit the records above.
#
# `python3 -c` and not `python3 -`, which would spend stdin on the PROGRAM and
# hand the reader an empty document — an unreadable verdict on every repository,
# and a fail-open one, so nothing would ever look wrong.
#
# Exit 0 with no output is a real answer: a configuration file that declares no
# queue at all. Any non-zero exit means the facts are unknown.
mergify_queue_facts() {
  python3 -c "$MERGIFY_QUEUE_FACTS_PY" 2>/dev/null
}

# --- the rule: judgement, no I/O ------------------------------------------------
#
# mergify_capacity <facts> <slots> <max_hosts> <jobs_per_check>
#
#   facts          : the reader's records, verbatim, or the literal string
#                    `unreadable` when the caller could not obtain them.
#   slots          : concurrent jobs one host of this pool serves.
#   max_hosts      : the pool's configured ceiling. 0 means "no configured
#                    ceiling", which is the pool module's own default.
#   jobs_per_check : how many jobs one speculative check run is observed to
#                    produce. The caller measures it; 1 when it never has.
#
# Echoes, space separated:
#
#   <hosts> <want> <checks> <batch> <reason>
#
#   hosts  the ceiling to enforce.
#   want   the ceiling the queue configuration asks for, BEFORE max_hosts caps
#          it. `want > max_hosts` is the sentence "your Terraform ceiling is now
#          the bottleneck", and it is the number an operator acts on.
#   checks the summed concurrency the configuration allows.
#   batch  the largest batch size any queue declares. Reported, never applied.
#   reason which branch answered.
#
# Always exits 0: the verdict is the output, not the status.
mergify_capacity() {
  # `${1-...}` and not `${1:-...}`: an EMPTY facts string is a real answer —
  # a configuration that parsed and declares no queue — and it must reach the
  # `no-queues` branch below rather than being folded into `unreadable`. The two
  # fail open to the same number and say entirely different things about the
  # repository, and only one of them is somebody's bug to go and fix.
  local facts="${1-unreadable}"
  local slots="${2:-1}"
  local max_hosts="${3:-0}"
  local jpc="${4:-1}"

  # A pool that reports 0 slots would divide by zero, and a pool that reports 0
  # jobs per check would derive a ceiling of nothing.
  [ "${slots:-0}" -gt 0 ] 2>/dev/null || slots=1
  [ "${jpc:-0}" -gt 0 ] 2>/dev/null || jpc=1
  [ "${max_hosts:-0}" -ge 0 ] 2>/dev/null || max_hosts=0

  # 1. FAIL OPEN. The configuration could not be read — the contents call
  #    failed, the file is not valid YAML, PyYAML is missing. Deriving a
  #    ceiling from an absence would throttle a healthy queue on a transient
  #    HTTP error, and a throttled queue is invisible: its checks are pending,
  #    not failed. So the configured ceiling stands, exactly as it did before
  #    this rule existed.
  if [ "$facts" = "unreadable" ]; then
    echo "$max_hosts $max_hosts 0 0 unreadable"
    return 0
  fi

  local checks=0 batch=0 name parallel size
  while IFS=$'\t' read -r name parallel size; do
    [ -n "${name:-}" ] || continue
    # A queue that names no concurrency runs Mergify's default of one. This is
    # the ONE place that default is written down, so a repository that says
    # nothing and a repository that says `1` size the pool identically.
    case "${parallel:-}" in
      '' | *[!0-9]*) parallel=1 ;;
      0) parallel=1 ;;
    esac
    case "${size:-}" in
      '' | *[!0-9]*) size=1 ;;
      0) size=1 ;;
    esac
    checks=$((checks + parallel))
    if [ "$size" -gt "$batch" ]; then batch="$size"; fi
  done <<EOF
$facts
EOF

  # 2. A configuration with no queue in it. Fail open again, and for a sharper
  #    reason than the unreadable case: this is a merge-queue POOL serving a
  #    repository whose Mergify config declares no queue, which is a
  #    misconfiguration somebody has to go and fix. Sizing the pool to zero
  #    would hide it behind a pool that merely looks idle.
  if [ "$checks" -le 0 ]; then
    echo "$max_hosts $max_hosts 0 0 no-queues"
    return 0
  fi

  # 3. The derivation. `checks` runs at once, `jpc` jobs in each, `slots` jobs
  #    to a host — rounded UP, because half a host serves no job.
  local want=$(( (checks * jpc + slots - 1) / slots ))
  [ "$want" -ge 1 ] || want=1

  # 4. The configured ceiling still wins. Terraform owns the MIG's maximum size
  #    and the autoscaler's, and a controller that published a demand above them
  #    would be asking for hosts the platform will not create — a ceiling that
  #    exists only in a metric. Reported as `want`, so the shortfall is a number
  #    rather than a surprise.
  if [ "$max_hosts" -gt 0 ] && [ "$want" -gt "$max_hosts" ]; then
    echo "$max_hosts $want $checks $batch capped-by-max-hosts"
    return 0
  fi

  echo "$want $want $checks $batch derived"
}
