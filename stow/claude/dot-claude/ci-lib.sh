#!/usr/bin/env bash
# Shared helpers for ci-verify and the Stop hook. Sourced, not executed.
#
# Conclusion classes: pass (success), fail (failure/cancelled/timed_out/
# action_required/stale/startup_failure), ignore (skipped/neutral unless
# CI_VERIFY_STRICT=1), pending (empty conclusion or a non-terminal status).
# Merge CLEAN and BEHIND pass; UNSTABLE and DIRTY fail; BLOCKED and UNKNOWN
# do not fail on their own (drafts and review rulesets use BLOCKED).

# Resolve jaq or jq into CI_GATE_JQ.
# Globals: CI_GATE_JQ
# Returns: 0 on success, 1 when neither CLI is on PATH
ci_gate::pick_jq() {
  if command -v jaq >/dev/null 2>&1; then
    CI_GATE_JQ=jaq
    return 0
  fi
  if command -v jq >/dev/null 2>&1; then
    CI_GATE_JQ=jq
    return 0
  fi
  return 1
}

# Fill defaults for every CI_VERIFY_* knob the scripts read.
# Globals: CI_VERIFY_TIMEOUT CI_VERIFY_POLL_SECONDS CI_VERIFY_SETTLE_SECONDS
#          CI_VERIFY_FOLLOW CI_VERIFY_FOLLOW_DEPTH CI_VERIFY_FOLLOW_WINDOW
#          CI_VERIFY_STRICT CI_VERIFY_FAST CI_VERIFY_JSON CI_VERIFY_ASSUME_PUSHED
#          CI_VERIFY_WORKFLOW_DIR CI_VERIFY_MAX_RUNS
ci_gate::load_config() {
  : "${CI_VERIFY_TIMEOUT:=600}"
  : "${CI_VERIFY_POLL_SECONDS:=5}"
  : "${CI_VERIFY_SETTLE_SECONDS:=8}"
  : "${CI_VERIFY_FOLLOW:=1}"
  : "${CI_VERIFY_FOLLOW_DEPTH:=3}"
  : "${CI_VERIFY_FOLLOW_WINDOW:=900}"
  : "${CI_VERIFY_STRICT:=0}"
  : "${CI_VERIFY_FAST:=0}"
  : "${CI_VERIFY_JSON:=0}"
  : "${CI_VERIFY_ASSUME_PUSHED:=0}"
  : "${CI_VERIFY_WORKFLOW_DIR:=.github/workflows}"
  : "${CI_VERIFY_MAX_RUNS:=40}"
}

# Map a GitHub conclusion+status into pass|fail|ignore|pending.
# Globals: CI_VERIFY_STRICT
# Args: $1 conclusion, $2 status
# Outputs: class name on STDOUT
ci_gate::classify() {
  local conclusion status
  conclusion=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  status=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')
  case "$conclusion" in
    null) conclusion="" ;;
  esac
  case "$status" in
    queued | in_progress | pending | waiting | requested | waiting_for_review)
      if [[ -z "$conclusion" ]]; then
        printf '%s\n' pending
        return 0
      fi
      ;;
  esac
  case "$conclusion" in
    success)
      printf '%s\n' pass
      ;;
    skipped | neutral)
      if [[ "${CI_VERIFY_STRICT}" == "1" ]]; then
        printf '%s\n' fail
      else
        printf '%s\n' ignore
      fi
      ;;
    failure | cancelled | canceled | timed_out | action_required | stale | startup_failure)
      printf '%s\n' fail
      ;;
    "")
      printf '%s\n' pending
      ;;
    *)
      printf '%s\n' fail
      ;;
  esac
}

# Map a PR mergeStateStatus into pass|fail|ignore.
# Args: $1 merge state
# Outputs: class name on STDOUT
ci_gate::merge_class() {
  local state
  state=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$state" in
    clean | behind | "") printf '%s\n' pass ;;
    unstable | dirty) printf '%s\n' fail ;;
    *) printf '%s\n' ignore ;;
  esac
}

# Invoke gh. Exists so tests can stub PATH without wrapping every call.
# Args: gh arguments
ci_gate::gh() {
  command gh "$@"
}

# Convert an ISO-8601 UTC timestamp to epoch seconds. GNU date first, BSD
# date as the macOS path. Unparseable input prints 0 so a window check can
# fail open rather than drop a child run.
# Args: $1 timestamp
# Outputs: epoch seconds on STDOUT
ci_gate::epoch() {
  local iso=$1 epoch
  epoch=$(date -u -d "$iso" +%s 2>/dev/null) && {
    printf '%s\n' "$epoch"
    return 0
  }
  iso=${iso%Z}
  iso=${iso%+00:00}
  epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%S" "$iso" +%s 2>/dev/null) && {
    printf '%s\n' "$epoch"
    return 0
  }
  printf '%s\n' 0
}

# True when $2 was created inside the follow window that starts at $1.
# Globals: CI_VERIFY_FOLLOW_WINDOW
# Args: $1 parent createdAt, $2 candidate createdAt
# Returns: 0 if in window or either stamp is unparseable
ci_gate::in_window() {
  local parent child window slack=5
  parent=$(ci_gate::epoch "$1")
  child=$(ci_gate::epoch "$2")
  window=${CI_VERIFY_FOLLOW_WINDOW}
  if [[ "$parent" == "0" || "$child" == "0" ]]; then
    return 0
  fi
  [[ "$child" -ge $((parent - slack)) && "$child" -le $((parent + window)) ]]
}

# Lowercase a string.
# Args: $1 text
# Outputs: lowercase text on STDOUT
ci_gate::lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# True when a candidate run is a dispatch/call child of the parent.
# A match is (a) the parent SHA or run id in the candidate name/title,
# (b) the same head SHA, or (c) a dispatch-like event inside the time window.
# Args: $1 parent JSON, $2 candidate JSON
# Returns: 0 on a match
ci_gate::run_matches() {
  local parent=$1 cand=$2
  local p_sha p_id p_created c_sha c_id c_created c_event c_name c_title
  p_sha=$("$CI_GATE_JQ" -r '.headSha // ""' <<<"$parent")
  p_id=$("$CI_GATE_JQ" -r '.databaseId // .id // ""' <<<"$parent")
  p_created=$("$CI_GATE_JQ" -r '.createdAt // ""' <<<"$parent")
  c_sha=$("$CI_GATE_JQ" -r '.headSha // ""' <<<"$cand")
  c_id=$("$CI_GATE_JQ" -r '.databaseId // .id // ""' <<<"$cand")
  c_created=$("$CI_GATE_JQ" -r '.createdAt // ""' <<<"$cand")
  c_event=$("$CI_GATE_JQ" -r '.event // ""' <<<"$cand")
  c_name=$("$CI_GATE_JQ" -r '.name // ""' <<<"$cand")
  c_title=$("$CI_GATE_JQ" -r '.displayTitle // ""' <<<"$cand")
  [[ "$c_id" == "$p_id" && -n "$c_id" ]] && return 1
  case "$c_event" in
    workflow_dispatch | repository_dispatch | workflow_run | workflow_call) ;;
    *) return 1 ;;
  esac
  if [[ -n "$p_sha" && ("$c_name" == *"$p_sha"* || "$c_title" == *"$p_sha"* || "$c_name" == *"${p_sha:0:7}"* || "$c_title" == *"${p_sha:0:7}"*) ]]; then
    return 0
  fi
  if [[ -n "$p_id" && ("$c_name" == *"$p_id"* || "$c_title" == *"$p_id"*) ]]; then
    return 0
  fi
  if [[ -n "$p_sha" && "$c_sha" == "$p_sha" ]]; then
    return 0
  fi
  ci_gate::in_window "$p_created" "$c_created"
}

# Fold a check list plus merge state into one reason and exit code.
# Globals: CI_GATE_REASON CI_GATE_EXIT
# Args: $1 checks JSON array, $2 merge state
ci_gate::evaluate() {
  local checks=$1 merge=$2
  local pending=0 failed=0 seen=0
  local conclusion status class
  CI_GATE_REASON="no-ci"
  CI_GATE_EXIT=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    conclusion=$("$CI_GATE_JQ" -r '.conclusion // ""' <<<"$line")
    status=$("$CI_GATE_JQ" -r '.status // ""' <<<"$line")
    seen=1
    class=$(ci_gate::classify "$conclusion" "$status")
    case "$class" in
      pending) pending=1 ;;
      fail) failed=1 ;;
    esac
  done < <("$CI_GATE_JQ" -c '.[]' <<<"$checks")
  if [[ "$pending" == "1" ]]; then
    CI_GATE_REASON="still-running"
    CI_GATE_EXIT=2
    return 0
  fi
  if [[ "$failed" == "1" ]]; then
    CI_GATE_REASON="checks-failed"
    CI_GATE_EXIT=1
    return 0
  fi
  if [[ "$(ci_gate::merge_class "$merge")" == "fail" ]]; then
    CI_GATE_REASON="checks-failed"
    CI_GATE_EXIT=1
    return 0
  fi
  if [[ "$seen" == "1" ]]; then
    CI_GATE_REASON="ok"
  fi
  # Read by ci-verify after this function returns.
  : "${CI_GATE_REASON}" "${CI_GATE_EXIT}"
}
