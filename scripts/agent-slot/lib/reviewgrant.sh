# shellcheck shell=bash
# grant-review: the operator's grant of one more review round for the PR on a slot's current branch. The hook
# stow/claude/dot-claude/slot-review-cap.sh allows 2 rounds per branch and counts a `review-grant` ledger line as one
# more for its branch. A slot's agent never grants: the verb refuses from a slot's directory and from the slot tmux
# server, and an ask rule in settings.json makes a slot's own request for it a denial.

# Usage: cmd_grant_review <repo>/<N>
cmd_grant_review() {
  local key=$1 repo n branch granted since='' rounds grants
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
  [[ -n $branch ]] || contract_fail slot-head-missing "$key has no clone yet, so no branch or commit to grant a \
round on" --value "$key" --command "agent-slot list"
  granted=$(contract_now)
  ledger_append review-grant "$(contract_json -n -c --arg repo "$repo" --argjson slot "$n" --arg branch "$branch" \
    '{repo: $repo, slot: $slot, branch: $branch}')" \
    || contract_fail script-error "the review-grant line for $key was not written to the ledger" --value "$key" \
      --command "agent-slot grant-review $key"
  if record_read "$repo" "$n"; then
    since=$(contract_json -r '.created_at // ""' <<<"$RECORD")
  fi
  rounds=$(review_count review-round "$repo" "$n" "$branch" "$since")
  grants=$(review_count review-grant "$repo" "$n" "$branch" "$since")
  contract_ok "$(contract_json -n -c --arg key "$key" --arg branch "$branch" --arg at "$granted" \
    --argjson rounds "$rounds" --argjson allowed "$((REVIEW_CAP + grants))" \
    '{key: $key, branch: $branch, granted_at: $at, rounds: $rounds, allowed: $allowed}')" \
    '"\(.key): one more review round granted on \(.branch), \(.rounds) of \(.allowed) used; tell the slot agent it can run ce-code-review again"'
}
