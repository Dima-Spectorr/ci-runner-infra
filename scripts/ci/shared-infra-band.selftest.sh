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
POOL_VARS="${BAND_POOL_VARS:-$ROOT/modules/ci-runner-host-pool/variables.tf}"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

echo "shared-infra-band self-test:"

for f in "$HOST_SH" "$NET_TF" "$POOL_TF" "$NET_VARS" "$POOL_VARS"; do
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

# The two endpoint expressions are READ OUT OF the Terraform, not restated here.
# Restated, this loop compared one hand-written formula against another and
# agreed with itself: change the Terraform's lower endpoint to `base + 2 *
# width`, or its upper endpoint's trailing `- 1` to `- 2`, and the test that
# exists to catch exactly that mismatch stayed green. The formulas below are
# whatever `band_span` currently says; the shell evaluates them with the same
# three inputs Terraform would.
#
# `format("%d-%d", <min expr>, <max expr>)` — the two argument lines, in order.
span_args=$(sed -n '/band_span = format(/,/^      )$/p' "$NET_TF" |
  sed -n 's/^ *\(local\.shared_infra_band_base[^,]*\),$/\1/p')
span_min_expr=$(printf '%s
' "$span_args" | sed -n 1p)
span_max_expr=$(printf '%s
' "$span_args" | sed -n 2p)

if [ -n "$span_min_expr" ] && [ -n "$span_max_expr" ]; then
  ok "both band_span endpoint expressions were read from the Terraform"
else
  bad "band_span's endpoint expressions could not be read from $NET_TF — the span is built some other way now, and every endpoint comparison below would silently compare nothing"
fi
[ "$fail" -eq 0 ] || { echo "shared-infra-band: FAILED"; exit 1; }

# Terraform arithmetic that survives translation to `$(( ))` is the subset these
# expressions use: the three names, integers, and `+ - * ( )`. Anything else —
# a `min()`, a conditional, a new variable — is not silently evaluated to
# something plausible; it fails the gate and asks for a human.
tf_expr_value() { # <expr> <slots>
  local e
  e=$(printf '%s' "$1" |
    sed -e "s/local\.shared_infra_band_base/$tf_base/g"         -e "s/local\.shared_infra_band_width/$tf_width/g"         -e "s/v\.slots_per_host/$2/g")
  if [ -n "$(printf '%s' "$e" | tr -d '0-9 +*()-')" ]; then
    printf 'UNEVALUATABLE'
    return 0
  fi
  printf '%s' "$(( e ))"
}

for slots in 1 2 4 8 16; do
  want_min=$(( host_base + host_width ))
  want_max=$(( host_base + slots * host_width + host_width - 1 ))

  # The Terraform expression, evaluated rather than pattern-matched: a textual
  # check cannot tell `slots * width` from `(slots - 1) * width`.
  got_min=$(tf_expr_value "$span_min_expr" "$slots")
  got_max=$(tf_expr_value "$span_max_expr" "$slots")

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
if [ "$got_ports" -eq 3 ]; then
  ok "all three rules take their ports from the computed span"
else
  bad "$got_ports of the 3 band rules take their ports from each.value.band_span — the ingress allow, the egress allow and the egress deny must name one range, and one that spells its ports literally drifts from the other two: the deny then carves a hole the allow does not fill, or leaves one it does"
fi

# --- the tags: source on both pools, stack tag on Linux only ------------------
#
# This is the half that keeps docs/adr-windows-pool.md true. If the stack tag
# ever lands on a Windows host, the ingress rule targets it and the pool gains
# the inbound path the Windows ADR exists to deny — from a one-line change in a
# file that says nothing about Windows.

# shellcheck disable=SC2016  # the ${...} here is Terraform interpolation in the file being searched, not a shell expansion
if grep -q 'ci-shared-infra-src-\${var.shared_infra_id}' "$POOL_TF"; then
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
if grep -qF 'source_tag = "ci-shared-infra-src-${k}"' "$NET_TF"; then
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

# --- the two namespaces are disjoint ------------------------------------------
#
# Nested, they were not two namespaces at all. `ci-shared-infra-<key>` for the
# source and `ci-shared-infra-stack-<key>` for the stack meant the pair keyed
# `stack-foo` had `foo`'s STACK tag as its own SOURCE tag -- both keys valid,
# both applies green, and `foo`'s ingress rule now targets `stack-foo`'s hosts,
# Windows included. Same shape one layer up in the rule names: `-allow-si-<key>`
# contained `-allow-si-eg-<key>`, so a pair keyed `eg-foo` collided with `foo`'s
# egress rule on a name that must be unique per project.
#
# What makes them disjoint is a FIXED role token between the fixed prefix and
# the key, so no key can spell its way from one namespace into the other. These
# assertions check the token is still there; that is the whole property.

# shellcheck disable=SC2016  # the ${...} here is Terraform interpolation in the file being searched, not a shell expansion
if grep -qF 'source_tag = "ci-shared-infra-src-${k}"' "$NET_TF" &&
   grep -qF 'stack_tag  = "ci-shared-infra-stack-${k}"' "$NET_TF"; then
  ok "the source and stack tag namespaces cannot collide"
else
  bad "the source and stack tags no longer sit in separate namespaces -- a pair key can spell the other role's tag, joining two repositories' bands with no error anywhere"
fi

# shellcheck disable=SC2016  # the Terraform interpolations are the literals under test
if grep -qF -- '-allow-si-in-${each.key}' "$NET_TF" && grep -qF -- '-allow-si-eg-${each.key}' "$NET_TF"; then
  ok "the ingress and egress rule names cannot collide"
else
  bad "the band rule names no longer carry distinct direction tokens -- a pair key can claim the other direction's firewall name, and firewall names are unique per project"
fi

# --- one rule per PAIR, and none at all by default ----------------------------
#
# The module is created once per project; a pair belongs to a repository. A
# scalar input could describe only the first repository's pair, and pointing it
# at the second silently retargets the first one's rules away from its own
# hosts — a rule that still exists, still applies clean, and admits nothing.

got_each=$(grep -cE 'for_each +?= +?local\.shared_infra$' "$NET_TF")
if [ "$got_each" -eq 3 ]; then
  ok "all three band rules are keyed per pair"
else
  bad "$got_each of the 3 band rules iterate local.shared_infra — a rule left on a scalar serves one pair while its partners serve all of them, and the halves of the path stop agreeing"
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

# ---------------------------------------------------------------------------
# The egress ALLOW has a floor to be an exception to.
#
# An allow rule permits nothing on its own; it carves a hole in a deny. The
# module-wide `egress_deny` is that deny — and it targets var.runner_network_tag,
# which a WINDOWS pool does not carry, because the documented Windows
# configuration passes no network_tags at all. Such a host matches no deny,
# falls through to GCP's implied allow-egress, and reaches a band port at any
# address at all. Not through this module's allow: through the absence of a
# refusal. destination_ranges and the per-pair override were advisory on
# precisely the host the feature was built for.
if grep -qE 'resource "google_compute_firewall" "shared_infra_egress_deny"' "$NET_TF"; then
  ok "band egress outside the permitted ranges is refused, not merely un-allowed"
else
  bad "there is no band egress deny — on a pool that carries no runner_network_tag the allow is decorative and destination_ranges constrains nothing"
fi

# It targets the SOURCE tag, which is the one tag such a host is guaranteed to
# have; targeting runner_network_tag again would reproduce the hole exactly.
if grep -qE '^  target_tags += +\[each\.value\.source_tag\]' "$NET_TF" &&
  [ "$(grep -cE '^  target_tags += +\[each\.value\.source_tag\]' "$NET_TF")" -eq 2 ]; then
  ok "the band deny follows the sending hosts by their source tag"
else
  bad "the band deny does not target each.value.source_tag — a deny on any other tag misses the Windows host it exists for"
fi

# And it LOSES to the allow. The allow runs at Terraform's default priority of
# 1000; a deny that outranked it would close the band outright, and a consumer
# hanging until the job's timeout looks the same either way.
if grep -qE '^  priority += +65533$' "$NET_TF"; then
  ok "the band deny sits below the allow, so the permitted ranges still pass"
else
  bad "the band deny's priority is not 65533 — above the allow's default 1000 it closes the band it is supposed to bound"
fi

# ---------------------------------------------------------------------------
# A one-slot pair is a deadlock, and the pair map is where it can be refused.
#
# The owner job reserves its slot for the length of the run. On a one-slot host
# it therefore takes the only agent, every consumer is pinned to that host, and
# nothing runs until the sweep releases the slot -- by tearing down the stack
# the consumers were queued for. adr-pr-host-affinity.md §3.4 called this
# uncatchable at plan time because a POOL cannot know whether the repository
# adopted the contract. The pair map can: entering it IS the adoption, and it
# carries the Linux pool's slots_per_host as its own input.
if grep -qE 'v\.slots_per_host >= 2 && v\.slots_per_host <= 90' "$NET_VARS"; then
  ok "a shared-infra pair must leave at least one slot for a consumer"
else
  bad "shared_infra_pairs still accepts slots_per_host = 1 — a pair that cannot run a single consumer applies clean and deadlocks the first run that uses it"
fi

# ---------------------------------------------------------------------------
# The tag namespace is RESERVED, not merely conventional.
#
# `ci-shared-infra-src-<id>` and `ci-shared-infra-stack-<id>` are the whole
# boundary: the firewall rules match on those strings and on nothing else. But
# the pool name is applied to every host as a network tag too, and so is every
# entry in var.network_tags. A pool named `ci-shared-infra-src-checkout` -- a
# name the existing 63-char validation is perfectly happy with -- is thereby an
# authorized source for pair `checkout`, in a pull request that never requested
# it and quite possibly another repository's. Nothing downstream can tell that
# tag from a minted one, because it IS the minted one.
#
# So the check has to live where names are accepted. Both doors, because a
# caller writing the tag into var.network_tags by hand does not need a
# plausible pool name at all.
if grep -qF 'startswith(var.name, "ci-shared-infra-")' "$POOL_VARS"; then
  ok "a pool may not NAME itself into a shared-infra tag namespace"
else
  bad "var.name accepts a ci-shared-infra- prefix — a pool name alone can join a pair's firewall rules"
fi

if grep -qF 'for t in var.network_tags : !startswith(t, "ci-shared-infra-")' "$POOL_VARS"; then
  ok "a caller may not hand-write a shared-infra tag into network_tags"
else
  bad "network_tags accepts a ci-shared-infra- tag — the reservation on var.name is then just a speed bump"
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
  cp "$NET_VARS" "$tmp/net-vars.tf"; cp "$POOL_VARS" "$tmp/pool-vars.tf"
  case "$key" in
    host) sed -i "$expr" "$tmp/host.sh" ;;
    net)  sed -i "$expr" "$tmp/net.tf"  ;;
    pool) sed -i "$expr" "$tmp/pool.tf" ;;
    vars) sed -i "$expr" "$tmp/net-vars.tf" ;;
    poolvars) sed -i "$expr" "$tmp/pool-vars.tf" ;;
  esac
  out=$(BAND_SELFTEST_CHILD=1 BAND_HOST_SH="$tmp/host.sh" BAND_NET_TF="$tmp/net.tf" BAND_POOL_TF="$tmp/pool.tf" BAND_NET_VARS="$tmp/net-vars.tf" BAND_POOL_VARS="$tmp/pool-vars.tf" bash "${BASH_SOURCE[0]}" 2>&1)
  if [ -n "$out" ] && printf '%s' "$out" | grep -c FAIL >/dev/null; then
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
mutate "the source tag namespace contains the stack one" net 's/ci-shared-infra-src-\${k}/ci-shared-infra-${k}/'
# shellcheck disable=SC2016  # the Terraform interpolations are the literals under test
mutate "the ingress rule name loses its direction"       net 's/-allow-si-in-\${each\.key}/-allow-si-${each.key}/'
mutate "the span's lower endpoint moved a slot up" net 's/^        local\.shared_infra_band_base + local\.shared_infra_band_width,$/        local.shared_infra_band_base + 2 * local.shared_infra_band_width,/'
mutate "the span's upper endpoint lost a port"    net 's/local\.shared_infra_band_width - 1,$/local.shared_infra_band_width - 2,/'
# shellcheck disable=SC2016  # the Terraform interpolations are the literals under test
mutate "source tag no longer built from key" net  's/source_tag = "ci-shared-infra-src-\${k}"/source_tag = "ci-shared-infra-src"/'
# shellcheck disable=SC2016
mutate "stack tag no longer built from key"  net  's/stack_tag  = "ci-shared-infra-stack-\${k}"/stack_tag  = "ci-shared-infra-stack"/'
mutate "pairs default to a populated map"    vars 's/^  default = {}$/  default = { demo = { slots_per_host = 4 } }/'
mutate "the name-length precondition removed"  net  '/precondition {/,/^    }$/d'
mutate "stack tag no longer gated on linux"  pool 's/var.host_os == "linux" ? /true ? /'
mutate "the band egress deny removed"        net  '/resource "google_compute_firewall" "shared_infra_egress_deny"/,/^}$/d'
mutate "the band deny outranks the allow"    net  's/^  priority *= 65533$/  priority           = 999/'
mutate "the band deny follows the wrong tag" net  '/shared_infra_egress_deny/,$ s/target_tags        = \[each.value.source_tag\]/target_tags        = [var.runner_network_tag]/'
mutate "a one-slot pair is accepted again"   vars 's/v.slots_per_host >= 2/v.slots_per_host >= 1/'
mutate "the pool name may enter the namespace" poolvars 's/!startswith(var.name, "ci-shared-infra-")/true/'
mutate "network_tags may enter the namespace"  poolvars 's/!startswith(t, "ci-shared-infra-")/true/'

if [ "$fail" -eq 0 ]; then
  echo "shared-infra-band: all checks pass"
else
  echo "shared-infra-band: FAILED"
fi
exit "$fail"
