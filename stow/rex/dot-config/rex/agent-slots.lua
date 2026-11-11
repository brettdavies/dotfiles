-- Agent slots: Claude agents on the Linux server, each in its own clone, each
-- shown as one tab in its repo's session on the Linux server's Rex server.
-- Both machines load these actions, since Rex.app offers only its own server's.
-- Pressed on the Mac, an action still acts on the Linux server: a pane it opens
-- in a Linux session runs there, and the Mac's helper hands what it runs on the
-- Mac to the Linux server's helper over ssh. This file only opens the tabs and
-- lays out a slot's panes.
local layout = require("layout")

-- A pane runs its command through the login shell of the host whose session
-- holds it, so the bare name finds that host's helper. rex.exec runs on the
-- host that loaded this file, with that server's bare PATH, so it takes the path.
local PANE_HELPER = "agent-slot-rex"
local HELPER = os.getenv("HOME") .. "/.local/bin/agent-slot-rex"

local function helper_pane(...)
  return layout.block{ command = { PANE_HELPER, ... } }
end

rex.action{
  name = "agent_slot_new",
  title = "New Agent",
  description = "Open the repo's prime as the session's first tab, or start an agent in a fresh slot, in a new tab.",
  category = "Agents",
  run = function(ctx)
    -- Rex.app gives an action the session of the pane it last focused. In a session with no tabs that pane can be in
    -- another session, on another host, and nothing an action can call tells which session the app shows; an action
    -- run with no session at all, as `rex do` outside a Rex terminal runs it, has no ctx.session_id.
    if not ctx.session_id then
      error("no session to open the tab in; in a session with no tabs, open one with cmd+t, then press the key", 0)
    end
    -- The helper in the tab decides what the tab becomes: the repo's prime, a slot's tab, or a repo picker. A key or
    -- palette press comes from an app, which performs the selection queued below, so the helper first waits to be
    -- shown; `rex do` has no app to select the tab.
    local launch = helper_pane("launch", "--here")
    if ctx.origin == "key" or ctx.origin == "palette" then launch = helper_pane("launch", "--here", "--wait-shown") end
    local w = layout.check(rex.session.new_window{
      focus = false,
      window_label = "new agent",
      layout = launch,
    })
    -- The new tab comes forward, since it may ask which repo to use. Rex.app shows the tab its own client selects, not
    -- the server's active window that `rex focus` sets, and it takes a client action from the CLI only with Remote
    -- Control on, so the selection is queued here, on the client that pressed the key.
    pcall(rex.client.queue, "session.select", { session_id = ctx.session_id, window_id = w.window_id })
    return { window_id = w.window_id, block_ids = w.block_ids }
  end,
}

-- The helper opens the tab itself, in the agent-slots session, so a restore
-- never runs in a tab it might close.
rex.action{
  name = "agent_slot_restore",
  title = "Restore Agent Tabs",
  description = "Open a tab for every live slot and running prime, resume dormant slots, and close tabs whose slot is gone.",
  category = "Agents",
  run = function()
    rex.exec.start({ HELPER, "restore", "--tab" }, { detach = true })
    return {}
  end,
}

-- The finish runs in a tab of the agent-slots session, so tearing the slot down never closes the tab the helper runs
-- in; the helper finds the slot of the tab holding the focused pane.
rex.action{
  name = "agent_slot_finish",
  title = "Finish Agent Task",
  description = "Finish the focused tab's task when it has no open PR, and tear its slot down when nothing in it is lost.",
  category = "Agents",
  run = function(ctx)
    if not ctx.block_id then error("no focused pane", 0) end
    rex.exec.start({ HELPER, "finish", "--tab", "--session", ctx.session_id, "--block", ctx.block_id },
      { detach = true })
    return {}
  end,
}

-- `rex do` passes no block to an action, so the helper names it in `block`.
rex.action{
  name = "agent_slot_layout",
  title = "Agent Slot Layout Around Pane",
  description = "Add the files pane of a slot or prime to the left of a pane and its git pane below it.",
  category = "Agents",
  args = {
    type = "object",
    properties = {
      key = { type = "string", description = "The slot, as <repo>/<N>, or the prime, as <repo>/prime." },
      block = { type = "string", description = "Its Claude pane; the focused pane when left out." },
    },
    required = { "key" },
  },
  run = function(ctx, args)
    local anchor = args.block or ctx.block_id
    if not anchor then error("no pane to lay out around", 0) end
    return {
      block_ids = layout.around(anchor, helper_pane("attach", args.key, "files"),
        helper_pane("attach", args.key, "git")),
    }
  end,
}

rex.bind("cmd+alt+n", "agent_slot_new")
rex.bind("cmd+alt+r", "agent_slot_restore")
rex.bind("cmd+alt+f", "agent_slot_finish")
