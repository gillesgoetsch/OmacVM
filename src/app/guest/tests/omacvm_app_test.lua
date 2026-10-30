-- omacvm_app.lua sets the outputs' kept rules again while Hyprland loads its
-- config (an Omarchy theme switch reloads it), against a fake Hyprland that
-- behaves as 0.56.2 and 0.57.0 do: hl.config with a key it does not know
-- records a config error (shown on the screen) and raises none; hl.get_config
-- gives nil and a message for such a key ("section.key" or "section:key").
-- Run: d=$(mktemp -d); XDG_RUNTIME_DIR=$d XDG_CONFIG_HOME=$d lua src/app/guest/tests/omacvm_app_test.lua src/app/guest/omacvm_app.lua
-- (Lua 5.4.)
local modpath = arg[1]
local rt = os.getenv("XDG_RUNTIME_DIR")
local cfg = os.getenv("XDG_CONFIG_HOME")
assert(modpath and rt and cfg and rt ~= "", "usage: see the top of this file")
os.execute("mkdir -p '" .. rt .. "/omacvm/display-sync' '" .. cfg .. "/hypr'")

local monitors, applied, window_rules, configs, errors
-- The options omacvm_app.lua sets, with Hyprland's defaults; a load can drop one (a newer Hyprland without it).
local OPTIONS = { ["cursor.no_hardware_cursors"] = 2, ["cursor.use_cpu_buffer"] = 2,
  ["render.keep_unmodified_copy"] = 2, ["render.cm_auto_hdr"] = 1, ["render.direct_scanout"] = 0 }
local known = OPTIONS
hl = {
  get_monitors = function() return monitors end,
  monitor = function(rule) applied[#applied + 1] = rule end,
  window_rule = function(rule) window_rules[#window_rules + 1] = rule end,
  config = function(c)
    configs[#configs + 1] = c
    for sec, kv in pairs(c) do
      if type(kv) ~= "table" then errors[#errors + 1] = "not a table: " .. tostring(sec)
      else
        for k in pairs(kv) do
          if known[sec .. "." .. k] == nil then errors[#errors + 1] = "unknown config key '" .. sec .. "." .. k .. "'" end
        end
      end
    end
  end,
  get_config = function(key)
    if type(key) ~= "string" then error("hl.get_config: bad type for arg 1") end
    local k = key:gsub(":", ".")
    if known[k] == nil then return nil, "unknown config key '" .. k .. "'" end
    return known[k]
  end,
  on = function() end,
  timer = function() end,
  exec_cmd = function() end,
}

local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

local function rule_file(output, text) write(rt .. "/omacvm/display-sync/" .. output .. ".rule", text) end

local function load_config(names, drop)
  monitors, applied, window_rules, configs, errors = {}, {}, {}, {}, {}
  known = {}
  for k, v in pairs(OPTIONS) do if k ~= drop then known[k] = v end end
  for _, n in ipairs(names) do monitors[#monitors + 1] = { name = n } end
  dofile(modpath)
  return applied
end

local failed = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failed = failed + 1 end
end

local MODE = "modeline 453 2940 3675 3763 3969 1840 1849 1858 1904 -hsync -vsync"
write(cfg .. "/hypr/monitors.lua",
  'local omarchy_monitor_scale = 2\nhl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })\n')

-- Nothing kept yet (first login): no rule.
check("no kept rule: nothing set", #load_config({ "Virtual-1", "NOTCH" }) == 0)

-- Hyprland's unmodified SDR copy of each HDR frame only while something
-- captures the output (render:keep_unmodified_copy 0), at every load.
local keep
for _, c in ipairs(configs) do
  if c.render and c.render.keep_unmodified_copy ~= nil then keep = c.render.keep_unmodified_copy end
end
check("HDR: SDR copy for captures only", keep == 0)

-- Hyprland's auto HDR off: display-sync sets Virtual-1's mode and its HDR
-- metadata follows that (a KMS recorder reads it, #579).
local auto
for _, c in ipairs(configs) do
  if c.render and c.render.cm_auto_hdr ~= nil then auto = c.render.cm_auto_hdr end
end
check("HDR: no auto HDR", auto == 0)

-- A keep_unmodified_copy the user set in their own Hyprland files wins: ours
-- is not set then. A comment that names it does not count.
local function keep_set()
  for _, c in ipairs(configs) do
    if c.render and c.render.keep_unmodified_copy ~= nil then return true end
  end
  return false
end
write(cfg .. "/hypr/looknfeel.lua", 'hl.config({ render = { keep_unmodified_copy = 2 } })\n')
load_config({ "Virtual-1" })
check("HDR: the user's own keep_unmodified_copy wins", not keep_set())
write(cfg .. "/hypr/looknfeel.lua", '-- render.keep_unmodified_copy: see the wiki\nhl.config({ render = { direct_scanout = 1 } })\n')
load_config({ "Virtual-1" })
check("HDR: a comment naming it does not count", keep_set())
write(cfg .. "/hypr/looknfeel.lua", 'hl.config({ render = { cm_auto_hdr = 1 } })\n')
load_config({ "Virtual-1" })
local auto_set = false
for _, c in ipairs(configs) do
  if c.render and c.render.cm_auto_hdr ~= nil then auto_set = true end
end
check("HDR: the user's own cm_auto_hdr wins", not auto_set)
os.remove(cfg .. "/hypr/looknfeel.lua")

-- The screen's kept rule comes back as it was sent (Omanotch's NOTCH output
-- above it can no longer push it aside with "auto").
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
local got = load_config({ "Virtual-1", "NOTCH" })
check("kept rule set again", #got == 1 and got[1].output == "Virtual-1" and got[1].mode == MODE
  and got[1].position == "0x0" and got[1].scale == "2")

-- An external display's rule too, with the HDR fields (numbers stay numbers).
rule_file("Virtual-2", 'hl.monitor({ output = "Virtual-2", mode = "modeline 533 3840 3888 3920 4000 2160 2163 2168 2222 +hsync -vsync", '
  .. 'position = "-480x-1080", scale = "auto", bitdepth = 10, cm = "hdr", supports_wide_color = 1, supports_hdr = 1, '
  .. 'max_luminance = 1600, min_luminance = 0.0005, sdr_max_luminance = 203 })\n')
got = load_config({ "Virtual-1", "Virtual-2", "NOTCH" })
local v2
for _, r in ipairs(got) do if r.output == "Virtual-2" then v2 = r end end
check("both outputs", #got == 2)
check("external's place and HDR fields", v2 and v2.position == "-480x-1080" and v2.bitdepth == 10 and v2.cm == "hdr"
  and v2.max_luminance == 1600 and v2.min_luminance == 0.0005 and v2.sdr_max_luminance == 203)

check("no window rule for an external's HDR fields", #window_rules == 0)

-- The screen in PQ (HDR): windows clipped at max_luminance again, not
-- tone-mapped (display-sync's hdr_tonemap); a reload dropped that rule.
local HDR_RULE = 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2", '
  .. 'bitdepth = 10, cm = "hdr", supports_wide_color = 1, supports_hdr = 1, max_luminance = 406, '
  .. 'min_luminance = 0.0005, sdr_max_luminance = 203 })\n'
rule_file("Virtual-1", HDR_RULE)
got = load_config({ "Virtual-1", "NOTCH" })
local wr = window_rules[1]
check("PQ screen: its rule", #got == 1 and got[1].cm == "hdr" and got[1].max_luminance == 406)
check("PQ screen: windows clipped", #window_rules == 1 and wr.name == "omacvm-hdr" and wr.tonemap == "clamp"
  and wr.match and wr.match.class == ".*")
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2", '
  .. 'bitdepth = 10, cm = "srgb" })\n')
load_config({ "Virtual-1", "NOTCH" })
check("10-bit sRGB screen: no window rule", #window_rules == 0)
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
load_config({ "Virtual-1", "NOTCH" })
check("SDR screen: no window rule", #window_rules == 0)
rule_file("Virtual-1", HDR_RULE)
write(cfg .. "/hypr/monitors.lua",
  'hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })\n')
load_config({ "Virtual-1", "NOTCH" })
check("user's own rule for the screen: no window rule", #window_rules == 0)
write(cfg .. "/hypr/monitors.lua",
  'local omarchy_monitor_scale = 2\nhl.monitor({ output = "", mode = "preferred", position = "auto", scale = omarchy_monitor_scale })\n')
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')

-- A display that left (the Mac's other screen left full screen): not set.
got = load_config({ "Virtual-1", "NOTCH" })
check("gone output not set", #got == 1 and got[1].output == "Virtual-1")
os.remove(rt .. "/omacvm/display-sync/Virtual-2.rule")

-- The user's own rule for the screen in monitors.lua wins.
write(cfg .. "/hypr/monitors.lua",
  'hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })\n')
check("user's own rule: not set", #load_config({ "Virtual-1", "NOTCH" }) == 0)
-- ... but not one that is commented out.
write(cfg .. "/hypr/monitors.lua",
  '-- hl.monitor({ output = "Virtual-1", mode = "1920x1200@60", position = "0x0", scale = 1 })\n')
check("commented-out user rule: set", #load_config({ "Virtual-1", "NOTCH" }) == 1)

-- Only plain values are read; a file that is not a kept rule is ignored and
-- nothing in it runs.
rule_file("Virtual-1", 'os.exit(3) hl.monitor({ output = "Virtual-1", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
check("not a rule: ignored", #load_config({ "Virtual-1" }) == 0)
rule_file("Virtual-1", 'hl.monitor({ output = "Virtual-1", mode = os.exit(3), position = "0x0", scale = "2" })\n')
check("code in a field: ignored", #load_config({ "Virtual-1" }) == 0)
rule_file("Virtual-1", 'hl.monitor({ output = "NOTCH", mode = "' .. MODE .. '", position = "0x0", scale = "2" })\n')
check("rule for another output: ignored", #load_config({ "Virtual-1", "NOTCH" }) == 0)
rule_file("Virtual-1", "")
check("empty file: ignored", #load_config({ "Virtual-1" }) == 0)

-- The pointer on its own layer: what the running driver says (its module
-- option), not the switch: a start on the stock driver stays as before.
local sys = rt .. "/sys"
local params = sys .. "/module/virtio_gpu/parameters"
os.execute("mkdir -p '" .. params .. "'")
local real_getenv = os.getenv
os.getenv = function(k) if k == "OMACVM_APP_LUA_SYS" then return sys end return real_getenv(k) end
local function value(key, sub)
  local v
  for _, c in ipairs(configs) do if c[key] and c[key][sub] ~= nil then v = c[key][sub] end end
  return v
end
rule_file("Virtual-1", "")
-- Every setting the config writes, as "section.key=value" (for what differs).
local function settings()
  local t = {}
  for _, c in ipairs(configs) do
    for sec, kv in pairs(c) do
      if type(kv) == "table" then for k, v in pairs(kv) do t[sec .. "." .. k .. "=" .. tostring(v)] = true end end
    end
  end
  return t
end
load_config({ "Virtual-1" })
local stock = settings()
check("stock driver: the pointer drawn into the frames", value("cursor", "no_hardware_cursors") == 1)
check("stock driver: no CPU buffer", value("cursor", "use_cpu_buffer") == nil)
write(params .. "/cursor_plane", "N\n")
load_config({ "Virtual-1" })
check("OmacVM's driver without the option (HDR alone): as before", value("cursor", "no_hardware_cursors") == 1)
write(params .. "/cursor_plane", "Y\n")
load_config({ "Virtual-1" })
check("cursor_plane: the pointer on the plane, from a CPU buffer", value("cursor", "no_hardware_cursors") == 0
  and value("cursor", "use_cpu_buffer") == 1)
local new = {}
for k in pairs(settings()) do if not stock[k] then new[#new + 1] = k end end
table.sort(new)
check("cursor_plane: only the pointer's two settings differ from the stock driver's",
  table.concat(new, " ") == "cursor.no_hardware_cursors=0 cursor.use_cpu_buffer=1")
check("cursor_plane: no direct scanout", value("render", "direct_scanout") == nil)
check("cursor_plane: no config error", #errors == 0)

-- A Hyprland without one of the options (a newer one that dropped it): that one is not set, the others are,
-- and no config error shows (pcall(hl.config, ...) let the error through: it is recorded, not raised).
for _, drop in ipairs({ "cursor.no_hardware_cursors", "cursor.use_cpu_buffer", "render.keep_unmodified_copy",
                        "render.cm_auto_hdr" }) do
  load_config({ "Virtual-1" }, drop)
  local sec, key = drop:match("^(%a+)%.([%a_]+)$")
  local set = {}
  for k in pairs(settings()) do set[#set + 1] = k:match("^[^=]+") end
  table.sort(set)
  check("a Hyprland without " .. drop .. ": no config error (" .. table.concat(errors, "; ") .. ")", #errors == 0)
  check("a Hyprland without " .. drop .. ": not set, the others are (" .. table.concat(set, " ") .. ")",
    value(sec, key) == nil and #set == 3)
end
write(params .. "/cursor_plane", "N\n")
load_config({ "Virtual-1" })
check("every option known: no config error", #errors == 0)
check("every option known: the three without the plane set",
  value("cursor", "no_hardware_cursors") == 1 and value("render", "keep_unmodified_copy") == 0
  and value("render", "cm_auto_hdr") == 0)
-- No hl.get_config (a Hyprland older than 0.55, none with a Lua config): nothing set, no error.
local get_config = hl.get_config
hl.get_config = nil
load_config({ "Virtual-1" })
check("no hl.get_config: nothing set, no error", #configs == 0 and #errors == 0)
hl.get_config = get_config
os.getenv = real_getenv

if failed > 0 then
  print(failed .. " failed")
  os.exit(1)
end
print("all passed")
