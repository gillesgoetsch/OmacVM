-- omarchy-notch-bar: hidden output that renders the bar for the macOS notch helper.
--
-- Under OmacVM.app it sits right above the built-in display, where the strip
-- is on the Mac (the VM window is below the camera in macOS's full screen):
-- no overlap, so Hyprland shows no "monitor layout" warning, and the app maps
-- its pointer by the outputs the guest reports, so it stays exact.
-- Elsewhere it overlaps the top edge of the built-in display, so it stays
-- inside the existing monitor layout: absolute pointers (the Parallels mouse,
-- UTM's USB tablet) keep their mapping, and the pointer never lands on it.
-- notchcast keeps the same places (notchcast/notch-place.h).
-- notchcast keeps its width equal to the built-in display and its height equal
-- to the Mac's strip (the menu bar height, which depends on the MacBook model
-- and its resolution).
-- install.sh fills in NOTCHBAR_OUTPUT / NOTCHBAR_SCREEN if they are set.
local NOTCH_OUTPUT = "NOTCH"
local BUILTIN_OUTPUT = "Virtual-1"

-- The built-in display is BUILTIN_OUTPUT, unless OmacVM.app says which output
-- it is ($XDG_RUNTIME_DIR/omacvm/builtin): with external displays the main
-- window's display is Virtual-1, and the MacBook's can be Virtual-2 or later.
-- notchcast follows the same file.
local function builtin_output()
  if BUILTIN_OUTPUT ~= "Virtual-1" then return BUILTIN_OUTPUT end  -- set by NOTCHBAR_SCREEN
  local f = io.open((os.getenv("XDG_RUNTIME_DIR") or "") .. "/omacvm/builtin", "r")
  if not f then return BUILTIN_OUTPUT end
  local name = f:read("l")
  f:close()
  return (name and name:match("^Virtual%-%d+$")) or BUILTIN_OUTPUT
end

-- Start out right on a config reload: the built-in display's width, position
-- and scale, and the logical height notchcast last gave the output (it
-- corrects anything else within two seconds).
local function logical_height()
  local state = os.getenv("XDG_STATE_HOME") or ((os.getenv("HOME") or "") .. "/.local/state")
  local f = io.open(state .. "/omanotch/strip-height", "r")
  if not f then return 26 end
  local h = tonumber(f:read("l"))
  f:close()
  return (h and h >= 10 and h <= 200) and h or 26
end

-- OmacVM.app's VMs say so in /etc/omacvm/env (OMACVM_VM_TYPE=app).
local function omacvm_app()
  local f = io.open("/etc/omacvm/env", "r")
  if not f then return false end
  local app = false
  for line in f:lines() do
    local v = line:match("^OMACVM_VM_TYPE=[\"']?([%w]+)")
    if v then app = (v == "app") end
  end
  f:close()
  return app
end

-- Logical rectangle of a monitor (width/height are pixels).
local function logical_rect(m)
  local s = (m.scale and m.scale > 0) and m.scale or 1
  local p = type(m.position) == "table" and m.position or {}
  local w, h = (m.width or 0) / s, (m.height or 0) / s
  if (m.transform or 0) % 2 == 1 then w, h = h, w end
  return { x = m.x or p.x or p[1] or 0, y = m.y or p.y or p[2] or 0, w = w, h = h }
end

local function overlaps(a, b)
  local e = 0.5
  return a.x + e < b.x + b.w and b.x + e < a.x + a.w and a.y + e < b.y + b.h and b.y + e < a.y + a.h
end

local function notch_rule()
  local builtin = builtin_output()
  local monitors = hl.get_monitors()
  for _, m in ipairs(monitors) do
    if m.name == builtin and m.width and m.width > 0 then
      local s = m.scale or 2
      local r = logical_rect(m)
      -- A whole number of pixels at this scale, as notchcast does it.
      local lh = logical_height()
      for _ = 1, 120 do
        if math.abs(lh * s - math.floor(lh * s + 0.5)) <= 1e-3 then break end
        lh = lh + 1
      end
      -- Right above the display when OmacVM.app and that place is free
      -- (notch-place.h does the same); else over its top edge.
      local y = r.y
      if omacvm_app() then
        local up = { x = r.x, y = r.y - lh, w = r.w, h = lh }
        local free = true
        for _, o in ipairs(monitors) do
          if o.name ~= builtin and o.name ~= NOTCH_OUTPUT and overlaps(up, logical_rect(o)) then free = false end
        end
        if free then y = r.y - lh end
      end
      return {
        output = NOTCH_OUTPUT,
        mode = string.format("%dx%d@60", m.width, math.floor(lh * s + 0.5)),
        position = string.format("%dx%d", math.floor(r.x + 0.5), math.floor(y + 0.5)),
        scale = s,
      }
    end
  end
  -- Before the built-in display exists (first start): notchcast sizes and
  -- places it later. Under OmacVM.app above y = 0, where no display is (they
  -- all start at 0 or below), so not even this first place overlaps one.
  return { output = NOTCH_OUTPUT, mode = "1024x52@60", position = omacvm_app() and "0x-26" or "0x0", scale = 2 }
end

hl.monitor(notch_rule())

-- On NOTCH, the bar copy and the wallpaper live on the overlay layer (see the
-- patches), stacked above Omarchy's notification popups, which are shown on
-- every output and would otherwise draw their top edge into the notch strip.
-- On the other outputs the bar and wallpaper are on other layers, where the
-- order does not matter.
-- (A higher order is "closer to the monitor edge", i.e. further down.)
hl.layer_rule({ match = { namespace = "^omarchy-bar$" }, order = -20 })
hl.layer_rule({ match = { namespace = "^omarchy-background$" }, order = -10 })

-- Its own workspace, so no real workspace or window is ever moved onto it.
hl.workspace_rule({ workspace = "name:notch", monitor = NOTCH_OUTPUT, default = true, persistent = true })

-- Keyboard focus cycling could still select the hidden output; hand focus back
-- to the built-in display without moving the cursor (and without touching the
-- user's own cursor.no_warps setting).
hl.on("monitor.focused", function(m)
  if not m or m.name ~= NOTCH_OUTPUT then return end
  hl.timer(function()
    local ok, previous = pcall(hl.get_config, "cursor.no_warps")
    hl.config({ cursor = { no_warps = true } })
    hl.dispatch(hl.dsp.focus({ monitor = builtin_output() }))
    hl.config({ cursor = { no_warps = ok and previous == true } })
  end, { timeout = 1, type = "oneshot" })
end)

-- Right above the built-in display, NOTCH is that display's neighbour "up":
-- a window moved up off its top edge would land on the hidden output. It goes
-- back to the built-in display's workspace at once.
hl.on("window.move_to_workspace", function(a, b)
  pcall(function()
    local win, ws = a, b
    if type(win) == "table" and win.window then win, ws = win.window, win.workspace end
    if not win or not win.address then return end
    ws = ws or win.workspace
    local name = ws and (ws.name or ws.config_name)
    if name ~= "notch" and name ~= "name:notch" then return end
    local target
    for _, m in ipairs(hl.get_monitors()) do
      if m.name == builtin_output() then
        local aw = m.active_workspace or m.activeWorkspace
        target = aw and (aw.name or aw.id)
      end
    end
    if target then
      hl.dispatch(hl.dsp.window.move({ window = "address:" .. win.address, workspace = tostring(target), follow = false }))
    end
  end)
end)

-- The overlap with the built-in display is deliberate (see above), but
-- Hyprland warns about any overlapping monitors after every layout change
-- ("Your monitor layout is set up incorrectly. Monitor NOTCH overlaps …"),
-- and has no option to turn that off. Dismiss that one warning, and only when
-- it names the NOTCH output: at once in the event handler, which catches it
-- before the next frame is drawn (no flash), plus a few late checks just in
-- case. No timer runs otherwise.
local function dismiss_notch_overlap_warning()
  for _, n in ipairs(hl.notification.get()) do
    local text = n:get_text()
    if type(text) == "string" and text:find(NOTCH_OUTPUT, 1, true) then n:dismiss() end
  end
end

local function on_layout_event()
  dismiss_notch_overlap_warning()
  for _, ms in ipairs({ 16, 50, 150, 500, 1500 }) do
    hl.timer(dismiss_notch_overlap_warning, { timeout = ms, type = "oneshot" })
  end
end

hl.on("monitor.layout_changed", on_layout_event)
hl.on("monitor.added", on_layout_event)
hl.on("config.reloaded", on_layout_event)
on_layout_event()
