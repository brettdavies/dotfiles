# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# attach: a pane's hold on one of its slot's tmux sessions, as a loop around a local tmux attach. It runs from $HOME, so
# the agent-state scan never counts the pane as using the slot. A missing session is resumed first; a client that ends
# while its session lives was detached, so the loop waits for Enter before attaching again. A pane ends only when
# agent-slot says its slot is gone.

ATTACH_KEY='' ATTACH_KIND='' ATTACH_NAME=''

# True while the pane's session exists.
attach_has_session() {
  timeout --kill-after=2 10 "$AR_TMUX" -L "$AR_TMUX_SOCKET" has-session -t "=$ATTACH_NAME" </dev/null >/dev/null 2>&1
}

# Usage: attach_pause <why>
attach_pause() {
  printf 'agent-slot-rex: %s %s: %s; retrying in %s s\n' "$ATTACH_KEY" "$ATTACH_KIND" "$1" "$AR_RETRY"
  sleep "$AR_RETRY"
}

# Returns 0 when the slot's sessions were started, 1 to retry later, and exits when the slot is gone.
attach_resume() {
  printf 'agent-slot-rex: %s has no %s session; resuming the slot\n' "$ATTACH_KEY" "$ATTACH_KIND"
  server_call 60 resume "$ATTACH_KEY" && return 0
  if [[ $(contract_json -r '.reason' <<<"$AR_ERROR") == slot-not-found ]]; then
    printf 'agent-slot-rex: %s is gone (%s); this pane is done\n' "$ATTACH_KEY" \
      "$(contract_json -r '.message' <<<"$AR_ERROR")"
    CONTRACT_EMITTED=1
    exit 0
  fi
  contract_error_text "$AR_ERROR"
  return 1
}

cmd_attach() {
  local attached=0 resumed=0
  slot_parse_key "$1"
  case $2 in
    claude | files | git) ;;
    *) usage_fail "the pane is claude, files, or git" "$2" ;;
  esac
  ATTACH_KEY=$1 ATTACH_KIND=$2
  ATTACH_NAME=$(slot_session "$SLOT_REPO" "$SLOT_N" "$2")
  contract_use_tools tmux
  cd "$HOME" || exit "$EXIT_GENERAL"
  while true; do
    if attach_has_session; then
      if ((attached == 1)); then
        printf 'agent-slot-rex: detached from %s; press Enter to reattach\n' "$ATTACH_NAME"
        IFS= read -r _ || exit 0
      fi
      attached=1 resumed=0
      "$AR_TMUX" -L "$AR_TMUX_SOCKET" attach -t "=$ATTACH_NAME" || true
      continue
    fi
    attached=0
    if ((resumed == 1)); then
      resumed=0
      attach_pause "$ATTACH_NAME is still missing after a resume"
    elif attach_resume; then
      resumed=1
    else
      attach_pause "resume failed: $(contract_json -r '.reason' <<<"$AR_ERROR")"
    fi
  done
}
