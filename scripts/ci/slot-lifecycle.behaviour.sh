#!/usr/bin/env bash
# What slot-reset.sh and slot-sweep.sh DO, as opposed to what they say.
#
# `host-startup.selftest.sh` reads both scripts as text: a pattern must be
# present, and a mutation of it must make the pattern go away. That is the right
# gate for an invariant that lives in one line -- `--disableupdate` is either an
# argument to config.sh or it is not -- and it is why a here-document that
# expanded to nothing (#268) now meets a `bash -n`.
#
# It cannot see a property that lives BETWEEN lines. The loop that took twelve of
# IntegrateIT's twenty-four slots out of service on 2026-08-23 was three correct
# statements composing into a trap:
#
#   the _work wipe recreates the TOP-LEVEL entries of _work, so _work/<owner>
#   came back and _work/<owner>/<repo> did not;
#
#   the runner launches job-completed.sh with that path as its working
#   directory, so the hook could not start;
#
#   the clean marker is written only at `stage != started`, so it was never
#   written again.
#
# Every one of those lines matched its own structural assertion, before the
# outage and after it. So this file exists one level up: it EXTRACTS the two
# scripts the way host-startup.sh writes them, runs them against a real slot
# tree in a sandbox, and asserts on the tree and the marker afterwards.
#
# The extraction is not a re-implementation. Both scripts are written by an
# UNQUOTED here-document, so the shell expands the body before `cat` ever sees
# it; `eval`ing the same body under the same variable names reproduces that
# expansion exactly, character for character. A name that failed to expand, a
# live backtick, an unescaped `$` in a comment -- all of them break here the way
# they break on a host.
#
# ROOT IS REQUIRED and the script re-execs to get it. The reset chowns a home to
# a slot user and empties directories owned by subordinate uids; run as anyone
# else it would report a partial wipe as a completed one, which is the exact
# failure the reset runs as root to avoid. A sandboxed run that quietly skipped
# the assertions would be worse than no gate at all, so a host with neither root
# nor passwordless sudo FAILS rather than passing vacuously.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../../modules/ci-runner-host-pool/scripts/host-startup.sh"

[ -f "$SCRIPT" ] || { echo "FAIL: missing $SCRIPT"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  if sudo -n true >/dev/null 2>&1; then
    exec sudo -n -E bash "${BASH_SOURCE[0]}" "$@"
  fi
  echo "FAIL: this suite runs the reset for real and needs root (or passwordless sudo)"
  echo "      it must not be skipped: every assertion below is about a tree only root can build"
  exit 1
fi

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() { # <description> <condition-as-command...>
  local d="$1"; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

# --- the sandbox --------------------------------------------------------------
#
# One slot, index 1. The index is not free: slot-reset.sh reads the home out of
# the account database and refuses anything that is not /home/<prefix><index>,
# so the user has to be real and its home has to be where the script insists.
IDX=1
PREFIX=ci-s
U="$PREFIX$IDX"
HOME_DIR="/home/$U"
OWNER=acme
REPO=widget

SB=$(mktemp -d /tmp/slot-lifecycle.XXXXXX) || exit 1

SLOT_ROOT="$SB/slots"
SLOT_STATE="$SB/state"
SLOT_TEMPLATE="$SB/template"
PIN_DIR="$SLOT_STATE/.pin"
SLOTS=$IDX

WORK="$SLOT_ROOT/$IDX/_work"
WORKSPACE="$WORK/$OWNER/$REPO"
MARKER="$SLOT_STATE/$IDX/clean"
SINCE="$SLOT_STATE/$IDX/dirty-since"

made_user=0
cleanup() {
  [ "$made_user" = 1 ] && userdel --remove --force "$U" >/dev/null 2>&1
  rm -rf -- "$SB"
}
trap cleanup EXIT

if id "$U" >/dev/null 2>&1; then
  echo "FAIL: $U already exists on this host — refusing to touch an account this suite did not create"
  exit 1
fi
useradd --create-home --home-dir "$HOME_DIR" --shell /usr/sbin/nologin "$U" >/dev/null 2>&1 || {
  echo "FAIL: could not create the sandbox slot user $U"
  exit 1
}
made_user=1

# --- extracting the two scripts, exactly as a host writes them ----------------

body_of() { # <opening-line> — the here-document body, up to its own EOF
  # `\%…%` rather than `/…/`, because every one of these openings names a path.
  sed -n "\%$1%,/^EOF\$/p" "$SCRIPT" | sed '1d;$d'
}

NOISE="$SB/expansion-noise"
: >"$NOISE"

expand_into() { # <destination> <body>
  # The same unquoted here-document the host uses, so the same expansion. `set
  # -u` is the point as much as the expansion is: an unbound name aborts here
  # rather than writing a truncated script, which is how #268 reached a fleet.
  #
  # Anything the expansion prints to stderr is collected rather than discarded.
  # An unquoted here-document expands its COMMENTS too, so a stray backtick pair
  # in a sentence runs whatever it encloses at boot; the command usually
  # succeeds or fails quietly and the only trace is a line on stderr.
  (
    set -u
    eval "cat >\"\$1\" <<EOF
$2
EOF" _ "$1"
  ) 2>>"$NOISE"
}

SLOT_USER_PREFIX=$PREFIX

RESET="$SB/slot-reset.sh"
SWEEP="$SB/slot-sweep.sh"

expand_into "$RESET" "$(body_of 'cat >/opt/ci/job-hooks/slot-reset\.sh <<EOF')" || {
  echo "FAIL: the slot-reset here-document did not expand"
  exit 1
}
expand_into "$SWEEP" "$(body_of 'cat >/opt/ci/job-hooks/slot-sweep\.sh <<EOF')" || {
  echo "FAIL: the slot-sweep here-document did not expand"
  exit 1
}
chmod 0755 "$RESET" "$SWEEP"

echo "extraction"
check "the reset expanded to a non-empty script" test -s "$RESET"
check "the reset parses"                         bash -n "$RESET"
check "the sweep expanded to a non-empty script" test -s "$SWEEP"
check "the sweep parses"                         bash -n "$SWEEP"
check "the reset was told where the slots are"   grep -q "SLOT_ROOT=\"$SLOT_ROOT\"" "$RESET"
check "the sweep was told how many slots there are" grep -q "^SLOTS=$SLOTS\$" "$SWEEP"
# The #268 class, and the reason this suite found one on its first run: a
# backtick pair inside a COMMENT is still a command substitution here.
if [ -s "$NOISE" ]; then
  bad "expanding the two scripts ran something and it complained:"
  sed 's/^/       /' "$NOISE"
else
  ok "expanding the two scripts executed nothing"
fi

# The sweep calls the reset by its installed path. In the sandbox that path is
# the extracted copy, so the one line naming it is rewritten and nothing else is.
sed -i "s#/opt/ci/job-hooks/slot-reset\.sh#$RESET#" "$SWEEP"

# --- the fixture --------------------------------------------------------------

install -d -o root -g root -m 0755 "$SLOT_STATE" "$SLOT_STATE/$IDX" "$PIN_DIR"
install -d -o root -g root -m 0700 "$SLOT_ROOT/.reset"
install -d -m 0755 "$SLOT_TEMPLATE"
printf 'from the template\n' >"$SLOT_TEMPLATE/.bashrc"
install -d -o "$U" -g "$U" -m 0755 "$SLOT_ROOT/$IDX"

# What a job leaves behind, and what the runner puts there before a job starts.
seed_work() {
  rm -rf -- "$WORK"
  install -d -o "$U" -g "$U" -m 0755 "$WORK" "$WORK/_actions" "$WORK/_temp" \
    "$WORK/_tool" "$WORK/$OWNER" "$WORKSPACE"
  printf 'previous job action code\n' >"$WORK/_actions/action.yml"
  printf 'a credential the last job left\n' >"$WORK/_temp/creds.json"
  printf 'the last pull request\n' >"$WORKSPACE/README.md"
  chown -R "$U:$U" "$WORK"
}

# The runner invokes both hooks with the pipeline workspace as their working
# directory. Reproducing that is the whole point of this fixture: it is the
# thing the reset can delete out from under the hook that comes after it.
in_workspace() { # <stage>
  ( cd "$WORKSPACE" 2>/dev/null || exit 127; "$RESET" "$1" "$IDX" >/dev/null 2>&1 )
}

# --- the stages ---------------------------------------------------------------

echo
echo "boot"
seed_work
printf 'a stale dotfile\n' >"$HOME_DIR/.leftover"
"$RESET" boot "$IDX" >/dev/null 2>&1
rc=$?
check "boot succeeds"                        test "$rc" = 0
check "boot writes the clean marker"         test -f "$MARKER"
check "boot rebuilds the home from template" test -f "$HOME_DIR/.bashrc"
check "boot removes what was in the home"    test ! -e "$HOME_DIR/.leftover"
check "boot takes _actions with everything"  test ! -e "$WORK/_actions/action.yml"
check "boot takes _temp with everything"     test ! -e "$WORK/_temp/creds.json"

echo
echo "started, on a clean slot"
seed_work
in_workspace started
rc=$?
check "started succeeds on a clean slot"      test "$rc" = 0
check "started withdraws the clean marker"    test ! -f "$MARKER"
check "started keeps the actions it will run" test -f "$WORK/_actions/action.yml"
check "started keeps _temp, which carries its own invocation" test -f "$WORK/_temp/creds.json"
check "started removes the last job's checkout" test ! -e "$WORKSPACE/README.md"
check "started leaves _tool in place as a directory" test -d "$WORK/_tool"
check "the reset lock lives where no slot can write it" test -f "$SLOT_STATE/$IDX/.reset.lock"

echo
echo "completed, closing that job"
in_workspace completed
rc=$?
check "completed succeeds"                    test "$rc" = 0
check "completed writes the clean marker"     test -f "$MARKER"
check "completed takes _actions"              test ! -e "$WORK/_actions/action.yml"
check "completed takes the credential in _temp" test ! -e "$WORK/_temp/creds.json"

echo
echo "started, on a slot whose last job never completed"
#
# The state the whole mechanism exists for. The job IS failed, deliberately and
# correctly: this is the one moment at which _actions cannot be trusted, so a
# job that ran here would run the previous job's action code.
seed_work
rm -f -- "$MARKER"
in_workspace started
rc=$?
check "the job is failed rather than run"          test "$rc" != 0
check "the untrusted actions are destroyed"        test ! -e "$WORK/_actions/action.yml"
check "no clean marker is invented for it"         test ! -f "$MARKER"

echo
echo "and then the slot comes back"
#
# One lost job is the design. A SECOND lost job is the defect: if the completed
# reset that follows cannot write the marker, every job routed here afterwards
# is failed the same way, forever. That is the loop, and these four assertions
# are the ones that would have caught it before it reached a fleet.
check "the directory the next hook is launched in still exists" test -d "$WORKSPACE"
in_workspace completed
rc=$?
check "the completed reset can run at all"     test "$rc" != 127
check "the completed reset succeeds"           test "$rc" = 0
check "the slot is marked clean again"         test -f "$MARKER"
seed_work
in_workspace started
check "the next job takes the ordinary path"   test "$?" = 0
in_workspace completed >/dev/null 2>&1

echo
echo "refusals"
seed_work
"$RESET" started nonsense >/dev/null 2>&1
check "a non-numeric index is refused"  test "$?" != 0
"$RESET" wipe "$IDX" >/dev/null 2>&1
check "an unknown stage is refused"     test "$?" != 0

# A slot owns the parent of _work, so the name is one an untrusted account can
# replace. Following it would have root empty whatever it points at.
"$RESET" completed "$IDX" >/dev/null 2>&1
rm -rf -- "$WORK"
sudo -u "$U" ln -s /tmp "$WORK"
"$RESET" completed "$IDX" >/dev/null 2>&1
rc=$?
check "a _work replaced by a symlink is refused" test "$rc" != 0
check "and the slot is not marked clean"         test ! -f "$MARKER"
check "and the symlink target is untouched"      test -d /tmp
rm -f -- "$WORK"

# --- the sweep ----------------------------------------------------------------
#
# Everything above is the reset in isolation. The sweep is what decides WHEN it
# runs, and the property that matters is the one it was written for: a slot left
# dirty by a job that never completed comes back without a job being spent on it.

echo
echo "sweep: a clean slot"
seed_work
"$RESET" completed "$IDX" >/dev/null 2>&1
printf '%s\n' 1 >"$SINCE"
"$SWEEP" >/dev/null 2>&1
check "a clean slot is left alone"                test -f "$MARKER"
check "and its dirty clock is cleared"            test ! -f "$SINCE"

echo
echo "sweep: a dirty slot, first sight"
seed_work
rm -f -- "$MARKER"
"$SWEEP" >/dev/null 2>&1
check "the first tick does not act"               test ! -f "$MARKER"
check "the first tick starts the clock"           test -f "$SINCE"
check "the slot is left as it was"                test -f "$WORK/_actions/action.yml"

echo
echo "sweep: a dirty slot, still dirty a grace later"
printf '%s\n' 1 >"$SINCE"
"$SWEEP" >/dev/null 2>&1
check "the slot is reset"                         test -f "$MARKER"
check "and the leftovers are gone"                test ! -e "$WORK/_actions/action.yml"
check "and the clock is cleared"                  test ! -f "$SINCE"
check "no job was spent doing it"                 test -d "$WORK"

echo
echo "sweep: a dirty slot with a job on it"
#
# The one thing this must never do. A live job holds a worker process for its
# whole length and the marker is absent for that whole length too, so 'dirty'
# alone describes a running job exactly as well as it describes a dead one.
seed_work
rm -f -- "$MARKER"
printf '%s\n' 1 >"$SINCE"
sudo -u "$U" bash -c 'exec -a Runner.Worker sleep 20' &
worker=$!
sleep 1
"$SWEEP" >/dev/null 2>&1
check "a slot with a worker on it is not reset"   test -f "$WORK/_actions/action.yml"
check "and it is not marked clean underneath one" test ! -f "$MARKER"
check "and its clock is reset, not advanced"      test ! -f "$SINCE"
kill "$worker" >/dev/null 2>&1
wait "$worker" >/dev/null 2>&1

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
