-- EON_DM_BuildStereo.lua -- One-button STEREO Drum Matrix setup.
--
-- The classic Build creates 16 child MIDI lane tracks — great for multi-out
-- mixing, heavy for a one-track stereo workflow. This action instead tags the
-- Swing track ITSELF as a single multi-pitch ("piano view") drum lane covering
-- every pad's trigger note, so the Drum Matrix overlay renders 16 sub-rows over
-- the Swing track and all pattern MIDI lives in ONE item that feeds the FX
-- directly. No child tracks, no sends, no folders.
--
-- The lane tag is the mode: P_EXT:EON_DRUM_LANE with stereo=true and
-- note_lo/note_hi spanning the kit's pad pitches. eon_drum_matrix.lua already
-- classifies and renders such a lane via the existing piano-lane path;
-- swing_sync/track_detection skip identity sync for stereo lanes (the Swing
-- track's name/color stay the user's).
--
-- Defer-based timing (mirrors EON_DM_Build.lua): Phase 1 validates + bumps the
-- gmem heartbeat, Phase 2 waits up to ~10 frames for the chosen instance's
-- registry slot so the pad pitch range comes from the RIGHT kit.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local json = dofile(SCRIPT_DIR .. 'lib/json.lua')
if not (json and json.encode) then
  r.ShowMessageBox('lib/json.lua missing or invalid.', 'EON DM Build Stereo', 0)
  return
end
local safety      = dofile(SCRIPT_DIR .. 'lib/safety.lua')
local swing_state = dofile(SCRIPT_DIR .. 'lib/swing_state_reader.lua')

-- Share the classic Build's script lock so the two builders can never race
-- each other on the same project.
if not safety.AcquireScriptLock('build', 30) then
  r.ShowMessageBox('A Drum Matrix build is already running.\nWait for it to finish before re-invoking.',
                   'EON DM Build Stereo', 0)
  return
end
r.atexit(function() safety.ReleaseScriptLock('build') end)

-- v1 header RELOCATED 2026-07-09 from cells 3/4 (foreign gmem trampler stomped
-- the 0..35 header region). Keep in sync with rk_lua_core.lua NAMELEN/NAME_BASE.
local KIT_GMEM_NAMELEN = 26090303
local KIT_GMEM_NAME    = 26090304
local GS_SWING_ALIVE   = 1711
local MAX_FRAMES       = 10
local ROW_PX           = 20   -- target px per pitch sub-row for the height bump

-- ---------------------------------------------------------------------------
-- Swing track discovery (same matcher/picker as EON_DM_Build.lua)
-- ---------------------------------------------------------------------------

local function find_swing_track()
  local n = r.CountTracks(0)
  local found = {}
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    for fi = 0, r.TrackFX_GetCount(tr) - 1 do
      if swing_state.IsSwingFX(tr, fi) then
        found[#found + 1] = {
          track   = tr,
          fx      = fi,
          inst_id = swing_state.GetInstanceId(tr, fi),
        }
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
    if slot then
      label = label .. string.format(' (%d pads)', swing_state.SlotPadCount(slot))
    else
      label = label .. ' (offline)'
    end
    items[i] = label:gsub('[|#!<>&]', ' ')
  end
  local x, y = r.GetMousePosition()
  gfx.init('EON DM Build Stereo', 0, 0, 0, x, y)
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
  if s == '' then return 'Kit' end
  return s
end

local function find_existing_kit_folders(swing_guid)
  local out = {}
  for i = 0, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, i)
    local _, raw = r.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_KIT_FOLDER', '', false)
    if raw and raw ~= '' then
      local ok, decoded = pcall(json.decode, raw)
      if ok and type(decoded) == 'table' and decoded.swing_guid == swing_guid then
        out[#out + 1] = tr
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Phase 1: validate, guard, bump heartbeat, defer to Phase 2
-- ---------------------------------------------------------------------------

local swing_hits = find_swing_track()
if #swing_hits == 0 then
  r.ShowMessageBox('No track with Swing JSFX found. Load Swing on a track first.',
                   'EON DM Build Stereo', 0)
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
  if #sel == 1 then
    chosen = sel[1]
  else
    chosen = pick_swing_menu((#sel > 1) and sel or swing_hits)
    if not chosen then return end
  end
end

local swing_track = chosen.track
local swing_fx = chosen.fx
local chosen_inst_id = chosen.inst_id

if swing_track == r.GetMasterTrack(0) then
  r.ShowMessageBox('Swing on the master track is not supported.', 'EON DM Build Stereo', 0)
  return
end

-- Already a lane? (stereo tag, or — pathological — a classic lane tag on the
-- Swing track itself.) Nothing to build either way.
do
  local _, raw = r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_DRUM_LANE', '', false)
  if raw and raw ~= '' then
    r.ShowMessageBox('This Swing track already carries a Drum Matrix lane tag\n' ..
                     '(stereo mode is already set up).', 'EON DM Build Stereo', 0)
    return
  end
end

local swing_guid = r.GetTrackGUID(swing_track)

-- Classic multi-lane kits already exist for this instance: both would edit the
-- same instrument (the lanes AND the stereo item feed the same Swing). Allow
-- it, but make sure the user chose it.
if #find_existing_kit_folders(swing_guid) > 0 then
  local resp = r.ShowMessageBox(
    'Drum Matrix lane tracks already exist for this Swing.\n\n' ..
    'The stereo grid and the lanes would BOTH send patterns to the same kit\n' ..
    '(double triggers if the same beat lives in both).\n\nSet up stereo mode anyway?',
    'EON DM Build Stereo', 4)   -- Yes/No
  if resp ~= 6 then return end
end

r.gmem_attach('Swing_Media_Transfer')
r.gmem_write(99, os.time())   -- bump KIT_GMEM_BRIDGE_ALIVE so JSFX publishes.

local frames_waited = 0

-- ---------------------------------------------------------------------------
-- Phase 2: deferred build
-- ---------------------------------------------------------------------------

-- Pitch range = span of the kit's actual pad trigger notes (per-slot identity
-- band). Fallbacks: root_note..root_note+15 (slider1 = param 0), then 36..51.
local function resolve_note_range(slot)
  local lo, hi
  if slot ~= nil then
    for i = 1, 16 do
      local p = swing_state.GetPadPitch(i, slot)
      if p and p > 0 and p <= 127 then
        if not lo or p < lo then lo = p end
        if not hi or p > hi then hi = p end
      end
    end
  end
  if not (lo and hi) then
    local root = math.floor(r.TrackFX_GetParam(swing_track, swing_fx, 0) or 36)
    if root >= 0 and root <= 112 then
      lo, hi = root, root + 15
    else
      lo, hi = 36, 51
    end
  end
  -- Clamp a pathological span (custom per-pad notes scattered across octaves)
  -- so the piano view stays usable; out-of-window pads still play, they just
  -- render via the foreign-note badge.
  if hi - lo > 31 then hi = lo + 31 end
  if hi > 127 then hi = 127 end
  return lo, hi
end

local function resolve_kit_label()
  if #swing_hits == 1 then
    local n = read_kit_name_from_gmem()
    if n ~= 'Kit' then return n end
  end
  local _, tn = r.GetSetMediaTrackInfo_String(swing_track, 'P_NAME', '', false)
  if tn and tn ~= '' then return tn end
  return 'Drums'
end

local function do_build(slot)
  local lo, hi = resolve_note_range(slot)
  local label = resolve_kit_label()

  r.Undo_BeginBlock()

  r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_DRUM_LANE',
    json.encode({
      stereo      = true,
      swing_instance_guid = swing_guid,
      pad_index   = 1,
      pad_pitch   = lo,
      pad_channel = 1,
      note_lo     = lo,
      note_hi     = hi,
      pad_name    = label,
      created_at  = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }), true)

  -- Starter item: normally the bridge already seeded one on first insert
  -- (P_EXT:EON_PATTERN_SEEDED). This is the fallback for tracks that predate
  -- the seeder or opted out of it.
  local _, seeded = r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_PATTERN_SEEDED', '', false)
  local has_midi = false
  for i = 0, r.CountTrackMediaItems(swing_track) - 1 do
    local take = r.GetActiveTake(r.GetTrackMediaItem(swing_track, i))
    if take and r.TakeIsMIDI(take) then has_midi = true break end
  end
  if not has_midi and (not seeded or seeded == '') then
    local end_t = r.TimeMap2_beatsToTime(0, 0, 1)   -- 1 bar; time-sig aware (matches the bridge seeder)
    local item = r.CreateNewMIDIItemInProj(swing_track, 0, end_t, false)
    if item then
      r.SetMediaItemInfo_Value(item, 'B_LOOPSRC', 1)
      local take = r.GetActiveTake(item)
      if take then r.GetSetMediaItemTakeInfo_String(take, 'P_NAME', 'Pattern 1', true) end
      r.UpdateItemInProject(item)
    end
  end
  r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_PATTERN_SEEDED', '1', true)

  -- Grow the track so the piano view gets a real sub-row per pitch (it falls
  -- back to collapsed composite blocks below ~3 px/row). Never shrink.
  local want_h = (hi - lo + 1) * ROW_PX + 20   -- +20 = stereo header band (label/cog/M/S)
  if want_h < 200 then want_h = 200 end
  if want_h > 640 then want_h = 640 end
  local cur_h = r.GetMediaTrackInfo_Value(swing_track, 'I_HEIGHTOVERRIDE') or 0
  if cur_h < want_h then
    r.SetMediaTrackInfo_Value(swing_track, 'I_HEIGHTOVERRIDE', want_h)
  end

  r.Undo_EndBlock('EON DM: set up stereo drum grid', -1)
  r.UpdateArrange()
  r.TrackList_AdjustWindows(false)

  r.ShowMessageBox(
    string.format('Stereo grid ready for "%s" (notes %d-%d, one item on the Swing track).\nRun EON Drum Matrix to edit.',
                  label, lo, hi),
    'EON DM Build Stereo', 0)
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
