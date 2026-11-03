-- Tab numbers: every tab's label starts with its position in its session, as "<n>: ", and this watcher is the only
-- writer of that prefix. It runs as `rex --autostart=false do --all tab-numbers.lua` beside the Rex server. A window
-- move emits only session_view_changed and a new session's first window only session_created, so it hears both beside
-- the window events, and on each recomputes the whole session from session.view, whose windows are in tab order. A
-- label whose prefix is already right is never written, so its own writes settle after one pass.

-- The prefix as a pattern, written the same in the reconcile's jq; a test holds the two to one text.
local NUMBER_PREFIX = "^[0-9]+: "
-- Rex refuses a window label longer than this many characters.
local LABEL_LIMIT = 128

-- UTF-8 continuation bytes are 0x80 to 0xBF, so every other byte starts a character.
local function chars(s)
  local n = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b > 0xBF then n = n + 1 end
  end
  return n
end

-- Usage: head(s, n); the first n characters of s.
local function head(s, n)
  local count = 0
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 or b > 0xBF then
      count = count + 1
      if count > n then return s:sub(1, i - 1) end
    end
  end
  return s
end

-- A label over the limit keeps its first limit - 1 characters, less trailing spaces, then an ellipsis, as the slot
-- helper cuts its labels, so a label either writer cut is cut the same again.
local function fit(s, limit)
  if chars(s) <= limit then return s end
  return (head(s, limit - 1):gsub(" +$", "")) .. "…"
end

local function strip(label)
  local rest = label or ""
  while rest:find(NUMBER_PREFIX) do rest = rest:gsub(NUMBER_PREFIX, "", 1) end
  return rest
end

local function renumber(session_id)
  if not session_id then return end
  local view = rex.call("session.view", { session_id = session_id })
  if type(view) ~= "table" or type(view.windows) ~= "table" then return end
  for i, w in ipairs(view.windows) do
    local prefix = i .. ": "
    local want = prefix .. fit(strip(w.label), LABEL_LIMIT - chars(prefix))
    if w.label ~= want then
      rex.call("session.set_window_label", { session_id = session_id, window_id = w.window_id, label = want })
    end
  end
end

local function session_of(ctx, ev)
  return (ctx and ctx.session_id) or (ev and ev.session and ev.session.session_id)
end

for _, name in ipairs({ "window_created", "window_closed", "window_label_changed", "session_view_changed",
  "session_created" }) do
  rex.on(name, function(ctx, ev) renumber(session_of(ctx, ev)) end)
end

-- --all attaches the script to every session only once its top level has returned, so the first pass over the
-- sessions that already exist runs from a timer.
rex.after(0, function()
  local list = rex.call("session.list")
  for _, s in ipairs((type(list) == "table" and list.sessions) or {}) do renumber(s.session_id) end
end)
