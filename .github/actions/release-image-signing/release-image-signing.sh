#!/usr/bin/env bash
# release-image-signing.sh — the logic behind action.yml. Two modes:
#
#   decide   Read the inputs and say whether to sign (armed=true|false to
#            $GITHUB_OUTPUT). Unconfigured and not required: a ::notice:: and
#            armed=false. Required and any input missing: FAIL. Configured: every
#            input is validated here, before any credential is minted.
#   sign     Run as the signer. The action mints a short-lived access token
#            between the modes and hands it to THIS step only (RIS_ACCESS_TOKEN);
#            no credentials file and no GOOGLE_* variable is created, so nothing
#            later in the caller's job inherits the signer. The token is written
#            to a 0600 file in this step's own temp dir for gcloud
#            (auth/access_token_file) and removed on exit.
#            `gcloud beta container binauthz attestations sign-and-create` per
#            digest, then read every attestation back and check its signature
#            with openssl against the committed public key, over a payload that
#            names THAT digest. Any miss fails. `sign` never self-skips: it only
#            runs armed, so a missing input there is a defect, not a choice.
#
# Inputs arrive as RIS_* environment variables (see action.yml). No defaults
# that name a project, key or attestor: unset means unset.
#
# Why verify at all when sign-and-create exited 0: it is tolerated when the
# attestation ALREADY EXISTS (a re-run of the same digest), so its exit status
# is not evidence that a valid attestation is there. And the verify pass checks
# against the COMMITTED key, so a signer whose key drifted from what customers
# trust fails the release here instead of every customer's admission policy.

set -euo pipefail

log() { printf '  %s\n' "$*"; }

# Whole-string match. `[[ =~ ]]` anchors on the WHOLE value, unlike a line
# tool, which would accept "good\nanything" because one LINE matched. A newline
# is refused outright: no input of this action can legitimately contain one.
matches() { [[ $1 != *$'\n'* && $1 =~ $2 ]]; }

RE_PROJECT='^[a-z][a-z0-9-]{4,28}[a-z0-9]$'
RE_ATTESTOR='^[a-z0-9][a-z0-9_-]{0,98}[a-z0-9]$'
die() { printf '::error title=Release image signing::%s\n' "$*"; exit 1; }

out() {
  # Outside Actions (the self-test sets GITHUB_OUTPUT) print instead.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >> "$GITHUB_OUTPUT"
  else
    printf 'output: %s\n' "$1"
  fi
}

# --- inputs -----------------------------------------------------------------

SIGNING_INPUTS=(RIS_WIF_PROVIDER RIS_SIGNER_SA RIS_ATTESTOR RIS_KEY_VERSION RIS_PUBLIC_KEY_PEM)
# Human names for messages: the action's input names.
input_name() {
  case "$1" in
    RIS_WIF_PROVIDER)   echo wif-provider ;;
    RIS_SIGNER_SA)      echo signer-sa ;;
    RIS_ATTESTOR)       echo attestor ;;
    RIS_ATTESTOR_PROJECT) echo attestor-project ;;
    RIS_KEY_VERSION)    echo key-version ;;
    RIS_PUBLIC_KEY_PEM) echo public-key-pem ;;
    *)                  echo "$1" ;;
  esac
}

parse_required() {
  local v
  v="${RIS_REQUIRED:-false}"
  v="${v,,}"
  case "$v" in
    true)     REQUIRED=1 ;;
    false|'') REQUIRED=0 ;;
    # A typo must not read as "not required" — that is the unsafe direction.
    *) die "required must be 'true' or 'false', got '${RIS_REQUIRED}'." ;;
  esac
}

# The attestor's project: explicit, or embedded in a qualified attestor name.
# Never the build project — the release attestor lives in the signing project.
normalise_attestor() {
  ATTESTOR="$RIS_ATTESTOR"
  ATTESTOR_PROJECT="${RIS_ATTESTOR_PROJECT:-}"
  case "$ATTESTOR" in
    projects/*/attestors/*)
      local embedded="${ATTESTOR#projects/}"
      embedded="${embedded%%/attestors/*}"
      ATTESTOR="${ATTESTOR##*/attestors/}"
      if [ -z "$embedded" ] || [ -z "$ATTESTOR" ] || [ "${embedded#*/}" != "$embedded" ]; then
        die "attestor looks fully qualified but does not parse: '$RIS_ATTESTOR' (expected projects/<project>/attestors/<name>)."
      fi
      if [ -n "$ATTESTOR_PROJECT" ] && [ "$ATTESTOR_PROJECT" != "$embedded" ]; then
        die "attestor names project '$embedded' but attestor-project is '$ATTESTOR_PROJECT' — refusing to guess which attestor is meant."
      fi
      ATTESTOR_PROJECT="$embedded"
      ;;
    */*) die "attestor must be a bare name or projects/<project>/attestors/<name>, got '$RIS_ATTESTOR'." ;;
  esac
  [ -n "$ATTESTOR_PROJECT" ] \
    || die "attestor-project is not set and attestor is not fully qualified. The attestor lives in the signing project; it is never assumed to be the build project."
}

# Runs after normalise_attestor, so ATTESTOR is the bare name and
# ATTESTOR_PROJECT the explicit or embedded project.
check_shapes() {
  matches "$RIS_WIF_PROVIDER" '^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$' \
    || die "wif-provider is not a provider resource name (projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<id>): '$RIS_WIF_PROVIDER'."
  matches "$RIS_SIGNER_SA" '^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$' \
    || die "signer-sa is not a service account email: '$RIS_SIGNER_SA'."
  matches "$RIS_KEY_VERSION" '^projects/[a-z][a-z0-9-]{4,28}[a-z0-9]/locations/[a-z0-9-]+/keyRings/[A-Za-z0-9_-]+/cryptoKeys/[A-Za-z0-9_-]+/cryptoKeyVersions/[0-9]+$' \
    || die "key-version is not a KMS crypto key VERSION resource name: '$RIS_KEY_VERSION'."
  matches "$ATTESTOR" "$RE_ATTESTOR" \
    || die "attestor is not an attestor name (lowercase letters, digits, '-' and '_'): '$RIS_ATTESTOR'."
  matches "$ATTESTOR_PROJECT" "$RE_PROJECT" \
    || die "attestor-project is not a project id: '$ATTESTOR_PROJECT'."
}

# Fills REFS from RIS_DIGESTS and RIS_DIGESTS_FILE; every ref must be pinned by
# digest. A tag is mutable, so a signature "of a tag" proves nothing.
load_refs() {
  REFS=()
  local r line words
  # read -a splits on whitespace without globbing a ref.
  while IFS= read -r line || [ -n "$line" ]; do
    read -r -a words <<< "$line"
    for r in ${words[@]+"${words[@]}"}; do REFS+=("$r"); done
  done <<< "${RIS_DIGESTS:-}"
  if [ -n "${RIS_DIGESTS_FILE:-}" ]; then
    [ -f "$RIS_DIGESTS_FILE" ] || die "digests-file '$RIS_DIGESTS_FILE' does not exist."
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%%#*}"
      read -r -a words <<< "$line"
      for r in ${words[@]+"${words[@]}"}; do REFS+=("$r"); done
    done < "$RIS_DIGESTS_FILE"
  fi
  [ "${#REFS[@]}" -gt 0 ] || die "no image digests were given (digests / digests-file) — nothing to sign."
  for r in "${REFS[@]}"; do
    matches "$r" '^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$' \
      || die "'$r' is not a digest-pinned image ref (<repo>/<name>@sha256:<64 hex>). Signatures are over digests, never tags."
  done
  if [ -n "${RIS_EXPECTED_COUNT:-}" ]; then
    matches "$RIS_EXPECTED_COUNT" '^[0-9]+$' || die "expected-count must be a number, got '$RIS_EXPECTED_COUNT'."
    [ "${#REFS[@]}" -eq "$RIS_EXPECTED_COUNT" ] \
      || die "expected $RIS_EXPECTED_COUNT digest-pinned refs, got ${#REFS[@]} — a release that lost an image must not sign the rest."
  fi
}

# A key the verify pass trusts must be one the repository COMMITTED: a file
# the release workflow generated or downloaded at run time would let the run
# vouch for itself. And it must be the algorithm the platform provisions
# (EC_SIGN_P256_SHA256), so a wrong file fails here, by name, not at verify.
check_one_key() { # <input name> <path>
  local name="$1" pem="$2"
  [[ $pem != *$'\n'* ]] || die "$name contains a newline."
  [ -f "$pem" ] || die "$name '$pem' does not exist — commit the product's public key and point this input at it."
  git ls-files --error-unmatch -- "$pem" >/dev/null 2>&1 \
    || die "$name '$pem' is not tracked by git. The key every attestation is checked against must be the one committed to the repository."
  command -v openssl >/dev/null 2>&1 || die "openssl is not on PATH — the key and every signature are checked with it."
  openssl pkey -pubin -in "$pem" -noout -text 2>/dev/null | grep -c 'prime256v1' >/dev/null \
    || die "$name '$pem' is not an EC P-256 public key. Release signing keys are EC_SIGN_P256_SHA256."
}

check_keys() {
  check_one_key public-key-pem "$RIS_PUBLIC_KEY_PEM"
  if [ -n "${RIS_PUBLIC_KEY_PEM_PREVIOUS:-}" ]; then
    check_one_key previous-public-key-pem "$RIS_PUBLIC_KEY_PEM_PREVIOUS"
  fi
}

# Sets MISSING / SET_COUNT over the signing inputs (attestor-project is checked
# with the attestor, since a qualified attestor carries it).
scan_inputs() {
  MISSING=()
  SET_COUNT=0
  local v
  for v in "${SIGNING_INPUTS[@]}"; do
    if [ -n "${!v:-}" ]; then SET_COUNT=$((SET_COUNT + 1)); else MISSING+=("$(input_name "$v")"); fi
  done
}

validate_armed() {
  normalise_attestor
  check_shapes
  check_keys
  load_refs
}

# --- decide -----------------------------------------------------------------

do_decide() {
  parse_required
  scan_inputs
  if [ "${#MISSING[@]}" -gt 0 ]; then
    out "armed=false"
    if [ "$REQUIRED" -eq 1 ]; then
      die "signing is required but unconfigured (missing: ${MISSING[*]}). This release may not publish unsigned images."
    fi
    if [ "$SET_COUNT" -eq 0 ]; then
      printf '::notice title=Release images unsigned::Release image signing is not configured for this repository, and not required — skipping. Images are published UNSIGNED.\n'
    else
      printf '::warning title=Release signing partially configured::missing: %s — skipping, images are published UNSIGNED. Set every input or none.\n' "${MISSING[*]}"
    fi
    return 0
  fi
  validate_armed
  out "armed=true"
  log "Release signing is ARMED: ${#REFS[@]} digest(s), attestor $ATTESTOR (project $ATTESTOR_PROJECT)."
}

# --- sign -------------------------------------------------------------------

# Writes each (payload, signature) pair of `attestations list --format=json`
# whose SIGNED payload names DIGEST into DIR as <n>.payload / <n>.sig, and
# prints the pair count. python3 is used for JSON and base64 only; the
# cryptographic check is openssl's. Both base64 alphabets and both key
# spellings are read, so an output-format change cannot silently empty the set.
extract_signed_payloads() {
  python3 - "$1" "$2" "$3" <<'PY'
import base64, json, os, sys

json_file, digest, out = sys.argv[1], sys.argv[2], sys.argv[3]

def b64(s):
    s = s.strip().replace("-", "+").replace("_", "/")
    return base64.b64decode(s + "=" * (-len(s) % 4), validate=True)

def pick(d, *keys):
    for k in keys:
        if isinstance(d, dict) and d.get(k):
            return d[k]
    return None

with open(json_file) as fh:
    text = fh.read().strip()
doc = json.loads(text) if text else []
occurrences = doc if isinstance(doc, list) else [doc]

n = 0
for occ in occurrences:
    att = pick(occ, "attestation") or {}
    raw = pick(att, "serializedPayload", "serialized_payload")
    if not raw:
        continue
    try:
        payload = b64(raw)
        signed_digest = json.loads(payload)["critical"]["image"]["docker-manifest-digest"]
    except Exception:
        continue
    # A valid signature over ANOTHER image's payload is not an attestation of
    # this one: the digest must be inside what was signed.
    if signed_digest != digest:
        continue
    for sig in pick(att, "signatures") or []:
        raw_sig = pick(sig, "signature")
        if not raw_sig:
            continue
        try:
            sig_bytes = b64(raw_sig)
        except Exception:
            continue
        with open(os.path.join(out, f"{n}.payload"), "wb") as fh:
            fh.write(payload)
        with open(os.path.join(out, f"{n}.sig"), "wb") as fh:
            fh.write(sig_bytes)
        n += 1
print(n)
PY
}

require_tools() {
  command -v gcloud >/dev/null 2>&1 || die "gcloud is not on PATH."
  gcloud beta container binauthz --help >/dev/null 2>&1 \
    || die "the gcloud 'beta' component is unavailable, so 'binauthz attestations' cannot run. Install it (gcloud components install beta, or setup-gcloud install_components: beta)."
  command -v python3 >/dev/null 2>&1 || die "python3 is not on PATH — the verify pass reads the attestation JSON with it."
  command -v openssl >/dev/null 2>&1 || die "openssl is not on PATH — the verify pass checks signatures with it."
}

do_sign() {
  parse_required
  scan_inputs
  [ "${#MISSING[@]}" -eq 0 ] || die "sign ran with inputs missing (${MISSING[*]}) — sign only runs armed, so this is a defect in the caller."
  [ -n "${RIS_ACCESS_TOKEN:-}" ] \
    || die "sign ran without the signer's access token — the auth step must run with token_format: access_token, and only this step receives it."
  validate_armed
  require_tools

  local work err ref digest count i ok key missing="" bad="" unreadable=""
  work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ris.XXXXXXXX")"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  err="$work/err"

  # The signer's token, readable by this user only, gone when the step ends.
  # gcloud reads it through auth/access_token_file; it is never written to a
  # gcloud config, a credentials file or an exported GOOGLE_* variable.
  ( umask 077 && printf '%s' "$RIS_ACCESS_TOKEN" > "$work/token" )
  unset RIS_ACCESS_TOKEN
  export CLOUDSDK_AUTH_ACCESS_TOKEN_FILE="$work/token"
  # The project is explicit on every call AND here, so nothing falls back to an
  # ambient gcloud configuration's project.
  export CLOUDSDK_CORE_PROJECT="$ATTESTOR_PROJECT"
  # Bill Binary Authorization / Container Analysis to the attestor's project.
  # Left to gcloud, a federated signer's calls can be attributed to a project
  # where those APIs are not enabled.
  export CLOUDSDK_BILLING_QUOTA_PROJECT="$ATTESTOR_PROJECT"

  echo "── signing ${#REFS[@]} digest(s)"
  for ref in "${REFS[@]}"; do
    log "sign $ref"
    if gcloud beta container binauthz attestations sign-and-create \
        --project="$ATTESTOR_PROJECT" \
        --artifact-url="$ref" \
        --attestor="$ATTESTOR" \
        --attestor-project="$ATTESTOR_PROJECT" \
        --keyversion="$RIS_KEY_VERSION" 2>"$err"; then
      log "  attested"
    elif grep -ci 'already exists' "$err" >/dev/null; then
      log "  already attested — the verify pass below decides whether it counts"
    else
      cat "$err"
      die "sign-and-create failed for $ref."
    fi
  done

  echo "── verifying against $(basename "$RIS_PUBLIC_KEY_PEM")"
  for ref in "${REFS[@]}"; do
    digest="${ref##*@}"
    rm -rf "$work/sig" && mkdir -p "$work/sig"
    # A failed list (permissions, wrong project) is its own failure, with
    # gcloud's own words — never an empty list, and never a pass.
    if ! gcloud beta container binauthz attestations list \
        --project="$ATTESTOR_PROJECT" \
        --attestor="$ATTESTOR" \
        --attestor-project="$ATTESTOR_PROJECT" \
        --artifact-url="$ref" \
        --format=json > "$work/list.json" 2>"$err"; then
      sed 's/^/    /' "$err"
      log "FAIL $ref (attestations list failed)"
      unreadable="$unreadable $ref"
      continue
    fi

    if ! python3 -c 'import json,sys; t=open(sys.argv[1]).read().strip(); sys.exit(0 if t and json.loads(t) else 1)' "$work/list.json" 2>/dev/null; then
      log "MISS $ref (no attestation)"
      missing="$missing $ref"
      continue
    fi

    count="$(extract_signed_payloads "$work/list.json" "$digest" "$work/sig")"
    ok=""
    i=0
    while [ -z "$ok" ] && [ "$i" -lt "$count" ]; do
      for key in "$RIS_PUBLIC_KEY_PEM" ${RIS_PUBLIC_KEY_PEM_PREVIOUS:+"$RIS_PUBLIC_KEY_PEM_PREVIOUS"}; do
        if openssl dgst -sha256 -verify "$key" -signature "$work/sig/$i.sig" "$work/sig/$i.payload" >/dev/null 2>&1; then
          ok=1
          break
        fi
      done
      i=$((i + 1))
    done

    if [ -n "$ok" ]; then
      log "OK   $ref"
    else
      log "BAD  $ref (attestation present, but no signature over this digest verifies against the committed key)"
      bad="$bad $ref"
    fi
  done

  if [ -n "$missing$bad$unreadable" ]; then
    [ -z "$unreadable" ] || printf '::error::Could not read attestations for:%s\n' "$unreadable"
    [ -z "$missing" ] || printf '::error::No attestation found for:%s\n' "$missing"
    [ -z "$bad" ] || printf '::error::Attestation signature does not verify against the committed public key for:%s\n' "$bad"
    die "refusing to publish: not every released digest carries a verified attestation."
  fi
  out "signed=true"
  log "All ${#REFS[@]} digest(s) carry an attestation whose signature verifies against the committed key."
}

case "${1:-}" in
  decide) do_decide ;;
  sign)   do_sign ;;
  *) echo "usage: release-image-signing.sh <decide|sign>" >&2; exit 2 ;;
esac
