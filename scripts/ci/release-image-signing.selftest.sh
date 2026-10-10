#!/usr/bin/env bash
# Self-test for .github/actions/release-image-signing — the shared release
# signing step every product vendors. Runs the action's script against a STUB
# gcloud that signs with throwaway EC P-256 keys made here, so the verify pass
# exercises real openssl signature checks over real payloads.
#
# What must hold, each as a case below:
#   - a good signature over the right digest, against the committed key: PASS
#   - signed with another key (fresh, or an ALREADY_EXISTS one):       FAIL
#   - the signed payload names another digest:                         FAIL
#   - sign-and-create "succeeds" but no attestation exists:            FAIL
#   - `attestations list` itself fails:                                FAIL
#   - required and an input missing, or no access token at sign:       FAIL
#   - a key that is untracked by git, or not EC P-256:                 FAIL
#   - a tracked key edited in the working tree, or staged not committed: FAIL
#   - a newline in a value, a malformed attestor name or project:      FAIL
#   - not required and unconfigured: a notice, armed=false, and gcloud never runs
#   - the token reaches gcloud only as a 0600 file, never as RIS_ACCESS_TOKEN,
#     and the file is gone when the step ends
#
# Needs bash, git, python3 and openssl — present on GitHub-hosted Ubuntu runners.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ACTION_DIR="$ROOT/.github/actions/release-image-signing"
SCRIPT="$ACTION_DIR/release-image-signing.sh"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

echo "release-image-signing self-test:"

for tool in git python3 openssl base64; do
  command -v "$tool" >/dev/null 2>&1 || { echo "  FAIL  $tool is not on PATH — the self-test cannot run, which is not a pass"; exit 1; }
done
[ -f "$SCRIPT" ] || { echo "  FAIL  $SCRIPT is missing"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/keys"

# The script requires the committed key to be TRACKED by git, so every case
# runs inside a throwaway repository whose index holds the test PEMs.
REPO="$T/repo"
git init -q "$REPO"
mkdir -p "$REPO/keys"

openssl ecparam -name prime256v1 -genkey -noout -out "$T/keys/a.key" 2>/dev/null
openssl ec -in "$T/keys/a.key" -pubout -out "$REPO/keys/a.pub.pem" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$T/keys/b.key" 2>/dev/null
openssl ec -in "$T/keys/b.key" -pubout -out "$REPO/keys/b.pub.pem" 2>/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$T/keys/rsa.key" 2>/dev/null
openssl pkey -in "$T/keys/rsa.key" -pubout -out "$REPO/keys/rsa.pub.pem" 2>/dev/null
cp "$REPO/keys/a.pub.pem" "$REPO/keys/untracked.pub.pem"
cp "$REPO/keys/a.pub.pem" "$REPO/keys/edited.pub.pem"
for k in a b rsa untracked edited; do
  [ -s "$REPO/keys/$k.pub.pem" ] || { echo "  FAIL  could not generate test key $k"; exit 1; }
done
git -C "$REPO" add keys/a.pub.pem keys/b.pub.pem keys/rsa.pub.pem keys/edited.pub.pem
# The script verifies against the COMMITTED content (HEAD), so the fixtures are
# committed, not only staged.
git -C "$REPO" -c user.name=selftest -c user.email=selftest@example.test -c commit.gpgsign=false \
  commit -q -m "test keys" || { echo "  FAIL  could not commit the test keys"; exit 1; }
git -C "$REPO" ls-files --error-unmatch -- keys/untracked.pub.pem >/dev/null 2>&1 \
  && { echo "  FAIL  the untracked fixture key is tracked — the case below would prove nothing"; exit 1; }
# A tracked, committed key that an earlier release step overwrote in the working
# tree — with another VALID EC P-256 key, so only the HEAD comparison can catch it.
cp "$REPO/keys/b.pub.pem" "$REPO/keys/edited.pub.pem"
git -C "$REPO" diff --quiet HEAD -- keys/edited.pub.pem \
  && { echo "  FAIL  the edited fixture key matches HEAD — the case below would prove nothing"; exit 1; }
# Tracked (staged) but never committed: not a committed key.
cp "$REPO/keys/a.pub.pem" "$REPO/keys/staged.pub.pem"
git -C "$REPO" add keys/staged.pub.pem

D1="sha256:$(printf 'one' | openssl dgst -sha256 -r | cut -c1-64)"
D2="sha256:$(printf 'two' | openssl dgst -sha256 -r | cut -c1-64)"
DX="sha256:$(printf 'other' | openssl dgst -sha256 -r | cut -c1-64)"
REF1="registry.example.test/demo/app@$D1"
REF2="registry.example.test/demo/worker@$D2"

# --- the stub -----------------------------------------------------------------
# STUB_SIGN:   good | wrongdigest | none | fail | exists
# STUB_LIST:   ok | fail
# STUB_KEY:    private key sign-and-create signs with
# STUB_STORE:  directory of attestations, one JSON list per digest
# STUB_LOG:    every invocation, one line, plus the billing project it saw,
#              the token file's content and mode, and whether RIS_ACCESS_TOKEN
#              leaked into gcloud's environment
cat > "$T/bin/gcloud" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
tok=""; mode=""
if [ -n "${CLOUDSDK_AUTH_ACCESS_TOKEN_FILE:-}" ] && [ -f "$CLOUDSDK_AUTH_ACCESS_TOKEN_FILE" ]; then
  tok="$(cat "$CLOUDSDK_AUTH_ACCESS_TOKEN_FILE")"
  mode="$(stat -c %a "$CLOUDSDK_AUTH_ACCESS_TOKEN_FILE")"
fi
echo "gcloud $* | quota=${CLOUDSDK_BILLING_QUOTA_PROJECT:-} | tok=$tok mode=$mode | env=${RIS_ACCESS_TOKEN:+LEAKED}" >> "$STUB_LOG"
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
    if [ "$STUB_LIST" = fail ]; then echo "ERROR: (gcloud) PERMISSION_DENIED: containeranalysis.occurrences.list" >&2; exit 1; fi
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
NL=$'\n'

# run <name> <mode> [VAR=value ...] — runs the script from inside the test
# repository in a clean environment carrying only what the case sets, and
# leaves RC, OUT, GH_OUT, LOG and TMP_LEFT behind.
run() {
  local name="$1" mode="$2"; shift 2
  local case_dir="$T/case-$name"
  mkdir -p "$case_dir/store" "$case_dir/tmp"
  : > "$case_dir/log"; : > "$case_dir/out"
  OUT="$(cd "$REPO" && env -i PATH="$T/bin:$PATH" HOME="$T" \
      GITHUB_OUTPUT="$case_dir/out" RUNNER_TEMP="$case_dir/tmp" \
      STUB_LOG="$case_dir/log" STUB_STORE="$case_dir/store" \
      STUB_SIGN=good STUB_LIST=ok STUB_KEY="$T/keys/a.key" STUB_OTHER_DIGEST="$DX" \
      RIS_WIF_PROVIDER="$PROVIDER" RIS_SIGNER_SA="$SIGNER" \
      RIS_ATTESTOR="demo-release-images" RIS_ATTESTOR_PROJECT="signing-proj-0" \
      RIS_KEY_VERSION="$KEYVER" RIS_PUBLIC_KEY_PEM="keys/a.pub.pem" \
      RIS_DIGESTS="$REF1 $REF2" RIS_REQUIRED=true RIS_ACCESS_TOKEN=stub-token \
      "$@" bash "$SCRIPT" "$mode" 2>&1)"
  RC=$?
  GH_OUT="$(cat "$case_dir/out")"
  LOG="$(cat "$case_dir/log")"
  TMP_LEFT="$(ls -A "$case_dir/tmp")"
}

has() { printf '%s' "$1" | grep -cF -- "$2" >/dev/null; }
# The three below are only ever called through `check "$label" <fn> ...`,
# which shellcheck cannot follow, so it reads them as unreachable (SC2317).
# shellcheck disable=SC2317
lacks() { ! has "$@"; }
# shellcheck disable=SC2317
count_is() { [ "$(printf '%s\n' "$1" | grep -cF -- "$2")" -eq "$3" ]; }
# shellcheck disable=SC2317
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

run missing-pem decide RIS_PUBLIC_KEY_PEM="keys/absent.pem"
expect_fail "committed key path missing: fails" "public-key-pem"

run untracked-pem decide RIS_PUBLIC_KEY_PEM="keys/untracked.pub.pem"
expect_fail "a key file git does not track: fails" "not tracked by git"

run untracked-previous-pem decide RIS_PUBLIC_KEY_PEM_PREVIOUS="keys/untracked.pub.pem"
expect_fail "an untracked previous key: fails" "previous-public-key-pem"

run edited-pem decide RIS_PUBLIC_KEY_PEM="keys/edited.pub.pem"
expect_fail "a tracked key edited in the working tree: fails" "differs from its committed content"

run edited-pem-sign sign RIS_PUBLIC_KEY_PEM="keys/edited.pub.pem" STUB_KEY="$T/keys/b.key"
expect_fail "sign with a tracked key edited to match the signer: fails before gcloud" "differs from its committed content"
check "  ...gcloud never ran" is_empty "$LOG"

run edited-previous-pem decide RIS_PUBLIC_KEY_PEM_PREVIOUS="keys/edited.pub.pem"
expect_fail "an edited previous key: fails" "previous-public-key-pem"

run staged-pem decide RIS_PUBLIC_KEY_PEM="keys/staged.pub.pem"
expect_fail "a key staged but never committed: fails" "not in the checked-out commit"

run rsa-pem decide RIS_PUBLIC_KEY_PEM="keys/rsa.pub.pem"
expect_fail "an RSA key instead of EC P-256: fails" "not an EC P-256 public key"

run count-mismatch decide RIS_EXPECTED_COUNT=5
expect_fail "expected-count mismatch: fails" "expected 5"

run bad-provider decide RIS_WIF_PROVIDER="projects/x/providers/y"
expect_fail "malformed provider name: fails" "wif-provider"

run newline-provider decide RIS_WIF_PROVIDER="$PROVIDER${NL}$PROVIDER"
expect_fail "a newline inside a value (provider): fails" "wif-provider is not"

run newline-signer decide RIS_SIGNER_SA="$SIGNER${NL}evil"
expect_fail "a newline inside a value (signer): fails" "signer-sa is not"

run newline-project decide RIS_ATTESTOR_PROJECT="signing-proj-0${NL}other-proj-1"
expect_fail "a newline inside a value (attestor project): fails" "attestor-project is not"

run bad-attestor-name decide RIS_ATTESTOR="Demo.Release!"
expect_fail "malformed attestor name: fails" "attestor is not an attestor name"

run bad-attestor-project decide RIS_ATTESTOR_PROJECT="Bad_Project"
expect_fail "malformed attestor project: fails" "attestor-project is not a project id"

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
check "  ...project passed explicitly" count_is "$LOG" "--project=signing-proj-0" 4
check "  ...billed to the attestor project" has "$LOG" "quota=signing-proj-0"
check "  ...token reached every sign/list as a 0600 file" count_is "$LOG" "tok=stub-token mode=600" 4
check "  ...RIS_ACCESS_TOKEN never reached gcloud's environment" lacks "$LOG" "LEAKED"
check "  ...token file removed when the step ends" is_empty "$TMP_LEFT"

run no-token sign RIS_ACCESS_TOKEN=
expect_fail "sign without the access token: fails" "without the signer's access token"
check "  ...gcloud never ran" is_empty "$LOG"

run wrong-key sign STUB_KEY="$T/keys/b.key"
expect_fail "signed with another key: fails" "does not verify"
check "  ...no signed=true on failure" lacks "$GH_OUT" "signed=true"
check "  ...token file removed on failure too" is_empty "$TMP_LEFT"

run exists-wrong-key sign STUB_SIGN=exists STUB_KEY="$T/keys/b.key"
expect_fail "ALREADY_EXISTS signed by another key: fails" "does not verify"

run wrong-digest sign STUB_SIGN=wrongdigest
expect_fail "signed payload names another digest: fails" "does not verify"

run missing-attestation sign STUB_SIGN=none
expect_fail "no attestation after sign-and-create: fails" "No attestation found"

run list-fails sign STUB_LIST=fail
expect_fail "attestations list exiting 1: fails, never an empty pass" "Could not read attestations"
check "  ...gcloud's own words are shown" has "$OUT" "PERMISSION_DENIED"

run create-error sign STUB_SIGN=fail
expect_fail "sign-and-create error: fails" "sign-and-create failed"

run already-exists sign STUB_SIGN=exists
expect_pass "ALREADY_EXISTS is tolerated, then verified" "already attested"

run qualified-attestor sign RIS_ATTESTOR="projects/signing-proj-0/attestors/demo-release-images" RIS_ATTESTOR_PROJECT=
expect_pass "qualified attestor, no attestor-project: passes" "OK   $REF1"
check "  ...short attestor name passed" has "$LOG" "--attestor=demo-release-images "

run rotation sign RIS_PUBLIC_KEY_PEM="keys/b.pub.pem" RIS_PUBLIC_KEY_PEM_PREVIOUS="keys/a.pub.pem"
expect_pass "signed with the previous key inside a rotation window: passes" "OK   $REF1"

run sign-unarmed sign RIS_KEY_VERSION=
expect_fail "sign never self-skips when an input is missing" "defect in the caller"

# --- the action wiring --------------------------------------------------------
# The script is only half: the action must pass inputs as env (never spliced
# into shell), gate auth and sign on `decide`, pin the auth action, mint a
# token only, and hand that token to the sign step alone.

# Prints every line of shell in a YAML file's `run:` keys: the one-line form,
# and every line of a `run: |` / `run: >` block body (lines indented deeper
# than the key, or blank).
run_bodies() {
  awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    inblk && ($0 ~ /^[ \t]*$/ || indent($0) > blk) { print; next }
    { inblk = 0 }
    /^[ \t]*(- )?run:[ \t]*[|>][-+]?[ \t]*$/ { inblk = 1; blk = indent($0); next }
    /^[ \t]*(- )?run:/ { print }
  ' "$1"
}

# The scan must catch an expression on a block body's SECOND line, or a clean
# result below proves nothing.
FIX="$T/fixture-action.yml"
{
  echo "runs:"
  echo "  using: composite"
  echo "  steps:"
  echo "    - shell: bash"
  echo "      run: |"
  echo "        echo safe"
  echo "        echo \"\${{ inputs.evil }}\""
  echo "    - shell: bash"
  echo "      run: echo fine"
} > "$FIX"
check "fixture: the run-body scan catches \${{ inside a run: | block" has "$(run_bodies "$FIX")" "\${{"
check "fixture: the run-body scan reads one-line run: too" has "$(run_bodies "$FIX")" "echo fine"

A="$ACTION_DIR/action.yml"
ACTION_TEXT="$(cat "$A")"
check "action.yml has run: bodies to scan" has "$(run_bodies "$A")" "release-image-signing.sh"
check "action.yml splices no expression into any run: body" lacks "$(run_bodies "$A")" "\${{"
check "auth and sign are both gated on decide" count_is "$ACTION_TEXT" "if: steps.decide.outputs.armed == 'true'" 2
check "auth action pinned by sha" has "$(grep -E 'uses: google-github-actions/auth@[0-9a-f]{40} # v' "$A")" "google-github-actions/auth@"
check "auth mints an access token only" has "$ACTION_TEXT" "token_format: access_token"
check "auth token lives ten minutes, not the default hour" has "$ACTION_TEXT" "access_token_lifetime: 600s"
check "auth writes no credentials file" has "$ACTION_TEXT" "create_credentials_file: false"
check "auth exports no GOOGLE_*/CLOUDSDK_* variables" has "$ACTION_TEXT" "export_environment_variables: false"
check "the token output is referenced exactly once (the sign step's env)" count_is "$ACTION_TEXT" "steps.auth.outputs.access_token" 1
check "composite action (keeps the caller's job_workflow_ref)" has "$ACTION_TEXT" "using: composite"

if [ "$fail" -eq 0 ]; then
  echo "  release-image-signing: all cases pass."
else
  echo "  release-image-signing: FAILED."
fi
exit "$fail"
