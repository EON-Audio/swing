-- @description EON: Float / unfloat Swing (toggle)
-- @version 1.0
-- @author EON Studios
-- @about
--   Toggles the floating window of the FIRST Swing instance on the selected
--   track. If no selected track carries one, it falls back to the Swing you
--   LAST TOUCHED, then to the first Swing anywhere in the project — so bound
--   to a key this is simply "show me Swing", rather than something that
--   silently does nothing when focus is elsewhere.
--
--   Bind it to a key or drop it on a toolbar; the toolbar button lights while
--   the window is open.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")

-- First Swing slot on a track, or nil. Returns the pair so callers never have to
-- re-derive the track.
local function first_swing_on(tr)
  if not tr then return nil end
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if T.fx_is_swing(tr, fx) then return tr, fx end
  end
  return nil
end

-- The Swing whose parameter the user last touched — but only when the
-- last-touched FX is a plain TRACK FX that is itself a Swing (take FX encode
-- an item index in tracknumber's high word; rec-input/container FX set high
-- bits in fxnumber — any of those, bail to the project scan).
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

local _, _, sec, cmd = reaper.get_action_context()

local function set_toggle(state)
  if sec and cmd then
    reaper.SetToggleCommandState(sec, cmd, state)
    reaper.RefreshToolbar2(sec, cmd)
  end
end

local tr, fx = find_swing()
if not tr then
  set_toggle(0)
  reaper.MB("No Swing found on the selected track, or anywhere in this project.",
            "EON: Float Swing", 0)
  return
end

-- TrackFX_GetFloatingWindow returns the window handle only while this FX is
-- FLOATING (nil when it is closed, or merely visible inside the chain window),
-- which makes it the honest read of which way to toggle. Show flags: 3 = float,
-- 2 = close the float.
local floating = reaper.TrackFX_GetFloatingWindow(tr, fx) ~= nil
reaper.TrackFX_Show(tr, fx, floating and 2 or 3)

-- State is set from what we just did. It can go stale if the user closes the
-- window by hand — REAPER gives scripts no notification of that — but the
-- action itself never gets confused, because it re-reads the real window state
-- every run. One more press always resyncs the button.
set_toggle(floating and 0 or 1)
