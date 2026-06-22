#!/usr/bin/env bats
# Verifies scripts/sync-dev-after-release.sh's pure logic: CalVer version
# validation and the early dirty-tree guard. The git fetch / switch / push / PR
# path runs against real remotes and is exercised by the release runbook, not
# here -- the tests stop the script at validation (exit 64) or at the
# clean-tree guard (exit 65), before any network or branch mutation.
#
# Run: bats tests/sync-dev-after-release.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
SCRIPT="$REPO_ROOT/scripts/sync-dev-after-release.sh"

setup() {
    TMP="$(mktemp -d)"
}

teardown() {
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# A git repo with one commit and an untracked file, so `git status` is dirty.
_dirty_repo() {
    # git -C targets the temp repo and the cd is guarded, so a failed cd can
    # never let these ops mutate the REAL repo.
    cd "$TMP" || { echo "FATAL: cd into fixture temp dir failed: $TMP" >&2; return 1; }
    git -C "$TMP" init -q
    git -C "$TMP" config user.email local-bats-testing@example.com
    git -C "$TMP" config user.name "Local Bats Testing"
    git -C "$TMP" commit -q --allow-empty -m init
    echo dirty > "$TMP/untracked"
}

@test "no argument exits 64 with usage" {
    run bash "$SCRIPT"
    [ "$status" -eq 64 ]
    [[ "$output" == *"usage"* ]]
}

@test "rejects SemVer vX.Y.Z" {
    run bash "$SCRIPT" v1.2.3
    [ "$status" -eq 64 ]
    [[ "$output" == *"version must match"* ]]
}

@test "rejects unpadded date" {
    run bash "$SCRIPT" 2026.6.3
    [ "$status" -eq 64 ]
}

@test "rejects a non-date token" {
    run bash "$SCRIPT" latest
    [ "$status" -eq 64 ]
}

@test "accepts CalVer date (passes validation, stops at dirty-tree guard)" {
    _dirty_repo
    run bash "$SCRIPT" 2026.06.03
    [ "$status" -eq 65 ]
    [[ "$output" == *"working tree not clean"* ]]
}

@test "accepts same-day CalVer suffix" {
    _dirty_repo
    run bash "$SCRIPT" 2026.06.03.1
    [ "$status" -eq 65 ]
}

@test "opens the PR via --body-file, never an inline --body" {
    grep -q -- '--body-file' "$SCRIPT"
    run grep -E 'gh pr create.*--body "' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "backport is surgical -- CHANGELOG.md only, never a branch merge" {
    grep -q 'git checkout origin/main -- CHANGELOG.md' "$SCRIPT"
    run grep -E 'git merge[[:space:]]+origin/main' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "shellcheck clean" {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck not installed"
    fi
    run shellcheck "$SCRIPT"
    [ "$status" -eq 0 ]
}
