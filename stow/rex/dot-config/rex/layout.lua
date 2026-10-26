-- The tmuxinator main-vertical window: yazi on the left, a shell top right,
-- lazygit bottom right, with the side and bottom panes at a third each.
local SHELL = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"
local SIDE_RATIO = 0.33
local BOTTOM_RATIO = 0.33

local function check(result, err)
  if err ~= nil then error(err, 0) end
  return result
end

-- The terminal reports its directory as a file:// URL with the host name and
-- percent-encoding, such as file://host/Users/me/My%20Repo.
local function cwd_of(block_id)
  if block_id then
    local r = rex.block.call(TERMINAL, "pwd", { block_id = block_id })
    local path = r and r.pwd and r.pwd:match("^file://[^/]*(/.*)$")
    if path then
      return (path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
    end
  end
  return os.getenv("HOME")
end

local function block(options)
  return rex.layout.block{ flavor = SHELL, options = options }
end

-- initial_input types the command into an interactive shell, as tmuxinator
-- does, so `y` (a shell function) resolves and the pane outlives the program.
local function pane(cwd, input)
  local options = { cwd = cwd }
  if input then options.initial_input = input .. "\n" end
  return block(options)
end

-- Splits left to the left of the anchor block and below beneath it, and
-- returns the three block IDs left to right, top to bottom.
local function around(anchor_id, left, below)
  local l = check(rex.session.new_split{
    anchor_id = anchor_id, direction = "horizontal", side = "before",
    ratio = SIDE_RATIO, layout = left,
  })
  local b = check(rex.session.new_split{
    anchor_id = anchor_id, direction = "vertical", side = "after",
    ratio = 1 - BOTTOM_RATIO, layout = below,
  })
  return { l.block_ids[1], anchor_id, b.block_ids[1] }
end

rex.action{
  name = "dev_layout",
  title = "New Dev Layout Tab",
  description = "Open a tab with yazi on the left, a shell top right, and lazygit bottom right.",
  category = "Layout",
  run = function(ctx)
    local cwd = cwd_of(ctx.block_id)
    local w = check(rex.session.new_window{
      layout = rex.layout.horizontal(SIDE_RATIO,
        pane(cwd, "y"),
        rex.layout.vertical(1 - BOTTOM_RATIO, pane(cwd), pane(cwd, "lazygit"))),
    })
    check(rex.session.focus_block{ block_id = w.block_ids[2] })
    return { window_id = w.window_id, block_ids = w.block_ids }
  end,
}

rex.action{
  name = "dev_layout_here",
  title = "Dev Layout Around Pane",
  description = "Add yazi to the left of the focused pane and lazygit below it.",
  category = "Layout",
  run = function(ctx)
    if not ctx.block_id then error("no focused pane", 0) end
    local cwd = cwd_of(ctx.block_id)
    return { block_ids = around(ctx.block_id, pane(cwd, "y"), pane(cwd, "lazygit")) }
  end,
}

-- Bindings to wire up later. A shortcut set in the app overrides these.
-- rex.bind("cmd+shift+l", "dev_layout")
-- rex.bind("cmd+alt+l", "dev_layout_here")

return {
  SHELL = SHELL,
  SIDE_RATIO = SIDE_RATIO,
  BOTTOM_RATIO = BOTTOM_RATIO,
  check = check,
  block = block,
  pane = pane,
  around = around,
}
