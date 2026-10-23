# shellcheck shell=bash
# Processes still running a Homebrew binary that the upgrade removed. `brew upgrade` and `brew cleanup` delete the kegs
# they replace while processes keep running the old executable, which /proc then names with a " (deleted)" suffix.
# Each long-running systemd user service among them is restarted onto the upgrade. A simple service reports a
# successful start as soon as it forks, even when the new binary dies at once, so a restart counts only if the unit is
# still active UPGRADE_RESTART_SETTLE_SECS (default 3) later and systemd has not restarted it on its own meanwhile
# (NRestarts unchanged). A binary that fails after that window still reads as restarted.
#
# The rest are left running and reported on info lines: restarting a oneshot or a transient unit (systemd-run) would
# rerun its job, the job's own unit is the one running this code, a unit whose Type systemd does not report is not
# known to be long-running, and a process in a session scope (tmux, an editor) is the user's to restart. The scan runs
# as the user, so another user's processes, system services among them, are not seen at all. Linux only.
#
# Warnings are kept for what failed: a restart that did not hold, a user manager that could not be reached, and a scan
# that could not see other processes. RUN_STALE holds the JSON array run.end carries as stale_processes, [{unit, exe,
# pids, action (restarted | restart-failed | left-running)}]. It is updated after each entry, and an entry is recorded
# as restart-failed before its restart is tried, so a run killed partway still reports every unit it reached.

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

_stale_procs_entry() { # <unit> <exe> <pids> <action>
  printf '{"unit":%s,"exe":%s,"pids":[%s],"action":"%s"}' "$(_run_log_str "$1")" "$(_run_log_str "$2")" "$3" "$4"
}

_stale_procs_prop() { # <name> <systemctl-show-output>
  printf '%s\n' "$2" | sed -n "s/^$1=//p"
}

# Restarts or reports one unit's processes on one removed executable, appending its entry to the caller's items and
# publishing them to RUN_STALE. A unit already settled for another executable keeps the action recorded in the caller's
# settled list, so a service on two removed executables restarts once.
_stale_procs_settle() { # <own-unit> <settle-secs> <kind> <unit> <exe> <pids>
  local action=left-running unit=$4 recorded props restarts
  local failure="restarting $unit onto the upgrade failed; check systemctl --user status $unit"
  case $settled in
    *"|$unit="*)
      recorded=${settled#*"|$unit="}
      action=${recorded%%|*}
      ;;
    *)
      if [ "$3" = user-service ] && [ "$4" != "$1" ]; then
        if ! props=$(systemctl --user show -p Type -p Transient -p NRestarts "$4" 2>/dev/null); then
          action=restart-failed failure="cannot reach the user manager to restart $unit; it still runs the removed $5"
        else
          case "$(_stale_procs_prop Transient "$props"):$(_stale_procs_prop Type "$props")" in
            no:simple | no:exec | no:forking | no:notify | no:notify-reload | no:dbus | no:idle)
              action=restart-failed
              restarts=$(_stale_procs_prop NRestarts "$props")
              RUN_STALE="[${items:+$items,}$(_stale_procs_entry "$unit" "$5" "$6" "$action")]"
              if systemctl --user try-restart "$4" 2>/dev/null; then
                sleep "$2"
                if systemctl --user is-active --quiet "$4" \
                  && [ "$(systemctl --user show -p NRestarts --value "$4" 2>/dev/null)" = "$restarts" ]; then
                  action=restarted
                fi
              fi
              ;;
          esac
        fi
      fi
      settled+="$unit=$action|"
      ;;
  esac
  case $action in
    restarted) run_log_note info "restarted $unit, which was running the removed $5" ;;
    restart-failed) run_log_note warning "Warning: $failure" ;;
    *) run_log_note info "$unit (pid ${6//,/ }) still runs the removed $5; restart it to load the upgrade" ;;
  esac
  items+="${items:+,}$(_stale_procs_entry "$unit" "$5" "$6" "$action")"
  # shellcheck disable=SC2034 # run-log.sh writes it into run.end
  RUN_STALE="[$items]"
}

# Usage: stale_procs_restart <proc-root> <prefix>
stale_procs_restart() {
  local own settle=${UPGRADE_RESTART_SETTLE_SECS:-3} items='' settled='|' group='' g_kind='' g_unit='' g_exe='' pids=''
  local kind unit exe pid
  # Inside a user namespace (which PrivateTmp= gives a user unit) every process outside it reads as blank, so a scan
  # that cannot read its own parent would find nothing and claim nothing is stale.
  if [ -e "$1/$PPID" ] && ! readlink "$1/$PPID/exe" >/dev/null 2>&1; then
    run_log_note warning "Warning: cannot read the executable of the job's parent (pid $PPID), so stale processes are not checked; a user unit with PrivateTmp= runs in a user namespace that hides them"
    return 0
  fi
  case $settle in
    *[!0-9]*)
      run_log_note warning "Warning: UPGRADE_RESTART_SETTLE_SECS=$settle is not a whole number of seconds; waiting 3 after each restart"
      settle=3
      ;;
  esac
  own=$(_stale_procs_unit "$1/self/cgroup" | cut -f2)
  while IFS=$'\t' read -r kind unit exe pid; do
    if [ "$kind/$unit/$exe" != "$group" ]; then
      [ -z "$group" ] || _stale_procs_settle "$own" "$settle" "$g_kind" "$g_unit" "$g_exe" "$pids"
      group="$kind/$unit/$exe" g_kind=$kind g_unit=$unit g_exe=$exe pids=''
    fi
    pids+="${pids:+,}$pid"
  done < <(
    find "$1" -mindepth 2 -maxdepth 2 -name exe -lname "$2/* (deleted)" -printf '%h\t%l\n' 2>/dev/null \
      | while IFS=$'\t' read -r dir exe; do
        printf '%s\t%s\t%s\n' "$(_stale_procs_unit "$dir/cgroup")" "${exe% (deleted)}" "${dir##*/}"
      done | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4n
  )
  [ -z "$group" ] || _stale_procs_settle "$own" "$settle" "$g_kind" "$g_unit" "$g_exe" "$pids"
  # shellcheck disable=SC2034 # run-log.sh writes it into run.end
  RUN_STALE="[$items]"
}
