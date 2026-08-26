#!/usr/bin/env bash
# Self-test for the seam between a pool and the controller that serves it.
#
# The controller is now a module of its own, and everything it needs about a
# pool travels as data: a `pool_descriptor` output on one side, a `ci-pools`
# JSON table on the other, parsed by pool-table.sh on the VM. Terraform checks
# none of that. `jsonencode` will happily encode a key the parser has never
# heard of, and the parser will happily default the column that key was supposed
# to fill — so a typo does not fail an apply, it produces a pool that drains on
# somebody else's grace period.
#
# The four things that break silently, and are checked here:
#
#   1. The controller module reads the decision scripts from its SIBLING module.
#      That resolves for a `git::…//modules/x` source (the clone carries the
#      whole repository) and not for an archive or registry source. A path that
#      stops resolving is `file()` failing at plan — but a path that resolves to
#      the WRONG place is a controller booting with a startup script that is
#      missing a rule, which runs, and quietly never drains.
#   2. The two modules each build the startup script from their own `join`.
#      Two lists drift. A controller missing recycle-decision.sh boots fine.
#   3. Every key of `pool_descriptor` is a column pool-table.sh actually reads.
#   4. Every column with NO safe default is in the descriptor. `mig` is the
#      worst of them: absent, the row is rejected, the pool is never ticked, and
#      its ONLY_UP autoscaler holds its last size while the dashboard is green.
#
# Tenancy-agnostic — no customer literals.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
POOL_TF="$ROOT/modules/ci-runner-host-pool"
CTRL_TF="$ROOT/modules/ci-runner-controller"
TABLE="$POOL_TF/scripts/pool-table.sh"

pass=0
fail=0
check() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "ok   $1"
    pass=$((pass + 1))
  else
    echo "FAIL $1: expected [$2] got [$3]"
    fail=$((fail + 1))
  fi
}

# --- 1 + 2. the same scripts, in the same order, and all of them on disk -------

# The pool module names them `${path.module}/scripts/x.sh`; the controller module
# names them `${local.pool_scripts}/x.sh`. Reduced to bare filenames, the two
# lists must be identical — including ORDER, because pool-table.sh has to be
# concatenated before the controller that calls pool_table_parse at file scope.
# `controller_startup_source`, not `controller_startup`: the value that reaches
# metadata is now a wrapper that gunzips this one, so the join is what the two
# lists have to be read out of. Matching the shorter name would also match the
# wrapper.
pool_list=$(sed -n '/controller_startup_source = join(/,/^  ])$/p' "$POOL_TF/main.tf" |
  grep -o 'scripts/[a-z-]*\.sh' | sed 's|scripts/||')
ctrl_list=$(sed -n '/controller_startup_source = join(/,/^  ])$/p' "$CTRL_TF/main.tf" |
  grep -o 'pool_scripts}/[a-z-]*\.sh' | sed 's|pool_scripts}/||')

check "the controller module builds its startup from the same scripts, in order" \
  "$pool_list" "$ctrl_list"

# A non-empty list, so a `sed` range that silently matches nothing cannot make
# the assertion above pass by comparing two empty strings.
check "the extraction found a script list at all" \
  yes "$([ "$(printf '%s\n' "$pool_list" | grep -c .)" -ge 8 ] && echo yes || echo no)"

missing=""
while read -r f; do
  [ -n "$f" ] || continue
  [ -f "$POOL_TF/scripts/$f" ] || missing="$missing $f"
done <<EOF
$ctrl_list
EOF
check "every script the controller module names is on disk beside it" "" "$missing"

# The relative hop itself, spelled as Terraform spells it. A rename of either
# module directory turns `file()` into a plan-time error nobody sees until the
# next apply of a repository that is not this one.
check "the sibling path the controller module uses resolves" yes \
  "$([ -d "$CTRL_TF/../ci-runner-host-pool/scripts" ] && echo yes || echo no)"

# --- 3 + 4. the descriptor speaks the parser's vocabulary ----------------------

# The columns, read out of the parser rather than restated here: every default
# in its jq block plus the one column that is compared instead of defaulted.
columns=$(
  {
    sed -n '/^  rows=/,/@tsv/p' "$TABLE" | grep -o '(\.[a-z_]* //' |
      tr -d '(. /'
    grep -o '\.mints_registration_token' "$TABLE" | head -1 | tr -d '.'
  } | sort -u
)
check "the parser still declares sixteen columns" 16 \
  "$(printf '%s\n' "$columns" | grep -c .)"

# `value = {` inside the pool_descriptor output, keys only.
descriptor=$(sed -n '/^output "pool_descriptor"/,/^}/p' "$POOL_TF/outputs.tf" |
  grep -oE '^    [a-z_]+ +=' | tr -d ' =' | sort -u)
check "the descriptor was found" yes \
  "$([ "$(printf '%s\n' "$descriptor" | grep -c .)" -ge 10 ] && echo yes || echo no)"

# A key the parser never reads is not an error anywhere: jsonencode writes it,
# jq ignores it, and the column it was meant to fill quietly takes its default.
unknown=""
while read -r k; do
  [ -n "$k" ] || continue
  printf '%s\n' "$columns" | grep -cx "$k" >/dev/null || unknown="$unknown $k"
done <<EOF
$descriptor
EOF
check "no descriptor key is a column the parser does not read" "" "$unknown"

# The four with no safe default. `slots` defaults to 1 and `host_os` to linux —
# wrong, but survivable and visible. These four are not: an absent `mig` or
# `region` rejects the row outright, and an absent `runner_labels` matches no
# job under GitHub's superset rule, so the pool reports zero demand forever
# while looking perfectly healthy.
for required in name mig region runner_labels; do
  printf '%s\n' "$descriptor" | grep -cx "$required" >/dev/null && r=yes || r=no
  check "the descriptor carries '$required', which has no safe default" yes "$r"
done

# The controller module's own `pools` type must accept every column, or a
# consumer setting one gets "an argument named X is not expected here" — at
# plan, which is the good failure, but only if the type is actually complete.
accepted=$(sed -n '/^  type = list(object({/,/^  }))$/p' "$CTRL_TF/variables.tf" |
  grep -oE '^    [a-z_]+ +=' | tr -d ' =' | sort -u)
check "the controller module's pools type accepts every column" \
  "$(printf '%s\n' "$columns")" "$(printf '%s\n' "$accepted")"

# --- 5. a pool can genuinely be built without a controller ---------------------

grep -qF 'count = var.manage_controller ? 1 : 0' "$POOL_TF/main.tf" && r=yes || r=no
check "manage_controller really removes the pool's own controller" yes "$r"

# And the table is rendered by the controller module ONLY. Rendering it in the
# pool module too would rewrite every existing controller's metadata to say what
# it already says, on whatever apply happened to be next.
grep -q '"ci-pools"' "$POOL_TF/main.tf" && r=yes || r=no
check "the pool module still renders one key per field, not a table" no "$r"

# --- 6. the controller is a managed group, and never two of them (#308) -------
#
# Both modules build the controller from a template held by a group of size 1,
# so a DELETED controller is rebuilt instead of staying deleted. Two properties
# of that arrangement are load-bearing and would fail silently if edited away,
# because both produce a plan that applies cleanly.
for m in "$POOL_TF" "$CTRL_TF"; do
  n=$(basename "$m")

  grep -q 'resource "google_compute_instance_group_manager" "controller"' "$m/main.tf" &&
    r=yes || r=no
  check "$n: the controller is a managed group, not a pet" yes "$r"

  # The pet is GONE, not merely joined by a group. Leaving the old resource in
  # place next to the new one is a plan that creates a second control plane and
  # reports success: two controllers, one repository, both counting demand and
  # both draining hosts.
  grep -q 'resource "google_compute_instance" "controller"' "$m/main.tf" &&
    r=yes || r=no
  check "$n: the standalone controller instance is gone, not duplicated" no "$r"

  # THE INVARIANT. A surge to two during a rolling replace is two controllers
  # serving one repository, each acting on a GitHub view the other is already
  # changing — briefly, on every apply that touches the startup script, which
  # is most of them.
  grep -A8 'resource "google_compute_instance_group_manager" "controller"' "$m/main.tf" |
    grep -q 'max_surge_fixed *= *0' && r=yes || r=no
  if [ "$r" = no ]; then
    # The block is longer than 8 lines in one module; widen rather than assume.
    sed -n '/resource "google_compute_instance_group_manager" "controller"/,/^}/p' "$m/main.tf" |
      grep -q 'max_surge_fixed *= *0' && r=yes || r=no
  fi
  check "$n: the group never surges to two controllers" yes "$r"

  # Autohealing grants a health probe the authority to DELETE the control
  # plane. A probe that cannot land — ranges not open to the tag, a central
  # firewall, the wrong port — then loops delete/rebuild/delete, which is worse
  # than the pet this replaced. Opt-in, and this asserts the default rather
  # than trusting a reviewer to notice a flipped bool.
  d=$(sed -n '/^variable "controller_autohealing"/,/^}/p' "$m/variables.tf" |
    grep -oE 'default *= *(true|false)' | grep -oE '(true|false)')
  check "$n: autohealing is off by default" false "$d"
done

# The port reaches the VM as an EMPTY STRING when autohealing is off, and the
# startup script has no default for it. A default there would open a listening
# socket on every controller in the fleet — the one machine holding the App
# installation token — to answer a probe nobody configured.
grep -q 'ci-health-port" = var.controller_autohealing ? tostring(var.controller_health_port) : ""' \
  "$POOL_TF/main.tf" && r=yes || r=no
check "the health port is empty unless autohealing asked for it" yes "$r"

sed -n '/^HEALTH_PORT=/,/^esac$/p' "$POOL_TF/scripts/controller-startup.sh" |
  grep -q 'HEALTH_PORT:=' && r=yes || r=no
check "the startup script never defaults the health port" no "$r"

# --- 7. the three couplings the probe path holds by literal, not by variable ---
#
# Enabling autohealing joins four files that never reference each other, and
# every one of these mismatches produces the SAME symptom: the probe does not
# answer, the group calls a healthy controller dead, and deletes it on a loop.
# None of them fails an apply and none of them is visible in a plan.

STARTUP="$POOL_TF/scripts/controller-startup.sh"
NET_TF="$ROOT/modules/ci-runner-network/main.tf"

# (a) The firewall opens a tag; the templates must carry that tag. The network
# module cannot reference either controller module — it is applied once per
# project, they are applied per pool — so the tag is a literal on both sides.
net_tag=$(sed -n '/resource "google_compute_firewall" "health_check"/,/^}/p' "$NET_TF" |
  grep -o '"ci-runner-[a-z-]*"' | tr -d '"' | grep -v '^ci-runner-host$' | head -1)
check "the health-check firewall opens the controller tag" "ci-runner-controller" "$net_tag"

for m in "$POOL_TF" "$CTRL_TF"; do
  n=$(basename "$m")
  sed -n '/resource "google_compute_instance_template" "controller"/,/^}/p' "$m/main.tf" |
    grep -q "\"$net_tag\"" && r=yes || r=no
  check "$n: the controller template carries the tag that firewall opens" yes "$r"
done

# (b) The responder's unit bind-mounts the heartbeat by ABSOLUTE path, inside a
# single-quoted heredoc that expands nothing. A change to STATE_DIR would move
# the file and leave the mount pointing at a path that no longer exists — and
# an absent bind source makes systemd refuse to start the unit, so this one at
# least fails loudly rather than answering 503.
state_dir=$(grep -m1 '^STATE_DIR=' "$STARTUP" | cut -d'"' -f2)
grep -q "^BindReadOnlyPaths=$state_dir/heartbeat\$" "$STARTUP" && r=yes || r=no
check "the responder binds the heartbeat from STATE_DIR, not from a stale path" yes "$r"

# And the tmpfs it is bound back into must be an ANCESTOR of that path, or the
# mount does nothing and the responder still sees the whole state directory —
# including api.body, which is the reason the tmpfs is there.
tmpfs=$(grep -m1 '^TemporaryFileSystem=' "$STARTUP" | cut -d= -f2 | cut -d: -f1)
case "$state_dir/" in
  "$tmpfs"/*) r=yes ;;
  *) r=no ;;
esac
check "the tmpfs covers the state directory it is meant to hide" yes "$r"

# (c) The bind source must EXIST when the unit starts. Absent, systemd refuses
# the unit; present-but-created-later never appears inside the namespace,
# because the responder does not exit and so is never restarted into a new one.
r=$(awk '/touch "\$STATE_DIR\/heartbeat"/ { t = NR }
         /^BindReadOnlyPaths=/ { b = NR }
         END { print (t > 0 && b > 0 && t < b) ? "yes" : "no" }' "$STARTUP")
check "the heartbeat is created before the unit that bind-mounts it" yes "$r"

# --- the controller boot script still fits in a metadata value ----------------
#
# 2026-08-24: the HOST script outgrew the 256 KiB cap on a GCE metadata value.
# `terraform plan` reads clean — the length is only checked by the API — so the
# first sign was an Error 413 at create time inside an unattended nightly apply,
# and three pools sat for a day on a template whose boot script was already
# known broken and already fixed. Gzipping the host's script moved the identical
# error one resource down onto the CONTROLLER's template, which is this one:
# fourteen files concatenated, about 305 KiB.
#
# Both are wrapped now, and both are asserted at plan time. This gate is the
# cheaper half — it fails on the pull request that adds the fourteenth script,
# not on a machine at 04:00. Budget 240 KiB against the 256 KiB cap, because
# Terraform's base64gzip is Go's gzip at its default level while this measures
# the runner's gzip: a compression-level difference must not be what decides
# whether a fleet's control plane can be created.
_cap=262144
_margin=245760
_files=""
while read -r f; do
  [ -n "$f" ] || continue
  _files="$_files $POOL_TF/scripts/$f"
done <<EOF
$pool_list
EOF
# shellcheck disable=SC2086
_gz=$(cat $_files | gzip | base64 -w0 | wc -c)
check "the gzipped controller boot script fits in a metadata value (${_gz} < ${_margin}, cap ${_cap})" \
  yes "$([ "$_gz" -lt "$_margin" ] && echo yes || echo no)"

# --- and it travels as many lines, not one ------------------------------------
#
# Fitting is not sufficient, and this is the failure that cost more than the 413
# did. A metadata value carrying ONE line of six figures is accepted when the
# instance template is created — plan green, apply green — and then every
# `instances.insert` from that template fails after hanging about two minutes,
# with `Internal error` or `The service is currently unavailable` and no mention
# of metadata, a script, or a line.
#
# Measured 2026-08-26 against a live controller template in the fleet's region:
# five creates, five failures; the same template cloned with the base64 body
# folded to 76 columns booted first try and reached the controller's own code. A
# 174 KiB PLAIN-TEXT startup-script in a template creates fine, so neither the
# size nor the template is what GCE chokes on. Three controller MIGs sat at
# `creating: 1` for days over this, which is three pools stuck at zero hosts and
# two repositories with no runners at all. See #434.
_fold='join("\n", regexall(".{1,${local.b64_fold_columns}}", base64gzip(local.controller_startup_source)))'
check "the controller blob is folded, not one enormous line" \
  yes "$(grep -qF "$_fold" "$POOL_TF/main.tf" && echo yes || echo no)"
check "the plan refuses a controller boot script with a long line" \
  yes "$(grep -qF 'for line in split("\n", local.controller_startup) : line if length(line) > 4096' "$POOL_TF/main.tf" && echo yes || echo no)"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
