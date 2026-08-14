# shellcheck shell=bash
# The watchdog's decision rule, as a pure function.
#
# WHY THIS IS ITS OWN FILE (2026-08-14)
#
# The watchdog compared ONE number: the age of the heartbeat file. That is
# correct while the loop is running and catastrophic once it is not, because the
# heartbeat is written at the END of a tick and the restart the watchdog issues
# starts that tick over:
#
#   heartbeat goes stale  ->  watchdog restarts the controller every 60s
#     ->  each restart kills the tick before it can finish  ->  heartbeat never
#     refreshes  ->  the watchdog restarts it again, forever.
#
# The controller then publishes NOTHING — not even ci_poller_heartbeat, whose
# whole purpose is to make a dead controller visible — because every series is
# queued during the tick and flushed at its end. Two of seven pools sat in this
# loop, both `active (running)`, both burning a full CPU-minute per minute, with
# `terraform apply` reporting success and the fleet dashboards showing an absent
# series that reads the same as "this project has no pool".
#
# The rule below adds the missing second number: how long the unit has been up.
# A controller that was just restarted is given a full threshold to prove itself
# regardless of how stale the heartbeat is — so a restart can never be the thing
# that prevents the heartbeat that would have stopped the restarting.
#
# Deliberately still dumb: two integers and a threshold, no state of its own.

# watchdog_verdict <hb_present:0|1> <hb_age_seconds> <service_uptime_seconds> <threshold>
#   -> restart | hold:<reason>
#
# hb_age is ignored when the file is absent; uptime is authoritative when the
# unit has just started. Callers pass -1 for an uptime they could not determine
# (unit inactive, systemd not answering), which is treated as "old enough to
# judge" — an unknown uptime must not disable the watchdog.
watchdog_verdict() {
  local present="$1" age="$2" uptime="$3" threshold="$4"

  # No heartbeat file at all = the loop has not completed its first tick since
  # the state directory was created. A normal boot, not a wedge.
  [ "$present" = "1" ] || { echo "hold:no-heartbeat-yet"; return; }

  # The grace that breaks the loop. A tick can legitimately outlast the poll
  # interval (a repo with many active runs walks one API call per run), so a
  # freshly started controller has NOT had the chance to write a heartbeat yet
  # and its stale file says nothing about the process now running.
  if [ "$uptime" -ge 0 ] && [ "$uptime" -lt "$threshold" ]; then
    echo "hold:restarted-${uptime}s-ago"
    return
  fi

  [ "$age" -ge "$threshold" ] && { echo restart; return; }
  echo "hold:fresh-${age}s"
}
