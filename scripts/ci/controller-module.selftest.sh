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

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
