#!/usr/bin/env bash

# Self-test for `.github/actions/shared-infra-db/resolve.sh`, the fallback a
# consuming job takes whenever the anchor published no shared stack.
#
# The whole reason this script exists as a FILE is that its interesting
# behaviour is a retry loop around `docker run`, and the only other way to reach
# that loop is to run a real workflow on a real fleet host with another slot
# holding the port — which is not a thing anyone can arrange on purpose. So the
# suite stubs `docker` and `ss` and drives the loop directly.
#
# What is actually being defended (#366):
#
#   * the host port is DRAWN by this script, never left to Docker. Docker's
#     allocator starts at 32768 every time; a fleet host runs several slots
#     under separate uids whose rootless published ports are all bound by
#     RootlessKit in the HOST namespace, so two slots publishing seconds apart
#     both take 32768 and the second dies with
#     `RootlessKit PortManager.AddPort(): bind: address already in use`
#     (measured in DataRetrival run 31790204079);
#   * a port already listening is not drawn;
#   * a port that FAILED to bind is not drawn again — a retry against the same
#     port is not an independent attempt;
#   * the port handed to the suite is the one Docker reports, not the one drawn;
#   * the shared branch still short-circuits before any of it, because that is
#     the branch a Windows job takes across the band under rule 3.
#
# `PG_PORT_CANDIDATES` makes the draw deterministic. Without it the assertions
# would be vacuous: with the busy-port filter deleted, a random candidate still
# lands in the free half about half the time, so a broken script would pass
# whenever the RNG was kind.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVE="$HERE/../../.github/actions/shared-infra-db/resolve.sh"
[ -f "$RESOLVE" ] || { echo "FAIL: cannot find resolve.sh at $RESOLVE"; exit 1; }

PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN"

# `ss` stub: prints the listener table the script scans. The lines are shaped
# like real `ss -Htan` output because the script parses the fourth column and
# strips everything up to the last colon.
cat > "$BIN/ss" <<'STUB'
#!/usr/bin/env bash
for p in ${SS_BUSY:-}; do printf 'LISTEN 0 128 0.0.0.0:%s 0.0.0.0:*\n' "$p"; done
STUB

# `docker` stub. `DOCKER_REFUSE` is a space-separated list of host ports whose
# `run` must fail, standing in for RootlessKit's bind error. Every invocation is
# appended to $TMP/calls so the assertions can read what was actually attempted.
cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$1" in
  run)
    port=""
    for a in "$@"; do
      case "$a" in 127.0.0.1:*:5432) port="${a#127.0.0.1:}"; port="${port%:5432}" ;; esac
    done
    for r in ${DOCKER_REFUSE:-}; do
      if [ "$r" = "$port" ]; then
        echo "docker: Error response from daemon: error while calling RootlessKit PortManager.AddPort(): listen tcp4 0.0.0.0:${port}: bind: address already in use" >&2
        exit 125
      fi
    done
    printf '%s' "$port" > "$DOCKER_LAST_PORT_FILE"
    echo "deadbeefcafe"
    ;;
  port)   printf '127.0.0.1:%s\n' "$(cat "$DOCKER_LAST_PORT_FILE")" ;;
  exec)   exit "${DOCKER_ISREADY_RC:-0}" ;;
  rm)     exit 0 ;;
  logs)   echo "(stub logs)" ;;
  *)      exit 0 ;;
esac
STUB
chmod +x "$BIN/ss" "$BIN/docker"

# run_resolve <name> — drives resolve.sh in a clean output/calls sandbox.
# Reads the caller's PG/ADDR/SS_BUSY/DOCKER_REFUSE/PG_PORT_CANDIDATES from the
# environment; sets OUT, CALLS and RC for the assertions.
run_resolve() {
  OUT="$TMP/out.$1"
  CALLS="$TMP/calls.$1"
  : > "$OUT"
  : > "$CALLS"
  : > "$TMP/lastport.$1"
  PATH="$BIN:$PATH" \
  GITHUB_OUTPUT="$OUT" \
  DOCKER_CALLS="$CALLS" \
  DOCKER_LAST_PORT_FILE="$TMP/lastport.$1" \
  RUNNER_OS=Linux \
  GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=selftest \
  PG="${PG:-}" ADDR="${ADDR:-}" \
  IMAGE="postgres@sha256:stub" \
  DB_USER="${DB_USER:-ci}" DB_PASSWORD="${DB_PASSWORD:-}" DB_NAME="${DB_NAME:-app}" \
  HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-30}" \
  PG_RETRY_SLEEP=0 PG_POLL_SLEEP=0 \
  PG_PORT_CANDIDATES="${PG_PORT_CANDIDATES:-}" \
  CI_SHARED_INFRA_PORT_MIN="${CI_SHARED_INFRA_PORT_MIN:-}" \
  CI_SHARED_INFRA_PORT_MAX="${CI_SHARED_INFRA_PORT_MAX:-}" \
  SS_BUSY="${SS_BUSY:-}" DOCKER_REFUSE="${DOCKER_REFUSE:-}" \
  DOCKER_ISREADY_RC="${DOCKER_ISREADY_RC:-0}" \
  bash "$RESOLVE" >"$TMP/stdout.$1" 2>&1
  RC=$?
}

ok() { # <condition-description> <0|1>
  if [ "$2" -eq 1 ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"
  fi
}

got() { sed -n "s/^$2=//p" "$1"; }

# ---------------------------------------------------------------------------
# The shared branch short-circuits, and does not touch Docker.
# ---------------------------------------------------------------------------
( PG=35100 ADDR=10.0.0.7 run_resolve shared
  ok "shared: exits 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
  ok "shared: url names addr and the band port" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@10.0.0.7:35100/app?sslmode=disable' ] && echo 1 || echo 0)"
  ok "shared: reports shared=1" "$([ "$(got "$OUT" shared)" = 1 ] && echo 1 || echo 0)"
  ok "shared: starts no container" "$([ ! -s "$CALLS" ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.shared" ) || true

# An empty `addr` beside a port is an anchor bug; the URL falls back to loopback
# rather than emitting `postgres://ci@:35100/app`.
( PG=35100 ADDR='' run_resolve sharednoaddr
  ok "shared without addr: falls back to loopback" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@127.0.0.1:35100/app?sslmode=disable' ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sharednoaddr" ) || true

# The slot that OWNS the stack must use loopback on a host that has not yet been
# rolled onto the hairpin SNAT: `addr` DNATs back into this same namespace, so
# source and destination are equal and the reply never returns through the
# host's conntrack. The slot's own band identifies it — the anchor draws the
# stack's port from the band of the slot it ran on, and bands are disjoint.
( PG=35100 ADDR=10.0.0.7 CI_SHARED_INFRA_PORT_MIN=35100 CI_SHARED_INFRA_PORT_MAX=35199 \
    run_resolve sharedown
  ok "shared on the anchor's own slot: uses loopback, not addr" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@127.0.0.1:35100/app?sslmode=disable' ] && echo 1 || echo 0)"
  ok "shared on the anchor's own slot: still reports shared=1" \
     "$([ "$(got "$OUT" shared)" = 1 ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sharedown" ) || true

# A sibling slot keeps `addr`: the port is outside ITS band, whatever it happens
# to have listening. Sending a sibling to loopback would reach its own unrelated
# service, or nothing — turning an intermittent failure into a total one.
( PG=35100 ADDR=10.0.0.7 CI_SHARED_INFRA_PORT_MIN=35200 CI_SHARED_INFRA_PORT_MAX=35299 \
    SS_BUSY="35100 22" run_resolve sharedsibling
  ok "shared from a sibling slot: keeps addr even with the same port listening" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@10.0.0.7:35100/app?sslmode=disable' ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sharedsibling" ) || true

# No band in the environment is the GitHub-hosted runner and the `container:`
# job: not a fleet slot, or a slot whose steps do not inherit the runner
# service's environment. Keep `addr` — it is right everywhere except the
# un-rolled owning slot, and guessing loopback there would address the
# container itself.
( PG=35100 ADDR=10.0.0.7 run_resolve sharednoband
  ok "shared with no band in the environment: keeps addr" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@10.0.0.7:35100/app?sslmode=disable' ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sharednoband" ) || true

# A malformed band must not crash the action or silently mean "ours".
( PG=35100 ADDR=10.0.0.7 CI_SHARED_INFRA_PORT_MIN=abc CI_SHARED_INFRA_PORT_MAX=35199 \
    run_resolve sharedbadband
  ok "shared with a non-numeric band: exits 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
  ok "shared with a non-numeric band: keeps addr" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@10.0.0.7:35100/app?sslmode=disable' ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sharedbadband" ) || true

# ---------------------------------------------------------------------------
# The fallback draws its own port.
# ---------------------------------------------------------------------------
( PG='' PG_PORT_CANDIDATES="24001" run_resolve draw
  ok "fallback: exits 0" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
  ok "fallback: publishes the drawn port explicitly, never '127.0.0.1::5432'" \
     "$(grep -q -- '127\.0\.0\.1:24001:5432' "$CALLS" && ! grep -q -- '127\.0\.0\.1::5432' "$CALLS" && echo 1 || echo 0)"
  ok "fallback: url carries the drawn port" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@127.0.0.1:24001/app?sslmode=disable' ] && echo 1 || echo 0)"
  ok "fallback: reports shared=0" "$([ "$(got "$OUT" shared)" = 0 ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.draw" ) || true

# A port already listening on the host is skipped. 32768 is the case that
# matters: it is where Docker's own allocator would have started.
( PG='' SS_BUSY="32768 24001" PG_PORT_CANDIDATES="24001 24002" run_resolve busy
  ok "busy port: skips the listener and takes the next candidate" \
     "$(grep -q -- '127\.0\.0\.1:24002:5432' "$CALLS" && ! grep -q -- '127\.0\.0\.1:24001:5432' "$CALLS" && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.busy" ) || true

# A bind that fails anyway — the window the listener scan cannot close — is
# retried on a DIFFERENT port, and the refused one is never drawn again.
( PG='' DOCKER_REFUSE="24001" PG_PORT_CANDIDATES="24001 24001 24002" run_resolve refuse
  ok "refused bind: still succeeds" "$([ "$RC" -eq 0 ] && echo 1 || echo 0)"
  ok "refused bind: the refused port is blacklisted, not redrawn" \
     "$([ "$(grep -c -- '127\.0\.0\.1:24001:5432' "$CALLS")" -eq 1 ] && echo 1 || echo 0)"
  ok "refused bind: the url names the port that bound" \
     "$([ "$(got "$OUT" url)" = 'postgres://ci@127.0.0.1:24002/app?sslmode=disable' ] && echo 1 || echo 0)"
  ok "refused bind: the leftover container is removed before the next attempt" \
     "$(grep -q '^rm --force ' "$CALLS" && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.refuse" ) || true

# Five refusals is a real failure, not a silent success on a port nothing bound.
( PG='' DOCKER_REFUSE="24001 24002 24003 24004 24005" \
  PG_PORT_CANDIDATES="24001 24002 24003 24004 24005" run_resolve exhausted
  ok "five refusals: fails" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
  ok "five refusals: says so" \
     "$(grep -q 'after 5 port attempts' "$TMP/stdout.exhausted" && echo 1 || echo 0)"
  ok "five refusals: publishes no url" \
     "$([ -z "$(got "$OUT" url)" ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.exhausted" ) || true

# ---------------------------------------------------------------------------
# The guards that were already there, kept honest.
# ---------------------------------------------------------------------------
( PG='' HEALTH_TIMEOUT=90m PG_PORT_CANDIDATES="24001" run_resolve badtimeout
  ok "health-timeout '90m': rejected with a message, not a bash syntax error" \
     "$([ "$RC" -ne 0 ] && grep -q 'whole number of seconds' "$TMP/stdout.badtimeout" && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.badtimeout" ) || true

# A non-empty password drops `trust` and reaches the URL; an empty one keeps
# `trust` and leaves the URL bare. This used to be wrong in both directions at
# once — `trust` unconditionally, password embedded anyway.
( PG='' DB_PASSWORD=s3cret PG_PORT_CANDIDATES="24001" run_resolve pw
  ok "password: not run under trust" \
     "$(! grep -q 'POSTGRES_HOST_AUTH_METHOD=trust' "$CALLS" && echo 1 || echo 0)"
  ok "password: reaches the url" \
     "$(grep -q '^url=postgres://ci:s3cret@' "$OUT" && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.pw" ) || true

( PG='' PG_PORT_CANDIDATES="24001" run_resolve trust
  ok "no password: trust, and no credential in the url" \
     "$(grep -q 'POSTGRES_HOST_AUTH_METHOD=trust' "$CALLS" && grep -q '^url=postgres://ci@' "$OUT" && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.trust" ) || true

# ---------------------------------------------------------------------------
# The URL says the server has no TLS, because nothing else can.
#
# Asserted on BOTH branches and asserted ONCE: an adopter that also appends the
# parameter would get `…/app?sslmode=disable?sslmode=disable`, which is not a
# parseable query, so "appears at all" is not the property that matters. The
# count check is what would catch a later edit that adds it at a call site as
# well as in `publish` (#386).
# ---------------------------------------------------------------------------
( PG=35100 ADDR=10.0.0.7 run_resolve sslshared
  ok "shared: the url declares sslmode=disable" \
     "$(case "$(got "$OUT" url)" in *'?sslmode=disable') echo 1 ;; *) echo 0 ;; esac)"
  ok "shared: it appears exactly once" \
     "$([ "$(got "$OUT" url | grep -o 'sslmode=disable' | wc -l)" -eq 1 ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sslshared" ) || true

( PG='' PG_PORT_CANDIDATES="24001" run_resolve sslfallback
  ok "fallback: the url declares sslmode=disable too" \
     "$(case "$(got "$OUT" url)" in *'?sslmode=disable') echo 1 ;; *) echo 0 ;; esac)"
  ok "fallback: it appears exactly once" \
     "$([ "$(got "$OUT" url | grep -o 'sslmode=disable' | wc -l)" -eq 1 ] && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.sslfallback" ) || true

# A Windows leg has no container runtime, so the fallback is not available to
# it — it must fail on that sentence rather than on `docker: command not found`.
( PATH="$BIN:$PATH" GITHUB_OUTPUT="$TMP/out.win" RUNNER_OS=Windows PG='' ADDR='' \
    IMAGE=x DB_USER=ci DB_PASSWORD='' DB_NAME=app HEALTH_TIMEOUT=30 \
    DOCKER_CALLS="$TMP/calls.win" DOCKER_LAST_PORT_FILE="$TMP/lp.win" \
    bash "$RESOLVE" >"$TMP/stdout.win" 2>&1
  rc=$?
  ok "windows fallback: fails naming the missing \`if:\` guard" \
     "$([ "$rc" -ne 0 ] && grep -q 'Linux-only' "$TMP/stdout.win" && echo 1 || echo 0)"
  printf '%s %s\n' "$PASS" "$FAIL" > "$TMP/r.win" ) || true

# Subshells were used so one case's environment cannot leak into the next; add
# their tallies back up here.
PASS=0; FAIL=0
for f in "$TMP"/r.*; do
  read -r p f2 < "$f"
  PASS=$((PASS + p)); FAIL=$((FAIL + f2))
done

printf '\nshared-infra-db selftest: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
