# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The helper on the Mac. Every slot and every repo session lives on the Linux server, and Rex.app is a client of that
# server's Rex, so on macOS a slot verb that a Rex.app action or the operator runs goes to the server's own helper over
# ssh, which prints its output and exits with its code. The verbs that drive a Rex server of their own (a pane's attach
# loop, the follow loop, and the reconcile passes a trigger runs) stop with wrong-host instead.

# Usage: forward_quote <word...>; the words as one command line for the server's login shell. zsh expands an unquoted
# word that starts with = to a command's path, so every word is single-quoted.
forward_quote() {
  local word out=''
  for word in "$@"; do
    out+=" '${word//\'/\'\\\'\'}'"
  done
  printf '%s' "${out# }"
}

# Usage: forward_verb <verb> [args...]; never returns.
forward_verb() {
  local verb=$1 arg args=() status=0 tty=-n err line
  shift
  case "$verb ${1:-}" in
    'attach '* | 'follow '* | 'restore --by' | 'restore --wait-server')
      contract_fail wrong-host "agent-slot-rex $verb drives the Rex server on the Linux server, so it runs only on \
$AR_SERVER" --value "$AR_SERVER" --command "ssh $AR_SERVER agent-slot-rex doctor"
      ;;
  esac
  # --here names the Mac tab the new-agent key opened; on the server, launch opens the agent's tab in its repo's session.
  for arg in "$@"; do
    [[ $verb == launch && $arg == --here ]] || args+=("$arg")
  done
  [[ $CONTRACT_OUTPUT != json ]] || args+=(--output json)
  # A terminal merges the server's stderr into its stdout, so only text output, where a tab waits for keys, gets one.
  [[ $CONTRACT_OUTPUT != text || ! -t 0 ]] || tty=-t
  contract_use_tools ssh
  err=$(mktemp)
  "$AR_SSH" "$tty" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
    -o LogLevel=ERROR "$AR_SERVER" "$AR_REMOTE_SELF $(forward_quote "$verb" "${args[@]}")" 2>"$err" || status=$?
  line=$(grep . "$err" | tail -1 || true)
  case $status in
    255)
      rm -f "$err"
      contract_fail server-unreachable "ssh to $AR_SERVER failed: ${line:-ssh printed nothing}" --value "$AR_SERVER" \
        --command "ssh $AR_SERVER agent-slot-rex doctor"
      ;;
    127)
      rm -f "$err"
      contract_fail dependency-missing "agent-slot-rex is not installed on $AR_SERVER: $line" --value "$AR_SERVER" \
        --command "ssh $AR_SERVER 'cd ~/dotfiles && scripts/stow-deploy local'"
      ;;
  esac
  cat "$err" >&2
  rm -f "$err"
  CONTRACT_EMITTED=1
  exit "$status"
}
