# shellcheck shell=bash
# Fixtures for the agent-slot-rex suites. rex, agent-slot, tmux, systemctl, ssh, ps, rexurrect, and the helper's own
# path (the command every pane and exec runs) are stubs that append their argv to $CALLS, reached through REX_BIN_DIR
# and the AGENT_SLOT_REX_* overrides. uname is a stub on PATH that reports Linux, or $UNAME_STUB when set, so the suite
# runs the server's code paths on a Mac too.
#
# rex answers from files under $STUBS/rexdata: sessions.json for `ls`, session-<id>.json for `session inspect`,
# process-<block>.json for `block call process`, and size-<block>.json for `block call size`, a terminal no client has
# asked a size of when absent. `new` adds the session it makes to sessions.json and writes its
# session-<id>.json, so a later lookup or inspect finds it; `window new` adds its window to the session's file and starts
# its block's command, as ps sees it; `window rename` changes the window's label there; `send` to a block that
# attaches_on_send names adds a client of the prime on that block's terminal. As Rex does, rex refuses a tab
# label longer than 128 characters with exit 2 and the same two stderr lines, and a subcommand named by rex_fails fails
# as told. rex refuses any call whose first argument is not --autostart=false, and logs the call without it; every raw
# argv also goes to $STUBS/rex-argv.log. `version --json` answers with the build rex_versions set, 0.0.1 by default.
# `server status` answers as the running server pid $REX_STUB_PID, instance $REX_STUB_INSTANCE, started at
# $REX_STUB_STARTED (default long past the start-up limit), and the server build rex_versions set, else the CLI's, or
# fails while $STUBS/rexdata/server-down exists; $STUBS/rexdata/instance and started, when present, stand in for a
# server that restarted while a pass ran, and restarts_after and stops_after make the server restart or stop once a
# given subcommand has answered. `kill` removes each session it names. `window close` of a window with
# $STUBS/rexdata/closed-elsewhere-<id> present fails as a close of a tab already gone does, after removing it from its
# session's file.
#
# agent-slot answers each verb from $STUBS/slot/<verb>.{out,err,rc}, or from <verb>.<n>.* on its nth call, and logs the
# AGENT_SLOT_REX_CLIENT and XDG_RUNTIME_DIR it was given as `agent-slot-client <name>` and `agent-slot-runtime <dir>`.
# tmux answers has-session and attach from $STUBS/tmux-answers the same way, logs the directory each attach ran from as
# `tmux-cwd <dir>`, and reports $STUBS/tmux-answers/pid as its server's pid, or exits with
# $STUBS/tmux-answers/display-message.rc when present. A call to the default tmux server, which the helper names with
# `-L default` and where an old-style prime runs, answers from $STUBS/tmux-default the same way. The prime map is
# $STUBS/primes, and the login shell an old-style prime's tab ends in logs `login-shell <args>`. ssh answers the forwarded helper verbs from $STUBS/ssh/<verb>.*,
# and a bare `true` as probe, and appends each remote command to $STUBS/ssh-remote.log; with $STUBS/ssh/unreachable
# present every call fails as ssh does, and with $STUBS/ssh/hang every call hangs. systemctl reports each unit active
# unless $STUBS/units/<unit> says otherwise, and rex-server.service's MainPID as $STUBS/units/rex-server.service.pid,
# else $REX_STUB_PID, unless $STUBS/units/show-fails makes `show` fail as an unreachable user manager does. ps reports
# $STUBS/cgroup.txt for `-o cgroup=`, $STUBS/tty/<pid> for `-o tty=`, and the command runs gave a pid for `-o args=`.

# shellcheck disable=SC2034 # the suites that load this file run it
AGENT_SLOT_REX="$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/agent-slot-rex"

agent_slot_rex_setup() {
  T=$BATS_TEST_TMPDIR
  STUBS=$T/stubs
  CALLS=$T/calls.log
  mkdir -p "$STUBS/rexdata" "$STUBS/ssh" "$STUBS/slot" "$STUBS/tmux-answers" "$STUBS/tmux-default" "$STUBS/units" \
    "$STUBS/os" "$STUBS/tty"
  : >"$CALLS"
  printf '{"sessions":[]}\n' >"$STUBS/rexdata/sessions.json"
  : >"$STUBS/ps.txt"
  export CALLS STUBS

  export REX_BIN_DIR=$STUBS
  export AGENT_SLOT_REX_SSH=$STUBS/ssh-stub
  export AGENT_SLOT_REX_PS=$STUBS/ps
  export AGENT_SLOT_REX_TMUX=$STUBS/tmux
  export AGENT_SLOT_REX_SYSTEMCTL=$STUBS/systemctl
  export AGENT_SLOT_REX_AGENT_SLOT=$STUBS/agent-slot
  export AGENT_SLOT_REX_REXURRECT=$STUBS/rexurrect
  export AGENT_SLOT_REX_SELF=$STUBS/agent-slot-rex
  export AGENT_SLOT_REX_APP_PATHS=
  export AGENT_SLOT_REX_STATE_DIR=$T/state
  export AGENT_SLOT_REX_SERVER=testserver
  export AGENT_SLOT_REX_RETRY_DELAY=0
  export AGENT_SLOT_REX_PRIMES=$STUBS/primes AGENT_SLOT_REX_LOGIN_SHELL=$STUBS/login-shell
  export AGENT_SLOT_REX_SHOWN_WAIT=0 AGENT_SLOT_REX_SHOWN_HOLD=2
  printf '# repo\tprime session\n' >"$STUBS/primes"
  export REX_STUB_PID=4242 REX_STUB_INSTANCE=11111111-2222-3333-4444-555555555555
  unset REX_SESSION REX_BLOCK UNAME_STUB
  printf '#!/bin/sh\necho "${UNAME_STUB:-Linux}"\n' >"$STUBS/os/uname"
  chmod +x "$STUBS/os/uname"
  export PATH="$STUBS/os:$PATH"

  stub rex '
printf "%s\n" "$*" >>"$STUBS/rex-argv.log"
if [ "$1" != --autostart=false ]; then
  echo "rex stub: called without --autostart=false: $*" >&2
  exit 99
fi
shift
printf "rex %s\n" "$*" >>"$CALLS"
if [ "$1 $2" = "window close" ] && [ -e "$STUBS/rexdata/closed-elsewhere-$5" ]; then
  f="$STUBS/rexdata/session-$4.json"
  jaq -c --arg w "$5" "del(.windows[] | select(.window_id == \$w))" "$f" >"$f.$$" && mv "$f.$$" "$f"
  echo "Error: window $5 not found" >&2
  exit 1
fi
fails="$STUBS/rexdata/fails-$1-$2"
if [ -e "$fails" ]; then
  tail -n +2 "$fails" >&2
  exit "$(head -1 "$fails")"
fi
restarts="$STUBS/rexdata/restarts-after-$1-$2" stops="$STUBS/rexdata/stops-after-$1-$2"
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
    case ${!#} in
      size) cat "$STUBS/rexdata/size-$b.json" 2>/dev/null || echo "{\"owner\":null,\"desired\":[]}" ;;
      *) cat "$STUBS/rexdata/process-$b.json" 2>/dev/null || echo "{\"child\":{\"pid\":0}}" ;;
    esac ;;
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
  "send -s")
    if [ -e "$STUBS/rexdata/attaches-on-send-$5" ]; then
      printf "/dev/%s\n" "$(cat "$STUBS/rexdata/attaches-on-send-$5")" >>"$STUBS/tmux-default/list-clients.out"
    fi ;;
  "actions --json") cat "$STUBS/rexdata/actions.json" 2>/dev/null || echo "{\"actions\":[{\"name\":\"agent_slot_new\"}]}" ;;
  "version --json") echo "{\"rex_version\":\"$(cat "$STUBS/rexdata/version" 2>/dev/null || echo 0.0.1)\"}" ;;
  "server status")
    if [ -e "$STUBS/rexdata/server-down" ]; then
      echo "Error: no Rex server is running at unix:///run/user/1000/rex/server.sock" >&2
      exit 1
    fi
    printf "%s\n" "you: uid 1000 over unix" "endpoint: unix:///run/user/1000/rex/server.sock" \
      "pid: $REX_STUB_PID" "instance: $(cat "$STUBS/rexdata/instance" 2>/dev/null || echo "$REX_STUB_INSTANCE")" \
      "started: $(cat "$STUBS/rexdata/started" 2>/dev/null || echo "${REX_STUB_STARTED:-2026-01-01T00:00:00Z}")" \
      "version: $({ cat "$STUBS/rexdata/server-version" "$STUBS/rexdata/version" 2>/dev/null; echo 0.0.1; } | head -1)" \
      "exit-empty: false" "sessions: 1" ;;
  *)
    if [ "$1" = new ]; then
      n=$(grep -c "^rex window new\|^rex new" "$CALLS")
      jaq -c --arg l "$2" ".sessions += [{session_id: (\"sess-\" + \$l), label: \$l}]" "$STUBS/rexdata/sessions.json" \
        >"$STUBS/rexdata/sessions.new" && mv "$STUBS/rexdata/sessions.new" "$STUBS/rexdata/sessions.json"
      jaq -n -c --arg id "sess-$2" --arg l "$2" --arg n "$n" "{session_id: \$id, label: \$l, windows: [{window_id:
        (\"win-new-\" + \$n), label: \$l, layers: [{blocks: [{block_id: (\"blk-new-\" + \$n)}]}]}]}" \
        >"$STUBS/rexdata/session-sess-$2.json"
      echo "{\"session_id\":\"sess-$2\",\"initial_windows\":[{\"window_id\":\"win-new-$n\",\"block_ids\":[\"blk-new-$n\"]}]}"
    elif [ "$1" = kill ]; then
      shift
      for sid in "$@"; do
        jaq -c --arg s "$sid" "del(.sessions[] | select(.session_id == \$s))" "$STUBS/rexdata/sessions.json" \
          >"$STUBS/rexdata/sessions.new" && mv "$STUBS/rexdata/sessions.new" "$STUBS/rexdata/sessions.json"
        rm -f "$STUBS/rexdata/session-$sid.json"
      done
    fi ;;
esac
[ ! -e "$restarts" ] || mv "$restarts" "$STUBS/rexdata/instance"
[ ! -e "$stops" ] || mv "$stops" "$STUBS/rexdata/server-down"' nolog
  stub agent-slot '
printf "agent-slot-client %s\n" "${AGENT_SLOT_REX_CLIENT:-}" >>"$CALLS"
printf "agent-slot-runtime %s\n" "${XDG_RUNTIME_DIR:-unset}" >>"$CALLS"
answer slot "$1"'
  stub tmux '
if [ "$1 $2" = "-L default" ]; then
  [ "$3" = attach ] && printf "tmux-cwd %s\n" "$PWD" >>"$CALLS"
  answer tmux-default "$3"
fi
[ "$3" = attach ] && printf "tmux-cwd %s\n" "$PWD" >>"$CALLS"
[ "$3" = attach ] && printf "PATH=%s\n" "$PATH" >>"$STUBS/path.log"
case $3 in
  display-message)
    [ -e "$STUBS/tmux-answers/display-message.rc" ] && exit "$(cat "$STUBS/tmux-answers/display-message.rc")"
    [ -e "$STUBS/tmux-answers/pid" ] || { echo "no server running on /tmp/tmux-1000/agent-slots" >&2; exit 1; }
    cat "$STUBS/tmux-answers/pid" ;;
  *) answer tmux-answers "$3" ;;
esac'
  stub systemctl '
[ "$1" = --user ] && shift
case $1 in
  is-active)
    state=$(cat "$STUBS/units/$2" 2>/dev/null || echo active)
    echo "$state"
    [ "$state" = active ] ;;
  show)
    [ -e "$STUBS/units/show-fails" ] && { echo "Failed to connect to bus: No medium found" >&2; exit 1; }
    cat "$STUBS/units/$5.pid" 2>/dev/null || echo "$REX_STUB_PID" ;;
esac'
  stub ssh-stub '
[ -e "$STUBS/ssh/hang" ] && exec sleep 30
if [ -e "$STUBS/ssh/unreachable" ]; then
  echo "ssh: connect to host testserver port 22: Connection refused" >&2
  exit 255
fi
remote=${!#}
printf "%s\n" "$remote" >>"$STUBS/ssh-remote.log"
case $remote in
  true) verb=probe ;;
  *agent-slot-rex\ *) verb=${remote#*agent-slot-rex }; verb=${verb%% *}; verb=${verb#?}; verb=${verb%?} ;;
  *) verb=other ;;
esac
answer ssh "$verb"'
  stub ps '
case " $* " in
  *" -o cgroup= "*) cat "$STUBS/cgroup.txt" 2>/dev/null ;;
  *" -o tty= "*) cat "$STUBS/tty/${!#}" 2>/dev/null || echo "?" ;;
  *" -o args= "*) awk -v p="${!#}" '"'"'$1 == p { sub(/^[0-9]+ /, ""); print; exit }'"'"' "$STUBS/ps.txt" ;;
  *) cat "$STUBS/ps.txt" ;;
esac'
  stub rexurrect 'exit 0'
  stub login-shell 'exit 0'
  stub agent-slot-rex 'exit 0'
}

# stub NAME BODY [nolog]: an executable that appends "NAME argv" to the calls log, unless nolog, then runs BODY. BODY
# can call `answer DIR VERB`, which prints $STUBS/DIR/VERB.out and .err and exits with VERB.rc (0 when there is none),
# or with VERB.<n>.* on the stub's nth call of that verb.
stub() {
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
STUBS='$STUBS'
CALLS='$CALLS'
answer() {
  local n base=\$STUBS/\$1/\$2
  n=\$(grep -c "^\$1-verb \$2\\\$" "\$CALLS")
  printf '%s-verb %s\n' "\$1" "\$2" >>"\$CALLS"
  [ -e "\$base.\$n.rc" ] || [ -e "\$base.\$n.out" ] || [ -e "\$base.\$n.err" ] && base=\$base.\$n
  [ -e "\$base.out" ] && cat "\$base.out"
  [ -e "\$base.err" ] && cat "\$base.err" >&2
  exit "\$(cat "\$base.rc" 2>/dev/null || echo 0)"
}
EOF
  [[ ${3:-} == nolog ]] || printf "printf '%%s %%s\\\\n' '%s' \"\$*\" >>\"\$CALLS\"\n" "$1" >>"$STUBS/$1"
  printf '%s\n' "$2" >>"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# _answer DIR VERB [N] RC [STDOUT [STDERR]]: what a stub returns for a verb, on every call or the nth.
_answer() {
  local dir=$1 verb=$2 base
  shift 2
  if [[ $1 =~ ^[0-9]+$ && $# -ge 2 && $2 =~ ^[0-9]+$ ]]; then
    base=$STUBS/$dir/$verb.$1
    shift
  else
    base=$STUBS/$dir/$verb
  fi
  printf '%s\n' "$1" >"$base.rc"
  if [[ -n ${2:-} ]]; then printf '%s\n' "$2" >"$base.out"; else rm -f "$base.out"; fi
  if [[ -n ${3:-} ]]; then printf '%s\n' "$3" >"$base.err"; else rm -f "$base.err"; fi
}

# slot_answer VERB [N] RC [STDOUT [STDERR]]: what agent-slot on this host returns for a verb.
slot_answer() { _answer slot "$@"; }

# tmux_answer VERB [N] RC: what tmux returns for has-session or attach.
tmux_answer() { _answer tmux-answers "$@"; }

# tmux_default_answer VERB [N] RC [STDOUT]: what tmux returns for a call to the default server, where old-style primes
# run.
tmux_default_answer() { _answer tmux-default "$@"; }

# ssh_answer VERB [N] RC [STDOUT [STDERR]]: what the server's helper returns for a forwarded verb, over ssh.
ssh_answer() { _answer ssh "$@"; }

# rex_versions CLI [SERVER]: the rex CLI's build, and the running server's, which is the CLI's unless given.
rex_versions() {
  printf '%s\n' "$1" >"$STUBS/rexdata/version"
  if [[ -n ${2:-} ]]; then printf '%s\n' "$2" >"$STUBS/rexdata/server-version"; else rm -f "$STUBS/rexdata/server-version"; fi
}

# unit UNIT STATE: systemctl reports the unit in that state.
unit() { printf '%s\n' "$2" >"$STUBS/units/$1"; }

# repos NAME...: the server's repos verb lists these repos.
repos() {
  slot_answer repos 0 "$(printf '%s\n' "$@" | jaq -R -s -c '{schema: "dotfiles.agent-slot/1", ok: true, verb: "repos",
    repos: split("\n") | map(select(. != "") | {name: ., prime: ("/srv/" + .), origin: "git@example.com:o/\(.).git"})}')"
}

# slots JSON-ARRAY: the server's list verb reports these slots, each merged over the defaults of an active slot, with a
# label_name, unless one is given, as list gives it: the slot's name, else its task, else its branch.
slots() {
  slot_answer list 0 "$(jaq -c '{schema: "dotfiles.agent-slot/1", ok: true, verb: "list",
    slots: map({state: "active", task: null, branch: null, agent: "idle", needs_you: [],
                sessions: {claude: true, files: true, git: true}} + . + {key: "\(.repo)/\(.slot)"}
               | {label_name: (.name // .task // .branch)} + .)}' <<<"$1")"
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

# primes REPO NAME...: the prime map holds each repo with its display name, in pairs, and a session of that name holds a
# Claude on the default tmux server. no_old_primes takes those sessions away.
primes() {
  while (($# >= 2)); do
    printf '%s\t%s\n' "$1" "$2" >>"$STUBS/primes"
    printf '%s\tclaude\n' "$2" >>"$STUBS/tmux-default/list-panes.out"
    shift 2
  done
}

# no_old_primes: the default tmux server's sessions hold no Claude.
no_old_primes() {
  rm -f "$STUBS/tmux-default/list-panes.out"
}

# prime_tab_in SESSION REPO: a tab of the Rex session whose own process holds the repo's prime, as a key's or a pass's tab
# does, so the new-agent key there starts a slot.
prime_tab_in() {
  local f=$STUBS/rexdata/session-$1.json
  jaq -c '.windows = [{window_id: "win-prime", label: "1: the prime", layers: [{blocks: [{block_id: "blk-prime"}]}]}]
    + .windows' "$f" >"$f.new"
  mv "$f.new" "$f"
  runs blk-prime 777 "bash /x/agent-slot-rex attach $2/prime claude"
}

# on_tty BLOCK PID TTY: the block's own process is PID, on terminal TTY, such as pts/9.
on_tty() {
  runs "$1" "$2" "zsh -l"
  printf '%s\n' "$3" >"$STUBS/tty/$2"
}

# prime_clients TTY...: the default tmux server's clients of the old-style prime asked about are on these terminals, as
# `tmux list-clients -F '#{client_tty}'` prints them.
prime_clients() {
  tmux_default_answer list-clients 0 "$(printf '/dev/%s\n' "$@")"
}

# at_prompt BLOCK PID TTY: the block's own process is PID, a zsh on terminal TTY sitting at its prompt, so its terminal's
# foreground process is the shell itself.
at_prompt() {
  on_tty "$1" "$2" "$3"
  printf '{"child":{"pid":%s,"name":"zsh"},"foreground":{"pid":%s,"name":"zsh"}}\n' "$2" "$2" \
    >"$STUBS/rexdata/process-$1.json"
}

# running_in BLOCK PID TTY PROGRAM: as at_prompt, except that the shell runs PROGRAM in the foreground.
running_in() {
  on_tty "$1" "$2" "$3"
  printf '{"child":{"pid":%s,"name":"zsh"},"foreground":{"pid":%s,"name":"%s"}}\n' "$2" "$(($2 + 1))" "$4" \
    >"$STUBS/rexdata/process-$1.json"
}

# attaches_on_send BLOCK TTY: text sent to the block starts a tmux client of the prime on TTY, as the prime command
# typed at its shell's prompt does.
attaches_on_send() {
  printf '%s\n' "$2" >"$STUBS/rexdata/attaches-on-send-$1"
}

# active SESSION WINDOW: the session's active window is WINDOW.
active() {
  local f=$STUBS/rexdata/session-$1.json
  jaq -c --arg w "$2" '.active_window_id = $w' "$f" >"$f.new"
  mv "$f.new" "$f"
}

# sized BLOCK: an app has asked the server for a size for the block's terminal, as Rex.app does for each pane of a tab
# it shows.
sized() {
  printf '%s\n' '{"owner":"client:app","desired":[{"client_id":"client:app","columns":120,"rows":40,
    "updated_at":"2026-11-03T14:24:52Z"}]}' >"$STUBS/rexdata/size-$1.json"
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

# restarts_after 'WORD WORD' [INSTANCE]: once rex has answered that subcommand, the Rex server answers as a new
# instance, 99999999-aaaa-bbbb-cccc-dddddddddddd unless given, as when it restarts in the middle of a pass.
restarts_after() {
  printf '%s\n' "${2:-99999999-aaaa-bbbb-cccc-dddddddddddd}" >"$STUBS/rexdata/restarts-after-${1// /-}"
}

# stops_after 'WORD WORD': once rex has answered that subcommand, no Rex server answers.
stops_after() {
  : >"$STUBS/rexdata/stops-after-${1// /-}"
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
    # BSD script(1) sends the EOF of a non-terminal stdin to the pty ahead of the input
    # already read, so the helper's first key is ^D and a line read sees end of input.
    # Python's pty writes the input, then that ^D, in util-linux script's order.
    python3 -c '
import os, pty, sys
eof_sent = False
def stdin_read(fd):
    global eof_sent
    data = os.read(fd, 1024)
    if data or eof_sent:
        return data
    eof_sent = True
    return b"\x04"
sys.exit(os.waitstatus_to_exitcode(pty.spawn(["bash", "-c", sys.argv[1]], stdin_read=stdin_read)))
' "$cmd"
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
