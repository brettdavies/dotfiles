# shellcheck shell=bash
# Helpers for scripts/upgrade/yazi-pins.sh: reading package.toml, choosing upstream revs past the supply-chain gate,
# installing them into a scratch HOME, and landing the PR.

# The gate measures how long a commit has been on the upstream branch by GitHub's own push time (the repository
# activity API), not by commit dates, which whoever pushes the commit sets.
# shellcheck disable=SC2034 # read by yazi-pins.sh
YAZI_PINS_GATE_S=$((7 * 24 * 3600))

# Usage: yazi_pins_parse <package.toml>
# Prints one "kind|use|rev|hash" line per dep, kind plugin or flavor, in file order.
yazi_pins_parse() {
  awk '
    function val(s) { sub(/^[^=]*= *"/, "", s); sub(/".*$/, "", s); return s }
    /^\[\[plugin\.deps\]\]/ { kind = "plugin"; next }
    /^\[\[flavor\.deps\]\]/ { kind = "flavor"; next }
    /^use *=/ { use = val($0) }
    /^rev *=/ { rev = val($0) }
    /^hash *=/ { print kind "|" use "|" rev "|" val($0) }
  ' "$1"
}

# Usage: yazi_pins_write <package.toml> < "kind|use|rev|hash" lines
# Writes the deps in ya's own layout, plugins before flavors.
yazi_pins_write() {
  local lines kind use rev hash first=1 want
  lines=$(cat)
  : >"$1"
  for want in plugin flavor; do
    while IFS='|' read -r kind use rev hash; do
      [ "$kind" = "$want" ] || continue
      [ "$first" = 1 ] || echo >>"$1"
      first=0
      printf '[[%s.deps]]\nuse = "%s"\nrev = "%s"\nhash = "%s"\n' "$kind" "$use" "$rev" "$hash" >>"$1"
    done <<<"$lines"
  done
}

# Usage: yazi_pins_iso <epoch-seconds>
yazi_pins_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# Usage: yazi_pins_candidate <owner/repo> <cutoff-iso>
# Prints the short after-SHA of the newest push, force push, or merge at or before the cutoff that is still on the
# default branch; a commit a later force push removed is skipped.
yazi_pins_candidate() {
  local repo=$1 cutoff=$2 branch entries ts sha status
  branch=$(gh api "repos/$repo" --jq .default_branch) || return 1
  entries=$(gh api "repos/$repo/activity?ref=refs/heads/$branch&per_page=100" \
    --jq '.[] | select(.activity_type | IN("push", "force_push", "pr_merge", "merge_queue_merge")) | "\(.timestamp) \(.after)"') \
    || return 1
  while read -r ts sha; do
    [ -n "$sha" ] || continue
    [[ "$ts" > "$cutoff" ]] && continue
    status=$(gh api "repos/$repo/compare/$sha...$branch" --jq .status) || return 1
    case $status in
      ahead | identical)
        echo "${sha:0:7}"
        return 0
        ;;
    esac
  done <<<"$entries"
  return 1
}

# Usage: yazi_pins_keep_current <owner/repo> <candidate> <current>
# Returns 0 when the current rev already contains the candidate, so a pin never moves backwards; 1 when the candidate
# is newer or the current rev is no longer on the branch; 2 when the API call fails.
yazi_pins_keep_current() {
  local status
  [ "$2" != "$3" ] || return 0
  status=$(gh api "repos/$1/compare/$2...$3" --jq .status) || return 2
  case $status in
    ahead | identical) return 0 ;;
    *) return 1 ;;
  esac
}

# Usage: yazi_pins_install <home>
# Runs ya pkg install for <home>/.config/yazi with nothing of the caller's environment but PATH, so the clone, the
# config, and the cache all stay inside <home>.
yazi_pins_install() {
  env -i HOME="$1" PATH="$PATH" XDG_CACHE_HOME="$1/.cache" GIT_TERMINAL_PROMPT=0 ya pkg install
}

# Usage: yazi_pins_ci_state <pr>
# Prints "<green | red | behind | pending> <head-sha>". Green needs every check SUCCESS, SKIPPED, or NEUTRAL and a
# CLEAN merge state, which also covers the base branch's required checks; behind means the base moved and its
# ruleset requires an up-to-date branch.
yazi_pins_ci_state() {
  # shellcheck disable=SC2016 # a jq program, not shell
  gh pr view "$1" --json headRefOid,mergeStateStatus,statusCheckRollup --jq '
    def st: if .__typename == "CheckRun" then (if .status == "COMPLETED" then .conclusion else .status end) else .state end;
    [.statusCheckRollup[] | st] as $s
    | (if any($s[]; IN("FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "CANCELLED")) then "red"
       elif .mergeStateStatus == "BEHIND" then "behind"
       elif ($s | length) > 0 and all($s[]; IN("SUCCESS", "SKIPPED", "NEUTRAL")) and .mergeStateStatus == "CLEAN" then "green"
       else "pending" end) + " " + .headRefOid'
}

# Usage: yazi_pins_wait_ci <pr> <sha> <owner/repo>
# Polls until the PR's checks pass, then prints the head they passed on and returns 0; returns 1 when they fail or
# the head moves to anything but this function's own update, and 2 after YAZI_PINS_CI_TIMEOUT seconds. A branch
# behind its base is updated through GitHub, whose merge commit must have <sha> as a parent before it is trusted.
yazi_pins_wait_ci() {
  local pr=$1 want=$2 repo=$3 deadline=$((SECONDS + ${YAZI_PINS_CI_TIMEOUT:-1800})) state head
  while :; do
    read -r state head < <(yazi_pins_ci_state "$pr" || echo "pending -")
    if [ "$head" != - ] && [ "$head" != "$want" ]; then
      return 1
    fi
    case $state in
      green)
        echo "$want"
        return 0
        ;;
      red) return 1 ;;
      behind)
        gh pr update-branch "$pr" >&2 || return 1
        read -r state head < <(yazi_pins_ci_state "$pr" || echo "pending -")
        gh api "repos/$repo/commits/$head" --jq "[.parents[].sha] | index(\"$want\") != null" | grep -qx true \
          || return 1
        want=$head
        ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] || return 2
    sleep "${YAZI_PINS_POLL_S:-20}"
  done
}
