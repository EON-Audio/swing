-- EON_DM_Build.lua -- One-button Drum Matrix session builder.
--
-- User loads Swing JSFX on a track, places the edit cursor where the pattern
-- should start, then runs this action. The script:
--   1. Finds the target Swing instance. One Swing → use it. Several Swings →
--      prefer the (single) selected track carrying one, else pop a picker
--      menu. Pads are then read from THAT instance's per-slot identity band
--      (registry slot via slider4 instance_id), so each kit builds its own
--      correct lanes.
--   2. Detects whether a Drum Matrix folder already exists for this Swing
--      instance (by matching swing_guid in P_EXT:EON_DRUM_KIT_FOLDER), and
--      offers Replace / Add parallel / Cancel.
--   3. Inserts a folder track named after the live Swing kit, plus 16 child
--      MIDI tracks named "01 <Pad>" ... "16 <Pad>", each colored on a rainbow
--      hue, each with a MIDI send to the Swing track, each with a 4-bar dim
--      MIDI item at the edit cursor.
--   4. Writes P_EXT JSON tags so eon_drum_matrix.lua and helpers can find
--      everything by GUID later.
--
-- Defer-based timing fix (mirrors EON_DM_SeedLane.lua):
-- Swing JSFX only publishes pad metadata to gmem when gmem[99]
-- (KIT_GMEM_BRIDGE_ALIVE) is recent. Phase 1 runs immediately (validation,
-- guards, collision dialog, bump heartbeat), then defers to Phase 2 which
-- waits up to ~10 frames for gmem[1711] (GS_SWING_ALIVE) to tick before
-- reading pads and building.

local r = reaper

-- ---------------------------------------------------------------------------
-- json + constants
-- ---------------------------------------------------------------------------

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local json = dofile(SCRIPT_DIR .. 'lib/json.lua')
if not (json and json.encode) then
  r.ShowMessageBox('lib/json.lua missing or invalid.', 'EON DM Build', 0)
  return
end
local category = dofile(SCRIPT_DIR .. 'lib/category.lua')
local safety   = dofile(SCRIPT_DIR .. 'lib/safety.lua')
local folder_layout = dofile(SCRIPT_DIR .. 'lib/folder_layout.lua')
-- Swing-FX detection + per-instance registry/identity reads (multi-Swing).
local swing_state = dofile(SCRIPT_DIR .. 'lib/swing_state_reader.lua')
-- House dialog (ReaImGui, async) for the end-of-build notice; every use
-- gates on available() and keeps ShowMessageBox as the fallback, so a
-- missing ReaImGui or a missing module file costs nothing but the styling.
local _dlg_ok, eon_dlg = pcall(dofile,
  SCRIPT_DIR .. '..' .. SCRIPT_DIR:sub(-1) .. 'eon_imgui_dialog.lua')
if not _dlg_ok then eon_dlg = nil end

-- Case #37: prevent rapid-double-press from creating duplicate kit folders.
-- 30 s TTL is generous — the defer-based build sequence runs ~10 frames so
-- a real run finishes in <500 ms; the TTL just protects against scripts
-- that crash mid-build leaving a stale lock.
if not safety.AcquireScriptLock('build', 30) then
  r.ShowMessageBox('Drum Matrix Build is already running.\nWait for it to finish before re-invoking.',
                   'EON DM Build', 0)
  return
end
-- Release the lock no matter how we exit (success, error, or one of the
-- early `return` paths below). atexit fires for one-shot scripts too.
r.atexit(function() safety.ReleaseScriptLock('build') end)

-- v1 header RELOCATED 2026-07-09 from cells 3/4 (foreign gmem trampler stomped
-- the 0..35 header region — see project_strip_sync_pad0_stomp / gmem relocation
-- map). Keep in sync with rk_lua_core.lua GMEM.NAMELEN / NAME_BASE.
local KIT_GMEM_NAMELEN = 26090303
local KIT_GMEM_NAME    = 26090304
local GS_SWING_ALIVE   = 1711
local MAX_FRAMES       = 10

local DEFAULT_PADS = {
  {pitch=36, name='Kick'},      {pitch=37, name='Side Stick'},
  {pitch=38, name='Snare'},     {pitch=39, name='Clap'},
  {pitch=40, name='Snare 2'},   {pitch=41, name='Low Tom'},
  {pitch=42, name='Closed HH'}, {pitch=43, name='High Tom'},
  {pitch=44, name='Pedal HH'},  {pitch=45, name='Mid Tom'},
  {pitch=46, name='Open HH'},   {pitch=47, name='Low Tom 2'},
  {pitch=48, name='Hi Tom'},    {pitch=49, name='Crash'},
  {pitch=50, name='Hi Tom 2'},  {pitch=51, name='Ride'},
}

-- ---------------------------------------------------------------------------
-- color helpers
-- ---------------------------------------------------------------------------

local function hsv_to_rgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  local rr, gg, bb = 0, 0, 0
  local seg = i % 6
  if     seg == 0 then rr, gg, bb = v, t, p
  elseif seg == 1 then rr, gg, bb = q, v, p
  elseif seg == 2 then rr, gg, bb = p, v, t
  elseif seg == 3 then rr, gg, bb = p, q, v
  elseif seg == 4 then rr, gg, bb = t, p, v
  else                 rr, gg, bb = v, p, q end
  return math.floor(rr * 255 + 0.5),
         math.floor(gg * 255 + 0.5),
         math.floor(bb * 255 + 0.5)
end

local function rainbow_color(pad_index)
  local h = ((pad_index - 1) % 16) / 16
  local R, G, B = hsv_to_rgb(h, 0.7, 0.85)
  return r.ColorToNative(R, G, B) | 0x1000000
end

local function dim_color_for_pad(pad_index)
  -- HSL -> RGB at hue=(pad-1)/16, sat 0.7, lit 0.55, then * 0.18 dim factor
  -- (matches the math in item_style.lua / EON_DM_SeedLane.lua).
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
  local rr = hue2rgb(h + 1/3)
  local gg = hue2rgb(h)
  local bb = hue2rgb(h - 1/3)
  local R = math.floor(rr * 255 * 0.18 + 0.5)
  local G = math.floor(gg * 255 * 0.18 + 0.5)
  local B = math.floor(bb * 255 * 0.18 + 0.5)
  return r.ColorToNative(R, G, B) | 0x1000000
end

-- ---------------------------------------------------------------------------
-- Swing track discovery
-- ---------------------------------------------------------------------------

local function find_swing_track()
  local n = r.CountTracks(0)
  local found = {}
  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    local fx_count = r.TrackFX_GetCount(tr)
    for fi = 0, fx_count - 1 do
      -- Same matcher the bridge ships (fx_ident / display-name patterns) —
      -- precise where the old lowercase-'swing' substring also caught
      -- unrelated FX with "swing" in a user-given name.
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

-- Multi-Swing picker: a native popup menu at the mouse listing each candidate
-- track. Returns the chosen entry or nil (cancelled). gfx.showmenu needs a
-- (zero-sized, invisible) gfx context; quit it immediately after.
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
    -- Scrub gfx.showmenu metacharacters from user-controlled track names.
    items[i] = label:gsub('[|#!<>&]', ' ')
  end
  local x, y = r.GetMousePosition()
  gfx.init('EON DM Build', 0, 0, 0, x, y)
  local choice = gfx.showmenu(table.concat(items, '|'))
  gfx.quit()
  if choice and choice >= 1 then return pool[choice] end
  return nil
end

-- ---------------------------------------------------------------------------
-- gmem readers
-- ---------------------------------------------------------------------------

local function read_live_pads()
  if (r.gmem_read(GS_SWING_ALIVE) or 0) == 0 then return nil end
  local pads = {}
  for i = 1, 16 do
    local pitch_raw = r.gmem_read(100 + (i - 1) * 80 + 10) or 0
    local pitch = math.floor(pitch_raw + 0.5)
    if pitch < 0 or pitch > 127 then pitch = DEFAULT_PADS[i].pitch end

    local name_base = 1720 + (i - 1) * 32
    local bytes = {}
    for j = 0, 31 do
      local c = r.gmem_read(name_base + j) or 0
      if c == 0 then break end
      bytes[#bytes + 1] = string.char(math.floor(c) & 0xFF)
    end
    local name = table.concat(bytes)
    if name == '' then name = DEFAULT_PADS[i].name end

    pads[i] = { pitch = pitch, name = name }
  end
  local any_nontrivial = false
  for i = 1, 16 do
    if pads[i].name ~= DEFAULT_PADS[i].name then any_nontrivial = true; break end
  end
  if not any_nontrivial then return nil end
  return pads
end

-- Per-instance variant: pads from the chosen Swing's own identity band
-- (registry-slot strided), so a multi-Swing session builds against the RIGHT
-- kit instead of whichever instance last published the shared block.
local function read_live_pads_slot(slot)
  local pads = {}
  for i = 1, 16 do
    local pitch = swing_state.GetPadPitch(i, slot)
    if not pitch or pitch == 0 then pitch = DEFAULT_PADS[i].pitch end
    local name = swing_state.GetPadName(i, slot)
    if name == '' then name = DEFAULT_PADS[i].name end
    pads[i] = { pitch = pitch, name = name }
  end
  local any_nontrivial = false
  for i = 1, 16 do
    if pads[i].name ~= DEFAULT_PADS[i].name then any_nontrivial = true; break end
  end
  if not any_nontrivial then return nil end
  return pads
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

-- ---------------------------------------------------------------------------
-- existing-kit detection / deletion
-- ---------------------------------------------------------------------------

local function find_existing_kit_folders(swing_guid)
  local out = {}
  local n = r.CountTracks(0)
  for i = 0, n - 1 do
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

local function delete_kit_folder(folder_track)
  -- Walk forward from folder_track collecting all tracks until folder depth
  -- returns to <= 0. Delete bottom-up so indices stay valid.
  local folder_idx = math.floor(r.GetMediaTrackInfo_Value(folder_track, 'IP_TRACKNUMBER') + 0.5) - 1
  local depth = 1
  local victims = { folder_track }
  local total = r.CountTracks(0)
  local i = folder_idx + 1
  while i < total and depth > 0 do
    local tr = r.GetTrack(0, i)
    if not tr then break end
    victims[#victims + 1] = tr
    local d = math.floor(r.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH') + 0.5)
    depth = depth + d
    i = i + 1
  end
  -- Delete bottom-up.
  for k = #victims, 1, -1 do
    r.DeleteTrack(victims[k])
  end
end

local function kit_suffix_for_existing(existing_count)
  -- existing_count is how many parallel kits already exist for this Swing.
  -- 0 -> "", 1 -> " Kit 2", 2 -> " Kit 3", ...
  if existing_count <= 0 then return '' end
  return string.format(' Kit %d', existing_count + 1)
end

-- ---------------------------------------------------------------------------
-- Phase 1: validate, attach gmem, bump heartbeat, defer to Phase 2
-- ---------------------------------------------------------------------------

local swing_hits = find_swing_track()
if #swing_hits == 0 then
  r.ShowMessageBox('No track with Swing JSFX found. Load Swing on a track first.',
                   'EON DM Build', 0)
  return
end

-- gmem must be attached before the registry reads in the selection below.
swing_state.Init()

-- Multi-Swing instance selection: one hit uses it directly; otherwise prefer
-- the (single) selected track carrying a Swing, else pop the picker menu.
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
    if not chosen then return end   -- picker cancelled
  end
end

local swing_track = chosen.track
local chosen_inst_id = chosen.inst_id

-- Swing-on-master guard: we can't insert sibling/child tracks under the master.
if swing_track == r.GetMasterTrack(0) then
  r.ShowMessageBox('Swing on the master track is not supported.', 'EON DM Build', 0)
  return
end

local swing_guid = r.GetTrackGUID(swing_track)

-- Stereo-grid coexistence: if this Swing track carries a stereo-mode lane tag
-- (auto-setup on insert, or EON_DM_BuildStereo), building classic lanes
-- alongside it would have BOTH editors feeding the same kit. When the stereo
-- pattern is still EMPTY (the untouched auto-seeded item) there is nothing to
-- lose — clear the tag silently. Only prompt when real notes are at stake;
-- the MIDI item stays on the Swing track either way and still plays.
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
        'Building lanes will MOVE the pattern onto the new per-pad lanes and\n' ..
        'remove the stereo MIDI item from the Swing track (notes at pitches that\n' ..
        'are not live pads are dropped).\n\nContinue?',
        'EON DM Build', 4)   -- Yes/No
      if resp ~= 6 then return end
    end
    clear_stereo_tag = true
  end
end

-- Collision: are there already DM folder(s) for this Swing instance?
local existing = find_existing_kit_folders(swing_guid)
local replace_existing = false
local kit_suffix = ''
if #existing > 0 then
  -- Yes/No/Cancel = MB type 3, returns 6/7/2.
  local resp = r.ShowMessageBox(
    'Drum Matrix lanes already exist for this Swing.\n\n' ..
    'YES = Replace (delete existing + rebuild)\n' ..
    'NO = Add a parallel set (Kit 2, Kit 3...)\n' ..
    'CANCEL = abort',
    'EON DM Build', 3)
  if resp == 2 then
    return                        -- Cancel: bail before any change.
  elseif resp == 6 then
    replace_existing = true       -- Yes: delete existing kits, rebuild fresh.
  elseif resp == 7 then
    kit_suffix = kit_suffix_for_existing(#existing)   -- No: add parallel set.
  else
    return                        -- Unknown / dialog closed.
  end
end

r.gmem_attach('Swing_Media_Transfer')
r.gmem_write(99, os.time())   -- bump KIT_GMEM_BRIDGE_ALIVE so JSFX publishes.

local frames_waited = 0

-- ---------------------------------------------------------------------------
-- Phase 2: deferred build
-- ---------------------------------------------------------------------------

-- Kit display name for the chosen instance. The legacy shared-block name is
-- only trustworthy when ONE Swing exists (any instance's kit load overwrites
-- it); for multi-Swing, parse the instance's parent folder ("Swing — <kit>",
-- maintained by the bridge), then fall back to the Swing track's own name.
local function resolve_kit_name()
  if #swing_hits == 1 then
    return read_kit_name_from_gmem()
  end
  local parent = folder_layout and folder_layout.FindParent(swing_track)
  if parent then
    local _, pn = r.GetSetMediaTrackInfo_String(parent, 'P_NAME', '', false)
    if pn then
      local kit = pn:match('^Swing — (.+)$') or pn:match('^Swing %- (.+)$')
      if kit and kit ~= '' then return kit end
    end
  end
  local _, tn = r.GetSetMediaTrackInfo_String(swing_track, 'P_NAME', '', false)
  if tn and tn ~= '' then return tn end
  return 'Kit'
end

local function do_build(slot)
  -- Pad source priority: the chosen instance's per-slot band; the legacy
  -- shared block ONLY when it's unambiguous (single Swing); else defaults —
  -- swing_sync adopts the real names/pitches the moment the instance
  -- heartbeats, so a default build self-heals rather than mirroring the
  -- WRONG kit.
  local pads
  if slot ~= nil then
    pads = read_live_pads_slot(slot)
  elseif #swing_hits == 1 then
    pads = read_live_pads()
  else
    safety.ConsoleWarn('Build: chosen Swing not registered yet — building default lanes (they sync once it goes live).')
  end
  pads = pads or DEFAULT_PADS
  local kit_name = resolve_kit_name()
  local created_at = os.date('!%Y-%m-%dT%H:%M:%SZ')

  local cursor_time = r.GetCursorPosition()
  if cursor_time < 0 then cursor_time = 0 end
  local cursor_qn  = r.TimeMap_timeToQN(cursor_time)
  local item_end_t = r.TimeMap_QNToTime(cursor_qn + 16)   -- 4 bars

  -- STEREO -> MULTI migration (capture pass): when we're clearing a stereo tag
  -- off a Swing that has notes, re-home every stereo note onto the pad lane
  -- we're about to build. pitch -> pad comes straight from THIS build's pad
  -- list, so a note only moves if its pitch is a live pad (unmapped pitches are
  -- dropped, by design). Captured NOW, before the tag/items are touched. The
  -- lane items grow to cover the whole stereo span so no note is lost; the
  -- write + source-item delete happen after the lanes exist (below).
  local lane_takes = {}
  local migrate_notes, build_t0, build_t1 = nil, cursor_time, item_end_t
  if clear_stereo_tag then
    local pitch2pad = {}
    for i = 1, 16 do
      local pd = pads[i]
      if pd and pd.pitch then pitch2pad[pd.pitch] = pitch2pad[pd.pitch] or i end
    end
    local notes, tmin, tmax = {}, nil, nil
    for ii = 0, r.CountTrackMediaItems(swing_track) - 1 do
      local take = r.GetActiveTake(r.GetTrackMediaItem(swing_track, ii))
      if take and r.TakeIsMIDI(take) then
        local _, ncnt = r.MIDI_CountEvts(take)
        for j = 0, ncnt - 1 do
          local ok, _, _, ps, pe, _, pitch, vel = r.MIDI_GetNote(take, j)
          local pad = ok and pitch2pad[pitch]
          if pad then
            local ts = r.MIDI_GetProjTimeFromPPQPos(take, ps)
            local te = r.MIDI_GetProjTimeFromPPQPos(take, pe)
            notes[#notes + 1] = { pad = pad, pitch = pitch, vel = vel, ts = ts, te = te }
            if not tmin or ts < tmin then tmin = ts end
            if not tmax or te > tmax then tmax = te end
          end
        end
      end
    end
    if #notes > 0 then
      migrate_notes = notes
      if tmin < build_t0 then build_t0 = tmin end
      if tmax > build_t1 then build_t1 = tmax end
    end
  end

  -- Build ALWAYS creates fresh MIDI tracks. ADAPT was tried (writing MIDI sends
  -- onto existing audio-return kit tracks) but didn't produce sound — MIDI tracks
  -- need to be separate from the multi-out audio-return tracks in this setup.
  r.Undo_BeginBlock()

  -- Stereo-grid handoff confirmed in Phase 1: drop the stereo lane tag so the
  -- Swing track stops classifying as a lane (its item is left in place).
  if clear_stereo_tag then
    r.GetSetMediaTrackInfo_String(swing_track, 'P_EXT:EON_DRUM_LANE', '', true)
  end

  -- If replacing, delete prior folders first (the GUID match is stable across
  -- track-index shifts as long as we re-query each time).
  if replace_existing then
    local victims = find_existing_kit_folders(swing_guid)
    for _, folder in ipairs(victims) do
      delete_kit_folder(folder)
    end
  end

  -- Find Swing track's CURRENT 0-based index (may have shifted after deletes).
  local swing_idx = math.floor(r.GetMediaTrackInfo_Value(swing_track, 'IP_TRACKNUMBER') + 0.5) - 1

  -- Place the DM folder INSIDE Swing's parent, AFTER any existing audio
  -- sub-folder + its 16 multi-outs. If no parent exists yet (user built DM
  -- without first running Multi-Out), create one — Swing gets a parent
  -- folder above it so the layout is consistent whichever build runs first.
  -- folder_layout.EnsureSwingParentLayout below normalises the depths
  -- afterwards regardless of insertion order.
  if folder_layout then folder_layout.EnsureParent(swing_track) end
  local end_of_parent = folder_layout and folder_layout.EndOfParentIndex(swing_track) or nil
  local folder_idx = end_of_parent and (end_of_parent + 1) or (swing_idx + 1)
  -- Re-read Swing's index in case EnsureParent shifted it.
  swing_idx = math.floor(r.GetMediaTrackInfo_Value(swing_track, 'IP_TRACKNUMBER') + 0.5) - 1

  -- Insert the DM folder header at the computed end-of-parent position.
  -- Track name is the static functional label "MIDI" (the Swing bridge's
  -- update_folder_track_name also enforces this on every sync; the kit name
  -- rides the PARENT folder "Swing — <kit>"). kit_suffix distinguishes
  -- parallel kit sets ("MIDI 2", ...).
  r.InsertTrackAtIndex(folder_idx, true)
  local folder = r.GetTrack(0, folder_idx)
  local folder_name = 'MIDI' .. kit_suffix
  r.GetSetMediaTrackInfo_String(folder, 'P_NAME', folder_name, true)
  r.SetMediaTrackInfo_Value(folder, 'I_FOLDERDEPTH', 1)   -- start folder
  r.GetSetMediaTrackInfo_String(folder, 'P_EXT:EON_DRUM_KIT_FOLDER',
    json.encode({
      swing_guid = swing_guid,
      kit_name   = kit_name,
      created_at = created_at,
    }), true)

  -- Lane color ownership: under "reaper"/"none" Swing must NOT paint lane
  -- tracks. Read once (hoisted out of the 16-iteration loop); absent/unknown →
  -- "swing". With swing_sync's lane_diff gated too, a skipped rainbow is never
  -- cleaned up — so it must not be painted in the first place under those modes.
  local _, _lc_pol = r.GetSetMediaTrackInfo_String(
    swing_track, 'P_EXT:EON_LANE_COLOR_POLICY', '', false)
  local _lc_write = (_lc_pol ~= 'reaper' and _lc_pol ~= 'none')

  -- Insert 16 child MIDI lanes immediately after the DM folder header
  -- (which sits at folder_idx — possibly NOT right after Swing when an
  -- audio sub-folder already occupies the slot between).
  for pad_idx = 1, 16 do
    local insert_at = folder_idx + pad_idx
    r.InsertTrackAtIndex(insert_at, true)
    local child = r.GetTrack(0, insert_at)
    local pad = pads[pad_idx]

    r.GetSetMediaTrackInfo_String(child, 'P_NAME',
      string.format('%02d %s', pad_idx, pad.name), true)
    if _lc_write then r.SetTrackColor(child, rainbow_color(pad_idx)) end
    -- B_MAINSEND off: audio returns from Swing's outputs already; the lane
    -- itself shouldn't add its own (silent) bus to master.
    r.SetMediaTrackInfo_Value(child, 'B_MAINSEND', 0)

    -- MIDI send to Swing: audio src disabled, all MIDI channels.
    local send_idx = r.CreateTrackSend(child, swing_track)
    if send_idx >= 0 then
      r.SetTrackSendInfo_Value(child, 0, send_idx, 'I_SRCCHAN', -1)
      r.SetTrackSendInfo_Value(child, 0, send_idx, 'I_MIDIFLAGS', 0)
    end

    -- Pre-create the pattern MIDI item (dim color, no take label). Normally a
    -- 4-bar block at the cursor; when migrating a stereo pattern the window is
    -- widened to [build_t0, build_t1] so every re-homed note has a home.
    local new_item = r.CreateNewMIDIItemInProj(child, build_t0, build_t1, false)
    if new_item then
      r.SetMediaItemInfo_Value(new_item, 'I_CUSTOMCOLOR', dim_color_for_pad(pad_idx))
      local take = r.GetActiveTake(new_item)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', true)
        lane_takes[pad_idx] = take
      end
    end

    -- Lane P_EXT. Auto-infer category from pad name so the preset library
    -- can target this pad without the user manually tagging it.
    r.GetSetMediaTrackInfo_String(child, 'P_EXT:EON_DRUM_LANE',
      json.encode({
        swing_instance_guid = swing_guid,
        pad_index   = pad_idx,
        pad_pitch   = pad.pitch,
        pad_channel = 1,
        pad_name    = pad.name,
        category    = category.InferFromName(pad.name),
        created_at  = created_at,
      }), true)

    -- Depth math is handed off to folder_layout.EnsureSwingParentLayout
    -- below. Everything goes in at depth 0; the reorganiser walks the
    -- parent afterwards and sets the canonical close-depth pattern (-1
    -- on every non-final sub-folder's last child, -2 on the final
    -- sub-folder's last child to also close the parent).
    r.SetMediaTrackInfo_Value(child, 'I_FOLDERDEPTH', 0)
  end

  -- STEREO -> MULTI migration (write pass): drop each captured note onto its
  -- pad's lane take at the same project time, then delete the stereo source
  -- items so the pattern plays from the lanes only (no double-trigger through
  -- Swing). Runs inside this build's one Undo block -- no nested Undo, unlike
  -- lane_tools.WriteRegion which owns its own.
  if migrate_notes then
    for _, mn in ipairs(migrate_notes) do
      local take = lane_takes[mn.pad]
      if take then
        local ppq_s = r.MIDI_GetPPQPosFromProjTime(take, mn.ts)
        local ppq_e = r.MIDI_GetPPQPosFromProjTime(take, mn.te)
        if ppq_e <= ppq_s then ppq_e = ppq_s + 1 end
        r.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0, mn.pitch, mn.vel, true)
      end
    end
    for _, take in pairs(lane_takes) do r.MIDI_Sort(take) end
    for ii = r.CountTrackMediaItems(swing_track) - 1, 0, -1 do
      local item = r.GetTrackMediaItem(swing_track, ii)
      local take = r.GetActiveTake(item)
      if take and r.TakeIsMIDI(take) then r.DeleteTrackMediaItem(swing_track, item) end
    end
  end

  -- Single-source layout pass — sets canonical FOLDERDEPTH for Swing's
  -- parent and every sub-folder inside it (audio sub-folder if Multi-Out
  -- has been built, this new DM folder, and any future Sedan folder).
  -- Last sub-folder's last child closes the parent (-2); non-final
  -- sub-folders close with -1. Idempotent — safe to run after any build.
  if folder_layout then folder_layout.EnsureSwingParentLayout(swing_track) end

  r.Undo_EndBlock('EON DM: build drum matrix session', -1)
  r.UpdateArrange()
  r.TrackList_AdjustWindows(false)

  local done_msg = string.format(
    'Built "%s" lanes for kit "%s" — 16 lanes ready.\nLoad/restart eon_drum_matrix.lua to display.',
    folder_name, kit_name)
  -- House notice, async: the dialog's own defer loop keeps this one-shot
  -- script alive until OK, so atexit (script-lock release) fires after the
  -- dismiss — the lock's 30 s TTL caps the hold if the box is left open.
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.info and eon_dlg.info({
    title = 'EON DM Build', message = done_msg,
  })
  if not shown then r.ShowMessageBox(done_msg, 'EON DM Build', 0) end
end

local function wait_then_build()
  frames_waited = frames_waited + 1
  -- Primary readiness signal: the CHOSEN instance's registry slot (heartbeats
  -- every @block — resolves on the first frame when the FX is processing).
  -- The legacy GS_SWING_ALIVE counter only short-circuits the wait when one
  -- Swing exists: with several, ANY instance ticks it, which says nothing
  -- about the one we picked.
  local slot = swing_state.ResolveSlot(chosen_inst_id)
  local alive = r.gmem_read(GS_SWING_ALIVE) or 0
  if slot ~= nil
     or (#swing_hits == 1 and alive > 0)
     or frames_waited >= MAX_FRAMES then
    do_build(slot)
    return
  end
  r.defer(wait_then_build)
end

r.defer(wait_then_build)
