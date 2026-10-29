# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it, and bounded sets its output by name
# agent-slot check: a read-only, fail-closed teardown verdict per slot, which the needs-you list, sweep, and finish all
# share. Every lookup must show that it ran; a lookup that fails, or that returns nothing to judge, is a blocker.
#
# A task has finished when none of its PRs is open or closed without merging and one has merged, or when the operator
# finished it with no PR open. A finished slot may go only when every check below passes:
#
#   the agent is idle or absent; the tree is clean apart from setup's docs/solutions link and nothing is stashed; every
#   local commit is in the final head of one of the task's PRs, or, for a task that never had a PR, on a branch on
#   origin; no untracked file exists beyond the files setup placed and Claude Code's own runtime files, and no ignored
#   file beyond those, tool and build output, and byte-for-byte copies of files HEAD tracks; and no symlink under the
#   home directory resolves into the slot. Tool output counts even inside a local-only directory, so Playwright's
#   .context/test-results passes while any other file under .context blocks. So do the Vale style packages the slot's
#   own .vale.ini names, each its StylesPath joined with the package's name, which `vale sync` downloads; anything else
#   under StylesPath, such as the repo's own styles, is judged like any other file.

CHECK_CODES='pr-state-unknown pr-closed-unmerged git-state-unknown agent-not-idle checked-by-own-agent
agent-state-unknown uncommitted-changes stash-present unpushed-commits commits-without-pr untracked-files
local-only-files home-symlink-into-slot home-scan-incomplete slot-busy not-released'
CHECK_DOCS=${CONTRACT_DOCS%#*}#teardown-blockers

CHECK_SETUP_FILES='docs/solutions .claude/settings.local.json'
# Files Claude Code writes into a project's .claude/ by itself: the scheduler's lock, and the tasks a session saved,
# which run only in the folder that saved them (https://code.claude.com/docs/en/scheduled-tasks). Its other runtime
# paths there, such as worktrees/ and agent-memory-local/, can hold a task's work, so they still block.
CHECK_RUNTIME_FILES='.claude/scheduled_tasks.lock .claude/scheduled_tasks.json'
# Names only a tool gives a directory, so every ignored path under one is its output. .gstack is gstack's state
# directory, which gstack ignores whole with a .gitignore of `*`; test-results is Playwright's outputDir. A source tree
# can name a directory build or dist too, so a build directory counts only when git lists it whole.
CHECK_TOOL_DIRS='node_modules .venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .astro .wrangler .blume .build .gstack test-results'
CHECK_BUILD_DIRS='target dist build venv coverage'

CHECK_BLOCKERS=()
CHECK_VERDICT=
CHECK_PACKAGE_DIRS=

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

# Usage: _check_tool_output <status> <path>; true for an ignored path under a tool directory.
_check_tool_output() {
  local name dir=/$2
  [[ $1 == '!!' ]] || return 1
  [[ $2 == */ ]] || dir=${dir%/*}/
  for name in $CHECK_TOOL_DIRS; do
    [[ $dir != */"$name"/* ]] || return 0
  done
  return 1
}

# Usage: _check_vale_packages <slot path>; prints the directory of each style package the slot's .vale.ini names: its
# StylesPath joined with the package's name, where a Packages entry is a bare name or a URL or path ending in
# <name>.zip. `vale sync` unpacks each package there. Vale reads both keys only above the first [section].
_check_vale_packages() {
  local line styles='' packages='' entry name
  [[ -f $1/.vale.ini ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ ! $line =~ ^[[:space:]]*\[ ]] || break
    [[ $line =~ ^[[:space:]]*(StylesPath|Packages)[[:space:]]*=[[:space:]]*(.*[^[:space:]]) ]] || continue
    if [[ ${BASH_REMATCH[1]} == StylesPath ]]; then styles=${BASH_REMATCH[2]}; else packages=${BASH_REMATCH[2]}; fi
  done <"$1/.vale.ini"
  styles=${styles#./}
  styles=${styles%/}
  [[ -n $styles && -n $packages ]] || return 0
  while IFS= read -r -d , entry; do
    entry=${entry#"${entry%%[![:space:]]*}"}
    entry=${entry%"${entry##*[![:space:]]}"}
    name=${entry##*/}
    name=${name%.zip}
    [[ -z $name || $name == . || $name == .. ]] || printf '%s/%s\n' "$styles" "$name"
  done <<<"$packages,"
}

# Usage: _check_package_output <status> <path>; true for an ignored path in one of CHECK_PACKAGE_DIRS.
_check_package_output() {
  local dir
  [[ $1 == '!!' ]] || return 1
  while IFS= read -r dir; do
    [[ -n $dir ]] || continue
    [[ ${2%/} != "$dir" && $2 != "$dir"/* ]] || return 0
  done <<<"$CHECK_PACKAGE_DIRS"
  return 1
}

# Usage: _check_build_output <status> <path>; true for tool output, or for an ignored directory git listed whole whose
# own name is a build directory. A new file inside a build-named directory that also holds tracked files is listed on
# its own, so it never matches.
_check_build_output() {
  local name
  ! _check_tool_output "$1" "$2" || return 0
  [[ $1 == '!!' && $2 == */ ]] || return 1
  name=${2%/}
  name=${name##*/}
  [[ " $CHECK_BUILD_DIRS " == *" $name "* ]]
}

# Usage: _check_head_copy <slot path> <blob list> <path>; true when the ignored path holds at least one file and each
# is a regular file outside the local-only names whose bytes are a blob in HEAD's tree. The commit checks hold HEAD to
# origin, so deleting such a copy loses nothing. A path find cannot read in full adds an empty name, which fails.
_check_head_copy() {
  local file hashes
  local -a files
  [[ -s $2 ]] || return 1
  mapfile -d '' files < <(find "$1/${3%/}" ! -type d -print0 2>/dev/null || printf '\0')
  ((${#files[@]} > 0)) || return 1
  for file in "${files[@]}"; do
    [[ -f $file && ! -L $file ]] || return 1
    ! _check_local_only "${file#"$1"/}" || return 1
  done
  hashes=$(git -C "$1" hash-object --no-filters -- "${files[@]}") || return 1
  ! grep -qvxF -f "$2" <<<"$hashes"
}

# Usage: _check_untracked_paths <slot path> <git status -z file>; prints each untracked (??) and ignored (!!) entry as
# "<status> <path>", NUL-separated, with a directory's trailing slash kept. git collapses an ignored directory into one
# entry, so a directory that can hold a file setup placed or a Claude Code runtime file, such as an ignored .claude/, is
# listed file by file instead, as is an ignored local-only directory such as .context/, so tool output inside it is
# told apart from the files kept there, and an ignored directory that holds a Vale package, such as a StylesPath ignored
# whole, so the package is told apart from anything else in it.
_check_untracked_paths() {
  local entry status path exempt file expand dir
  while IFS= read -r -d '' entry; do
    status=${entry:0:2}
    [[ $status == '??' || $status == '!!' ]] || continue
    path=${entry:3}
    expand=0
    if [[ $path == */ ]]; then
      [[ $status != '!!' ]] || ! _check_local_only "${path%/}" || expand=1
      for exempt in $CHECK_SETUP_FILES $CHECK_RUNTIME_FILES; do
        [[ $exempt != "$path"* ]] || expand=1
      done
      while IFS= read -r dir; do
        [[ -z $dir || $dir/ == "$path" || $dir/ != "$path"* ]] || expand=1
      done <<<"$CHECK_PACKAGE_DIRS"
    fi
    if ((expand == 0)); then
      printf '%s\0' "$entry"
      continue
    fi
    while IFS= read -r -d '' file; do
      printf '%s %s\0' "$status" "${file#"$1"/}"
    done < <(find "$1/${path%/}" -mindepth 1 \( -type f -o -type l \) -print0)
  done <"$2"
}

# Usage: _check_files <slot path>; untracked files beyond what setup placed and Claude Code's runtime files, and ignored
# files beyond those, build output, and copies of files HEAD tracks. HEAD's tree is listed once, and only for ignored
# paths nothing else exempts.
_check_files() {
  local entry status path listing tree untracked=() ignored=() local_only=()
  CHECK_PACKAGE_DIRS=$(_check_vale_packages "$1")
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
      _check_tool_output "$status" "$path" || local_only+=("${path%/}")
    elif [[ " $CHECK_SETUP_FILES $CHECK_RUNTIME_FILES " == *" ${path%/} "* ]] \
      || _check_build_output "$status" "$path" || _check_package_output "$status" "$path"; then
      continue
    elif [[ $status == '!!' ]]; then
      ignored+=("$path")
    else
      untracked+=("${path%/}")
    fi
  done < <(_check_untracked_paths "$1" "$listing")
  if ((${#ignored[@]} > 0)); then
    tree=$(git -C "$1" ls-tree -r --format='%(objecttype) %(objectname)' HEAD 2>/dev/null) || tree=
    sed -n 's/^blob //p' <<<"$tree" >"$listing"
    for path in "${ignored[@]}"; do
      _check_head_copy "$1" "$listing" "$path" || untracked+=("${path%/}")
    done
  fi
  rm -f "$listing"
  ((${#local_only[@]} == 0)) || _check_block local-only-files \
    "local-only files: ${local_only[*]:0:3}$( ((${#local_only[@]} <= 3)) || echo ' and more')" \
    "${#local_only[@]}" "${local_only[@]}"
  ((${#untracked[@]} == 0)) || _check_block untracked-files \
    "$(_check_plural "${#untracked[@]}" "untracked file"): ${untracked[*]:0:3}" "${#untracked[@]}" "${untracked[@]}"
}

# Usage: _check_uncommitted <slot path>; changes to tracked files beyond setup's docs/solutions link. A repo can track
# docs/solutions with a relative target that does not resolve from a slot, so setup re-points it at the solutions repo;
# that unstaged change is setup's, not the task's.
_check_uncommitted() {
  local out
  if ! out=$(git -C "$1" status --porcelain=v1 --untracked-files=no); then
    _check_block git-state-unknown "git status failed in the slot"
    return
  fi
  [[ $(readlink "$1/docs/solutions") != "$AS_SOLUTIONS" ]] || out=$(grep -vxF ' M docs/solutions' <<<"$out" || true)
  [[ -z $out ]] || _check_block uncommitted-changes \
    "$(_check_plural "$(grep -c . <<<"$out")" "uncommitted change")" "$(grep -c . <<<"$out")"
}

# Usage: _check_stash <slot path>; anything stashed.
_check_stash() {
  local out
  if ! out=$(git -C "$1" stash list); then
    _check_block git-state-unknown "git stash list failed in the slot"
    return
  fi
  [[ -z $out ]] || _check_block stash-present \
    "$(_check_plural "$(grep -c . <<<"$out")" "stash entry" "stash entries")" "$(grep -c . <<<"$out")"
}

# Usage: _check_agent <repo> <n>; blocks unless the slot's agent is idle or absent, from the agents agentstate_load read.
# The slot's own agent is busy while it runs a check, so that check reports checked-by-own-agent, with a next_step
# pointing at release, which tears the slot down once that agent is idle. A waiting agent waits on the operator whoever
# runs the check.
_check_agent() {
  agentstate_of "$1" "$2"
  case $AGENT_STATE in
    busy | waiting)
      if [[ $AGENT_STATE == busy ]] && agentstate_inside_agent; then
        _check_block checked-by-own-agent "this check runs inside the slot's own agent, which stays busy until it \
ends; run agent-slot release as your last step, and the slot is torn down once you are idle"
        CHECK_BLOCKERS[-1]=$(contract_json -c --arg docs "$CHECK_DOCS" --arg cmd "$RELEASE_COMMAND" \
          '. + {next_step: {action: "run", command: $cmd, docs: $docs}}' <<<"${CHECK_BLOCKERS[-1]}")
      else
        _check_block agent-not-idle "the agent is $AGENT_STATE"
      fi
      ;;
    unknown) _check_block agent-state-unknown "agent state unknown: $AGENT_DETAIL" "" "${AGENT_HOLDERS[@]}" ;;
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
      git -C "$path" fetch -q --no-tags --prune origin "${refspecs[@]}"; then
      _check_block git-state-unknown "git fetch from origin failed (log: $BOUNDED_LOG)"
    fi

    operator=$(contract_json -r '.finished_by_operator // false' <<<"$RECORD")
    mapfile -t closed < <(contract_json -r '.[] | select(.state == "CLOSED") | .number' <<<"$prs")
    if ((${#closed[@]} > 0)) && [[ $operator != true ]]; then
      _check_block pr-closed-unmerged "PR #$(printf '%s, PR #' "${closed[@]}" | sed 's/, PR #$//') closed without merging" \
        "" "${closed[@]}"
    fi

    _check_agent "$repo" "$n"

    _check_uncommitted "$path"
    _check_stash "$path"
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
                   then [$blockers[] | select(.code != "checked-by-own-agent")] else [] end),
       teardown: ($finished and ($blockers | length) == 0)}')
}

# Records the PRs a verdict found and the needs-you list it produced, when the slot's lock is free. A check run inside
# the slot's own agent records nothing: it sees that agent mid-turn, which says nothing about the slot once the turn
# ends, and its needs-you list would stand on the slot's tab until a check from outside replaced it.
check_record() {
  local repo=$1 n=$2
  [[ $(contract_json -r .state <<<"$CHECK_VERDICT") == active ]] || return 0
  ! contract_json -e 'any(.blockers[]; .code == "checked-by-own-agent")' <<<"$CHECK_VERDICT" >/dev/null || return 0
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
