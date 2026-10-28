# shellcheck shell=bash
# Fixtures for the agent-slot-rex suite. rex, ssh, ps, and the helper's own path (the command every pane and exec runs)
# are stubs that append their argv to $CALLS, reached through REX_BIN_DIR and the AGENT_SLOT_REX_* overrides.
#
# rex answers from files under $STUBS/rexdata: sessions.json for `ls`, session-<id>.json for `session inspect`, and
# process-<block>.json for `block call process`. `new` adds the session it makes to sessions.json and writes its
# session-<id>.json, so a later lookup or inspect finds it; `window new` adds its window to the session's file and starts
# its block's command, as ps sees it; `window rename` changes the window's label there. As Rex does, rex refuses a tab
# label longer than 128 characters with exit 2 and the same two stderr lines, and a subcommand named by rex_fails fails
# as told. ssh answers each agent-slot verb from $STUBS/ssh/<verb>.{out,err,rc}, or from <verb>.<n>.* on its nth call;
# the attach loop's tmux calls count as the verbs attach and has-session, and a bare `true` as probe. With
# $STUBS/ssh/unreachable present every call fails as ssh does, and with $STUBS/ssh/hang every call hangs.

# shellcheck disable=SC2034 # the suites that load this file run it
AGENT_SLOT_REX="$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/agent-slot-rex"

agent_slot_rex_setup() {
  T=$BATS_TEST_TMPDIR
  STUBS=$T/stubs
  CALLS=$T/calls.log
  mkdir -p "$STUBS/rexdata" "$STUBS/ssh"
  : >"$CALLS"
  printf '{"sessions":[]}\n' >"$STUBS/rexdata/sessions.json"
  : >"$STUBS/ps.txt"
  export CALLS STUBS

  export REX_BIN_DIR=$STUBS
  export AGENT_SLOT_REX_SSH=$STUBS/ssh-stub
  export AGENT_SLOT_REX_PS=$STUBS/ps
  export AGENT_SLOT_REX_SELF=$STUBS/agent-slot-rex
  export AGENT_SLOT_REX_APP_PATHS=
  export AGENT_SLOT_REX_STATE_DIR=$T/state
  export AGENT_SLOT_REX_SERVER=testserver
  export AGENT_SLOT_REX_RETRY_DELAY=0 AGENT_SLOT_REX_JITTER=0
  unset REX_SESSION REX_BLOCK

  stub rex '
fails="$STUBS/rexdata/fails-$1-$2"
if [ -e "$fails" ]; then
  tail -n +2 "$fails" >&2
  exit "$(head -1 "$fails")"
fi
label= sub=
case "$1 $2" in
  "window rename") label=$6 sub="window rename" ;;
  "window new") label=$5 sub="window new" ;;
  new\ *) [ "$3" = --window ] && label=$4 sub=new ;;
esac
if [ -n "$label" ] && [ "$(jaq -n --arg l "$label" "\$l | length")" -gt 128 ]; then
  printf "%s\n" "Error: label must be at most 128 characters" "Run \"rex $sub --help\" for more information." >&2
  exit 2
fi
case "$1 $2" in
  "ls --json") cat "$STUBS/rexdata/sessions.json" ;;
  "window rename")
    f="$STUBS/rexdata/session-$4.json"
    if [ -e "$f" ]; then
      jaq -c --arg w "$5" --arg l "$6" "(.windows[] | select(.window_id == \$w) | .label) = \$l" "$f" >"$f.$$"
      mv "$f.$$" "$f"
    fi ;;
  "session inspect")
    if [ -e "$STUBS/rexdata/starts-on-inspect-$3" ]; then
      cat "$STUBS/rexdata/starts-on-inspect-$3" >>"$STUBS/ps.txt"
      rm -f "$STUBS/rexdata/starts-on-inspect-$3"
    fi
    cat "$STUBS/rexdata/session-$3.json" 2>/dev/null || { echo "session $3 not found" >&2; exit 1; } ;;
  "block call")
    b=$(printf "%s\n" "$@" | sed -n "/^-b$/{n;p;}")
    cat "$STUBS/rexdata/process-$b.json" 2>/dev/null || echo "{\"child\":{\"pid\":0}}" ;;
  "window new")
    n=$(grep -c "^rex window new\|^rex new" "$CALLS")
    sid=$4 label=$5
    while [ "$1" != -- ]; do shift; done
    shift
    if [ -e "$STUBS/rexdata/hold-window-new" ]; then
      read -r hold_sid hold_n <"$STUBS/rexdata/hold-window-new"
      for _ in $(seq 40); do
        [ "$(grep -c "^rex session inspect $hold_sid " "$CALLS")" -ge "$hold_n" ] && break
        sleep 0.05
      done
      sleep 0.3
    fi
    if [ -e "$STUBS/rexdata/session-$sid.json" ]; then
      jaq -c --arg w "win-new-$n" --arg l "$label" --arg b "blk-new-$n" \
        ".windows += [{window_id: \$w, label: \$l, layers: [{blocks: [{block_id: \$b}]}]}]" \
        "$STUBS/rexdata/session-$sid.json" >"$STUBS/rexdata/session-$sid.new.$$"
      mv "$STUBS/rexdata/session-$sid.new.$$" "$STUBS/rexdata/session-$sid.json"
    fi
    printf "{\"child\":{\"pid\":%s}}\n" "$((9000 + n))" >"$STUBS/rexdata/process-blk-new-$n.json"
    printf "%s %s\n" "$((9000 + n))" "$*" >>"$STUBS/ps.txt"
    echo "{\"window_id\":\"win-new-$n\",\"block_ids\":[\"blk-new-$n\"]}" ;;
  "actions --json") cat "$STUBS/rexdata/actions.json" 2>/dev/null || echo "{\"actions\":[{\"name\":\"agent_slot_new\"}]}" ;;
  "version --json") echo "{\"rex_version\":\"${REX_STUB_VERSION:-0.0.1}\"}" ;;
  *)
    if [ "$1" = new ]; then
      n=$(grep -c "^rex window new\|^rex new" "$CALLS")
      jaq -c --arg l "$2" ".sessions += [{session_id: (\"sess-\" + \$l), label: \$l}]" "$STUBS/rexdata/sessions.json" \
        >"$STUBS/rexdata/sessions.new" && mv "$STUBS/rexdata/sessions.new" "$STUBS/rexdata/sessions.json"
      jaq -n -c --arg id "sess-$2" --arg l "$2" --arg n "$n" "{session_id: \$id, label: \$l, windows: [{window_id:
        (\"win-new-\" + \$n), label: \$l, layers: [{blocks: [{block_id: (\"blk-new-\" + \$n)}]}]}]}" \
        >"$STUBS/rexdata/session-sess-$2.json"
      echo "{\"session_id\":\"sess-$2\",\"initial_windows\":[{\"window_id\":\"win-new-$n\",\"block_ids\":[\"blk-new-$n\"]}]}"
    fi ;;
esac'
  stub ssh-stub '
[ -e "$STUBS/ssh/hang" ] && exec sleep 30
if [ -e "$STUBS/ssh/unreachable" ]; then
  echo "ssh: connect to host testserver port 22: Connection refused" >&2
  exit 255
fi
remote=${!#}
case $remote in
  *" attach -t "*) verb=attach ;;
  *has-session*) verb=has-session ;;
  true) verb=probe ;;
  *agent-slot\ *) verb=${remote#*agent-slot }; verb=${verb%% *} ;;
  *) verb=other ;;
esac
n=$(grep -c "^ssh-stub-verb $verb\$" "$CALLS")
printf "ssh-stub-verb %s\n" "$verb" >>"$CALLS"
base=$STUBS/ssh/$verb
[ -e "$base.$n.rc" ] || [ -e "$base.$n.out" ] || [ -e "$base.$n.err" ] && base=$base.$n
[ -e "$base.out" ] && cat "$base.out"
[ -e "$base.err" ] && cat "$base.err" >&2
exit "$(cat "$base.rc" 2>/dev/null || echo 0)"'
  stub ps 'cat "$STUBS/ps.txt"'
  stub agent-slot-rex 'exit 0'
}

# stub NAME BODY: an executable that appends "NAME argv" to the calls log, then runs BODY.
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

# ssh_answer VERB [N] RC [STDOUT [STDERR]]: what the ssh stub returns for an agent-slot verb, on every call or the nth.
ssh_answer() {
  local verb=$1 base
  if [[ $2 =~ ^[0-9]+$ && $# -ge 3 && $3 =~ ^[0-9]+$ ]]; then
    base=$STUBS/ssh/$verb.$2
    shift
  else
    base=$STUBS/ssh/$verb
  fi
  printf '%s\n' "$2" >"$base.rc"
  if [[ -n ${3:-} ]]; then printf '%s\n' "$3" >"$base.out"; else rm -f "$base.out"; fi
  if [[ -n ${4:-} ]]; then printf '%s\n' "$4" >"$base.err"; else rm -f "$base.err"; fi
}

# repos NAME...: the server's repos verb lists these repos.
repos() {
  ssh_answer repos 0 "$(printf '%s\n' "$@" | jaq -R -s -c '{schema: "dotfiles.agent-slot/1", ok: true, verb: "repos",
    repos: split("\n") | map(select(. != "") | {name: ., prime: ("/srv/" + .), origin: "git@example.com:o/\(.).git"})}')"
}

# slots JSON-ARRAY: the server's list verb reports these slots, each merged over the defaults of an active slot.
slots() {
  ssh_answer list 0 "$(jaq -c '{schema: "dotfiles.agent-slot/1", ok: true, verb: "list",
    slots: map({state: "active", task: null, branch: null, agent: "idle", needs_you: [],
                sessions: {claude: true, files: true, git: true}} + . + {key: "\(.repo)/\(.slot)"})}' <<<"$1")"
}

# server_error REASON MESSAGE EXIT RETRYABLE: an agent-slot error object.
server_error() {
  jaq -n -c --arg r "$1" --arg m "$2" --argjson c "$3" --argjson retry "$4" '{schema: "dotfiles.agent-slot/1",
    ok: false, verb: "launch", reason: $r, exit_code: $c, message: $m, value: "v",
    next_step: {action: "run", command: "agent-slot doctor", docs: "https://example.com"},
    recovery: {side_effects: "none", retryable: $retry, max_retries: 1, reconcile: null},
    context: {version: "x", tools: {}, config: {}, env: []}, log: "/srv/state/logs/launch.log"}'
}

# session ID LABEL WINDOWS-JSON: a Rex session; WINDOWS-JSON is [{window_id, label, blocks: [block ids]}].
session() {
  jaq -c --arg id "$1" --arg l "$2" '.sessions += [{session_id: $id, label: $l}]' "$STUBS/rexdata/sessions.json" \
    >"$STUBS/rexdata/sessions.new"
  mv "$STUBS/rexdata/sessions.new" "$STUBS/rexdata/sessions.json"
  jaq -n -c --arg id "$1" --arg l "$2" --argjson w "$3" '{session_id: $id, label: $l, windows: [$w[] |
    {window_id, label, layers: [{blocks: [.blocks[] | {block_id: ., flavor: "com.superlogical.terminal.shell"}]}]}]}' \
    >"$STUBS/rexdata/session-$1.json"
}

# runs BLOCK PID COMMAND: the block's own process is PID, and ps shows it running COMMAND.
runs() {
  printf '{"child":{"pid":%s}}\n' "$2" >"$STUBS/rexdata/process-$1.json"
  printf '%s %s\n' "$2" "$3" >>"$STUBS/ps.txt"
}

# starts_on_inspect SESSION BLOCK PID COMMAND: as runs, except that ps shows the process only once SESSION has been
# inspected, as for a pane that starts while a snapshot is under way.
starts_on_inspect() {
  printf '{"child":{"pid":%s}}\n' "$3" >"$STUBS/rexdata/process-$2.json"
  printf '%s %s\n' "$3" "$4" >"$STUBS/rexdata/starts-on-inspect-$1"
}

# rex_fails 'WORD WORD' RC STDERR: rex exits RC on that subcommand, printing STDERR, and changes nothing.
rex_fails() {
  printf '%s\n%s\n' "$2" "$3" >"$STUBS/rexdata/fails-${1// /-}"
}

# hold_window_new SESSION COUNT: each `rex window new` waits, for up to 2 s, until SESSION has been inspected COUNT
# times, so passes that run at once have all taken their snapshot before any of them opens a tab.
hold_window_new() {
  printf '%s %s\n' "$1" "$2" >"$STUBS/rexdata/hold-window-new"
}

# called PATTERN: the calls log has a line matching the extended regex.
called() {
  grep -qE "$1" "$CALLS" || {
    echo "no call matches: $1" >&2
    cat "$CALLS" >&2
    return 1
  }
}

# not_called PATTERN: no line of the calls log matches the extended regex.
not_called() {
  if grep -qE "$1" "$CALLS"; then
    echo "a call matches: $1" >&2
    grep -E "$1" "$CALLS" >&2
    return 1
  fi
}

# no_rex: the rex CLI is nowhere the helper looks.
no_rex() {
  export REX_BIN_DIR=$T/no-rex
  mkdir -p "$REX_BIN_DIR"
}

# with_tty COMMAND...: runs the command with a terminal on its stdin, typing the input piped to with_tty.
with_tty() {
  local cmd
  cmd=$(printf '%q ' "$@")
  if script --version 2>/dev/null | grep -q util-linux; then
    script -qec "$cmd" /dev/null
  else
    script -q /dev/null bash -c "$cmd"
  fi
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
