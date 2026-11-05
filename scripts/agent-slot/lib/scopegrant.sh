# shellcheck shell=bash
# grant-scope: a person's grant of one more path a slot's PR may change. The hook stow/claude/dot-claude/slot-scope-guard.sh
# denies a `git push` of a path no `Touches:` glob of the slot's brief covers, and a `scope-grant` ledger line for the
# slot covers the paths its pathspec matches. A slot's agent and a coordinating session never grant: the verb refuses
# from a slot's directory and from the slot tmux server, an ask rule in settings.json makes a slot's own request for it a
# denial, and it reads a typed confirmation from /dev/tty, which an agent's Bash tool does not have.

# Seconds a person has to type the confirmation, so a shell that shares a terminal with a TUI is not held for good.
SCOPE_GRANT_WAIT=120

# Usage: scope_grant_confirm <key> <pathspec>; returns 0 when the slot's key is typed at the terminal.
scope_grant_confirm() {
  local answer=''
  { exec 3<>/dev/tty; } 2>/dev/null || contract_fail grant-needs-terminal "grant-scope needs a person at a terminal to \
type the confirmation, and this shell has none" --value "$1" --command "agent-slot grant-scope $1 $(contract_quote "$2")"
  printf 'Let %s change paths matching %s in its PR.\nType the slot key, %s, to grant it: ' "$1" "$2" "$1" >&3
  IFS= read -r -t "$SCOPE_GRANT_WAIT" -u 3 answer || true
  exec 3>&-
  [[ $answer == "$1" ]] || contract_fail grant-not-confirmed "the answer was not the slot key, so $2 is not granted to \
$1" --value "$1" --command "agent-slot grant-scope $1 $(contract_quote "$2")"
}

# Usage: cmd_grant_scope <repo>/<N> <pathspec>
cmd_grant_scope() {
  local key=$1 spec=$2 repo n granted since='' grants
  slot_parse_key "$key"
  repo=$SLOT_REPO n=$SLOT_N
  if slot_at "$PWD" >/dev/null; then
    contract_fail scope-grant-from-slot "grant-scope is the operator's to run, and $PWD is inside a slot" \
      --value "$PWD" --command "agent-slot grant-scope $key $(contract_quote "$spec")"
  elif [[ ${TMUX:-} == */"$AS_TMUX_SOCKET",* ]]; then
    contract_fail scope-grant-from-slot "grant-scope is the operator's to run, and this shell runs on the slot tmux \
server" --value "${TMUX%%,*}" --command "agent-slot grant-scope $key $(contract_quote "$spec")"
  fi
  slot_taken "$repo" "$n" || contract_fail slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  git -C "$(slot_path "$repo" "$n")" ls-files -- "$spec" >/dev/null 2>&1 \
    || usage_fail "git does not accept that pathspec" "$spec"
  scope_grant_confirm "$key" "$spec"
  granted=$(contract_now)
  ledger_append scope-grant "$(contract_json -n -c --arg repo "$repo" --argjson slot "$n" --arg spec "$spec" \
    '{repo: $repo, slot: $slot, pathspec: $spec}')" \
    || contract_fail script-error "the scope-grant line for $key was not written to the ledger" --value "$key" \
      --command "agent-slot grant-scope $key $(contract_quote "$spec")"
  if record_read "$repo" "$n"; then
    since=$(contract_json -r '.created_at // ""' <<<"$RECORD")
  fi
  grants=$(scope_grant_count "$repo" "$n" "$since")
  contract_ok "$(contract_json -n -c --arg key "$key" --arg spec "$spec" --arg at "$granted" --argjson grants "$grants" \
    '{key: $key, pathspec: $spec, granted_at: $at, grants: $grants}')" \
    '"\(.key): paths matching \(.pathspec) granted, \(.grants) grant(s) in all; tell the slot agent it can push them"'
}

# Usage: scope_grant_count <repo> <n> <since>; prints the slot's scope-grant lines with a ts at or after <since>.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
scope_grant_count() {
  [[ -r $AS_LEDGER ]] || {
    printf 0
    return 0
  }
  contract_json -R -s -r --arg repo "$1" --argjson n "$2" --arg since "$3" \
    '[split("\n")[] | fromjson? | select(type == "object" and .event == "scope-grant" and .repo == $repo
      and .slot == $n and .ts >= $since)] | length' "$AS_LEDGER"
}
