# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Calls to agent-slot on this host: the one seam every slot verb's work on the slots goes through. Each call runs
# agent-slot by path under timeout, reads no stdin, and names this helper in AGENT_SLOT_REX_CLIENT, so the push
# agent-slot runs after a launch or teardown skips the reconcile this helper runs right after. It also hands agent-slot
# the user manager's runtime directory, which a shell in a slot's tmux session lacks and agent-slot's systemctl --user
# calls need. agent-slot exits with its own codes, which never include 124 or 137 (timeout stopped the call) or 127
# (agent-slot is not installed).
#
# server_ssh is the bounded ssh call to the server that the follow loop probes it with; ssh reports its own failure (no
# route, a refused key, a changed host key) as exit 255.

SERVER_STATUS=0
SERVER_OUT=
SERVER_STDERR=
SERVER_LOG=
AR_ERROR=

# Usage: server_run <seconds> <label> <command...>
# Sets SERVER_STATUS, SERVER_OUT (stdout), and SERVER_STDERR; a failed call keeps both in SERVER_LOG.
server_run() {
  local secs=$1 label=$2 out err
  shift 2
  out=$(mktemp) err=$(mktemp)
  SERVER_STATUS=0 SERVER_LOG=
  timeout --kill-after=2 "$secs" "$@" </dev/null >"$out" 2>"$err" || SERVER_STATUS=$?
  SERVER_OUT=$(<"$out")
  SERVER_STDERR=$(<"$err")
  ((SERVER_STATUS == 0)) || SERVER_LOG=$(_server_keep "$label" "$(contract_quote "$@")" "$out" "$err")
  rm -f "$out" "$err"
  return "$SERVER_STATUS"
}

# Usage: server_ssh <seconds> <label> <remote command>
server_ssh() {
  server_run "$1" "$2" "$AR_SSH" -n -o BatchMode=yes -o ConnectTimeout=10 "$AR_SERVER" "$3"
}

_server_keep() {
  local label=$1 cmd=$2 out=$3 err=$4 log
  mkdir -p "$AR_LOG_DIR" 2>/dev/null || return 0
  log="$AR_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$-$label.log"
  {
    printf 'command: %s\nexit: %s\n--- stdout\n' "$cmd" "$SERVER_STATUS"
    cat "$out"
    printf -- '--- stderr\n'
    cat "$err"
  } >"$log" 2>/dev/null || return 0
  printf '%s' "$log"
}

# True when the last call outlived its bound.
server_timed_out() { ((SERVER_STATUS == 124 || SERVER_STATUS == 137)); }

# Usage: server_call <seconds> <verb> [args...]
# Runs `agent-slot <verb> <args> --output json`. On failure sets AR_ERROR to the error object: the one agent-slot
# printed, or one this helper builds for a call that outlived its bound, a missing agent-slot, or a command that printed
# none.
server_call() {
  local secs=$1 verb=$2
  shift 2
  AR_ERROR=
  server_run "$secs" "$verb" env AGENT_SLOT_REX_CLIENT="$AR_CLIENT" XDG_RUNTIME_DIR="$AR_RUNTIME_DIR" \
    "$AR_AGENT_SLOT" "$verb" "$@" --output json && return 0
  server_error "$secs" "$verb"
  return "$SERVER_STATUS"
}

# The last line ssh printed: on a failure, its verdict.
server_ssh_line() {
  grep . <<<"$SERVER_STDERR" | tail -1 || true
}

# Usage: server_error <seconds> <verb>; sets AR_ERROR for the failed call.
server_error() {
  local secs=$1 verb=$2 envelope
  contract_use_tools agent-slot
  if server_timed_out; then
    AR_ERROR=$(contract_error_json agent-slot-timed-out "agent-slot $verb did not finish within $secs s" \
      --value "$secs" --command "agent-slot-rex restore" --side-effects unknown --reconcile "agent-slot-rex restore" \
      --log "$SERVER_LOG")
    return
  fi
  if ((SERVER_STATUS == 127)); then
    AR_ERROR=$(contract_error_json dependency-missing "agent-slot is not installed at $AR_AGENT_SLOT" \
      --value "$AR_AGENT_SLOT" --command "cd ~/dotfiles && scripts/stow-deploy local" --log "$SERVER_LOG")
    return
  fi
  envelope=$(grep '^{' <<<"$SERVER_STDERR" | tail -1 \
    | contract_json -c 'select(.ok == false and has("reason"))' || true)
  if [[ -n $envelope ]]; then
    AR_ERROR=$envelope
  else
    AR_ERROR=$(contract_error_json script-error "agent-slot $verb exited $SERVER_STATUS without an error object" \
      --value "$SERVER_STATUS" --command "agent-slot $verb --output json" --side-effects unknown \
      --reconcile "agent-slot-rex restore" --log "$SERVER_LOG")
  fi
}

# Usage: ar_fail <error-json>
# Records the error as the outcome of a reconcile pass under way, prints it as contract_fail does, and exits with its
# code; with AR_HOLD set, waits for q first, so a tab shows the error until the operator has read it. With AR_DONE
# naming what a slot verb had already done before the pass that failed, the error says so and reports partial side
# effects, so a caller never reads a completed teardown as one that did nothing.
AR_HOLD=0
AR_DONE=
ar_fail() {
  local error=$1 code
  if [[ -n $AR_DONE ]]; then
    error=$(contract_json -c --arg did "$AR_DONE" '.message += " (after \($did))"
      | .recovery.side_effects = "partial" | .recovery.reconcile = "agent-slot-rex restore"' <<<"$error")
  fi
  code=$(contract_json -r '.exit_code' <<<"$error")
  journal_end "$error"
  contract_emit_error "$error"
  ((AR_HOLD == 0)) || ar_hold
  exit "$code"
}

# Usage: server_call_or_fail <seconds> <verb> [args...]; server_call, ending the command on failure.
server_call_or_fail() {
  server_call "$@" || ar_fail "$AR_ERROR"
}

# Usage: ar_hold [prompt]
# Keeps a tab open for the operator to read it: waits for q, or for the end of input when no terminal is attached. With
# AR_AGAIN naming a verb, r runs that verb again in the same tab. A tab can wait hours for its q, so it gives up the
# reconcile lock first.
AR_AGAIN=
ar_hold() {
  local key
  lock_release
  printf '%s\n' "${1:-${AR_AGAIN:+press r to run the $AR_AGAIN again; }press q to close this tab}"
  while IFS= read -r -s -n 1 key; do
    [[ $key != q ]] || return 0
    [[ -z $AR_AGAIN || $key != r ]] || ar_again
  done
}

# True when an r reached the terminal while the AR_AGAIN verb ran, typed or sent by a launch.
ar_again_pending() {
  local key
  [[ -n $AR_AGAIN && -t 0 ]] && IFS= read -r -s -n 1 -t 0.2 key && [[ $key == r ]]
}

# Runs the AR_AGAIN verb again, replacing this process, so the tab keeps its place.
ar_again() {
  [[ $CONTRACT_NOISE == /dev/null ]] || rm -f "$CONTRACT_NOISE"
  exec "$AR_SELF" "$AR_AGAIN"
}
