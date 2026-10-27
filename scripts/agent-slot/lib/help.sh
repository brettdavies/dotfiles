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
  sweep    tear down every slot whose task has finished and that check passes (reports only, without --yes)
  finish   mark a task with no open PR finished and tear its slot down if check passes (reports only, without --yes)
  doctor   check every launch prerequisite and summarize launch times
  schema   print the JSON Schema of the objects agent-slot prints, and every error reason

Every verb takes --output json (one JSON object on stdout, or an error object on stderr) and --help.
Exit codes: 0 ok, 1 failed, 2 usage, 77 auth, 78 configuration.
Reasons and their fixes: https://github.com/brettdavies/dotfiles/blob/main/README.md#agent-slot-reasons'

VERBS=' repos list whoami launch resume warm check sweep finish doctor schema '

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
      'starting with a letter or digit, up to 64.' \
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
      'returns: slots[] of {key, repo, slot, path, state, task, branch, prs, finished, finished_by, blockers,' \
      '         needs_you, teardown}' \
      'example: agent-slot check dotfiles/2 --output json' ;;
    sweep) printf '%s\n' 'usage: agent-slot sweep [--yes] [--output json]' \
      'Tears down every slot whose task has finished and whose check passes; lists the rest. Without --yes it only' \
      'reports what it would delete. Agents ask the operator first.' \
      'returns: dry_run, torn_down[], would_tear_down[], needs_you[] of {key, needs_you}, slots[] (each with result)' \
      'example: agent-slot sweep --output json' ;;
    finish) printf '%s\n' 'usage: agent-slot finish <repo>/<N> [--yes] [--output json]' \
      "Marks a task with no open PR finished and tears its slot down when check passes; it refuses a task with an" \
      'open PR. Without --yes it only reports. Agents ask the operator first.' \
      'returns: key, then dry_run, would_tear_down, verdict without --yes, or torn_down with it' \
      'example: agent-slot finish dotfiles/2 --yes' ;;
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
