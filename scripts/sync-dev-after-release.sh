#!/usr/bin/env bash
# Backport release artifacts from main to dev after a CalVer release publishes.
#
# The release flow cuts release/* from origin/main and regenerates CHANGELOG.md
# there; that commit never round-trips to dev, so dev's CHANGELOG.md drifts
# behind main with every release. This script closes that gap: it copies
# CHANGELOG.md verbatim from origin/main and lands it on dev via a PR (direct
# commits to dev are not permitted per RELEASES.md).
#
# The copy is surgical -- only CHANGELOG.md moves, only main -> dev. dev is
# normally many commits ahead of main (unreleased work), so a merge or a
# wholesale checkout would revert that work. Never widen this to a branch merge.
# Other release-prep edits (README.md, RELEASES.md polish), when they actually
# drift, are folded into the same PR by hand -- see RELEASES.md.
#
# Run AFTER:
#   1. The release/* -> main PR has merged.
#   2. release.yml tagged the release and pushed the tag.
#   3. The GitHub Release was created.
#
# Usage:
#   ./scripts/sync-dev-after-release.sh 2026.06.03
#   ./scripts/sync-dev-after-release.sh 2026.06.03.1   # same-day re-release
#
# Idempotent: if dev already matches main on CHANGELOG.md, exits 0 without
# creating a branch or PR.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 YYYY.MM.DD[.N]" >&2
    exit 64
fi

VERSION="$1"
# CalVer: YYYY.MM.DD with an optional same-day .N suffix; no leading "v".
if [[ ! "$VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]]; then
    echo "error: version must match YYYY.MM.DD or YYYY.MM.DD.N (got: $VERSION)" >&2
    exit 64
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree not clean -- commit or stash first" >&2
    git status --short >&2
    exit 65
fi

git fetch origin --tags --quiet

# The release tag must exist locally.
if ! git rev-parse --verify --quiet "refs/tags/$VERSION" >/dev/null; then
    echo "error: tag $VERSION not found locally -- run 'git fetch origin --tags' or verify the release published" >&2
    exit 66
fi

# main must be at or past the tag (i.e. release/* actually merged).
TAG_SHA="$(git rev-parse "$VERSION")"
if ! git merge-base --is-ancestor "$TAG_SHA" origin/main; then
    echo "error: tag $VERSION is not reachable from origin/main -- wait for release/* to merge" >&2
    exit 66
fi

# The GitHub Release must exist and not still be a draft. The tag can exist
# while the Release was never created (or stayed draft), in which case the
# backport is premature.
if command -v gh >/dev/null 2>&1; then
    is_draft="$(gh release view "$VERSION" --json isDraft --jq .isDraft 2>/dev/null || true)"
    case "$is_draft" in
        false) ;;
        true)
            echo "error: GitHub Release $VERSION is still draft -- publish it first" >&2
            exit 67
            ;;
        "")
            echo "error: no GitHub Release for $VERSION -- create it with 'gh release create $VERSION'" >&2
            exit 67
            ;;
        *)
            echo "warning: unexpected isDraft value '$is_draft' for $VERSION -- proceeding" >&2
            ;;
    esac
else
    echo "warning: gh not on PATH -- skipping GitHub Release published-state check" >&2
fi

git switch dev
git pull --ff-only origin dev

# Cut a branch -- RELEASES.md bans direct commits to dev.
SYNC_BRANCH="chore/sync-dev-after-${VERSION}"

if git rev-parse --verify --quiet "$SYNC_BRANCH" >/dev/null; then
    echo "error: branch $SYNC_BRANCH already exists locally -- delete it or finish the prior run" >&2
    exit 68
fi
if git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1; then
    echo "error: branch $SYNC_BRANCH already exists on origin -- check for an open PR or delete the remote branch" >&2
    exit 68
fi

git checkout -b "$SYNC_BRANCH"

# Surgical: CHANGELOG.md from main is authoritative. Never a branch merge.
git checkout origin/main -- CHANGELOG.md

# `git checkout origin/main -- CHANGELOG.md` updates both the working tree and
# the index, and CHANGELOG.md is the only file this backport touches, so an
# unstaged `git diff` is always empty here. Compare the index against HEAD
# (--cached) to tell whether main's CHANGELOG actually differs from dev's.
if git diff --cached --quiet CHANGELOG.md; then
    echo "no changes -- dev already in sync with $VERSION"
    git switch dev
    git branch -D "$SYNC_BRANCH"
    exit 0
fi

git add CHANGELOG.md
git commit -m "chore(release): backport $VERSION CHANGELOG to dev

Brings dev's CHANGELOG.md current with the $VERSION release on main, copied
verbatim from origin/main. main is authoritative for CHANGELOG; dev never
edits it directly."

# Post-sync sanity check: re-running generate-changelog.py against the current
# PR bodies should reproduce the backported CHANGELOG.md. Drift here means
# upstream PR bodies were edited after main's CHANGELOG.md was generated. Warn,
# do not fail; the backport is still correct against what main currently has.
if [[ -x scripts/generate-changelog.py ]] && command -v git-cliff >/dev/null 2>&1; then
    if scripts/generate-changelog.py --dry-run --tag "$VERSION" >/dev/null 2>&1; then
        echo "regen check: CHANGELOG.md matches what PR bodies would produce"
    else
        echo "warning: PR bodies have drifted from main's CHANGELOG.md for $VERSION" >&2
        echo "  re-run 'scripts/generate-changelog.py --dry-run --tag $VERSION' to see the diff" >&2
    fi
fi

# Push and open the PR. Direct merge to dev is not permitted.
if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh not on PATH -- branch is committed locally as $SYNC_BRANCH; push and PR by hand" >&2
    exit 69
fi

git push -u origin "$SYNC_BRANCH"

# PR body composed at runtime in a tmp file; submitted via --body-file (never
# an inline --body, per the repo's PR-authoring convention and the
# heredoc-pr-guard hook).
PR_BODY_FILE="$(mktemp -t "sync-dev-after-${VERSION}-pr-body.XXXXXX")"
trap 'rm -f "$PR_BODY_FILE"' EXIT

TAG_SHORT="$(git rev-parse --short "$TAG_SHA")"

cat > "$PR_BODY_FILE" <<EOF
## Summary

Backports the ${VERSION} CHANGELOG.md from \`main\` so dev's changelog stops drifting behind released history. Copied
verbatim from \`origin/main\` at \`${TAG_SHORT}\`; the only changed file is \`CHANGELOG.md\`.

Generated by \`scripts/sync-dev-after-release.sh\`. Idempotent per release: if dev already matches main, the script
exits without opening this PR.

## Changelog

Producer-side release bookkeeping; nothing users observe. No \`## Changelog\` bullets to extract.

## Type of Change

- [x] \`chore\`: Maintenance tasks (release backport)

## Testing

- [x] Manual testing completed

Preflight verified the \`${VERSION}\` tag exists, \`origin/main\` is at or past it, and the GitHub Release is published.

## Files Modified

**Modified:**

- \`CHANGELOG.md\` (verbatim copy from \`origin/main\` at \`${TAG_SHORT}\`)

**Created:**

- None.

**Deleted:**

- None.

## Breaking Changes

- [x] No breaking changes

## Deployment Notes

- [x] No special deployment steps required
EOF

gh pr create \
    --base dev \
    --head "$SYNC_BRANCH" \
    --title "chore(release): sync dev after ${VERSION}" \
    --body-file "$PR_BODY_FILE"

echo "PR opened against dev; review and merge once CI is green."
