#!/usr/bin/env bash
# Discover runs and follow dispatch / reusable-workflow children.
# Sourced by ci-verify after ci-lib.sh.

# Print extra owner/repo targets found in workflow YAML plus CI_VERIFY_DISPATCH_REPOS.
# Globals: CI_VERIFY_WORKFLOW_DIR CI_VERIFY_DISPATCH_REPOS CI_VERIFY_REPO
# Outputs: one owner/repo per line
ci_gate::scan_dispatch_repos() {
  local dir=${CI_VERIFY_WORKFLOW_DIR} f extra
  local -a found=()
  if [[ -d "$dir" ]]; then
    for f in "$dir"/*.yml "$dir"/*.yaml; do
      [[ -f "$f" ]] || continue
      while IFS= read -r extra; do
        [[ -n "$extra" ]] && found+=("$extra")
      done < <(grep -oE '[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/' "$f" | sed 's|/.github/workflows/||' || true)
      while IFS= read -r extra; do
        [[ -n "$extra" ]] && found+=("$extra")
      done < <(grep -oE 'repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/dispatches' "$f" | sed -E 's|^repos/||; s|/dispatches$||' || true)
      if grep -qE 'repository-dispatch|repository_dispatch' "$f"; then
        while IFS= read -r extra; do
          [[ -n "$extra" ]] && found+=("$extra")
        done < <(grep -oE 'repository:[[:space:]]*["'"'"']?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$f" | sed -E 's/.*repository:[[:space:]]*["'"'"']?//' || true)
      fi
    done
  fi
  if [[ -n "${CI_VERIFY_DISPATCH_REPOS:-}" ]]; then
    IFS=',' read -r -a extra <<<"$CI_VERIFY_DISPATCH_REPOS"
    found+=("${extra[@]}")
  fi
  if [[ ${#found[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${found[@]}" | awk -v self="${CI_VERIFY_REPO:-}" 'NF && $0 != self' | sort -u
}

# Emit one check object as a single JSON line.
# Args: $1 name, $2 conclusion, $3 status, $4 url, $5 repo, $6 run id, $7 kind
ci_gate::emit_check() {
  local conclusion status
  conclusion=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  status=$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')
  # shellcheck disable=SC2016  # jq program; $names are --arg bindings
  "$CI_GATE_JQ" -n \
    --arg name "$1" \
    --arg conclusion "$conclusion" \
    --arg status "$status" \
    --arg url "$4" \
    --arg repo "$5" \
    --arg run_id "$6" \
    --arg kind "$7" \
    '{name:$name, conclusion:$conclusion, status:$status, url:$url, repo:$repo, run_id:$run_id, kind:$kind}'
}

# List recent runs on a repo. Empty array on any gh failure.
# Args: $1 owner/repo, $2 optional --commit SHA
# Outputs: JSON array
ci_gate::list_runs() {
  local repo=$1 sha=${2:-} args=()
  args=(-R "$repo" --limit "$CI_VERIFY_MAX_RUNS"
    --json "databaseId,name,status,conclusion,workflowName,event,createdAt,headSha,displayTitle,url")
  if [[ -n "$sha" ]]; then
    args+=(--commit "$sha")
  fi
  ci_gate::gh run list "${args[@]}" 2>/dev/null || printf '%s\n' '[]'
}

# Follow one run: emit it, its jobs (reusable workflow jobs live here), then children.
# Globals: CI_GATE_SEEN CI_VERIFY_FOLLOW CI_VERIFY_FOLLOW_DEPTH CI_VERIFY_REPO
# Args: $1 owner/repo, $2 run id, $3 depth, $4 parent JSON
ci_gate::follow_run() {
  local repo=$1 id=$2 depth=$3 parent=${4:-} key detail job_line
  local name conclusion status url
  key="${repo}#${id}"
  [[ -n "${CI_GATE_SEEN[$key]:-}" ]] && return 0
  CI_GATE_SEEN[$key]=1
  detail=$(ci_gate::gh run view "$id" -R "$repo" \
    --json databaseId,name,status,conclusion,workflowName,event,createdAt,headSha,displayTitle,url,jobs \
    2>/dev/null) || return 0
  [[ -n "$detail" && "$detail" != "null" ]] || return 0
  name=$("$CI_GATE_JQ" -r '.workflowName // .name // "run"' <<<"$detail")
  conclusion=$("$CI_GATE_JQ" -r '.conclusion // ""' <<<"$detail")
  status=$("$CI_GATE_JQ" -r '.status // ""' <<<"$detail")
  url=$("$CI_GATE_JQ" -r '.url // ""' <<<"$detail")
  ci_gate::emit_check "$name" "$conclusion" "$status" "$url" "$repo" "$id" run
  while IFS= read -r job_line; do
    [[ -n "$job_line" ]] || continue
    ci_gate::emit_check \
      "$("$CI_GATE_JQ" -r '.name' <<<"$job_line")" \
      "$("$CI_GATE_JQ" -r '.conclusion // ""' <<<"$job_line")" \
      "$("$CI_GATE_JQ" -r '.status // ""' <<<"$job_line")" \
      "$("$CI_GATE_JQ" -r '.url // ""' <<<"$job_line")" \
      "$repo" "$id" job
  done < <("$CI_GATE_JQ" -c '.jobs // [] | .[]' <<<"$detail")
  if [[ "${CI_VERIFY_FOLLOW}" != "1" || "$depth" -ge "${CI_VERIFY_FOLLOW_DEPTH}" ]]; then
    return 0
  fi
  [[ -z "$parent" ]] && parent=$detail
  ci_gate::follow_children "$repo" "$detail" "$depth"
}

# Find and follow dispatch/call children of one parent, same-repo and extra repos.
# Args: $1 parent repo, $2 parent JSON, $3 depth
ci_gate::follow_children() {
  local repo=$1 parent=$2 depth=$3 extra cand
  ci_gate::follow_candidates "$repo" "$parent" "$depth" "$(ci_gate::list_runs "$repo")"
  while IFS= read -r extra; do
    [[ -n "$extra" ]] || continue
    ci_gate::follow_candidates "$extra" "$parent" "$depth" "$(ci_gate::list_runs "$extra")"
  done < <(ci_gate::scan_dispatch_repos)
}

# Walk a run-list JSON array and follow each matching child.
# Args: $1 repo, $2 parent JSON, $3 depth, $4 runs JSON
ci_gate::follow_candidates() {
  local repo=$1 parent=$2 depth=$3 runs=$4 cand id
  [[ -n "$runs" && "$runs" != "null" ]] || return 0
  while IFS= read -r cand; do
    [[ -n "$cand" ]] || continue
    ci_gate::run_matches "$parent" "$cand" || continue
    id=$("$CI_GATE_JQ" -r '.databaseId // empty' <<<"$cand")
    [[ -n "$id" ]] || continue
    ci_gate::follow_run "$repo" "$id" $((depth + 1)) "$parent"
  done < <("$CI_GATE_JQ" -c '.[]' <<<"$runs")
}

# Collect every check for the current SHA / PR / followed children.
# Globals: CI_VERIFY_REPO CI_VERIFY_SHA CI_VERIFY_PR CI_GATE_MERGE CI_GATE_PR_URL
# Outputs: JSON array of checks
ci_gate::collect() {
  local checks runs run_id rollup
  CI_GATE_MERGE=""
  CI_GATE_PR_URL=""
  declare -gA CI_GATE_SEEN=()
  {
    if [[ -n "${CI_VERIFY_PR:-}" ]]; then
      rollup=$(ci_gate::gh pr view "$CI_VERIFY_PR" -R "$CI_VERIFY_REPO" \
        --json number,url,mergeStateStatus,statusCheckRollup 2>/dev/null) || rollup=""
    else
      rollup=$(ci_gate::gh pr view -R "$CI_VERIFY_REPO" \
        --json number,url,mergeStateStatus,statusCheckRollup 2>/dev/null) || rollup=""
    fi
    if [[ -n "$rollup" && "$rollup" != "null" ]]; then
      CI_GATE_MERGE=$("$CI_GATE_JQ" -r '.mergeStateStatus // ""' <<<"$rollup")
      CI_GATE_PR_URL=$("$CI_GATE_JQ" -r '.url // ""' <<<"$rollup")
      : "${CI_GATE_MERGE}" "${CI_GATE_PR_URL}"
      while IFS= read -r checks; do
        [[ -n "$checks" ]] || continue
        ci_gate::emit_check \
          "$("$CI_GATE_JQ" -r '.name // "check"' <<<"$checks")" \
          "$("$CI_GATE_JQ" -r '.conclusion // ""' <<<"$checks")" \
          "$("$CI_GATE_JQ" -r '.status // ""' <<<"$checks")" \
          "$("$CI_GATE_JQ" -r '.detailsUrl // .targetUrl // ""' <<<"$checks")" \
          "$CI_VERIFY_REPO" "" check
      done < <("$CI_GATE_JQ" -c '.statusCheckRollup // [] | .[]' <<<"$rollup")
    fi
    runs=$(ci_gate::list_runs "$CI_VERIFY_REPO" "$CI_VERIFY_SHA")
    while IFS= read -r run_id; do
      [[ -n "$run_id" ]] || continue
      ci_gate::follow_run "$CI_VERIFY_REPO" "$run_id" 0 ""
    done < <("$CI_GATE_JQ" -r '.[] | .databaseId // empty' <<<"$runs")
  } | "$CI_GATE_JQ" -s 'unique_by(.url + "|" + .name + "|" + .run_id)'
}
