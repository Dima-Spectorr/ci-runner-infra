#!/usr/bin/env bash
# cloud-sdk-digest — keep the digest-pinned `cloud-sdk:slim` image fresh across
# the modules that run Cloud Build steps in it (#1614).
#
# WHY THIS EXISTS (#1588, #1614)
#
# Two modules run privileged Cloud Build steps in Google's `cloud-sdk` image:
#   modules/ci-runner-apply-trigger/main.tf      local.cloud_sdk_image
#   modules/ci-runner-cache-warmer/variables.tf  variable "gcloud_image" default
#
# Pinning by `@sha256:` stops a moving `:slim` tag from changing the destroy
# guard or the cache publisher with nothing merged here (#1588). A digest pin
# nobody watches has the opposite failure: it stays frozen while `cloud-sdk:slim`
# ships weekly OS/Python/gcloud CVE fixes (#1614).
#
# Pure functions + small CLI, mirroring `runner-version.sh`:
#   `.github/workflows/cloud-sdk-digest.yml` (via `cloud-sdk-digest-watch.sh`)
#   is the only caller that touches the network, and `cloud-sdk-digest.selftest.sh`
#   proves every rule and mutates each one to show it is load-bearing.
#
# Tenancy-agnostic: no owner, project or customer literal.

set -uo pipefail

CSD_IMAGE_REPO="gcr.io/google.com/cloudsdktool/cloud-sdk"
CSD_APPLY_FILE="modules/ci-runner-apply-trigger/main.tf"
CSD_WARMER_FILE="modules/ci-runner-cache-warmer/variables.tf"

# csd_valid <digest> -- 0 when <digest> is an exact lowercase `sha256:<64-hex>`.
csd_valid() {
  local d="${1:-}" hex
  case "$d" in
    sha256:*)
      hex="${d#sha256:}"
      [ "${#hex}" -eq 64 ] || return 1
      case "$hex" in *[!0-9a-f]*) return 1 ;; esac
      return 0
      ;;
    *) return 1 ;;
  esac
}

# csd_apply_pin <file> -- the `@sha256:...` digest of `local.cloud_sdk_image`.
csd_apply_pin() {
  sed -n "s|^[[:space:]]*cloud_sdk_image[[:space:]]*=[[:space:]]*\"${CSD_IMAGE_REPO}@\(sha256:[^\"]*\)\"[[:space:]]*$|\1|p" "$1" 2>/dev/null | sed -n '1p'
}

# csd_warmer_pin <file> -- the `@sha256:...` default of `variable "gcloud_image"`.
csd_warmer_pin() {
  awk -v prefix="${CSD_IMAGE_REPO}@" '
    /^variable "gcloud_image" \{/ { inblk = 1; next }
    inblk && /^\}/ { exit }
    inblk && /^[[:space:]]*default[[:space:]]*=/ {
      line = $0
      sub(/^[^"]*"/, "", line); sub(/".*$/, "", line)
      if (index(line, prefix) == 1) {
        print substr(line, length(prefix) + 1)
      }
      exit
    }
  ' "$1" 2>/dev/null
}

# csd_pins <repo root> -- prints the single `sha256:<64-hex>` digest when both
# modules agree and are valid; prints diagnostics on stderr and returns 1 when
# either is missing, malformed or out of step.
csd_pins() {
  local root="$1" a w
  a=$(csd_apply_pin "$root/$CSD_APPLY_FILE")
  w=$(csd_warmer_pin "$root/$CSD_WARMER_FILE")
  if csd_valid "$a" && [ "$a" = "$w" ]; then
    printf '%s\n' "$a"
    return 0
  fi
  {
    echo "cloud-sdk pins disagree or are not valid sha256 digests:"
    echo "  $CSD_APPLY_FILE  cloud_sdk_image     = '${a}'"
    echo "  $CSD_WARMER_FILE gcloud_image default = '${w}'"
  } >&2
  return 1
}

# csd_verify_manifest <headers file> <body file>
# Computes `sha256:<hex>` over the raw manifest bytes in <body file>, verifies
# <body file> parses as a Docker/OCI manifest JSON object, and — if the registry
# sent a `Docker-Content-Digest` header — asserts the header matches the
# computed digest. Never trusts the header without hashing the body.
csd_verify_manifest() {
  local hdr="$1" body="$2" computed header_digest
  [ -s "$body" ] || { echo "csd_verify_manifest: empty manifest body" >&2; return 1; }
  python3 - "$body" <<'PY' || { echo "csd_verify_manifest: body is not a valid Docker/OCI manifest JSON" >&2; return 1; }
import json, sys
with open(sys.argv[1], "rb") as fh:
    doc = json.load(fh)
if not isinstance(doc, dict):
    sys.exit(1)
mt = str(doc.get("mediaType") or "")
has_layers = isinstance(doc.get("manifests"), list) or isinstance(doc.get("layers"), list)
if not has_layers and "manifest" not in mt and "index" not in mt:
    sys.exit(1)
PY
  computed="sha256:$(sha256sum "$body" | awk '{print $1}')"
  csd_valid "$computed" || { echo "csd_verify_manifest: invalid computed digest '$computed'" >&2; return 1; }
  if [ -f "$hdr" ]; then
    header_digest=$(tr -d '\r' <"$hdr" | awk 'tolower($1) == "docker-content-digest:" { print $2 }' | tail -n 1)
    if [ -n "$header_digest" ] && [ "$header_digest" != "$computed" ]; then
      echo "csd_verify_manifest: Docker-Content-Digest '$header_digest' != computed '$computed'" >&2
      return 1
    fi
  fi
  printf '%s\n' "$computed"
}

# csd_bump <repo root> <new digest> -- atomically rewrite both pins to <new>.
# Refuses unless both existing pins currently agree and <new> is `csd_valid`.
csd_bump() {
  local root="$1" new="$2" tmp_a tmp_w
  csd_valid "$new" || { echo "csd_bump: '$new' is not sha256:<64-hex>" >&2; return 1; }
  csd_pins "$root" >/dev/null || return 1

  tmp_a="$root/$CSD_APPLY_FILE.csd-tmp"
  tmp_w="$root/$CSD_WARMER_FILE.csd-tmp"

  sed "s|^\\([[:space:]]*cloud_sdk_image[[:space:]]*=[[:space:]]*\"${CSD_IMAGE_REPO}@\\)sha256:[0-9a-f]*\"|\\1${new}\"|" \
    "$root/$CSD_APPLY_FILE" >"$tmp_a" || { rm -f "$tmp_a"; return 1; }

  awk -v repo="$CSD_IMAGE_REPO" -v new="$new" '
    /^variable "gcloud_image" \{/ { inblk = 1 }
    inblk && !done && /^[[:space:]]*default[[:space:]]*=/ {
      sub(/"[^"]*"/, "\"" repo "@" new "\"")
      done = 1
    }
    inblk && /^\}/ { inblk = 0 }
    { print }
  ' "$root/$CSD_WARMER_FILE" >"$tmp_w" || { rm -f "$tmp_a" "$tmp_w"; return 1; }

  mv -f "$tmp_a" "$root/$CSD_APPLY_FILE" || { rm -f "$tmp_w"; return 1; }
  mv -f "$tmp_w" "$root/$CSD_WARMER_FILE" || return 1
  [ "$(csd_pins "$root")" = "$new" ]
}

# csd_pr_title <old digest> <new digest> / csd_pr_title_digest <title>
# Uses `fix(deps):` so release-please cuts a tag for module consumers; carries
# the full target digest so `csd_pr_title_digest` is an exact inverse.
csd_pr_title() {
  local old_short="${1#sha256:}"
  old_short="sha256:${old_short:0:12}"
  printf 'fix(deps): pin cloud-sdk:slim to %s (was %s)\n' "$2" "$old_short"
}

csd_pr_title_digest() {
  local d
  d=$(printf '%s\n' "$1" | sed -n 's/^fix(deps): pin cloud-sdk:slim to \(sha256:[0-9a-f]\{64\}\) (was sha256:[0-9a-f]\{12\})$/\1/p')
  csd_valid "$d" && printf '%s\n' "$d"
}

csd_pr_body() {
  local old="$1" new="$2"
  cat <<EOF
Opened by \`cloud-sdk-digest.yml\`, the scheduled \`cloud-sdk:slim\` digest check (#1614).

Google's \`${CSD_IMAGE_REPO}:slim\` tag now resolves to \`${new}\` (this repository currently pins \`${old}\`). Keeping the \`@sha256:\` pin prevents unreviewed tag drift inside privileged Cloud Build steps (#1588); advancing it on schedule picks up upstream Debian, Python and Google Cloud SDK security patches (#1614).

This PR updates both pins in lockstep:

- \`${CSD_APPLY_FILE}\`: \`local.cloud_sdk_image\`
- \`${CSD_WARMER_FILE}\`: \`variable "gcloud_image"\` default

**Merging updates module defaults only.** Each consumer root picks up the new Cloud Build step image on its next Terraform apply after bumping its \`ci-runner-infra\` module ref.

If \`cloud-sdk:slim\` advances again before this merges, the next scheduled run updates this PR in place on \`automation/cloud-sdk-digest\` instead of opening a second one.

Tier: direct
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    pins) csd_pins "${1:-.}" ;;
    verify-manifest) csd_verify_manifest "$@" ;;
    bump) csd_bump "$@" ;;
    *)
      echo "usage: $0 pins [root] | verify-manifest <headers> <body> | bump <root> <sha256:...>" >&2
      exit 2
      ;;
  esac
fi
