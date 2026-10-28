do local r = rex.exec({ os.getenv("HOME") .. "/.local/bin/rexurrect", "auto-restore" }, { env = { REXURRECT_STATE_DIR = os.getenv("HOME") .. "/.local/state/rexurrect" } }) if r then io.stderr:write(r.stderr) end end
require("layout")
require("agent-slots")

-- Once the server's ssh answers, give every live agent slot its tab back.
rex.exec.start({ os.getenv("HOME") .. "/.local/bin/agent-slot-rex", "restore", "--wait-server" }, { detach = true })
-- Then keep the tabs following the server: a restore each minute, and at once after a sleep or a reconnect.
rex.exec.start({ os.getenv("HOME") .. "/.local/bin/agent-slot-rex", "follow" }, { detach = true })
