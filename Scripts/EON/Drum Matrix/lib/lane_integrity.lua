-- lane_integrity.lua -- EON Drum Matrix Phase 7. Detect MIDI notes on a drum
-- lane whose pitch DOESN'T match the lane's pad_pitch — usually the sign of
-- an accidental edit, paste, or import. Surfaces as a warning badge in the
-- overlay and offers a Normalize action that transposes foreign notes to
-- the lane's pitch (single Undo block).
--
-- Detection is cached per-take via MIDI_GetHash so the per-frame cost is a
-- single hash lookup unless notes actually changed.

local M = {}

-- =============================================================================
-- per-take cache: take pointer -> { hash, lo, hi, foreign_count, total_count }
-- =============================================================================
local cache = {}

local function read_hash(take)
  if not reaper.MIDI_GetHash then return nil end
  local ok, hash = reaper.MIDI_GetHash(take, false, '')
  if ok and type(hash) == 'string' and hash ~= '' then return hash end
  return nil
end

-- Resolve a lane's pitch range. Drum lanes collapse to [pad_pitch, pad_pitch];
-- piano lanes use note_lo/note_hi. Matches render_drum_matrix.resolve_pad_range
-- for the v1 (lane_info-driven) case — when Swing publishes ranges in Phase 2,
-- thread the resolved lo/hi through here too.
local function lane_range(lane_info)
  if not lane_info then return nil, nil end
  local lo, hi = lane_info.note_lo, lane_info.note_hi
  if type(lo) == 'number' and type(hi) == 'number' and hi >= lo then return lo, hi end
  local p = lane_info.pad_pitch
  return p, p
end
M.LaneRange = lane_range

-- A note is foreign when its pitch falls OUTSIDE the lane's range [lo..hi].
-- For a drum lane (lo == hi) this is exactly "pitch ~= pad_pitch" as before.
local function compute_foreign(take, lo, hi)
  local foreign, total = 0, 0
  local _, n = reaper.MIDI_CountEvts(take)
  for i = 0, n - 1 do
    local ok, _, _, _, _, _, p = reaper.MIDI_GetNote(take, i)
    if ok then
      total = total + 1
      if p < lo or p > hi then foreign = foreign + 1 end
    end
  end
  return foreign, total
end

-- Returns foreign_count, total_count for one take + range [lo..hi]. Cached by
-- hash + range (so a range change invalidates the count).
function M.GetForeignForTake(take, lo, hi)
  if not take or not lo or not hi then return 0, 0 end
  -- Take pointer might be stale (item deleted, split, glued). Validate first
  -- so we drop the cache entry rather than hitting a dead-pointer crash
  -- inside MIDI_CountEvts.
  if reaper.ValidatePtr and not reaper.ValidatePtr(take, 'MediaItem_Take*') then
    cache[take] = nil
    return 0, 0
  end
  local cur = read_hash(take)
  local entry = cache[take]
  if entry and cur and entry.hash == cur and entry.lo == lo and entry.hi == hi then
    return entry.foreign_count, entry.total_count
  end
  local f, t = compute_foreign(take, lo, hi)
  cache[take] = { hash = cur, lo = lo, hi = hi, foreign_count = f, total_count = t }
  return f, t
end

-- Sweep the cache and drop any entries whose take pointer is no longer valid.
-- Mirror of midi_cache.PurgeStale. Call once per defer tick from the main
-- script so dead entries don't leak when items are deleted externally.
function M.PurgeStale()
  if not reaper.ValidatePtr then return end
  for take, _ in pairs(cache) do
    if not reaper.ValidatePtr(take, 'MediaItem_Take*') then
      cache[take] = nil
    end
  end
end

-- Sum foreign notes across all MIDI takes on the lane's track. Cheap when
-- nothing has changed (hash lookups).
function M.CountForeignOnLane(lane)
  if not (lane and lane.track and lane.lane_info) then return 0, 0 end
  local lo, hi = lane_range(lane.lane_info)
  if not lo then return 0, 0 end
  local foreign, total = 0, 0
  local n = reaper.CountTrackMediaItems(lane.track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(lane.track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local f, t = M.GetForeignForTake(take, lo, hi)
      foreign = foreign + f
      total   = total + t
    end
  end
  return foreign, total
end

-- =============================================================================
-- Normalize foreign notes on a lane. One Undo block. Returns notes changed.
--   Drum lane (lo == hi): TRANSPOSE foreign notes to the pad pitch (unchanged).
--   Piano lane (lo < hi): DELETE out-of-range notes. Transposing a foreign note
--     into a multi-pitch range is meaningless — a note outside [lo..hi] belongs
--     to a different pad entirely, so it's removed (see spec §9).
-- =============================================================================
function M.NormalizeLane(lane)
  if not (lane and lane.track and lane.lane_info) then return 0 end
  local lo, hi = lane_range(lane.lane_info)
  if not lo then return 0 end
  local piano = lo < hi
  reaper.Undo_BeginBlock()
  local changed = 0
  local n = reaper.CountTrackMediaItems(lane.track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(lane.track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local touched = false
      if piano then
        -- Delete back-to-front so indices stay valid as we remove notes.
        local _, ncount = reaper.MIDI_CountEvts(take)
        for ni = ncount - 1, 0, -1 do
          local ok, _, _, _, _, _, pitch = reaper.MIDI_GetNote(take, ni)
          if ok and (pitch < lo or pitch > hi) then
            reaper.MIDI_DeleteNote(take, ni)
            changed = changed + 1
            touched = true
          end
        end
      else
        local _, ncount = reaper.MIDI_CountEvts(take)
        for ni = 0, ncount - 1 do
          local ok, _, _, _, _, _, pitch = reaper.MIDI_GetNote(take, ni)
          if ok and pitch ~= lo then   -- lo == hi == pad_pitch here
            reaper.MIDI_SetNote(take, ni, nil, nil, nil, nil, nil, lo, nil, true)
            changed = changed + 1
            touched = true
          end
        end
      end
      if touched then
        reaper.MIDI_Sort(take)
        reaper.UpdateItemInProject(item)
        cache[take] = nil   -- invalidate the cached count
      end
    end
  end
  reaper.Undo_EndBlock(piano and 'EON DM: normalize lane (delete foreign notes)'
                             or  'EON DM: normalize lane (transpose foreign notes)', -1)
  return changed
end

-- =============================================================================
-- Targeted transpose: move every note at `from_pitch` to `to_pitch` across all
-- MIDI takes on a track. Shared iterator (no Undo wrapping) so the caller picks
-- the Undo policy.
-- =============================================================================
local function transpose_on_track(track, from_pitch, to_pitch)
  local moved = 0
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local _, ncount = reaper.MIDI_CountEvts(take)
      local touched = false
      for ni = 0, ncount - 1 do
        local ok, _, _, _, _, _, pitch = reaper.MIDI_GetNote(take, ni)
        if ok and pitch == from_pitch then
          reaper.MIDI_SetNote(take, ni, nil, nil, nil, nil, nil, to_pitch, nil, true)
          moved = moved + 1
          touched = true
        end
      end
      if touched then
        reaper.MIDI_Sort(take)
        reaper.UpdateItemInProject(item)
        cache[take] = nil   -- invalidate cached foreign-count
      end
    end
  end
  return moved
end

-- Kit-follow transpose (P3). When a loaded kit remaps a pad's trigger-note
-- from_pitch -> to_pitch, move the lane's existing notes so the painted beat
-- keeps triggering the SAME pad. SILENT (no Undo block) — reflecting the kit
-- isn't a user edit, matching swing_sync's name/color sync discipline. Lanes
-- are one-track-per-pad, so this never merges another lane's pattern. Returns
-- notes moved (0 if nothing to do / invalid args).
function M.FollowNoteRemap(lane, from_pitch, to_pitch)
  if not (lane and lane.track) then return 0 end
  if not (from_pitch and to_pitch) or from_pitch == to_pitch then return 0 end
  if reaper.ValidatePtr and not reaper.ValidatePtr(lane.track, 'MediaTrack*') then return 0 end
  return transpose_on_track(lane.track, from_pitch, to_pitch)
end

function M.Clear()
  cache = {}
end

return M
