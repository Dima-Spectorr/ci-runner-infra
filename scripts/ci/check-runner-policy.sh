#!/usr/bin/env bash
# =============================================================================
# check-runner-policy.sh — which pool a job may claim, and for how long
#
# USAGE
#   bash scripts/ci/check-runner-policy.sh [--selftest]
#                                          [--scope=<label>]
#                                          [--forks=allowed|blocked]
#                                          [--max-timeout=<minutes>]
#                                          [--allow-dynamic-runner]
#                                          [<file>...]
#
# PURPOSE
#   Properties of a `.github/workflows/*.yml` job, all of which have already
#   gone wrong on this fleet and none of which any existing gate reads:
#
#     RUNNER1  a fleet-reachable `runs-on` also names a label that SCOPES it to
#              one repository.
#     RUNNER2  and, with `--scope=<label>`, it must be THAT label.
#     RUNNER3  every job declares `timeout-minutes`.
#     RUNNER4  a workflow reachable by fork code keeps that code off the pool.
#     RUNNER5  the runner is selected dynamically — UNDECIDED, not passed.
#     RUNNER6  and the declared timeout is actually below the default it replaces.
#     RUNNER7  a REMOTE reusable workflow's jobs are not in this repository.
#
# WHAT COUNTS AS REACHING THE FLEET
#   `self-hosted` is a LABEL, not a requirement. GitHub routes a job to any
#   runner whose label set is a SUPERSET of what `runs-on` names, so
#   `runs-on: IntegrateIT` and `runs-on: [linux, gcp]` both reach this fleet
#   without the marker ever appearing. An earlier revision gated RUNNER1/2/4 on
#   seeing that literal, which made omitting one redundant label the cheapest
#   way past all three. So the question is inverted: a job is treated as
#   fleet-reachable unless EVERY label it names is a GitHub-hosted image
#   (`ubuntu-*`, `windows-*`, `macos-*`), and a dynamically selected runner —
#   an expression or a `{group:}` — counts as reachable for the fork question,
#   because "not proven self-hosted" is not "hosted".
#
# WHY RUNNER1 IS A SECURITY CHECK AND NOT TIDINESS
#   Every pool on this fleet answers to `self-hosted, <os>, gcp` plus ONE
#   repository label, and the repository label is the whole of the boundary.
#   `README.md` states the rule it enforces: one repository per pool, because a
#   warm host reuses caches, checked-out trees and whatever credential material
#   the previous job left behind. A `runs-on: [self-hosted, Linux, gcp]` is not
#   a job with a short label list — it is a job that any pool in the fleet can
#   pick up, so one repository's workflow executes on another repository's warm
#   host. IntegrateIT's `runner-version-check.yml` was written that way and ran
#   that way weekly (measured 2026-08-15); nothing reported it, because from
#   GitHub's side it is a job that found a runner.
#
#   The check needs no per-repo configuration to make that judgement, and
#   deliberately so — a gate every consumer must configure is a gate several
#   consumers configure wrongly. A label is a SCOPE label when it is not one of
#   the platform labels every pool carries (`GENERIC` below). That is what makes
#   `[self-hosted, linux, gcp]` fail and `[self-hosted, linux, gcp, <Repo>]`
#   pass without this file ever knowing a repository name. `--scope=<label>`
#   adds the stronger form for a consumer that wants it: not merely SOME scope,
#   but its own.
#
# WHY RUNNER3 IS HERE RATHER THAN IN A STYLE GUIDE
#   A job with no `timeout-minutes` inherits GitHub's 360-minute default. On a
#   warm host that is a slot held for six hours; and where the queue's
#   `checks_timeout` expires first, the pull request is SILENTLY DEQUEUED rather
#   than turning red. The catalog measured nine repositories with effectively no
#   job timeouts at all.
#
#   What this does NOT bound is the wait for a runner: `timeout-minutes` starts
#   when the job starts, and a self-hosted job that never finds a runner is
#   cancelled by GitHub after 24 hours regardless. So RUNNER3 is about the job
#   that STARTS and hangs — which is the one that holds a warm slot, and the one
#   whose silent dequeue looks like a pull request that simply stopped moving.
#
# WHY RUNNER4 HAS TWO ANSWERS AND NOT ONE
#   Fork code on a warm, credentialed, reused host is the attack the isolation
#   rules exist for. But a repository that forbids forking cannot be reached
#   that way at all, and a gate that fails such a repository on every pull
#   request teaches its readers to disable the gate. So the posture is DECLARED,
#   once, in the consuming workflow where it is reviewable — `--forks=blocked`
#   for a repository whose forking is off, `--forks=allowed` (the default) for
#   every other, where each self-hosted job must then carry a guard that
#   EXCLUDES or RE-ROUTES forks in its `if:` or in its `runs-on`.
#
#   Direction, not mention. `if: …head.repo.fork == true` names the fork and
#   selects fork-authored code exclusively onto the warm pool — the precise
#   attack RUNNER4 exists to stop — so a check that looked for the substring
#   passed the inversion of the thing it was checking. Only readable exclusions
#   count (`== false`, `!= true`, `!<fork>`, a same-repository `full_name` test)
#   and, in `runs-on`, only a route whose FORK-TRUE branch names a hosted image.
#   Anything else is unguarded: an unrecognised-but-correct guard costs one
#   reported job, where an unrecognised inversion costs the boundary.
#
# WHY REACHABILITY CROSSES A LOCAL `uses:` CALL
#   A `pull_request` workflow that calls `./.github/workflows/build.yml` runs
#   that callee's jobs in the caller's pull-request context — but the callee
#   declares only `workflow_call`, so judged alone it looks fork-unreachable and
#   its self-hosted jobs are never asked for a guard, while the caller has no
#   `runs-on` to judge. Read apart, both files are clean and fork code is on a
#   warm host. So reachability is computed over the whole file set first, and
#   transitively.
#
# WHY IT PARSES INSTEAD OF GREPPING
#   The same reason `check-merge-queue-single-step.sh` gives: the properties are
#   statements about the document GitHub loads, and a line reader gets each one
#   wrong in the direction that reports clean. `runs-on: self-hosted` is a
#   string where `runs-on: [self-hosted]` is a list and `runs-on: {group: …}` is
#   neither; `timeout-minutes` appears at both job and STEP level and only the
#   job one bounds the slot; a `uses:` job takes no timeout at all. Each of
#   those reads as satisfied to a grep. So the file goes through a real YAML
#   parser and every record below is addressed by path.
#
# WHAT IT DOES NOT ASSERT
#   A `runs-on` that is an expression (`${{ vars.CI_RUNNER_LABEL }}`) resolves
#   at run time against repository configuration this gate cannot see. It is
#   reported as UNDECIDED (RUNNER5) rather than passed: an expression is the one
#   spelling that can quietly name any pool in the fleet, and silence there
#   would be the vacuous pass this gate exists to prevent.
#
#   The other exception is `runs-on: ${{ fromJSON(matrix.<key>.<field>) }}`,
#   where the label lists are LITERALS in the same file — apigee-portal's
#   `unit-tests.yml` writes each leg's pool as `'["self-hosted", "linux", "gcp",
#   "Apigee-Portal"]'`. Nothing about that is undecidable, and abstaining on it
#   would be the gate declining to read a boundary written down in front of it.
#   Each leg is resolved and judged SEPARATELY, as `<job>~leg<n>`: a union would
#   let one scoped leg vouch for an unscoped one sharing the job. Resolution is
#   refused — back to RUNNER5 — the moment it stops being a literal lookup: an
#   `include:`/`exclude:` that can add or override legs, a value that is itself
#   an expression, or anything that is not parseable JSON.
#
#   The fleet's own fork-routing idiom —
#   `runs-on: ${{ …head.repo.fork && 'ubuntu-latest' || vars.CI_RUNNER_LABEL }}`
#   — used to silence RUNNER5 as well, on the reasoning that the expression IS
#   the routing decision RUNNER5 asks about. It is not. It decides where FORK
#   code goes and says nothing about which pool the other branch names, so fork
#   isolation was standing in for pool scoping: two properties, one answer, and
#   the answer belonged to the other question. The guard now settles RUNNER4
#   only. A consumer whose pool genuinely comes from a repository variable its
#   admins scope says so with `--allow-dynamic-runner` — in its own workflow,
#   in a diff, the same shape as `--forks=blocked`.
#
# EXIT CODES
#   0 — clean
#   1 — a property is broken
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail=0
# Every diagnostic carries its check id, and the self-test asserts the ID SET a
# fixture produces rather than a count — counts let one detector's regression
# hide behind another detector firing on the same fixture.
err() { local id="$1"; shift; echo "::error::[$id] $*"; fail=1; }

# Labels every pool in the fleet carries, so none of them scopes a job to one
# repository. Matched case-insensitively: GitHub treats runner labels that way,
# and `Linux` versus `linux` is a difference this gate must not read as a scope.
# `X64`/`ARM64` are added by the agent itself; `gcp`/`aws`/`azure` name the
# provider a pool runs on, which several pools share.
GENERIC='self-hosted|linux|windows|macos|x64|arm64|arm|gcp|aws|azure|on-prem'

# --- the parser is a hard dependency, not a nice-to-have ---------------------
# Conditional, it would be worse than useless: on a runner without PyYAML the
# gate would report PASS over files it never opened. It installs nothing — see
# the same note in `check-merge-queue-single-step.sh` for why a required check
# must not reach PyPI on every pull request in fourteen repositories.
export PY_BIN="${PY_BIN:-}"
py_usable() {
  command -v "$1" >/dev/null 2>&1 &&
    "$1" -c 'import sys, yaml; sys.exit(0 if sys.version_info >= (3, 7) else 1)' >/dev/null 2>&1
}

ensure_yaml() {
  local c
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

# Loads one workflow and emits TAB-separated records:
#
#   #ERR\t<message>                  the document does not load
#   #PR                              a `pull_request` trigger is present
#   #PRTARGET                        a `pull_request_target` trigger is present
#   #JOB\t<id>                       a job exists (or one resolved matrix leg,
#                                    as `<job>~leg<n>` — see the matrix note above)
#   #REUSABLE\t<id>                  the job is a `uses:` call (takes no timeout)
#   #TIMEOUT\t<id>\t<value>          the JOB's timeout-minutes, never a step's
#   #LABEL\t<id>\t<label>            one literal label of a list/string runs-on
#   #EXPR\t<id>                      runs-on carries a `${{ }}` expression
#   #GROUP\t<id>                     runs-on is a `{group: …}` mapping
#   #FORKGUARD\t<id>                 `head.repo.fork` decides this job
read_workflow() {
  "${PY_BIN:-python3}" - "$1" <<'PY'
import json
import re
import sys

import yaml

# LF only. On Windows `print` emits CRLF, and the trailing CR lands inside the
# last field — so a label reads as `IntegrateIT\r`, matches nothing, and the
# check that branches on it quietly takes the other path.
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(newline="\n")


def out(*fields):
    print("\t".join(str(f).replace("\t", " ").replace("\n", " ") for f in fields))


try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
except Exception as exc:  # noqa: BLE001 - any load failure is the same verdict
    out("#ERR", " ".join(str(exc).split())[:400])
    sys.exit(0)

if not isinstance(doc, dict):
    out("#ERR", "workflow is not a mapping")
    sys.exit(0)

# `on:` is the one key YAML 1.1 turns into a boolean, and PyYAML's safe loader
# does exactly that — so the trigger set lives under the key `True`, not "on",
# and a reader that asks for "on" finds nothing and reports a workflow with no
# triggers. Every fork check downstream would then be skipped, on every file.
triggers = doc.get("on", doc.get(True))
if isinstance(triggers, dict):
    names = list(triggers.keys())
elif isinstance(triggers, list):
    names = list(triggers)
elif triggers is not None:
    names = [triggers]
else:
    names = []
names = [str(n) for n in names]
if "pull_request" in names:
    out("#PR")
if "pull_request_target" in names:
    out("#PRTARGET")

# `runs-on: ${{ fromJSON(matrix.<key>[.<field>]) }}` and nothing else. The
# anchors matter: a expression that merely CONTAINS a `fromJSON(matrix…)` is
# doing something further with it, and this resolver would be guessing.
MATRIX_RUNS_ON = re.compile(
    r"^\s*\$\{\{\s*fromJSON\(\s*matrix\.([A-Za-z0-9_-]+)"
    r"((?:\.[A-Za-z0-9_-]+)?)\s*\)\s*\}\}\s*$"
)

# --- fork guards, by DIRECTION and not by mention -----------------------------
# The first version of this asked whether the text `head.repo.fork` appeared
# anywhere in the job's `if:` or `runs-on`. That is not a guard, it is a topic:
# `if: github.event.pull_request.head.repo.fork == true` mentions it and selects
# fork-authored code EXCLUSIVELY onto the warm pool — the precise attack RUNNER4
# exists to stop, passing the check meant to stop it.
#
# So only shapes that demonstrably EXCLUDE or RE-ROUTE forks count, and anything
# else is unguarded. That direction is deliberate: an unrecognised-but-correct
# guard costs one reported job and one reviewer's minute, where an unrecognised
# inversion costs the boundary.
FORK = r"(?:github\.event\.)?pull_request\.head\.repo\.fork|head\.repo\.fork"
SAME_REPO = (
    r"(?:head_repository|head\.repo)\.full_name\s*==\s*github\.repository"
    r"|github\.repository\s*==\s*(?:[\w.]*\.)?(?:head_repository|head\.repo)\.full_name"
)
IF_EXCLUDES = re.compile(
    # `fork == false`, `fork != true`, `!<...>fork`, or a same-repository test.
    r"(?:(?:%s)\s*==\s*false"
    r"|(?:%s)\s*!=\s*true"
    r"|![\w.\s]*(?:%s)"
    r"|%s)" % (FORK, FORK, FORK, SAME_REPO),
    re.IGNORECASE,
)
# `${{ <fork> && 'ubuntu-latest' || vars.CI_RUNNER_LABEL }}` — the fleet's
# routing idiom. What makes it a guard is that the FORK-TRUE branch names a
# GitHub-hosted image; written the other way round it hands forks the pool.
RUNS_ON_ROUTES = re.compile(
    r"(?:%s)\s*&&\s*'([^']*)'" % FORK, re.IGNORECASE
)
HOSTED_IMAGE = re.compile(r"^(?:ubuntu|windows|macos)-", re.IGNORECASE)


def split_top_level(expr, operator):
    """Split on `operator` at paren depth 0, outside single/double quotes."""
    parts, buf, depth, quote, i = [], [], 0, None, 0
    while i < len(expr):
        ch = expr[i]
        if quote:
            buf.append(ch)
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in "'\"":
            quote = ch
            buf.append(ch)
        elif ch == "(":
            depth += 1
            buf.append(ch)
        elif ch == ")":
            depth -= 1
            buf.append(ch)
        elif depth == 0 and expr[i:i + 2] == operator:
            parts.append("".join(buf))
            buf = []
            i += 2
            continue
        else:
            buf.append(ch)
        i += 1
    parts.append("".join(buf))
    return parts


def condition_excludes(expr):
    """True when `expr` cannot be true for a fork, read as a Boolean tree.

    A substring search is not enough. `always() || …fork == false` contains the
    exclusion and runs for forks anyway, because the OTHER disjunct does not
    care — so for `||` EVERY alternative has to exclude, while for `&&` ONE
    conjunct excluding is enough to make the whole condition false for a fork.
    Anything left after that is a leaf, and a leaf counts only if it matches a
    recognised exclusion shape outright.
    """
    expr = expr.strip()
    while expr.startswith("(") and expr.endswith(")"):
        # Only peel a wrapper that really is one; `(a) && (b)` must not be peeled.
        inner = expr[1:-1]
        depth = 0
        wraps = True
        for j, ch in enumerate(inner):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth < 0:
                    wraps = False
                    break
        if not wraps or depth != 0:
            break
        expr = inner.strip()

    ors = split_top_level(expr, "||")
    if len(ors) > 1:
        return all(condition_excludes(part) for part in ors)
    ands = split_top_level(expr, "&&")
    if len(ands) > 1:
        return any(condition_excludes(part) for part in ands)
    return bool(IF_EXCLUDES.search(expr))


def fork_guarded(job):
    """True only for a guard whose direction is readable and correct."""
    condition = job.get("if")
    if isinstance(condition, str) and condition_excludes(condition):
        return True
    runs_on = job.get("runs-on")
    if isinstance(runs_on, str):
        hit = RUNS_ON_ROUTES.search(runs_on)
        if hit and HOSTED_IMAGE.match(hit.group(1).strip()):
            return True
    return False


def resolve_matrix_legs(job):
    """Label lists for each leg of a matrix-selected `runs-on`, or None.

    None means "keep treating this as an expression" and is returned for every
    shape that is not a plain lookup of a JSON literal — the resolver must never
    be the reason a pool boundary goes unread, so anything it is not sure of
    goes back to RUNNER5 rather than being resolved optimistically.
    """
    runs_on = job.get("runs-on")
    if not isinstance(runs_on, str):
        return None
    hit = MATRIX_RUNS_ON.match(runs_on)
    if not hit:
        return None
    key, field = hit.group(1), hit.group(2).lstrip(".")

    matrix = (job.get("strategy") or {}).get("matrix")
    if not isinstance(matrix, dict):
        return None
    # `include` can add legs and override a leg's fields; `exclude` removes
    # them. Replicating GitHub's expansion order here would be a second
    # implementation of it, and a wrong one is a gate that reports on legs that
    # do not exist while missing the ones that do.
    if "include" in matrix or "exclude" in matrix:
        return None

    entries = matrix.get(key)
    if not isinstance(entries, list) or not entries:
        return None

    legs = []
    for entry in entries:
        if field:
            if not isinstance(entry, dict) or field not in entry:
                return None
            value = entry[field]
        else:
            value = entry
        if not isinstance(value, str) or "${{" in value:
            return None
        try:
            parsed = json.loads(value)
        except ValueError:
            return None
        if isinstance(parsed, str):
            parsed = [parsed]
        if not isinstance(parsed, list) or not all(isinstance(x, str) for x in parsed):
            return None
        legs.append(parsed)
    return legs


jobs = doc.get("jobs")
if not isinstance(jobs, dict):
    sys.exit(0)

for job_id, job in jobs.items():
    job_id = str(job_id)
    if not isinstance(job, dict):
        out("#JOB", job_id)
        continue

    # One record set per leg when a matrix decides the pool, so a scoped leg
    # cannot vouch for an unscoped one sharing the job. `~` keeps the synthetic
    # id free of regex metacharacters: these ids are interpolated into the
    # `sed`/`grep` patterns that read these records back.
    legs = resolve_matrix_legs(job)
    if legs is None:
        variants = [(job_id, job.get("runs-on"))]
    else:
        variants = [("%s~leg%d" % (job_id, i + 1), lab) for i, lab in enumerate(legs)]

    # The fork guard may sit in either place, and both are load-bearing: `if:`
    # skips the job, `runs-on` re-routes it. Read from the JOB, not the leg: a
    # matrix cannot decide whether the head repository is a fork, so every leg
    # inherits the one answer.
    guarded = fork_guarded(job)

    for vid, runs_on in variants:
        out("#JOB", vid)

        # A job that calls a reusable workflow accepts no `timeout-minutes` at
        # all: requiring one there would fail a correct workflow, and the bound
        # belongs to the called workflow's own jobs, which this gate reads
        # separately.
        if "uses" in job:
            out("#REUSABLE", vid)
            # …and "separately" was doing unearned work. A LOCAL callee's own
            # file declares only `workflow_call`, so it looked fork-unreachable
            # while the caller — which has the `pull_request` trigger — has no
            # `runs-on` to judge. Fork reachability therefore has to be carried
            # ACROSS the call, which is what this record lets the caller do.
            target = job["uses"] if isinstance(job.get("uses"), str) else ""
            if target.strip().startswith("./"):
                out("#CALLS", vid, target.strip().split("@")[0])
            elif target.strip():
                # Another repository's file, which this gate does not have. The
                # RUNNER3 exemption above still applies — a `uses:` job accepts
                # no timeout — but nothing here has read the jobs that exemption
                # hands the bound to.
                out("#REMOTECALL", vid, target.strip())

        if "timeout-minutes" in job:
            out("#TIMEOUT", vid, job.get("timeout-minutes"))

        if isinstance(runs_on, dict):
            # `{group: …}` names a runner GROUP, whose membership lives in
            # repository settings rather than in this file. Undecidable here,
            # and reported as such rather than passed.
            out("#GROUP", vid)
        else:
            labels = runs_on if isinstance(runs_on, list) else ([runs_on] if runs_on else [])
            for label in labels:
                text = str(label)
                if "${{" in text:
                    out("#EXPR", vid)
                else:
                    out("#LABEL", vid, text.strip())

        if guarded:
            out("#FORKGUARD", vid)
PY
}

# --- the checks --------------------------------------------------------------
# `grep -E` metacharacters in a value that is about to become a pattern. A YAML
# job id may legally contain `.`, `[`, `+` and more, and unescaped those match
# MORE records than intended — one job's timeout answering for another's, which
# is an error in the direction that reports clean.
re_quote() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|\\\/]/\\&/g'; }

# Files a `pull_request` workflow can reach through a local `uses:` call — see
# `compute_reachable`. Newline-separated absolute paths.
REACHABLE_PR=""
# A `timeout-minutes` at or above this bounds nothing GitHub was not already
# bounding. Overridable downwards by a consumer whose queue expires sooner.
MAX_TIMEOUT=360
# Declared acceptance of an undecidable pool — see RUNNER5.
ALLOW_DYNAMIC=0

# `scope` empty means RUNNER2 is not asserted; `forks` is the declared posture.
check_file() {
  local file="$1" scope="$2" forks="$3"
  local records status rel
  rel="${file#"$REPO_ROOT"/}"

  # The reader's exit status, not merely its output. Killed mid-write or dying
  # on an interpreter-level fault it emits no `#ERR` and no records, and an
  # empty record set is indistinguishable from a file with nothing wrong in it.
  # That is precisely the vacuous pass this gate is arranged against, so it is
  # caught rather than trusted.
  records="$(read_workflow "$file")"
  status=$?
  if [ "$status" -ne 0 ]; then
    err RUNNER0 "$rel: the YAML reader exited $status without a verdict — treating as unreadable rather than clean"
    return
  fi

  # `grep -c`, not `grep -q`, for the reason spelled out at the next use of it
  # below: `-q` exits at the first match, the writer takes SIGPIPE, and
  # `pipefail` turns a SUCCESSFUL match into a failed pipeline. Here that would
  # swallow the unreadable-file verdict itself.
  if [ "$(printf '%s\n' "$records" | grep -c '^#ERR	')" -gt 0 ]; then
    err RUNNER0 "$rel: $(printf '%s\n' "$records" | sed -n 's/^#ERR\t//p' | head -1)"
    return
  fi

  local has_pr=0
  # `grep -c` reads to EOF. `grep -q` would exit at the first match, the writer
  # upstream would take SIGPIPE, and `pipefail` would report a SUCCESSFUL match
  # as a failed pipeline — the artefact the catalog documents in §5.2a, which
  # here would invert the fork check on whichever files buffered slowly.
  if [ "$(printf '%s\n' "$records" | grep -c '^#PR$')" -gt 0 ] ||
     [ "$(printf '%s\n' "$records" | grep -c '^#PRTARGET$')" -gt 0 ]; then
    has_pr=1
  fi
  # …or reached from one. A callee declares only `workflow_call` and runs with
  # the caller's pull-request context, so judging it on its own triggers reads a
  # self-hosted job with no guard as unreachable by forks.
  if [ "$has_pr" -eq 0 ] && printf '%s\n' "$REACHABLE_PR" | grep -qxF -- "$file"; then
    has_pr=1
  fi

  local job job_re
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    job_re="$(re_quote "$job")"

    local labels self_hosted=0 scoped=0 hosted_only=1 label
    labels="$(printf '%s\n' "$records" | sed -n "s/^#LABEL\t${job_re}\t//p")"
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      if printf '%s' "$label" | grep -qiE "^self-hosted$"; then
        self_hosted=1
        hosted_only=0
      else
        # A label that is not a GitHub-hosted image is a label some runner in
        # the fleet was registered with.
        printf '%s' "$label" | grep -qiE "^(ubuntu|windows|macos)-" || hosted_only=0
        printf '%s' "$label" | grep -qiE "^(${GENERIC})$" || scoped=1
      fi
    done <<EOF
$labels
EOF

    # `self-hosted` is a label, not a requirement. GitHub routes a job to any
    # runner carrying a SUPERSET of what `runs-on` names, so `runs-on: Atlas`
    # and `runs-on: [linux, gcp]` both reach this fleet without the marker —
    # and gating every isolation check on the marker meant the cheapest way to
    # bypass RUNNER1/2/4 was to omit one redundant label. So the question is
    # inverted: a job is treated as fleet-reachable unless every label it names
    # is a GitHub-hosted image.
    if [ -n "$labels" ] && [ "$hosted_only" -eq 0 ]; then
      self_hosted=1
    fi

    local has_expr=0 has_group=0 has_guard=0 has_timeout=0 reusable=0 timeout=""
    [ "$(printf '%s\n' "$records" | grep -c "^#EXPR	${job_re}$")" -gt 0 ] && has_expr=1
    [ "$(printf '%s\n' "$records" | grep -c "^#GROUP	${job_re}$")" -gt 0 ] && has_group=1
    [ "$(printf '%s\n' "$records" | grep -c "^#FORKGUARD	${job_re}$")" -gt 0 ] && has_guard=1
    [ "$(printf '%s\n' "$records" | grep -c "^#REUSABLE	${job_re}$")" -gt 0 ] && reusable=1
    timeout="$(printf '%s\n' "$records" | sed -n "s/^#TIMEOUT\t${job_re}\t//p" | head -1)"
    [ -n "$timeout" ] && has_timeout=1

    # An expression or a group names no label this gate can read, so the label
    # loop above proves nothing either way — and "not proven self-hosted" was
    # being spent as "hosted", which is the passing direction. A dynamically
    # selected runner may be any pool in the fleet, so it is treated as one for
    # the fork question. RUNNER1/RUNNER2 stay quiet: those ask WHICH pool, and
    # that genuinely is not decidable here.
    if [ "$has_expr" -eq 1 ] || [ "$has_group" -eq 1 ]; then
      self_hosted=1
    fi

    # RUNNER3 — the bound on the slot. Asserted for every job that runs steps,
    # hosted or not: a hung GitHub-hosted job costs no pool slot but still holds
    # the pull request against the queue's `checks_timeout`.
    if [ "$reusable" -eq 0 ] && [ "$has_timeout" -eq 0 ]; then
      err RUNNER3 "$rel: job '$job' declares no timeout-minutes (inherits GitHub's 360-minute default)"
    fi

    # RUNNER6 — and the bound has to bind. `timeout-minutes: 360` satisfies
    # RUNNER3 while preserving in full the failure it exists to prevent: it IS
    # GitHub's default, so a job declaring it holds a warm slot for six hours
    # exactly as an undeclared one does. Key presence was the wrong question.
    #
    # A non-literal value is the same finding wearing a different spelling:
    # `timeout-minutes: ${{ vars.JOB_TIMEOUT }}` satisfies the key-presence test
    # and can resolve to 360, and this gate cannot read the variable. Reported
    # rather than passed, on the same rule RUNNER5 follows for `runs-on`.
    if [ "$has_timeout" -eq 1 ]; then
      if printf '%s' "$timeout" | grep -qE '^[0-9]+$'; then
        if [ "$timeout" -ge "$MAX_TIMEOUT" ]; then
          err RUNNER6 "$rel: job '$job' declares timeout-minutes: $timeout, which is not below the $MAX_TIMEOUT-minute ceiling — it bounds nothing GitHub was not already bounding"
        fi
      else
        err RUNNER6 "$rel: job '$job' declares timeout-minutes: $timeout, which this gate cannot resolve to a number — an expression that lands on $MAX_TIMEOUT or more bounds nothing, and nothing here can rule that out"
      fi
    fi

    if [ "$self_hosted" -eq 1 ]; then
      # RUNNER1 — the boundary. A pool is scoped by a label no other pool
      # carries; without one this job is offered to the whole fleet.
      if [ "$scoped" -eq 0 ] && [ "$has_expr" -eq 0 ] && [ "$has_group" -eq 0 ]; then
        err RUNNER1 "$rel: job '$job' runs-on [$(printf '%s' "$labels" | tr '\n' ' ')] — self-hosted with no repository-scoped label, so ANY pool in the fleet may run it"
      fi

      # RUNNER2 — the stronger form, for a consumer that names its own pool.
      if [ -n "$scope" ] && [ "$has_expr" -eq 0 ] && [ "$has_group" -eq 0 ]; then
        if [ "$(printf '%s\n' "$labels" | grep -cix -- "$scope")" -eq 0 ]; then
          err RUNNER2 "$rel: job '$job' is self-hosted but does not carry the declared scope label '$scope'"
        fi
      fi

      # RUNNER4 — fork code never reaches a warm host.
      if [ "$has_pr" -eq 1 ] && [ "$forks" = "allowed" ] && [ "$has_guard" -eq 0 ]; then
        err RUNNER4 "$rel: job '$job' is self-hosted on a pull_request workflow with no fork guard (nothing keeps fork-authored code off a credentialed warm host)"
      fi
    fi

    # RUNNER5 — undecidable, and said out loud. An expression or a runner group
    # resolves against configuration this gate cannot read, and an expression is
    # the one spelling that can name any pool in the fleet.
    #
    # A fork guard used to silence this, on the reasoning that the fleet's
    # routing idiom IS the decision RUNNER5 asks about. It is not: it decides
    # where FORK code goes, and says nothing about which pool the other branch
    # names. Fork isolation was standing in for pool scoping — two properties,
    # one answer, and the answer belonged to the other question. So the guard
    # now silences RUNNER4 only, and a consumer whose pool genuinely comes from
    # a repository variable declares that with `--allow-dynamic-runner`, in its
    # workflow, where it is reviewable — the same shape as `--forks=blocked`.
    if [ "$has_expr" -eq 1 ] || [ "$has_group" -eq 1 ]; then
      if [ "$ALLOW_DYNAMIC" -eq 0 ]; then
        err RUNNER5 "$rel: job '$job' selects its runner dynamically — this gate cannot decide which pool it claims (declare --allow-dynamic-runner if the label is a repository variable your admins scope)"
      fi
    fi

    # RUNNER7 — the exemption above, made honest. A `uses:` job takes no
    # timeout because the bound belongs to the called workflow's jobs; for a
    # LOCAL callee this gate reads those jobs, and now carries fork
    # reachability into them. For a REMOTE one it holds neither file nor
    # jobs, so the exemption was handing the property to a document nobody
    # checked. Undecided and said so, like RUNNER5.
    local remote
    remote="$(printf '%s\n' "$records" | sed -n "s/^#REMOTECALL\t${job_re}\t//p" | head -1)"
    if [ -n "$remote" ]; then
      err RUNNER7 "$rel: job '$job' calls the remote reusable workflow '$remote' — its jobs' runner scope and timeouts are not in this repository, so this gate cannot decide them"
    fi
  done <<EOF
$(printf '%s\n' "$records" | sed -n 's/^#JOB\t//p')
EOF
}

# --- fork reachability across local reusable workflows -----------------------
# A `pull_request` workflow that calls `./.github/workflows/build.yml` runs that
# callee's jobs in the caller's pull-request context, with the caller's ref
# checked out — but the callee's own file declares `workflow_call` and nothing
# else, so read alone it looks unreachable by forks and its self-hosted jobs are
# never asked for a guard. Reachability is therefore computed over the whole
# file set first, transitively, and only then are the files judged.
#
# It follows LOCAL calls only. A remote `uses:` is another repository's file,
# which this gate does not have; that limitation is named in RUNNER7 rather than
# assumed away.
compute_reachable() {
  local f records seed="" edges="" caller target changed=1 line
  for f in "$@"; do
    records="$(read_workflow "$f")" || continue
    if [ "$(printf '%s\n' "$records" | grep -c '^#PR$')" -gt 0 ] ||
       [ "$(printf '%s\n' "$records" | grep -c '^#PRTARGET$')" -gt 0 ]; then
      seed="$seed$f"$'\n'
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      target="$(cd "$(dirname "$f")/../.." 2>/dev/null && pwd)/${line#./}"
      edges="$edges$f	$target"$'\n'
    done <<EOF
$(printf '%s\n' "$records" | sed -n 's/^#CALLS\t[^\t]*\t//p')
EOF
  done

  REACHABLE_PR="$seed"
  # Fixpoint rather than one hop: a caller may reach a callee that itself calls
  # another, and the pool at the end of that chain is as reachable as the first.
  while [ "$changed" -eq 1 ]; do
    changed=0
    while IFS=$'\t' read -r caller target; do
      [ -n "${target:-}" ] || continue
      printf '%s\n' "$REACHABLE_PR" | grep -qxF -- "$caller" || continue
      printf '%s\n' "$REACHABLE_PR" | grep -qxF -- "$target" && continue
      REACHABLE_PR="$REACHABLE_PR$target"$'\n'
      changed=1
    done <<EOF
$edges
EOF
  done
}

# --- self-test ---------------------------------------------------------------
# The fixtures run BEFORE the real check in CI, for the reason the drift gate
# gives: a config gate's characteristic failure is a vacuous pass — it reads a
# file it never matches and reports clean — so the detectors are proved to fire
# before any repository's own workflows are believed.
# SC2030/SC2016 are deliberate below and scoped to this function. The fixture
# runner evaluates `check_file` inside `$( )` with `fail=0` so a planted failure
# scores the fixture without poisoning the real run's exit status — the subshell
# IS the isolation. And a fixture asserting the fleet's `${{ }}` routing idiom
# must carry that text literally, so its single quotes are the point.
# shellcheck disable=SC2030,SC2016
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"

  # Asserts the SET of check ids a fixture produces. A count would let one
  # detector's regression hide behind another firing on the same file.
  expect() {
    local name="$1" want="$2" scope="$3" forks="$4" body="$5" dynamic="${6:-0}"
    local got out_text
    printf '%s\n' "$body" > "$tmp/wf.yml"
    out_text="$(fail=0; ALLOW_DYNAMIC=$dynamic; check_file "$tmp/wf.yml" "$scope" "$forks" 2>&1)"
    got="$(printf '%s\n' "$out_text" | sed -n 's/.*::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort -u | tr '\n' ' ')"
    got="$(printf '%s' "$got" | sed 's/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "FAIL $name: want ids [$want], got [$got]"
      # A gate that says only "not found" cannot be told apart from a gate that
      # is broken, so the input it judged is printed with the verdict.
      printf '%s\n' "$out_text" | sed 's/^/      /'
      status=1
    else
      echo "ok   $name [$want]"
    fi
  }

  expect "clean self-hosted job" "" "" allowed \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "unscoped self-hosted — the IntegrateIT runner-version-check shape" "RUNNER1 RUNNER3" "" allowed \
'on:
  schedule:
    - cron: "0 6 * * 1"
jobs:
  check:
    runs-on: [self-hosted, Linux, gcp]
    steps: [{run: "true"}]'

  expect "case-insensitive platform labels are not scopes" "RUNNER1" "" allowed \
'on: [push]
jobs:
  build:
    runs-on: [SELF-HOSTED, Windows, GCP, X64]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  expect "missing timeout only" "RUNNER3" "" allowed \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps: [{run: "true"}]'

  # The step-level key is the trap: it satisfies a grep for `timeout-minutes`
  # and bounds nothing that holds the slot.
  expect "a step timeout is not a job timeout" "RUNNER3" "" allowed \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: "true"
        timeout-minutes: 5'

  expect "a reusable-workflow job takes no timeout" "" "" allowed \
'on: [push]
jobs:
  call:
    uses: ./.github/workflows/other.yml'

  expect "fork PR reaches the pool" "RUNNER4" "" allowed \
'on:
  pull_request:
    branches: [main]
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "fork guard in if:" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: github.event.pull_request.head.repo.fork == false
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # The fleet's fork-routing idiom. The guard is real — forks go to a hosted
  # image — so RUNNER4 is answered. RUNNER5 is NOT: which pool the other branch
  # names is still a repository variable, and letting the guard answer both was
  # fork isolation vouching for pool scoping.
  expect "fork routing answers RUNNER4 and not RUNNER5" "RUNNER5" "" allowed \
'on:
  pull_request:
jobs:
  build:
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || vars.CI_RUNNER_LABEL }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "…and the consumer may declare that pool undecidable-but-accepted" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || vars.CI_RUNNER_LABEL }}
    timeout-minutes: 30
    steps: [{run: "true"}]' 1

  # Written the other way round, the SAME idiom hands forks the pool. The first
  # version of this gate read both as guarded, because it looked for the topic
  # rather than the direction.
  expect "inverted routing sends forks TO the pool" "RUNNER4 RUNNER5" "" allowed \
'on:
  pull_request:
jobs:
  build:
    runs-on: ${{ github.event.pull_request.head.repo.fork && vars.CI_RUNNER_LABEL || '"'"'ubuntu-latest'"'"' }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "an inverted if: guard is not a guard" "RUNNER4" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: github.event.pull_request.head.repo.fork == true
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "mentioning the fork is not excluding it" "RUNNER4" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: github.event.pull_request.head.repo.fork
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "negation is a guard" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: "!github.event.pull_request.head.repo.fork"
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A substring search finds the exclusion inside `always() || …fork == false`
  # and calls it a guard, while the OTHER disjunct runs the job for forks
  # regardless. `||` needs EVERY alternative to exclude.
  expect "an exclusion beside an unconditional alternative is not a guard" "RUNNER4" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: always() || github.event.pull_request.head.repo.fork == false
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # `&&` is the other direction: one conjunct excluding is enough, because the
  # whole condition is then false for a fork whatever the rest says.
  expect "an exclusion anded with anything is still a guard" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: github.event.pull_request.draft == false && github.event.pull_request.head.repo.fork == false
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "every alternative excluding is a guard" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: (github.event_name == "push" && github.event.pull_request.head.repo.fork == false) || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "a same-repository test is a guard" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "forks blocked by repository setting" "" "" blocked \
'on:
  pull_request:
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "pull_request_target counts as fork-reachable" "RUNNER4" "" allowed \
'on:
  pull_request_target:
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "declared scope not carried" "RUNNER2" "OtherRepo" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "declared scope carried" "" "ExampleRepo" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "runner group is undecidable, not clean" "RUNNER5" "" blocked \
'on: [push]
jobs:
  build:
    runs-on:
      group: warm
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "a string runs-on is a runs-on" "RUNNER1 RUNNER3" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: self-hosted
    steps: [{run: "true"}]'

  # The apigee-portal `unit-tests.yml` shape: the pool is chosen through the
  # matrix, but every label list is a literal in the same file.
  expect "matrix-selected runs-on resolves to its literal legs" "" "Apigee-Portal" blocked \
'on: [push]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: api, runs_on: '"'"'["self-hosted", "linux", "gcp", "Apigee-Portal"]'"'"'}
          - {name: web, runs_on: '"'"'["ubuntu-latest"]'"'"'}
    steps: [{run: "true"}]'

  # The reason the legs are judged separately rather than unioned: unioned, the
  # scoped leg below would supply the scope label the unscoped one is missing,
  # and this file would report clean on a leg the whole fleet can claim.
  expect "one unscoped leg is not covered by a scoped one" "RUNNER1" "" blocked \
'on: [push]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: api, runs_on: '"'"'["self-hosted", "linux", "gcp", "Apigee-Portal"]'"'"'}
          - {name: web, runs_on: '"'"'["self-hosted", "linux", "gcp"]'"'"'}
    steps: [{run: "true"}]'

  expect "a matrix leg answers --scope like any other job" "RUNNER2" "OtherRepo" blocked \
'on: [push]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: api, runs_on: '"'"'["self-hosted", "linux", "gcp", "Apigee-Portal"]'"'"'}
    steps: [{run: "true"}]'

  # `include:` can add legs and override fields. Resolving anyway would mean
  # reimplementing GitHub's expansion, so this goes back to undecided.
  expect "include: refuses resolution rather than guessing" "RUNNER5" "" blocked \
'on: [push]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: api, runs_on: '"'"'["self-hosted", "linux", "gcp", "Apigee-Portal"]'"'"'}
        include:
          - {name: extra, runs_on: '"'"'["self-hosted", "linux", "gcp"]'"'"'}
    steps: [{run: "true"}]'

  # The matrix value is itself an expression, so the label list is still decided
  # by configuration this gate cannot read.
  expect "a matrix value that is an expression stays undecided" "RUNNER5" "" blocked \
'on: [push]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: api, runs_on: "${{ vars.CI_RUNNER_JSON }}"}
    steps: [{run: "true"}]'

  # `self-hosted` is a label, not a requirement: GitHub routes to any runner
  # whose labels are a SUPERSET of what `runs-on` names. Dropping the marker was
  # therefore the cheapest way past every check gated on it.
  expect "a repository label alone still reaches the pool" "RUNNER4" "" allowed \
'on:
  pull_request:
jobs:
  build:
    runs-on: ExampleRepo
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "platform labels alone reach the whole fleet" "RUNNER1" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: [linux, gcp]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "a hosted image is not the fleet" "" "" allowed \
'on:
  pull_request:
jobs:
  build:
    runs-on: [ubuntu-24.04]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # RUNNER3 satisfied, RUNNER3 defeated: 360 IS the default it exists to
  # replace, so the six-hour warm slot survives the check unchanged.
  expect "a timeout equal to the default bounds nothing" "RUNNER6" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 360
    steps: [{run: "true"}]'

  # And an unresolvable one is the same finding in a different spelling — the
  # key is present, the value could be 360, and nothing here can rule it out.
  expect "a timeout this gate cannot resolve is not a bound" "RUNNER6" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: ${{ vars.JOB_TIMEOUT }}
    steps: [{run: "true"}]'

  # The RUNNER3 exemption for a `uses:` job hands the bound to the called
  # workflow. For a remote callee that document is not in this repository.
  expect "a remote reusable workflow is undecidable" "RUNNER7" "" blocked \
'on: [push]
jobs:
  call:
    uses: owner/repo/.github/workflows/ci.yml@11bd71901bbe5b1630ceea73d27597364c9af683'

  expect "unparseable document" "RUNNER0" "" allowed \
'jobs: [ this is not a workflow'

  # The `on:`/`True` trap, asserted directly: a reader that asks PyYAML for the
  # key "on" gets nothing, concludes the workflow has no triggers, and skips
  # RUNNER4 on every file in the fleet.
  expect "block-mapping on: still registers the pull_request trigger" "RUNNER4" "" allowed \
'name: x
on:
  pull_request:
    types: [opened]
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # --- the two-file fixture --------------------------------------------------
  # Fork reachability is a property of a PAIR of files, so it cannot be asserted
  # with `expect`, which judges one. The caller has the `pull_request` trigger
  # and no runner; the callee has the runner and only a `workflow_call` trigger.
  # Read apart they are each clean, and fork-authored code reaches a warm host.
  expect_pair() {
    local name="$1" want="$2" caller_body="$3" callee_body="$4"
    local got out_text dir="$tmp/pair"
    rm -rf "$dir"; mkdir -p "$dir/.github/workflows"
    printf '%s\n' "$caller_body" > "$dir/.github/workflows/caller.yml"
    printf '%s\n' "$callee_body" > "$dir/.github/workflows/callee.yml"
    out_text="$(fail=0
      compute_reachable "$dir/.github/workflows/caller.yml" "$dir/.github/workflows/callee.yml"
      check_file "$dir/.github/workflows/caller.yml" "" allowed
      check_file "$dir/.github/workflows/callee.yml" "" allowed 2>&1)"
    got="$(printf '%s\n' "$out_text" | sed -n 's/.*::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort -u | tr '\n' ' ')"
    got="$(printf '%s' "$got" | sed 's/ *$//')"
    if [ "$got" != "$want" ]; then
      echo "FAIL $name: want ids [$want], got [$got]"
      printf '%s\n' "$out_text" | sed 's/^/      /'
      status=1
    else
      echo "ok   $name [$want]"
    fi
  }

  expect_pair "fork reachability crosses a local reusable-workflow call" "RUNNER4" \
'on:
  pull_request:
jobs:
  call:
    uses: ./.github/workflows/callee.yml' \
'on:
  workflow_call:
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect_pair "…and the callee's own guard answers it" "" \
'on:
  pull_request:
jobs:
  call:
    uses: ./.github/workflows/callee.yml' \
'on:
  workflow_call:
jobs:
  build:
    if: github.event.pull_request.head.repo.fork == false
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # …and a callee nobody reaches from a pull request is not asked for a guard.
  expect_pair "an unreached callee is not fork-reachable" "" \
'on:
  push:
jobs:
  call:
    uses: ./.github/workflows/callee.yml' \
'on:
  workflow_call:
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  rm -rf "$tmp"
  return "$status"
}

# --- entry point -------------------------------------------------------------
# SC2031: `fail` is read here after `selftest`'s subshells wrote their own copies
# of it, which is exactly the intent — a fixture's planted failure must not reach
# this exit status. On the real path `check_file` runs in THIS shell, so the
# value read here is the one its `err()` calls set.
# shellcheck disable=SC2031
main() {
  local scope="" forks="allowed" run_selftest=0
  local -a files=()
  local arg

  for arg in "$@"; do
    case "$arg" in
      --selftest) run_selftest=1 ;;
      --scope=*)  scope="${arg#--scope=}" ;;
      --forks=*)  forks="${arg#--forks=}" ;;
      --max-timeout=*) MAX_TIMEOUT="${arg#--max-timeout=}" ;;
      --allow-dynamic-runner) ALLOW_DYNAMIC=1 ;;
      -*)         echo "::error::[RUNNER0] unknown option: $arg"; return 1 ;;
      *)          files+=("$arg") ;;
    esac
  done

  case "$forks" in
    allowed|blocked) ;;
    *) echo "::error::[RUNNER0] --forks must be 'allowed' or 'blocked', got '$forks'"; return 1 ;;
  esac

  if ! printf '%s' "$MAX_TIMEOUT" | grep -qE '^[1-9][0-9]*$'; then
    echo "::error::[RUNNER0] --max-timeout must be a positive integer, got '$MAX_TIMEOUT'"
    return 1
  fi

  if ! ensure_yaml; then
    # Reported and failed, never skipped: a gate that cannot read is not a gate
    # that passes. PyYAML is on `ubuntu-latest` and baked into the golden image,
    # so its absence is a runner-image bug with one owner.
    echo "::error::[RUNNER0] no Python with PyYAML available; this gate cannot read a workflow"
    return 1
  fi

  if [ "$run_selftest" -eq 1 ]; then
    selftest
    return
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r arg; do
      [ -n "$arg" ] || continue
      files+=("$arg")
    done <<EOF
$(find "$REPO_ROOT/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
EOF
  fi

  if [ "${#files[@]}" -eq 0 ]; then
    # The vacuous pass, named. A gate that reports success over a tree it never
    # opened is worse than no gate, because it is believed.
    echo "::error::[RUNNER0] no workflow files found under .github/workflows — nothing was checked"
    return 1
  fi

  # Reachability across the whole set first — a callee's verdict depends on a
  # caller this loop may not have reached yet.
  compute_reachable "${files[@]}"

  local f
  for f in "${files[@]}"; do
    check_file "$f" "$scope" "$forks"
  done

  if [ "$fail" -eq 0 ]; then
    echo "runner policy clean: ${#files[@]} workflow file(s)"
  fi
  return "$fail"
}

main "$@"
