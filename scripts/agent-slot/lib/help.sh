# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# agent-slot's usage text and each verb's --help: a usage line, what the verb does, the fields its JSON object carries,
# and one example. VERBS is the closed set the dispatcher accepts.

USAGE='usage: agent-slot <verb> [options] [--output json]

Verbs:
  repos    list the prime checkouts a slot can be made from
  list     list every slot with its state, agent, task, and what blocks its teardown
  whoami   print the slot the current directory is inside
  launch   start an agent in a fresh slot of a repo, optionally with its first message
  resume   bring back the tmux sessions and Claude conversation of a slot
  prime    start the prime of a repo if it is not running, and say where it runs
  retask   give a live slot a new task, in a new Claude session
  warm     trust the slot paths of one repo, or of every repo, in Claude ahead of time
  check    judge whether each slot can be torn down, and list what blocks it
  adopt    attach a PR or issue to a live slot, naming the slot if it has no name
  probe    mark a draft this slot pushed, titled test(probe): <what it probes>, so closing it does not block teardown
  close-probe  close a draft this slot marked a probe; run from inside the slot
  reopen   bring the work of a torn-down slot on a PR or issue back in a fresh slot, resuming its conversation
  sweep    tear down every slot whose task has finished and that check passes (reports only, without --yes)
  finish   mark a task finished and tear its slot down if check passes (reports only, without --yes)
  grant-review  allow a slot one more review round for the PR on its current branch (operator or prime)
  grant-scope  let a slot'"'"'s PR change one more path, confirmed at a terminal (operator only)
  release  hand this slot'"'"'s teardown upstream once its agent has run the closing skills; run from inside the slot
  doctor   check every launch prerequisite and summarize launch times
  schema   print the JSON Schema of the objects agent-slot prints, and every error reason

Every verb takes --output json (one JSON object on stdout, or an error object on stderr) and --help.
Exit codes: 0 ok, 1 failed, 2 usage, 77 auth, 78 configuration.
Reasons and their fixes: https://github.com/brettdavies/dotfiles/blob/main/README.md#agent-slot-reasons'

VERBS=' repos list whoami launch resume prime retask warm check adopt probe close-probe reopen sweep finish grant-review grant-scope release doctor schema '

verb_help() {
  case $1 in
    repos) printf '%s\n' 'usage: agent-slot repos [--output json]' \
      'Lists each git repo under ~/dev, and each one AGENT_SLOT_EXTRA_PRIMES names, that has an origin. A repo goes by' \
      "its directory's name, so the Obsidian vault is obsidian-vault." \
      'returns: repos[] of {name, prime, origin}' \
      'example: agent-slot repos --output json' ;;
    list) printf '%s\n' 'usage: agent-slot list [--output json]' \
      'Lists every slot with its state, agent state, label, and its needs-you blockers, and every running prime. A' \
      'slot'"'"'s label is its name, else its task, else its branch. A tmux server that does not answer costs only its own' \
      'primes, and primes_unread names it, so a prime missing from the list is proof only while that is empty.' \
      'returns: slots[] of the slot record plus {key, path, state, branch, label_name, agent, agent_detail, sessions,' \
      '         needs_you}, and primes[] of {key, repo, server, session, label}, where server is slots, or default for' \
      '         a session on the default tmux server that holds the prime, and primes_unread[], the servers it could' \
      '         not read' \
      "example: agent-slot list --output json | jaq '.slots[] | select(.needs_you != [])'" ;;
    whoami) printf '%s\n' 'usage: agent-slot whoami [--path DIR] [--output json]' \
      'Prints the slot that DIR (default: the current directory) is inside. Outside a slot it fails with the error' \
      'reason not-in-slot (exit 1).' \
      'returns: slot, the slot record plus {key, path, label_name}; the record has head_foreign and head_owner only' \
      '         when its head is a foreign head' \
      'example: agent-slot whoami --output json' ;;
    launch) printf '%s\n' \
      'usage: agent-slot launch <repo> --model (opus | sonnet) [--pr <ref> | --issue <ref>] [--request-id ID]' \
      '                         [--task NAME] [--prompt-file FILE] [--requested-at EPOCH] [--opened-at EPOCH]' \
      '                         [--shown-at EPOCH] [--output json]' \
      'Clones the repo into its lowest free slot, sets it up like the prime checkout, and starts Claude there with' \
      '--dangerously-skip-permissions on the --model given, at --effort xhigh, on the slot profile, which drops a few' \
      'tools, skills, and plugins (see the README); a sonnet slot also gets opus as its advisor. It also starts the' \
      'repo'"'"'s prime, whose Claude runs on the account'"'"'s own model and effort with no profile. Every launch names a' \
      'model. A repeat with the same --request-id, --task, or work item returns the same' \
      'slot, except that a --prompt-file the slot would not receive (another request, or this request under a' \
      'different brief) is refused with item-held-by-slot rather than dropped, and a --model other than the one that' \
      'slot runs on is refused with model-differs. A --prompt-file needs a line for each of Scope:, Limits:,' \
      'Reviews:, Reports to:, Touches:, and Adds:, each with a value, or the launch is refused with brief-incomplete.' \
      'Touches: lists the paths the PR may change as comma-separated git pathspec globs, and Adds: the public surface' \
      'it may add or none; both go into the slot record as scope, and slot-scope-guard.sh denies a git push of a path' \
      'no Touches: glob covers.' \
      'Agents always pass --request-id. ID: letters, digits, ., _, and -, up to 128. NAME: letters, digits, _,' \
      '-, and /, starting with a letter or digit, up to 64, and not ending in -prime, which names a repo'"'"'s prime. A new' \
      'slot pushes a restore to the Rex helper on this' \
      "host, so its tab opens in Rex; the push runs in the background and is logged to $AS_STATE_DIR/push.log." \
      '--pr or --issue gives the slot a work item and a name from it, <repo>-pr<N>-<slug> or <repo>-issue<N>-<slug>,' \
      'which its Claude session takes and which is the task when --task is not given. A ref is N (in the origin' \
      'repo), owner/name#N, or its GitHub URL, such as https://github.com/owner/name/pull/N. A PR'"'"'s head branch is' \
      'checked out tracking the remote that holds it: origin, the remote the prime checkout has for that repo, or' \
      'fork. A head whose branch or repository is gone is checked out from refs/pull/N/head with no upstream, and' \
      'head_pushable is false. An issue leaves the base branch checked out.' \
      "A head in a repo whose owner is outside AGENT_SLOT_TRUSTED_OWNERS or cannot be determined, on a fork or on the" \
      "PR's own repo, is a foreign head: head_foreign is true, Claude starts with user settings only, and git" \
      'gets no hooks. To run a fork once someone has reviewed it, tear its slot down and launch again with its owner' \
      "added for that one command: AGENT_SLOT_TRUSTED_OWNERS='$(owners_list) <owner>' agent-slot launch <repo> --model opus --pr" \
      '<ref>. That checks out the branch as it is then, so compare it with what was reviewed. See the README.' \
      '--requested-at, --opened-at, and --shown-at are seconds since the epoch: when the launch was asked for, and' \
      'for a launch from the new-agent key, when its tab opened and when Rex.app showed it; the launch'"'"'s ledger' \
      'line keeps them for doctor'"'"'s key to ready.' \
      'returns: created, key, repo, slot, path, state, task, name, items[] of {kind, repo, number, title}, label_name,' \
      '         request_id, session_id, base, head_pushable (null without a PR head), trust_prompt_expected,' \
      '         prompt_delivered (null without --prompt-file), missing_siblings, phases,' \
      '         head_foreign, head_owner (null when unknown or not foreign),' \
      '         deps ({manager, command, status, log} of the frozen install of the root lockfile, status one of' \
      '         installed, failed, timed-out, tool-missing, prime-not-set-up, head-not-on-base;' \
      '         null when the repo has nothing to install or the head is foreign),' \
      '         next_step,' \
      '         prior ({session_id, ts, note} of a torn-down slot on the same item, whose conversation agent-slot' \
      '         reopen resumes, else null), prime (what agent-slot prime returns for the repo, or' \
      '         {error: {reason, exit_code, message, value, next_step, recovery, log}} when it did not start, which' \
      '         leaves the slot running;' \
      '         null when the slot already held the request)' \
      'example: agent-slot launch dotfiles --model sonnet --pr 887 --request-id "$(uuidv7)" --prompt-file brief.md --output json' ;;
    retask) printf '%s\n' 'usage: agent-slot retask <repo>/<N> (--task <name> | --issue <ref>) --prompt-file <file> [--output json]' \
      "A new task in a live slot starts a new Claude session, under the task's name, with the brief as its first message." \
      'Follow-up work on the same task goes to the existing session; work on a PR starts with launch --pr. The agent must' \
      'be idle or absent (else agent-busy) and the old work pushed (else slot-work-unfinished, value naming what is left).' \
      'The clone returns to the base with its other local branches removed. The old session stays in prior_sessions and' \
      'in a retask ledger line, and a reopen finds it. returns: key, task, name, session_id, previous_session_id, items.' \
      'Example: agent-slot retask dotfiles/2 --task fix-login --prompt-file brief.md --output json' \
      ;;
    resume) printf '%s\n' 'usage: agent-slot resume <repo>/<N> [--model (opus | sonnet)] [--output json]' \
      '--model switches the slot to that model: the record takes it, and an idle Claude is ended and typed again into its' \
      'pane on that model, resuming the same conversation by session ID. A Claude that is busy, waiting, or unreadable' \
      'is never ended: resume fails with agent-busy and changes nothing. Naming the model the slot already runs is a' \
      "plain resume. With --model it also returns model, previous_model, and restarted. The README's Commands section" \
      'has the rest. Example: agent-slot resume dotfiles/2 --model opus' \
      "Starts whichever of the slot's tmux sessions are missing, resuming its Claude conversation by session ID" \
      "with --dangerously-skip-permissions, and starts the repo's prime if it is not running. Then it deletes each of" \
      "the slot's local branches whose PRs all merged or closed, with origin's branch of that name, keeping the base," \
      "origin's default branch, the branch checked out, any branch a PR targets, and any branch either side of which" \
      'holds work its PRs never had. Each delete is a prune line in the ledger.' \
      'returns: key, started[] (the sessions it created), pruned_branches[], prune_failed[] of {branch, reason}' \
      '         (a delete that failed here or on origin; the next resume retries it), prune_checked (false when' \
      '         GitHub gave no PR list, so nothing was pruned), prime (as launch reports it)' \
      'example: agent-slot resume dotfiles/2' ;;
    prime) printf '%s\n' 'usage: agent-slot prime <repo> [--output json]' \
      "Starts the repo's prime if it is not running: <repo>-prime, <repo>-prime-files, and <repo>-prime-git on the slot" \
      "server, at the repo's own checkout, with Claude in bypass permissions mode resuming its last conversation under" \
      'the name <repo>-prime. It creates only what is missing and never touches git or trust, so the checkout keeps its' \
      'branch and local changes and Claude asks to trust an untrusted one. A session the prime map names for the repo' \
      'that holds a Claude on the default tmux server is the prime until it is closed, and nothing starts. Nothing that' \
      'ends a slot ends a prime. Its Claude runs on the account'"'"'s own default model and effort. Each session takes' \
      'its name only once its program is typed in: a start cut off before then leaves <name>-starting-p<pid>, which' \
      'the next run kills and lists in cleared[].' \
      'returns: key, repo, path, name, server (slots or default), session, started[], cleared[],' \
      '         conversation {mode: running, resumed, or fresh; session_id}, trust_prompt_expected, next_step' \
      'example: agent-slot prime bird --output json' ;;
    warm) printf '%s\n' 'usage: agent-slot warm <repo> | --all [--count N] [--output json]' \
      "Trusts slot paths 1 through N (default: the per-repo slot limit, $AS_MAX_PER_REPO) in Claude, so no launch there" \
      "spends time on the trust step, when Claude already trusts the repo's prime checkout. --all does it for every" \
      'repo agent-slot repos lists, and fails with prime-untrusted naming each repo whose prime Claude does not trust.' \
      'agent-slot-warm.timer runs warm --all every ten minutes.' \
      'returns: paths[] of {key, path, result: trusted, already-trusted, in-use, prime-untrusted, or unrecognized};' \
      '         with --all, repos[] of {repo, prime, paths[]}' \
      'example: agent-slot warm dotfiles --count 4' ;;
    check) printf '%s\n' 'usage: agent-slot check [<repo>/<N>] [--output json]' \
      'Judges each slot (or one): whether its task has finished and what blocks its teardown. It deletes nothing.' \
      'A probe (see probe) closed unmerged neither finishes the task nor blocks it.' \
      'returns: slots[] of {key, repo, slot, path, state, task, branch, prs[] of {number, state, head, oid, url, title,' \
      '         created_at, draft, probe}, finished, finished_by (merge, operator, or release), blockers, needs_you,' \
      '         teardown}' \
      'example: agent-slot check dotfiles/2 --output json' ;;
    adopt) printf '%s\n' 'usage: agent-slot adopt <repo>/<N> (--pr <ref> | --issue <ref>) [--output json]' \
      "Attaches a PR or issue to a live slot's record, and names a slot that has no name from it:" \
      "<repo>-pr<N>-<slug> or <repo>-issue<N>-<slug>. A ref is N (in the slot's origin repo), owner/name#N, or" \
      "its GitHub URL. A PR of origin's repo also joins the slot's PRs, which check judges. When the slot's agent" \
      "is idle, its Claude session is typed /rename <name>; the automatic sweep renames a busy agent's session once" \
      'it is idle. It deletes nothing, so it needs no ask.' \
      'returns: key, name, items[] of {kind, repo, number, title}, item (the one attached), renamed' \
      'example: agent-slot adopt dotfiles/2 --issue 10331 --output json' ;;
    probe) printf '%s\n' 'usage: agent-slot probe <pr> [--output json]' \
      'Marks a PR a probe: a draft this slot opened to exercise CI or a workflow and never means to merge. Run it from' \
      'inside the slot, right after pushing a new branch with git push -u origin HEAD and opening the PR with' \
      "gh pr create --draft --base <the slot's base> and the title test(probe): <what it probes>; the base is" \
      '.slot.base in agent-slot whoami --output json. On an open PR, any other title is refused with' \
      'pr-title-not-probe.' \
      'A ref is N, owner/name#N, or' \
      "its GitHub URL, in the repo of the slot's origin. The PR must be an open draft on a branch this clone created," \
      'whose current head this clone pushed; anything else is refused with pr-not-open, pr-not-draft, or' \
      "pr-not-from-this-slot. It attaches the PR as a work item and changes only the slot's record, so it needs no ask." \
      'A marked PR closed unmerged neither finishes the task nor blocks it (see check); one taken out of draft stops' \
      'being a probe. Marking one already marked, open or closed, changes nothing. Other errors: not-in-slot,' \
      'pr-state-unknown, item-not-found, item-kind-mismatch, and slot-busy, which is safe to retry.' \
      'returns: key, pr {repo, number, title, head, oid, url}, probes[], already_marked' \
      'example: agent-slot probe 487 --output json' ;;
    close-probe) printf '%s\n' 'usage: agent-slot close-probe <pr> [--output json]' \
      'Closes a PR this slot marked with agent-slot probe, for a slot where gh pr close is denied. Run it from inside' \
      'the slot. It closes only an open PR titled test(probe): <what it probes> (else pr-title-not-probe) that is marked' \
      '(else pr-not-probe) and still a draft (else pr-not-draft),' \
      'on a branch this clone created, whose current head this clone pushed (else pr-not-from-this-slot). It leaves a' \
      'comment saying why and deletes no branch, so gh pr reopen undoes it, and it needs no ask. A marked draft already' \
      'closed succeeds without closing again; a merged one fails with pr-not-open. A close whose outcome is unknown' \
      'fails with pr-close-failed, and rerunning it is safe. Other errors: not-in-slot, pr-state-unknown,' \
      'item-not-found, item-kind-mismatch.' \
      'returns: key, pr {repo, number, title, head, oid, url}, closed, already_closed' \
      'example: agent-slot close-probe 487 --output json' ;;
    reopen) printf '%s\n' \
      'usage: agent-slot reopen <repo> --model (opus | sonnet) (--pr <ref> | --issue <ref>) [--session ID] [--prompt-file FILE]' \
      '                         [--request-id ID] [--dry-run] [--output json]' \
      "Finds the slot of the repo that worked on a PR or issue in the ledger after its teardown: the newest whose" \
      "work items hold it, else, for a PR of origin's repo, the newest whose PRs hold its number. --session ID picks" \
      'the teardown of the slot whose Claude session that was, as for a slot torn down before work items were' \
      'recorded; one whose work items name another item is refused. A ref is N (in the origin repo),' \
      'owner/name#N, or its GitHub URL. It refuses while a slot holds the item or the Claude session' \
      '(item-held-by-slot), while a Claude agent has the session open (session-in-use), when no teardown names the' \
      'item (item-not-found-in-ledger), and when Claude Code no longer has the transcript (transcript-missing).' \
      'A retry with the request ID of a slot on another model than --model is refused with model-differs.' \
      '--dry-run changes nothing and exits 0 with the plan, or with the refusal a reopen would hit; a ref GitHub' \
      'cannot read still fails. Its command checks the prime for a Cloudflare config, since the slot is not cloned yet.' \
      'The head is the branch the slot had checked out, else the PR'"'"'s head branch, else' \
      'the base, fetched from the remote the ledger recorded for it when that is on origin'"'"'s host, else from the' \
      "PR's head repository. A PR that GitHub reports merged into the base, whose head is that branch at the commit" \
      'the ledger recorded for it, or at any commit when it recorded none, gives the base instead (head.source.branch' \
      'is base), since the base holds its work; the dry run'"'"'s text output says why. A reopen is a foreign head when' \
      "the source slot was, or when that URL or a PR's head on" \
      'GitHub is. A --prompt-file needs a line for each of Scope:, Limits:, Reviews:, Reports to:, Touches:, and Adds:,' \
      'each with a value, or the reopen is refused with brief-incomplete. Agents ask the operator first.' \
      'returns: launch'"'"'s fields (key, name, items, session_id, prompt_delivered, ...) plus reopened_from {slot,' \
      '         session_id, ts}, settled_prs (the PRs already merged or closed, which neither finish nor block the' \
      '         task), head, and head_moved; with --dry-run, dry_run, would_reopen, refusal (null, or {reason,' \
      '         exit_code, message, value, next_step, recovery}), item, source (the teardown event, or {key, state,' \
      '         name, items, session_id} of the slot that holds the item or request), name, items[] of {kind, repo,' \
      '         number, title}, task, session_id, transcript, transcript_exists, head {branch, remote, url, oid,' \
      '         source {branch, remote}}, slot, command, prompt_delivered. Both forms return head_foreign and' \
      '         head_owner, null when a dry run plans no head' \
      'example: agent-slot reopen dotfiles --model opus --pr 887 --dry-run --output json' ;;
    sweep) printf '%s\n' 'usage: agent-slot sweep [--yes [--auto]] [--output json]' \
      'Tears down every slot whose task has finished and whose check passes; lists the rest. Without --yes it only' \
      "reports what it would delete. Agents ask the operator first. A teardown deletes the slot's clone, moving it to" \
      'the trash and purging it from there at once; a purge that fails leaves the slot torn down, lists it under' \
      'purge_failed, and names the trash-rm command that finishes it. A teardown pushes a restore to the Rex helper,' \
      "which closes the slot's tab. --auto, which agent-slot-sweep.timer runs, tears down only a slot its agent" \
      'released or the operator finished: a finished slot that is neither is kept, its idle agent is typed the' \
      'closing steps once, and a slot whose agent is gone or never releases joins the needs-you list as' \
      'not-released. A slot whose agent ran release --not-yet stays off that list, and its idle agent is reminded' \
      "once after $AS_RELEASE_REMIND s. A finished slot kept only by files left in it gets its idle agent a reminder" \
      'naming them, once, before it is listed. Each --yes pass appends a line to' \
      "$AS_STATE_DIR/teardown.log." \
      'returns: dry_run, torn_down[], purge_failed[], would_tear_down[], closing_sent[], cleanup_sent[], reminded[],' \
      '         not_yet[], renamed[] of {key, name}, needs_you[] of {key, needs_you}, slots[] (each with result, and a' \
      '         torn-down one with purge {purged, entry, ms, and code, message, next_step, log when it failed})' \
      'example: agent-slot sweep --output json' ;;
    finish) printf '%s\n' \
      'usage: agent-slot finish <repo>/<N> [--yes [--when-idle] [--allow-open-pr]] [--output json]' \
      'Marks a task finished and tears its slot down when check passes. It refuses a task that has an open PR' \
      '(task-has-open-pr) unless given --allow-open-pr, which finishes the task whatever state its PRs are in;' \
      'release and the Rex finish key never pass it. Without --yes it only reports, naming in would_need the flag' \
      "the task would need. Agents ask the operator first. A teardown deletes the slot's clone, moving it to the" \
      'trash and purging it from there at once; a purge that fails leaves the slot torn down and names the trash-rm' \
      "command that finishes it. A teardown pushes a restore to the Rex helper, which closes the slot's tab." \
      "--when-idle, which release starts, first waits up to $AS_RELEASE_WAIT s for the slot's agent to go idle. The" \
      'finish a release starts marks the task finished on that release, and refuses with release-withdrawn once a' \
      '--not-yet or a newer release replaces it. Each --yes run appends its outcome, with allow_open_pr when it had' \
      "the flag, to $AS_STATE_DIR/teardown.log." \
      'returns: key, then dry_run, would_tear_down, would_need (null or --allow-open-pr), verdict without --yes, or' \
      '         torn_down and purge {purged, entry, ms, and code, message, next_step, log when it failed} with it' \
      'example: agent-slot finish dotfiles/2 --yes' ;;
    grant-review) printf '%s\n' 'usage: agent-slot grant-review <repo>/<N> [--output json]' \
      "Grants the slot's agent one more ce-code-review round for the PR on the slot's current branch, past the 2 per PR" \
      "that slot-review-cap.sh allows; each grant is one round. The operator or a prime runs it, for a round that reviews" \
      "round 1's P0 or P1 fixes: run from a slot's directory, or from any pane on the slot tmux server but a prime's" \
      "Claude pane, it is refused with review-grant-from-slot. A grant appends a review-grant" \
      "line to the ledger and changes nothing else; each run is one more round, so run it once per request. On a detached" \
      "head the branch is the commit, and a new commit starts a new count. Other errors: slot-not-found and slot-head-missing." \
      'returns: key, branch, granted_at, rounds (used), allowed (the 2 plus each grant)' \
      'example: agent-slot grant-review dotfiles/2 --output json' ;;
    grant-scope) printf '%s\n' 'usage: agent-slot grant-scope <repo>/<N> <pathspec> [--output json]' \
      "Lets the slot's PR change the paths a git pathspec matches, past the Touches: globs of its brief, so" \
      "slot-scope-guard.sh stops denying a git push of them. It lists to the terminal (/dev/tty) the paths the" \
      "slot's branch changes that the pathspec covers and how many stay outside the brief and the grants, and reads" \
      "the slot's key back within $SCOPE_GRANT_WAIT s. With no terminal it is refused with grant-needs-terminal," \
      "with no answer or a wrong one with grant-not-confirmed, and from a slot's directory or its tmux server with" \
      "scope-grant-from-slot. A pathspec git rejects, an exclude pathspec (:!, :^, :/!, :/^, or :(exclude)), a" \
      "control character, and one that covers none of the paths the branch changes are refused with usage before" \
      "the terminal is asked; a shell under Claude Code (CLAUDECODE set) is refused with grant-needs-terminal even" \
      "when it holds a pseudo-terminal. A slot still being set up is refused with slot-busy. A grant appends a" \
      "scope-grant line to the ledger and changes nothing else; each run grants one pathspec, quoted so the shell" \
      "does not expand it, and there is no revoke. It is a guard, not a trust boundary. Other error:" \
      "slot-not-found." \
      'returns: key, pathspec, granted_at, grants (the slot'"'"'s scope grants in all)' \
      'example: agent-slot grant-scope dotfiles/2 '"'"'docs/*.md'"'"' --output json' ;;
    release) printf '%s\n' 'usage: agent-slot release [--not-yet WHY] [--output json]' \
      "A slot's agent runs it as its last step, from inside the slot. It refuses with compound-not-run until this" \
      "slot's Claude session has run both /compound-engineering:ce-compound and its refresh mode (mode:refresh)," \
      'and with background-jobs-running while that Claude still runs a' \
      'Bash tool command other than this one, naming each. Then it records the request and starts finish --yes' \
      '--when-idle in a session of its own, outside the slot, which tears the slot down once the agent is idle and' \
      'check passes. A slot whose task has not finished stays requested until the automatic sweep tears it down. It' \
      'deletes nothing itself, so it needs no ask. --not-yet records why the slot is not ready, such as a wait on CI,' \
      'so the automatic sweep reminds the agent later instead of listing the slot. Of a release and a --not-yet, the' \
      'newer stands: --not-yet withdraws an earlier release, and the finish it started stands down. It does not undo' \
      "the operator's finish: on a slot the operator finished it refuses with finished-by-operator." \
      'returns: key, requested_at, runner_pid, skills[], already_requested; with --not-yet, key, not_yet {why, at},' \
      '         release_withdrawn' \
      "example: agent-slot release --not-yet 'release.yml run 42 has not finished' --output json" ;;
    doctor) printf '%s\n' 'usage: agent-slot doctor [--output json]' \
      'Checks every launch prerequisite on this server and the time from key press to Claude idle: launch_times' \
      'from each launch request, and key_to_ready from the new-agent key'"'"'s tab opening, with the median of each step.' \
      'returns: ok, findings[] (error objects with severity), launch_times, key_to_ready {launches, measured,' \
      '         not_ready[], median_s, p90_s, phases}, verified_versions' \
      'example: agent-slot doctor' ;;
    schema) printf '%s\n' 'usage: agent-slot schema [--output json]' \
      'Prints the JSON Schema of the success and error objects, and every reason an error can carry.' \
      'returns: success and error (JSON Schema documents), reasons[] of {reason, exit_code, retryable, max_retries,' \
      '         action}' \
      "example: agent-slot schema --output json | jaq '.reasons[] | select(.retryable)'" ;;
  esac
}
