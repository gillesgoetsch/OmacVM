-- OmacVM control centre (feature control-centre): a floating window in the
-- middle of the display, about two thirds of it, like a quick-access window.
-- The menu, the bar item and the launcher open it with
-- omarchy-launch-or-focus-tui, so its app id is org.omarchy.omacvm.
-- Loaded from hyprland.lua after Omarchy's defaults; Escape or q closes it.
local match = { class = "^org\\.omarchy\\.omacvm$" }
hl.window_rule({ match = match, float = true })
hl.window_rule({ match = match, center = true })
hl.window_rule({ match = match, size = { "(monitor_w*0.65)", "(monitor_h*0.65)" } })
