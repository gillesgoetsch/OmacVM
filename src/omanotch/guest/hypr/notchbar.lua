-- omarchy-notch-bar: hidden output that renders the bar for the macOS notch helper.
--
-- It overlaps the top edge of the built-in display, so it stays
-- inside the existing monitor layout: absolute pointers (the Parallels mouse,
-- UTM's USB tablet) keep their mapping, and the pointer never lands on it.
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

local function notch_rule()
  local builtin = builtin_output()
  for _, m in ipairs(hl.get_monitors()) do
    if m.name == builtin and m.width and m.width > 0 then
      local s = m.scale or 2
      local p = type(m.position) == "table" and m.position or {}
      -- A whole number of pixels at this scale, as notchcast does it.
      local lh = logical_height()
      for _ = 1, 120 do
        if math.abs(lh * s - math.floor(lh * s + 0.5)) <= 1e-3 then break end
        lh = lh + 1
      end
      return {
        output = NOTCH_OUTPUT,
        mode = string.format("%dx%d@60", m.width, math.floor(lh * s + 0.5)),
        position = string.format("%dx%d", p.x or p[1] or 0, p.y or p[2] or 0),
        scale = s,
      }
    end
  end
  -- Before the built-in display exists (first start): notchcast sizes it later.
  return { output = NOTCH_OUTPUT, mode = "1024x52@60", position = "0x0", scale = 2 }
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
