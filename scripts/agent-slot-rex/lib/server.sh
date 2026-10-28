# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# Calls to the Linux server. Each one is `ssh -n -o BatchMode=yes` under timeout, so it never reads the operator's
# keys and never waits on a prompt, and runs agent-slot by path, because the server's login PATH is not trusted. ssh
# reports its own failure (no route, a refused key, a changed host key) as exit 255, which agent-slot never uses, so
# 255 means the server was not reached; 124 means the call outlived its bound.

# The server's shell expands the tilde.
# shellcheck disable=SC2088
AR_REMOTE='~/.local/bin/agent-slot'

SERVER_STATUS=0
SERVER_OUT=
SERVER_STDERR=
SERVER_LOG=
AR_ERROR=

# Usage: server_ssh <seconds> <label> <remote command>
# Sets SERVER_STATUS, SERVER_OUT (stdout), and SERVER_STDERR; a failed call keeps both in SERVER_LOG.
server_ssh() {
  local secs=$1 label=$2 cmd=$3 out err
  out=$(mktemp) err=$(mktemp)
  SERVER_STATUS=0 SERVER_LOG=
  timeout --kill-after=2 "$secs" "$AR_SSH" -n -o BatchMode=yes -o ConnectTimeout=10 "$AR_SERVER" "$cmd" \
    </dev/null >"$out" 2>"$err" || SERVER_STATUS=$?
  SERVER_OUT=$(<"$out")
  SERVER_STDERR=$(<"$err")
  ((SERVER_STATUS == 0)) || SERVER_LOG=$(_server_keep "$label" "$cmd" "$out" "$err")
  rm -f "$out" "$err"
  return "$SERVER_STATUS"
}

_server_keep() {
  local label=$1 cmd=$2 out=$3 err=$4 log
  mkdir -p "$AR_LOG_DIR" 2>/dev/null || return 0
  log="$AR_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$-$label.log"
  {
    printf 'command: ssh -n -o BatchMode=yes %s %s\nexit: %s\n--- stdout\n' "$AR_SERVER" "$cmd" "$SERVER_STATUS"
    cat "$out"
    printf -- '--- stderr\n'
    cat "$err"
  } >"$log" 2>/dev/null || return 0
  printf '%s' "$log"
}

# Usage: server_call <seconds> <verb> [args...]
# Runs `agent-slot <verb> <args> --output json` on the server. On failure sets AR_ERROR to the error object: the one
# agent-slot printed, or one this helper builds for an unreachable server or a command that printed none.
server_call() {
  local secs=$1 verb=$2
  shift 2
  AR_ERROR=
  server_ssh "$secs" "$verb" "$AR_REMOTE $(contract_quote "$verb" "$@") --output json" && return 0
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
  contract_use_tools ssh
  case $SERVER_STATUS in
    255)
      AR_ERROR=$(contract_error_json server-unreachable "ssh to $AR_SERVER failed: $(server_ssh_line)" \
        --value "$AR_SERVER" --command "ssh -n -o BatchMode=yes $AR_SERVER true" --log "$SERVER_LOG")
      return
      ;;
    124)
      AR_ERROR=$(contract_error_json server-unreachable "$AR_SERVER did not finish agent-slot $verb within $secs s" \
        --value "$AR_SERVER" --command "ssh -n -o BatchMode=yes $AR_SERVER true" --side-effects unknown \
        --reconcile "agent-slot-rex restore" --log "$SERVER_LOG")
      return
      ;;
  esac
  envelope=$(grep '^{' <<<"$SERVER_STDERR" | tail -1 \
    | contract_json -c 'select(.ok == false and has("reason"))' || true)
  if [[ -n $envelope ]]; then
    AR_ERROR=$envelope
  elif ((SERVER_STATUS == 127)); then
    AR_ERROR=$(contract_error_json dependency-missing "agent-slot is not installed at $AR_REMOTE on $AR_SERVER" \
      --value "$AR_SERVER" --command "ssh $AR_SERVER 'cd ~/dotfiles && scripts/stow-deploy local'" --log "$SERVER_LOG")
  else
    AR_ERROR=$(contract_error_json script-error \
      "agent-slot $verb on $AR_SERVER exited $SERVER_STATUS without an error object" --value "$SERVER_STATUS" \
      --command "ssh $AR_SERVER '$AR_REMOTE $verb'" --side-effects unknown --reconcile "agent-slot-rex restore" \
      --log "$SERVER_LOG")
  fi
}

# Usage: ar_fail <error-json>
# Records the error as the outcome of a reconcile pass under way, prints it as contract_fail does, and exits with its
# code; with AR_HOLD set, waits for q first, so a tab shows the error until the operator has read it.
AR_HOLD=0
ar_fail() {
  local code
  code=$(contract_json -r '.exit_code' <<<"$1")
  journal_end "$1"
  contract_emit_error "$1"
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
