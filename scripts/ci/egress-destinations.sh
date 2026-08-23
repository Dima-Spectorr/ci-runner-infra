#!/usr/bin/env bash
# =============================================================================
# egress-destinations.sh — what the pool actually connected out to, and what is
# new since the last time somebody looked
#
# USAGE
#   scripts/ci/egress-destinations.sh --project <id> [--account <sa-email>]
#                                     [--hours <n>] [--baseline <file>]
#                                     [--fail-on-new] [--update-baseline]
#                                     [--from-file <ndjson>] [--selftest]
#
# WHY THIS EXISTS
#   `modules/ci-runner-network` now logs the runner firewall rules, so every
#   outbound connection from a warm host is written down. A log nobody reads is
#   the state that change was fixing one level down — the module's own comment
#   already described a refusal "recorded in a firewall log nobody is reading" —
#   so the record needs something that reads it.
#
#   "Alert on a never-before-seen destination" is the ask, and it cannot be an
#   alert-policy threshold: Cloud Monitoring has no notion of *novel*, only of
#   *more*. Novelty needs a baseline, a baseline needs to be written down
#   somewhere a human agreed to, and the place this fleet writes down agreed
#   state is the repository. So this is a diff, not a detector:
#
#     the destinations seen in the window  −  the destinations in the baseline
#
#   and a new one is a pull request that adds a line, reviewed by whoever knows
#   whether the pool should be talking to it.
#
# WHY THE KEY IS NOT THE IP ADDRESS
#   GitHub, npm, PyPI and Google APIs all sit behind CDNs that rotate addresses
#   constantly. Keyed by IP the baseline would churn every day, every run would
#   report dozens of "new" destinations, and within a week nobody would read it
#   — a novelty report that cries wolf is worse than none, because its silence
#   is what people would have relied on.
#
#   The key is `<asn>|<country>|<port>` — the network that owns the address,
#   not the address. AS36459 (GitHub) stays AS36459 across every rotation, and a
#   connection to a rented VPS is a different ASN on the first packet. Where the
#   log has no ASN (an in-estate RFC1918 destination, or metadata excluded) the
#   key falls back to the /24 and says so, because a silently different key
#   shape is how a baseline stops matching anything.
#
# WHAT IT DOES NOT DECIDE
#   Whether a destination is legitimate. That is the review, and the baseline
#   file is where the review is recorded. This script decides only "in the
#   baseline" or "not in the baseline", which is a question it can answer.
#
#   It also cannot see what the pool reached BEFORE logging was enabled. A
#   freshly logged pool has an empty baseline and every destination is new;
#   `--update-baseline` on a first run is how that is seeded, and seeding it is
#   an act of review, not a formality.
#
# EXIT CODES
#   0 — no new destinations (or --fail-on-new not given)
#   1 — new destinations and --fail-on-new
#   2 — usage, or the read failed
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PROJECT=""; ACCOUNT=""; HOURS=24; BASELINE=""; FAIL_ON_NEW=0; UPDATE=0
FROM_FILE=""; SELFTEST=0

# The corporate proxy blackholes the token endpoint; without this the read below
# fails as an auth error rather than a network one, which sends the reader
# looking at IAM. Same bypass `ensure-alert-policies.sh` sets, for the same
# reason.
export no_proxy="googleapis.com,*.googleapis.com,localhost,127.0.0.1,::1,.local"
export NO_PROXY="$no_proxy"

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" >&2; exit 2; }

# ── the pure part ────────────────────────────────────────────────────────────
# Everything below `aggregate` is testable without gcloud, which is the point of
# --from-file: the shape of a firewall log entry is the thing most likely to be
# wrong, and discovering that against a live project costs a day.

# aggregate <ndjson-file>  ->  "<count>\t<key>" per destination, sorted by key
#
# Reads the LogEntry stream one JSON object per line. A malformed line is not
# skipped quietly: jq fails, and the caller treats that as a failed read rather
# than as an empty result — an aggregation that silently drops what it cannot
# parse reports a quiet pool, which is the one answer that must never be a
# guess.
# SC2016: the `$p`, `$port`, `$asn` below are jq's own variables, bound by the
# `as` clauses in the same program. Single quotes are what keeps them jq's;
# letting the shell see them would substitute empty strings into the filter.
# shellcheck disable=SC2016
aggregate() {
  jq -r -s '
    map(select(.jsonPayload.disposition == "ALLOWED"))
    | map(
        .jsonPayload as $p
        | ($p.connection.dest_port // "?" | tostring) as $port
        | ($p.remote_location.asn // null) as $asn
        | ($p.remote_location.country // "??") as $country
        | ($p.connection.dest_ip // "0.0.0.0") as $ip
        | if $asn == null
          # No ASN: an in-estate destination, or metadata excluded. The /24 is
          # the coarsest thing still meaningful, and `net:` marks the key shape
          # so a fallback key can never be mistaken for an ASN key.
          then "net:" + (($ip | split(".") | .[0:3] | join(".")) + ".0/24") + "|" + $country + "|" + $port
          else "as:" + ($asn | tostring) + "|" + $country + "|" + $port
          end
      )
    | group_by(.)
    | map({ key: .[0], n: length })
    | sort_by(.key)
    | .[]
    | "\(.n)\t\(.key)"
  ' "$1" | tr -d '\r'
}
# The `tr` is not defensive noise. jq's Windows build writes stdout in text
# mode, so every key arrived with a trailing CR — which compared unequal to the
# same key from a baseline file, made `comm` report each destination as both new
# and missing at once, and would have been a permanently red report that always
# had a plausible-looking explanation.

# ── reading the log ──────────────────────────────────────────────────────────
read_log() {  # -> ndjson on stdout
  local filter
  # EGRESS only. The IAP-SSH rule is logged too and is ingress; folding it in
  # here would put an operator's laptop in a list of places the POOL goes.
  filter='logName:"compute.googleapis.com%2Ffirewall"
    AND jsonPayload.rule_details.direction="EGRESS"
    AND jsonPayload.disposition="ALLOWED"'

  local -a cmd=(gcloud logging read "$filter"
    --project="$PROJECT" --freshness="${HOURS}h" --limit=100000 --format=json)
  [ -n "$ACCOUNT" ] && cmd+=(--account="$ACCOUNT")

  # `--format=json` is a single array; the aggregator wants a stream, and `-s`
  # in jq re-slurps it either way.
  "${cmd[@]}" | jq -c '.[]'
}

# ── the diff ─────────────────────────────────────────────────────────────────
# The scratch directory is owned here rather than by a RETURN trap inside the
# work function. A RETURN trap set in one function stays installed and fires on
# the NEXT function return too, by which point its `local tmp` is gone and
# `set -u` turns the cleanup into an error at the end of an otherwise successful
# run. The fixtures call back into this, so that is not a theoretical ordering.
main() {
  local tmp rc
  tmp="$(mktemp -d)"
  run "$tmp" "$@"; rc=$?
  rm -rf "$tmp"
  return "$rc"
}

run() {
  local tmp="$1"; shift

  # Reset every option before parsing. The fixtures call `main` again from
  # inside `selftest`, and a `SELFTEST` left at 1 from the outer invocation
  # makes the inner call re-enter the fixtures — an infinite recursion that
  # looks exactly like a hung log read. The other options are reset for the same
  # reason: a `--baseline` from one fixture must not leak into the next.
  PROJECT=""; ACCOUNT=""; HOURS=24; BASELINE=""; FAIL_ON_NEW=0; UPDATE=0
  FROM_FILE=""; SELFTEST=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --project) PROJECT="$2"; shift 2 ;;
      --account) ACCOUNT="$2"; shift 2 ;;
      --hours)   HOURS="$2";   shift 2 ;;
      --baseline) BASELINE="$2"; shift 2 ;;
      --from-file) FROM_FILE="$2"; shift 2 ;;
      --fail-on-new) FAIL_ON_NEW=1; shift ;;
      --update-baseline) UPDATE=1; shift ;;
      --selftest) SELFTEST=1; shift ;;
      *) echo "unknown argument: $1" >&2; usage ;;
    esac
  done

  [ "$SELFTEST" = "1" ] && { selftest; return; }

  command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; return 2; }

  if [ -z "$FROM_FILE" ]; then
    [ -n "$PROJECT" ] || { echo "--project is required" >&2; usage; }
    case "$HOURS" in ''|*[!0-9]*) echo "--hours must be a whole number" >&2; return 2 ;; esac
  fi
  [ -n "$BASELINE" ] || BASELINE="$REPO_ROOT/docs/egress-baselines/${PROJECT:-unknown}.txt"

  if [ -n "$FROM_FILE" ]; then
    cp "$FROM_FILE" "$tmp/log.ndjson"
  else
    if ! read_log > "$tmp/log.ndjson"; then
      echo "::error::could not read the firewall log for $PROJECT — treating as a failed read, not as a quiet pool" >&2
      return 2
    fi
    # A pool that ran jobs and logged nothing is a configuration problem, not a
    # clean bill of health: the likeliest cause is firewall_logging = "off" or a
    # module version predating it. Reported as a failure for the same reason the
    # workflow gates fail when they read no files.
    if [ ! -s "$tmp/log.ndjson" ]; then
      echo "::error::no EGRESS firewall log entries in the last ${HOURS}h for $PROJECT — the record is not being written (check firewall_logging), so nothing was compared" >&2
      return 2
    fi
  fi

  if ! aggregate "$tmp/log.ndjson" > "$tmp/seen.tsv"; then
    echo "::error::the log could not be aggregated — treating as a failed read" >&2
    return 2
  fi

  cut -f2 "$tmp/seen.tsv" | sort -u > "$tmp/seen.keys"

  if [ -f "$BASELINE" ]; then
    # `grep -Ev` with a POSIX class, not `\s` and `\|`. Both are GNU
    # extensions: they work on the runner and on a pool host, and they are
    # silently literal on the BSD grep an operator reads this file with on a
    # laptop — where a commented baseline line would become a destination key
    # that matches nothing, so every real destination reports as new.
    grep -Ev '^[[:space:]]*(#|$)' "$BASELINE" | sort -u > "$tmp/base.keys"
  else
    : > "$tmp/base.keys"
  fi

  comm -23 "$tmp/seen.keys" "$tmp/base.keys" > "$tmp/new.keys"
  comm -13 "$tmp/seen.keys" "$tmp/base.keys" > "$tmp/gone.keys"

  echo "destinations seen in the last ${HOURS}h: $(wc -l < "$tmp/seen.keys" | tr -d ' ')"
  while IFS=$'\t' read -r n key; do
    printf '  %8s  %s\n' "$n" "$key"
  done < "$tmp/seen.tsv"

  if [ "$UPDATE" = "1" ]; then
    mkdir -p "$(dirname "$BASELINE")"
    {
      echo "# Egress destinations agreed for ${PROJECT:-this pool}."
      echo "# Key: as:<asn>|<country>|<port>, or net:<a.b.c.0/24>|<country>|<port>"
      echo "# when the log carried no ASN. A line here is a REVIEWED destination:"
      echo "# adding one is a pull request somebody reads, which is the whole"
      echo "# mechanism — this file is the baseline, not a cache."
      cat "$tmp/seen.keys"
    } > "$BASELINE"
    echo "baseline written: $BASELINE ($(wc -l < "$tmp/seen.keys" | tr -d ' ') destinations)"
    return 0
  fi

  local new_count gone_count
  new_count="$(wc -l < "$tmp/new.keys" | tr -d ' ')"
  gone_count="$(wc -l < "$tmp/gone.keys" | tr -d ' ')"

  # Reported, never a failure. A destination the pool stopped using is a
  # baseline that needs tidying, not an incident, and treating it as one would
  # make the report red on every routine dependency removal.
  if [ "$gone_count" -gt 0 ]; then
    echo "in the baseline and not seen in this window ($gone_count) — tidy when convenient:"
    sed 's/^/  /' "$tmp/gone.keys"
  fi

  if [ "$new_count" -eq 0 ]; then
    echo "no new egress destinations."
    return 0
  fi

  echo "::warning::$new_count egress destination(s) not in the baseline:"
  sed 's/^/  /' "$tmp/new.keys"
  echo "Review each one. If it belongs, add it to $BASELINE in a pull request;"
  echo "if it does not, that is a warm host reaching somewhere nobody agreed to."

  [ "$FAIL_ON_NEW" = "1" ] && return 1
  return 0
}

# ── fixtures ─────────────────────────────────────────────────────────────────
selftest() {
  local tmp status=0
  tmp="$(mktemp -d)"

  entry() {  # <disposition> <direction> <ip> <port> [<asn> <country>]
    # -ge 6, not -ge 5. The optional part is a PAIR, and at five arguments the
    # branch below reads `$6` under `set -u` — an "unbound variable" from
    # inside a fixture helper, which reads as the gate being broken rather than
    # as the fixture being miswritten.
    if [ $# -ge 6 ]; then
      printf '{"jsonPayload":{"disposition":"%s","rule_details":{"direction":"%s"},"connection":{"dest_ip":"%s","dest_port":%s},"remote_location":{"asn":%s,"country":"%s"}}}\n' \
        "$1" "$2" "$3" "$4" "$5" "$6"
    else
      printf '{"jsonPayload":{"disposition":"%s","rule_details":{"direction":"%s"},"connection":{"dest_ip":"%s","dest_port":%s}}}\n' \
        "$1" "$2" "$3" "$4"
    fi
  }

  expect() {  # <name> <want-stdout> <ndjson-file>
    local name="$1" want="$2" file="$3" got
    got="$(aggregate "$file" | tr '\n' ';')"
    got="${got%;}"
    if [ "$got" != "$want" ]; then
      echo "FAIL $name"
      echo "      want: $want"
      echo "      got:  $got"
      status=1
    else
      echo "ok   $name"
    fi
  }

  # An ASN key survives an address rotation. This is the reason the key is not
  # the IP: three different GitHub addresses are one destination.
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US
    entry ALLOWED EGRESS 140.82.112.3 443 36459 US
    entry ALLOWED EGRESS 20.201.28.151 443 36459 US
  } > "$tmp/rotate.ndjson"
  expect "an address rotation is one destination" "3	as:36459|US|443" "$tmp/rotate.ndjson"

  # Identical keys arriving NON-ADJACENTLY still group. jq's `group_by` sorts
  # before it groups, so this holds — but the claim is worth a fixture rather
  # than a reader's memory of the jq manual, because if it were false the
  # counts would be wrong only on real traffic (which interleaves) and never on
  # a fixture whose matching entries happen to sit next to each other.
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US
    entry ALLOWED EGRESS 203.0.113.9 443 64512 RU
    entry ALLOWED EGRESS 140.82.112.3 443 36459 US
  } > "$tmp/interleaved.ndjson"
  expect "interleaved keys still group"     "2	as:36459|US|443;1	as:64512|RU|443" "$tmp/interleaved.ndjson"

  # A different network on the same port is a different destination, which is
  # the case the whole report exists for.
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US
    entry ALLOWED EGRESS 203.0.113.9 443 64512 RU
  } > "$tmp/two.ndjson"
  expect "a different ASN is a different destination" \
    "1	as:36459|US|443;1	as:64512|RU|443" "$tmp/two.ndjson"

  # Port is part of the key: the same network reached on 5432 is not the same
  # fact as reached on 443.
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US
    entry ALLOWED EGRESS 140.82.121.4 5432 36459 US
  } > "$tmp/ports.ndjson"
  expect "the port is part of the key" \
    "1	as:36459|US|443;1	as:36459|US|5432" "$tmp/ports.ndjson"

  # No ASN — an RFC1918 destination, or metadata excluded. The fallback is the
  # /24 and it is MARKED, so a baseline written under one metadata setting
  # cannot silently half-match one written under the other.
  { entry ALLOWED EGRESS 10.20.30.41 5432
    entry ALLOWED EGRESS 10.20.30.99 5432
  } > "$tmp/noasn.ndjson"
  expect "no ASN falls back to a marked /24" "2	net:10.20.30.0/24|??|5432" "$tmp/noasn.ndjson"

  # Ingress is filtered by the query, but a DENIED entry can arrive in a
  # hand-supplied file, and counting a refusal as a destination the pool reached
  # would put somewhere it never got to into the baseline.
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US
    entry DENIED EGRESS 203.0.113.9 25 64512 RU
  } > "$tmp/denied.ndjson"
  expect "a refused connection is not a destination" "1	as:36459|US|443" "$tmp/denied.ndjson"

  # An entry missing the fields entirely must still produce a key rather than
  # `null|null|null`, which would collapse every malformed entry into one line
  # that looks like a real destination.
  printf '{"jsonPayload":{"disposition":"ALLOWED","rule_details":{"direction":"EGRESS"}}}\n' > "$tmp/bare.ndjson"
  expect "a bare entry keys to something legible" "1	net:0.0.0.0/24|??|?" "$tmp/bare.ndjson"

  # The end-to-end diff, through main(), against a written baseline.
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US
    entry ALLOWED EGRESS 203.0.113.9 443 64512 RU
  } > "$tmp/diff.ndjson"
  printf '# agreed\nas:36459|US|443\n' > "$tmp/baseline.txt"

  local out
  out="$(main --from-file "$tmp/diff.ndjson" --baseline "$tmp/baseline.txt" --fail-on-new 2>&1)"
  local rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -c 'as:64512|RU|443' >/dev/null \
     && ! printf '%s' "$out" | grep -c '::warning.*as:36459' >/dev/null; then
    echo "ok   the diff reports only the destination not in the baseline"
  else
    echo "FAIL the diff reports only the destination not in the baseline (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
    status=1
  fi

  # A baseline entry the pool stopped using is reported and is NOT a failure.
  printf 'as:36459|US|443\nas:99999|NL|443\n' > "$tmp/stale.txt"
  { entry ALLOWED EGRESS 140.82.121.4 443 36459 US; } > "$tmp/one.ndjson"
  out="$(main --from-file "$tmp/one.ndjson" --baseline "$tmp/stale.txt" --fail-on-new 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -c 'as:99999|NL|443' >/dev/null; then
    echo "ok   a destination that disappeared is reported, not failed"
  else
    echo "FAIL a destination that disappeared is reported, not failed (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
    status=1
  fi

  # An absent baseline is an empty one: every destination is new, and seeding it
  # is a deliberate act rather than the default.
  out="$(main --from-file "$tmp/one.ndjson" --baseline "$tmp/nope.txt" --fail-on-new 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -c 'as:36459|US|443' >/dev/null; then
    echo "ok   an absent baseline makes every destination new"
  else
    echo "FAIL an absent baseline makes every destination new (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
    status=1
  fi

  # --update-baseline seeds the file, and the seeded file then matches.
  main --from-file "$tmp/diff.ndjson" --baseline "$tmp/seeded.txt" --update-baseline >/dev/null 2>&1
  out="$(main --from-file "$tmp/diff.ndjson" --baseline "$tmp/seeded.txt" --fail-on-new 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -c 'no new egress destinations' >/dev/null; then
    echo "ok   a seeded baseline matches the window it was seeded from"
  else
    echo "FAIL a seeded baseline matches the window it was seeded from (rc=$rc)"
    printf '%s\n' "$out" | sed 's/^/      /'
    status=1
  fi

  rm -rf "$tmp"
  [ "$status" -eq 0 ] && echo "egress-destinations self-test: all fixtures pass"
  return "$status"
}

main "$@"
