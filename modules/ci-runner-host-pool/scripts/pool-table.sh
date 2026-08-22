#!/usr/bin/env bash
# ci-runner-host-pool — the controller's POOL TABLE, as a PURE function.
#
# WHY THIS FILE EXISTS
#
# Until now a controller served exactly one pool, and every fact about that pool
# was its own instance metadata: `ci-mig-name`, `ci-slots`, `ci-runner-labels`
# and a dozen more, one key each. A repository that needs four pools — Linux CI,
# Windows CI, Linux merge-queue, Windows merge-queue — therefore needed four
# controllers, and four controllers poll the SAME repository's run list four
# times per tick. At the default 20s poll that is 720 list calls an hour against
# a 5000/hour installation budget, for one answer, and the fourth copy of it is
# the one that runs into the secondary rate limit and blinds all four.
#
# So the controller now reads a TABLE of pools from one metadata key and ticks
# each of them, sweeping GitHub ONCE. This file turns that key into rows.
#
# IT IS A PURE FUNCTION, and that is the point: the table decides which machines
# a controller may delete, and a controller that misreads it either deletes
# hosts belonging to a pool it should not touch or — far more likely and far
# quieter — silently serves three pools out of four. Neither is discoverable
# from a boot log. scripts/ci/pool-table.selftest.sh runs this instead.
#
# A REJECTED ROW IS NOT A FATAL ERROR, AND IS NEVER SILENT. One malformed pool
# must not stop the other three from draining hosts, so a bad row is skipped and
# reported on stderr; the controller logs it and publishes
# ci_pool_table_rejected so a pool that quietly stopped being served is visible
# on a dashboard rather than in nobody's log. A table with NO valid row is a
# controller with nothing to do and is reported by the return code instead.
#
# Tenancy-agnostic — no customer literals, no project/repo knowledge.

# pool_table_parse [<json>]
#
# Reads the pool table as JSON (argument, or stdin when no argument is given)
# and writes one TAB-separated row per VALID pool to stdout, in the order the
# table declares them. Rejected rows go to stderr as `reject:<name>:<reason>`.
#
# The OUTPUT is tab-separated even though the internal split below is not: every
# column of a row that survives validation is non-empty, so the collapsing that
# forces US on the input side cannot bite a reader of the output.
#
# Columns, in this fixed order — the reader in controller-startup.sh splits on
# them positionally, so a column may be appended and never inserted:
#
#    1 name                     pool name; also the metric label and the
#                               instance-template/MIG name prefix
#    2 mig                      regional MIG this pool's hosts live in
#    3 region                   region of that MIG
#    4 slots                    runner agents per host
#    5 min_hosts                warm floor
#    6 max_hosts                ceiling, for the saturation ratio
#    7 drain_grace_seconds      idle before a host may be drained
#    8 register_grace_seconds   how long `absent` still means "booting"
#    9 orphan_confirm_ticks     ticks an offline agent must have no instance
#   10 recycle_max_unavailable  hosts that may be mid-recycle at once
#   11 host_os                  linux | windows
#   12 mints_registration_token true | false
#   13 role                     ci | merge-queue
#   14 beacon_interval          seconds between a Windows host's beacon writes
#   15 pin_orphan_grace_seconds how long a pinned job may wait for its host
#   16 runner_labels            comma-separated, exactly what the agents register
#
# Echoes rows and returns 0 when at least one row is valid; returns 1 when the
# document cannot be parsed at all or yields no valid row.
pool_table_parse() {
  local doc="${1:-}"
  [ -n "$doc" ] || doc=$(cat)

  # A single jq pass emits every row with defaults already applied, so the shell
  # below validates rather than parses. `@tsv` escapes any tab, newline or
  # carriage return INSIDE a value, which is what keeps a hand-edited label list
  # from shifting every later column.
  #
  # Then every separator is translated to US (0x1f) — because `read` still
  # treats a tab as IFS WHITESPACE even when IFS is set to exactly a tab, and so
  # collapses runs of them. Two adjacent empty fields would silently become one
  # and every later column would shift left: a pool with no name and no mig
  # would parse as a pool named after its region. US is not IFS whitespace, so
  # an empty field stays an empty field. A raw US byte arriving inside a value
  # would defeat that, so it is replaced before the split rather than trusted.
  #
  # `.[]?` and not `.[]`: a table that is an object rather than an array, or is
  # empty, must reach the "no valid row" return below rather than making jq
  # itself fail with a message no operator will see.
  local rows
  rows=$(printf '%s' "$doc" | jq -r '
    .[]? | [
      (.name // ""),
      (.mig // ""),
      (.region // ""),
      (.slots // 1),
      (.min_hosts // 0),
      (.max_hosts // 0),
      (.drain_grace_seconds // 900),
      (.register_grace_seconds // 600),
      (.orphan_confirm_ticks // 3),
      (.recycle_max_unavailable // 0),
      (.host_os // "linux"),
      # Compared, not tested for truthiness: in jq the STRING "false" is true,
      # and a hand-written or loosely templated table is exactly where that
      # string arrives — silently arming a Linux pool to mint GitHub tokens.
      (if (.mints_registration_token == true or .mints_registration_token == "true")
       then "true" else "false" end),
      (.role // "ci"),
      (.beacon_interval // 30),
      (.pin_orphan_grace_seconds // 900),
      (.runner_labels // "")
    ] | @tsv | gsub("\u001f"; " ")' 2>/dev/null | tr '\t' '\037') || {
    echo "reject::the pool table is not valid JSON" >&2
    return 1
  }

  local name mig region slots minh maxh grace reg_grace ticks recycle
  local host_os mint role beacon pin labels
  local kept=0 why
  while IFS=$'\037' read -r name mig region slots minh maxh grace reg_grace \
    ticks recycle host_os mint role beacon pin labels; do
    [ -n "${name:-}" ] || continue

    # First reason wins, and every test is guarded on the ones before it, so a
    # row missing three fields is reported once rather than three times — an
    # operator reading a boot log should get one line per broken pool.
    why=""

    # The two that address real infrastructure. A row missing either names no
    # machines, and every later call would be made against an empty string —
    # which for `gcloud compute instance-groups managed list-instances` is not
    # an error, it is a different command.
    [ -z "$why" ] && [ -z "${mig:-}" ] && why="no mig"
    [ -z "$why" ] && [ -z "${region:-}" ] && why="no region"

    # An empty label set matches NOTHING under GitHub's superset rule: every
    # queued job is discarded as "not mine", the pool reports zero demand on
    # every tick and never leaves zero hosts, while looking perfectly healthy.
    # This was a hard exit when a controller served one pool; with a table it
    # has to be a per-row refusal, or one bad pool takes the other three down.
    [ -z "$why" ] && [ -z "${labels:-}" ] && why="no runner_labels"

    if [ -z "$why" ]; then
      case "${host_os:-}" in
        linux | windows) ;;
        *) why="host_os '${host_os:-}' is neither linux nor windows" ;;
      esac
    fi

    if [ -z "$why" ]; then
      case "${role:-}" in
        ci | merge-queue) ;;
        *) why="role '${role:-}' is neither ci nor merge-queue" ;;
      esac
    fi

    # Every numeric column is fed to `[ … -gt … ]` somewhere in the tick, and
    # under the controller's flags a non-numeric operand there is not a wrong
    # answer, it is `integer expression expected` and a dead tick. Checked as a
    # group because the failure is identical whichever one is malformed.
    if [ -z "$why" ]; then
      local n
      for n in "$slots" "$minh" "$maxh" "$grace" "$reg_grace" "$ticks" \
        "$recycle" "$beacon" "$pin"; do
        case "${n:-}" in
          '' | *[!0-9]*) why="a numeric field is not a number ('${n:-}')"; break ;;
        esac
      done
    fi

    # Zero slots is arithmetically valid and operationally absurd: the
    # autoscaler divides demand by it (`single_instance_assignment`), and every
    # host reads `present` at zero registered agents, so nothing ever drains.
    if [ -z "$why" ] && [ "${slots:-0}" -lt 1 ]; then
      why="slots must be at least 1"
    fi

    if [ -n "$why" ]; then
      echo "reject:$name:$why" >&2
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$mig" "$region" "$slots" "$minh" "$maxh" "$grace" "$reg_grace" \
      "$ticks" "$recycle" "$host_os" "$mint" "$role" "$beacon" "$pin" "$labels"
    kept=$((kept + 1))
  done <<POOL_TABLE_EOF
$rows
POOL_TABLE_EOF

  [ "$kept" -gt 0 ] || return 1
  return 0
}
