#!/usr/bin/env bash
# Backport release artifacts from main to dev after a CalVer release publishes.
#
# The release flow cuts release/* from origin/main and regenerates CHANGELOG.md
# there; that commit never round-trips to dev, so dev's CHANGELOG.md drifts
# behind main with every release. This script closes that gap: it copies
# CHANGELOG.md verbatim from origin/main and lands it on dev via a PR (direct
# commits to dev are not permitted per RELEASES.md).
#
# The set of files is discovered, never hardcoded. A hardcoded list only ever
# catches what its author predicted: the 2026.09.14 release edited a stow
# payload and deleted three tmuxinator configs on the release branch, and a
# CHANGELOG-only backport left every one of them on main alone, where the next
# overlay would silently restore them from dev. What needs backporting is
# whatever main and dev actually disagree about, so that is what this computes.
#
# Still surgical, only main -> dev, never a branch merge. dev is normally many
# commits ahead of main (unreleased work), so adopting main's version of a file
# dev has moved on would revert that work. Candidates are therefore classified
# against the PREVIOUS release tag, which is the last point the two branches
# agreed:
#
#   release-prep  dev's copy is byte-identical to the previous tag's, so dev
#                 never touched it and main's version is purely release-prep.
#                 Adopted automatically.
#   contested     both sides moved since the previous tag. Never adopted
#                 silently; listed for a human, and included only with
#                 --include-contested.
#
# Guarded paths (docs/plans, docs/solutions, .context, ...) are excluded: they
# live on dev by design and main lacking them is correct, so "syncing" them
# would delete them from dev. The set resolves from the same workflow the
# release leak-check uses, never a second hand-kept copy.
#
# Run AFTER:
#   1. The release/* -> main PR has merged.
#   2. release.yml tagged the release and pushed the tag.
#   3. The GitHub Release was created.
#
# Usage:
#   ./scripts/sync-dev-after-release.sh 2026.06.03
#   ./scripts/sync-dev-after-release.sh 2026.06.03.1   # same-day re-release
#   ./scripts/sync-dev-after-release.sh 2026.06.03 --include-contested
#   ./scripts/sync-dev-after-release.sh 2026.06.03 --only README.md --only AGENTS.md
#   ./scripts/sync-dev-after-release.sh 2026.06.03 --dry-run
#
# Idempotent: if dev already matches main everywhere that counts, exits 0
# without creating a branch or PR.

set -euo pipefail

VERSION=""
INCLUDE_CONTESTED=false
DRY_RUN=false
ONLY=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-contested) INCLUDE_CONTESTED=true ;;
    --dry-run) DRY_RUN=true ;;
    --only)
      [[ $# -ge 2 ]] || {
        echo "error: --only needs a path" >&2
        exit 64
      }
      ONLY+=("$2")
      shift
      ;;
    -h | --help)
      echo "usage: $0 YYYY.MM.DD[.N] [--include-contested] [--only PATH]... [--dry-run]"
      exit 0
      ;;
    -*)
      echo "error: unknown flag $1" >&2
      exit 64
      ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "error: unexpected argument $1" >&2
        exit 64
      fi
      VERSION="$1"
      ;;
  esac
  shift
done

if [[ -z "$VERSION" ]]; then
  echo "usage: $0 YYYY.MM.DD[.N] [--include-contested] [--dry-run]" >&2
  exit 64
fi
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

# --- Discover what to sync -------------------------------------------------

# The guarded set lives on dev only; main lacking those paths is correct, so
# they must never enter the candidate list. Resolved from the workflow, the
# same source the release leak-check reads.
GUARDED="$(scripts/release/guarded-paths.sh)"

# The previous release tag is the last commit where main and dev agreed, which
# is what makes it the reference for "did dev move this file too?". Tags sort
# by version so the newest below $VERSION is the predecessor.
PREV_TAG="$(git tag --list --sort=-version:refname \
  | awk -v cur="$VERSION" '$0 != cur { print; exit }')"
if [[ -z "$PREV_TAG" ]]; then
  echo "error: no release tag older than $VERSION -- cannot classify candidates" >&2
  exit 66
fi

# blob_at REF PATH -- the object id of PATH at REF, or the empty string when
# the path does not exist there. Comparing ids rather than content keeps
# "absent on both sides" distinct from "identical on both sides".
blob_at() {
  git rev-parse --quiet --verify "$1:$2" 2>/dev/null || true
}

RELEASE_PREP=()
CONTESTED=()

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  dev_blob="$(blob_at origin/dev "$path")"
  prev_blob="$(blob_at "$PREV_TAG" "$path")"
  if [[ "$dev_blob" == "$prev_blob" ]]; then
    RELEASE_PREP+=("$path")
  else
    CONTESTED+=("$path")
  fi
done < <(git diff --no-renames --name-only origin/dev origin/main | grep -Ev "$GUARDED" || true)

# `${arr[@]+...}` guards the expansion: under `set -u` a bare "${arr[@]}" on an
# empty array is an unbound-variable error in bash before 4.4, which is what
# macOS still ships as /bin/bash.
SYNC_PATHS=(${RELEASE_PREP[@]+"${RELEASE_PREP[@]}"})
if [[ "$INCLUDE_CONTESTED" == true ]]; then
  SYNC_PATHS+=(${CONTESTED[@]+"${CONTESTED[@]}"})
fi

# --only narrows the set to named paths, contested ones included. The whole-set
# flag is too blunt on its own: a release leaves some contested paths that
# should be adopted next to others where dev is deliberately ahead, and the
# first real run hit exactly that (dependency bumps landed on dev after the
# release, so main's copies of those workflows are stale and must not win).
# Intersecting rather than assigning is what keeps this safe -- a path that is
# guarded, undiverged, or misspelled cannot be forced in by naming it.
if [[ ${#ONLY[@]} -gt 0 ]]; then
  ALL_CANDIDATES=(${RELEASE_PREP[@]+"${RELEASE_PREP[@]}"} ${CONTESTED[@]+"${CONTESTED[@]}"})
  FILTERED=()
  for want in "${ONLY[@]}"; do
    matched=false
    for cand in ${ALL_CANDIDATES[@]+"${ALL_CANDIDATES[@]}"}; do
      if [[ "$cand" == "$want" ]]; then
        FILTERED+=("$cand")
        matched=true
        break
      fi
    done
    if [[ "$matched" != true ]]; then
      echo "error: --only $want is not a diverged, unguarded path" >&2
      exit 64
    fi
  done
  SYNC_PATHS=(${FILTERED[@]+"${FILTERED[@]}"})
fi

echo "Comparing origin/dev against origin/main since $PREV_TAG"
if [[ ${#RELEASE_PREP[@]} -gt 0 ]]; then
  echo "  release-prep (dev untouched since $PREV_TAG, adopting main's copy):"
  printf '    %s\n' "${RELEASE_PREP[@]}"
fi
if [[ ${#CONTESTED[@]} -gt 0 ]]; then
  if [[ "$INCLUDE_CONTESTED" == true ]]; then
    echo "  contested (both sides moved; adopting main's copy per --include-contested):"
  else
    echo "  contested (both sides moved since $PREV_TAG; NOT adopted):" >&2
  fi
  printf '    %s\n' "${CONTESTED[@]}"
  if [[ "$INCLUDE_CONTESTED" != true && ${#ONLY[@]} -eq 0 ]]; then
    echo "  re-run with --include-contested to take main's version of these," >&2
    echo "  name the ones you want with --only PATH, or resolve them by hand." >&2
  fi
fi

if [[ ${#SYNC_PATHS[@]} -eq 0 ]]; then
  echo "no changes -- dev already in sync with $VERSION"
  git switch dev
  git branch -D "$SYNC_BRANCH"
  exit 0
fi

# The resolved set, after --only narrowing. Printing it is the point of a dry
# run: the classification above says what diverged, this says what would move.
echo "  syncing (${#SYNC_PATHS[@]} path(s)):"
printf '    %s\n' "${SYNC_PATHS[@]}"

if [[ "$DRY_RUN" == true ]]; then
  echo "dry run -- no branch, commit, or PR created"
  git switch dev
  git branch -D "$SYNC_BRANCH"
  exit 0
fi

# Adopt main's state for each path. A path main deleted has to be removed from
# dev rather than checked out, because `git checkout main -- <deleted>` fails
# on a pathspec that does not exist at that ref.
for path in "${SYNC_PATHS[@]}"; do
  if [[ -n "$(blob_at origin/main "$path")" ]]; then
    git checkout origin/main -- "$path"
  else
    git rm --quiet --ignore-unmatch -- "$path"
  fi
done

# `git checkout REF -- FILE` and `git rm` both stage, so an unstaged `git diff`
# is always empty here. Compare the index against HEAD instead.
if git diff --cached --quiet; then
  echo "no changes -- dev already in sync with $VERSION"
  git switch dev
  git branch -D "$SYNC_BRANCH"
  exit 0
fi

# No `git add` here: `git checkout REF -- path` and `git rm` both stage their
# result already, and re-adding a path this loop deleted fails the whole run on
# "pathspec did not match any files" because it is gone from the worktree.

COMMIT_MSG_FILE="$(mktemp -t "sync-dev-after-${VERSION}-commit.XXXXXX")"
{
  echo "chore(release): backport $VERSION release-prep state to dev"
  echo
  echo "Brings dev current with the $VERSION release on main for every path the"
  echo "two branches disagree about, discovered by comparing the branches rather"
  echo "than from a fixed list. main is authoritative for these paths; dev never"
  echo "edits CHANGELOG.md directly, and the rest are release-branch edits that"
  echo "never round-tripped."
  echo
  echo "Synced: ${SYNC_PATHS[*]}"
} >"$COMMIT_MSG_FILE"
git commit --file "$COMMIT_MSG_FILE"
rm -f "$COMMIT_MSG_FILE"

# Post-sync sanity check: re-running generate-changelog.py against the current
# PR bodies should reproduce the backported CHANGELOG.md. Drift here means
# upstream PR bodies were edited after main's CHANGELOG.md was generated. Warn,
# do not fail; the backport is still correct against what main currently has.
if printf '%s\n' "${SYNC_PATHS[@]}" | grep -qx 'CHANGELOG.md' \
  && [[ -x scripts/generate-changelog.py ]] && command -v git-cliff >/dev/null 2>&1; then
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
ADOPTED=()
REMOVED=()
for path in "${SYNC_PATHS[@]}"; do
  if [[ -n "$(blob_at origin/main "$path")" ]]; then
    ADOPTED+=("$path")
  else
    REMOVED+=("$path")
  fi
done
MODIFIED_BULLETS="None."
[[ ${#ADOPTED[@]} -gt 0 ]] && MODIFIED_BULLETS="$(printf -- '- `%s`\n' "${ADOPTED[@]}")"
DELETED_BULLETS="None."
[[ ${#REMOVED[@]} -gt 0 ]] && DELETED_BULLETS="$(printf -- '- `%s`\n' "${REMOVED[@]}")"
CONTESTED_NOTE="None."
if [[ ${#CONTESTED[@]} -gt 0 && "$INCLUDE_CONTESTED" != true ]]; then
  CONTESTED_NOTE="$(printf -- '- `%s`\n' "${CONTESTED[@]}")"
fi

cat >"$PR_BODY_FILE" <<EOF
## Summary

Backports the ${VERSION} release-prep state from \`main\` so dev stops drifting behind released history. The paths are
discovered by comparing \`origin/dev\` against \`origin/main\` at \`${TAG_SHORT}\` and excluding the guarded set, not read
from a fixed list, so a release-branch edit to any file is caught rather than only the ones someone predicted.

A path is adopted when dev's copy is byte-identical to its copy at \`${PREV_TAG}\`, meaning dev never touched it and
main's version is purely release-prep. Paths both branches moved since \`${PREV_TAG}\` are reported instead of
overwritten.

Generated by \`scripts/sync-dev-after-release.sh\`. Idempotent per release: if dev already matches main, the script
exits without opening this PR.

**Paths still contested (not adopted here):**

${CONTESTED_NOTE}

## Changelog

Producer-side release bookkeeping; nothing users observe. No \`## Changelog\` bullets to extract.

## Type of Change

- [x] \`chore\`: Maintenance tasks (release backport)

## Testing

- [x] Manual testing completed

Preflight verified the \`${VERSION}\` tag exists, \`origin/main\` is at or past it, and the GitHub Release is published.

## Files Modified

**Modified:**

${MODIFIED_BULLETS}

**Created:**

- None.

**Renamed:**

- None.

**Deleted:**

${DELETED_BULLETS}

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
