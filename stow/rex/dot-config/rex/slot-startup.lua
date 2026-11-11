-- The start-up step, on the Linux server only. It runs detached, waits for this server to finish loading, restores the
-- operator's own tabs with rexurrect once per server instance, then gives every live slot its tab. rex.exec hands its
-- child this server's bare PATH, so the helper is named by its path.
rex.exec.start({ os.getenv("HOME") .. "/.local/bin/agent-slot-rex", "restore", "--at-start" }, { detach = true })
