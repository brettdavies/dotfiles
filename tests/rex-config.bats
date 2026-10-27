#!/usr/bin/env bats
# The Rex config package: init.lua, layout.lua, and agent-slots.lua. CI has no Lua and no Rex, so these hold the files
# to their contracts by text; `rex config check` on the Mac loads them for real.
#
# Run: bats tests/rex-config.bats

REX_DIR="$BATS_TEST_DIRNAME/../stow/rex/dot-config/rex"
INIT="$REX_DIR/init.lua"
LAYOUT="$REX_DIR/layout.lua"
SLOTS="$REX_DIR/agent-slots.lua"

@test "init.lua runs rexurrect from HOME, requires both modules, and starts one background restore" {
  grep -q 'rex.exec({ os.getenv("HOME") .. "/.local/bin/rexurrect", "auto-restore" }' "$INIT"
  grep -q 'REXURRECT_STATE_DIR = os.getenv("HOME") .. "/.local/state/rexurrect"' "$INIT"
  [ "$(grep -c '/Users/' "$INIT")" -eq 0 ]
  grep -qx 'require("layout")' "$INIT"
  grep -qx 'require("agent-slots")' "$INIT"
  [ "$(grep -c 'rex.exec.start' "$INIT")" -eq 1 ]
  grep -q 'rex.exec.start({ os.getenv("HOME") .. "/.local/bin/agent-slot-rex", "restore", "--wait-server" }, { detach = true })' \
    "$INIT"
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

@test "the new-agent action brings its tab forward, through the client that pressed the key, outside a repo's session" {
  awk '/name = "agent_slot_new"/,/^}/' "$SLOTS" >"$BATS_TEST_TMPDIR/new"
  grep -q 'if not is_known_repo(view and view.label) then' "$BATS_TEST_TMPDIR/new"
  grep -q 'pcall(rex.client.queue, "session.select", { session_id = ctx.session_id, window_id = w.window_id })' \
    "$BATS_TEST_TMPDIR/new"
  grep -q 'local REPOS_FILE = state_dir() .. "/repos"' "$SLOTS"
}

@test "the restore action starts the helper detached, and the layout action attaches the files and git panes" {
  grep -q 'rex.exec.start({ HELPER, "restore", "--tab" }, { detach = true })' "$SLOTS"
  grep -q 'helper_pane("attach", args.key, "files")' "$SLOTS"
  grep -q 'helper_pane("attach", args.key, "git")' "$SLOTS"
  grep -q 'layout.around(anchor,' "$SLOTS"
  grep -q 'local HELPER = os.getenv("HOME") .. "/.local/bin/agent-slot-rex"' "$SLOTS"
}

@test "agent-slots.lua binds the new-agent and restore keys" {
  grep -qx 'rex.bind("cmd+alt+n", "agent_slot_new")' "$SLOTS"
  grep -qx 'rex.bind("cmd+alt+r", "agent_slot_restore")' "$SLOTS"
}

@test "every helper verb the Lua names is one agent-slot-rex has" {
  local verbs named verb
  verbs=$(grep '^VERBS=' "$BATS_TEST_DIRNAME/../scripts/agent-slot-rex/lib/help.sh")
  named=$(grep -ohE 'helper_pane\("[a-z]+"|HELPER, "[a-z]+"|agent-slot-rex", "[a-z]+"' "$SLOTS" "$INIT" \
    | grep -oE '"[a-z]+"$' | tr -d '"' | sort -u | paste -sd ' ')
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
