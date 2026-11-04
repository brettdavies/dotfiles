#!/usr/bin/env bash
# SessionStart Claude hook: gives an agent in a slot its slot context. Inside a slot (the payload's cwd, or the working
# directory, under the slot root with a record) and only for the pane's top-level Claude in the slot's Claude session
# (see scripts/agent-slot/lib/hook.sh), it:
#   - records the payload's session ID and its transcript (sessions_transcript_of) in the slot record, and appends a
#     `session` ledger line when either changed (a /clear starts a new session);
#   - on the slot's first start sets the record's ready_at and, when the launch carried a request ID, appends the
#     `ready` ledger line that agent-slot doctor joins to the launch line;
#   - prints SessionStart additionalContext naming the slot, its task and work items, and its working rules.
# Anywhere else it prints nothing. Always exits 0; failures go to the agent-slot hooks.log.

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  echo "ERROR: needs bash >= 4.4 (running $BASH_VERSION); install it with: brew install bash" >&2
  exit 1
fi

AS_HOME=$(readlink -f "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../scripts/agent-slot")

# Usage: context_record <repo> <n>
# Under the slot lock, so the first-start check and the ready line happen once.
# shellcheck disable=SC2016 # jaq programs; their $names are bound with --arg
context_record() {
  local repo=$1 n=$2 sid transcript source ready old_sid old_transcript first request task
  sid=$(hook_field .session_id)
  transcript=$(sessions_transcript_of "$sid" "$(hook_field .transcript_path)")
  source=$(hook_field .source)
  # EPOCHREALTIME uses the locale's decimal mark, and --argjson needs a period.
  ready=${EPOCHREALTIME:-}
  ready=${ready/,/.}
  [[ -n $ready ]] || ready=$(printf '%(%s)T' -1)
  if ! record_lock_slot "$repo" "$n" --wait 10; then
    hook_log "slot $repo/$n lock not taken; session $sid not recorded"
    return 0
  fi
  if ! record_read "$repo" "$n"; then
    record_unlock_slot "$repo" "$n"
    return 0
  fi
  IFS=$'\t' read -r old_sid old_transcript first request task <<<"$(contract_json -r '[.session_id // "-",
    .transcript // "-", (.ready_at == null | tostring), .request_id // "-", .task // "-"] | join("\t")' <<<"$RECORD")"
  record_update "$repo" "$n" --arg sid "$sid" --arg tr "$transcript" --argjson ready "$ready" '
    (if $sid != "" then .session_id = $sid else . end)
    | (if $tr != "" then .transcript = $tr else . end)
    | (if .ready_at == null then .ready_at = $ready else . end)'
  if [[ -n $sid$transcript && ($sid != "$old_sid" || $transcript != "$old_transcript") ]]; then
    ledger_append session "$(contract_json -n -c --arg repo "$repo" --argjson slot "$n" --arg task "$task" \
      --arg sid "$sid" --arg tr "$transcript" --arg source "$source" \
      '{repo: $repo, slot: $slot, task: (if $task == "-" then null else $task end), session_id: $sid,
        transcript: $tr, source: $source}')"
  fi
  if [[ $first == true && $request != - ]]; then
    ledger_append ready "$(contract_json -n -c --arg id "$request" --argjson at "$ready" --arg repo "$repo" \
      --argjson slot "$n" --arg sid "$sid" \
      '{request_id: $id, ready_at: $at, repo: $repo, slot: $slot, session_id: $sid}')"
  fi
  record_unlock_slot "$repo" "$n"
}

# Usage: context_text <repo> <n>; prints the SessionStart output for the record in RECORD. The lines reach jaq as data
# through --arg, never as part of its program, so an apostrophe or a backtick in one prints as written.
# shellcheck disable=SC2016 # a jaq program; its $names are bound with --arg
context_text() {
  local task items base prime solutions rules plans closing rules_after reopen unattended vault_rules='' deps
  local finished='Your task is finished when its PRs are open, or merged if the brief says so, and nothing is left unpushed.'
  task=$(contract_json -r '.task // ""' <<<"$RECORD")
  items=$(contract_json -r '.items // [] | map("\(if .kind == "pr" then "PR" else .kind end) \(.repo)#\(.number)"
    + (if (.title // "") == "" then "" else " (\(.title))" end)) | join(", ")' <<<"$RECORD")
  base=$(contract_json -r '.base // "the default branch"' <<<"$RECORD")
  prime=$(contract_json -r '.prime // "for this repo"' <<<"$RECORD")
  if [[ -n $(record_solutions_worktree) ]]; then
    solutions="docs/solutions is this slot's own worktree of the solutions repo, which no other agent writes in; \
publish from it only through \`sd-commit-doc\`, and the slot is not torn down while it holds anything unpublished."
  else
    solutions='docs/solutions is the solutions repo shared with every other agent; commit to it only through `sd-commit-doc`.'
  fi
  deps=$(contract_json -r 'def more($list; $total): ($total // ($list | length)) - ($list | length) | if . > 0 then " and \(.) more" else "" end;
    (.prime // "its prime checkout") as $prime
    | (.base // "the base branch") as $base
    | (.base // "<base>") as $base_ref
    | .deps // {}
    | ((.dirty // []) | if length > 0
       then "The install left these changed, untracked, or ignored, which can block teardown or land in a commit: \(join(", "))"
         else "" end) as $dirty_names
    | (if $dirty_names == "" then "" else $dirty_names + more(.dirty; .dirty_total) + "."
         + " Restore or remove what you do not mean to keep." end) as $dirty
    | ((.stopped // []) | if length > 0 then "Setup stopped what the install left running: \(join(", "))" else "" end) as $stopped_names
    | (if $stopped_names == "" then "" else $stopped_names + more(.stopped; .stopped_total) + "." end) as $stopped
    | "An install runs code the tree names, any tracked file can change what it runs, such as pnpm-workspace.yaml,"
      + " binding.gyp, or .env, and --ignore-scripts stops only the scripts. Read the whole of"
      + " `git diff origin/\($base_ref)...HEAD`, or the whole tree when the head is on \($base), before you run it, and if"
      + " you cannot, leave it uninstalled and say so in your report. A frozen install also takes what a lockfile pins"
      + " without the supply-chain age gate." as $read
    | " If your head has since left the base branch, read what it changes first." as $moved
    | "`git -C \($prime) fetch origin \($base_ref):\($base_ref)`" as $fetch
    | (.off_base // "") as $off_base
    | ({"prime-lacks-base": "the prime holds no branch named \($base), so nothing shows that base has been chosen on this host",
        "base-rewritten": "origin'"'"'s \($base) no longer holds what the prime last knew of it, so its history has been replaced",
        "base-lacks-head": "\($base) does not hold this head",
        "pr-base-lacks-head": "the branch this PR targets does not hold this head",
        "pr-head-behind-base": ("this PR'"'"'s head is behind \($base), and a head set back to an older commit can bring"
          + " back what \($base) has since removed")}[$off_base]
       // "the base branch does not hold this head") as $cause
    | (if $off_base == "" and .status != "head-not-on-base" then "" else
        " This head'"'"'s git hooks, .claude settings, and CLAUDE.md are unread too, and they run or load whether or not"
        + " you install." end) as $hooks
    | (if (.status // "installed") == "installed" then "" else
      "When this slot was made, `\(.command)` "
      + ({failed: "failed; its log is \(.log).",
          "timed-out": "hit the AGENT_SLOT_DEPS_TIMEOUT limit; its log is \(.log).",
          "tool-missing": "could not run, because \(.manager) is not on this host'"'"'s PATH.",
          "not-ignored": "was not run, because this repo does not ignore node_modules.",
          "prime-not-set-up": ("was not run, because this repo'"'"'s prime is untrusted or its node_modules holds no"
            + " package, so nothing shows its install has been chosen on this host."),
          "head-not-on-base": "was not run, because \($cause)."}[.status]
         // "reported \(.status).")
      + " If it has not succeeded since, the repo'"'"'s hooks fail their tool gates, so deal with that before your first"
      + " push. "
      + ({failed: ("Read the log, fix what it names, and rerun the command from the slot root." + $moved),
          "timed-out": ("Rerun it from the slot root, where that limit does not apply." + $moved),
          "tool-missing": "Installing a package manager is a host change, so report this to whoever you report to.",
          "not-ignored": ("Installing here leaves an untracked tree that blocks teardown and can land in a commit, so add"
            + " node_modules/ to .gitignore first if your task allows that, and otherwise report it."),
          "prime-not-set-up": ($read + $hooks + " Later slots of this repo install on their own once the operator has"
            + (if $off_base == "prime-lacks-base" then " run \($fetch), has" else "" end)
            + " run this install in the prime at \($prime) and opened Claude there."),
          "head-not-on-base": ($read + $hooks
            + (if $off_base == "prime-lacks-base"
               then " Later slots of this repo install on their own once the operator has run \($fetch)."
               else "" end))}[.status] // "") end) as $status_line
    | [$status_line, $dirty, $stopped] | map(select(. != "")) | join(" ")' <<<"$RECORD")
  rules=$(
    cat <<'EOF'
`agent-slot whoami` names this slot.
Run agent-slot verbs with `--output json` after the verb; `--help` on any verb lists its flags and fields.
`agent-slot schema --output json` prints the whole contract: the success and error objects and every reason.
To hand a task to another agent, run `agent-slot launch <repo> --request-id <id> --prompt-file <brief>`.
A slot you launch is independent: hand off the brief, report its key, and don't wait on it or watch it.
Launching a slot is not a delegated wait: set no watchdog or watcher on it; watch your own PRs and CI to the end.
Claude runs here with `--dangerously-skip-permissions`; ask rules, deny rules, and hooks still stop tool calls.
EOF
  )
  unattended="You run unattended: nobody answers a prompt or a question in this tab, so a hook denies every \
permission request, \`AskUserQuestion\`, and plan mode here; do the work another way within your brief, and send a \
decision only a person can make to the session your brief reports to."
  plans=$(
    printf '%s\n' \
      "Run every plan you write through \`/plan-eng-review\`, \`/plan-devex-review\`, then \
\`/compound-engineering:ce-doc-review\`, and commit and push the plan once it is written and again after each review." \
      "Answer each review question yourself where the code, the repo's docs, \`docs/solutions\`, or precedent settles \
it, and record the choice and its evidence in the plan." \
      "Nobody watches this tab, so a question asked here, \`AskUserQuestion\` included, is never answered. Send a \
decision only a person can make, such as a name, a breaking change, a version call, or a scope cut, to the session \
your brief reports to as one \`SendMessage\`: the question, the options, your recommendation, and its evidence." \
      "Keep working on what that decision does not block, then end your turn; the answer arrives as a message. If the \
brief names no such session, leave the decision open in the plan and in your report."
  )
  if [[ $1 == "$VAULT_REPO" ]]; then
    finished='Your task is finished when its work is on origin/main and nothing is left unpushed.'
    vault_rules=$(
      cat <<'EOF'
This is the Obsidian vault. Nothing automated commits in the vault, and the operator wants no autocommits there.
Commit only your own task's work, on main, with no branch or PR, and stage each path by name.
Run `git fetch` then `git rebase origin/main` before each push, so parallel slots never clobber each other; never force-push.
The vault is sensitive: put no vault content in docs/solutions, another repo, a PR body, or any outside service.
When you run the closing skills, record only a tooling or process lesson, with no note title, path, name, or quotation, and discard any draft that needs one.
A slot clones from origin, so it holds only what is pushed; ~/obsidian-vault gets your work when the operator pulls there.
EOF
    )
  fi
  closing=$(
    printf '%s\n' \
      "$finished" \
      "Then close it out, in this order:" \
      "1. Run \`$RELEASE_COMPOUND\` once per finding from this session, one full run each, and once even when \
none qualifies." \
      "2. Run \`$RELEASE_REFRESH\` across every refresh opportunity those runs surfaced, or scoped to the area you \
touched." \
      "3. Before you release, ${RELEASE_CLEANUP/commit and PR/$(release_deliver "$1")}." \
      "4. Stop every background job you no longer need. $RELEASE_WAITING" \
      "5. Run \`$RELEASE_COMMAND\`; it refuses until both skills have run and while a background job of yours still \
runs, and tears the slot down once you are idle and its task has finished." \
      "6. Then report what you did and stop."
  )
  rules_after=$(
    cat <<'EOF'
You need not run `agent-slot check` on this slot; you are busy running it, so it reports `checked-by-own-agent`.
`agent-slot sweep` and `agent-slot finish` delete slots: ask the operator before running either with `--yes`.
In a review round, re-check the state of the PR before stacking new commits on it.
Stage with `git add`, then run a plain `git commit`; never `git commit -a` or `git commit <path>`.
Create no git worktrees inside this slot.
EOF
  )
  reopen="\`agent-slot reopen\` asks for permission, \`--help\` and \`--dry-run\` included, and nobody here can grant \
it: send a reopen to the session your brief reports to."
  contract_json -n -c --arg text "$(
    printf '%s\n' "You are working in agent slot $(slot_key "$1" "$2"), a clone at $(slot_path "$1" "$2")."
    if [[ -n $task ]]; then printf 'Task: %s.\n' "$task"; else printf '%s\n' 'This slot was given no task name.'; fi
    [[ -z $items ]] || printf 'Work items: %s.\n' "$items"
    printf '%s\n' "The base branch is $base." \
      "The prime checkout $prime is read-only for you; make every change in this slot."
    [[ -z $vault_rules ]] || printf '%s\n' "$vault_rules"
    [[ -z $deps ]] || printf '%s\n' "$deps"
    printf '%s\n' "$solutions" "$rules" "$unattended" "$plans" "$closing" \
      "$rules_after" "$reopen"
  )" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $text}}'
}

context_main() {
  local dir at repo n
  hook_use_socket "${TMUX%%,*}" || return 0
  dir=$(hook_field .cwd)
  at=$(slot_at "${dir:-$PWD}") || return 0
  read -r repo n <<<"$at"
  record_read "$repo" "$n" || return 0
  hook_pane || return 0
  [[ $HOOK_PANE_SESSION == "$(slot_session "$repo" "$n")" ]] && hook_top_level_claude || return 0
  context_record "$repo" "$n"
  record_read "$repo" "$n" || return 0
  context_text "$repo" "$n"
}

HOOK_PAYLOAD_IN=$(cat)
[[ -n ${TMUX:-} && -n ${TMUX_PANE:-} ]] || exit 0
(
  set -euo pipefail
  shopt -s inherit_errexit
  exec 2>/dev/null
  # shellcheck source=/dev/null
  source "$AS_HOME/lib/hook.sh"
  hook_init slot-context "$AS_HOME"
  # shellcheck disable=SC2034 # read by hook.sh
  HOOK_PAYLOAD=$HOOK_PAYLOAD_IN
  out=$(context_main)
  [[ -z $out ]] || printf '%s\n' "$out"
) </dev/null
exit 0
