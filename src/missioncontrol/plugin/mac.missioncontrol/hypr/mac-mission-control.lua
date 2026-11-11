-- Mac Mission Control, the Hyprland half.
-- https://github.com/gillesgoetsch/omarchy-mac-mission-control
--
-- The shell plugin loads this file into the running Hyprland with
-- `hyprctl eval 'dofile(...)'`: when the shell starts and after every config
-- reload (a reload starts Lua afresh and forgets it). Nothing in ~/.config/hypr
-- has to require it.
--
--   N fingers up / down      open / close, following the fingers
--   N fingers left / right   while it is open: the next / previous desktop
--   CTRL + UP, F3 key        toggle
--
-- Hyprland only forwards here; the overview (MissionControl.qml) owns the
-- state and draws. Two channels:
--
--   Hyprland -> shell   custom socket2 events, "mmc>>..." (hl.dsp.event): a
--                       snapshot of monitors, workspaces and windows when a
--                       gesture starts, then one event per finger movement.
--   shell -> Hyprland   `hyprctl eval 'mac_mission_control.<fn>(...)'`.
--
-- The overview draws live copies of the windows, so the real ones are hidden
-- while it is up (a tag with an opacity 0 rule; a standalone capture ignores
-- opacity). The swap is tied to the overview's own layer, per monitor: the
-- layer maps with the copies already in its first frame, and the windows are
-- hidden in the handler of that very map, so both land in the same frame.
-- Leaving is the reverse: the layer unmaps, the windows show. If the shell
-- dies, its layers close and the windows come back.
--
-- Settings: a table named `mac_mission_control_config` in your Hyprland config,
-- see README.md. All of them are optional.

-- Loaded again into the same Lua (the shell restarted, the plugin was updated):
-- the previous load puts back what it had changed and goes quiet.
if type(mac_mission_control) == "table" and type(mac_mission_control.unload) == "function" then
  pcall(mac_mission_control.unload)
end

local user = type(mac_mission_control_config) == "table" and mac_mission_control_config or {}
local FINGERS = tonumber(user.fingers) or 4
local KEYS = type(user.keys) == "table" and user.keys or { "CTRL + UP", "XF86LaunchA" }
local NOTCH = type(user.notch) == "table" and user.notch or {}        -- monitor name -> logical px
local LOG = user.log and ((os.getenv("HOME") or "") .. "/.cache/mac-mission-control.log") or nil

local OVERVIEW_LAYER = "mac-mission-control"
local HIDDEN_TAG = "mac-mission-control-hidden"
local SUBMAP = "mac-mission-control"
local FLOATING_TAG = "omarchy-floating-workspace" -- Omarchy: these windows carry a titlebar
local TITLEBAR_HEIGHT = 30                        -- Omarchy's default/hypr/workspace-modes.lua, bar_height
local HOME = os.getenv("HOME") or ""

local hidden = false     -- the overview is up somewhere
local up = {}            -- monitor name -> its overview layer is mapped
local switching = false  -- the overview itself is changing workspaces
local demo = nil         -- { monitor = name, workspaces = { [id] = true } }: all the overview may show

local paging, in_submap = false, false

local function log(...)
  if not LOG then return end
  local f = io.open(LOG, "a")
  if not f then return end
  f:write(os.date("%H:%M:%S "), table.concat({ ... }, " "), "\n")
  f:close()
end

local function emit(data)
  hl.dispatch(hl.dsp.event("mmc>>" .. data))
end

local function sel(address) return "address:" .. address end

-- A hidden helper output (OmacVM's NOTCH) or a mirror is not a screen; in demo
-- mode only the one monitor is.
local function real(monitor)
  if not monitor or not monitor.name or monitor.name:find("^NOTCH") or monitor.is_mirror then return false end
  return not demo or not demo.monitor or monitor.name == demo.monitor
end

local function shown(workspace_id)
  return workspace_id and workspace_id > 0 and (not demo or not demo.workspaces or demo.workspaces[workspace_id] == true)
end

local function has_tag(window, tag)
  local tags = window.tags
  if type(tags) ~= "table" then return false end
  for key, value in pairs(tags) do
    local name = type(value) == "string" and value or key
    if type(name) == "string" and (name == tag or name == tag .. "*") then return true end
  end
  return false
end

local function readable(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- A camera notch, in logical pixels from the top of a monitor, or 0: from the
-- settings, or (in an OmacVM guest) the MacBook's own, when the built-in
-- display is the whole panel and OmacVM has not made the strip beside the
-- notch an output of its own.
local function notch_of(monitor)
  if tonumber(NOTCH[monitor.name]) then return tonumber(NOTCH[monitor.name]) end
  local f = io.open((os.getenv("XDG_RUNTIME_DIR") or "") .. "/omacvm/builtin", "r")
  if not f then return 0 end
  local builtin = (f:read("l") or ""):match("^Virtual%-%d+$") or "Virtual-1"
  f:close()
  if monitor.name ~= builtin then return 0 end
  for _, m in ipairs(hl.get_monitors() or {}) do
    if m.name and m.name:find("^NOTCH") then return 0 end
  end
  local aspect = monitor.height / monitor.width
  if aspect < 0.64 or aspect > 0.66 then return 0 end -- a notched panel is taller than 16:10
  local height = 37
  f = io.open(HOME .. "/.local/state/omanotch/strip-height", "r")
  if f then
    local h = tonumber(f:read("l"))
    f:close()
    if h and h >= 10 and h <= 200 then height = h end
  end
  return height
end

local function color(key, fallback)
  local ok, value = pcall(hl.get_config, key)
  if ok and type(value) == "table" and type(value.colors) == "table" and tonumber(value.colors[1]) then
    return string.format("%08x", value.colors[1]) -- aarrggbb
  end
  return fallback
end

local function number(key, fallback)
  local ok, value = pcall(hl.get_config, key)
  return ok and tonumber(value) or fallback
end

-- Titlebar colours, as Omarchy's workspace-modes.lua picks them from the theme.
-- (A theme change reloads the config, and with it this file.)
local function titlebar_colors()
  local colors = {}
  local file = io.open(HOME .. "/.local/state/omarchy/current/theme/colors.toml", "r")
  if file then
    for line in file:lines() do
      local key, value = line:match('^%s*([%w_]+)%s*=%s*"#(%x%x%x%x%x%x)"')
      if key then colors[key] = value end
    end
    file:close()
  end
  local background = colors.background or "1a1b26"
  local titlebar = colors.lighter_background
  if not titlebar or titlebar == background then titlebar = colors.selection or background end
  return titlebar, colors.foreground or "c0caf5"
end
local TITLEBAR, TITLE = titlebar_colors()

local function listed(w)
  local ws = w.workspace
  return w.mapped and not w.hidden and ws and shown(ws.id) and real(w.monitor)
    and type(w.at) == "table" and type(w.size) == "table"
end

-- Everything the overview needs to draw the desktop as it is right now, sent
-- in the same compositor tick as the gesture's first movement.
local function snapshot()
  emit("snap")
  emit(string.format("o,%s,%s,%s", tonumber(user.travel) or "", tonumber(user.gap) or "", tonumber(user.preview_height) or ""))
  local shadows = hl.get_config("decoration.shadow.enabled")
  emit(string.format("c,%s,%s,%d,%d,%d,%s,%s,%d,%s,%s",
    color("general.col.active_border", "ff7daea3"), color("general.col.inactive_border", "aa595959"),
    number("general.border_size", 2), TITLEBAR_HEIGHT, number("decoration.rounding", 0), TITLEBAR, TITLE,
    shadows and number("decoration.shadow.range", 16) or 0, tostring(number("decoration.shadow.render_power", 3)),
    color("decoration.shadow.color", "35000000")))

  local focused = hl.get_active_monitor()
  for _, m in ipairs(hl.get_monitors() or {}) do
    if real(m) then
      local scale = m.scale or 1
      local pos = type(m.position) == "table" and m.position or { x = m.x or 0, y = m.y or 0 }
      local ws = m.active_workspace
      emit(string.format("m,%s,%d,%d,%d,%d,%d,%d,%d,%d", m.name, pos.x, pos.y,
        math.floor(m.width / scale + 0.5), math.floor(m.height / scale + 0.5),
        ws and ws.id or 0, (focused and focused.name == m.name) and 1 or 0, notch_of(m),
        (demo and demo.renumber) and 1 or 0))
    end
  end

  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if shown(ws.id) and real(ws.monitor) then
      emit(string.format("k,%d,%s", ws.id, ws.monitor.name))
    end
  end

  -- hl.get_windows() is in stacking order, bottom first.
  local active = hl.get_active_window()
  for _, w in ipairs(hl.get_windows() or {}) do
    if listed(w) then
      emit(string.format("w,%s,%d,%d,%d,%d,%d,%s,%d,%d,%d,%d,%d", w.address, w.at.x, w.at.y, w.size.x, w.size.y,
        w.workspace.id, w.monitor.name, w.floating and 1 or 0, w.fullscreen or 0, w.pinned and 1 or 0,
        has_tag(w, FLOATING_TAG) and 1 or 0, (active and active.address == w.address) and 1 or 0))
    end
  end
end

local function tag(window, enabled)
  hl.dispatch(hl.dsp.window.tag({ tag = (enabled and "+" or "-") .. HIDDEN_TAG, window = sel(window.address) }))
end

-- monitor: a name, or nil for every monitor.
local function show_windows(monitor)
  for _, w in ipairs(hl.get_windows() or {}) do
    if has_tag(w, HIDDEN_TAG) and (not monitor or not w.monitor or w.monitor.name == monitor) then tag(w, false) end
  end
end

local function hide_windows(monitor)
  for _, w in ipairs(hl.get_windows() or {}) do
    local ws = w.workspace
    if w.mapped and ws and w.monitor and w.monitor.name == monitor and (ws.visible or w.pinned)
        and not has_tag(w, HIDDEN_TAG) then
      tag(w, true)
    end
  end
end

local function toggle()
  if not hidden then snapshot() end
  emit("toggle")
end

-- ---------------------------------------------------------------- sideways

-- While the overview is up, N fingers sideways page through its desktops
-- instead of sliding Hyprland's workspaces. A finger count and direction has
-- one gesture, so the workspace swipe is taken out for that time and put back
-- after. A hl.gesture that fails is a config error on the screen, not a Lua
-- error, so each call is only made when it will succeed: the swap happens
-- only if ~/.config/hypr/input.lua has that workspace swipe, written the way
-- Omarchy suggests it:
--   hl.gesture({ fingers = 4, direction = "horizontal", action = "workspace" })
local function workspace_swipe_configured()
  if user.sideways ~= nil then return user.sideways == true end
  local f = io.open(HOME .. "/.config/hypr/input.lua", "r")
  if not f then return false end
  local pattern = '^%s*hl%.gesture%(%s*{%s*fingers%s*=%s*' .. FINGERS
    .. '%s*,%s*direction%s*=%s*"horizontal"%s*,%s*action%s*=%s*"workspace"%s*}%s*%)'
  local found = false
  for line in f:lines() do
    if line:find(pattern) then found = true end
  end
  f:close()
  return found
end
local can_page = workspace_swipe_configured()
local sideways = 0

local function take_sideways()
  if paging or not can_page then return end
  paging = true
  hl.gesture({ fingers = FINGERS, direction = "horizontal", action = "unset" })
  hl.gesture({
    fingers = FINGERS,
    direction = "horizontal",
    action = {
      start = function() mac_mission_control_call("side_start") end,
      update = function(e) mac_mission_control_call("side_update", e) end,
      finish = function() mac_mission_control_call("side_finish") end,
    },
  })
end

local function give_back_sideways()
  if not paging then return end
  paging = false
  hl.gesture({ fingers = FINGERS, direction = "horizontal", action = "unset" })
  hl.gesture({ fingers = FINGERS, direction = "horizontal", action = "workspace" })
end

-- ---------------------------------------------------------------- keys

-- Keys while the overview is up. A submap, so that SUPER + Q and SUPER + W
-- mean the window under the pointer there instead of the focused one behind
-- it; what should still work is bound again in it. Keys it does not bind
-- reach the overview (ESC).
local function keys(enabled)
  if enabled == in_submap then return end
  in_submap = enabled
  hl.dispatch(hl.dsp.submap(enabled and SUBMAP or "reset"))
end

-- A monitor's ten workspaces start after a multiple of ten (1-10, 11-20, ...),
-- which is how Omarchy numbers them per monitor.
local function block(monitor)
  local ws = monitor and monitor.active_workspace
  return ws and ws.id and ws.id > 0 and math.floor((ws.id - 1) / 10) * 10 or 0
end

-- ---------------------------------------------------------------- calls

local fake_ms = 0
local OMARCHY_APPS = (readable(HOME .. "/.local/bin/omarchy-apps") and HOME .. "/.local/bin/omarchy-apps")
  or (readable("/usr/bin/omarchy-apps") and "/usr/bin/omarchy-apps") or nil

local function reset()
  up, hidden = {}, false
  give_back_sideways()
  keys(false)
  show_windows()
  emit("reset")
end

-- Called by the overview through `hyprctl eval`.
mac_mission_control = {
  toggle = toggle,

  -- Switch to a window: focus it and bring it to the front.
  activate = function(address)
    hl.dispatch(hl.dsp.focus({ window = sel(address) }))
    hl.dispatch(hl.dsp.window.bring_to_top())
  end,

  -- Go to a desktop (by workspace id) while the overview stays up: its windows
  -- are hidden before they would show. The switch itself must not slide (the
  -- overview does the moving), so where the workspace animation is on, the
  -- overview passes its settings as `slide`: it is off for the switch and
  -- back a moment later. (Whether a leaf is on is only looked at per frame, so
  -- it has to stay off for longer than one.)
  workspace = function(id, slide)
    if hidden then
      for _, w in ipairs(hl.get_windows() or {}) do
        if w.mapped and w.workspace and w.workspace.id == id and not has_tag(w, HIDDEN_TAG) then tag(w, true) end
      end
    end
    switching = true
    if type(slide) == "table" then hl.animation({ leaf = "workspaces", enabled = false }) end
    hl.dispatch(hl.dsp.focus({ workspace = tostring(id) }))
    hl.timer(function()
      switching = false
      if type(slide) == "table" then hl.animation(slide) end
    end, { timeout = 120, type = "oneshot" })
  end,

  -- A window dragged onto a desktop: it leaves the overview, so it is shown
  -- again, and it goes in front of what is there already.
  move = function(address, id)
    hl.dispatch(hl.dsp.window.tag({ tag = "-" .. HIDDEN_TAG, window = sel(address) }))
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(id), follow = false, window = sel(address) }))
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = sel(address) }))
  end,

  -- SUPER/CTRL + W over a window in the overview.
  close = function(address)
    hl.dispatch(hl.dsp.window.close({ window = sel(address) }))
  end,

  -- SUPER/CTRL + Q over a window: the whole app, but of a terminal only that
  -- window. With omarchy-app-switcher installed its `omarchy-apps` does the
  -- quitting (helpers and tray processes included); otherwise every window of
  -- the app is closed.
  quit = function(address)
    local window = hl.get_window(sel(address))
    if not window then return end
    local class = window.class or ""
    if has_tag(window, "terminal") or class == "" then
      hl.dispatch(hl.dsp.window.close({ window = sel(address) }))
    elseif OMARCHY_APPS and class:match("^[%w%._%-]+$") then
      hl.exec_cmd(OMARCHY_APPS .. " quit --key 'win:" .. class .. "'")
    else
      for _, w in ipairs(hl.get_windows() or {}) do
        if w.class == class then hl.dispatch(hl.dsp.window.close({ window = sel(w.address) })) end
      end
    end
  end,

  -- Where the windows are now, for the overview to bring its copies up to date
  -- after it moved one (the others of a tiled desktop re-tile).
  geometry = function()
    for _, w in ipairs(hl.get_windows() or {}) do
      if listed(w) then
        emit(string.format("x,%s,%d,%d,%d,%d,%d,%d", w.address, w.at.x, w.at.y, w.size.x, w.size.y,
          w.workspace.id, has_tag(w, FLOATING_TAG) and 1 or 0))
      end
    end
    emit("x,end")
  end,

  -- Desktops dragged into a new order in the bar: "old:new,old:new" renumbers
  -- those workspaces (through spare ids, as a target must be free). The
  -- workspaces themselves stay as they are, tiling tree included.
  -- Omarchy's layout mode belongs to the number, so a desktop that lands on a
  -- number with another mode is brought in line by Omarchy's own apply(); its
  -- windows then rearrange, and the overview gets out of the way for that.
  reorder = function(spec)
    local moves = {}
    for from, to in tostring(spec):gmatch("(%d+):(%d+)") do
      table.insert(moves, { tonumber(from), tonumber(to) })
    end
    if #moves == 0 then return end
    local floating = {}
    for _, w in ipairs(hl.get_windows() or {}) do floating[w.address] = w.floating end

    switching = true
    for i, move in ipairs(moves) do
      hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(move[1]), id = 9000 + i }))
    end
    for i, move in ipairs(moves) do
      hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(9000 + i), id = move[2] }))
    end
    hl.timer(function() switching = false end, { timeout = 150, type = "oneshot" })

    local ok, modes = pcall(require, "default.hypr.workspace-modes")
    if ok and type(modes) == "table" and type(modes.apply) == "function" then pcall(modes.apply) end
    for _, w in ipairs(hl.get_windows() or {}) do
      if floating[w.address] ~= nil and floating[w.address] ~= w.floating then
        emit("leave")
        break
      end
    end
    log("reorder " .. tostring(spec))
  end,

  -- The way out, should windows ever stay hidden:
  --   hyprctl eval 'mac_mission_control.reset()'
  reset = reset,

  -- For screenshots: show one monitor and only these workspaces of it, and
  -- (third argument) number them 1, 2, 3 in the bar whatever their ids.
  --   hyprctl eval 'mac_mission_control.demo("DP-1", { 7, 8, 9 }, true)'   and   .demo()   to end it
  demo = function(monitor, workspaces, renumber)
    if not monitor then
      demo = nil
      return
    end
    demo = { monitor = monitor, workspaces = {}, renumber = renumber == true }
    for _, id in ipairs(workspaces or {}) do demo.workspaces[id] = true end
    if next(demo.workspaces) == nil then demo.workspaces = nil end
  end,

  -- For tests and recordings: what a swipe sends, without the fingers.
  --   hyprctl eval 'mac_mission_control.swipe("s")'   then ("u", dy [, ms]) and ("e")
  swipe = function(what, dy, ms)
    if what == "s" then
      if not hidden then snapshot() end
      fake_ms = 0
      emit("g,s,1")
    elseif what == "u" then
      fake_ms = fake_ms + (ms or 8)
      emit(string.format("g,u,%.3f,%d", dy or 0, fake_ms))
    else
      emit("g,e,0")
    end
  end,
}

-- ---------------------------------------------------------------- handlers

-- What Hyprland's events, the gesture and the keys do. They are reached through
-- the hooks below, which outlive this load.
local travelled = 0
mac_mission_control.live = true
mac_mission_control.handlers = {
  layer_opened = function(layer)
    if not layer or layer.namespace ~= OVERVIEW_LAYER then return end
    local name = layer.monitor and layer.monitor.name
    if not name then return end
    up[name], hidden = true, true
    hide_windows(name)
    take_sideways()
    keys(true)
    emit("h," .. name)
  end,

  layer_closed = function(layer)
    if not layer or layer.namespace ~= OVERVIEW_LAYER then return end
    local name = layer.monitor and layer.monitor.name
    if name then up[name] = nil end
    if not name or next(up) == nil then
      up, hidden = {}, false
      give_back_sideways()
      keys(false)
      show_windows()     -- every one, wherever it has got to
    else
      show_windows(name)
    end
  end,

  -- A window that closes while the overview is up: its copy goes.
  window_gone = function(window)
    if hidden and window and window.address then emit("gone," .. window.address) end
  end,

  -- A window that opens while the overview is up belongs on screen: leave.
  window_open = function()
    if hidden then emit("leave") end
  end,

  -- A workspace switched to from outside (a key, a bar) while the overview is
  -- up: the overview stays and moves over to that desktop. Its windows are
  -- hidden here, before the frame that would show them.
  workspace_active = function()
    if not hidden or switching then return end
    for _, m in ipairs(hl.get_monitors() or {}) do
      if real(m) and up[m.name] and m.active_workspace and m.active_workspace.id > 0 then
        hide_windows(m.name)
        emit(string.format("ws,%s,%d", m.name, m.active_workspace.id))
      end
    end
  end,

  -- N fingers, vertical. `start` comes with the first movement and `update`
  -- repeats it, so only `update` reports deltas.
  swipe_start = function(e)
    if not hidden then snapshot() end
    travelled = 0
    emit("g,s," .. ((e and e.direction == "UP") and 1 or 0))
  end,
  swipe_update = function(e)
    local d = e and e.delta
    if d then
      travelled = travelled + (d.y or 0)
      emit(string.format("g,u,%.3f,%d", d.y or 0, e.time_ms or 0))
    end
  end,
  swipe_finish = function(e)
    emit("g,e," .. ((e and e.cancelled) and 1 or 0))
    log(string.format("swipe dy=%.0f %s", travelled, hidden and "(overview up)" or ""))
  end,

  -- N fingers, sideways, while the overview is up.
  side_start = function()
    local m = hl.get_monitor_at_cursor() or hl.get_active_monitor()
    sideways = 0
    emit(string.format("s,s,%s,%d", m and m.name or "", number("gestures.workspace_swipe_distance", 300)))
  end,
  side_update = function(e)
    local d = e and e.delta
    if d then
      sideways = sideways + (d.x or 0)
      emit(string.format("s,u,%.3f,%d", d.x or 0, e.time_ms or 0))
    end
  end,
  side_finish = function()
    emit("s,e")
    log(string.format("swipe dx=%.0f (overview up)", sideways))
  end,

  toggle = toggle,
  key = function(which) emit("key," .. which) end,
  -- SUPER + 1..0 in the overview: that desktop of the monitor, and the overview goes along.
  desktop = function(n)
    hl.dispatch(hl.dsp.focus({ workspace = tostring(n + block(hl.get_active_monitor())) }))
  end,
}

-- Put back what this load changed and go quiet: before the next load into the
-- same Lua, and when the plugin is switched off. The hooks stay.
mac_mission_control.unload = function()
  pcall(reset)
  mac_mission_control.live = false
end

-- ---------------------------------------------------------------- hooks

-- Registered once per Lua state (a config reload starts a new one) and never
-- taken out: Hyprland 0.56 has no safe way to. Keybind:remove() erases every
-- bind on that key, the user's own included, and segfaults the compositor on
-- a handle whose bind is already gone. So the hooks stay and call whichever
-- load of this file is live; one that is switched off makes them do nothing.
local HOOKS = 1 -- raise when the hooks themselves change: an older set then needs a config reload
if mac_mission_control_hooks == nil then
  mac_mission_control_hooks = HOOKS

  function mac_mission_control_call(name, ...)
    local module = mac_mission_control
    if type(module) ~= "table" or not module.live then return end
    local handler = module.handlers and module.handlers[name]
    if type(handler) == "function" then return handler(...) end
  end
  local call = mac_mission_control_call

  hl.on("layer.opened", function(layer) call("layer_opened", layer) end)
  hl.on("layer.closed", function(layer) call("layer_closed", layer) end)
  hl.on("window.close", function(window) call("window_gone", window) end)
  hl.on("window.destroy", function(window) call("window_gone", window) end)
  hl.on("window.open", function() call("window_open") end)
  hl.on("workspace.active", function() call("workspace_active") end)

  hl.gesture({
    fingers = FINGERS,
    direction = "vertical",
    action = {
      start = function(e) call("swipe_start", e) end,
      update = function(e) call("swipe_update", e) end,
      finish = function(e) call("swipe_finish", e) end,
    },
  })

  for _, key in ipairs(KEYS) do
    hl.bind(key, function() call("toggle") end, { description = "Mission Control" })
  end

  hl.define_submap(SUBMAP, function()
    for _, key in ipairs(KEYS) do
      hl.bind(key, function() call("toggle") end, { description = "Mission Control: leave" })
    end
    for _, mod in ipairs({ "SUPER", "CTRL" }) do
      hl.bind(mod .. " + W", function() call("key", "w") end, { description = "Mission Control: close the window under the pointer" })
      hl.bind(mod .. " + Q", function() call("key", "q") end, { description = "Mission Control: quit the app under the pointer" })
    end
    for n = 1, 10 do
      hl.bind("SUPER + code:" .. tostring(n + 9), function() call("desktop", n) end,
        { description = "Mission Control: desktop " .. n })
    end
  end)

  -- The hidden windows. (Opacity changes are instant: Omarchy keeps the
  -- fadeSwitch animation off.) Added at run time, so after every rule of the
  -- config, Omarchy's "opacity 1" for floating workspaces among them.
  hl.window_rule({
    name = "mac-mission-control-hidden",
    match = { tag = HIDDEN_TAG },
    opacity = "0 override 0 override 0 override",
  })
  -- The overview appears and goes with the frame it is asked to, not with a
  -- layer fade, and it is the topmost thing on the overlay layer (a lower
  -- order is further up), above bars that live there too.
  hl.layer_rule({ match = { namespace = "^mac-mission-control" }, no_anim = true })
  hl.layer_rule({ match = { namespace = "^mac-mission-control$" }, order = -50 })
elseif mac_mission_control_hooks ~= HOOKS then
  -- Hooks from an older version of this file: only a config reload replaces them.
  emit("stale")
end

-- Windows may still carry the tag from a shell that went away mid-overview.
pcall(show_windows)
pcall(emit, "reset")
