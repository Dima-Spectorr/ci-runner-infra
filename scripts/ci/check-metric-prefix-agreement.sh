#!/usr/bin/env bash
# =============================================================================
# check-metric-prefix-agreement.sh — one custom-metric prefix, or no autoscaling
#
# USAGE
#   bash scripts/ci/check-metric-prefix-agreement.sh --selftest
#   bash scripts/ci/check-metric-prefix-agreement.sh [--root=<repo root>]
#
# WHAT IT PROTECTS
#   The pool scales on ONE number: `<metric_prefix>/ci_demand`, written by the
#   controller and read by the hosts' regional autoscaler. The two live in
#   DIFFERENT Terraform modules, each with its own `metric_prefix` variable and
#   its own default, and a root may instantiate them independently — so nothing
#   in Terraform makes the writer and the reader agree.
#
#   When they disagree, nothing errors. The controller keeps publishing, the
#   autoscaler keeps evaluating, the MIG reports `targetSize 0` and
#   `isStable: true`, and the only trace is a status detail nobody reads:
#
#       MISSING_CUSTOM_METRIC_DATA_POINTS
#
#   In `ONLY_UP` mode a pool that starts at zero then stays at zero forever
#   while every job in the repository queues. Measured on 2026-08-26:
#   Telnet-Emulation had 0 registered runners and 8 queued jobs for hours with a
#   healthy controller publishing `ci_demand = 5` the whole time — into a prefix
#   its own autoscaler did not select. IntegrateIT had the same mismatch and
#   only looked fine because a `scalingSchedule` floor was holding hosts up:
#   scheduled capacity, never demand.
#
#   The alert policies are on the same fault line. They hardcode the prefix in
#   `scripts/ci/ensure-alert-policies.sh`, so the same divergence that stops the
#   scaling also silences `ci_poller_heartbeat` — the alert whose entire job is
#   to say the controller went quiet.
#
# WHAT IT ASSERTS
#   Four places name the prefix, and all four must be the same string:
#
#     1. modules/ci-runner-controller/variables.tf  — the WRITER's default
#     2. modules/ci-runner-host-pool/variables.tf   — the READER's default
#     3. controller-startup.sh `METRIC_PREFIX=${METRIC_PREFIX:-...}` — the
#        fallback that decides what gets written when metadata is absent, which
#        is exactly the case where nobody is watching
#     4. every `custom.googleapis.com/...` literal in ensure-alert-policies.sh
#
# FAILING CLOSED
#   Not finding a value is a hard error, never a pass. A reader that stops
#   matching reports "all four agree" over four empty strings, which is the
#   vacuous green this exists to prevent.
# =============================================================================
set -euo pipefail

ROOT="."
SELFTEST=0

for arg in "$@"; do
  case "$arg" in
    --selftest) SELFTEST=1 ;;
    --root=*) ROOT="${arg#*=}" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

CONTROLLER_VARS="modules/ci-runner-controller/variables.tf"
POOL_VARS="modules/ci-runner-host-pool/variables.tf"
STARTUP="modules/ci-runner-host-pool/scripts/controller-startup.sh"
ALERTS="scripts/ci/ensure-alert-policies.sh"

# The `default` line of a named Terraform variable block. Anchored on the block
# so a `default` belonging to some other variable in the same file cannot answer
# for this one.
tf_default() {
  local file="$1" var="$2" val
  val="$(awk -v want="variable \"$var\" {" '
    index($0, want) == 1 { inblock = 1; next }
    inblock && /^}/ { exit }
    inblock && $1 == "default" { print; exit }
  ' "$file" | sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/')"
  printf '%s' "$val"
}

fail() { echo "FAIL: $*" >&2; FAILED=1; }

check_root() {
  local root="$1"
  local ctl pool boot alert_prefixes
  FAILED=0

  for f in "$CONTROLLER_VARS" "$POOL_VARS" "$STARTUP" "$ALERTS"; do
    [ -f "$root/$f" ] || { echo "FAIL: missing $f — cannot compare what is not there" >&2; return 1; }
  done

  ctl="$(tf_default "$root/$CONTROLLER_VARS" metric_prefix)"
  pool="$(tf_default "$root/$POOL_VARS" metric_prefix)"
  boot="$(sed -nE 's/^METRIC_PREFIX=\$\{METRIC_PREFIX:-([^}]*)\}.*/\1/p' "$root/$STARTUP" | head -1)"

  # Every distinct prefix the alert policies select on. `sort -u` so the report
  # names the offender rather than a count.
  alert_prefixes="$(grep -oE 'custom\.googleapis\.com/[A-Za-z0-9_.-]+/' "$root/$ALERTS" | sed 's:/$::' | sort -u)"

  # Fail closed BEFORE comparing: three empty strings compare equal.
  [ -n "$ctl" ]  || { echo "FAIL: no metric_prefix default found in $CONTROLLER_VARS" >&2; return 1; }
  [ -n "$pool" ] || { echo "FAIL: no metric_prefix default found in $POOL_VARS" >&2; return 1; }
  [ -n "$boot" ] || { echo "FAIL: no METRIC_PREFIX fallback found in $STARTUP" >&2; return 1; }
  [ -n "$alert_prefixes" ] || { echo "FAIL: no custom.googleapis.com metric selected in $ALERTS" >&2; return 1; }

  echo "writer  $ctl   ($CONTROLLER_VARS)"
  echo "reader  $pool   ($POOL_VARS)"
  echo "boot    $boot   ($STARTUP)"

  if [ "$pool" != "$ctl" ]; then
    fail "the autoscaler reads '$pool/ci_demand' and the controller writes '$ctl/ci_demand'."
    echo "      The pool will sit at zero hosts, stable and green, while jobs queue." >&2
  fi
  if [ "$boot" != "$ctl" ]; then
    fail "controller-startup.sh falls back to '$boot' but the module supplies '$ctl'."
    echo "      A controller booted without the metadata key publishes where nobody reads." >&2
  fi

  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    echo "alert   $p   ($ALERTS)"
    if [ "$p" != "$ctl" ]; then
      fail "an alert policy selects '$p/...' but the fleet publishes '$ctl/...'."
      echo "      That alert can never fire — including the one for a silent controller." >&2
    fi
  done <<<"$alert_prefixes"

  [ "$FAILED" -eq 0 ] || return 1
  echo "ok — writer, reader, boot fallback and every alert policy name '$ctl'"
}

selftest() {
  local tmp status
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  seed() {
    rm -rf "$tmp/r"
    mkdir -p "$tmp/r/modules/ci-runner-controller" \
             "$tmp/r/modules/ci-runner-host-pool/scripts" \
             "$tmp/r/scripts/ci"
    cat >"$tmp/r/$CONTROLLER_VARS" <<'EOF'
variable "unrelated" {
  default = "custom.googleapis.com/decoy"
}

variable "metric_prefix" {
  type    = string
  default = "custom.googleapis.com/ci"
}
EOF
    cat >"$tmp/r/$POOL_VARS" <<'EOF'
variable "metric_prefix" {
  type    = string
  default = "custom.googleapis.com/ci"
}
EOF
    printf 'METRIC_PREFIX=${METRIC_PREFIX:-custom.googleapis.com/ci}\n' >"$tmp/r/$STARTUP"
    printf '"filter": "metric.type=\\"custom.googleapis.com/ci/ci_poller_heartbeat\\""\n' >"$tmp/r/$ALERTS"
  }

  run() { ( cd "$tmp/r" && bash "$SELF" --root=. ) >/dev/null 2>&1; }

  # CASE 0 — a repo where all four agree must be quiet. Without this the three
  # mutants below prove only that the script can fail.
  seed
  run || { echo "selftest: clean tree must pass" >&2; return 1; }

  # MUTANT 1 — THE OUTAGE. The reader's default drifts from the writer's. This
  # is the exact shape that took Telnet-Emulation to zero runners: no error
  # anywhere, an autoscaler selecting a prefix nobody writes.
  seed
  sed -i 's|custom.googleapis.com/ci|custom.googleapis.com/github|' "$tmp/r/$POOL_VARS"
  run && { echo "selftest: a reader/writer prefix split must fail" >&2; return 1; }

  # MUTANT 2 — the boot fallback drifts. Only bites a controller that comes up
  # without the metadata key, which is the case no one is watching.
  seed
  printf 'METRIC_PREFIX=${METRIC_PREFIX:-custom.googleapis.com/github}\n' >"$tmp/r/$STARTUP"
  run && { echo "selftest: a drifted boot fallback must fail" >&2; return 1; }

  # MUTANT 3 — an alert policy left on the old prefix. Scaling still works, so
  # nothing looks wrong; the alert simply never fires again.
  seed
  printf '"filter": "metric.type=\\"custom.googleapis.com/github/ci_poller_heartbeat\\""\n' >"$tmp/r/$ALERTS"
  run && { echo "selftest: an alert policy on a stale prefix must fail" >&2; return 1; }

  # MUTANT 4 — the reader's default disappears entirely. Must be a hard error,
  # not a pass: an empty string compares equal to another empty string.
  seed
  printf 'variable "metric_prefix" {\n  type = string\n}\n' >"$tmp/r/$POOL_VARS"
  run && { echo "selftest: a missing default must fail closed, not pass" >&2; return 1; }

  echo "selftest OK — quiet when all four agree; fires on a reader/writer split,"
  echo "a drifted boot fallback, a stale alert policy, and a missing default."
}

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

if [ "$SELFTEST" -eq 1 ]; then
  selftest
  exit 0
fi

cd "$ROOT"
check_root .
