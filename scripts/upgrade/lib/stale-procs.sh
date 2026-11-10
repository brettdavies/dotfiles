# shellcheck shell=bash
# Processes still running a Homebrew binary that the upgrade removed. `brew upgrade` and `brew cleanup` delete the kegs
# they replace while processes keep running the old executable, which /proc then names with a " (deleted)" suffix.
# Each long-running systemd user service among them is restarted onto the upgrade. The rest are reported and left
# running: restarting a oneshot or a transient unit (systemd-run) would rerun its command, the job's own unit is the one
# running this code, a unit whose Type systemd does not report is not known to be long-running, and a process in a
# session scope (tmux, an editor) is the user's to restart. The scan runs as the user, so another user's processes,
# system services among them, are not seen at all. Linux only.
#
# Logs one output event per unit and executable through run-log.sh's run_log_note, and sets RUN_STALE to the JSON
# array run.end carries as stale_processes: [{unit, exe, pids, action (restarted | restart-failed | left-running)}].

# Prints "<kind><TAB><unit>" for a cgroup v2 file, where kind is user-service for a service of the user manager and
# other for anything else. The unit is never empty: read with IFS set to a tab would merge the two tabs around an empty
# field and shift every later field.
_stale_procs_unit() { # <cgroup-file>
  local path unit
  path=$(sed -n 's/^0:://p' "$1" 2>/dev/null)
  unit=${path##*/}
  case $path in
    */user@*.service/*.service) printf 'user-service\t%s' "$unit" ;;
    *) printf 'other\t%s' "${unit:-unknown}" ;;
  esac
}

# Succeeds for a unit a restart moves onto the upgrade without rerunning a one-off command.
_stale_procs_restartable() { # <unit>
  [ "$(systemctl --user show -p Transient --value "$1" 2>/dev/null)" != yes ] || return 1
  case $(systemctl --user show -p Type --value "$1" 2>/dev/null) in
    simple | exec | forking | notify | notify-reload | dbus | idle) return 0 ;;
  esac
  return 1
}

# Restarts the unit and succeeds only if the restart held. A simple service reports a successful start as soon as it
# forks, so try-restart exits 0 even when the new binary dies at once. The unit has to be active 3 s later on the same
# InvocationID, which systemd's own restarts change; NRestarts would not do, since a manual restart resets it. The 3 s
# is from a transient user service that exits on restart: try-restart returned 0, and within 3 s NRestarts went from 0
# to 2. A binary that fails after that window still reads as restarted.
_stale_procs_restart_holds() { # <unit>
  local invocation
  systemctl --user try-restart "$1" 2>/dev/null || return 1
  invocation=$(systemctl --user show -p InvocationID --value "$1" 2>/dev/null)
  sleep 3
  systemctl --user is-active --quiet "$1" 2>/dev/null \
    && [ "$(systemctl --user show -p InvocationID --value "$1" 2>/dev/null)" = "$invocation" ]
}

# Restarts or reports one unit's processes on one removed executable, appending its entry to the caller's items. A
# unit already settled for another executable keeps the action recorded in the caller's settled list, so a service on
# two removed executables restarts once.
_stale_procs_settle() { # <own-unit> <kind> <unit> <exe> <pids>
  local action=left-running unit=$3 recorded
  case $settled in
    *"|$unit="*)
      recorded=${settled#*"|$unit="}
      action=${recorded%%|*}
      ;;
    *)
      if [ "$2" = user-service ] && [ "$3" != "$1" ] && _stale_procs_restartable "$3"; then
        if _stale_procs_restart_holds "$3"; then action=restarted; else action=restart-failed; fi
      fi
      settled+="$unit=$action|"
      ;;
  esac
  case $action in
    restarted) run_log_note info "restarted $unit, which was running the removed $4" ;;
    restart-failed) run_log_note warning "Warning: restarting $unit onto the upgrade failed or did not stay up; check systemctl --user status $unit" ;;
    *) run_log_note warning "Warning: $unit (pid ${5//,/ }) still runs the removed $4; restart it to load the upgrade" ;;
  esac
  items+="${items:+,}{\"unit\":$(_run_log_str "$unit"),\"exe\":$(_run_log_str "$4"),\"pids\":[$5],\"action\":\"$action\"}"
}

# Succeeds unless the job runs in a nested user namespace, which PrivateTmp= and every other namespace directive give
# a user unit. There the kernel refuses the executable link of every process outside the namespace, so the scan would
# find nothing and claim nothing is stale. Only the initial namespace maps the whole uid range onto itself. Reading
# another process's link is no probe: one holding a capability the job lacks (the user manager, the job's parent,
# holds CAP_WAKE_ALARM) or one that is not dumpable refuses it from any namespace.
_stale_procs_can_see() { # <proc-root>
  local inside outside count
  read -r inside outside count 2>/dev/null <"$1/self/uid_map" || return 0
  [ "$inside $outside $count" = "0 0 4294967295" ]
}

# Usage: stale_procs_restart <proc-root> <prefix>
stale_procs_restart() {
  local own items='' settled='|' group='' g_kind='' g_unit='' g_exe='' pids='' kind unit exe pid
  if ! _stale_procs_can_see "$1"; then
    run_log_note warning "Warning: the job runs in a user namespace, which hides every process outside it, so stale processes are not checked; remove PrivateTmp= and any other namespace directive from its unit"
    return 0
  fi
  own=$(_stale_procs_unit "$1/self/cgroup" | cut -f2)
  while IFS=$'\t' read -r kind unit exe pid; do
    if [ "$kind/$unit/$exe" != "$group" ]; then
      [ -z "$group" ] || _stale_procs_settle "$own" "$g_kind" "$g_unit" "$g_exe" "$pids"
      group="$kind/$unit/$exe" g_kind=$kind g_unit=$unit g_exe=$exe pids=''
    fi
    pids+="${pids:+,}$pid"
  done < <(
    find "$1" -mindepth 2 -maxdepth 2 -name exe -lname "$2/* (deleted)" -printf '%h\t%l\n' 2>/dev/null \
      | while IFS=$'\t' read -r dir exe; do
        printf '%s\t%s\t%s\n' "$(_stale_procs_unit "$dir/cgroup")" "${exe% (deleted)}" "${dir##*/}"
      done | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4n
  )
  [ -z "$group" ] || _stale_procs_settle "$own" "$g_kind" "$g_unit" "$g_exe" "$pids"
  # shellcheck disable=SC2034 # run-log.sh writes it into run.end
  RUN_STALE="[$items]"
}
