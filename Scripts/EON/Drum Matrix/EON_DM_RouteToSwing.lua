-- EON_DM_RouteToSwing.lua -- DEV-ONLY helper: route every EON Drum Matrix
-- lane track (P_EXT:EON_DRUM_LANE) to the project's Swing-bearing track via
-- MIDI sends (audio src = -1, MIDI all channels). Phase 8 Session Builder
-- will subsume this — for now this gets your painted notes triggering Swing.

local r = reaper

-- Find first track containing a Swing JSFX (by FX name match).
local function find_swing_track()
  local n = r.CountTracks(0)
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    local fx_count = r.TrackFX_GetCount(tr)
    for fi = 0, fx_count - 1 do
      local _, fx_name = r.TrackFX_GetFXName(tr, fi, '')
      if fx_name and fx_name:lower():find('swing', 1, true) then
        return tr, fx_name
      end
    end
  end
  return nil
end

local function has_send_to(src, dest)
  local n = r.GetTrackNumSends(src, 0)   -- 0 = sends
  for i = 0, n - 1 do
    local d = r.GetTrackSendInfo_Value(src, 0, i, 'P_DESTTRACK')
    if d == dest then return true end
  end
  return false
end

local swing_track, swing_name = find_swing_track()
if not swing_track then
  r.ShowMessageBox(
    'No track with a Swing JSFX found.\n\nLoad Swing on a track first, then run this again.',
    'EON DM Route', 0)
  return
end

local total = r.CountTracks(0)
local routed, skipped = 0, 0

r.Undo_BeginBlock()
for i = 0, total - 1 do
  local track = r.GetTrack(0, i)
  if track ~= swing_track then
    local ok, raw = r.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', '', false)
    if ok and raw ~= '' then
      if has_send_to(track, swing_track) then
        skipped = skipped + 1
      else
        local send_idx = r.CreateTrackSend(track, swing_track)
        if send_idx >= 0 then
          -- I_SRCCHAN = -1 disables audio (MIDI-only send)
          r.SetTrackSendInfo_Value(track, 0, send_idx, 'I_SRCCHAN', -1)
          -- I_MIDIFLAGS: 0 = all source channels -> all destination channels
          r.SetTrackSendInfo_Value(track, 0, send_idx, 'I_MIDIFLAGS', 0)
          routed = routed + 1
        end
      end
    end
  end
end
r.Undo_EndBlock('EON DM: route drum lanes to Swing', -1)

r.UpdateArrange()
r.ShowMessageBox(
  string.format(
    'Routed %d drum lane(s) to "%s" via MIDI sends.\n%d already routed (skipped).',
    routed, swing_name or 'Swing', skipped),
  'EON DM Route', 0)
