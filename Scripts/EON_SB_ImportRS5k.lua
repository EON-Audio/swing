-- EON_SB_ImportRS5k.lua
-- Companion: import a ReaSamplOmatic5000 rack into a Swing kit.
-- Select the track holding the RS5k instances (or the folder parent of a
-- multi-out rack) and run this action. If NO Swing instance exists yet, one is
-- created on a new track and floated so the import is self-contained; otherwise
-- the import lands in the live Swing. Either way the browser opens its import
-- dialog (same auto-map / sequential / pad-picker flow as "Import SFZ Kit...").
-- (c) EON Studios

reaper.gmem_attach("Swing_Media_Transfer")
local CMD = 26090300     -- v1 header relocated 2026-07-09 (cells 0..35 dead; see rk_lua_core GMEM)
local BRIDGE_ALIVE = 99
local sep = package.config:sub(1, 1)

-- ⚠️ This used to walk up from the script's own directory to a sibling Swing/
-- dir. Scripts/ and Swing/ are siblings ONLY in the dev repo -- both shipped
-- layouts split them across <resource>/Scripts and <resource>/Effects, so the
-- derived path pointed at nothing and Swing was never auto-created. Resolve
-- against the Effects tree instead. (core.jsfx_addname, rk_lua_core.lua)
local _rs5k_dir = (select(2, reaper.get_action_context()) or ""):match("^(.*)[/\\]") or ""
package.path = _rs5k_dir .. sep .. "?.lua;" .. (package.path or "")
local core = require("rk_lua_core")

local function swing_addname()
  local name, _, why = core.jsfx_addname("Swing_ReaKit.jsfx")
  if not name then
    reaper.ShowConsoleMsg("[EON] Could not locate Swing_ReaKit.jsfx under the " ..
      "Effects folder -- cannot create a Swing instance.\n  " .. tostring(why) .. "\n")
  end
  return name
end

-- Same Swing-instance test the bridge/browser use.
local function fx_is_swing(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  return (fname:find("DrumKit_ReaKit")
       or fname:match("^JS: Swing")
       or fname:match("Swing %— 16%-Pad")) ~= nil
end

local function any_swing_exists()
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if fx_is_swing(tr, fx) then return true end
    end
  end
  return false
end

-- ── main ──
-- Need the bridge alive (it drives the browser pipeline) and no command in flight.
if reaper.gmem_read(BRIDGE_ALIVE) <= 0 or math.floor(reaper.gmem_read(CMD)) ~= 0 then
  return
end

local track = reaper.GetSelectedTrack(0, 0)
if not track then
  reaper.MB("Select the track holding the ReaSamplOmatic5000 rack first.",
    "Import RS5k Rack", 0)
  return
end

-- Source track passed by its 1-based number; capture BEFORE inserting anything.
local tnum = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
if tnum < 1 then
  reaper.MB("That track can't be imported (master/unnumbered).",
    "Import RS5k Rack", 0)
  return
end

-- If no Swing exists, create one on a NEW track at the END (so the source
-- track's number doesn't shift) and float it so its @gfx runs and the instance
-- registers. A short defer then lets it come alive before we open the browser,
-- which auto-targets the first live instance.
local wait = 0
if not any_swing_exists() then
  reaper.Undo_BeginBlock()
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Swing", true)
  local sname = swing_addname()
  local fx = sname and reaper.TrackFX_AddByName(tr, sname, false, -1) or -1
  if fx < 0 then
    reaper.Undo_EndBlock("Import RS5k Rack (couldn't add Swing)", -1)
    reaper.MB("Couldn't add the Swing instrument automatically.\n\nAdd a Swing "
      .. "to a track yourself, then run this action again.", "Import RS5k Rack", 0)
    return
  end
  reaper.TrackFX_Show(tr, fx, 3)  -- float → @gfx → instance heartbeats/registers
  reaper.Undo_EndBlock("Import RS5k Rack: new Swing instance", -1)
  wait = 20  -- ~20 defer cycles for the fresh instance to register
end

reaper.SetExtState("Swing", "import_rs5k_track", tostring(tnum), false)

-- Open the browser to handle the import (CMD 60). When we just created a Swing,
-- wait a few cycles first so it's registered when the browser resolves a target.
local function fire()
  if wait > 0 then wait = wait - 1; reaper.defer(fire); return end
  reaper.gmem_write(26090301, 0)     -- PARAM1 = pad 0 (relocated cell)
  reaper.gmem_write(CMD, 60)  -- CMD 60 = open browser
end
fire()
