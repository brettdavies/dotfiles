# shellcheck shell=bash
# Processes still running a Homebrew binary that the upgrade removed. `brew upgrade` and `brew cleanup` delete the kegs
# they replace while processes keep running the old executable, which /proc then names with a " (deleted)" suffix.
# Each long-running systemd user service among them is restarted onto the upgrade, and counts as restarted only if it
# is still active UPGRADE_RESTART_SETTLE_SECS (default 3) later: a simple service reports a successful start as soon as
# it forks, even when the new binary dies at once. The rest are reported, as info lines, and left running: restarting a oneshot would rerun its job, the job's own unit is the one running this code, a unit whose
# Type systemd does not report is not known to be long-running, and a process in a session scope (tmux, an editor) is
# the user's to restart. The scan runs as the user, so another user's processes, system services among them, are not
# seen at all. Linux only.
#
# Logs one output event per unit and executable through run-log.sh's run_log_note; only a failed restart is a warning.
# RUN_STALE holds the JSON array run.end carries as stale_processes, [{unit, exe, pids, action (restarted |
# restart-failed | left-running)}], and is updated after each entry, so a run killed partway still reports the units it
# had settled.

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
      if [ "$2" = user-service ] && [ "$3" != "$1" ]; then
        case $(systemctl --user show -p Type --value "$3" 2>/dev/null) in
          simple | exec | forking | notify | notify-reload | dbus | idle)
            action=restart-failed
            if systemctl --user try-restart "$3" 2>/dev/null; then
              sleep "${UPGRADE_RESTART_SETTLE_SECS:-3}"
              if systemctl --user is-active --quiet "$3"; then action=restarted; fi
            fi
            ;;
        esac
      fi
      settled+="$unit=$action|"
      ;;
  esac
  case $action in
    restarted) run_log_note info "restarted $unit, which was running the removed $4" ;;
    restart-failed) run_log_note warning "Warning: restarting $unit onto the upgrade failed; check systemctl --user status $unit" ;;
    *) run_log_note info "$unit (pid ${5//,/ }) still runs the removed $4; restart it to load the upgrade" ;;
  esac
  items+="${items:+,}{\"unit\":$(_run_log_str "$unit"),\"exe\":$(_run_log_str "$4"),\"pids\":[$5],\"action\":\"$action\"}"
  # shellcheck disable=SC2034 # run-log.sh writes it into run.end
  RUN_STALE="[$items]"
}

# Usage: stale_procs_restart <proc-root> <prefix>
stale_procs_restart() {
  local own items='' settled='|' group='' g_kind='' g_unit='' g_exe='' pids='' kind unit exe pid
  # Inside a user namespace (which PrivateTmp= gives a user unit) every process outside it reads as blank, so a scan
  # that cannot read its own parent would find nothing and claim nothing is stale.
  if [ -e "$1/$PPID" ] && ! readlink "$1/$PPID/exe" >/dev/null 2>&1; then
    run_log_note warning "Warning: cannot read the executable of the job's parent (pid $PPID), so stale processes are not checked; a user unit with PrivateTmp= runs in a user namespace that hides them"
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
