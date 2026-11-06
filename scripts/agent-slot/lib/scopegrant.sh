# shellcheck shell=bash
# grant-scope: an operator's grant of one more path a slot's PR may change. The hook
# stow/claude/dot-claude/slot-scope-guard.sh denies a `git push` of a path no `Touches:` glob of the slot's brief
# covers, and a `scope-grant` ledger line for the slot covers the paths its pathspec matches. The verb refuses from a
# slot's directory and from the slot tmux server, an ask rule in settings.json makes a slot's own request for it a
# denial, and it reads a typed confirmation from /dev/tty, which an agent's Bash tool does not have. It is a guard, not a
# trust boundary: a shell that can give a command a pseudo-terminal, or write the ledger, can still grant.

# Seconds a person has to type the confirmation, so a shell that shares a terminal with a TUI is not held for good.
SCOPE_GRANT_WAIT=120

# Usage: scope_grant_command <key> <pathspec>
scope_grant_command() {
  printf 'agent-slot grant-scope %s %s' "$1" "$(contract_quote "$2")"
}

# Usage: scope_grant_survey <repo> <n> <pathspec>; compares the slot's branch with origin/<base>. Sets
# SCOPE_STATE to nobase (the clone has no origin/<base>), nochange (the branch changes no paths), or ok; SCOPE_CHANGED
# to the changed paths, one per line; SCOPE_COVERED to those this pathspec matches; and SCOPE_OUTSIDE to how many are
# still matched by none of the brief's Touches: globs, the slot's earlier grants, and this pathspec.
SCOPE_STATE='' SCOPE_CHANGED='' SCOPE_COVERED='' SCOPE_OUTSIDE=0 SCOPE_BASE=''
scope_grant_survey() {
  local path against all since
  local -a specs=()
  SCOPE_STATE=nobase SCOPE_CHANGED='' SCOPE_COVERED='' SCOPE_OUTSIDE=0 SCOPE_BASE=''
  path=$(slot_path "$1" "$2")
  record_read "$1" "$2" || return 0
  SCOPE_BASE=$(contract_json -r '.base // empty' <<<"$RECORD")
  since=$(contract_json -r '.task_started_at // .created_at // ""' <<<"$RECORD")
  [[ -n $SCOPE_BASE ]] && git -C "$path" rev-parse -q --verify "origin/$SCOPE_BASE" >/dev/null 2>&1 || return 0
  against="origin/$SCOPE_BASE...HEAD"
  SCOPE_CHANGED=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "$against" 2>/dev/null) || return 0
  SCOPE_STATE=nochange
  [[ -n $SCOPE_CHANGED ]] || return 0
  SCOPE_STATE=ok
  SCOPE_COVERED=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "$against" -- "$3" 2>/dev/null) \
    || return 0
  mapfile -t specs < <(contract_json -r '.scope.touches[]?' <<<"$RECORD"; scope_grants "$1" "$2" "$since"; printf '%s\n' "$3")
  all=$(git -C "$path" -c core.quotePath=false diff --name-only --no-renames "$against" -- "${specs[@]}" 2>/dev/null) \
    || all=$SCOPE_COVERED
  SCOPE_OUTSIDE=$(comm -23 <(sort -u <<<"$SCOPE_CHANGED") <(sort -u <<<"$all") | grep -c . || true)
}

# Usage: scope_grant_confirm <key> <pathspec>; returns 0 when the slot's key is typed at the terminal.
scope_grant_confirm() {
  local answer='' command status
  command=$(scope_grant_command "$1" "$2")
  [[ -z ${CLAUDECODE:-} ]] || contract_fail grant-needs-terminal "grant-scope needs a person at a terminal, and this \
shell runs under Claude Code (CLAUDECODE is set), where a terminal can be faked. Run it from a terminal window on this \
host, outside any Claude session" --value "$1" --command "$command"
  { exec 3<>/dev/tty; } 2>/dev/null || contract_fail grant-needs-terminal "grant-scope needs a person at a terminal to \
type the confirmation, and this shell has none. Run it from a terminal window on this host, outside any Claude session \
(ssh -t from another machine)" --value "$1" --command "$command"
  printf 'Let %s push paths matching %s.\n' "$1" "$(contract_quote "$2")" >&3
  case $SCOPE_STATE in
    nobase) printf 'This clone has no origin/%s to compare with, so what it covers is not shown.\n' "${SCOPE_BASE:-base}" >&3 ;;
    nochange) printf 'The branch changes no paths against origin/%s yet.\n' "$SCOPE_BASE" >&3 ;;
    *)
      printf 'It covers:\n  %s\n' "${SCOPE_COVERED//$'\n'/$'\n'  }" >&3
      if ((SCOPE_OUTSIDE == 0)); then
        printf 'With it, every changed path is covered, so the next push goes through.\n' >&3
      elif ((SCOPE_OUTSIDE == 1)); then
        printf '1 changed path stays outside the brief and the grants.\n' >&3
      else
        printf '%s changed paths stay outside the brief and the grants.\n' "$SCOPE_OUTSIDE" >&3
      fi
      printf 'Later changes it matches are covered too.\n' >&3
      ;;
  esac
  printf 'Type the slot key, %s, to grant it: ' "$1" >&3
  IFS= read -r -t "$SCOPE_GRANT_WAIT" -u 3 answer && status=0 || status=$?
  if ((status != 0)); then
    printf '\n' >&3
    exec 3>&-
    contract_fail grant-not-confirmed "$( ((status > 128)) && echo "no answer was typed within $SCOPE_GRANT_WAIT s" \
      || echo "the input ended with no answer"), so $2 is not granted to $1" --value "$1" --command "$command"
  fi
  exec 3>&-
  [[ $answer == "$1" ]] || contract_fail grant-not-confirmed "the answer was not the slot key, so $2 is not granted to \
$1" --value "$1" --command "$command"
}

# Usage: cmd_grant_scope <repo>/<N> <pathspec>
cmd_grant_scope() {
  local key=$1 spec=$2 repo n granted since='' grants err command
  slot_parse_key "$key"
  repo=$SLOT_REPO n=$SLOT_N
  command=$(scope_grant_command "$key" "$spec")
  if slot_at "$PWD" >/dev/null; then
    contract_fail scope-grant-from-slot "grant-scope is the operator's to run, and $PWD is inside a slot. Run it from a \
shell outside the slot directory and off the slot tmux server" --value "$PWD" --command "$command"
  elif [[ ${TMUX:-} == */"$AS_TMUX_SOCKET",* ]]; then
    contract_fail scope-grant-from-slot "grant-scope is the operator's to run, and this shell runs on the slot tmux \
server. Run it from a shell outside the slot directory and off the slot tmux server" --value "${TMUX%%,*}" \
      --command "$command"
  fi
  slot_taken "$repo" "$n" || contract_fail slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  [[ -d $(slot_path "$repo" "$n")/.git ]] || contract_fail slot-busy "$key is still being set up, so it has no clone to \
check the pathspec in" --value "$key" --command "$command"
  if [[ $spec == *[[:cntrl:]]* ]]; then
    usage_fail "a pathspec cannot hold a control character, such as a newline" "$(printf '%q' "$spec")"
  fi
  if [[ $spec =~ ^:[/!^]*[!^] || $spec == :\(*exclude* ]]; then
    usage_fail "an exclude pathspec takes coverage away, so it cannot be granted" "$spec"
  fi
  err=$(git -C "$(slot_path "$repo" "$n")" ls-files -- "$spec" 2>&1 >/dev/null) \
    || usage_fail "git does not accept that pathspec: ${err#fatal: }" "$spec"
  scope_grant_survey "$repo" "$n" "$spec"
  if [[ $SCOPE_STATE == ok && -z $SCOPE_COVERED ]]; then
    usage_fail "that pathspec covers none of the $(grep -c . <<<"$SCOPE_CHANGED") paths this slot's branch changes \
against origin/$SCOPE_BASE: ${SCOPE_CHANGED//$'\n'/, }" "$spec"
  fi
  scope_grant_confirm "$key" "$spec"
  granted=$(contract_now)
  ledger_append scope-grant "$(contract_json -n -c --arg repo "$repo" --argjson slot "$n" --arg spec "$spec" \
    '{repo: $repo, slot: $slot, pathspec: $spec}')" \
    || contract_fail script-error "the scope-grant line for $key was not written to the ledger" --value "$key" \
      --command "$command"
  if record_read "$repo" "$n"; then
    since=$(contract_json -r '.task_started_at // .created_at // ""' <<<"$RECORD")
  fi
  grants=$(scope_grants "$repo" "$n" "$since" | grep -c . || true)
  contract_ok "$(contract_json -n -c --arg key "$key" --arg spec "$spec" --arg at "$granted" --argjson grants "$grants" \
    '{key: $key, pathspec: $spec, granted_at: $at, grants: $grants}')" \
    '"\(.key): paths matching \(.pathspec) granted, \(.grants) grant(s) in all; tell the slot agent it can push them"'
}
