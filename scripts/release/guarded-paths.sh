#!/usr/bin/env bash
# Emits one ERE matching every path that must never reach `main`, for `grep -E`.
#
# `guard-main-docs` rejects two sets on a PR to main: a base list hardcoded in
# the reusable workflow, and this repo's `extra_paths` in
# .github/workflows/guard-main-docs.yml. Every local screen that kept its own
# copy of that union drifted from the workflow, because nothing tied the copies
# to the source: a path the workflow guards but a copy omits passes the local
# check and reaches an open release with a green `guard-docs`.
#
# The `extra_paths` half is read from the workflow here, so registering a path
# there is the only edit a new guarded path needs. The value is the inline
# quoted form the reusable documents, `extra_paths: 'a/,b.md,**/.agent/'`.
# Entries are globs with the reusable's rules: `*` and `?` stay within one
# segment, `**/` spans any number of directories, a trailing `/` guards the
# directory and everything under it, and an entry without glob characters is
# a prefix (trailing slash) or an exact path. Keep this translation and the
# reusable's `globToRegExp` in step; they must agree on what is guarded.
#
# Usage:
#   GUARDED="$(scripts/release/guarded-paths.sh)"
#   git diff origin/main..HEAD --name-only | grep -E "$GUARDED"
#
# Exit 1 when nothing resolves, so a missing workflow cannot pass as "clean".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORKFLOW="$REPO_ROOT/.github/workflows/guard-main-docs.yml"

# Hardcoded in brettdavies/.github/.github/workflows/guard-main-docs.yml, which
# is a different repo and cannot be read from here. This is the one list that
# still needs a manual edit when the reusable changes.
REUSABLE_BASE=(
  'docs/architecture/'
  'docs/brainstorms/'
  'docs/ideation/'
  'docs/plans/'
  'docs/research/'
  'docs/reviews/'
  'docs/solutions/'
)

# Gitignored, so it cannot be committed by accident. Screened anyway: `git add
# -f` defeats the ignore, and the cost of catching that here is one array entry.
LOCAL_ONLY=('.context/')

# Prints the workflow's `extra_paths` value one path per line:
# `extra_paths: 'a/,b.md'` (single or double quotes) -> a/ and b.md.
read_extra_paths() {
  [[ -f "$WORKFLOW" ]] || return 0
  sed -n "s/^[[:space:]]*extra_paths:[[:space:]]*['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}[[:space:]]*\$/\1/p" "$WORKFLOW" \
    | tr ',' '\n'
}

# Converts one entry to an anchored ERE fragment. Metacharacters other than
# the glob ones are escaped, so `.vale.ini` cannot also match `Xvale!ini`.
glob_to_ere() {
  local glob="$1" re="" i c n
  n=${#glob}
  for ((i = 0; i < n; i++)); do
    c=${glob:i:1}
    case "$c" in
      '*')
        if [[ "${glob:i+1:1}" == '*' ]]; then
          i=$((i + 1))
          if [[ "${glob:i+1:1}" == '/' ]]; then
            i=$((i + 1))
            re+='(.*/)?'
          else
            re+='.*'
          fi
        else
          re+='[^/]*'
        fi
        ;;
      '?') re+='[^/]' ;;
      '.' | '^' | '$' | '+' | '(' | ')' | '{' | '}' | '|' | '[' | ']' | "\\") re+="\\$c" ;;
      *) re+="$c" ;;
    esac
  done
  # A trailing slash means "this directory and everything under it"; anything
  # else must match the whole path, so a file never matches a longer sibling.
  if [[ "$glob" == */ ]]; then
    printf '^%s' "$re"
  else
    printf '^%s$' "$re"
  fi
}

frags=()
declare -A seen=()
while IFS= read -r path; do
  path="${path#"${path%%[![:space:]]*}"}"
  path="${path%"${path##*[![:space:]]}"}"
  [[ -n "$path" ]] || continue
  # `extra_paths` may repeat a path the reusable's base already covers.
  [[ -n "${seen[$path]:-}" ]] && continue
  seen[$path]=1
  frags+=("$(glob_to_ere "$path")")
done < <(
  printf '%s\n' "${REUSABLE_BASE[@]}" "${LOCAL_ONLY[@]}"
  read_extra_paths
)

if [[ ${#frags[@]} -eq 0 ]]; then
  echo "guarded-paths: no guarded paths resolved (is $WORKFLOW present?)" >&2
  exit 1
fi

printf '(%s)\n' "$(
  IFS='|'
  echo "${frags[*]}"
)"
