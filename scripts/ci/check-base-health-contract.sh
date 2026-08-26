#!/usr/bin/env bash
# =============================================================================
# check-base-health-contract.sh — the base-health names, joined to the jobs
#
# USAGE
#   bash scripts/ci/check-base-health-contract.sh --selftest
#   bash scripts/ci/check-base-health-contract.sh [--lane=<path>] [--workflows=<dir>]
#
# WHAT IT PROTECTS
#   The merge lane's base-health gate reads a list of CHECK-RUN NAMES on the tip
#   of the base: it refuses to merge onto a tip that is red and, since v5.67.0,
#   waits for a tip that has not answered yet. Every one of those names is a
#   plain string in the caller's `merge-lane.yml`, matched literally.
#
#   A name that matches nothing counts as MISSING, and missing does not halt.
#   So a typo, or renaming the job that answers, does not break the lane and
#   does not fail anything: it SILENTLY DISARMS the gate, and the repository
#   goes back to merging onto an unverified base while the configuration still
#   claims otherwise. That is the failure this exists to make loud, and it is
#   the same shape the docs-pin check covers for `uses:` — a contract that spans
#   two files with nothing joining them.
#
# THE DEFAULT IS THE DANGEROUS CASE, NOT THE EXEMPT ONE
#   `base-health-checks` is OPTIONAL. Left unset the lane reads `required-checks`
#   on the base tip instead (merge-lane.sh: `BASE_HEALTH=("${REQUIRED[@]}")`),
#   so a caller that never mentions base health still arms the gate — against a
#   list written for pull requests. A required check that runs only on
#   `pull_request` publishes NOTHING on the tip, which is the same silent
#   disarm arrived at without anyone choosing it. This reads the fallback
#   exactly as the lane does; treating an absent input as "nothing to check"
#   would exempt precisely the callers most likely to be wrong.
#
# WHAT IT ASSERTS
#   For every name in the effective list, some workflow in `.github/workflows`
#   both (a) declares a job whose reported check-run name equals it — the job's
#   `name:` where it has one, otherwise its key — and (b) triggers on `push` to
#   the lane's base. Both halves matter: a job with the right name that never
#   runs on the base publishes nothing on the tip, which reads as MISSING all
#   the same.
#
# FAILING CLOSED
#   An empty extraction is a hard error, never a pass. A reader that stops
#   finding the block reports "every name accounted for" over a list of nothing,
#   which is precisely the vacuous green this gate is here to prevent.
# =============================================================================
set -euo pipefail

LANE=".github/workflows/merge-lane-self.yml"
WFDIR=".github/workflows"
SELFTEST=0

for arg in "$@"; do
  case "$arg" in
    --selftest) SELFTEST=1 ;;
    --lane=*) LANE="${arg#*=}" ;;
    --workflows=*) WFDIR="${arg#*=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 2; }

# The document Actions LOADS, not a line-walk over it: both check lists are
# block scalars, and a reader that mis-handles the indentation returns a SHORT
# list — this gate reporting clean over names it never checked.
contract_report() { # $1 = lane file, $2 = workflow dir
  python3 - "$1" "$2" <<'PY'
import os, sys, yaml

lane_path, wfdir = sys.argv[1], sys.argv[2]
lane = yaml.safe_load(open(lane_path, encoding="utf-8")) or {}

def lines(v):
    return [n.strip() for n in str(v or "").splitlines() if n.strip()]

explicit, required, base = [], [], None
for job in (lane.get("jobs") or {}).values():
    if not isinstance(job, dict) or "merge-lane.yml" not in str(job.get("uses") or ""):
        continue
    with_ = job.get("with") or {}
    explicit += lines(with_.get("base-health-checks"))
    required += lines(with_.get("required-checks"))
    base = base or str(with_.get("base") or "").strip() or None

# The lane's own precedence, mirrored: the explicit list when there is one,
# otherwise the required list. Never the union — that is neither behaviour.
source = "base-health-checks" if explicit else "required-checks (base-health-checks unset)"
names = sorted(set(explicit or required))
if not names:
    print("NONE")
    raise SystemExit(0)
base = base or "main"

# `on` is the YAML 1.1 boolean True once loaded, which is why this reads both.
def triggers(doc):
    return doc.get("on") if "on" in doc else doc.get(True) or {}

def pushes_to(doc, branch):
    on = triggers(doc)
    if isinstance(on, str):
        return on == "push"
    if isinstance(on, list):
        return "push" in on
    push = (on or {}).get("push")
    if push is None:
        return False
    if not isinstance(push, dict):
        return True          # `push:` with no filter is every branch
    branches = push.get("branches")
    return branches is None or branch in [str(b) for b in branches]

published = {}
for entry in sorted(os.listdir(wfdir)):
    if not entry.endswith((".yml", ".yaml")):
        continue
    try:
        doc = yaml.safe_load(open(os.path.join(wfdir, entry), encoding="utf-8")) or {}
    except yaml.YAMLError:
        continue
    if not isinstance(doc, dict):
        continue
    on_base = pushes_to(doc, base)
    for key, job in (doc.get("jobs") or {}).items():
        if not isinstance(job, dict):
            continue
        published.setdefault(str(job.get("name") or key), []).append((entry, on_base))

print("BASE\t%s\t%s" % (base, source))
for name in names:
    where = published.get(name)
    if not where:
        print("MISSING\t%s" % name)
    elif not any(on_base for _, on_base in where):
        print("NOTONBASE\t%s\t%s" % (name, ",".join(f for f, _ in where)))
    else:
        print("OK\t%s\t%s" % (name, ",".join(f for f, ob in where if ob)))
PY
}

verdict() { # $1 = lane file, $2 = workflow dir; prints the report, returns 1 on a finding
  local report status=0
  report="$(contract_report "$1" "$2")" || fail "could not read $1"
  if [ "$report" = "NONE" ]; then
    echo "OK — $1 names no checks at all; there is no contract to join."
    return 0
  fi
  [ -n "$report" ] || fail "extracted NOTHING from $1 — that is this gate's own
  vacuous-pass shape, not a clean repository. Fix the reader."
  local kind name where
  while IFS=$'\t' read -r kind name where; do
    case "$kind" in
      BASE) echo "base: $name — reading $where" ;;
      OK) echo "  ok    $name — published by $where on the base" ;;
      MISSING)
        status=1
        echo "  FAIL  $name — no job in $2 reports a check-run by this name."
        echo "        A name that matches nothing counts as missing, and missing"
        echo "        does not halt the lane: this disarms the gate silently."
        ;;
      NOTONBASE)
        status=1
        echo "  FAIL  $name — declared by $where, but that workflow does not run"
        echo "        on a push to the base, so the name is never published on"
        echo "        the tip the gate reads."
        ;;
    esac
  done <<< "$report"
  return $status
}

if [ "$SELFTEST" -eq 1 ]; then
  python3 -c 'import yaml' 2>/dev/null ||
    fail "python3 with PyYAML is required (pip install pyyaml)"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/wf"

  cat > "$tmp/wf/merge-lane-self.yml" <<'YAML'
name: Merge lane
on:
  workflow_run:
    workflows: ["CI", "main-health"]
    types: [completed]
jobs:
  lane:
    uses: ./.github/workflows/merge-lane.yml
    with:
      base: main
      required-checks: |
        main-health
      base-health-checks: |
        main-health
YAML
  cat > "$tmp/wf/main-health.yml" <<'YAML'
name: main-health
on:
  push:
    branches: [main]
jobs:
  main-health:
    name: main-health
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YAML

  verdict "$tmp/wf/merge-lane-self.yml" "$tmp/wf" >/dev/null ||
    fail "selftest FAILED (must-be-quiet). A name published by a job that runs
  on a push to the base must pass."

  # MUTANT 1 — the rename. The job answers under a new name; the lane still
  # asks for the old one, which is the silent disarm.
  sed -i 's/^    name: main-health$/    name: base-health/' "$tmp/wf/main-health.yml"
  if verdict "$tmp/wf/merge-lane-self.yml" "$tmp/wf" >/dev/null 2>&1; then
    fail "selftest FAILED (must-fire, rename). Renaming the job away from the
  name the lane asks for must be a finding — that is the exact silent disarm."
  fi
  sed -i 's/^    name: base-health$/    name: main-health/' "$tmp/wf/main-health.yml"

  # MUTANT 2 — the right name on a workflow that never runs on the base. It
  # publishes nothing on the tip, which reads as missing all the same.
  sed -i 's/^  push:$/  pull_request:/; /^    branches: \[main\]$/d' "$tmp/wf/main-health.yml"
  if verdict "$tmp/wf/merge-lane-self.yml" "$tmp/wf" >/dev/null 2>&1; then
    fail "selftest FAILED (must-fire, not-on-base). A job with the right name
  that never runs on a push to the base publishes nothing on the tip."
  fi

  # MUTANT 3 — THE FALLBACK, and the reason it is a mutant rather than a
  # comment. Drop `base-health-checks` and the lane reads `required-checks` on
  # the tip instead. The workflow is still pull-request-only from mutant 2, so
  # the finding must survive the input disappearing; a reader that treats an
  # absent input as "nothing to check" goes quiet here and exempts every caller
  # that never opted in.
  python3 - "$tmp/wf/merge-lane-self.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
i = s.index("      base-health-checks:")
open(p, "w", encoding="utf-8").write(s[:i])
PY
  if verdict "$tmp/wf/merge-lane-self.yml" "$tmp/wf" >/dev/null 2>&1; then
    fail "selftest FAILED (must-fire, required-checks fallback). With
  base-health-checks unset the lane reads required-checks on the base tip, so
  this gate must read the same list rather than reporting nothing to check."
  fi

  echo "selftest OK — quiet on a joined contract; fires on a renamed job, on one"
  echo "that never runs on the base, and through the required-checks fallback."
  exit 0
fi

[ -f "$LANE" ] || fail "no such file: $LANE (run from the repository root)"
[ -d "$WFDIR" ] || fail "no such directory: $WFDIR"
python3 -c 'import yaml' 2>/dev/null ||
  fail "python3 with PyYAML is required to read $LANE (pip install pyyaml)"

verdict "$LANE" "$WFDIR"
