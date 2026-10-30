# shellcheck shell=bash
# Fixtures for the agent-slot suites. Each test gets its own slot root, dev root, and state directory under
# BATS_TEST_TMPDIR, reached through agent-slot's AGENT_SLOT_* overrides; tmux, claude, gh, git-crypt, trash, systemctl,
# and ssh are stubs that record their argv, and no Rex client is configured, so nothing pushes. git is real, with
# GIT_CONFIG_GLOBAL pointing at a test config, so no fixture repo inherits the host's signing or URL rewrites. The trash
# stub runs the real trash-cli on a trash under BATS_TEST_TMPDIR, since a teardown purges the entry trash-cli wrote.

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
  : >"$T/gitignore"
  git config --file "$GIT_CONFIG_GLOBAL" core.excludesFile "$T/gitignore"

  export AGENT_SLOT_ROOT=$T/slots
  export AGENT_SLOT_DEV=$T/dev
  export AGENT_SLOT_EXTRA_PRIMES=
  export AGENT_SLOT_STATE_DIR=$T/state
  export AGENT_SLOT_TMUX_SOCKET=agent-slot-test
  export AGENT_SLOT_TMUX_CONF=$T/slots.conf
  export AGENT_SLOT_SOLUTIONS=$T/solutions
  export AGENT_SLOT_GIT_CRYPT_KEY=$T/git-crypt.key
  export AGENT_SLOT_CLAUDE_STATE=$T/claude.json
  export AGENT_SLOT_CLAUDE_PROJECTS=$T/claude-projects
  export AGENT_SLOT_CLAUDE_SETTINGS=$T/claude-settings.json
  mkdir -p "$AGENT_SLOT_CLAUDE_PROJECTS"
  : >"$AGENT_SLOT_TMUX_CONF"
  : >"$AGENT_SLOT_GIT_CRYPT_KEY"
  printf '{"projects":{}}\n' >"$AGENT_SLOT_CLAUDE_STATE"
  printf '{"skipDangerousModePermissionPrompt":true}\n' >"$AGENT_SLOT_CLAUDE_SETTINGS"

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
  export XDG_DATA_HOME=$T/data
  TRASH=$XDG_DATA_HOME/Trash
  TRASH_PUT=$(command -v trash-put || true)
  trash_stub
  stub systemctl 'echo enabled'
  # ssh reaches the Rex clients a push names. Each host answers from $STUBS/ssh-<host>.{rc,err}, and while
  # $STUBS/ssh-<host>.hold exists it does not answer at all, for up to 30 s, as a Mac that is asleep.
  stub ssh '
host=${@: -2:1}
for ((i = 0; i < 300; i++)); do [ -e "$STUBS/ssh-$host.hold" ] || break; sleep 0.1; done
[ ! -e "$STUBS/ssh-$host.err" ] || cat "$STUBS/ssh-$host.err" >&2
exit "$(cat "$STUBS/ssh-$host.rc" 2>/dev/null || echo 0)"'
  export AGENT_SLOT_TMUX=$STUBS/tmux AGENT_SLOT_CLAUDE=$STUBS/claude AGENT_SLOT_GH=$STUBS/gh
  export AGENT_SLOT_GIT_CRYPT=$STUBS/git-crypt AGENT_SLOT_TRASH=$STUBS/trash AGENT_SLOT_SYSTEMCTL=$STUBS/systemctl
  export AGENT_SLOT_SSH=$STUBS/ssh AGENT_SLOT_REX_CLIENTS=
  unset AGENT_SLOT_REX_CLIENT
}

# trash_stub [AFTER]: the trash stub, which runs trash-cli's trash-put on the sandbox trash under $T/data, then AFTER once
# it succeeds. trash-cli and agent-slot both find the home trash from XDG_DATA_HOME, and the stub sets it again because
# agent-slot starts some tools from an empty environment: no test ever writes to the real trash.
trash_stub() {
  stub trash "[ \"\$1\" != --version ] || { echo 'trash 0.test'; exit 0; }
[ -n '$TRASH_PUT' ] || { echo 'trash-put not found; install trash-cli' >&2; exit 127; }
XDG_DATA_HOME='$XDG_DATA_HOME' '$TRASH_PUT' \"\$@\" || exit
${1:-}"
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

# gitstatusd_standin: prints the path of a copy of perl named as powerlevel10k's gitstatusd binary is, so a process
# started from it, as `"$(gitstatusd_standin)" -e 'sleep 120'`, has the daemon's comm, gitstatusd-linu. Not a copy of
# sleep: where coreutils is one multicall binary, as uutils is on Ubuntu 26.04, the copy picks its utility by its own
# name and exits at once.
gitstatusd_standin() {
  cp "$(command -v perl)" "$T/gitstatusd-linux-x86_64"
  printf '%s\n' "$T/gitstatusd-linux-x86_64"
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

# task_slot_setup: repoa/1 as a real clone of a bare origin, with an active record, no PRs, no agent, and a home scan
# root holding one unrelated link. A PR is GitHub's refs/pull/<N>/head ref in the origin plus an entry in the stubbed
# `gh pr list`; a merge is a squash commit on main with the head branch deleted, as GitHub does.
task_slot_setup() {
  mkdir -p "$T/home" "$T/elsewhere"
  ln -s "$T/elsewhere" "$T/home/unrelated-link"
  export AGENT_SLOT_HOME_SCAN_ROOTS="$T/home:3"
  prime repoa
  ORIGIN=$T/origins/repoa.git
  SLOT=$AGENT_SLOT_ROOT/repoa/1
  mkdir -p "$AGENT_SLOT_ROOT/repoa"
  git clone -q "$ORIGIN" "$SLOT"
  jaq -n -c --arg prime "$AGENT_SLOT_DEV/repoa" '{schema: "dotfiles.agent-slot/1", repo: "repoa", slot: 1,
    state: "active", task: "t1", base: "main", prime: $prime, session_id: "s1", prs: [],
    finished_by_operator: false, created_at: "2026-01-01T00:00:00Z", transcript: "/t/s1.jsonl"}' \
    >"$SLOT/.git/agent-slot.json"
  echo '[]' >"$STUBS/gh-prs.json"
  stub gh 'cat "$STUBS/gh-prs.json"'
}

# work BRANCH [N]: N commits (default 1) on BRANCH in the slot.
work() {
  local i
  git -C "$SLOT" checkout -q -B "$1"
  for ((i = 0; i < ${2:-1}; i++)); do git -C "$SLOT" commit -q --allow-empty -m "work $i on $1"; done
}

# pr NUMBER STATE BRANCH [CREATED]: a PR whose final head is the branch's current tip in the slot, opened at CREATED,
# which defaults to a time after the slot's record was made.
pr() {
  local sha
  sha=$(git -C "$SLOT" rev-parse "$3")
  git -C "$SLOT" push -q origin "$sha:refs/pull/$1/head"
  pr_listed "$1" "$2" "$3" "$sha" "${4:-2026-06-01T00:00:00Z}"
}

# pr_listed NUMBER STATE BRANCH OID CREATED: an entry in the stubbed `gh pr list`.
pr_listed() {
  jaq -c --argjson n "$1" --arg state "$2" --arg head "$3" --arg oid "$4" --arg created "$5" \
    '. + [{number: $n, state: $state, headRefName: $head, headRefOid: $oid, createdAt: $created,
      url: "https://github.com/x/repoa/pull/\($n)"}]' "$STUBS/gh-prs.json" >"$STUBS/gh-prs.new"
  mv "$STUBS/gh-prs.new" "$STUBS/gh-prs.json"
}

# fork_remote: points the slot's origin at GitHub's https URL for up/repoa and adds a remote named fork at GitHub's ssh
# URL for me/repoa, the shape `gh pr checkout` leaves for a PR from a fork. The test's git config rewrites both URLs to
# bare repos under $T, so check reads both remotes as on github.com while git reaches the local repos.
fork_remote() {
  mkdir -p "$T/forks"
  git clone -q --bare "$ORIGIN" "$T/forks/repoa.git"
  git config --file "$GIT_CONFIG_GLOBAL" "url.$T/origins/.insteadOf" https://github.com/up/
  git config --file "$GIT_CONFIG_GLOBAL" "url.$T/forks/.insteadOf" git@github.com:me/
  git -C "$SLOT" remote set-url origin https://github.com/up/repoa.git
  git -C "$SLOT" remote add fork git@github.com:me/repoa.git
}

# operator_finished: the record of a task the operator finished.
operator_finished() {
  jaq '.finished_by_operator = true' "$SLOT/.git/agent-slot.json" >"$T/r" && mv "$T/r" "$SLOT/.git/agent-slot.json"
}

# squash_merge BRANCH: GitHub's squash merge: one commit on main, and the head branch deleted.
squash_merge() {
  git clone -q "$ORIGIN" "$T/merger"
  git -C "$T/merger" merge -q --squash "origin/$1" >/dev/null
  git -C "$T/merger" commit -q --allow-empty -m "squash $1"
  git -C "$T/merger" push -q origin HEAD:main
  git -C "$T/merger" push -q origin --delete "$1"
  chmod -R u+w "$T/merger" && find "$T/merger" -delete
}

# A finished task: one PR, pushed, squash-merged, with every local commit in the PR's final head.
finished_task() {
  work feat/x 2
  git -C "$SLOT" push -q origin feat/x
  pr 7 MERGED feat/x
  squash_merge feat/x
}
