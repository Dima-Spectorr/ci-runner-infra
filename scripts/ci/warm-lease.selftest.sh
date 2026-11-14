#!/usr/bin/env bash
# Behavioural self-test for the cache warmer's single-flight lease
# (modules/ci-runner-cache-warmer/main.tf: claim_common, claim_script,
# mark_script).
#
# cache-warmer.selftest.sh checks the TEXT of those scripts. This one RENDERS
# them the way Terraform would — every `${local.*}` / `${var.*}` the scripts use
# replaced with a test value, `%%{` unescaped to `%{` — and RUNS them against a
# fake GCS: a directory standing in for the bucket, served by a `curl` on PATH
# that honours ifGenerationMatch=0 (412 when the name exists) and answers GETs
# with timeCreated. The question it answers is the one the lease exists for
# (IntegrateIT #33507): does a second warm of a DIFFERENT commit skip while the
# first runs, and does a warm after a finished or dead one warm normally?
#
# Any interpolation left unrendered fails the test rather than running a script
# with a literal `${local.x}` in it, so a new reference in the scripts must be
# taught to render() below.
# shellcheck disable=SC2016

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN="$HERE/../../modules/ci-runner-cache-warmer/main.tf"
[ -f "$MAIN" ] || { echo "FAIL: missing $MAIN"; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

HOLD=3600
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STAGED="$T/staged"
STORE="$T/store"
mkdir -p "$T/bin" "$STAGED" "$STORE"

# The body of a `<<-EOT` local, with the heredoc's 4-space indent stripped.
heredoc() { # <file> <local name>
  awk -v want="$2" '
    $0 ~ ("^  " want " = <<-EOT$") { inside = 1; next }
    inside && /^  EOT$/ { exit }
    inside { sub(/^    /, ""); print }
  ' "$1"
}

render() { # <file> <local name>
  local common body
  common=$(heredoc "$1" claim_common)
  body=$(heredoc "$1" "$2")
  [ -n "$common" ] && [ -n "$body" ] || return 1
  # Quoted: bash 5.2's patsub_replacement turns an unquoted `&` in the
  # replacement into the matched text, and claim_common's URLs are full of `&`.
  body=${body//'${local.claim_common}'/"$common"}
  body=${body//'${local.skip_marker}'/$STAGED/skip}
  body=${body//'${local.build_failed}'/$STAGED/build-failed}
  body=${body//'${local.lease_file}'/$STAGED/lease}
  body=${body//'${local.claim_inflight_s}'/$HOLD}
  body=${body//'${local.claim_slot_seconds}'/43200}
  body=${body//'${local.claim_prefix_enc}'/turbo%2Fo%2Fr%2Fwarm-claims%2F}
  body=${body//'${var.cache_bucket}'/bucket}
  body=${body//'%%{'/'%{'}
  case "$body" in *'${local.'* | *'${var.'*) return 1 ;; esac
  printf '%s\n' "$body"
}

render "$MAIN" claim_script >"$T/claim.sh" || { echo "FAIL: claim_script did not render (an interpolation this test does not know)"; exit 1; }
render "$MAIN" mark_script >"$T/mark.sh" || { echo "FAIL: mark_script did not render (an interpolation this test does not know)"; exit 1; }

# gcloud: a token, unless FAKE_NO_TOKEN.
cat >"$T/bin/gcloud" <<'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_NO_TOKEN:-}" ] && exit 1
echo fake-token
FAKE

# curl: the fake bucket. An object is a file named by its decoded name; its
# mtime is its timeCreated. FAKE_BROKEN answers every request with a 503.
cat >"$T/bin/curl" <<'FAKE'
#!/usr/bin/env bash
method=GET out="" fmt="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift ;;
    -o) out=$2; shift ;;
    -w) fmt=$2; shift ;;
    -K | -H | --data-binary | --proto | --connect-timeout | --max-time) shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
emit() { # <code> <body>
  if [ "$out" != /dev/null ]; then printf '%s' "$2"; fi
  if [ -n "$fmt" ]; then
    case "$fmt" in '\n'*) printf '\n' ;; esac
    printf '%s' "$1"
  fi
}
if [ -n "${FAKE_BROKEN:-}" ]; then emit 503 '{"error":{}}'; exit 0; fi
if [ "$method" = POST ]; then
  # Create-only is the warmer's whole grant: a POST without the precondition
  # would be an overwrite, which the real bucket refuses this identity.
  case "$url" in *'ifGenerationMatch=0&'* | *'ifGenerationMatch=0') ;; *) emit 403 '{}'; exit 0 ;; esac
  name=${url##*name=}
  name=${name//%2F//}
  f="$FAKE_STORE/$name"
  if [ -e "$f" ]; then emit 412 '{}'; exit 0; fi
  mkdir -p "$(dirname "$f")"; : >"$f"
  emit 200 '{}'; exit 0
fi
name=${url##*/o/}
name=${name//%2F//}
f="$FAKE_STORE/$name"
if [ -e "$f" ]; then
  emit 200 "{\"name\": \"$name\", \"timeCreated\": \"$(date -u -r "$f" +%Y-%m-%dT%H:%M:%S.000Z)\"}"
else
  emit 404 '{"error":{"code":404}}'
fi
FAKE
chmod +x "$T/bin/gcloud" "$T/bin/curl"

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
LEASES="$STORE/turbo/o/r/warm-claims"

warm() { # <claim|mark> <sha> -> the script's output; status in $?
  PATH="$T/bin:$PATH" FAKE_STORE="$STORE" WARM_SHA="$2" WARM_BUILD_ID="b-$2" bash "$T/$1.sh" 2>&1
}
reset() { rm -rf "${STORE:?}"/* "$STAGED"/*; }
skipped() { [ -f "$STAGED/skip" ]; }
lease() { cat "$STAGED/lease" 2>/dev/null; }
# A lease object of window <w> index <n>, created <age> seconds ago.
plant() { # <w> <n> <age> [done]
  mkdir -p "$LEASES"
  touch -d "@$(( $(date -u +%s) - $3 ))" "$LEASES/inflight-$1-$2"
  [ -z "${4:-}" ] || : >"$LEASES/inflight-$1-$2-done"
}
win() { echo $(( $(date -u +%s) / HOLD )); }

# 1. Nothing running: the warm takes a lease and builds.
reset
warm claim "$SHA1" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && ! skipped && [ "$(lease)" = "$(win)-0" ] && [ -e "$LEASES/inflight-$(win)-0" ]; then ok; else
  bad "with no warm running, the claim did not take lease $(win)-0 and build (rc=$rc, lease='$(lease)')"
fi

# 2. THE MAIN FLOW: a warm of a DIFFERENT commit starts while that one runs, and
#    skips install, build and publish with exit 0.
mv "$STAGED/lease" "$T/lease-a"
o=$(warm claim "$SHA2"); rc=$?
if [ "$rc" -eq 0 ] && skipped && [ -z "$(lease)" ] && [ ! -e "$LEASES/inflight-$(win)-1" ]; then ok; else
  bad "a warm of another commit ran beside a live one (rc=$rc): $o"
fi
# ...and its mark step releases nothing that is not its own.
warm mark "$SHA2" >/dev/null
if [ ! -e "$LEASES/inflight-$(win)-0-done" ]; then ok; else
  bad "a skipped warm's mark step released the running warm's lease"
fi

# 3. The first warm finishes; its mark releases the lease and marks its commit.
rm -f "$STAGED/skip"; mv "$T/lease-a" "$STAGED/lease"
warm mark "$SHA1" >/dev/null
if [ -e "$LEASES/inflight-$(win)-0-done" ] && ls "$LEASES/$SHA1"-*-done >/dev/null 2>&1; then ok; else
  bad "the mark step did not release the lease and mark the commit warmed"
fi

# 4. ...and the next warm, of another commit, builds normally on the next n.
warm claim "$SHA2" >/dev/null
if ! skipped && [ "$(lease)" = "$(win)-1" ]; then ok; else
  bad "a warm after a finished one did not build (lease='$(lease)')"
fi

# 5. A finished warm whose BUILD failed still releases, and is not marked warmed.
: >"$STAGED/build-failed"
warm mark "$SHA2" >/dev/null
if [ -e "$LEASES/inflight-$(win)-1-done" ] && ! ls "$LEASES/$SHA2"-*-done >/dev/null 2>&1; then ok; else
  bad "a lint-failed warm kept its lease, or was marked warmed"
fi

# 6. The commit already warmed in this slot is skipped (the per-commit check).
warm claim "$SHA1" >/dev/null
if skipped && [ -z "$(lease)" ]; then ok; else
  bad "a commit already warmed in this slot was warmed again"
fi

# 7. A warm that DIED: its lease has no -done and is older than the timeout. It
#    no longer counts, and the next warm builds.
reset
plant "$(win)" 0 $(( HOLD + 60 ))
warm claim "$SHA1" >/dev/null
if ! skipped && [ "$(lease)" = "$(win)-1" ]; then ok; else
  bad "a dead warm's lease (older than build_timeout) still blocked the next warm (lease='$(lease)')"
fi

# 8. A live lease in the PREVIOUS window still blocks.
reset
plant $(( $(win) - 1 )) 0 60
warm claim "$SHA1" >/dev/null
# ...before taking a lease of its own (a take-then-yield would also skip, but
# only because the post-create re-read caught what the first read missed).
if skipped && [ ! -e "$LEASES/inflight-$(win)-0" ]; then ok; else
  bad "a live lease from the previous window did not block a new warm before it took a lease"
fi

# 9. The boundary race: a lease this warm could not see before taking its own
#    (the next window) but created first. This warm yields and releases its own.
reset
plant $(( $(win) + 1 )) 0 30
warm claim "$SHA1" >/dev/null
if skipped && [ -z "$(lease)" ] && [ -e "$LEASES/inflight-$(win)-0-done" ]; then ok; else
  bad "two warms that raced across a window boundary both built (no yield to the earlier lease)"
fi

# 10. FAIL-OPEN: no token, or a bucket that answers 503, still warms, exit 0.
reset
FAKE_NO_TOKEN=1 warm claim "$SHA1" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && ! skipped; then ok; else bad "no access token stopped the warm"; fi
reset
plant "$(win)" 0 60
FAKE_BROKEN=1 warm claim "$SHA1" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && ! skipped; then ok; else bad "an unreadable lease answer skipped the warm instead of failing open"; fi

# 11. No commit SHA: no claim at all, the warm runs.
reset
warm claim "" >/dev/null; rc=$?
if [ "$rc" -eq 0 ] && ! skipped && [ -z "$(lease)" ]; then ok; else bad "a build with no commit SHA did not fail open"; fi

echo "warm-lease self-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
