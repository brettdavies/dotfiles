#!/usr/bin/env bash
# ci-verify — wait for CI on the current branch's latest pushed commit, then
# return one exit code from the checks' actual conclusions and the PR merge
# state. 0 only when every required check passed.
#
# A check is green only at conclusion success. failure, cancelled, timed_out,
# action_required, stale, and startup_failure fail the gate. skipped and
# neutral are ignored unless CI_VERIFY_STRICT=1. Late-registering checks are
# caught by one re-poll after CI_VERIFY_SETTLE_SECONDS.
#
# Followed work:
#   (a) reusable workflow / composite jobs on the caller run (workflow_call
#       `uses: owner/repo/.github/workflows/x.yml@ref`)
#   (b) workflow_dispatch, repository_dispatch, workflow_run, and
#       workflow_call runs, same-repo and cross-repo, including chains
#
# Correlation (first match wins):
#   1. Child run-name / displayTitle contains the origin SHA (full or 7-char)
#      or origin run id — put `ci_verify_sha` / `ci_verify_run` in the
#      dispatch payload or `run-name:` so this hits. The run list API does
#      not expose client_payload.
#   2. Child headSha equals the origin SHA (intra-repo dispatches).
#   3. Fallback: dispatch-like event created inside CI_VERIFY_FOLLOW_WINDOW
#      seconds of the parent. Can attach an unrelated concurrent dispatch.
#
# Extra target repos come from CI_VERIFY_DISPATCH_REPOS (comma-separated),
# --dispatch-repo, and a scan of .github/workflows for repository-dispatch
# targets and reusable-workflow `uses:` repos.
#
# Merge CLEAN and BEHIND pass. UNSTABLE and DIRTY fail. BLOCKED does not fail
# the gate by itself (drafts and review rulesets use it); check conclusions
# still decide. UNKNOWN is treated the same way as BLOCKED.
#
# Exit codes:
#   0  ok | no-ci | not-pushed | no-repo
#   1  checks-failed
#   2  still-running (deadline or --fast snapshot)
#   3  usage
#   4  could-not-verify (missing gh, jq/jaq, or another dependency).
#      Prints a WARNING that CI was NOT verified. The Stop hook treats 4 as
#      warn-and-allow: the turn ends, the WARNING is surfaced.
#
# Knobs (env or flags): CI_VERIFY_TIMEOUT (600), CI_VERIFY_POLL_SECONDS (5),
# CI_VERIFY_SETTLE_SECONDS (8), CI_VERIFY_FOLLOW (1), CI_VERIFY_FOLLOW_DEPTH
# (3), CI_VERIFY_FOLLOW_WINDOW (900), CI_VERIFY_DISPATCH_REPOS,
# CI_VERIFY_STRICT (0), CI_VERIFY_ALLOW_STOP (Stop hook only).
#
# This script only GETs run/PR data. It never creates a dispatch.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$HERE/ci-lib.sh"
# shellcheck disable=SC1091
source "$HERE/ci-follow.sh"

# Print a could-not-verify WARNING and exit 4.
# Args: $1 missing tool name, e.g. "gh" or "jq (or jaq)"
# Returns: 4
ci_verify::unverified() {
  local tool=$1
  local message="WARNING: ${tool} is not on PATH. CI was NOT verified."
  if [[ "${CI_VERIFY_JSON:-0}" == "1" && -n "${CI_GATE_JQ:-}" ]]; then
    # shellcheck disable=SC2016  # jq program; $names are --arg bindings
    "$CI_GATE_JQ" -n \
      --arg message "$message" \
      --arg tool "$tool" \
      '{reason:"could-not-verify", exit_code:4, message:$message, missing:$tool,
        next_step:{action:"install", command:"", docs:"file:~/.claude/ci-verify.sh"}}'
  else
    echo "ci-verify: $message" >&2
  fi
  exit 4
}

# Print usage to STDERR.
# Returns: 3
ci_verify::usage() {
  echo "usage: ci-verify [--fast] [--json] [--timeout N] [--settle-seconds N] [--poll-seconds N]" >&2
  echo "                 [--sha SHA] [--branch B] [--repo OWNER/REPO] [--pr N]" >&2
  echo "                 [--no-follow] [--follow-depth N] [--dispatch-repo OWNER/REPO]" >&2
  exit 3
}

# Parse CLI flags into CI_VERIFY_* env vars.
# Args: argv
ci_verify::parse() {
  local extra=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fast) CI_VERIFY_FAST=1 ;;
      --json) CI_VERIFY_JSON=1 ;;
      --timeout)
        CI_VERIFY_TIMEOUT=$2
        shift
        ;;
      --settle-seconds)
        CI_VERIFY_SETTLE_SECONDS=$2
        shift
        ;;
      --poll-seconds)
        CI_VERIFY_POLL_SECONDS=$2
        shift
        ;;
      --sha)
        CI_VERIFY_SHA=$2
        shift
        ;;
      --branch)
        CI_VERIFY_BRANCH=$2
        shift
        ;;
      --repo)
        CI_VERIFY_REPO=$2
        shift
        ;;
      --pr)
        CI_VERIFY_PR=$2
        shift
        ;;
      --no-follow) CI_VERIFY_FOLLOW=0 ;;
      --follow-depth)
        CI_VERIFY_FOLLOW_DEPTH=$2
        shift
        ;;
      --dispatch-repo)
        extra="${extra:+$extra,}$2"
        shift
        ;;
      -h | --help) ci_verify::usage ;;
      *) ci_verify::usage ;;
    esac
    shift
  done
  if [[ -n "$extra" ]]; then
    CI_VERIFY_DISPATCH_REPOS="${CI_VERIFY_DISPATCH_REPOS:+$CI_VERIFY_DISPATCH_REPOS,}$extra"
  fi
  : "${CI_VERIFY_PR:-}" "${CI_VERIFY_FOLLOW:-}" "${CI_VERIFY_FOLLOW_DEPTH:-}"
}

# Resolve repo / branch / SHA from git and gh when flags left them empty.
# Returns: 0, or prints a no-repo/not-pushed result and exits
ci_verify::resolve() {
  if [[ -z "${CI_VERIFY_SHA:-}" || -z "${CI_VERIFY_BRANCH:-}" ]]; then
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || ci_verify::finish no-repo 0 '[]' ""
    : "${CI_VERIFY_SHA:=$(git rev-parse HEAD 2>/dev/null || true)}"
    : "${CI_VERIFY_BRANCH:=$(git branch --show-current 2>/dev/null || true)}"
  fi
  if [[ -z "${CI_VERIFY_REPO:-}" ]]; then
    CI_VERIFY_REPO=$(ci_gate::gh repo view --json nameWithOwner 2>/dev/null | "$CI_GATE_JQ" -r '.nameWithOwner // empty' || true)
  fi
  if [[ -z "${CI_VERIFY_SHA:-}" || -z "${CI_VERIFY_REPO:-}" ]]; then
    ci_verify::finish no-repo 0 '[]' ""
  fi
  if [[ "${CI_VERIFY_ASSUME_PUSHED}" != "1" ]] && ! ci_verify::is_pushed; then
    ci_verify::finish not-pushed 0 '[]' ""
  fi
}

# True when HEAD is on a remote-tracking ref.
# Returns: 0 if pushed
ci_verify::is_pushed() {
  local sha=$CI_VERIFY_SHA branch=$CI_VERIFY_BRANCH ref
  [[ -n "$sha" ]] || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  if [[ -n "$branch" ]]; then
    ref=$(git rev-parse --verify "refs/remotes/origin/${branch}" 2>/dev/null || true)
    [[ "$ref" == "$sha" ]] && return 0
  fi
  git branch -r --contains "$sha" 2>/dev/null | grep -q .
}

# Print the human or JSON report and exit.
# Args: $1 reason, $2 exit, $3 checks JSON, $4 merge
ci_verify::finish() {
  local reason=$1 exit_code=$2 checks=$3 merge=$4
  local message failed next_action next_cmd
  case "$reason" in
    ok) message="GREEN (${CI_VERIFY_SHA:0:7}${merge:+, merge $merge})" ;;
    no-ci) message="no CI runs or checks for ${CI_VERIFY_SHA:0:7} — nothing to wait for" ;;
    not-pushed) message="HEAD is not on a remote-tracking branch — nothing pushed" ;;
    no-repo) message="no git repo / SHA — nothing to verify" ;;
    still-running) message="CI still running for ${CI_VERIFY_SHA:0:7}" ;;
    checks-failed) message="CI failed for ${CI_VERIFY_SHA:0:7}" ;;
    *) message=$reason ;;
  esac
  failed=$("$CI_GATE_JQ" -c '[.[] | select(.conclusion == "failure" or .conclusion == "cancelled"
    or .conclusion == "canceled" or .conclusion == "timed_out" or .conclusion == "action_required"
    or .conclusion == "stale" or .conclusion == "startup_failure")]' <<<"$checks")
  case "$reason" in
    checks-failed) next_action="investigate" ;;
    still-running) next_action="wait" ;;
    *) next_action="none" ;;
  esac
  next_cmd="$HERE/ci-verify.sh"
  if [[ "${CI_VERIFY_JSON}" == "1" ]]; then
    # shellcheck disable=SC2016  # jq program; $names are --arg bindings
    "$CI_GATE_JQ" -n \
      --arg reason "$reason" \
      --argjson exit_code "$exit_code" \
      --arg message "$message" \
      --arg sha "${CI_VERIFY_SHA:-}" \
      --arg branch "${CI_VERIFY_BRANCH:-}" \
      --arg merge "$merge" \
      --argjson checks "$checks" \
      --arg action "$next_action" \
      --arg command "$next_cmd" \
      '{reason:$reason, exit_code:$exit_code, message:$message, sha:$sha, branch:$branch, merge:$merge, checks:$checks,
        next_step:{action:$action, command:$command, docs:"file:~/.claude/ci-verify.sh"}}'
  else
    echo "ci-verify: $message"
    if [[ "$reason" == "checks-failed" ]]; then
      echo ""
      echo "failed:"
      "$CI_GATE_JQ" -r '.[] | "  - \(.name) (\(.conclusion))  \(.url)"' <<<"$failed"
      [[ -n "$merge" ]] && echo "merge: $merge"
    elif [[ "$reason" == "still-running" ]]; then
      echo ""
      "$CI_GATE_JQ" -r '.[] | "  - \(.name) [\(.status)//\(.conclusion)]  \(.url)"' <<<"$checks"
    fi
  fi
  exit "$exit_code"
}

# Wait until checks finish (or --fast / deadline), then settle once and judge.
ci_verify::wait() {
  local deadline now checks settled=0
  now=$(date +%s)
  deadline=$((now + CI_VERIFY_TIMEOUT))
  while true; do
    checks=$(ci_gate::collect)
    ci_gate::evaluate "$checks" "${CI_GATE_MERGE:-}"
    if [[ "${CI_GATE_REASON}" != "still-running" ]]; then
      if [[ "${CI_VERIFY_FAST}" == "1" || "$settled" == "1" ]]; then
        ci_verify::finish "$CI_GATE_REASON" "$CI_GATE_EXIT" "$checks" "${CI_GATE_MERGE:-}"
      fi
      if [[ "${CI_VERIFY_SETTLE_SECONDS}" -gt 0 ]]; then
        sleep "${CI_VERIFY_SETTLE_SECONDS}"
      fi
      settled=1
      continue
    fi
    if [[ "${CI_VERIFY_FAST}" == "1" ]]; then
      ci_verify::finish still-running 2 "$checks" "${CI_GATE_MERGE:-}"
    fi
    now=$(date +%s)
    if [[ "$now" -ge "$deadline" ]]; then
      ci_verify::finish still-running 2 "$checks" "${CI_GATE_MERGE:-}"
    fi
    sleep "${CI_VERIFY_POLL_SECONDS}"
  done
}

main() {
  ci_verify::parse "$@"
  ci_gate::load_config
  ci_gate::pick_jq || ci_verify::unverified "jq (or jaq)"
  command -v gh >/dev/null 2>&1 || ci_verify::unverified "gh"
  ci_verify::resolve
  ci_verify::wait
}

main "$@"
