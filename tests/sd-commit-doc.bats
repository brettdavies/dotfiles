#!/usr/bin/env bats
# Tests for sd-commit-doc: isolated-worktree commit + push + shared-clone fast-forward.
# Uses a local bare repo as origin so nothing touches the network.
# run-tests: parallel

setup() {
  # An inherited GIT_DIR outranks `-C`, so every `git -C "$SD"` below would
  # retarget whichever repo the caller was in. Git exports these to hooks, so
  # a hook-invoked run reaches this file with them set.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR

  SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/sd-commit-doc"
  TMP=$(mktemp -d)
  ORIGIN="$TMP/origin.git"
  SD="$TMP/sd"

  git init -q --bare "$ORIGIN"
  git clone -q "$ORIGIN" "$SD"
  git -C "$SD" symbolic-ref HEAD refs/heads/main # land the first commit on main, whatever init.defaultBranch is
  git -C "$SD" config user.email test@example.com
  git -C "$SD" config user.name Test
  git -C "$SD" config commit.gpgsign false

  # Seed origin/main with an initial commit.
  mkdir -p "$SD/workflow-issues"
  echo seed >"$SD/seed.md"
  git -C "$SD" add seed.md
  git -C "$SD" commit -q -m seed
  git -C "$SD" push -q -u origin main

  MSG="$TMP/msg.md"
  printf 'docs(x): add a thing\n' >"$MSG"
  export SD_DIR="$SD"
  unset SD_TREE

  # Outside any checkout, so no scenario resolves the host checkout's own
  # docs/solutions link and reaches the real corpus.
  cd "$TMP" || return 1
}

teardown() {
  rm -rf "$TMP"
}

REASONS=" usage path-invalid tree-unresolved validation-failed commit-hook-failed path-in-shared-clone rebase-in-progress overlap-with-origin rebase-conflict push-rejected push-hook-failed push-failed git-failed "

# A failure ends with the marker and three fixed lines, the reason drawn from
# the closed set, so an agent reads the outcome from one place.
assert_failed_with() {
  [ "$status" -ne 0 ]
  local n=${#lines[@]}
  [[ "${lines[n - 4]}" == "sd-commit-doc: FAILED during "* ]]
  [ "${lines[n - 3]}" = "sd-commit-doc: reason: $1" ]
  [[ "$REASONS" == *" $1 "* ]]
  [[ "${lines[n - 2]}" == "sd-commit-doc: state: "* ]]
  [[ "${lines[n - 1]}" == "sd-commit-doc: next: "?* ]]
}

next_command() {
  local n=${#lines[@]}
  printf '%s\n' "${lines[n - 1]#sd-commit-doc: next: }"
}

seed_docs() {
  printf 'a\n' >"$SD/workflow-issues/a.md"
  printf 'b\n' >"$SD/workflow-issues/b.md"
  printf 'c\n' >"$SD/workflow-issues/c.md"
  git -C "$SD" add workflow-issues
  git -C "$SD" commit -q -m docs
  git -C "$SD" push -q origin main
}

# A linked worktree of the fixture corpus, the tree a slot drafts in.
make_wt() {
  git -C "$SD" worktree add -q --detach "$TMP/wt" origin/main
  WT=$(cd "$TMP/wt" && pwd -P)
  mkdir -p "$WT/workflow-issues"
}

# Hooks live in the fixture's own hooks path, so a global core.hooksPath on
# the host cannot hide them; worktrees share it through the common config.
install_hook() {
  mkdir -p "$TMP/hooks"
  git -C "$SD" config core.hooksPath "$TMP/hooks"
  cat >"$TMP/hooks/$1"
  chmod +x "$TMP/hooks/$1"
}

# Another writer moves origin while the worktree's HEAD stays put.
origin_writes() {
  if [[ ! -d $TMP/other ]]; then
    git clone -q -b main "$ORIGIN" "$TMP/other"
    git -C "$TMP/other" config user.email other@example.com
    git -C "$TMP/other" config user.name Other
    git -C "$TMP/other" config commit.gpgsign false
  fi
  mkdir -p "$TMP/other/$(dirname "$1")"
  printf '%s\n' "$2" >"$TMP/other/$1"
  git -C "$TMP/other" add -- "$1"
  git -C "$TMP/other" commit -q -m "other: $1"
  git -C "$TMP/other" push -q origin main
}

no_stash() {
  [ -z "$(git -C "$SD" rev-parse -q --verify refs/stash)" ]
}

@test "errors without enough arguments" {
  run "$SCRIPT" "$MSG"
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage:"* ]]
}

@test "errors when the message file is missing" {
  run "$SCRIPT" "$TMP/nope.md" workflow-issues/a.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"message file not found"* ]]
}

@test "errors when a doc file is missing under the solutions repo" {
  run "$SCRIPT" "$MSG" workflow-issues/missing.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"file not found under"* ]]
}

@test "rejects an absolute path" {
  run "$SCRIPT" "$MSG" /etc/hosts
  [ "$status" -ne 0 ]
  [[ "$output" == *"repo-relative"* ]]
}

@test "commits and pushes a new file, then fast-forwards the clone" {
  echo hello >"$SD/workflow-issues/new.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]

  git -C "$SD" cat-file -e "origin/main:workflow-issues/new.md"
  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ "$(git -C "$SD" log -1 --format=%s origin/main)" = "docs(x): add a thing" ]

  run git -C "$SD" show --format= --name-only origin/main
  [ "$output" = "workflow-issues/new.md" ]
}

# The commit runs under `git -C <worktree>`, so a message path is only usable
# there once it no longer depends on the caller's directory.
@test "accepts a message file given relative to the caller's directory" {
  mkdir -p "$TMP/notes"
  cp "$MSG" "$TMP/notes/msg.md"
  echo hello >"$SD/workflow-issues/new.md"
  cd "$TMP"
  run "$SCRIPT" notes/msg.md workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" log -1 --format=%s origin/main)" = "docs(x): add a thing" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "commits multiple files in one commit" {
  echo a >"$SD/workflow-issues/a.md"
  echo b >"$SD/workflow-issues/b.md"
  run "$SCRIPT" "$MSG" workflow-issues/a.md workflow-issues/b.md
  [ "$status" -eq 0 ]

  git -C "$SD" cat-file -e "origin/main:workflow-issues/a.md"
  git -C "$SD" cat-file -e "origin/main:workflow-issues/b.md"
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "commits a modification to an existing tracked file and reconciles the checkout" {
  echo changed >"$SD/seed.md"
  run "$SCRIPT" "$MSG" seed.md
  [ "$status" -eq 0 ]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ "$(git -C "$SD" show origin/main:seed.md)" = changed ]
}

# One pathspec git does not know makes `git checkout -- <paths>` refuse every
# path, so a single revert over a new file and a tracked one leaves the tracked
# copy modified and the fast-forward blocked behind it.
@test "reconciles the checkout when one call commits a new file and a modified one" {
  echo hello >"$SD/workflow-issues/new.md"
  echo changed >"$SD/seed.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md seed.md
  [ "$status" -eq 0 ]
  [[ "$output" != *"not fast-forwarded"* ]]

  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
  [ "$(git -C "$SD" show origin/main:seed.md)" = changed ]
  git -C "$SD" cat-file -e "origin/main:workflow-issues/new.md"
}

@test "fails loudly when the shared clone's copies cannot be reverted" {
  echo changed >"$SD/seed.md"
  # A held index lock is what a concurrent writer in the shared clone looks
  # like; the push lands, but the revert and the fast-forward cannot.
  local stub="$TMP/bin"
  mkdir -p "$stub"
  cat >"$stub/git" <<STUB
#!/usr/bin/env bash
[[ " \$* " == *" fetch "* && -e "$TMP/pushed" ]] && touch "$SD/.git/index.lock"
[[ " \$* " == *" push "* ]] && touch "$TMP/pushed"
exec "$(command -v git)" "\$@"
STUB
  chmod +x "$stub/git"

  PATH="$stub:$PATH" run "$SCRIPT" "$MSG" seed.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"index.lock"* ]]
  [[ "$output" == *"FAILED during reverting the shared clone's copies (the push already landed)"* ]]
  [ "$(git -C "$SD" show origin/main:seed.md)" = changed ]
}

@test "leaves an unrelated uncommitted file in the clone untouched" {
  echo hello >"$SD/workflow-issues/new.md"
  echo scratch >"$SD/other-agent-wip.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ -f "$SD/other-agent-wip.md" ]
  [ "$(cat "$SD/other-agent-wip.md")" = scratch ]
}

# The corpus schema check lives in the solutions repo's own hook library, so the
# same rejection the pre-commit hook would raise is available before any work
# happens. Running it up front turns a mid-commit hook abort — after a fetch, a
# worktree, and a staged copy — into a named failure that costs a second. The
# stub stands in for the real validator so the suite stays hermetic.
@test "rejects a doc the repo's own validator fails, before committing" {
  mkdir -p "$SD/.githooks"
  cat >"$SD/.githooks/lib-validate.sh" <<'LIB'
validate_files() {
  printf 'FAIL: %s: missing required field: module\n' "$1"
  return 1
}
LIB
  echo hello >"$SD/workflow-issues/new.md"
  local before
  before=$(git -C "$SD" rev-parse origin/main)

  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing required field: module"* ]]

  # Nothing reached origin, and the clone is untouched apart from the doc itself.
  [ "$(git -C "$SD" rev-parse origin/main)" = "$before" ]
  run git -C "$SD" worktree list
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

# A failure anywhere in the sequence has to name itself. Hook output can fill the
# tail of a transcript, and a caller that reads the status through a pipe sees
# only the last command's. A marker line on stderr is the signal that survives
# both.
@test "announces its own failure with a marker line" {
  mkdir -p "$SD/.githooks"
  cat >"$SD/.githooks/lib-validate.sh" <<'LIB'
validate_files() { return 1; }
LIB
  echo hello >"$SD/workflow-issues/new.md"

  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -ne 0 ]
  [[ "$output" == *"sd-commit-doc: FAILED"* ]]
}

@test "worktree: publishes a new doc in place and fast-forwards the shared clone" {
  make_wt
  echo hello >"$WT/workflow-issues/new.md"
  [ ! -e "$SD/workflow-issues/new.md" ]

  cd "$WT"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"sd-commit-doc: committed and pushed 1 file(s) from $WT (worktree)"* ]]

  [ "$(git -C "$SD" show origin/main:workflow-issues/new.md)" = hello ]
  [ "$(git -C "$SD" log -1 --format=%s origin/main)" = "docs(x): add a thing" ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "worktree: an edit, a deletion, and a rename land on origin as M, D, and R" {
  seed_docs
  make_wt
  echo a2 >"$WT/workflow-issues/a.md"
  rm "$WT/workflow-issues/b.md"
  git -C "$WT" mv workflow-issues/c.md workflow-issues/d.md

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/a.md workflow-issues/b.md workflow-issues/c.md workflow-issues/d.md
  [ "$status" -eq 0 ]

  run git -C "$SD" show --name-status -M --format= origin/main
  [[ "$output" == *$'M\tworkflow-issues/a.md'* ]]
  [[ "$output" == *$'D\tworkflow-issues/b.md'* ]]
  [[ "$output" == *$'R100\tworkflow-issues/c.md\tworkflow-issues/d.md'* ]]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "worktree: a path another publish staged stays staged and out of the commit" {
  make_wt
  echo theirs >"$WT/workflow-issues/staged-by-other.md"
  git -C "$WT" add workflow-issues/staged-by-other.md
  echo mine >"$WT/workflow-issues/new.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]

  run git -C "$SD" show --format= --name-only origin/main
  [ "$output" = "workflow-issues/new.md" ]
  [ "$(git -C "$WT" diff --cached --name-only)" = "workflow-issues/staged-by-other.md" ]
}

@test "worktree: a commit hook rejection leaves nothing committed or staged" {
  make_wt
  printf '#!/bin/sh\necho "PROSE GATE FAILED: recast the flagged line"\nexit 1\n' | install_hook pre-commit
  echo sloppy >"$WT/workflow-issues/new.md"
  local head
  head=$(git -C "$WT" rev-parse HEAD)

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with commit-hook-failed
  [[ "$output" == *"PROSE GATE FAILED: recast the flagged line"* ]]
  [[ "$output" == *"sd-commit-doc: state: nothing staged"* ]]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$head" ]
  [ -z "$(git -C "$WT" diff --cached --name-only)" ]
  [ "$(git -C "$SD" rev-parse origin/main)" = "$head" ]
}

@test "worktree: the pre-flight names an invalid modified tracked doc beside a valid named one" {
  seed_docs
  make_wt
  mkdir -p "$WT/.githooks"
  cat >"$WT/.githooks/lib-validate.sh" <<'LIB'
_flag() {
  local f rc=0
  while IFS= read -r f; do
    [ -f "$f" ] && grep -q INVALID "$f" && { echo "FAIL: $f: missing required field: module"; rc=1; }
  done
  return $rc
}
validate_files() { printf '%s\n' "$1" | _flag; }
validate_changed_since() { git diff --name-only "$1" | _flag; }
LIB
  echo INVALID >"$WT/workflow-issues/a.md"
  echo fine >"$WT/workflow-issues/new.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with validation-failed
  [[ "$output" == *"FAIL: workflow-issues/a.md: missing required field: module"* ]]
  [[ "$output" != *"FAIL: workflow-issues/new.md"* ]]
  [ -z "$(git -C "$WT" diff --cached --name-only)" ]
  [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$SD" rev-parse origin/main)" ]
}

@test "worktree: rebases onto another writer's doc and keeps an unrelated tracked edit" {
  seed_docs
  make_wt
  origin_writes workflow-issues/theirs.md theirs
  echo unrelated-edit >"$WT/workflow-issues/b.md"
  echo mine >"$WT/workflow-issues/new.md"
  no_stash

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]

  git -C "$SD" cat-file -e origin/main:workflow-issues/theirs.md
  [ "$(git -C "$SD" show origin/main:workflow-issues/new.md)" = mine ]
  [ "$(cat "$WT/workflow-issues/b.md")" = unrelated-edit ]
  [ "$(git -C "$SD" show origin/main:workflow-issues/b.md)" = b ]
  no_stash
}

@test "worktree: refuses to rebase over an unnamed edit to a doc origin changed" {
  seed_docs
  make_wt
  origin_writes workflow-issues/b.md origin-b
  echo local-b >"$WT/workflow-issues/b.md"
  echo mine >"$WT/workflow-issues/new.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with overlap-with-origin
  [[ "$output" == *"workflow-issues/b.md"* ]]
  [[ "$output" == *"sd-commit-doc: state: committed in $WT, not pushed"* ]]
  [ "$(git -C "$WT" log -1 --format=%s)" = "docs(x): add a thing" ]
  [ "$(cat "$WT/workflow-issues/b.md")" = local-b ]
  ! git -C "$SD" cat-file -e origin/main:workflow-issues/new.md || false
  [ ! -e "$(git -C "$WT" rev-parse --path-format=absolute --git-path rebase-merge)" ]
}

@test "worktree: refuses to rebase over an untracked draft at a path origin added" {
  make_wt
  origin_writes workflow-issues/draft.md origin-draft
  echo local-draft >"$WT/workflow-issues/draft.md"
  echo mine >"$WT/workflow-issues/new.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with overlap-with-origin
  [[ "$output" == *"workflow-issues/draft.md"* ]]
  [ "$(cat "$WT/workflow-issues/draft.md")" = local-draft ]
}

@test "worktree: a rebase conflict aborts, prints the resume steps, and the rerun publishes" {
  seed_docs
  make_wt
  origin_writes workflow-issues/a.md origin-a
  echo mine-a >"$WT/workflow-issues/a.md"
  echo unrelated-edit >"$WT/workflow-issues/b.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/a.md
  assert_failed_with rebase-conflict
  [[ "$output" == *"git -C $WT rebase --autostash origin/main"* ]]
  [[ "$output" == *"git -C $WT diff --name-only --diff-filter=U"* ]]
  [[ "$output" == *"git -C $WT add -A -- <each conflicted doc>"* ]]
  [[ "$output" == *"git -C $WT rebase --continue"* ]]
  [ ! -e "$(git -C "$WT" rev-parse --path-format=absolute --git-path rebase-merge)" ]
  [ "$(git -C "$WT" log -1 --format=%s)" = "docs(x): add a thing" ]
  [ "$(cat "$WT/workflow-issues/b.md")" = unrelated-edit ]

  local next
  next=$(next_command)
  [ "$next" = "git -C $WT rebase --autostash origin/main" ]
  ! eval "$next" || false
  echo resolved-a >"$WT/workflow-issues/a.md"
  git -C "$WT" add workflow-issues/a.md
  GIT_EDITOR=true git -C "$WT" rebase --continue

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/a.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" show origin/main:workflow-issues/a.md)" = resolved-a ]
  [ "$(cat "$WT/workflow-issues/b.md")" = unrelated-edit ]
  no_stash
}

@test "worktree: a rerun during a rebase refuses and names continue and abort" {
  seed_docs
  make_wt
  echo mine-a >"$WT/workflow-issues/a.md"
  git -C "$WT" commit -q -am local
  origin_writes workflow-issues/a.md origin-a
  git -C "$WT" fetch -q origin main
  ! git -C "$WT" rebase -q origin/main || false

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/a.md
  assert_failed_with rebase-in-progress
  [[ "$output" == *"git -C $WT rebase --continue"* ]]
  [[ "$output" == *"git -C $WT rebase --abort"* ]]
}

@test "worktree: with origin unreachable it keeps the commit, and the rerun pushes it once" {
  make_wt
  local before
  before=$(git -C "$SD" rev-parse origin/main)
  echo mine >"$WT/workflow-issues/new.md"

  mv "$ORIGIN" "$TMP/origin.away"
  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  mv "$TMP/origin.away" "$ORIGIN"
  assert_failed_with push-failed
  [[ "$output" == *"sd-commit-doc: state: committed in $WT, not pushed"* ]]
  [ "$(git -C "$WT" log -1 --format=%s)" = "docs(x): add a thing" ]

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" rev-list --count "$before..origin/main")" -eq 1 ]
  [ "$(git -C "$SD" show origin/main:workflow-issues/new.md)" = mine ]
}

@test "worktree: a deletion whose push failed publishes on the rerun without bringing the doc back" {
  seed_docs
  make_wt
  local before
  before=$(git -C "$SD" rev-parse origin/main)
  git -C "$WT" rm -q workflow-issues/b.md

  mv "$ORIGIN" "$TMP/origin.away"
  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/b.md
  mv "$TMP/origin.away" "$ORIGIN"
  assert_failed_with push-failed

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/b.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" rev-list --count "$before..origin/main")" -eq 1 ]
  ! git -C "$SD" cat-file -e origin/main:workflow-issues/b.md || false
  [ ! -e "$WT/workflow-issues/b.md" ]
}

@test "worktree: a push that loses a race to another writer is rebased and retried once" {
  make_wt
  echo mine >"$WT/workflow-issues/new.md"
  install_hook pre-push <<HOOK
#!/usr/bin/env bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
[ -e "$TMP/raced" ] && exit 0
touch "$TMP/raced"
git clone -q -b main "$ORIGIN" "$TMP/racer"
git -C "$TMP/racer" -c user.email=r@example.com -c user.name=R -c commit.gpgsign=false commit -q --allow-empty -m race
git -C "$TMP/racer" push -q origin main
HOOK

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" show origin/main:workflow-issues/new.md)" = mine ]
  [ "$(git -C "$SD" log -1 --format=%s origin/main~1)" = race ]
}

@test "worktree: a push that loses the race again after its retry stops with push-rejected and keeps the commit" {
  make_wt
  echo mine >"$WT/workflow-issues/new.md"
  install_hook pre-push <<HOOK
#!/usr/bin/env bash
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
[ -d "$TMP/racer" ] || git clone -q -b main "$ORIGIN" "$TMP/racer"
git -C "$TMP/racer" pull -q origin main
git -C "$TMP/racer" -c user.email=r@example.com -c user.name=R -c commit.gpgsign=false commit -q --allow-empty -m race
git -C "$TMP/racer" push -q origin main
HOOK

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with push-rejected
  [[ "$output" == *"sd-commit-doc: state: committed in $WT, not pushed"* ]]
  [ "$(git -C "$WT" log -1 --format=%s)" = "docs(x): add a thing" ]
}

@test "worktree: a pre-push hook rejection names the push step and is not retried" {
  make_wt
  install_hook pre-push <<HOOK
#!/bin/sh
echo run >>"$TMP/pre-push-runs"
echo "PRE-PUSH SAYS NO" >&2
exit 1
HOOK
  echo mine >"$WT/workflow-issues/new.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with push-hook-failed
  [[ "$output" == *"PRE-PUSH SAYS NO"* ]]
  [[ "$output" == *"FAILED during pushing"* ]]
  [ "$(wc -l <"$TMP/pre-push-runs")" -eq 1 ]
}

@test "worktree: with nothing to stage or push it exits 0 saying the paths are on origin/main" {
  make_wt
  SD_TREE=$WT run "$SCRIPT" "$MSG" seed.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"already on origin/main"* ]]
  [ "$(git -C "$SD" rev-list --count origin/main)" -eq 1 ]
}

@test "worktree: an edit made in the shared clone instead of the worktree is refused" {
  make_wt
  echo edited-in-shared-clone >"$SD/seed.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" seed.md
  assert_failed_with path-in-shared-clone
  [[ "$output" == *"$SD/seed.md"* ]]
  [[ "$output" == *"$WT/seed.md"* ]]
  [[ "$output" == *"another session's draft"* ]]
  [ "$(next_command)" = "diff -u $WT/seed.md $SD/seed.md" ]
  [[ "$output" == *"cp $SD/seed.md $WT/seed.md"* ]]
  [ "$(git -C "$SD" show origin/main:seed.md)" = seed ]
  [ "$(cat "$SD/seed.md")" = edited-in-shared-clone ]
  [ -z "$(git -C "$WT" status --porcelain)" ]
}

@test "worktree: a path only the shared clone holds is refused" {
  make_wt
  echo drafted-in-shared-clone >"$SD/workflow-issues/sd-only.md"
  local before
  before=$(git -C "$SD" rev-parse origin/main)

  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/sd-only.md
  assert_failed_with path-in-shared-clone
  [[ "$output" == *"$SD/workflow-issues/sd-only.md"* ]]
  [ "$(git -C "$SD" rev-parse origin/main)" = "$before" ]
  [ -f "$SD/workflow-issues/sd-only.md" ]
}

@test "worktree: a publish leaves the shared clone's own edit at that path in place" {
  make_wt
  echo prime-session-draft >"$SD/seed.md"
  echo published >"$WT/seed.md"

  SD_TREE=$WT run "$SCRIPT" "$MSG" seed.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" show origin/main:seed.md)" = published ]
  [ "$(cat "$SD/seed.md")" = prime-session-draft ]
}

@test "resolution: a link, a directory inside the worktree, and SD_TREE resolve the same tree" {
  make_wt
  mkdir -p "$TMP/slot/docs"
  git init -q "$TMP/slot"
  ln -s "$WT" "$TMP/slot/docs/solutions"
  echo one >"$WT/workflow-issues/one.md"
  echo two >"$WT/workflow-issues/two.md"
  echo three >"$WT/workflow-issues/three.md"

  cd "$TMP/slot"
  run "$SCRIPT" "$MSG" workflow-issues/one.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $WT (worktree)"* ]]

  cd "$TMP/slot/docs/solutions/workflow-issues"
  run "$SCRIPT" "$MSG" workflow-issues/two.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $WT (worktree)"* ]]

  cd "$TMP"
  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues/three.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $WT (worktree)"* ]]

  [ "$(git -C "$SD" show origin/main:workflow-issues/three.md)" = three ]
}

@test "resolution: a link to a worktree of another corpus is refused and untouched" {
  local origin2="$TMP/origin2.git" sd2="$TMP/sd2"
  git init -q --bare "$origin2"
  git clone -q "$origin2" "$sd2" 2>/dev/null
  git -C "$sd2" symbolic-ref HEAD refs/heads/main
  git -C "$sd2" config user.email test@example.com
  git -C "$sd2" config user.name Test
  git -C "$sd2" config commit.gpgsign false
  echo seed >"$sd2/seed.md"
  git -C "$sd2" add seed.md
  git -C "$sd2" commit -q -m seed
  git -C "$sd2" push -q -u origin main
  git -C "$sd2" worktree add -q --detach "$TMP/wt2" origin/main
  local wt2 before2
  wt2=$(cd "$TMP/wt2" && pwd -P)
  before2=$(git -C "$sd2" rev-parse origin/main)
  mkdir -p "$TMP/consumer/docs" "$wt2/workflow-issues"
  git init -q "$TMP/consumer"
  ln -s "$wt2" "$TMP/consumer/docs/solutions"
  echo doc >"$wt2/workflow-issues/x.md"
  echo doc >"$SD/workflow-issues/x.md"

  cd "$TMP/consumer"
  run "$SCRIPT" "$MSG" workflow-issues/x.md
  assert_failed_with tree-unresolved
  [[ "$output" == *"$TMP/consumer"* ]]
  [[ "$output" == *"$wt2"* ]]

  cd "$TMP"
  SD_TREE=$wt2 run "$SCRIPT" "$MSG" workflow-issues/x.md
  assert_failed_with tree-unresolved

  [ "$(git -C "$sd2" rev-parse HEAD)" = "$before2" ]
  [ "$(git -C "$wt2" rev-parse HEAD)" = "$before2" ]
  [ "$(git --git-dir="$origin2" rev-parse main)" = "$before2" ]
  [ -z "$(git -C "$wt2" diff --cached --name-only)" ]
  ! git -C "$SD" cat-file -e origin/main:workflow-issues/x.md || false
}

@test "resolution: a docs/solutions link to a directory outside the corpus is refused" {
  mkdir -p "$TMP/elsewhere/workflow-issues" "$TMP/plain/docs"
  git init -q "$TMP/plain"
  ln -s "$TMP/elsewhere" "$TMP/plain/docs/solutions"
  echo doc >"$TMP/elsewhere/workflow-issues/x.md"
  echo doc >"$SD/workflow-issues/x.md"
  local before
  before=$(git -C "$SD" rev-parse origin/main)

  cd "$TMP/plain"
  run "$SCRIPT" "$MSG" workflow-issues/x.md
  assert_failed_with tree-unresolved
  [[ "$output" == *"$TMP/plain"* ]]
  [ "$(git -C "$SD" rev-parse origin/main)" = "$before" ]
}

# A repo that keeps its own docs/solutions directory publishes nothing from it;
# a doc written into the shared clone still publishes from there.
@test "copy-out: a checkout whose docs/solutions is a real directory publishes from the shared clone" {
  mkdir -p "$TMP/plain/docs/solutions/workflow-issues"
  git init -q "$TMP/plain"
  echo local >"$TMP/plain/docs/solutions/workflow-issues/x.md"
  echo shared >"$SD/workflow-issues/x.md"

  cd "$TMP/plain"
  run "$SCRIPT" "$MSG" workflow-issues/x.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $SD (copy-out)"* ]]
  [ "$(git -C "$SD" show origin/main:workflow-issues/x.md)" = shared ]
}

@test "copy-out: a docs/solutions link that does not resolve publishes from the shared clone" {
  mkdir -p "$TMP/a/b/checkout/docs"
  git init -q "$TMP/a/b/checkout"
  ln -s ../../nowhere/solutions-docs "$TMP/a/b/checkout/docs/solutions"
  echo shared >"$SD/workflow-issues/x.md"

  cd "$TMP/a/b/checkout"
  run "$SCRIPT" "$MSG" workflow-issues/x.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"from $SD (copy-out)"* ]]
  [ "$(git -C "$SD" show origin/main:workflow-issues/x.md)" = shared ]
}

@test "worktree: a directory or an absolute path is refused" {
  make_wt
  SD_TREE=$WT run "$SCRIPT" "$MSG" workflow-issues
  assert_failed_with path-invalid

  SD_TREE=$WT run "$SCRIPT" "$MSG" "$WT/seed.md"
  assert_failed_with path-invalid
}

@test "copy-out: a prime checkout linked to the shared clone publishes through the link" {
  mkdir -p "$TMP/prime/docs"
  git init -q "$TMP/prime"
  ln -s "$SD" "$TMP/prime/docs/solutions"
  echo prime >"$TMP/prime/docs/solutions/workflow-issues/prime.md"

  cd "$TMP/prime"
  run "$SCRIPT" "$MSG" workflow-issues/prime.md
  [ "$status" -eq 0 ]
  [[ "$output" == *"sd-commit-doc: committed and pushed 1 file(s) from $SD (copy-out)"* ]]
  [ "$(git -C "$SD" show origin/main:workflow-issues/prime.md)" = prime ]
  [ "$(git -C "$SD" rev-parse main)" = "$(git -C "$SD" rev-parse origin/main)" ]
  [ -z "$(git -C "$SD" status --porcelain)" ]
}

@test "copy-out: a doc that exists only in a worktree, called from no checkout, names SD_TREE" {
  make_wt
  echo mine >"$WT/workflow-issues/new.md"
  run "$SCRIPT" "$MSG" workflow-issues/new.md
  assert_failed_with path-invalid
  [[ "$output" == *"file not found under"* ]]
  [[ "$output" == *"SD_TREE"* ]]
}

@test "copy-out: argument and path failures carry the reason, state, and next lines" {
  run "$SCRIPT" "$MSG"
  assert_failed_with usage
  run "$SCRIPT" "$MSG" workflow-issues/missing.md
  assert_failed_with path-invalid
}

@test "--help prints the usage, resolution order, variables, and reason codes" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: sd-commit-doc"* ]]
  [[ "$output" == *"SD_TREE"* ]]
  [[ "$output" == *"SD_DIR"* ]]
  [[ "$output" == *"copy-out"* ]]
  [[ "$output" == *"rebase --continue"* ]]
  local r
  for r in $REASONS; do
    [[ "$output" == *"$r"* ]]
  done
}

@test "worktree: commits in the worktree despite GIT_DIR and GIT_INDEX_FILE from the caller" {
  make_wt
  git init -q "$TMP/decoy"
  echo mine >"$WT/workflow-issues/new.md"

  run env GIT_DIR="$TMP/decoy/.git" GIT_INDEX_FILE="$TMP/decoy/.git/index" SD_TREE="$WT" "$SCRIPT" "$MSG" workflow-issues/new.md
  [ "$status" -eq 0 ]
  [ "$(git -C "$SD" show origin/main:workflow-issues/new.md)" = mine ]
  ! git -C "$TMP/decoy" rev-parse -q --verify HEAD || false
}
