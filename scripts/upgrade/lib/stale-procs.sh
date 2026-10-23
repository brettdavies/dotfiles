# shellcheck shell=bash
# Processes still running a Homebrew binary that the upgrade removed. `brew upgrade` and `brew cleanup` delete the kegs
# they replace while processes keep running the old executable, which /proc then names with a " (deleted)" suffix.
# Each long-running systemd user service among them is restarted onto the upgrade. The rest are reported and left
# running: restarting a oneshot would rerun its job, the job's own unit is the one running this code, a system service
# needs root, and a process in a session scope (tmux, an editor) is the user's to restart. Linux only.
#
# Logs one output event per unit and executable through run-log.sh's run_log_note, and sets RUN_STALE to the JSON
# array run.end carries as stale_processes: [{unit, exe, pids, action (restarted | restart-failed | left-running)}].

# Prints "<kind><TAB><unit>" for a cgroup v2 file, where kind is user-service for a service of the user manager and
# other for anything else.
_stale_procs_unit() { # <cgroup-file>
  local path
  path=$(sed -n 's/^0:://p' "$1" 2>/dev/null)
  case $path in
    */user@*.service/*.service) printf 'user-service\t%s' "${path##*/}" ;;
    *) printf 'other\t%s' "${path##*/}" ;;
  esac
}

# Restarts or reports one unit's processes, appending its entry to the caller's items.
_stale_procs_settle() { # <kind> <unit> <exe> <pids>
  local action=left-running unit=${2:-unknown}
  if [ "$1" = user-service ] && [ "$2" != "$own" ] \
    && [ "$(systemctl --user show -p Type --value "$2" 2>/dev/null)" != oneshot ]; then
    if systemctl --user try-restart "$2" 2>/dev/null; then action=restarted; else action=restart-failed; fi
  fi
  case $action in
    restarted) run_log_note info "restarted $unit, which was running the removed $3" ;;
    restart-failed) run_log_note warning "Warning: restarting $unit failed; it still runs the removed $3" ;;
    *) run_log_note warning "Warning: $unit (pid ${4//,/ }) still runs the removed $3; restart it to load the upgrade" ;;
  esac
  items+="${items:+,}{\"unit\":$(_run_log_str "$unit"),\"exe\":$(_run_log_str "$3"),\"pids\":[$4],\"action\":\"$action\"}"
}

# Usage: stale_procs_restart <proc-root> <prefix>
stale_procs_restart() {
  local own items='' group='' g_kind='' g_unit='' g_exe='' pids='' kind unit exe pid
  own=$(_stale_procs_unit "$1/self/cgroup" | cut -f2)
  while IFS=$'\t' read -r kind unit exe pid; do
    if [ "$kind/$unit/$exe" != "$group" ]; then
      [ -z "$group" ] || _stale_procs_settle "$g_kind" "$g_unit" "$g_exe" "$pids"
      group="$kind/$unit/$exe" g_kind=$kind g_unit=$unit g_exe=$exe pids=''
    fi
    pids+="${pids:+,}$pid"
  done < <(
    find "$1" -mindepth 2 -maxdepth 2 -name exe -lname "$2/* (deleted)" -printf '%h\t%l\n' 2>/dev/null \
      | while IFS=$'\t' read -r dir exe; do
        printf '%s\t%s\t%s\n' "$(_stale_procs_unit "$dir/cgroup")" "${exe% (deleted)}" "${dir##*/}"
      done | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4n
  )
  [ -z "$group" ] || _stale_procs_settle "$g_kind" "$g_unit" "$g_exe" "$pids"
  # shellcheck disable=SC2034 # run-log.sh writes it into run.end
  RUN_STALE="[$items]"
}
