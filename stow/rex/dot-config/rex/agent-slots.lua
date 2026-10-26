-- Agent slots: Claude agents on the Linux server, each in its own clone, each
-- shown as one tab in its repo's session. Every tab and pane runs
-- agent-slot-rex, which talks to the server's agent-slot over ssh; this file
-- only opens the tabs and lays out a slot's panes.
local layout = require("layout")

local HELPER = os.getenv("HOME") .. "/.local/bin/agent-slot-rex"

local function helper_pane(...)
  return layout.block{ command = { HELPER, ... } }
end

rex.action{
  name = "agent_slot_new",
  title = "New Agent",
  description = "Start a Claude agent in a fresh slot of this session's repo, in a background tab.",
  category = "Agents",
  run = function(ctx)
    local w = layout.check(rex.session.new_window{
      focus = false,
      window_label = "new agent",
      layout = helper_pane("launch", "--here"),
    })
    return { window_id = w.window_id, block_ids = w.block_ids }
  end,
}

-- The helper opens the tab itself, in the agent-slots session, so a restore
-- never runs in a tab it might close.
rex.action{
  name = "agent_slot_restore",
  title = "Restore Agent Tabs",
  description = "Open a tab for every live slot, resume dormant ones, and close tabs whose slot is gone.",
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
  description = "Add a slot's files pane to the left of a pane and its git pane below it.",
  category = "Agents",
  args = {
    type = "object",
    properties = {
      key = { type = "string", description = "The slot, as <repo>/<N>." },
      block = { type = "string", description = "The slot's Claude pane; the focused pane when left out." },
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
