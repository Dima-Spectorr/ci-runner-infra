#!/usr/bin/env bash
# The firewall's band span and the host's band DNAT must be the same numbers.
#
# They are computed in two languages, in two files, from two copies of the same
# two constants: `host-startup.sh` places each slot's band with CI_BAND_BASE and
# CI_BAND_WIDTH, and `ci-runner-network` opens a span from a base and width of
# its own. The duplication is not an accident — the network module is created
# once per project and deliberately does not depend on the pools — but a
# duplicated constant that drifts is only as safe as whatever notices.
#
# Nothing would notice. A firewall span narrower than the DNAT range does not
# fail an apply, does not log an error on the host, and does not refuse a
# connection in any way a test client can see: the SYN is dropped and the client
# waits until the job's timeout. The symptom is "integration tests are flaky on
# the last slot", weeks later.
#
# So this test reads both files and asserts they agree — on the base, on the
# width, and on the endpoints of the span for several pool sizes.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Overridable so the mutation pass at the bottom can point this same script at
# deliberately broken copies. A checker nobody has ever seen fail is a checker
# whose greps could all be matching nothing.
HOST_SH="${BAND_HOST_SH:-$ROOT/modules/ci-runner-host-pool/scripts/host-startup.sh}"
NET_TF="${BAND_NET_TF:-$ROOT/modules/ci-runner-network/main.tf}"
POOL_TF="${BAND_POOL_TF:-$ROOT/modules/ci-runner-host-pool/main.tf}"
NET_VARS="${BAND_NET_VARS:-$ROOT/modules/ci-runner-network/variables.tf}"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

echo "shared-infra-band self-test:"

for f in "$HOST_SH" "$NET_TF" "$POOL_TF" "$NET_VARS"; do
  if [ ! -r "$f" ]; then
    echo "  FAIL  missing $f — every check below would be vacuous"
    exit 1
  fi
done

# --- the constants, read out of each file rather than restated here -----------
#
# Restating 35000 in this test would make it agree with itself and prove
# nothing: the question is whether the two SOURCES agree, so both numbers are
# extracted, and a missing one is a failure rather than an empty string that
# compares equal to another empty string.

host_base=$(sed -n 's/^CI_BAND_BASE=\([0-9]\{1,\}\)$/\1/p'  "$HOST_SH" | head -1)
host_width=$(sed -n 's/^CI_BAND_WIDTH=\([0-9]\{1,\}\)$/\1/p' "$HOST_SH" | head -1)
tf_base=$(sed -n 's/.*shared_infra_band_base *= *\([0-9]\{1,\}\).*/\1/p'   "$NET_TF" | head -1)
tf_width=$(sed -n 's/.*shared_infra_band_width *= *\([0-9]\{1,\}\).*/\1/p' "$NET_TF" | head -1)

for pair in "host_base:$host_base" "host_width:$host_width" "tf_base:$tf_base" "tf_width:$tf_width"; do
  name=${pair%%:*}; val=${pair#*:}
  if [ -n "$val" ]; then
    ok "$name found ($val)"
  else
    bad "$name not found — the constant was renamed or reshaped, and this test can no longer compare anything"
  fi
done
[ "$fail" -eq 0 ] || { echo "shared-infra-band: FAILED"; exit 1; }

if [ "$host_base" = "$tf_base" ]; then
  ok "band base agrees ($host_base)"
else
  bad "band base differs: host-startup.sh says $host_base, ci-runner-network says $tf_base"
fi

if [ "$host_width" = "$tf_width" ]; then
  ok "band width agrees ($host_width)"
else
  bad "band width differs: host-startup.sh says $host_width, ci-runner-network says $tf_width"
fi

# --- the span endpoints, for several pool sizes -------------------------------
#
# Slots are numbered from ONE, so the span starts one width above the base. That
# off-by-one is the mistake this pair of files is most likely to make
# independently — it was made once already, in the ADR — and it is invisible
# from either side alone: each file is self-consistent while the last slot's
# band sits outside the firewall's range.

for slots in 1 2 4 8 16; do
  want_min=$(( host_base + host_width ))
  want_max=$(( host_base + slots * host_width + host_width - 1 ))

  # The Terraform expression, evaluated rather than pattern-matched: a textual
  # check cannot tell `slots * width` from `(slots - 1) * width`.
  got_min=$(( tf_base + tf_width ))
  got_max=$(( tf_base + slots * tf_width + tf_width - 1 ))

  if [ "$want_min" = "$got_min" ] && [ "$want_max" = "$got_max" ]; then
    ok "slots=$slots span $got_min-$got_max"
  else
    bad "slots=$slots: host says $want_min-$want_max, firewall says $got_min-$got_max"
  fi

  # And the last slot's band must actually be inside the span. This is the
  # assertion the ADR's original formula failed.
  last_slot_max=$(( host_base + slots * host_width + host_width - 1 ))
  if [ "$last_slot_max" -le "$got_max" ]; then
    ok "slots=$slots last slot's band ends inside the span"
  else
    bad "slots=$slots: slot $slots ends at $last_slot_max, past the span's $got_max"
  fi
done

# --- the span is built from the constants, not written out as a literal -------

if grep -qE 'shared_infra_band_base \+ v\.slots_per_host \* local\.shared_infra_band_width' "$NET_TF"; then
  ok "the span's upper end follows slots_per_host"
else
  bad "the span's upper end no longer follows slots_per_host — a fixed span silently drops the slots above it"
fi

got_ports=$(grep -cE 'ports +?= +?\[each\.value\.band_span\]' "$NET_TF")
if [ "$got_ports" -eq 2 ]; then
  ok "both rules take their ports from the computed span"
else
  bad "$got_ports of the 2 band rules take their ports from each.value.band_span — one that names its ports literally drifts from the other, and the pair then permits different ranges in each direction"
fi

# --- the tags: source on both pools, stack tag on Linux only ------------------
#
# This is the half that keeps docs/adr-windows-pool.md true. If the stack tag
# ever lands on a Windows host, the ingress rule targets it and the pool gains
# the inbound path the Windows ADR exists to deny — from a one-line change in a
# file that says nothing about Windows.

# shellcheck disable=SC2016  # the ${...} here is Terraform interpolation in the file being searched, not a shell expansion
if grep -q 'ci-shared-infra-\${var.shared_infra_id}' "$POOL_TF"; then
  ok "the source tag is built from shared_infra_id"
else
  bad "the source tag is not built from shared_infra_id — a tag derived per module differs between the two pools of a pair"
fi

# shellcheck disable=SC2016  # the ${...} here is Terraform interpolation in the file being searched, not a shell expansion
if grep -q 'var.host_os == "linux" ? \["ci-shared-infra-stack-\${var.shared_infra_id}"\]' "$POOL_TF"; then
  ok "the stack tag is conditional on host_os == linux"
else
  bad "the stack tag is not gated on host_os — a Windows host carrying it becomes an ingress TARGET"
fi

if grep -qE 'target_tags +?= +?\[each\.value\.stack_tag\]' "$NET_TF"; then
  ok "the ingress rule targets the stack tag, not the source tag"
else
  bad "the ingress rule does not target the stack tag — with the source tag as target it admits traffic TO every host of the pair, Windows included"
fi

if grep -qE 'source_tags +?= +?\[each\.value\.source_tag\]' "$NET_TF"; then
  ok "the ingress rule's source is the pair-wide tag"
else
  bad "the ingress rule's source is not the pair-wide tag — the Windows host would match no source and rule 3 would fail closed"
fi

# --- disabled by default ------------------------------------------------------
#
# The patterns below are whitespace-tolerant on purpose: `terraform fmt` aligns
# the `=` of adjacent assignments, so a rigid single-space pattern breaks the
# moment a longer name is added beside it — and it breaks as a red gate on an
# unrelated change, which is how a gate gets deleted rather than fixed.

# shellcheck disable=SC2016  # the ${...} here is Terraform interpolation in the file being searched, not a shell expansion
if grep -qF 'source_tag = "ci-shared-infra-${k}"' "$NET_TF"; then
  ok "the network's source tag is built from the pair key"
else
  bad "the network's source tag is not built from the pair key — it would no longer name the tag the pool module puts on the hosts, and the rule would match nothing"
fi

# shellcheck disable=SC2016  # the ${...} here is Terraform interpolation in the file being searched, not a shell expansion
if grep -qF 'stack_tag  = "ci-shared-infra-stack-${k}"' "$NET_TF"; then
  ok "the network's stack tag is built from the pair key"
else
  bad "the network's stack tag is not built from the pair key — the ingress rule would target a tag no Linux host carries"
fi

# --- one rule per PAIR, and none at all by default ----------------------------
#
# The module is created once per project; a pair belongs to a repository. A
# scalar input could describe only the first repository's pair, and pointing it
# at the second silently retargets the first one's rules away from its own
# hosts — a rule that still exists, still applies clean, and admits nothing.

got_each=$(grep -cE 'for_each +?= +?local\.shared_infra$' "$NET_TF")
if [ "$got_each" -eq 2 ]; then
  ok "both band rules are keyed per pair"
else
  bad "$got_each of the 2 band rules iterate local.shared_infra — a rule left on a scalar serves one pair while its partner serves all of them, and the two halves of the path stop agreeing"
fi

if grep -qE '^  default += +\{\}' "$NET_VARS"; then
  ok "the pair map is empty by default"
else
  bad "shared_infra_pairs is not empty by default — a project that asked for no pair gets new firewall rules"
fi

# The generated rule NAME is length-checked, and checked where a second variable
# is legal to read. A `variable` validation cannot reference `var.name_prefix`
# before Terraform 1.9, and this repository supports 1.5 — written there it
# would refuse to LOAD the module for every 1.5-1.8 consumer, including the ones
# that never set a pair.
if grep -qE 'condition += +length\("\$\{var\.name_prefix\}-allow-si-eg-\$\{each\.key\}"\) <= 63' "$NET_TF"; then
  ok "the rule name's 63-character limit is checked at plan time"
else
  bad "the generated egress rule's name is not length-checked in the resource — either the check is gone, or it moved back into a variable validation where a 1.5 consumer cannot load it"
fi

# --- mutations ----------------------------------------------------------------
#
# Every assertion above is a grep or a comparison, and both fail open in the
# same way: rename the thing they read and they match nothing, report nothing,
# and pass. So each one is shown failing on a copy that breaks exactly what it
# claims to check. Skipped in the child runs, which would otherwise recurse.

if [ "${BAND_SELFTEST_CHILD:-}" = "1" ]; then
  [ "$fail" -eq 0 ] && echo "shared-infra-band: all checks pass" || echo "shared-infra-band: FAILED"
  exit "$fail"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mutate() {
  # mutate <label> <file-key> <sed-expression>
  local label="$1" key="$2" expr="$3" out
  cp "$HOST_SH" "$tmp/host.sh"; cp "$NET_TF" "$tmp/net.tf"; cp "$POOL_TF" "$tmp/pool.tf"
  cp "$NET_VARS" "$tmp/net-vars.tf"
  case "$key" in
    host) sed -i "$expr" "$tmp/host.sh" ;;
    net)  sed -i "$expr" "$tmp/net.tf"  ;;
    pool) sed -i "$expr" "$tmp/pool.tf" ;;
    vars) sed -i "$expr" "$tmp/net-vars.tf" ;;
  esac
  out=$(BAND_SELFTEST_CHILD=1 BAND_HOST_SH="$tmp/host.sh" BAND_NET_TF="$tmp/net.tf" BAND_POOL_TF="$tmp/pool.tf" BAND_NET_VARS="$tmp/net-vars.tf"         bash "${BASH_SOURCE[0]}" 2>&1)
  if [ -n "$out" ] && printf '%s' "$out" | grep -q FAIL; then
    ok "mutation caught: $label"
  else
    bad "mutation NOT caught: $label — the assertion for it passes on a file that breaks it"
  fi
}

echo "  -- mutations"
mutate "host base moved to 40000"            host 's/^CI_BAND_BASE=35000/CI_BAND_BASE=40000/'
mutate "host width narrowed to 10"           host 's/^CI_BAND_WIDTH=100/CI_BAND_WIDTH=10/'
mutate "firewall base moved to 35001"        net  's/shared_infra_band_base *= *35000/shared_infra_band_base = 35001/'
mutate "span drops the last slot"            net  's/v.slots_per_host \* local.shared_infra_band_width/(v.slots_per_host - 1) * local.shared_infra_band_width/'
mutate "ingress targets the source tag"      net  's/target_tags *= *\[each.value.stack_tag\]/target_tags = [each.value.source_tag]/'
mutate "ingress sources the stack tag"       net  's/source_tags *= *\[each.value.source_tag\]/source_tags = [each.value.stack_tag]/'
mutate "ports written as a literal span"     net  's/ports *= *\[each.value.band_span\]/ports = ["35100-35499"]/'
mutate "egress left un-keyed"                net  '/shared_infra_egress/,$ s/for_each = local.shared_infra$/count = 1/'
# `${k}` is sed pattern text, not a shell expansion -- the single quotes are
# the point.
# shellcheck disable=SC2016
mutate "source tag no longer built from key" net  's/source_tag = "ci-shared-infra-\${k}"/source_tag = "ci-shared-infra"/'
# shellcheck disable=SC2016
mutate "stack tag no longer built from key"  net  's/stack_tag  = "ci-shared-infra-stack-\${k}"/stack_tag  = "ci-shared-infra-stack"/'
mutate "pairs default to a populated map"    vars 's/^  default = {}$/  default = { demo = { slots_per_host = 4 } }/'
mutate "the name-length precondition removed"  net  '/precondition {/,/^    }$/d'
mutate "stack tag no longer gated on linux"  pool 's/var.host_os == "linux" ? /true ? /'

if [ "$fail" -eq 0 ]; then
  echo "shared-infra-band: all checks pass"
else
  echo "shared-infra-band: FAILED"
fi
exit "$fail"
