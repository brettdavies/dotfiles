# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# doctor: the slot layer on the Linux server. It checks the rex CLI and the Rex server it answers for, the units that
# keep the layer running, rexurrect, the reconcile journal, and where the agent-slots tmux server runs, then adds
# agent-slot's own doctor.
#
# Each finding is an error object (contract_error_json) plus a severity and the host it is about. A missing
# prerequisite never stops the other checks. A Rex version that differs from scripts/agent-slot/verified-versions only
# warns. Exit 1 when any finding is an error.

DOCTOR_FINDINGS=()
DOCTOR_SLOT='{}'

# Usage: doctor_finding <error | warning> <reason> <message> [contract_error_json options]
doctor_finding() {
  local severity=$1
  shift
  DOCTOR_FINDINGS+=("$(contract_error_json "$@" \
    | contract_json -c --arg s "$severity" '. + {severity: $s, host: "server"}')")
}

# Usage: doctor_systemctl <systemctl args...>; systemctl, reaching the user manager from a shell that lacks its
# runtime directory too.
doctor_systemctl() {
  XDG_RUNTIME_DIR=$AR_RUNTIME_DIR timeout --kill-after=2 10 "$AR_SYSTEMCTL" "$@" </dev/null 2>/dev/null
}

# Usage: doctor_active [--user] <unit>
doctor_active() {
  local scope=()
  if [[ $1 == --user ]]; then
    scope=(--user)
    shift
  fi
  [[ $(doctor_systemctl "${scope[@]}" is-active "$1" || true) == active ]]
}

doctor_check_rex() {
  local version='' verified message
  if [[ -z $AR_REX ]]; then
    doctor_finding error dependency-missing "the rex CLI is not in REX_BIN_DIR or at any of: ${AR_REX_PATHS//:/, }" \
      --value "${REX_BIN_DIR:-}" --command "sudo apt-get install rex"
    return
  fi
  ! rex_version || version=$REX_OUT
  if rex_server_status; then
    doctor_check_server "$version"
  else
    doctor_finding error rex-server-down "no Rex server answers on this host ($(rex_error_line))" \
      --value "$AR_REX_UNIT" --command "systemctl --user start $AR_REX_UNIT"
  fi
  verified=$(awk '!/^[[:space:]]*#/ && $1 == "rex" { print $2 }' "$AR_VERIFIED" 2>/dev/null || true)
  [[ -n $version && $version != "$verified" ]] || return 0
  message="Rex $version differs from the version the two-machine checklist last ran on (${verified:-none});"
  message+=" run the checklist, then update scripts/agent-slot/verified-versions"
  doctor_finding warning version-unverified "$message" --value "$version"
}

# Usage: doctor_check_server <installed rex version>; the checks that need the running Rex server.
doctor_check_server() {
  local version=$1 unit_pid steps
  if ! rex_actions; then
    doctor_finding error rex-failed "rex actions --json exited non-zero, so the Rex server did not answer" \
      --value "$AR_REX" --command "rex --autostart=false actions --json"
  elif ! contract_json -e '[.actions[]?.name] | index("agent_slot_new") != null' <<<"$REX_OUT" >/dev/null; then
    doctor_finding error rex-action-unregistered \
      "Rex has not loaded agent-slots.lua: agent_slot_new is not among its actions" --value agent_slot_new \
      --command "cd ~/dotfiles && scripts/stow-deploy rex"
  fi
  if unit_pid=$(doctor_systemctl --user show -p MainPID --value "$AR_REX_UNIT") \
    && [[ $REX_SERVER_PID != "${unit_pid:-0}" ]]; then
    doctor_finding error rex-server-foreign "the Rex server on this host (pid $REX_SERVER_PID) is not the one \
$AR_REX_UNIT started (MainPID ${unit_pid:-0}), so the service cannot take the socket until that server stops" \
      --value "$REX_SERVER_PID" --action ask-operator \
      --command "$AR_REXURRECT save && rex --autostart=false server stop && systemctl --user restart $AR_REX_UNIT"
  fi
  if [[ -n $version && -n $REX_SERVER_VERSION && $version != "$REX_SERVER_VERSION" ]]; then
    steps="1) update Rex.app and the iOS app to at least $version, 2) $AR_REXURRECT save,"
    steps+=" 3) systemctl --user restart $AR_REX_UNIT, 4) rerun the two-machine checklist"
    doctor_finding warning rex-restart-pending "the installed rex is $version but the running Rex server is \
$REX_SERVER_VERSION; to move the server to it, in order: $steps" --value "$REX_SERVER_VERSION" --action ask-operator \
      --command "$AR_REXURRECT save && systemctl --user restart $AR_REX_UNIT"
  fi
  doctor_check_startup
}

# The start-up step records, for the server instance it ran in, whether rexurrect restored the operator's own tabs.
doctor_check_startup() {
  local outcome
  outcome=$(startup_record_outcome "$REX_SERVER_INSTANCE")
  case $outcome in
    stopped | skipped)
      doctor_finding warning own-tabs-unrestored "the start-up step did not restore the operator's own tabs into this \
Rex server (rexurrect: $outcome); a restart of the server runs it again" --value "$outcome" --action ask-operator \
        --command "systemctl --user restart $AR_REX_UNIT"
      ;;
  esac
}

doctor_check_units() {
  doctor_active --user "$AR_RECONCILE_TIMER" || doctor_finding error reconcile-timer-inactive "$AR_RECONCILE_TIMER is \
not running, so nothing corrects a slot tab that a missed launch or teardown left wrong" \
    --value "$AR_RECONCILE_TIMER" --command "systemctl --user enable --now $AR_RECONCILE_TIMER"
  doctor_active --user "$AR_TAB_NUMBERS_UNIT" || doctor_finding error tab-numbers-inactive "$AR_TAB_NUMBERS_UNIT is \
not running, so tabs carry no position number" \
    --value "$AR_TAB_NUMBERS_UNIT" --command "systemctl --user enable --now $AR_TAB_NUMBERS_UNIT"
  doctor_active "$AR_LOGIN_UNIT" || doctor_finding error login-server-inactive "$AR_LOGIN_UNIT is not running, so \
neither Rex.app nor the iOS app can reach this host's Rex server; scripts/rex-login-server-deploy.sh installs it" \
    --value "$AR_LOGIN_UNIT" --command "sudo systemctl enable --now $AR_LOGIN_UNIT"
}

doctor_check_rexurrect() {
  [[ -x $AR_REXURRECT ]] && return 0
  doctor_finding warning rexurrect-missing "rexurrect is not installed at $AR_REXURRECT, so the operator's own tabs \
do not come back after a Rex restart" --value "$AR_REXURRECT" --command "cd ~/dotfiles && scripts/rexurrect-deploy.sh"
}

# A running timer whose journal has no recent pass, or whose last three passes failed or found the reconcile lock
# held, is keeping no tab current: a busy pass journals ok, so a lock nobody releases would otherwise look healthy.
doctor_check_journal() {
  local log=$AR_STATE/reconcile.log verdict
  [[ -s $log ]] || return 0
  doctor_active --user "$AR_RECONCILE_TIMER" || return 0
  verdict=$(tail -n 3 "$log" | contract_json -s -r --argjson stale "$AR_RECONCILE_STALE" '
    (now - (.[-1].at | fromdateiso8601) | floor) as $age
    | if $age > $stale then "its newest pass ran \($age) s ago"
      elif length == 3 and all(.[]; .skipped == "reconcile-busy")
      then "its last 3 passes found the reconcile lock held"
      elif length == 3 and all(.[]; .ok == false or .skipped == "reconcile-busy")
      then "its last 3 passes failed, the newest with \(.[-1].error.reason // .[-1].skipped // "an error")"
      else empty end' || true)
  [[ -n $verdict ]] || return 0
  doctor_finding error reconcile-stale "$AR_RECONCILE_TIMER is running, but the reconcile journal shows no recent \
good pass: $verdict" --value "$log" --command "agent-slot-rex restore"
}

# The agent-slots tmux server dies with the unit whose cgroup holds it, so a service unit's is a hazard; a scope of its
# own or a login session's is not. One that runs and does not answer is reported as such; none running is no finding.
doctor_check_tmux() {
  local out pid unit status=0
  out=$(mktemp)
  timeout --kill-after=2 10 "$AR_TMUX" -L "$AR_TMUX_SOCKET" display-message -p '#{pid}' </dev/null >"$out" \
    2>/dev/null || status=$?
  pid=$(<"$out")
  rm -f "$out"
  if ((status == 124 || status == 137)); then
    doctor_finding error tmux-unresponsive "the $AR_TMUX_SOCKET tmux server did not answer within 10 s" \
      --value "$AR_TMUX_SOCKET" --command "$AR_TMUX -L $AR_TMUX_SOCKET list-sessions"
    return 0
  fi
  ((status == 0)) && [[ $pid =~ ^[0-9]+$ ]] || return 0
  unit=$("$AR_PS" -o cgroup= -p "$pid" 2>/dev/null | tail -1 || true)
  unit=${unit##*/}
  unit=${unit%%[[:space:]]*}
  [[ $unit == *.service ]] || return 0
  doctor_finding warning tmux-outside-scope "the agent-slots tmux server (pid $pid) runs in $unit's cgroup, so \
stopping or restarting $unit ends every agent; once no agent is working, tmux -L $AR_TMUX_SOCKET kill-server lets the \
next resume start it in a scope of its own" --value "$unit" --action ask-operator --command "agent-slot list"
}

doctor_check_tools() {
  local tool hint
  for tool in "$AR_TMUX" timeout; do
    command -v "$tool" >/dev/null && continue
    case $tool in
      timeout) hint='brew install coreutils' ;;
      *) hint='brew install tmux' ;;
    esac
    doctor_finding error dependency-missing "$tool is not on PATH ($PATH)" --value "$tool" --command "$hint"
  done
}

# Adds agent-slot doctor's findings, or the finding that says why it could not run, and keeps its launch times.
doctor_check_slot() {
  local findings
  server_call 120 doctor || true
  if contract_json -e '.findings | type == "array"' <<<"$SERVER_OUT" >/dev/null 2>&1; then
    DOCTOR_SLOT=$(contract_json -c . <<<"$SERVER_OUT")
    findings=$(contract_json -c '.findings[] | . + {host: "server"}' <<<"$SERVER_OUT")
    [[ -z $findings ]] || mapfile -t -O "${#DOCTOR_FINDINGS[@]}" DOCTOR_FINDINGS <<<"$findings"
    return
  fi
  [[ -n $AR_ERROR ]] || server_error 120 doctor
  DOCTOR_FINDINGS+=("$(contract_json -c '. + {severity: "error", host: "server"}' <<<"$AR_ERROR")")
}

cmd_doctor() {
  local findings errors
  contract_use_tools rex tmux agent-slot
  doctor_check_rex
  doctor_check_units
  doctor_check_rexurrect
  doctor_check_journal
  doctor_check_tmux
  doctor_check_tools
  doctor_check_slot
  findings=$(printf '%s\n' "${DOCTOR_FINDINGS[@]}" | contract_json -s -c 'map(select(. != null))')
  errors=$(contract_json '[.[] | select(.severity == "error")] | length' <<<"$findings")
  contract_ok "$(contract_json -n -c --argjson f "$findings" --argjson e "$errors" --argjson s "$DOCTOR_SLOT" \
    --arg server "$AR_SERVER" --arg rex "$AR_REX" '{ok: ($e == 0), server: $server,
      rex: (if $rex == "" then null else $rex end), findings: $f, launch_times: ($s.launch_times // null),
      verified_versions: ($s.verified_versions // null)}')" '
    (.findings[] | "\(.severity | ascii_upcase)\t\(.host): \(.reason): \(.message)" +
      (if .next_step.command then "\n\tnext: \(.next_step.command)" else "" end)),
    (.launch_times | if . == null then empty
     elif .measured == 0 then "launch times: none measured yet (target \(.target_s) s)"
     else "launch times: median \(.median_s) s, p90 \(.p90_s) s over \(.measured) launches (target \(.target_s) s)"
     end),
    (if .ok then "doctor: no errors"
     else "doctor: \([.findings[] | select(.severity == "error")] | length) error(s)" end)'
  ((errors == 0)) || exit "$EXIT_GENERAL"
}
