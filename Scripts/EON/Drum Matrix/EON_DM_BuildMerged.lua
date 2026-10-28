-- EON_DM_BuildMerged.lua -- One-button MERGED Drum Matrix setup.
--
-- Classic Build gives every pad two tracks: a MIDI lane feeding Swing and an
-- audio multi-out fed BY Swing. Merged mode collapses that pair: the pattern
-- MIDI item moves onto the pad's existing audio track, so one track per drum
-- carries its notes, its channel strip, its fader and its sends. ~37 tracks
-- becomes ~21.
--
-- WHY THERE IS STILL A HIDDEN TRACK
-- ---------------------------------
-- A merged track cannot send its own MIDI to Swing: it already RECEIVES audio
-- from Swing, and a track that both feeds and is fed by the same track is a
-- routing cycle. REAPER culls the feedback edge — that is exactly why the old
-- ADAPT attempt (EON_DM_Build.lua:495) went silent. Allowing feedback in
-- Preferences would fix the cycle but disables plugin delay compensation for
-- the entire project, so it is not an option we can ship.
--
-- Instead the trigger MIDI leaves via ONE hidden track that mirrors every
-- lane's notes into a single multi-pitch item — the same shape the Stereo
-- build puts on the Swing track. Nothing is both upstream and downstream of
-- Swing, so there is no cycle and PDC is untouched. lib/merged_mirror.lua owns
-- the mirroring; EON_DM_MergedMirror.lua keeps it live while you edit.
--
-- PREREQUISITE: Multi-Out. Merged mode ADOPTS the 16 audio tracks Swing's
-- MULTI button already builds (it never creates them) — that keeps track
-- naming, colours, icons, sends and the Drum Strip exactly where the bridge
-- put them. EON_Swing_Strip_Sync finds pad tracks purely by Swing's send
-- channels, so every merged track keeps its strip with no changes there.
--
-- Defer-based timing mirrors EON_DM_Build/BuildStereo: Phase 1 validates and
-- bumps the gmem heartbeat, Phase 2 waits for the instance's registry slot so
-- pad names and pitches come from the RIGHT kit.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local json = dofile(SCRIPT_DIR .. 'lib/json.lua')
if not (json and json.encode) then
  r.ShowMessageBox('lib/json.lua missing or invalid.', 'EON DM Build Merged', 0)
  return
end
local safety      = dofile(SCRIPT_DIR .. 'lib/safety.lua')
local category    = dofile(SCRIPT_DIR .. 'lib/category.lua')
local swing_state = dofile(SCRIPT_DIR .. 'lib/swing_state_reader.lua')
local mirror      = dofile(SCRIPT_DIR .. 'lib/merged_mirror.lua')
if not (mirror and mirror.EnsureTrigger) then
  r.ShowMessageBox('lib/merged_mirror.lua missing or invalid.', 'EON DM Build Merged', 0)
  return
end

-- Share the other builders' lock so no two builds can race on one project.
if not safety.AcquireScriptLock('build', 30) then
  r.ShowMessageBox('A Drum Matrix build is already running.\nWait for it to finish before re-invoking.',
                   'EON DM Build Merged', 0)
  return
end
r.atexit(function() safety.ReleaseScriptLock('build') end)

local KIT_GMEM_NAMELEN = 26090303
local KIT_GMEM_NAME    = 26090304
local GS_SWING_ALIVE   = 1711
local MAX_FRAMES       = 10
local NUM_PADS         = 16

-- ---------------------------------------------------------------------------
-- Swing discovery (same matcher/picker as EON_DM_Build / EON_DM_BuildStereo)
-- ---------------------------------------------------------------------------

local function find_swing_tracks()
  local found = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    for fi = 0, r.TrackFX_GetCount(tr) - 1 do
      if swing_state.IsSwingFX(tr, fi) then
        found[#found + 1] = { track = tr, fx = fi, inst_id = swing_state.GetInstanceId(tr, fi) }
        break
      end
    end
  end
  return found
end

local function pick_swing_menu(pool)
  local items = {}
  for i, h in ipairs(pool) do
    local _, tn = r.GetSetMediaTrackInfo_String(h.track, 'P_NAME', '', false)
    local num = math.floor(r.GetMediaTrackInfo_Value(h.track, 'IP_TRACKNUMBER') + 0.5)
    local slot = swing_state.ResolveSlot(h.inst_id)
    local label = string.format('Track %d: %s', num, (tn ~= '' and tn) or 'Swing')
    label = label .. (slot and string.format(' (%d pads)', swing_state.SlotPadCount(slot)) or ' (offline)')
    items[i] = label:gsub('[|#!<>&]', ' ')
  end
  local x, y = r.GetMousePosition()
  gfx.init('EON DM Build Merged', 0, 0, 0, x, y)
  local choice = gfx.showmenu(table.concat(items, '|'))
  gfx.quit()
  if choice and choice >= 1 then return pool[choice] end
  return nil
end

local function read_kit_name_from_gmem()
  local len = math.floor((r.gmem_read(KIT_GMEM_NAMELEN) or 0) + 0.5)
  if len <= 0 or len > 64 then return 'Kit' end
  local bytes = {}
  for i = 0, len - 1 do
    local c = r.gmem_read(KIT_GMEM_NAME + i) or 0
    if c == 0 then break end
    bytes[#bytes + 1] = string.char(math.floor(c) & 0xFF)
  end
  local s = table.concat(bytes)
  return (s ~= '') and s or 'Kit'
end

-- ---------------------------------------------------------------------------
-- Multi-out pad tracks, discovered from Swing's own sends
-- ---------------------------------------------------------------------------

-- Mirrors rk_lua_core.srcchan_pad (inlined so the DM keeps no dependency on the
-- bridge's Lua core). Returns a 0-based pad index, or -1 for a send that isn't
-- a pad feed (audio disabled, odd channel, or one of the FX return pairs which
-- sit at channel 32+ and therefore land >= NUM_PADS).
local function srcchan_pad(src_chan)
  if not src_chan then return -1 end
  src_chan = math.floor(src_chan)
  if src_chan < 0 then return -1 end
  local ch = src_chan % 1024          -- strip the width code
  if ch % 2 ~= 0 then return -1 end   -- pads sit on even channel pairs
  return ch / 2
end

local function send_dest(swing_track, s)
  local d = r.GetTrackSendInfo_Value(swing_track, 0, s, 'P_DESTTRACK')
  if d then return d end
  if r.BR_GetMediaTrackSendInfo_Track then
    return r.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
  end
  return nil
end

-- Is `dest` one of Swing's own pad tracks? The ownership test core.swing_send_pad gained on 2026-10-10, mirrored
-- here (DM22, 2026-10-26): a channel alone is topology -- REAPER's default for a hand-made send is channels 1-2,
-- so a user's own send from Swing to a reverb bus read as pad 1, and the bus was tagged, seeded and resized as a
-- merged lane while the real pad-1 track was skipped (with no multi-out at all, the bus alone passed the guard).
-- The P_EXT:EON_PAD_IDX tag every build stamps, or, for a track built before the tag, a destination inside
-- Swing's Audio sub (P_EXT:EON_AUDIO_KIT_FOLDER), directly or through the "Bank A" folder (P_EXT:EON_BANK_FOLDER).
local function owned_pad_track(dest)
  local _, tag = r.GetSetMediaTrackInfo_String(dest, 'P_EXT:EON_PAD_IDX', '', false)
  if tag and tag ~= '' then return true end
  local par = r.GetParentTrack(dest)
  if par then
    local _, bf = r.GetSetMediaTrackInfo_String(par, 'P_EXT:EON_BANK_FOLDER', '', false)
    if bf == 'A' then par = r.GetParentTrack(par) end
  end
  if not par then return false end
  local _, af = r.GetSetMediaTrackInfo_String(par, 'P_EXT:EON_AUDIO_KIT_FOLDER', '', false)
  return af ~= nil and af ~= ''
end

-- pad_tracks[1..16] = MediaTrack, plus the count found.
local function find_pad_tracks(swing_track)
  local out, n = {}, 0
  for s = 0, r.GetTrackNumSends(swing_track, 0) - 1 do
    local pad = srcchan_pad(r.GetTrackSendInfo_Value(swing_track, 0, s, 'I_SRCCHAN'))
    if pad >= 0 and pad < NUM_PADS then
      local dest = send_dest(swing_track, s)
      if dest and owned_pad_track(dest) and not out[pad + 1] then
        out[pad + 1] = dest
        n = n + 1
      end
    end
  end
  return out, n
end

-- Dim item colour per pad — same math as EON_DM_Build / EON_DM_SeedLane so a
-- merged lane's items look identical to a classic lane's.
local function dim_color_for_pad(pad_index)
  local h = ((pad_index - 1) % 16) / 16
  local s, l = 0.7, 0.55
  local q = l < 0.5 and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  local function hue2rgb(t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end
  local cr = math.floor(hue2rgb(h + 1/3) * 255 * 0.18)
  local cg = math.floor(hue2rgb(h)       * 255 * 0.18)
  local cb = math.floor(hue2rgb(h - 1/3) * 255 * 0.18)
  return r.ColorToNative(cr, cg, cb) | 0x1000000
end

-- ---------------------------------------------------------------------------
-- Phase 1: validate + guard
-- ---------------------------------------------------------------------------

local swing_hits = find_swing_tracks()
if #swing_hits == 0 then
  r.ShowMessageBox('No track with Swing JSFX found. Load Swing on a track first.',
                   'EON DM Build Merged', 0)
  return
end

swing_state.Init()

local chosen
if #swing_hits == 1 then
  chosen = swing_hits[1]
else
  local sel = {}
  for _, h in ipairs(swing_hits) do
    if r.GetMediaTrackInfo_Value(h.track, 'I_SELECTED') == 1 then sel[#sel + 1] = h end
  end
  if #sel == 1 then chosen = sel[1]
  else
    chosen = pick_swing_menu((#sel > 1) and sel or swing_hits)
    if not chosen then return end
  end
end

local swing_track     = chosen.track
local chosen_inst_id  = chosen.inst_id

if swing_track == r.GetMasterTrack(0) then
  r.ShowMessageBox('Swing on the master track is not supported.', 'EON DM Build Merged', 0)
  return
end

local swing_guid = r.GetTrackGUID(swing_track)

-- Multi-out is the prerequisite: merged mode adopts those tracks, never makes
-- them. Checked BEFORE the defer so the user gets the fix immediately.
local pad_tracks, pad_track_count = find_pad_tracks(swing_track)
if pad_track_count == 0 then
  r.ShowMessageBox(
    'Merged mode needs Swing\'s multi-out tracks, and this instance has none.\n\n' ..
    'Hit MULTI in Swing to build the 16 audio tracks first, then run this again.',
    'EON DM Build Merged', 0)
  return
end

-- Classic lanes for this Swing would double-trigger the same kit (their MIDI
-- sends and our trigger track both reach Swing). Make the user choose.
do
  local classic = 0
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local ok, raw = r.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_LANE', '', false)
    if ok and raw ~= '' then
      local dec_ok, lane = pcall(json.decode, raw)
      if dec_ok and type(lane) == 'table'
         and lane.swing_instance_guid == swing_guid
         and lane.merged ~= true and lane.stereo ~= true then
        classic = classic + 1
      end
    end
  end
  if classic > 0 then
    local resp = r.ShowMessageBox(
      string.format('%d classic Drum Matrix lane track(s) already feed this Swing.\n\n' ..
                    'Their MIDI sends and merged mode would BOTH trigger the same kit\n' ..
                    '(double hits for any beat that lives in both).\n\n' ..
                    'Set up merged mode anyway?', classic),
      'EON DM Build Merged', 4)   -- Yes/No
    if resp ~= 6 then return end
  end
end

-- Stereo-grid coexistence, EON_DM_Build's rule (DM23, 2026-10-26): the bridge tags every fresh Swing stereo
-- and seeds 'Pattern 1'; this build left that tag and item live beside the merged lanes, so the overlay showed
-- the stereo grid AND sixteen merged lanes for one kit, and every beat in Pattern 1 played beside the trigger
-- track. An EMPTY stereo pattern is cleared silently; one with notes is MOVED onto the pad tracks after a Yes.
local clear_stereo_tag = false
do
  local _, stereo_raw = r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_DRUM_LANE', '', false)
  if stereo_raw and stereo_raw ~= '' then
    local has_notes = false
    for i = 0, r.CountTrackMediaItems(swing_track) - 1 do
      local take = r.GetActiveTake(r.GetTrackMediaItem(swing_track, i))
      if take and r.TakeIsMIDI(take) then
        local _, ncnt = r.MIDI_CountEvts(take)
        if ncnt > 0 then has_notes = true break end
      end
    end
    if has_notes then
      local resp = r.ShowMessageBox(
        'This Swing is in stereo-grid mode and its pattern has notes.\n\n' ..
        'Merged mode will MOVE the pattern onto the pad tracks\' own items and\n' ..
        'remove the stereo MIDI item from the Swing track (notes at pitches that\n' ..
        'are not live pads are dropped).\n\nContinue?',
        'EON DM Build Merged', 4)   -- Yes/No
      if resp ~= 6 then return end
    end
    clear_stereo_tag = true
  end
end

r.gmem_attach('Swing_Media_Transfer')
-- No bridge-alive stamp here (DM213): Swing publishes its pad bands whatever cell 99 holds, and the stamp
-- impersonated a bridge for 5 s (a real one refused to start, a fresh Swing posted its auto-load into silence).

local frames_waited = 0

-- ---------------------------------------------------------------------------
-- Phase 2: deferred build
-- ---------------------------------------------------------------------------

local function read_pads(slot)
  -- The legacy shared block is only the chosen Swing's when ONE Swing exists (only the browser-target
  -- instance publishes it). Several Swings and the chosen one unresolved: skip it, as EON_DM_Build does,
  -- and lay the pads out from the root note (DM216, 2026-10-26: another kit's pitches went into merged lane
  -- tags that swing_sync never re-syncs, so notes painted there fired the wrong pads until a rerun).
  local shared_ok = (slot ~= nil) or (#swing_hits == 1)
  if not shared_ok then
    safety.ConsoleWarn('Build Merged: chosen Swing not registered yet and several Swings are live -- pads laid out from the root note; rerun once it is live to take its names and notes.')
  end
  local pads = {}
  for i = 1, NUM_PADS do
    local name  = shared_ok and (swing_state.GetPadName(i, slot) or '') or ''
    local pitch = shared_ok and swing_state.GetPadPitch(i, slot) or nil
    if not pitch or pitch < 0 or pitch > 127 then
      -- Fall back to the kit root note (slider1 = param 0) laid out chromatically.
      local root = math.floor(r.TrackFX_GetParam(swing_track, chosen.fx, 0) or 36)
      if root < 0 or root > 112 then root = 36 end
      pitch = root + (i - 1)
    end
    if name == '' then name = string.format('Pad %d', i) end
    pads[i] = { name = name, pitch = pitch }
  end
  return pads
end

local function do_build(slot)
  -- Pad Banks step 5a: Drum Matrix lanes are bank A's (v1); the bands carry the bank on screen.
  -- With no slot, read_pads reads the legacy shared block: the bank its publisher shows (audit S13).
  if (slot ~= nil and swing_state.SlotBankCur(slot) ~= 0)
     or (slot == nil and swing_state.SharedBankCur() ~= 0) then
    r.ShowMessageBox("Drum Matrix lanes follow pad bank A.\nShow bank A in Swing (click tab A, or run 'EON: Swing bank A') and build again.", "EON DM Build Merged", 0)
    return
  end
  local pads = read_pads(slot)
  local kit_name = (#swing_hits == 1) and read_kit_name_from_gmem() or 'Kit'
  local created_at = os.date('!%Y-%m-%dT%H:%M:%SZ')

  local cursor_time = r.GetCursorPosition()
  if cursor_time < 0 then cursor_time = 0 end
  local cursor_qn = r.TimeMap_timeToQN(cursor_time)
  local item_end_t = r.TimeMap_QNToTime(cursor_qn + 16)   -- 4 bars

  -- STEREO -> MERGED migration (capture pass), EON_DM_Build's: every play of the stereo item as REAPER plays it
  -- (merged_mirror.CollectItem: loop repeats, item bounds, mutes kept), keyed to THIS build's pads; captured
  -- now, before the tag or the items are touched. A pad's notes go into the item this build seeds (widened to
  -- cover them) or, on a track that already has MIDI, into a new item over their span. A muted stereo item is
  -- left on the Swing track as it is.
  local migrate, mig_t0, mig_t1 = nil, cursor_time, item_end_t
  if clear_stereo_tag then
    local pitch2pad = {}
    for i = 1, NUM_PADS do
      local pd = pads[i]
      if pd and pd.pitch then pitch2pad[pd.pitch] = pitch2pad[pd.pitch] or i end
    end
    local plays, notes = {}, {}
    for ii = 0, r.CountTrackMediaItems(swing_track) - 1 do
      mirror.CollectItem(r.GetTrackMediaItem(swing_track, ii), plays, true)
    end
    for _, n in ipairs(plays) do
      local pad = pitch2pad[n.pitch]
      if pad then
        notes[#notes + 1] = { pad = pad, pitch = n.pitch, vel = n.vel, ts = n.s, te = n.e, muted = n.muted }
        if n.s < mig_t0 then mig_t0 = n.s end
        if n.e > mig_t1 then mig_t1 = n.e end
      end
    end
    if #notes > 0 then migrate = notes end
  end
  local mig_pads = {}
  if migrate then for _, mn in ipairs(migrate) do mig_pads[mn.pad] = true end end

  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  -- Stereo-grid handoff confirmed in Phase 1: the Swing track stops being a lane.
  if clear_stereo_tag then
    r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_DRUM_LANE', '', true)
  end

  local tagged, seeded = 0, 0
  local pad_takes = {}
  for pad_idx = 1, NUM_PADS do
    local tr = pad_tracks[pad_idx]
    if tr then
      local pad = pads[pad_idx]

      -- Lane tag. `merged = true` is what tells merged_mirror to pick this
      -- track up and what makes swing_sync skip its identity pass — the Kit
      -- Bridge owns this track's name, colour and icon (same reasoning as the
      -- stereo lane). Name/colour are deliberately NOT written here.
      r.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_LANE',
        json.encode({
          merged              = true,
          swing_instance_guid = swing_guid,
          pad_index           = pad_idx,
          pad_pitch           = pad.pitch,
          pad_channel         = 1,
          pad_name            = pad.name,
          category            = category.InferFromName(pad.name),
          created_at          = created_at,
        }), true)
      tagged = tagged + 1

      -- Seed a pattern item only when the track has no MIDI of its own. Audio
      -- items already sitting on the track are irrelevant and left alone.
      local has_midi = false
      for i = 0, r.CountTrackMediaItems(tr) - 1 do
        local take = r.GetActiveTake(r.GetTrackMediaItem(tr, i))
        if take and r.TakeIsMIDI(take) then has_midi = true break end
      end
      if not has_midi or mig_pads[pad_idx] then
        local t0, t1 = cursor_time, item_end_t
        if mig_pads[pad_idx] then t0, t1 = mig_t0, mig_t1 end   -- room for every migrated note
        local item = r.CreateNewMIDIItemInProj(tr, t0, t1, false)
        if item then
          r.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', dim_color_for_pad(pad_idx))
          local take = r.GetActiveTake(item)
          if take then
            r.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', true)
            pad_takes[pad_idx] = take
          end
          if not has_midi then seeded = seeded + 1 end
        end
      end

      -- A merged track must never send MIDI to Swing itself — that is the
      -- cycle. Multi-out tracks have no such send, but a track adopted from a
      -- hand-rolled setup might; strip it so the routing stays acyclic.
      for s = r.GetTrackNumSends(tr, 0) - 1, 0, -1 do
        if r.GetTrackSendInfo_Value(tr, 0, s, 'P_DESTTRACK') == swing_track then
          r.RemoveTrackSend(tr, 0, s)
        end
      end

      -- Room for the pattern lane; multi-out tracks are built at 28 px.
      if (r.GetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE') or 0) < 54 then
        r.SetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE', 54)
      end
    end
  end

  -- STEREO -> MERGED migration (write pass): each captured note onto its pad's item at the same project
  -- time, muted ones muted, then the unmuted stereo MIDI items leave the Swing track so the pattern plays
  -- through the trigger track only. Inside this build's one Undo block, like EON_DM_Build's.
  if migrate then
    for _, mn in ipairs(migrate) do
      local take = pad_takes[mn.pad]
      if take then
        local ppq_s = r.MIDI_GetPPQPosFromProjTime(take, mn.ts)
        local ppq_e = r.MIDI_GetPPQPosFromProjTime(take, mn.te)
        if ppq_e <= ppq_s then ppq_e = ppq_s + 1 end
        r.MIDI_InsertNote(take, false, mn.muted or false, ppq_s, ppq_e, 0, mn.pitch, mn.vel, true)
      end
    end
    for _, take in pairs(pad_takes) do r.MIDI_Sort(take) end
    for ii = r.CountTrackMediaItems(swing_track) - 1, 0, -1 do
      local item = r.GetTrackMediaItem(swing_track, ii)
      local take = r.GetActiveTake(item)
      if take and r.TakeIsMIDI(take) and r.GetMediaItemInfo_Value(item, 'B_MUTE') ~= 1 then
        r.DeleteTrackMediaItem(swing_track, item)
      end
    end
  end

  local trigger = mirror.EnsureTrigger(swing_track, swing_guid, kit_name)
  -- Inside the undo block on purpose: the trigger item is part of this build,
  -- so one Ctrl+Z should take the whole thing back out.
  if trigger then mirror.Sync(swing_guid, true) end

  r.PreventUIRefresh(-1)
  r.Undo_EndBlock('EON DM: set up merged drum tracks', -1)

  r.UpdateArrange()
  r.TrackList_AdjustWindows(false)

  local msg
  if not trigger then
    msg = string.format(
      'Tagged %d merged lane(s), but the hidden trigger track could not be created.\n' ..
      'Nothing will play until it exists — re-run this action.', tagged)
  else
    msg = string.format(
      'Merged mode ready for "%s".\n\n' ..
      '  %d pad track(s) now carry their own pattern item (%d seeded).\n' ..
      '  Trigger MIDI leaves via one hidden track, kept in step by the bridge.',
      kit_name, tagged, seeded)
  end
  r.ShowMessageBox(msg, 'EON DM Build Merged', 0)
end

local function wait_then_build()
  frames_waited = frames_waited + 1
  local slot = swing_state.ResolveSlot(chosen_inst_id)
  local alive = r.gmem_read(GS_SWING_ALIVE) or 0
  if slot ~= nil
     or (#swing_hits == 1 and alive > 0 and frames_waited >= 2)
     or frames_waited >= MAX_FRAMES then
    do_build(slot)
    return
  end
  r.defer(wait_then_build)
end

r.defer(wait_then_build)
