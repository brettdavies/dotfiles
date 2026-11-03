require("layout")
require("agent-slots")

-- The Linux server, which hosts the slots, deploys slot-startup.lua: its start-up step restores the operator's own tabs
-- with rexurrect before it gives every live slot its tab, since a slot tab opened first would make rexurrect restore a
-- second copy of that repo's session. Elsewhere rexurrect restores on its own.
local config_home = os.getenv("XDG_CONFIG_HOME")
if config_home == nil or config_home == "" then config_home = os.getenv("HOME") .. "/.config" end
local startup = io.open(config_home .. "/rex/slot-startup.lua", "r")
if startup then
  startup:close()
  require("slot-startup")
else
  local r = rex.exec({ os.getenv("HOME") .. "/.local/bin/rexurrect", "auto-restore" }, { env = { REXURRECT_STATE_DIR = os.getenv("HOME") .. "/.local/state/rexurrect" } })
  if r then io.stderr:write(r.stderr) end
end
