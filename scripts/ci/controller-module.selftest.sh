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
pool_list=$(sed -n '/controller_startup = join(/,/^  ])$/p' "$POOL_TF/main.tf" |
  grep -o 'scripts/[a-z-]*\.sh' | sed 's|scripts/||')
ctrl_list=$(sed -n '/controller_startup = join(/,/^  ])$/p' "$CTRL_TF/main.tf" |
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

# --- 8. the stall rule's caller must preserve "unknown", not flatten it -------
#
# infra_dequeue draws its second line at a CANCELLED job that completed zero
# steps, and it distinguishes "" (the caller could not tell) from "0" (it ran
# nothing) because only the second earns a requeue. That distinction is made in
# the rule, which the decision self-test covers — but it is DESTROYED or kept in
# the jq that feeds it, which lives in the startup script and no pure-function
# test can reach.
#
# The failure it guards is quiet in the worst way: the jobs API omits `.steps`
# entirely when it holds no step data, `.steps[]?` turns that absence into a
# length of 0, and the rule then reads a job it knows nothing about as the exact
# signature it retries on. Nothing errors; a cancelled-by-a-newer-commit job
# gets requeued and burns a queue CI run.
#
# So the program is extracted from the script rather than restated here — a
# second copy would pass while the real one drifted — and run against the two
# payloads that differ only in the field.
# shellcheck disable=SC2016  # a sed address matching shell source text, on
# purpose: the `$(` is the script's own characters, not an expansion of ours.
sig_jq=$(sed -n '/sig=$(printf .* | jq -r ./,/@tsv/p' "$STARTUP" |
  sed '1s/.*jq -r .//; $s/.*/  | .[] | [ .c, (.e | tostring), (.s | tostring) ] | @tsv/')
[ -n "$sig_jq" ] && r=yes || r=no
check "the stall signature program was found in the startup script" yes "$r"

sig_of() { # <steps-field-json>
  printf '{"jobs":[{"status":"completed","conclusion":"cancelled","started_at":"2026-08-23T10:00:00Z","completed_at":"2026-08-23T10:15:00Z"%s}]}' "$1" |
    jq -r "$sig_jq" 2>/dev/null | cut -f3
}

# Absent — GitHub told us nothing about the steps. Must stay empty.
check "a job with no steps field reports an UNKNOWN step count" "" "$(sig_of '')"

# Present and null. Same thing, and jq treats the two identically only if the
# guard tests for null rather than for the key.
check "a job with a null steps field reports an UNKNOWN step count" "" "$(sig_of ',"steps":null')"

# Present and empty — the job recorded steps and completed none. A real zero,
# and the case the whole rule exists for: a slot that took the job and died.
check "a job with an empty steps array reports ZERO" "0" "$(sig_of ',"steps":[]')"

# And a job that got somewhere still counts what it got through, so the arm
# above cannot fire on it.
check "a job that completed a step reports that count" "1" \
  "$(sig_of ',"steps":[{"status":"completed"},{"status":"in_progress"}]')"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
