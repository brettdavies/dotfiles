# shellcheck shell=bash
# Proves a yazi config's plugins in a running yazi: a private tmux server opens yazi over a throwaway git repo holding
# an untracked file and a Markdown file, and the screen must show git.yazi's sign for the untracked file, no pending
# fetchers, no failed task, and the Markdown file previewed through piper and glow. A fetcher that does not fit the
# running yazi's API fails as "Run fetcher 'git' ... Failed" in the task view and keeps an "N left" counter in the
# status bar, while git.yazi still paints signs before its result is rejected. glow renders a level-one heading
# without its "#", which a plain-text fallback preview keeps.

# Usage: yazi_check_verdict <listing-capture> <preview-capture> <task-view-capture>
# Prints ok, failed-fetchers, pending-fetchers, no-git-sign, or no-preview.
yazi_check_verdict() {
  if grep -q 'Failed' "$3"; then
    echo failed-fetchers
  elif grep -Eq '[0-9]+ left' "$1" "$3"; then
    echo pending-fetchers
  elif ! grep -Eq 'untracked\.txt +\?' "$1"; then
    echo no-git-sign
  elif ! grep -q 'Pin check' "$2" || grep -q '# Pin check' "$2"; then
    echo no-preview
  else
    echo ok
  fi
}

_yazi_check_repo() { # <dir>
  local g=(git -C "$1" -c user.name=yazi-pins -c user.email=yazi-pins@localhost -c commit.gpgsign=false)
  mkdir -p "$1" && git init -q "$1" \
    && printf 'tracked\n' >"$1/tracked.txt" && "${g[@]}" add tracked.txt && "${g[@]}" commit -q -m seed \
    && printf 'untracked\n' >"$1/untracked.txt" \
    && printf '# Pin check\n\npiper rendered this line.\n' >"$1/pin-check.md"
}

_yazi_check_wait() { # <sock> <capture-file> <grep -E pattern that must match> [<pattern that must not>]
  local deadline=$((SECONDS + ${YAZI_CHECK_TIMEOUT:-20}))
  while [ "$SECONDS" -lt "$deadline" ]; do
    tmux -L "$1" capture-pane -p -t check >"$2" 2>/dev/null || return 1
    if grep -Eq "$3" "$2" && { [ -z "${4:-}" ] || ! grep -Eq "$4" "$2"; }; then
      return 0
    fi
    sleep 0.5
  done
}

# Usage: yazi_check <home> <out-dir>
# Runs yazi under <home> (its .config/yazi holds the config and installed packages) and writes listing.txt,
# preview.txt, and tasks.txt to <out-dir>. Prints the verdict and returns 0 only for ok. YAZI_CHECK_TIMEOUT (seconds,
# default 20) bounds each wait for the screen to settle.
yazi_check() {
  local home=$1 out=$2 sock="yazi-pins-check-$$" cmd verdict
  mkdir -p "$out"
  if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 _yazi_check_repo "$home/check-repo" >&2; then
    echo repo-failed
    return 1
  fi
  printf -v cmd 'env -i HOME=%q PATH=%q TERM=tmux-256color XDG_CACHE_HOME=%q yazi %q' \
    "$home" "$PATH" "$home/.cache" "$home/check-repo"
  tmux -L "$sock" -f /dev/null new-session -d -s check -x 150 -y 16 "$cmd" || {
    echo tmux-failed
    return 1
  }
  _yazi_check_wait "$sock" "$out/listing.txt" 'untracked\.txt +\?' '[0-9]+ left'
  # The listing starts on .git; the next row is pin-check.md.
  tmux -L "$sock" send-keys -t check j 2>/dev/null
  _yazi_check_wait "$sock" "$out/preview.txt" 'piper rendered this line'
  tmux -L "$sock" send-keys -t check w 2>/dev/null
  sleep 1
  tmux -L "$sock" capture-pane -p -t check >"$out/tasks.txt" 2>/dev/null
  tmux -L "$sock" kill-server 2>/dev/null
  verdict=$(yazi_check_verdict "$out/listing.txt" "$out/preview.txt" "$out/tasks.txt")
  echo "$verdict"
  [ "$verdict" = ok ]
}
