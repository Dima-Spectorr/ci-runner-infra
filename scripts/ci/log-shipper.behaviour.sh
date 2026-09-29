#!/usr/bin/env bash
# What /opt/ci/log-shipper.sh DOES with the journal, as opposed to what it says.
#
# WHY (#1403). The slot reset, the sweeps and the pin tools report through
# `logger`, and until the shipper existed none of it reached Cloud Logging: a
# condemned slot, or a reset failing closed on every host, could be read only
# from a shell on the VM. The shipper is the one thing between those lines and
# the alert that watches them, and every way it can be wrong is silent -- a
# filter that lets a job forge a line, a cursor that moves past a batch that was
# never written, a batch shipped from its END so the middle of a backlog is lost,
# a message that breaks the JSON. None of that is visible from the host, which
# keeps working either way.
#
# So this EXTRACTS the script exactly as host-startup.sh writes it (a quoted
# here-document, so the body is the file byte for byte), runs it against a stub
# journal, a stub metadata server and a stub Logging endpoint, and asserts on
# the payload and the cursor. Then it breaks the script the way a later edit
# plausibly would, and asserts the suite notices every break: a behaviour check
# that passes on a broken shipper is not evidence.
#
# No root, no network, no journald: the three stubs are on PATH.

# The mutations below edit the TEXT of the shipper, in which `$token` and
# `$MAX` are literal characters; expanding them here would edit nothing.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required (the host image installs it)"; exit 1; }

TOP=$(mktemp -d) || exit 1
trap 'rm -rf "$TOP"' EXIT

SHIPPER="$TOP/log-shipper.sh"
awk '
  $0 == "  cat >/opt/ci/log-shipper.sh <<'"'"'EOF'"'"'" { on = 1; next }
  on && $0 == "EOF" { exit }
  on { print }
' "$SCRIPT" >"$SHIPPER"
# An empty extraction means the anchor moved; an empty script "ships nothing"
# and would fail every assertion for the wrong reason, or pass a mutant.
[ -s "$SHIPPER" ] || { echo "FAIL: could not extract log-shipper.sh from host-startup.sh"; exit 1; }
bash -n "$SHIPPER" || { echo "FAIL: the generated log-shipper.sh does not parse"; exit 1; }

# --- the stubs ------------------------------------------------------------------
BIN="$TOP/bin"
mkdir -p "$BIN"

cat >"$BIN/journalctl" <<'STUB'
#!/usr/bin/env bash
# Records its argv, then replays the fixture journal after --after-cursor,
# honouring --lines= the way systemd 255 does: +N is the oldest N, N the newest.
printf '%s\n' "$@" >"$STUB_DIR/journalctl.argv"
after="" lines=""
for a in "$@"; do
  case "$a" in
    --after-cursor=*) after="${a#--after-cursor=}" ;;
    --lines=*) lines="${a#--lines=}" ;;
  esac
done
# The failure modes the shipper must tell apart, as journalctl reports them.
if [ -f "$STUB_DIR/jfail" ]; then echo "Failed to open journal: Too many open files" >&2; exit 1; fi
if [ "$after" = rejected ]; then echo "Failed to seek to cursor: Invalid argument" >&2; exit 1; fi
if [ -z "$after" ]; then
  cat "$STUB_DIR/journal.jsonl"
else
  awk -v c="\"__CURSOR\":\"$after\"" 'found { print; next } index($0, c) { found = 1 }' "$STUB_DIR/journal.jsonl"
fi >"$STUB_DIR/jsel"
case "$lines" in
  +*) awk -v n="${lines#+}" 'NR <= n' "$STUB_DIR/jsel" ;;
  '') cat "$STUB_DIR/jsel" ;;
  *) tail -n "$lines" "$STUB_DIR/jsel" ;;
esac
# A journal that stalls mid-entry: a line cut short, then nothing until killed.
if [ -f "$STUB_DIR/jhang" ]; then printf '{"__CURSOR":"cut","MESS'; exec sleep 30; fi
STUB

cat >"$BIN/curl" <<'STUB'
#!/usr/bin/env bash
# Metadata answers by path; a POST to the Logging stub stores its body and the
# -K config it was handed, and answers with the code in $STUB_DIR/http.
url="" out="" kfile=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o) i=$((i + 1)); out="${args[$i]}" ;;
    -K) i=$((i + 1)); kfile="${args[$i]}" ;;
    http://* | https://*) url="${args[$i]}" ;;
  esac
done
printf '%s\n' "$*" >>"$STUB_DIR/curl.argv"
case "$url" in
  */project/project-id) echo proj-x ;;
  */instance/id) echo 1234567 ;;
  */instance/zone) echo projects/99/zones/zone-a ;;
  */instance/name) echo host-a ;;
  */instance/attributes/ci-pool) echo pool-a ;;
  */instance/service-accounts/default/token)
    [ -f "$STUB_DIR/no-token" ] && exit 22
    echo '{"access_token":"tok-SECRET-123","expires_in":3599,"token_type":"Bearer"}' ;;
  https://logging.stub/v2/entries:write)
    n=$(find "$STUB_DIR" -maxdepth 1 -name 'post.*.json' | wc -l)
    n=$((n + 1))
    cat >"$STUB_DIR/post.$n.json"
    [ -n "$kfile" ] && cat "$kfile" >"$STUB_DIR/post.$n.k"
    [ -n "$out" ] && echo '{}' >"$out"
    printf '%s' "$(cat "$STUB_DIR/http")" ;;
  *) exit 7 ;;
esac
STUB

cat >"$BIN/logger" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_DIR/notes"
STUB
chmod 0755 "$BIN"/*

# --- the fixture journal ----------------------------------------------------------
# e3 carries a quote, a newline and a BEL; e4 is a MESSAGE journald stored as
# bytes (not valid UTF-8), which `-o json` renders as an array of numbers; e5 is
# longer than the shipper's cut.
long=$(head -c 2500 /dev/zero | tr '\0' x)
fixture() { # <cursor> <identifier> <message-json> [<priority>]
  printf '{"__CURSOR":"%s","__REALTIME_TIMESTAMP":"1790000000123456","__MONOTONIC_TIMESTAMP":"%s","_BOOT_ID":"b00t","PRIORITY":"%s","_UID":"0","SYSLOG_IDENTIFIER":"%s","MESSAGE":%s}\n' \
    "$1" "${1#c}000" "${4:-5}" "$2" "$3"
}
base_journal() {
  fixture c1 ci-slot-reset '"slot 1: /run/user/1001/docker.sock reads as foreign"'
  fixture c2 ci-slot-sweep '"slot 2: 4 consecutive failures to reach a clean state — taking it out of service"' 4
  fixture c3 ci-slot-reset '"slot 3: a \"quoted\" name\nforged: host ready\u0007"'
  fixture c4 ci-pin-hold '[115,108,111,116,10,255,52]'
  fixture c5 ci-pin-sweep "\"$long\""
}

# --- the suite ------------------------------------------------------------------
# run_suite <shipper> -> prints one line per failed assertion, nothing on success.
run_suite() {
  local sh="$1" SD st f p
  SD=$(mktemp -d "$TOP/run.XXXXXX")
  st="$SD/state"
  f="$SD/fails"
  : >"$f"
  fail() { printf '%s\n' "$1" >>"$f"; }
  ship() {
    env PATH="$BIN:$PATH" STUB_DIR="$SD" CI_LOG_SHIPPER_STATE="$st" \
      CI_LOG_SHIPPER_ENDPOINT=https://logging.stub/v2/entries:write \
      CI_LOG_SHIPPER_METADATA=http://md.stub/computeMetadata/v1 \
      CI_LOG_SHIPPER_MAX="${MAX:-200}" CI_LOG_SHIPPER_JOURNAL_TIMEOUT="${JT:-20}" bash "$sh" >/dev/null 2>&1
  }
  posts() { find "$SD" -maxdepth 1 -name 'post.*.json' | wc -l; }
  cursor() { cat "$st/cursor" 2>/dev/null; }

  base_journal >"$SD/journal.jsonl"

  # 1. A first run ships the boot's lines, once, and saves the cursor.
  echo 200 >"$SD/http"
  ship
  [ "$(posts)" -eq 1 ] || fail "a first run with five lines did not make exactly one write"
  p="$SD/post.1.json"
  jq -e . "$p" >/dev/null 2>&1 || fail "the body is not valid JSON"
  [ "$(cursor)" = c5 ] || fail "an accepted write did not move the cursor to its last entry (got '$(cursor)')"
  grep -qx -- '--boot' "$SD/journalctl.argv" || fail "a first run (no cursor) does not start from this boot"

  # The match set: the four slot tools, root only, and nothing else.
  local want got
  want=$(printf '%s\n' _UID=0 SYSLOG_IDENTIFIER=ci-pin-hold SYSLOG_IDENTIFIER=ci-pin-sweep \
    SYSLOG_IDENTIFIER=ci-slot-reset SYSLOG_IDENTIFIER=ci-slot-sweep | LC_ALL=C sort)
  got=$(grep -v -- '^--' "$SD/journalctl.argv" | LC_ALL=C sort)
  [ "$got" = "$want" ] || fail "journalctl matches are not exactly the four slot-tool identifiers AND _UID=0: $(printf '%s' "$got" | tr '\n' ' ')"
  grep -qx -- '--output=json' "$SD/journalctl.argv" || fail "journalctl is not asked for JSON"

  [ "$(jq -r .logName "$p")" = projects/proj-x/logs/ci-slot-lifecycle ] || fail "logName is $(jq -r .logName "$p")"
  [ "$(jq -c .resource "$p")" = '{"type":"gce_instance","labels":{"project_id":"proj-x","instance_id":"1234567","zone":"zone-a"}}' ] ||
    fail "resource is $(jq -c .resource "$p") -- the zone must be its short name"
  [ "$(jq -c .labels "$p")" = '{"pool":"pool-a","host":"host-a"}' ] || fail "the pool/host labels are $(jq -c .labels "$p")"
  [ "$(jq -r .partialSuccess "$p")" = true ] || fail "partialSuccess is off -- one bad entry would drop the batch"
  [ "$(jq '.entries | length' "$p")" = 5 ] || fail "$(jq '.entries | length' "$p") entries shipped, want 5"
  [ "$(jq -r '[.entries[].jsonPayload.identifier] | join(",")' "$p")" = ci-slot-reset,ci-slot-sweep,ci-slot-reset,ci-pin-hold,ci-pin-sweep ] ||
    fail "entries are not in journal order"
  [ "$(jq -r '.entries[0].jsonPayload.message' "$p")" = 'slot 1: /run/user/1001/docker.sock reads as foreign' ] ||
    fail "a plain message did not arrive intact"
  [ "$(jq -r '.entries[1].severity' "$p")/$(jq -r '.entries[0].severity' "$p")" = WARNING/NOTICE ] ||
    fail "PRIORITY is not mapped to severity"
  [ "$(jq -r '.entries[0].timestamp' "$p")" = 2026-09-21T14:13:20.123456Z ] ||
    fail "the timestamp is $(jq -r '.entries[0].timestamp' "$p"), want the journal's own to the microsecond"
  [ "$(jq -r '.entries[1].insertId' "$p")" = b00t-2000 ] || fail "insertId is not boot id + monotonic stamp, so a resend is not collapsed"
  [ "$(jq -r '.entries[2].jsonPayload.message' "$p")" = 'slot 3: a "quoted" name forged: host ready ' ] ||
    fail "control characters survived into the message: $(jq -c '.entries[2].jsonPayload.message' "$p")"
  [ "$(jq -r '.entries[3].jsonPayload.message' "$p")" = slot4 ] || fail "a byte-array message is not reduced to printable ASCII"
  [ "$(jq -r '.entries[4].jsonPayload.message | length' "$p")" = 2000 ] || fail "a long message is not cut at 2000"
  [ "$(jq '[.entries[] | keys[]] | unique | join(",")' -r "$p")" = insertId,jsonPayload,severity,timestamp ] ||
    fail "an entry carries fields beyond insertId/jsonPayload/severity/timestamp: $(jq -c '[.entries[] | keys[]] | unique' "$p")"
  # The token reaches the endpoint, and never through argv.
  grep -q 'Authorization: Bearer tok-SECRET-123' "$SD/post.1.k" 2>/dev/null || fail "the bearer token was not handed to curl via -K"
  ! grep -q tok-SECRET "$SD/curl.argv" || fail "the bearer token appears in curl's argv"

  # 2. Nothing new: no write at all.
  ship
  [ "$(posts)" -eq 1 ] || fail "a run with nothing new still wrote"

  # 3. Endpoint down: the cursor stays and the SAME batch goes next time.
  fixture c6 ci-slot-reset '"slot 1: refusing to call this slot clean"' >>"$SD/journal.jsonl"
  fixture c7 ci-slot-reset '"slot 2: fine"' >>"$SD/journal.jsonl"
  echo 503 >"$SD/http"
  ship
  [ "$(cursor)" = c5 ] || fail "a 503 moved the cursor -- those lines are lost"
  echo 000 >"$SD/http"
  ship
  [ "$(cursor)" = c5 ] || fail "an unreachable endpoint moved the cursor"
  echo 200 >"$SD/http"
  ship
  [ "$(cursor)" = c7 ] || fail "the retry after an outage did not move the cursor"
  local last; last=$(posts)
  [ "$(jq -r '[.entries[].jsonPayload.message] | join("|")' "$SD/post.$last.json")" = 'slot 1: refusing to call this slot clean|slot 2: fine' ] ||
    fail "the retry did not resend the refused batch, in order"
  [ "$(jq -r '[.entries[].jsonPayload.message] | join("|")' "$SD/post.2.json")" = "$(jq -r '[.entries[].jsonPayload.message] | join("|")' "$SD/post.$last.json")" ] ||
    fail "the refused batch and its retry differ"

  # 4. A batch Logging will never accept is dropped, not resent forever.
  fixture c8 ci-slot-reset '"slot 1: poison"' >>"$SD/journal.jsonl"
  echo 400 >"$SD/http"
  ship
  [ "$(cursor)" = c8 ] || fail "a 400 left the cursor behind -- one bad batch would wedge the shipper forever"

  # 5. No token: nothing sent, nothing lost.
  fixture c9 ci-slot-reset '"slot 1: after"' >>"$SD/journal.jsonl"
  last=$(posts)
  : >"$SD/no-token"
  echo 200 >"$SD/http"
  ship
  if [ "$(posts)" -ne "$last" ] || [ "$(cursor)" != c8 ]; then fail "a run with no token wrote, or moved the cursor"; fi
  rm -f "$SD/no-token"
  ship
  [ "$(cursor)" = c9 ] || fail "the run after the token came back did not ship"

  # 6. Bounded, and a backlog is shipped from its START.
  {
    fixture c10 ci-slot-reset '"b1"'
    fixture c11 ci-slot-reset '"b2"'
    fixture c12 ci-slot-reset '"b3"'
  } >>"$SD/journal.jsonl"
  MAX=2 ship
  last=$(posts)
  [ "$(jq -r '[.entries[].jsonPayload.message] | join(",")' "$SD/post.$last.json")" = b1,b2 ] ||
    fail "a bounded run did not ship the OLDEST entries after the cursor"
  [ "$(cursor)" = c11 ] || fail "a bounded run moved the cursor past what it shipped"
  MAX=2 ship
  last=$(posts)
  [ "$(jq -r '[.entries[].jsonPayload.message] | join(",")' "$SD/post.$last.json")" = b3 ] ||
    fail "the rest of the backlog did not follow on the next run"
  grep -qx -- '--after-cursor=c11' "$SD/journalctl.argv" || fail "the next run did not resume from the saved cursor"
  grep -qx -- '--lines=+2' "$SD/journalctl.argv" || fail "journalctl is not asked for the OLDEST n (--lines=+N)"

  # 7. journalctl fails for a reason that is not the cursor: the cursor stays.
  # Deleting it on any non-zero exit restarts from --boot, and a failure that
  # repeats then never moves again (#1410 review F2).
  fixture c13 ci-slot-reset '"after a failure"' >>"$SD/journal.jsonl"
  : >"$SD/jfail"
  ship
  [ "$(cursor)" = c12 ] || fail "a journalctl failure that is not about the cursor lost the cursor (now '$(cursor)')"
  rm -f "$SD/jfail"
  ship
  [ "$(cursor)" = c13 ] || fail "the run after a journalctl failure did not resume from the cursor"

  # 8. A cursor journalctl refuses to seek to: reset, and start over from the boot.
  printf '%s' rejected >"$st/cursor"
  ship
  [ -e "$st/cursor" ] && fail "a cursor journalctl refused was kept -- the shipper would be stuck on it forever"
  ship
  grep -qx -- '--boot' "$SD/journalctl.argv" || fail "after a refused cursor the next run did not restart from the boot"

  # 9. Out of time mid-entry: ship the whole entries, keep the cut one for later.
  base_journal >"$SD/journal.jsonl"
  printf '%s' c2 >"$st/cursor"
  : >"$SD/jhang"
  last=$(posts)
  JT=2 ship
  rm -f "$SD/jhang"
  if [ "$(posts)" -le "$last" ]; then
    fail "a timed-out read shipped nothing -- a slow journal would never make progress"
  else
    [ "$(jq '.entries | length' "$SD/post.$(posts).json")" = 3 ] ||
      fail "a timed-out read did not ship exactly its three complete entries"
  fi
  [ "$(cursor)" = c5 ] || fail "a timed-out read did not move the cursor to its last COMPLETE entry (got '$(cursor)')"

  # 10. More than a pipe buffer (64 KiB) in one batch: all of it, in one write.
  : >"$SD/journal.jsonl"
  local i big
  big=$(head -c 1900 /dev/zero | tr '\0' y)
  for i in $(seq 100 139); do fixture "c$i" ci-slot-reset "\"$big\""; done >"$SD/journal.jsonl"
  rm -f "$st/cursor"
  ship
  [ "$(jq '.entries | length' "$SD/post.$(posts).json")" = 40 ] || fail "a batch over 64 KiB was not shipped whole"
  [ "$(cursor)" = c139 ] || fail "a batch over 64 KiB did not move the cursor to its end"

  cat "$f"
}

PASS=0
FAIL=0

out=$(run_suite "$SHIPPER")
if [ -z "$out" ]; then
  PASS=$((PASS + 1))
else
  while IFS= read -r l; do [ -n "$l" ] && { FAIL=$((FAIL + 1)); echo "FAIL: $l"; }; done <<<"$out"
fi

# --- mutations: each must make the suite fail -----------------------------------
mutate() { # <description> <sed program>
  local m="$TOP/mutant.sh"
  sed "$2" "$SHIPPER" >"$m"
  if cmp -s "$m" "$SHIPPER"; then
    FAIL=$((FAIL + 1)); echo "FAIL: mutation '$1' did not apply -- its anchor moved"; return
  fi
  if [ -n "$(run_suite "$m")" ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: the suite passes a shipper with '$1'"; fi
}

mutate "any uid may write the lines"         's/^matches+=(_UID=0)$/:/'
mutate "the whole journal is read"           's/^for id in "\${IDENTIFIERS\[@\]}"; do matches+=.*$/:/'
mutate "an extra identifier is shipped"      's/^IDENTIFIERS=(ci-slot-reset /IDENTIFIERS=(ci-controller ci-slot-reset /'
mutate "the cursor moves on any answer"      's/^  \*) note "entries:write -> HTTP/  *) advance; note "entries:write -> HTTP/'
mutate "an accepted write keeps the cursor"  's/^  200) advance ;;$/  200) ;;/'
mutate "a 400 is resent forever"             '/^    advance ;;$/d'
mutate "the batch is unbounded"              's/ "--lines=+\$MAX" / /'
mutate "a backlog is shipped from its end"   's/"--lines=+\$MAX"/"--lines=$MAX"/'
mutate "the cursor goes on any failure"      's/if \[ -n "\$cursor" \] && grep -q .Failed to seek to cursor. "\$errf" 2>\/dev\/null; then/if [ -n "$cursor" ]; then/'
mutate "a refused cursor is kept"            's/^      rm -f "\$cursor_file"$/      :/'
mutate "a timed-out read is discarded"       's/-- shipping the complete entries it wrote" ;;/-- retrying"; exit 0 ;;/'
mutate "one bad line fails the whole batch"  's/\[inputs | fromjson? | select(type == "object")\] | map(/[inputs | fromjson] | map(/'
mutate "control characters pass through"     's/map(if \. < 32 or \. == 127 then 32 else \. end)/map(.)/'
mutate "messages are not cut"                's/| implode | \.\[0:\$n\];/| implode;/'
mutate "the token goes in argv"              's/-K <(printf .header = "Authorization: Bearer %s"\\n. "\$token")/-H "Authorization: Bearer $token"/'
mutate "no insertId"                         '/^      insertId: /d'
mutate "a first run skips the boot"          's/else opts+=(--boot); fi/fi/'

printf 'log-shipper behaviour: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
