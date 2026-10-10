#!/usr/bin/env bash
# release-image-signing.sh — the logic behind action.yml. Two modes:
#
#   decide   Read the inputs and say whether to sign (armed=true|false to
#            $GITHUB_OUTPUT). Unconfigured and not required: a ::notice:: and
#            armed=false. Required and any input missing: FAIL. Configured: every
#            input is validated here, before any credential is minted.
#   sign     Run as the signer (the action authenticates between the modes).
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
  v=$(printf '%s' "${RIS_REQUIRED:-false}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
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

check_shapes() {
  printf '%s' "$RIS_WIF_PROVIDER" | grep -cE '^projects/[0-9]+/locations/global/workloadIdentityPools/[a-z0-9-]+/providers/[a-z0-9-]+$' >/dev/null \
    || die "wif-provider is not a provider resource name (projects/<number>/locations/global/workloadIdentityPools/<pool>/providers/<id>): '$RIS_WIF_PROVIDER'."
  printf '%s' "$RIS_SIGNER_SA" | grep -cE '^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]+\.iam\.gserviceaccount\.com$' >/dev/null \
    || die "signer-sa is not a service account email: '$RIS_SIGNER_SA'."
  printf '%s' "$RIS_KEY_VERSION" | grep -cE '^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+/cryptoKeyVersions/[0-9]+$' >/dev/null \
    || die "key-version is not a KMS crypto key VERSION resource name: '$RIS_KEY_VERSION'."
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
    printf '%s' "$r" | grep -cE '^[a-z0-9][a-z0-9._:/-]*@sha256:[0-9a-f]{64}$' >/dev/null \
      || die "'$r' is not a digest-pinned image ref (<repo>/<name>@sha256:<64 hex>). Signatures are over digests, never tags."
  done
  if [ -n "${RIS_EXPECTED_COUNT:-}" ]; then
    printf '%s' "$RIS_EXPECTED_COUNT" | grep -cE '^[0-9]+$' >/dev/null || die "expected-count must be a number, got '$RIS_EXPECTED_COUNT'."
    [ "${#REFS[@]}" -eq "$RIS_EXPECTED_COUNT" ] \
      || die "expected $RIS_EXPECTED_COUNT digest-pinned refs, got ${#REFS[@]} — a release that lost an image must not sign the rest."
  fi
}

check_keys() {
  [ -f "$RIS_PUBLIC_KEY_PEM" ] || die "public-key-pem '$RIS_PUBLIC_KEY_PEM' does not exist — commit the product's public key and point this input at it."
  if [ -n "${RIS_PUBLIC_KEY_PEM_PREVIOUS:-}" ]; then
    [ -f "$RIS_PUBLIC_KEY_PEM_PREVIOUS" ] || die "previous-public-key-pem is set but '$RIS_PUBLIC_KEY_PEM_PREVIOUS' does not exist."
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
  validate_armed
  require_tools

  # Bill Binary Authorization / Container Analysis to the attestor's project.
  # Left to gcloud, a federated signer's calls can be attributed to a project
  # where those APIs are not enabled.
  export CLOUDSDK_BILLING_QUOTA_PROJECT="$ATTESTOR_PROJECT"

  local work err ref digest count i ok key missing="" bad=""
  work="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$work'" EXIT
  err="$work/err"

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
    # A failed list (permissions, wrong project) yields no JSON: reported as a
    # MISS, which fails the step — never a pass.
    gcloud beta container binauthz attestations list \
      --project="$ATTESTOR_PROJECT" \
      --attestor="$ATTESTOR" \
      --attestor-project="$ATTESTOR_PROJECT" \
      --artifact-url="$ref" \
      --format=json > "$work/list.json" 2>/dev/null || : > "$work/list.json"

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

  if [ -n "$missing$bad" ]; then
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
