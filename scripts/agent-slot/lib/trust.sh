# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# Claude's workspace trust for slot paths.
#
# Claude keys trust on the path and records it as hasTrustDialogAccepted in its app-state file. That key is not a
# supported interface, so it is only ever read here, and a missing or unreadable entry counts as untrusted. Nothing
# pre-trusts a path, so trust_accept answers Claude's own dialog: it starts Claude at the path in a scratch pane on its
# own tmux socket, which the slot hooks ignore, and reads the screen. This is the one place to replace once Claude
# offers a supported way to trust a path.
#
# Trusting a path lets Claude load the repo's own .claude settings and hooks, so a slot path is trusted only for a repo
# whose prime checkout the operator has already trusted in Claude. Any other repo's launch shows trust needed.

TRUST_LOG=

# Usage: trust_known <path>; true when Claude's app-state file marks the path's realpath trusted.
trust_known() {
  local real
  real=$(realpath -m "$1")
  [[ -r $AS_CLAUDE_STATE ]] || return 1
  [[ $(contract_json -r --arg p "$real" '.projects[$p].hasTrustDialogAccepted // false' "$AS_CLAUDE_STATE" \
    2>/dev/null) == true ]]
}

# Usage: _trust_screen <screen> <realpath>
# Prints dialog-no or dialog-yes (the dialog for this path, with that option highlighted), other-dialog, prompt, or
# unknown.
_trust_screen() {
  local lines
  lines=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$1")
  if grep -qF 'Accessing workspace:' <<<"$lines"; then
    if ! grep -qxF -- "$2" <<<"$lines"; then
      echo other-dialog
    elif grep -qx '❯ Yes, I trust this folder' <<<"$lines"; then
      echo dialog-yes
    elif grep -qx '❯ No, exit' <<<"$lines" && grep -qx 'Yes, I trust this folder' <<<"$lines"; then
      echo dialog-no
    else
      echo other-dialog
    fi
  elif grep -qE '^❯( |$)' <<<"$lines" && ! grep -qE 'No, exit|Yes, I trust' <<<"$lines"; then
    echo prompt
  else
    echo unknown
  fi
}

_trust_kill() {
  local out
  bounded out trust-kill 5 "$AS_TMUX" -L "$AS_TRUST_SOCKET" kill-session -t "=$1" || true
}

# Usage: trust_accept <path>
# Returns 0 once the path is trusted (accepted here, or already), 1 when the screen was not one it recognizes; then
# TRUST_LOG holds the last screen.
trust_accept() {
  local path=$1 real session screen='' out kind='' accepted=0 last_key=0 deadline
  real=$(realpath -m "$path")
  session=trust-$$-${path//[^A-Za-z0-9]/_}
  TRUST_LOG=
  contract_on_exit _trust_kill "$session"
  if ! bounded out trust-start 10 /usr/bin/env -i -C / HOME="$HOME" USER="$USER" LOGNAME="$USER" \
    TERM=xterm-256color LANG="${LANG:-C.UTF-8}" PATH="$PATH" \
    "$AS_TMUX" -L "$AS_TRUST_SOCKET" -f /dev/null new-session -d -s "$session" -x 240 -y 50 -c "$path" "$AS_CLAUDE"; then
    TRUST_LOG=$BOUNDED_LOG
    return 1
  fi
  # The screen decides each key: Down only while "No, exit" is highlighted and Enter only once "Yes" is, each sent again
  # when the screen has not moved a second or two later. A key sent while the dialog is still drawing is lost, and
  # Enter never lands on "No, exit". Times are EPOCHREALTIME in microseconds: SECONDS counts the wall clock's whole
  # seconds, so a gap of one in it can be a few milliseconds long and a deadline set from it up to a second short.
  deadline=$((${EPOCHREALTIME/./} + AS_TRUST_TIMEOUT * 1000000))
  while ((${EPOCHREALTIME/./} < deadline)); do
    if bounded screen trust-capture 5 "$AS_TMUX" -L "$AS_TRUST_SOCKET" capture-pane -p -J -t "=$session:"; then
      kind=$(_trust_screen "$screen" "$real")
      case $kind in
        dialog-no)
          if ((${EPOCHREALTIME/./} - last_key >= 1000000)); then
            bounded out trust-keys 5 "$AS_TMUX" -L "$AS_TRUST_SOCKET" send-keys -t "=$session:" Down || true
            last_key=${EPOCHREALTIME/./}
          fi
          ;;
        dialog-yes)
          if ((accepted == 0 || ${EPOCHREALTIME/./} - last_key >= 2000000)); then
            bounded out trust-keys 5 "$AS_TMUX" -L "$AS_TRUST_SOCKET" send-keys -t "=$session:" Enter || true
            accepted=1 last_key=${EPOCHREALTIME/./}
          fi
          ;;
        prompt) break ;;
        other-dialog) ((accepted == 1)) || break ;;
      esac
      ((accepted == 0)) || ! trust_known "$path" || {
        kind=prompt
        break
      }
    fi
    sleep 0.5
  done
  _trust_kill "$session"
  [[ $kind == prompt ]] && return 0
  mkdir -p "$AS_LOG_DIR"
  TRUST_LOG="$AS_LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$$-trust-screen.log"
  printf 'path: %s\nscreen (%s):\n%s\n' "$real" "${kind:-none}" "${screen:-}" >"$TRUST_LOG"
  return 1
}

# Usage: warm_paths <repo> <count>
# Trusts slot paths 1..count ahead of time, creating each empty directory first, when the repo's prime checkout
# (REPO_PRIME) is trusted. A path that holds a clone or a claim is left alone. Sets WARM_RESULTS to one JSON object
# per path.
WARM_RESULTS=()
warm_paths() {
  local repo=$1 count=$2 n path result prime_trusted=0
  WARM_RESULTS=()
  ! trust_known "$REPO_PRIME" || prime_trusted=1
  for ((n = 1; n <= count; n++)); do
    path=$(slot_path "$repo" "$n")
    if slot_taken "$repo" "$n"; then
      result=in-use
    elif trust_known "$path"; then
      result=already-trusted
    elif ((prime_trusted == 0)); then
      result=prime-untrusted
    else
      mkdir -p "$path"
      if trust_accept "$path"; then result=trusted; else result=unrecognized; fi
    fi
    WARM_RESULTS+=("$(contract_json -n -c --arg p "$path" --arg k "$(slot_key "$repo" "$n")" --arg r "$result" \
      --arg log "${TRUST_LOG:-}" '{key: $k, path: $p, result: $r} + (if $r == "unrecognized" then {log: $log} else {} end)')")
  done
}

WARM_REPO='' WARM_COUNT=3
warm_parse_args() {
  while (($#)); do
    case $1 in
      --count)
        [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || usage_fail "--count takes a positive number" "${2:-}"
        WARM_COUNT=$2
        shift 2
        ;;
      -*) usage_fail "unknown option $1" "$1" ;;
      *)
        [[ -z $WARM_REPO ]] || usage_fail "warm takes one repo" "$1"
        WARM_REPO=$1
        shift
        ;;
    esac
  done
  [[ -n $WARM_REPO ]] || usage_fail "warm needs a repo; agent-slot repos lists them"
}

cmd_warm() {
  local repo=$1 count=$2 json bad
  require_tools tmux claude
  repo_prime "$repo"
  mkdir -p "$AS_ROOT/$repo"
  warm_paths "$repo" "$count"
  json=$(printf '%s\n' "${WARM_RESULTS[@]}" | contract_json -s -c '{paths: .}')
  bad=$(contract_json -r '[.paths[] | select(.result == "unrecognized")][0] // empty | .path' <<<"$json")
  if [[ -n $bad ]]; then
    contract_fail trust-dialog-unrecognized \
      "Claude showed a screen at $bad that is not its trust dialog for that path, so the path was left untrusted" \
      --value "$bad" --command "cd $bad && claude" --side-effects partial \
      --log "$(contract_json -r '[.paths[] | select(.result == "unrecognized")][0].log' <<<"$json")"
  fi
  contract_ok "$json" '.paths[] | "\(.key)\t\(.result)"'
}
