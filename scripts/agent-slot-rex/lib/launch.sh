# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# launch: the new-agent key's tab. The key opens a background tab running `launch --here`. In a repo's session whose
# prime is open in none of its tabs, that tab becomes the prime's tab; otherwise, on success it becomes the slot's tab
# (relabelled, laid out, and attached), and on failure it stays open with the error and, for a retryable reason, a retry
# under the same request ID, so the server returns the slot the first try may have made.

LAUNCH_REPO='' LAUNCH_TASK='' LAUNCH_HERE=0 LAUNCH_WAIT_SHOWN=0 LAUNCH_PICKED=0 LAUNCH_NAMED=0 LAUNCH_WINDOW=''
LAUNCH_REPOS='[]'
LAUNCH_OPENED_AT='' LAUNCH_SHOWN_AT=''

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
      --wait-shown)
        LAUNCH_WAIT_SHOWN=1
        shift
        ;;
      *) usage_fail "unknown argument $1" "$1" ;;
    esac
  done
}

launch_is_repo() {
  contract_json -e --arg r "$1" 'index($r) != null' <<<"$LAUNCH_REPOS" >/dev/null
}

# The wall clock in seconds since the epoch, to the microsecond. EPOCHREALTIME takes the locale's decimal mark.
launch_now() {
  printf '%s' "${EPOCHREALTIME/,/.}"
}

# Prints when this tab's process started, in seconds since the epoch, or nothing where /proc cannot say. Rex starts a
# tab's command as a child of its server, and exec keeps a process's start time, so this is when the tab opened. /proc
# gives the start in clock ticks since boot, on the clock /proc/uptime reads, so its age places it on the wall clock.
launch_opened_at() {
  local stat uptime now fields
  { stat=$(<"/proc/$$/stat") && read -r uptime _ </proc/uptime; } 2>/dev/null || return 0
  now=$(launch_now)
  # The fields after the command name, which ends at the last ") ", start at the third: the start time is the 22nd.
  read -r -a fields <<<"${stat##*) }"
  awk -v now="$now" -v up="$uptime" -v start="${fields[19]}" -v hz="$(getconf CLK_TCK)" \
    'BEGIN { if (start ~ /^[0-9]+$/ && hz > 0) printf "%.3f", now - (up - start / hz) }'
}

launch_request_id() {
  if command -v uuidgen >/dev/null; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# Sets LAUNCH_REPO from --repo, else from the Rex session's name, which sets LAUNCH_NAMED, else from a numbered list
# when a terminal is attached, which sets LAUNCH_PICKED; with none of them, refuses with repo-required.
launch_resolve_repo() {
  local label=''
  if [[ -n $LAUNCH_REPO ]]; then
    launch_is_repo "$LAUNCH_REPO" && return 0
    contract_fail repo-not-found "no prime checkout is named $LAUNCH_REPO" --value "$LAUNCH_REPO" \
      --command "agent-slot repos"
  fi
  if [[ -n ${REX_SESSION:-} ]]; then
    rex_session_label "$REX_SESSION"
    label=$REX_OUT
    if launch_is_repo "$label"; then
      LAUNCH_REPO=$label LAUNCH_NAMED=1
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

# One sweep tab serves every launch: a sweep tab already open is asked to sweep again, which it does once its current
# run ends, so two sweeps never reconcile tabs at once.
launch_open_sweep() {
  rex_helper_block "$AR_CONTROL" sweep
  if [[ -n $REX_OUT ]]; then
    rex_send "$REX_SID" "$REX_OUT" r
  else
    rex_open_tab "$AR_CONTROL" sweep "$AR_SELF" sweep
  fi
}

# Relabels this tab, lays it out, opens or reruns the sweep tab, and becomes the Claude pane's attach loop.
launch_succeeded() {
  local key label
  key=$(contract_json -r '.key' <<<"$SERVER_OUT")
  label=$(contract_json -r '.key
    + ((.label_name // .task // .branch) as $name | if $name then " · \($name)" else "" end)
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

# Returns once the app that pressed the key shows this tab: its queued selection makes the tab the session's active
# window. Rex.app gives a key pressed in a session with no tabs the context of the pane it last focused, so the tab can
# open in another session, even on another host, where nobody sees it and its select fails. Such a tab starts nothing:
# it asks for Enter, in case the app showed it without moving the active window, and closes itself unanswered.
launch_wait_shown() {
  local deadline=$((SECONDS + AR_SHOWN_WAIT)) key
  while true; do
    if rex_run session inspect "$REX_SESSION" --json \
      && [[ $(contract_json -r '.active_window_id // ""' <<<"$REX_OUT") == "$LAUNCH_WINDOW" ]]; then
      return 0
    fi
    ((SECONDS < deadline)) || break
    sleep 0.25
  done
  printf 'agent-slot-rex: Rex.app has not shown this tab, so the new-agent key may have opened it in another session\n'
  printf 'press Enter to go on, or q to close it; it closes in %s s\n' "$AR_SHOWN_HOLD"
  if IFS= read -r -s -n 1 -t "$AR_SHOWN_HOLD" key && [[ $key != q ]]; then
    return 0
  fi
  CONTRACT_EMITTED=1
  rex_close "$REX_SESSION" "$LAUNCH_WINDOW"
  exit 0
}

# A key's tab reads the repos in the background while it waits for Rex.app to show it, a wait of 2 to 3 s, since
# the read changes nothing. launch_repos takes that read, or reads again through launch_call, with its retry, when the
# early one failed. The exit of a tab that is never shown waits for the read, so it outlives no tab.
LAUNCH_REPOS_EARLY='' LAUNCH_REPOS_PID=''
launch_repos_early() {
  LAUNCH_REPOS_EARLY=$(mktemp)
  (server_call 30 repos && printf '%s\n' "$SERVER_OUT" >"$LAUNCH_REPOS_EARLY") </dev/null >/dev/null 2>&1 &
  LAUNCH_REPOS_PID=$!
  contract_on_exit launch_repos_reap
}

launch_repos_reap() {
  [[ -z $LAUNCH_REPOS_PID ]] || wait "$LAUNCH_REPOS_PID" 2>/dev/null || true
  LAUNCH_REPOS_PID=
  [[ -z $LAUNCH_REPOS_EARLY ]] || rm -f "$LAUNCH_REPOS_EARLY"
  LAUNCH_REPOS_EARLY=
}

# Sets SERVER_OUT to the server's repos.
launch_repos() {
  local early=''
  if [[ -n $LAUNCH_REPOS_PID ]] && wait "$LAUNCH_REPOS_PID" && [[ -s $LAUNCH_REPOS_EARLY ]]; then
    early=$(<"$LAUNCH_REPOS_EARLY")
  fi
  LAUNCH_REPOS_PID=
  launch_repos_reap
  if [[ -n $early ]]; then
    SERVER_OUT=$early
  else
    launch_call 30 repos
  fi
}

# Makes this tab the repo's prime tab, first in its session and labelled with the prime session's name, and becomes the
# prime's attach. A prime that is not running stops the tab with the reason, since attaching would fail.
launch_prime() {
  if ! prime_running "$PRIME_SESSION"; then
    launch_try rex_rename "$REX_SESSION" "$LAUNCH_WINDOW" "$LAUNCH_REPO · prime not running"
    [[ $CONTRACT_OUTPUT != text || ! -t 0 ]] || AR_HOLD=1
    ar_fail "$(contract_error_json prime-not-running "the prime tmux session of $LAUNCH_REPO, $PRIME_SESSION, is not \
running on the default tmux server; start it, then press the key again" --value "$PRIME_SESSION" \
      --command "$(contract_quote tmux has-session -t "=$PRIME_SESSION")")"
  fi
  launch_try rex_rename "$REX_SESSION" "$LAUNCH_WINDOW" "$PRIME_SESSION"
  launch_try rex_or_fail window move -s "$REX_SESSION" "$LAUNCH_WINDOW" --index 1
  contract_ok "$(contract_json -n -c --arg repo "$LAUNCH_REPO" --arg prime "$PRIME_SESSION" \
    '{repo: $repo, prime: $prime}')" '"opening the prime of \(.repo), \(.prime)"'
  rm -f "$CONTRACT_NOISE"
  exec "$AR_SELF" prime "$LAUNCH_REPO"
}

launch_here() {
  local args
  args=("$LAUNCH_REPO" --request-id "$(launch_request_id)" --requested-at "$(launch_now)")
  [[ -z $LAUNCH_OPENED_AT ]] || args+=(--opened-at "$LAUNCH_OPENED_AT")
  [[ -z $LAUNCH_SHOWN_AT ]] || args+=(--shown-at "$LAUNCH_SHOWN_AT")
  [[ -z $LAUNCH_TASK ]] || args+=(--task "$LAUNCH_TASK")
  launch_try rex_rename "$REX_SESSION" "$LAUNCH_WINDOW" "$LAUNCH_REPO · launching"
  printf 'agent-slot-rex: starting an agent in a fresh slot of %s (request %s)\n' "$LAUNCH_REPO" "${args[2]}"
  # Outlasts the server's own bounds end to end: repo lock 60 s, clone 900 s, git-crypt 120 s, trust 45 s, and the
  # three sessions' tmux calls 90 s.
  launch_call 1260 launch "${args[@]}"
  launch_succeeded
}

cmd_launch() {
  contract_use_tools rex agent-slot
  if ((LAUNCH_HERE == 1)); then
    LAUNCH_OPENED_AT=$(launch_opened_at)
    [[ -n ${REX_SESSION:-} && -n ${REX_BLOCK:-} ]] \
      || usage_fail "--here runs only in a Rex terminal, which sets REX_SESSION and REX_BLOCK"
    rex_window_of "$REX_SESSION" "$REX_BLOCK"
    LAUNCH_WINDOW=$REX_OUT
    ((LAUNCH_WAIT_SHOWN == 0)) || launch_repos_early
    ((LAUNCH_WAIT_SHOWN == 0)) || launch_wait_shown
    ((LAUNCH_WAIT_SHOWN == 0)) || LAUNCH_SHOWN_AT=$(launch_now)
  fi
  launch_repos
  LAUNCH_REPOS=$(contract_json -c '[.repos[].name]' <<<"$SERVER_OUT")
  launch_resolve_repo
  if ((LAUNCH_PICKED == 1 || LAUNCH_HERE == 0)); then
    launch_elsewhere
    return
  fi
  if ((LAUNCH_NAMED == 1)) && prime_of "$LAUNCH_REPO" && ! prime_tab_open "$REX_SESSION" "$PRIME_SESSION"; then
    launch_prime
  fi
  launch_here
}
