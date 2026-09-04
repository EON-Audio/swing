-- lane_tools.lua -- EON Drum Matrix. Operations on drum lanes invoked from
-- the settings window's Tools tab. Every op iterates the lane's tracks,
-- mutates MIDI inside one Undo block per gesture, and respects the canonical
-- HARD CONTRACT from paint_mode.lua:
--   * MIDI_InsertNote / MIDI_DeleteNote / MIDI_SetNote MUST be followed by
--     MIDI_Sort(take) + UpdateItemInProject(item).
--   * Typed MIDI API only (no MIDI_GetEvt / MIDI_InsertEvt).
--   * Undo_BeginBlock / Undo_EndBlock wraps every mutating call.

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.decode then json = mod end
end

-- Swing math (#8) lives in arrange_coords (same module the renderer/paint use).
local coords
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'arrange_coords.lua')
  if ok and type(mod) == 'table' and mod.SwingTransformQN then coords = mod end
end

-- Slots toolbar (#4) highlight-clear hook. Injected by eon_drum_matrix so the
-- SAME slots_strip instance (and its last_loaded_letter state) is notified —
-- we must NOT dofile slots_strip here (that would make a second copy with its
-- own state). Any lane-tools mutation diverges the pattern from the recalled
-- slot, so we drop the highlight.
local _note_user_edit = nil
function M.SetNoteUserEditHook(fn) _note_user_edit = fn end
local function note_user_edit()
  if _note_user_edit then _note_user_edit() end
end

-- Status-bar helper for empty-lane no-ops so the user sees feedback when an
-- operation runs against an empty pattern. Without this, Clear/Quantize/Mirror
-- on a blank lane look broken (and inconsistent with Randomize which already
-- prints).
local function status(msg)
  if msg and reaper.Help_Set then reaper.Help_Set(msg, false) end
end

-- =============================================================================
-- lane discovery
-- =============================================================================

-- Read the P_EXT:EON_DRUM_LANE JSON off a track. Returns { track, lane_info }
-- or nil if the track isn't a drum lane.
function M.LaneFromTrack(tr)
  if not tr or not json then return nil end
  local ok, raw = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_LANE', '', false)
  if not ok or raw == '' then return nil end
  local dec_ok, lane = pcall(json.decode, raw)
  if not dec_ok or type(lane) ~= 'table' or not lane.pad_pitch then return nil end
  return { track = tr, lane_info = lane }
end

-- Get whichever drum lane is currently selected in REAPER (or nil if no
-- selected track is tagged). Used as the default tool target.
function M.GetSelectedLane()
  local tr = reaper.GetSelectedTrack(0, 0)
  return M.LaneFromTrack(tr)
end

-- Return a list of { track, lane_info } for every track tagged as a Drum Matrix
-- lane (P_EXT:EON_DRUM_LANE present and JSON-decodable). Order = REAPER track
-- order.
function M.GetLanes()
  local out = {}
  if not json then return out end
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local ok, raw = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_LANE', '', false)
    if ok and raw ~= '' then
      local dec_ok, lane = pcall(json.decode, raw)
      if dec_ok and type(lane) == 'table' and lane.pad_pitch then
        out[#out + 1] = { track = tr, lane_info = lane }
      end
    end
  end
  return out
end

-- =============================================================================
-- low-level helpers (operate on one take/lane at a time)
-- =============================================================================

local function each_midi_take_on_track(track, fn)
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      fn(item, take)
    end
  end
end

-- Live Swing pad map (swing_state_reader over the per-slot identity band).
-- Loaded lazily; `false` remembers a failed load so we don't retry per call.
-- Declared up here because lane_range below needs it for stereo lanes.
local swing_state
local function ensure_swing_state()
  if swing_state ~= nil then return swing_state or nil end
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'swing_state_reader.lua')
  swing_state = (ok and type(mod) == 'table' and mod.SlotForLane) and mod or false
  return swing_state or nil
end

-- { [pad_index] = live pitch } for a stereo lane, straight from the paired
-- Swing's identity band -- EVERY valid pad, no window applied. nil when the
-- instance can't be resolved (offline / no bridge), so callers fall back to
-- the tag's contiguous layout.
local function stereo_live_pitches(lane_info)
  local ss = ensure_swing_state()
  if not ss then return nil end
  pcall(ss.Init)
  local ok, slot = pcall(ss.SlotForLane, lane_info)
  if not ok or slot == nil then return nil end
  local map, any = {}, false
  for pad = 1, 16 do
    local ok2, p = pcall(ss.GetPadPitch, pad, slot)
    if ok2 and type(p) == 'number' and p == math.floor(p) and p > 0 and p <= 127 then
      map[pad] = p
      any = true
    end
  end
  return any and map or nil
end

-- Resolve a lane's pitch range. Piano lanes use note_lo..note_hi; drum lanes
-- collapse to pad_pitch..pad_pitch (so range-aware ops behave identically there).
--
-- STEREO lanes FOLLOW THE LIVE PAD MAP (2026-09-02). The tag's note_lo/note_hi
-- were frozen when the bridge first saw the Swing (root..root+15, root=36 on a
-- fresh insert), so any kit or remap that moved a pad outside that window had
-- the pad DROPPED on StepSeq export and then WIPED from the StepSeq grid on the
-- next region re-import (rig: .dev_tests/sssync_run.sh NO_SHOW ROOT44 -- rows
-- 8..11 vanished). The range is now the UNION of the tag window and the live
-- pitches: the live half is what makes every pad collectable/writable, the tag
-- half keeps notes at pitches a pad USED to own inside the clear window, so an
-- export still fully defines the region instead of leaving stale hits behind.
local function lane_range(lane_info)
  local lo, hi = lane_info.note_lo, lane_info.note_hi
  local tagged = type(lo) == 'number' and type(hi) == 'number' and hi >= lo
  if lane_info.stereo == true then
    local live = stereo_live_pitches(lane_info)
    if live then
      if not tagged then lo, hi = nil, nil end   -- malformed tag: live map alone
      for _, p in pairs(live) do
        if not lo or p < lo then lo = p end
        if not hi or p > hi then hi = p end
      end
      return lo, hi
    end
  end
  if tagged then return lo, hi end
  local p = lane_info.pad_pitch
  return p, p
end
M.LaneRange = lane_range
M.StereoLivePitches = stereo_live_pitches   -- { [pad] = pitch } or nil when offline

-- Is a StepSeq currently SYNCED to this lane's Swing? (Package 2: swing has one owner.
-- While synced, the StepSeq's groove is what the item carries and what plays; the DM's
-- own lane swing is shown as following it.) Reads the StepSeq courier band's SYNCON
-- field for the lane's registry slot; false when the instance can't be resolved.
function M.LaneSynced(lane_info)
  local ss = ensure_swing_state()
  if not ss then return false end
  pcall(ss.Init)
  local ok, slot = pcall(ss.SlotForLane, lane_info)
  if not ok or slot == nil then return false end
  return (reaper.gmem_read(26030000 + slot * 64 + 11) or 0) > 0.5   -- EON_SS_SYNC_SS_SYNCON
end

-- Collect all notes on `take` whose pitch is within [lo..hi]. For drum lanes
-- (lo == hi == pad_pitch) this is the original single-pitch behavior. The note
-- record carries `pitch` so range-aware ops can preserve each note's pitch.
-- Returns { { idx, ppq_s, ppq_e, pitch, vel, chan, sel, muted }, ... }.
local function collect_notes(take, lo, hi)
  local out = {}
  local _, n = reaper.MIDI_CountEvts(take)
  for i = 0, n - 1 do
    local ok, sel, muted, ppq_s, ppq_e, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok and pitch >= lo and pitch <= hi then
      out[#out + 1] = {
        idx = i, ppq_s = ppq_s, ppq_e = ppq_e, pitch = pitch,
        vel = vel, chan = chan, sel = sel, muted = muted,
      }
    end
  end
  return out
end

-- Range-aware gather keyed off a lane: piano lanes collect every note in
-- [note_lo..note_hi]; drum lanes collect only the pad pitch.
local function collect_lane_notes(take, lane_info)
  local lo, hi = lane_range(lane_info)
  return collect_notes(take, lo, hi)
end

local function delete_notes_desc(take, indices)
  table.sort(indices, function(a, b) return a > b end)   -- delete high-to-low
  for _, idx in ipairs(indices) do
    reaper.MIDI_DeleteNote(take, idx)
  end
  reaper.MIDI_Sort(take)
end

local function finalize_take(take)
  local item = reaper.GetMediaItemTake_Item(take)
  if item then reaper.UpdateItemInProject(item) end
end

-- =============================================================================
-- operations
-- =============================================================================

-- Delete every note matching the lane's pad_pitch across all the lane's items.
function M.ClearLane(lane)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local removed = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    if #notes > 0 then
      local idxs = {}
      for _, n in ipairs(notes) do idxs[#idxs + 1] = n.idx end
      delete_notes_desc(take, idxs)
      removed = removed + #idxs
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock('EON DM: clear lane', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if removed == 0 then status('EON DM: lane already empty') end
  return removed
end

function M.ClearAllLanes()
  local total = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  for _, lane in ipairs(M.GetLanes()) do
    each_midi_take_on_track(lane.track, function(item, take)
      local notes = collect_lane_notes(take, lane.lane_info)
      if #notes > 0 then
        local idxs = {}
        for _, n in ipairs(notes) do idxs[#idxs + 1] = n.idx end
        delete_notes_desc(take, idxs)
        total = total + #idxs
        finalize_take(take)
      end
    end)
  end
  reaper.Undo_EndBlock('EON DM: clear all lanes', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  return total
end

-- Clear the whole clip: delete EVERY note on the lane's items regardless of
-- pitch (vs ClearLane, which only clears the lane's range). Handy on piano
-- lanes to wipe a melodic clip outright, or to nuke foreign notes in one shot.
function M.ClearClip(lane)
  if not (lane and lane.track) then return 0 end
  local removed = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local _, n = reaper.MIDI_CountEvts(take)
    if n > 0 then
      local idxs = {}
      for i = 0, n - 1 do idxs[#idxs + 1] = i end
      delete_notes_desc(take, idxs)
      removed = removed + #idxs
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock('EON DM: clear clip (all notes)', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if removed == 0 then status('EON DM: clip already empty') end
  return removed
end

-- Quantize all matching notes on the lane to the current project grid.
-- Uses NEAREST snap (REAPER's convention for quantize).
function M.QuantizeLane(lane)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local _, grid_div_qn = reaper.GetSetProjectGrid(0, false)
  if not grid_div_qn or grid_div_qn == 0 then
    status('EON DM: no grid set — cannot quantize')
    return 0
  end
  local moved = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    -- Per-TAKE move counter — avoids the previous outer-counter bug where a
    -- previous take's moves caused the next take's sort to fire spuriously.
    local take_moved = 0
    for _, n in ipairs(notes) do
      local proj_t  = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_s)
      local proj_e  = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_e)
      local dur     = proj_e - proj_t
      local qn      = reaper.TimeMap_timeToQN(proj_t)
      local snapped = math.floor(qn / grid_div_qn + 0.5) * grid_div_qn
      local new_t   = reaper.TimeMap_QNToTime(snapped)
      if math.abs(new_t - proj_t) > 1e-6 then
        local new_ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, new_t)
        local new_ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, new_t + dur)
        reaper.MIDI_SetNote(take, n.idx, nil, nil, new_ppq_s, new_ppq_e, nil, nil, nil, true)
        take_moved = take_moved + 1
      end
    end
    -- Unconditional Sort + finalize on any take that had matching notes —
    -- protects us from skipping when every note happened to already be on
    -- the grid (zero moves but we still inspected notes). MIDI_Sort on an
    -- unchanged take is a cheap no-op.
    if #notes > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
    moved = moved + take_moved
  end)
  reaper.Undo_EndBlock('EON DM: quantize lane', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if moved == 0 then status('EON DM: nothing to quantize (lane empty or already on grid)') end
  return moved
end

-- Shift every existing note in the lane onto its swung position: snap to the
-- nearest straight grid cell, then move to that cell's swung start. Uses the
-- lane's own swing_amount. No-op on a non-power-of-2 grid (matches the slider
-- being disabled there). Mirrors QuantizeLane's per-take Sort/finalize shape.
function M.ApplySwingToLane(lane)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  if not coords then status('EON DM: swing math unavailable'); return 0 end
  local sw = tonumber(lane.lane_info.swing_amount) or 0
  local _, gdiv = reaper.GetSetProjectGrid(0, false)
  if not gdiv or gdiv == 0 then status('EON DM: no grid set — cannot apply swing'); return 0 end
  -- Effective swing grid: a lane's own swing_subdiv overrides the project grid
  -- so Apply snaps/shifts on the SAME grid the lane's render + paint use.
  local sd    = tonumber(lane.lane_info.swing_subdiv)
  local g_eff = (sd and sd > 0) and sd or gdiv
  if not coords.IsSwingableDiv(g_eff) then
    status('EON DM: swing needs a 1/4–1/16 or triplet grid'); return 0
  end
  local moved = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    local take_moved = 0
    for _, n in ipairs(notes) do
      local proj_t = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_s)
      local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_e)
      local dur    = proj_e - proj_t
      local qn     = reaper.TimeMap_timeToQN(proj_t)
      local cell_idx = math.floor(qn / g_eff + 0.5)
      local swung_qn = coords.SwingTransformQN(cell_idx * g_eff, g_eff, sw)
      local new_t    = reaper.TimeMap_QNToTime(swung_qn)
      if math.abs(new_t - proj_t) > 1e-6 then
        local nps = reaper.MIDI_GetPPQPosFromProjTime(take, new_t)
        local npe = reaper.MIDI_GetPPQPosFromProjTime(take, new_t + dur)
        reaper.MIDI_SetNote(take, n.idx, nil, nil, nps, npe, nil, nil, nil, true)
        take_moved = take_moved + 1
      end
    end
    if #notes > 0 then reaper.MIDI_Sort(take); finalize_take(take) end
    moved = moved + take_moved
  end)
  reaper.Undo_EndBlock('EON DM: apply swing to lane', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if moved == 0 then status('EON DM: nothing to swing (lane empty or already swung)') end
  return moved
end

-- Mirror notes around the midpoint of the item they live in.
-- Each note's start time gets flipped: new_start = item_end - (note_end - item_start).
function M.MirrorLane(lane)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local moved = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local item_end   = item_start + item_len
    local notes = collect_lane_notes(take, lane.lane_info)
    -- Build new positions BEFORE applying so we don't read mutated state mid-loop.
    local new_pos = {}
    for _, n in ipairs(notes) do
      local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_s)
      local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_e)
      local dur    = proj_e - proj_s
      local new_s  = item_end - (proj_s - item_start) - dur
      if new_s < item_start then new_s = item_start end
      new_pos[#new_pos + 1] = { idx = n.idx, new_s = new_s, dur = dur }
    end
    for _, np in ipairs(new_pos) do
      local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, np.new_s)
      local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, np.new_s + np.dur)
      reaper.MIDI_SetNote(take, np.idx, nil, nil, ppq_s, ppq_e, nil, nil, nil, true)
      moved = moved + 1
    end
    if #new_pos > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock('EON DM: mirror lane', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if moved == 0 then status('EON DM: nothing to mirror (lane empty)') end
  return moved
end

-- Shift every note on the lane by `direction * grid_step` seconds.
-- direction: +1 = right, -1 = left. Honors the current project grid.
function M.ShiftLane(lane, direction)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local _, grid_div_qn = reaper.GetSetProjectGrid(0, false)
  if not grid_div_qn or grid_div_qn == 0 then return 0 end
  local moved = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    for _, n in ipairs(notes) do
      local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_s)
      local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_e)
      local qn_s   = reaper.TimeMap_timeToQN(proj_s) + direction * grid_div_qn
      local qn_e   = reaper.TimeMap_timeToQN(proj_e) + direction * grid_div_qn
      local new_s  = reaper.TimeMap_QNToTime(qn_s)
      local new_e  = reaper.TimeMap_QNToTime(qn_e)
      local new_ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, new_s)
      local new_ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, new_e)
      reaper.MIDI_SetNote(take, n.idx, nil, nil, new_ppq_s, new_ppq_e, nil, nil, nil, true)
      moved = moved + 1
    end
    -- Per-TAKE gate (mirrors QuantizeLane): sort only takes that actually had
    -- matching notes. The old `moved > 0` test was a cumulative counter, so
    -- once any take moved a note every later take sorted spuriously.
    if #notes > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock(
    string.format('EON DM: shift lane %s', direction > 0 and 'right' or 'left'),
    -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if moved == 0 then status('EON DM: nothing to shift (lane empty)') end
  return moved
end

-- Fill every Nth grid step inside the lane's items with a note at the lane's
-- pad pitch. Optionally clear any existing notes first.
-- step_n: 1 means every grid step, 2 means every other, 4 means every 4th, etc.
-- clear_first: bool — when true, remove existing notes on this lane before fill.
function M.FillEveryN(lane, step_n, clear_first)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  if not step_n or step_n < 1 then step_n = 1 end
  local _, grid_div_qn = reaper.GetSetProjectGrid(0, false)
  if not grid_div_qn or grid_div_qn == 0 then return 0 end
  local pitch = lane.lane_info.pad_pitch
  local inserted = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    if clear_first then
      local existing = collect_lane_notes(take, lane.lane_info)
      if #existing > 0 then
        local idxs = {}
        for _, e in ipairs(existing) do idxs[#idxs + 1] = e.idx end
        delete_notes_desc(take, idxs)
      end
    end
    local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local item_end   = item_start + item_len

    local start_qn = reaper.TimeMap_timeToQN(item_start)
    local end_qn   = reaper.TimeMap_timeToQN(item_end)
    local effective_step_qn = grid_div_qn * step_n
    local first_idx = math.ceil(start_qn / effective_step_qn - 1e-6)
    local last_idx  = math.floor(end_qn / effective_step_qn + 1e-6)

    for idx = first_idx, last_idx do
      local t       = reaper.TimeMap_QNToTime(idx * effective_step_qn)
      if t >= item_start - 1e-6 and t < item_end - 1e-6 then
        local len_t = reaper.TimeMap_QNToTime(idx * effective_step_qn + grid_div_qn) - t
        local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, t)
        local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, t + len_t)
        reaper.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0, pitch, 100, true)
        inserted = inserted + 1
      end
    end
    if inserted > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock(
    string.format('EON DM: fill every %d steps', step_n),
    -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if inserted == 0 then status('EON DM: nothing to fill (no items on lane?)') end
  return inserted
end

-- =============================================================================
-- Phase E: additional lane operations
-- =============================================================================

local _settings_ok, _settings_lib = pcall(dofile, SCRIPT_DIR .. 'settings_store.lua')
local _settings = (_settings_ok and _settings_lib) or nil

local function _default_velocity()
  if _settings and _settings.Get then
    local v = _settings.Get('default_velocity') or 100
    if v < 1 then v = 1 elseif v > 127 then v = 127 end
    return v
  end
  return 100
end

-- Insert `count` evenly-spaced notes inside the grid step containing `time`.
function M.Roll(lane, time, count)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  if not count or count < 2 then count = 2 end
  local _, grid_div_qn = reaper.GetSetProjectGrid(0, false)
  if not grid_div_qn or grid_div_qn == 0 then return 0 end

  local pitch = lane.lane_info.pad_pitch   -- roll sub-notes use the pad's root pitch
  local lo, hi = lane_range(lane.lane_info) -- but clear any in-range note in the cell
  local vel   = _default_velocity()
  local qn    = reaper.TimeMap_timeToQN(time)
  local cell_start_qn = math.floor(qn / grid_div_qn) * grid_div_qn
  local sub_qn        = grid_div_qn / count

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local inserted = 0
  each_midi_take_on_track(lane.track, function(item, take)
    local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local item_end   = item_start + item_len
    local cell_start_t = reaper.TimeMap_QNToTime(cell_start_qn)
    if cell_start_t >= item_start - 1e-6 and cell_start_t < item_end - 1e-6 then
      -- Clear notes that already sit in this cell.
      local _, ncount = reaper.MIDI_CountEvts(take)
      local victims = {}
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, _, _, p = reaper.MIDI_GetNote(take, i)
        if ok and p >= lo and p <= hi then
          local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
          if t >= cell_start_t - 1e-6
             and t < reaper.TimeMap_QNToTime(cell_start_qn + grid_div_qn) - 1e-6 then
            victims[#victims + 1] = i
          end
        end
      end
      delete_notes_desc(take, victims)
      for k = 0, count - 1 do
        local sub_t = reaper.TimeMap_QNToTime(cell_start_qn + k * sub_qn)
        local sub_e = reaper.TimeMap_QNToTime(cell_start_qn + (k + 1) * sub_qn)
        local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, sub_t)
        local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, sub_e)
        reaper.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0, pitch, vel, true)
        inserted = inserted + 1
      end
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock(string.format('EON DM: roll x%d', count), -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  return inserted
end

-- Boost velocity on every Nth EXISTING note (sorted by start time).
function M.AccentEveryN(lane, n, boost)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  if not n or n < 1 then n = 4 end
  if not boost or boost == 0 then boost = 30 end
  local pitch = lane.lane_info.pad_pitch
  local bumped = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    table.sort(notes, function(a, b) return a.ppq_s < b.ppq_s end)
    for i, note in ipairs(notes) do
      if (i - 1) % n == 0 then
        local new_vel = note.vel + boost
        if new_vel < 1 then new_vel = 1 elseif new_vel > 127 then new_vel = 127 end
        reaper.MIDI_SetNote(take, note.idx, nil, nil, nil, nil, nil, nil, new_vel, true)
        bumped = bumped + 1
      end
    end
    if bumped > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock(string.format('EON DM: accent every %d', n), -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  return bumped
end

-- Random timing (±time_ms ms) + velocity (±vel_amount on 0-127 scale) jitter
-- on every lane note. Defaults pulled from settings when args omitted.
function M.HumanizeLane(lane, time_ms, vel_amount)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  if not time_ms    and _settings then time_ms    = _settings.Get('humanize_time_ms')    end
  if not vel_amount and _settings then vel_amount = _settings.Get('humanize_vel_amount') end
  time_ms    = time_ms    or 5
  vel_amount = vel_amount or 10
  local pitch = lane.lane_info.pad_pitch
  local touched = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    for _, note in ipairs(notes) do
      local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(take, note.ppq_s)
      local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(take, note.ppq_e)
      local dur    = proj_e - proj_s
      local jitter = (math.random() * 2 - 1) * (time_ms / 1000)
      local new_t  = proj_s + jitter
      local new_ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, new_t)
      local new_ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, new_t + dur)
      local v_jit = math.random(-vel_amount, vel_amount)
      local new_vel = note.vel + v_jit
      if new_vel < 1 then new_vel = 1 elseif new_vel > 127 then new_vel = 127 end
      reaper.MIDI_SetNote(take, note.idx, nil, nil, new_ppq_s, new_ppq_e, nil, nil, new_vel, true)
      touched = touched + 1
    end
    if touched > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock('EON DM: humanize lane', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  return touched
end

-- Wipe lane and fill grid steps with probability density_pct/100. Default
-- pulled from settings (randomize_density_pct).
function M.RandomizeLane(lane, density_pct)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  if not density_pct and _settings then density_pct = _settings.Get('randomize_density_pct') end
  density_pct = density_pct or 25
  if density_pct < 0 then density_pct = 0 elseif density_pct > 100 then density_pct = 100 end
  local _, grid_div_qn = reaper.GetSetProjectGrid(0, false)
  if not grid_div_qn or grid_div_qn == 0 then return 0 end
  local pitch = lane.lane_info.pad_pitch
  local vel   = _default_velocity()
  local inserted = 0
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  each_midi_take_on_track(lane.track, function(item, take)
    local notes = collect_lane_notes(take, lane.lane_info)
    if #notes > 0 then
      local idxs = {}
      for _, n in ipairs(notes) do idxs[#idxs + 1] = n.idx end
      delete_notes_desc(take, idxs)
    end
    local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local item_end   = item_start + item_len
    local start_qn = reaper.TimeMap_timeToQN(item_start)
    local end_qn   = reaper.TimeMap_timeToQN(item_end)
    local first_idx = math.ceil(start_qn / grid_div_qn - 1e-6)
    local last_idx  = math.floor(end_qn / grid_div_qn + 1e-6)
    for idx = first_idx, last_idx do
      if math.random(1, 100) <= density_pct then
        local t = reaper.TimeMap_QNToTime(idx * grid_div_qn)
        if t >= item_start - 1e-6 and t < item_end - 1e-6 then
          local len_t = reaper.TimeMap_QNToTime(idx * grid_div_qn + grid_div_qn) - t
          local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, t)
          local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, t + len_t)
          reaper.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0, pitch, vel, true)
          inserted = inserted + 1
        end
      end
    end
    if inserted > 0 then
      reaper.MIDI_Sort(take)
      finalize_take(take)
    end
  end)
  reaper.Undo_EndBlock(string.format('EON DM: randomize lane (%d%%)', density_pct), -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  return inserted
end

-- =============================================================================
-- Zoom: fit the arrange timeline to every item on every Drum Matrix lane.
-- Direct-API approach (no Main_OnCommand action-ID dependency, no item-
-- selection side effects): walk the lanes, find min start + max end across
-- all their items, then call reaper.GetSet_ArrangeView2 to set the visible
-- time range. Adds a small horizontal padding so notes don't sit flush
-- against the viewport edges.
--
-- NOTE: the Z key / Settings "Zoom to pattern" button / EON_DM_ZoomToPattern
-- action now zoom to the CURRENT pattern REGION (pattern_regions.ZoomToCurrent /
-- ZoomToSong) instead. This "fit all lane content" helper is kept as a utility
-- but is no longer wired to those entry points.
-- =============================================================================
function M.ZoomToAllItemsOnDMLanes()
  local lanes = M.GetLanes()
  if #lanes == 0 then
    status('EON DM: no drum lanes detected')
    return 0
  end

  -- Walk every item on every lane track, accumulating the time bounds.
  local min_start = math.huge
  local max_end   = -math.huge
  local item_count = 0
  for _, lane in ipairs(lanes) do
    if lane.track then
      local n = reaper.CountTrackMediaItems(lane.track)
      for i = 0, n - 1 do
        local item = reaper.GetTrackMediaItem(lane.track, i)
        -- MIDI only: a merged lane rides an audio track and carries audio items
        -- by design, which would otherwise stretch the zoom to cover them.
        -- No-op for classic and stereo lanes (MIDI is all they hold).
        local tk = item and reaper.GetActiveTake(item)
        if tk and reaper.TakeIsMIDI(tk) then
          local pos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION') or 0
          local len = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')   or 0
          if pos < min_start          then min_start = pos          end
          if (pos + len) > max_end    then max_end   = pos + len    end
          item_count = item_count + 1
        end
      end
    end
  end

  if item_count == 0 then
    status('EON DM: no items on drum lanes to zoom to')
    return 0
  end

  -- Pad each side by 5% of the span (min 0.5s) so the items don't slam the
  -- viewport edges. Clamp start ≥ 0 so we don't show pre-roll dead space
  -- the user can't navigate into.
  local span = max_end - min_start
  if span <= 0 then span = 1.0 end           -- single zero-length item edge case
  local pad  = math.max(span * 0.05, 0.5)
  local view_start = math.max(0, min_start - pad)
  local view_end   = max_end + pad

  -- isSet=true tells REAPER to APPLY (not query) the view. The two zero
  -- screen-pixel args mean "use the current arrange viewport width" —
  -- REAPER computes pixels-per-second from the requested time range and
  -- the live arrange pane width, so this works regardless of monitor size
  -- or the user's current zoom level.
  reaper.GetSet_ArrangeView2(0, true, 0, 0, view_start, view_end)
  reaper.UpdateArrange()
  return item_count
end

-- =============================================================================
-- Duplicate bar → next bar
-- Copies the notes in the bar under the playhead/cursor forward by one bar.
-- Per-lane (DuplicateBarToNext) and whole-pattern (DuplicateBarAllLanes) ops,
-- invoked from the cog popup and the Ctrl+B / Ctrl+Shift+B key binds.
-- =============================================================================

-- Resolve the source anchor: play cursor while transport runs, else the edit
-- cursor (same rule paste uses). Returns (time, playing) so callers can decide
-- whether to advance the edit cursor afterward.
local function resolve_src(src_time)
  local playing = (reaper.GetPlayState() & 1) == 1
  return src_time or (playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()), playing
end

-- Start time of the bar AFTER the bar containing `t` — i.e. where the duplicate
-- lands. Used to advance the edit cursor so repeated presses walk forward
-- instead of stacking copies into the same destination bar.
local function next_bar_start(t)
  -- 0-based measure index of t via the TimeMap2 pair (same convention
  -- pattern_regions uses). NOT TimeMap_QNToMeasures, which is 1-based and
  -- mismatches the 0-based GetMeasureInfo -- that off-by-one advanced the
  -- cursor two bars instead of one.
  local _, meas = reaper.TimeMap2_timeToBeats(0, t)
  return reaper.TimeMap2_beatsToTime(0, 0.0, meas + 1)
end

-- Find (or create/extend) a MIDI take on `track` covering [t0, t1). If an
-- existing item contains t0, extend it toward t1 when needed; otherwise create
-- a fresh item (color-matched to the source items so it blends in). Either way
-- the coverage is clamped so we never overlap a following item on the lane.
local function take_covering(track, t0, t1, color)
  local n = reaper.CountTrackMediaItems(track)
  local hit_item, hit_take, hit_s, hit_e = nil, nil, nil, nil
  local next_start = math.huge
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local s = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      local e = s + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      if t0 >= s - 1e-6 and t0 < e - 1e-6 then
        hit_item, hit_take, hit_s, hit_e = item, take, s, e
      elseif s > t0 + 1e-6 and s < next_start then
        next_start = s   -- nearest item starting to the right of t0
      end
    end
  end
  local want_end = math.min(t1, next_start)   -- don't overlap the next item
  if hit_item then
    if hit_e < want_end - 1e-6 then
      reaper.SetMediaItemInfo_Value(hit_item, 'D_LENGTH', want_end - hit_s)
    end
    return hit_item, hit_take
  end
  if want_end <= t0 + 1e-6 then want_end = t1 end   -- degenerate guard
  local item = reaper.CreateNewMIDIItemInProj(track, t0, want_end, false)
  if not item then return nil, nil end
  local take = reaper.GetActiveTake(item)
  if color and color ~= 0 then reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', color) end
  if take then reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', true) end
  return item, take
end

-- Core (NO Undo block — wrapped by the public ops). Returns notes duplicated.
local function dup_bar_core(lane, src_time)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  -- Source bar (meas) and destination bar (meas+1). Resolve bar boundaries with
  -- the 0-based TimeMap2_timeToBeats / beatsToTime pair (the convention
  -- pattern_regions relies on) -- NOT TimeMap_QNToMeasures, which is 1-based and
  -- mismatches the 0-based TimeMap_GetMeasureInfo: that off-by-one copied from
  -- the bar AFTER the cursor's into the one beyond that. beatsToTime returns
  -- bar boundary times directly, so there's no float-edge round-trip to mis-round.
  local _, meas = reaper.TimeMap2_timeToBeats(0, src_time)   -- 0-based measure idx
  local bs  = reaper.TimeMap2_beatsToTime(0, 0.0, meas)       -- src bar start
  local be  = reaper.TimeMap2_beatsToTime(0, 0.0, meas + 1)   -- src end / dst start
  local be2 = reaper.TimeMap2_beatsToTime(0, 0.0, meas + 2)   -- dst bar end
  local qn_delta = reaper.TimeMap_timeToQN(be) - reaper.TimeMap_timeToQN(bs)
  if qn_delta <= 0 then return 0 end

  -- Gather the lane's in-range notes whose start falls in [bs, be).
  local src, color = {}, nil
  each_midi_take_on_track(lane.track, function(item, take)
    for _, nrec in ipairs(collect_lane_notes(take, lane.lane_info)) do
      local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_s)
      if t_s >= bs - 1e-6 and t_s < be - 1e-6 then
        local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_e)
        src[#src + 1] = { t_s = t_s, t_e = t_e, pitch = nrec.pitch, vel = nrec.vel }
        if not color then
          local c = reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR')
          if c and c ~= 0 then color = c end
        end
      end
    end
  end)
  if #src == 0 then return 0 end

  local _, dest = take_covering(lane.track, be, be2, color)
  if not dest then return 0 end
  for _, s in ipairs(src) do
    local d_s = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(s.t_s) + qn_delta)
    local d_e = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(s.t_e) + qn_delta)
    local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(dest, d_s)
    local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(dest, d_e)
    reaper.MIDI_InsertNote(dest, false, false, ppq_s, ppq_e, 0, s.pitch, s.vel, true)
  end
  reaper.MIDI_Sort(dest)
  finalize_take(dest)
  return #src
end

-- Duplicate the source bar forward one bar on a SINGLE lane. When stopped and
-- something was duplicated, advance the edit cursor to the new bar so repeated
-- presses chain forward (when playing, the play cursor already moves on).
function M.DuplicateBarToNext(lane, src_time)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local playing
  src_time, playing = resolve_src(src_time)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local n = dup_bar_core(lane, src_time)
  if n > 0 and not playing then
    reaper.SetEditCurPos(next_bar_start(src_time), false, false)
  end
  reaper.Undo_EndBlock('EON DM: duplicate bar -> next', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if n == 0 then status('EON DM: no notes in this bar to duplicate') end
  return n
end

-- Duplicate the source bar forward one bar across EVERY drum lane, in ONE
-- Undo block (a single shared source time so all lanes use the same bar).
function M.DuplicateBarAllLanes(src_time)
  local playing
  src_time, playing = resolve_src(src_time)
  local lanes = M.GetLanes()
  if #lanes == 0 then status('EON DM: no drum lanes detected'); return 0 end
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local total = 0
  for _, lane in ipairs(lanes) do
    total = total + dup_bar_core(lane, src_time)
  end
  if total > 0 and not playing then
    reaper.SetEditCurPos(next_bar_start(src_time), false, false)
  end
  reaper.Undo_EndBlock('EON DM: duplicate bar -> next (all lanes)', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if total == 0 then status('EON DM: no notes in this bar to duplicate') end
  return total
end

-- =============================================================================
-- stamp an arbitrary source range to a destination (region-based patterns, #4)
-- =============================================================================

-- Core (NO Undo block — wrapped by the public op). Copies a lane's notes whose
-- start falls in [src_t0, src_t1) to a destination starting at dest_t0. A
-- generalization of dup_bar_core: the source/destination are explicit, and the
-- offset is a tempo-aware QN delta so the copy lands musically correct across
-- tempo/meter changes. Returns the number of notes inserted.
local function stamp_range_core(lane, src_t0, src_t1, dest_t0)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local q_s0   = reaper.TimeMap_timeToQN(src_t0)
  local q_s1   = reaper.TimeMap_timeToQN(src_t1)
  local q_d0   = reaper.TimeMap_timeToQN(dest_t0)
  local span_q = q_s1 - q_s0
  if span_q <= 0 then return 0 end
  local qn_delta = q_d0 - q_s0
  local dest_end = reaper.TimeMap_QNToTime(q_d0 + span_q)

  -- Gather the lane's in-range notes (start within [src_t0, src_t1)).
  local src, color = {}, nil
  each_midi_take_on_track(lane.track, function(item, take)
    for _, nrec in ipairs(collect_lane_notes(take, lane.lane_info)) do
      local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_s)
      if t_s >= src_t0 - 1e-6 and t_s < src_t1 - 1e-6 then
        local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_e)
        src[#src + 1] = { t_s = t_s, t_e = t_e, pitch = nrec.pitch, vel = nrec.vel }
        if not color then
          local c = reaper.GetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR')
          if c and c ~= 0 then color = c end
        end
      end
    end
  end)
  if #src == 0 then return 0 end

  local _, dest = take_covering(lane.track, dest_t0, dest_end, color)
  if not dest then return 0 end
  for _, s in ipairs(src) do
    local d_s = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(s.t_s) + qn_delta)
    local d_e = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(s.t_e) + qn_delta)
    local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(dest, d_s)
    local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(dest, d_e)
    reaper.MIDI_InsertNote(dest, false, false, ppq_s, ppq_e, 0, s.pitch, s.vel, true)
  end
  reaper.MIDI_Sort(dest)
  finalize_take(dest)
  return #src
end

-- Stamp the [src_t0, src_t1) range across EVERY drum lane to dest_t0, in ONE
-- Undo block (so a whole pattern stamp is a single undo). dest_t0 defaults to
-- the play cursor when transport is rolling, else the edit cursor. When stopped
-- and something was stamped, advance the edit cursor by the range length so
-- repeated stamps chain forward. Returns total notes inserted.
function M.StampRangeAllLanes(src_t0, src_t1, dest_t0)
  if not (src_t0 and src_t1) or src_t1 <= src_t0 then return 0 end
  local playing
  dest_t0, playing = resolve_src(dest_t0)
  local lanes = M.GetLanes()
  if #lanes == 0 then status('EON DM: no drum lanes detected'); return 0 end
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  local total = 0
  for _, lane in ipairs(lanes) do
    total = total + stamp_range_core(lane, src_t0, src_t1, dest_t0)
  end
  if total > 0 and not playing then
    local span_q = reaper.TimeMap_timeToQN(src_t1) - reaper.TimeMap_timeToQN(src_t0)
    local advance = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(dest_t0) + span_q)
    reaper.SetEditCurPos(advance, false, false)
  end
  reaper.Undo_EndBlock('EON DM: stamp pattern', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  if total == 0 then status('EON DM: pattern is empty — nothing to stamp') end
  return total
end

-- Count drum notes whose start falls in [t0, t1) across EVERY lane. Read-only
-- (no Undo, no edits) — used by the Pattern Manager's note-count column. Reuses
-- the same lane/take/note traversal as the stamp engine so the count matches
-- exactly what a stamp would copy.
function M.CountNotesInRange(t0, t1)
  if not (t0 and t1) or t1 <= t0 then return 0 end
  local count = 0
  for _, lane in ipairs(M.GetLanes()) do
    if lane.track and lane.lane_info then
      each_midi_take_on_track(lane.track, function(_, take)
        for _, nrec in ipairs(collect_lane_notes(take, lane.lane_info)) do
          local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_s)
          if t_s >= t0 - 1e-6 and t_s < t1 - 1e-6 then count = count + 1 end
        end
      end)
    end
  end
  return count
end

-- =============================================================================
-- StepSeq sync: region <-> tempo-independent pattern blob (Phase 1)
-- The canonical conversion both the bridge courier and the shared preset format
-- use. A "blob" is MULTI-LANE and tempo-independent (quarter-notes relative to
-- the region start), so it survives tempo/meter changes and kit re-layouts:
--   { len_qn = <region length in QN>,
--     lanes = { [pad_index] = { pad_pitch = <n>, notes = { {q, v, d}, ... } } } }
-- q = QN offset from the region start, d = QN duration, v = MIDI velocity.
-- Notes are keyed by pad_index (the StepSeq row mapping is kit-layout agnostic);
-- pad_pitch is carried so the reverse write knows which note to emit.
-- =============================================================================

-- Stereo-mode support: a stereo lane (lane_info.stereo == true, tag on the
-- Swing track itself) holds ALL pads' notes in one take, so the blob
-- conversion needs a pad_index <-> pitch map. Prefer the live Swing pad map
-- (per-slot identity band, via stereo_live_pitches near the top of this file);
-- fall back to the contiguous note_lo + pad - 1 layout BuildStereo writes when
-- the instance is offline.

-- { [pad_index] = pitch }. Live map = every valid pad, UNWINDOWED (2026-09-02:
-- the old `p >= lo and p <= hi` filter against the seed-time tag window is
-- what dropped remapped pads from export and wiped them on re-import). The
-- offline fallback is still laid out inside the TAG window, since without the
-- instance the tag is the only layout we know.
local function stereo_pad_pitches(lane_info)
  local live = stereo_live_pitches(lane_info)
  if live then return live end
  local map = {}
  local lo, hi = lane_info.note_lo, lane_info.note_hi
  if not (type(lo) == 'number' and type(hi) == 'number' and hi >= lo) then
    lo, hi = lane_range(lane_info)
  end
  for pad = 1, 16 do
    local p = lo + pad - 1
    if p <= hi then map[pad] = p end
  end
  return map
end

-- Public row map for the stereo cog menu: array of { pad, pitch, name },
-- sorted highest pitch first to match the grid's top-to-bottom row order.
-- Names come from the live Swing pad map; offline falls back to "Note N".
function M.StereoRows(lane_info)
  local rows = {}
  local ss = ensure_swing_state()
  local slot = nil
  if ss then
    local ok, s = pcall(ss.SlotForLane, lane_info)
    if ok then slot = s end
  end
  for pad, pitch in pairs(stereo_pad_pitches(lane_info)) do
    local name
    if ss and slot ~= nil then
      local ok, nm = pcall(ss.GetPadName, pad, slot)
      if ok and nm and nm ~= '' then name = nm end
    end
    rows[#rows + 1] = { pad = pad, pitch = pitch, name = name or ('Note ' .. pitch) }
  end
  table.sort(rows, function(a, b) return a.pitch > b.pitch end)
  return rows
end

-- Read every Drum Matrix lane's notes whose START falls in [t0, t1) into a blob.
-- Read-only (no edits, no Undo).
function M.CollectRegion(t0, t1)
  local blob = { len_qn = 0, lanes = {} }
  if not (t0 and t1) or t1 <= t0 then return blob end
  local q0 = reaper.TimeMap_timeToQN(t0)
  blob.len_qn = reaper.TimeMap_timeToQN(t1) - q0

  -- Per-note window math, identical for both lane shapes. nil = outside window.
  local function note_rec(take, n)
    local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_s)
    if ts < t0 - 1e-6 or ts >= t1 - 1e-6 then return nil end
    local te = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_e)
    local q  = reaper.TimeMap_timeToQN(ts) - q0
    local d  = reaper.TimeMap_timeToQN(te) - reaper.TimeMap_timeToQN(ts)
    if q < 0 then q = 0 end
    if d < 0 then d = 0 end
    return { q = q, v = n.vel, d = d, pitch = n.pitch }
  end

  for _, lane in ipairs(M.GetLanes()) do
    local li = lane.lane_info
    if li.stereo == true then
      -- Stereo lane: ONE take holds every pad. Split notes into blob lanes by
      -- pitch -> pad_index so the StepSeq side sees the same 16-row shape a
      -- multi-lane kit produces. Every mapped pad contributes a rec (empty
      -- rows included, matching the classic per-lane behavior); pitches with
      -- no pad mapping stay in the item but are not a StepSeq row.
      local pitch2pad = {}
      for pad, p in pairs(stereo_pad_pitches(li)) do
        pitch2pad[p] = pad
        blob.lanes[pad] = blob.lanes[pad] or { pad_pitch = p, notes = {} }
      end
      each_midi_take_on_track(lane.track, function(_, take)
        for _, n in ipairs(collect_lane_notes(take, li)) do
          local pad = pitch2pad[n.pitch]
          if pad then
            local nn = note_rec(take, n)
            if nn then
              local rec = blob.lanes[pad]
              rec.notes[#rec.notes + 1] = nn
            end
          end
        end
      end)
    elseif li.pad_index then
      local pad = li.pad_index
      local rec = blob.lanes[pad] or { pad_pitch = li.pad_pitch, notes = {} }
      each_midi_take_on_track(lane.track, function(_, take)
        for _, n in ipairs(collect_lane_notes(take, li)) do
          local nn = note_rec(take, n)
          if nn then rec.notes[#rec.notes + 1] = nn end
        end
      end)
      blob.lanes[pad] = rec
    end
  end
  -- 2B: controller events from the HOME lane (the stereo lane when there is one,
  -- otherwise the first lane) -> blob.cc = { {q, chan, cc, v}, ... }. The StepSeq's
  -- CC lanes live there on export, so that is where they are read back from.
  local home = nil
  for _, lane in ipairs(M.GetLanes()) do
    if lane.lane_info and lane.lane_info.stereo == true then home = lane; break end
    home = home or lane
  end
  if home then
    blob.cc = {}
    each_midi_take_on_track(home.track, function(_, take)
      local _, _, ccn = reaper.MIDI_CountEvts(take)
      for i = 0, (ccn or 0) - 1 do
        local ok, _, _, ppq, chanmsg, chan, msg2, msg3 = reaper.MIDI_GetCC(take, i)
        if ok and chanmsg == 0xB0 then
          local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)
          if ts >= t0 - 1e-6 and ts < t1 - 1e-6 then
            blob.cc[#blob.cc + 1] = { q = reaper.TimeMap_timeToQN(ts) - q0, chan = chan, cc = msg2, v = msg3 }
          end
        end
      end
    end)
  end
  return blob
end

-- Replace every lane's notes within [t0, t1) with the blob's notes (the StepSeq
-- "flatten"). Lanes present in the project but absent from the blob are CLEARED
-- in-window, so an Export fully defines the region. ONE Undo block; HARD
-- CONTRACT. Returns the number of notes written.
function M.WriteRegion(t0, t1, blob)
  if not (t0 and t1) or t1 <= t0 or type(blob) ~= 'table' then return 0 end
  local lanes_blob = blob.lanes or {}
  local q0 = reaper.TimeMap_timeToQN(t0)
  local written = 0

  -- Insert one blob note into `dest` at `pitch` (shared by both lane shapes).
  local function insert_blob_note(dest, nn, pitch)
    local nq = q0 + (tonumber(nn.q) or 0)
    local nd = tonumber(nn.d) or 0
    if nd <= 0 then nd = 0.01 end                 -- minimum audible length
    local s_t = reaper.TimeMap_QNToTime(nq)
    local e_t = reaper.TimeMap_QNToTime(nq + nd)
    if e_t > t1 then e_t = t1 end
    local v = tonumber(nn.v) or 100
    if v < 1 then v = 1 elseif v > 127 then v = 127 end
    local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(dest, s_t)
    local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(dest, e_t)
    reaper.MIDI_InsertNote(dest, false, false, ppq_s, ppq_e, 0, pitch, v, true)
    written = written + 1
  end

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()
  for _, lane in ipairs(M.GetLanes()) do
    local li = lane.lane_info
    -- 1) clear the [t0,t1) window on this lane (across its takes). Range-aware:
    --    a stereo lane's collect covers its whole note_lo..note_hi window, so
    --    the one take is emptied across ALL pads with no extra branch.
    each_midi_take_on_track(lane.track, function(_, take)
      local victims = {}
      for _, n in ipairs(collect_lane_notes(take, li)) do
        local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, n.ppq_s)
        if ts >= t0 - 1e-6 and ts < t1 - 1e-6 then victims[#victims + 1] = n.idx end
      end
      if #victims > 0 then delete_notes_desc(take, victims); finalize_take(take) end
    end)
    -- 2) insert the blob's notes into a take covering [t0,t1).
    if li.stereo == true then
      -- Stereo lane: EVERY blob pad writes into the one take, each at its
      -- pad's pitch (live Swing map; the blob's own pad_pitch as fallback).
      -- The window check below is against lane_range, which for a stereo lane
      -- now spans the live pad map -- so a live pad is never skipped; only a
      -- blob pad_pitch fallback outside every known window is dropped (it
      -- would be invisible to the grid and double-trigger against a
      -- coexisting lane build).
      local pmap = stereo_pad_pitches(li)
      local lo, hi = lane_range(li)
      local any = false
      for _, rec in pairs(lanes_blob) do
        if type(rec) == 'table' and type(rec.notes) == 'table' and #rec.notes > 0 then
          any = true
          break
        end
      end
      if any then
        local _, dest = take_covering(lane.track, t0, t1, nil)
        if dest then
          for pad, rec in pairs(lanes_blob) do
            if type(rec) == 'table' and type(rec.notes) == 'table' then
              local padn = tonumber(pad)
              local pitch = (padn and pmap[padn])
                or (type(rec.pad_pitch) == 'number' and rec.pad_pitch or nil)
              if pitch and pitch >= lo and pitch <= hi then
                for _, nn in ipairs(rec.notes) do
                  insert_blob_note(dest, nn, pitch)
                end
              end
            end
          end
          reaper.MIDI_Sort(dest)
          finalize_take(dest)
        end
      end
    else
      local rec = li.pad_index and lanes_blob[li.pad_index] or nil
      if rec and type(rec.notes) == 'table' and #rec.notes > 0 then
        local _, dest = take_covering(lane.track, t0, t1, nil)
        if dest then
          for _, nn in ipairs(rec.notes) do
            insert_blob_note(dest, nn, li.pad_pitch)
          end
          reaper.MIDI_Sort(dest)
          finalize_take(dest)
        end
      end
    end
  end
  -- 2B: the StepSeq's CC lanes -> controller events on the HOME lane (stereo lane if
  -- any, else the first lane). Only the controllers the StepSeq OWNS (blob.cc_lanes,
  -- listed even when empty) are cleared in the window first; anything else in the
  -- item -- pitch bend, other CCs -- is not ours and stays.
  if type(blob.cc_lanes) == 'table' and #blob.cc_lanes > 0 then
    local home = nil
    for _, lane in ipairs(M.GetLanes()) do
      if lane.lane_info and lane.lane_info.stereo == true then home = lane; break end
      home = home or lane
    end
    -- (not `home and take_covering(...)`: an `and` expression keeps only the FIRST of a
    -- function's return values, which handed us the item and no take -- audit 2026-09-03)
    local dest = nil
    if home then local _; _, dest = take_covering(home.track, t0, t1, nil) end
    if dest then
      local owned = {}
      for _, l in ipairs(blob.cc_lanes) do owned[tostring(l.cc) .. ':' .. tostring(l.chan)] = true end
      local _, _, ccn = reaper.MIDI_CountEvts(dest)
      for i = (ccn or 0) - 1, 0, -1 do   -- delete high-to-low so indices stay valid
        local ok, _, _, ppq, chanmsg, chan, msg2 = reaper.MIDI_GetCC(dest, i)
        if ok and chanmsg == 0xB0 and owned[tostring(msg2) .. ':' .. tostring(chan)] then
          local ts = reaper.MIDI_GetProjTimeFromPPQPos(dest, ppq)
          if ts >= t0 - 1e-6 and ts < t1 - 1e-6 then reaper.MIDI_DeleteCC(dest, i) end
        end
      end
      for _, ev in ipairs(blob.cc or {}) do
        local s_t = reaper.TimeMap_QNToTime(q0 + (tonumber(ev.q) or 0))
        if s_t < t1 then
          reaper.MIDI_InsertCC(dest, false, false, reaper.MIDI_GetPPQPosFromProjTime(dest, s_t), 0xB0,
                               math.floor(ev.chan or 0), math.floor(ev.cc or 0), math.floor(ev.v or 0))
          written = written + 1
        end
      end
      reaper.MIDI_Sort(dest)
      finalize_take(dest)
    end
  end
  reaper.Undo_EndBlock('EON DM: sync write region (StepSeq -> Drum Matrix)', -1)
  note_user_edit()
  reaper.PreventUIRefresh(-1)
  return written
end

-- =============================================================================
-- commit pattern to a single item (#9)
-- =============================================================================

-- Resolve the Swing destination track from an existing lane's MIDI send. Each
-- lane is built with one send to the Swing JSFX track (EON_DM_Build line 369);
-- P_DESTTRACK on send 0 hands back that track pointer directly.
local function resolve_swing_track(lanes)
  for _, lane in ipairs(lanes) do
    local ns = reaper.GetTrackNumSends(lane.track, 0)   -- 0 = sends
    for si = 0, ns - 1 do
      local d = reaper.GetTrackSendInfo_Value(lane.track, 0, si, 'P_DESTTRACK')
      if d then return d end
    end
  end
  return nil
end

-- Locate the kit-folder header for these lanes (matching swing_guid) so we can
-- name the committed track after the kit. Returns kit_name or nil.
local function resolve_kit_name(lanes)
  if not json then return nil end
  local guid = lanes[1] and lanes[1].lane_info and lanes[1].lane_info.swing_instance_guid
  if not guid then return nil end
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    local _, raw = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_KIT_FOLDER', '', false)
    if raw ~= '' then
      local ok, dec = pcall(json.decode, raw)
      if ok and type(dec) == 'table' and dec.swing_guid == guid then
        return dec.kit_name
      end
    end
  end
  return nil
end

-- Flatten every lane's notes into ONE MIDI item on a NEW track placed just below
-- the kit, routed into Swing the same way the lanes are (MIDI send, audio off).
-- Source lanes are left untouched. The whole thing is one undo step.
function M.CommitPatternToItem()
  local lanes = M.GetLanes()
  if #lanes == 0 then status('EON DM: no drum lanes detected'); return false end

  -- A stereo-grid pattern already IS one item on the Swing track — there is
  -- nothing to flatten. Commit operates on classic per-pad lanes only.
  local classic = {}
  for _, lane in ipairs(lanes) do
    if lane.lane_info.stereo ~= true then classic[#classic + 1] = lane end
  end
  if #classic == 0 then
    status('EON DM: stereo grid — the pattern already lives in one item on the Swing track')
    return false
  end
  lanes = classic

  -- Time span = union of every lane item, and the track index just below the
  -- lowest lane (so the committed track lands right under the kit).
  local t0, t1 = math.huge, -math.huge
  local last_lane_idx = -1
  for _, lane in ipairs(lanes) do
    local idx = math.floor(reaper.GetMediaTrackInfo_Value(lane.track, 'IP_TRACKNUMBER') + 0.5) - 1
    if idx > last_lane_idx then last_lane_idx = idx end
    local nit = reaper.CountTrackMediaItems(lane.track)
    for i = 0, nit - 1 do
      local item = reaper.GetTrackMediaItem(lane.track, i)
      -- MIDI only — see ZoomToAllItemsOnDMLanes. An audio item on a merged lane
      -- would widen the committed pattern span to cover audio that is not part
      -- of the pattern at all.
      local tk = item and reaper.GetActiveTake(item)
      if tk and reaper.TakeIsMIDI(tk) then
        local s = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
        local e = s + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
        if s < t0 then t0 = s end
        if e > t1 then t1 = e end
      end
    end
  end
  if t1 <= t0 then status('EON DM: lanes are empty — nothing to commit'); return false end

  local swing_track = resolve_swing_track(lanes)
  local kit_name    = resolve_kit_name(lanes)
  local insert_at   = (last_lane_idx >= 0) and (last_lane_idx + 1) or reaper.CountTracks(0)

  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  -- New destination track below the kit. FOLDERDEPTH 0 = sibling; InsertTrack
  -- leaves every other track's depth untouched, so the folder chain is intact.
  reaper.InsertTrackAtIndex(insert_at, true)
  local dest_track = reaper.GetTrack(0, insert_at)
  reaper.GetSetMediaTrackInfo_String(dest_track, 'P_NAME',
    'EON DM Commit' .. (kit_name and (' ' .. kit_name) or ''), true)
  reaper.SetMediaTrackInfo_Value(dest_track, 'B_MAINSEND', 0)
  reaper.SetMediaTrackInfo_Value(dest_track, 'I_FOLDERDEPTH', 0)
  if swing_track then
    local sidx = reaper.CreateTrackSend(dest_track, swing_track)
    if sidx >= 0 then
      reaper.SetTrackSendInfo_Value(dest_track, 0, sidx, 'I_SRCCHAN', -1)
      reaper.SetTrackSendInfo_Value(dest_track, 0, sidx, 'I_MIDIFLAGS', 0)
    end
  end

  -- One MIDI item spanning the union, then fold every lane's notes in at their
  -- pad pitch (project-time → dest PPQ so tempo/meter changes are preserved).
  local dest_item = reaper.CreateNewMIDIItemInProj(dest_track, t0, t1, false)
  local dest = dest_item and reaper.GetActiveTake(dest_item)
  if not dest then
    reaper.Undo_EndBlock('EON DM: commit pattern (cancelled — no take)', -1)
    reaper.PreventUIRefresh(-1)
    return false
  end
  reaper.GetSetMediaItemTakeInfo_String(dest, 'P_NAME', '', true)

  local inserted = 0
  for _, lane in ipairs(lanes) do
    each_midi_take_on_track(lane.track, function(_, take)
      for _, nrec in ipairs(collect_lane_notes(take, lane.lane_info)) do
        local t_s = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_s)
        local t_e = reaper.MIDI_GetProjTimeFromPPQPos(take, nrec.ppq_e)
        local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(dest, t_s)
        local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(dest, t_e)
        reaper.MIDI_InsertNote(dest, false, nrec.muted, ppq_s, ppq_e,
          nrec.chan, nrec.pitch, nrec.vel, true)
        inserted = inserted + 1
      end
    end)
  end

  reaper.MIDI_Sort(dest)
  finalize_take(dest)
  reaper.Undo_EndBlock('EON DM: commit pattern to item', -1)
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  status(string.format('EON DM: committed %d note(s) to a new item', inserted))
  return true
end

return M
