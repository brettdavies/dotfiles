#!/usr/bin/env bats
# Stop hook: refuse the turn while CI is red or still running.
#
# Run: bats tests/ci-stop-gate.bats

HOOK="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/ci-stop-gate.sh"
VERIFY="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/ci-verify.sh"

setup() {
  FIX="$BATS_TEST_TMPDIR/fix"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$FIX" "$STUBS"
  printf '%s\n' 0 >"$FIX/pr.views"
  _install_gh_stub
  export CI_VERIFY_FIXTURE="$FIX"
  export CI_VERIFY_ASSUME_PUSHED=1
  export CI_VERIFY_SHA=abc123def456
  export CI_VERIFY_BRANCH=feat/x
  export CI_VERIFY_REPO=owner/app
  export CI_VERIFY_TIMEOUT=5
  export CI_VERIFY_POLL_SECONDS=0
  export CI_VERIFY_SETTLE_SECONDS=0
  export CI_VERIFY_FOLLOW=1
  export CI_VERIFY_ALLOW_STOP=0
  unset CI_VERIFY_ALLOW_STOP
}

_install_gh_stub() {
  cat >"$STUBS/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
FIX=${CI_VERIFY_FIXTURE:?}
printf '%s\n' "$*" >>"$FIX/calls.log"
repo=""
prev=""
id=""
has_commit=0
for arg in "$@"; do
  case "$prev" in
    -R | --repo) repo=$arg ;;
    --commit) has_commit=1 ;;
  esac
  case "$arg" in
    --repo=*) repo=${arg#--repo=} ;;
    --commit=*) has_commit=1 ;;
  esac
  [[ "$arg" =~ ^[0-9]+$ ]] && id=$arg
  prev=$arg
done
slug=${repo:-origin}
slug=${slug//\//_}
pick() {
  local base=$1 n=$2 s=$3 f
  for f in "$FIX/${base}-${n}.${s}.json" "$FIX/${base}.${s}.json" "$FIX/${base}-${n}.json" "$FIX/${base}.json"; do
    if [[ -f "$f" ]]; then
      cat "$f"
      return 0
    fi
  done
  return 1
}
case "${1:-} ${2:-}" in
  "repo view") pick repo 1 "$slug" || printf '%s\n' '{"nameWithOwner":"owner/app"}' ;;
  "pr view")
    [[ -f "$FIX/pr.missing" ]] && exit 1
    n=$(cat "$FIX/pr.views" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" >"$FIX/pr.views"
    pick pr "$n" "$slug" || printf '%s\n' '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"CLEAN","statusCheckRollup":[]}'
    ;;
  "run list")
    if [[ "$has_commit" == "1" ]]; then
      pick runs-sha 1 "$slug" || pick runs 1 "$slug" || printf '%s\n' '[]'
    else
      pick runs-all 1 "$slug" || pick runs 1 "$slug" || printf '%s\n' '[]'
    fi
    ;;
  "run view") pick "run-${id}" 1 "$slug" || printf '%s\n' '{}' ;;
  *) echo "gh-stub: unhandled: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUBS/gh"
}

_write() {
  printf '%s\n' "$2" >"$FIX/$1"
}

_hook() {
  local payload=${1:-'{"stop_hook_active":false}'}
  printf '%s\n' "$payload" | PATH="$STUBS:$PATH" "$HOOK"
}

@test "still-running CI blocks Stop" {
  touch "$FIX/pr.missing"
  _write runs.json '[{"databaseId":101,"name":"CI","status":"in_progress","conclusion":"","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101"}]'
  _write run-101.json '{"databaseId":101,"name":"CI","status":"in_progress","conclusion":"","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"","status":"in_progress","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _hook
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  [[ "$output" == *"still running"* || "$output" == *"ci-verify.sh"* ]]
}

@test "red CI blocks Stop and names the failed check" {
  touch "$FIX/pr.missing"
  _write runs.json '[{"databaseId":101,"name":"CI","status":"completed","conclusion":"failure","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101"}]'
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"failure","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"failure","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _hook
  echo "$output"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  [[ "$output" == *"bats"* ]]
  [[ "$output" == *"CI_VERIFY_ALLOW_STOP"* ]]
}

@test "green CI allows Stop" {
  _write pr.json '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"bats","conclusion":"SUCCESS","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/101"}]}'
  _write runs.json '[{"databaseId":101,"name":"CI","status":"completed","conclusion":"success","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101"}]'
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"success","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"success","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _hook
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "stop_hook_active allows Stop even when CI is red" {
  touch "$FIX/pr.missing"
  _write runs.json '[{"databaseId":101,"name":"CI","status":"completed","conclusion":"failure","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101"}]'
  run _hook '{"stop_hook_active":true}'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "CI_VERIFY_ALLOW_STOP=1 allows Stop even when CI is red" {
  touch "$FIX/pr.missing"
  _write runs.json '[{"databaseId":101,"name":"CI","status":"completed","conclusion":"failure","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101"}]'
  run env PATH="$STUBS:$PATH" CI_VERIFY_FIXTURE="$FIX" \
    CI_VERIFY_ASSUME_PUSHED=1 CI_VERIFY_SHA=abc123def456 \
    CI_VERIFY_REPO=owner/app CI_VERIFY_ALLOW_STOP=1 \
    bash -c 'printf "%s\n" "{\"stop_hook_active\":false}" | "'"$HOOK"'"'
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "no CI is a fast path that allows Stop" {
  touch "$FIX/pr.missing"
  _write runs.json '[]'
  run _hook
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "ci-stop-gate.sh is executable and uses bash" {
  [ -x "$HOOK" ]
  head -1 "$HOOK" | grep -q bash
  [ -x "$VERIFY" ]
}
