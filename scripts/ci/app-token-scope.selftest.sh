#!/usr/bin/env bash
# shellcheck disable=SC2016  # stub bodies, sed mutants and the pre-hook are literal code for an inner shell
# Every GitHub App installation token the fleet mints is DOWN-SCOPED (#1419).
#
# WHY THIS EXISTS
#
# `POST /app/installations/{id}/access_tokens` with no body returns a token
# carrying EVERY permission the App holds, on EVERY repository of the
# installation. Pool hosts mint one at boot while they run untrusted job code,
# and the controller mints one for every read. Once the runner Apps are granted
# Actions: write (#1413), an unscoped token would let job code cancel, re-run
# and dispatch workflows fleet-wide. Nothing about an unscoped token fails: it
# works BETTER, so no alert, check or log would ever notice a regression.
#
# So this asserts, on the shipping text, that every mint sends a body naming
# `repositories` and `permissions`, that no mint but the dedicated
# cancel/re-run one (gh_actions_token, #1413) asks for actions: write, and —
# by RUNNING the two mint functions against a stub curl — that a refused
# (422) scoped mint never falls back to an unscoped or wider one. The checker
# is then run against mutated copies, each of which must be caught.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS="$ROOT/modules/ci-runner-host-pool/scripts"
HOST="$SCRIPTS/host-startup.sh"
CTRL="$SCRIPTS/controller-startup.sh"

pass=0; fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   $1"; pass=$((pass + 1))
  else echo "FAIL $1: expected [$2] got [$3]"; fail=$((fail + 1)); fi
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ── structural checker ───────────────────────────────────────────────────────
# mint_violations <file>... — one line per violation, nothing when clean.
# A bash function is the unit: every function whose body names access_tokens
# must also carry `repositories`, `permissions` and a `-d` body flag, and must
# not ask for actions write unless it is gh_actions_token. A mint in any other
# language is reported outright: nothing here can read its body, so it is
# unreviewed until this checker learns to.
mint_violations() {
  local f
  for f in "$@"; do
    case "$f" in
      *.sh)
        awk -v file="${f##*/}" '
          function flush() {
            if (fn != "" && mint) {
              if (!scoped) print file ": " fn ": mint body names no repositories + permissions"
              # One body per mint: a second, body-less access_tokens curl (an
              # "unscoped fallback") is exactly what this must refuse.
              if (sends != mint) print file ": " fn ": " mint " mint(s) but " sends " scoped body flag(s)"
              if (fn != "gh_actions_token" && aw) print file ": " fn ": mint requests actions write"
            }
            fn = ""; body = ""; mint = 0; scoped = 0; sends = 0; aw = 0
          }
          # actions write in ANY form: a JSON literal, a key/value in a message
          # or jq program, a permission whose value is a variable, or a jq
          # --arg / --argjson carrying the word write.
          function actions_write(l) {
            return l ~ /actions(\\?")?[[:space:]]*[:=][[:space:]]*(\\?")?write/ \
                || l ~ /actions(\\?")?[[:space:]]*:[[:space:]]*(\\?")?\$/ \
                || l ~ /--arg(json)?[[:space:]]+[A-Za-z_]+[[:space:]]+['"'"'"]?"?write/
          }
          /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { flush(); fn = $1; sub(/\(\).*/, "", fn) }
          # Comments are not code: a comment naming a permission scopes nothing.
          fn != "" && !/^[[:space:]]*#/ { body = body "\n" $0 }
          # ONE line carrying both keys is the body being built; the words
          # scattered across a log message are not.
          fn != "" && !/^[[:space:]]*#/ && /repositories/ && /permissions/ { scoped = 1 }
          fn != "" && /access_tokens/ && !/^[[:space:]]*#/ { mint++ }
          fn != "" && /-d "\$body"/ && !/^[[:space:]]*#/ { sends++ }
          fn != "" && !/^[[:space:]]*#/ && actions_write($0) { aw = 1 }
          fn == "" && /access_tokens/ && !/^[[:space:]]*#/ { print file ": mint outside a function" }
          /^}/ { flush() }
          END { flush() }
        ' "$f"
        ;;
      *)
        if grep -n 'access_tokens' "$f" >/dev/null 2>&1; then
          echo "${f##*/}: unreviewed mint in a non-bash script"
        fi
        ;;
    esac
  done
}

ALL_SCRIPTS=()
while IFS= read -r f; do ALL_SCRIPTS+=("$f"); done < <(
  find "$ROOT/modules" -path '*/scripts/*' -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.py' \) | sort)

check "every module script mint is scoped" "" "$(mint_violations "${ALL_SCRIPTS[@]}")"

# The checker must actually see the two mints it is guarding, or a rename
# turns every assertion above vacuous.
mints_seen=$(awk '/access_tokens/ && !/^[[:space:]]*#/' "$HOST" "$CTRL" | wc -l | tr -d ' ')
check "host and controller mints are both present" "yes" "$([ "$mints_seen" -ge 2 ] && echo yes || echo no)"

# ── mutants: each must be caught ─────────────────────────────────────────────
mutant() { # <name> <file> <sed-expression>
  local m="$WORK/${2##*/}"
  sed "$3" "$2" >"$m"
  if cmp -s "$m" "$2"; then
    check "mutant $1 applies" "changed" "unchanged"
    return
  fi
  check "mutant $1 is caught" "caught" "$([ -n "$(mint_violations "$m")" ] && echo caught || echo missed)"
}
mutant "host body dropped"        "$HOST" '/-d "\$body"/d'
mutant "host repositories dropped" "$HOST" 's/{"repositories":\["%s"\],/{/'
mutant "host asks actions write"  "$HOST" 's/"administration":"write"/"administration":"write","actions":"write"/'
mutant "controller asks actions write" "$CTRL" 's/"checks":"read"/"checks":"read","actions":"write"/'
mutant "controller body dropped"  "$CTRL" '/-d "\$body"/d'
mutant "controller permissions dropped" "$CTRL" 's/permissions: \$p/scope: $p/'
mutant "controller body-less fallback mint" "$CTRL" \
  '/^    msg=\$(printf/i\    resp=$(curl -sS -X POST "https://api.github.com/app/installations/$INSTALL_ID/access_tokens")'
mutant "host body-less fallback mint" "$HOST" \
  '/^  code=\${resp##/a\  [ "$code" = 201 ] || resp=$(curl -sS -X POST "https://api.github.com/app/installations/$INSTALL_ID/access_tokens")'
mutant "controller actions write via --arg" "$CTRL" \
  's/--argjson p "\$perms" /--argjson p "$perms" --arg lvl write /'
mutant "controller actions from a variable" "$CTRL" \
  's/core) perms=.*/core) perms="{\\"actions\\":$lvl}" ;;/'

# #1413's dedicated mint is the ONE place actions: write is allowed, and it
# must stay exactly that: one repository, actions write, nothing else.
check "gh_actions_token is the only actions-write mint, and exactly that" \
  "body=\$(jq -cn --arg r \"\$REPO\" '{repositories: [\$r], permissions: {actions: \"write\"}}')" \
  "$(sed -n '/^gh_actions_token() {/,/^}/p' "$CTRL" | grep 'body=\$(jq' | sed 's/^ *//')"

# A mint in a PowerShell script is reported, not waved through.
printf 'Invoke-RestMethod "https://api.github.com/app/installations/1/access_tokens"\n' >"$WORK/mint.ps1"
check "mutant ps1 mint is caught" "caught" "$([ -n "$(mint_violations "$WORK/mint.ps1")" ] && echo caught || echo missed)"

# ── behaviour: run the mints against a stub curl ─────────────────────────────
fn() { sed -n "/^$1() {/,/^}/p" "$2"; }

# The stub records each call's -d body (or NOBODY) and answers from a script of
# status codes, one per call; the last code repeats.
STUBS='
timeout() { shift; "$@"; }
gcloud() { echo fake-key; }
openssl() { case "$1" in base64) cat ;; *) cat >/dev/null; printf sig ;; esac; }
curl() {
  local b=NOBODY a prev=""
  for a in "$@"; do [ "$prev" = -d ] && b="$a"; prev="$a"; done
  printf "%s\n" "$b" >>"$W/calls"
  local n; n=$(wc -l <"$W/calls" | tr -d " ")
  local code; code=$(sed -n "${n}p" "$W/codes"); [ -n "$code" ] || code=$(tail -n 1 "$W/codes")
  if [ "$code" = 201 ]; then printf "{\"token\":\"tok-%s\"}\n%s" "$n" "$code"
  else printf "{\"message\":\"stub %s\"}\n%s" "$code" "$code"; fi
}
event() { printf "%s %s\n" "$1" "$2" >>"$W/events"; }
throttled_event() { shift 2; event "$@"; }
gh_rate_note() { :; }
'

# run_mint <file> <codes...> — runs gh_token from <file>, prints "rc=<n>".
run_mint() {
  local file="$1"; shift
  W="$WORK/run"; rm -rf "$W"; mkdir -p "$W/state"
  printf '%s\n' "$@" >"$W/codes"
  : >"$W/calls"; : >"$W/events"
  W="$W" T_REPO="${T_REPO:-}" bash -c "
    set -uo pipefail
    STATE_DIR=\"\$W/state\"; LOG=/dev/null; REPO=\"\${T_REPO:-svc-repo}\"; REPO_FULL=\"own/\$REPO\"
    INSTALL_ID=11; APP_ID=22; KEY_SECRET=k; CURL_TIMEOUTS=(); GH_TOKEN=''; GH_TOKEN_EXPIRY=0
    log() { :; }
    $STUBS
    $(fn gh_token "$file")
    ${T_PRE:-}
    out=\$(gh_token); rc=\$?
    printf 'rc=%s out=%s' \"\$rc\" \"\$out\"
  " 2>&1
}
calls() { tr -d ' ' <"$WORK/run/calls" | paste -sd '|' -; }

FULL='{"repositories":["svc-repo"],"permissions":{"actions":"read","administration":"write","checks":"read","pull_requests":"read"}}'
CORE='{"repositories":["svc-repo"],"permissions":{"actions":"read","administration":"write"}}'
ADMIN='{"repositories":["svc-repo"],"permissions":{"administration":"write"}}'
HOSTB='{"repositories":["svc-repo"],"permissions":{"administration":"write"}}'

# Controller, granted everything: one mint, the full scoped set.
r=$(run_mint "$CTRL" 201)
check "controller: granted mint succeeds" "rc=0 out=tok-1" "$r"
check "controller: granted mint body" "$FULL" "$(calls)"

# Controller, optional reads not granted: narrows to the core pair, WARNING.
r=$(run_mint "$CTRL" 422 201)
check "controller: 422 narrows and succeeds" "rc=0 out=tok-2" "$r"
check "controller: 422 retries NARROWER, never unscoped" "$FULL|$CORE" "$(calls)"
check "controller: narrowing is a WARNING" "WARNING gh-token-scope-narrowed" "$(cat "$WORK/run/events")"
check "controller: narrowing is remembered" "yes" "$([ -s "$WORK/run/state/gh-token-narrowed" ] && echo yes || echo no)"

# Controller, Actions: read missing (or repo not selected): third tier,
# administration:write alone, so drain/cordon/orphan/registration survive.
r=$(run_mint "$CTRL" 422 422 201)
check "controller: core 422 narrows to admin and succeeds" "rc=0 out=tok-3" "$r"
check "controller: tiers only ever narrow" "$FULL|$CORE|$ADMIN" "$(calls)"
check "controller: each narrowing is a WARNING" \
  "WARNING gh-token-scope-narrowed|WARNING gh-token-scope-narrowed" "$(paste -sd '|' - <"$WORK/run/events")"
check "controller: admin tier is remembered" "admin" "$(cut -d' ' -f1 <"$WORK/run/state/gh-token-narrowed")"

# Controller, even administration:write refused: fails loud, no fourth and no
# unscoped call.
r=$(run_mint "$CTRL" 422)
check "controller: admin 422 is a refused mint" "rc=1 out=" "$r"
check "controller: admin 422 never widens" "$FULL|$CORE|$ADMIN" "$(calls)"
check "controller: admin 422 is an ERROR" \
  "WARNING gh-token-scope-narrowed|WARNING gh-token-scope-narrowed|ERROR gh-token-scope-refused" \
  "$(paste -sd '|' - <"$WORK/run/events")"

# Controller, a narrowing recorded this hour: straight to that tier.
r=$(T_PRE='printf "core %s" "$(date +%s)" >"$STATE_DIR/gh-token-narrowed"' run_mint "$CTRL" 201)
check "controller: remembered core narrowing mints core once" "rc=0 out=tok-1 $CORE" "$r $(calls)"
r=$(T_PRE='printf "admin %s" "$(date +%s)" >"$STATE_DIR/gh-token-narrowed"' run_mint "$CTRL" 201)
check "controller: remembered admin narrowing mints admin once" "rc=0 out=tok-1 $ADMIN" "$r $(calls)"
r=$(T_PRE='printf "admin %s" "$(( $(date +%s) - 7200 ))" >"$STATE_DIR/gh-token-narrowed"' run_mint "$CTRL" 201)
check "controller: an expired narrowing retries the full set" "rc=0 out=tok-1 $FULL" "$r $(calls)"

# Behavioural mutant: a third tier that still asks for actions:read is not a
# third tier, and the tier test must see it.
sed "s/\*) perms='{\"administration\":\"write\"}' ;;/*) perms='{\"actions\":\"read\",\"administration\":\"write\"}' ;;/" \
  "$CTRL" >"$WORK/ctrl-mutant.sh"
if cmp -s "$WORK/ctrl-mutant.sh" "$CTRL"; then
  check "mutant third tier keeps actions:read applies" "changed" "unchanged"
else
  run_mint "$WORK/ctrl-mutant.sh" 422 422 201 >/dev/null
  check "mutant third tier keeps actions:read is caught" "caught" \
    "$([ "$(calls)" != "$FULL|$CORE|$ADMIN" ] && echo caught || echo missed)"
fi

# Controller, a transient failure: no retry at all.
r=$(run_mint "$CTRL" 502)
check "controller: 5xx is not retried" "rc=1 out= $FULL" "$r $(calls)"

# Host: one mint, Administration: write only.
r=$(run_mint "$HOST" 201)
check "host: granted mint succeeds" "rc=0 out=tok-1" "$r"
check "host: mint body" "$HOSTB" "$(calls)"

# Host: refused is fatal to the boot, never retried unscoped.
r=$(run_mint "$HOST" 422)
check "host: 422 is refused, one call only" "rc=1 out= $HOSTB" "$r $(calls)"

# Host: a repository name that could break the JSON body mints nothing.
r=$(T_REPO='x","y' run_mint "$HOST" 201)
check "host: malformed repo mints nothing" "rc=1 out= " "$r $(calls)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
