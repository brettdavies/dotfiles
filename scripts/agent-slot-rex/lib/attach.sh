# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# attach: a pane's hold on one of the tmux sessions of its slot or prime, as a loop around a local tmux attach. It runs
# from $HOME, so the agent-state scan never counts the pane as using the slot. A missing session is started first,
# through resume for a slot and agent-slot prime for a prime; a client that ends while its session lives was detached, so
# the loop waits for Enter before attaching again. A tmux server that does not answer is waited out rather than started
# on, since the start would wait on the same server. A pane ends only when agent-slot says its slot, or its prime's
# checkout, is gone.

ATTACH_KEY='' ATTACH_KIND='' ATTACH_NAME='' ATTACH_RESTART='' ATTACH_GONE=''

# True while the pane's session exists.
attach_has_session() {
  timeout --kill-after=2 10 "$AR_TMUX" -L "$AR_TMUX_SOCKET" has-session -t "=$ATTACH_NAME" </dev/null >/dev/null 2>&1
}

# Usage: attach_pause <why>
attach_pause() {
  printf 'agent-slot-rex: %s %s: %s; retrying in %s s\n' "$ATTACH_KEY" "$ATTACH_KIND" "$1" "$AR_RETRY"
  sleep "$AR_RETRY"
}

# Returns 0 when the sessions were started, 1 to retry later, and exits when the slot or the prime's checkout is gone.
attach_resume() {
  if [[ $SLOT_N == "$SLOT_PRIME" ]]; then
    printf 'agent-slot-rex: %s has no %s session; starting the prime\n' "$ATTACH_KEY" "$ATTACH_KIND"
    if server_call "$AR_PRIME_BOUND" prime "$SLOT_REPO"; then
      # This pane began while the default server did not answer, so it took the old-style session for gone. Only the
      # prime command attaches to one, and this loop would wait for a slot-server session that never comes.
      [[ $(contract_json -r '.server' <<<"$SERVER_OUT") != default ]] || exec "$AR_SELF" prime "$SLOT_REPO"
      return 0
    fi
  else
    printf 'agent-slot-rex: %s has no %s session; resuming the slot\n' "$ATTACH_KEY" "$ATTACH_KIND"
    server_call "$AR_RESUME_BOUND" resume "$ATTACH_KEY" && return 0
  fi
  if [[ $(contract_json -r '.reason' <<<"$AR_ERROR") == "$ATTACH_GONE" ]]; then
    printf 'agent-slot-rex: %s is gone (%s); this pane is done\n' "$ATTACH_KEY" \
      "$(contract_json -r '.message' <<<"$AR_ERROR")"
    CONTRACT_EMITTED=1
    exit 0
  fi
  contract_error_text "$AR_ERROR"
  return 1
}

cmd_attach() {
  local attached=0 resumed=0 status
  slot_parse_attach_key "$1"
  ATTACH_RESTART=resume ATTACH_GONE=slot-not-found
  if [[ $SLOT_N == "$SLOT_PRIME" ]]; then
    ATTACH_RESTART='agent-slot prime' ATTACH_GONE=repo-not-found
  fi
  case $2 in
    claude | files | git) ;;
    *) usage_fail "the pane is claude, files, or git" "$2" ;;
  esac
  ATTACH_KEY=$1 ATTACH_KIND=$2
  ATTACH_NAME=$(slot_session "$SLOT_REPO" "$SLOT_N" "$2")
  contract_use_tools tmux
  cd "$HOME" || exit "$EXIT_GENERAL"
  while true; do
    status=0
    attach_has_session || status=$?
    if ((status == 0)); then
      if ((attached == 1)); then
        printf 'agent-slot-rex: detached from %s; press Enter to reattach\n' "$ATTACH_NAME"
        IFS= read -r _ || exit 0
      fi
      attached=1 resumed=0
      "$AR_TMUX" -L "$AR_TMUX_SOCKET" attach -t "=$ATTACH_NAME" || true
      continue
    fi
    if ((status == 124 || status == 137)); then
      attach_pause "the $AR_TMUX_SOCKET tmux server did not answer"
      continue
    fi
    attached=0
    if ((resumed == 1)); then
      resumed=0
      attach_pause "$ATTACH_NAME is still missing after $ATTACH_RESTART"
    elif attach_resume; then
      resumed=1
    else
      attach_pause "$ATTACH_RESTART failed: $(contract_json -r '.reason' <<<"$AR_ERROR")"
    fi
  done
}
