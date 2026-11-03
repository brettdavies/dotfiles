#!/usr/bin/env bats
# The Rex config package: init.lua, layout.lua, agent-slots.lua, and the Linux server's slot-startup.lua. CI has no Lua
# and no Rex, so these hold the files to their contracts by text; `rex config check` loads them for real.
#
# Run: bats tests/rex-config.bats

REX_DIR="$BATS_TEST_DIRNAME/../stow/rex/dot-config/rex"
INIT="$REX_DIR/init.lua"
LAYOUT="$REX_DIR/layout.lua"
SLOTS="$REX_DIR/agent-slots.lua"
STARTUP="$REX_DIR/slot-startup.lua"

@test "init.lua loads the start-up step only where its module is deployed, else restores with rexurrect, and starts no follow loop" {
  grep -qx 'require("layout")' "$INIT"
  grep -qx 'require("agent-slots")' "$INIT"
  grep -q '"/rex/slot-startup.lua"' "$INIT"
  grep -qx '  require("slot-startup")' "$INIT"
  grep -q 'rex.exec({ os.getenv("HOME") .. "/.local/bin/rexurrect", "auto-restore" }' "$INIT"
  grep -q 'REXURRECT_STATE_DIR = os.getenv("HOME") .. "/.local/state/rexurrect"' "$INIT"
  [ "$(grep -c '/Users/' "$INIT")" -eq 0 ]
  run grep -n 'follow' "$INIT" "$STARTUP"
  [ "$status" -eq 1 ]
}

@test "the start-up step is named once, in the Linux-only module, started detached by the helper's path" {
  [ "$(cat "$INIT" "$SLOTS" "$STARTUP" | grep -c -- '--at-start')" -eq 1 ]
  grep -qF 'rex.exec.start({ os.getenv("HOME") .. "/.local/bin/agent-slot-rex", "restore", "--at-start" }, { detach = true })' \
    "$STARTUP"
}

@test "layout.lua keeps both dev layout actions, their ratios, programs, and focus" {
  grep -q 'name = "dev_layout",' "$LAYOUT"
  grep -q 'title = "New Dev Layout Tab",' "$LAYOUT"
  grep -q 'name = "dev_layout_here",' "$LAYOUT"
  grep -q 'title = "Dev Layout Around Pane",' "$LAYOUT"
  grep -qx 'local SIDE_RATIO = 0.33' "$LAYOUT"
  grep -qx 'local BOTTOM_RATIO = 0.33' "$LAYOUT"
  grep -q 'pane(cwd, "y")' "$LAYOUT"
  grep -q 'pane(cwd, "lazygit")' "$LAYOUT"
  grep -q 'rex.session.focus_block{ block_id = w.block_ids\[2\] }' "$LAYOUT"
}

@test "layout.lua returns its pane builders and ratios for agent-slots.lua" {
  grep -qx 'return {' "$LAYOUT"
  local name
  for name in SIDE_RATIO BOTTOM_RATIO check block pane around; do
    grep -qx "  $name = $name," "$LAYOUT"
  done
}

@test "agent-slots.lua requires layout and defines the new-agent, restore, and layout actions" {
  grep -qx 'local layout = require("layout")' "$SLOTS"
  grep -q 'name = "agent_slot_new",' "$SLOTS"
  grep -q 'name = "agent_slot_restore",' "$SLOTS"
  grep -q 'name = "agent_slot_layout",' "$SLOTS"
  grep -q 'key = { type = "string"' "$SLOTS"
  grep -q 'required = { "key" }' "$SLOTS"
}

@test "the new-agent action opens its tab without focus, running the launch in that tab" {
  awk '/name = "agent_slot_new"/,/^}/' "$SLOTS" >"$BATS_TEST_TMPDIR/new"
  grep -q 'rex.session.new_window{' "$BATS_TEST_TMPDIR/new"
  grep -q 'focus = false,' "$BATS_TEST_TMPDIR/new"
  grep -q 'helper_pane("launch", "--here")' "$BATS_TEST_TMPDIR/new"
}

@test "the new-agent action always brings its tab forward, through the client that pressed the key" {
  awk '/name = "agent_slot_new"/,/^}/' "$SLOTS" >"$BATS_TEST_TMPDIR/new"
  grep -qx '    pcall(rex.client.queue, "session.select", { session_id = ctx.session_id, window_id = w.window_id })' \
    "$BATS_TEST_TMPDIR/new"
  run grep -nE 'is_known_repo|REPOS_FILE' "$SLOTS"
  [ "$status" -eq 1 ]
}

@test "the restore action starts the helper detached, and the layout action attaches the files and git panes" {
  grep -q 'rex.exec.start({ HELPER, "restore", "--tab" }, { detach = true })' "$SLOTS"
  grep -q 'helper_pane("attach", args.key, "files")' "$SLOTS"
  grep -q 'helper_pane("attach", args.key, "git")' "$SLOTS"
  grep -q 'layout.around(anchor,' "$SLOTS"
}

@test "panes name the helper bare, for the login shell of the host whose session holds them, and rex.exec by its path" {
  grep -qx 'local PANE_HELPER = "agent-slot-rex"' "$SLOTS"
  grep -qx 'local HELPER = os.getenv("HOME") .. "/.local/bin/agent-slot-rex"' "$SLOTS"
  grep -q 'command = { PANE_HELPER, ... }' "$SLOTS"
  run grep -n 'command = { HELPER' "$SLOTS"
  [ "$status" -eq 1 ]
  run grep -nE 'rex\.exec(\.start)?\(\{ PANE_HELPER' "$SLOTS"
  [ "$status" -eq 1 ]
}

@test "agent-slots.lua binds the new-agent and restore keys" {
  grep -qx 'rex.bind("cmd+alt+n", "agent_slot_new")' "$SLOTS"
  grep -qx 'rex.bind("cmd+alt+r", "agent_slot_restore")' "$SLOTS"
}

@test "every helper verb the Lua names is one agent-slot-rex has" {
  local verbs named verb
  verbs=$(grep '^VERBS=' "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib/help.sh")
  named=$(grep -ohE 'helper_pane\("[a-z]+"|HELPER, "[a-z]+"|agent-slot-rex", "[a-z]+"' "$SLOTS" "$INIT" "$STARTUP" \
    | grep -oE '"[a-z]+"$' | tr -d '"' | sort -u | paste -sd ' ' -)
  [ "$named" = "attach finish launch restore" ]
  for verb in $named; do
    [[ $verbs == *" $verb "* ]] || {
      echo "the Lua names a verb agent-slot-rex lacks: $verb" >&2
      return 1
    }
  done
}

@test "agent-slots.lua binds the finish key, which hands the focused pane to the helper's finish --tab" {
  grep -q 'rex.bind("cmd+alt+f", "agent_slot_finish")' "$REX_DIR/agent-slots.lua"
  grep -q '"finish", "--tab", "--session", ctx.session_id, "--block", ctx.block_id' "$REX_DIR/agent-slots.lua"
}
