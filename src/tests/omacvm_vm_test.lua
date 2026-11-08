-- Hyprland 0.57's quirks:skip_non_kms_dmabuf_formats ends up off on every route (#630),
-- against a stand-in for Hyprland's Lua config that behaves as 0.56.2 and 0.57.0 do:
-- hl.config with an unknown key records a config error (shown on the screen) and does
-- not raise one; hl.get_config gives nil and a message for an unknown key; a config
-- load starts from the defaults; hl.env is setenv(), so os.getenv sees what it set.
-- And OmacVM's folder ends up ahead of Omarchy's bin on the session's PATH (#748).
-- Run by src/tests/dmabuf-alpha.sh:
--   lua omacvm_vm_test.lua PIECE [ROUTE=FILE,FILE...]...
-- PIECE: src/guest/omacvm_vm.lua; each ROUTE: the Lua files OmacVM's installers
-- require from hyprland.lua on that route. XDG_CONFIG_HOME and XDG_RUNTIME_DIR: empty
-- temp folders. (Lua 5.5, as Hyprland 0.56 and 0.57.)
local piece = arg[1]
local cfg = os.getenv("XDG_CONFIG_HOME")
local rt = os.getenv("XDG_RUNTIME_DIR")
assert(piece and cfg and cfg ~= "" and rt and rt ~= "", "usage: see the top of this file")
os.execute("mkdir -p '" .. cfg .. "/hypr'")
local KEY = "quirks.skip_non_kms_dmabuf_formats"

local failed = 0
local function check(name, ok)
  print((ok and "ok   " or "FAIL ") .. name)
  if not ok then failed = failed + 1 end
end
local function write(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- The stand-in. known: the keys this Hyprland has, with their defaults. env: the
-- process environment hl.env writes (opts.path: PATH at Hyprland's start).
local values, known, errors, sets
local env = {}
local real_getenv = os.getenv
os.getenv = function(k)
  if k == "PATH" or env[k] ~= nil then return env[k] end   -- PATH: only the stand-in's
  return real_getenv(k)
end
local function hyprland(skip_default, opts)
  opts = opts or {}
  env = { PATH = opts.path }
  known = {
    ["cursor.no_hardware_cursors"] = 2, ["cursor.use_cpu_buffer"] = 2,
    ["render.keep_unmodified_copy"] = 2, ["render.cm_auto_hdr"] = 1,
  }
  if skip_default ~= nil then known[KEY] = skip_default end
  values, errors, sets = {}, {}, {}
  for k, v in pairs(known) do values[k] = v end
  hl = {
    config = function(t)
      if type(t) ~= "table" then errors[#errors + 1] = "hl.config: not a table"; return end
      local function walk(prefix, tbl)
        for k, v in pairs(tbl) do
          local full = prefix == "" and k or (prefix .. "." .. k)
          if known[full] == nil and type(v) == "table" then walk(full, v)
          elseif known[full] == nil then errors[#errors + 1] = "unknown config key '" .. full .. "'"
          else values[full] = v; sets[#sets + 1] = full end
        end
      end
      walk("", t)
    end,
    get_monitors = function() return {} end,
    monitor = function() end,
    window_rule = function() end,
    on = function() end,
    timer = function() end,
    exec_cmd = function() end,
  }
  if not opts.no_env then
    hl.env = function(k, v) env[k] = tostring(v) end
  end
  if not opts.no_get_config then
    hl.get_config = function(key)
      if type(key) ~= "string" then error("hl.get_config: bad type for arg 1") end
      local k = key:gsub(":", ".")
      if known[k] == nil then return nil, "unknown config key '" .. k .. "'" end
      return values[k]
    end
  end
end
local function times_set()
  local n = 0
  for _, k in ipairs(sets) do if k == KEY then n = n + 1 end end
  return n
end
-- A config reload: Hyprland sets every value back to its default before it runs the Lua.
local function reload()
  for k, v in pairs(known) do values[k] = v end
end
-- load_config(files): the user's looknfeel.lua first (as Omarchy's hyprland.lua has it),
-- then the files OmacVM requires at its end.
local lua_load = load
local function load_config(files, looknfeel)
  local lf = cfg .. "/hypr/looknfeel.lua"
  os.remove(lf)
  if looknfeel then
    write(lf, looknfeel)
    local chunk = assert(lua_load(looknfeel, "looknfeel.lua"))
    chunk()
  end
  for _, f in ipairs(files) do
    local ok, err = pcall(dofile, f)
    if not ok then errors[#errors + 1] = "error in " .. f .. ": " .. tostring(err) end
  end
end
local function errs() return #errors == 0 and "" or (" (" .. table.concat(errors, "; ") .. ")") end

local have_piece = io.open(piece, "r")
if have_piece then have_piece:close() end
check("the piece exists: " .. piece, have_piece ~= nil)

-- Every route: with 0.57's default (on) the option ends up off, and no config error.
for i = 2, #arg do
  local route, list = arg[i]:match("^([%w-]+)=(.*)$")
  assert(route, "ROUTE=FILE,FILE: " .. arg[i])
  local files = {}
  for f in list:gmatch("[^,]+") do files[#files + 1] = f end
  hyprland(true)
  load_config(files)
  check(route .. ": Hyprland 0.57's default (on) ends up off, no config error (" .. (#files > 0 and table.concat(files, " ") or "no OmacVM Lua") .. ")" .. errs(),
    values[KEY] == false and #errors == 0)
end

if have_piece then
  local P = { piece }
  hyprland(true); load_config(P)
  check("0.57 default on: set to false once, no error" .. errs(), values[KEY] == false and times_set() == 1 and #errors == 0)
  hyprland(false); load_config(P)
  check("0.56.2 default off: no hl.config call" .. errs(), times_set() == 0 and #sets == 0 and #errors == 0)
  hyprland(nil); load_config(P)
  check("a Hyprland without the option: no call, no config error" .. errs(), #sets == 0 and #errors == 0)
  hyprland(true, { no_get_config = true }); load_config(P)
  check("no hl.get_config: nothing happens" .. errs(), #sets == 0 and #errors == 0)
  hyprland(1); load_config(P)
  check("an int 1 (older types): set to false" .. errs(), values[KEY] == false and #errors == 0)
  hyprland(true); load_config(P, "hl.config({ quirks = { skip_non_kms_dmabuf_formats = true } })\n")
  check("the user's own true in looknfeel.lua: kept" .. errs(), values[KEY] == true and times_set() == 1 and #errors == 0)
  hyprland(true); load_config(P, "-- quirks.skip_non_kms_dmabuf_formats: see the wiki\nhl.config({ general = {} })\n")
  check("a comment naming it: still set" .. errs(), values[KEY] == false and times_set() == 1)
  hyprland(true); load_config(P, "hl.config({ quirks = { skip_non_kms_dmabuf_formats = false } })\n")
  check("#630's workaround line already in looknfeel.lua: no second set" .. errs(),
    values[KEY] == false and times_set() == 1 and #errors == 0)
  -- A config reload starts from the defaults again (Hyprland resets every value before
  -- it runs the Lua): the second load sets it again.
  hyprland(true); load_config(P); reload(); load_config(P)
  check("a reload: set again from the default" .. errs(), values[KEY] == false and times_set() == 2 and #errors == 0)
end

-- PATH (#748). Omarchy's default/hypr/envs.lua (omarchy-mac 4.0 and Omarchy 4.5 alike;
-- loaded by default.hypr.omarchy, before OmacVM's line at the end of hyprland.lua):
local function omarchy_envs(omarchy_path)
  local bin_dir = omarchy_path .. "/bin"
  local kept = {}
  for entry in (os.getenv("PATH") or "/usr/local/bin:/usr/bin"):gmatch("[^:]+") do
    if entry ~= bin_dir then table.insert(kept, entry) end
  end
  table.insert(kept, 1, bin_dir)
  hl.env("PATH", table.concat(kept, ":"))
end
if have_piece then
  local P = { piece }
  local OVR = "/usr/local/lib/omacvm/omarchy-overrides"
  local START = "/home/u/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/bin"
  hyprland(false, { path = START }); omarchy_envs("/usr/share/omarchy"); load_config(P)
  check("PATH: OmacVM's folder, then Omarchy's bin, then the rest as Hyprland started" .. errs(),
    env.PATH == OVR .. ":/usr/share/omarchy/bin:" .. START and #errors == 0)
  local first = env.PATH
  reload(); omarchy_envs("/usr/share/omarchy"); load_config(P)
  check("a reload (Omarchy's bin first again, then OmacVM's): the same PATH", env.PATH == first)
  reload(); omarchy_envs("/usr/share/omarchy"); load_config(P)
  check("... and again", env.PATH == first)
  hyprland(false, { path = START }); omarchy_envs("/home/u/.local/share/omarchy"); load_config(P)
  check("Omarchy dev-linked (OMARCHY_PATH in the home): its bin second",
    env.PATH == OVR .. ":/home/u/.local/share/omarchy/bin:" .. START)
  hyprland(false, { path = START .. ":" .. OVR }); omarchy_envs("/usr/share/omarchy"); load_config(P)
  check("OmacVM's folder already on PATH: once, in front",
    env.PATH == OVR .. ":/usr/share/omarchy/bin:" .. START)
  -- The folder is not looked at (here it does not exist): with the Bridge off it is empty
  -- or gone and changes nothing, so it stays on PATH and no reload is needed.
  local f = io.open(OVR, "r")
  if f then f:close() end
  hyprland(false, { path = START }); omarchy_envs("/usr/share/omarchy"); load_config(P)
  check("the folder missing (" .. (f and "there" or "not there") .. " here): still first",
    env.PATH:sub(1, #OVR + 1) == OVR .. ":")
  hyprland(false, {}); load_config(P)
  check("no PATH at all: the folder, then Hyprland's fallback", env.PATH == OVR .. ":/usr/local/bin:/usr/bin")
  hyprland(false, { path = START, no_env = true }); load_config(P)
  check("no hl.env: PATH left as it is, no error" .. errs(), env.PATH == START and #errors == 0)
end

if failed == 0 then print("omacvm_vm_test: all passed") end
os.exit(failed == 0 and 0 or 1)
