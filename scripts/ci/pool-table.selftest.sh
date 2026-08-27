#!/usr/bin/env bash
# Self-test for the controller's pool table.
#
# The table is the controller's ENTIRE picture of what it manages: which MIGs it
# may delete instances from, which labels count as its demand, which pools mint
# GitHub registration tokens. Every other rule in the controller is downstream
# of a row produced here, so a parse bug does not surface as a parse error — it
# surfaces as a pool that quietly stops being served, or as a delete issued
# against the wrong instance group.
#
# The two failure shapes worth naming, because both look healthy from outside:
#
#  * A DROPPED ROW. Three pools tick, the fourth never does. Its hosts are never
#    drained and its demand is never published, so its autoscaler — which is
#    ONLY_UP — holds whatever it last scaled to, forever. Nothing is red.
#  * A SHIFTED COLUMN. One row with an unescaped tab in its label list moves
#    every later field left: `region` becomes a label, `slots` becomes a region.
#    The controller then divides demand by a string and issues gcloud calls
#    against a region that does not exist.
#
# So the cases below cover each validation branch, both directions of the
# "one bad row must not take the others down" rule, and the field-order contract
# itself — asserted column by column, since an inserted column is invisible to
# any test that only counts fields.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/../../modules/ci-runner-host-pool/scripts/pool-table.sh"

PASS=0
FAIL=0

OUT=""
ERR=""
RC=0

# run <json> — parse it, capturing stdout, stderr and the return code
# separately. All three are contract: the rows the controller ticks, the
# rejections it logs and counts, and the "nothing to serve" signal that stops it
# from booting into an empty loop.
run() {
  local errfile
  errfile=$(mktemp)
  OUT=$(pool_table_parse "$1" 2>"$errfile")
  RC=$?
  ERR=$(cat "$errfile")
  rm -f "$errfile"
}

ok() { PASS=$((PASS + 1)); }
bad() { # <desc> <want> <got>
  FAIL=$((FAIL + 1))
  printf 'FAIL: %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"
}

want_rc() { # <desc> <expected>
  if [ "$RC" -eq "$2" ]; then ok; else bad "$1" "rc $2" "rc $RC"; fi
}
want_rows() { # <desc> <expected count>
  local n
  n=$(printf '%s' "$OUT" | grep -c . || true)
  if [ "$n" -eq "$2" ]; then ok; else bad "$1" "$2 row(s)" "$n row(s): $OUT"; fi
}
want_names() { # <desc> <space separated names in order>
  local got
  got=$(printf '%s\n' "$OUT" | grep . | cut -f1 | tr '\n' ' ')
  got="${got% }"
  if [ "$got" = "$2" ]; then ok; else bad "$1" "$2" "$got"; fi
}
want_reject() { # <desc> <substring the rejection must contain>
  case "$ERR" in
    *"$2"*) ok ;;
    *) bad "$1" "stderr containing '$2'" "${ERR:-<empty>}" ;;
  esac
}
want_field() { # <desc> <1-based column> <expected>
  local got
  got=$(printf '%s\n' "$OUT" | grep . | head -1 | cut -f"$2")
  if [ "$got" = "$3" ]; then
    ok
  else
    bad "$1" "column $2 = '$3'" "column $2 = '$got'"
  fi
}

# A fully specified pool: nothing defaulted, so the column-order assertions
# below can use a DISTINCT value per column. Two columns that share a value
# cannot detect a swap between them, which is the whole point of this row.
FULL='[{"name":"linux-ci","mig":"ci-linux-mig","region":"europe-west4",
  "slots":6,"min_hosts":1,"max_hosts":11,"drain_grace_seconds":901,
  "register_grace_seconds":602,"orphan_confirm_ticks":4,
  "recycle_max_unavailable":2,"host_os":"linux",
  "mints_registration_token":false,"role":"ci","beacon_interval":31,
  "pin_orphan_grace_seconds":903,"runner_labels":"self-hosted,linux-ci,Repo"}]'

# --- the column-order contract ------------------------------------------------
# controller-startup.sh reads these rows POSITIONALLY. Appending a column is
# safe; inserting one silently re-points every field after it at the wrong
# value, and the controller keeps running.
run "$FULL"
want_rc "a fully specified pool parses" 0
want_rows "a fully specified pool is one row" 1
want_field "column 1 is name" 1 linux-ci
want_field "column 2 is mig" 2 ci-linux-mig
want_field "column 3 is region" 3 europe-west4
want_field "column 4 is slots" 4 6
want_field "column 5 is min_hosts" 5 1
want_field "column 6 is max_hosts" 6 11
want_field "column 7 is drain_grace_seconds" 7 901
want_field "column 8 is register_grace_seconds" 8 602
want_field "column 9 is orphan_confirm_ticks" 9 4
want_field "column 10 is recycle_max_unavailable" 10 2
want_field "column 11 is host_os" 11 linux
want_field "column 12 is mints_registration_token" 12 false
want_field "column 13 is role" 13 ci
want_field "column 14 is beacon_interval" 14 31
want_field "column 15 is pin_orphan_grace_seconds" 15 903
want_field "column 16 is runner_labels" 16 "self-hosted,linux-ci,Repo"

# --- the four-pool shape this table exists for --------------------------------
# Order is contract, not incidental: the tick walks the table in order, and the
# merge-queue pools are declared last so a shared budget is spent on ordinary CI
# first when both are hungry in the same tick.
FOUR='[
  {"name":"linux-ci","mig":"m1","region":"r","runner_labels":"a"},
  {"name":"windows-ci","mig":"m2","region":"r","host_os":"windows",
   "mints_registration_token":true,"runner_labels":"b"},
  {"name":"linux-mq","mig":"m3","region":"r","role":"merge-queue",
   "runner_labels":"c"},
  {"name":"windows-mq","mig":"m4","region":"r","host_os":"windows",
   "role":"merge-queue","mints_registration_token":true,"runner_labels":"d"}]'
run "$FOUR"
want_rc "four pools parse" 0
want_rows "four pools are four rows" 4
want_names "the table keeps its declared order" \
  "linux-ci windows-ci linux-mq windows-mq"

# --- defaults -----------------------------------------------------------------
# A minimal row must land on the same values the single-pool module has always
# used, or migrating a repository to the table silently re-tunes its controller.
run '[{"name":"p","mig":"m","region":"r","runner_labels":"a"}]'
want_field "slots defaults to 1" 4 1
want_field "min_hosts defaults to 0" 5 0
want_field "drain grace defaults to 900" 7 900
want_field "register grace defaults to 600" 8 600
want_field "orphan confirm defaults to 3" 9 3
# Must equal the Terraform variable's default. A pool that omits the field and
# lands on 0 here cannot upgrade itself at all, and nothing goes red about it.
want_field "recycle_max_unavailable defaults to 1" 10 1
want_field "host_os defaults to linux" 11 linux
want_field "a pool does not mint tokens unless it says so" 12 false
want_field "role defaults to ci" 13 ci

# The two default sites must agree, and only a gate keeps them agreeing: the
# module renders an explicit value into metadata, so the jq fallback fires only
# for a pool entry that omits the field — a path no single-pool consumer walks
# and therefore nobody notices is wrong.
TFVARS="$(dirname "$0")/../../modules/ci-runner-host-pool/variables.tf"
POOLTABLE="$(dirname "$0")/../../modules/ci-runner-host-pool/scripts/pool-table.sh"
tf_default=$(awk '/^variable "recycle_max_unavailable"/{f=1} f && /^  default/{print $3; exit}' "$TFVARS")
jq_default=$(grep -o 'recycle_max_unavailable // [0-9][0-9]*' "$POOLTABLE" | grep -o '[0-9][0-9]*$')
if [ -n "$tf_default" ] && [ "$tf_default" = "$jq_default" ]; then ok; else
  bad "the Terraform default and the pool-table fallback agree" "$tf_default" "$jq_default"
fi

# The string "false" is TRUE in jq. A table that reached this parser through a
# loosely typed template would otherwise arm a pool to mint GitHub registration
# tokens because someone quoted a boolean.
run '[{"name":"p","mig":"m","region":"r","runner_labels":"a",
  "mints_registration_token":"false"}]'
want_field 'the string "false" does not arm token minting' 12 false
run '[{"name":"p","mig":"m","region":"r","runner_labels":"a",
  "mints_registration_token":true}]'
want_field "a real true does arm token minting" 12 true

# --- rejections, one per validation branch ------------------------------------
# Each of these is a row the controller must refuse to act on, and must SAY it
# refused: a rejection nobody can see is the dropped-pool failure above.
reject_case() { # <desc> <json> <reason substring>
  run "$2"
  want_rows "$1 — the row is dropped" 0
  want_reject "$1 — and reported" "$3"
}
# The name reaches two places that treat it as syntax rather than as text: the
# JSON of every metric point, and a `case` pattern. Both failures are silent and
# both are cross-pool — one bad name takes down the whole controller's telemetry
# or quietly steals another pool's completed jobs.
reject_case "a quote in a name would break every pool's metric flush" \
  '[{"name":"a\"b","mig":"m","region":"r","runner_labels":"a"}]' "name may use only"
reject_case "a glob in a name would claim another pool's outcomes" \
  '[{"name":"lin-*","mig":"m","region":"r","runner_labels":"a"}]' "name may use only"
reject_case "and a space, which is not a metric label value either" \
  '[{"name":"lin ci","mig":"m","region":"r","runner_labels":"a"}]' "name may use only"

reject_case "a pool with no mig names no machines" \
  '[{"name":"p","region":"r","runner_labels":"a"}]' "no mig"
reject_case "a pool with no region cannot be addressed" \
  '[{"name":"p","mig":"m","runner_labels":"a"}]' "no region"
reject_case "a pool with no labels matches nothing" \
  '[{"name":"p","mig":"m","region":"r"}]' "no runner_labels"
reject_case "a pool with empty labels matches nothing" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":""}]' "no runner_labels"
reject_case "an unknown host_os has no liveness rule" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a","host_os":"darwin"}]' \
  "neither linux nor windows"
reject_case "host_os is case sensitive, like the rest of the contract" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a","host_os":"Windows"}]' \
  "neither linux nor windows"
reject_case "an unknown role has no sizing rule" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a","role":"mergify"}]' \
  "neither ci nor merge-queue"
reject_case "a non-numeric slot count would break every comparison" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a","slots":"six"}]' \
  "not a number"
reject_case "a fractional grace would break every comparison" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a",
     "drain_grace_seconds":2.5}]' "not a number"
reject_case "a negative grace is not a number to [ -gt ]" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a",
     "register_grace_seconds":-1}]' "not a number"
# Zero slots divides the autoscaler's demand by zero and reads every host as
# fully registered, so nothing ever drains.
reject_case "zero slots is arithmetically valid and operationally dead" \
  '[{"name":"p","mig":"m","region":"r","runner_labels":"a","slots":0}]' \
  "at least 1"

# A row with no name at all is skipped WITHOUT a rejection line: there is
# nothing to name in the message, and the count it would inflate is per-pool.
run '[{"mig":"m","region":"r","runner_labels":"a"}]'
want_rows "an unnamed pool is not a pool" 0
if [ -z "$ERR" ]; then
  ok
else
  bad "an unnamed pool is skipped quietly" "" "$ERR"
fi

# --- one bad row must not take the others down --------------------------------
# The reason rejection is per-row rather than fatal. A typo in the newest pool
# must not stop the three that were draining hosts correctly this morning.
run '[
  {"name":"good-1","mig":"m1","region":"r","runner_labels":"a"},
  {"name":"broken","mig":"m2","region":"r","runner_labels":"b","slots":"x"},
  {"name":"good-2","mig":"m3","region":"r","runner_labels":"c"}]'
want_rc "a table with one bad row still serves the good ones" 0
want_names "the good rows survive, in order" "good-1 good-2"
want_reject "the bad row is named in the rejection" "reject:broken:"

# --- nothing to serve ---------------------------------------------------------
# Distinct from "a row was rejected": the controller has no work at all, which
# is a boot-time refusal rather than a per-tick warning.
run '[]'
want_rc "an empty table is not a controller" 1
run '{}'
want_rc "an object where an array belongs is not a controller" 1
run 'not json at all'
want_rc "unparseable metadata is not a controller" 1
want_reject "unparseable metadata says so" "not valid JSON"
run '[{"name":"only","mig":"m","region":"r"}]'
want_rc "a table whose every row is rejected is not a controller" 1

# --- the shifted-column failure -----------------------------------------------
# A tab inside a label list would move every later column of that row. jq's
# @tsv escapes it, and this asserts that it stays escaped rather than being
# re-expanded on the way through the shell.
run '[{"name":"p","mig":"m","region":"r","runner_labels":"a\tb"}]'
want_rows "a tab in a label list does not become a new column" 1
want_field "the tab stays escaped" 16 'a\tb'

# --- stdin --------------------------------------------------------------------
# The controller pipes the metadata value in rather than embedding it in an
# argument, so this is the path that actually runs in production.
OUT=$(printf '%s' "$FULL" | pool_table_parse 2>/dev/null)
if [ "$(printf '%s\n' "$OUT" | cut -f1)" = "linux-ci" ]; then
  ok
else
  bad "the table can be read from stdin" "linux-ci" "$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
