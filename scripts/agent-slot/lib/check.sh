# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# agent-slot check: a read-only, fail-closed teardown verdict per slot, which the needs-you list, sweep, and finish all
# share. Every lookup must show that it ran; a lookup that fails, or that returns nothing to judge, is a blocker.
#
# A task has finished when none of its PRs is open or closed without merging and one has merged, or when the operator
# finished it with no PR open. A finished slot may go only when every check below passes:
#
#   the agent is idle or absent; the tree is clean and nothing is stashed; every local commit is in the final head of
#   one of the task's PRs, or, for a task that never had a PR, on a branch on origin; no untracked or ignored file
#   exists beyond build and dependency output and the files setup placed; and no symlink under the home directory
#   resolves into the slot.

CHECK_CODES='pr-state-unknown pr-closed-unmerged git-state-unknown agent-not-idle agent-state-unknown
uncommitted-changes stash-present unpushed-commits commits-without-pr untracked-files local-only-files
home-symlink-into-slot home-scan-incomplete slot-busy'

CHECK_SETUP_FILES='docs/solutions .claude/settings.local.json'
CHECK_BUILD_DIRS='node_modules target dist build .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo coverage'

CHECK_BLOCKERS=()
CHECK_VERDICT=

# Usage: _check_block <code> <message> [count] [value...]
_check_block() {
  local code=$1 message=$2 count=${3:-}
  shift $(($# < 3 ? $# : 3))
  CHECK_BLOCKERS+=("$(printf '%s\n' "$@" | contract_json -R -s -c --arg code "$code" --arg message "$message" \
    --arg count "$count" '{code: $code, message: $message}
      + (if $count == "" then {} else {count: ($count | tonumber)} end)
      + (split("\n") | map(select(. != "")) | if length > 0 then {values: .} else {} end)')")
}

_check_plural() { if (($1 == 1)); then printf '1 %s' "$2"; else printf '%s %s' "$1" "${3:-$2s}"; fi; }

_check_local_only() {
  local part
  local IFS=/
  for part in $1; do
    case $part in .context | todos | TODO* | .env*) return 0 ;; esac
  done
  return 1
}

# Usage: _check_build_output <status> <path>; true for an ignored directory git listed whole whose own name is a build
# or dependency directory. A new file inside a build-named directory that also holds tracked files is listed on its
# own, so it never matches.
_check_build_output() {
  local name
  [[ $1 == '!!' && $2 == */ ]] || return 1
  name=${2%/}
  name=${name##*/}
  [[ " $CHECK_BUILD_DIRS " == *" $name "* ]]
}

# Usage: _check_untracked_paths <slot path> <git status -z file>; prints each untracked (??) and ignored (!!) entry as
# "<status> <path>", NUL-separated, with a directory's trailing slash kept. git collapses an ignored directory into one
# entry, so a directory that holds a file setup placed, such as an ignored .claude/, is listed file by file instead.
_check_untracked_paths() {
  local entry status path setup file
  while IFS= read -r -d '' entry; do
    status=${entry:0:2}
    [[ $status == '??' || $status == '!!' ]] || continue
    path=${entry:3}
    if [[ $path == */ ]]; then
      for setup in $CHECK_SETUP_FILES; do
        [[ $setup == "$path"* ]] || continue
        while IFS= read -r -d '' file; do
          printf '%s %s\0' "$status" "${file#"$1"/}"
        done < <(find "$1/${path%/}" -mindepth 1 \( -type f -o -type l \) -print0)
        continue 2
      done
    fi
    printf '%s\0' "$entry"
  done <"$2"
}

# Usage: _check_files <slot path>; untracked and ignored files beyond build output and what setup placed.
_check_files() {
  local entry status path listing untracked=() local_only=()
  listing=$(mktemp)
  if ! git -C "$1" status --porcelain=v1 -z --ignored=matching --untracked-files=all >"$listing" 2>/dev/null; then
    rm -f "$listing"
    _check_block git-state-unknown "git status failed in the slot"
    return
  fi
  while IFS= read -r -d '' entry; do
    status=${entry:0:2}
    path=${entry:3}
    if _check_local_only "${path%/}"; then
      local_only+=("${path%/}")
    elif [[ " $CHECK_SETUP_FILES " != *" ${path%/} "* ]] && ! _check_build_output "$status" "$path"; then
      untracked+=("${path%/}")
    fi
  done < <(_check_untracked_paths "$1" "$listing")
  rm -f "$listing"
  ((${#local_only[@]} == 0)) || _check_block local-only-files \
    "local-only files: ${local_only[*]:0:3}$( ((${#local_only[@]} <= 3)) || echo ' and more')" \
    "${#local_only[@]}" "${local_only[@]}"
  ((${#untracked[@]} == 0)) || _check_block untracked-files \
    "$(_check_plural "${#untracked[@]}" "untracked file"): ${untracked[*]:0:3}" "${#untracked[@]}" "${untracked[@]}"
}

# Usage: _check_agent <repo> <n>; blocks unless the slot's agent is idle or absent, from the agents agentstate_load read.
_check_agent() {
  agentstate_of "$1" "$2"
  case $AGENT_STATE in
    busy | waiting) _check_block agent-not-idle "the agent is $AGENT_STATE" ;;
    unknown) _check_block agent-state-unknown "agent state unknown: $AGENT_DETAIL" ;;
  esac
}

# Usage: _check_commits <slot path> <base> <pr count>
# A commit counts as pushed once an origin branch or tag holds it; local tags count as heads, so a commit only a local
# tag still reaches is unpushed. Origin's tags are fetched into refs/agent-slot/origin-tags.
_check_commits() {
  local path=$1 base=$2 has_prs=$3 baseref heads uncontained unpushed_heads unpushed
  baseref=refs/remotes/origin/$base
  git -C "$path" rev-parse -q --verify "$baseref" >/dev/null || baseref=refs/remotes/origin/HEAD
  if ! git -C "$path" rev-parse -q --verify "$baseref" >/dev/null \
    || ! heads=$({
      git -C "$path" rev-parse HEAD
      git -C "$path" for-each-ref --format='%(objectname)' refs/heads
      git -C "$path" worktree list --porcelain | sed -n 's/^HEAD //p'
    } | sort -u); then
    _check_block git-state-unknown "the slot's local heads or origin's $base could not be read"
    return
  fi
  local -a h contained=("$baseref" --glob='refs/agent-slot/pr/*')
  local -a on_origin=(--remotes=origin --glob='refs/agent-slot/origin-tags/*')
  mapfile -t h <<<"$heads"
  # A clone keeps a local copy of origin's default branch, whose history need not be in the base (dev).
  ! git -C "$path" rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null || contained+=(refs/remotes/origin/HEAD)
  if ((has_prs > 0)); then
    if ! uncontained=$(git -C "$path" rev-list --count "${h[@]}" --not "${contained[@]}") \
      || ! unpushed_heads=$(git -C "$path" rev-list --count "${h[@]}" --not "${contained[@]}" "${on_origin[@]}") \
      || ! unpushed=$(git -C "$path" rev-list --count "${h[@]}" --tags --not "${contained[@]}" "${on_origin[@]}"); then
      _check_block git-state-unknown "git rev-list failed in the slot"
      return
    fi
    local without_pr=$((uncontained - unpushed_heads))
    ((without_pr == 0)) || _check_block commits-without-pr \
      "$(_check_plural "$without_pr" "commit on a branch with no PR" "commits on a branch with no PR")" "$without_pr"
  else
    unpushed=$(git -C "$path" rev-list --count "${h[@]}" --tags --not "${on_origin[@]}") || {
      _check_block git-state-unknown "git rev-list failed in the slot"
      return
    }
  fi
  ((unpushed == 0)) || _check_block unpushed-commits "$(_check_plural "$unpushed" "unpushed commit")" "$unpushed"
}

check_inputs_load() {
  agentstate_load
  home_scan_load
}

# Usage: check_slot <repo> <n>; sets CHECK_VERDICT. PR state comes from one gh call per repo, made on first use.
check_slot() {
  local repo=$1 n=$2 path real state base origin prs='[]' prs_known=1 refspecs=() number out finished operator
  local -a closed links
  CHECK_BLOCKERS=()
  path=$(slot_path "$repo" "$n")
  real=$(realpath -m "$path")
  if ! record_read "$repo" "$n"; then
    RECORD=$(contract_json -n -c --arg r "$repo" --argjson n "$n" '{repo: $r, slot: $n, state: "setting-up"}')
  fi
  state=$(contract_json -r '.state // "active"' <<<"$RECORD")
  if [[ $state != active ]]; then
    _check_block slot-busy "$(slot_key "$repo" "$n") is $state"
  else
    base=$(contract_json -r '.base // "main"' <<<"$RECORD")
    origin=$(git -C "$path" config --get remote.origin.url || true)
    pr_load "$repo" "$origin"
    if [[ ${PR_OK[$repo]} == 1 ]]; then
      prs=$(pr_for_slot "$repo" "$path" "$RECORD")
    else
      prs_known=0
      _check_block pr-state-unknown "gh could not read the PRs of $(pr_repo_slug "$origin")"
    fi

    refspecs=('+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/agent-slot/origin-tags/*')
    while read -r number; do
      [[ -n $number ]] && refspecs+=("+refs/pull/$number/head:refs/agent-slot/pr/$number")
    done < <(contract_json -r '.[].number' <<<"$prs")
    if ! bounded out fetch 120 /usr/bin/env GIT_SSH_COMMAND='ssh -o BatchMode=yes' GIT_TERMINAL_PROMPT=0 \
      git -C "$path" fetch -q --prune origin "${refspecs[@]}"; then
      _check_block git-state-unknown "git fetch from origin failed (log: $BOUNDED_LOG)"
    fi

    operator=$(contract_json -r '.finished_by_operator // false' <<<"$RECORD")
    mapfile -t closed < <(contract_json -r '.[] | select(.state == "CLOSED") | .number' <<<"$prs")
    if ((${#closed[@]} > 0)) && [[ $operator != true ]]; then
      _check_block pr-closed-unmerged "PR #$(printf '%s, PR #' "${closed[@]}" | sed 's/, PR #$//') closed without merging" \
        "" "${closed[@]}"
    fi

    _check_agent "$repo" "$n"

    if out=$(git -C "$path" status --porcelain=v1 --untracked-files=no); then
      [[ -z $out ]] || _check_block uncommitted-changes \
        "$(_check_plural "$(grep -c . <<<"$out")" "uncommitted change")" "$(grep -c . <<<"$out")"
    else
      _check_block git-state-unknown "git status failed in the slot"
    fi
    if out=$(git -C "$path" stash list); then
      [[ -z $out ]] || _check_block stash-present "$(_check_plural "$(grep -c . <<<"$out")" "stash entry" "stash entries")" \
        "$(grep -c . <<<"$out")"
    else
      _check_block git-state-unknown "git stash list failed in the slot"
    fi
    _check_commits "$path" "$base" "$(contract_json 'length' <<<"$prs")"
    _check_files "$path"

    if ((HOME_SCAN_OK == 0)); then
      _check_block home-scan-incomplete "the scan for home-directory symlinks into the slot did not finish"
    else
      mapfile -t links < <(home_links_into "$real")
      ((${#links[@]} == 0)) || _check_block home-symlink-into-slot "$(_check_plural "${#links[@]}" \
        "symlink under the home directory resolves" "symlinks under the home directory resolve") into the slot" \
        "${#links[@]}" "${links[@]}"
    fi
  fi

  finished=$(contract_json -r --argjson op "$(contract_json '.finished_by_operator // false' <<<"$RECORD")" \
    --argjson ok "$prs_known" '
    if $ok == 0 then false
    else (any(.[]; .state == "OPEN") | not) as $none_open
      | ($none_open and ((any(.[]; .state == "MERGED") and (any(.[]; .state == "CLOSED") | not)) or $op))
    end' <<<"$prs")
  [[ $state == active ]] || finished=false
  CHECK_VERDICT=$(printf '%s\n' "${CHECK_BLOCKERS[@]}" | contract_json -s -c --arg key "$(slot_key "$repo" "$n")" \
    --arg path "$path" --arg state "$state" --argjson prs "$prs" --argjson finished "$finished" \
    --arg branch "$(git -C "$path" symbolic-ref --short -q HEAD 2>/dev/null || true)" --argjson record "$RECORD" '
    map(select(. != null)) as $blockers
    | {key: $key, repo: $record.repo, slot: $record.slot, path: $path, state: $state, task: $record.task,
       branch: (if $branch == "" then null else $branch end), prs: $prs, finished: $finished,
       finished_by: (if $finished | not then null elif $record.finished_by_operator then "operator" else "merge" end),
       blockers: $blockers,
       needs_you: (if $finished or any($blockers[]; .code == "pr-closed-unmerged" or .code == "pr-state-unknown")
                   then $blockers else [] end),
       teardown: ($finished and ($blockers | length) == 0)}')
}

# Records the PRs a verdict found and the needs-you list it produced, when the slot's lock is free.
check_record() {
  local repo=$1 n=$2
  [[ $(contract_json -r .state <<<"$CHECK_VERDICT") == active ]] || return 0
  record_update "$repo" "$n" --argjson v "$CHECK_VERDICT" --arg at "$(contract_now)" '
    .prs = ((.prs // []) + [$v.prs[].number] | unique)
    | .last_check = {at: $at, finished: $v.finished, blockers: $v.needs_you}' || true
}

cmd_check() {
  local repo n verdicts=()
  require_tools tmux claude gh
  if [[ -n ${CHECK_KEY:-} ]]; then
    slot_parse_key "$CHECK_KEY"
    slot_taken "$SLOT_REPO" "$SLOT_N" \
      || contract_fail slot-not-found "$CHECK_KEY holds no slot" --value "$CHECK_KEY" --command "agent-slot list"
  fi
  check_inputs_load
  while read -r repo; do
    [[ -n $repo ]] || continue
    [[ -z ${CHECK_KEY:-} || $repo == "$SLOT_REPO" ]] || continue
    while read -r n; do
      [[ -n $n ]] || continue
      [[ -z ${CHECK_KEY:-} || $n == "$SLOT_N" ]] || continue
      check_slot "$repo" "$n"
      check_record "$repo" "$n"
      verdicts+=("$CHECK_VERDICT")
    done < <(slot_numbers "$repo")
  done < <(slot_repos)
  contract_ok "$(printf '%s\n' "${verdicts[@]}" | contract_json -s -c '{slots: map(select(. != null))}')" '
    if (.slots | length) == 0 then "no slots"
    else .slots[] | "\(.key)\t\(if .teardown then "can be torn down" elif .finished then "finished" else "active" end)"
      + (if (.blockers | length) > 0 then "\t\(.blockers | map(.message) | join("; "))" else "" end)
    end'
}
