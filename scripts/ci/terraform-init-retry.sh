#!/usr/bin/env bash
# =============================================================================
# terraform-init-retry.sh — `terraform init` for a module, retried when, and
# only when, the failure came from the network rather than the configuration
#
# USAGE
#   bash scripts/ci/terraform-init-retry.sh <module-dir>
#   bash scripts/ci/terraform-init-retry.sh --selftest
#
# THE HAZARD
#   `validate every module standalone` in ci.yml loops over `modules/*/` and
#   runs `terraform init -backend=false` once per module under `set -euo
#   pipefail`. Every module is an independent chance to hit a transient
#   registry reset, so the job's flake rate is roughly the per-call rate TIMES
#   the module count, and it grows every time a module is added. Observed on
#   #264, run 32607485135:
#
#     Error: Failed to query available provider packages
#       could not retrieve the list of available versions for provider
#       hashicorp/google: could not connect to registry.terraform.io: ...
#       read: connection reset by peer
#
#   The pull request was clean. It lands where it costs most: this is a
#   required check, so the reset dequeues the pull request and everything
#   behind it pays the CI time again (#271).
#
# WHY THIS IS NOT `for i in 1 2 3`
#   A blind retry hides a real failure behind a delay, and a repository whose
#   gates retry everything eventually retries a genuine breakage into a
#   timeout. So a failure is CLASSIFIED first:
#
#     * a PERMANENT failure — a version constraint nothing satisfies, a
#       provider that does not exist, a syntax error — fails on the first
#       attempt. Retrying it changes nothing except how long the reviewer
#       waits for the same message.
#     * anything else is retried, up to `ATTEMPTS`, with a backoff. Unknown
#       failures are retried rather than failed fast on purpose: the cost of
#       retrying a real error is the backoff, and it still fails; the cost of
#       failing fast on an unrecognised transient is the flake this file
#       exists to remove.
#
#   `terraform validate` is deliberately NOT wrapped. It is offline, so its
#   failures are always real, and retrying it would hide genuine breakage.
#
# CONFIGURATION (environment, all with CI-appropriate defaults)
#   TF_BIN     the terraform binary                    (default: terraform)
#   ATTEMPTS   total attempts, including the first     (default: 3)
#   BACKOFF    seconds before the 2nd attempt; doubles (default: 5)
# =============================================================================
set -uo pipefail

TF_BIN="${TF_BIN:-terraform}"
ATTEMPTS="${ATTEMPTS:-3}"
BACKOFF="${BACKOFF:-5}"

# The failures that will never succeed on a second call. Matched against the
# combined stdout+stderr of the attempt, case-insensitively. Anything not on
# this list is treated as possibly transient.
#
# Kept deliberately short and specific: a pattern here turns a retry into an
# immediate failure, so a phrase that also appears in a network error would
# reintroduce exactly the flake this removes. "no available releases match"
# and its siblings are constraint arithmetic and cannot depend on the network
# — Terraform emits the connection error above INSTEAD, not alongside.
PERMANENT_PATTERNS='no available releases match|does not have a package available|provider registry .* does not have a provider named|Unsupported Terraform Core version|Invalid provider requirements|Error: Invalid|Unsupported block type|Unsupported argument'

is_permanent() { printf '%s' "$1" | grep -Eqi "$PERMANENT_PATTERNS"; }

init_module() { # <module-dir>
  local dir="$1" attempt=1 wait="$BACKOFF" out rc
  if [ ! -d "$dir" ]; then
    echo "::error::[TFINIT] no such module directory: $dir" >&2
    return 1
  fi

  while :; do
    # Unquoted on purpose: TF_BIN may carry an interpreter and a path, which is
    # how the self-test drives a fake without depending on an execute bit the
    # developer's filesystem may not have.
    # shellcheck disable=SC2086
    out="$($TF_BIN -chdir="$dir" init -backend=false 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    [ "$rc" -eq 0 ] && return 0

    if is_permanent "$out"; then
      echo "::error::[TFINIT] \`init\` failed in $dir for a reason a retry cannot change — not retried" >&2
      return "$rc"
    fi
    if [ "$attempt" -ge "$ATTEMPTS" ]; then
      echo "::error::[TFINIT] \`init\` failed in $dir on all $ATTEMPTS attempts — this is no longer a transient registry reset" >&2
      return "$rc"
    fi

    echo "::warning::[TFINIT] \`init\` failed in $dir (attempt $attempt of $ATTEMPTS), retrying in ${wait}s" >&2
    sleep "$wait"
    attempt=$((attempt + 1))
    wait=$((wait * 2))
  done
}

# =============================================================================
# SELF-TEST — a fake terraform, because the real one would need the registry
# this file exists to stop depending on. Each case asserts BOTH the exit status
# and the number of calls: a retry that never retries and a retry that never
# stops both pass an exit-status-only check.
# =============================================================================
selftest() {
  local tmp pass=0 bad=0
  tmp="$(mktemp -d)" || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/module"

  # $tmp/script decides what the fake terraform does on each call; $tmp/calls
  # counts them. Writing the count from the fake rather than inferring it from
  # the output is the point — it is the only way to tell "succeeded first try"
  # from "retried and the retries were silent".
  cat > "$tmp/tf" <<'FAKE'
#!/usr/bin/env sh
n=$(cat "$TMPD/calls" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$TMPD/calls"
mode=$(cat "$TMPD/script")
case "$mode" in
  ok)          echo "Terraform has been successfully initialized!"; exit 0 ;;
  transient)   echo "Error: Failed to query available provider packages"
               echo "could not connect to registry.terraform.io: read: connection reset by peer"
               exit 1 ;;
  permanent)   echo "Error: Failed to query available provider packages"
               echo "no available releases match the given constraints >= 9.9.9"
               exit 1 ;;
  unknown)     echo "Error: something nobody has seen before"; exit 1 ;;
  flaky2)      if [ "$n" -lt 3 ]; then
                 echo "could not connect to registry.terraform.io: connection reset by peer"; exit 1
               fi
               echo "Terraform has been successfully initialized!"; exit 0 ;;
esac
exit 1
FAKE
  chmod +x "$tmp/tf" 2>/dev/null || true

  run_case() { # <label> <mode> <want-rc> <want-calls>
    local label="$1" mode="$2" want_rc="$3" want_calls="$4" calls rc=0
    printf '%s' "$mode" > "$tmp/script"
    : > "$tmp/calls"
    (
      export TMPD="$tmp"
      TF_BIN="sh $tmp/tf" ATTEMPTS=3 BACKOFF=0 init_module "$tmp/module"
    ) >/dev/null 2>&1 || rc=$?
    calls="$(cat "$tmp/calls" 2>/dev/null || echo 0)"
    if [ "$rc" -eq "$want_rc" ] && [ "$calls" = "$want_calls" ]; then
      pass=$((pass + 1))
    else
      bad=$((bad + 1))
      printf 'SELFTEST FAIL: %s\n  expected: rc=%s calls=%s\n  got:      rc=%s calls=%s\n' \
        "$label" "$want_rc" "$want_calls" "$rc" "$calls"
    fi
  }

  run_case "a clean init is called once"                 ok        0 1
  run_case "two resets then success"                     flaky2    0 3
  run_case "a reset every time stops at ATTEMPTS"        transient 1 3
  run_case "an unsatisfiable constraint fails first try" permanent 1 1
  run_case "an unrecognised failure is retried"          unknown   1 3

  # A module that is not there is a mistake in the caller, not a flake, and it
  # must not spend the backoff before saying so.
  : > "$tmp/calls"
  printf 'ok' > "$tmp/script"
  local absent_rc=0
  ( export TMPD="$tmp"; TF_BIN="sh $tmp/tf" ATTEMPTS=3 BACKOFF=0 init_module "$tmp/absent" ) >/dev/null 2>&1 || absent_rc=$?
  if [ "$absent_rc" -ne 0 ] && [ ! -s "$tmp/calls" ]; then
    pass=$((pass + 1))
  else
    bad=$((bad + 1))
    echo "SELFTEST FAIL: a missing module directory should fail without calling terraform"
  fi

  printf 'terraform-init-retry selftest: %d passed, %d failed\n' "$pass" "$bad"
  [ "$bad" -eq 0 ]
}

if [ "${1:-}" = "--selftest" ]; then
  selftest
  exit $?
fi

if [ $# -ne 1 ]; then
  echo "::error::[TFINIT] usage: terraform-init-retry.sh <module-dir>" >&2
  exit 2
fi

init_module "$1"
exit $?
