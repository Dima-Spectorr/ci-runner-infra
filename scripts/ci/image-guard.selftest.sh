#!/usr/bin/env bash
# The `guard` step of cloudbuild.yaml, tested as the shell actually receives it.
#
# WHY THIS FILE EXISTS. The image trigger produced two builds in its life and
# both died in step 0. The first said `SHORT_SHA: unbound variable` — a shell
# error naming something that is not a shell variable. `_IMAGE_VERSION` was
# `g$SHORT_SHA`, a substitution referenced inside another substitution's value,
# the nesting was never resolved, and Cloud Build pasted the raw text into the
# script for bash to expand a second time.
#
# Nothing caught it because there was nothing to catch it with. Reading
# cloudbuild.yaml, the step is correct: `[ -n "${_IMAGE_VERSION}" ]` is exactly
# the check that was wanted. The defect is not in the source, it is in the
# RENDERING — what remains after substitution and before bash — and a test that
# greps the YAML can never see it. So this file renders the step the way Cloud
# Build does, runs it, and asserts on outcomes.
#
# The rendering rule is measured, not assumed (`5ea57da5`, 2026-08-26, read off
# the executed build resource): `${_NAME}` is replaced by
# its value, and `$$` in an `args` entry is unescaped to a single `$`. This
# step uses `args`. A `script:` step is NOT unescaped the same way, which is a
# separate live defect tracked in #459 — do not copy this renderer to one.
#
# A literal `$` is the SUBJECT of this file, so almost every single-quoted string
# below is deliberately unexpanded — `'g$SHORT_SHA'` is the eleven characters the
# build actually received, and letting the shell expand it would test nothing.
# shellcheck disable=SC2016
#
# The probes are invoked through their NAME, held in a variable, by mutate() —
# which is the design: each has to run against the real config and against a
# mutated copy, and a caller that named one directly could not do both.
# shellcheck disable=SC2317

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$ROOT/cloudbuild.yaml"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

echo "image-guard self-test:"

[ -r "$CONFIG" ] || { echo "  FAIL  cloudbuild.yaml is missing — every check below would be vacuous"; exit 1; }

# Extract the block scalar that is step `guard`'s script. Deliberately not a
# YAML library: the runner image is not guaranteed to carry PyYAML, and a
# missing import would turn this whole file into a skip that still prints a
# heading.
extract_guard() {
  awk '
    /^  - id: guard$/        { in_step = 1; next }
    in_step && /^  - id: /   { exit }
    in_step && /^      - \|$/ { in_body = 1; next }
    in_body {
      if ($0 !~ /^        / && $0 !~ /^[[:space:]]*$/) exit
      sub(/^        /, "")
      print
    }
  ' "$1"
}

# Cloud Build, in its order: substitute, then unescape.
render() {
  local s="$1"; shift
  local kv k v
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    s=${s//"\${$k}"/$v}
  done
  printf '%s' "${s//'$$'/'$'}"
}

# Every substitution the step reads, so a rendering never leaves a `${X}`
# behind and quietly tests a different script than the one that runs. SHORT_SHA
# is in here because it is the one the step now derives the version from, and a
# renderer that ignored it would be testing the bug.
render_guard() {
  local version="$1" sha="${2-3133b15}" zone="${3-us-central1-a}" tag="${4-ci-runner}" loc="${5-us-central1}"
  render "$GUARD" \
    "_IMAGE_VERSION=$version" "SHORT_SHA=$sha" "_ZONE=$zone" \
    "_NETWORK_TAG=$tag" "_IMAGE_STORAGE_LOCATION=$loc"
}

# The ONE thing rewritten that Cloud Build would not: `/workspace` is the
# builder's shared volume and is not writable here. Pointed at a scratch
# directory so the handoff file can be read back and asserted on.
WORKSPACE="$(mktemp -d)"
trap 'rm -rf "$WORKSPACE"' EXIT

run_guard() {
  local script
  script="$(render_guard "$@")"
  case "$script" in
    *'${_'*|*'${SHORT_SHA}'*) echo "RENDER-INCOMPLETE"; return 99 ;;
  esac
  rm -f "$WORKSPACE/image_version"
  printf '%s' "${script//\/workspace\//$WORKSPACE/}" | bash 2>&1
}

# What the later steps read. Empty when the guard refused.
handed_off() { cat "$WORKSPACE/image_version" 2>/dev/null; }

GUARD="$(extract_guard "$CONFIG")"
if [ -z "$GUARD" ]; then
  echo "  FAIL  could not extract the guard step — the extractor no longer matches cloudbuild.yaml"
  echo "  image guard UNVERIFIABLE."
  exit 1
fi
case "$GUARD" in
  *_IMAGE_VERSION*) ok "extracted the guard step ($(printf '%s' "$GUARD" | wc -l) lines)" ;;
  *) echo "  FAIL  extracted a block that does not mention _IMAGE_VERSION — wrong step"; exit 1 ;;
esac

# ---------------------------------------------------------------- the checks

# The rendering is valid shell at all. This alone would have caught nothing:
# `[ -n "g$SHORT_SHA" ]` parses fine. It is `set -u` that made it fatal, and
# `set -u` is one edit away from being dropped.
if printf '%s' "$(render_guard 'g3133b15')" | bash -n 2>/dev/null; then
  ok "the rendered step is syntactically valid"
else
  bad "the rendered step does not parse as shell"
fi

out="$(run_guard 'v3-0-0')"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(handed_off)" = "v3-0-0" ]; then
  ok "a pinned version passes and is handed to the later steps"
else
  bad "a pinned version should pass and be handed on, got rc=$rc handoff='$(handed_off)': $out"
fi

# THE DEFAULT, which is the whole reason the trigger sends nothing now. Empty
# version, real commit: the step derives it, and derives it here where a step's
# text is substituted directly.
out="$(run_guard '' 'abc1234')"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(handed_off)" = "gabc1234" ]; then
  ok "an empty version is derived from SHORT_SHA as gabc1234"
else
  bad "an empty version should derive gabc1234, got rc=$rc handoff='$(handed_off)': $out"
fi

# No commit and no pin: an out-of-band `gcloud builds submit`. Refused rather
# than stamped with something ambiguous.
out="$(run_guard '' '')"; rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"_IMAGE_VERSION is required"* ]] && [ -z "$(handed_off)" ]; then
  ok "no version and no commit is refused, and hands nothing on"
else
  bad "an unversioned non-trigger build should be refused, got rc=$rc: $out"
fi

# THE REGRESSION. An unresolved substitution is non-empty, so it sails through
# every `-n` check, and what it reaches is `image_name` — the build spends
# forty minutes and creates an image literally called
# `ci-runner-host-g$SHORT_SHA`.
out="$(run_guard 'g$SHORT_SHA')"; rc=$?
if [ "$rc" -ne 0 ] && [[ "$out" == *"never resolved"* ]]; then
  ok "an unresolved substitution is refused, by name"
else
  bad "an unresolved _IMAGE_VERSION should be refused, got rc=$rc: $out"
fi

# The value must not be re-expanded by the shell on its way to that check. The
# original step said `"${_IMAGE_VERSION}"` in double quotes, which is why the
# error was about a shell variable rather than about the version.
if [[ "$out" == *'g$SHORT_SHA'* ]]; then
  ok "the unresolved value is echoed literally, not expanded"
else
  bad "the guard should print the offending value verbatim, got: $out"
fi

for pair in "_ZONE:3" "_NETWORK_TAG:4" "_IMAGE_STORAGE_LOCATION:5"; do
  name=${pair%:*}; pos=${pair#*:}
  args=('v3-0-0' '3133b15' 'us-central1-a' 'ci-runner' 'us-central1')
  args[pos - 1]=''
  out="$(run_guard "${args[@]}")"; rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" == *"$name is required"* ]]; then
    ok "an empty $name is refused"
  else
    bad "an empty $name should be refused, got rc=$rc: $out"
  fi
done

# The option that was tried and did not work. Its absence is asserted so that
# turning it on again — the obvious-looking fix, and the one already measured
# twice — has to argue with a test first. Two live builds say it does not reach
# a substitution the trigger supplies; what replaced it needs no option at all.
if grep -qE '^[[:space:]]*dynamicSubstitutions:' "$CONFIG"; then
  bad "options.dynamicSubstitutions is back — see the note in options, it was measured not to help"
else
  ok "no dynamicSubstitutions: the version is derived in a step, not nested"
fi

# Nothing may reach for `_IMAGE_VERSION` after the guard: it is empty on every
# triggered build, and a step that reads it directly silently names the image
# `<family>-`.
strays=$(awk '/^  - id: guard$/ { g = 1; next } /^  - id: / { g = 0 } !g' "$CONFIG" | grep -c 'IMAGE_VERSION}' || true)
if [ "$strays" -eq 0 ]; then
  ok "no step after the guard reads _IMAGE_VERSION directly"
else
  bad "$strays reference(s) to the _IMAGE_VERSION substitution outside the guard - read /workspace/image_version instead"
fi

# AND THE OTHER HALF OF THAT RULE, which cost a whole image build to learn: a
# step may not USE `$IMAGE_VERSION` as a shell variable either unless it reads
# the handoff file first. Each step is its own container, so the assignment the
# guard makes is gone by the time the next one starts; under `set -u` the
# reference is not a wrong name, it is a dead step. Build `8cfda54c`
# (2026-08-26) died on `IMAGE_VERSION: unbound variable` in
# `report`, the LAST step, after packer had already created
# `ci-runner-host-gbcae58c` and forty minutes of provisioning had succeeded.
#
# The check is per-STEP rather than per-file: mentioning the name is fine, and
# so is not mentioning it. What is never fine is one step using the variable
# while another does the reading.
steps_missing_version_read() { # <config> -> the offending step ids, if any
  local cfg="$1" step block out=""
  while IFS= read -r step; do
    [ -n "$step" ] || continue
    [ "$step" = "guard" ] && continue
    block=$(awk -v want="$step" '
      $0 ~ /^  - id: / { cur = substr($0, 9) }
      cur == want { print }
    ' "$cfg")
    case "$block" in
      *'IMAGE_VERSION'*)
        case "$block" in
          *'cat /workspace/image_version'*) : ;;
          *) out="$out $step" ;;
        esac ;;
    esac
  done <<EOF
$(grep -oE '^  - id: .*' "$cfg" | sed 's/^  - id: //')
EOF
  printf '%s' "$out"
}

missing_read="$(steps_missing_version_read "$CONFIG")"
if [ -z "$missing_read" ]; then
  ok "every step that uses \$IMAGE_VERSION reads it from /workspace/image_version"
else
  bad "step(s)$missing_read use \$IMAGE_VERSION without reading /workspace/image_version — a shell variable does not cross a step boundary"
fi

# The mutation for it, run here rather than with the others below: those probe
# the RENDERED guard step, and this one is a property of the file's shape.
_mutant="$(mktemp)"
awk '
  /^  - id: / { step = substr($0, 9) }
  step == "report" && /IMAGE_VERSION="\$\$\(cat \/workspace\/image_version\)"/ { next }
  { print }
' "$CONFIG" > "$_mutant"
if cmp -s "$_mutant" "$CONFIG"; then
  bad "mutation 'the report step stops reading the handoff' changed nothing — the pattern no longer matches"
elif [ -n "$(steps_missing_version_read "$_mutant")" ]; then
  ok "mutation caught: the report step stops reading the handoff"
else
  bad "mutation 'the report step stops reading the handoff' was not caught"
fi
rm -f "$_mutant"

# -------------------------------------------------------------- the mutations
#
# Each removes the fix and asserts a check goes red. A gate that cannot fail is
# the thing this whole file was written about.

mutate() {
  local label="$1" expr="$2" probe="$3"
  local tmp; tmp="$(mktemp)"
  sed -E "$expr" "$CONFIG" > "$tmp"
  if cmp -s "$tmp" "$CONFIG"; then
    bad "mutation '$label' changed nothing — the pattern no longer matches"
    rm -f "$tmp"; return
  fi
  local saved="$GUARD"
  GUARD="$(extract_guard "$tmp")"
  if "$probe"; then
    bad "mutation '$label' was not caught"
  else
    ok "mutation caught: $label"
  fi
  GUARD="$saved"
  rm -f "$tmp"
}

# Each probe re-runs one assertion from above against the MUTATED config and
# returns true when it still holds — i.e. when the mutation slipped past.
probe_unresolved_refused() {
  local o; o="$(run_guard 'g$SHORT_SHA')"
  [[ "$o" == *"never resolved"* ]]
}
probe_value_is_literal() {
  local o; o="$(run_guard 'g$SHORT_SHA')"
  [[ "$o" == *'g$SHORT_SHA'* ]]
}

mutate "the unresolved-substitution check deleted" \
  '/a substitution in it was never resolved/,+4d; /case "\$\$IMAGE_VERSION" in/d' \
  probe_unresolved_refused

probe_derives_from_sha() {
  run_guard '' 'abc1234' >/dev/null
  [ "$(handed_off)" = "gabc1234" ]
}
probe_handoff_after_checks() {
  run_guard 'v3-0-0' '3133b15' '' >/dev/null
  [ -z "$(handed_off)" ]
}

mutate "the SHORT_SHA fallback deleted" \
  '/IMAGE_VERSION="g\$\$SHORT_SHA"/d' \
  probe_derives_from_sha

# The handoff moved back above the checks, which is where it was first written.
# A build that the guard is about to refuse would leave a version file behind,
# and the file's existence is what the later steps take as agreement.
mutate "the handoff written before the checks" \
  '/printf .%s. "\$\$IMAGE_VERSION" > \/workspace\/image_version/d; s@^( *)\[ -n "\$\$ZONE" \]@\1printf "%s" "$$IMAGE_VERSION" > /workspace/image_version\n\1[ -n "$$ZONE" ]@' \
  probe_handoff_after_checks

mutate "the version taken back into double quotes" \
  "s@IMAGE_VERSION='\\\$\\{_IMAGE_VERSION\\}'@IMAGE_VERSION=\"\\\${_IMAGE_VERSION}\"@" \
  probe_value_is_literal

# ---- what the build reads, versus what the trigger watches -------------------
#
# The image trigger fires on a path list, and the packer template uploads files
# into the build with `file` provisioners. Those two sets have to agree, and
# nothing made them: the vulnerability gate's script and its two data files live
# outside `packer/`, were copied in from the start, and were never watched.
#
# The failure that produces is circular and does not look like a configuration
# bug. The gate goes red on a finding; the fix is a line in
# `docs/image-vuln-offdistro.txt`; merging that line rebuilds nothing, because
# the trigger never heard of the file. The red build stays red until somebody
# happens to touch `packer/` for an unrelated reason.
#
# Derived from the template rather than listed here, so a new provisioner is
# caught the day it is added instead of the day it matters.
PKR="$ROOT/packer/ci-host-image.pkr.hcl"
TRIGGER_VARS="$ROOT/modules/ci-host-image-trigger/variables.tf"
packer_upload_paths_are_watched() {
  [ -r "$PKR" ] && [ -r "$TRIGGER_VARS" ] || {
    bad "cannot read the packer template or the trigger's variables — this check would be vacuous"
    return
  }
  # `source = "../<path>"` in a provisioner: the `..` is what makes it a file
  # outside `packer/`, which is exactly the population at issue.
  local unwatched="" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    grep -qF "\"$path\"" "$TRIGGER_VARS" || unwatched="$unwatched $path"
  done <<EOF
$(grep -oE 'source[[:space:]]*=[[:space:]]*"\.\./[^"]+"' "$PKR" | sed 's/.*"\.\.\///; s/"$//' | sort -u)
EOF
  printf '%s' "$unwatched"
}

unwatched="$(packer_upload_paths_are_watched)"
if [ -z "$unwatched" ]; then
  ok "every file the packer template uploads from outside packer/ is watched by the trigger"
else
  bad "the build reads$unwatched but the trigger does not watch it — changing one of those files cannot cause the rebuild that would apply it. Add it to included_files in $TRIGGER_VARS"
fi

# The mutation: drop one path from the watched list and the check must notice.
_tvmut="$(mktemp)"
grep -v '"docs/image-vuln-offdistro.txt"' "$TRIGGER_VARS" > "$_tvmut"
if cmp -s "$_tvmut" "$TRIGGER_VARS"; then
  bad "mutation 'a watched upload path removed' changed nothing — the path is no longer in the list"
else
  _tvreal="$TRIGGER_VARS"; TRIGGER_VARS="$_tvmut"
  if [ -n "$(packer_upload_paths_are_watched)" ]; then
    ok "mutation caught: a watched upload path removed"
  else
    bad "mutation 'a watched upload path removed' was not caught"
  fi
  TRIGGER_VARS="$_tvreal"
fi
rm -f "$_tvmut"

echo
if [ "$fail" -eq 0 ]; then
  echo "image-guard selftest: all checks passed"
else
  echo "image-guard selftest: FAILURES above"
fi
exit "$fail"
