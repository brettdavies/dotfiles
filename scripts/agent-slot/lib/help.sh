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
  warm     trust the next slot paths of a repo in Claude ahead of time
  check    judge whether each slot can be torn down, and list what blocks it
  adopt    attach a PR or issue to a live slot, naming the slot if it has no name
  sweep    tear down every slot whose task has finished and that check passes (reports only, without --yes)
  finish   mark a task finished and tear its slot down if check passes (reports only, without --yes)
  release  hand this slot'"'"'s teardown upstream once its agent has run the closing skills; run from inside the slot
  doctor   check every launch prerequisite and summarize launch times
  schema   print the JSON Schema of the objects agent-slot prints, and every error reason

Every verb takes --output json (one JSON object on stdout, or an error object on stderr) and --help.
Exit codes: 0 ok, 1 failed, 2 usage, 77 auth, 78 configuration.
Reasons and their fixes: https://github.com/brettdavies/dotfiles/blob/main/README.md#agent-slot-reasons'

VERBS=' repos list whoami launch resume warm check adopt sweep finish release doctor schema '

verb_help() {
  case $1 in
    repos) printf '%s\n' 'usage: agent-slot repos [--output json]' \
      'Lists each git repo under ~/dev (and ~/dotfiles) that has an origin.' \
      'returns: repos[] of {name, prime, origin}' \
      'example: agent-slot repos --output json' ;;
    list) printf '%s\n' 'usage: agent-slot list [--output json]' \
      'Lists every slot with its state, agent state, task, and its needs-you blockers.' \
      'returns: slots[] of the slot record plus {key, path, state, branch, agent, agent_detail, sessions, needs_you}' \
      "example: agent-slot list --output json | jaq '.slots[] | select(.needs_you != [])'" ;;
    whoami) printf '%s\n' 'usage: agent-slot whoami [--path DIR] [--output json]' \
      'Prints the slot that DIR (default: the current directory) is inside. Outside a slot it fails with the error' \
      'reason not-in-slot (exit 1).' \
      'returns: slot, the slot record plus {key, path}' \
      'example: agent-slot whoami --output json' ;;
    launch) printf '%s\n' \
      'usage: agent-slot launch <repo> [--request-id ID] [--task NAME] [--prompt-file FILE] [--requested-at EPOCH]' \
      '                         [--output json]' \
      'Clones the repo into its lowest free slot, sets it up like the prime checkout, and starts Claude there with' \
      '--dangerously-skip-permissions. A repeat with the same --request-id (or --task) returns the same slot. Agents' \
      'always pass --request-id. ID: letters, digits, ., _, and -, up to 128. NAME: letters, digits, _, -, and /,' \
      'starting with a letter or digit, up to 64. A new slot pushes a restore to each Mac in AGENT_SLOT_REX_CLIENTS,' \
      "so its tab opens in Rex; the push runs in the background and is logged to $AS_STATE_DIR/push.log." \
      'returns: created, key, repo, slot, path, state, task, request_id, session_id, base, trust_prompt_expected,' \
      '         prompt_delivered (false when the slot already held the task), missing_siblings, phases, next_step' \
      'example: agent-slot launch dotfiles --request-id "$(uuidv7)" --prompt-file brief.md --output json' ;;
    resume) printf '%s\n' 'usage: agent-slot resume <repo>/<N> [--output json]' \
      "Starts whichever of the slot's tmux sessions are missing, resuming its Claude conversation by session ID" \
      'with --dangerously-skip-permissions.' \
      'returns: key, started[] (the sessions it created)' \
      'example: agent-slot resume dotfiles/2' ;;
    warm) printf '%s\n' 'usage: agent-slot warm <repo> [--count N] [--output json]' \
      "Trusts slot paths 1 through N (default 3) in Claude, so no launch there spends time on the trust step," \
      "when Claude already trusts the repo's prime checkout." \
      'returns: paths[] of {key, path, result: trusted, already-trusted, in-use, prime-untrusted, or unrecognized}' \
      'example: agent-slot warm dotfiles --count 4' ;;
    check) printf '%s\n' 'usage: agent-slot check [<repo>/<N>] [--output json]' \
      'Judges each slot (or one): whether its task has finished and what blocks its teardown. It deletes nothing.' \
      'returns: slots[] of {key, repo, slot, path, state, task, branch, prs, finished, finished_by (merge, operator,' \
      '         or release), blockers, needs_you, teardown}' \
      'example: agent-slot check dotfiles/2 --output json' ;;
    adopt) printf '%s\n' 'usage: agent-slot adopt <repo>/<N> (--pr <ref> | --issue <ref>) [--output json]' \
      "Attaches a PR or issue to a live slot's record, and names a slot that has no name from it:" \
      "<repo>-pr<N>-<slug> or <repo>-issue<N>-<slug>. A ref is N (in the slot's origin repo), owner/name#N, or" \
      "its GitHub URL. A PR of origin's repo also joins the slot's PRs, which check judges. When the slot's agent" \
      "is idle, its Claude session is typed /rename <name>; the automatic sweep renames a busy agent's session once" \
      'it is idle. It deletes nothing, so it needs no ask.' \
      'returns: key, name, items[] of {kind, repo, number, title}, item (the one attached), renamed' \
      'example: agent-slot adopt Pillow/1 --issue 10331 --output json' ;;
    sweep) printf '%s\n' 'usage: agent-slot sweep [--yes [--auto]] [--output json]' \
      'Tears down every slot whose task has finished and whose check passes; lists the rest. Without --yes it only' \
      "reports what it would delete. Agents ask the operator first. A teardown deletes the slot's clone, moving it to" \
      'the trash and purging it from there at once; a purge that fails leaves the slot torn down, lists it under' \
      'purge_failed, and names the trash-rm command that finishes it. A teardown pushes a restore to each Rex client,' \
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
      "command that finishes it. A teardown pushes a restore to each Rex client, which closes the slot's tab." \
      "--when-idle, which release starts, first waits up to $AS_RELEASE_WAIT s for the slot's agent to go idle. The" \
      'finish a release starts marks the task finished on that release, and refuses with release-withdrawn once a' \
      '--not-yet or a newer release replaces it. Each --yes run appends its outcome, with allow_open_pr when it had' \
      "the flag, to $AS_STATE_DIR/teardown.log." \
      'returns: key, then dry_run, would_tear_down, would_need (null or --allow-open-pr), verdict without --yes, or' \
      '         torn_down and purge {purged, entry, ms, and code, message, next_step, log when it failed} with it' \
      'example: agent-slot finish dotfiles/2 --yes' ;;
    release) printf '%s\n' 'usage: agent-slot release [--not-yet WHY] [--output json]' \
      "A slot's agent runs it as its last step, from inside the slot. It refuses with compound-not-run until this" \
      "slot's Claude session has run both /compound-engineering:ce-compound and" \
      '/compound-engineering:ce-compound-refresh, and with background-jobs-running while that Claude still runs a' \
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
      'Checks every launch prerequisite on this server and the time from key press to Claude idle.' \
      'returns: ok, findings[] (error objects with severity), launch_times, verified_versions' \
      'example: agent-slot doctor' ;;
    schema) printf '%s\n' 'usage: agent-slot schema [--output json]' \
      'Prints the JSON Schema of the success and error objects, and every reason an error can carry.' \
      'returns: success and error (JSON Schema documents), reasons[] of {reason, exit_code, retryable, max_retries,' \
      '         action}' \
      "example: agent-slot schema --output json | jaq '.reasons[] | select(.retryable)'" ;;
  esac
}
