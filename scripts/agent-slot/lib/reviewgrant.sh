# shellcheck shell=bash
# grant-review: the operator's grant of one more review round for the PR on a slot's current branch. The hook
# stow/claude/dot-claude/slot-review-cap.sh allows 2 rounds per PR and counts a `review-grant` ledger line as one more
# for its branch. A slot's agent never grants: the verb refuses from a slot's directory and from the slot tmux server.

# Usage: cmd_grant_review <repo>/<N>
cmd_grant_review() {
  local key=$1 repo n branch granted
  slot_parse_key "$key"
  repo=$SLOT_REPO n=$SLOT_N
  if slot_at "$PWD" >/dev/null; then
    contract_fail review-grant-from-slot "grant-review is the operator's to run, and $PWD is inside a slot" \
      --value "$PWD" --command "agent-slot grant-review $key"
  elif [[ ${TMUX:-} == */"$AS_TMUX_SOCKET",* ]]; then
    contract_fail review-grant-from-slot "grant-review is the operator's to run, and this shell runs on the slot tmux \
server" --value "${TMUX%%,*}" --command "agent-slot grant-review $key"
  fi
  slot_taken "$repo" "$n" || contract_fail slot-not-found "$key holds no slot" --value "$key" --command "agent-slot list"
  branch=$(slot_review_key "$(slot_path "$repo" "$n")")
  [[ -n $branch ]] || contract_fail slot-head-missing "$key has no branch or commit to grant a round on" \
    --value "$key" --command "agent-slot check $key"
  granted=$(contract_now)
  ledger_append review-grant "$(contract_json -n -c --arg repo "$repo" --argjson slot "$n" --arg branch "$branch" \
    '{repo: $repo, slot: $slot, branch: $branch}')"
  contract_ok "$(contract_json -n -c --arg key "$key" --arg branch "$branch" --arg at "$granted" \
    '{key: $key, branch: $branch, granted_at: $at}')" '"\(.key): one more review round granted on \(.branch)"'
}
