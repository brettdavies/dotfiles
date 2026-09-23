#!/usr/bin/env bats
# Tests for stow/local/dot-local/bin/mac-open, the server half of the yazi
# hand-off.
#
# Run: bats tests/mac-open.bats
#
# `ssh`, `timeout`, `tailscale`, `tmux`, and `ya` are stubs in a PATH-prepended
# directory, each appending its argv to CALLS. The `ssh` stub hands the remote
# command to a real `zsh -c` with HOME pointing at a fake Mac home whose
# ~/.local/bin/mac-open-here records the arguments it received, one per line,
# in RECEIVED; so quoting and tilde expansion are exercised for real. Knobs:
#   SSH_EXIT / SSH_ERR   status and stderr for the call (255 skips the receiver,
#                        as a failed connection does)
#   SSH_FAIL_MATCH       apply SSH_EXIT / SSH_ERR only to calls naming this word
#   RECEIVER_OUT         what the fake receiver prints on stdout
#   TIMEOUT_EXIT         make `timeout` report its own expiry instead of running
#   WHOIS                "addr=name ..." answers for `tailscale whois --json`
#   WHOIS_EXIT           make `tailscale whois` fail
#   DRIVE_TABLE          the `tailscale drive list` output
#   CLIENTS              "session activity pid" lines for `tmux list-clients`
#   TMUX_EXIT            make `tmux list-clients` fail
#   YA_EXIT              make `ya` fail
# The guard reads a real /proc environment: tests start a background `sleep`
# carrying the SSH_CONNECTION they want the tmux client to have.

SCRIPT="$BATS_TEST_DIRNAME/../stow/local/dot-local/bin/mac-open"

bats_require_minimum_version 1.5.0

MAC_ADDR="100.64.0.10"
OTHER_ADDR="100.64.0.20"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  MACHOME="$BATS_TEST_TMPDIR/machome"
  FIX="$BATS_TEST_TMPDIR/fix"
  export CALLS="$BATS_TEST_TMPDIR/calls.log"
  export RECEIVED="$BATS_TEST_TMPDIR/received.log"
  export STDIN_COPY="$BATS_TEST_TMPDIR/stdin.bin"
  export YA_LOG="$BATS_TEST_TMPDIR/ya.log"
  export MACHOME
  mkdir -p "$STUBS" "$MACHOME/.local/bin" "$FIX/dev" "$FIX/vault" "$FIX/outside"
  : >"$CALLS"
  : >"$RECEIVED"

  export WHOIS="$MAC_ADDR=bretts-air $OTHER_ADDR=pixel"
  export DRIVE_TABLE
  DRIVE_TABLE=$(printf '%s\n' \
    'name     path              as' \
    '-----    --------------    -----' \
    "dev      $FIX/dev    brett" \
    "vault    $FIX/vault    brett")

  # The guard passes by default: no tmux, and a session from the Mac.
  unset TMUX TMUX_PANE YAZI_ID
  export SSH_CONNECTION="$MAC_ADDR 50000 100.64.0.1 22"

  stub ssh '
    log ssh "$@"
    remote=${!#}
    if [[ -n ${SSH_FAIL_MATCH:-} && $remote != *"$SSH_FAIL_MATCH"* ]]; then
      code=0 err=""
    else
      code=${SSH_EXIT:-0} err=${SSH_ERR:-}
    fi
    if [[ $code -eq 255 ]]; then printf "%s\n" "$err" >&2; exit 255; fi
    HOME=$MACHOME CODE=$code ERR=$err zsh -fc "$remote"'
  cat >"$MACHOME/.local/bin/mac-open-here" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$RECEIVED"
[[ $1 != receive ]] || cat >"$STDIN_COPY"
[[ -z ${RECEIVER_OUT:-} ]] || printf '%s\n' "$RECEIVER_OUT"
[[ -z ${ERR:-} ]] || printf '%s\n' "$ERR" >&2
exit "${CODE:-0}"
EOF
  chmod +x "$MACHOME/.local/bin/mac-open-here"
  stub timeout '
    log timeout "$@"
    [[ -z ${TIMEOUT_EXIT:-} ]] || exit "$TIMEOUT_EXIT"
    while [[ $1 == -* ]]; do shift; done
    shift
    exec "$@"'
  stub tailscale '
    log tailscale "$@"
    case $1 in
      drive) printf "%s\n" "$DRIVE_TABLE" ;;
      whois)
        [[ -z ${WHOIS_EXIT:-} ]] || exit "$WHOIS_EXIT"
        for pair in $WHOIS; do
          if [[ ${pair%%=*} == "${!#}" ]]; then
            printf "{\"Node\":{\"ComputedName\":\"%s\"}}\n" "${pair#*=}"
            exit 0
          fi
        done
        echo "no match for IP:port ${!#}" >&2
        exit 1 ;;
    esac'
  stub tmux '
    log tmux "$@"
    case $1 in
      display-message) echo "\$7" ;;
      list-clients)
        [[ -z ${TMUX_EXIT:-} ]] || exit "$TMUX_EXIT"
        while read -r s a p; do
          [[ $s == "$3" ]] && echo "$a $p"
        done <<<"${CLIENTS:-}"
        ;;
    esac'
  stub ya '
    printf "%s %s\n" "$(date +%s%N)" "$*" >>"$YA_LOG"
    exit "${YA_EXIT:-0}"'
}

teardown() {
  local pid
  for pid in ${BG_PIDS:-}; do kill "$pid" 2>/dev/null || true; done
}

# stub NAME BODY: an executable NAME whose body can call `log`.
stub() {
  cat >"$STUBS/$1" <<EOF
#!/usr/bin/env bash
log() { printf '%s\n' "\$*" >>"\$CALLS"; }
$2
EOF
  chmod +x "$STUBS/$1"
}

dispatch() { PATH="$STUBS:$PATH" run --separate-stderr "$SCRIPT" "$@"; }

# A process whose /proc environment carries SSH_CONNECTION=$1 (none when empty),
# standing in for a tmux client. Sets CLIENT_PID.
client_with() {
  if [[ -n $1 ]]; then
    SSH_CONNECTION="$1" sleep 60 >/dev/null 2>&1 3>&- &
  else
    env -u SSH_CONNECTION sleep 60 >/dev/null 2>&1 3>&- &
  fi
  CLIENT_PID=$!
  BG_PIDS="${BG_PIDS:-} $CLIENT_PID"
}

in_tmux() {
  export TMUX="/tmp/tmux-test/default,1,7" TMUX_PANE="%3"
  unset SSH_CONNECTION
}

fixture() {
  mkdir -p "$(dirname "$1")"
  printf '%s' "${2:-content}" >"$1"
}

ssh_calls() { grep -c '^ssh ' "$CALLS" || true; }

# Wait for the deferred notification, which a background child sends.
ya_line() {
  for _ in $(seq 1 40); do
    [[ -s $YA_LOG ]] && break
    sleep 0.05
  done
  cat "$YA_LOG" 2>/dev/null
}

@test "mac-open passes shellcheck" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  run "$BATS_TEST_DIRNAME/../scripts/lint-shell" stow/local/dot-local/bin/mac-open
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

@test "no arguments prints usage on stderr, exits 2, and dials nothing" {
  dispatch
  [ "$status" -eq 2 ]
  [[ $stderr == usage:* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "an unknown subcommand prints usage on stderr and exits 2" {
  dispatch frobnicate x
  [ "$status" -eq 2 ]
  [[ $stderr == usage:* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "--help prints usage on stdout and exits 0" {
  dispatch --help
  [ "$status" -eq 0 ]
  [[ $output == usage:* ]]
  [ -z "$stderr" ]
}

# ---------------------------------------------------------------------------
# Client-origin guard
# ---------------------------------------------------------------------------

@test "a tmux client attached from another tailnet node is refused without dialing (AE9)" {
  fixture "$FIX/dev/n.md"
  in_tmux
  client_with "$OTHER_ADDR 40000 100.64.0.1 22"
  pid=$CLIENT_PID
  CLIENTS="\$7 100 $pid" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: not-from-mac: this session is attached from pixel; the hand-off runs only from a session attached from bretts-air"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "the server console (no SSH_CONNECTION) is refused without dialing" {
  fixture "$FIX/dev/n.md"
  unset SSH_CONNECTION
  dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"not-from-mac: this session is on the server console"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "a tmux client with no SSH_CONNECTION reads as the server console" {
  fixture "$FIX/dev/n.md"
  in_tmux
  client_with ""
  pid=$CLIENT_PID
  CLIENTS="\$7 100 $pid" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"not-from-mac: this session is on the server console"* ]]
}

@test "outside tmux, the session's own SSH_CONNECTION from the Mac proceeds" {
  fixture "$FIX/dev/n.md"
  dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
  [ "$(ssh_calls)" -eq 1 ]
}

@test "with neither jaq nor jq installed the guard fails closed naming the tool" {
  fixture "$FIX/dev/n.md"
  nojq="$BATS_TEST_TMPDIR/nojq"
  mkdir -p "$nojq"
  for f in /usr/bin/* /bin/*; do
    case ${f##*/} in jq | jaq) ;; *) [[ -e $nojq/${f##*/} ]] || ln -s "$f" "$nojq/" ;; esac
  done
  PATH="$STUBS:$nojq" run --separate-stderr "$SCRIPT" edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"not-from-mac: neither jaq nor jq is installed"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "a failing tailscale whois fails closed without dialing" {
  fixture "$FIX/dev/n.md"
  WHOIS_EXIT=1 dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"not-from-mac: tailscale whois could not name $MAC_ADDR"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "of two clients in the session, the most recently active decides" {
  fixture "$FIX/dev/n.md"
  in_tmux
  client_with "$MAC_ADDR 50000 100.64.0.1 22"
  mac=$CLIENT_PID
  client_with "$OTHER_ADDR 40000 100.64.0.1 22"
  other=$CLIENT_PID
  CLIENTS=$'$7 200 '"$other"$'\n$7 100 '"$mac" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"attached from pixel"* ]]
  CLIENTS=$'$7 100 '"$other"$'\n$7 200 '"$mac" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
}

@test "a more recent client of a different session is ignored" {
  fixture "$FIX/dev/n.md"
  in_tmux
  client_with "$MAC_ADDR 50000 100.64.0.1 22"
  mac=$CLIENT_PID
  client_with "$OTHER_ADDR 40000 100.64.0.1 22"
  other=$CLIENT_PID
  CLIENTS=$'$9 900 '"$other"$'\n$7 100 '"$mac" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
  grep -q '^tmux list-clients -t \$7 ' "$CALLS"
}

@test "two clients tied on activity proceed when either is the Mac" {
  fixture "$FIX/dev/n.md"
  in_tmux
  client_with "$OTHER_ADDR 40000 100.64.0.1 22"
  other=$CLIENT_PID
  client_with "$MAC_ADDR 50000 100.64.0.1 22"
  mac=$CLIENT_PID
  CLIENTS=$'$7 300 '"$other"$'\n$7 300 '"$mac" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
}

@test "the guard's tmux calls run under a 3 s foreground bound" {
  fixture "$FIX/dev/n.md"
  in_tmux
  client_with "$MAC_ADDR 50000 100.64.0.1 22"
  CLIENTS="\$7 100 $CLIENT_PID" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
  grep -q '^timeout --foreground 3 tmux display-message ' "$CALLS"
  grep -q '^timeout --foreground 3 tmux list-clients -t \$7 ' "$CALLS"
}

@test "a tmux session with no client fails closed without dialing" {
  fixture "$FIX/dev/n.md"
  in_tmux
  CLIENTS="" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: not-from-mac: tmux reported no client for this session; the hand-off runs only from a session attached from bretts-air"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "a failing tmux list-clients fails closed without dialing" {
  fixture "$FIX/dev/n.md"
  in_tmux
  TMUX_EXIT=1 dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"not-from-mac: tmux reported no client for this session; "* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "a tmux server that does not answer within the bound fails closed without dialing" {
  fixture "$FIX/dev/n.md"
  in_tmux
  TIMEOUT_EXIT=124 dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"not-from-mac: tmux reported no client for this session; "* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Edit route
# ---------------------------------------------------------------------------

@test "edit of three files is one ssh call naming all three and the server alias (AE8)" {
  for f in a b c; do fixture "$FIX/outside/$f.md"; done
  MAC_OPEN_SERVER_ALIAS=srv dispatch edit "$FIX/outside/a.md" "$FIX/outside/b.md" "$FIX/outside/c.md"
  [ "$status" -eq 0 ]
  [ "$(ssh_calls)" -eq 1 ]
  [ "$(cat "$RECEIVED")" = "$(printf '%s\n' edit srv "$FIX/outside/a.md" "$FIX/outside/b.md" "$FIX/outside/c.md")" ]
}

@test "a path with a space and a single quote reaches the receiver intact" {
  fixture "$FIX/outside/it's a note.md"
  MAC_OPEN_SERVER_ALIAS=srv dispatch edit "$FIX/outside/it's a note.md"
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p "$RECEIVED")" = "$FIX/outside/it's a note.md" ]
}

@test "edit sends absolute paths, resolved from a relative one" {
  fixture "$FIX/outside/rel.md"
  cd "$FIX/outside"
  MAC_OPEN_SERVER_ALIAS=srv dispatch edit rel.md
  [ "$status" -eq 0 ]
  [ "$(sed -n 3p "$RECEIVED")" = "$FIX/outside/rel.md" ]
}

@test "edit on a directory reports not-a-file and dials nothing" {
  dispatch edit "$FIX/dev"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: not-a-file: $FIX/dev is not a regular file; directories open locally"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "edit of a missing path reports not-a-file naming the argument as given and dials nothing" {
  cd "$FIX/outside"
  dispatch edit missing.md
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: not-a-file: missing.md is not a regular file; directories open locally"* ]]
  [ "$(ssh_calls)" -eq 0 ]
}

@test "edit and view calls carry -n and a foreground 20 s bound, over BatchMode with a 3 s connect timeout" {
  fixture "$FIX/dev/n.md"
  fixture "$FIX/dev/x.pdf"
  dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
  dispatch view "$FIX/dev/x.pdf"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^timeout --foreground 20 ssh -n -o BatchMode=yes -o ConnectTimeout=3 bretts-air ' "$CALLS")" -eq 2 ]
}

@test "MAC_OPEN_HOST and MAC_OPEN_SERVER_ALIAS reach the ssh argv and the remote command" {
  fixture "$FIX/dev/n.md"
  WHOIS="$MAC_ADDR=studio" MAC_OPEN_HOST=studio MAC_OPEN_SERVER_ALIAS=box dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 0 ]
  grep -q -- '-o ConnectTimeout=3 studio ' "$CALLS"
  [ "$(sed -n 2p "$RECEIVED")" = "box" ]
}

# ---------------------------------------------------------------------------
# View route
# ---------------------------------------------------------------------------

@test "view of a file under a share opens it at the share's mount path, with no stdin payload" {
  fixture "$FIX/dev/foo/x.pdf"
  dispatch view "$FIX/dev/foo/x.pdf"
  [ "$status" -eq 0 ]
  [ "$(cat "$RECEIVED")" = "$(printf '%s\n' view dev /Volumes/dev/foo/x.pdf)" ]
  [ ! -e "$STDIN_COPY" ]
}

@test "view maps a symlink by its target" {
  fixture "$FIX/vault/real.png"
  ln -s "$FIX/vault/real.png" "$FIX/outside/link.png"
  dispatch view "$FIX/outside/link.png"
  [ "$status" -eq 0 ]
  [ "$(cat "$RECEIVED")" = "$(printf '%s\n' view vault /Volumes/vault/real.png)" ]
}

@test "view picks the longest share root when roots nest" {
  mkdir -p "$FIX/dev/sub"
  fixture "$FIX/dev/sub/deep.pdf"
  DRIVE_TABLE="$DRIVE_TABLE"$'\n'"sub      $FIX/dev/sub    brett" dispatch view "$FIX/dev/sub/deep.pdf"
  [ "$status" -eq 0 ]
  [ "$(cat "$RECEIVED")" = "$(printf '%s\n' view sub /Volumes/sub/deep.pdf)" ]
}

@test "view of files under two shares makes one call per share" {
  fixture "$FIX/dev/a.pdf"
  fixture "$FIX/vault/b.png"
  fixture "$FIX/dev/c.pdf"
  dispatch view "$FIX/dev/a.pdf" "$FIX/vault/b.png" "$FIX/dev/c.pdf"
  [ "$status" -eq 0 ]
  [ "$(ssh_calls)" -eq 2 ]
  [ "$(cat "$RECEIVED")" = "$(printf '%s\n' view dev /Volumes/dev/a.pdf /Volumes/dev/c.pdf view vault /Volumes/vault/b.png)" ]
}

@test "view of a file outside every share streams a copy and reports it (AE4)" {
  head -c 3145728 /dev/zero >"$FIX/outside/shot.png"
  # The receiver prints the copy's path as the operator reads it on the Mac.
  # shellcheck disable=SC2088
  YAZI_ID=1 RECEIVER_OUT="~/Downloads/mac-open/1-shot.png" dispatch view "$FIX/outside/shot.png"
  [ "$status" -eq 0 ]
  [ "$(cat "$RECEIVED")" = "$(printf '%s\n' receive shot.png 3145728)" ]
  cmp "$FIX/outside/shot.png" "$STDIN_COPY"
  grep -q '^timeout --foreground 23 ssh -o BatchMode=yes' "$CALLS"
  [[ $stderr == *"mac-open: copying shot.png (3.0MiB) to the Mac"* ]]
  [[ $stderr == *"mac-open: opened a copy at ~/Downloads/mac-open/1-shot.png on the Mac; edits there do not write back"* ]]
  [[ $(ya_line) == *"--content=opened a copy at ~/Downloads/mac-open/1-shot.png"*"--level=info"* ]]
}

@test "the copy is announced before the receive call is made" {
  fixture "$FIX/outside/shot.png"
  stub timeout '
    log timeout "$@"
    printf "stderr-at-dial:%s\n" "$(cat "$ANNOUNCE_PROBE" 2>/dev/null)" >>"$CALLS"
    while [[ $1 == -* ]]; do shift; done
    shift
    exec "$@"'
  export ANNOUNCE_PROBE="$BATS_TEST_TMPDIR/err"
  PATH="$STUBS:$PATH" "$SCRIPT" view "$FIX/outside/shot.png" 2>"$ANNOUNCE_PROBE"
  grep -q 'stderr-at-dial:mac-open: copying shot.png' "$CALLS"
}

@test "an unreadable share table sends every file down the copy route and says so" {
  fixture "$FIX/dev/x.pdf"
  DRIVE_TABLE="something else entirely" dispatch view "$FIX/dev/x.pdf"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$RECEIVED")" = "receive" ]
  [[ $stderr == *"share-table: tailscale drive list printed an unexpected table"* ]]
}

@test "a share table with no shares copies the file without a share-table warning" {
  fixture "$FIX/outside/x.pdf"
  DRIVE_TABLE=$'name     path    as\n-----    ----    --' dispatch view "$FIX/outside/x.pdf"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$RECEIVED")" = "receive" ]
  [[ $stderr != *"share-table"* ]]
}

@test "a failed receive after a successful share call fails the whole selection" {
  fixture "$FIX/dev/a.pdf"
  fixture "$FIX/outside/b.png"
  SSH_FAIL_MATCH=receive SSH_EXIT=1 SSH_ERR="mac-open-here: copy-failed: disk full; free space" \
    dispatch view "$FIX/dev/a.pdf" "$FIX/outside/b.png"
  [ "$status" -eq 1 ]
  [ "$(ssh_calls)" -eq 2 ]
  [[ $stderr == *"remote-failed: mac-open-here: copy-failed: disk full"* ]]
}

@test "an unreachable Mac stops the remaining copies after one call" {
  fixture "$FIX/outside/a.png"
  fixture "$FIX/outside/b.png"
  SSH_EXIT=255 SSH_ERR="ssh: connect to host bretts-air port 22: Operation timed out" \
    dispatch view "$FIX/outside/a.png" "$FIX/outside/b.png"
  [ "$status" -eq 1 ]
  [ "$(ssh_calls)" -eq 1 ]
  [ "$(grep -c 'unreachable:' <<<"$stderr")" -eq 1 ]
  [[ $stderr != *"copying b.png"* ]]
}

@test "a timed-out share call stops the remaining share and copy calls" {
  fixture "$FIX/dev/a.pdf"
  fixture "$FIX/vault/b.png"
  fixture "$FIX/outside/c.png"
  TIMEOUT_EXIT=124 dispatch view "$FIX/dev/a.pdf" "$FIX/vault/b.png" "$FIX/outside/c.png"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^timeout ' "$CALLS")" -eq 1 ]
  [ "$(grep -c 'timed-out:' <<<"$stderr")" -eq 1 ]
  [[ $stderr != *"copying"* ]]
}

# ---------------------------------------------------------------------------
# Failure reasons: each is one line ending in its next step
# ---------------------------------------------------------------------------

@test "ssh 255 quoting a host key failure reports unreachable with the Remote Login step (AE5)" {
  fixture "$FIX/dev/n.md"
  YAZI_ID=1 SSH_EXIT=255 SSH_ERR="Host key verification failed." dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: unreachable: Host key verification failed.; check that bretts-air is awake with Remote Login on"* ]]
  [[ $(ya_line) == *"--level=warn"* ]]
}

@test "ssh 255 with nothing on stderr still reports unreachable with the Remote Login step" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=255 SSH_ERR="" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: unreachable: ssh failed; check that bretts-air is awake with Remote Login on"* ]]
}

@test "ssh 255 with Permission denied names the Mac's authorized_keys" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=255 SSH_ERR=$'Warning: Permanently added host\nbrett@bretts-air: Permission denied (publickey).' \
    dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"unreachable: brett@bretts-air: Permission denied (publickey).; bretts-air's ~/.ssh/authorized_keys does not carry this host's key"* ]]
  [[ $stderr != *"Remote Login"* ]]
}

@test "the timeout's own expiry reports timed-out" {
  fixture "$FIX/dev/n.md"
  TIMEOUT_EXIT=124 dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: timed-out: bretts-air stopped answering after connecting; retry, and check the Mac if it keeps happening"* ]]
}

@test "a missing receiver (127) names the Mac-side deploy" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=127 dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: receiver-missing: bretts-air has no ~/.local/bin/mac-open-here; run 'cd ~/dotfiles && git pull && scripts/stow-deploy local' on bretts-air"* ]]
}

@test "an older receiver's usage error (2) names the Mac-side deploy" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=2 SSH_ERR="usage: mac-open-here edit ..." dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: receiver-outdated: bretts-air's mac-open-here does not know this request; run 'cd ~/dotfiles && git pull && scripts/stow-deploy local' on bretts-air"* ]]
}

@test "a receiver failure is reported as remote-failed with the receiver's line (AE6)" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=1 SSH_ERR=$'zsh: some startup notice\nmac-open-here: code-cli-missing: no VS Code CLI at /x; install VS Code or set MAC_OPEN_CODE_CLI' \
    dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: remote-failed: mac-open-here: code-cli-missing: no VS Code CLI at /x; install VS Code or set MAC_OPEN_CODE_CLI"* ]]
}

@test "a failure the receiver did not print still names a next step" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=1 SSH_ERR="zsh: segmentation fault" dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: remote-failed: zsh: segmentation fault; "* ]]
}

@test "a short copy on the Mac reports short-copy with the byte counts" {
  fixture "$FIX/outside/big.bin"
  SSH_EXIT=1 SSH_ERR="mac-open-here: short-copy: 3 of 7 bytes arrived; retry, or move the file under a share to open it in place" \
    dispatch view "$FIX/outside/big.bin"
  [ "$status" -eq 1 ]
  [[ $stderr == *"mac-open: short-copy: 3 of 7 bytes arrived; retry, or move the file under a share to open it in place"* ]]
}

# ---------------------------------------------------------------------------
# Notifications
# ---------------------------------------------------------------------------

@test "without YAZI_ID no notification is sent" {
  fixture "$FIX/dev/n.md"
  SSH_EXIT=127 dispatch edit "$FIX/dev/n.md"
  sleep 0.5
  [ ! -s "$YA_LOG" ]
}

@test "with YAZI_ID the reason goes to yazi as single-token notify:push arguments" {
  fixture "$FIX/dev/n.md"
  YAZI_ID=1 SSH_EXIT=127 dispatch edit "$FIX/dev/n.md"
  line=$(ya_line)
  [[ $line == *"emit notify:push --title=mac-open --content=receiver-missing: bretts-air has no"*" --level=warn --timeout=8" ]]
}

@test "a failing ya leaves the exit status and the stderr line unchanged" {
  fixture "$FIX/dev/n.md"
  YAZI_ID=1 YA_EXIT=1 SSH_EXIT=127 dispatch edit "$FIX/dev/n.md"
  [ "$status" -eq 1 ]
  [ "$stderr" = "mac-open: receiver-missing: bretts-air has no ~/.local/bin/mac-open-here; run 'cd ~/dotfiles && git pull && scripts/stow-deploy local' on bretts-air" ]
}

@test "under an opener's sh, the notification waits for the fallback to finish" {
  fixture "$FIX/dev/n.md"
  done_at="$BATS_TEST_TMPDIR/fallback-done"
  YAZI_ID=1 SSH_EXIT=127 PATH="$STUBS:$PATH" sh -c '"$1" edit "$2" 2>/dev/null || { sleep 1; date +%s%N >"$3"; }' \
    sh "$SCRIPT" "$FIX/dev/n.md" "$done_at"
  line=$(ya_line)
  [ -n "$line" ]
  [ "${line%% *}" -ge "$(cat "$done_at")" ]
}
