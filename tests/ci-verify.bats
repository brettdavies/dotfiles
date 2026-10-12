#!/usr/bin/env bats
# Exit-code and follow logic for ~/.claude/ci-verify.sh, with gh stubbed.
#
# Run: bats tests/ci-verify.bats

VERIFY="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/ci-verify.sh"
LIB="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/ci-lib.sh"
SETTINGS="$BATS_TEST_DIRNAME/../stow/claude/dot-claude/settings.json"

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
  export CI_VERIFY_FOLLOW_DEPTH=3
  export CI_VERIFY_FOLLOW_WINDOW=900
  export CI_VERIFY_STRICT=0
  export CI_VERIFY_FAST=0
  export CI_VERIFY_JSON=0
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
  "repo view")
    pick repo 1 "$slug" || printf '%s\n' '{"nameWithOwner":"owner/app"}'
    ;;
  "pr view")
    if [[ -f "$FIX/pr.missing" ]]; then
      exit 1
    fi
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
  "run view")
    pick "run-${id}" 1 "$slug" || pick "run-${id}" 1 origin || printf '%s\n' '{}'
    ;;
  *)
    echo "gh-stub: unhandled: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$STUBS/gh"
}

_run_json() {
  printf '%s\n' '{"name":"CI","conclusion":"success","status":"completed","url":"https://github.com/owner/app/actions/runs/101","databaseId":101,"workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat"}'
}

_write() {
  printf '%s\n' "$2" >"$FIX/$1"
}

_verify() {
  PATH="$STUBS:$PATH" "$VERIFY" "$@"
}

# ---------------------------------------------------------------------------
# classify (sourced library)
# ---------------------------------------------------------------------------

@test "classify: success → pass" {
  # shellcheck disable=SC1090
  source "$LIB"
  [ "$(ci_gate::classify success completed)" = pass ]
}

@test "classify: FAILURE uppercase → fail" {
  # shellcheck disable=SC1090
  source "$LIB"
  [ "$(ci_gate::classify FAILURE COMPLETED)" = fail ]
}

@test "classify: cancelled → fail" {
  # shellcheck disable=SC1090
  source "$LIB"
  [ "$(ci_gate::classify cancelled completed)" = fail ]
}

@test "classify: timed_out → fail" {
  # shellcheck disable=SC1090
  source "$LIB"
  [ "$(ci_gate::classify timed_out completed)" = fail ]
}

@test "classify: action_required → fail" {
  # shellcheck disable=SC1090
  source "$LIB"
  [ "$(ci_gate::classify action_required completed)" = fail ]
}

@test "classify: skipped → ignore" {
  # shellcheck disable=SC1090
  source "$LIB"
  CI_VERIFY_STRICT=0
  [ "$(ci_gate::classify skipped completed)" = ignore ]
}

@test "classify: neutral → ignore" {
  # shellcheck disable=SC1090
  source "$LIB"
  CI_VERIFY_STRICT=0
  [ "$(ci_gate::classify neutral completed)" = ignore ]
}

@test "classify: empty conclusion + in_progress → pending" {
  # shellcheck disable=SC1090
  source "$LIB"
  [ "$(ci_gate::classify "" in_progress)" = pending ]
}

@test "evaluate: success + CLEAN → exit 0" {
  # shellcheck disable=SC1090
  source "$LIB"
  ci_gate::pick_jq
  CI_VERIFY_STRICT=0
  ci_gate::evaluate '[{"conclusion":"success","status":"completed"}]' CLEAN
  [ "$CI_GATE_EXIT" -eq 0 ]
  [ "$CI_GATE_REASON" = ok ]
}

@test "evaluate: cancelled → exit 1" {
  # shellcheck disable=SC1090
  source "$LIB"
  ci_gate::pick_jq
  ci_gate::evaluate '[{"conclusion":"cancelled","status":"completed"}]' CLEAN
  [ "$CI_GATE_EXIT" -eq 1 ]
  [ "$CI_GATE_REASON" = checks-failed ]
}

@test "evaluate: skipped-only → exit 0" {
  # shellcheck disable=SC1090
  source "$LIB"
  ci_gate::pick_jq
  CI_VERIFY_STRICT=0
  ci_gate::evaluate '[{"conclusion":"skipped","status":"completed"}]' CLEAN
  [ "$CI_GATE_EXIT" -eq 0 ]
  [ "$CI_GATE_REASON" = ok ]
}

@test "evaluate: still running → exit 2" {
  # shellcheck disable=SC1090
  source "$LIB"
  ci_gate::pick_jq
  ci_gate::evaluate '[{"conclusion":"","status":"in_progress"}]' ""
  [ "$CI_GATE_EXIT" -eq 2 ]
  [ "$CI_GATE_REASON" = still-running ]
}

# ---------------------------------------------------------------------------
# ci-verify through a stubbed gh
# ---------------------------------------------------------------------------

@test "pass: required checks success and merge CLEAN → 0" {
  _write pr.json '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"bats","conclusion":"SUCCESS","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/101"}]}'
  _write runs.json "[$(_run_json)]"
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"success","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"success","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"GREEN"* ]]
}

@test "fail: a check conclusion is failure → 1" {
  _write pr.json '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"name":"bats","conclusion":"FAILURE","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/101"}]}'
  _write runs.json "[$(_run_json)]"
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"failure","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"failure","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bats"* ]]
  [[ "$output" == *"https://github.com/owner/app/actions/runs/101"* ]]
}

@test "fail: cancelled run → 1" {
  touch "$FIX/pr.missing"
  _write runs.json '[{"databaseId":101,"name":"CI","status":"completed","conclusion":"cancelled","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101"}]'
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"cancelled","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[]}'
  run _verify
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"cancelled"* ]]
}

@test "skipped-only required checks → 0" {
  _write pr.json '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"windows","conclusion":"SKIPPED","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/101"}]}'
  _write runs.json "[$(_run_json)]"
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"skipped","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"windows","conclusion":"skipped","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "late-registering check that fails is caught on settle re-poll → 1" {
  _write pr-1.json '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"CLEAN","statusCheckRollup":[{"name":"bats","conclusion":"SUCCESS","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/101"}]}'
  _write pr-2.json '{"number":1,"url":"https://github.com/owner/app/pull/1","mergeStateStatus":"UNSTABLE","statusCheckRollup":[{"name":"bats","conclusion":"SUCCESS","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/101"},{"name":"late","conclusion":"FAILURE","status":"COMPLETED","detailsUrl":"https://github.com/owner/app/actions/runs/109"}]}'
  _write runs.json "[$(_run_json)]"
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"success","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"success","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"late"* ]]
}

@test "reusable workflow job failure on the caller run → 1" {
  touch "$FIX/pr.missing"
  _write runs.json "[$(_run_json)]"
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"failure","workflowName":"CI","event":"pull_request","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"shared / lint","conclusion":"failure","status":"completed","url":"https://github.com/brettdavies/.github/actions/runs/9/job/2"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"shared / lint"* ]]
}

@test "intra-repo workflow_dispatch failure is followed → 1" {
  touch "$FIX/pr.missing"
  _write runs-sha.json "[$(_run_json)]"
  _write runs-all.json "[$(_run_json),{\"databaseId\":202,\"name\":\"finalize\",\"status\":\"completed\",\"conclusion\":\"failure\",\"workflowName\":\"finalize-release\",\"event\":\"workflow_dispatch\",\"createdAt\":\"2026-10-12T00:01:00Z\",\"headSha\":\"dddddddd\",\"displayTitle\":\"finalize abc123def456\",\"url\":\"https://github.com/owner/app/actions/runs/202\"}]"
  _write run-101.json '{"databaseId":101,"name":"CI","status":"completed","conclusion":"success","workflowName":"CI","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"feat","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"bats","conclusion":"success","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  _write run-202.json '{"databaseId":202,"name":"finalize","status":"completed","conclusion":"failure","workflowName":"finalize-release","event":"workflow_dispatch","createdAt":"2026-10-12T00:01:00Z","headSha":"dddddddd","displayTitle":"finalize abc123def456","url":"https://github.com/owner/app/actions/runs/202","jobs":[{"name":"publish","conclusion":"failure","status":"completed","url":"https://github.com/owner/app/actions/runs/202/job/1"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"finalize"* || "$output" == *"publish"* ]]
}

@test "inter-repo repository_dispatch failure is followed → 1" {
  touch "$FIX/pr.missing"
  mkdir -p "$FIX/workflows"
  cat >"$FIX/workflows/release.yml" <<'YML'
name: release
jobs:
  tap:
    steps:
      - uses: peter-evans/repository-dispatch@v3
        with:
          repository: other/tap
          event-type: formula-update
YML
  export CI_VERIFY_WORKFLOW_DIR="$FIX/workflows"
  _write runs.json "[$(_run_json)]"
  _write run-101.json '{"databaseId":101,"name":"release","status":"completed","conclusion":"success","workflowName":"release","event":"push","createdAt":"2026-10-12T00:00:00Z","headSha":"abc123def456","displayTitle":"release","url":"https://github.com/owner/app/actions/runs/101","jobs":[{"name":"tap","conclusion":"success","status":"completed","url":"https://github.com/owner/app/actions/runs/101/job/1"}]}'
  _write runs.other_tap.json '[{"databaseId":303,"name":"update-formula","status":"completed","conclusion":"failure","workflowName":"update-formula","event":"repository_dispatch","createdAt":"2026-10-12T00:01:00Z","headSha":"eeeeeeee","displayTitle":"formula abc123def456","url":"https://github.com/other/tap/actions/runs/303"}]'
  _write run-303.other_tap.json '{"databaseId":303,"name":"update-formula","status":"completed","conclusion":"failure","workflowName":"update-formula","event":"repository_dispatch","createdAt":"2026-10-12T00:01:00Z","headSha":"eeeeeeee","displayTitle":"formula abc123def456","url":"https://github.com/other/tap/actions/runs/303","jobs":[{"name":"commit","conclusion":"failure","status":"completed","url":"https://github.com/other/tap/actions/runs/303/job/1"}]}'
  run _verify
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"other/tap"* || "$output" == *"update-formula"* || "$output" == *"commit"* ]]
}

@test "not pushed HEAD is a fast path → 0" {
  unset CI_VERIFY_ASSUME_PUSHED
  export CI_VERIFY_ASSUME_PUSHED=0
  sandbox="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$sandbox"
  git -C "$sandbox" init -q -b feat/x
  git -C "$sandbox" config user.email test@example.com
  git -C "$sandbox" config user.name test
  git -C "$sandbox" config commit.gpgsign false
  printf 'x\n' >"$sandbox/f"
  git -C "$sandbox" add f
  git -C "$sandbox" commit -q -m seed
  run env -C "$sandbox" PATH="$STUBS:$PATH" \
    CI_VERIFY_FIXTURE="$FIX" CI_VERIFY_ASSUME_PUSHED=0 \
    CI_VERIFY_REPO=owner/app CI_VERIFY_TIMEOUT=5 \
    CI_VERIFY_POLL_SECONDS=0 CI_VERIFY_SETTLE_SECONDS=0 \
    "$VERIFY"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing pushed"* ]]
}

@test "no CI runs or checks → 0" {
  touch "$FIX/pr.missing"
  _write runs.json '[]'
  run _verify
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no CI"* ]]
}

@test "settings.json registers the Stop hook on ci-stop-gate.sh" {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  run jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$SETTINGS"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci-stop-gate.sh"* ]]
}
