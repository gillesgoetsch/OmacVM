-- Parking and unparking of per-display workspaces against a fake Hyprland.
-- Run: XDG_RUNTIME_DIR=$(mktemp -d) lua src/workspaces/tests/monitor_workspaces_test.lua src/workspaces/guest/monitor_workspaces.lua
-- (Lua 5.4; a plain `make macosx` build of lua.org's source is enough.)
-- The fake: change_id fails when the ID is taken, empty hidden workspaces
-- vanish, and a display that comes back may get an empty workspace opened
-- on it first, as Hyprland does.
local modpath = arg[1]
local W, MON, VIS, handlers, rules
local log = {}

local function reset(monitors, workspaces)
  W, MON, VIS, handlers, rules = {}, {}, {}, {}, {}
  for _, m in ipairs(monitors) do MON[#MON+1] = m end
  for _, w in ipairs(workspaces) do
    W[w[1]] = { id = w[1], mon = w[2], windows = w[3] }
    if w[4] then VIS[w[2]] = w[1] end
  end
end

local function cleanup()
  for id, w in pairs(W) do
    if w.windows == 0 and VIS[w.mon] ~= id then W[id] = nil end
  end
end

local function monitor_rule(id)
  for _, r in ipairs(rules) do if r.workspace == tostring(id) then return r.monitor end end
end

hl = {}
function hl.get_monitors()
  local t = {}
  for _, m in ipairs(MON) do t[#t+1] = { name = m } end
  return t
end
function hl.get_workspaces()
  local t = {}
  for id, w in pairs(W) do t[#t+1] = { id = id, windows = w.windows, monitor = { name = w.mon } } end
  return t
end
function hl.get_active_monitor() return { name = MON[1] } end
function hl.get_active_workspace() return W[VIS[MON[1]]] and { id = VIS[MON[1]] } end
function hl.workspace_rule(r)
  for i, x in ipairs(rules) do if x.workspace == r.workspace then rules[i] = r; return end end
  rules[#rules+1] = r
end
hl.dsp = { workspace = {} }
function hl.dsp.workspace.change_id(a) return { "change_id", a } end
function hl.dsp.workspace.move(a) return { "move", a } end
function hl.dsp.focus(a) return { "focus", a } end
function hl.dispatch(d)
  local kind, a = d[1], d[2]
  if kind == "change_id" then
    local from, to = tonumber(a.workspace), a.id
    if not W[from] or W[to] then log[#log+1] = "change_id " .. from .. "->" .. to .. " FAILED"; return end
    W[to] = W[from]; W[to].id = to; W[from] = nil
    for m, v in pairs(VIS) do if v == from then VIS[m] = to end end
  elseif kind == "move" then
    local id = tonumber(a.workspace)
    if W[id] then
      if VIS[W[id].mon] == id then VIS[W[id].mon] = nil end
      W[id].mon = a.monitor
    end
  elseif kind == "focus" then
    local id = tonumber(a.workspace)
    if W[id] then VIS[W[id].mon] = id end
  end
  cleanup()
end
local timers = {}
function hl.timer(fn) timers[#timers+1] = fn end
function hl.on(ev, fn) handlers[ev] = fn end

local function run_timers()
  local t = timers; timers = {}
  for _, fn in ipairs(t) do
    local ok, err = pcall(fn)
    if not ok then log[#log+1] = "LUA ERROR: " .. tostring(err) end
  end
end

local function load_module()
  package.loaded.mw = nil
  return dofile(modpath)
end

local function unplug(name)
  for i, m in ipairs(MON) do if m == name then table.remove(MON, i) end end
  VIS[name] = nil
  for _, w in pairs(W) do if w.mon == name then w.mon = MON[1] end end
  cleanup()
  handlers["monitor.removed"](); run_timers()
end

local function replug(name, preopen)
  table.insert(MON, name)
  if preopen and not W[preopen] then W[preopen] = { id = preopen, mon = name, windows = 0 } end
  if preopen then VIS[name] = preopen end
  handlers["monitor.added"](); run_timers()
end

local function dump()
  local ids = {}
  for id in pairs(W) do ids[#ids+1] = id end
  table.sort(ids)
  local s = {}
  for _, id in ipairs(ids) do
    local w = W[id]
    s[#s+1] = id .. "@" .. w.mon:gsub("Virtual%-", "V") .. "(" .. w.windows .. ")" .. (VIS[w.mon] == id and "*" or "")
  end
  return table.concat(s, " ")
end

local function parked_file()
  local f = io.open(os.getenv("XDG_RUNTIME_DIR") .. "/hypr-parked-workspaces")
  if not f then return "(none)" end
  local s = f:read("a"); f:close(); return (s:gsub("\n", "; "))
end

local fails = 0
local function check(name, want)
  local got = dump()
  local ok = got == want and #log == 0 and parked_file() == "(none)"
  print((ok and "PASS " or "FAIL ") .. name)
  if not ok then
    fails = fails + 1
    print("  got:    " .. got); print("  want:   " .. want)
    print("  parked: " .. parked_file())
    for _, l in ipairs(log) do print("  log: " .. l) end
  end
  log = {}
end

os.remove(os.getenv("XDG_RUNTIME_DIR") .. "/hypr-parked-workspaces")

-- 1: one parked workspace, Hyprland pre-opens 11 (the case tested before).
reset({ "Virtual-1", "Virtual-2" }, { { 1, "Virtual-1", 2, true }, { 11, "Virtual-2", 1, true } })
load_module(); unplug("Virtual-2"); replug("Virtual-2", 11)
check("one workspace back", "1@V1(2)* 11@V2(1)*")

-- 2: two parked workspaces of Virtual-2 (11 and 12), pre-opened 11.
reset({ "Virtual-1", "Virtual-2" }, { { 1, "Virtual-1", 2, true }, { 11, "Virtual-2", 1, true }, { 12, "Virtual-2", 3 } })
load_module(); unplug("Virtual-2"); replug("Virtual-2", 11)
check("two workspaces back", "1@V1(2)* 11@V2(1)* 12@V2(3)")

-- 3: three parked (11, 12, 13), notebook has 1 and 3, pre-opened 11.
reset({ "Virtual-1", "Virtual-2" }, { { 1, "Virtual-1", 2, true }, { 3, "Virtual-1", 1 }, { 11, "Virtual-2", 1 }, { 12, "Virtual-2", 3, true }, { 13, "Virtual-2", 2 } })
load_module(); unplug("Virtual-2"); replug("Virtual-2", 11)
check("three workspaces back", "1@V1(2)* 3@V1(1) 11@V2(1)* 12@V2(3) 13@V2(2)")

-- 4: no pre-open (Hyprland put an unrelated ID there).
reset({ "Virtual-1", "Virtual-2" }, { { 1, "Virtual-1", 2, true }, { 11, "Virtual-2", 1, true }, { 12, "Virtual-2", 3 } })
load_module(); unplug("Virtual-2"); replug("Virtual-2", nil)
check("two back, no pre-open", "1@V1(2)* 11@V2(1) 12@V2(3)")

-- 5: two displays unplugged, one comes back.
reset({ "Virtual-1", "Virtual-2", "Virtual-3" }, { { 1, "Virtual-1", 1, true }, { 11, "Virtual-2", 1, true }, { 12, "Virtual-2", 1 }, { 21, "Virtual-3", 1, true } })
load_module(); unplug("Virtual-3"); unplug("Virtual-2"); replug("Virtual-2", 11)
log = {}
local after = dump()
print((after == "1@V1(1)* 2@V1(1) 11@V2(1)* 12@V2(1)" and parked_file():match("^2 21; $") and "PASS " or "FAIL ") .. "Virtual-2 back, Virtual-3 still parked: " .. after .. " | " .. parked_file())
replug("Virtual-3", 21)
check("then Virtual-3 back", "1@V1(1)* 11@V2(1)* 12@V2(1) 21@V3(1)*")

-- 6: the parked workspace with the lowest ID was emptied while unplugged.
reset({ "Virtual-1", "Virtual-2" }, { { 1, "Virtual-1", 2, true }, { 11, "Virtual-2", 1, true }, { 12, "Virtual-2", 3 } })
load_module(); unplug("Virtual-2"); W[2].windows = 0; cleanup(); replug("Virtual-2", 11)
check("emptied one dropped", "1@V1(2)* 11@V2(0)* 12@V2(3)")

-- 7: Hyprland pre-opened 12 (the second parked ID) instead of 11.
reset({ "Virtual-1", "Virtual-2" }, { { 1, "Virtual-1", 2, true }, { 11, "Virtual-2", 1, true }, { 12, "Virtual-2", 3 } })
load_module(); unplug("Virtual-2"); replug("Virtual-2", 12)
check("pre-opened 12", "1@V1(2)* 11@V2(1) 12@V2(3)*")

os.exit(fails == 0 and 0 or 1)
