#!/usr/bin/env bash
# Self-test for .github/actions/release-image-signing — the shared release
# signing step every product vendors. Runs the action's script against a STUB
# gcloud that signs with throwaway EC P-256 keys made here, so the verify pass
# exercises real openssl signature checks over real payloads.
#
# What must hold, each as a case below:
#   - a good signature over the right digest, against the committed key: PASS
#   - signed with another key:                                         FAIL
#   - the signed payload names another digest:                         FAIL
#   - sign-and-create "succeeds" but no attestation exists:            FAIL
#   - required and an input missing:                                   FAIL
#   - not required and unconfigured: a notice, armed=false, and gcloud never runs
#
# Needs bash, python3 and openssl — present on GitHub-hosted Ubuntu runners.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_DIR="$ROOT/.github/actions/release-image-signing"
SCRIPT="$ACTION_DIR/release-image-signing.sh"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

echo "release-image-signing self-test:"

for tool in python3 openssl base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "  FAIL  $tool is not on PATH — the self-test cannot run, which is not a pass"; exit 1; }
done
[ -f "$SCRIPT" ] || { echo "  FAIL  $SCRIPT is missing"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/keys"

openssl ecparam -name prime256v1 -genkey -noout -out "$T/keys/a.key" 2>/dev/null
openssl ec -in "$T/keys/a.key" -pubout -out "$T/keys/a.pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$T/keys/b.key" 2>/dev/null
openssl ec -in "$T/keys/b.key" -pubout -out "$T/keys/b.pub.pem" 2>/dev/null
if [ ! -s "$T/keys/a.pub.pem" ] || [ ! -s "$T/keys/b.pub.pem" ]; then
  echo "  FAIL  could not generate test keys"; exit 1
fi

D1="sha256:$(printf 'one' | openssl dgst -sha256 -r | cut -c1-64)"
D2="sha256:$(printf 'two' | openssl dgst -sha256 -r | cut -c1-64)"
DX="sha256:$(printf 'other' | openssl dgst -sha256 -r | cut -c1-64)"
REF1="registry.example.test/demo/app@$D1"
REF2="registry.example.test/demo/worker@$D2"

# --- the stub -----------------------------------------------------------------
# STUB_SIGN:   good | wrongdigest | none | fail | exists
# STUB_KEY:    private key sign-and-create signs with
# STUB_STORE:  directory of attestations, one JSON list per digest
# STUB_LOG:    every invocation, one line, plus the billing project it saw
cat > "$T/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
echo "gcloud $* | quota=${CLOUDSDK_BILLING_QUOTA_PROJECT:-}" >> "$STUB_LOG"
args=" $* "
url=""
for a in "$@"; do case "$a" in --artifact-url=*) url="${a#--artifact-url=}" ;; esac; done
digest="${url##*@}"
store="$STUB_STORE/$(printf '%s' "$digest" | tr ':' '_').json"
case "$args" in
  *" binauthz --help "*) exit 0 ;;
  *" attestations sign-and-create "*)
    case "$STUB_SIGN" in
      fail)   echo "ERROR: (gcloud) PERMISSION_DENIED: the caller does not have permission" >&2; exit 1 ;;
      none)   exit 0 ;;
    esac
    signed="$digest"
    [ "$STUB_SIGN" = wrongdigest ] && signed="$STUB_OTHER_DIGEST"
    payload="$(mktemp)"
    printf '{"critical":{"identity":{"docker-reference":"%s"},"image":{"docker-manifest-digest":"%s"},"type":"Google cloud binauthz container signature"}}' "${url%@*}" "$signed" > "$payload"
    sig_b64="$(openssl dgst -sha256 -sign "$STUB_KEY" "$payload" | base64 | tr -d '\n')"
    pay_b64="$(base64 < "$payload" | tr -d '\n')"
    rm -f "$payload"
    printf '[{"attestation":{"serializedPayload":"%s","signatures":[{"publicKeyId":"stub","signature":"%s"}]},"kind":"ATTESTATION"}]' "$pay_b64" "$sig_b64" > "$store"
    if [ "$STUB_SIGN" = exists ]; then echo "ERROR: (gcloud) ALREADY_EXISTS: Requested entity already exists" >&2; exit 1; fi
    exit 0 ;;
  *" attestations list "*)
    if [ -f "$store" ]; then cat "$store"; else echo "[]"; fi
    exit 0 ;;
esac
echo "stub gcloud: unexpected call: $*" >&2
exit 3
STUB
chmod +x "$T/bin/gcloud"

PROVIDER="projects/123456789012/locations/global/workloadIdentityPools/github-release-signing/providers/demo"
SIGNER="signer-demo@signing-proj-0.iam.gserviceaccount.com"
KEYVER="projects/signing-proj-0/locations/global/keyRings/release-image-signing/cryptoKeys/image-signing-demo-v1/cryptoKeyVersions/1"

# run <name> <mode> [VAR=value ...] — runs the script in a clean environment
# carrying only what the case sets, and leaves RC, OUT, GH_OUT, LOG behind.
run() {
  local name="$1" mode="$2"; shift 2
  local case_dir="$T/case-$name"
  mkdir -p "$case_dir/store"
  : > "$case_dir/log"; : > "$case_dir/out"
  OUT="$(env -i PATH="$T/bin:$PATH" HOME="$T" \
      GITHUB_OUTPUT="$case_dir/out" \
      STUB_LOG="$case_dir/log" STUB_STORE="$case_dir/store" \
      STUB_SIGN=good STUB_KEY="$T/keys/a.key" STUB_OTHER_DIGEST="$DX" \
      RIS_WIF_PROVIDER="$PROVIDER" RIS_SIGNER_SA="$SIGNER" \
      RIS_ATTESTOR="demo-release-images" RIS_ATTESTOR_PROJECT="signing-proj-0" \
      RIS_KEY_VERSION="$KEYVER" RIS_PUBLIC_KEY_PEM="$T/keys/a.pub.pem" \
      RIS_DIGESTS="$REF1 $REF2" RIS_REQUIRED=true \
      "$@" bash "$SCRIPT" "$mode" 2>&1)"
  RC=$?
  GH_OUT="$(cat "$case_dir/out")"
  LOG="$(cat "$case_dir/log")"
}

has() { printf '%s' "$1" | grep -cF -- "$2" >/dev/null; }
lacks() { ! has "$@"; }
count_is() { [ "$(printf '%s\n' "$1" | grep -cF -- "$2")" -eq "$3" ]; }
is_empty() { [ -z "$1" ]; }
# check <label> <command...> — ok when the command succeeds.
check() { local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }

expect_pass() { # <label> <needle in output>
  if [ "$RC" -eq 0 ] && has "$OUT" "$2"; then ok "$1"; else bad "$1 (rc=$RC)"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}
expect_fail() { # <label> <needle in output>
  if [ "$RC" -ne 0 ] && has "$OUT" "$2"; then ok "$1"; else bad "$1 (rc=$RC, wanted a failure naming '$2')"; printf '%s\n' "$OUT" | sed 's/^/        /'; fi
}

# --- decide -------------------------------------------------------------------

run unset-not-required decide RIS_REQUIRED=false RIS_WIF_PROVIDER= RIS_SIGNER_SA= RIS_ATTESTOR= RIS_ATTESTOR_PROJECT= RIS_KEY_VERSION= RIS_PUBLIC_KEY_PEM= RIS_DIGESTS=
expect_pass "not required + unconfigured: notice and no-op" "::notice"
check "  ...armed=false written" has "$GH_OUT" "armed=false"
check "  ...gcloud never ran" is_empty "$LOG"

run unset-required decide RIS_WIF_PROVIDER= RIS_SIGNER_SA= RIS_ATTESTOR= RIS_ATTESTOR_PROJECT= RIS_KEY_VERSION= RIS_PUBLIC_KEY_PEM=
expect_fail "required + unconfigured: fails" "signing is required but unconfigured"

run one-missing-required decide RIS_ATTESTOR=
expect_fail "required + attestor missing: fails naming it" "missing: attestor"

run one-missing-not-required decide RIS_REQUIRED=false RIS_KEY_VERSION=
expect_pass "not required + partially configured: warning, no-op" "::warning"
check "  ...armed=false written" has "$GH_OUT" "armed=false"

run bad-required-value decide RIS_REQUIRED=yes
expect_fail "a required value that is not true/false fails closed" "required must be"

run no-digests decide RIS_DIGESTS=
expect_fail "armed with no digests: fails" "no image digests"

run tag-ref decide RIS_DIGESTS="registry.example.test/demo/app:v1.2.3"
expect_fail "a tag instead of a digest: fails" "not a digest-pinned image ref"

run missing-pem decide RIS_PUBLIC_KEY_PEM="$T/keys/absent.pem"
expect_fail "committed key path missing: fails" "public-key-pem"

run count-mismatch decide RIS_EXPECTED_COUNT=5
expect_fail "expected-count mismatch: fails" "expected 5"

run bad-provider decide RIS_WIF_PROVIDER="projects/x/providers/y"
expect_fail "malformed provider name: fails" "wif-provider"

run attestor-conflict decide RIS_ATTESTOR="projects/elsewhere/attestors/demo-release-images"
expect_fail "qualified attestor naming another project than attestor-project: fails" "refusing to guess"

printf '%s\n%s\n# a comment\n\n' "$REF1" "$REF2" > "$T/digests.txt"
run armed decide RIS_DIGESTS= RIS_DIGESTS_FILE="$T/digests.txt" RIS_EXPECTED_COUNT=2
expect_pass "fully configured, digests from a file: armed" "ARMED"
check "  ...armed=true written" has "$GH_OUT" "armed=true"

# --- sign ---------------------------------------------------------------------

run good sign
expect_pass "good signature over each digest, committed key: passes" "OK   $REF2"
check "  ...signed=true written" has "$GH_OUT" "signed=true"
check "  ...one sign-and-create per digest" count_is "$LOG" "sign-and-create" 2
check "  ...key version passed" has "$LOG" "--keyversion=$KEYVER"
check "  ...attestor project passed" has "$LOG" "--attestor-project=signing-proj-0"
check "  ...billed to the attestor project" has "$LOG" "quota=signing-proj-0"

run wrong-key sign STUB_KEY="$T/keys/b.key"
expect_fail "signed with another key: fails" "does not verify"
check "  ...no signed=true on failure" lacks "$GH_OUT" "signed=true"

run wrong-digest sign STUB_SIGN=wrongdigest
expect_fail "signed payload names another digest: fails" "does not verify"

run missing-attestation sign STUB_SIGN=none
expect_fail "no attestation after sign-and-create: fails" "No attestation found"

run create-error sign STUB_SIGN=fail
expect_fail "sign-and-create error: fails" "sign-and-create failed"

run already-exists sign STUB_SIGN=exists
expect_pass "ALREADY_EXISTS is tolerated, then verified" "already attested"

run qualified-attestor sign RIS_ATTESTOR="projects/signing-proj-0/attestors/demo-release-images" RIS_ATTESTOR_PROJECT=
expect_pass "qualified attestor, no attestor-project: passes" "OK   $REF1"
check "  ...short attestor name passed" has "$LOG" "--attestor=demo-release-images "

run rotation sign RIS_PUBLIC_KEY_PEM="$T/keys/b.pub.pem" RIS_PUBLIC_KEY_PEM_PREVIOUS="$T/keys/a.pub.pem"
expect_pass "signed with the previous key inside a rotation window: passes" "OK   $REF1"

run sign-unarmed sign RIS_KEY_VERSION=
expect_fail "sign never self-skips when an input is missing" "defect in the caller"

# --- the action wiring --------------------------------------------------------
# The script is only half: the action must pass inputs as env (never spliced
# into shell), gate auth and sign on `decide`, and pin the auth action.
A="$ACTION_DIR/action.yml"
ACTION_TEXT="$(cat "$A")"
check "action.yml splices no expression into a run: line" lacks "$(grep -E '^[[:space:]]*run:' "$A")" "\${{"
check "auth and sign are both gated on decide" count_is "$ACTION_TEXT" "if: steps.decide.outputs.armed == 'true'" 2
check "auth action pinned by sha" has "$(grep -E 'uses: google-github-actions/auth@[0-9a-f]{40} # v' "$A")" "google-github-actions/auth@"
check "composite action (keeps the caller's job_workflow_ref)" has "$ACTION_TEXT" "using: composite"

if [ "$fail" -eq 0 ]; then
  echo "  release-image-signing: all cases pass."
else
  echo "  release-image-signing: FAILED."
fi
exit "$fail"
