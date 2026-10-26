# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# launch: the new-agent key's tab. The key opens a background tab running `launch --here`; on success that tab becomes
# the slot's tab (relabelled, laid out, and attached), and on failure it stays open with the error and, for a
# retryable reason, a retry under the same request ID, so the server returns the slot the first try may have made.

LAUNCH_REPO='' LAUNCH_TASK='' LAUNCH_HERE=0 LAUNCH_PICKED=0 LAUNCH_WINDOW=''
LAUNCH_REPOS='[]'

launch_parse_args() {
  while (($#)); do
    case $1 in
      --repo | --task)
        (($# >= 2)) || usage_fail "$1 needs a value" "$1"
        case $1 in
          --repo) LAUNCH_REPO=$2 ;;
          --task) LAUNCH_TASK=$2 ;;
        esac
        shift 2
        ;;
      --here)
        LAUNCH_HERE=1
        shift
        ;;
      *) usage_fail "unknown argument $1" "$1" ;;
    esac
  done
}

launch_is_repo() {
  contract_json -e --arg r "$1" 'index($r) != null' <<<"$LAUNCH_REPOS" >/dev/null
}

launch_request_id() {
  if command -v uuidgen >/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# Sets LAUNCH_REPO from --repo or the Rex session's name, else from a numbered list when a terminal is attached, which
# sets LAUNCH_PICKED; with neither, refuses with repo-required.
launch_resolve_repo() {
  local label=''
  if [[ -n $LAUNCH_REPO ]]; then
    launch_is_repo "$LAUNCH_REPO" && return 0
    contract_fail repo-not-found "$AR_SERVER has no prime checkout named $LAUNCH_REPO" --value "$LAUNCH_REPO" \
      --command "ssh $AR_SERVER '$AR_REMOTE repos'"
  fi
  if [[ -n ${REX_SESSION:-} ]]; then
    rex_session_label "$REX_SESSION"
    label=$REX_OUT
    if launch_is_repo "$label"; then
      LAUNCH_REPO=$label
      return 0
    fi
  fi
  if [[ ! -t 0 ]]; then
    contract_fail repo-required "the Rex session ${label:+($label) }names no repo, and no terminal is attached to ask; \
pass --repo with one of: $(contract_json -r 'join(", ")' <<<"$LAUNCH_REPOS")" --value "$label" \
      --command "agent-slot-rex launch --repo <name>"
  fi
  launch_pick_repo
  LAUNCH_PICKED=1
}

launch_pick_repo() {
  local choice count
  if [[ -n ${REX_SESSION:-} && -n ${REX_BLOCK:-} ]]; then
    rex_window_of "$REX_SESSION" "$REX_BLOCK"
    [[ -z $REX_OUT ]] || rex_focus "$REX_SESSION" "$REX_OUT"
  fi
  count=$(contract_json 'length' <<<"$LAUNCH_REPOS")
  contract_json -r 'to_entries[] | "\(.key + 1)) \(.value)"' <<<"$LAUNCH_REPOS"
  while true; do
    printf 'repo for the new agent (1-%s, q to cancel): ' "$count"
    IFS= read -r choice || exit 0
    [[ $choice != q ]] || exit 0
    if [[ $choice =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)); then
      LAUNCH_REPO=$(contract_json -r --argjson i "$((choice - 1))" '.[$i]' <<<"$LAUNCH_REPOS")
      return 0
    fi
  done
}

launch_elsewhere() {
  local args=(launch --here --repo "$LAUNCH_REPO")
  [[ -z $LAUNCH_TASK ]] || args+=(--task "$LAUNCH_TASK")
  rex_open_tab "$LAUNCH_REPO" "$LAUNCH_REPO · launching" "$AR_SELF" "${args[@]}"
  contract_ok "$(contract_json -n -c --arg repo "$LAUNCH_REPO" --arg s "$REX_NEW_SESSION" --arg w "$REX_NEW_WINDOW" \
    '{repo: $repo, session_id: $s, window_id: $w}')" \
    '"launching an agent on \(.repo) in a background tab of its session"'
}

# The tabs and panes around a successful launch are a convenience: when one cannot be made, the slot is still running
# and the next restore makes it, so the error is shown and the launch goes on.
launch_try() {
  ("$@") || true
}

launch_open_sweep() {
  rex_open_tab "$AR_CONTROL" sweep "$AR_SELF" sweep
}

# Relabels this tab, lays it out, opens the sweep tab, and becomes the Claude pane's attach loop.
launch_succeeded() {
  local key label
  key=$(contract_json -r '.key' <<<"$SERVER_OUT")
  label=$(contract_json -r '.key + (if .task then " · \(.task)" else "" end)
    + (if .trust_prompt_expected == true then " · trust needed" else "" end)' <<<"$SERVER_OUT")
  launch_try rex_rename "$REX_SESSION" "$LAUNCH_WINDOW" "$label"
  launch_try rex_layout "$REX_SESSION" "$REX_BLOCK" "$key"
  launch_try launch_open_sweep
  contract_ok "$SERVER_OUT" '"\(.key) \(if .created then "is ready" else "already held this request" end) at \(.path)"'
  rm -f "$CONTRACT_NOISE"
  exec "$AR_SELF" attach "$key" claude
}

# Shows the failed call's error in this tab. Returns 0 when the operator asks for a retry.
launch_failed() {
  local key
  launch_try rex_rename "$REX_SESSION" "$LAUNCH_WINDOW" "${LAUNCH_REPO:-new agent} · launch failed"
  printf '\nagent-slot-rex: the launch%s failed\n' "${LAUNCH_REPO:+ on $LAUNCH_REPO}"
  contract_error_text "$AR_ERROR"
  if [[ $(contract_json -r '.recovery.retryable' <<<"$AR_ERROR") == true ]]; then
    printf 'press Enter to retry with the same request ID, or q to close this tab\n'
    while IFS= read -r -n 1 key; do
      [[ -n $key ]] || return 0
      [[ $key != q ]] || return 1
    done
    return 1
  fi
  ar_hold
  return 1
}

# Usage: launch_call <seconds> <verb> [args...]
# server_call, which in a launch tab shows a failure and retries it while the operator asks to.
launch_call() {
  until server_call "$@"; do
    ((LAUNCH_HERE == 1)) || ar_fail "$AR_ERROR"
    launch_failed || {
      CONTRACT_EMITTED=1
      [[ $CONTRACT_OUTPUT != json ]] || printf '%s\n' "$AR_ERROR" >&2
      exit "$(contract_json -r '.exit_code' <<<"$AR_ERROR")"
    }
  done
}

launch_here() {
  local args
  args=("$LAUNCH_REPO" --request-id "$(launch_request_id)" --requested-at "$(date +%s)")
  [[ -z $LAUNCH_TASK ]] || args+=(--task "$LAUNCH_TASK")
  launch_try rex_rename "$REX_SESSION" "$LAUNCH_WINDOW" "$LAUNCH_REPO · launching"
  printf 'agent-slot-rex: starting an agent in a fresh slot of %s on %s (request %s)\n' "$LAUNCH_REPO" "$AR_SERVER" \
    "${args[2]}"
  launch_call 960 launch "${args[@]}"
  launch_succeeded
}

cmd_launch() {
  contract_use_tools rex ssh
  if ((LAUNCH_HERE == 1)); then
    [[ -n ${REX_SESSION:-} && -n ${REX_BLOCK:-} ]] \
      || usage_fail "--here runs only in a Rex terminal, which sets REX_SESSION and REX_BLOCK"
    rex_window_of "$REX_SESSION" "$REX_BLOCK"
    LAUNCH_WINDOW=$REX_OUT
  fi
  launch_call 30 repos
  LAUNCH_REPOS=$(contract_json -c '[.repos[].name]' <<<"$SERVER_OUT")
  launch_resolve_repo
  if ((LAUNCH_PICKED == 1 || LAUNCH_HERE == 0)); then
    launch_elsewhere
    return
  fi
  launch_here
}
