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
#                                          [--shared-infra]
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
#     RUNNER7  a REMOTE reusable workflow's jobs are not in this repository —
#              UNDECIDED, and declarable with a `remote-reusable-allowed` marker
#              naming the callee (see `remote_call_declared`).
#     RUNNER8  a job on a WINDOWS pool label declares `container:` or
#              `services:`, neither of which that pool can run.
#     RUNNER12 a route onto the merge-queue pool is decided by facts the
#              requester cannot forge, not by the branch name alone.
#     RUNNER13 and the two pools it routes between carry disjoint scope labels,
#              so neither can be scheduled onto the other's hosts.
#     RUNNER14 and, in a repository that HAS such a route, no pull-request job
#              names its pool literally and so sits out the route entirely.
#
#   And, behind `--shared-infra`, the three that make a pull request use ONE
#   host and ONE copy of its infrastructure (docs/adr-pr-host-affinity.md):
#
#     RUNNER9  a fleet-reachable LINUX job in a pull-request workflow resolves
#              its `runs-on` from the anchor job's output, or IS the anchor, or
#              carries a declared exemption.
#     RUNNER10 at most ONE job across the repository's pull-request workflows
#              owns the shared infrastructure — counting a `uses:` job that
#              declares itself an owner, which is what calling the fleet's
#              published anchor looks like from the caller's side.
#     RUNNER11 a WINDOWS fleet job does not name `localhost` on a
#              shared-infrastructure port — there is nothing listening there.
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
# WHY RUNNER8 IS A GATE AND NOT A LESSON
#   A Windows pool on this fleet has no container runtime at all — no daemon, no
#   per-slot runtime, no registry credential helper. That is not an omission to
#   be filled in later: the pool exists for a WiX/`signtool` packaging build,
#   which needs the host's Win32 surface, and putting that build in a Windows
#   container is what would break the one job the pool is for. Job isolation on
#   a Windows pool is ONE LOCAL WINDOWS ACCOUNT PER SLOT, not a container
#   (`docs/adr-windows-pool.md` §4).
#
#   So `container:` and `services:` cannot run there, and the way they fail is
#   the reason this is a gate. A `services:` block fails at "Initialize
#   containers" before a single step runs, with an error about docker on a host
#   that has no docker — which every reader takes for a broken host and reports
#   as a fleet fault. The same workflow reads as perfectly ordinary, because on
#   GitHub-hosted `windows-latest` and on the Linux pool it is.
#
#   The rule is scoped to the label and not to the key: `container:` on a Linux
#   pool is how that pool is MEANT to be used, so a blanket ban would be a gate
#   the fleet's own consumers must disable. A `windows-2022` hosted image is not
#   this fleet either, and it does run containers. Only a fleet-reachable job
#   naming the `windows` platform label is refused.
#
# WHY RUNNER14 IS THE HALF RUNNER12/13 DO NOT COVER
#   Those two judge the route a job WRITES. Neither of them can see the job that
#   writes no route at all, and that is the job the whole two-pool split is
#   defeated by: a repository stands up a merge-queue pool, moves its main
#   pull-request workflow onto the route, and leaves one small required workflow
#   naming the pull-request pool the way it always did. Nothing is red. The
#   route works. The one workflow that stayed behind is then, on every
#   speculative `mergify/merge-queue/<sha>` draft, queueing against the pool
#   that is full of the pull requests waiting for that very queue to drain —
#   while the merge-queue pool it was supposed to use sits with free slots.
#
#   Measured on IntegrateIT, 2026-08-23: `generic-binary-check.yml` kept
#   `runs-on: [self-hosted, linux, gcp, IntegrateIT]` after `pr-check.yml`
#   adopted the lane route, and on pull request #11307 its 65-SECOND job waited
#   31m06s for a runner. Mergify reports that as "waiting for generic-binary",
#   which reads as a check that is still running rather than a check that cannot
#   start, so the pull request looks busy for as long as it takes.
#
#   The rule is therefore cross-file and self-configuring, in the shape RUNNER10
#   already established: if ANY job in the file set routes on the merge-queue
#   branch prefix, the repository HAS two pools, and from that point a
#   fleet-reachable job in a pull-request workflow that names its pool literally
#   is a job that will run on the wrong one. No flag turns this on — a
#   repository with no route never mentions the prefix and is never asked.
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
#   in a diff, the same shape as `--forks=blocked` — or, for one job rather than
#   all of them, with `# dynamic-runner-allowed(<job>, #<issue>): <who scopes
#   the value>` beside it.
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

# The one platform label that names a WINDOWS pool, for RUNNER8. It is a subset
# of GENERIC on purpose and must stay one: GENERIC answers "does this label
# scope the job to a repository", which every OS label fails, while this answers
# "which OS is on the other end". Widen it to a second OS and RUNNER8 starts
# refusing `container:` on the Linux pool, which is how that pool is meant to be
# used — so the self-test carries a Linux-pool-with-a-container fixture whose
# only job is to fail if this line ever grows.
WINDOWS_LABEL='windows'

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
#   #CONTAINER\t<id>                 the job declares `container:`
#   #SERVICES\t<id>                  the job declares `services:`
#   #QUEUEREF\t<id>\t<origin>        an expression routes on the merge-queue
#                                    branch prefix; `origin` is `runs-on` or
#                                    `output:<name>`
#   #QUEUESAMEREPO\t<id>\t<origin>   ...and also requires the head branch to
#                                    live in this repository
#   #QUEUEAUTHOR\t<id>\t<origin>     ...and also requires the author to be
#                                    Mergify
#   #QUEUESKIP\t<id>                 the job's `if:` cannot be true on a
#                                    merge-queue draft, so it takes no route
#   #ROUTEARM\t<id>\t<origin>\t<hosted|pool>\t<labels>  one comma-joined JSON
#                                    label set that expression can resolve to
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

# `needs.<job>.outputs.<name>` anywhere inside a `runs-on` expression. The job
# id is what matters: it names the anchor, which is how RUNNER9 tells the one
# job that MAY name a pool literally from the ones that may not.
NEEDS_OUTPUT = re.compile(r"needs\.([A-Za-z0-9_-]+)\.outputs\.")

# The literals in a `runs-on` expression that can actually BECOME the runner:
# the operands of a short-circuit. GitHub Actions quotes strings with single
# quotes only, but not every quoted string is a candidate label — in
# `contains(github.ref, 'main') && 'PoolA' || …` the first literal is an
# argument to a condition and can never be the answer. Reporting it would fail
# the guard a careful author wrote, which is the worst kind of false positive.
LITERAL_ALT = re.compile(r"(?:&&|\|\|)\s*'([^']*)'")

# The same question for a literal that OPENS the expression, which no operator
# precedes: `${{ 'PoolA' || needs.anchor.outputs.runs-on }}` is that pool on
# every run, because a non-empty string short-circuits before the reference is
# ever read. Deliberately not the mirror rule "a literal FOLLOWED by an
# operator" — that one also matches the `'main'` in `x == 'main' && …`.
LITERAL_FIRST = re.compile(r"\$\{\{\s*'([^']*)'")

# A loopback address with a port in the shared-infrastructure band, anywhere in
# a job's steps. On a Windows host there is nothing listening there: the stack
# runs on the LINUX host of the same pull request, and is reached at that host's
# address (docs/ci-pr-shared-infra.md §4). Written as `localhost` it fails as a
# refused connection at whatever point the test first queries — late, and
# nowhere near the line that is wrong.
#
# The band is 35100-44099 and it starts at 35100, not at 35000: slot indices
# begin at ONE, so the first slot's hundred ports sit one width above the base.
# 90 slots of 100 ports is the widest `shared_infra_slots_per_host` the network
# module accepts. Ports outside the band are somebody else's business and are
# not reported — 35000-35099 belongs to nobody, and reporting it would send a
# reader looking for a slot that does not exist.
#
# `(?![0-9])` because without it `localhost:351000` matches on its first five
# digits: a five-digit prefix of a six-digit port, reported as a band port the
# job never named.
LOOPBACK_BAND = re.compile(
    r"(?:localhost|127\.0\.0\.1)[:/]"
    r"(35[1-9][0-9]{2}|3[6-9][0-9]{3}|4[0-3][0-9]{3}|440[0-9]{2})(?![0-9])",
    re.IGNORECASE,
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
# GitHub's hosted images are a finite, well-known family, and this must match
# THAT family rather than its prefix: `ubuntu-pool-1` is an ordinary custom
# label on a self-hosted runner, and reading it as a hosted image would let a
# fork guard route fork code onto the fleet while this gate called it safe.
# Anything outside the family is treated as a self-hosted label — the direction
# that over-reports rather than the one that opens the boundary.
#
# "Finite family" has to mean the versions GitHub actually ships, not any
# number: `\d+(?:\.\d+)?` accepted `ubuntu-1`, `ubuntu-2204`, `windows-11` and
# `macos-14.0`, none of which is a hosted image and every one of which is an
# ordinary self-hosted naming convention.
#
# A per-OS version SHAPE was the first tightening and it was not enough. A shape
# still says "any number of the right form", so `ubuntu-99.04`, `windows-2099`
# and `macos-99` were hosted images to this gate — and a fleet that wanted a
# private label of exactly that form would silently get every isolation check
# skipped on the job carrying it. So the versions are ENUMERATED. There are
# eleven of them; there is no shape to guess at.
#
# The list goes stale in the SAFE direction, on purpose: an image GitHub adds
# later reads as self-hosted until this line is updated, which costs one
# reported job and a one-line pull request. The other direction costs the
# boundary. Last checked against GitHub's runner-images inventory 2026-08-23.
HOSTED_IMAGE = re.compile(
    r"^(?:"
    r"ubuntu-(?:latest|24\.04|22\.04)"
    r"|windows-(?:latest|2025|2022|11-arm)"
    r"|macos-(?:latest|15|14|13)"
    r")(?:-(?:arm|arm64|large|xlarge))?$",
    re.IGNORECASE,
)


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


def condition_excludes(expr, leaf=None):
    """True when `expr` cannot be true for a fork, read as a Boolean tree.

    A substring search is not enough. `always() || …fork == false` contains the
    exclusion and runs for forks anyway, because the OTHER disjunct does not
    care — so for `||` EVERY alternative has to exclude, while for `&&` ONE
    conjunct excluding is enough to make the whole condition false for a fork.
    Anything left after that is a leaf, and a leaf counts only if it matches a
    recognised exclusion shape outright.

    `leaf` is the leaf test, defaulting to the fork one. The TREE is the part
    that is hard to get right and it is identical for any "this condition
    cannot be true for X" question, so RUNNER14 asks its own question — does
    this job sit out the merge-queue drafts — through this same walk rather
    than through a second copy of it that drifts.
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
        return all(condition_excludes(part, leaf) for part in ors)
    ands = split_top_level(expr, "&&")
    if len(ands) > 1:
        return any(condition_excludes(part, leaf) for part in ands)
    return bool((leaf or IF_EXCLUDES.search)(expr))


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


# --- the merge-queue route (RUNNER12/RUNNER13) --------------------------------
# A repository served by BOTH a pull-request pool and a merge-queue pool routes
# between them in one expression, and that expression is where both of this
# fleet's queue-routing failures get written.
#
# `github.head_ref` is chosen by whoever opened the pull request. A branch named
# `mergify/merge-queue/anything` therefore hands ordinary -- or forked -- work
# the pool that exists to be RESERVED for the queue, and does it by spelling a
# string. Two facts nobody outside the repository can forge have to be required
# with it: the head branch lives in this repository, and the pull request was
# opened by Mergify. A human cannot author a pull request as `mergify[bot]`.
QUEUE_BRANCH = re.compile(r"mergify/merge-queue/")
QUEUE_SAME_REPO = re.compile(r"head\.repo\.full_name\s*==\s*github\.repository")
QUEUE_AUTHOR = re.compile(r"""user\.login\s*==\s*(['"])mergify\[bot\]\1""")

# RUNNER14's one legitimate way out without a marker: a job that does not RUN
# on a merge-queue draft has no route to take, and asking it to resolve a pool
# it will never claim would be a finding nobody can act on. Deliberately narrow
# -- the two readable spellings of "not a queue draft" and nothing inferred --
# because the two error directions are not symmetric here either: an
# unrecognised-but-correct skip costs one declared exemption, where an
# over-eager reading silently excuses the job the whole rule is about.
QUEUE_SKIP = re.compile(
    r"!\s*startsWith\(\s*github\.head_ref\s*,\s*(['\"])mergify/merge-queue/\1\s*\)"
    r"|startsWith\(\s*github\.head_ref\s*,\s*(['\"])mergify/merge-queue/\2\s*\)"
    r"\s*==\s*false"
)


def queue_skipped(job):
    """True when this job cannot run on a `mergify/merge-queue/<sha>` draft."""
    condition = job.get("if")
    return isinstance(condition, str) and condition_excludes(
        condition, QUEUE_SKIP.search
    )


# A single-quoted JSON array inside an expression -- the label set one arm of
# the route resolves to. `runs-on` needs a list and an expression yields a
# string, so each arm is JSON and `fromJSON` unwraps whichever one won.
EXPR_JSON_ARRAY = re.compile(r"'(\[[^']*\])'")


def emit_expr_facts(vid, origin, text):
    """Facts about ONE expression: whether it routes on the queue branch, on
    what else, and which label sets its arms are. Facts only -- whether a
    missing conjunct is a finding is decided once, in the shell, like every
    other rule in this file."""
    if "${{" not in text or not QUEUE_BRANCH.search(text):
        return
    out("#QUEUEREF", vid, origin)
    if QUEUE_SAME_REPO.search(text):
        out("#QUEUESAMEREPO", vid, origin)
    if QUEUE_AUTHOR.search(text):
        out("#QUEUEAUTHOR", vid, origin)
    for m in EXPR_JSON_ARRAY.finditer(text):
        try:
            arm = json.loads(m.group(1))
        except ValueError:
            continue
        if not (isinstance(arm, list) and all(isinstance(x, str) for x in arm)):
            continue
        # Whether an arm is a GitHub-hosted image is decided HERE, against the
        # same `HOSTED_IMAGE` every other hosted/self-hosted judgement in this
        # file uses. The fork idiom's safe arm carries no scope label at all,
        # and a shell that only counted scope labels would read it as an
        # unscoped pool and report a correct workflow.
        kind = "hosted" if arm and all(HOSTED_IMAGE.match(x.strip()) for x in arm) else "pool"
        # Comma-joined: a runner label may not contain a comma, so the shell can
        # split it without a second parser.
        out("#ROUTEARM", vid, origin, kind, ",".join(arm))


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

        # KEY PRESENCE, and deliberately nothing more. `container: node:20` is a
        # string and `container: {image: node:20}` is a mapping; a `services:`
        # block is a mapping of names. All three mean the same thing to the
        # runner — it will try to start a container — and a reader that looked
        # at the VALUE would have to decide which shapes count, which is the
        # kind of judgement that reports clean on the shape nobody thought of.
        # Read from the JOB and emitted per leg: a matrix chooses the pool, not
        # whether the job runs in a container.
        if "container" in job:
            out("#CONTAINER", vid)
        if "services" in job:
            out("#SERVICES", vid)

        # A job that cannot be true on a `mergify/merge-queue/<sha>` draft never
        # competes for a pool during queue validation, so RUNNER14 has nothing to
        # ask of it. Emitted per leg like the rest: the `if:` is the JOB's, and a
        # matrix does not change whether the queue drafts reach it.
        if queue_skipped(job):
            out("#QUEUESKIP", vid)

        # A job that publishes outputs is a CANDIDATE anchor — not an anchor.
        # What makes it one is another job resolving its pool from those
        # outputs, which is a fact about the OTHER job and is decided in the
        # shell. Emitted so a repository with exactly one fleet job (its own
        # anchor, nothing consuming it) is not reported for failing to depend
        # on itself.
        if isinstance(job.get("outputs"), dict) and job["outputs"]:
            out("#OUTPUTS", vid)
            # ...and WHAT they publish, for RUNNER12/13. The merge-queue
            # route is published as a job output rather than written into
            # every `runs-on`, so an expression scanner reading only `runs-on`
            # sees `fromJSON(needs.lane.outputs.runner)` in each downstream job
            # and never reaches the one expression that decides.
            for oname, ovalue in job["outputs"].items():
                emit_expr_facts(vid, "output:%s" % oname, str(ovalue))

        # RUNNER11 reads the job's steps as TEXT. Every place a port can be
        # written — `run:`, `env:`, `with:`, a service's options — is one
        # string in the end, and a reader that walked only `run:` would miss
        # the `DATABASE_URL` in `env:`, which is where it is actually written.
        blob = yaml.safe_dump(job, default_flow_style=False, allow_unicode=True)
        for m in LOOPBACK_BAND.finditer(blob):
            out("#LOOPBACKBAND", vid, m.group(1))

        # --- the shared-infrastructure records (RUNNER9/10/11) -------------
        #
        # `runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}` is the whole
        # of rule 1's mechanism: the run's first fleet job publishes the host it
        # landed on, and every later job resolves its pool from that output
        # instead of naming the pool again. Emitted with the job it names, so
        # the caller can tell an anchor from a consumer without guessing.
        #
        # Matched on the SUBSTRING rather than anchored like MATRIX_RUNS_ON,
        # because the fleet's fork idiom wraps it:
        # `${{ fork && 'ubuntu-latest' || fromJSON(needs.anchor.outputs.runs-on) }}`
        # is a correct consumer and an anchored match would call it unpinned.
        #
        # A substring match is also what makes the literal check below
        # necessary. `${{ needs.anchor.outputs.label || 'ExampleRepo' }}`
        # contains the reference and resolves to the POOL whenever the output is
        # empty — which is every run where the anchor was skipped, and every run
        # where it failed before publishing. That is the second host RUNNER9
        # exists to stop, wearing the shape of the fix.
        #
        # So each literal alternative in the expression is checked, and only a
        # GitHub-HOSTED image is accepted beside the reference: that is the fork
        # idiom's `'ubuntu-latest'` and nothing else. The record is still
        # emitted either way, because it is also how the ANCHOR is discovered —
        # a consumer with a bad fallback still names its anchor, and dropping
        # the record would report the anchor for failing to pin to itself. What
        # the literal costs is the CONSUMER's credit, which is the job that is
        # actually wrong.
        for label in (runs_on if isinstance(runs_on, list) else [runs_on]):
            text = str(label) if label is not None else ""
            anchors = [m.group(1) for m in NEEDS_OUTPUT.finditer(text)]
            for anchor in anchors:
                out("#RUNSONNEEDS", vid, anchor)
            # Hoisted out of the loop above. The literals belong to the
            # EXPRESSION, not to each reference inside it, and scanning per
            # reference emitted the same literal once per
            # `needs.<job>.outputs.*` the expression happened to name.
            if anchors:
                seen = dict.fromkeys(
                    LITERAL_ALT.findall(text) + LITERAL_FIRST.findall(text)
                )
                for lit in seen:
                    if lit.strip() and not HOSTED_IMAGE.match(lit.strip()):
                        out("#RUNSONLITERAL", vid, lit.strip())

        if isinstance(runs_on, dict):
            # `{group: …}` names a runner GROUP, whose membership lives in
            # repository settings rather than in this file. Undecidable here,
            # and reported as such rather than passed.
            out("#GROUP", vid)
        else:
            labels = runs_on if isinstance(runs_on, list) else ([runs_on] if runs_on else [])
            literal = []
            for label in labels:
                text = str(label)
                if "${{" in text:
                    out("#EXPR", vid)
                    # A repository small enough to route inline rather than
                    # through a lane job writes the same decision here, and it
                    # is the same decision.
                    emit_expr_facts(vid, "runs-on", text)
                else:
                    literal.append(text.strip())
                    out("#LABEL", vid, text.strip())
            # Whether every literal label is a GitHub-hosted image is decided
            # HERE, once, against `HOSTED_IMAGE` — the same expression the fork
            # guard's safe-destination test uses. It was decided twice, in two
            # languages, and two spellings of one security rule drift apart on
            # the first change to either.
            if literal and all(HOSTED_IMAGE.match(t) for t in literal):
                out("#HOSTEDONLY", vid)

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

# One spelling for a file, so that a path used as a set KEY and a path used as a
# set MEMBER compare equal. Falls back to the argument unchanged when the
# directory cannot be entered, which is the reading a missing file deserves.
# The labels of ONE comma-joined arm that scope it to a repository: every label
# that is not one of the platform labels every pool in the fleet carries.
# Lower-cased, because GitHub does not distinguish `Linux` from `linux`, and a
# comparison that did would read two spellings of one pool as two pools.
scope_labels() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
    tr '[:upper:]' '[:lower:]' | grep -vxE "(${GENERIC})" | grep -v '^$' | sort -u
}

# Two arms are two pools when EACH carries a scope label the other does not.
# Not "they differ" -- mutual non-superset is the property GitHub's scheduler
# reads, and a set that merely differs can still contain the other whole.
disjoint_scopes() {
  local a b
  a="$(scope_labels "$1")"
  b="$(scope_labels "$2")"
  [ -n "$(comm -23 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))" ] &&
    [ -n "$(comm -13 <(printf '%s\n' "$a") <(printf '%s\n' "$b"))" ]
}


abs_path() {
  local d b
  d="$(dirname -- "$1")"
  b="$(basename -- "$1")"
  d="$(cd -- "$d" 2>/dev/null && pwd)" || { printf '%s' "$1"; return; }
  [ -n "$d" ] || { printf '%s' "$1"; return; }
  printf '%s/%s' "$d" "$b"
}

# Files a `pull_request` workflow can reach through a local `uses:` call — see
# `compute_reachable`. Newline-separated absolute paths.
REACHABLE_PR=""

# The same set computed WITHOUT the fork guard.
#
# Two different questions were reading one answer. RUNNER4 asks "can FORK code
# reach a warm host", and a `fork == false` edge is correctly not a path for it.
# Everything else asks "does this file take part in a pull request at all", and
# a guarded edge is precisely the path that DOES run — for an in-repo pull
# request, which is every pull request the fleet actually serves. Read off
# REACHABLE_PR, a guarded callee was invisible: two `services:` owners inside it
# were two stacks in one run, and the gate said nothing.
REACHABLE_PR_ANY=""
# A `timeout-minutes` at or above this bounds nothing GitHub was not already
# bounding. Overridable downwards by a consumer whose queue expires sooner.
MAX_TIMEOUT=360
# Declared acceptance of an undecidable pool — see RUNNER5.
ALLOW_DYNAMIC=0
# RUNNER9/10/11, off by default. Opt-in for the reason the ADR gives: a gate
# that fails every repository on the day it merges is a gate that gets disabled
# in every repository on the day after. A repository turns it on in the same
# pull request that consolidates its workflows onto an anchor.
SHARED_INFRA=0
# Owner jobs seen across the whole file set, for RUNNER10. Cross-file, because
# "one owner per pull request" is a property of the RUN, and a run spans every
# workflow the event triggers — two files each holding one owner is the shape
# this rule exists to catch, and the shape a per-file count reads as clean.
SHARED_INFRA_OWNERS=""

# RUNNER14, and cross-file for a reason RUNNER10's is not: the two halves of
# this finding are usually in DIFFERENT files. The route lives in the workflow
# that was migrated and the literal pool lives in the one that was not, so a
# per-file reading of either half is clean. Whether the repository has a route
# at all also cannot be known until every file has been read, and the file that
# has it may be read last — so the candidates are collected here and judged
# once, at the end, rather than reported as they are found.
QUEUE_ROUTED=0
# `<abs file>\t<job id>\t<labels>` per line, one per fleet job that named its
# pool literally in a pull-request workflow. The absolute path is carried
# because the exemption marker is read back out of the file at verdict time,
# long after `check_file` has returned.
QUEUE_UNROUTED=""

# Every LOCAL `uses:` edge the file set contains, as
# `<callee abs path>	<caller abs path>	<caller job id>`. Filled by
# `compute_reachable`, which already walks these edges for fork reachability.
#
# RUNNER10 needs them because "one stack per run" is counted per INVOCATION and
# not per job definition. A reusable workflow whose job brings up a stack,
# called from three jobs, is three stacks in one run — and read as a file it is
# one job and looks clean. That is not a hypothetical shape; it is what a
# repository reaches by factoring its one owner job out into a reusable
# workflow, which is the refactor this contract otherwise encourages.
CALL_EDGES=""

# RUNNER9's escape hatch and RUNNER10's declaration, in the shape RUNNER7's
# marker already established: beside the job, naming the job, with an issue.
#
#   # shared-infra-owner(<job-id>): <what it brings up>
#   # shared-infra-exempt(<job-id>, #<issue>): <why this job may name a pool>
#
# The job id is not decoration. A YAML reader has discarded comments by the time
# it yields a job, so a bare marker cannot be attributed to one — and a bare
# marker is also un-reviewable: it excuses whatever the file happens to contain
# after the next change, including a job added later that nobody weighed.
# YAML comment lines only — block-scalar bodies removed.
#
# `# shared-infra-exempt(job, #1): x` written inside a `run: |` block is not a
# comment. It is shell, in the middle of a step, and it declares nothing; it
# reads as a declaration only to a grep that treats the file as text. A
# repository could exempt a job by echoing the marker, and would not have to
# mean to: a `run:` block that greps its own logs for the string is enough.
#
# Tracked by INDENT, which is what a block scalar is: the body of `run: |` is
# every following line indented past the line that opened it, blank lines
# included, and the block ends at the first line that is not. Written in awk
# rather than parsed, because PyYAML has discarded comments by the time it
# yields anything — the reader that could parse this is the one that cannot see
# it.
comment_view() {
  awk '
    {
      match($0, /^[ \t]*/); ind = RLENGTH
      if (inblock) {
        if ($0 ~ /^[ \t]*$/) next
        if (ind > blockind) next
        inblock = 0
      }
      print
      # A block-scalar indicator ends its line -- EXCEPT that YAML allows a
      # comment after it, so `run: | # note` opens a block just as `run: |`
      # does. Missing that shape put the whole body back into the comment view,
      # which is the bypass this function exists to close, reachable by adding
      # a comment.
      #
      # Anchored on the `:` (or a sequence dash) that a block scalar always
      # follows, and never fired on a line that is itself a comment: without
      # that, a comment ending in `|` would swallow everything indented under
      # it. `[-+0-9]*` because the chomping and indentation indicators may be
      # written in either order (`|2-` as well as `|-2`).
      if ($0 !~ /^[ \t]*#/ &&
          ($0 ~ /:[ \t]*[|>][-+0-9]*[ \t]*(#.*)?$/ ||
           $0 ~ /^[ \t]*-[ \t]*[|>][-+0-9]*[ \t]*(#.*)?$/)) {
        inblock = 1; blockind = ind
      }
    }
  ' "$1"
}

shared_infra_marker() {
  local file="$1" kind="$2" job="$3" esc tail
  # `re_quote`, not a second escaping expression written here. A YAML job id may
  # legally contain `.`, `[` and `+`, and two spellings of one escaping rule
  # drift apart on the first change to either.
  esc="$(re_quote "$job")"
  case "$kind" in
    # An exemption carries an issue; an owner declaration does not, because it
    # declares intent rather than accepting a known gap.
    exempt) tail=",[[:space:]]*#[0-9]+[[:space:]]*" ;;
    *)      tail="[[:space:]]*" ;;
  esac
  # Process substitution and not a pipe: `-q` exits at the first match, and in a
  # pipeline that SIGPIPEs the writer and `pipefail` turns a successful match
  # into a failed command. Here the reader is not in grep's pipeline at all.
  grep -Eq "^[[:space:]]*#.*shared-infra-${kind}\([[:space:]]*${esc}${tail}\):[[:space:]]*[^[:space:]]" <(comment_view "$file")
}

# RUNNER7's escape hatch, and deliberately NOT RUNNER5's `--allow-dynamic-runner`.
# A CLI flag excuses every remote call in the repository at once — including one
# a later, unrelated change adds — and it lives in the CI invocation rather than
# beside the call it excuses, so the reviewer of that call never sees it. This is
# a marker in the workflow, and it NAMES ITS CALLEE:
#
#   # remote-reusable-allowed(<owner>/<repo>/.github/workflows/<file>, #<issue>): <reason>
#
# Point the `uses:` at a different workflow, or a different owner, and the marker
# stops matching and the check re-arms. The REF is deliberately not part of it: a
# pin bump does not change the fact this gate cannot read the callee's jobs, and
# whether that ref may float at all is `check-action-pins.sh`'s question, not
# this one.
#
# What the marker asserts is narrow, and worth stating so nobody reads it as
# more: a human has read the callee and accepted its runner scope and timeouts.
# It does not verify them — nothing here can, which is the whole finding. The
# issue number is where that reading is recorded, so the acceptance has an owner
# and a place to be revisited; a marker without one is not accepted.
# RUNNER5's escape hatch, in the same shape and for the same reason RUNNER7's
# exists:
#
#   # dynamic-runner-allowed(<job-id>, #<issue>): <who scopes the value>
#
# `--allow-dynamic-runner` excuses EVERY dynamic job in the repository at once,
# including one a later, unrelated change adds, and it lives in the CI
# invocation rather than beside the job it excuses — so the reviewer of that job
# never sees it. That trade is fine for a repository where every fleet job
# resolves its pool from one anchor, which is why the flag stays. It is the
# wrong trade for a repository with ONE such job, and this one is now that
# repository: `shared-infra-anchor.yml` takes its pool label as a
# `workflow_call` input, so its `runs-on` is an expression by construction and
# always will be, while every other workflow here is GitHub-hosted and must stay
# checkable.
#
# What the marker asserts is exactly what the flag asserts, narrowed to one job:
# a human has read where that value comes from and accepted that whoever
# supplies it scopes it. The issue number is where that reading is recorded.
dynamic_runner_declared() {
  local file="$1" job="$2" esc
  # `re_quote` for the same reason `shared_infra_marker` uses it: a YAML job id
  # may legally contain `.`, `[` and `+`, and two spellings of one escaping rule
  # drift apart on the first change to either.
  esc="$(re_quote "$job")"
  # An issue is required, as it is for an exemption and a remote call: this
  # accepts a known gap rather than declaring intent, so it needs an owner and a
  # place to be revisited. The trailing `[^[:space:]]` refuses `(...): ` with
  # nothing after it — a waiver wearing the shape of a declaration.
  grep -Eq "^[[:space:]]*#.*dynamic-runner-allowed\([[:space:]]*${esc}[[:space:]]*,[[:space:]]*#[0-9]+[[:space:]]*\):[[:space:]]*[^[:space:]]" <(comment_view "$file")
}

# RUNNER14's escape hatch, in the same shape as every other marker here:
#
#   # merge-queue-route-exempt(<job-id>, #<issue>): <why this job stays behind>
#
# There are real reasons for one. A job whose whole purpose is to observe the
# pull-request pool belongs on the pull-request pool; so does one the queue pool
# is deliberately not sized for. What there is no reason for is the job that
# stayed behind because nobody noticed it, and that job and this one are
# indistinguishable in the YAML — which is what the marker is for. It records
# WHICH of the two this is, beside the job, with an issue to revisit it.
merge_queue_route_declared() {
  local file="$1" job="$2" esc
  esc="$(re_quote "$job")"
  grep -Eq "^[[:space:]]*#.*merge-queue-route-exempt\([[:space:]]*${esc}[[:space:]]*,[[:space:]]*#[0-9]+[[:space:]]*\):[[:space:]]*[^[:space:]]" <(comment_view "$file")
}

remote_call_declared() {
  local file="$1" callee="$2" esc
  # The callee is DATA, not a pattern. Unescaped, the `.` in `ci.yml` matches any
  # character, so a marker for `ci.yml` would also excuse a call to `ciXyml`.
  esc="$(printf '%s' "$callee" | sed 's/[][\.^$*+?(){}|]/\\&/g')"
  # A file, not a pipe, so `-q`'s early exit cannot turn into a pipefail false
  # negative. The trailing `[^[:space:]]` is the reason: `(...): ` with nothing
  # after it is a waiver wearing the shape of a declaration.
  grep -Eq "^[[:space:]]*#.*remote-reusable-allowed\([[:space:]]*${esc}[[:space:]]*,[[:space:]]*#[0-9]+[[:space:]]*\):[[:space:]]*[^[:space:]]" <(comment_view "$file")
}

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
  if [ "$has_pr" -eq 0 ] && printf '%s\n' "$REACHABLE_PR" | grep -cxF -- "$(abs_path "$file")" >/dev/null; then
    has_pr=1
  fi
  # The guard-blind answer, for the rules that are not RUNNER4. See
  # REACHABLE_PR_ANY: a callee behind `fork == false` still runs, for every
  # pull request from the repository itself.
  local has_pr_any="$has_pr"
  if [ "$has_pr_any" -eq 0 ] && printf '%s\n' "$REACHABLE_PR_ANY" | grep -cxF -- "$(abs_path "$file")" >/dev/null; then
    has_pr_any=1
  fi

  local job job_re
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    job_re="$(re_quote "$job")"
    # A matrix leg is judged separately — a scoped leg cannot vouch for an
    # unscoped one — so `$job` here may be the synthetic `lint~leg1`. That id
    # exists nowhere in the workflow. Anything a workflow AUTHOR has to write or
    # read uses the YAML job id instead: the exemption marker names it, and a
    # diagnostic that recommended `shared-infra-exempt(lint~leg1, …)` was
    # recommending a declaration that could never match.
    local job_base="${job%%~leg*}"

    local labels self_hosted=0 scoped=0 hosted_only=0 windows_pool=0 label
    labels="$(printf '%s\n' "$records" | sed -n "s/^#LABEL\t${job_re}\t//p")"
    # "Every literal label is a GitHub-hosted image" is the reader's answer, not
    # a second opinion computed here — see `#HOSTEDONLY`.
    [ "$(printf '%s\n' "$records" | grep -c "^#HOSTEDONLY	${job_re}$")" -gt 0 ] && hosted_only=1
    while IFS= read -r label; do
      [ -n "$label" ] || continue
      # RUNNER8's half of the label question: which OS is on the other end.
      # Case-insensitively, for the same reason every other label test here is —
      # GitHub does not distinguish `Windows` from `windows`, and a gate that
      # did would read the capitalised spelling every consumer actually writes
      # as some other pool entirely and say nothing about it.
      if printf '%s' "$label" | grep -ciE "^(${WINDOWS_LABEL})$" >/dev/null; then
        windows_pool=1
      fi
      if printf '%s' "$label" | grep -ciE "^self-hosted$" >/dev/null; then
        self_hosted=1
      else
        printf '%s' "$label" | grep -ciE "^(${GENERIC})$" >/dev/null || scoped=1
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
    local has_container=0 has_services=0 rule8_keys=""
    [ "$(printf '%s\n' "$records" | grep -c "^#CONTAINER	${job_re}$")" -gt 0 ] && has_container=1
    [ "$(printf '%s\n' "$records" | grep -c "^#SERVICES	${job_re}$")" -gt 0 ] && has_services=1
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
      if printf '%s' "$timeout" | grep -cE '^[0-9]+$' >/dev/null; then
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

      # RUNNER8 — a Windows pool runs no containers, and this is the one place
      # a job author finds that out before the pool does. Scoped to the WINDOWS
      # label: `container:` on the Linux pool is how that pool is meant to be
      # used, and a hosted `windows-2022` image is not this fleet and does run
      # containers, so neither is touched.
      if [ "$windows_pool" -eq 1 ] && { [ "$has_container" -eq 1 ] || [ "$has_services" -eq 1 ]; }; then
        if [ "$has_container" -eq 1 ]; then
          rule8_keys="container:"
        fi
        if [ "$has_services" -eq 1 ]; then
          rule8_keys="${rule8_keys:+$rule8_keys and }services:"
        fi
        err RUNNER8 "$rel: job '$job' targets a Windows pool label and declares $rule8_keys — a Windows pool has NO container runtime (job isolation there is one local Windows account per slot, not a container), so this job fails at 'Initialize containers' before any step runs, with an error about docker on a host that has none"
      fi
    fi

    # --- RUNNER12/13: the merge-queue route ----------------------------------
    #
    # OUTSIDE the self-hosted block on purpose. The job that DECIDES the route
    # is the lane job, and the lane job runs on `ubuntu-latest` -- it is a
    # five-second expression, not pool work. Gating this on `self_hosted` would
    # skip the one job in the repository that publishes the decision and report
    # clean on every downstream job that merely obeys it.
    local origin
    while IFS= read -r origin; do
      [ -n "$origin" ] || continue
      local origin_re
      origin_re="$(re_quote "$origin")"

      # RUNNER12 -- the branch name is not a fact. `github.head_ref` is whatever
      # the requester typed, so a route keyed on the prefix alone offers the
      # reserved pool to any pull request willing to be named after the queue,
      # forks included. Its absence is silent: the workflow is green, the route
      # works, and it also works for everybody else.
      local same_repo=0 author=0 missing=""
      [ "$(printf '%s\n' "$records" | grep -c "^#QUEUESAMEREPO	${job_re}	${origin_re}$")" -gt 0 ] && same_repo=1
      [ "$(printf '%s\n' "$records" | grep -c "^#QUEUEAUTHOR	${job_re}	${origin_re}$")" -gt 0 ] && author=1
      [ "$same_repo" -eq 0 ] && missing="the head branch living in this repository (head.repo.full_name == github.repository)"
      [ "$author" -eq 0 ] && missing="${missing:+$missing and }the author being Mergify (user.login == 'mergify[bot]')"
      if [ -n "$missing" ]; then
        err RUNNER12 "$rel: job '$job' routes on the merge-queue branch prefix in $origin but does not also require $missing -- github.head_ref is chosen by whoever opened the pull request, so as written ANY pull request named 'mergify/merge-queue/...' claims the pool reserved for the queue"
      fi

      # RUNNER13 -- and the two pools have to be two pools. GitHub schedules a
      # self-hosted runner by SUPERSET, so if one arm's labels cover the
      # other's the route is decorative: every ordinary job is eligible for the
      # queue's hosts and the split buys nothing. Covered the other way round
      # and the queue cannot be addressed at all -- its jobs ask for a label no
      # runner carries and queue against it forever rather than failing.
      #
      # The same property the controller module asserts across its `pools`
      # table at plan time, asserted here across the workflow that ADDRESSES
      # them. Both ends, because either one alone is a rule the other drifts
      # away from.
      local arms=() arm
      while IFS= read -r arm; do
        [ -n "$arm" ] || continue
        arms+=("$arm")
      done <<EOF
$(printf '%s\n' "$records" | sed -n "s/^#ROUTEARM\t${job_re}\t${origin_re}\tpool\t//p")
EOF

      local i j
      for ((i = 0; i < ${#arms[@]}; i++)); do
        # An arm naming no scope label at all is offered to the entire fleet --
        # RUNNER1's finding, reached through an expression RUNNER1 cannot read.
        if [ -z "$(scope_labels "${arms[$i]}")" ]; then
          err RUNNER13 "$rel: job '$job' routes $origin to [${arms[$i]}], which names no repository-scoped label -- that is not a pool, it is every pool in the fleet"
          continue
        fi
        for ((j = i + 1; j < ${#arms[@]}; j++)); do
          [ -n "$(scope_labels "${arms[$j]}")" ] || continue
          if ! disjoint_scopes "${arms[$i]}" "${arms[$j]}"; then
            err RUNNER13 "$rel: job '$job' routes $origin between [${arms[$i]}] and [${arms[$j]}], and one label set covers the other -- GitHub matches a runner by superset, so these are not two pools. The queue pool carries its own scope label INSTEAD OF the pull-request pool's, never in addition to it"
          fi
        done
      done
    done <<EOF
$(printf '%s\n' "$records" | sed -n "s/^#QUEUEREF\t${job_re}\t//p" | sort -u)
EOF

    # --- RUNNER14: the job that takes no route -------------------------------
    #
    # Two facts, both collected here and neither judged here: does this
    # repository route at all, and which of its pull-request jobs named a pool
    # instead. The verdict needs both and cannot have them until the last file
    # has been read -- see `QUEUE_ROUTED`.
    local job_routes=0
    [ "$(printf '%s\n' "$records" | grep -c "^#QUEUEREF	${job_re}	")" -gt 0 ] && job_routes=1
    [ "$job_routes" -eq 1 ] && QUEUE_ROUTED=1

    if [ "$self_hosted" -eq 1 ] && [ "$has_pr_any" -eq 1 ] &&
      [ "$has_expr" -eq 0 ] && [ "$has_group" -eq 0 ] && [ "$reusable" -eq 0 ] &&
      [ "$job_routes" -eq 0 ] &&
      [ "$(printf '%s\n' "$records" | grep -c "^#QUEUESKIP	${job_re}$")" -eq 0 ]; then
      # A `uses:` job is excluded because it names no pool -- its callee does,
      # and the callee is judged in its own file, carrying this file's
      # pull-request reachability with it. An EXPRESSION is excluded for the
      # opposite reason: it may well be the route, and where it is not, RUNNER5
      # already reports it as a pool this gate cannot read. Adding a second
      # verdict on the same undecidable value would be this rule guessing.
      #
      # The job that publishes the route is excluded too, and has to be: it runs
      # BEFORE the route it computes exists, so a pool is the only thing it can
      # name. Nothing is lost -- RUNNER12/13 judge that job in full.
      QUEUE_UNROUTED="${QUEUE_UNROUTED}$(abs_path "$file")	${job_base}	$(printf '%s' "$labels" | tr '\n' ' ')"$'\n'
    fi

      # --- RUNNER9/10/11: one host, one stack, per pull request ---------------
      #
      # Off unless --shared-infra. See the flag's comment for why an opt-in.
      # A job with no `runs-on` at all is a `uses:` job — it runs the callee's
      # jobs, which this gate judges in the callee's own file, and asking it to
      # pin a pool it never names would be a finding nobody could act on.
      #
      # A runner GROUP is included, and it was not. `runs-on: {group: X}` names
      # neither a label nor an expression, so the job fell out of these rules
      # entirely: two group-selected jobs could each declare `services:` and the
      # gate reported clean. A group is a pool named directly — which is the
      # subject of RUNNER9, not an exception to it.
      #
      # A `uses:` job is included too, but ONLY when it declares itself an
      # owner. That is not a loophole being widened, it is the one this
      # contract's own recommended refactor opened: the anchor's body belongs in
      # ONE reusable workflow that every repository calls, and the moment it
      # moves there the caller's anchor job has no `runs-on`, no `services:` and
      # nothing else a YAML reader can see. Counted as before, such a caller
      # declares no owner at all — so a repository could call the fleet anchor
      # AND keep a second job with its own `services:` block, and RUNNER10 would
      # count one owner and report two stacks clean. The marker is the only
      # evidence there is, which is exactly why the marker exists.
      #
      # RUNNER9 cannot fire on this job (an owner is an anchor, and an anchor
      # names its own pool by definition) and neither can RUNNER11 (a `uses:`
      # job has no steps to dial anything from). The widening reaches RUNNER10
      # and nothing else.
      if [ "$SHARED_INFRA" -eq 1 ] && [ "$has_pr_any" -eq 1 ] && [ "$hosted_only" -eq 0 ] &&
         { [ -n "$labels" ] || [ "$has_expr" -eq 1 ] || [ "$has_group" -eq 1 ] ||
           { [ "$reusable" -eq 1 ] && shared_infra_marker "$file" owner "$job_base"; }; }; then
        local pins_to_anchor=0 is_owner=0 is_anchor=0
        [ "$(printf '%s
' "$records" | grep -c "^#RUNSONNEEDS	${job_re}	")" -gt 0 ] && pins_to_anchor=1
        # ...unless the same expression can also resolve to a pool literal. A
        # `||` fallback is not a safety net here, it is the failure: the run
        # whose anchor did not publish is exactly the run that lands the job on
        # a second host.
        [ "$(printf '%s
' "$records" | grep -c "^#RUNSONLITERAL	${job_re}	")" -gt 0 ] && pins_to_anchor=0
        # An owner is a job that brings the stack up: it declares `services:`,
        # or it says so. Both, rather than services alone, because a stack
        # started by a `docker compose up` step in a `run:` block is invisible
        # to YAML and is the shape a real anchor takes once it outgrows
        # `services:`.
        { [ "$has_services" -eq 1 ] || shared_infra_marker "$file" owner "$job_base"; } && is_owner=1
        # The anchor is whatever another job resolves its pool FROM. Read off
        # the graph, not asserted: a job that calls itself the anchor and that
        # nobody pins to is not holding a host for anyone.
        [ "$(printf '%s
' "$records" | grep -c "^#RUNSONNEEDS	[^	]*	${job_re}$")" -gt 0 ] && is_anchor=1
        [ "$is_owner" -eq 1 ] && is_anchor=1
        # …and a job that PUBLISHES outputs in a file where nothing resolves a
        # pool from anything. That is a repository with one fleet job: it IS
        # the anchor, it holds the host the run will use, and there is no other
        # job for it to pin to. Reported without this, the only fix on offer
        # was to make the job depend on itself — which is why the reader emits
        # `#OUTPUTS` at all.
        if [ "$(printf '%s\n' "$records" | grep -c "^#RUNSONNEEDS	")" -eq 0 ] &&
           [ "$(printf '%s\n' "$records" | grep -c "^#OUTPUTS	${job_re}$")" -gt 0 ]; then
          is_anchor=1
        fi

        # RUNNER9 — a second host per run is the whole failure this addresses.
        # A Linux fleet job that names its pool literally is scheduled by
        # GitHub onto ANY free agent of that pool, so a run with two such jobs
        # is a run with two hosts, and the second one cannot see the database
        # the first one started: the stack is bound to one host's address, and
        # the band's firewall admits only the pair, not a bystander. The
        # symptom is a connection refused in a job that changed nothing.
        #
        # Windows is exempt by design, not by omission — rule 1's exception.
        # A Windows job reaches the stack across the band (RUNNER11 checks it
        # reaches it correctly), so it is a second host on purpose.
        if [ "$windows_pool" -eq 0 ] && [ "$pins_to_anchor" -eq 0 ] && [ "$is_anchor" -eq 0 ]; then
          if ! shared_infra_marker "$file" exempt "$job_base"; then
            err RUNNER9 "$rel: job '$job' is self-hosted on a pull_request workflow and names its pool directly instead of resolving it from the anchor job's output — GitHub may place it on a different host than the rest of this run, where the run's shared stack does not exist (use runs-on: \${{ fromJSON(needs.<anchor>.outputs.runs-on) }}, or declare '# shared-infra-exempt($job_base, #<issue>): <reason>')"
          fi
        fi

        # RUNNER10 — one stack per run. Counted across every pull-request
        # workflow in the repository and reported once, in main(): "one owner"
        # is a property of the RUN, and a run spans every workflow the event
        # triggers, so two files each holding one owner is exactly the shape
        # this rule exists to catch and exactly the shape a per-file count
        # reads as clean.
        # A declared exemption exempts the job from both rules it can be the
        # subject of. A repository that has argued, in writing and against an
        # issue, that this job needs its own stack has answered RUNNER10 as
        # well — and a marker that silenced one rule while leaving the other
        # red would just be read as the gate being broken.
        if [ "$is_owner" -eq 1 ] && ! shared_infra_marker "$file" exempt "$job_base"; then
          # Once per INVOCATION, not once per definition. A reusable workflow
          # whose job brings up a stack, called from three caller jobs, starts
          # three stacks in one run; counted per file it is one owner and reads
          # clean. That is not a hypothetical shape — it is the one a repository
          # lands on by factoring its single owner job out into a reusable
          # workflow, which is the refactor this contract otherwise encourages.
          #
          # A file nothing calls has no incoming edges and counts once, exactly
          # as before; so does every file when `check_file` is driven directly,
          # without a reachability pass in front of it.
          local abs_self si_edges cfile cjob2
          abs_self="$(abs_path "$file")"
          si_edges="$(awk -v self="$abs_self" -F'\t' '$1 == self' <<EOF
$CALL_EDGES
EOF
)"
          if [ -n "$si_edges" ]; then
            while IFS=$'\t' read -r _ cfile cjob2; do
              [ -n "${cjob2:-}" ] || continue
              SHARED_INFRA_OWNERS="${SHARED_INFRA_OWNERS}${rel}: job '${job}' (called from ${cfile#"$REPO_ROOT"/} job '${cjob2}')"$'
'
            done <<EOF
$si_edges
EOF
          else
            SHARED_INFRA_OWNERS="${SHARED_INFRA_OWNERS}${rel}: job '${job}'"$'
'
          fi
        fi

        # RUNNER11 — the Windows half of rule 3, and the mistake it is going to
        # make. A Windows job's connection to the stack goes to the LINUX
        # host's address on the slot's band port; `localhost` on that port is
        # the Windows machine, where nothing is listening. It fails as a
        # refusal or a hang, in a job whose code is correct everywhere else,
        # which is why it is worth a gate rather than a paragraph.
        local lb
        lb="$(printf '%s
' "$records" | sed -n "s/^#LOOPBACKBAND	${job_re}	//p" | head -1)"
        if [ -n "$lb" ] && [ "$windows_pool" -eq 1 ]; then
          err RUNNER11 "$rel: job '$job' runs on a Windows pool and names localhost:$lb — a shared-infrastructure port, which on a Windows host has nothing listening on it (the stack runs on the run's LINUX host; use the address the host exports as CI_SHARED_INFRA_ADDR)"
        elif [ -n "$lb" ] && { [ "$has_expr" -eq 1 ] || [ "$has_group" -eq 1 ]; } &&
             shared_infra_marker "$file" exempt "$job_base"; then
          # The OS is not decidable here, and this is the one shape in which
          # that matters. A job selecting its pool dynamically names no
          # `windows` label, so `windows_pool` is 0 and the check above was
          # skipped — for a job that has ALSO declared, with the exemption, that
          # it is deliberately a second host. That is the Windows job of rule
          # 3, spelled the way the fleet's routing idiom spells it, and reading
          # it as non-Windows reports the one job this rule exists for as clean.
          #
          # An ordinary consumer is untouched: it resolves its pool from the
          # anchor and carries no exemption, and `localhost` on the run's Linux
          # host is exactly right for it.
          err RUNNER11 "$rel: job '$job' names localhost:$lb — a shared-infrastructure port — while selecting its runner dynamically AND declaring a shared-infra exemption, so it is a second host of unknown OS: if that host is Windows nothing is listening on that port (use the address the host exports as CI_SHARED_INFRA_ADDR, which is correct on either OS)"
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
      if [ "$ALLOW_DYNAMIC" -eq 0 ] && ! dynamic_runner_declared "$file" "$job_base"; then
        err RUNNER5 "$rel: job '$job' selects its runner dynamically — this gate cannot decide which pool it claims (declare '# dynamic-runner-allowed($job_base, #<issue>): <who scopes the value>' beside the job, or --allow-dynamic-runner if every dynamic job in the repository has the same answer)"
      fi
    fi

    # RUNNER7 — the exemption above, made honest. A `uses:` job takes no
    # timeout because the bound belongs to the called workflow's jobs; for a
    # LOCAL callee this gate reads those jobs, and now carries fork
    # reachability into them. For a REMOTE one it holds neither file nor
    # jobs, so the exemption was handing the property to a document nobody
    # checked. Undecided and said so, like RUNNER5.
    #
    # Undecidable is not the same as forbidden, and this gate had been reading it
    # that way: the fleet's whole premise is ONE reusable workflow in
    # `ci-runner-infra` called by every repository instead of nine drifting
    # copies, so an unconditional refusal here made the only path past it the
    # vendoring that another gate in this same run exists to prevent. The
    # decision it cannot make is now declarable, next to the call, naming it.
    local remote
    remote="$(printf '%s\n' "$records" | sed -n "s/^#REMOTECALL\t${job_re}\t//p" | head -1)"
    if [ -n "$remote" ] && ! remote_call_declared "$file" "${remote%%@*}"; then
      err RUNNER7 "$rel: job '$job' calls the remote reusable workflow '$remote' — its jobs' runner scope and timeouts are not in this repository, so this gate cannot decide them (read the callee, then declare it: '# remote-reusable-allowed(${remote%%@*}, #<issue>): <reason>')"
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
  local f records seed="" edges="" caller target changed=1 line _cjob
  # Reset, because RUNNER10 reads it and the self-test drives the pass more than
  # once in a single process: edges left over from the previous fixture would be
  # counted against the next one's owners.
  CALL_EDGES=""
  for f in "$@"; do
    # Both sides of every edge are canonicalised, because the two sides were
    # spelled differently: the caller was whatever the invocation passed —
    # `.github/workflows/ci.yml` in the documented `<file>...` mode — while a
    # `./…` call target was resolved to an absolute path here. The seeds were
    # then relative, the targets absolute, and the membership test matched neither
    # against the other, so reachability silently computed to nothing on the
    # exact invocation the usage line documents. `check_file` canonicalises the
    # same way before asking whether its file is in the set.
    f="$(abs_path "$f")"
    records="$(read_workflow "$f")" || continue
    if [ "$(printf '%s\n' "$records" | grep -c '^#PR$')" -gt 0 ] ||
       [ "$(printf '%s\n' "$records" | grep -c '^#PRTARGET$')" -gt 0 ]; then
      seed="$seed$f"$'\n'
    fi
    # An edge carries its CALLER JOB, because a guard on the calling job is a
    # guard on everything that job reaches: `if: …fork == false` on the `uses:`
    # job means the callee's jobs never run for a fork through this edge. Read
    # without it, the callee was asked for a guard it could not need, and the
    # only way to satisfy the gate was to duplicate the caller's condition in a
    # file that has no pull-request context of its own. A callee reached by ANY
    # unguarded edge is still reachable — the guard has to hold on every path.
    local cjob cjob_re
    while IFS=$'\t' read -r cjob line; do
      [ -n "${line:-}" ] || continue
      cjob_re="$(re_quote "$cjob")"
      target="$(cd "$(dirname "$f")/../.." 2>/dev/null && pwd)/${line#./}"
      # Recorded BEFORE the fork guard, and deliberately. A guarded edge is
      # still an invocation: `fork == false` is exactly the condition under
      # which the job runs on THIS fleet, so it brings the callee's stack up on
      # every in-repo pull request. The guard scopes REACHABILITY, which is a
      # question about forks; it does not scope how many stacks a run starts.
      CALL_EDGES="$CALL_EDGES$target	$f	$cjob"$'\n'
      [ "$(printf '%s\n' "$records" | grep -c "^#FORKGUARD	${cjob_re}$")" -gt 0 ] && continue
      edges="$edges$f	$target"$'\n'
    done <<EOF
$(printf '%s\n' "$records" | sed -n 's/^#CALLS\t//p')
EOF
  done

  REACHABLE_PR="$seed"
  REACHABLE_PR_ANY="$seed"
  # Fixpoint rather than one hop: a caller may reach a callee that itself calls
  # another, and the pool at the end of that chain is as reachable as the first.
  while [ "$changed" -eq 1 ]; do
    changed=0
    while IFS=$'\t' read -r caller target; do
      [ -n "${target:-}" ] || continue
      printf '%s\n' "$REACHABLE_PR" | grep -cxF -- "$caller" >/dev/null || continue
      printf '%s\n' "$REACHABLE_PR" | grep -cxF -- "$target" >/dev/null && continue
      REACHABLE_PR="$REACHABLE_PR$target"$'\n'
      changed=1
    done <<EOF
$edges
EOF
  done

  # …and again over CALL_EDGES, which carries the guarded edges too. Same
  # fixpoint, different edge set: `<callee>	<caller>	<caller job>`, so the
  # two fields are read in the other order.
  changed=1
  while [ "$changed" -eq 1 ]; do
    changed=0
    while IFS=$'\t' read -r target caller _cjob; do
      [ -n "${caller:-}" ] || continue
      printf '%s\n' "$REACHABLE_PR_ANY" | grep -cxF -- "$caller" >/dev/null || continue
      printf '%s\n' "$REACHABLE_PR_ANY" | grep -cxF -- "$target" >/dev/null && continue
      REACHABLE_PR_ANY="$REACHABLE_PR_ANY$target"$'\n'
      changed=1
    done <<EOF
$CALL_EDGES
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

  # `ubuntu-pool-1` is a custom label on a fleet runner, not a hosted image.
  # Read by prefix it was hosted, and every isolation check was skipped on it.
  # RUNNER4 is the discriminator: a hosted image is not fleet-reachable and is
  # never asked for a fork guard, so this fixture fires only if the label is
  # read as what it is — a custom label on a fleet runner.
  expect "an OS-prefixed custom label is not a hosted image" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-pool-1
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "a real hosted image is still hosted" "" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-24.04-arm
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A version-shaped suffix is not a version GitHub ships. `ubuntu-2204` is the
  # dotless spelling a fleet uses for its own pool, `windows-11` is a desktop
  # nobody hosts runners on, and `macos-14.0` is a point release where the
  # hosted label is `macos-14`. Each was read as hosted by `\d+(\.\d+)?`, which
  # skipped every isolation check on the job carrying it.
  expect "a dotless Ubuntu version is a custom label" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-2204
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "a bare Windows desktop version is a custom label" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: windows-11
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "a macOS point release is a custom label" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: macos-14.0
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # …and the shapes GitHub does ship stay hosted, so the tightening is not just
  # "report everything".
  expect "the shipped Windows and macOS images stay hosted" "" "" allowed \
'on: [pull_request]
jobs:
  win:
    runs-on: windows-2022
    timeout-minutes: 30
    steps: [{run: "true"}]
  arm:
    runs-on: windows-11-arm
    timeout-minutes: 30
    steps: [{run: "true"}]
  mac:
    runs-on: macos-latest-xlarge
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A version of the right SHAPE is still not a version GitHub ships. These
  # three passed the per-OS shapes (`\d{2}\.04`, `20\d{2}`, `\d{2}`) and are
  # exactly the private labels a fleet would pick if it wanted one that looked
  # official — so the versions are enumerated rather than shaped, and each of
  # these reads as the custom label it is.
  expect "an unshipped Ubuntu LTS number is a custom label" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: ubuntu-99.04
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "an unshipped Windows year is a custom label" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: windows-2099
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect "an unshipped macOS major is a custom label" "RUNNER4" "" allowed \
'on: [pull_request]
jobs:
  build:
    runs-on: macos-99
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # …and every version that IS shipped stays hosted, so enumerating did not
  # quietly drop one. `windows-2022-large` is a real larger-runner label.
  expect "the enumerated images stay hosted" "" "" allowed \
'on: [pull_request]
jobs:
  u22:
    runs-on: ubuntu-22.04
    timeout-minutes: 30
    steps: [{run: "true"}]
  w25:
    runs-on: windows-2025
    timeout-minutes: 30
    steps: [{run: "true"}]
  wlarge:
    runs-on: windows-2022-large
    timeout-minutes: 30
    steps: [{run: "true"}]
  m13:
    runs-on: macos-13
    timeout-minutes: 30
    steps: [{run: "true"}]
  m14:
    runs-on: macos-14
    timeout-minutes: 30
    steps: [{run: "true"}]
  m15:
    runs-on: macos-15
    timeout-minutes: 30
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

  # …or declare it for ONE job instead of the whole repository. The flag excuses
  # every dynamic job at once, including one a later change adds, from a CI
  # invocation the reviewer of this job never sees; the marker is beside the job
  # and names it. Note the absent trailing `1`: no flag here.
  expect "a per-job declaration accepts an undecidable pool without the flag" "" "" allowed \
'on:
  pull_request:
jobs:
  # dynamic-runner-allowed(build, #1): the label is a repository variable our admins scope
  build:
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || vars.CI_RUNNER_LABEL }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # An issue is not decoration. This marker accepts a known gap rather than
  # declaring intent, so it needs an owner and a place to be revisited — the
  # same bar `shared-infra-exempt` and `remote-reusable-allowed` are held to.
  expect "…but not without an issue" "RUNNER5" "" allowed \
'on:
  pull_request:
jobs:
  # dynamic-runner-allowed(build): the label is a repository variable our admins scope
  build:
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || vars.CI_RUNNER_LABEL }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # …and not for a job it does not name. A bare or misdirected marker would
  # excuse whatever the file contains after the next change, including a job
  # added later that nobody weighed.
  expect "…and not for a job the marker does not name" "RUNNER5" "" allowed \
'on:
  pull_request:
jobs:
  # dynamic-runner-allowed(lint, #1): the label is a repository variable our admins scope
  build:
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || vars.CI_RUNNER_LABEL }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

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

  # ...and declaring it clears it. The fleet calls one shared reusable workflow
  # on purpose, so "undecidable" has to be declarable or the only way past this
  # check is to vendor the callee — which is what the fleet exists not to do.
  expect "a declared remote reusable workflow is accepted" "" "" blocked \
'on: [push]
jobs:
  call:
    # remote-reusable-allowed(owner/repo/.github/workflows/ci.yml, #4141): a human read the callee and accepted its runner scope
    uses: owner/repo/.github/workflows/ci.yml@11bd71901bbe5b1630ceea73d27597364c9af683'

  # The ref is deliberately not part of the marker: a pin bump does not change
  # what this gate can read. Asserted, so the omission stays a decision.
  expect "the declaration survives a ref bump" "" "" blocked \
'on: [push]
jobs:
  call:
    # remote-reusable-allowed(owner/repo/.github/workflows/ci.yml, #4141): unchanged across the bump below
    uses: owner/repo/.github/workflows/ci.yml@v9'

  # The callee IS the scope. A marker earned by reading one workflow must not
  # silently cover the next `uses:` somebody points at a different one.
  expect "a declaration for another callee excuses nothing" "RUNNER7" "" blocked \
'on: [push]
jobs:
  call:
    # remote-reusable-allowed(owner/repo/.github/workflows/other.yml, #4141): a different workflow entirely
    uses: owner/repo/.github/workflows/ci.yml@v9'

  # Every element of the grammar carries weight, so each is proven to be load-
  # bearing on its own. No issue: the acceptance has nowhere to be recorded and
  # nobody to revisit it. No reason: a waiver wearing a declaration's shape.
  expect "a declaration with no issue is not one" "RUNNER7" "" blocked \
'on: [push]
jobs:
  call:
    # remote-reusable-allowed(owner/repo/.github/workflows/ci.yml): reviewed, honest
    uses: owner/repo/.github/workflows/ci.yml@v9'

  expect "a declaration with no reason is not one" "RUNNER7" "" blocked \
'on: [push]
jobs:
  call:
    # remote-reusable-allowed(owner/repo/.github/workflows/ci.yml, #4141):
    uses: owner/repo/.github/workflows/ci.yml@v9'

  # And it must be a comment. The string is what a job would echo while doing
  # exactly the thing the marker claims was reviewed.
  expect "the marker in a run: step is not a declaration" "RUNNER7" "" blocked \
'on: [push]
jobs:
  note:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps: [{run: "echo remote-reusable-allowed(owner/repo/.github/workflows/ci.yml, #4141): x"}]
  call:
    uses: owner/repo/.github/workflows/ci.yml@v9'

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

  # --- RUNNER8: containers on a Windows pool ---------------------------------
  # The pool has no container runtime and never will (§4 of the ADR): the build
  # it exists for needs the host's Win32 surface. `Windows` is capitalised here
  # on purpose — GitHub does not distinguish the spellings and neither may this.
  expect "container: on a Windows pool label" "RUNNER8" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    container: mcr.microsoft.com/windows/servercore:ltsc2022
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # The one that fails at "Initialize containers" before a single step runs.
  expect "services: on a Windows pool label" "RUNNER8" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, windows, gcp, ExampleRepo]
    timeout-minutes: 30
    services:
      db:
        image: postgres:16
    steps: [{run: "true"}]'

  expect "both keys are one finding" "RUNNER8" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, windows, gcp, ExampleRepo]
    container: {image: node:20}
    timeout-minutes: 30
    services:
      db:
        image: postgres:16
    steps: [{run: "true"}]'

  # The rule is scoped to the LABEL, not to the key. On the Linux pool a
  # container is how the pool is meant to be used, and a gate that refused it
  # would be a gate the fleet's own consumers turn off. This fixture is the one
  # that fails if the Windows label set ever widens.
  expect "container: on a Linux pool is the intended usage" "" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    container: node:20
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A GitHub-hosted Windows image is not this fleet, and it does run containers.
  expect "container: on a hosted Windows image is not this pool" "" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: windows-2022
    container: mcr.microsoft.com/windows/servercore:ltsc2022
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # …and a Windows pool job that asks for no container is simply clean, so the
  # rule is not "the Windows label is suspicious".
  expect "a Windows pool job with neither key is clean" "" "" blocked \
'on: [push]
jobs:
  build:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A matrix decides the pool; it does not decide whether the job runs in a
  # container. The Windows leg is refused and the Linux leg is not, from one
  # job-level `container:`.
  expect "one Windows leg of a matrix is enough" "RUNNER8" "" blocked \
'on: [push]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    container: node:20
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: win, runs_on: '"'"'["self-hosted", "windows", "gcp", "ExampleRepo"]'"'"'}
          - {name: lin, runs_on: '"'"'["self-hosted", "linux", "gcp", "ExampleRepo"]'"'"'}
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

  # The same pair, judged the way the usage line documents: repository-relative
  # paths. Reachability keyed the caller by the string it was handed and the
  # callee by an absolute path it resolved itself, so the two never compared
  # equal and the whole computation silently produced nothing — a fixture that
  # only ever passed absolute paths could not see it.
  expect_pair_rel() {
    local name="$1" want="$2" caller_body="$3" callee_body="$4"
    local got out_text dir="$tmp/pairrel"
    rm -rf "$dir"; mkdir -p "$dir/.github/workflows"
    printf '%s\n' "$caller_body" > "$dir/.github/workflows/caller.yml"
    printf '%s\n' "$callee_body" > "$dir/.github/workflows/callee.yml"
    out_text="$(fail=0
      cd "$dir" || exit 1
      compute_reachable .github/workflows/caller.yml .github/workflows/callee.yml
      check_file .github/workflows/caller.yml "" allowed
      check_file .github/workflows/callee.yml "" allowed 2>&1)"
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

  expect_pair_rel "reachability holds when the paths are relative" "RUNNER4" \
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

  # A guard on the CALLING job is a guard on everything that job reaches, so the
  # callee is not asked to repeat a condition its own file has no context for.
  expect_pair "a guard on the calling job covers the callee" "" \
'on:
  pull_request:
jobs:
  call:
    if: github.event.pull_request.head.repo.fork == false
    uses: ./.github/workflows/callee.yml' \
'on:
  workflow_call:
jobs:
  build:
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

  # --- RUNNER9/10/11: one host, one stack -------------------------------------
  #
  # `ALLOW_DYNAMIC=1` throughout, and `--forks=blocked`, so each fixture asserts
  # the shared-infrastructure ids alone. The anchor idiom IS an expression, so
  # RUNNER5 fires on every correct consumer here; carrying it in every expected
  # set would let these fixtures keep agreeing with a gate that had stopped
  # reading anything else. RUNNER5's own behaviour is fixtured above.
  expect_si() {
    local name="$1" want="$2" body="$3"
    local got out_text
    printf '%s\n' "$body" > "$tmp/si.yml"
    out_text="$(fail=0; ALLOW_DYNAMIC=1; SHARED_INFRA=1; SHARED_INFRA_OWNERS=""
      check_file "$tmp/si.yml" "" blocked
      shared_infra_owner_verdict 2>&1)"
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

  # The shape rule 1 asks for: one job brings the stack up on whatever host it
  # landed on and publishes that host, and everything else resolves its pool
  # from that output instead of naming the pool again.
  expect_si "an anchor and a consumer that resolves its pool from it" "" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]
  test:
    needs: [anchor]
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # And the failure it asks about. `lint` names the pool directly, so GitHub may
  # place it on any free agent of that pool — a second host, in a run whose
  # database exists on the first one only.
  expect_si "a second job naming the pool directly is a second host" "RUNNER9" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]
  test:
    needs: [anchor]
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]
  lint:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # The fleet's fork-routing idiom wraps the resolution rather than replacing
  # it, and it is the spelling every consumer in a public repository writes. An
  # anchored match on `fromJSON(...)` read it as unpinned and reported the one
  # workflow shape that had got this right.
  expect_si "the fork-routing idiom still counts as pinned" "" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]
  test:
    needs: [anchor]
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A stack brought up by a `run:` step is invisible to YAML, so the marker is
  # the only way to say "this job is the anchor" — and it makes that job an
  # anchor for the graph, not merely silent about itself.
  expect_si "the owner marker declares an anchor a reader cannot see" "" \
'# shared-infra-owner(anchor): brings up the compose stack in a run step
on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    steps: [{id: pin, run: "docker compose up -d"}]'

  # The escape hatch, in RUNNER7's shape: beside the job, naming the job, with
  # an issue. One naming a DIFFERENT job does not excuse this one — an exemption
  # that covered whatever the file happened to contain would be un-reviewable.
  expect_si "a declared exemption is accepted" "" \
'# shared-infra-exempt(lint, #248): runs on the arm pool, touches no database
on: [pull_request]
jobs:
  lint:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect_si "an exemption naming another job does not cover this one" "RUNNER9" \
'# shared-infra-exempt(other, #248): not this job
on: [pull_request]
jobs:
  lint:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # Rule 1's exception. A Windows job IS a second host, on purpose, and reaches
  # the stack across the band — so it is never asked to pin.
  expect_si "a Windows job is a second host by design" "" \
'on: [pull_request]
jobs:
  win:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # …but it must reach the stack at the LINUX host's address. `localhost` on a
  # band port is the Windows machine, where nothing is listening: a refusal or a
  # hang, in a job whose code is right everywhere else. Read from the whole job
  # rather than from `run:` alone, because this is the shape the mistake takes.
  expect_si "a Windows job dialling localhost on a band port" "RUNNER11" \
'on: [pull_request]
jobs:
  win:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    timeout-minutes: 30
    env:
      DATABASE_URL: "postgres://ci@localhost:35100/app"
    steps: [{run: "true"}]'

  # A port outside the band is a service the job started itself, which is fine.
  expect_si "localhost outside the band is the job's own service" "" \
'on: [pull_request]
jobs:
  win:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "curl http://localhost:8080/health"}]'

  # Off unless asked for. The fixture that proves the opt-in is the one that
  # would otherwise be loudest.
  expect "the shared-infra rules are silent without the flag" "" "" blocked \
'on: [pull_request]
jobs:
  lint:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # RUNNER10 needs two files: "one stack per run" is a property of the RUN, and
  # a run spans every workflow the event triggers. One owner per file is exactly
  # the arrangement a per-file count reads as clean.
  expect_si_pair() {
    local name="$1" want="$2" a_body="$3" b_body="$4"
    local got out_text
    printf '%s\n' "$a_body" > "$tmp/si_a.yml"
    printf '%s\n' "$b_body" > "$tmp/si_b.yml"
    out_text="$(fail=0; ALLOW_DYNAMIC=1; SHARED_INFRA=1; SHARED_INFRA_OWNERS=""
      check_file "$tmp/si_a.yml" "" blocked
      check_file "$tmp/si_b.yml" "" blocked
      shared_infra_owner_verdict 2>&1)"
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

  expect_si_pair "two workflows each bringing up a stack is two stacks" "RUNNER10" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    services:
      db: {image: "postgres:16"}
    steps: [{run: "true"}]' \
'on: [pull_request]
jobs:
  anchor2:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    services:
      db: {image: "postgres:16"}
    steps: [{run: "true"}]'

  # …and one owner beside a consumer in another file is the arrangement the rule
  # wants, so the count is not merely "more than one job mentions a database".
  expect_si_pair "one owner across two workflows is the point" "" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]' \
'on: [pull_request]
jobs:
  test:
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # Uppercase is the same mistake. A gate that reads `localhost` and not
  # `LOCALHOST` reports the job clean, and the job still cannot reach the stack.
  expect_si "an uppercase band host is the same Windows mistake" "RUNNER11" \
'on: [pull_request]
jobs:
  win:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    timeout-minutes: 30
    steps:
      - run: psql postgres://ci@LOCALHOST:35100/app'

  # A six-digit port is not a band port. Without the trailing guard the first
  # five digits match, and the job is reported for a mistake it did not make.
  expect_si "a longer port that starts with a band port is not one" "" \
'on: [pull_request]
jobs:
  win:
    runs-on: [self-hosted, Windows, gcp, ExampleRepo]
    timeout-minutes: 30
    steps: [{run: "curl http://localhost:351000/health"}]'

  # The anchor reference beside a literal pool. This resolves to the POOL on
  # every run where the anchor was skipped or failed before publishing — the
  # second host RUNNER9 exists to stop, wearing the shape of the fix. Only a
  # GitHub-hosted image is allowed beside the reference, because that is the
  # fleet's fork-routing idiom.
  expect_si "a pool literal beside the anchor reference is not a pin" "RUNNER9" \
'on: [pull_request]
jobs:
  test:
    runs-on: ${{ needs.anchor.outputs.runs-on || '"'"'ExampleRepo'"'"' }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  expect_si "the fork-routing fallback to a hosted image still pins" "" \
'on: [pull_request]
jobs:
  test:
    runs-on: ${{ github.event.pull_request.head.repo.fork && '"'"'ubuntu-latest'"'"' || fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A quoted string is not automatically a candidate label. Here it is an
  # argument to a condition and can never be what `runs-on` resolves to, so
  # reporting it would fail the guard a careful author wrote — which is the
  # false positive that teaches a repository to pass `--allow-dynamic-runner`
  # and lose the rule entirely.
  expect_si "a literal inside a condition is not a fallback" "" \
'on: [pull_request]
jobs:
  test:
    runs-on: ${{ contains(github.ref, '"'"'main'"'"') && fromJSON(needs.anchor.outputs.runs-on) || fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # The literal that opens the expression, which no operator precedes. A
  # non-empty string short-circuits before the reference is read, so this is
  # the pool on every run, not just on the runs where the anchor went missing.
  expect_si "a pool literal ahead of the anchor reference is not a pin" "RUNNER9" \
'on: [pull_request]
jobs:
  test:
    runs-on: ${{ '"'"'ExampleRepo'"'"' || fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]'

  # A marker inside a `run: |` block is shell, not a declaration. A repository
  # could exempt a job by echoing the string, and would not have to mean to.
  expect_si "an exemption echoed inside a run block exempts nothing" "RUNNER9" \
'on: [pull_request]
jobs:
  test:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps:
      - run: |
          # shared-infra-exempt(test, #1): echoed, not declared
          echo hi'

  # The same bypass, reachable by adding a comment. `run: | # note` is a block
  # scalar too, and a reader that only recognises an indicator at end of line
  # puts the whole body back in the comment view.
  expect_si "an exemption echoed inside a commented block scalar exempts nothing" "RUNNER9" \
'on: [pull_request]
jobs:
  test:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    steps:
      - run: | # a trailing comment is legal after the indicator
          # shared-infra-exempt(test, #1): echoed, not declared
          echo hi'

  # RUNNER10 counts INVOCATIONS, not definitions. A reusable workflow with one
  # owner job, called from two caller jobs, brings two stacks up in one run;
  # read as a file it is one owner and reads clean. Both files have to live
  # under a `.github/workflows` directory, because that is what a `./…` call
  # target is resolved against.
  expect_si_calls() {
    local name="$1" want="$2" caller_body="$3"
    local got out_text wf="$tmp/.github/workflows"
    mkdir -p "$wf"
    printf '%s\n' "$caller_body" > "$wf/caller.yml"
    cat > "$wf/reusable.yml" <<'YAML'
on: [workflow_call]
jobs:
  up:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    services:
      db: {image: "postgres:16"}
    steps: [{run: "true"}]
YAML
    out_text="$(fail=0; ALLOW_DYNAMIC=1; SHARED_INFRA=1; SHARED_INFRA_OWNERS=""
      compute_reachable "$wf/caller.yml" "$wf/reusable.yml" >/dev/null
      check_file "$wf/caller.yml" "" blocked
      check_file "$wf/reusable.yml" "" blocked
      shared_infra_owner_verdict 2>&1)"
    got="$(printf '%s\n' "$out_text" | sed -n 's/.*::error::\[\([A-Z0-9]*\)\].*/\1/p' | sort -u | tr '\n' ' ')"
    got="$(printf '%s' "$got" | sed 's/ *$//')"
    rm -rf "$wf"
    if [ "$got" != "$want" ]; then
      echo "FAIL $name: want ids [$want], got [$got]"
      printf '%s\n' "$out_text" | sed 's/^/      /'
      status=1
    else
      echo "ok   $name [$want]"
    fi
  }

  expect_si_calls "one owner called from two jobs is two stacks" "RUNNER10" \
'on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/reusable.yml
  b:
    uses: ./.github/workflows/reusable.yml'

  expect_si_calls "the same owner called once is one stack" "" \
'on: [pull_request]
jobs:
  a:
    uses: ./.github/workflows/reusable.yml'

  # A fork guard scopes RUNNER4 and nothing else. `fork == false` is precisely
  # the condition under which these calls DO run -- for every pull request the
  # repository opens against itself -- so a guarded callee takes part in the
  # run, and two invocations of it are two stacks. Read off the guard-aware
  # reachable set, the callee was not in a pull request at all and the whole
  # rule was skipped.
  expect_si_calls "a fork-guarded owner called twice is still two stacks" "RUNNER10" \
'on: [pull_request]
jobs:
  a:
    if: github.event.pull_request.head.repo.fork == false
    uses: ./.github/workflows/reusable.yml
  b:
    if: github.event.pull_request.head.repo.fork == false
    uses: ./.github/workflows/reusable.yml'


  # A runner GROUP names the pool as directly as a label does, and read as
  # neither a label nor an expression both of these fell out of the rules
  # entirely -- two stacks in one run, reported clean.
  expect_si "two group-selected owners are still two stacks" "RUNNER10" \
'on: [pull_request]
jobs:
  a:
    runs-on:
      group: fleet
    timeout-minutes: 30
    services:
      db: {image: "postgres:16"}
    steps: [{run: "true"}]
  b:
    runs-on:
      group: fleet
    timeout-minutes: 30
    services:
      db: {image: "postgres:16"}
    steps: [{run: "true"}]'

  # A repository with ONE fleet job. It publishes the host it landed on, and
  # there is no other job for it to pin to: it IS the anchor. The finding it
  # used to get could only be answered by making the job depend on itself.
  expect_si "the only fleet job in the file is the anchor" "" \
'on: [pull_request]
jobs:
  only:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    steps: [{id: pin, run: "true"}]'

  # ...and publishing outputs is not a licence to name the pool. A file where
  # something DOES resolve a pool from a `needs` output has an anchor already,
  # and a second job that publishes anything is just a second host.
  expect_si "a second publisher beside a real anchor is still a second host" "RUNNER9" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]
  test:
    needs: [anchor]
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps: [{run: "true"}]
  lint:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      whatever: ${{ steps.x.outputs.whatever }}
    steps: [{id: x, run: "true"}]'

  # The exemption names the YAML job id, which is the only id a workflow author
  # can write. A matrix leg is judged as the synthetic `suite~leg1`, and a
  # marker matched against THAT could never be written at all -- so every
  # matrix-selected pool was unexemptable.
  expect_si "an exemption covers the matrix legs of the job it names" "" \
'# shared-infra-exempt(suite, #248): each leg is its own pool, by design
on: [pull_request]
jobs:
  suite:
    runs-on: ${{ fromJSON(matrix.suite.runs_on) }}
    timeout-minutes: 30
    strategy:
      matrix:
        suite:
          - {name: api, runs_on: '"'"'["self-hosted", "linux", "gcp", "ExampleRepo"]'"'"'}
          - {name: web, runs_on: '"'"'["self-hosted", "linux", "gcp", "OtherRepo"]'"'"'}
    steps: [{run: "true"}]'

  # RUNNER11 on a job whose OS is not decidable. Selecting the pool dynamically
  # names no `windows` label, so the Windows check was skipped -- on a job that
  # has ALSO declared, with the exemption, that it is deliberately a second
  # host. That is rule 3's Windows job, spelled the way this fleet spells
  # routing, and it was the one job the rule exists for.
  expect_si "a deliberate second host of unknown OS may not name localhost" "RUNNER11" \
'# shared-infra-exempt(win, #248): the Windows leg of this suite
on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]
  win:
    needs: [anchor]
    runs-on: ${{ fromJSON(needs.anchor.outputs.win-runs-on) }}
    timeout-minutes: 30
    steps:
      - run: psql postgres://ci@localhost:35100/app'

  # ...and the ordinary consumer, which is the same shape minus the exemption,
  # is untouched: it lands on the run's own Linux host and `localhost` there is
  # exactly right.
  expect_si "an ordinary consumer may name localhost" "" \
'on: [pull_request]
jobs:
  anchor:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 30
    outputs:
      runs-on: ${{ steps.pin.outputs.runs-on }}
    services:
      db: {image: "postgres:16"}
    steps: [{id: pin, run: "true"}]
  test:
    needs: [anchor]
    runs-on: ${{ fromJSON(needs.anchor.outputs.runs-on) }}
    timeout-minutes: 30
    steps:
      - run: psql postgres://ci@localhost:35100/app'

  # --- RUNNER12/13 fixtures: the merge-queue route ----------------------------
  #
  # The lane job runs on `ubuntu-latest`, so no other rule in this gate looks at
  # it. That is exactly why these two live here: it is the one job in the
  # repository that decides which pool every OTHER job claims.
  #
  # Written with DOUBLE-quoted shell strings, unlike every fixture above. A
  # GitHub expression quotes its own string literals with single quotes, and a
  # fixture that spelled them any other way would be testing this gate against a
  # syntax no real workflow can contain.

  local QGUARD="github.event.pull_request.head.repo.full_name == github.repository
             && github.event.pull_request.user.login == 'mergify[bot]'
             && startsWith(github.head_ref, 'mergify/merge-queue/')"

  expect "the routed lane job, written correctly" "" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ ($QGUARD)
            && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  # The whole of the vulnerability, and it is shorter than the correct version.
  # Green, working, and available to anybody willing to name a branch after the
  # queue -- a fork included.
  expect "routing on the branch prefix alone" "RUNNER12" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ startsWith(github.head_ref, 'mergify/merge-queue/')
            && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  # Half a guard. The head branch is proven to live in this repository, so no
  # fork reaches the pool -- but any member of the repository still takes it by
  # naming a branch, which is most of what the rule is for.
  expect "same-repo without the Mergify author" "RUNNER12" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ (github.event.pull_request.head.repo.full_name == github.repository
             && startsWith(github.head_ref, 'mergify/merge-queue/'))
            && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  # The mirror of the case above, and the one a reviewer waves through: the
  # author is proven, so the pull request really is Mergify's -- but nothing
  # says the head branch is not a fork's, and a fork can name a branch too.
  expect "the Mergify author without same-repo" "RUNNER12" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ (github.event.pull_request.user.login == 'mergify[bot]'
             && startsWith(github.head_ref, 'mergify/merge-queue/'))
            && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  # The queue arm carries the pull-request pool's label AS WELL AS its own. It
  # reads like belt and braces and it undoes the split: a job asking for
  # `ExampleRepo` matches these runners too, so ordinary pull requests are
  # scheduled onto the hosts reserved for the queue.
  expect "the queue arm is a superset of the CI arm" "RUNNER13" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ ($QGUARD)
            && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\",\"ExampleRepo-merge-queue\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  # The other direction, and the quieter one: an arm naming no scope label is
  # not a pool, it is every pool in the fleet.
  expect "an arm with no scope label is the whole fleet" "RUNNER13" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ ($QGUARD)
            && '[\"self-hosted\",\"linux\",\"gcp\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  # The fork idiom wraps the route, and its safe arm is a hosted image carrying
  # no scope label at all. Counted as a pool it would be the unscoped-fleet
  # finding above, so this fixture fails if `#ROUTEARM`s hosted/pool judgement
  # is ever dropped or re-derived in the shell.
  expect "a hosted fork arm is not a pool" "" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ github.event.pull_request.head.repo.fork
            && '[\"ubuntu-latest\"]'
            || (($QGUARD)
                && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
                || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]') }}
    steps: [{run: \"true\"}]"

  # Case is not a difference. GitHub does not distinguish `Linux` from `linux`,
  # and neither may this -- otherwise the two arms below read as two pools and
  # the superset that merges them goes unreported.
  expect "case does not make two pools" "RUNNER13" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ ($QGUARD)
            && '[\"self-hosted\",\"Linux\",\"gcp\",\"ExampleRepo\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"examplerepo\"]' }}
    steps: [{run: \"true\"}]"

  # A repository with no merge-queue pool never mentions the prefix, and none of
  # this applies to it. These two rules are opted into by the route EXISTING,
  # not by a flag -- a gate every consumer must configure is a gate several
  # consumers configure wrongly, which is the same reasoning as `--scope`.
  expect "no queue route, no queue rules" "" "" allowed \
"on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]'
    steps: [{run: \"true\"}]"

  # The same decision written inline in `runs-on`, by a repository small enough
  # not to have a lane job. RUNNER5 comes with it -- the runner IS dynamic -- and
  # RUNNER12 has to be reached past it rather than instead of it. `--forks=
  # blocked` only to keep RUNNER4 out of the assertion; it is not the subject.
  expect "the route written inline in runs-on" "RUNNER12 RUNNER5" "" blocked \
"on: [pull_request]
jobs:
  build:
    runs-on: >-
      \${{ fromJSON(startsWith(github.head_ref, 'mergify/merge-queue/')
          && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
          || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]') }}
    timeout-minutes: 30
    steps: [{run: \"true\"}]"

  # --- RUNNER14 fixtures: the job that took no route --------------------------
  #
  # A PAIR, always, because that is the shape the rule exists for: the route is
  # in the workflow somebody migrated and the literal pool is in the one they
  # did not, and each file read alone is clean. The pair is also what proves the
  # verdict does not depend on the order -- `expect_mq_pair` is called with the
  # route second as often as first.
  expect_mq_pair() {
    local name="$1" want="$2" a_body="$3" b_body="$4"
    local got out_text
    printf '%s\n' "$a_body" > "$tmp/mq_a.yml"
    printf '%s\n' "$b_body" > "$tmp/mq_b.yml"
    out_text="$(fail=0; ALLOW_DYNAMIC=1; QUEUE_ROUTED=0; QUEUE_UNROUTED=""
      check_file "$tmp/mq_a.yml" "" blocked
      check_file "$tmp/mq_b.yml" "" blocked
      merge_queue_route_verdict 2>&1)"
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

  local MQ_LANE="on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      runner: >-
        \${{ ($QGUARD)
            && '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo-merge-queue\"]'
            || '[\"self-hosted\",\"linux\",\"gcp\",\"ExampleRepo\"]' }}
    steps: [{run: \"true\"}]"

  expect_mq_pair "a second workflow that named the pool sits out the route" "RUNNER14" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  # Order is not evidence. The same two files, read the other way round, are the
  # same repository -- and this is the ordering a `find | sort` actually
  # produces for a policy check named before its lane.
  expect_mq_pair "…and the same pair with the route read last" "RUNNER14" \
'on: [pull_request]
jobs:
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]' \
"$MQ_LANE"

  # The fix the diagnostic recommends, asserted as clean: resolving the pool
  # from the routing job's output is what taking the route looks like.
  expect_mq_pair "a job that resolves its pool from the lane is clean" "" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  policy:
    needs: lane
    runs-on: ${{ fromJSON(needs.lane.outputs.runner) }}
    timeout-minutes: 10
    steps: [{run: "true"}]'

  # No route in the repository, no rule. A repository with one pool names it
  # literally in every workflow and is not being asked to change.
  expect_mq_pair "a repository with no route is never asked" "" \
'on: [pull_request]
jobs:
  lane:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps: [{run: "true"}]' \
'on: [pull_request]
jobs:
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  # A job that cannot run on a queue draft has no route to take.
  expect_mq_pair "a job the queue drafts never reach needs no route" "" \
"$MQ_LANE" \
"on: [pull_request]
jobs:
  policy:
    if: \"!startsWith(github.head_ref, 'mergify/merge-queue/')\"
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: \"true\"}]"

  # …and the guard is read as a Boolean tree, not as a substring: the same test
  # as one arm of an `||` does NOT keep the job off a draft, because the other
  # arm runs it there.
  expect_mq_pair "the skip has to actually skip" "RUNNER14" \
"$MQ_LANE" \
"on: [pull_request]
jobs:
  policy:
    if: \"always() || !startsWith(github.head_ref, 'mergify/merge-queue/')\"
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: \"true\"}]"

  # The declared exemption, and then the two ways of writing one that is not a
  # declaration at all.
  expect_mq_pair "a declared exemption is accepted" "" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  # merge-queue-route-exempt(policy, #4242): watches the pull-request pool
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  expect_mq_pair "an exemption with no issue is not one" "RUNNER14" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  # merge-queue-route-exempt(policy): because
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  expect_mq_pair "an exemption naming another job does not cover this one" "RUNNER14" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  # merge-queue-route-exempt(other, #4242): a different job entirely
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  # A marker echoed by a step is shell, not a declaration -- the same bypass
  # `comment_view` closes for every other marker in this file.
  expect_mq_pair "a marker inside a run: block declares nothing" "RUNNER14" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  policy:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps:
      - run: |
          # merge-queue-route-exempt(policy, #4242): not a comment, a script
          true'

  # A GitHub-hosted job never claims a pool, so the rule has nothing to say
  # about it -- and a repository routing between two pools still runs plenty of
  # hosted jobs.
  expect_mq_pair "a hosted job is not a pool job" "" \
"$MQ_LANE" \
'on: [pull_request]
jobs:
  policy:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps: [{run: "true"}]'

  # A workflow with no pull-request trigger is not part of a queue draft at all.
  expect_mq_pair "a push-only workflow is out of scope" "" \
"$MQ_LANE" \
'on:
  push:
    branches: [main]
jobs:
  publish:
    runs-on: [self-hosted, linux, gcp, ExampleRepo]
    timeout-minutes: 10
    steps: [{run: "true"}]'

  rm -rf "$tmp"
  return "$status"
}

# --- entry point -------------------------------------------------------------
# SC2031: `fail` is read here after `selftest`'s subshells wrote their own copies
# of it, which is exactly the intent — a fixture's planted failure must not reach
# this exit status. On the real path `check_file` runs in THIS shell, so the
# value read here is the one its `err()` calls set.
# The RUNNER10 verdict, which is the one that cannot be reached from inside
# check_file: it is a count over the whole set. A function rather than a block
# in main() so the fixtures can drive it over two files, which is the shape it
# exists to catch and the one a single-file fixture cannot express.
# SC2031: same story as main() below -- the selftest's fixtures run check_file in
# subshells that write their own copies of these, and the real path sets them in
# THIS shell, which is the copy this verdict reads.
# shellcheck disable=SC2031
shared_infra_owner_verdict() {
  [ "$SHARED_INFRA" -eq 1 ] || return 0
  local owners
  owners="$(printf '%s' "$SHARED_INFRA_OWNERS" | grep -c .)"
  [ "$owners" -gt 1 ] || return 0
  # Every owner is named, not only the surplus one: which of two is the mistake
  # is a question the repository answers, not this gate.
  err RUNNER10 "$owners jobs bring up shared infrastructure in this repository's pull-request workflows, and a pull request gets ONE stack: $(printf '%s' "$SHARED_INFRA_OWNERS" | paste -sd';' -) — the surplus owners should consume the anchor's stack instead (or declare '# shared-infra-exempt(<job>, #<issue>): <reason>' beside the one that genuinely needs its own)"
}

# The RUNNER14 verdict, deferred for the same reason and read the same way. The
# order the files happened to be given must not decide anything: a repository
# whose route lives in the LAST file read is the same repository as one whose
# route is in the first.
# shellcheck disable=SC2031
merge_queue_route_verdict() {
  [ "$QUEUE_ROUTED" -eq 1 ] || return 0
  local file job labels rel
  while IFS=$'\t' read -r file job labels; do
    [ -n "$file" ] || continue
    # Read now rather than at collection time: the marker is a property of the
    # file, and nothing about it changes between the two moments -- but the
    # grep is only paid for a repository that actually has a route.
    merge_queue_route_declared "$file" "$job" && continue
    rel="${file#"$REPO_ROOT"/}"
    err RUNNER14 "$rel: job '$job' runs-on [$labels] literally, in a repository whose workflows route between a pull-request pool and a merge-queue pool — so on every 'mergify/merge-queue/<sha>' draft this job queues against the pull-request pool, which is exactly the pool the queued pull requests are filling, while the merge-queue pool it should be using sits idle. Resolve the pool from the routing job's output (runs-on: \${{ fromJSON(needs.<lane>.outputs.runner) }}), or declare '# merge-queue-route-exempt($job, #<issue>): <reason>' beside it"
  done <<EOF
$(printf '%s' "$QUEUE_UNROUTED" | grep -v '^$')
EOF
}

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
      --shared-infra) SHARED_INFRA=1 ;;
      -*)         echo "::error::[RUNNER0] unknown option: $arg"; return 1 ;;
      *)          files+=("$arg") ;;
    esac
  done

  case "$forks" in
    allowed|blocked) ;;
    *) echo "::error::[RUNNER0] --forks must be 'allowed' or 'blocked', got '$forks'"; return 1 ;;
  esac

  if ! printf '%s' "$MAX_TIMEOUT" | grep -cE '^[1-9][0-9]*$' >/dev/null; then
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

  # RUNNER10 is the one verdict that cannot be reached inside check_file: it is
  # a count over the whole set, so it is reported here, once, naming every
  # owner rather than only the surplus one — which of two owners is the mistake
  # is a question the repository answers, not this gate.
  shared_infra_owner_verdict

  # RUNNER14 is the other one, and for a related reason: whether the repository
  # routes at all is a fact about the SET, and the file that proves it may be
  # the last one read.
  merge_queue_route_verdict

  if [ "$fail" -eq 0 ]; then
    echo "runner policy clean: ${#files[@]} workflow file(s)"
  fi
  return "$fail"
}

main "$@"
