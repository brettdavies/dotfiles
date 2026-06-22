#!/usr/bin/env bats
# Tests for the .githooks/pre-push md-only skip path.
#
# Strategy: source the hook in a way that exercises is_md_only_push without
# triggering the rest of the hook's side effects (shellcheck/bats/git-lfs).
# The hook reads stdin into PUSH_REFS before calling the helper, so we set
# that variable directly in each test.
#
# Run: bats tests/pre-push-skip-md-only.bats

HOOK="$BATS_TEST_DIRNAME/../.githooks/pre-push"
ZERO_SHA=0000000000000000000000000000000000000000

setup() {
    REPO_DIR=$(mktemp -d -t pp-test-XXXXXX)
    # Guard the cd and target git -C "$REPO_DIR" so a failed cd can never let
    # these ops mutate the REAL repo (a fixture identity/commit leaking into the
    # working repo is exactly what this guards against). The cd is still needed
    # because the extracted helper reads the CURRENT repo.
    cd "$REPO_DIR" || { echo "FATAL: cd into temp repo failed: $REPO_DIR" >&2; return 1; }
    git -C "$REPO_DIR" init -q -b main
    git -C "$REPO_DIR" config user.email local-bats-testing@example.com
    git -C "$REPO_DIR" config user.name "Local Bats Testing"

    git -C "$REPO_DIR" commit -q --allow-empty -m "root"
    BASE_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)

    git -C "$REPO_DIR" remote add origin "$REPO_DIR/.git"
    git -C "$REPO_DIR" update-ref refs/remotes/origin/main "$BASE_SHA"
    git -C "$REPO_DIR" update-ref refs/remotes/origin/dev "$BASE_SHA"

    extract_helper
}

teardown() {
    rm -rf "$REPO_DIR"
}

# Extract just the is_md_only_push function + its ZERO_SHA constant from the
# hook. Avoids running the hook's top-level side effects.
extract_helper() {
    awk '
        /^ZERO_SHA=/ { print; next }
        /^is_md_only_push\(\) \{/ { in_fn=1 }
        in_fn { print }
        in_fn && /^\}$/ { in_fn=0 }
    ' "$HOOK" >"$REPO_DIR/helper.sh"
    # shellcheck disable=SC1091
    source "$REPO_DIR/helper.sh"
}

commit_files() {
    for f in "$@"; do
        mkdir -p "$REPO_DIR/$(dirname "$f")"
        printf 'x\n' >"$REPO_DIR/$f"
        git -C "$REPO_DIR" add "$f"
    done
    git -C "$REPO_DIR" commit -q -m "test commit"
    git -C "$REPO_DIR" rev-parse HEAD
}

@test "empty PUSH_REFS → run checks (return 1)" {
    PUSH_REFS=""
    run is_md_only_push
    [ "$status" -eq 1 ]
}

@test "single .md file diff → skip checks (return 0)" {
    head_sha=$(commit_files docs/x.md)
    PUSH_REFS="refs/heads/main $head_sha refs/heads/main $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 0 ]
}

@test "multiple .md files diff → skip checks" {
    head_sha=$(commit_files docs/a.md docs/b.md README.md)
    PUSH_REFS="refs/heads/main $head_sha refs/heads/main $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 0 ]
}

@test "one .sh file → run checks" {
    head_sha=$(commit_files scripts/x.sh)
    PUSH_REFS="refs/heads/main $head_sha refs/heads/main $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 1 ]
}

@test "mixed .md and .sh → run checks" {
    head_sha=$(commit_files docs/x.md scripts/x.sh)
    PUSH_REFS="refs/heads/main $head_sha refs/heads/main $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 1 ]
}

@test "deleting a branch (local_sha=zero) → run checks (no diff to evaluate)" {
    PUSH_REFS="(delete) $ZERO_SHA refs/heads/old $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 1 ]
}

@test "new branch (remote_sha=zero) with .md only via merge-base resolution → skip" {
    head_sha=$(commit_files docs/x.md)
    git update-ref refs/remotes/origin/dev "$BASE_SHA"
    PUSH_REFS="refs/heads/feat $head_sha refs/heads/feat $ZERO_SHA"
    run is_md_only_push
    [ "$status" -eq 0 ]
}

@test "new branch with no resolvable merge base → run checks defensively" {
    head_sha=$(commit_files docs/x.md)
    git update-ref -d refs/remotes/origin/main
    git update-ref -d refs/remotes/origin/dev
    PUSH_REFS="refs/heads/feat $head_sha refs/heads/feat $ZERO_SHA"
    run is_md_only_push
    [ "$status" -eq 1 ]
}

@test "no files changed in push (empty diff) → run checks" {
    head_sha=$BASE_SHA
    PUSH_REFS="refs/heads/main $head_sha refs/heads/main $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 1 ]
}

@test ".md file at repo root → skip" {
    head_sha=$(commit_files CHANGELOG.md)
    PUSH_REFS="refs/heads/main $head_sha refs/heads/main $BASE_SHA"
    run is_md_only_push
    [ "$status" -eq 0 ]
}
