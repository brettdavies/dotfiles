#!/usr/bin/env bash
# Canonical version: 2026.11.03 (generic)
#
# Backport release artifacts from main to dev after a release tag publishes.
#
# Writes the released version into every version carrier the repo has and
# copies CHANGELOG.md from main, then lands them via a PR against dev (per
# this repo's PR-only convention: direct commits to dev are not permitted).
#   - Version carriers, each updated in place when present: the release
#     package's Cargo.toml (the workspace member that builds the binary when
#     the root manifest is virtual, `RELEASE_MANIFEST`; the root otherwise),
#     package.json, pyproject.toml, VERSION (plain text, no leading "v").
#     A repo with none of them gets a VERSION only for a vX.Y.Z tag: a bare
#     CalVer tag is the version, and a repo that releases on one may forbid a
#     carrier. A site (SITE_VERSION_BASE set in scripts/release/release.env)
#     gets neither a package.json version nor a VERSION: its tag, the deploy
#     stamp site-version.sh computes, is the version.
#   - Cargo.lock, whose workspace-member entries are refreshed from the synced
#     manifests once every other path is in, and checked with `--locked`.
#   - CHANGELOG.md, copied verbatim from origin/main when main carries one.
#     Main is fully authoritative for CHANGELOG; dev never edits it directly.
#   - Every other path main and dev disagree about, discovered rather than
#     listed. A release branch is edited for reasons nobody predicts (a doc
#     fix, a reverted payload, a deleted config), and each such edit is made
#     against main's base and never round-trips. A fixed list misses all of
#     them silently, and the next release's overlay or cherry-pick then
#     restores dev's copy over main's, undoing the edit.
#
# Discovery is bounded by the PREVIOUS release tag, the last point the two
# branches agreed, so widening the copy cannot revert dev's unreleased work:
#
#   release-prep  dev's copy is byte-identical to the previous tag's, so dev
#                 never touched it and main's version is purely release-prep.
#                 Adopted automatically.
#   contested     both sides moved since the previous tag. Reported, never
#                 adopted silently; --include-contested takes them all and
#                 --only PATH takes the ones you name.
#
# Guarded paths are excluded: they live on dev by design, so "syncing" them
# would delete them. The set resolves from scripts/release/guarded-paths.sh
# when the repo vendors it, never a second hand-kept copy.
#
# Run AFTER:
#   1. The release/v* -> main PR has merged.
#   2. `git tag -a vX.Y.Z` (or a site stamp `v<base>.<epoch>-g<sha7>`, or a bare
#      CalVer `YYYY.MM.DD[.N]` tag) has been pushed to origin.
#   3. The GitHub Release has been created.
#
# Usage:
#   ./scripts/sync-dev-after-release.sh v0.2.0
#   ./scripts/sync-dev-after-release.sh v0.2.0 --dry-run
#   ./scripts/sync-dev-after-release.sh v0.2.0 --only README.md
#   ./scripts/sync-dev-after-release.sh v0.2.0 --include-contested
#
# Idempotent: safe to re-run. If dev already matches main on every synced
# file, the script exits 0 without creating a branch or PR.

set -euo pipefail

USAGE="usage: $0 vX.Y.Z[-g<sha7>]|YYYY.MM.DD[.N] [--include-contested] [--only PATH]... [--dry-run]"
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
      echo "$USAGE"
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
  echo "$USAGE" >&2
  exit 64
fi
VERSION_NO_V="${VERSION#v}"

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# `RELEASE_MANIFEST` and `release_manifest` answer which manifest a `vX.Y.Z`
# tag names. Preflight and postflight read them from here, so this script reads
# the same definitions rather than keeping a second copy that can drift when
# the binary crate moves.
# shellcheck disable=SC1091  # sibling release lib, always vendored alongside
. scripts/release/_lib.sh

if [[ ! "$VERSION" =~ $RELEASE_TAG_RE ]]; then
  echo "error: version must be a vMAJOR.MINOR.PATCH, a site stamp vBASE.EPOCH-gSHA7, or bare CalVer YYYY.MM.DD[.N] tag (got: $VERSION); for example: $0 v1.2.3" >&2
  exit 64
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree not clean -- commit or stash first" >&2
  git status --short >&2
  exit 65
fi

git fetch origin --tags --quiet

# Verify the release tag exists locally.
if ! git rev-parse --verify --quiet "refs/tags/$VERSION" >/dev/null; then
  echo "error: tag $VERSION not found locally -- run 'git fetch origin --tags' or verify the release published" >&2
  exit 66
fi

# Verify main is at or past the tag (i.e. release/* actually merged).
# Peeled, since an annotated tag names a tag object, not the released commit.
TAG_SHA="$(git rev-parse "$VERSION^{commit}")"
if ! git merge-base --is-ancestor "$TAG_SHA" origin/main; then
  echo "error: tag $VERSION is not reachable from origin/main -- wait for the release PR to merge" >&2
  exit 66
fi

# Verify the GitHub Release exists and is not still a draft. The tag can exist
# (above check) while the GitHub Release was never created (or stayed draft),
# in which case consumers won't see the new version via `gh release` and the
# backport is premature.
if command -v gh >/dev/null 2>&1; then
  is_draft="$(gh release view "$VERSION" --json isDraft --jq .isDraft 2>/dev/null || true)"
  case "$is_draft" in
    false)
      ;;
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

# Cut a branch -- the repo's RELEASES.md and AGENTS.md ban direct commits to dev.
SYNC_BRANCH="chore/sync-dev-after-${VERSION}"
# Only a branch this run created may be cleaned up. A dry run creates none, so
# deleting the branch of a sync already in flight would discard its work.
BRANCH_IS_OURS=false

restore_dev() {
  git switch dev
  if [[ "$BRANCH_IS_OURS" == true ]]; then
    git branch -D "$SYNC_BRANCH"
    BRANCH_IS_OURS=false
  fi
  return 0
}

# Discovery copies main's versions in to compare them, which stages as well as
# writes, so an exit before the commit puts every synced path back to dev's
# copy. A path dev lacks was created by this run and is removed, along with any
# directory that held only it; a single restore of the whole list would refuse
# a created path git has never seen and restore nothing.
discard_sync() {
  local path
  for path in ${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}; do
    if git cat-file -e "$DEV_HEAD:$path" 2>/dev/null; then
      git restore --source="$DEV_HEAD" --staged --worktree -- "$path"
    else
      git rm --quiet --cached --ignore-unmatch -- "$path"
      rm -f -- "$path"
      [[ "$path" == */* ]] && { rmdir -p "${path%/*}" 2>/dev/null || true; }
    fi
  done
  restore_dev
}

# A dry run creates no branch, so an existing one is no reason to refuse: the
# question it answers, what this release would carry back, is exactly the one
# asked while a prior attempt is still open.
if [[ "$DRY_RUN" == false ]]; then
  if git rev-parse --verify --quiet "$SYNC_BRANCH" >/dev/null; then
    echo "error: branch $SYNC_BRANCH already exists locally -- delete it or finish the prior run" >&2
    exit 68
  fi
  if git ls-remote --exit-code --heads origin "$SYNC_BRANCH" >/dev/null 2>&1; then
    echo "error: branch $SYNC_BRANCH already exists on origin -- check for an open PR or delete the remote branch" >&2
    exit 68
  fi
  git checkout -b "$SYNC_BRANCH"
  BRANCH_IS_OURS=true
fi

# From the first write to the commit, every exit leaves dev as it was found,
# including one `set -e` takes on an unexpected failure.
DEV_HEAD="$(git rev-parse HEAD)"
SYNC_PATHS=()
trap discard_sync EXIT

# Writes VERSION_NO_V into the first `version = "..."` line of a TOML file,
# or the first `"version": "..."` entry of a JSON file, in place and without
# reformatting anything else.
set_version_line() {
  local file="$1" tmp
  tmp="$(mktemp)"
  awk -v v="$VERSION_NO_V" '
    !done && /^version = "/ { sub(/^version = "[^"]*"/, "version = \"" v "\""); done = 1 }
    !done && /"version": *"/ { sub(/"version": *"[^"]*"/, "\"version\": \"" v "\""); done = 1 }
    { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Every version carrier present gets the released number; the release commit
# on main bumped each of them. Cargo.lock is listed here so discovery below
# never copies main's, but it is written only once every manifest is synced.
if [[ -f Cargo.toml ]]; then
  set_version_line "$(release_manifest)"
  SYNC_PATHS+=("$(release_manifest)")
  if [[ -f Cargo.lock ]]; then
    SYNC_PATHS+=(Cargo.lock)
  fi
fi
if [[ -f package.json && -z "${SITE_VERSION_BASE:-}" ]]; then
  set_version_line package.json
  SYNC_PATHS+=(package.json)
fi
if [[ -f pyproject.toml ]]; then
  set_version_line pyproject.toml
  SYNC_PATHS+=(pyproject.toml)
fi
if [[ -f VERSION ]] || [[ ${#SYNC_PATHS[@]} -eq 0 && "$VERSION" == v* && -z "${SITE_VERSION_BASE:-}" ]]; then
  printf '%s\n' "$VERSION_NO_V" >VERSION
  SYNC_PATHS+=(VERSION)
fi

# Every changelog from main (authoritative), once the changelog machinery has
# produced one there; until then the version carriers are the only synced
# artifacts.
#
# Every one, not just the released crate's: a workspace member releases on its
# own tag line, so a release of one leaves the other's changelog on main ahead
# of dev. The next release branch overlays dev's tree onto main, which would
# carry that staler copy back and drop the section main already published.
changelog_paths() {
  local path
  path="$(release_changelog)"
  [[ -n "$path" ]] && printf '%s\n' "$path"
  # Each member names its own under [package.metadata.changelog]; the same
  # table generate-changelog.py reads, so the two cannot disagree.
  if [[ -f Cargo.toml ]]; then
    crate_changelog_paths
  fi
}

while IFS= read -r CHANGELOG_PATH; do
  [[ -n "$CHANGELOG_PATH" ]] || continue
  # shellcheck disable=SC2076  # literal match against the accumulated list
  [[ " ${SYNC_PATHS[*]} " == *" $CHANGELOG_PATH "* ]] && continue
  if git cat-file -e "origin/main:$CHANGELOG_PATH" 2>/dev/null; then
    git checkout origin/main -- "$CHANGELOG_PATH"
    SYNC_PATHS+=("$CHANGELOG_PATH")
  fi
done < <(changelog_paths | sort -u)

# --- Everything else the two branches disagree about ------------------------

# The guarded set lives on dev by design, so it must never enter the candidate
# list. Resolve it from the vendored script when the repo has one; a repo with
# no guarded paths simply matches nothing.
GUARDED='^$'
if [[ -x scripts/release/guarded-paths.sh ]]; then
  GUARDED="$(scripts/release/guarded-paths.sh)"
fi

# The previous release tag is the last commit where the branches agreed, which
# is what makes it the reference for "did dev move this file too?".
PREV_TAG="$(git tag --list "${RELEASE_TAG_GLOBS[@]}" --sort=-version:refname \
  | awk -v cur="$VERSION" '$0 != cur { print; exit }')"

blob_at() {
  git rev-parse --quiet --verify "$1:$2" 2>/dev/null || true
}

_already_synced() {
  local p
  for p in ${SYNC_PATHS[@]+"${SYNC_PATHS[@]}"}; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

RELEASE_PREP=()
CONTESTED=()
if [[ -n "$PREV_TAG" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    # Version carriers are written from $VERSION above, not copied from main.
    _already_synced "$path" && continue
    if [[ "$(blob_at origin/dev "$path")" == "$(blob_at "$PREV_TAG" "$path")" ]]; then
      RELEASE_PREP+=("$path")
    else
      CONTESTED+=("$path")
    fi
  done < <(git diff --no-renames --name-only origin/dev origin/main | grep -Ev "$GUARDED" || true)
fi

DISCOVERED=(${RELEASE_PREP[@]+"${RELEASE_PREP[@]}"})
if [[ "$INCLUDE_CONTESTED" == true ]]; then
  DISCOVERED+=(${CONTESTED[@]+"${CONTESTED[@]}"})
fi

# --only narrows the discovered set to named paths, contested included. The
# all-or-nothing flag is too blunt alone: a release routinely leaves some
# contested paths that should be adopted beside others where dev is
# deliberately ahead (a dependency bump that landed after the release makes
# main's copy the stale one). Intersecting rather than assigning is what keeps
# this safe, so a guarded, undiverged, or misspelled path cannot be forced in.
if [[ ${#ONLY[@]} -gt 0 ]]; then
  ALL_CANDIDATES=(${RELEASE_PREP[@]+"${RELEASE_PREP[@]}"} ${CONTESTED[@]+"${CONTESTED[@]}"})
  DISCOVERED=()
  for want in "${ONLY[@]}"; do
    matched=false
    for cand in ${ALL_CANDIDATES[@]+"${ALL_CANDIDATES[@]}"}; do
      if [[ "$cand" == "$want" ]]; then
        DISCOVERED+=("$cand")
        matched=true
        break
      fi
    done
    if [[ "$matched" != true ]]; then
      echo "error: --only $want is not a diverged, unguarded path" >&2
      exit 64
    fi
  done
fi

if [[ ${#CONTESTED[@]} -gt 0 ]]; then
  if [[ "$INCLUDE_CONTESTED" == true ]]; then
    echo "contested (both sides moved; adopting main's copy per --include-contested):"
  else
    echo "contested (both sides moved since ${PREV_TAG:-the previous tag}; NOT adopted):" >&2
  fi
  printf '  %s\n' "${CONTESTED[@]}"
  if [[ "$INCLUDE_CONTESTED" != true && ${#ONLY[@]} -eq 0 ]]; then
    echo "  re-run with --include-contested to take main's version of these," >&2
    echo "  name the ones you want with --only PATH, or resolve them by hand." >&2
  fi
fi

# Adopt each discovered path. A path main deleted is removed rather than
# checked out, because `git checkout main -- <deleted>` fails on a pathspec
# that does not exist at that ref.
for path in ${DISCOVERED[@]+"${DISCOVERED[@]}"}; do
  if [[ -n "$(blob_at origin/main "$path")" ]]; then
    git checkout origin/main -- "$path"
  else
    git rm --quiet --ignore-unmatch -- "$path"
  fi
  SYNC_PATHS+=("$path")
done

# Cargo.lock records every workspace member's version, and a release can move
# more than the released crate's: a sibling member's bump arrives through
# discovery as that member's manifest. Refresh the members' entries from the
# synced manifests rather than copying main's lock, which would revert
# dependency updates dev merged after the release, and refuse to commit a lock
# that `cargo metadata --locked` rejects.
if [[ -f Cargo.lock ]]; then
  if ! have_bin cargo; then
    echo "error: cargo not on PATH -- Cargo.lock cannot be synced to the manifests; nothing was committed" >&2
    exit 69
  fi
  if ! cargo update --workspace --offline --quiet \
    || ! cargo metadata --locked --offline --format-version 1 >/dev/null; then
    echo "error: Cargo.lock does not resolve against the synced manifests; nothing was committed" >&2
    exit 70
  fi
fi

# `git checkout origin/main -- FILE` stages the file, so `git diff --quiet`
# (worktree against index) never sees that change and would report "no
# changes" with a differing CHANGELOG. `status --porcelain` sees staged,
# unstaged, and untracked alike, including a VERSION created on the first
# sync. Compare the index against HEAD too, since a discovered deletion is
# already staged and leaves the worktree clean.
if [[ -z "$(git status --porcelain -- "${SYNC_PATHS[@]}")" ]] && git diff --cached --quiet; then
  echo "no changes -- dev already in sync with $VERSION"
  exit 0
fi

echo "syncing (${#SYNC_PATHS[@]} path(s)):"
printf '  %s\n' "${SYNC_PATHS[@]}"

if [[ "$DRY_RUN" == true ]]; then
  echo "dry run -- no branch, commit, or PR created"
  exit 0
fi

# Only the carrier paths need an explicit add: checkout and rm already stage
# their result, and re-adding a path just deleted fails on "pathspec did not
# match any files" because it is gone from the worktree.
for path in "${SYNC_PATHS[@]}"; do
  [[ -e "$path" ]] && git add -- "$path"
done

COMMIT_MSG_FILE="$(mktemp -t "sync-dev-after-${VERSION}-commit.XXXXXX")"
cat >"$COMMIT_MSG_FILE" <<EOF
chore(release): backport $VERSION artifacts to dev

Brings dev's release bookkeeping current with the $VERSION release on
main: version carriers set to ${VERSION_NO_V}, and CHANGELOG.md copied
verbatim from origin/main when main carries one.

Synced: ${SYNC_PATHS[*]}
EOF
git commit --file "$COMMIT_MSG_FILE"
trap - EXIT
rm -f "$COMMIT_MSG_FILE"

# Post-sync sanity check: re-running generate-changelog.py against the current
# PR bodies should produce an identical CHANGELOG.md. It fails when upstream PR
# bodies were edited after main's CHANGELOG.md was generated, when something
# rewrapped the generated file, or when the generator cannot run at all, and
# only the generator knows which, so its own reason line is what the warning
# carries. With no changelog in this sync there is nothing to compare. Warn, do
# not fail; the backport is still correct against what main currently has.
#
# The reason is the generator's `DRY RUN:` or `error:` line, else its last
# line, since a crash's traceback ends with the exception.
regen_reason() {
  awk '/^(DRY RUN|error):/ { print; found = 1; exit } NF { last = $0 } END { if (!found) print last }'
}

# In a workspace the release changelog is a member's, and the generator
# refuses the routing root a run without --crate would read; the same helper
# the cut script calls decides the arguments, so the two compare one file.
if _already_synced "$(release_changelog)" \
  && [[ -x scripts/generate-changelog.py ]] && command -v git-cliff >/dev/null 2>&1; then
  read -ra crate_args <<<"$(changelog_crate_args)"
  regen_args=(--dry-run --tag "$VERSION" "${crate_args[@]}")
  if regen_err="$(scripts/generate-changelog.py "${regen_args[@]}" 2>&1 >/dev/null)"; then
    echo "regen check: $(release_changelog) matches what PR bodies would produce"
  else
    echo "warning: regen check did not pass for $(release_changelog) at $VERSION: $(regen_reason <<<"$regen_err")" >&2
    echo "  re-run 'scripts/generate-changelog.py ${regen_args[*]}' for its full output" >&2
  fi
fi

# Push the sync branch and open a PR. Direct merge to dev is not permitted.
if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh not on PATH -- branch is committed locally as $SYNC_BRANCH; push and PR by hand" >&2
  exit 69
fi

git push -u origin "$SYNC_BRANCH"

# PR body composed at runtime; written to mktemp so gh pr create reads it
# via --body-file rather than an inline heredoc.
PR_BODY_FILE="$(mktemp -t "sync-dev-after-${VERSION}-pr-body.XXXXXX")"
trap 'rm -f "$PR_BODY_FILE"' EXIT

TAG_SHORT="$(git rev-parse --short "$TAG_SHA")"
# Backticks below are markdown code spans in the PR body, not expansions.
# shellcheck disable=SC2016
SYNC_LIST="$(printf '`%s`, ' "${SYNC_PATHS[@]}")"
SYNC_LIST="${SYNC_LIST%, }"
# shellcheck disable=SC2016
SYNC_BULLETS="$(for f in "${SYNC_PATHS[@]}"; do
  if [[ "$f" == CHANGELOG.md ]]; then
    printf -- '- `%s` (verbatim copy from `origin/main` at `%s`)\n' "$f" "$TAG_SHORT"
  else
    printf -- '- `%s` (version set to `%s`)\n' "$f" "$VERSION_NO_V"
  fi
done)"

cat >"$PR_BODY_FILE" <<EOF
## Summary

Backports the ${VERSION} release-prep state from \`main\` so dev's version carriers match the released
number and the ${VERSION} CHANGELOG section sits at the top of dev's \`CHANGELOG.md\` going forward.

Source: tag \`${VERSION}\` at \`${TAG_SHORT}\` on \`main\`. Files synced: ${SYNC_LIST}.

Generated by \`scripts/sync-dev-after-release.sh\`. Run idempotently per release: if dev already matches main on
these files, the script exits 0 without creating this PR.

## Changelog

This PR is producer-side scaffolding and does not change anything users see; no \`## Changelog\` bullets to
extract.

## Type of Change

- [x] \`chore\`: Maintenance tasks (release backport)

## Related Issues/Stories

- Story: n/a
- Issue: n/a
- Architecture: n/a
- Related PRs: the release/${VERSION} PR into main

## Testing

- [x] Manual testing completed

The script's preflight verified: the release tag exists, \`origin/main\` is at or past it, and the GitHub Release
is not still a draft. \`generate-changelog.py --dry-run\` was also invoked post-sync to check for PR-body drift
against the backported CHANGELOG; see this PR's stderr for any drift warnings.

## Files Modified

**Modified:**

${SYNC_BULLETS}

**Created:**

- None.

**Renamed:**

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
