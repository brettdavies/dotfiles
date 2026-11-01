#!/usr/bin/env bash
# Release drift gate: what does the release branch's base carry that the
# integration branch never received?
#
# Security PRs, hotfixes, and config edits land on main first. The release
# branch is cut from main and then takes dev's changes, so anything main holds
# that dev never received is either reverted by the release or collides with
# it, and Dependabot raises the same fix again. Run this before cutting the
# release branch; it exits non-zero while any such drift exists.
#
# Usage:
#   scripts/release/drift.sh [--base REF] [--head REF] [--since REF]
#                            [--no-fetch] [--result-file PATH]
#
# Flags:
#   --base REF          Integration branch (default: origin/dev)
#   --head REF          Release base (default: origin/main)
#   --since REF         Anchor for "commits on head since the last release".
#                       Default, in order: the newest release tag reachable
#                       from head (vX.Y.Z or a bare CalVer YYYY.MM.DD[.N]);
#                       the newest head commit whose subject starts with
#                       "release:" or "release v"; the merge base of the two
#                       refs.
#   --no-fetch          Skip `git fetch origin` (default: fetch when a ref
#                       starts with origin/)
#   --result-file PATH  Write "<pass> <fail> <skip>" to PATH at exit for
#                       _lib.sh's delegate_to_subscript; suppresses the summary
#
# Gates:
#   0. The anchor release itself reached base: for each version carrier and
#      CHANGELOG.md the anchor changed, every line the release added is in
#      base's copy or was held by base at some commit, and every line it
#      removed is gone from base's copy (a release whose backport never ran is
#      invisible to gate 1, which only looks past it).
#   1. Every commit on head since the anchor, and every file those commits
#      touched that base does not already contain. A file base has moved
#      further on its own is not drift: head's change (anchor to head) is
#      checked against base's copy, first by three-way merge and then line by
#      line (every added line present, every removed line gone). In a
#      package.json, a dependency entry counts as present when base declares
#      it in the same section at the same or a newer lower bound. Lockfiles
#      are handled by gate 3.
#   2. .github/ paths head carries that base does not contain. A path
#      base holds and head does not is what the release delivers, not
#      drift, so only the head-ahead direction fails.
#   3. For each lockfile head carries (package-lock.json, bun.lock,
#      Cargo.lock): every
#      package head resolves newer than base, one line per package name so
#      nested copies and hoisting moves never show. Only resolved versions
#      compare; a file:, workspace:, link: or git spec is left out. A copy
#      head nests under a package base no longer carries is not counted,
#      since base dropped what pulled it in. The count of base-newer
#      packages (routine updates awaiting release) is reported for context.
#
# Exit codes:
#   0 = no drift
#   1 = drift found (see the failed gates)
#   2 = setup error (missing dependency, unknown ref)
#
# Dependencies: git, diff, perl, jq or jaq (for package-lock.json and bun.lock), sort -V, join.
set -euo pipefail

# shellcheck disable=SC1091  # sibling _lib.sh, always vendored alongside
. "$(dirname "$0")/_lib.sh"

# Argument parsing -----------------------------------------------------------

BASE_REF="origin/dev"
HEAD_REF="origin/main"
SINCE_REF=""
DO_FETCH=1
RESULT_FILE=""

usage() {
  print_usage_header
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE_REF="$2"
      shift 2
      ;;
    --head)
      HEAD_REF="$2"
      shift 2
      ;;
    --since)
      SINCE_REF="$2"
      shift 2
      ;;
    --no-fetch)
      DO_FETCH=0
      shift
      ;;
    --result-file)
      RESULT_FILE="$2"
      shift 2
      ;;
    -h | --help) usage ;;
    *)
      echo "unknown arg: $1" >&2
      usage
      ;;
  esac
done

require_bin git
require_bin join
JQ_BIN=""
if have_bin jq; then
  JQ_BIN=jq
elif have_bin jaq; then
  JQ_BIN=jaq
fi
readonly JQ_BIN

readonly LOCKFILE_PATTERN='(^|/)(package-lock\.json|bun\.lock|Cargo\.lock)$'
# Overridable from release.env, which _lib.sh sourced above. A workspace names
# each member manifest and each member changelog here: the root list covers a
# single-package repo, and a carrier this list omits is a file whose
# release-time edit the gate silently treats as ordinary drift.
readonly VERSION_CARRIERS="${VERSION_CARRIERS:-Cargo.toml package.json pyproject.toml VERSION CHANGELOG.md}"

# Setup ----------------------------------------------------------------------

# Fetches origin when either ref is a remote-tracking ref; a failed fetch is
# reported and the gates run on whatever the local refs hold.
maybe_fetch() {
  [[ $DO_FETCH -eq 1 ]] || return 0
  [[ "$BASE_REF" == origin/* || "$HEAD_REF" == origin/* ]] || return 0
  git fetch origin --quiet 2>/dev/null || echo "warning: git fetch origin failed; using local refs" >&2
}

# Aborts with exit 2 when a ref does not resolve to a commit.
require_ref() {
  git rev-parse --verify --quiet "$1^{commit}" >/dev/null || {
    echo "unknown ref: $1" >&2
    exit 2
  }
}

# Resolves the anchor commit for "since the last release" and prints how it
# was chosen. Honors --since when given.
resolve_anchor() {
  local tag subject_commit
  if [[ -n "$SINCE_REF" ]]; then
    require_ref "$SINCE_REF"
    ANCHOR=$(git rev-parse "$SINCE_REF^{commit}")
    ANCHOR_HOW="--since $SINCE_REF"
    return
  fi
  if tag=$(git describe --tags --abbrev=0 --match 'v[0-9]*' --match '[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]*' "$HEAD_REF" 2>/dev/null); then
    ANCHOR=$(git rev-parse "$tag^{commit}")
    ANCHOR_HOW="tag $tag"
    return
  fi
  # `git log --grep` searches the whole message, so a body that quotes a
  # release line would match; filter on the subject line itself.
  subject_commit=$(git log --format='%H %s' "$HEAD_REF" 2>/dev/null \
    | grep -E -m1 '^[0-9a-f]+ release(: | v?[0-9])' | cut -d' ' -f1 || true)
  if [[ -n "$subject_commit" ]]; then
    ANCHOR="$subject_commit"
    ANCHOR_HOW="release commit $(git log -1 --format='%h %s' "$subject_commit")"
    return
  fi
  ANCHOR=$(git merge-base "$BASE_REF" "$HEAD_REF")
  ANCHOR_HOW="merge base $(git rev-parse --short "$ANCHOR")"
}

# Gate 0: the anchor release reached base ------------------------------------
#
# Gate 1 only looks past the anchor, so a release whose backport never ran
# is invisible to it. Compare the version carriers and CHANGELOG.md at the
# anchor against base: base must already hold every change the release made
# to them, or the next overlay cut reverts the release's own bookkeeping.
#
# The release's diff mixes two kinds of line: those the cut wrote itself (the
# version bump, the new changelog section) and content the overlay carried
# over from base. Base may later edit or delete the second kind on its own, so
# an added line counts as held when base's copy has it or base held it at any
# commit; a line base once held and then dropped is base's own edit, not a
# missing backport. The lines the cut wrote were never on base before the
# backport, so a skipped backport still fails, and a version bump fails twice:
# its new line was never held and its old line is still in base's copy.
#
# A line that repeats within a file, such as a changelog's "### Fixed",
# counts as present wherever it appears. The version line and the release
# heading are unique to the release, and those keep the check sound.

gate_anchor_backported() {
  header "Anchor release backported to $BASE_REF"
  local path verdict head_blob prev
  local -a flagged=()
  if [[ "$ANCHOR" == "$(git merge-base "$BASE_REF" "$HEAD_REF")" ]]; then
    gate_skip "anchor bookkeeping" "anchor is the merge base; nothing to compare"
    return
  fi
  prev=$(git rev-parse --verify --quiet "$ANCHOR^" || true)
  for path in $VERSION_CARRIERS; do
    head_blob=$(blob_at "$ANCHOR" "$path")
    [[ -n "$head_blob" ]] || continue
    [[ -n "$prev" && "$(blob_at "$prev" "$path")" == "$head_blob" ]] && continue
    if [[ -z "$prev" || -z "$(blob_at "$prev" "$path")" ]]; then
      # The anchor release created this file, so there is no change to
      # contain; base only has to carry the file. Base may since have moved
      # it on (a routine bump), which is not drift.
      [[ -n "$(blob_at "$BASE_REF" "$path")" ]] || flagged+=("missing $path")
      continue
    fi
    verdict=$(classify_file_at "$ANCHOR" "$prev" "$path" history)
    [[ "$verdict" == contained ]] || flagged+=("$verdict $path")
  done
  if [[ ${#flagged[@]} -eq 0 ]]; then
    gate_pass "$BASE_REF carries the $ANCHOR_HOW bookkeeping"
    return
  fi
  gate_fail "$BASE_REF lacks the $ANCHOR_HOW bookkeeping" "${#flagged[@]} files; run scripts/sync-dev-after-release.sh"
  for path in "${flagged[@]}"; do
    printf '    %-9s %s\n' "${path%% *}" "${path#* }"
  done
}

# Gate 1: commits on head since the anchor and the files they touched -------

# Prints the blob id of PATH at REF, or nothing when the path is absent.
blob_at() {
  git rev-parse --verify --quiet "$1:$2" 2>/dev/null || true
}

# Classifies PATH as "contained", "differs", or "missing": whether base
# already holds everything head changed in it since the anchor. A path base
# deleted counts as contained when head's copy is still the anchor's. First a
# three-way merge of head's change onto base's copy; a clean merge that leaves
# base's copy untouched is contained. When base has also edited nearby lines
# the merge cannot answer, so the fallback checks head's change line by line:
# every line head added must appear in base's copy and every line head removed
# must be gone from it. Lines that are only punctuation are ignored, since
# they repeat throughout a file.
classify_file() {
  classify_file_at "$HEAD_REF" "$ANCHOR" "$1"
}

# Same as classify_file, for an explicit head ref and anchor ref (an empty
# anchor means "no prior state", so any difference from base is drift). With
# a fourth argument, the line check also counts an added line as present when
# base held PATH with that line at any commit (gate 0's rule).
classify_file_at() {
  local head_ref="$1" anchor_ref="$2" path="$3" history="${4:-}"
  local anchor_blob head_blob base_blob tmp merged status held=""
  head_blob=$(blob_at "$head_ref" "$path")
  base_blob=$(blob_at "$BASE_REF" "$path")
  anchor_blob=""
  [[ -n "$anchor_ref" ]] && anchor_blob=$(blob_at "$anchor_ref" "$path")
  if [[ -z "$base_blob" ]]; then
    # Base deleted a path head has not touched since the anchor: head carries
    # nothing base never received, and the deletion is base's own change for
    # the release to deliver. Only a head-side change since the anchor is
    # missing from base.
    if [[ -n "$anchor_blob" && "$head_blob" == "$anchor_blob" ]]; then
      echo contained
    else
      echo missing
    fi
    return
  fi
  if [[ "$head_blob" == "$base_blob" ]]; then
    echo contained
    return
  fi
  if [[ -z "$anchor_blob" ]]; then
    echo differs
    return
  fi
  tmp=$(mktemp -d)
  git cat-file -p "$anchor_blob" >"$tmp/anchor"
  git cat-file -p "$base_blob" >"$tmp/base"
  git cat-file -p "$head_blob" >"$tmp/head"
  set +e
  merged=$(git merge-file -p "$tmp/base" "$tmp/anchor" "$tmp/head" 2>/dev/null)
  status=$?
  set -e
  if [[ $status -eq 0 && "$merged" == "$(<"$tmp/base")" ]]; then
    echo contained
    rm -rf "$tmp"
    return
  fi
  if [[ -n "$history" ]]; then
    held="$tmp/held"
    base_history_lines "$path" "$held"
  fi
  if lines_contained "$tmp/anchor" "$tmp/head" "$tmp/base" "$path" "$held"; then
    echo contained
  else
    echo differs
  fi
  rm -rf "$tmp"
}

# Writes to OUT every line PATH held at any commit on BASE_REF that touched it,
# each once. A package.json copy is qualified first, as lines_contained
# qualifies the copies it compares.
base_history_lines() {
  local path="$1" out="$2" commit
  : >"$out.all"
  while IFS= read -r commit; do
    git cat-file -p "$commit:$path" >"$out.rev" 2>/dev/null || continue
    if [[ "${path##*/}" == package.json ]]; then
      qualify_dependency_entries "$out.rev"
    fi
    cat "$out.rev" >>"$out.all"
  done < <(git rev-list "$BASE_REF" -- "$path")
  sort -u "$out.all" >"$out"
}

# Lines on one side of a diff between two files, marker stripped. `+` gives the
# lines added going from the first file to the second, `-` the lines removed.
#
# `git diff --no-index` rather than diff's --unchanged-line-format family:
# those belong to GNU diffutils, and BSD diff rejects them outright. The
# rejection printed a usage message and produced no lines, so every line-level
# containment check silently answered "nothing changed" on a BSD host, which
# passed gates that should have failed. git is already a hard dependency here.
diff_side() {
  local marker="$1" left="$2" right="$3"
  git diff --no-index --no-color -U0 -- "$left" "$right" 2>/dev/null \
    | grep -E "^\\${marker}" \
    | grep -vE "^\\${marker}{3}" \
    | cut -c2-
  return 0
}

# Returns 0 when every content line ADDED between ANCHOR_FILE and HEAD_FILE
# is present in BASE_FILE and every content line REMOVED is absent from it.
# When PATH names a package.json, the three copies are first rewritten in place
# by qualify_dependency_entries, and an added dependency entry base does not
# hold verbatim still counts as present when dependency_covered finds base's
# range at or past it, since a range base has bumped since still carries it.
# With HELD_FILE, an added line found there counts as present too.
lines_contained() {
  local anchor_file="$1" head_file="$2" base_file="$3" path="${4:-}" held_file="${5:-}" manifest=0 line
  if [[ "${path##*/}" == package.json ]]; then
    manifest=1
    qualify_dependency_entries "$anchor_file" "$head_file" "$base_file"
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:][:punct:]]*$ ]] && continue
    grep -qxF -- "$line" "$base_file" && continue
    [[ -n "$held_file" ]] && grep -qxF -- "$line" "$held_file" && continue
    [[ $manifest -eq 1 ]] && dependency_covered "$line" "$base_file" && continue
    return 1
  done < <(diff_side + "$anchor_file" "$head_file")
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:][:punct:]]*$ ]] && continue
    grep -qxF -- "$line" "$base_file" && return 1
  done < <(diff_side - "$anchor_file" "$head_file")
  return 0
}

# Rewrites each entry of a package.json dependency section (dependencies,
# devDependencies, peerDependencies, optionalDependencies) in FILE... in place
# as "<section><TAB><name><TAB><range>". The line check then compares an entry
# within its own section and ignores its indentation and trailing comma, so a
# removed range that another section repeats still counts as gone. Expects one
# entry per line, as npm and bun write the file; other lines are left as is.
qualify_dependency_entries() {
  # shellcheck disable=SC2016  # perl variables, not shell expansions
  perl -i -ne '
    if (/^\s*"(dependencies|devDependencies|peerDependencies|optionalDependencies)"\s*:\s*\{\s*$/) { $s = $1 }
    elsif (defined $s && /^\s*\}/) { undef $s }
    elsif (defined $s && /^\s*"([^"]+)"\s*:\s*"([^"]*)"\s*,?\s*$/) { $_ = "$s\t$1\t$2\n" }
    print;
    undef $s if eof;
  ' "$@"
}

# Returns 0 when BASE_FILE covers the qualified dependency LINE: base declares
# the same package in the same section at a range whose lower bound is the same
# as or newer than the line's. Only a bare version or one led by ^, ~, >=, or =
# has a lower bound here; any other range (a URL, a tag, a workspace or
# compound range) is never covered.
dependency_covered() {
  local line="$1" base_file="$2" section name range want base_range
  local entry=$'^(dependencies|devDependencies|peerDependencies|optionalDependencies)\t([^\t]+)\t(.+)$'
  local floor='^(\^|~|>=|=)?([0-9]+(\.[0-9]+)*)$'
  [[ "$line" =~ $entry ]] || return 1
  section="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}" range="${BASH_REMATCH[3]}"
  [[ "$range" =~ $floor ]] || return 1
  want="${BASH_REMATCH[2]}"
  base_range=$(awk -F'\t' -v s="$section" -v n="$name" '$1 == s && $2 == n { print $3; exit }' "$base_file")
  [[ "$base_range" =~ $floor ]] || return 1
  version_at_least "${BASH_REMATCH[2]}" "$want"
}

# Returns 0 when dotted version A is the same as or newer than dotted version
# B, comparing component by component as numbers (a missing component is 0).
version_at_least() {
  local -a a b
  local i
  IFS=. read -ra a <<<"$1"
  IFS=. read -ra b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    ((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
    ((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
  done
  return 0
}

gate_head_commits() {
  header "Commits on $HEAD_REF since $ANCHOR_HOW"
  local commits files path verdict touched_by
  local -a flagged=()
  commits=$(git log --format='%h %s' "$ANCHOR..$HEAD_REF")
  if [[ -z "$commits" ]]; then
    gate_pass "no commits on $HEAD_REF since the anchor"
    return
  fi
  printf '%s\n' "$commits" | sed 's/^/    /'
  files=$(git diff --name-only "$ANCHOR" "$HEAD_REF" | grep -vE "$LOCKFILE_PATTERN" || true)
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -n "$(blob_at "$HEAD_REF" "$path")" ]] || continue # deleted on head; reviewed by hand
    verdict=$(classify_file "$path")
    [[ "$verdict" == contained ]] || flagged+=("$verdict $path")
  done <<<"$files"
  if [[ ${#flagged[@]} -eq 0 ]]; then
    gate_pass "$BASE_REF already contains every change those commits made"
    return
  fi
  gate_fail "changes on $HEAD_REF that $BASE_REF does not contain" "${#flagged[@]} files"
  for path in "${flagged[@]}"; do
    touched_by=$(git log --format=%h "$ANCHOR..$HEAD_REF" -- "${path#* }" | paste -sd, -)
    printf '    %-9s %s  (head commits %s)\n' "${path%% *}" "${path#* }" "$touched_by"
  done
}

# Gate 2: .github/ must match ------------------------------------------------

gate_github_dir() {
  header ".github/ parity"
  local paths path verdict count
  local -a flagged=()
  paths=$(git diff --name-only "$BASE_REF" "$HEAD_REF" -- .github/ || true)
  if [[ -z "$paths" ]]; then
    gate_pass ".github/ identical on $BASE_REF and $HEAD_REF"
    return
  fi
  count=$(printf '%s\n' "$paths" | wc -l | tr -d ' ')
  # Only the head-ahead direction is drift. Config that reached base and not
  # head is what the release delivers, and failing on it would turn this gate
  # red on every release that touches a workflow. `classify_file` is gate 1's
  # containment test: whether base already holds everything head changed.
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    # Absent on head: base-only, so head cannot be carrying anything here.
    [[ -n "$(blob_at "$HEAD_REF" "$path")" ]] || continue
    verdict=$(classify_file "$path")
    [[ "$verdict" == contained ]] || flagged+=("$verdict $path")
  done <<<"$paths"
  if [[ ${#flagged[@]} -eq 0 ]]; then
    gate_pass ".github/: $BASE_REF contains every change $HEAD_REF carries ($count paths the release delivers)"
    return
  fi
  gate_fail ".github/ on $HEAD_REF holds changes $BASE_REF never received" "${#flagged[@]} of $count paths"
  printf '%s\n' "${flagged[@]}" | sed 's/^/    /'
}

# Gate 3: lockfile resolution ------------------------------------------------

# Prints "key name version scope" per package entry in the lockfile PATH at
# REF. key is the entry's lockfile path (npm's `node_modules/a/node_modules/b`,
# Bun's `a/b`, a crate's name), which places a nested copy under the package
# that pulled it in. scope is dev/runtime for npm and crate for Cargo.
lockfile_entries() {
  local ref="$1" path="$2"
  case "$path" in
    *package-lock.json)
      git show "$ref:$path" | "$JQ_BIN" -r '.packages | to_entries[]
        | select(.key | contains("node_modules/"))
        | select(.value.version != null)
        | "\(.key) \(.key | sub(".*node_modules/"; "")) \(.value.version) \(if .value.dev then "dev" else "runtime" end)"'
      ;;
    *bun.lock)
      # Each entry is `key: ["name@version", ...]`; the first element carries
      # the resolved version. Everything is "dev" or "runtime" by workspace
      # section, which the entry does not record, so scope is unknown.
      # Bun writes trailing commas, which jq and jaq reject; strip them
      # before parsing.
      # shellcheck disable=SC2016
      git show "$ref:$path" | perl -0pe 's/,(\s*[}\]])/$1/g' | "$JQ_BIN" -r '.packages | to_entries[]
        | select(.value[0] | type == "string")
        | (.value[0] | capture("^(?<name>@?[^@]+)@(?<ver>[^@]+)$")) as $m
        | "\(.key) \($m.name) \($m.ver) pkg"'
      ;;
    *Cargo.lock)
      git show "$ref:$path" | awk -F'"' '
        /^name = /    { name = $2 }
        /^version = / { if (name != "") { print name " " name " " $2 " crate"; name = "" } }'
      ;;
  esac
}

# Prints "name version scope" per package for the lockfile PATH at REF,
# keeping only the highest resolved version per name. A spec that is not a
# version (file:, workspace:, link:, a git URL) has no order against a
# registry version and is left out. With PARENT_REF, a nested entry counts
# only when its parent's key exists in PARENT_REF's lockfile: a copy pulled in
# by a package that side no longer carries is nothing it could have received.
lockfile_versions() {
  local ref="$1" path="$2" parent_ref="${3:-}" tmp
  tmp=$(mktemp -d)
  : >"$tmp/keys"
  [[ -n "$parent_ref" ]] && lockfile_entries "$parent_ref" "$path" | cut -d' ' -f1 >"$tmp/keys"
  lockfile_entries "$ref" "$path" >"$tmp/entries"
  awk -v filter="${parent_ref:+1}" '
    FILENAME == ARGV[1] { have[$1] = 1; next }
    $3 !~ /^[0-9]/ { next }
    filter && length($1) > length($2) && substr($1, length($1) - length($2)) == "/" $2 {
      parent = substr($1, 1, length($1) - length($2) - 1)
      sub(/\/?node_modules$/, "", parent)
      if (parent != "" && !(parent in have)) next
    }
    { print $2, $3, $4 }' "$tmp/keys" "$tmp/entries" \
    | sort -k1,1 -k2,2V | awk '{ last[$1] = $0 } END { for (k in last) print last[k] }' | sort -k1,1
  rm -rf "$tmp"
}

# Runs the resolution comparison for one lockfile path.
compare_lockfile() {
  local path="$1"
  local head_newer=0 base_newer=0 head_lines="" name base_ver head_ver head_scope newest line
  if [[ -z "$(blob_at "$BASE_REF" "$path")" ]]; then
    gate_skip "$path" "not present on $BASE_REF"
    return
  fi
  if [[ "$path" != *Cargo.lock && -z "$JQ_BIN" ]]; then
    gate_skip "$path" "needs jq or jaq"
    return
  fi
  while read -r name base_ver _ head_ver head_scope; do
    [[ "$base_ver" == "$head_ver" ]] && continue
    newest=$(printf '%s\n%s\n' "$base_ver" "$head_ver" | sort -V | tail -1)
    if [[ "$newest" == "$head_ver" ]]; then
      head_newer=$((head_newer + 1))
      line=$(printf '    %-8s %-44s %s=%-14s %s=%s' "$head_scope" "$name" "$BASE_REF" "$base_ver" "$HEAD_REF" "$head_ver")
      head_lines+="$line"$'\n'
    else
      base_newer=$((base_newer + 1))
    fi
  done < <(join <(lockfile_versions "$BASE_REF" "$path") <(lockfile_versions "$HEAD_REF" "$path" "$BASE_REF"))
  if [[ $head_newer -eq 0 && $base_newer -eq 0 ]] \
    && [[ -z "$(lockfile_versions "$HEAD_REF" "$path" 2>/dev/null | head -1)" ]]; then
    gate_fail "$path" "parsed zero packages on $HEAD_REF; the lockfile format is not understood"
    return
  fi
  if [[ $head_newer -eq 0 ]]; then
    gate_pass "$path: nothing newer on $HEAD_REF ($base_newer packages newer on $BASE_REF, awaiting release)"
    return
  fi
  gate_fail "$path: $head_newer packages newer on $HEAD_REF" "$base_newer newer on $BASE_REF, awaiting release"
  printf '%s' "$head_lines"
}

gate_lockfiles() {
  header "Lockfile resolution"
  local paths path
  paths=$(git ls-tree -r --name-only "$HEAD_REF" | grep -E "$LOCKFILE_PATTERN" || true)
  if [[ -z "$paths" ]]; then
    gate_skip "lockfiles" "no package-lock.json, bun.lock, or Cargo.lock on $HEAD_REF"
    return
  fi
  while IFS= read -r path; do
    [[ -n "$path" ]] && compare_lockfile "$path"
  done <<<"$paths"
}

# Main -----------------------------------------------------------------------

main() {
  maybe_fetch
  require_ref "$BASE_REF"
  require_ref "$HEAD_REF"
  resolve_anchor
  gate_anchor_backported
  gate_head_commits
  gate_github_dir
  gate_lockfiles

  if [[ -n "$RESULT_FILE" ]]; then
    printf "%d %d %d\n" "$PASS_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" >"$RESULT_FILE"
  else
    print_summary
  fi
  [[ $FAIL_COUNT -eq 0 ]] || exit 1
}

main "$@"
