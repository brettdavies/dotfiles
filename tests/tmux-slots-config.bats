#!/usr/bin/env bats
# Tests for the tmux configuration split: base.conf holds the settings both
# servers share, tmux.conf adds the plugins for the operator's default server,
# and slots.conf configures the dedicated `agent-slots` server that agent-slot
# sessions run on.
#
# Run: bats tests/tmux-slots-config.bats
#
# Real-server tests load the repo copies under a per-test TMUX_TMPDIR, so they
# never reach the operator's default server or the live agent-slots socket, and
# skip when tmux is not installed. TMUX_PLUGIN_MANAGER_PATH points tpm at an
# empty directory: with the operator's plugins installed, tmux-continuum would
# otherwise restore saved sessions into the test server.

bats_require_minimum_version 1.5.0

TMUX_CONF_DIR="$BATS_TEST_DIRNAME/../stow/tmux/dot-config/tmux"
BASE_CONF="$TMUX_CONF_DIR/base.conf"
TMUX_CONF="$TMUX_CONF_DIR/tmux.conf"
SLOTS_CONF="$TMUX_CONF_DIR/slots.conf"

setup() {
  # A unix socket path is capped near 104 bytes, which a long TMPDIR under
  # BATS_TEST_TMPDIR can exceed.
  SOCK_DIR=$(mktemp -d /tmp/tmux-slots-test.XXXXXX)
  export TMUX_TMPDIR="$SOCK_DIR"
  export TMUX=
  export TMUX_PLUGIN_MANAGER_PATH="$BATS_TEST_TMPDIR/plugins/"
  mkdir -p "$TMUX_PLUGIN_MANAGER_PATH"
}

teardown() {
  local sock
  for sock in "$SOCK_DIR"/tmux-*/*; do
    [ -S "$sock" ] || continue
    timeout 10 tmux -S "$sock" kill-server 2>/dev/null || true
  done
  rm -rf "$SOCK_DIR"
}

# start_server SOCKET CONF: a detached server on SOCKET whose only config file
# is CONF. Later `tm` calls address it.
#
# Its panes run /bin/sh. The operator's login zsh would start powerlevel10k's
# gitstatus daemon, which init adopts, so it outlives kill-server and the leak
# guard in scripts/run-tests kills it and fails the suite.
start_server() {
  command -v tmux >/dev/null 2>&1 || skip "tmux not installed"
  SOCKET="$1"
  timeout 20 tmux -L "$SOCKET" -f "$2" start-server \; set-option -g default-shell /bin/sh \; \
    new-session -d -s probe
}

tm() {
  timeout 10 tmux -L "$SOCKET" "$@"
}

# assert_options SCOPE NAME=VALUE...: each option reads back VALUE.
assert_options() {
  local scope=$1 pair got failures=()
  shift
  for pair in "$@"; do
    got=$(tm show-options "$scope" -v "${pair%%=*}")
    [ "$got" = "${pair#*=}" ] || failures+=("${pair%%=*}: want '${pair#*=}', got '$got'")
  done
  [ "${#failures[@]}" -eq 0 ] || printf '%s\n' "${failures[@]}"
  [ "${#failures[@]}" -eq 0 ]
}

# assert_shared_settings: the base.conf settings both servers carry unchanged.
assert_shared_settings() {
  assert_options -g prefix=C-Space mouse=on base-index=1 renumber-windows=on \
    history-limit=50000 set-clipboard=on focus-events=on mode-keys=vi
  assert_options -gw pane-base-index=1
  assert_options -s escape-time=0 extended-keys=always
}

# ---------------------------------------------------------------------------
# File shape (runs without tmux)
# ---------------------------------------------------------------------------

@test "tmux.conf and slots.conf source base.conf from beside themselves" {
  grep -qxF "source-file -F '#{d:current_file}/base.conf'" "$TMUX_CONF"
  grep -qxF "source-file -F '#{d:current_file}/base.conf'" "$SLOTS_CONF"
}

@test "base.conf carries no plugin or reload binding, and no hook but the two focus hooks" {
  run grep -nE '@plugin|@resurrect|@continuum|tpm|^[[:space:]]*run|^bind r ' "$BASE_CONF"
  [ "$status" -eq 1 ]
  run grep -E '^[[:space:]]*set-hook' "$BASE_CONF"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "set-hook -g client-focus-out "* ]]
  [[ "${lines[1]}" == "set-hook -g client-focus-in "* ]]
}

@test "tmux.conf declares its plugins and runs tpm on its last line" {
  grep -qF "set -g @plugin 'tmux-plugins/tmux-resurrect'" "$TMUX_CONF"
  grep -qF "set -g @plugin 'tmux-plugins/tmux-continuum'" "$TMUX_CONF"
  [ "$(grep -v '^[[:space:]]*$' "$TMUX_CONF" | tail -1)" = "run '~/.tmux/plugins/tpm/tpm'" ]
}

@test "slots.conf loads no plugin and sources nothing but base.conf" {
  run grep -nE '@plugin|@resurrect|@continuum|tpm|^[[:space:]]*run[[:space:]]' "$SLOTS_CONF"
  [ "$status" -eq 1 ]
  run grep -nE '^[[:space:]]*source' "$SLOTS_CONF"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"/base.conf'" ]]
}

@test "slots.conf overrides the slot settings and sets the replay and prune hooks" {
  grep -qx 'set -g detach-on-destroy on' "$SLOTS_CONF"
  grep -qx 'set -g set-titles off' "$SLOTS_CONF"
  grep -qx 'set -g allow-passthrough all' "$SLOTS_CONF"
  grep -qxF "set-hook -g client-attached \"run-shell -b '~/.claude/slot-status.sh --replay #{socket_path}'\"" "$SLOTS_CONF"
  grep -qxF "set-hook -g client-detached \"run-shell -b '~/dotfiles/scripts/tmux/prune-orphans.sh -L agent-slots'\"" "$SLOTS_CONF"
}

# ---------------------------------------------------------------------------
# The operator's default server (tmux.conf)
# ---------------------------------------------------------------------------

@test "tmux.conf applies every shared setting and keeps the operator's overrides" {
  start_server u3-operator "$TMUX_CONF"

  assert_shared_settings
  assert_options -g allow-passthrough=on detach-on-destroy=off set-titles=on
}

@test "tmux.conf keeps its plugins, default-server prune hook, and tmux.conf reload" {
  start_server u3-operator "$TMUX_CONF"

  [ "$(tm show-options -gv @plugin)" = tmux-plugins/tmux-continuum ]
  assert_options -g @continuum-restore=on @resurrect-capture-pane-contents=on

  run tm show-hooks -g client-detached
  [[ "$output" == *"run-shell -b "*"/scripts/tmux/prune-orphans.sh" ]]

  run tm list-keys -T prefix r
  [[ "$output" == *"source-file "*"/.config/tmux/tmux.conf "* ]]

  if [ -x "$HOME/.tmux/plugins/tpm/tpm" ]; then
    run tm list-keys -T prefix I
    [[ "$output" == *"tpm/bindings/install_plugins"* ]]
  fi
}

# ---------------------------------------------------------------------------
# The slot server (slots.conf)
# ---------------------------------------------------------------------------

@test "a slot server loads slots.conf with the shared settings and the slot overrides" {
  start_server agent-slots "$SLOTS_CONF"

  [ "$(tm display-message -p '#{socket_path}')" = "$SOCK_DIR/tmux-$(id -u)/agent-slots" ]
  assert_shared_settings
  assert_options -g detach-on-destroy=on set-titles=off allow-passthrough=all
}

@test "a slot server replays status on attach and prunes its own orphans on detach" {
  start_server agent-slots "$SLOTS_CONF"

  run tm show-hooks -g client-attached
  [[ "$output" == *"run-shell -b"*"/.claude/slot-status.sh --replay #{socket_path}"* ]]

  run tm show-hooks -g client-detached
  [[ "$output" == *"run-shell -b"*"/scripts/tmux/prune-orphans.sh -L agent-slots"* ]]

  run tm list-keys -T prefix r
  [[ "$output" == *"source-file "*"/.config/tmux/slots.conf "* ]]
}

# wait_window_style VALUE: the probe window's own window-active-style reads back VALUE within five seconds.
wait_window_style() {
  local tries=0
  until [ "$(tm show-options -wv -t probe window-active-style)" = "$1" ]; do
    ((tries++ < 50)) || return 1
    sleep 0.1
  done
}

# focus_round_trip CONF SOCKET: a client attached to a server on SOCKET running CONF reports its terminal losing
# focus, then regaining it.
focus_round_trip() {
  command -v script >/dev/null || skip "script(1) gives the tmux client a terminal"
  start_server "$2" "$1"
  local fifo=$BATS_TEST_TMPDIR/client-in-$2 tries=0
  mkfifo "$fifo"
  script -qec "TERM=xterm-256color tmux -L $SOCKET attach -t probe" /dev/null <"$fifo" >/dev/null 2>&1 3>&- &
  exec 7>"$fifo"
  until [ "$(tm list-clients | wc -l)" -ge 1 ]; do
    ((tries++ < 50)) || return 1
    sleep 0.1
  done
  printf '\033[O' >&7
  wait_window_style 'bg=#3c2010'
  printf '\033[I' >&7
  wait_window_style ''
  [ "$(tm show-options -gwv window-active-style)" = 'bg=#1e1e1e' ]
  exec 7>&-
}

@test "on both servers, a terminal that loses focus tints the whole view amber, and regaining focus restores it" {
  focus_round_trip "$TMUX_CONF" focus-operator
  focus_round_trip "$SLOTS_CONF" focus-slots
}

@test "a slot server loads none of tmux.conf's plugins" {
  start_server agent-slots "$SLOTS_CONF"

  run tm show-options -g
  [ "$status" -eq 0 ]
  run grep -E '^@(plugin|resurrect-|continuum-)' <<<"$output"
  [ "$status" -eq 1 ]

  run tm list-keys
  [ "$status" -eq 0 ]
  [[ "$output" != *tpm* ]]
  [[ "$output" != *resurrect* ]]
  [[ "$output" != *continuum* ]]
}
