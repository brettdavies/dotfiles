#!/usr/bin/env bats
# agent-slot check: the fail-closed teardown verdict.
#
# Run: bats tests/agent-slot-check.bats
#
# Each test builds a real slot clone of a bare origin (task_slot_setup in tests/lib/agent-slot.bash).

bats_require_minimum_version 1.5.0

load lib/platform
load lib/agent-slot

setup_file() {
  require_linux "agent-slot reads /proc for agent state"
}

setup() {
  agent_slot_setup
  task_slot_setup
  SLEEPERS=()
}

teardown() {
  local pid
  for pid in "${SLEEPERS[@]}"; do kill "$pid" 2>/dev/null || true; done
}

# Usage: check [dir]; runs from dir with agent-slot exec'd, so no shell of the test's own holds dir as its cwd.
check() {
  run --separate-stderr bash -c 'cd "$1" && exec "$2" check repoa/1 --output json' _ "${1:-$PWD}" "$AGENT_SLOT"
  [ "$status" -eq 0 ] || {
    echo "$stderr"
    false
  }
  VERDICT=$(jaq -c '.slots[0]' <<<"$output")
}

has_blocker() { jaq -e --arg c "$1" 'any(.blockers[]; .code == $c)' <<<"$VERDICT" >/dev/null; }
lacks_blocker() { jaq -e --arg c "$1" 'all(.blockers[]; .code != $c)' <<<"$VERDICT" >/dev/null; }

# merged_with PATH...: a finished task whose one squash-merged PR adds the given paths, which the test has written.
merged_with() {
  work feat/x
  git -C "$SLOT" add -- "$@"
  git -C "$SLOT" commit -q -m 'add files'
  git -C "$SLOT" push -q origin feat/x
  pr 7 MERGED feat/x
  squash_merge feat/x
}

listed() {
  git -C "$SLOT" status --porcelain=v1 --ignored=matching --untracked-files=all | grep -qxF "$1"
}

@test "control: a finished, clean, fully pushed slot with no agent passes" {
  finished_task
  check
  jaq -e '.finished == true and .finished_by == "merge" and .blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "AE5: a merged PR plus one unpushed commit blocks with unpushed-commits, count 1" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'after the merge'
  check
  jaq -e '.finished == true and .teardown == false
    and (.needs_you[] | select(.code == "unpushed-commits") | .count == 1 and .message == "1 unpushed commit")' \
    <<<"$VERDICT"
}

@test "AE6: an agent reported busy or waiting blocks with agent-not-idle" {
  finished_task
  local status_value
  for status_value in busy waiting; do
    jaq -n -c --arg cwd "$SLOT" --arg s "$status_value" '[{pid: 1, cwd: $cwd, status: $s}]' >"$STUBS/claude-agents.json"
    check
    has_blocker agent-not-idle
    jaq -e '.teardown == false' <<<"$VERDICT"
  done
}

@test "an idle agent passes" {
  finished_task
  jaq -n -c --arg cwd "$SLOT" '[{pid: 1, cwd: $cwd, status: "idle"}]' >"$STUBS/claude-agents.json"
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
}

@test "check run from inside the slot passes an idle agent; its own /proc scan does not block" {
  finished_task
  jaq -n -c --arg cwd "$SLOT" '[{pid: 1, cwd: $cwd, status: "idle"}]' >"$STUBS/claude-agents.json"
  check "$SLOT"
  lacks_blocker agent-state-unknown
  jaq -e '.teardown == true' <<<"$VERDICT"
}

@test "a shell outside the slot's panes with its working directory in the slot blocks with agent-state-unknown" {
  finished_task
  (cd "$SLOT" && exec setsid sleep 120 </dev/null >/dev/null 2>&1) &
  SLEEPERS+=($!)
  local n=0
  until [ "$(readlink "/proc/${SLEEPERS[0]}/cwd" 2>/dev/null)" = "$SLOT" ] || ((n++ > 50)); do sleep 0.1; done
  check
  has_blocker agent-state-unknown
}

@test "a failed claude agents lookup blocks with agent-state-unknown" {
  finished_task
  stub claude 'exit 1'
  check
  has_blocker agent-state-unknown
  jaq -e '.teardown == false' <<<"$VERDICT"
}

@test "AE9: a PR closed without merging blocks with pr-closed-unmerged naming it, though the task has not finished" {
  work feat/y
  git -C "$SLOT" push -q origin feat/y
  pr 9 CLOSED feat/y
  check
  jaq -e '.finished == false and (.needs_you[] | select(.code == "pr-closed-unmerged")
    | .message == "PR #9 closed without merging" and .values == ["9"])' <<<"$VERDICT"
}

@test "AE10: a commit pushed after the merge, onto a recreated branch with no PR, blocks with commits-without-pr" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'one more'
  git -C "$SLOT" push -q origin feat/x
  check
  jaq -e '.needs_you[] | select(.code == "commits-without-pr") | .count == 1
    and .message == "1 commit on a branch with no PR"' <<<"$VERDICT"
  lacks_blocker unpushed-commits
}

@test "a dev-based slot passes though the clone's local default branch holds history dev lacks" {
  git clone -q "$ORIGIN" "$T/devmaker"
  git -C "$T/devmaker" checkout -q --orphan dev
  git -C "$T/devmaker" commit -q --allow-empty -m 'dev root'
  git -C "$T/devmaker" push -q origin dev
  git -C "$SLOT" fetch -q origin
  git -C "$SLOT" checkout -q -B dev origin/dev
  jaq -c '.base = "dev"' "$SLOT/.git/agent-slot.json" >"$T/record" && mv "$T/record" "$SLOT/.git/agent-slot.json"
  work feat/x 2
  git -C "$SLOT" push -q origin feat/x
  pr 7 MERGED feat/x
  check
  jaq -e '.finished == true and .blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "a fetch from origin that fails blocks with git-state-unknown" {
  finished_task
  git -C "$SLOT" remote set-url origin "$T/missing.git"
  check
  jaq -e 'any(.blockers[]; .code == "git-state-unknown" and (.message | startswith("git fetch from origin failed")))
    and .teardown == false' <<<"$VERDICT"
}

@test "a commit on a local branch that is neither checked out nor pushed blocks with unpushed-commits" {
  finished_task
  git -C "$SLOT" checkout -q -b side
  git -C "$SLOT" commit -q --allow-empty -m 'side work'
  git -C "$SLOT" checkout -q feat/x
  check
  jaq -e '.blockers[] | select(.code == "unpushed-commits") | .count == 1' <<<"$VERDICT"
}

@test "a commit reachable only from a local tag blocks with unpushed-commits" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'tagged work'
  git -C "$SLOT" tag local-only
  git -C "$SLOT" reset -q --hard HEAD~1
  check
  jaq -e '.blockers[] | select(.code == "unpushed-commits") | .count == 1' <<<"$VERDICT"
}

@test "with no PR, a commit reachable only from a local tag blocks with unpushed-commits" {
  work feat/y
  git -C "$SLOT" push -q origin feat/y
  git -C "$SLOT" commit -q --allow-empty -m 'tagged work'
  git -C "$SLOT" tag local-only
  git -C "$SLOT" reset -q --hard HEAD~1
  check
  jaq -e '.prs == [] and (.blockers[] | select(.code == "unpushed-commits") | .count == 1)' <<<"$VERDICT"
}

@test "a tag origin deletes after a check saw it leaves nothing behind that blocks" {
  finished_task
  git clone -q "$ORIGIN" "$T/tagger"
  git -C "$T/tagger" commit -q --allow-empty -m 'release'
  git -C "$T/tagger" tag v1
  git -C "$T/tagger" push -q origin v1
  check
  git -C "$T/tagger" push -q origin --delete v1
  check
  jaq -e '.blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "a tag origin has, on a commit no origin branch holds, does not block" {
  finished_task
  git clone -q "$ORIGIN" "$T/tagger"
  git -C "$T/tagger" commit -q --allow-empty -m 'release'
  git -C "$T/tagger" tag v1
  git -C "$T/tagger" push -q origin v1
  git -C "$SLOT" fetch -q origin --tags
  check
  jaq -e '.blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "AE11: two PRs, one merged and one open, is not finished" {
  finished_task
  git -C "$SLOT" checkout -q -B feat/second main
  git -C "$SLOT" commit -q --allow-empty -m second
  git -C "$SLOT" push -q origin feat/second
  pr 8 OPEN feat/second
  check
  jaq -e '.finished == false and .teardown == false and .needs_you == []' <<<"$VERDICT"
}

@test "a stale remote-tracking ref for a deleted branch does not count once fetch prunes it" {
  work feat/z
  git -C "$SLOT" push -q origin feat/z
  git --git-dir="$ORIGIN" update-ref -d refs/heads/feat/z
  jaq '.finished_by_operator = true' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  git -C "$SLOT" rev-parse -q --verify refs/remotes/origin/feat/z
  check
  jaq -e '.needs_you[] | select(.code == "unpushed-commits") | .count == 1' <<<"$VERDICT"
}

@test "a task with no PR whose commits are on an origin branch passes once the operator finished it" {
  work feat/w
  git -C "$SLOT" push -q origin feat/w
  jaq '.finished_by_operator = true' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  check
  jaq -e '.finished == true and .finished_by == "operator" and .teardown == true' <<<"$VERDICT"
}

@test "a gh failure blocks with pr-state-unknown and never finishes" {
  finished_task
  stub gh 'echo boom >&2; exit 1'
  check
  jaq -e '.finished == false and .teardown == false
    and any(.needs_you[]; .code == "pr-state-unknown")' <<<"$VERDICT"
}

@test "local-only files block; dependency output, the docs/solutions link, and the slot's Claude settings do not" {
  finished_task
  printf 'node_modules/\n.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/node_modules/pkg" "$SLOT/.claude" "$SLOT/docs" "$T/shared/notes"
  touch "$SLOT/node_modules/pkg/index.js" "$T/shared/notes/a.md"
  echo '{}' >"$SLOT/.claude/settings.local.json"
  ln -s "$T/shared" "$SLOT/docs/solutions"
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
  mkdir -p "$SLOT/.context/handoffs"
  touch "$SLOT/.context/handoffs/next.md"
  check
  jaq -e '.needs_you[] | select(.code == "local-only-files") | .values == [".context/handoffs/next.md"]' <<<"$VERDICT"
}

@test "untracked files under build- and dist-named source directories block" {
  finished_task
  mkdir -p "$SLOT/tools/build" "$SLOT/src/dist"
  echo deploy >"$SLOT/tools/build/deploy.sh"
  echo notes >"$SLOT/src/dist/notes.md"
  check
  jaq -e '.blockers[] | select(.code == "untracked-files") | .values == ["src/dist/notes.md", "tools/build/deploy.sh"]' \
    <<<"$VERDICT"
}

@test "a new ignored file in a build directory that holds tracked files blocks; a wholly ignored one does not" {
  work feat/x
  mkdir -p "$SLOT/tools/build"
  echo tracked >"$SLOT/tools/build/tracked.sh"
  git -C "$SLOT" add tools/build/tracked.sh
  git -C "$SLOT" commit -q -m 'tracked build script'
  git -C "$SLOT" push -q origin feat/x
  pr 7 MERGED feat/x
  squash_merge feat/x
  echo 'build/' >"$SLOT/.git/info/exclude"
  echo new >"$SLOT/tools/build/new.sh"
  mkdir -p "$SLOT/out/build"
  echo object >"$SLOT/out/build/o.o"
  check
  jaq -e '.blockers == [{code: "untracked-files", message: "1 untracked file: tools/build/new.sh", count: 1,
    values: ["tools/build/new.sh"]}]' <<<"$VERDICT"
}

@test "ignored Astro, Wrangler, Blume, and SwiftPM output that git lists whole does not block" {
  finished_task
  printf '.astro/\n.wrangler/\n.blume/\n.build/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/apps/demo/.astro" "$SLOT/workers/web/.wrangler/state" "$SLOT/apps/docs/.blume" "$SLOT/pkg/.build"
  echo '{}' >"$SLOT/apps/demo/.astro/data-store.json"
  echo db >"$SLOT/workers/web/.wrangler/state/d1.sqlite"
  echo '<html>' >"$SLOT/apps/docs/.blume/index.html"
  echo yaml >"$SLOT/pkg/.build/debug.yaml"
  listed '!! workers/web/.wrangler/'
  check
  jaq -e '.blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "ignored files in a tool directory that also holds tracked files do not block" {
  mkdir -p "$SLOT/apps/brand/.astro"
  echo 'declare module "astro:content" {}' >"$SLOT/apps/brand/.astro/types.d.ts"
  merged_with apps/brand/.astro/types.d.ts
  echo '.astro/' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/apps/brand/.astro/collections"
  echo 'export default new Map();' >"$SLOT/apps/brand/.astro/content-modules.mjs"
  echo '{}' >"$SLOT/apps/brand/.astro/collections/pages.schema.json"
  listed '!! apps/brand/.astro/content-modules.mjs'
  check
  jaq -e '.blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "ignored copies of tracked files do not block, one by one or as a directory git lists whole" {
  mkdir -p "$SLOT/packages/brand/fonts"
  echo '<svg/>' >"$SLOT/packages/brand/favicon.svg"
  echo sans >"$SLOT/packages/brand/fonts/sans.woff2"
  echo serif >"$SLOT/packages/brand/fonts/serif.woff2"
  merged_with packages/brand
  printf '/apps/web/public/favicon.svg\n/apps/web/public/fonts/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/apps/web/public"
  cp "$SLOT/packages/brand/favicon.svg" "$SLOT/apps/web/public/favicon.svg"
  cp -r "$SLOT/packages/brand/fonts" "$SLOT/apps/web/public/fonts"
  listed '!! apps/web/public/fonts/'
  check
  jaq -e '.blockers == [] and .teardown == true' <<<"$VERDICT"
}

@test "ignored files that are not copies of tracked files block, as does a directory holding one or a symlink" {
  mkdir -p "$SLOT/packages/brand/fonts"
  echo sans >"$SLOT/packages/brand/fonts/sans.woff2"
  merged_with packages/brand
  printf 'scratch/\n/apps/web/public/fonts/\n/apps/web/public/logo.woff2\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/scratch" "$SLOT/apps/web/public"
  echo 'work in progress' >"$SLOT/scratch/notes.md"
  cp -r "$SLOT/packages/brand/fonts" "$SLOT/apps/web/public/fonts"
  echo edited >"$SLOT/apps/web/public/fonts/new.woff2"
  ln -s ../../../packages/brand/fonts/sans.woff2 "$SLOT/apps/web/public/logo.woff2"
  check
  jaq -e '.blockers == [{code: "untracked-files", count: 3,
    message: "3 untracked files: apps/web/public/fonts apps/web/public/logo.woff2 scratch",
    values: ["apps/web/public/fonts", "apps/web/public/logo.woff2", "scratch"]}]' <<<"$VERDICT"
}

@test "an ignored .env that copies a tracked file blocks as local-only, and a directory holding one blocks" {
  echo 'API_URL=http://localhost' >"$SLOT/.env.example"
  merged_with .env.example
  printf '.env\nconfig/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/config"
  cp "$SLOT/.env.example" "$SLOT/.env"
  cp "$SLOT/.env.example" "$SLOT/config/.env.local"
  check
  jaq -e '.blockers == [{code: "local-only-files", message: "local-only files: .env", count: 1, values: [".env"]},
    {code: "untracked-files", message: "1 untracked file: config", count: 1, values: ["config"]}]' <<<"$VERDICT"
}

@test "untracked files block though they sit in a tool directory or copy a tracked file" {
  echo '<svg/>' >"$SLOT/favicon.svg"
  merged_with favicon.svg
  mkdir -p "$SLOT/apps/web/.astro" "$SLOT/apps/web/public"
  echo notes >"$SLOT/apps/web/.astro/notes.md"
  cp "$SLOT/favicon.svg" "$SLOT/apps/web/public/favicon.svg"
  check
  jaq -e '.blockers[] | select(.code == "untracked-files")
    | .values == ["apps/web/.astro/notes.md", "apps/web/public/favicon.svg"]' <<<"$VERDICT"
}

@test "an untracked file blocks with untracked-files, and a stray file in the slot's .claude/ blocks too" {
  finished_task
  touch "$SLOT/notes.txt"
  printf '.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/.claude"
  touch "$SLOT/.claude/scratch.md"
  check
  jaq -e '.needs_you[] | select(.code == "untracked-files") | .values == [".claude/scratch.md", "notes.txt"]
    or .values == ["notes.txt", ".claude/scratch.md"]' <<<"$VERDICT"
}

@test "Claude Code's scheduled-task files in the slot's .claude/ do not block; a file the task wrote there does" {
  finished_task
  printf '.claude/\n' >"$SLOT/.git/info/exclude"
  mkdir -p "$SLOT/.claude"
  echo '{"sessionId":"s1","pid":1,"acquiredAt":0}' >"$SLOT/.claude/scheduled_tasks.lock"
  echo '{"tasks": []}' >"$SLOT/.claude/scheduled_tasks.json"
  listed '!! .claude/'
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
  : >"$SLOT/.git/info/exclude"
  listed '?? .claude/scheduled_tasks.lock'
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
  mkdir -p "$SLOT/.claude/commands"
  touch "$SLOT/.claude/commands/new.md"
  check
  jaq -e '.needs_you[] | select(.code == "untracked-files") | .values == [".claude/commands/new.md"]' <<<"$VERDICT"
  printf '.claude/\n' >"$SLOT/.git/info/exclude"
  check
  jaq -e '.needs_you[] | select(.code == "untracked-files") | .values == [".claude/commands/new.md"]' <<<"$VERDICT"
}

@test "an uncommitted change and a stash each block" {
  finished_task
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" pull -q origin main
  echo change >"$SLOT/tracked.txt"
  git -C "$SLOT" add tracked.txt
  check
  has_blocker uncommitted-changes
  git -C "$SLOT" stash -q
  check
  has_blocker stash-present
  lacks_blocker uncommitted-changes
}

@test "a tracked docs/solutions link that setup points at the solutions repo does not block; any other change to it does" {
  work feat/x
  mkdir -p "$SLOT/docs"
  ln -s ../../dev/solutions-docs "$SLOT/docs/solutions"
  git -C "$SLOT" add docs/solutions
  git -C "$SLOT" commit -q -m 'track the solutions link'
  git -C "$SLOT" push -q origin feat/x
  pr 7 MERGED feat/x
  squash_merge feat/x
  ln -sfn "$AGENT_SLOT_SOLUTIONS" "$SLOT/docs/solutions"
  check
  jaq -e '.teardown == true' <<<"$VERDICT"
  git -C "$SLOT" add docs/solutions
  check
  jaq -e '.blockers == [{code: "uncommitted-changes", message: "1 uncommitted change", count: 1}]' <<<"$VERDICT"
  git -C "$SLOT" reset -q docs/solutions
  ln -sfn "$T/elsewhere" "$SLOT/docs/solutions"
  check
  jaq -e '.blockers == [{code: "uncommitted-changes", message: "1 uncommitted change", count: 1}]' <<<"$VERDICT"
}

@test "a symlink in the home directory into the slot blocks with home-symlink-into-slot" {
  finished_task
  mkdir -p "$T/home/.local/bin"
  ln -s "$SLOT/tool" "$T/home/.local/bin/tool"
  check
  jaq -e --arg l "$T/home/.local/bin/tool" '.needs_you[] | select(.code == "home-symlink-into-slot")
    | .values == [$l]' <<<"$VERDICT"
}

@test "a home scan that times out, or finds nothing to judge, blocks with home-scan-incomplete" {
  finished_task
  local i
  for i in $(seq 1 3000); do ln -s "$T/elsewhere" "$T/home/l$i"; done
  AGENT_SLOT_HOME_SCAN_TIMEOUT=0.05 check
  has_blocker home-scan-incomplete
  AGENT_SLOT_HOME_SCAN_ROOTS="$T/elsewhere:1" check
  has_blocker home-scan-incomplete
}

@test "a linked worktree inside the slot holding an unpushed commit blocks teardown" {
  finished_task
  git -C "$SLOT" worktree add -q --detach "$SLOT/wt" main
  git -C "$SLOT/wt" commit -q --allow-empty -m 'in the worktree'
  printf 'wt/\n' >>"$SLOT/.git/info/exclude"
  check
  jaq -e '.needs_you[] | select(.code == "unpushed-commits") | .count == 1' <<<"$VERDICT"
}

@test "check records the task's PRs and its needs-you list, which list then shows" {
  finished_task
  git -C "$SLOT" commit -q --allow-empty -m 'after the merge'
  check
  jaq -e '.prs == [7] and .last_check.finished == true and .last_check.blockers[0].code == "unpushed-commits"' \
    "$SLOT/.git/agent-slot.json"
  echo repoa-1 >"$STUBS/tmux-sessions"
  run --separate-stderr "$AGENT_SLOT" list --output json
  jaq -e '.slots[0].needs_you[0].message == "1 unpushed commit"' <<<"$output"
}

@test "a PR opened before the slot existed does not count as the task's" {
  work feat/x
  git -C "$SLOT" push -q origin feat/x
  pr 3 MERGED feat/x
  jaq '(.[0].createdAt) = "2025-01-01T00:00:00Z"' "$STUBS/gh-prs.json" >"$T/p" && mv "$T/p" "$STUBS/gh-prs.json"
  check
  jaq -e '.prs == [] and .finished == false' <<<"$VERDICT"
}

@test "a merged PR whose branch the slot deleted after switching to the base, before any check, finishes the task" {
  finished_task
  git -C "$SLOT" checkout -q main
  git -C "$SLOT" pull -q --ff-only origin main
  git -C "$SLOT" branch -q -D feat/x
  check
  jaq -e '.finished == true and .finished_by == "merge" and ([.prs[].number] == [7]) and .teardown == true' \
    <<<"$VERDICT"
}

@test "a slot that is still setting up is reported busy and never finished" {
  jaq '.state = "setting-up"' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
  check
  jaq -e '.finished == false and .blockers[0].code == "slot-busy"' <<<"$VERDICT"
}

@test "check of a slot that does not exist exits 1 with slot-not-found" {
  run --separate-stderr "$AGENT_SLOT" check repoa/9 --output json
  [ "$status" -eq 1 ]
  jaq -e '.reason == "slot-not-found"' <<<"$stderr"
}
