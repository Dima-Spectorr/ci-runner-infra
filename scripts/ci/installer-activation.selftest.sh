#!/usr/bin/env bash
# The controller installer must ACTIVATE what it just wrote.
#
# WHY THIS IS A GATE AND NOT A REVIEW NOTE
#
# The controller VM is long-lived and keeps its boot disk across a reset, so
# `/opt/ci-controller/controller.sh` from the PREVIOUS version is already on
# disk and `ci-controller.service` is already enabled. On boot systemd starts
# the OLD code; the startup script then overwrites the file. `systemctl enable
# --now` on an already-running unit is a NO-OP — so the new file is installed
# and the old process keeps serving the pool.
#
# That failure reports success everywhere it is looked for: `terraform apply`
# says applied, the file on disk hashes to the new version, the unit is
# `active (running)`. Only the behaviour is old. It is how v5.1.0 reached the
# IntegrateIT controller on 2026-08-14 — bounded curls and a heartbeat watchdog
# present in the file, absent from the running loop, and the watchdog inert
# because the old loop never wrote the heartbeat it keys on.
#
# So: every unit the controller installer writes must be restarted by it, not
# merely enabled. Host units are exempt — hosts are MIG instances that boot on a
# fresh disk, where `enable --now` starts the only version that exists.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$ROOT/modules/ci-runner-host-pool/scripts/controller-startup.sh"

fail=0
ok()  { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }

# Units the script writes to /etc/systemd/system, taken from the heredoc
# redirections rather than from a hand-kept list, so a unit added later is
# covered without editing this gate.
units_written() { # <file>
  grep -oE '>/etc/systemd/system/[A-Za-z0-9@._-]+' "$1" \
    | sed 's|.*/||' | sort -u
}

restarted() { # <file> <unit>
  grep -qE "systemctl[[:space:]]+restart[[:space:]]+$2([[:space:]]|$)" "$1"
}

echo "installer-activation self-test:"

# --- 0. selftest: prove the detectors fire ----------------------------------
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

cat >"$FIX/bad.sh" <<'BADEOF'
cat >/etc/systemd/system/x.service <<'EOF'
[Service]
ExecStart=/opt/x.sh
EOF
systemctl daemon-reload
systemctl enable --now x.service
BADEOF

cat >"$FIX/good.sh" <<'GOODEOF'
cat >/etc/systemd/system/x.service <<'EOF'
[Service]
ExecStart=/opt/x.sh
EOF
systemctl daemon-reload
systemctl enable x.service
systemctl restart x.service
GOODEOF

expect() { # <actual> <expected> <ok-msg> <bad-msg>
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$4"; fi
}

expect "$(units_written "$FIX/bad.sh")" "x.service" \
  "detector finds the unit an installer writes" \
  "detector found no unit in a file that writes one — every pass below is vacuous"

if restarted "$FIX/bad.sh" x.service; then
  bad "detector accepts 'enable --now' as activation — the case this gate exists for"
else
  ok "detector rejects 'enable --now' alone"
fi

if restarted "$FIX/good.sh" x.service; then
  ok "detector accepts an explicit restart"
else
  bad "detector rejects an explicit restart — it would be turned off, not fixed"
fi

[ "$fail" -eq 0 ] || { echo "  activation UNVERIFIABLE (detectors are broken)."; exit 1; }

# --- 1. the real installer ---------------------------------------------------
[ -f "$INSTALLER" ] || {
  bad "installer not found at ${INSTALLER#"$ROOT/"} — this gate would pass vacuously"
  exit 1
}

all_units=$(units_written "$INSTALLER")

found=0
while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  # A `.service` that a `.timer` activates is not started by the installer at
  # all — the timer is. Restarting the timer is what makes the NEXT activation
  # run the new file, and that activation reads the script fresh, so the
  # service carries no stale process to replace.
  case "$unit" in
    *.service)
      if printf '%s\n' "$all_units" | grep -cx "${unit%.service}.timer" >/dev/null; then
        ok "$unit is timer-activated (${unit%.service}.timer) — no resident process to replace"
        continue
      fi
      ;;
  esac
  found=$((found + 1))
  if restarted "$INSTALLER" "$unit"; then
    ok "$unit is restarted by the installer"
  else
    bad "$unit is written but never restarted — a rebooted controller keeps running the previous version while the new file sits on disk"
  fi
done <<<"$all_units"

if [ "$found" -eq 0 ]; then
  bad "no units found in ${INSTALLER#"$ROOT/"} — this gate would pass vacuously"
fi

if [ "$fail" -eq 0 ]; then
  echo "  every installed unit is activated by the installer that wrote it."
else
  echo "  INSTALLED-BUT-NOT-ACTIVATED — an apply can report success over old code."
fi
exit "$fail"
