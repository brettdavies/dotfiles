# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# attach: a pane's connection to one of its slot's tmux sessions on the server. ServerAlive notices a dropped
# connection within about ten seconds; the loop then retries every few seconds plus up to AR_JITTER seconds of random
# delay, so the panes of every tab reconnecting after a wake do not reach sshd at once and trip its MaxStartups. A pane
# never exits on a disconnect: it ends only when the server says its slot is gone.

ATTACH_SOCKET=agent-slots
# The server's shell expands $HOME and $PATH; its login PATH is not trusted to hold tmux.
# shellcheck disable=SC2016
ATTACH_PATH='export PATH="$HOME/.local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH";'
ATTACH_MISSING=3

# Usage: attach_session <repo> <n> <claude | files | git>; the tmux session name, as agent-slot names it.
attach_session() {
  local name="${1//[.:]/_}-$2"
  [[ $3 == claude ]] || name+=-$3
  printf '%s' "$name"
}

# The server's login shell is zsh, which expands a word that starts with = to a command's path, so the exact-match
# target is always single-quoted. A session name holds only letters, digits, _, and -.
attach_target() { printf "'=%s'" "$1"; }

attach_remote() {
  printf '%s tmux -L %s has-session -t %s 2>/dev/null || exit %s; exec tmux -L %s attach -t %s' \
    "$ATTACH_PATH" "$ATTACH_SOCKET" "$(attach_target "$1")" "$ATTACH_MISSING" "$ATTACH_SOCKET" "$(attach_target "$1")"
}

# Usage: attach_pause <tries> <why>
attach_pause() {
  local delay=$((AR_RETRY + RANDOM % (AR_JITTER + 1)))
  printf 'agent-slot-rex: %s %s: %s; retry %s in %s s\n' "$ATTACH_KEY" "$ATTACH_KIND" "$2" "$1" "$delay"
  sleep "$delay"
}

# Usage: attach_resume; returns 0 when the slot's sessions were started, 1 to retry later, and exits when the slot is
# gone.
attach_resume() {
  printf 'agent-slot-rex: %s has no %s session; resuming the slot\n' "$ATTACH_KEY" "$ATTACH_KIND"
  server_call 60 resume "$ATTACH_KEY" && return 0
  if [[ $(contract_json -r '.reason' <<<"$AR_ERROR") == slot-not-found ]]; then
    printf 'agent-slot-rex: %s is gone from %s (%s); this pane is done\n' "$ATTACH_KEY" "$AR_SERVER" \
      "$(contract_json -r '.message' <<<"$AR_ERROR")"
    CONTRACT_EMITTED=1
    exit 0
  fi
  ar_error_text "$AR_ERROR"
  return 1
}

cmd_attach() {
  local status tries=0 resumed=0 err line
  [[ $1 =~ ^([A-Za-z0-9._-]+)/([0-9]+)$ ]] || usage_fail "a slot is named <repo>/<N>, such as dotfiles/2" "$1"
  case $2 in
    claude | files | git) ;;
    *) usage_fail "the pane is claude, files, or git" "$2" ;;
  esac
  ATTACH_KEY=$1 ATTACH_KIND=$2
  ATTACH_NAME=$(attach_session "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$2")
  err=$(mktemp)
  contract_on_exit rm -f "$err"
  contract_use_tools ssh
  while true; do
    status=0
    "$AR_SSH" -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -t \
      "$AR_SERVER" "$(attach_remote "$ATTACH_NAME")" 2>"$err" || status=$?
    if ((status == 0)); then
      server_ssh 20 has-session "$ATTACH_PATH tmux -L $ATTACH_SOCKET has-session -t $(attach_target "$ATTACH_NAME")" \
        || status=$SERVER_STATUS
      ((status != 1)) || status=$ATTACH_MISSING
      if ((status == 0)); then
        printf 'agent-slot-rex: detached from %s; press Enter to reattach\n' "$ATTACH_NAME"
        IFS= read -r _ || exit 0
        tries=0 resumed=0
        continue
      fi
    fi
    if ((status == ATTACH_MISSING)); then
      if ((resumed == 0)); then
        resumed=1
        attach_resume && continue
        line="resume failed: $(contract_json -r '.reason' <<<"$AR_ERROR")"
      else
        resumed=0 line="$ATTACH_NAME is still missing after a resume"
      fi
      tries=$((tries + 1))
      attach_pause "$tries" "$line"
      continue
    fi
    tries=$((tries + 1)) resumed=0
    line=$(grep . "$err" | tail -1 || true)
    [[ $status != 255 || -n $line ]] || line="ssh to $AR_SERVER failed"
    attach_pause "$tries" "${line:-ssh exited $status}"
  done
}
