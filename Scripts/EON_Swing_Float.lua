-- @description EON: Float Swing (always show)
-- @version 1.0
-- @author EON Studios
-- @about
--   Floats (and fronts) the FIRST Swing instance on the selected track; if no
--   selected track carries one, falls back to the Swing you LAST TOUCHED, then
--   to the first Swing anywhere in the project. ONE-WAY: unlike
--   "EON: Float / unfloat Swing (toggle)" this never closes the window, so it
--   is safe on a hardware pad or in a custom action chain where a toggle could
--   land on "hide".
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")

-- First Swing slot on a track, or nil (same targeting as the toggle action).
local function first_swing_on(tr)
  if not tr then return nil end
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if T.fx_is_swing(tr, fx) then return tr, fx end
  end
  return nil
end

-- The Swing whose parameter the user last touched — but only when the
-- last-touched FX is a plain TRACK FX that is itself a Swing. Take FX encode an
-- item index in tracknumber's high word and rec-input/container FX set high
-- bits in fxnumber; any of those -> not ours, bail to the project scan.
local function last_touched_swing()
  local ok, tn, fxn = reaper.GetLastTouchedFX()
  if not ok then return nil end
  if (tn >> 16) ~= 0 or (fxn >> 16) ~= 0 then return nil end
  local ti = tn & 0xFFFF
  local tr = ti == 0 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, ti - 1)
  if tr and T.fx_is_swing(tr, fxn) then return tr, fxn end
  return nil
end

-- Selected tracks first (in selection order), then the last-touched Swing,
-- then the whole project top to bottom.
local function find_swing()
  for i = 0, reaper.CountSelectedTracks(0) - 1 do
    local tr, fx = first_swing_on(reaper.GetSelectedTrack(0, i))
    if tr then return tr, fx end
  end
  local tr, fx = last_touched_swing()
  if tr then return tr, fx end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr2, fx2 = first_swing_on(reaper.GetTrack(0, i))
    if tr2 then return tr2, fx2 end
  end
  return nil
end

local tr, fx = find_swing()
if not tr then
  reaper.MB("No Swing found on the selected track, or anywhere in this project.",
            "EON: Float Swing", 0)
  return
end

-- 3 = show floating window: opens it if closed, fronts it if already floating.
reaper.TrackFX_Show(tr, fx, 3)
