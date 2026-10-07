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
hl.config({ cursor = { no_hardware_cursors = mac and 0 or 1 } })
-- The cursor plane from a CPU buffer (a dumb buffer: virtio-gpu copies it to
-- the Mac with the plane update); pcall: an older Hyprland lacks the option.
if mac then pcall(hl.config, { cursor = { use_cpu_buffer = 1 } }) end
-- A config reload drops the rules omacvm-display-sync sent with hyprctl eval:
-- every output would fall back to Omarchy's catch-all in monitors.lua (the
-- EDID's preferred mode, position "auto"). That is a modeset, a black flash on
-- every display, and beside Omanotch's NOTCH output an "auto" output keeps
-- moving right (NOTCH follows it every 2 s). So a reload declares the rules the
-- sync last sent (it keeps each in $XDG_RUNTIME_DIR/omacvm/display-sync/
-- Virtual-N.rule), after monitors.lua: Hyprland then sees no change at all.
-- Only an hl.monitor call for a Virtual-N output runs, with nothing else in
-- reach. No file (first start, a user rule for that output): nothing to do.
do
  local dir = (os.getenv("XDG_RUNTIME_DIR") or "") .. "/omacvm/display-sync/"
  for n = 1, 16 do
    local f = io.open(dir .. "Virtual-" .. n .. ".rule", "r")
    if f then
      local rule = f:read("l")
      f:close()
      if rule and rule:match('^hl%.monitor%(%{ output = "Virtual%-' .. n .. '", [^\n]*%}%)$') then
        local ok, chunk = pcall(load, rule, "=omacvm-display-sync", "t", { hl = { monitor = hl.monitor } })
        if ok and chunk then pcall(chunk) end
      end
    end
  end
end

-- A reload can still bring back a cached mode (a window size the sync has not
-- seen yet): look at the window's again.
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
