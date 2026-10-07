#!/usr/bin/env bash
# Self-test for the machinery that lets ONE controller VM serve MANY repositories
# (#1486): one OS process per repository, each the same loop the single-
# repository controller runs, each with its own state directory.
#
# What only goes wrong once a second repository exists:
#
#   1. Two repositories under ONE slug share drain counters and delete each
#      other's markers. The slug function, its collisions and the refusal of the
#      whole table are executed here, on the VM's side and on Terraform's.
#   2. A repository's process reads SOMEBODY ELSE'S settings. Environment first,
#      then metadata — executed against a stub `md`, both ways round.
#   3. BOTH shapes on one machine: the single-repository unit and a templated
#      unit serving one repository, each draining the other's hosts. The real
#      activation functions are run against a recording `systemctl`.
#   4. One wedged repository hidden behind two healthy ones. The real watchdog
#      and the real liveness responder are rendered and run.
#
# …and the compatibility half: with no table, nothing above exists. The state
# directory, the log and the unit are the ones the fleet already has.
#
# Functions are EXTRACTED FROM THE SHIPPED SCRIPT and run, never re-typed, and
# every extraction is checked for being non-empty first: an empty subject runs,
# exits 0 and passes every assertion written against it.
#
#   bash scripts/ci/multi-repo.selftest.sh          the shell half (no terraform)
#   bash scripts/ci/multi-repo.selftest.sh --plan   the Terraform half: applies
#                                                   the provider-less
#                                                   repos-table module offline
#
# Tenancy-agnostic — no customer literals.

# Three findings that are this file's method rather than its mistakes: the
# variables and stub functions below are read by code that is extracted from
# the shipped script and eval'd, which no static reader can follow (SC2034,
# SC2317), and the single-quoted text is shell written out for another process
# or matched literally (SC2016).
# shellcheck disable=SC2034,SC2317,SC2016

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTRL="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"
MODDIR="$ROOT/modules/ci-runner-controller"

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

# has <haystack> <needle> — yes/no. Not `printf | grep -q`: under pipefail a
# grep that exits at its first match can kill the writer and fail a true match.
has() {
  case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac
}

# fn <name> — the named function's text from the shipped script.
fn() {
  sed -n "/^$1() {/,/^}/p" "$CTRL"
}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# A path the platform's own tools (python, terraform) can open as given.
TN=$(cygpath -m "$T" 2>/dev/null || echo "$T")

for f in repo_slug repos_table_rows repo_slugs_to_retire repo_rows_install \
  repo_units_write repo_units_activate repo_units_retire_all livez_script; do
  if [ -z "$(fn "$f")" ]; then
    echo "FAIL $f() not found in controller-startup.sh — every assertion on it would be vacuous"
    exit 1
  fi
done

pool() { # <name> <labels> [role]
  printf '{"name":"%s","mig":"%s-mig","region":"r1","runner_labels":"%s","role":"%s"}' "$1" "$1" "$2" "${3:-ci}"
}
row() { # <owner> <repo> <pools json> [extra json members]
  printf '{"github_owner":"%s","github_repo":"%s","pools":[%s]%s}' "$1" "$2" "$3" "${4:-}"
}

THREE="[$(row Acme App "$(pool app-linux gcp,app)" ',"github_app_id":"11","github_app_installation_id":"22","github_app_private_key_secret":"key-a","queue_base_branch":"main"'),$(row acme tools "$(pool tools-linux gcp,tools)" ',"queue_base_branch":"master"'),$(row other svc "$(pool svc-linux gcp,svc),$(pool svc-queue gcp,queue merge-queue)")]"
ONE="[$(row acme solo "$(pool solo-linux gcp,solo)")]"
COLLIDE="[$(row a-b c "$(pool p1 gcp,a)"),$(row a b-c "$(pool p2 gcp,b)")]"

if [ "${1:-}" != "--plan" ]; then

  # --- 1. the slug -----------------------------------------------------------
  eval "$(fn repo_slug)"
  check "slug: owner and repo joined, lower-cased" "acme-app" "$(repo_slug Acme App)"
  check "slug: a character outside the unit-safe set becomes a dash" "acme-my-repo" "$(repo_slug acme 'my repo')"
  check "slug: dot and underscore survive" "acme-a.b_c" "$(repo_slug acme a.b_c)"
  check "slug: two different repositories CAN collide — the function does not hide it" "$(repo_slug a-b c)" "$(repo_slug a b-c)"
  check "slug: an owner that would start the unit name with a dot is refused" "refused" "$(repo_slug .hidden x >/dev/null && echo made || echo refused)"
  check "slug: an empty repo is refused" "refused" "$(repo_slug acme '' >/dev/null && echo made || echo refused)"

  # --- 2. the table parser ---------------------------------------------------
  eval "$(fn repos_table_rows)"
  rows3=$(printf '%s' "$THREE" | repos_table_rows 2>/dev/null)
  check "table: three rows in, three rows out" "3" "$(printf '%s' "$rows3" | grep -c .)"
  check "table: a row carries its own App id, installation, key and base" "0|acme-app|Acme|App|11|22|key-a|main" "$(printf '%s\n' "$rows3" | sed -n 1p)"
  check "table: an omitted App id stays an EMPTY column, later columns do not slide" "1|acme-tools|acme|tools||||master" "$(printf '%s\n' "$rows3" | sed -n 2p)"
  check "table: a slug collision refuses the WHOLE table (exit 2)" "2" "$(printf '%s' "$COLLIDE" | repos_table_rows >/dev/null 2>&1; echo $?)"
  check "table: a refused table prints no row at all" "" "$(printf '%s' "$COLLIDE" | repos_table_rows 2>/dev/null)"
  check "table: the refusal names the slug" "yes" "$(has "$(printf '%s' "$COLLIDE" | repos_table_rows 2>&1 >/dev/null)" "slug 'a-b-c'")"
  unsafe="[$(row acme bad "$(pool b gcp,b)" ',"github_app_private_key_secret":"two words"'),$(row acme good "$(pool g gcp,g)")]"
  check "table: a value an environment file would cut short rejects its row, the rest are served" "1|acme-good|acme|good||||" "$(printf '%s' "$unsafe" | repos_table_rows 2>/dev/null)"
  check "table: the rejected row is named" "yes" "$(has "$(printf '%s' "$unsafe" | repos_table_rows 2>&1 >/dev/null)" "ci-repos row 0")"
  check "table: something that is not a table is an error, not zero rows" "1" "$(printf '{"a":1}' | repos_table_rows >/dev/null 2>&1; echo $?)"

  # --- 3. which units a changed table retires --------------------------------
  eval "$(fn repo_slugs_to_retire)"
  check "retire: a slug present and no longer wanted" "gone" "$(repo_slugs_to_retire $'a\nb' $'a\ngone\nb')"
  check "retire: nothing when the table did not shrink" "" "$(repo_slugs_to_retire $'a\nb' $'b\na')"
  check "retire: a slug that is a PREFIX of a wanted one is still retired" "acme-app" "$(repo_slugs_to_retire 'acme-app-2' $'acme-app\nacme-app-2')"

  # --- 4. the installer's files, for 1 row and for 3 -------------------------
  eval "$(fn repo_rows_install)"
  eval "$(fn repo_units_write)"
  install_into() { # <dir> <json>
    UNIT_DIR="$1/units" REPOS_ETC="$1/etc" STATE_ROOT="$1/state" SELF_INSTALL=/opt/ci-controller/controller.sh
    mkdir -p "$UNIT_DIR" "$STATE_ROOT"
    repo_rows_install "$2"
  }
  slugs1=$(install_into "$T/one" "$ONE" 2>/dev/null)
  check "install(1 row): one slug served" "acme-solo" "$slugs1"
  check "install(1 row): one environment file" "1" "$(find "$T/one/etc" -name '*.env' | grep -c .)"
  slugs3=$(install_into "$T/three" "$THREE" 2>/dev/null)
  check "install(3 rows): three slugs, in table order" "acme-app acme-tools other-svc" "$(printf '%s' "$slugs3" | tr '\n' ' ' | sed 's/ $//')"
  check "install(3 rows): three environment files" "3" "$(find "$T/three/etc" -name '*.env' | grep -c .)"
  check "install(3 rows): three state directories" "3" "$(find "$T/three/state" -mindepth 1 -maxdepth 1 -type d | grep -c .)"
  check "install: the environment file names the row's repository" "CI_GITHUB_OWNER=Acme CI_GITHUB_REPO=App" "$(grep -E '^CI_GITHUB_(OWNER|REPO)=' "$T/three/etc/acme-app.env" | tr '\n' ' ' | sed 's/ $//')"
  check "install: the row's own base branch, not the neighbour's" "CI_QUEUE_BASE=master" "$(grep '^CI_QUEUE_BASE=' "$T/three/etc/acme-tools.env")"
  check "install: the pools file holds THAT row's pools only" "svc-linux,svc-queue" "$(jq -r 'map(.name) | join(",")' "$T/three/etc/other-svc.pools.json")"
  check "install: the environment file points at the row's own pools file" "CI_POOLS_FILE=$T/three/etc/other-svc.pools.json" "$(grep '^CI_POOLS_FILE=' "$T/three/etc/other-svc.env")"
  install_into "$T/collide" "$COLLIDE" >/dev/null 2>&1
  check "install: a refused table writes no file a unit could start from" "0" "$(find "$T/collide" -type f | grep -c .)"

  (
    UNIT_DIR="$T/three/units" REPOS_ETC=/etc/ci-controller SELF_INSTALL=/opt/ci-controller/controller.sh
    repo_units_write
  )
  check "units: three templates, whatever the row count" "ci-controller-watchdog@.service ci-controller-watchdog@.timer ci-controller@.service" "$(find "$T/three/units" -type f -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')"
  check "units: the instance name reaches the process as its slug" "Environment=CI_REPO_SLUG=%i" "$(grep '^Environment=' "$T/three/units/ci-controller@.service")"
  check "units: each instance loads its own row" "EnvironmentFile=/etc/ci-controller/%i.env" "$(grep '^EnvironmentFile=' "$T/three/units/ci-controller@.service")"
  check "units: the instance runs the same loop the single-repository unit runs" "ExecStart=/opt/ci-controller/controller.sh --loop" "$(grep '^ExecStart=' "$T/three/units/ci-controller@.service")"
  check "units: the watchdog is told WHICH repository to watch" "ExecStart=/opt/ci-controller/watchdog.sh %i" "$(grep '^ExecStart=' "$T/three/units/ci-controller-watchdog@.service")"

  # --- 5. activation: exactly the table, never both shapes -------------------
  eval "$(fn repo_units_activate)"
  eval "$(fn repo_units_retire_all)"
  activate() { # <dir> <slugs> -> the systemctl calls, one per line
    : >"$1/calls"
    (
      UNIT_DIR="$1/units" REPOS_ETC="$1/etc" CALLS="$1/calls"
      systemctl() { echo "$*" >>"$CALLS"; }
      repo_units_activate "$2" >/dev/null 2>&1
    )
    cat "$1/calls"
  }
  touch "$T/three/units/ci-controller.service" "$T/three/etc/left-over.env" "$T/three/etc/left-over.pools.json"
  calls3=$(activate "$T/three" "$slugs3")
  check "activate(3 rows): three controller instances restarted" "3" "$(printf '%s\n' "$calls3" | grep -c '^restart ci-controller@')"
  check "activate: restarted, not merely enabled — each repository by name" "restart ci-controller@acme-tools.service" "$(printf '%s\n' "$calls3" | grep -x 'restart ci-controller@acme-tools.service')"
  check "activate: each repository's watchdog timer restarted" "3" "$(printf '%s\n' "$calls3" | grep -c '^restart ci-controller-watchdog@.*\.timer$')"
  check "activate: the single-repository unit is stopped FIRST" "disable --now ci-controller.service ci-controller-watchdog.timer" "$(printf '%s\n' "$calls3" | sed -n 1p)"
  check "activate: the single-repository unit file is gone" "gone" "$([ -e "$T/three/units/ci-controller.service" ] && echo present || echo gone)"
  check "activate: a row the table dropped is disabled" "disable --now ci-controller@left-over.service ci-controller-watchdog@left-over.timer" "$(printf '%s\n' "$calls3" | grep 'left-over')"
  check "activate: and its environment file is removed" "gone" "$([ -e "$T/three/etc/left-over.env" ] && echo present || echo gone)"
  check "activate: a row still in the table keeps its file" "present" "$([ -e "$T/three/etc/acme-app.env" ] && echo present || echo gone)"
  last_disable=$(printf '%s\n' "$calls3" | grep -n '^disable' | tail -n 1 | cut -d: -f1)
  first_restart=$(printf '%s\n' "$calls3" | grep -n '^restart' | sed -n 1p | cut -d: -f1)
  check "activate: every stop comes before the first start" "yes" "$([ "${last_disable:-99}" -lt "${first_restart:-0}" ] && echo yes || echo no)"
  check "activate(1 row): exactly one controller instance" "1" "$(activate "$T/one" "$slugs1" | grep -c '^restart ci-controller@')"

  retire_all() { # <dir> -> the systemctl calls
    : >"$1/calls"
    (
      UNIT_DIR="$1/units" REPOS_ETC="$1/etc" CALLS="$1/calls"
      systemctl() { echo "$*" >>"$CALLS"; }
      repo_units_retire_all >/dev/null 2>&1
    )
    cat "$1/calls"
  }
  check "legacy install: every unit of a table it once carried is disabled" "3" "$(retire_all "$T/three" | grep -c '^disable --now ci-controller@')"
  check "legacy install: the templates and the rows are gone" "0" "$(find "$T/three/units" "$T/three/etc" -type f 2>/dev/null | grep -c .)"
  mkdir -p "$T/never/units"
  check "legacy install: a controller that never had a table calls systemctl for nothing" "" "$(retire_all "$T/never")"

  # --- 6. the process: its state directory, and the shape it is in -----------
  state_block=$(sed -n '/^STATE_ROOT="\$STATE_DIR"$/,/^fi$/p' "$CTRL")
  shape_block=$(sed -n '/^REPOS_RAW=\$(md /,/^fi$/p' "$CTRL")
  settings=$(grep -E '^(OWNER|REPO|APP_ID|INSTALL_ID|KEY_SECRET|QUEUE_BASE)=' "$CTRL")
  pools_block=$(sed -n '/^POOLS_JSON=""$/,/^fi$/p' "$CTRL")
  check "extracted: the state-directory block is not empty" "yes" "$([ -n "$state_block" ] && echo yes || echo no)"
  check "extracted: the shape block is not empty" "yes" "$([ -n "$shape_block" ] && echo yes || echo no)"
  check "extracted: all six repository settings" "6" "$(printf '%s\n' "$settings" | grep -c .)"
  check "extracted: the pool-table block is not empty" "yes" "$([ -n "$pools_block" ] && echo yes || echo no)"

  state_of() { # <slug or empty> -> "<state dir> <log>"
    (
      STATE_DIR=/var/lib/ci-controller LOG=/var/log/ci-controller.log
      if [ -n "$1" ]; then CI_REPO_SLUG="$1"; else unset CI_REPO_SLUG; fi
      eval "$state_block" 2>/dev/null
      echo "$STATE_DIR $LOG"
    )
  }
  check "legacy: no slug keeps the state directory and the log it always had" "/var/lib/ci-controller /var/log/ci-controller.log" "$(state_of '')"
  check "repository process: its own state directory and its own log" "/var/lib/ci-controller/acme-app /var/log/ci-controller-acme-app.log" "$(state_of acme-app)"
  check "repository process: a slug that would leave the state directory is refused" "" "$(state_of '../etc')"
  check "repository process: a slug with a slash is refused" "" "$(state_of 'a/b')"

  PACKED=$(printf '%s' "$THREE" | gzip -c | base64 | tr -d '\r')
  shape_of() { # <ci-repos metadata> <slug or empty> -> "<installer flag> <rows>" or "exit"
    (
      md() { [ "$1" = "instance/attributes/ci-repos" ] && printf '%s' "$SHAPE_MD"; }
      SHAPE_MD="$1" REPO_SLUG="$2"
      eval "$shape_block" 2>/dev/null
      echo "$REPOS_INSTALLER $(printf '%s' "$REPOS_JSON" | jq -r 'length' 2>/dev/null)"
    )
  }
  check "shape: no table, no slug — the single-repository controller" "0 " "$(shape_of '' '')"
  check "shape: a table and no slug — the installer, which serves nothing itself" "1 3" "$(shape_of "$PACKED" '')"
  check "shape: a table and a slug — one repository's process" "0 3" "$(shape_of "$PACKED" acme-app)"
  check "shape: a slug with NO table exits — a left-over unit must not serve beside the single-repository one" "" "$(shape_of '' acme-app)"
  check "shape: a table that does not unpack exits rather than reading as no table" "" "$(shape_of 'not-a-table' '')"

  settings_of() { # env|metadata -> the six values
    (
      md() { echo "md:${1##*/}"; }
      if [ "$1" = env ]; then
        CI_GITHUB_OWNER=o CI_GITHUB_REPO=r CI_APP_ID=1 CI_APP_INSTALLATION_ID=2 CI_APP_KEY_SECRET=k CI_QUEUE_BASE=b
      else
        unset CI_GITHUB_OWNER CI_GITHUB_REPO CI_APP_ID CI_APP_INSTALLATION_ID CI_APP_KEY_SECRET CI_QUEUE_BASE
      fi
      eval "$settings"
      echo "$OWNER $REPO $APP_ID $INSTALL_ID $KEY_SECRET $QUEUE_BASE"
    )
  }
  check "settings: the environment wins, for every one of them" "o r 1 2 k b" "$(settings_of env)"
  check "settings: with no environment, exactly the metadata keys it always read" "md:ci-github-owner md:ci-github-repo md:ci-app-id md:ci-app-installation-id md:ci-app-key-secret md:ci-queue-base" "$(settings_of metadata)"

  pools_of() { # <pools file or empty> <installer flag> -> pool names
    (
      md() {
        case "$1" in
          instance/attributes/ci-pool) echo legacy-pool ;;
          instance/attributes/ci-mig-name) echo legacy-mig ;;
          *) echo "" ;;
        esac
      }
      if [ -n "$1" ]; then CI_POOLS_FILE="$1"; else unset CI_POOLS_FILE; fi
      REPOS_INSTALLER="$2"
      eval "$pools_block"
      printf '%s' "$POOLS_JSON" | jq -r '[length, (map(.name) | join(","))] | join(" ")'
    )
  }
  check "legacy synthesis: exactly ONE row, from the single-pool keys" "1 legacy-pool" "$(pools_of '' 0)"
  printf '%s' "$THREE" | jq -c '.[2].pools' >"$T/p.json"
  check "repository process: its pools come from its own file" "2 svc-linux,svc-queue" "$(pools_of "$T/p.json" 0)"
  check "installer of a table: no pools of its own, and none synthesised" "0 " "$(pools_of '' 1)"

  check "dispatch: the single-repository unit on a table controller refuses to loop" "yes" "$(has "$(sed -n '/^case "\${1:-}" in$/,/^esac$/p' "$CTRL" | sed -n '/--loop)/,/run_loop/p')" 'if [ "$REPOS_INSTALLER" = 1 ]; then')"

  # --- 7. the watchdog restarts ONE repository, and says which ---------------
  wd_body=$(sed -n '/^    cat <<WDEOF$/,/^WDEOF$/p' "$CTRL" | sed '1d;$d')
  check "extracted: the watchdog body is not empty" "yes" "$([ -n "$wd_body" ] && echo yes || echo no)"
  mkdir -p "$T/wd/alpha" "$T/wd/beta"
  touch "$T/wd/heartbeat" "$T/wd/alpha/heartbeat"
  touch -d '2 hours ago' "$T/wd/beta/heartbeat"
  {
    echo 'watchdog_verdict() { if [ "$1" = 1 ] && [ "$2" -ge "$4" ]; then echo restart; else echo ok; fi; }'
    echo 'systemctl() { [ "$1" = show ] || echo "systemctl $*" >>"$CALLS"; }'
    echo 'logger() { echo "logger $*" >>"$CALLS"; }'
    # shellcheck disable=SC2034  # read by the heredoc the eval renders
    STATE_DIR="$T/wd" STATE_ROOT="$T/wd" wd_threshold=300
    eval "cat <<WDRENDER"$'\n'"$wd_body"$'\n'"WDRENDER"
  } >"$T/wd.sh"
  watchdog() { # [slug] -> what it did
    : >"$T/wd.calls"
    CALLS="$T/wd.calls" bash "$T/wd.sh" "$@" >/dev/null 2>&1
    cat "$T/wd.calls"
  }
  check "watchdog: a wedged repository is restarted alone" "systemctl restart ci-controller@beta.service" "$(watchdog beta | grep '^systemctl')"
  check "watchdog: and the log line names its unit" "yes" "$(has "$(watchdog beta | grep '^logger')" 'restarting ci-controller@beta.service')"
  check "watchdog: a healthy repository beside it is left alone" "" "$(watchdog alpha)"
  check "watchdog: with no argument it reads the single-repository heartbeat (fresh)" "" "$(watchdog)"
  touch -d '2 hours ago' "$T/wd/heartbeat"
  check "watchdog: and restarts the single-repository unit under its old name" "systemctl restart ci-controller.service" "$(watchdog | grep '^systemctl')"

  # --- 8. health: unhealthy if ANY repository is wedged, and it says which ----
  eval "$(fn livez_script)"
  PY=$(command -v python3 || command -v python || true)
  if [ -z "$PY" ]; then
    echo "FAIL python3 is not installed — the liveness responder cannot be run, and it is the one thing allowed to delete the controller"
    fail=$((fail + 1))
  else
    mkdir -p "$T/hz/alpha" "$T/hz/beta" "$T/hz/gamma" "$T/py-multi" "$T/py-legacy"
    touch "$T/hz/alpha/heartbeat" "$T/hz/beta/heartbeat" "$T/hz/gamma/heartbeat" "$T/hz/heartbeat"
    livez_script "(\"alpha\", \"$TN/hz/alpha/heartbeat\"), (\"beta\", \"$TN/hz/beta/heartbeat\"), (\"gamma\", \"$TN/hz/gamma/heartbeat\"), " 900 0 >"$T/py-multi/livez.py"
    livez_script "(\"\", \"$TN/hz/heartbeat\")" 900 0 >"$T/py-legacy/livez.py"
    verdict() { # <dir> -> "<ok> <names> <body after the age>"
      "$PY" -c 'import sys; sys.path.insert(0, sys.argv[1]); import livez; ok, body, named = livez.verdict(); print(int(ok), ",".join(named) or "-", body.split(" ", 1)[1])' "$TN/$1" 2>&1 | tr -d '\r'
    }
    check "health: every repository fresh is healthy" "1 - threshold=900" "$(verdict py-multi)"
    touch -d '2 hours ago' "$T/hz/beta/heartbeat"
    check "health: ONE wedged repository makes the machine unhealthy, and is named" "0 beta threshold=900 wedged=beta" "$(verdict py-multi)"
    rm -f "$T/hz/gamma/heartbeat"
    check "health: a repository with no heartbeat at all is wedged too" "0 beta,gamma threshold=900 wedged=beta,gamma" "$(verdict py-multi)"
    check "health(legacy): fresh is healthy, and the answer is the one it always gave" "1 - threshold=900" "$(verdict py-legacy)"
    touch -d '2 hours ago' "$T/hz/heartbeat"
    check "health(legacy): stale is unhealthy with no repository named" "0 - threshold=900" "$(verdict py-legacy)"
  fi

  # --- 9. the Terraform text a plan cannot be run for here -------------------
  #
  # The parent module needs a cloud provider to plan. What can be held without
  # one: the single-repository arm renders the three keys it always rendered
  # and no `ci-repos`, and the table's pools are the same columns as `pools`.
  legacy_arm=$(sed -n '/^  repo_metadata = /,/^  })$/p' "$MODDIR/main.tf" | sed -n '/}) : tomap({/,$p')
  repos_arm=$(sed -n '/^  repo_metadata = /,/^  })$/p' "$MODDIR/main.tf" | sed '/}) : tomap({/,$d')
  check "terraform: the single-repository arm was found" "yes" "$([ -n "$legacy_arm" ] && echo yes || echo no)"
  check "terraform: single-repository metadata has NO ci-repos key" "0" "$(printf '%s\n' "$legacy_arm" | grep -c '"ci-repos"')"
  check "terraform: single-repository metadata keeps its three keys" "ci-github-owner ci-github-repo ci-pools" "$(printf '%s\n' "$legacy_arm" | grep -oE '^    "ci-[a-z-]+"' | tr -d ' "' | tr '\n' ' ' | sed 's/ $//')"
  check "terraform: the table arm renders ci-repos and nothing else" "ci-repos" "$(printf '%s\n' "$repos_arm" | grep -oE '^    "ci-[a-z-]+"' | tr -d ' "' | tr '\n' ' ' | sed 's/ $//')"
  check "terraform: the keys every shape shares do not name a repository" "0" "$(sed -n '/^  metadata = merge(local.repo_metadata, {$/,/^  })$/p' "$MODDIR/main.tf" | grep -cE '"ci-(repos|pools|github-owner|github-repo)"')"
  cols_of() { # <variable name> -> its pool columns, sorted
    sed -n "/^variable \"$1\" {/,/^}/p" "$MODDIR/variables.tf" | grep -oE '^ +[a-z_]+ += (optional\()?(string|number|bool)' | awk '{print $1}' | sort | tr '\n' ' '
  }
  legacy_cols=$(cols_of pools)
  repos_cols=$(sed -n '/^variable "repos" {/,/^}/p' "$MODDIR/variables.tf" | sed -n '/pools = list(object({/,/}))/p' | grep -oE '^ +[a-z_]+ += (optional\()?(string|number|bool)' | awk '{print $1}' | sort | tr '\n' ' ')
  check "terraform: the legacy pools type was read" "yes" "$(has "$legacy_cols" 'runner_labels')"
  check "terraform: a table row's pools have exactly the columns of the single-repository pools" "$legacy_cols" "$repos_cols"

else

  # --- the Terraform half: the provider-less module, applied offline ---------
  command -v terraform >/dev/null 2>&1 || {
    echo "FAIL terraform is not installed — --plan cannot run"
    exit 1
  }
  eval "$(fn repo_slug)"
  eval "$(fn repos_table_rows)"
  export TF_DATA_DIR="$TN/tfdata"
  export TF_IN_AUTOMATION=1
  (cd "$MODDIR/repos-table" && terraform init -input=false -backend=false -no-color >/dev/null 2>&1) || {
    echo "FAIL terraform init of repos-table failed"
    exit 1
  }
  APP='"github_app_id":"1","github_app_installation_id":"2","github_app_private_key_secret":"key"'
  tf() { # <case> <tfvars json> -> apply's output on one line; state kept per case
    printf '%s' "$2" >"$T/$1.tfvars.json"
    (cd "$MODDIR/repos-table" && terraform apply -auto-approve -input=false -no-color -state="$TN/$1.tfstate" -var-file="$TN/$1.tfvars.json" 2>&1) \
      | tr '\n' ' ' | sed 's/│//g' | tr -s ' '
  }
  out() { # <case> <output name>
    (cd "$MODDIR/repos-table" && terraform output -no-color -state="$TN/$1.tfstate" -json "$2" 2>/dev/null) | tr -d '\r'
  }
  LEGACY="{$APP,\"github_owner\":\"acme\",\"github_repo\":\"solo\",\"legacy_pool_count\":1}"

  check "plan: both shapes at once are rejected" "yes" "$(has "$(tf both "{$APP,\"github_owner\":\"acme\",\"github_repo\":\"solo\",\"legacy_pool_count\":1,\"repos\":$ONE}")" 'never both')"
  check "plan: neither shape is rejected" "yes" "$(has "$(tf neither "{$APP}")" 'was given no repository')"
  check "plan: half of the single-repository shape is rejected" "yes" "$(has "$(tf half "{$APP,\"github_owner\":\"acme\",\"legacy_pool_count\":1}")" 'needs all three')"
  dup="[$(row acme one "$(pool shared gcp,one)"),$(row acme two "$(pool shared gcp,two)")]"
  check "plan: one pool name under two repositories is rejected" "yes" "$(has "$(tf dup "{$APP,\"repos\":$dup}")" 'unique across the WHOLE')"
  check "plan: two repositories under one slug are rejected" "yes" "$(has "$(tf collide "{$APP,\"repos\":$COLLIDE}")" 'resolve to the same repository slug')"
  covered="[$(row acme one "$(pool one-ci gcp,one),$(pool one-queue gcp,one merge-queue)")]"
  check "plan: inside ONE repository, a queue pool the CI pool covers is rejected" "yes" "$(has "$(tf covered "{$APP,\"repos\":$covered}")" 'inside one repository')"
  across="[$(row acme one "$(pool one-ci gcp,linux)"),$(row acme two "$(pool two-queue gcp,linux merge-queue),$(pool two-ci gcp,two)")]"
  check "plan: the same labels in TWO repositories are not a collision" "yes" "$(has "$(tf across "{$APP,\"repos\":$across}")" 'Apply complete')"
  check "plan: a value an environment file would cut short is rejected" "yes" "$(has "$(tf unsafe "{$APP,\"repos\":[$(row acme one "$(pool p gcp,p)" ',"github_app_private_key_secret":"two words"')]}")" 'cut the value short')"

  check "plan: the single-repository shape applies" "yes" "$(has "$(tf legacy "$LEGACY")" 'Apply complete')"
  check "plan: single-repository shape is 'legacy'" '"legacy"' "$(out legacy shape)"
  check "plan: and its ci-repos value is EMPTY — the parent renders no key" '""' "$(out legacy metadata_value)"
  check "plan: and it serves no slug" "[]" "$(out legacy slugs)"

  three_out=$(tf three "{$APP,\"repos\":$THREE}")
  check "plan: a three-row table applies" "yes" "$(has "$three_out" 'Apply complete')"
  # Everything below reads that apply's outputs, so say why it failed.
  [ "$(has "$three_out" 'Apply complete')" = yes ] || echo "     terraform said: $three_out"
  check "plan: the table shape is 'repos'" '"repos"' "$(out three shape)"
  check "plan: Terraform's slugs are the VM's slugs, for the same pairs" "$(repo_slug Acme App) $(repo_slug acme tools) $(repo_slug other svc)" "$(out three slugs | jq -r 'join(" ")')"
  # `tr`: a jq built for Windows ends each line of a multi-line string in CRLF.
  meta=$(out three metadata_value | jq -r . | tr -d '\r')
  check "plan: no line of the metadata value is past the fold" "0" "$(printf '%s\n' "$meta" | awk 'length($0) > 76' | grep -c .)"
  unpacked=$(printf '%s' "$meta" | base64 -d 2>/dev/null | gzip -dc 2>/dev/null)
  check "plan: the value unpacks with the two tools the VM uses" "3" "$(printf '%s' "$unpacked" | jq -r 'length' 2>/dev/null)"
  vm_rows=$(printf '%s' "$unpacked" | repos_table_rows 2>/dev/null)
  check "plan: the VM's parser serves every row Terraform rendered" "3" "$(printf '%s' "$vm_rows" | grep -c .)"
  check "plan: a row's own App id reaches the VM" "0|acme-app|Acme|App|11|22|key-a|main" "$(printf '%s\n' "$vm_rows" | sed -n 1p)"
  check "plan: a row that names none gets the controller-wide values" "1|acme-tools|acme|tools|1|2|key|master" "$(printf '%s\n' "$vm_rows" | sed -n 2p)"
  check "plan: every pool name in the table, in row order" "app-linux tools-linux svc-linux svc-queue" "$(out three pool_names | jq -r 'join(" ")')"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
