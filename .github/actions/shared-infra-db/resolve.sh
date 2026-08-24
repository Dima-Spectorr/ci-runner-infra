#!/usr/bin/env bash
# The body of the `shared-infra-db` action's `resolve` step.
#
# It lives in a FILE rather than inline in action.yml so it can be executed
# against a stubbed `docker` and `ss` — see `scripts/ci/shared-infra-db.selftest.sh`.
# Inline YAML is only reachable by running a whole workflow on a real fleet
# host, which is the expensive place to discover that the retry loop retries on
# the same port.
#
# Contract with action.yml — every one of these is set by the caller:
#   PG ADDR IMAGE DB_USER DB_PASSWORD DB_NAME HEALTH_TIMEOUT GITHUB_OUTPUT
#
# Three knobs exist only so the selftest does not sleep for real time or depend
# on the RNG. They default to the production values and are never set by
# action.yml.
#   PG_RETRY_SLEEP      seconds between port attempts (default 3)
#   PG_POLL_SLEEP       seconds between health polls  (default 1)
#   PG_PORT_CANDIDATES  whitespace-separated ports drawn IN ORDER before
#                       falling back to $RANDOM (default: empty, i.e. always
#                       random). A test that leaves the draw to $RANDOM cannot
#                       prove the busy-port filter or the retry blacklist: with
#                       the filter deleted a random candidate still lands in the
#                       free half about half the time, so the assertion passes
#                       on a broken script whenever the RNG is kind.
set -euo pipefail

: "${GITHUB_OUTPUT:?}"
retry_sleep="${PG_RETRY_SLEEP:-3}"
poll_sleep="${PG_POLL_SLEEP:-1}"
candidates="${PG_PORT_CANDIDATES:-}"

# `?sslmode=disable`, on BOTH branches, appended here rather than at either call
# site so the two cannot drift apart.
#
# The server runs with no TLS on either branch — the anchor's compose is the
# stock `postgres` image, and so is the fallback's `docker run` — and the URL is
# the only thing a consumer receives. Nothing in
# `postgres://ci@10.0.0.7:35100/app` says the handshake will be refused, so
# every adopter rediscovers it, and the rediscovery is expensive because the
# symptom is rarely a message about TLS. DataRetrival hit it twice on one pull
# request chain: once as "The server does not support SSL connections"
# (DataRetrival#2487) and once, from the same handshake at a second consumer,
# as `KnexTimeoutError: Timeout acquiring a connection` after 30 seconds
# (DataRetrival#2491) — which reads as pool exhaustion and was investigated as
# one.
#
# libpq's own spelling, understood by `pg-connection-string` and therefore by
# node-postgres, so this is the action stating a fact only the action holds
# rather than a private convention. An adopter that already appends the
# parameter itself must stop when it re-pins: two of them concatenate into
# `…/app?sslmode=disable?sslmode=disable`, which is not a parseable query
# (#386).
publish() { # <base-url> <port> <shared>
  {
    printf 'url=%s?sslmode=disable\n' "$1"
    printf 'port=%s\n' "$2"
    printf 'shared=%s\n' "$3"
  } >> "$GITHUB_OUTPUT"
}

# The credential half of the URL, built once for both branches so the shared
# stack and the fallback are indistinguishable to the suite.
auth="$DB_USER"
[ -z "$DB_PASSWORD" ] || auth="${DB_USER}:${DB_PASSWORD}"

if [ -n "$PG" ]; then
  # The shared stack, at the host's VPC address — the same address rule 3 has
  # the Windows leg use, and the right one for a job in any OTHER slot: a
  # sibling has its own network namespace, so `127.0.0.1` there is the slot and
  # not the host. The loopback line is a guard against an `addr` the anchor
  # should never have published empty beside a port.
  host="127.0.0.1"
  [ -z "$ADDR" ] || host="$ADDR"

  # EXCEPT IN THE SLOT THAT OWNS THE STACK, on a host that has not yet been
  # rolled onto the hairpin SNAT.
  #
  # The band port is DNAT'd host→slot in PREROUTING, and a packet from inside a
  # slot does reach PREROUTING: it leaves over the veth and is forwarded, not
  # locally generated. The owning slot is special on the way BACK — the DNAT
  # rewrites the destination to the address the packet came from, so source and
  # destination are equal, the reply never returns through the host's conntrack
  # to be un-DNAT'd, and the connection hangs until the client's own timeout.
  # Every sibling slot connects to the same string fine, so this reads as flaky
  # rather than broken: it bites only the roughly one consumer job in four that
  # lands on the anchor's own slot.
  #
  # Measured in DataRetrival run 32755968066: anchor on slot 3,
  # `migration-harness-run` on slot 4 connected at 17:22:41,
  # `integration-tests` on slot 3 timed out against the identical URL. Knex
  # reports it as `KnexTimeoutError: Timeout acquiring a connection` 30 seconds
  # later, which is why it was first read as TLS.
  #
  # `host-startup.sh` now SNATs that hairpin, which fixes it for every consumer
  # — including the ones this action cannot help, a `container:` job among them
  # (see below). This branch is what covers the hosts still running the old
  # boot script, and it stays after they roll because it costs a string
  # comparison.
  #
  # THE TEST IS THE BAND, not a listener. Each slot is told its own band at boot
  # (`CI_SHARED_INFRA_PORT_MIN`/`MAX`, disjoint per slot) and the anchor draws
  # the stack's port from the band of the slot it ran on, so `$PG` falling in
  # THIS slot's band means this slot is the anchor's. A listener probe was the
  # first attempt and is not sound: identical fixed ports are explicitly
  # allowed across the slot namespaces, so a sibling that happens to publish a
  # service on the same number would be sent to loopback and reach its own
  # service instead of the stack.
  #
  # Absent variables mean "not a fleet slot, or not visible from here" and are
  # not an error — a GitHub-hosted runner, and a `container:` job, whose steps
  # do not inherit the runner service's environment. Those keep `$ADDR`, which
  # is correct everywhere except the un-rolled owning-slot case. The Windows leg
  # of rule 3 is untouched: it is a string concatenation and nothing else, and a
  # Windows job is never the owning slot anyway, the anchor's compose being
  # Linux.
  own_band=0
  case "${PG}:${CI_SHARED_INFRA_PORT_MIN:-}:${CI_SHARED_INFRA_PORT_MAX:-}" in
    *[!0-9:]* | *::* | :* | *:) : ;;
    *)
      if [ "$PG" -ge "$CI_SHARED_INFRA_PORT_MIN" ] && [ "$PG" -le "$CI_SHARED_INFRA_PORT_MAX" ]; then
        own_band=1
      fi
      ;;
  esac
  if [ "$host" != "127.0.0.1" ] && [ "$own_band" = 1 ]; then
    host="127.0.0.1"
    echo "::notice::the shared stack is published in THIS slot (${PG} is in this slot's band ${CI_SHARED_INFRA_PORT_MIN}-${CI_SHARED_INFRA_PORT_MAX}) — using loopback, because ${ADDR}:${PG} hairpins back to this namespace and only works from a sibling"
  fi

  publish "postgres://${auth}@${host}:${PG}/${DB_NAME}" "$PG" 1
  echo "::notice::using the run's shared stack at ${host}:${PG}"
  exit 0
fi

# No shared stack. Everything below is the degraded leg.
echo "::notice::the anchor published no shared stack — starting a throwaway Postgres for this job alone"

# FAIL FAST, AND ONLY HERE. The two preconditions below belong to the fallback,
# not to the action: the shared branch above is a string concatenation and works
# on any runner, which is exactly how a Windows job reaches the stack across the
# band under rule 3. Guarding at the top of the script instead would break that.
#
# Without these the leg still fails, just later and wearing a worse error:
# `docker: command not found` from inside a `$(...)`, or a Windows shell's
# rendition of the same.
if [ "${RUNNER_OS:-Linux}" != "Linux" ]; then
  echo "::error::this action's fallback is Linux-only (RUNNER_OS=${RUNNER_OS:-unset}) and the anchor published no shared stack, so there is nothing for this job to connect to. A Windows leg must skip when the anchor degrades — guard the job on the anchor's \`addr\` output being non-empty."
  exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  echo "::error::the fallback needs a container runtime and \`docker\` is not on PATH. On a fleet host this means the slot's rootless daemon did not come up; on any other runner it means this job cannot use the fallback at all."
  exit 1
fi

# `health-timeout` reaches the arithmetic below, where a non-integer is a bash
# syntax error under `set -e` rather than a message anyone can act on. `90m` is
# the plausible mistake: the input is seconds, and every neighbouring GitHub
# knob (`timeout-minutes`) is not.
case "$HEALTH_TIMEOUT" in
  '' | *[!0-9]*)
    echo "::error::health-timeout must be a whole number of seconds; got '${HEALTH_TIMEOUT}'"
    exit 1
    ;;
esac

# THE HOST PORT IS DRAWN HERE, NOT LEFT TO DOCKER.
#
# `--publish '127.0.0.1::5432'` reads as "let the kernel pick" and does not mean
# that on this fleet. Docker's own allocator picks, it starts scanning at 32768
# every time, and a runner HOST carries several slots — each a separate UNIX
# user running rootless Docker, each publishing through RootlessKit, which binds
# in the HOST network namespace. The slots share one port space while sharing no
# allocator state, so two jobs that publish within a few seconds of each other
# both take 32768 and the second one dies:
#
#   error while calling RootlessKit PortManager.AddPort():
#   listen tcp4 0.0.0.0:32768: bind: address already in use
#
# Measured in DataRetrival run 31790204079, job `migration-harness-run`, which
# is why that repository wrote its own action rather than use a `services:`
# block. Re-running does not help — the allocator picks 32768 again. And this is
# not the rare leg: the fallback runs whenever the anchor found the host already
# held, which is whenever two pull requests are in flight, i.e. exactly when
# several slots are starting containers seconds apart.
#
# The listener scan only NARROWS the window; it cannot hold a port, and
# something else may bind it between the check and the `docker run`. The RETRY
# is the actual guard, and the RANDOM DRAW is what makes each attempt
# independent — a retry against Docker's allocator would pick 32768 again.
#
# 20000-29999 is below Docker's scan start and clear of the shared-infra band
# (35100-44099), so a throwaway can never squat on a port the anchor would
# publish a real stack on.
used_ports="$(ss -Htan 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u || true)"

# `--name`, so a container left behind by a failed attempt can be removed before
# the next one; without it `docker run` failing at bind leaves an unreachable
# created container per attempt. Sanitised because Docker accepts only
# `[a-zA-Z0-9][a-zA-Z0-9_.-]*` and `DB_NAME` is the caller's string.
name="ci-shared-db-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}-${GITHUB_JOB:-job}-${DB_NAME}"
name="$(printf '%s' "$name" | tr -c 'a-zA-Z0-9_.-' '-')"

auth_env=(--env "POSTGRES_PASSWORD=${DB_PASSWORD}")
if [ -z "$DB_PASSWORD" ]; then
  # Empty password keeps `trust`, which is the documented normal case for a CI
  # fixture database and matches what the anchor's compose does. A non-empty one
  # drops `trust` entirely and lets the image default to scram-sha-256, so the
  # URL's credential is the credential the server checks.
  auth_env=(--env POSTGRES_HOST_AUTH_METHOD=trust)
fi

started=""
port=""
for attempt in 1 2 3 4 5; do
  port=""
  for _ in $(seq 1 50); do
    if [ -n "$candidates" ]; then
      candidate="${candidates%%[[:space:]]*}"
      case "$candidates" in
        *[[:space:]]*) candidates="${candidates#*[[:space:]]}" ;;
        *)             candidates="" ;;
      esac
    else
      candidate=$(( 20000 + RANDOM % 10000 ))
    fi
    # Matched in-shell rather than with `echo … | grep -qx`. That pipeline is
    # WRONG UNDER `set -o pipefail`, which is set above: when the list is long
    # enough that grep matches and exits before echo finishes writing, echo dies
    # of SIGPIPE (141) and pipefail reports the PIPELINE as failed — so a port
    # that IS in use takes the `||` branch and is published as free. The bug
    # only appears on a host busy enough to make the list long, i.e. exactly the
    # host where publishing an occupied port collides.
    case $'\n'"$used_ports"$'\n' in
      *$'\n'"$candidate"$'\n'*) ;;
      *) port="$candidate"; break ;;
    esac
  done
  [ -n "$port" ] || { echo "::error::could not find a free host port to publish the fallback Postgres on"; exit 1; }

  docker rm --force "$name" >/dev/null 2>&1 || true

  # No `--rm`: the host reaps the slot's containers at job end, and `--rm` would
  # delete the container the moment it exited, taking its logs with it in
  # exactly the case worth reading them.
  if docker run --detach \
       --name "$name" \
       --publish "127.0.0.1:${port}:5432" \
       --env "POSTGRES_USER=${DB_USER}" \
       "${auth_env[@]}" \
       --env "POSTGRES_DB=${DB_NAME}" \
       -- "$IMAGE" >/dev/null; then
    started=1
    break
  fi

  echo "::warning::could not publish the fallback Postgres on 127.0.0.1:${port} (attempt ${attempt}/5) — retrying on another port."
  # Do not draw this port again. A retry against the same port is not an
  # independent attempt, which is the whole reason the draw is random.
  used_ports="$(printf '%s\n%s\n' "$used_ports" "$port")"
  sleep "$retry_sleep"
done
[ -n "$started" ] || { echo "::error::the fallback Postgres failed to start after 5 port attempts."; exit 1; }

# Read the mapping back from Docker rather than trusting `$port`: if the two
# ever disagree, every later step talks to the wrong database and the failure
# looks like a schema bug rather than a wiring bug.
hostport="$(docker port "$name" 5432/tcp | head -n 1 | sed 's/.*://')"
[ -n "$hostport" ] || { echo "::error::the fallback Postgres published no host port"; exit 1; }

# Ready means "accepts connections", which is later than "container is
# running" — a suite that connects in between reads "the database system is
# starting up" and reports itself broken.
deadline=$(( SECONDS + HEALTH_TIMEOUT ))
until docker exec "$name" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "::error::the fallback Postgres did not accept connections within ${HEALTH_TIMEOUT}s"
    docker logs --tail 50 "$name" || true
    exit 1
  fi
  sleep "$poll_sleep"
done

publish "postgres://${auth}@127.0.0.1:${hostport}/${DB_NAME}" "$hostport" 0
