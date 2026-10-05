-- Separate workspaces per monitor: SUPER + 1..0 always means "1..0 on the
-- monitor I'm on", instead of jumping to wherever workspace N happens to live.
--
-- The main display is Virtual-1 (the VM window, or the first display in full
-- screen); further displays are Virtual-2, Virtual-3, ... (Parallels, Fusion
-- and OmacVM.app all name them so). Omanotch's hidden NOTCH output overlaps
-- Virtual-1 and is never an external monitor.
--
-- Hyprland has one global list of workspace IDs, and each ID belongs to one
-- monitor, so two "workspace 2"s cannot share an ID. The notebook keeps the
-- real IDs 1..10; Virtual-2 uses 11..20, Virtual-3 21..30 and so on (offset
-- 10 per display; an external with another name counts as the second). The
-- keys and the bar widget (plugin omacvm.workspaces) subtract the offset
-- again, so 11..20 never show up anywhere you look.
--
-- Used by hypr/bindings.lua (monitor_workspaces.workspace(n)).

local M = {}

M.LAPTOP = "Virtual-1"
M.OFFSET = 10

-- Outputs that are not real screens (Omanotch's hidden NOTCH output).
local function ignored(name)
  return name:find("^NOTCH") ~= nil
end

-- The offset of a monitor name: 0 for the main display, (N-1)*10 for Virtual-N.
local function name_offset(name)
  if not name or name == M.LAPTOP or ignored(name) then
    return 0
  end
  local n = tonumber(name:match("^Virtual%-(%d+)$"))
  if n and n >= 2 then
    return (n - 1) * M.OFFSET
  end
  return M.OFFSET
end

function M.offset(monitor)
  return name_offset(monitor and monitor.name)
end

-- Workspace N (1..10) on the focused monitor, as a workspace selector string.
function M.workspace(n)
  return tostring(n + M.offset(hl.get_active_monitor()))
end

-- The external monitors that are there, by offset.
local function externals()
  local present = {}
  for _, monitor in ipairs(hl.get_monitors() or {}) do
    if monitor.name and monitor.name ~= M.LAPTOP and not ignored(monitor.name) and not monitor.is_mirror then
      local offset = name_offset(monitor.name)
      if not present[offset] then
        present[offset] = monitor.name
      end
    end
  end
  return present
end

-- The offset whose range holds workspace ID (0 for 1..10).
local function range_of(id)
  return math.floor((id - 1) / M.OFFSET) * M.OFFSET
end

local function workspace_ids()
  local ids = {}
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if ws.id and ws.id > 0 then
      ids[ws.id] = ws
    end
  end
  return ids
end

-- Parking: unplugging moves 11..20 to the notebook, where the keys and the bar
-- only reach 1..10. So each one is renumbered in place into a free notebook
-- slot (windows stay put), and the record "slot original" is kept in a file so
-- replugging can put it back. A file, not a Lua table, so it survives
-- `hyprctl reload` while unplugged. Cleared when Hyprland starts, because a
-- record from an earlier session would point at unrelated workspaces.
local PARKED = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/hypr-parked-workspaces"

local function read_parked()
  local parked = {}
  local f = io.open(PARKED, "r")
  if not f then
    return parked
  end
  for line in f:lines() do
    local slot, original = line:match("^(%d+) (%d+)$")
    if slot then
      parked[tonumber(slot)] = tonumber(original)
    end
  end
  f:close()
  return parked
end

local function write_parked(parked)
  if next(parked) == nil then
    os.remove(PARKED)
    return
  end
  local f = io.open(PARKED, "w")
  if not f then
    return
  end
  for slot, original in pairs(parked) do
    f:write(slot, " ", original, "\n")
  end
  f:close()
end

local function change_id(from, to)
  hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(from), id = to }))
end

-- Workspaces of a display that is gone: renumber each into the lowest free
-- 1..10, in order. If the notebook is full, the rest keep their IDs.
local function park()
  local present = externals()
  local ids = workspace_ids()
  local stray = {}
  for id in pairs(ids) do
    local range = range_of(id)
    if range > 0 and not present[range] then
      table.insert(stray, id)
    end
  end
  if #stray == 0 then
    return
  end
  table.sort(stray)

  local parked = read_parked()
  local slot = 1
  for _, original in ipairs(stray) do
    while slot <= M.OFFSET and ids[slot] do
      slot = slot + 1
    end
    if slot > M.OFFSET then
      break
    end
    change_id(original, slot)
    parked[slot] = original
    ids[slot] = true
  end
  write_parked(parked)
end

-- With a display back: give each parked workspace of it that still exists
-- its original ID again. pin() then moves it to that display. An emptied
-- parked workspace is gone and simply dropped; parked workspaces of displays
-- still missing stay parked.
--
-- `ids` is kept in step with every renumbering (Hyprland refuses an ID that
-- is taken), and the records go in order of their original ID, so several
-- parked workspaces of one display all come back.
local function unpark()
  local parked = read_parked()
  if next(parked) == nil then
    return {}
  end

  local present = externals()
  local ids = workspace_ids()
  local wanted = {}
  local slots = {}
  for slot, original in pairs(parked) do
    wanted[original] = true
    slots[#slots + 1] = slot
  end
  table.sort(slots, function(a, b) return parked[a] < parked[b] end)

  local function move(from, to)
    change_id(from, to)
    ids[to], ids[from] = ids[from], nil
  end

  local left = {}
  local back = {}
  for _, slot in ipairs(slots) do
    local original = parked[slot]
    local range = range_of(original)
    if not ids[slot] then
      -- emptied: gone
    elseif not present[range] then
      left[slot] = original
    elseif not ids[original] then
      move(slot, original)
    elseif (ids[original].windows or 1) == 0 then
      -- Hyprland already opened the empty workspace "original" on the
      -- display that came back: rename that one out of the way first, to
      -- an ID that is free and that no other parked workspace wants.
      local spare
      for id = range + 1, range + M.OFFSET do
        if not ids[id] and not wanted[id] then
          spare = id
          break
        end
      end
      if spare then
        move(original, spare)
        move(slot, original)
        back[#back + 1] = original
      else
        left[slot] = original
      end
    end
  end
  write_parked(left)
  return back
end

-- Pin each range to its monitor, so a workspace created by moving a window to
-- it opens on the right screen. Rewritten whenever a monitor appears.
local function pin()
  for n = 1, M.OFFSET do
    hl.workspace_rule({ workspace = tostring(n), monitor = M.LAPTOP })
  end

  local present = externals()
  for offset, name in pairs(present) do
    for n = offset + 1, offset + M.OFFSET do
      hl.workspace_rule({ workspace = tostring(n), monitor = name })
    end
  end

  -- Unplugging parks a display's range on the notebook. The rules above may
  -- land after Hyprland has already placed workspaces for the new monitor,
  -- so hand each range back explicitly.
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    local name = ws.id and ws.id > M.OFFSET and present[range_of(ws.id)]
    if name and ws.monitor and ws.monitor.name ~= name then
      hl.dispatch(hl.dsp.workspace.move({ workspace = tostring(ws.id), monitor = name }))
    end
  end
end

-- Deferred: while the event runs, the unplugged monitor may still be listed
-- and its workspaces not yet handed to the notebook.
local function later(fn)
  hl.timer(fn, { timeout = 300, type = "oneshot" })
end

-- Exposed for testing by hand: hyprctl eval 'require("hypr.monitor_workspaces").unpark()'
M.park, M.unpark = park, unpark

pin()
park() -- also covers a reload while unplugged
hl.on("monitor.added", function()
  pin()
  later(function()
    local back = unpark()
    pin()
    -- Show each workspace that came back on its display (not the empty one
    -- Hyprland opened there), then return to where the focus was.
    if #back > 0 then
      local focused = hl.get_active_workspace and hl.get_active_workspace()
      for _, id in ipairs(back) do
        hl.dispatch(hl.dsp.focus({ workspace = tostring(id) }))
      end
      if focused and focused.id then
        hl.dispatch(hl.dsp.focus({ workspace = tostring(focused.id) }))
      end
    end
  end)
end)
hl.on("monitor.removed", function() later(park) end)
hl.on("hyprland.start", function() write_parked({}) end)

return M
