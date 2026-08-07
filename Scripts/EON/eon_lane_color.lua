-- @noindex
-- eon_lane_color.lua
-- Shared helper for the Lane Color Ownership setting.
--
-- The setting lives in P_EXT:EON_LANE_COLOR_POLICY on the Swing ENGINE track,
-- per instance, and decides who owns the pad/lane track colors:
--   "swing"  (default) — Swing paints the lanes; a HUMAN TCP recolor repaints
--                        the pad.
--   "reaper"           — REAPER/SWS owns the colors; they flow INTO the pad.
--   "none"             — pad color and track color are unrelated.
--
-- This is a pure metadata write (no gmem / no JSFX) — the bridge and Drum Matrix
-- read the P_EXT every defer tick, so a change takes effect on the next pass.
-- See .docs/specs/Spec_Lane_Color_Ownership.md.
-- (c) EON Studios

local M = {}

M.KEY   = "P_EXT:EON_LANE_COLOR_POLICY"
M.MODES = { "swing", "reaper", "none" }

-- Mirror of eon_action_target.fx_is_swing / bridge is_swing_fx.
local function fx_is_swing(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and ident and ident:find("DrumKit_ReaKit") then return true end
  if fname and fname:find("DrumKit_ReaKit") then return true end
  if fname and (fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad")) then return true end
  return false
end

local function track_has_swing(tr)
  if not tr then return false end
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if fx_is_swing(tr, fx) then return true end
  end
  return false
end

-- Resolve the Swing engine track the user is "looking at":
--   1. the focused FX's track (FX chain / floating window focused), else
--   2. the selected track if it hosts a Swing, else
--   3. the first Swing track in the project.
-- Returns a MediaTrack* or nil.
function M.focused_swing_track()
  local retval, tnum, _, fxnum = reaper.GetFocusedFX2()
  if retval and (retval & 1) == 1 and fxnum and fxnum >= 0 and fxnum < 0x1000000 then
    local tr = (tnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, tnum - 1)
    if tr and fx_is_swing(tr, fxnum) then return tr end
  end
  local sel = reaper.GetSelectedTrack(0, 0)
  if track_has_swing(sel) then return sel end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if track_has_swing(tr) then return tr end
  end
  return nil
end

-- Current mode for a track (default "swing" when unset/unknown). Track nil → nil.
function M.Get(track)
  if not track then return nil end
  local _, v = reaper.GetSetMediaTrackInfo_String(track, M.KEY, "", false)
  if v == "reaper" or v == "none" then return v end
  return "swing"
end

-- Convenience: mode for the focused Swing (nil if no Swing in the project).
function M.GetFocused()
  return M.Get(M.focused_swing_track())
end

-- Write the mode to a track. "swing" clears the key (default = absent) to keep
-- existing projects byte-identical. Silent — no undo point (published state).
function M.Set(track, mode)
  if not track then return false end
  local store = (mode == "reaper" or mode == "none") and mode or ""
  reaper.GetSetMediaTrackInfo_String(track, M.KEY, store, true)
  return true
end

-- Resolve the focused Swing and set the mode. Returns true on success. Shows a
-- console note if no Swing could be found so the wrapper isn't a silent no-op.
function M.SetFocused(mode)
  local tr = M.focused_swing_track()
  if not tr then
    reaper.ShowConsoleMsg("EON Lane Colors: no Swing instance found to apply the setting.\n")
    return false
  end
  M.Set(tr, mode)
  return true
end

return M
