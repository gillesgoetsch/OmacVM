-- notchbar.lua keeps every window off the hidden NOTCH output (#848), against
-- a fake Hyprland: the monitors, windows and workspaces as hl.get_* give them,
-- the events notchbar.lua listens to, and the dispatches it makes.
-- Run: lua src/omanotch/guest/tests/notchbar_test.lua src/omanotch/guest/hypr/notchbar.lua
-- (Lua 5.5, as Hyprland 0.56.)
local modpath = assert(arg[1], "usage: see the top of this file")

local handlers, timers, moves, monitors, windows
-- Hyprland 0.56 gives its windows, workspaces and monitors as userdata (seen
-- in a 4.5 guest: type() "userdata", fields read by name, a missing one nil).
-- The fakes are tables that type() calls userdata, so code that checks for a
-- table misses them as it does in Hyprland.
local rawtype = type
local UD = {}
type = function(v)
  local mt = rawtype(v) == "table" and getmetatable(v)
  if mt == UD then return "userdata" end
  return rawtype(v)
end
local function ud(t) return setmetatable(t, UD) end
hl = {
  monitor = function() end,
  layer_rule = function() end,
  workspace_rule = function() end,
  config = function() end,
  get_config = function() return false end,
  get_monitors = function() return monitors end,
  get_windows = function() return windows end,
  on = function(name, fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end,
  timer = function(fn) timers[#timers + 1] = fn end,
  dispatch = function(d) if d and d.move then moves[#moves + 1] = d.move end end,
  dsp = {
    focus = function(a) return { focus = a } end,
    window = { move = function(a) return { move = a } end },
  },
  notification = { get = function() return {} end },
}

local function run_timers()
  while #timers > 0 do
    local t = timers
    timers = {}
    for _, fn in ipairs(t) do fn() end
  end
end

local function fire(name, ...)
  for _, fn in ipairs(handlers[name] or {}) do fn(...) end
  run_timers()
end

local V1 = ud({ name = "Virtual-1" })
local NOTCH = ud({ name = "NOTCH" })
local function load(wins)
  handlers, timers, moves = {}, {}, {}
  monitors = {
    ud({ name = "Virtual-1", width = 3024, height = 1890, scale = 2, x = 0, y = 0, active_workspace = ud({ id = 1, name = "1" }) }),
    ud({ name = "NOTCH", width = 3024, height = 66, scale = 2, x = 0, y = -33, active_workspace = ud({ id = 11, name = "11" }) }),
  }
  windows = wins or {}
  dofile(modpath)
  run_timers()
end

local failed = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failed = failed + 1 end
end
local function moved(addr)
  for _, m in ipairs(moves) do
    if m.window == "address:" .. addr then return m end
  end
end

-- The reporter's state at a config reload: three windows on workspace 11 on NOTCH.
local ws11 = ud({ id = 11, name = "11", monitor = NOTCH })
load({
  ud({ address = "0xa1", monitor = NOTCH, workspace = ws11 }),
  ud({ address = "0xa2", monitor = NOTCH, workspace = ws11 }),
  ud({ address = "0xb1", monitor = V1, workspace = ud({ id = 1, name = "1", monitor = V1 }) }),
})
local m = moved("0xa1")
check("load: a window on a numbered workspace on NOTCH goes to the built-in display's workspace",
  m and m.workspace == "1" and m.follow == false)
check("load: ... every one of them", moved("0xa2") ~= nil)
check("load: a window on the built-in display stays", moved("0xb1") == nil)

-- A window moved onto NOTCH's numbered workspace (no name "notch").
load({})
fire("window.move_to_workspace", ud({ address = "0xc1" }), ws11)
check("move to a numbered workspace on NOTCH: sent back", moved("0xc1") and moved("0xc1").workspace == "1")
fire("window.move_to_workspace", { window = ud({ address = "0xc2" }), workspace = ud({ name = "name:notch" }) })
check("move to NOTCH's own workspace (the event's table form): sent back", moved("0xc2") ~= nil)
fire("window.move_to_workspace", ud({ address = "0xc3" }), ud({ id = 2, name = "2", monitor = V1 }))
check("move to a workspace on the built-in display: left alone", moved("0xc3") == nil)

-- A workspace moved to the monitor above takes its windows along: the next
-- workspace event brings them back.
load({})
windows = { ud({ address = "0xd1", monitor = NOTCH, workspace = ud({ id = 3, name = "3", monitor = NOTCH }) }) }
fire("workspace.move_to_monitor")
check("a workspace moved to NOTCH: its window comes back", moved("0xd1") and moved("0xd1").workspace == "1")
moves = {}
fire("workspace.active")
check("... and at the next workspace change too", moved("0xd1") ~= nil)
moves = {}
windows = { ud({ address = "0xd2", monitor = V1, workspace = ud({ id = 1, name = "1", monitor = V1 }) }) }
fire("window.open")
check("a window opened on the built-in display: nothing moved", #moves == 0)

-- Without the built-in display listed: nothing is moved, nothing raised.
load({})
monitors = { ud({ name = "NOTCH", active_workspace = ud({ id = 11, name = "11" }) }) }
windows = { ud({ address = "0xe1", monitor = NOTCH, workspace = ws11 }) }
local ok = pcall(fire, "workspace.active")
check("no built-in display: no move and no error", ok and #moves == 0)

-- A window table without a monitor (a special workspace): left alone.
load({ ud({ address = "0xf1", workspace = ud({ id = -98, name = "special:scratchpad" }) }) })
check("a window without a monitor: left alone", moved("0xf1") == nil)

if failed > 0 then
  print(failed .. " failed")
  os.exit(1)
end
print("ok   notchbar.lua keeps windows off NOTCH")
