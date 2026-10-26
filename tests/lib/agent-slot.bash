# shellcheck shell=bash
# Fixtures for the agent-slot suites. Each test gets its own slot root, dev root, and state directory under
# BATS_TEST_TMPDIR, reached through agent-slot's AGENT_SLOT_* overrides; tmux, claude, gh, git-crypt, trash, and
# systemctl are stubs that record their argv. git is real, with GIT_CONFIG_GLOBAL pointing at a test config, so no
# fixture repo inherits the host's signing or URL rewrites.

# shellcheck disable=SC2034 # the suites that load this file run it
AGENT_SLOT="$BATS_TEST_DIRNAME/../scripts/agent-slot/agent-slot"

agent_slot_setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
  T=$BATS_TEST_TMPDIR
  STUBS=$T/stubs
  CALLS=$T/calls.log
  mkdir -p "$STUBS" "$T/dev" "$T/state" "$T/solutions"
  : >"$CALLS"
  export CALLS STUBS

  export GIT_CONFIG_GLOBAL=$T/gitconfig
  git config --file "$GIT_CONFIG_GLOBAL" user.email test@example.com
  git config --file "$GIT_CONFIG_GLOBAL" user.name Test
  git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  export AGENT_SLOT_ROOT=$T/slots
  export AGENT_SLOT_DEV=$T/dev
  export AGENT_SLOT_EXTRA_PRIMES=
  export AGENT_SLOT_STATE_DIR=$T/state
  export AGENT_SLOT_TMUX_SOCKET=agent-slot-test
  export AGENT_SLOT_TMUX_CONF=$T/slots.conf
  export AGENT_SLOT_SOLUTIONS=$T/solutions
  export AGENT_SLOT_GIT_CRYPT_KEY=$T/git-crypt.key
  export AGENT_SLOT_CLAUDE_STATE=$T/claude.json
  : >"$AGENT_SLOT_TMUX_CONF"
  : >"$AGENT_SLOT_GIT_CRYPT_KEY"
  printf '{"projects":{}}\n' >"$AGENT_SLOT_CLAUDE_STATE"

  # tmux keeps each socket's sessions in a file: no file means no server. capture-pane prints $STUBS/screen. On any
  # socket but the slot one (the trust step's), Down swaps in $STUBS/screen-down and Enter $STUBS/screen-after when
  # they exist; with $STUBS/drop-first-down present, the first Down is lost, as a key sent before the dialog listens.
  stub tmux '
sock=default
while (($#)); do
  case $1 in
    -L | -S) sock=${2##*/}; shift 2 ;;
    -f) shift 2 ;;
    *) break ;;
  esac
done
cmd=$1
shift
sessions=$STUBS/tmux-sessions
[ "$sock" = agent-slot-test ] || sessions=$STUBS/tmux-sessions-$sock
target="" name="" last=""
while (($#)); do
  case $1 in
    -t) target=${2#=}; target=${target%:}; shift ;;
    -s) name=$2; shift ;;
  esac
  last=$1
  shift
done
case $cmd in
  list-sessions)
    [ -f "$sessions" ] || { echo "no server running on /tmp/tmux-test/$sock" >&2; exit 1; }
    cat "$sessions" ;;
  new-session) echo "$name" >>"$sessions" ;;
  kill-session)
    [ -f "$sessions" ] || exit 1
    grep -vxF "$target" "$sessions" >"$sessions.new" || true
    cat "$sessions.new" >"$sessions" ;;
  list-panes) cat "$STUBS/tmux-panes" 2>/dev/null || true ;;
  capture-pane) cat "$STUBS/screen" 2>/dev/null || true ;;
  send-keys)
    if [ "$sock" = agent-slot-test ]; then
      [ "$last" = Enter ] || printf "%s" "$last" >"$STUBS/typed-$target"
    elif [ "$last" = Down ] && [ -f "$STUBS/screen-down" ]; then
      if [ -f "$STUBS/drop-first-down" ]; then
        rm "$STUBS/drop-first-down"
      else
        cp "$STUBS/screen-down" "$STUBS/screen"
      fi
    elif [ "$last" = Enter ] && [ -f "$STUBS/screen-after" ]; then
      cp "$STUBS/screen-after" "$STUBS/screen"
    fi ;;
esac'
  stub claude '
case "$*" in
  "agents --json") cat "$STUBS/claude-agents.json" 2>/dev/null || echo "[]" ;;
  --version) echo "${CLAUDE_STUB_VERSION:-2.1.310} (Claude Code)" ;;
esac'
  stub gh 'exit 0'
  stub git-crypt 'exit 0'
  stub trash 'mkdir -p "$STUBS/trashed"; for p in "$@"; do cp -a "$p" "$STUBS/trashed/" && chmod -R u+w "$p" && find "$p" -delete; done'
  stub systemctl 'echo enabled'
  export AGENT_SLOT_TMUX=$STUBS/tmux AGENT_SLOT_CLAUDE=$STUBS/claude AGENT_SLOT_GH=$STUBS/gh
  export AGENT_SLOT_GIT_CRYPT=$STUBS/git-crypt AGENT_SLOT_TRASH=$STUBS/trash AGENT_SLOT_SYSTEMCTL=$STUBS/systemctl
}

# stub NAME BODY: an executable that appends "NAME argv" to the calls log, then runs BODY with STUBS and CALLS set.
# Both paths are written into the stub, because agent-slot starts some tools from an empty environment.
stub() {
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
STUBS='$STUBS'
CALLS='$CALLS'
printf '%s %s\n' "$1" "\$*" >>"\$CALLS"
$2
EOF
  chmod +x "$STUBS/$1"
}

# prime NAME [ORIGIN]: a clone under the dev root whose origin is a bare repo with one commit on main.
prime() {
  local name=$1 origin=${2:-$T/origins/$1.git}
  if [ ! -d "$origin" ]; then
    git init -q --bare "$origin"
    git clone -q "$origin" "$T/seed-$name" 2>/dev/null
    git -C "$T/seed-$name" commit -q --allow-empty -m seed
    git -C "$T/seed-$name" push -q origin HEAD:main
  fi
  git clone -q "$origin" "$AGENT_SLOT_DEV/$name"
}

# slot REPO N [JSON-FIELDS]: a slot clone with a record; the record merges the given fields over its defaults.
slot() {
  local repo=$1 n=$2 fields=${3:-'{}'} path=$AGENT_SLOT_ROOT/$1/$2
  mkdir -p "$AGENT_SLOT_ROOT/$repo"
  git init -q -b main "$path"
  jaq -n -c --arg repo "$repo" --argjson n "$n" --arg prime "$AGENT_SLOT_DEV/$repo" --argjson f "$fields" \
    '{schema: "dotfiles.agent-slot/1", repo: $repo, slot: $n, state: "active", task: null, base: "main",
      prime: $prime, session_id: "11111111-2222-3333-4444-555555555555", prs: []} + $f' \
    >"$path/.git/agent-slot.json"
}

# Asserts a JSON error object carries every field the contract promises.
assert_error_shape() {
  jaq -e '
    (.ok == false) and (.reason | type == "string") and (.exit_code | type == "number")
    and (.message | type == "string") and has("value")
    and (.next_step | has("action") and has("command") and has("docs"))
    and (.recovery | has("side_effects") and has("retryable") and has("max_retries") and has("reconcile"))
    and (.recovery.side_effects != "unknown" or .recovery.reconcile != null)
    and (.context | has("version") and has("tools") and has("config") and has("env"))
    and has("log")' <<<"$1" >/dev/null
}

# origin_file NAME PATH CONTENT: commits a file to the prime's origin, on main.
origin_file() {
  mkdir -p "$(dirname "$T/seed-$1/$2")"
  printf '%s\n' "$3" >"$T/seed-$1/$2"
  git -C "$T/seed-$1" add "$2"
  git -C "$T/seed-$1" commit -q -m "add $2"
  git -C "$T/seed-$1" push -q origin HEAD:main
}

# origin_symlink NAME PATH TARGET: commits a symlink to the prime's origin, on main.
origin_symlink() {
  mkdir -p "$(dirname "$T/seed-$1/$2")"
  ln -s "$3" "$T/seed-$1/$2"
  git -C "$T/seed-$1" add "$2"
  git -C "$T/seed-$1" commit -q -m "link $2"
  git -C "$T/seed-$1" push -q origin HEAD:main
}

# fingerprint DIR: one line per file (by content), symlink (by target), and directory under DIR, git objects aside.
fingerprint() {
  (
    cd "$1" || exit 1
    find . -path ./.git/objects -prune -o -type f -exec sha256sum {} + | sort
    find . -path ./.git/objects -prune -o -type l -printf '%p -> %l\n' | sort
    find . -path ./.git/objects -prune -o -type d -print | sort
  )
}

# trusted PATH...: marks paths trusted in the sandboxed Claude app-state file, as Claude does once its dialog is accepted.
trusted() {
  local path state=$AGENT_SLOT_CLAUDE_STATE
  for path in "$@"; do
    jaq --arg p "$path" '.projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})' "$state" >"$state.new"
    mv "$state.new" "$state"
  done
}
