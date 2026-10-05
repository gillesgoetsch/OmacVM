-- OmacVM Glide (experimental): two-finger scrolling with the Mac's own
-- acceleration and momentum, on OmacVM's virtual trackpad. Written by OmacVM
-- (omacvm enable/disable scroll-momentum); changes here are overwritten.

-- Omarchy's display scale, from monitors.lua (its scaling menu writes it there):
-- logical pixels grow with the scale, so the scroll factor shrinks with it.
local function monitor_scale()
  local f = io.open((os.getenv("HOME") or "") .. "/.config/hypr/monitors.lua", "r")
  if not f then return 2 end
  local text = f:read("*a")
  f:close()
  return tonumber(text:match("local omarchy_monitor_scale = ([%d%.]+)")) or 2
end

-- Tuned on a MacBook Pro 16" at display scale 2 against macOS side by side:
-- GTK apps and the rest take the base factor; Chromium-based apps (Chromium,
-- Chrome, Omarchy's web apps, Electron) turn touchpad scrolling into about
-- 3.3 times more movement, so they get a third of it.
local chromium_ratio = 3.3
hl.device({ name = "apple-inc.-magic-trackpad-(omacvm)", accel_profile = "flat", natural_scroll = true,
            scroll_factor = 0.328 * chromium_ratio * 2 / monitor_scale() })
o.window("(chromium|google-chrome.*|chrome-.*|brave-browser.*|microsoft-edge.*|vivaldi.*|slacky|[Ss]lack|discord|vesktop|[Cc]ode|code-oss|[Cc]ursor|obsidian|[Ss]ignal|[Ss]potify|1[Pp]assword|teams-for-linux|figma-linux|[Ee]lectron)",
         { scroll_touchpad = 1 / chromium_ratio })
