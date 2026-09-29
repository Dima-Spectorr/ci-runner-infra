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

# AND THEN SUDO GETS OUT OF THE WAY. sudo sets SUDO_UID itself, and that is not
# an incidental variable to slot-reset.sh: it is the signal "a slot invoked me,
# so read the index out of the account database and ignore anything the caller
# named". It is the whole reason the sudoers rule can be safe. Here it is a lie
# — the invoking account is the CI runner, not a slot — so every reset below is
# refused with "uid N is not a slot user", and the suite would then be testing
# the refusal path twenty times over while reporting the reset as broken.
#
# Both callers this file models are root with no sudo in the picture: systemd's
# ExecStartPre on the agent unit, and the sweep's own timer. Neither has these.
unset SUDO_UID SUDO_GID SUDO_USER SUDO_COMMAND

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; }

check() { # <description> <condition-as-command...>
  local d="$1"; shift
  # `!` is a shell KEYWORD and a keyword does not survive "$@" expansion -- it
  # arrives here as a command named `!`, which does not exist, so the assertion
  # reports the missing command instead of the condition. Refuse it outright:
  # a negated condition has its own helper below.
  if [ "$1" = '!' ]; then
    bad "$d [harness: negate with check_not, not a leading !]"
    return
  fi
  if "$@"; then ok "$d"; else bad "$d"; fi
}

check_not() { # <description> <condition-as-command...>
  local d="$1"; shift
  if "$@"; then bad "$d"; else ok "$d"; fi
}

# Wrapped rather than redirected at the call site, so the quieting lands on
# pgrep and not on the assertion's own verdict.
pgrep_slot() { pgrep -u "$U" >/dev/null 2>&1; }

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

# The tool cache the reset hook REPORTS on. Bound here for the same reason
# SLOT_USER_PREFIX is bound further down: host-startup.sh bakes these three into
# the hook at write time, the expansion below runs under `set -u`, and a name it
# has not heard of does not render empty — it aborts the whole here-document.
# expand_into catches that and says so, which is the only reason this is a line
# of setup rather than an afternoon.
#
# Pointed inside $SB like everything else here. This file runs under `sudo -n` on
# a real slot host, where /var/lib/ci-cache and /opt/ci-tool-cache exist and
# belong to live jobs; the hook only reads names out of them, but a fixture that
# can reach a production path at all is a fixture one edit away from writing to
# it.
# shellcheck disable=SC2034  # read by the here-document bodies, through the eval
CACHE_SLOTS="$SB/cache"
# shellcheck disable=SC2034
TOOL_CACHE_MASTER="$SB/tool-master"
# shellcheck disable=SC2034
TOOL_CACHE_NAME=tools

WORK="$SLOT_ROOT/$IDX/_work"
WORKSPACE="$WORK/$OWNER/$REPO"
MARKER="$SLOT_STATE/$IDX/clean"
BURNS_1392="$SLOT_STATE/$IDX/burns"
SINCE="$SLOT_STATE/$IDX/dirty-since"

made_user=0
made_unit=0
made_rundir=0
made_linger=0
DAEMON_UNIT="ci-dockerd@$IDX.service"
cleanup() {
  # The stand-in daemon first: userdel refuses an account with a live process.
  [ "$made_unit" = 1 ] && systemctl stop "$DAEMON_UNIT" >/dev/null 2>&1
  # And the slot's user manager, for the same reason (#1395).
  if [ "$made_linger" = 1 ]; then
    loginctl disable-linger "$U" >/dev/null 2>&1
    systemctl stop "user@$(id -u "$U").service" >/dev/null 2>&1
  fi
  [ "$made_rundir" = 1 ] && rm -rf -- "/run/$U"
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

# Everything the two hooks say, kept rather than discarded. Both are chatty on
# the way out — every refusal in them is a `say` — while a failing assertion
# here is a one-line "boot succeeds FAIL" naming an exit status and no reason.
# The log is printed only when something failed, so a green run stays quiet.
HOOKLOG="$SB/hook-output"
: >"$HOOKLOG"

expand_into() { # <destination> <body>
  # The same unquoted here-document the host uses, so the same expansion. `set
  # -u` is the point as much as the expansion is: an unbound name aborts here
  # rather than writing a truncated script, which is how #268 reached a fleet.
  #
  # `eval` JOINS its arguments and evaluates the result; it does not take
  # positional parameters. So a trailing `_ "$1"` does not bind $1 — it lands on
  # the closing EOF, which then terminates nothing, and bash reads to the end of
  # the string with `warning: here-document delimited by end-of-file` on the
  # stderr this function collects. $1 is already the destination: it is this
  # function's own first argument, which the subshell inherits. Hence the
  # newline after EOF, and nothing after that.
  #
  # Anything the expansion prints to stderr is collected rather than discarded.
  # An unquoted here-document expands its COMMENTS too, so a stray backtick pair
  # in a sentence runs whatever it encloses at boot; the command usually
  # succeeds or fails quietly and the only trace is a line on stderr.
  (
    set -u
    eval "cat >\"\$1\" <<EOF
$2
EOF
"
  ) 2>>"$NOISE"
}

# Read by the here-document bodies below, not by this file: host-startup.sh
# renders `SLOT_USER_PREFIX="$SLOT_USER_PREFIX"` into each hook, so the name has
# to be bound HERE for the expansion under `set -u` to succeed. No static reader
# — shellcheck included — can see through the eval that does it.
# shellcheck disable=SC2034
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

# mktemp gives the sandbox 0700 root, and every path below it inherits that as
# an execute barrier: a `sudo -u ci-s1` step cannot TRAVERSE into its own slot
# directory, let alone write there. On a host the slot tree lives under a 0755
# /var/lib path. Without this the tests that act as the slot fail on the fixture
# rather than on the thing they are testing.
chmod 0755 "$SB"

install -d -o root -g root -m 0755 "$SLOT_STATE" "$SLOT_STATE/$IDX" "$PIN_DIR"
# Both levels, the way provision_slot_user creates them. The reset renames _work
# into $SLOT_ROOT/.reset/$idx/ for the duration; with the per-slot level missing
# that rename fails, the reset gives up before it purges anything, and the
# result reads as "the reset does not empty _work" — a fixture gap wearing the
# costume of the bug this suite exists to catch.
install -d -o root -g root -m 0700 "$SLOT_ROOT/.reset" "$SLOT_ROOT/.reset/$IDX"
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
  # A missing workspace is a FIXTURE fault, and it used to be a silent one: 127
  # with nothing in the hook log, which reads as the reset failing. Say so.
  ( cd "$WORKSPACE" 2>/dev/null ||
      { echo "in_workspace $1: $WORKSPACE does not exist -- the hook was never run" >>"$HOOKLOG"; exit 127; }
    "$RESET" "$1" "$IDX" >>"$HOOKLOG" 2>&1 )
}

# --- the stages ---------------------------------------------------------------

echo
echo "boot"
seed_work
printf 'a stale dotfile\n' >"$HOME_DIR/.leftover"
"$RESET" boot "$IDX" >>"$HOOKLOG" 2>&1
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
echo "quiesce: a writer the last job left running"
#
# #237 finding 3, and the reason this suite exists rather than another static
# assertion. Every step of the old reset was right: it emptied the home, it
# restored the template, it tore the containers down, it wrote the marker. The
# ORDER was wrong -- the teardown came after the wipe -- so anything the last
# job left running had a window in which to put a dotfile, a credential or a
# checkout back into a home that had just been made clean, and the marker went
# on over it. Nothing in the text of any one line is incorrect, and the slot the
# next job lands on is certified clean by a reset a writer outlived.
#
# A detached container is the case the issue names; a process the job simply
# backgrounded is the same bug with less machinery, needs no daemon in the
# sandbox, and is what runs here.
seed_work
sudo -u "$U" nohup bash -c "while :; do printf 'the last job is still here\n' >'$HOME_DIR/.pwned'; sleep 0.1; done" \
  >/dev/null 2>&1 &
# Long enough for the loop to have written once, so a pass cannot be a writer
# that never got started.
sleep 1
check "the writer is actually running before the reset" test -e "$HOME_DIR/.pwned"

in_workspace completed
rc=$?
# A full second AFTER the reset returned. The writer's loop turns ten times in
# it, so a survivor recreates the file and this assertion is not a race.
sleep 1
check "the reset succeeds with a writer to stop"  test "$rc" = 0
# NOT `check ... ! pgrep ... >/dev/null 2>&1`: those redirections attach to
# `check`, not to pgrep, so the verdict this assertion prints goes to /dev/null
# and a failure is counted with nothing on screen naming it. Silence the
# condition, never the harness.
check_not "no process of the slot outlives the reset" pgrep_slot
check "nothing rewrote the home after the wipe"   test ! -e "$HOME_DIR/.pwned"
check "the home is the template's again"          test -f "$HOME_DIR/.bashrc"
check "and the marker means it"                   test -f "$MARKER"

# The suite goes on after a failed assertion, so a writer that DID survive would
# keep rewriting the home under every case below and the report would blame
# them. Kill anything of this slot's here, whatever the verdict was.
sudo pkill -KILL -u "$U" >/dev/null 2>&1 || :
sleep 0.2
rm -f -- "$HOME_DIR/.pwned"

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
"$RESET" started nonsense >>"$HOOKLOG" 2>&1
check "a non-numeric index is refused"  test "$?" != 0
"$RESET" wipe "$IDX" >>"$HOOKLOG" 2>&1
check "an unknown stage is refused"     test "$?" != 0

# A slot owns the parent of _work, so the name is one an untrusted account can
# replace. Following it would have root empty whatever it points at.
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
rm -rf -- "$WORK"
sudo -u "$U" ln -s /tmp "$WORK"
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
rc=$?
check "a _work replaced by a symlink is refused" test "$rc" != 0
check "and the slot is not marked clean"         test ! -f "$MARKER"
check "and the symlink target is untouched"      test -d /tmp
rm -f -- "$WORK"

echo
echo "the slot's private /tmp (#1383)"
#
# PrivateTmp keeps one slot's /tmp from its siblings, and the namespace lives as
# long as the daemon -- many jobs. gitleaks-action downloads to the fixed path
# /tmp/gitleaks.tmp, so the second gitleaks job on a slot died on the first
# one's file. The reset now empties that /tmp, and it has to find it through the
# daemon: the root callers modelled here run in the HOST namespace, where the
# literal /tmp is everybody's.
#
# So the daemon is real enough to own a namespace: a transient unit under the
# exact name the reset asks systemd about, as the slot user, with PrivateTmp --
# the three things the reset checks. It is spared by the quiesce the same way
# the real daemon is, by its cgroup name.
seed_work
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
HOST_SENTINEL=$(mktemp /tmp/slot-lifecycle-host.XXXXXX)
dpid=""
if systemd-run --quiet --unit="$DAEMON_UNIT" --uid="$U" -p PrivateTmp=yes \
     sleep 600 >>"$HOOKLOG" 2>&1; then
  made_unit=1
  # MainPID is set at fork, before systemd has built the namespace. Wait until
  # the process IS sleep, or /proc/<pid>/root/tmp can still be the host's.
  for _ in $(seq 1 50); do
    dpid=$(systemctl show -p MainPID --value "$DAEMON_UNIT" 2>/dev/null)
    case "$dpid" in '' | 0) dpid="" ;; *) [ "$(cat "/proc/$dpid/comm" 2>/dev/null)" = sleep ] && break ;; esac
    sleep 0.1
  done
fi
SLOT_TMP="/proc/${dpid:-0}/root/tmp"
private_tmp() {
  [ -n "$dpid" ] && [ -d "$SLOT_TMP" ] &&
    [ "$(stat -L -c '%d:%i' "$SLOT_TMP")" != "$(stat -L -c '%d:%i' /tmp)" ]
}
check "the stand-in daemon has a private /tmp to reset" private_tmp

seed_slot_tmp() {
  # Removed first: the slot owns it and /tmp is sticky, so Ubuntu's
  # fs.protected_regular refuses even root an O_CREAT on the old copy.
  rm -f -- "$SLOT_TMP/gitleaks.tmp"
  printf 'a previous download\n' >"$SLOT_TMP/gitleaks.tmp"
  install -d -o "$U" -g "$U" "$SLOT_TMP/a-fixed-dir" "$SLOT_TMP/.dotnet"
  chown "$U:$U" "$SLOT_TMP/gitleaks.tmp"
}
seed_slot_tmp
# The completed reset above emptied _work, and in_workspace runs each hook FROM
# the workspace, as the runner does: without a fresh one the hook never starts.
seed_work
in_workspace started
rc=$?
check "started succeeds with a leftover download"      test "$rc" = 0
check "started removes the fixed-path download"        test ! -e "$SLOT_TMP/gitleaks.tmp"
check "started leaves the rest of /tmp to the job boundary" test -d "$SLOT_TMP/a-fixed-dir"
in_workspace completed
rc=$?
check "completed succeeds"                             test "$rc" = 0
check "completed empties the slot's /tmp"              test ! -e "$SLOT_TMP/a-fixed-dir"
check "the agent's runtime directory survives"         test -d "$SLOT_TMP/.dotnet"
check "the stand-in daemon survived the quiesce"       test -d "/proc/${dpid:-0}"
check "the HOST /tmp is untouched"                     test -f "$HOST_SENTINEL"
check "and the marker means it"                        test -f "$MARKER"

# Break it back, and prove the assertions above notice: the same reset with the
# emptying call removed must leave the directory where the job put it.
MUTANT="$SB/slot-reset.mutant.sh"
sed 's/^  reset_slot_tmp all || rc=1$/  :/' "$RESET" >"$MUTANT"
chmod 0755 "$MUTANT"
check_not "the mutation applied" cmp -s "$RESET" "$MUTANT"
seed_slot_tmp
"$MUTANT" completed "$IDX" >>"$HOOKLOG" 2>&1
check "without the call, the leftover survives -- so the check above is live" test -d "$SLOT_TMP/a-fixed-dir"
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1

# A symlink the job planted, pointing at a HOST directory: the link goes, the
# target and its content do not.
HOST_TARGET=$(mktemp -d /tmp/slot-lifecycle-target.XXXXXX)
printf 'host data\n' >"$HOST_TARGET/keep"
ln -s "$HOST_TARGET" "$SLOT_TMP/evil"
chown -h "$U:$U" "$SLOT_TMP/evil"
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
check "a planted symlink is removed"                   test ! -L "$SLOT_TMP/evil"
check "and the host directory it named is untouched"   test -f "$HOST_TARGET/keep"
rm -rf -- "$HOST_TARGET"

# WHAT IS SPARED, and only in the shape the runtime uses. $dpid is a live
# process of the slot uid; 999999999 is above any pid_max, so never alive.
make_sock() { python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"; }
seed_spared() {
  # The live-pid entries SURVIVE a reset by design, so a re-seed meets them.
  rm -f -- "$SLOT_TMP/dotnet-diagnostic-$dpid-1-socket" "$SLOT_TMP/clr-debug-pipe-$dpid-1-in"
  make_sock "$SLOT_TMP/dotnet-diagnostic-$dpid-1-socket"
  make_sock "$SLOT_TMP/dotnet-diagnostic-999999999-1-socket"
  mkfifo "$SLOT_TMP/clr-debug-pipe-$dpid-1-in" "$SLOT_TMP/clr-debug-pipe-999999999-1-in"
  printf 'carried data\n' >"$SLOT_TMP/dotnet-diagnostic-$dpid-2-socket"
  install -d "$SLOT_TMP/.dotnet/shm" "$SLOT_TMP/.dotnet/lockfiles" "$SLOT_TMP/.dotnet/junk"
}
seed_spared
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
check "a live pid's diagnostic socket survives"        test -S "$SLOT_TMP/dotnet-diagnostic-$dpid-1-socket"
check "a dead pid's diagnostic socket goes"            test ! -e "$SLOT_TMP/dotnet-diagnostic-999999999-1-socket"
check "a live pid's debug pipe survives"               test -p "$SLOT_TMP/clr-debug-pipe-$dpid-1-in"
check "a dead pid's debug pipe goes"                   test ! -e "$SLOT_TMP/clr-debug-pipe-999999999-1-in"
check "a regular file under a live pid's name goes"    test ! -e "$SLOT_TMP/dotnet-diagnostic-$dpid-2-socket"
check ".dotnet/shm survives"                           test -d "$SLOT_TMP/.dotnet/shm"
check ".dotnet/lockfiles survives"                     test -d "$SLOT_TMP/.dotnet/lockfiles"
check "anything else in .dotnet goes"                  test ! -e "$SLOT_TMP/.dotnet/junk"

# Break the pid rule back and prove the dead-pid assertions notice.
# shellcheck disable=SC2016  # the pattern is the RENDERED hook's literal ${p%%-*}; nothing here may expand it
sed 's/tmp_pid_alive "\${p%%-\*}"/true/' "$RESET" >"$MUTANT"
check_not "the pid-rule mutation applied" cmp -s "$RESET" "$MUTANT"
seed_spared
"$MUTANT" completed "$IDX" >>"$HOOKLOG" 2>&1
check "without the pid rule a dead pid's socket survives -- so the check is live" \
  test -S "$SLOT_TMP/dotnet-diagnostic-999999999-1-socket"
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1

# ROOTLESSKIT'S COPY-UP DIRECTORY (#1387). rootlesskit makes it, binds /etc onto
# it, moves the bind away and removes it, all before dockerd makes its socket; a
# live host had none left in any slot's /tmp. So it is spared only while that
# can still be running -- no socket at /run/<slot>/docker.sock -- and only in
# the shape it has then: an empty real directory the slot owns. The socket here
# is a bound, never-listening stand-in, removed again before the sweep section.
DSOCK="/run/$U/docker.sock"
# A LEFTOVER /run/$U is this suite's own, from a run that was killed before its
# cleanup (#1392 T1): the account is created above and the suite refuses to
# start if it already existed, so no live slot can own this path here. Refusing
# on it would fail every later run on that machine until someone removed it.
rm -rf -- "/run/$U"
if install -d -o "$U" -g "$U" -m 0700 "/run/$U"; then
  made_rundir=1
fi
check "the suite owns /run/$U for the stand-in socket" test "$made_rundir" = 1
seed_copyup() {
  rm -rf -- "$SLOT_TMP"/rootlesskit-*
  install -d -o "$U" -g "$U" -m 0700 "$SLOT_TMP/rootlesskit-b1" "$SLOT_TMP/rootlesskit-b2" \
    "$SLOT_TMP/rootlesskit-b4"
  printf 'carried data\n' >"$SLOT_TMP/rootlesskit-b2/stash"
  install -d -o root -g root -m 0700 "$SLOT_TMP/rootlesskit-b3"
  install -d -o "$U" -g "$U" -m 0700 "$SLOT_TMP/rootlesskit-b4/.hidden"
}
copyup_reset() { # <script> <with|without> -- one completed reset, the socket as named
  rm -f -- "$DSOCK"
  if [ "$2" = with ]; then make_sock "$DSOCK"; fi
  seed_copyup
  "$1" completed "$IDX" >>"$HOOKLOG" 2>&1
  rm -f -- "$DSOCK"
}
copyup_reset "$RESET" without
check "before the socket, an empty slot-owned copy-up dir survives" test -d "$SLOT_TMP/rootlesskit-b1"
check "one holding a file goes"                        test ! -e "$SLOT_TMP/rootlesskit-b2"
check "one owned by anyone but the slot goes"          test ! -e "$SLOT_TMP/rootlesskit-b3"
check "one holding only a dot-entry goes"              test ! -e "$SLOT_TMP/rootlesskit-b4"
copyup_reset "$RESET" with
check "once the socket exists, even an empty one goes" test ! -e "$SLOT_TMP/rootlesskit-b1"

# Each of the three conditions broken back, and the assertion it backs notices.
# shellcheck disable=SC2016  # the patterns are the RENDERED hook's literal $sock/$1/$uid; nothing here may expand them
sed 's/rootlesskit-\*) \[ ! -S "\$sock" \] && /rootlesskit-*) /' "$RESET" >"$MUTANT"
check_not "the socket-rule mutation applied" cmp -s "$RESET" "$MUTANT"
copyup_reset "$MUTANT" with
check "without the socket rule an empty one survives the socket -- so the check is live" \
  test -d "$SLOT_TMP/rootlesskit-b1"
sed 's/ -maxdepth 0 -type d -empty -print/ -maxdepth 0 -type d -print/' "$RESET" >"$MUTANT"
check_not "the emptiness mutation applied" cmp -s "$RESET" "$MUTANT"
copyup_reset "$MUTANT" without
check "without the emptiness rule the stash survives -- so the check is live" \
  test -f "$SLOT_TMP/rootlesskit-b2/stash"
# shellcheck disable=SC2016  # as above: the rendered hook's literal text
sed 's/\[ "\$(stat -c .%u. -- "\$1" 2>\/dev\/null)" = "\$uid" \] &&$/true \&\&/' "$RESET" >"$MUTANT"
check_not "the owner mutation applied" cmp -s "$RESET" "$MUTANT"
copyup_reset "$MUTANT" without
check "without the owner rule root's directory survives -- so the check is live" \
  test -d "$SLOT_TMP/rootlesskit-b3"
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1

# Through the HOST namespace, with no daemon: nothing may be emptied, because
# the only /tmp left to find is the host's.
systemctl stop "$DAEMON_UNIT" >/dev/null 2>&1
made_unit=0
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
check "with no daemon the reset still succeeds"        test "$?" = 0
check "and the HOST /tmp is still untouched"           test -f "$HOST_SENTINEL"

# A daemon WITHOUT PrivateTmp resolves to the host's /tmp through /proc as well.
# The guard must refuse it. (Its mutation is not run here: a broken guard would
# empty this machine's /tmp. host-startup.selftest.sh mutates it structurally.)
if systemd-run --quiet --unit="$DAEMON_UNIT" --uid="$U" sleep 600 >>"$HOOKLOG" 2>&1; then
  made_unit=1
  sleep 1
fi
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
check "a daemon sharing the host /tmp is refused, and the host /tmp survives" test -f "$HOST_SENTINEL"
check "and the refusal is logged" grep -q 'is not a private one' "$HOOKLOG"
systemctl stop "$DAEMON_UNIT" >/dev/null 2>&1
made_unit=0
rm -f -- "$HOST_SENTINEL"

echo
echo "the daemon's socket, moved by the job (#1392)"
#
# The slot owns /run/<slot>, so a job can rename docker.sock. The daemon keeps
# listening on the renamed inode, and the reset used to read the missing name as
# "no daemon": it skipped the container and volume prune and wrote the marker
# anyway, handing the next job the last one's database through the new name.
#
# The stand-in daemon is a real listener in the unit the reset asks systemd
# about, bound where the real one binds. It accepts and hangs up at once, so a
# prune that does reach it fails in milliseconds instead of waiting out three
# docker timeouts -- which is also why the positive case below is asserted on
# the classification and not on the marker.
# /run/$U and $DSOCK are the copy-up section's, still in place (and emptied of
# its stand-in socket).
MOVED="/run/$U/x.sock"
RUNLOG="$SB/run-output"
check "/run/$U is still there for the stand-in daemon" test -d "/run/$U"
LISTENER='import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(8)
while True:
    c, _ = s.accept()
    c.close()'
if systemd-run --quiet --unit="$DAEMON_UNIT" --uid="$U" python3 -c "$LISTENER" "$DSOCK" \
     >>"$HOOKLOG" 2>&1; then
  made_unit=1
fi
for _ in $(seq 1 50); do
  [ -S "$DSOCK" ] && break
  sleep 0.1
done
check "the stand-in daemon listens at the slot's socket" test -S "$DSOCK"

reset_once() { # <script> -- one completed reset; its output kept apart as well
  "$1" completed "$IDX" >"$RUNLOG" 2>&1
  rc=$?
  cat "$RUNLOG" >>"$HOOKLOG"
  return 0
}
refused_socket() { grep -q 'is not the socket it listens on' "$RUNLOG"; }
reads_as() { grep -q "$DSOCK reads as $1\$" "$RUNLOG"; }

# The daemon's own socket, where it belongs: classified as the daemon's -- not
# merely "not foreign", which absent and starting would pass as well.
reset_once "$RESET"
check "the daemon's own socket reads as ours"          reads_as ours
check_not "and is not called foreign"                  refused_socket

# A FAILED LISTING IS NOT AN EMPTY ONE (#1392 review). A docker ps piped into
# sort took sort's status, so a listing that errored or timed out -- a slow
# daemon, or one a leftover had stopped -- read as "no containers" and the
# marker went on over a live stack. Here docker is a stand-in, swapped in for
# every call the reset makes, that answers everything empty and succeeds, and
# fails ps on demand. Everything else about the slot is healthy, so the ps
# failure is the only thing that can cost the marker.
FAKEBIN="$SB/fakebin"
install -d -m 0755 "$FAKEBIN"
FAKECALLS="$SB/fake-calls"
: >"$FAKECALLS"
chmod 0666 "$FAKECALLS"
cat >"$FAKEBIN/docker" <<FAKE
#!/bin/sh
echo "\$(id -un): \$*" >>"$FAKECALLS"
[ "\$1" = ps ] && [ -f "$SB/ps-fails" ] && exit 1
exit 0
FAKE
chmod 0755 "$FAKEBIN/docker"
# The transport first, on its own, so a failure below is about the reset and
# not about the stand-in being unreachable as the slot.
fake_as_slot() {
  timeout 30 sudo -u "$U" DOCKER_HOST="unix://$DSOCK" "$FAKEBIN/docker" network prune --force \
    >>"$HOOKLOG" 2>&1
}
check "the stand-in docker runs as the slot user" fake_as_slot
# The RENDERED reset, not host-startup.sh's text: install_job_hooks writes it
# through an unquoted here-document, which joins every backslash-continued line.
# So `DOCKER_HOST="unix://$sock" \` + an indented `docker ps` arrives as ONE line
# with a run of spaces between the two -- and a pattern that wants exactly one
# space, or `docker` at the start of a line, leaves the real docker in place,
# talking to a stand-in daemon that hangs up on it (#1394).
fake_docker() { # <script> <out> -- the same reset, with every docker call on the stand-in
  sed "s#^\([[:space:]]*\)docker #\1$FAKEBIN/docker #; s#\(DOCKER_HOST=\"unix://\\\$sock\"\)[[:space:]]\{1,\}docker #\1 $FAKEBIN/docker #" "$1" >"$2"
  chmod 0755 "$2"
}
FAKED="$SB/slot-reset.faked.sh"
fake_docker "$RESET" "$FAKED"
check_not "every docker call is on the stand-in" grep -qE '^[[:space:]]*docker |"[[:space:]]+docker ' "$FAKED"


rm -f -- "$MARKER" "$SB/ps-fails"
: >"$FAKECALLS"
reset_once "$FAKED"
check "the reset's own docker calls reach the stand-in" grep -q ': ps --all' "$FAKECALLS"
check "with docker answering, the slot is marked clean" test -f "$MARKER"

rm -f -- "$MARKER"
: >"$SB/ps-fails"
reset_once "$FAKED"
check "a failed docker ps fails the reset"             test "$rc" != 0
check "and the slot is not marked clean"               test ! -f "$MARKER"
check "and says why"                                   grep -q 'could not list the containers' "$RUNLOG"

# Put the pipe back, and the same failure earns the marker -- so the check is
# live. The hook runs under pipefail, so the pipe alone would still carry
# docker's status; the old listing's status was sort's, and that is restored
# with pipefail off inside the substitution.
# shellcheck disable=SC2016  # the rendered hook's literal $derr; nothing here may expand it
sed 's#if ! cids=\$(timeout 30 #if ! cids=$(set +o pipefail; timeout 30 #; s#docker ps --all --quiet --no-trunc 2>"\$derr"); then#docker ps --all --quiet --no-trunc 2>"$derr" | sort -u); then#' \
  "$FAKED" >"$MUTANT"
chmod 0755 "$MUTANT"
check_not "the pipe mutation applied" cmp -s "$FAKED" "$MUTANT"
rm -f -- "$MARKER"
reset_once "$MUTANT"
check "piped into sort, the failed ps earns the marker -- so the check is live" test -f "$MARKER"
rm -f -- "$SB/ps-fails"
# What the stand-in was asked, kept with the hooks' own output for a failed run.
sed 's/^/  stand-in docker: /' "$FAKECALLS" >>"$HOOKLOG"

# Renamed by the job.
rm -f -- "$MARKER" "$BURNS_1392"
sudo -u "$U" mv -- "$DSOCK" "$MOVED"
reset_once "$RESET"
check "a renamed socket fails the reset"               test "$rc" != 0
check "and says why"                                   refused_socket
check "and the slot is not marked clean"               test ! -f "$MARKER"
check "and the failure is counted like any unclean reset" grep -qx 1 "$BURNS_1392"

# Break the fail-closed branch back: the same rename must then earn the marker,
# which is the leak -- so the assertions above are live.
# shellcheck disable=SC2016  # the rendered hook's literal $dsock; nothing here may expand it
sed 's/if \[ "\$dsock" = foreign \]; then/if false; then/' "$RESET" >"$MUTANT"
check_not "the fail-closed mutation applied" cmp -s "$RESET" "$MUTANT"
rm -f -- "$MARKER"
reset_once "$MUTANT"
check "without the branch the renamed socket earns the marker -- so the check is live" \
  test -f "$MARKER"

# A listener of the JOB's own at the name, the daemon's renamed out of the way.
rm -f -- "$MARKER"
sudo -u "$U" python3 -c "$LISTENER" "$DSOCK" >/dev/null 2>&1 &
fake=$!
for _ in $(seq 1 50); do
  [ -S "$DSOCK" ] && break
  sleep 0.1
done
check "the job's own listener is up at the name"       test -S "$DSOCK"
reset_once "$RESET"
# The quiesce now runs BEFORE the classification (#1392 review), so the job's
# listener is gone by then and what is left at the name answers nobody.
check "a job's listener at the name fails the reset"   test "$rc" != 0
check "and is called foreign"                          refused_socket
check "and the slot is not marked clean"               test ! -f "$MARKER"
# By pid, so the stand-in daemon -- the same program -- is never the one hit.
kill "$fake" >/dev/null 2>&1
wait "$fake" >/dev/null 2>&1

# A listener the quiesce does NOT stop -- root's here, standing in for anything
# outside the slot uid's reach -- is what the peer check is for. Refused as
# foreign, and with the check broken back it is trusted.
rm -f -- "$DSOCK" "$MARKER"
python3 -c "$LISTENER" "$DSOCK" >/dev/null 2>&1 &
fake=$!
for _ in $(seq 1 50); do
  [ -S "$DSOCK" ] && break
  sleep 0.1
done
reset_once "$RESET"
check "a listener outside the daemon's unit is called foreign" refused_socket
check "and the slot is not marked clean"               test ! -f "$MARKER"
# shellcheck disable=SC2016  # the rendered hook's literal $p/$peer
sed 's/\[ "\$p" = "\$peer" \] && { echo ours/true \&\& { echo ours/' "$RESET" >"$MUTANT"
check_not "the peer mutation applied" cmp -s "$RESET" "$MUTANT"
check "the outside listener is still up for the mutant" test -S "$DSOCK"
for _ in $(seq 1 50); do
  [ -S "$DSOCK" ] && break
  sleep 0.1
done
# Without a live daemon the reset says nothing about the socket at all, and the
# assertion below would pass for that reason instead.
check "the stand-in daemon is still up for the mutant" systemctl is-active --quiet "$DAEMON_UNIT"
reset_once "$MUTANT"
check "without the peer check the job's listener reads as ours -- so the check is live" \
  reads_as ours
kill "$fake" >/dev/null 2>&1
wait "$fake" >/dev/null 2>&1

systemctl stop "$DAEMON_UNIT" >/dev/null 2>&1
made_unit=0
rm -rf -- "/run/$U"
made_rundir=0
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
check "with the daemon gone the slot comes back clean" test -f "$MARKER"

echo
echo "the slot's user manager: a job's own units (#1395)"
#
# A slot user lingers, so its user manager outlives every job, and a job can
# hand it a process: `systemd-run --user --unit=x sleep 1d` lands in
# user@<uid>.service/app.slice, outside the agent's cgroup, and the quiesce used
# to spare that whole tree. Measured live 2026-09-29: the unit ran on into the
# next job. So here the manager is real (linger, as on a host), the job's units
# are started AS THE SLOT, from the slot's own bus, and the reset must leave
# the manager and its bus up and nothing else of the job's.
SUID=$(id -u "$U")
UBUS="/run/user/$SUID/bus"
if loginctl enable-linger "$U" >>"$HOOKLOG" 2>&1; then
  made_linger=1
fi
for _ in $(seq 1 100); do
  [ -S "$UBUS" ] && break
  sleep 0.1
done
check "the slot has a user manager and a user bus" test -S "$UBUS"
as_slot() { sudo -u "$U" XDG_RUNTIME_DIR="/run/user/$SUID" DBUS_SESSION_BUS_ADDRESS="unix:path=$UBUS" "$@"; }
unit_live() { # <unit> -- live in the slot's manager
  timeout 10 systemctl --user -M "$U@" is-active --quiet "$1" >/dev/null 2>&1
}
seed_units() {
  timeout 10 systemctl --user -M "$U@" stop probe-1395.service probe-1395t.timer >/dev/null 2>&1
  timeout 10 systemctl --user -M "$U@" reset-failed >/dev/null 2>&1
  as_slot systemd-run --user --quiet --unit=probe-1395 sleep 600 >>"$HOOKLOG" 2>&1
  as_slot systemd-run --user --quiet --unit=probe-1395t --on-active=1h true >>"$HOOKLOG" 2>&1
  for _ in $(seq 1 50); do
    unit_live probe-1395.service && unit_live probe-1395t.timer && break
    sleep 0.1
  done
}
settle() { sleep 0.5; } # the manager notices an emptied cgroup asynchronously
user_manager_up() { systemctl is-active --quiet "user@$SUID.service" && unit_live dbus.service && test -S "$UBUS"; }

seed_units
check "the job's service is running before the reset" unit_live probe-1395.service
check "the job's timer is armed before the reset"     unit_live probe-1395t.timer

# HELD first: a slot a live run holds keeps everything, exactly as before.
printf 'run=4242\nslot=%s\nttl=600\nexpiry=%s\nreserve=0\nboot=%s\n' "$IDX" \
  "$(( $(date +%s) + 600 ))" "$(cat /proc/sys/kernel/random/boot_id)" >"$PIN_DIR/host"
reset_once "$RESET"
settle
check "a held slot keeps the job's service"            unit_live probe-1395.service
check "a held slot keeps the job's timer"              unit_live probe-1395t.timer
rm -f -- "$PIN_DIR/host"

rm -f -- "$MARKER"
reset_once "$RESET"
settle
check "the reset succeeds with the job's units to stop" test "$rc" = 0
check "and says what it stopped"                       grep -q 'unit(s) the last job left in its service manager' "$RUNLOG"
check_not "the job's service does not survive"         unit_live probe-1395.service
check_not "the job's timer does not survive"           unit_live probe-1395t.timer
check "the user manager and its bus survive"           user_manager_up
check "and the marker means it"                        test -f "$MARKER"

# Each half broken back, and the assertion it backs notices.
#
# Without the unit stop the timer -- which has no process to kill -- survives,
# while the service's process is still reached by the kill loop: that is the
# narrowed spare doing its half.
# shellcheck disable=SC2016  # the rendered hook's literal $uid
sed '/^  stop_user_units "\$uid" || units_rc=1$/d' "$RESET" >"$MUTANT"
chmod 0755 "$MUTANT"
check_not "the unit-stop mutation applied" cmp -s "$RESET" "$MUTANT"
seed_units
check "seeded for the unit-stop mutant"                unit_live probe-1395.service
reset_once "$MUTANT"
settle
check "without the unit stop the job's timer survives -- so the check is live" unit_live probe-1395t.timer
check_not "and the narrowed spare still reaches the service's process" unit_live probe-1395.service
reset_once "$RESET"

# ...and with the whole user@ tree spared again as well, the service survives
# too -- so the narrowing is what reached it above.
# shellcheck disable=SC2016  # the rendered hook's literal regex
sed '/^  stop_user_units "\$uid" || units_rc=1$/d; s#grep -qE "^0::/system#grep -qE "user@[0-9]*\\.service|^0::/system#' "$RESET" >"$MUTANT"
check_not "the spare-widening mutation applied" cmp -s "$RESET" "$MUTANT"
seed_units
check "seeded for the spare-widening mutant"           unit_live probe-1395.service
reset_once "$MUTANT"
settle
check "with the whole tree spared the job's service survives -- so the check is live" unit_live probe-1395.service
reset_once "$RESET"
settle
check_not "and the real reset still takes it"          unit_live probe-1395.service

# A HELPER THE BUS FORKS (#1395 R1). Classic D-Bus activation -- a service file
# in the job's own home with no SystemdService= -- makes dbus-daemon fork the
# job's program into dbus.service's cgroup, with no cgroup write by the job.
# Only the bus daemon itself is spared, by pid.
ACT_DIR="$HOME_DIR/.local/share/dbus-1/services"
install -d -o "$U" -g "$U" "$HOME_DIR/.local" "$HOME_DIR/.local/share" "$HOME_DIR/.local/share/dbus-1" "$ACT_DIR"
printf '[D-BUS Service]\nName=org.probe1395\nExec=/bin/sleep 600\n' >"$ACT_DIR/org.probe1395.service"
chown "$U:$U" "$ACT_DIR/org.probe1395.service"
bus_pid() { timeout 10 systemctl --user -M "$U@" show -p MainPID --value dbus.service 2>/dev/null; }
helper_alive() { pgrep -u "$U" -f '^/bin/sleep 600$' >/dev/null 2>&1; }
as_slot timeout 5 dbus-send --session --print-reply --dest=org.probe1395 / org.freedesktop.DBus.Peer.Ping >>"$HOOKLOG" 2>&1
for _ in $(seq 1 30); do helper_alive && break; sleep 0.1; done
check "the bus forked the job's activated helper"      helper_alive
bus_before=$(bus_pid)
reset_once "$RESET"
settle
check_not "the activated helper does not survive"      helper_alive
check "the bus daemon itself does"                     test "$(bus_pid)" = "$bus_before"
rm -rf -- "$HOME_DIR/.local"

# A UNIT THAT WILL NOT STOP fails the slot closed (R4). A timer, so the kill
# loop has no process to fail on and the verdict is the unit stop's alone.
as_slot systemd-run --user --quiet --unit=probe-1395r --on-active=1h \
  --timer-property=RefuseManualStop=yes true >>"$HOOKLOG" 2>&1
check "the unstoppable timer is armed"                 unit_live probe-1395r.timer
rm -f -- "$MARKER"
reset_once "$RESET"
check "a unit that will not stop fails the reset"      test "$rc" != 0
check "and says so"                                    grep -q 'would not stop' "$RUNLOG"
check "and the slot is not marked clean"               test ! -f "$MARKER"
# shellcheck disable=SC2016  # the rendered hook's literal text
sed '/would not stop: /{n;s/^  return 1$/  return 0/}' "$RESET" >"$MUTANT"
check_not "the fail-closed mutation applied" cmp -s "$RESET" "$MUTANT"
check "the unstoppable timer is still armed for the mutant" unit_live probe-1395r.timer
rm -f -- "$MARKER"
reset_once "$MUTANT"
check "without the final return 1 the unstoppable unit earns the marker -- so the check is live" test -f "$MARKER"

loginctl disable-linger "$U" >>"$HOOKLOG" 2>&1
systemctl stop "user@$SUID.service" >>"$HOOKLOG" 2>&1
made_linger=0

# --- the sweep ----------------------------------------------------------------
#
# Everything above is the reset in isolation. The sweep is what decides WHEN it
# runs, and the property that matters is the one it was written for: a slot left
# dirty by a job that never completed comes back without a job being spent on it.

echo
echo "sweep: a clean slot"
seed_work
"$RESET" completed "$IDX" >>"$HOOKLOG" 2>&1
printf '%s\n' 1 >"$SINCE"
"$SWEEP" >>"$HOOKLOG" 2>&1
check "a clean slot is left alone"                test -f "$MARKER"
check "and its dirty clock is cleared"            test ! -f "$SINCE"

echo
echo "sweep: a dirty slot, first sight"
seed_work
rm -f -- "$MARKER"
"$SWEEP" >>"$HOOKLOG" 2>&1
check "the first tick does not act"               test ! -f "$MARKER"
check "the first tick starts the clock"           test -f "$SINCE"
check "the slot is left as it was"                test -f "$WORK/_actions/action.yml"

echo
echo "sweep: a dirty slot, still dirty a grace later"
printf '%s\n' 1 >"$SINCE"
"$SWEEP" >>"$HOOKLOG" 2>&1
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
"$SWEEP" >>"$HOOKLOG" 2>&1
check "a slot with a worker on it is not reset"   test -f "$WORK/_actions/action.yml"
check "and it is not marked clean underneath one" test ! -f "$MARKER"
check "and its clock is reset, not advanced"      test ! -f "$SINCE"
kill "$worker" >/dev/null 2>&1
wait "$worker" >/dev/null 2>&1

# --- the burn count, and condemnation -----------------------------------------
#
# Everything above is about a slot that comes back. #278 is the slot that does
# not: on 2026-08-23 twelve of IntegrateIT's twenty-four could not reach a clean
# state, so the started hook refused every job routed to them -- in about six
# seconds each, which is faster than a healthy slot finishes anything. Failing
# quickly is how they kept WINNING the race for queued work, and the repository
# saw a pool of twenty-four runners burn its queue down without running it.
#
# The count is the whole mechanism, so it is asserted as arithmetic rather than
# as a log line: what increments it, what clears it, and who is allowed to write
# it. It lives beside the clean marker under root-owned state precisely because
# the subject of the measurement is the slot.
BURNS="$SLOT_STATE/$IDX/burns"
CONDEMNED="$SLOT_STATE/$IDX/condemned"

echo
echo "burns: what a slot has cost"
seed_work
rm -f -- "$MARKER" "$BURNS"
in_workspace started
check "a job refused on a dirty slot is counted"  grep -qx 1 "$BURNS"
in_workspace completed
check "and reaching a clean state clears the debt" test ! -e "$BURNS"
check "which is the point of clearing it"          test -f "$MARKER"

# A count that is a lifetime total condemns every slot on a long-lived host
# eventually, whatever its health, so the two directions are asserted together.
seed_work
rm -f -- "$MARKER"
in_workspace started
in_workspace completed
seed_work
rm -f -- "$MARKER"
in_workspace started
check "the count is consecutive, not cumulative"   grep -qx 1 "$BURNS"

echo
echo "burns: who may write the count"
#
# The slot user owns its home and the parent of _work, and is the account a job
# runs as. If it could reach this file it could zero its own record between
# failures and never be condemned at all.
if sudo -u "$U" sh -c ": >'$BURNS'" 2>/dev/null; then
  bad "a slot cannot rewrite its own count"
else
  ok "a slot cannot rewrite its own count"
fi
check "and the count survived the attempt"         grep -qx 1 "$BURNS"

echo
echo "condemnation: a slot whose reset can never finish"
#
# An obstruction the reset genuinely cannot clear. The symlinked _work above is
# the one the refusal path already covers, so it is reused here for a different
# purpose: it makes `completed` fail deterministically, tick after tick, which
# is the shape of every fault this counts.
in_workspace completed >/dev/null 2>&1
rm -rf -- "$WORK"
sudo -u "$U" ln -s /tmp "$WORK"
rm -f -- "$MARKER" "$BURNS" "$CONDEMNED"
printf '%s\n' 1 >"$SINCE"

"$SWEEP" >>"$HOOKLOG" 2>&1
check "one failed sweep condemns nothing"          test ! -e "$CONDEMNED"
check "and the sweep's own failure is counted"     grep -qx 1 "$BURNS"
check "and the clock is left alone, so it retries" test -f "$SINCE"

"$SWEEP" >>"$HOOKLOG" 2>&1
check "two is still within the allowance"          test ! -e "$CONDEMNED"

"$SWEEP" >>"$HOOKLOG" 2>&1
check "three takes the slot out of service"        test -f "$CONDEMNED"
check "and the symlink target is still untouched"  test -d /tmp

echo
echo "condemnation: and the way back"
#
# Condemned is not disabled and not deleted. The sweep goes on trying the reset,
# so a slot whose obstruction clears -- a wedged container finally reaped, a
# disk that came back -- returns without anyone being paged.
rm -f -- "$WORK"
seed_work
"$SWEEP" >>"$HOOKLOG" 2>&1
check "a slot that reaches a clean state is clean" test -f "$MARKER"
check "and it is put back into service"            test ! -e "$CONDEMNED"
check "and it owes nothing"                        test ! -e "$BURNS"
check "and its clock is cleared"                   test ! -f "$SINCE"

# --- the pin hold's guest attribute (#1393) ------------------------------------
#
# ci-pin-hold publishes the hold to a guest attribute as best effort, and on a
# host that never wrote ci/ a lost PUT reads to the controller as a FREE host
# (#1384). The sweep is what republishes it. That is a property of two scripts
# and a metadata server taking turns, so it is run, not grepped.
#
# THE METADATA SERVER IS A STUB, and it has to be. This suite runs on a real
# pool host, and a PUT that reached the real server would publish a fake hold on
# the CI runner running it -- which the controller would then honour.
PIN_STUB="$SB/metadata-stub"
install -d -m 0755 "$PIN_STUB"
export STUB_ATTR="$SB/pin-attr" STUB_PUTS="$SB/pin-puts" STUB_REFUSE="$SB/pin-refuse"
cat >"$PIN_STUB/curl" <<'STUB'
#!/usr/bin/env bash
# Answers ONLY the pin-hold attribute; anything else reads as unreachable.
put=0; data=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) [ "$2" = PUT ] && put=1; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -H | --connect-timeout | --max-time) shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in */instance/guest-attributes/ci/pin-hold) ;; *) exit 7 ;; esac
if [ "$put" = 1 ]; then
  printf '%s\n' "$data" >>"$STUB_PUTS"
  [ -e "$STUB_REFUSE" ] && exit 22
  printf '%s' "$data" >"$STUB_ATTR"
  exit 0
fi
[ -f "$STUB_ATTR" ] || exit 22
cat "$STUB_ATTR"
STUB
chmod 0755 "$PIN_STUB/curl"

# Bound for the expansion under `set -u`, as SLOT_USER_PREFIX is above.
# shellcheck disable=SC2034
PIN_DEFAULT_TTL=1800
# shellcheck disable=SC2034
PIN_MAX_TTL=7200
# shellcheck disable=SC2034
HOST_LABEL=host-lifecycle-test

PINHOLD="$SB/pin-hold.sh"
PINSWEEP="$SB/pin-sweep.sh"
: >"$NOISE"
expand_into "$PINHOLD" "$(body_of 'cat >/opt/ci/job-hooks/pin-hold\.sh <<EOF')" || {
  echo "FAIL: the pin-hold here-document did not expand"
  exit 1
}
expand_into "$PINSWEEP" "$(body_of 'cat >/opt/ci/job-hooks/pin-sweep\.sh <<EOF')" || {
  echo "FAIL: the pin-sweep here-document did not expand"
  exit 1
}
chmod 0755 "$PINHOLD" "$PINSWEEP"

HOLD="$PIN_DIR/host"
SWEEPOUT="$SB/pin-sweep-output"
BOOT=$(cat /proc/sys/kernel/random/boot_id)

run_pin_sweep() { # [script] — one tick, against the stub, output kept
  : >"$SWEEPOUT"
  PATH="$PIN_STUB:$PATH" "${1:-$PINSWEEP}" >>"$SWEEPOUT" 2>&1
  cat "$SWEEPOUT" >>"$HOOKLOG"
}
write_hold() { # <expiry> — a plain (non-reserving) hold, as ci-pin-hold writes one
  printf 'run=4242\nslot=%s\nttl=600\nexpiry=%s\nreserve=0\nboot=%s\n' "$IDX" "$1" "$BOOT" >"$HOLD"
}
hold_expiry() { sed -n 's/^expiry=//p' "$HOLD"; }
attr_is() { [ -f "$STUB_ATTR" ] && [ "$(cat "$STUB_ATTR")" = "$1" ]; }
puts() { if [ -f "$STUB_PUTS" ]; then wc -l <"$STUB_PUTS"; else echo 0; fi; }
mutant() { # <dest> <sed-program> — true only when the program changed something
  sed "$2" "$PINSWEEP" >"$1" && chmod 0755 "$1" && ! cmp -s "$PINSWEEP" "$1"
}

echo
echo "pin hold: the sweep republishes a hold the first PUT lost (#1393)"
check "the hold script parses"                  bash -n "$PINHOLD"
check "the sweep script parses"                 bash -n "$PINSWEEP"
check "and expanding them executed nothing"     test ! -s "$NOISE"

rm -f -- "$HOLD" "$STUB_ATTR" "$STUB_PUTS"
: >"$STUB_REFUSE"
SUDO_UID=$(id -u "$U") PATH="$PIN_STUB:$PATH" "$PINHOLD" --run 4242 --ttl 10m >"$SB/pin-out" 2>>"$HOOKLOG"
check "the hold is granted while the metadata server refuses writes" grep -qx 'pinned=1' "$SB/pin-out"
check "and the record is on disk"               test -f "$HOLD"
check "and the PUT was tried"                   test "$(puts)" = 1
check "and lost -- nothing is published"        test ! -e "$STUB_ATTR"
WANT="4242 $(hold_expiry)"

run_pin_sweep
check "a sweep that is also refused says so"    grep -q 'could not publish' "$SWEEPOUT"
check "and leaves the record alone"             test -f "$HOLD"

rm -f -- "$STUB_REFUSE"
run_pin_sweep
check "the next sweep publishes the live hold"  attr_is "$WANT"

n=$(puts)
run_pin_sweep
check "a confirmed hold costs no write"         test "$(puts)" = "$n"

printf 'something else' >"$STUB_ATTR"
run_pin_sweep
check "a published value that drifted is rewritten" attr_is "$WANT"

echo
echo "pin hold: an expired hold is released, never republished"
write_hold "$(( $(date +%s) - 5 ))"
printf '%s' "4242 $(hold_expiry)" >"$STUB_ATTR"
rm -f -- "$STUB_PUTS"
run_pin_sweep
check_not "the expired hold is not republished" grep -q '^4242 ' "$STUB_PUTS"
check "its attribute is cleared"                attr_is ""
check "and the record is gone"                  test ! -e "$HOLD"
run_pin_sweep
check "nothing is published once it is released" test "$(puts)" = 1

echo
echo "pin hold: each assertion above fails against the bug it names"
#
# The same discipline as the structural suite's mutate(): break the sweep the
# way #1393 describes, run the scenario again, and require the assertion to see
# it. A mutation that applies to nothing is itself a failure.
M="$SB/pin-sweep.mutant"

# The sed pattern matches the literal $vars in the script under test.
# shellcheck disable=SC2016
if mutant "$M" 's@|| publish "\$want"@|| :@'; then
  write_hold "$(( $(date +%s) + 600 ))"; rm -f -- "$STUB_ATTR" "$STUB_REFUSE"
  run_pin_sweep "$M"
  check_not "without the republish, a lost hold stays lost -- so the check is live" attr_is "4242 $(hold_expiry)"
else bad "mutation did not apply: the live republish"; fi

# The sed pattern matches the literal $vars in the script under test.
# shellcheck disable=SC2016
if mutant "$M" 's@\[ "\$have" = "\$want" \] || publish@publish@'; then
  write_hold "$(( $(date +%s) + 600 ))"; rm -f -- "$STUB_REFUSE"
  printf '%s' "4242 $(hold_expiry)" >"$STUB_ATTR"
  n=$(puts); run_pin_sweep "$M"
  check_not "an unconditional publish writes a confirmed hold -- so the check is live" test "$(puts)" = "$n"
else bad "mutation did not apply: the read-back"; fi

# The sed pattern matches the literal $vars in the script under test.
# shellcheck disable=SC2016
if mutant "$M" 's@if \[ "\$expiry" -gt "\$now" \]; then@if true; then@'; then
  write_hold "$(( $(date +%s) - 5 ))"; rm -f -- "$STUB_PUTS" "$STUB_ATTR" "$STUB_REFUSE"
  run_pin_sweep "$M"
  check "a sweep that treats expired as live republishes it -- so the check is live" grep -q '^4242 ' "$STUB_PUTS"
else bad "mutation did not apply: the expiry test"; fi

if mutant "$M" 's@>/dev/null 2>&1 || { say "could not publish@>/dev/null 2>\&1 || true || { say "could not publish@'; then
  write_hold "$(( $(date +%s) + 600 ))"; rm -f -- "$STUB_ATTR"; : >"$STUB_REFUSE"
  run_pin_sweep "$M"
  check_not "a swallowed refusal says nothing -- so the check is live" grep -q 'could not publish' "$SWEEPOUT"
else bad "mutation did not apply: the refusal message"; fi

rm -f -- "$HOLD" "$STUB_REFUSE"

if [ "$FAIL" -gt 0 ] && [ -s "$HOOKLOG" ]; then
  echo
  echo "what the hooks said:"
  sed 's/^/  /' "$HOOKLOG"
fi

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
