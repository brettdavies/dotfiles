# shellcheck shell=bash disable=SC2034 # its globals are read by the files that source it
# The read verbs: repos, list, whoami.

# Prime checkouts, as tab-separated name, path, and origin URL, sorted by name. A prime checkout is a clone (a .git
# directory, never a worktree's .git file) with an origin, directly under the dev root or named in the extra list.
repo_primes() {
  local dir origin
  local -a dirs=("$AS_DEV"/*/)
  local IFS=:
  # shellcheck disable=SC2206
  dirs+=($AS_EXTRA_PRIMES)
  unset IFS
  for dir in "${dirs[@]}"; do
    dir=${dir%/}
    [[ -d $dir/.git ]] || continue
    origin=$(git -C "$dir" config --get remote.origin.url 2>/dev/null) || continue
    printf '%s\t%s\t%s\n' "${dir##*/}" "$dir" "$origin"
  done | sort -t $'\t' -k1,1 -u
}

# Usage: repo_prime <name>; sets REPO_PRIME and REPO_ORIGIN, or fails with repo-not-found.
REPO_PRIME=
REPO_ORIGIN=
repo_prime() {
  local name path origin
  while IFS=$'\t' read -r name path origin; do
    if [[ $name == "$1" ]]; then
      REPO_PRIME=$path REPO_ORIGIN=$origin
      return 0
    fi
  done < <(repo_primes)
  contract_fail repo-not-found "no prime checkout named $1 with an origin under $AS_DEV" --value "$1" \
    --command "agent-slot repos"
}

cmd_repos() {
  local json
  json=$(repo_primes | contract_json -R -s -c '
    split("\n") | map(select(. != "") | split("\t") | {name: .[0], prime: .[1], origin: .[2]}) | {repos: .}')
  contract_ok "$json" '.repos[] | "\(.name)\t\(.prime)"'
}

# label_name($branch), on a slot record: the one label every surface shows for the slot, its name, else its task, else
# the branch its clone has checked out ($branch, "" for none).
SLOT_LABEL_DEF='def label_name($branch): .name // .task // (if $branch == "" then null else $branch end);'

# Usage: slot_branch <path>; prints the branch the slot's clone has checked out, or nothing.
slot_branch() {
  [[ ! -d $1/.git ]] || git -C "$1" symbolic-ref --short -q HEAD || true
}

# Usage: slot_view <repo> <n> <session-list>
# Sets SLOT_VIEW to the slot as list reports it: the record's fields plus agent state, tmux sessions, branch, the
# needs-you list, and label_name.
SLOT_VIEW=
slot_view() {
  local repo=$1 n=$2 sessions=$3 rec path state agent branch claude=false files=false git=false
  path=$(slot_path "$repo" "$n")
  if record_read "$repo" "$n"; then
    rec=$RECORD
  else
    rec=$(contract_json -n -c --arg r "$repo" --argjson n "$n" '{repo: $r, slot: $n, state: "setting-up"}')
  fi
  ! grep -qxF "$(slot_session "$repo" "$n")" <<<"$sessions" || claude=true
  ! grep -qxF "$(slot_session "$repo" "$n" files)" <<<"$sessions" || files=true
  ! grep -qxF "$(slot_session "$repo" "$n" git)" <<<"$sessions" || git=true
  state=$(contract_json -r '.state // "active"' <<<"$rec")
  [[ $state != active || $claude == true ]] || state=dormant
  agentstate_of "$repo" "$n"
  agent=$AGENT_STATE
  branch=$(slot_branch "$path")
  SLOT_VIEW=$(contract_json -c --arg key "$(slot_key "$repo" "$n")" --arg path "$path" --arg state "$state" \
    --arg agent "$agent" --arg detail "$AGENT_DETAIL" --arg branch "$branch" --argjson claude "$claude" \
    --argjson files "$files" --argjson git "$git" "$SLOT_LABEL_DEF"'
    label_name($branch) as $label | (if $branch == "" then null else $branch end) as $branch
    | . + {key: $key, path: $path, state: $state, branch: $branch, label_name: $label,
         agent: $agent, agent_detail: (if $detail == "" then null else $detail end),
         sessions: {claude: $claude, files: $files, git: $git},
         needs_you: (.last_check.blockers // [])}' <<<"$rec")
}

cmd_list() {
  local sessions repo n views=()
  contract_use_tools tmux claude
  slot_sessions_or_fail
  sessions=$SLOT_SESSIONS
  agentstate_load
  while read -r repo; do
    [[ -n $repo ]] || continue
    while read -r n; do
      [[ -n $n ]] || continue
      slot_view "$repo" "$n" "$sessions"
      views+=("$SLOT_VIEW")
    done < <(slot_numbers "$repo")
  done < <(slot_repos)
  contract_ok "$(printf '%s\n' "${views[@]}" | contract_json -s -c '{slots: .}')" '
    if (.slots | length) == 0 then "no slots"
    else .slots[] | "\(.key)\t\(.state)\t\(.agent)\t\(.label_name // "-")" +
      (if (.needs_you | length) > 0 then "\tneeds you: \(.needs_you[0].message)" else "" end)
    end'
}

# Usage: slot_at <dir>; prints "<repo> <n>" for the slot holding dir, or returns 1.
slot_at() {
  local dir rel repo n
  dir=$(realpath -m "$1")
  [[ $dir == "$AS_ROOT_REAL"/* ]] || return 1
  rel=${dir#"$AS_ROOT_REAL"/}
  repo=${rel%%/*}
  rel=${rel#"$repo"}
  rel=${rel#/}
  n=${rel%%/*}
  [[ -n $repo && $n =~ ^[0-9]+$ ]] || return 1
  printf '%s %s' "$repo" "$n"
}

cmd_whoami() {
  local dir=${WHOAMI_PATH:-$PWD} at='' repo='' n=''
  at=$(slot_at "$dir") || true
  [[ -z $at ]] || read -r repo n <<<"$at"
  if [[ -z $at ]] || ! record_read "$repo" "$n"; then
    contract_fail not-in-slot "$dir is not inside a slot under $AS_ROOT" --value "$dir" --command "agent-slot list"
  fi
  contract_ok "$(contract_json -c --arg key "$(slot_key "$repo" "$n")" --arg path "$(slot_path "$repo" "$n")" \
    --arg branch "$(slot_branch "$(slot_path "$repo" "$n")")" "$SLOT_LABEL_DEF"'
    {slot: (. + {key: $key, path: $path, label_name: label_name($branch)})}' <<<"$RECORD")" \
    '.slot | "\(.key) at \(.path)\(if .label_name then " (\(.label_name))" else "" end)"'
}
