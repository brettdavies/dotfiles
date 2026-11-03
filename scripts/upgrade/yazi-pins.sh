#!/usr/bin/env bash
# Moves the yazi plugin and flavor pins in stow/yazi/dot-config/yazi/package.toml to each upstream repo's newest
# commit past the seven-day gate, proves them in a running yazi, and lands them through a squash-merged PR. The brew
# job runs it on the Linux server whenever the installed yazi differs from the version the pins were last proven on.
#
# Usage: scripts/upgrade/yazi-pins.sh [--base BRANCH] [--repo URL] [--gh-repo OWNER/NAME] [--checkout PATH]
#   --base      branch the bump starts from and merges into (default dev)
#   --repo      git URL to clone (default: this checkout's origin)
#   --gh-repo   GitHub repository for the PR (default: parsed from --repo)
#   --checkout  host checkout to fast-forward after a merge (default ~/dotfiles; "" skips the pull)
#
# Progress goes to stderr; the last stdout line is the outcome object run-log.sh records as yazi_pins.
# Exit codes: 0 bumped or not-needed, 75 waiting, 1 failed, 2 usage.
# Env: YAZI_PINS_STATE_DIR, YAZI_PINS_CHECK_CMD, YAZI_PINS_CI_TIMEOUT, YAZI_PINS_POLL_S, YAZI_PINS_NOW (epoch
# seconds), YAZI_CHECK_TIMEOUT. BOOTSTRAP.md#yazi-plugin-pins lists the outcomes and reasons.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/run-log.sh
. "$here/lib/run-log.sh"
# shellcheck source=lib/yazi-check.sh
. "$here/lib/yazi-check.sh"
# shellcheck source=lib/yazi-pins-lib.sh
. "$here/lib/yazi-pins-lib.sh"

DOCS=https://github.com/brettdavies/dotfiles/blob/main/BOOTSTRAP.md#yazi-plugin-pins
PKG_PATH=stow/yazi/dot-config/yazi/package.toml
SELF="$here/yazi-pins.sh"

usage() {
  sed -n '6,13p' "$SELF" | sed 's/^# \{0,1\}//' >&2
  echo "ERROR: $1" >&2
  exit 2
}

base=dev
repo=$(git -C "$here/../.." remote get-url origin 2>/dev/null || true)
gh_repo=
checkout=$HOME/dotfiles
while [ $# -gt 0 ]; do
  case $1 in
    --base | --repo | --gh-repo | --checkout)
      [ $# -ge 2 ] || usage "$1 needs a value"
      case $1 in
        --base) base=$2 ;;
        --repo) repo=$2 ;;
        --gh-repo) gh_repo=$2 ;;
        --checkout) checkout=$2 ;;
      esac
      shift 2
      ;;
    -h | --help)
      sed -n '6,13p' "$SELF" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$repo" ] || usage "no --repo given and this checkout has no origin"
[ -n "$gh_repo" ] || gh_repo=$(sed -E 's#^.*github\.com[:/]##; s#\.git$##' <<<"$repo")

export GIT_TERMINAL_PROMPT=0 GH_PROMPT_DISABLED=1 GIT_EDITOR=true GIT_SSH_COMMAND="ssh -o BatchMode=yes"
state_dir=${YAZI_PINS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles}
pr_file=$state_dir/yazi-pins-pr
capture=$state_dir/yazi-pins-check.txt
mkdir -p "$state_dir"
YAZI_VERSION=$(yazi --version 2>/dev/null | awk '/Version:/ { print $2; exit }' || true)
work=$(mktemp -d "${TMPDIR:-/tmp}/yazi-pins.XXXXXX")
trap 'tmux -L "yazi-pins-check-$$" kill-server 2>/dev/null || true; rm -rf "$work"' EXIT

now=${YAZI_PINS_NOW:-$(date +%s)}
cutoff=$(yazi_pins_iso $((now - YAZI_PINS_GATE_S)))

# Usage: emit <outcome> <reason> <message> <value> <pr> <host-json> <action> <command>
# Prints the outcome object and exits with the outcome's code. bumped and not-needed stamp the yazi version the pins
# are now proven on, which is what keeps the brew job from running the bump again for it.
emit() {
  local code=1 value=null pr=null cmd=null docs=null
  case $1 in
    bumped | not-needed)
      code=0
      printf '%s\n' "$YAZI_VERSION" >"$state_dir/yazi-pins-proven"
      ;;
    waiting) code=75 ;;
  esac
  [ -z "$4" ] || value=$(_run_log_str "$4")
  [ -z "$5" ] || pr=$(_run_log_str "$5")
  if [ "$7" != none ]; then
    cmd=$(_run_log_str "$8")
    docs="\"$DOCS\""
  fi
  echo "yazi-pins: $1 ($2): $3" >&2
  printf '{"outcome":"%s","reason":"%s","exit_code":%s,"message":%s,"value":%s,"yazi_version":%s,"pr":%s,"host_update":%s,"next_step":{"action":"%s","command":%s,"docs":%s}}\n' \
    "$1" "$2" "$code" "$(_run_log_str "$3")" "$value" "$(_run_log_str "$YAZI_VERSION")" "$pr" "${6:-null}" \
    "$7" "$cmd" "$docs"
  exit "$code"
}
[ -n "$YAZI_VERSION" ] || emit failed check-failed "yazi --version printed no version" "" "" null rerun "$SELF"

# Fast-forwards the host checkout when it sits on the base branch, then installs what it now pins over the old pins'
# files (--discard, for the reason yazi_pkg_install in lib/yazi.sh gives); git refuses on its own when a local edit
# would be overwritten. Prints the host_update object.
pull_host() {
  local branch out action=pulled reason=ok msg="fast-forwarded and installed the new pins"
  if [ -z "$checkout" ] || ! git -C "$checkout" rev-parse --git-dir >/dev/null 2>&1; then
    action=skipped reason=no-checkout msg="no git checkout at ${checkout:-(none)}"
  elif branch=$(git -C "$checkout" symbolic-ref --short -q HEAD || true) && [ "$branch" != "$base" ]; then
    action=skipped reason=not-on-base msg="checkout is on ${branch:-a detached HEAD}, not $base"
  elif ! out=$(git -C "$checkout" pull --ff-only -q 2>&1); then
    action=failed reason=pull-failed msg=$(tr '\n' ' ' <<<"$out")
  elif ! out=$(ya pkg install --discard 2>&1); then
    action=failed reason=install-failed msg=$(tail -n 3 <<<"$out" | tr '\n' ' ')
  fi
  printf '{"action":"%s","reason":"%s","checkout":%s,"message":%s}' \
    "$action" "$reason" "$(_run_log_str "$checkout")" "$(_run_log_str "$msg")"
}

# Waits on the PR's checks, merges the head they passed on, and pulls the host checkout.
land() { # <pr-url> <head-sha>
  local head rc=0 host
  head=$(yazi_pins_wait_ci "$1" "$2" "$gh_repo") || rc=$?
  case $rc in
    1) emit failed ci-failed "checks failed, or something other than this job moved the head, on $1" "" "$1" null \
      inspect-pr "gh pr checks $1" ;;
    2) emit failed ci-timeout "checks still running on $1 after ${YAZI_PINS_CI_TIMEOUT:-1800} s; the next run resumes it" \
      "" "$1" null inspect-pr "gh pr checks $1" ;;
  esac
  gh pr merge "$1" -R "$gh_repo" --squash --delete-branch --match-head-commit "$head" >&2 \
    || emit failed merge-failed "gh pr merge refused $1" "$head" "$1" null inspect-pr "gh pr view $1"
  [ "$(gh pr view "$1" -R "$gh_repo" --json state --jq .state)" = MERGED ] \
    || emit failed merge-failed "$1 is not merged after gh pr merge" "$head" "$1" null inspect-pr "gh pr view $1"
  rm -f "$pr_file"
  host=$(pull_host)
  if [[ "$host" == '{"action":"pulled"'* ]]; then
    emit bumped pr-merged "merged $1" "" "$1" "$host" none ""
  fi
  emit bumped pr-merged "merged $1; this host still installs the old pins until its checkout is pulled" "" "$1" \
    "$host" pull "git -C ${checkout:-~/dotfiles} pull --ff-only && ya pkg install --discard"
}

# Installs <package.toml lines> into a fresh scratch HOME holding the clone's yazi config and checks it there.
# Prints the verdict; the captures land in <home>/check-out.
try_pins() { # <home> <"kind|use|rev|hash" lines>
  mkdir -p "$1/.config/yazi"
  cp "$work/clone/stow/yazi/dot-config/yazi/"* "$1/.config/yazi/"
  printf '%s' "$2" | yazi_pins_write "$1/.config/yazi/package.toml"
  yazi_pins_install "$1" >&2 || return 3
  ${YAZI_PINS_CHECK_CMD:-yazi_check} "$1" "$1/check-out" || true
}

save_capture() { # <home>
  cat "$1/check-out/listing.txt" "$1/check-out/preview.txt" "$1/check-out/tasks.txt" >"$capture" 2>/dev/null || true
}

# A PR this job opened is resumed when it was proven on the installed yazi, and replaced when it was not; any other
# open bump PR stops the run.
open=$(gh pr list -R "$gh_repo" --state open --base "$base" --json url,headRefName,headRefOid \
  --jq '.[] | select(.headRefName | startswith("fix/yazi-pins-")) | "\(.url) \(.headRefName) \(.headRefOid)"') \
  || emit failed gh-failed "gh pr list failed for $gh_repo" "" "" null rerun "$SELF"
if [ -n "$open" ]; then
  read -r url name head <<<"$open"
  [ "$(cat "$pr_file" 2>/dev/null)" = "$url $head" ] \
    || emit failed pr-open "an open bump PR this job did not push, or whose head moved: $url" "$head" "$url" null \
      inspect-pr "gh pr view $url"
  proven=${name#fix/yazi-pins-}
  if [ "${proven%-*}" = "$YAZI_VERSION" ]; then
    land "$url" "$head"
  fi
  echo "yazi-pins: closing $url, proven on yazi ${proven%-*}, not $YAZI_VERSION" >&2
  gh pr close "$url" -R "$gh_repo" --delete-branch >&2 \
    || emit failed gh-failed "gh pr close failed for $url" "" "$url" null inspect-pr "gh pr view $url"
  rm -f "$pr_file"
fi

echo "yazi-pins: cloning $repo at $base" >&2
git clone -q --branch "$base" --single-branch "$repo" "$work/clone" >&2 \
  || emit failed git-failed "git clone of $repo at $base failed" "" "" null rerun "$SELF"
pkg=$work/clone/$PKG_PATH
current=$(yazi_pins_parse "$pkg")

candidates='' seen=''
while IFS='|' read -r kind use rev hash; do
  up=${use%%:*}
  cand=$(awk -v r="$up" '$1 == r { print $2 }' <<<"$seen")
  if [ -z "$cand" ]; then
    cand=$(yazi_pins_candidate "$up" "$cutoff") \
      || emit failed upstream-unreachable "no revision of $up reached its branch by $cutoff" "$up" "" null rerun "$SELF"
    seen+="$up $cand"$'\n'
  fi
  keep=0
  yazi_pins_keep_current "$up" "$cand" "$rev" || keep=$?
  [ "$keep" != 2 ] || emit failed upstream-unreachable "cannot compare $cand with $rev in $up" "$up" "" null rerun "$SELF"
  [ "$keep" = 0 ] || rev=$cand
  candidates+="$kind|$use|$rev|"$'\n'
done <<<"$current"

echo "yazi-pins: installing and checking the candidates in yazi $YAZI_VERSION" >&2
verdict=$(try_pins "$work/candidate" "$candidates") \
  || emit failed hash-failed "ya pkg install of the candidates failed" "$(tr '\n' ' ' <<<"$candidates")" "" null rerun "$SELF"
save_capture "$work/candidate"
changes=''
while IFS='|' read -r kind use rev hash; do
  old=$(grep "^$kind|$use|" <<<"$current" || true)
  [ "${old##*|}" = "$hash" ] || changes+="$use ${old#*|*|} -> $rev $hash; "
done < <(yazi_pins_parse "$work/candidate/.config/yazi/package.toml")

if [ "$verdict" != ok ] && [ -n "$changes" ]; then
  echo "yazi-pins: candidates failed ($verdict); checking the current pins" >&2
  current_verdict=$(try_pins "$work/current" "$current") || current_verdict=install-failed
  if [ "$current_verdict" = ok ]; then
    emit not-needed up-to-date "the current pins work in yazi $YAZI_VERSION; the candidates failed the check" \
      "rejected: $changes($verdict)" "" null none ""
  fi
  save_capture "$work/current"
fi
if [ "$verdict" != ok ]; then
  newer=''
  while IFS='|' read -r kind use rev hash; do
    n=$(gh api "repos/${use%%:*}/commits?path=${use#*:}.yazi&since=$cutoff&per_page=1" --jq length 2>/dev/null || echo 0)
    [ "$n" = 0 ] || newer+="${use#*:} "
  done <<<"$current"
  if [ -n "$newer" ]; then
    emit waiting cooldown "check: $verdict; ${newer}changed upstream since $cutoff, and the job retries daily" \
      "$verdict; pane $capture" "" null rerun "$SELF"
  fi
  emit failed check-failed "check: $verdict, and no pinned plugin changed upstream since $cutoff" \
    "$verdict; pane $capture" "" null rerun "$SELF"
fi
[ -n "$changes" ] || emit not-needed up-to-date "the pinned plugins work in yazi $YAZI_VERSION" "" "" null none ""

branch="fix/yazi-pins-$YAZI_VERSION-$(yazi_pins_iso "$now" | cut -c1-10 | tr -d -)"
cp "$work/candidate/.config/yazi/package.toml" "$pkg"
# shellcheck source=lib/yazi-pins-pr.sh
. "$here/lib/yazi-pins-pr.sh"
yazi_pins_messages "$work" "$changes"
{
  git -C "$work/clone" switch -q -c "$branch" \
    && git -C "$work/clone" add "$PKG_PATH" \
    && git -C "$work/clone" commit -q --file "$work/commit-msg" \
    && git -C "$work/clone" push -q origin "$branch"
} >&2 || emit failed git-failed "committing or pushing $branch failed" "$changes" "" null rerun "$SELF"
sha=$(git -C "$work/clone" rev-parse HEAD)
url=$(gh pr create -R "$gh_repo" --base "$base" --head "$branch" --title "$(head -n 1 "$work/commit-msg")" \
  --body-file "$work/pr-body") || emit failed gh-failed "gh pr create failed for $branch" "$changes" "" null rerun "$SELF"
echo "$url $sha" >"$pr_file"
land "$url" "$sha"
