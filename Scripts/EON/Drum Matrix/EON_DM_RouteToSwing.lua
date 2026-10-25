-- EON_DM_RouteToSwing.lua -- DEV-ONLY helper: route every EON Drum Matrix
-- lane track (P_EXT:EON_DRUM_LANE) to ITS Swing-bearing track via
-- MIDI sends (audio src = -1, MIDI all channels). Phase 8 Session Builder
-- will subsume this — for now this gets your painted notes triggering Swing.
--
-- Per Swing (2026-10-23, audit H01): a lane goes to the Swing its tag names (swing_instance_guid =
-- that Swing's TRACK guid, as every build writes it). Until then every tagged track went to the
-- FIRST Swing, so a second Swing's lanes and its own track doubled onto the first kit. A lane whose
-- guid finds no Swing (Seed Lane's '{DEV-SEED-PLACEHOLDER}', an older lane, a deleted Swing) goes
-- to the one Swing when the project has exactly one, else it is left alone and counted.
-- Never routed: merged lanes (fed BY Swing -- a send back is the cycle EON_DM_BuildMerged strips)
-- and stereo lanes (the tag sits on the Swing track itself).
--
-- Wrong sends the old version left (the user's call, 2026-10-23: "Ask, then remove"): a project
-- saved after the old command keeps those sends, so a lane went on triggering both Swings. Only the
-- shape that command made counts: a MIDI-only send (I_SRCCHAN -1) from a tagged track to a Swing
-- track that is not its own (a Swing track's own Swing is itself). Audio sends, sends to anything
-- but a Swing, the own Swing's send, and every send of a lane whose own Swing cannot be told
-- (several Swings, a guid that finds none) are never touched. The command lists them and asks
-- first; the removal sits inside the same undo block, so one Ctrl+Z puts them back.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local json_ok, json = pcall(dofile, SCRIPT_DIR .. 'lib/json.lua')
if not (json_ok and type(json) == 'table' and json.decode) then
  r.ShowMessageBox('lib/json.lua missing or invalid.', 'EON DM Route', 0)
  return
end

-- Every track containing a Swing JSFX -- by the plugin's FILE compared whole (rk_lua_core's
-- core.is_swing_fx rule, written out), never its shown name: "swing" in a name took any plugin so
-- named, and missed a renamed Swing. Returns the list (track order) and a map from the track's
-- GUID to its entry; the shown name is kept for the summary line.
local function find_swing_tracks()
  local list, by_guid = {}, {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    for fi = 0, r.TrackFX_GetCount(tr) - 1 do
      local ok, ident = r.TrackFX_GetNamedConfigParm(tr, fi, 'fx_ident')
      local f = ok and ((ident or ''):match('[^/\\]+$') or ''):lower() or ''
      if f == 'swing_reakit.jsfx' or f == 'swing_lite.jsfx' or f == 'drumkit_reakit.jsfx' then
        local _, fx_name = r.TrackFX_GetFXName(tr, fi, '')
        local s = { track = tr, name = fx_name }
        list[#list + 1] = s
        by_guid[r.GetTrackGUID(tr)] = s
        break
      end
    end
  end
  return list, by_guid
end

local function has_send_to(src, dest)
  local n = r.GetTrackNumSends(src, 0)   -- 0 = sends
  for i = 0, n - 1 do
    local d = r.GetTrackSendInfo_Value(src, 0, i, 'P_DESTTRACK')
    if d == dest then return true end
  end
  return false
end

local function track_name(tr)
  local _, name = r.GetTrackName(tr)
  return name or '?'
end

local swings, swing_by_guid = find_swing_tracks()
if #swings == 0 then
  r.ShowMessageBox(
    'No track with a Swing JSFX found.\n\nLoad Swing on a track first, then run this again.',
    'EON DM Route', 0)
  return
end

-- Pass 1, nothing changed yet: the lanes to route (plan) and the wrong sends (wrong, in track order
-- and, per track, in ascending send index -- removed back to front below).
local plan, wrong = {}, {}
local unmatched = 0
for i = 0, r.CountTracks(0) - 1 do
  local track = r.GetTrack(0, i)
  local ok, raw = r.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', '', false)
  if ok and raw ~= '' then
    local self_swing = swing_by_guid[r.GetTrackGUID(track)]
    local dec_ok, lane = pcall(json.decode, raw)
    local lane_ok = dec_ok and type(lane) == 'table'
    local own = self_swing
    if not own and lane_ok then
      own = swing_by_guid[lane.swing_instance_guid]
      if not own and #swings == 1 then own = swings[1] end
    end
    if not self_swing then
      if not lane_ok then
        unmatched = unmatched + 1
      elseif lane.merged ~= true and lane.stereo ~= true then
        if own then plan[#plan + 1] = { track = track, dest = own } else unmatched = unmatched + 1 end
      end
    end
    if own then
      for si = 0, r.GetTrackNumSends(track, 0) - 1 do
        local d = r.GetTrackSendInfo_Value(track, 0, si, 'P_DESTTRACK')
        local ds
        for _, s in ipairs(swings) do if d == s.track then ds = s break end end
        if ds and ds ~= own and r.GetTrackSendInfo_Value(track, 0, si, 'I_SRCCHAN') == -1 then
          wrong[#wrong + 1] = { track = track, idx = si, dest = ds }
        end
      end
    end
  end
end

-- Ask before removing (type 4: 6 = Yes, 7 = No). A No still routes.
local remove = false
if #wrong > 0 then
  local lines = {}
  for k, w in ipairs(wrong) do
    if k > 12 then
      lines[#lines + 1] = string.format('  ...and %d more', #wrong - 12)
      break
    end
    lines[#lines + 1] = string.format('  %s  ->  %s', track_name(w.track), track_name(w.dest.track))
  end
  remove = r.ShowMessageBox(string.format(
    '%d connection(s) send a lane\'s MIDI to a Swing that is not its own\n' ..
    '(left by an older version of this command), so that Swing plays it too:\n\n%s\n\n' ..
    'Remove them? One Ctrl+Z puts them back.', #wrong, table.concat(lines, '\n')),
    'EON DM Route', 4) == 6
end

local routed, skipped, removed = 0, 0, 0
r.Undo_BeginBlock()
if remove then
  for k = #wrong, 1, -1 do            -- back to front: a track's lower send indices stay valid
    local w = wrong[k]
    if r.RemoveTrackSend(w.track, 0, w.idx) then removed = removed + 1 end
  end
end
for _, pl in ipairs(plan) do
  if has_send_to(pl.track, pl.dest.track) then
    skipped = skipped + 1
  else
    local send_idx = r.CreateTrackSend(pl.track, pl.dest.track)
    if send_idx >= 0 then
      -- I_SRCCHAN = -1 disables audio (MIDI-only send)
      r.SetTrackSendInfo_Value(pl.track, 0, send_idx, 'I_SRCCHAN', -1)
      -- I_MIDIFLAGS: 0 = all source channels -> all destination channels
      r.SetTrackSendInfo_Value(pl.track, 0, send_idx, 'I_MIDIFLAGS', 0)
      routed = routed + 1
    end
  end
end
r.Undo_EndBlock('EON DM: route drum lanes to Swing', -1)

r.UpdateArrange()
local msg
if #swings == 1 then
  msg = string.format('Routed %d drum lane(s) to "%s" via MIDI sends.\n%d already routed (skipped).',
    routed, swings[1].name or 'Swing', skipped)
else
  msg = string.format('Routed %d drum lane(s), each to its own Swing (%d in this project), via MIDI sends.\n' ..
    '%d already routed (skipped).', routed, #swings, skipped)
end
if unmatched > 0 then
  msg = msg .. string.format('\n%d lane(s) left alone: the Swing they belong to was not found.', unmatched)
end
if removed > 0 then
  msg = msg .. string.format('\nRemoved %d connection(s) to a Swing that was not the lane\'s own.', removed)
elseif #wrong > 0 and not remove then
  msg = msg .. string.format('\n%d connection(s) to another Swing kept, as you chose.', #wrong)
end
r.ShowMessageBox(msg, 'EON DM Route', 0)
