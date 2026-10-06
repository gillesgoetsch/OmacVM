-- OmacVM.app: Hyprland draws the pointer (Omarchy's cursor) into the picture;
-- QEMU hides the Mac's over the VM window. Software cursor: virtio-gpu's cursor
-- plane stayed empty here. Written by OmacVM; changes here are overwritten.
hl.config({ cursor = { no_hardware_cursors = 1 } })

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
