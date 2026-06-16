#!/usr/bin/env bats
# Verifies scripts/generate-changelog.py's offline seams: --check mode and
# CalVer/SemVer branch detection via --print-tag. The git-cliff generation path
# and PR-body expansion need git-cliff + network and are exercised by the
# release runbook (RELEASES.md), not here.
#
# Invoked via python3, not the uv-run shebang: the bats CI image installs
# python3 (>= 3.11, so tomllib is present) but not uv. Skips if the host
# python3 predates tomllib.
#
# Run: bats tests/generate-changelog.bats

REPO_ROOT="$BATS_TEST_DIRNAME/.."
GEN="$REPO_ROOT/scripts/generate-changelog.py"

setup() {
    # The shebang sets PYTHONDONTWRITEBYTECODE=1; these tests invoke python3
    # directly (CI has no uv), so set it here too to keep __pycache__ out of the
    # tree.
    export PYTHONDONTWRITEBYTECODE=1
    if ! python3 -c 'import tomllib' 2>/dev/null; then
        skip "python3 lacks tomllib (need >= 3.11)"
    fi
    TMP="$(mktemp -d)"
}

teardown() {
    [ -n "${TMP:-}" ] && rm -rf "$TMP"
}

# Seed $TMP with cliff.toml and, when $1 is non-empty, a CHANGELOG.md.
_seed() {
    touch "$TMP/cliff.toml"
    if [ -n "${1:-}" ]; then
        printf '%s\n' "$1" > "$TMP/CHANGELOG.md"
    fi
}

# Turn $TMP into a git repo (empty cliff.toml + one commit) on branch $1.
_fixture_repo_on() {
    cd "$TMP"
    touch cliff.toml
    git init -q
    git config user.email t@t.t
    git config user.name t
    git commit -q --allow-empty -m init
    git checkout -q -b "$1"
}

@test "--check: versioned section exits 0" {
    _seed "## [2026.06.03]"
    run python3 "$GEN" --check "$TMP"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "--check: [Unreleased] exits 1" {
    _seed "## [Unreleased]"
    run python3 "$GEN" --check "$TMP"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL"* ]]
}

@test "--check: missing CHANGELOG exits 1" {
    _seed ""
    run python3 "$GEN" --check "$TMP"
    [ "$status" -eq 1 ]
}

@test "missing cliff.toml errors out" {
    run python3 "$GEN" --check "$TMP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cliff.toml not found"* ]]
}

@test "--print-tag: CalVer branch resolves the bare date tag" {
    _fixture_repo_on "release/2026.06.16"
    run python3 "$GEN" --print-tag
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "2026.06.16" ]
}

@test "--print-tag: same-day CalVer suffix is preserved" {
    _fixture_repo_on "release/2026.06.16.1"
    run python3 "$GEN" --print-tag
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "2026.06.16.1" ]
}

@test "--print-tag: SemVer release branch still works" {
    _fixture_repo_on "release/v1.2.3"
    run python3 "$GEN" --print-tag
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "v1.2.3" ]
}

@test "--print-tag: non-release branch fails with a clear message" {
    _fixture_repo_on "work"
    run python3 "$GEN" --print-tag
    [ "$status" -ne 0 ]
    [[ "$output" == *"could not detect version"* ]]
}

@test "--print-tag: --tag overrides branch detection" {
    _fixture_repo_on "work"
    run python3 "$GEN" --print-tag --tag 2026.06.16
    [ "$status" -eq 0 ]
    [ "${lines[-1]}" = "2026.06.16" ]
}
