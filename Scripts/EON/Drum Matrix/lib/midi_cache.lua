-- midi_cache.lua — EON Drum Matrix. Per-take MIDI metadata cache keyed by
-- reaper.MIDI_GetHash(take, false). When a take's notes change REAPER's hash
-- changes; this module detects the mismatch and recomputes. Phase 3 caches
-- pitch range (min/max note pitch + note count) only; future phases may add
-- more derivations (cell occupancy, foreign-pitch sets) using the same key.
--
-- Pure helper module: no ImGui, no gfx, no globals, no MIDI mutation.

local M = {}

-- Module-scoped cache: cache[take] = { hash, min, max, count }
-- REAPER take userdata pointers are stable across calls, safe as table keys.
local cache = {}

-- Soft upper bound on cached takes. The cache only sheds entries via
-- PurgeStale / Invalidate / Clear, so a long session opening many takes could
-- grow it without bound; on overflow we flush the whole table (see below).
local MAX_CACHE = 256

local function compute_pitch_range(take)
  local _, note_count = reaper.MIDI_CountEvts(take)
  if not note_count or note_count == 0 then
    return nil, nil, 0
  end
  local min_p, max_p = 127, 0
  local found = 0
  for i = 0, note_count - 1 do
    local ok, _, _, _, _, _, pitch = reaper.MIDI_GetNote(take, i)
    if ok and pitch then
      if pitch < min_p then min_p = pitch end
      if pitch > max_p then max_p = pitch end
      found = found + 1
    end
  end
  if found == 0 then return nil, nil, 0 end
  return min_p, max_p, found
end

local function read_hash(take)
  -- MIDI_GetHash signature: reaper.MIDI_GetHash(take, notesonly[, hash]) -> retval, hash
  -- Some bindings need a placeholder string parameter; pass '' for safety.
  -- If the API is missing or returns nothing usable, return nil so the cache
  -- gracefully falls back to recomputing each call.
  if not reaper.MIDI_GetHash then return nil end
  local ok, hash = reaper.MIDI_GetHash(take, false, '')
  if ok and type(hash) == 'string' and hash ~= '' then
    return hash
  end
  return nil
end

function M.GetPitchRange(take)
  if not take then return nil, nil, 0 end
  -- Hardening: take pointer might be stale after the user unfreezes / splits
  -- / re-glues an item. Validate before any API call so we drop the entry
  -- rather than crashing inside MIDI_CountEvts on a dead pointer.
  if reaper.ValidatePtr and not reaper.ValidatePtr(take, 'MediaItem_Take*') then
    cache[take] = nil
    return nil, nil, 0
  end
  if not reaper.TakeIsMIDI or not reaper.TakeIsMIDI(take) then
    return nil, nil, 0
  end

  local cur_hash = read_hash(take)
  local entry = cache[take]
  if entry and cur_hash and entry.hash == cur_hash then
    return entry.min, entry.max, entry.count
  end

  local min_p, max_p, count = compute_pitch_range(take)
  -- Before inserting a NEW key, enforce the soft size cap. A full flush on
  -- overflow is cheaper than LRU bookkeeping; the next few frames recompute.
  if not cache[take] then
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    if n >= MAX_CACHE then cache = {} end
  end
  cache[take] = { hash = cur_hash, min = min_p, max = max_p, count = count }
  return min_p, max_p, count
end

function M.Invalidate(take)
  if take then cache[take] = nil end
end

-- Sweep the cache and drop any entries whose take pointer is no longer valid.
-- Cheap (only valid-checks the keys, doesn't recompute hashes). Call once per
-- defer tick from the main loop so stale entries don't accumulate when items
-- are deleted externally.
function M.PurgeStale()
  if not reaper.ValidatePtr then return end
  for take, _ in pairs(cache) do
    if not reaper.ValidatePtr(take, 'MediaItem_Take*') then
      cache[take] = nil
    end
  end
end

function M.Clear()
  cache = {}
end

return M
