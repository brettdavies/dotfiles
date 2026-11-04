#!/usr/bin/env bats
# agent-slot launch and the dependencies a JavaScript repo's lockfile pins: a slot has them before its agent starts, from
# a frozen install that never writes a lockfile, and a failed install is reported without costing the slot.
#
# Run: bats tests/agent-slot-deps.bats
# run-tests: parallel

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot
load lib/processes

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  export AGENT_SLOT_LOCK_WAIT=2 AGENT_SLOT_TRUST_TIMEOUT=3
  # A launch from an SSH command or a Claude hook arrives without the shell's age gate, so the gate tests start there too.
  unset npm_config_min_release_age npm_config_minimum_release_age
  prime repoa
  PRIME=$AGENT_SLOT_DEV/repoa
  mkdir -p "$PRIME/node_modules/some-tool"
  SLOT=$AGENT_SLOT_ROOT/repoa/1
  trusted "$(realpath -m "$SLOT")" "$(realpath -m "$PRIME")"
  LEDGER=$AGENT_SLOT_STATE_DIR/ledger.jsonl
}

teardown() {
  stop_spawned
  assert_no_leaks
}

launch() {
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id "$1" --output json
  echo "launch: status=$status output=$output stderr=${stderr:-}"
}

# js_repo FILE...: gives repoa's origin a package.json that ignores node_modules, and each named lockfile.
js_repo() {
  local file
  origin_file repoa .gitignore 'node_modules/'
  origin_file repoa package.json '{"name": "repoa"}'
  for file in "$@"; do origin_file repoa "$file" 'locked'; done
}

# stub_manager NAME [BODY]: stands in for a package manager. It answers --version as a release with the age gate does,
# records where it ran and the environment it was given, populates node_modules, then runs BODY.
stub_manager() {
  stub "$1" "
if [ \"\${1:-}\" = --version ]; then echo 11.16.0; exit 0; fi
{
  echo \"cwd=\$PWD\"
  echo \"playwright=\${PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD:-}\"
  echo \"npm_age=\${npm_config_min_release_age:-}\"
  echo \"pnpm_age=\${npm_config_minimum_release_age:-}\"
} >\"\$STUBS/$1-ran\"
mkdir -p node_modules/.bin
$2"
  export "AGENT_SLOT_${1^^}=$STUBS/$1"
}

ran() { grep -qxF "$2" "$STUBS/$1-ran"; }

# A body for stub_manager: starts a process that ignores TERM and outlives the install, and records its pid.
# shellcheck disable=SC2016 # expanded by the stub that runs it
LEFTOVER='(trap "" TERM HUP; exec sleep 120) </dev/null >/dev/null 2>&1 &
echo "$!" >"$STUBS/leftover-pid"'

# leftover_is_gone: the recorded process is dead, by its pid, since this suite's tests run side by side and a search by
# name would find a sibling's. A killed orphan is reaped by init a moment later, and until then it still answers kill -0.
leftover_is_gone() {
  local pid i
  pid=$(<"$STUBS/leftover-pid")
  for ((i = 0; i < 20; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  echo "still running: $pid"
  return 1
}

# never_called PATTERN: bats does not fail a test on a bare `! grep` that is not its last command.
never_called() {
  if grep -qE "$1" "$CALLS"; then
    echo "called: $1"
    return 1
  fi
}

# tree_holds_no_install: nothing the install touched shows in git status. A slot's setup files do, in this fixture.
tree_holds_no_install() {
  local listed
  listed=$(git -C "$SLOT" status --porcelain)
  echo "status: $listed"
  [[ $listed != *node_modules* && $listed != *bun.lock* && $listed != *package.json* ]]
}

last_launch() { jaq -e -s "map(select(.event == \"launch\")) | .[-1] | $1" "$LEDGER"; }

# real_bun: the real bun, or skips. A file: dependency keeps the real install offline.
real_bun() {
  AGENT_SLOT_BUN=$(command -v bun) || skip "bun not installed"
  export AGENT_SLOT_BUN
  local seed=$T/seed-repoa
  mkdir -p "$seed/vendor/tool"
  printf '{"name": "tool", "version": "1.0.0"}\n' >"$seed/vendor/tool/package.json"
  printf '{"name": "repoa", "dependencies": {"tool": "file:./vendor/tool"}}\n' >"$seed/package.json"
  printf 'node_modules/\n' >"$seed/.gitignore"
  (cd "$seed" && "$AGENT_SLOT_BUN" install --save-text-lockfile >/dev/null 2>&1)
  git -C "$seed" add .gitignore package.json bun.lock vendor
  git -C "$seed" commit -q -m 'a real lockfile'
  git -C "$seed" push -q origin HEAD:main
  LOCK_SHA=$(git -C "$seed" hash-object bun.lock)
}

@test "a bun repo's slot gets a frozen install in the clone, before its agent starts" {
  js_repo bun.lock
  stub_manager bun
  launch r-bun
  [ "$status" -eq 0 ]
  grep -qxF 'bun install --frozen-lockfile' "$CALLS"
  ran bun "cwd=$(realpath "$SLOT")"
  ran bun 'playwright=1'
  [ -d "$SLOT/node_modules" ]
  installed=$(grep -n '^bun install' "$CALLS" | cut -d: -f1)
  started=$(grep -n '^tmux .*new-session' "$CALLS" | head -1 | cut -d: -f1)
  [ -n "$started" ] && [ "$installed" -lt "$started" ]
}

@test "the launch reports the install in its output, the slot's record, and the ledger with its phase" {
  js_repo bun.lock
  stub_manager bun
  launch r-report
  [ "$status" -eq 0 ]
  jaq -e '.deps == {manager: "bun", command: "bun install --frozen-lockfile", status: "installed", log: null,
    dirty: [], stopped: []}' <<<"$output"
  jaq -e '.phases.deps | type == "number"' <<<"$output"
  jaq -e '.deps.status == "installed"' "$SLOT/.git/agent-slot.json"
  last_launch '.deps.status == "installed" and (.phases.deps | type == "number")'
}

@test "an npm repo's slot gets npm ci under the supply-chain age gate" {
  js_repo package-lock.json
  stub_manager npm
  launch r-npm
  [ "$status" -eq 0 ]
  grep -qxF 'npm ci' "$CALLS"
  ran npm 'npm_age=7'
  ran npm 'playwright=1'
  jaq -e '.deps == {manager: "npm", command: "npm ci", status: "installed", log: null, dirty: [], stopped: []}' <<<"$output"
}

@test "a pnpm repo's slot gets a frozen install under the supply-chain age gate" {
  js_repo pnpm-lock.yaml
  stub_manager pnpm
  launch r-pnpm
  [ "$status" -eq 0 ]
  grep -qxF 'pnpm install --frozen-lockfile' "$CALLS"
  ran pnpm 'pnpm_age=10080'
  jaq -e '.deps.manager == "pnpm" and .deps.status == "installed"' <<<"$output"
}

@test "a repo that holds both lockfiles is installed with bun" {
  js_repo pnpm-lock.yaml bun.lock
  stub_manager bun
  stub_manager pnpm
  launch r-both
  [ "$status" -eq 0 ]
  grep -qxF 'bun install --frozen-lockfile' "$CALLS"
  never_called '^pnpm install'
}

@test "a repo with no package.json installs nothing, even with a lockfile" {
  origin_file repoa bun.lock 'locked'
  stub_manager bun
  launch r-nopkg
  [ "$status" -eq 0 ]
  never_called '^bun '
  jaq -e '.deps == null and (.phases.deps | type == "number")' <<<"$output"
}

@test "a package.json with no lockfile it can install from installs nothing" {
  origin_file repoa package.json '{"name": "repoa"}'
  stub_manager bun
  stub_manager npm
  launch r-nolock
  [ "$status" -eq 0 ]
  never_called '^(bun|npm) (install|ci)'
  jaq -e '.deps == null' <<<"$output"
  [ ! -e "$SLOT/node_modules" ]
}

@test "a repo that does not ignore node_modules is reported and not installed, so no tree lands in its git status" {
  origin_file repoa package.json '{"name": "repoa"}'
  origin_file repoa bun.lock 'locked'
  stub_manager bun
  launch r-unignored
  [ "$status" -eq 0 ]
  never_called '^bun install'
  [ ! -e "$SLOT/node_modules" ]
  jaq -e '.deps.status == "not-ignored" and .deps.manager == "bun"' <<<"$output"
}

@test "a prime with no node_modules is reported and not installed, since nothing shows this repo's install has run here" {
  js_repo bun.lock
  stub_manager bun
  rm -rf "$PRIME/node_modules"
  launch r-noinstall
  [ "$status" -eq 0 ]
  never_called '^bun install'
  [ ! -e "$SLOT/node_modules" ]
  jaq -e '.deps == {manager: "bun", command: "bun install --frozen-lockfile", status: "prime-not-set-up", log: null,
    dirty: [], stopped: []} and .state == "active"' <<<"$output"
}

@test "a prime whose node_modules is empty is not set up" {
  js_repo bun.lock
  stub_manager bun
  rm -rf "$PRIME/node_modules"
  mkdir "$PRIME/node_modules"
  launch r-empty
  [ "$status" -eq 0 ]
  never_called '^bun install'
  jaq -e '.deps.status == "prime-not-set-up"' <<<"$output"
}

@test "a prime whose node_modules holds only .cache is not set up" {
  js_repo bun.lock
  stub_manager bun
  rm -rf "$PRIME/node_modules"
  mkdir -p "$PRIME/node_modules/.cache/prettier"
  launch r-cache
  [ "$status" -eq 0 ]
  never_called '^bun install'
  jaq -e '.deps.status == "prime-not-set-up"' <<<"$output"
}

@test "a prime whose node_modules is a file or a dangling link is not set up" {
  js_repo bun.lock
  stub_manager bun
  rm -rf "$PRIME/node_modules"
  : >"$PRIME/node_modules"
  launch r-file
  [ "$status" -eq 0 ]
  never_called '^bun install'
  jaq -e '.deps.status == "prime-not-set-up"' <<<"$output"
}

@test "a prime whose node_modules is a link to an installed tree is set up" {
  js_repo bun.lock
  stub_manager bun
  rm -rf "$PRIME/node_modules"
  mkdir -p "$T/elsewhere/tool"
  ln -s "$T/elsewhere" "$PRIME/node_modules"
  launch r-link
  [ "$status" -eq 0 ]
  grep -qxF 'bun install --frozen-lockfile' "$CALLS"
}

@test "an untrusted prime is reported and not installed, even with node_modules" {
  js_repo bun.lock
  stub_manager bun
  jaq --arg p "$(realpath -m "$PRIME")" 'del(.projects[$p])' "$AGENT_SLOT_CLAUDE_STATE" >"$T/state.new"
  cp "$T/state.new" "$AGENT_SLOT_CLAUDE_STATE"
  launch r-untrusted
  [ "$status" -eq 0 ]
  never_called '^bun install'
  jaq -e '.deps.status == "prime-not-set-up"' <<<"$output"
}

@test "a dev that reached origin but that the prime has never held is off the base, whoever pushed it" {
  js_repo bun.lock
  stub_manager bun
  git -C "$T/seed-repoa" push -q origin main:refs/heads/dev
  launch r-newdev
  [ "$status" -eq 0 ]
  never_called '^bun install'
  jaq -e '.deps.status == "head-not-on-base" and .state == "active"' <<<"$output"
}

@test "a dev the prime holds is the base, and its tip installs" {
  js_repo bun.lock
  stub_manager bun
  git -C "$T/seed-repoa" push -q origin main:refs/heads/dev
  git -C "$PRIME" fetch -q origin dev:refs/heads/dev
  launch r-owndev
  [ "$status" -eq 0 ]
  grep -qxF 'bun install --frozen-lockfile' "$CALLS"
  jaq -e '.deps.status == "installed" and .base == "dev"' <<<"$output"
}

@test "a failed install keeps the slot, and its output in a log the launch names" {
  js_repo bun.lock
  stub_manager bun 'echo "lockfile had changes, but lockfile is frozen" >&2; exit 1'
  launch r-fail
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "failed" and .state == "active"' <<<"$output"
  log=$(jaq -r '.deps.log' <<<"$output")
  grep -q 'lockfile is frozen' "$log"
  grep -q 'new-session' "$CALLS"
}

@test "an install past its time limit is stopped, and the slot is still made" {
  js_repo bun.lock
  stub_manager bun 'sleep 30'
  export AGENT_SLOT_DEPS_TIMEOUT=1
  launch r-slow
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "timed-out" and .state == "active"' <<<"$output"
  [ -r "$(jaq -r '.deps.log' <<<"$output")" ]
}

@test "an install that ignores its stop signal and has to be killed still reads as timed-out" {
  js_repo bun.lock
  stub_manager bun "trap '' TERM; exec sleep 30"
  AGENT_SLOT_DEPS_TIMEOUT=1 launch r-wedged
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "timed-out" and .state == "active"' <<<"$output"
}

@test "an install killed from outside before its limit reads as failed, not timed-out" {
  js_repo bun.lock
  stub_manager bun 'kill -9 $$'
  launch r-killed
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "failed"' <<<"$output"
  grep -q '^exit: 137' "$(jaq -r '.deps.log' <<<"$output")"
}

@test "an install that changes a tracked file or adds an untracked one names them, and still reads installed" {
  js_repo bun.lock
  stub_manager bun 'echo stamped >>package.json; echo built >stamp.txt'
  launch r-dirty
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "installed" and (.deps.dirty | sort) == ["package.json", "stamp.txt"]' <<<"$output"
  last_launch '(.deps.dirty | sort) == ["package.json", "stamp.txt"]'
}

@test "a workspace tree a root-anchored ignore misses is named, while the root's is not" {
  origin_file repoa .gitignore '/node_modules/'
  origin_file repoa package.json '{"name": "repoa"}'
  origin_file repoa bun.lock 'locked'
  stub_manager bun 'mkdir -p packages/a/node_modules/tool; touch packages/a/node_modules/tool/index.js'
  launch r-workspace
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "installed" and .deps.dirty == ["packages/"]' <<<"$output"
}

@test "what a failed install leaves dirty is named too" {
  js_repo bun.lock
  stub_manager bun 'echo half >half-done.txt; exit 1'
  launch r-dirty-failed
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "failed" and .deps.dirty == ["half-done.txt"]' <<<"$output"
}

@test "setup's own files in the slot are not counted as the install's" {
  js_repo bun.lock
  stub_manager bun
  launch r-clean
  [ "$status" -eq 0 ]
  jaq -e '.deps.dirty == []' <<<"$output"
}

@test "a process an install leaves running is stopped and named, so it holds no slot" {
  js_repo bun.lock
  stub_manager bun "$LEFTOVER"
  launch r-leftover
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "installed" and .deps.stopped == ["sleep"]' <<<"$output"
  leftover_is_gone
}

@test "a process left behind by an install that timed out is stopped too" {
  js_repo bun.lock
  stub_manager bun "$LEFTOVER
sleep 30"
  AGENT_SLOT_DEPS_TIMEOUT=1 launch r-leftover-timeout
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "timed-out" and (.deps.stopped | index("sleep") != null)' <<<"$output"
  leftover_is_gone
}

@test "an install's own session is what gets stopped, not a process setup already had" {
  js_repo bun.lock
  stub_manager bun
  spawn sleep 120
  launch r-other
  [ "$status" -eq 0 ]
  kill -0 "${SPAWNED[0]}"
  jaq -e '.deps.stopped == []' <<<"$output"
}

@test "a package manager this host lacks is reported, and the slot is still made" {
  js_repo pnpm-lock.yaml
  export AGENT_SLOT_PNPM=$T/no-such-pnpm
  launch r-absent
  [ "$status" -eq 0 ]
  jaq -e '.deps == {manager: "pnpm", command: "pnpm install --frozen-lockfile", status: "tool-missing", log: null,
    dirty: [], stopped: []} and .state == "active"' <<<"$output"
}

@test "a launch in text mode says when dependencies did not install, and names the log" {
  js_repo bun.lock
  stub_manager bun 'exit 1'
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-text
  [ "$status" -eq 0 ]
  echo "output: $output"
  [[ $output == *"is ready"*"dependencies did not install when this slot was made (failed)"*"log: "*deps.log* ]]
}

@test "a launch in text mode says nothing about dependencies that installed" {
  js_repo bun.lock
  stub_manager bun
  run --separate-stderr "$AGENT_SLOT" launch repoa --request-id r-text-ok
  [ "$status" -eq 0 ]
  echo "output: $output"
  [[ $output == *"is ready"* ]]
  [[ $output != *"dependencies"* ]]
}

@test "a real frozen install populates node_modules, leaves the tree clean, and blocks no teardown" {
  real_bun
  launch r-real
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "installed"' <<<"$output"
  [ -f "$SLOT/node_modules/tool/package.json" ]
  [ "$(git -C "$SLOT" hash-object bun.lock)" = "$LOCK_SHA" ]
  tree_holds_no_install
  echo '[]' >"$STUBS/gh-prs.json"
  stub_gh_items
  run --separate-stderr "$AGENT_SLOT" check repoa/1 --output json
  echo "check: status=$status output=$output stderr=${stderr:-}"
  [ "$status" -eq 0 ]
  jaq -e '.slots[0].blockers | (type == "array") and ([.[].code]
    | all(. != "untracked-files" and . != "local-only-files" and . != "uncommitted-changes"))' <<<"$output"
}

@test "a real frozen install refuses a lockfile its package.json disagrees with, and does not rewrite it" {
  real_bun
  printf '{"name": "repoa", "dependencies": {"tool": "file:./vendor/tool", "other": "file:./vendor/tool"}}\n' \
    >"$T/seed-repoa/package.json"
  git -C "$T/seed-repoa" add package.json
  git -C "$T/seed-repoa" commit -q -m 'a package.json ahead of its lockfile'
  git -C "$T/seed-repoa" push -q origin HEAD:main
  launch r-drift
  [ "$status" -eq 0 ]
  jaq -e '.deps.status == "failed"' <<<"$output"
  [ "$(git -C "$SLOT" hash-object bun.lock)" = "$LOCK_SHA" ]
  tree_holds_no_install
}
