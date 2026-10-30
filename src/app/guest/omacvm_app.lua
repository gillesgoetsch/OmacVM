-- OmacVM.app: Hyprland draws the pointer (Omarchy's cursor) into the picture;
-- QEMU hides the Mac's over the VM window. Software cursor: the default.
-- With the app's experimental "Mac pointer for the VM" (OEM string
-- omacvm.hwcursor=1 -> /run/omacvm/host.env) the pointer goes on virtio-gpu's
-- cursor plane and the Mac's own cursor shows it (no frame to wait for).
-- Written by OmacVM; changes here are overwritten.
local function mac_pointer()
  local ok, f = pcall(function() return io.open("/run/omacvm/host.env") end)
  if not ok or not f then return false end
  local on = false
  for l in f:lines() do
    if l == "OMACVM_HWCURSOR=1" then on = true end
  end
  f:close()
  return on
end
local mac = mac_pointer()
-- The app's experimental "Pointer on its own layer" (omacvm.pointerplane=2):
-- OmacVM's virtio-gpu driver then shows a cursor plane on every output
-- (cursor_plane=1), and QEMU shows each over that display's window.
-- Read from the running driver, so a start on the stock one stays as before.
local function driver_option(name)
  local dir = os.getenv("OMACVM_APP_LUA_SYS") or "/sys"
  local ok, f = pcall(function() return io.open(dir .. "/module/virtio_gpu/parameters/" .. name) end)
  if not ok or not f then return false end
  local v = f:read("l")
  f:close()
  return v == "Y"
end
local plane = driver_option("cursor_plane")
-- Every option below is set only when this Hyprland has it: hl.config with a
-- key it does not know puts a config error on the screen, and pcall does not
-- catch that (Hyprland records it, it does not raise one). hl.get_config
-- gives nil for such a key (Hyprland 0.55 and newer, every Hyprland with a Lua
-- config). The same guard as ~/.config/hypr/omacvm_vm.lua's.
local function set_option(section, name, value)
  if type(hl.get_config) ~= "function" then return end
  local ok, now = pcall(hl.get_config, section .. "." .. name)
  if not ok or now == nil then return end
  pcall(hl.config, { [section] = { [name] = value } })
end
-- With the plane the pointer is not drawn into the frames: a pointer move
-- costs no new picture; QEMU shows the same image over its window.
set_option("cursor", "no_hardware_cursors", (mac or plane) and 0 or 1)
-- The cursor plane from a CPU buffer (a dumb buffer: virtio-gpu copies it to
-- the Mac with the plane update).
if mac or plane then set_option("cursor", "use_cpu_buffer", 1) end
-- HDR: with Virtual-1 in PQ and its SDR white at 203 nits, Hyprland 0.56's
-- default ("auto") keeps an unmodified SDR copy of every frame for screen
-- sharing: every window is drawn twice, into a second colour target. 0 makes
-- that copy only while something captures the output (a screenshot, a screen
-- share; Hyprland redraws the whole output for the first captured frame). The
-- screen shows the same pixels and screenshots are the same; each HDR frame
-- costs the Mac's GPU 10-19 % less. No effect in SDR (no copy there either
-- way). A keep_unmodified_copy the user set in their own Hyprland files wins:
-- then it is not set here.
local function user_sets(word)
  local home = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")
  for _, name in ipairs({ "hyprland", "looknfeel", "input", "bindings", "autostart", "envs", "monitors", "monitor_workspaces" }) do
    local f = io.open(home .. "/hypr/" .. name .. ".lua", "r")
    if f then
      for line in f:lines() do
        local code = line:gsub("%-%-.*$", "")
        if code:find(word, 1, true) then
          f:close()
          return true
        end
      end
      f:close()
    end
  end
  return false
end
if not user_sets("keep_unmodified_copy") then
  set_option("render", "keep_unmodified_copy", 0)
end
-- HDR: omacvm-display-sync sets Virtual-1's mode (PQ, or SDR while the Mac
-- cannot show PQ) and says supports_hdr in both, so Hyprland also takes back
-- the HDR metadata a KMS recorder reads (#579). With supports_hdr Hyprland's
-- auto HDR could switch it on its own for a full-screen window: to PQ for an
-- HDR window while the Mac cannot show PQ, and the metadata to SDR for one
-- that tags SDR colours while the screen stays PQ (recordings grey; read in
-- Hyprland 0.56.2's Renderer.cpp, no client in the VM did it). 0 keeps
-- display-sync's mode. No effect without HDR (no output says
-- supports_hdr then). A cm_auto_hdr the user set wins, as above.
if not user_sets("cm_auto_hdr") then
  set_option("render", "cm_auto_hdr", 0)
end
-- A config reload drops the rules omacvm-display-sync gave the outputs, and
-- each output would take monitors.lua's rule ("auto" place, cached mode) until
-- display-sync runs again after the reload. With Omanotch's NOTCH output above
-- the screen, "auto" put the screen to the right of NOTCH for a moment: on an
-- Omarchy theme switch (it reloads the config) the picture went black and slid
-- in again. So the rule each output shows now (display-sync keeps it in
-- $XDG_RUNTIME_DIR/omacvm/display-sync/<output>.rule) is set again here, and
-- the reload changes nothing. Not for an output monitors.lua names: the
-- user's own rule wins (display-sync leaves those alone too).
local function user_rule(output)
  local home = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")
  local f = io.open(home .. "/hypr/monitors.lua", "r")
  if not f then return false end
  local found = false
  for line in f:lines() do
    -- (Hyprland's Lua is 5.5: a loop variable cannot be assigned to.)
    local code = line:gsub("%-%-.*$", "")
    local name = code:match("output%s*=%s*[\"']([^\"']*)[\"']")
    if name == output then found = true end
  end
  f:close()
  return found
end

-- The fields of a kept rule: `hl.monitor({ output = "Virtual-1", mode = "...",
-- position = "0x0", scale = "2", bitdepth = 10, cm = "hdr", ... })`. Only
-- plain strings and numbers are read; nothing in the file is run.
local KEPT_FIELDS = {
  output = true, mode = true, position = true, scale = true, bitdepth = true, cm = true,
  supports_wide_color = true, supports_hdr = true, max_luminance = true, min_luminance = true,
  sdr_max_luminance = true,
}
local function parse_rule(text)
  local body = text and text:match("^%s*hl%.monitor%(%s*(%b{})%s*%)%s*$")
  if not body then return nil end
  local rule = {}
  for k, v in body:gmatch('([%a_]+)%s*=%s*"([^"]*)"') do
    if KEPT_FIELDS[k] then rule[k] = v end
  end
  for k, v in body:gmatch("([%a_]+)%s*=%s*(%-?[%d%.]+)%s*[,}]") do
    if KEPT_FIELDS[k] and tonumber(v) then rule[k] = tonumber(v) end
  end
  if type(rule.output) ~= "string" or not rule.output:match("^Virtual%-%d+$") then return nil end
  if type(rule.mode) ~= "string" or rule.position == nil or rule.scale == nil then return nil end
  return rule
end

local function keep_display_rules()
  local dir = (os.getenv("XDG_RUNTIME_DIR") or "") .. "/omacvm/display-sync/"
  local present = {}
  for _, m in ipairs(hl.get_monitors() or {}) do
    if m.name then present[m.name] = true end
  end
  for n = 1, 16 do
    local output = "Virtual-" .. n
    local f = present[output] and io.open(dir .. output .. ".rule", "r")
    if f then
      local rule = parse_rule(f:read("a"))
      f:close()
      if rule and rule.output == output and not user_rule(output) then
        hl.monitor(rule)
        -- HDR: windows only clipped at max_luminance, not tone-mapped (Chrome
        -- looked gray; display-sync's hdr_tonemap says why). A reload drops it.
        -- pcall: the other outputs' rules still come back if this fails.
        if output == "Virtual-1" and rule.cm == "hdr" then
          pcall(hl.window_rule, { name = "omacvm-hdr", match = { class = ".*" }, tonemap = "clamp" })
        end
      end
    end
  end
end
pcall(keep_display_rules)

-- A config reload brings back the cached mode; apply the window's again.
hl.on("config.reloaded", function()
  hl.exec_cmd("/usr/local/bin/omacvm-display-sync --once")
end)
-- An output that only moves (display-sync, Omanotch, a reload's "auto") sends
-- no event to omacvm-displays, which tells the Mac where the outputs are for
-- the pointer: poke it. At most one poke per 100 ms.
local displays_poke_pending = false
hl.on("monitor.layout_changed", function()
  if displays_poke_pending then return end
  displays_poke_pending = true
  hl.timer(function()
    displays_poke_pending = false
    hl.exec_cmd("/usr/local/bin/omacvm-displays poke")
  end, { timeout = 100, type = "oneshot" })
end)
