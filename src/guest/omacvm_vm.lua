-- OmacVM: Hyprland settings every OmacVM VM needs, on every route
-- (OmacVM.app, UTM, Parallels, VMware Fusion). Each one says why and when it
-- can go. Required from hyprland.lua by guest/hypr-vm.sh.
-- Written by OmacVM; changes here are overwritten.

-- A key the user names in their own Hyprland files (comments do not count):
-- then their value wins and OmacVM sets nothing. The same as omacvm_app.lua's.
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

-- Transparent panels, notifications and the Omarchy menu (#630).
-- Hyprland 0.57.0 turns quirks:skip_non_kms_dmabuf_formats on by default
-- (hyprwm/Hyprland#15803, for NVIDIA). Hyprland then offers apps only the
-- buffer formats a display plane takes. virtio-gpu's plane (OmacVM.app, UTM,
-- Parallels) takes XRGB8888 only, so apps get no format with alpha: Mesa has
-- no EGL config with alpha, and every transparent layer Qt Quick draws on the
-- GPU (the Omarchy shell's) comes out opaque black around its card. false is
-- what Hyprland 0.56 and older have. Hyprland builds the format table at its
-- start: this takes effect at the next login.
-- Only on a Hyprland that has the option and has it on: hl.get_config gives
-- nil for a key it does not know (hl.config with one would put a config error
-- on the screen; pcall does not catch that). So on Hyprland 0.56 (false
-- already) nothing is set, and once Hyprland drops the option this does
-- nothing. Can go when Hyprland keeps formats with alpha on such planes.
local function dmabuf_alpha()
  if type(hl.get_config) ~= "function" then return end
  local ok, on = pcall(hl.get_config, "quirks.skip_non_kms_dmabuf_formats")
  if not ok or not (on == true or on == 1) then return end
  if user_sets("skip_non_kms_dmabuf_formats") then return end
  hl.config({ quirks = { skip_non_kms_dmabuf_formats = false } })
end
dmabuf_alpha()
