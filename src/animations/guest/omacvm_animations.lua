-- OmacVM: Fewer animations (experimental; the app's VM window, the control
-- centre or omacvm enable|disable fewer-animations). Required from
-- hyprland.lua by animations/guest/install.sh while the feature is on; off
-- takes this file and that line away. Written by OmacVM; changes here are
-- overwritten.
--
-- A window's border takes its new colour at once when the focus moves,
-- instead of fading to it. While a border fades, Hyprland draws both windows
-- again in every frame, so moving the pointer across windows redraws most of
-- the screen (MacBook Air M2, whole Mac: about 0.43 W less with this).
-- Every other animation, blur and shadows stay as Omarchy has them; Omarchy's
-- own "no animations" toggle in its menu stays Omarchy's.
hl.animation({ leaf = "border", enabled = false })
hl.animation({ leaf = "borderangle", enabled = false })
