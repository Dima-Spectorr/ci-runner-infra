#!/usr/bin/env bash
# =============================================================================
# check-merge-queue-single-step.sh — one CI run per pull request, enforced
#
# USAGE
#   bash scripts/ci/check-merge-queue-single-step.sh [--selftest] [<file>]
#
# PURPOSE
#   Mergify re-checks a queued pull request IN PLACE — on the PR branch, reusing
#   the run that already happened — only when FOUR things hold at once. Break
#   any one and it instead pushes a throwaway draft to
#   `mergify/merge-queue/<sha>`, where EVERY `pull_request` workflow in this
#   repository runs a second time:
#
#     1. `merge_queue.max_parallel_checks: 1`
#     2. every queue rule's `batch_size: 1`
#     3. no `max_checks_retries`
#     4. SINGLE-STEP CI — `merge_conditions` is EMPTY or IDENTICAL to
#        `queue_conditions`
#
#   That is Tier 0, and it is what `MPC_MAX=1` / `BATCH_MAX=1` below assert. A
#   repository whose queue is genuinely its bottleneck raises those two
#   constants into Tier 1 — see `docs/ci-merge-queue-baseline.md` for the
#   measurement that justifies the move, and for why the knob to raise is
#   `batch_size` and never `max_parallel_checks`. The logic is the same in both
#   tiers; only the two numbers differ, so a diff against this canonical copy
#   stays a two-liner.
#
#   The evidence is in the Mergify payload: a two-step pull request carries
#   `speculative_check_pr: <n>` and shows a `mergify/merge-queue/*` workflow run
#   alongside its own (measured on DataRetrival #2383, 2026-08-14). A single-step
#   one reports `speculative_check_pr: null` and "Checks skipped - PR is already
#   up-to-date".
#
# WHY IT PARSES INSTEAD OF PATTERN-MATCHING
#   Every invariant here is a statement about the document Mergify LOADS, and
#   that document is not the text. `queue: {name: default}` and a block mapping
#   are the same action; `"max_checks_retries": 2` and the bare spelling are the
#   same key; `<<: *shared` splices keys that appear nowhere near the rule they
#   land in; an alias is not a copy of a list but the SAME list. A reader that
#   walks lines gets each of those wrong in the safe-looking direction — it
#   reports clean — and a config gate's characteristic failure is exactly that
#   vacuous pass. So the file goes through a real YAML parser (`python3` +
#   PyYAML, which the runner image carries — see `ensure_yaml`) and every check
#   below reads the loaded document by EXACT PATH: `merge_queue.max_parallel_checks`,
#   `queue_rules[1].batch_size`. Never a key name found somewhere in the text —
#   `max_parallel_checks` one level too deep is not a value in an odd spot, it is
#   a file Mergify REJECTS OUTRIGHT, and the queue then fails closed.
#
#   Identity (4) is asserted as NODE IDENTITY — `merge_conditions` and
#   `queue_conditions` being the same object after the parser resolves aliases,
#   which is precisely what Mergify's schema means by "identical". Two lists that
#   happen to match today are two nodes, and they drift on the next check added
#   to one of them; the drift is invisible, because the queue keeps merging and
#   only the runner bill changes.
#
# CHECK 5 — nothing may reach the queue through a `pull_request_rules` queue
#   action, because that rule's `conditions:` are a SECOND list and a second
#   list differs by construction (if only by carrying `base`/`-draft`).
#
# CHECK 6 — but SOMETHING must still queue a green pull request without a human,
#   and it must be able to admit one. Removing the queue action is only half the
#   change: with no queue action and no `auto_merge_conditions`, Mergify posts a
#   "tick the box to queue" comment and waits, so the PR is green, no merge
#   happens, and NO check anywhere goes red to say why (DataRetrival #2378,
#   fixed in #2384). An `auto_merge_conditions` that is empty, null, or aimed at
#   a branch no queue rule serves fails the same way with the key present.
#
# CHECK 7 — `auto_merge_conditions` must not restate the required checks. They
#   live once, in the anchored list, which is what governs when a queued pull
#   request embarks; a second copy is a list to keep in sync, and the anchor
#   exists precisely so that no such copy exists.
#
# CHECK 10 — and each rule must OWN the list it shares. Identity between one
#   rule's two fields does not say the list is that rule's: a second rule can
#   alias the FIRST rule's anchor for both of its fields, pass CHECK 4, and
#   leave two rules sharing one list — where a check added for one base is
#   silently required of the other.
#
# CHECK 9 — a queue rule with no `queue_conditions`, or with conditions naming
#   no check at all, admits pull requests on base/draft state alone. The gate
#   would then be certifying a queue that merges before CI succeeds.
#
# EXIT CODES
#   0 — clean
#   1 — an invariant is broken
# =============================================================================
# `+e` is stated rather than assumed. This gate's whole shape is an aggregator —
# every detector runs, `err` records, and the exit code comes from the tally at
# the end — so a stray `errexit` would abort it mid-sweep on an EXPECTED non-zero
# (a `grep -vx` that matches nothing) and report a failure with no finding
# attached. Bash does not normally export `SHELLOPTS`, so a `run:` block's `-e`
# does not reach a child script today; that is a default, not a contract, and the
# cost of not depending on it is one word.
set +e
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# =============================================================================
# THE TIER. These two constants are the ONLY things a consuming repository is
# expected to change, and changing either moves it from Tier 0 to Tier 1 in
# docs/ci-merge-queue-baseline.md. Everything else in this file is identical
# across the fleet, so a diff against the canonical copy stays a two-liner.
#
# TIER 0 (both 1) — in place, one CI run per pull request. The default, and
# right for every repository whose queue is not its bottleneck: twelve of
# thirteen, surveyed 2026-08-17.
#
# TIER 1 — validation moves to a throwaway `mergify/merge-queue/<sha>` draft.
# Justified only by the measurement in the baseline: merge cadence slower than
# one CI run, so the queue rather than CI is what pull requests wait on.
#
# THEY ARE NOT THE SAME KIND OF NUMBER, and conflating them is the mistake this
# gate exists to stop. Queue throughput is `batch_size × max_parallel_checks`,
# but the RUNNER BILL is `max_parallel_checks` alone — each parallel check is
# another concurrent CI run, while each extra pull request in a batch rides a
# run already happening.
#
#   MPC_MAX   costs runners, LINEARLY, from THIS repository's own pool.
#             Recompute `max_parallel_checks × peak runners per run` against
#             that pool's ceiling in the same pull request, and take the
#             ceiling from Terraform — `slots_per_host × max_hosts` in the
#             pool's `.tfvars` — never from a live runner count. Every pool in
#             the fleet runs `min_hosts = 0`, so an idle pool has deregistered
#             every agent and GitHub reports zero runners for a pool that is
#             fully provisioned. A survey that read that zero on 2026-08-19
#             concluded eleven repositories had no self-hosted runners; ten of
#             them do.
#   BATCH_MAX costs no runners at all. It is bounded by the BISECT: isolating
#             one culprit from N takes ceil(log2(N)) further draft runs, which
#             every pull request in the batch waits through.
#
# Wanting more throughput is an argument for BATCH_MAX — or, since 2026-08-19
# and for free, for `merge_queue.mode: parallel` with a covering scope map,
# which adds no drafts at all. It is never an argument for MPC_MAX.
MPC_MAX=1
BATCH_MAX=1
# =============================================================================

# ceil(log2(n)) for n >= 1, in integer shell arithmetic.
ceil_log2() { local n="$1" r=0 p=1; while [ "$p" -lt "$n" ]; do p=$((p * 2)); r=$((r + 1)); done; printf '%s' "$r"; }

fail=0
# Every diagnostic carries its check id. The self-test asserts the ID SET a
# fixture produces, not a count: counts let one detector's regression hide
# behind another detector firing on the same fixture.
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

# --- the parser is a hard dependency, not a nice-to-have ---------------------
# Made conditional, this is worse than useless: on a runner without PyYAML the
# gate would report PASS over a file Mergify cannot load.
#
# It does NOT install anything. A required check that pip-installs an unpinned
# package at gate time makes every pull request in fourteen repositories depend
# on PyPI being up and shipping a compatible release — and it runs that install
# on self-hosted hosts holding a GCP service identity. PyYAML is present on
# `ubuntu-latest` and baked into the golden host image; if it is ever missing
# the gate says so and fails, which is a runner-image bug with one owner rather
# than a supply-chain surface on every merge.
# The interpreter is CHOSEN, not assumed. `actions/setup-python` prepends its own
# Python to PATH, and that one does not carry the image's `python3-yaml` — so a
# workflow that sets up Python for an unrelated step turns this gate into CHECK0
# "no YAML parser available" on a runner that has one. Pick the first interpreter
# that can actually run the reader, image path included. The probe asks for
# everything the reader uses, not just PyYAML: a Python 2 on `python`, or a 3.x
# too old for `sys.stdout.reconfigure`, would import yaml and then die inside the
# reader — which reads as CHECK0 on a valid config, the exact failure this loop
# exists to prevent.
# Exported, so the probe is paid ONCE. `expect` runs each fixture in a subshell:
# an unexported PY_BIN starts empty in every one of them, and the selftest pays a
# fresh interpreter probe per fixture — measured at 87s against 36s.
export PY_BIN="${PY_BIN:-}"
py_usable() {
  command -v "$1" >/dev/null 2>&1 &&
    "$1" -c 'import sys, yaml; sys.exit(0 if sys.version_info >= (3, 7) and hasattr(sys.stdout, "reconfigure") else 1)' >/dev/null 2>&1
}

ensure_yaml() {
  local c
  # A value already in PY_BIN is a CACHE, not an instruction: it may equally
  # have come from the environment, where a stale path or a Python without
  # PyYAML would skip the probe and surface later as CHECK0 on a valid config —
  # the reader failing, reported as the configuration failing. So it is probed
  # once and dropped if it does not work, leaving the loop below to run.
  if [ -n "$PY_BIN" ]; then
    py_usable "$PY_BIN" && return 0
    PY_BIN=""
  fi
  for c in python3 /usr/bin/python3 /usr/bin/python /usr/local/bin/python3 python; do
    if py_usable "$c"; then
      PY_BIN="$c"
      return 0
    fi
  done
  return 1
}

# Loads the file and emits one TAB-separated record per node:
#
#   <path>\t<scalar or "">\t<map|seq|str|int|bool|null>
#
# plus two kinds of finding the path stream cannot express:
#
#   #ERR\t<parser message>          the document does not load
#   #DUP\t<key>                     a mapping declares the same key twice
#   #RULE\t<rule path>\t<state>     same | different | absent | empty
#
# plus the SEMANTIC records, which the path stream cannot express either: a
# condition list is a tree whose `or:` branches mean something a flattened value
# scan destroys. `or: [base = main, base = develop]` is ONE admissible set of two
# branches, not two ANDed bases, and `or: [-draft, check-success = ci]` requires
# a check on only one of its two satisfiable paths. Both readings are decided
# here, on the tree, and published as verdicts:
#
#   #QCCHECK\t<rule path>\t<yes|no>   every satisfiable path names a check
#   #RULEBASE\t<rule path>\t<base>    a base the rule can admit
#   #RULEBASEANY\t<rule path>         the rule constrains no base
#   #RULEBASEEMPTY\t<rule path>       the rule's base conditions admit nothing
#   #RULEBASEREGEX\t<rule path>       `base ~=`: admissible set not enumerable
#   #RULEBASENOT\t<rule path>\t<base>  a base the rule EXCLUDES (`base != x`)
#   #RULEDRAFT\t<rule path>\t<draft|-draft>
#   #AMCBASE / #AMCBASEANY / #AMCBASEEMPTY / #AMCBASEREGEX / #AMCBASENOT / #AMCDRAFT
#   #AMCBASEUNSERVED\t<base>          admitted, but no queue rule takes it
#   #DRAFTCLASH\t<draft|-draft>       admitted polarity no APPLICABLE rule takes
#   #AMCBASEDISJOINT                  admission and rules share no branch
#   #AMCCHECK\t<condition>            a check restated in the admission list
#   #TYPOKEY\t<path>\t<guarded key>   a key one or two edits from a guarded one
#   #BUDGET                           traversal exceeded its record budget
#   #DEPTH                            a tree nests past the read depth
#
# `#RULE` is the identity verdict, taken on the constructed objects: an alias
# yields the SAME list, two written-out lists never do, and an alias pointing at
# ANOTHER rule's anchor yields a list that is not this rule's.
read_yaml() {
  "${PY_BIN:-python3}" - "$1" <<'PY'
import re, sys, yaml

# LF only. On Windows `print` emits CRLF, and the trailing CR lands inside the
# last field — so a type reads as `seq\r`, never equals `seq`, and the check
# that branches on it quietly takes the other path.
sys.stdout.reconfigure(newline="\n")

dups = []


class Loader(yaml.SafeLoader):
    pass


def no_duplicates(loader, node, deep=False):
    # PyYAML silently keeps the last of a repeated key. Mergify's own loader may
    # keep either, and a config whose effective value depends on that is not a
    # config this gate can certify.
    seen = set()
    for key_node, _ in node.value:
        # `<<` has no constructor of its own — it is spliced by the mapping
        # constructor below. Keys it brings in are NOT duplicates of the local
        # ones: YAML says the local key wins, unambiguously.
        if key_node.tag == "tag:yaml.org,2002:merge":
            continue
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            dups.append(str(key))
        seen.add(key)
    return yaml.SafeLoader.construct_mapping(loader, node, deep=deep)


Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.load(fh, Loader=Loader)
except Exception as exc:  # noqa: BLE001 - any load failure is the same verdict
    print("#ERR\t%s" % " ".join(str(exc).split())[:400])
    sys.exit(0)

for key in dups:
    print("#DUP\t%s" % key)

if doc is None:
    doc = {}


def kind(value):
    if isinstance(value, dict):
        return "map"
    if isinstance(value, list):
        return "seq"
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    return "str"


def scalar(value):
    if isinstance(value, (dict, list)) or value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value).replace("\t", " ").replace("\n", " ")


# A path is only an address if one address means one node. `.` and `[` are this
# encoding's separators, so a key that CONTAINS one collides with a real nesting:
# a top-level key literally named `merge_queue.max_parallel_checks` emits the
# record a nested `merge_queue: {max_parallel_checks: 1}` would, and the gate
# then certifies a document in which the required mapping is absent — Mergify
# sees an unknown top-level key and refuses the file. Rejected rather than
# escaped: no legal Mergify key contains either character, so the honest verdict
# is that the document is not addressable.
# The tab and the newline are the RECORD's own delimiters, not the path's. A key
# spelled `"max_parallel_checks\t1\tint"` is emitted verbatim into a
# tab-separated stream, where `val_at` then decodes it as the required path
# carrying the required value — a key Mergify rejects, certified by this gate as
# the setting it is impersonating. Same verdict, same reason: not addressable.
BAD_KEY_CHARS = (".", "[", "]", "\t", "\n", "\r")

ESC = chr(92)


def safe_key(text):
    """A key REPORTED in a record must not carry the record's delimiters either."""
    for raw, shown in ((ESC, ESC + ESC), (chr(9), ESC + "t"),
                       (chr(13), ESC + "r"), (chr(10), ESC + "n")):
        text = text.replace(raw, shown)
    return text
bad_keys = []
typo_keys = []
misplaced_keys = []

# Keys this gate asserts on. A key MISSPELLED into one of these is the worst
# shape a Mergify config takes here: `merge_conditons: *gate` is not a value in
# the wrong place, it is an unknown key — Mergify refuses the file, nothing
# queues, and every check below reads a document where the guarded key is simply
# absent, which several of them treat as a valid spelling.
GUARDED_KEYS = (
    "max_parallel_checks", "batch_size", "merge_conditions", "queue_conditions",
    "auto_merge_conditions", "queue_rules", "merge_queue", "max_checks_retries",
    "merge_protections_settings", "autoqueue", "pull_request_rules",
    # Guarded since CHECK 2 began asserting on it. Misspelled, it is invisible
    # twice over: Mergify refuses the file for the unknown key, and CHECK 2 —
    # which only looks when the batch exceeds 1 — sees a Tier 0 rule and says
    # nothing. Green gate, dead queue.
    "batch_max_failure_resolution_attempts",
)
# Rejecting every UNKNOWN key would fail configurations that use Mergify keys
# this gate has never heard of — a fleet-wide false failure, and the reason the
# test is a near miss rather than a schema. These are the real keys close enough
# to matter; anything else within two edits of a guarded key is a typo.
KNOWN_KEYS = set(GUARDED_KEYS) | {
    "conditions", "actions", "name", "queue", "defaults", "extends", "priority",
    "commands_restrictions", "priority_rules", "partition_rules", "merge_method",
    "update_method", "checks_timeout", "branch_protection_injection_mode",
    "queue_branch_merge_method", "batch_max_wait_time", "speculative_checks",
    "description", "label", "comment", "review", "close", "assign", "backport",
    "delete_head_branch", "dismiss_reviews", "edit", "github_actions", "rebase",
    "request_reviews", "squash", "update", "commit_message_template",
    "disallow_checks_interruption_from_queues", "allow_inplace_checks",
    "batch_max_failure_resolution_attempts", "min", "max",
}


def edit_distance(a, b, limit=2):
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


# WHERE a guarded key is a guarded key. Mergify accepts each of these in
# exactly one position, and both questions below are meaningless outside it:
# `scopes.source.files.merge-queue` in some other tool's config is two edits
# from `merge_queue` and is not a misspelling of anything, while a top-level
# `merge_conditions: []` is not the queue rule's key "spelled right" — Mergify
# sees an unknown top-level key and refuses the file.
LEGAL_KEYS = {
    "root": {"merge_queue", "queue_rules", "merge_protections_settings",
             "pull_request_rules", "defaults", "extends", "priority_rules",
             "partition_rules", "commands_restrictions"},
    "merge_queue": {"max_parallel_checks", "max_checks_retries"},
    "queue_rule": {
        "name", "queue_conditions", "merge_conditions", "batch_size",
        "autoqueue", "priority", "conditions", "checks_timeout",
        "max_checks_retries", "batch_max_wait_time", "speculative_checks",
        "merge_method", "update_method", "queue_branch_merge_method",
        "branch_protection_injection_mode", "allow_inplace_checks",
        "disallow_checks_interruption_from_queues", "commit_message_template",
        "batch_max_failure_resolution_attempts",
    },
    "merge_protections_settings": {"auto_merge_conditions", "autoqueue"},
}
# Reported by CHECK 1 / CHECK 3 / CHECK 6 with the reason each of them owns, so
# the position check stays quiet on them rather than raising a second finding
# on the same key.
MISPLACED_ELSEWHERE = ("max_parallel_checks", "max_checks_retries",
                       "auto_merge_conditions")


def context_of(path):
    """The schema position a mapping sits at, or None when unrecognised.

    None is the answer for every key under `pull_request_rules`, under a
    condition list, and under anything this gate has never heard of. Both
    callers stay silent there: a position check that guesses at an unknown
    context reports on other tools' files.
    """
    if path == "":
        return "root"
    if path in ("merge_queue", "merge_protections_settings"):
        return path
    if re.match(r"^queue_rules\[[0-9]+\]$", path):
        return "queue_rule"
    return None


def near_miss(text, context):
    # Short keys are excluded: at four characters two edits reaches an unrelated
    # word, and a gate that renames a reader's correct key teaches them to
    # delete it.
    if context is None or text in KNOWN_KEYS or len(text) < 6:
        return None
    legal = LEGAL_KEYS.get(context, set())
    for guarded in GUARDED_KEYS:
        # Only against keys that would MEAN something here. `merge_conditions`
        # is not a candidate misspelling at the top level, because the correctly
        # spelled key would be refused there too.
        if guarded in legal and edit_distance(text, guarded) <= 2:
            return guarded
    return None


# An acyclic alias graph is not a cycle, and the cycle guard below does not stop
# it: `a: &a [x]` doubled nineteen times is a document under a kilobyte whose
# traversal is 2**19 nodes. The guard is a budget on records emitted, because
# that is the quantity that actually blows up — a gate that runs past its
# workflow timeout fails the same way as one that crashes, only slower and with
# no message saying why.
RECORD_BUDGET = 20000
emitted = [0]


class BudgetExceeded(Exception):
    pass


def walk(node, path, seen):
    if isinstance(node, dict):
        items = node.items()
    elif isinstance(node, list):
        items = ((i, v) for i, v in enumerate(node))
    else:
        return
    for key, value in items:
        if isinstance(node, dict):
            text = str(key)
            if any(c in text for c in BAD_KEY_CHARS):
                bad_keys.append(text)
                continue
            child = "%s.%s" % (path, text) if path else text
            context = context_of(path)
            guarded = near_miss(text, context)
            if guarded:
                typo_keys.append((child, guarded))
            elif (context is not None and text in GUARDED_KEYS
                    and text not in LEGAL_KEYS.get(context, set())
                    and text not in MISPLACED_ELSEWHERE):
                misplaced_keys.append((child, context))
        else:
            child = "%s[%d]" % (path, key)
        emitted[0] += 1
        if emitted[0] > RECORD_BUDGET:
            raise BudgetExceeded()
        print("%s\t%s\t%s" % (child, scalar(value), kind(value)))
        # A recursive alias (`loop: &loop [*loop]`) is legal YAML and loads into
        # an object that contains itself. Walked naively this raises deep in the
        # traversal, AFTER the required records have been printed — a traceback
        # beside a full path stream, which reads as a usable document.
        if isinstance(value, (dict, list)):
            if id(value) in seen:
                bad_keys.append("%s (cycle)" % child)
                continue
            walk(value, child, seen | {id(value)})


try:
    walk(doc, "", {id(doc)})
except BudgetExceeded:
    # Emitted before the key findings so the reason for a short path stream is
    # never below the records that look like a complete document.
    print("#BUDGET")
    for key in bad_keys:
        print("#BADKEY\t%s" % safe_key(key))
    sys.exit(0)

for key in bad_keys:
    print("#BADKEY\t%s" % safe_key(key))

for path, guarded in typo_keys:
    print("#TYPOKEY\t%s\t%s" % (path, guarded))

for path, context in misplaced_keys:
    print("#MISPLACED\t%s\t%s" % (path, context))

rules = doc.get("queue_rules") if isinstance(doc, dict) else None
# Which rule each condition list belongs to. Identity between a rule's OWN two
# fields does not say the rule owns its list: a second rule can point both of
# its fields at the FIRST rule's anchor, and then every per-rule verdict below
# reads `same` while the two rules are silently one list.
owners = {}
if isinstance(rules, list):
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict):
            continue
        qc = rule.get("queue_conditions")
        if isinstance(qc, list):
            # The document stays referenced for the life of this process, so no
            # id() is recycled underneath this map.
            if id(qc) in owners:
                print("#ALIAS\tqueue_rules[%d]\tqueue_rules[%d]" % (i, owners[id(qc)]))
            else:
                owners[id(qc)] = i
        if "merge_conditions" not in rule:
            state = "absent"
        else:
            mc = rule.get("merge_conditions")
            # An explicitly empty list is one of the two single-step spellings,
            # exactly as omitting the key is.
            if mc is None or (isinstance(mc, list) and not mc):
                state = "empty"
            elif mc is qc:
                state = "same"
            else:
                state = "different"
        print("#RULE\tqueue_rules[%d]\t%s" % (i, state))

# --- the condition tree, read as a tree -------------------------------------
#
# Everything below is decided on the STRUCTURE. A flattened scan of the same
# lists gets two specific things backwards, both in the direction that reports
# clean: it counts the members of an `or:` as ANDed (so a legitimate
# `or: [base = main, base = develop]` is rejected as an impossible pair of
# bases), and it accepts a check found on ONE branch of an `or:` as a check the
# rule requires (so `or: [-draft, check-success = ci]` reads as gated on CI when
# a non-draft pull request satisfies the other branch and merges ungated).

# `!=` before `=` and `~=` before `=`, longest first: scanning for `=` alone
# finds the `=` INSIDE `!=` and reads `check-success != x` as a positive
# requirement — the reading that turns a negated check into a satisfied gate.
COND_OPS = ("!=", ">=", "<=", "~=", "=", ":", ">", "<")
POSITIVE_CHECKS = ("check-success", "check-neutral", "check-skipped")
ANY_CHECKS = POSITIVE_CHECKS + ("check-failure", "check-pending")
MAX_DEPTH = 64
# Set whenever a traversal stops AT that depth. Truncation is reported, never
# absorbed: a `check-success` under 65 nested `and:` nodes is a restated check
# that is really there, and a reader returning the cut subtree as empty turns a
# finding into a PASS — the vacuous pass this gate exists to prevent. No config
# a human writes nests that far, so failing closed on it costs nothing real.
TRUNCATED = set()


def parse_cond(text):
    """(negated, attribute, operator, value) for one condition string.

    The operator is the LEFTMOST one outside quotes, not the first one in
    `COND_OPS`. Scanning by precedence finds the operator inside a quoted
    value — `check-success = "lint != docs"` splits on the `!=` and yields
    `check-success = "lint` as the attribute, which fails a valid rule and can
    equally hide a restated check.
    """
    body = " ".join(str(text).split())
    negated = False
    while body.startswith("-"):
        negated = not negated
        body = body[1:].strip()
    quote = ""
    i = 0
    while i < len(body):
        char = body[i]
        if quote:
            if char == quote:
                quote = ""
            i += 1
            continue
        if char in "\"'":
            quote = char
            i += 1
            continue
        if i > 0:
            for op in COND_OPS:  # longest first AT THIS POSITION: `!=` before `=`
                if body.startswith(op, i):
                    value = body[i + len(op):].strip()
                    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                        value = value[1:-1]
                    return negated, body[:i].strip(), op, value
        i += 1
    return negated, body, "", ""


def branches(node):
    """(connective, children) for a tree node; None for a leaf condition."""
    if isinstance(node, list):
        return "and", node
    if isinstance(node, dict) and len(node) == 1:
        key, value = next(iter(node.items()))
        if str(key) in ("and", "or") and isinstance(value, list):
            return str(key), value
        if str(key) == "not":
            return "not", [value]
    return None


DNF_LIMIT = 4096


def neg_leaf(text):
    """Mergify negates a condition with a leading `-`, so inversion is textual."""
    stripped = str(text).strip()
    return stripped[1:].strip() if stripped.startswith("-") else "-" + stripped


def denot(item, negate=False, depth=0):
    """The tree with every `not:` pushed down to the leaves, or None.

    `not` used to be the end of reading: both the DNF and the base algebra
    treated the subtree as unknown, and the base algebra then called it
    UNCONSTRAINED — a rule spelled `not: {base = main}` serves everything except
    main and was compared as if it served everything, so an admission list of
    exactly `main` found it overlapping and passed. De Morgan is the whole of
    the fix: negation swaps the connective and inverts the leaves, which invert
    by the same `-` prefix Mergify itself uses.
    """
    if depth > MAX_DEPTH:
        TRUNCATED.add("denot")
        return None
    kids = branches(item)
    if kids is None:
        if not isinstance(item, str):
            return None if negate else item
        return neg_leaf(item) if negate else item
    connective, children = kids
    if connective == "not":
        if len(children) != 1:
            return None
        return denot(children[0], not negate, depth + 1)
    out = []
    for child in children:
        sub = denot(child, negate, depth + 1)
        if sub is None:
            return None
        out.append(sub)
    flipped = "or" if connective == "and" else "and"
    result = connective if not negate else flipped
    return out if result == "and" else {"or": out}


def dnf(node, depth=0):
    """The tree as a list of conjunctive terms, or None when not computable.

    Reducing an AND to "any child requires it" is not the same question. Two
    disjunctions can imply a check JOINTLY —
    `(base = main or check) and (base = develop or check)` requires the check on
    every satisfiable path, because no pull request targets both bases — while
    neither child requires it alone. Expanding to terms asks the actual
    question, and the unsatisfiable term is where the joint implication lives.
    """
    if depth > MAX_DEPTH:
        TRUNCATED.add("dnf")
        return None
    kids = branches(node)
    if kids is None:
        return [[node]] if isinstance(node, str) else [[]]
    connective, children = kids
    if connective == "not":
        inner = denot(node)
        return None if inner is None else dnf(inner, depth + 1)
    if connective == "and":
        terms = [[]]
        for child in children:
            sub = dnf(child, depth + 1)
            if sub is None:
                return None
            product = []
            for term in terms:
                for extra in sub:
                    product.append(term + extra)
                    if len(product) > DNF_LIMIT:
                        return None
            terms = product
        return terms
    if connective == "or":
        if not children:
            return None
        out = []
        for child in children:
            sub = dnf(child, depth + 1)
            if sub is None:
                return None
            out.extend(sub)
            if len(out) > DNF_LIMIT:
                return None
        return out
    return None  # an unknown connective: what this gate cannot read, it does not assert


def satisfiable(term):
    """False when the term contradicts itself, so no pull request takes it.

    The base half is the SET ALGEBRA rather than a count of `base =` clauses:
    `base = main` beside `base != main` admits nothing, and neither does
    `base = main` beside `base ~= ^release/`, while neither pair is two positive
    equalities. A term left alive here is one `requires()` asks the check
    question about and `#DRAFTCLASH` compares rules against — a dead one answers
    for pull requests that cannot exist.
    """
    drafts = set()
    for text in term:
        stripped = " ".join(str(text).split())
        if stripped in ("draft", "-draft"):
            drafts.add(stripped)
    if len(drafts) > 1:
        return False
    acc = UNIVERSE
    for text in term:
        acc = base_and(acc, base_set(text, set()))
    return not base_empty(acc)


def requires(node, predicate, depth=0):
    """Does EVERY satisfiable term of this tree contain a matching condition?

    An unreadable tree (a `not`, or an expansion past the term budget) answers
    True: silence rather than a finding, because the alternative is failing a
    configuration this gate merely could not read.
    """
    terms = dnf(node)
    if terms is None:
        return True
    live = [t for t in terms if satisfiable(t)]
    if not live:
        return True  # nothing is admitted at all; the base checks own that case
    return all(any(isinstance(c, str) and predicate(c) for c in t) for t in live)


def leaves(node, out, depth=0):
    if depth > MAX_DEPTH:
        TRUNCATED.add("leaves")
        return
    kids = branches(node)
    if kids is None:
        if isinstance(node, str):
            out.append(node)
        return
    for child in kids[1]:
        leaves(child, out, depth + 1)


def is_required_check(text):
    negated, attr, op, _ = parse_cond(text)
    return (not negated) and attr in POSITIVE_CHECKS and op in ("=", ":", "~=")


def is_any_check(text):
    _, attr, op, _ = parse_cond(text)
    return attr in ANY_CHECKS and op != ""


def is_exactly(token):
    return lambda text: " ".join(str(text).split()) == token


# The bases a condition tree admits, as a SET WITH A COMPLEMENT:
#   ("in", {…})   exactly these branches
#   ("out", {…})  every branch except these — ("out", set()) is unconstrained
#   None          not enumerable (a regex), so no comparison is made
# `base != main` is an ordinary Mergify condition and belongs to the algebra:
# reading it as "unenumerable" disabled the comparison, and a rule serving
# everything-but-main against an admission list of exactly `main` then passed
# while nothing could ever queue.
#   ("re", {(pattern, negated), …})  every branch matching all of these
# A regex names no set this gate can enumerate, but it is still a PREDICATE, and
# a predicate answers the only question asked of the rule side: does this rule
# serve `main`? Collapsing it to "unknown" declined that question and let a rule
# spelled `base ~= ^release/` stand in for the `main` rule that is missing.
UNIVERSE = ("out", frozenset())
EMPTY = ("in", frozenset())


def re_admits(patterns, name):
    for pattern, negated in patterns:
        try:
            hit = re.search(pattern, name) is not None
        except re.error:
            return None  # a pattern Mergify may accept and this gate cannot read
        if hit == negated:
            return False
    return True


def base_and(a, b):
    if a is None or b is None:
        return None
    if a == UNIVERSE:
        return b
    if b == UNIVERSE:
        return a
    (ka, sa), (kb, sb) = a, b
    if ka == "re" and kb == "re":
        return ("re", sa | sb)
    if ka == "re" or kb == "re":
        # A regex narrows an enumerated set by FILTERING it, which keeps the
        # comparison enumerable. Against a complement there is nothing to
        # filter, so the pair stays unknown.
        patterns, other = (sa, b) if ka == "re" else (sb, a)
        if other[0] != "in":
            return None
        kept = set()
        for name in other[1]:
            verdict = re_admits(patterns, name)
            if verdict is None:
                return None
            if verdict:
                kept.add(name)
        return ("in", frozenset(kept))
    if ka == "in" and kb == "in":
        return ("in", sa & sb)
    if ka == "in":
        return ("in", sa - sb)
    if kb == "in":
        return ("in", sb - sa)
    return ("out", sa | sb)


def base_or(a, b):
    if a is None or b is None:
        return None
    if a == EMPTY:
        return b
    if b == EMPTY:
        return a
    (ka, sa), (kb, sb) = a, b
    if ka == "re" or kb == "re":
        return None  # a union with a regex is not enumerable in either direction
    if ka == "in" and kb == "in":
        return ("in", sa | sb)
    if ka == "in":
        return ("out", sb - sa)
    if kb == "in":
        return ("out", sa - sb)
    return ("out", sa & sb)


def base_admits(bases, name):
    if bases is None:
        return True
    kind, members = bases
    if kind == "re":
        verdict = re_admits(members, name)
        return True if verdict is None else verdict
    return (name in members) if kind == "in" else (name not in members)


def base_empty(bases):
    return bases is not None and bases[0] == "in" and not bases[1]


def base_overlaps(a, b):
    """Can one pull request satisfy both? Only an empty IN set admits nothing."""
    return not base_empty(base_and(a, b))


def base_set(node, flags, depth=0):
    if depth > MAX_DEPTH:
        TRUNCATED.add("base")
        return None
    kids = branches(node)
    if kids is None:
        if not isinstance(node, str):
            return UNIVERSE
        negated, attr, op, value = parse_cond(node)
        if attr != "base":
            return UNIVERSE
        if op in ("=", ":"):
            return ("out", frozenset([value])) if negated else ("in", frozenset([value]))
        if op == "!=":
            return ("in", frozenset([value])) if negated else ("out", frozenset([value]))
        # `base ~= ^release/` is a set this gate cannot enumerate, but it is a
        # predicate it CAN apply. Kept as one, it still narrows an enumerated
        # set beside it — `base = main` ANDed with `base ~= ^release/` admits
        # nothing — and it still answers whether a rule serves a named branch.
        # Saying "unconstrained" would be a lie in the safe direction; saying
        # "unknown" declines a question that has an answer.
        if op == "~=":
            flags.add("regex")
            return ("re", frozenset([(value, negated)]))
        return None
    connective, children = kids
    if connective == "not":
        inner = denot(node)
        return None if inner is None else base_set(inner, flags, depth + 1)
    if connective == "and":
        acc = UNIVERSE
        for child in children:
            acc = base_and(acc, base_set(child, flags, depth + 1))
        return acc
    if connective == "or":
        if not children:
            return UNIVERSE
        acc = ("in", frozenset())
        for child in children:
            acc = base_or(acc, base_set(child, flags, depth + 1))
        return acc
    # Not UNIVERSE. Calling an unreadable node "unconstrained" is an ASSERTION
    # that it admits every branch, and every comparison then runs on it; None
    # declines the comparison instead.
    return None


def emit_bases(prefix, bases, flags, path):
    suffix = ("\t%s" % path) if path else ""
    if bases is None:
        print("#%sBASEANY%s" % (prefix, suffix))
        if "regex" in flags:
            print("#%sBASEREGEX%s" % (prefix, suffix))
    elif base_empty(bases):
        print("#%sBASEEMPTY%s" % (prefix, suffix))
    elif bases[0] == "re":
        # Not enumerable, so nothing to NAME here; the comparisons still apply
        # it as a predicate.
        print("#%sBASEANY%s" % (prefix, suffix))
        print("#%sBASEREGEX%s" % (prefix, suffix))
    elif bases == UNIVERSE:
        print("#%sBASEANY%s" % (prefix, suffix))
    elif bases[0] == "in":
        for base in sorted(bases[1]):
            print("#%sBASE%s\t%s" % (prefix, suffix, base))
    else:
        print("#%sBASEANY%s" % (prefix, suffix))
        for base in sorted(bases[1]):
            print("#%sBASENOT%s\t%s" % (prefix, suffix, base))


def draft_state(node):
    """'draft' / '-draft' when the tree pins it, None when it takes either."""
    pinned = [t for t in ("draft", "-draft") if requires(node, is_exactly(t))]
    return pinned[0] if len(pinned) == 1 else None


rule_infos = []
if isinstance(rules, list):
    for i, rule in enumerate(rules):
        if not isinstance(rule, dict) or "queue_conditions" not in rule:
            continue
        path = "queue_rules[%d]" % i
        qc = rule.get("queue_conditions")
        # A condition list Mergify accepts is a SEQUENCE. A scalar there — most
        # often an alias pointing at a string anchor — loads as a one-condition
        # tree here and reads as a perfectly gated rule, while Mergify refuses
        # the file on the type and nothing queues at all.
        if not isinstance(qc, list):
            print("#QCTYPE\t%s\t%s" % (path, kind(qc)))
            continue
        mc = rule.get("merge_conditions")
        if "merge_conditions" in rule and mc is not None and not isinstance(mc, list):
            print("#QCTYPE\t%s.merge_conditions\t%s" % (path, kind(mc)))
            continue
        print("#QCCHECK\t%s\t%s" % (path, "yes" if requires(qc, is_required_check) else "no"))
        # `check-skipped = X` says the check did not run. Alone it is not a
        # gate: every path through the rule is satisfied by a check that never
        # reported. It is legitimate only BESIDE the success form
        # (`or: [check-success = X, check-skipped = X]`), which is how a
        # path-filtered workflow is admitted — so the question is whether the
        # rule names a success anywhere, not what any single branch holds.
        rule_leaves = []
        leaves(qc, rule_leaves)
        success_named = False
        skip_named = False
        for text in rule_leaves:
            negated, attr, op, _ = parse_cond(text)
            if negated or op not in ("=", ":", "~="):
                continue
            if attr in ("check-success", "check-neutral"):
                success_named = True
            elif attr == "check-skipped":
                skip_named = True
        if skip_named and not success_named:
            print("#QCSKIPONLY\t%s" % path)
        flags = set()
        bases = base_set(qc, flags)
        emit_bases("RULE", bases, flags, path)
        state = draft_state(qc)
        if state:
            print("#RULEDRAFT\t%s\t%s" % (path, state))
        rule_infos.append((path, bases, state))

settings = doc.get("merge_protections_settings") if isinstance(doc, dict) else None
amc = settings.get("auto_merge_conditions") if isinstance(settings, dict) else None
if amc is not None and not isinstance(amc, list):
    # Same type rule as a queue rule's lists, and the same failure: Mergify
    # refuses the file, while a scalar here loads as a one-condition tree that
    # every check below reads as a working admission list.
    print("#AMCTYPE\t%s" % kind(amc))
elif amc is not None:
    texts = []
    leaves(amc, texts)
    for text in texts:
        if is_any_check(text):
            print("#AMCCHECK\t%s" % " ".join(str(text).split())[:200])
    amc_flags = set()
    amc_bases = base_set(amc, amc_flags)
    emit_bases("AMC", amc_bases, amc_flags, "")
    amc_draft = draft_state(amc)
    if amc_draft:
        print("#AMCDRAFT\t%s" % amc_draft)

    # The comparisons live HERE, where both sides are still sets rather than
    # lines of text. A rule is a candidate for an admitted pull request when
    # its bases overlap the admission list's; the bash side would have to
    # rebuild that from records to ask the same question.
    if rule_infos and not base_empty(amc_bases):
        if amc_bases is not None and amc_bases[0] == "in":
            for base in sorted(amc_bases[1]):
                if not any(base_admits(b, base) for _, b, _ in rule_infos):
                    print("#AMCBASEUNSERVED\t%s" % base)
        # The general case, which naming bases one at a time cannot reach: an
        # admission list of `base != main` enumerates nothing to loop over, and a
        # rule whose own base conditions are contradictory (`base = main` ANDed
        # with `base = develop`) contributes no base to be compared against.
        # Both admit NOTHING jointly and both used to read as PASS. Overlap is
        # the same question in either spelling, and it survives the complement.
        elif not any(base_overlaps(b, amc_bases) for _, b, _ in rule_infos):
            print("#AMCBASEDISJOINT")
    # Draft polarity, per ADMISSION PATH and against the APPLICABLE rules only.
    #
    # Both halves of that are load-bearing. A repository may serve `main` with
    # `-draft` and `release` with `draft`: that is routing, not deadlock, and
    # reading every rule's draft term at once fails it on the rule the admitted
    # pull request never reaches. A rule pinning neither polarity takes both, so
    # it clears the clash by itself.
    #
    # And the admission list has paths of its own. `(base = main and draft) or
    # (base = release and -draft)` pins NO polarity as a whole, so asking the
    # question once answers "unpinned" and says nothing — while the `main` path
    # is deadlocked against a `main`/`-draft` rule exactly as if it had been
    # written alone. Each satisfiable term carries its own base set and its own
    # polarity, which is the pair the comparison needs.
    amc_terms = dnf(amc)
    live_terms = [t for t in (amc_terms or []) if satisfiable(t)]
    # Every path through the list contradicts ITSELF — `base = main` beside both
    # `draft` and `-draft`, or two bases in one term. The admissible base set is
    # not empty (each condition is satisfiable on its own), so the base checks
    # say nothing, and the list queues exactly as much as no list at all.
    if amc_terms is not None and not live_terms and not base_empty(amc_bases):
        print("#AMCDEAD")
    seen_clash = set()
    for term in live_terms:
        term_draft = draft_state(term)
        if not term_draft or term_draft in seen_clash:
            continue
        term_bases = base_set(term, set())
        candidates = [r for r in rule_infos if base_overlaps(r[1], term_bases)]
        opposite = "-draft" if term_draft == "draft" else "draft"
        if candidates and all(state == opposite for _, _, state in candidates):
            seen_clash.add(term_draft)
            print("#DRAFTCLASH\t%s" % term_draft)

if TRUNCATED:
    print("#DEPTH")
PY
}

scan_file() {
  local f="$1" doc mpc misplaced rules r b
  if [ ! -f "$f" ]; then
    err CHECK0 "no Mergify configuration at $f. This gate cannot show that the queue checks in place, and a missing config is not an absent queue — Mergify falls back to its own defaults."
    return
  fi

  # --- CHECK 0: it has to load at all, and mean one thing --------------------
  if ! ensure_yaml; then
    err CHECK0 "no YAML parser available (python3 with PyYAML, which the runner image is expected to carry — this gate deliberately installs nothing). Without one it cannot tell a config Mergify loads from one it refuses, and reporting PASS on that basis is the vacuous pass this gate exists to prevent. Install python3 + PyYAML on the runner."
    return
  fi
  # The STATUS, not just the output. A reader that dies partway still leaves the
  # records it managed to print, and every check below then reads a document it
  # never finished loading — the vacuous pass again, this time with a traceback
  # printed above the PASS line where nothing is looking.
  if ! doc="$(read_yaml "$f")"; then
    err CHECK0 "the YAML reader exited non-zero on \`$f\`, so the document was never fully inspected. Whatever it printed before dying is not a verdict; treat this as an unreadable configuration."
    return
  fi

  if printf '%s\n' "$doc" | grep -c '^#ERR	' >/dev/null; then
    err CHECK0 "\`$f\` is not loadable YAML, so nothing below it is worth asserting: Mergify refuses the whole file and NO pull request queues. Parser said: $(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#ERR" { print $2; exit }')"
    return
  fi
  if printf '%s\n' "$doc" | grep -cx '#BUDGET' >/dev/null; then
    err CHECK0 "\`$f\` expands past this gate's traversal budget. A cycle is not required for that: aliases that reference each other acyclically double the traversal each level, so a sub-kilobyte file can expand to millions of nodes — the gate then runs until the job times out, which reads as infrastructure flakiness rather than as a configuration finding. No valid Mergify configuration is that shape."
    return
  fi
  if printf '%s\n' "$doc" | grep -cx '#DEPTH' >/dev/null; then
    err CHECK0 "a condition list in \`$f\` nests deeper than this gate reads (64 levels). Everything below that point was NOT inspected, and reporting PASS on a tree it stopped reading is the vacuous pass this gate exists to prevent — a \`check-success\` under 65 nested \`and:\` nodes is restated whether or not the reader reached it. Flatten the conditions."
    return
  fi
  local badkeys; badkeys="$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#BADKEY" { print $2 }' | sort -u | tr '\n' ' ')"
  if [ -n "${badkeys// /}" ]; then
    err CHECK0 "\`$f\` contains a key this gate cannot address unambiguously: ${badkeys}. A key holding \`.\`, \`[\`, \`]\`, a tab, a carriage return or a newline collides with a genuinely nested path or with the record protocol itself — a top-level \`\"merge_queue.max_parallel_checks\"\` would read here exactly like the nested mapping Mergify requires, while Mergify itself sees an unknown top-level key and refuses the file. A \`(cycle)\` entry means a recursive alias, which no valid Mergify configuration has. Remove it."
    return
  fi
  local dups; dups="$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#DUP" { print $2 }' | sort -u | tr '\n' ' ')"
  if [ -n "${dups// /}" ]; then
    err CHECK0 "\`$f\` declares the same key twice: ${dups}. Which declaration wins is loader-dependent, so \`max_parallel_checks: 1\` followed by \`max_parallel_checks: 5\` can read as compliant here and run parallel queue checks in production. Remove the duplicate."
  fi

  # --- CHECK 11: a key one or two edits from a guarded one -------------------
  # Every check in this file asserts on an EXACT path, which is what makes a
  # misspelling invisible to all of them: `merge_conditons: *gate` leaves
  # `merge_conditions` absent, and absent is one of the two spellings CHECK 4
  # accepts. Mergify meanwhile refuses the file on the unknown key, so nothing
  # queues at all while this gate reports single-step CI.
  while IFS=$'\t' read -r _ p guarded; do
    [ -n "$p" ] || continue
    err CHECK11 "\`$f\` declares \`$p\`, which is within two characters of \`$guarded\` — the key this gate asserts on. If it is a misspelling, Mergify rejects the whole file on the unknown key and NOTHING queues, while every check here reads \`$guarded\` as merely absent, which several of them accept as a valid spelling. Fix the spelling, or rename the key so it is not a near miss."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#TYPOKEY"')

  # --- CHECK 12: a guarded key spelled right, in a position Mergify refuses ---
  # CHECK 11 catches the key one edit away; this is its mirror image, and every
  # exact-path reader below is blind to it in the same way. A top-level
  # `merge_conditions: []` or `batch_size: 1` is not the queue rule's setting
  # "declared globally" — Mergify rejects the file on an unknown top-level key,
  # nothing queues, and the per-rule checks here read the key as merely absent,
  # which several of them accept.
  local where
  while IFS=$'\t' read -r _ p context; do
    [ -n "$p" ] || continue
    case "$context" in
      root) where="at the top level" ;;
      queue_rule) where="inside a \`queue_rules\` entry" ;;
      *) where="inside \`$context\`" ;;
    esac
    err CHECK12 "\`$f\` declares \`$p\` $where, which is not a position Mergify accepts that key in. It is not a setting in an unusual place: the file is refused on the unknown key and NOTHING queues, while every check in this gate reads the key as absent at the path it does assert on. Move it to the position Mergify defines for it."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#MISPLACED"')

  # Exact-path readers. `$1 == p` and nothing looser: a check that matches a
  # SUFFIX is a check that accepts the key one level too deep, which is the
  # misplacement this gate exists to catch.
  val_at()   { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }
  kind_at()  { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { print $3; exit }'; }
  has_path() { printf '%s\n' "$doc" | awk -F'\t' -v p="$1" '$1 == p { found = 1 } END { exit !found }'; }
  paths_re() { printf '%s\n' "$doc" | awk -F'\t' -v re="$1" '$1 ~ re { print $1 }'; }
  # The immediate child KEYS of a mapping, by exact prefix rather than by regex:
  # a rule path carries `[0]`, and every character class in it would have to be
  # escaped to ask this question with `paths_re`.
  child_keys() { printf '%s\n' "$doc" | awk -F'\t' -v pre="$1." '
    index($1, pre) == 1 { rest = substr($1, length(pre) + 1); if (rest !~ /[.[]/) print rest }'; }
  # Condition SUBTREES are deliberately not read here. Flattening a condition
  # list to the scalars underneath loses the connectives, and the two readings
  # that costs are the ones this gate is for: an `or:` of bases read as a
  # conjunction, and a check on one `or:` branch read as required. Those
  # verdicts come from the reader's `#QCCHECK` / `#RULEBASE*` / `#AMC*` records,
  # taken on the tree.

  # --- CHECK 1: max_parallel_checks, at the top level and nowhere else -------
  misplaced="$(paths_re '(^|\\.)max_parallel_checks$' | grep -vx 'merge_queue.max_parallel_checks')"
  if [ -n "$misplaced" ]; then
    err CHECK1 "\`max_parallel_checks\` is declared at \`$(printf '%s' "$misplaced" | tr '\n' ' ')\`, not at the top-level \`merge_queue.max_parallel_checks\`. Mergify permits it in exactly one place and REJECTS the whole file otherwise (\`Extra inputs are not permitted\`) — so this is not a value in the wrong spot, it is a configuration that loads nothing and queues nothing."
  else
    mpc="$(val_at merge_queue.max_parallel_checks)"
    if [ -z "$mpc" ]; then
      err CHECK1 "\`.mergify.yml\` declares no \`merge_queue.max_parallel_checks\`. Left unset it inherits a vendor default above 1, and parallel queue checks are performed on throwaway \`mergify/merge-queue/<sha>\` branches — a second full CI run per pull request."
    elif [ "$(kind_at merge_queue.max_parallel_checks)" != "int" ]; then
      err CHECK1 "\`merge_queue.max_parallel_checks\` is a \`$(kind_at merge_queue.max_parallel_checks)\`, not a whole number. Mergify rejects the file, so nothing queues."
    elif [ "$mpc" -lt 1 ]; then
      err CHECK1 "\`merge_queue.max_parallel_checks\` is \`$mpc\`. The smallest legal width is 1."
    elif [ "$mpc" -gt "$MPC_MAX" ]; then
      err CHECK1 "\`merge_queue.max_parallel_checks\` is \`$mpc\`, above this repository's ceiling of $MPC_MAX. Above 1, Mergify stops checking in place and validates on throwaway \`mergify/merge-queue/<sha>\` branches — a second CI run — and the width is how many of those run AT ONCE, so it multiplies the runners drawn from a pool shared with every other repository on the fleet. If the intent is more throughput, raise \`batch_size\` instead: a batch is validated by ONE draft run whatever its size, so batching buys throughput for no extra runners while the width costs a full concurrent run each. If the intent is throughput rather than capacity, \`merge_queue.mode: parallel\` with a covering scope map buys it for NO extra runners — the width is still the ceiling; the mode only changes which entries may hold those slots. Raising \`MPC_MAX\` in this script is a capacity decision — show \`max_parallel_checks × peak runners per run\` against this repository's own pool ceiling (\`slots_per_host × max_hosts\` from its Terraform, never a live runner count: every pool scales to zero and reports zero while idle) in the same pull request."
    fi
  fi

  # --- CHECK 2: batch_size, once per rule ------------------------------------
  # Per rule, because the default is inherited PER RULE. A whole-file count says
  # `batch_size: 1` exists; the rule that omitted it still batches.
  #
  # Two legal shapes: a plain int, or a `{min, max}` mapping for dynamic
  # batching. Both are read, and the ceiling applies to the largest batch the
  # shape can produce.
  #
  # Above 1 the check also enforces the PAIRING. When a batch fails, Mergify
  # bisects it — splitting and re-checking halves until a single-pull-request
  # batch fails — and `batch_max_failure_resolution_attempts` caps the splits.
  # Unset means UNLIMITED: one flaky test becomes an unbounded chain of draft
  # runs. Too small ends the bisect with pull requests still unseparated, and
  # Mergify dequeues all of them, so a pull request that never failed anything
  # is thrown out for a neighbour's bug. Isolating one of N takes ceil(log2(N))
  # splits, which is exactly the floor asserted below.
  rules="$(paths_re '^queue_rules\\[[0-9]+\\]' | sed -E 's/^(queue_rules\[[0-9]+\]).*/\1/' | sort -u)"
  if [ -z "$rules" ]; then
    err CHECK2 "\`.mergify.yml\` declares no \`queue_rules\`. Mergify then supplies its own defaults, which batch pull requests together and validate the batch on a throwaway queue branch — the second CI run this gate exists to prevent."
  else
    while read -r r; do
      [ -n "$r" ] || continue
      b="$(val_at "$r.batch_size")"
      bk="$(kind_at "$r.batch_size")"
      hi=""
      if ! has_path "$r.batch_size"; then
        err CHECK2 "queue rule \`$r\` declares no \`batch_size\`. It inherits the batching default, and a batch is validated on a throwaway \`mergify/merge-queue/<sha>\` branch — every \`pull_request\` workflow runs a second time for any pull request this rule admits, whatever the other rules declare."
      elif [ "$bk" = "int" ]; then
        if [ "$b" -lt 1 ]; then
          err CHECK2 "queue rule \`$r\` sets \`batch_size: $b\`. The smallest legal batch is 1."
        elif [ "$b" -gt "$BATCH_MAX" ]; then
          err CHECK2 "queue rule \`$r\` sets \`batch_size: $b\`, above this repository's ceiling of $BATCH_MAX. The cost of a larger batch is not runners, it is BLAME: when the batch fails, every member waits through the bisect, and the wider the batch the longer that takes. Raise \`BATCH_MAX\` in this script only alongside the measurement in \`docs/ci-merge-queue-baseline.md\`."
        else
          hi="$b"
        fi
      elif [ "$bk" = "map" ]; then
        lo="$(val_at "$r.batch_size.min")"
        mx="$(val_at "$r.batch_size.max")"
        extra_batch_keys="$(child_keys "$r.batch_size" | grep -vx -e min -e max | tr '\n' ' ')"
        if [ "$(kind_at "$r.batch_size.min")" != "int" ] || [ "$(kind_at "$r.batch_size.max")" != "int" ]; then
          err CHECK2 "queue rule \`$r\` gives \`batch_size\` as a mapping but not as \`{min: <int>, max: <int>}\`. Mergify rejects the file and NOTHING queues."
        elif [ "$lo" -lt 1 ]; then
          err CHECK2 "queue rule \`$r\` sets \`batch_size.min: $lo\`. The smallest legal batch is 1."
        elif [ "$mx" -lt "$lo" ]; then
          err CHECK2 "queue rule \`$r\` sets \`batch_size\` to \`{min: $lo, max: $mx}\` — the maximum is below the minimum, which is not a range."
        elif [ "$mx" -gt "$BATCH_MAX" ]; then
          err CHECK2 "queue rule \`$r\` sets \`batch_size.max: $mx\`, above this repository's ceiling of $BATCH_MAX. The cost of a larger batch is not runners, it is BLAME: when the batch fails, every member waits through the bisect, and the wider the batch the longer that takes. Raise \`BATCH_MAX\` in this script only alongside the measurement in \`docs/ci-merge-queue-baseline.md\`."
        # `min` and `max` are the whole schema here. An extra key is not a
        # harmless annotation — Mergify refuses the document over it and NOTHING
        # queues — and the checks above would not notice, because they ask what
        # `min` and `max` hold rather than what else is present. This gate would
        # then be green on a config the queue never loads, which is the one
        # outcome it exists to make impossible.
        #
        # Held in a variable rather than asked twice: `grep -q` cannot report
        # WHICH key offended, and the message is the whole value of the check.
        # The extra key's own VALUE does not matter — the reader prints a record
        # for every node, mappings and lists included, so `spread: {enabled:
        # true}` and `spread: [true]` both surface as the child `spread`. The
        # `t1-batch-extra-key-*` fixtures hold that.
        elif [ -n "$extra_batch_keys" ]; then
          err CHECK2 "queue rule \`$r\` gives \`batch_size\` a key that is not \`min\` or \`max\`: ${extra_batch_keys}. Mergify's schema takes those two and refuses the whole file over anything else, so nothing queues at all."
        else
          hi="$mx"
        fi
      else
        err CHECK2 "queue rule \`$r\` sets \`batch_size\` to a \`$bk\`. Mergify accepts a whole number or a \`{min, max}\` mapping and rejects anything else, taking the whole file with it."
      fi
      if [ -n "$hi" ] && [ "$hi" -gt 1 ]; then
        need="$(ceil_log2 "$hi")"
        a="$(val_at "$r.batch_max_failure_resolution_attempts")"
        if ! has_path "$r.batch_max_failure_resolution_attempts"; then
          err CHECK2 "queue rule \`$r\` batches up to $hi pull requests but declares no \`batch_max_failure_resolution_attempts\`. Unset means UNLIMITED bisection: one flaky test in a batch becomes an unbounded chain of draft runs, each a full CI run, while every pull request in the batch waits. Declare at least $need — ceil(log2($hi)), the splits it takes to isolate one culprit from $hi."
        elif [ "$(kind_at "$r.batch_max_failure_resolution_attempts")" != "int" ]; then
          err CHECK2 "queue rule \`$r\` sets \`batch_max_failure_resolution_attempts\` to a \`$(kind_at "$r.batch_max_failure_resolution_attempts")\`, not a whole number. Mergify rejects the file and nothing queues."
        elif [ "$a" -lt "$need" ]; then
          err CHECK2 "queue rule \`$r\` batches up to $hi pull requests but allows only $a failure-resolution attempt(s). Isolating one culprit from $hi takes $need splits, so the bisect ends early with pull requests still unseparated — and Mergify dequeues ALL of them, throwing out ones that never failed anything. Raise it to at least $need, or lower the batch."
        fi
      fi
    done <<EOF
$rules
EOF
  fi

  # --- CHECK 3: max_checks_retries ------------------------------------------
  if [ -n "$(paths_re '(^|\\.)max_checks_retries$')" ]; then
    err CHECK3 "\`max_checks_retries\` is set at \`$(paths_re '(^|\\.)max_checks_retries$' | tr '\n' ' ')\`. Retrying checks requires a queue branch to retry them ON, so declaring it disables in-place checking outright."
  fi

  # --- CHECK 4: single-step, as node identity, per rule ----------------------
  # The verdict comes from the loaded objects, so an alias pointing at ANOTHER
  # rule's anchor reads as `different` — the counts balance in the text, the
  # nodes do not, and every pull request that rule admits gets two-step CI.
  while IFS=$'\t' read -r _ r state; do
    [ -n "$r" ] || continue
    [ "$state" = "different" ] || continue
    err CHECK4 "queue rule \`$r\` does not share ONE node between \`queue_conditions\` and \`merge_conditions\`. Mergify checks a queued pull request in place only when \`merge_conditions\` is empty or IDENTICAL to \`queue_conditions\`; two separately written lists — or an alias pointing at another rule's anchor — match only until the next check is added to one of them, and the drift is silent: merges keep working, each pull request merely pays a second full CI run. Write \`queue_conditions: &<name>\` and \`merge_conditions: *<name>\` with THIS rule's own name, or drop \`merge_conditions\` entirely."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#RULE"')

  # --- CHECK 10: each rule owns its condition list ---------------------------
  # CHECK 4 asks whether a rule's two fields are one node; that says nothing
  # about WHOSE node it is. A rule aliasing an earlier rule's anchor for both
  # fields passes CHECK 4 cleanly while the two rules share one list — so a
  # check added for one rule's base silently lands on the other's too.
  while IFS=$'\t' read -r _ r owner; do
    [ -n "$r" ] || continue
    err CHECK10 "queue rule \`$r\` uses the SAME condition list object as \`$owner\` — it aliases that rule's anchor instead of declaring its own. The two rules are then one list: a check added for one rule's base is silently required of the other's, and removing it from one removes it from both. Give each rule its own \`&anchor\`."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#ALIAS"')

  # --- CHECK 9: the queue rule actually gates on CI --------------------------
  # `merge_conditions` being absent or empty is a valid single-step spelling,
  # which makes `queue_conditions` the ONLY thing standing between a pull
  # request and a merge. A rule that names no check merges on base/draft state.
  # A condition list that is not a SEQUENCE. Mergify's schema takes a list here
  # and refuses the file otherwise; loaded, a scalar becomes a one-condition
  # tree that reads as an ordinary — often perfectly gated — rule.
  while IFS=$'\t' read -r _ p ktype; do
    [ -n "$p" ] || continue
    err CHECK9 "\`$p\` is a \`$ktype\`, not a list of conditions. Mergify requires a sequence there and refuses the whole file otherwise, so nothing queues — while loaded here the scalar reads as a single condition, which is how a rule with no gate at all can look gated. This is usually an alias (\`*name\`) pointing at a scalar anchor instead of at a condition list."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#QCTYPE"')

  # `check-skipped` says the check DID NOT RUN. A rule whose only check
  # condition is the skipped form is satisfied by a workflow that never
  # reported — the ungated merge CHECK 9 exists to prevent, spelled in the
  # vocabulary CHECK 9 accepts.
  while IFS=$'\t' read -r _ p; do
    [ -n "$p" ] || continue
    err CHECK9 "queue rule \`$p\` gates only on \`check-skipped\`, which is satisfied when the check never ran. Nothing has to SUCCEED for a pull request this rule admits to embark and merge. The skip-aware form is \`or: [check-success = X, check-skipped = X]\` — the success branch is what makes the skipped branch safe; alone it is not a gate."
  done < <(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#QCSKIPONLY"')

  if [ -n "$rules" ]; then
    while read -r r; do
      [ -n "$r" ] || continue
      if ! has_path "$r.queue_conditions"; then
        err CHECK9 "queue rule \`$r\` declares no \`queue_conditions\`. Entry to the queue is then decided by \`auto_merge_conditions\` alone — which carries base/draft facts and is forbidden from carrying checks — so a pull request can embark and merge before CI has succeeded."
      # The verdict comes from the TREE, not from the presence of a check
      # anywhere under the path. Presence is the dangerous reading twice over: a
      # rule whose only condition is `label = check-success-waived` names a
      # label, and `or: [-draft, check-success = ci]` names a check on one
      # branch while a non-draft pull request embarks through the other with no
      # check required at all. What is asserted is that EVERY satisfiable path
      # requires one. Negated forms are not accepted — `-check-failure = X`
      # requires nothing to have succeeded.
      elif [ "$(printf '%s\n' "$doc" | awk -F'\t' -v p="$r" '$1 == "#QCCHECK" && $2 == p { print $3; exit }')" = "no" ]; then
        err CHECK9 "queue rule \`$r\` has \`queue_conditions\` that do not require a check (\`check-success\`/\`check-neutral\`/\`check-skipped\`) on every path a pull request can satisfy. This is the ONE list that decides when a queued pull request embarks — \`merge_conditions\` is empty or identical by construction — so a pull request taking an unguarded path merges on base/draft state alone. An \`or:\` counts only when EVERY branch requires a check; skip-aware forms (\`or: [check-success = X, check-skipped = X]\`) do."
      fi
    done <<EOF
$rules
EOF
  fi

  # --- CHECK 5: no queue action ---------------------------------------------
  # Matched on the ACTION PATH in the LOADED document, so a block mapping, an
  # inline `queue: {name: default}`, and a `queue` spliced in through a `<<`
  # merge key are one finding rather than one caught and two missed.
  local qaction; qaction="$(paths_re '^pull_request_rules\\[[0-9]+\\]\\.actions\\.queue$')"
  if [ -n "$qaction" ]; then
    err CHECK5 "a \`pull_request_rules\` queue action is back at \`$(printf '%s' "$qaction" | tr '\n' ' ')\`. Its \`conditions:\` are a SEPARATE list from \`merge_conditions\` — different by construction, since it must carry \`base\`/\`-draft\` — so every pull request is checked twice: once on its own branch and once on a throwaway \`mergify/merge-queue/<sha>\` draft. Queue via \`merge_protections_settings.auto_merge_conditions\` instead."
  fi

  # --- CHECK 6: something still queues a green PR, and CAN admit one ---------
  local amc_misplaced; amc_misplaced="$(paths_re '(^|\\.)auto_merge_conditions$' | grep -vx 'merge_protections_settings.auto_merge_conditions')"
  if [ -n "$amc_misplaced" ]; then
    err CHECK6 "\`auto_merge_conditions\` is declared at \`$(printf '%s' "$amc_misplaced" | tr '\n' ' ')\`, not at \`merge_protections_settings.auto_merge_conditions\`. Only that path queues anything; written anywhere else it is an unknown key in a rule Mergify then refuses, and green pull requests sit unqueued with no red check to say why."
  fi

  local amc_kind amc_items autoqueue_on
  amc_kind="$(kind_at merge_protections_settings.auto_merge_conditions)"
  amc_items="$(paths_re '^merge_protections_settings\\.auto_merge_conditions\\[[0-9]+\\]$')"
  # `autoqueue` is deprecated but still honoured, so it counts — only when it is
  # at a queue rule's own path AND actually enabled. Any node merely NAMED
  # `autoqueue` satisfies nothing, and `autoqueue: false` disables the very
  # thing this check is looking for.
  autoqueue_on=""
  while read -r r; do
    [ -n "$r" ] || continue
    [ "$(val_at "$r.autoqueue")" = "true" ] && autoqueue_on="yes"
  done <<EOF
$rules
EOF

  if [ -n "$amc_items" ]; then
    :
  elif [ -n "$autoqueue_on" ] || [ -n "$qaction" ]; then
    :
  elif [ "$amc_kind" = "seq" ] || [ "$amc_kind" = "null" ]; then
    err CHECK6 "\`merge_protections_settings.auto_merge_conditions\` is present but empty. An empty condition list is not \"queue everything\" — nothing matches it, so green pull requests sit unqueued exactly as if the key were missing, and no check goes red to say why."
  else
    err CHECK6 "nothing in \`.mergify.yml\` puts a pull request INTO the queue: no \`merge_protections_settings.auto_merge_conditions\`, no enabled \`queue_rules[].autoqueue\`, no queue action. Mergify then posts a \"tick the box to queue\" comment and waits for a human — the pull request sits green and unmerged with no red check anywhere to say why (DataRetrival #2378)."
  fi

  # --- CHECK 7: auto_merge_conditions must not restate the checks ------------
  # Read from the loaded list, so an aliased `auto_merge_conditions: *admission`
  # is inspected like any other.
  #
  # Split on the ATTRIBUTE, not matched as a substring. `check-` occurs inside
  # ordinary VALUES too — `label = check-success-waived` names a label, restates
  # nothing — and a gate that rejects a correct config teaches its next reader
  # to delete it. Every operator spelling counts, negation included: `-check-
  # success = X` and `check-success != X` are restated checks as much as the
  # plain form, and the old `[=:~]` character class matched neither.
  local amc_checks; amc_checks="$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#AMCCHECK" { print $2 }' | sort -u | tr '\n' ' ')"
  if [ -n "${amc_checks// /}" ]; then
    err CHECK7 "\`auto_merge_conditions\` carries check conditions (${amc_checks}) — any \`check-*\` attribute, whether it restates a required check or names a failure/pending state. They belong once, in the anchored condition list, which is what decides when a queued pull request embarks; a second copy is one more list to keep in sync and it will drift. Keep this list to the \`base\`/\`-draft\`/label facts."
  fi

  # --- CHECK 8: auto_merge_conditions must aim at a branch a rule serves -----
  # `base = develop` against queue rules that only serve `main` is the CHECK 6
  # failure with the key present: the list exists, nothing ever matches it.
  #
  # Both sides are the ADMISSIBLE SET computed on the tree, never a list of the
  # `base = …` strings found underneath. A flattened list cannot tell
  # `[base = main, base = develop]` — a conjunction no pull request satisfies —
  # from `or: [base = main, base = develop]`, which is the ordinary way to serve
  # two branches, and the reading that treats them alike fails a correct config.
  local rule_bases
  has() { printf '%s\n' "$doc" | awk -F'\t' -v k="$1" '$1 == k' | grep -q .; }
  rule_bases="$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#RULEBASE" { print $3 }' | sort -u)"

  # An EMPTY admissible set is the impossible list, whatever spelling produced
  # it: two ANDed bases, or an `or:` every branch of which is ANDed against a
  # different base. Each base named is individually served by a rule, which is
  # exactly why it reads as correct.
  if has '#AMCBASEEMPTY'; then
    err CHECK8 "\`auto_merge_conditions\` admits NO base: its \`base\` conditions are ANDed and no pull request can target two branches at once, so nothing is ever queued — while every base it names IS served by a rule, which is why this reads as correct. Write one base, or an explicit \`or:\`."
  fi
  # A BASE-LESS list is the third spelling. If the rules DO constrain the base,
  # an unconstrained auto-merge list matches pull requests targeting branches no
  # rule admits — queued into nothing, green and unmerged, nothing red. Not
  # demanded when a rule takes any base, and not when either side constrains the
  # base by regex or by exclusion, whose admissible set is not enumerable here.
  if [ -n "$amc_items" ] && [ -n "$rule_bases" ] \
     && has '#AMCBASEANY' && ! has '#AMCBASEREGEX' && ! has '#AMCBASENOT' \
     && ! has '#RULEBASEANY' && ! has '#RULEBASEREGEX'; then
    err CHECK8 "\`auto_merge_conditions\` names no \`base\`, but the queue rules only admit: $(printf '%s' "$rule_bases" | tr '\n' ' '). Pull requests targeting any other branch are matched for auto-merge and then have no rule to queue into — they sit green and unmerged with no red check to say why. Name the base this repository queues."
  fi

  # Membership and draft polarity are both decided in the reader, where each
  # side is still a SET (with a complement, so `base != main` participates)
  # rather than lines of text, and where each rule's base and draft terms are
  # still attached to each other. Rebuilding either correlation out here would
  # be asking a different question with the same words.
  local unserved
  unserved="$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#AMCBASEUNSERVED" { print $2 }' | sort -u)"
  while read -r b; do
    [ -n "$b" ] || continue
    err CHECK8 "\`auto_merge_conditions\` queues pull requests based on \`$b\`, but no queue rule admits that base (the rules serve: $(printf '%s' "$rule_bases" | tr '\n' ' ')). Auto-queueing then matches pull requests no rule can take — they sit green and unmerged with no red check to say why."
  done <<EOF
$unserved
EOF
  # Every PATH through the list contradicts itself — `base = main` beside both
  # `draft` and `-draft`. The base set stays non-empty, so the checks above see
  # a list naming a served branch, and it still queues nothing.
  if has '#AMCDEAD'; then
    err CHECK8 "every path through \`auto_merge_conditions\` contradicts itself, so no pull request satisfies the list and nothing is ever queued. Each condition is satisfiable alone — which is why the base it names still looks served — but they cannot hold together (\`draft\` beside \`-draft\`, or two bases in one path). Split the mutually exclusive facts into an explicit \`or:\`."
  fi
  if has '#AMCTYPE'; then
    err CHECK8 "\`merge_protections_settings.auto_merge_conditions\` is a \`$(printf '%s\n' "$doc" | awk -F'\t' '$1 == "#AMCTYPE" { print $2; exit }')\`, not a list of conditions. Mergify requires a sequence and refuses the whole file otherwise — nothing queues — while loaded here the scalar reads as a single working condition. Usually an alias pointing at a scalar anchor."
  fi
  if has '#AMCBASEDISJOINT'; then
    err CHECK8 "\`auto_merge_conditions\` and the queue rules admit DISJOINT sets of branches: no pull request can satisfy both, so nothing is ever queued. Same failure as an unserved base, in a spelling that names no base to point at — an admission list written as an exclusion (\`base != x\`), or a queue rule whose own \`base\` conditions are ANDed together and therefore admit nothing at all."
  fi
  if printf '%s\n' "$doc" | awk -F'\t' '$1 == "#DRAFTCLASH" && $2 == "draft"' | grep -c . >/dev/null; then
    err CHECK8 "\`auto_merge_conditions\` admits \`draft\` while every queue rule that can take those pull requests requires \`-draft\`. Only drafts are then auto-queued, and no rule accepts them: nothing merges, and nothing goes red."
  fi
  if printf '%s\n' "$doc" | awk -F'\t' '$1 == "#DRAFTCLASH" && $2 == "-draft"' | grep -c . >/dev/null; then
    err CHECK8 "\`auto_merge_conditions\` requires \`-draft\` while every queue rule that can take those pull requests requires \`draft\`. The two admit disjoint sets of pull requests, so the queue takes nothing at all — the mirror image of the case above, and just as silent."
  fi
}

selftest() {
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local cases=0
  # Probe HERE, in the parent shell, so the exported result reaches every
  # fixture's subshell. Probing inside `expect` sets it in a child that exits.
  ensure_yaml || true

  # An `auto_merge_conditions` holding one `check-success` under N nested `and:`
  # nodes. Written out rather than escaped inline, because the indentation IS
  # the nesting and a one-line spelling of it is unreadable.
  deep_amc() {
    local n="$1" i=0 pad
    printf 'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n'
    printf '    queue_conditions: &gate\n      - base = main\n      - -draft\n'
    printf '      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n'
    printf 'merge_protections_settings:\n  auto_merge_conditions:\n'
    while [ "$i" -lt "$n" ]; do
      pad=$((4 + i * 4))
      printf '%*s- and:\n' "$pad" ''
      i=$((i + 1))
    done
    printf '%*s- check-success = "Lint"\n' $((4 + n * 4)) ''
  }

  # expect <name> "<expected check ids, space-separated>" <config body>
  #
  # The ID SET, not a count: asserting counts lets a regressed detector hide
  # behind a different one firing the same number of times on the same fixture.
  expect() {
    local name="$1" want="$2" body="$3" got
    printf '%b' "$body" >"$tmp/$name.yml"
    fail=0
    got="$(scan_file "$tmp/$name.yml" 2>&1 \
      | sed -n 's/^::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort | tr '\n' ' ' | sed 's/ *$//')"
    want="$(printf '%s' "$want" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/^ *//; s/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "SELFTEST FAILED — fixture \`$name\` should raise [${want:-none}]; the gate raised [${got:-none}]. A detector is not seeing what this fixture exists to prove."
      return 1
    fi
    cases=$((cases + 1))
  }

  local CLEAN='merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n'

  expect clean '' "$CLEAN" || return 1
  # The four in-place preconditions, one fixture each.
  expect no-mpc CHECK1 "$(printf '%s' "$CLEAN" | sed 's/merge_queue:\\n  max_parallel_checks: 1\\n//')" || return 1
  expect mpc-5 CHECK1 "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: 5/')" || return 1
  expect batch-5 CHECK2 "$(printf '%s' "$CLEAN" | sed 's/batch_size: 1/batch_size: 5/')" || return 1
  # The `{min, max}` shape. A whole-file text search for `batch_size: <n>` finds
  # nothing here, which is how an unbounded range passes for compliance —
  # measured live on the fleet 2026-08-17, one repository was batching five deep
  # with no attempt bound and no declared width at all.
  #
  # NOTE the sed replacements below are spelled out with `\\n` rather than built
  # from a printf format. `printf` would collapse `\\n` to `\n`, and GNU sed then
  # reads `\n` in the REPLACEMENT as a real newline — producing fixtures that are
  # merely different from the ones intended, rather than failing and saying so.
  expect batch-range-over CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5/')" || return 1
  expect batch-range-one '' \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 1/')" || return 1
  expect batch-min-above-max CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 3\\n      max: 2/')" || return 1
  expect batch-map-missing-max CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1/')" || return 1
  expect batch-zero CHECK2 "$(printf '%s' "$CLEAN" | sed 's/batch_size: 1/batch_size: 0/')" || return 1
  expect batch-not-a-number CHECK2 "$(printf '%s' "$CLEAN" | sed 's/batch_size: 1/batch_size: "1"/')" || return 1
  expect mpc-zero CHECK1 "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: 0/')" || return 1
  expect mpc-not-a-number CHECK1 "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: "1"/')" || return 1

  # TIER 1, exercised HERE even though this repository is Tier 0. The bisect
  # pairing is the rule most likely to be got wrong by whoever raises the
  # constants, and it is unreachable while BATCH_MAX is 1 — so the fixtures
  # below raise the ceilings for their own duration. A Tier 1 repository that
  # raises the constants for real inherits detectors these fixtures already
  # proved, instead of shipping them untested.
  local T0_MPC="$MPC_MAX" T0_BATCH="$BATCH_MAX"
  MPC_MAX=3 BATCH_MAX=5
  expect t1-mpc-at-ceiling '' "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: 3/')" || return 1
  expect t1-mpc-over-ceiling CHECK1 "$(printf '%s' "$CLEAN" | sed 's/max_parallel_checks: 1/max_parallel_checks: 4/')" || return 1
  # ceil(log2(5)) is 3, so five deep needs three attempts and no fewer.
  expect t1-batch-paired '' \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5\\n    batch_max_failure_resolution_attempts: 3/')" || return 1
  expect t1-batch-unbounded CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5/')" || return 1
  expect t1-batch-one-short CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5\\n    batch_max_failure_resolution_attempts: 2/')" || return 1
  # An extra key under `batch_size` satisfies every question the checks above
  # ask — min is an int, max is an int, the range is sane, the bisect is paired —
  # and Mergify still refuses the whole document over it.
  expect t1-batch-extra-key CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5\\n      spread: true\\n    batch_max_failure_resolution_attempts: 3/')" || return 1
  # The same key carrying a MAPPING and a LIST. Raised in review as a gap on the
  # theory that `child_keys` suppresses non-scalars; it does not — the reader
  # prints a record for every node, so the container itself is a child of
  # `batch_size` and only its own descendants are filtered out. These two hold
  # that reading, so a future change to the reader that stops emitting container
  # nodes fails here instead of silently reopening the hole.
  expect t1-batch-extra-key-map CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5\\n      spread:\\n        enabled: true\\n    batch_max_failure_resolution_attempts: 3/')" || return 1
  expect t1-batch-extra-key-list CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size:\\n      min: 1\\n      max: 5\\n      spread:\\n        - true\\n    batch_max_failure_resolution_attempts: 3/')" || return 1
  # The bisect budget MISSPELLED, on a Tier 0 rule. Before it was guarded this
  # was the gate's quietest possible failure: CHECK 2 does not look at a batch of
  # 1, so nothing here had an opinion, while Mergify refused the file outright.
  expect attempts-misspelled CHECK11 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 1\\n    batch_max_failure_resolution_attempt: 3/')" || return 1
  # `0` is not "unset" — it dequeues the whole batch on the first failure, which
  # is the innocent-pull-request outcome stated the other way round.
  expect t1-batch-attempts-zero CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 5\\n    batch_max_failure_resolution_attempts: 0/')" || return 1
  expect t1-batch-int-paired '' \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 4\\n    batch_max_failure_resolution_attempts: 2/')" || return 1
  expect t1-batch-over-ceiling CHECK2 \
    "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 6\\n    batch_max_failure_resolution_attempts: 3/')" || return 1
  # A batch of exactly 1 never bisects, so it needs no attempt bound.
  expect t1-batch-one-unpaired '' "$CLEAN" || return 1
  MPC_MAX="$T0_MPC" BATCH_MAX="$T0_BATCH"
  expect retries CHECK3 "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 1\\n    max_checks_retries: 2/')" || return 1
  # The same key QUOTED, and the same key spliced in through a merge key. Both
  # are the setting; only a parser sees either.
  expect retries-quoted CHECK3 "$(printf '%s' "$CLEAN" | sed 's/    batch_size: 1/    batch_size: 1\\n    "max_checks_retries": 2/')" || return 1
  expect retries-merge-key CHECK3 \
    'defaults: &d\n  max_checks_retries: 2\nmerge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    <<: *d\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The identity, broken the way it actually breaks: two lists written out, equal
  # today. A value comparison passes this; node identity is what catches it.
  expect split-lists CHECK4 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions:\n      - base = main\n      - check-success = "Lint"\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `merge_conditions: []` is the OTHER valid single-step spelling, exactly as
  # omitting the key is. Flagging it would push repos back to a written-out list.
  expect merge-conditions-empty '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: []\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A queue action returning: CHECK 5 fires, CHECK 6 stays silent (it does queue).
  expect queue-action CHECK5 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions:\n      queue:\n        name: default\n' || return 1
  # The SAME action inline, and again with the whole `actions` mapping inline.
  expect queue-action-inline CHECK5 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions:\n      queue: {name: default}\n' || return 1
  expect queue-action-flow-actions CHECK5 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\npull_request_rules:\n  - name: auto-queue\n    conditions:\n      - base = main\n    actions: {queue: {name: default}}\n' || return 1
  # Both halves of #2378 removed: nothing queues at all.
  expect nothing-queues CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n' || return 1
  # The key is present and empty. Nothing matches an empty list, so this queues
  # exactly as much as the fixture above: nothing.
  expect amc-empty CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions: []\n' || return 1
  # `autoqueue` is the deprecated path — accepted, but only when enabled.
  expect autoqueue-true '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n    autoqueue: true\n' || return 1
  expect autoqueue-false CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n    autoqueue: false\n' || return 1
  expect amc-checks CHECK7 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - check-success = "Lint"\n' || return 1
  # The same restatement reached through an ALIAS. The list is not written under
  # the key at all; only the loaded document has it there.
  expect amc-checks-aliased CHECK7 \
    'admission: &adm\n  - base = main\n  - check-success = "Lint"\nmerge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions: *adm\n' || return 1
  # Auto-queueing aimed at a branch no queue rule serves: the key is present and
  # the queue still never admits anything.
  expect amc-wrong-base CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = develop\n' || return 1
  # A COMMENTED-OUT queue action must not satisfy CHECK 6, and must not trip
  # CHECK 5: Mergify never sees it, so reading raw text gets both wrong.
  expect commented-out CHECK6 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n# pull_request_rules:\n#   - name: auto-queue\n#     actions:\n#       queue:\n#         name: default\n' || return 1
  # TWO queue rules, each conforming, each with its OWN anchor.
  expect two-queues '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *def\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # And the same two-rule shape with ONE rule unanchored: a per-rule regression
  # that a whole-file "an anchor exists" test would pass.
  expect two-queues-one-split CHECK4 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions:\n      - base = main\n      - check-success = "Lint"\n    merge_conditions:\n      - base = main\n      - check-success = "Lint"\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The counts BALANCE here — two anchors, two aliases — but the second rule
  # aliases the FIRST rule's node, so its own conditions are a different list.
  expect cross-aliased CHECK4 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Build"\n    merge_conditions: *low\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Second rule omits batch_size. A whole-file count sees the first rule's `1`
  # and passes; this rule batches.
  expect rule-without-batch CHECK2 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: low-risk\n    queue_conditions: &low\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *low\n    batch_size: 1\n  - name: default\n    queue_conditions: &def\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *def\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `max_parallel_checks` one level too deep: Mergify rejects the file outright.
  # A keyword scan finds the value it wanted and reports in-place checking.
  expect mpc-misplaced CHECK1 \
    'queue_rules:\n  - name: default\n    max_parallel_checks: 1\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `auto_merge_conditions` in a queue rule: misplaced AND nothing queues.
  expect amc-misplaced 'CHECK6 CHECK6' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n    auto_merge_conditions:\n      - base = main\n' || return 1
  # A required context whose name contains a colon. Quoted, it is one scalar;
  # a reader that splits on `:` invents a path from it and can satisfy a check
  # nothing in the file declares.
  expect colon-in-condition '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - '"'"'check-success = "build: api"'"'"'\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The required check deleted from the one list that gates the queue. Every
  # structural invariant still holds; the queue would merge before CI passes.
  expect no-check-condition CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The skip-aware shape the fleet actually uses: each required check is
  # `or: [check-success = X, check-skipped = X]`, because a path-filtered job
  # legitimately skips and a skipped check is not a success. The checks are then
  # one level below the condition list, where a top-level scan does not see them.
  expect nested-or-conditions '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - or:\n          - check-success = "Lint"\n          - check-skipped = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # And the same nesting used to smuggle the checks into auto_merge_conditions.
  expect amc-checks-nested CHECK7 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - or:\n        - check-success = "Lint"\n        - check-skipped = "Lint"\n' || return 1
  expect no-queue-conditions CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Two rules, one list: the second aliases the first rule's anchor for BOTH of
  # its fields, so every per-rule identity verdict is `same` and CHECK 4 is
  # silent — while `release` in fact requires the check written for `main`.
  expect shared-condition-list CHECK10 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n  - name: release\n    queue_conditions: *gate\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # `auto_merge_conditions` present, non-empty, and naming NO base. The orphan
  # loop has nothing to compare and passes; the list matches pull requests on
  # every branch, and the ones the rule does not admit queue into nothing.
  expect amc-no-base CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - -draft\n' || return 1
  # …but a base-less list is FINE when no rule constrains the base either:
  # there is nothing for it to disagree with, and demanding a base here would
  # reject a correct config.
  expect amc-no-base-unconstrained-rules '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - -draft\n' || return 1
  # `check-success` inside a VALUE, not as the operator. This is a label name;
  # it restates no check, and rejecting it would teach the next reader that
  # CHECK 7 fires on correct configurations and can be deleted.
  expect amc-label-lookalike '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - label != check-success-waived\n' || return 1
  # The same lookalike on the QUEUE side, where the loose reading fails the
  # dangerous way: this rule gates on a label and nothing else, and a substring
  # match reads it as gated on CI.
  expect queue-label-lookalike CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - label != check-success-waived\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A duplicate key: which declaration wins is the loader's business, not this
  # gate's. Both findings are wanted — the second value is also non-compliant,
  # and a reader that stops at the first `max_parallel_checks: 1` reports clean.
  expect duplicate-key 'CHECK0 CHECK1' \
    'merge_queue:\n  max_parallel_checks: 1\n  max_parallel_checks: 5\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A top-level key literally NAMED `merge_queue.max_parallel_checks`. Mergify
  # sees an unknown top-level key and refuses the file; a path built by joining
  # raw keys sees the nested mapping it was looking for.
  expect flat-dotted-key CHECK0 \
    '"merge_queue.max_parallel_checks": 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # A recursive alias. Legal YAML, no valid Mergify configuration, and walked
  # naively it dies AFTER printing every record the checks below read.
  expect recursive-alias CHECK0 "${CLEAN}loop: &loop\n  - *loop\n" || return 1
  # Two bases in one ANDed list: each is served by a rule, so the orphan loop
  # passes both, and no pull request satisfies the conjunction.
  expect amc-two-bases CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n  - name: dev\n    queue_conditions: &devgate\n      - base = develop\n      - check-success = "Lint"\n    merge_conditions: *devgate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - base = develop\n' || return 1
  # Admission and rule disagree about drafts: only drafts are auto-queued, and
  # the rule admits none of them.
  expect amc-draft-polarity CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - draft\n' || return 1
  # The SAME two bases under an `or:` — the ordinary way to serve two branches,
  # and indistinguishable from the fixture above once the tree is flattened.
  # This is the false failure that would teach a reader to delete CHECK 8.
  expect amc-or-two-bases '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n  - name: dev\n    queue_conditions: &devgate\n      - base = develop\n      - check-success = "Lint"\n    merge_conditions: *devgate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - or:\n        - base = main\n        - base = develop\n' || return 1
  # An `or:` whose OTHER branch requires nothing: a non-draft pull request takes
  # the `-draft` branch and embarks with no check required at all. Presence of a
  # check anywhere under the list reads this as gated on CI.
  expect qc-or-unguarded-branch CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - or:\n          - -draft\n          - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # Restated checks in the other operator spellings. `check-success != X` hides
  # its `=` inside a `!=`, and the negated form leads with a `-`; a character
  # class of `[=:~]` anchored after the attribute matched neither.
  expect amc-check-not-equals CHECK7 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - check-failure != "Lint"\n' || return 1
  expect amc-check-negated CHECK7 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -check-success = "Lint"\n' || return 1
  # `base ~=` constrains the base to a set this gate cannot enumerate. Comparing
  # an unenumerable set against the rules would reject a correct configuration.
  expect base-regex '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base ~= ^release/\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base ~= ^release/\n' || return 1
  # One character off a guarded key. `merge_conditions` is then absent — which
  # CHECK 4 accepts as a valid single-step spelling — while Mergify refuses the
  # whole file on the unknown key and nothing queues at all.
  expect typo-key CHECK11 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditons: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n' || return 1
  # The mirror of the draft-polarity case: the admission list refuses drafts and
  # every rule that constrains draft state requires one.
  expect amc-draft-polarity-mirror CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # Two rules with OPPOSITE draft polarity, which is routing rather than
  # deadlock: `main` takes non-drafts, `release` takes drafts, and the admission
  # list names `release`. Reading the union of every rule's draft terms finds
  # `-draft` on the rule this pull request never reaches and fails a correct
  # configuration — the false failure that teaches a reader to delete CHECK 8.
  expect amc-draft-polarity-other-rule '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\n  - name: release\n    queue_conditions: &relgate\n      - base = release\n      - draft\n      - check-success = "Lint"\n    merge_conditions: *relgate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = release\n    - draft\n' || return 1
  # A rule that pins NO draft polarity accepts both, so it clears the clash on
  # its own — reading "no `-draft` term" as "requires the opposite" fails it.
  expect amc-draft-unconstrained-rule '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - draft\n' || return 1
  # `base != main` is DECIDABLE, and disjoint from `base = main`. The admission
  # list takes everything but `main`; the only rule takes `main` alone.
  expect amc-base-excluded CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base != main\n    - -draft\n' || return 1
  # A rule constraining its base by REGEX has no enumerable admissible set, so
  # the base-less admission list above it cannot be called unserved.
  expect rule-base-regex-silences-baseless '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base ~= ^(main|release/.+)$\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - -draft\n' || return 1
  # An AND of two ORs. No pull request targets two bases, so the terms pairing
  # `base = main` with `base = develop` are unsatisfiable and drop out; every
  # SURVIVING term names the check, which is what "required on every path" means.
  # Asking `any(child requires)` per AND would answer no and raise CHECK4 here.
  expect qc-and-of-ors-joint-check '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - or:\n          - base = develop\n          - check-success = "Lint"\n      - or:\n          - base = release\n          - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # The operator is the LEFTMOST one OUTSIDE quotes. A `!=` inside the quoted
  # check name is part of the value; splitting on it reads the attribute as
  # `check-success = "lint` and the condition stops counting as a required check.
  expect quoted-value-holding-operator '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "lint != docs"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # The admission list has PATHS of its own. As a whole it pins no polarity, so
  # asking the question once answers "unpinned" and says nothing — while its
  # `draft` branch is deadlocked against the `main`/`-draft` rule exactly as if
  # it had been written alone.
  expect amc-draft-per-branch CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - or:\n        - and:\n            - base = main\n            - draft\n        - and:\n            - base = main\n            - -draft\n' || return 1
  # A tab inside a mapping key is the record protocol delimiter itself. Emitted
  # verbatim it decodes as the required path carrying the required value: a key
  # Mergify refuses, certified here as the setting it is impersonating.
  expect key-holding-tab CHECK0 \
    'merge_queue:\n  max_parallel_checks: 1\n  "max_parallel_checks\\tx": 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # A regex ANDed with an exact base. The regex is not "unconstrained", and it
  # is not opaque either: applied to the one branch the list names, it decides
  # the question — `develop` does not match `^release/`, so this list admits
  # nothing at all and queues nothing. Dropping the regex would read it as
  # plainly admitting `develop`; declining the comparison would report clean.
  expect amc-regex-and-exact CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base ~= ^release/\n    - base = develop\n    - -draft\n' || return 1
  # ... and where the regex meets a COMPLEMENT there is nothing to apply it to:
  # `base != main` enumerates no candidate to test the pattern against, so the
  # pair stays unknown and the comparison is declined rather than guessed.
  expect regex-against-exclusion '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base ~= ^release/\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base != main\n    - -draft\n' || return 1
  # The rule's OWN bases are ANDed, so it admits nothing and contributes no base
  # to compare against. An empty `rule_bases` used to skip the comparison
  # entirely and report PASS on a queue that cannot take a single pull request.
  expect rule-base-contradiction CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - base = develop\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # `not:` is not the end of reading. This rule serves everything EXCEPT main,
  # which is exactly the branch the admission list names, so nothing can queue.
  # Read as an unknown connective the subtree used to answer UNCONSTRAINED — an
  # assertion that it serves every branch — and the comparison passed.
  expect rule-not-inverted-base CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - not:\n          base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # The same inversion where it must stay SILENT: `not: {base = develop}` serves
  # main among everything else, so the admission list is served and the config is
  # ordinary. An inversion that only ever raises findings is a broken reader with
  # a lucky fixture.
  expect rule-not-inverted-served '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - not:\n          base = develop\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # A `draft` branch that also carries `base = main` AND `base != main`. No pull
  # request takes it, so it is not an admitted polarity to compare rules against.
  # Counting only positive `base =` clauses left it alive and reported the
  # `-draft` rule as deadlocked against a path that cannot exist.
  expect amc-term-base-negation-dead '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - or:\n        - and:\n            - base = main\n            - base != main\n            - draft\n        - and:\n            - base = main\n            - -draft\n' || return 1
  # An interpreter handed in through the environment is a CACHE, not an
  # instruction. Trusted unprobed, a stale `PY_BIN` skips the probe and the
  # reader dies inside a valid config — CHECK0 on a file that has nothing wrong
  # with it. Probed and dropped, the candidate loop still finds a working one.
  PY_BIN=/nonexistent/python expect stale-py-bin-env '' "$CLEAN" || return 1
  # A guarded key spelled CORRECTLY, at a position Mergify refuses. Every
  # exact-path reader here treats it as absent, and absent is a spelling several
  # of them accept.
  expect misplaced-guarded-key 'CHECK12 CHECK12' \
    "${CLEAN}merge_conditions: []\nbatch_size: 2\n" || return 1
  # ... and the near-miss test asks the same question the other way round. A key
  # two edits from `merge_queue` in a mapping that is not a Mergify object is
  # not a misspelling of anything — the correctly spelled key would mean nothing
  # there either.
  expect near-miss-outside-schema '' \
    "${CLEAN}scopes:\n  source:\n    files:\n      merge-queue: true\n" || return 1
  # A condition list that is not a sequence. Mergify refuses the file on the
  # type; loaded, the scalar is a one-condition tree that reads as a gated rule.
  expect queue-conditions-scalar CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nanchors:\n  gate: &gate "check-success = Lint"\nqueue_rules:\n  - name: default\n    queue_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # `check-skipped` says the check did not run. Alone it gates nothing, and it
  # is spelled in the exact vocabulary CHECK 9 accepts.
  expect skipped-only-gate CHECK9 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - check-skipped = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # The skip-aware form the fleet actually uses. The success branch is what
  # makes the skipped branch safe, so this must stay clean.
  expect skip-aware-or '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - -draft\n      - or:\n          - check-success = "Lint"\n          - check-skipped = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # An admission list every path of which contradicts ITSELF. The base set stays
  # non-empty — `main` is named and served — so every base check reads correct,
  # and the list queues nothing.
  expect amc-self-contradictory CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base = main\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - draft\n    - -draft\n' || return 1
  # A regex is not "unknown": it is a PREDICATE, and applied to the branch the
  # admission list names it decides the question. Declining the comparison let a
  # rule serving `^release/` stand in for the missing `main` rule.
  expect rule-regex-unserved-base CHECK8 \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base ~= ^release/\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = main\n    - -draft\n' || return 1
  # ... and the same predicate says this pair is FINE, which is what stops the
  # check above from being a blanket rejection of regex rules.
  expect rule-regex-served-base '' \
    'merge_queue:\n  max_parallel_checks: 1\nqueue_rules:\n  - name: default\n    queue_conditions: &gate\n      - base ~= ^release/\n      - -draft\n      - check-success = "Lint"\n    merge_conditions: *gate\n    batch_size: 1\nmerge_protections_settings:\n  auto_merge_conditions:\n    - base = release/2026\n    - -draft\n' || return 1
  # Nesting past the read depth. The restated check is really in the file; a
  # reader that stops before reaching it must say so rather than report clean.
  expect deep-nesting CHECK0 \
    "$(deep_amc 70)" || return 1
  # Aliases that reference each other ACYCLICALLY. The cycle guard does not fire
  # — there is no cycle — and each level doubles the traversal, so this
  # sub-kilobyte file expands past any timeout the job is given.
  expect alias-fanout CHECK0 \
    "${CLEAN}a: &a [x, x]\nb: &b [*a, *a]\nc: &c [*b, *b]\nd: &d [*c, *c]\ne: &e [*d, *d]\nf: &f [*e, *e]\ng: &g [*f, *f]\nh: &h [*g, *g]\ni: &i [*h, *h]\nj: &j [*i, *i]\nk: &k [*j, *j]\nl: &l [*k, *k]\nm: &m [*l, *l]\nn: &n [*m, *m]\no: &o [*n, *n]\n" || return 1
  # Every invariant above still matches textually; the document does not load,
  # so Mergify refuses the file and the queue stops.
  expect unloadable CHECK0 "${CLEAN}broken: [\n" || return 1
  # A missing file is a finding, not a pass.
  expect_missing() {
    fail=0
    local got; got="$(scan_file "$tmp/absent.yml" 2>&1 | grep -c '^::error::')"
    [ "$got" -eq 1 ] || { echo "SELFTEST FAILED — a missing .mergify.yml reported $got findings, not 1."; return 1; }
    cases=$((cases + 1))
  }
  expect_missing || return 1

  echo "PASS — selftest: $cases fixtures, each asserted on the check ids it plants."
  return 0
}

if [ "${1:-}" = "--selftest" ]; then
  selftest || exit 1
  exit 0
fi

scan_file "${1:-$REPO_ROOT/.mergify.yml}"

if [ "$fail" -ne 0 ]; then
  echo "FAILED — the merge queue would check pull requests on a throwaway branch, or nothing would queue them at all."
  exit 1
fi
echo "PASS — the queue is within its tier (max_parallel_checks <= $MPC_MAX, batch_size <= $BATCH_MAX with the bisect bounded, no retries, one anchored condition list per rule), each rule gates on CI, and auto_merge_conditions queues green pull requests without a human."
