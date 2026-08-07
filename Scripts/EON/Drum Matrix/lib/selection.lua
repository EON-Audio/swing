-- selection.lua -- EON Drum Matrix multi-cell selection. Tracks a set of
-- selected notes across lanes and exposes bulk operations (clear, velocity
-- adjust, shift). Selection is session-only (cleared on script restart).
--
-- Identity model: each selected note is keyed by { take, ppq_s, pitch }.
-- Operations look up the note fresh inside its take by matching ppq_s+pitch
-- so deletions/inserts elsewhere in the take don't desync the selection.
-- After shift ops we rewrite the entries with new ppq positions.

-- Singleton across modules: render_drum_matrix, paint_mode, and the main script
-- each dofile() this file, and REAPER's dofile does NOT cache — without this
-- guard they'd get THREE independent selection sets, so a paint-side select
-- (rect-select, paste) would never light up in the render-side highlight.
-- Cache the built module in package.loaded so every dofile returns one instance.
local _cached = package.loaded and package.loaded['eon_dm_selection']
if _cached then return _cached end

local M = {}

local entries = {}    -- list of { take, ppq_s, pitch }
local lookup  = {}    -- set, key = "<take_ptr>:<ppq_s_int>:<pitch>"

local function k(take, ppq_s, pitch)
  return tostring(take) .. ':' .. tostring(math.floor(ppq_s + 0.5)) .. ':' .. tostring(pitch)
end

function M.Clear()
  entries = {}
  lookup  = {}
end

function M.Add(take, ppq_s, pitch)
  if not take then return end
  local key = k(take, ppq_s, pitch)
  if lookup[key] then return end
  lookup[key] = true
  entries[#entries + 1] = { take = take, ppq_s = ppq_s, pitch = pitch }
end

function M.Remove(take, ppq_s, pitch)
  local key = k(take, ppq_s, pitch)
  if not lookup[key] then return end
  lookup[key] = nil
  for i = #entries, 1, -1 do
    local e = entries[i]
    if k(e.take, e.ppq_s, e.pitch) == key then
      table.remove(entries, i)
      break
    end
  end
end

function M.Toggle(take, ppq_s, pitch)
  if M.Contains(take, ppq_s, pitch) then
    M.Remove(take, ppq_s, pitch)
  else
    M.Add(take, ppq_s, pitch)
  end
end

function M.Contains(take, ppq_s, pitch)
  return lookup[k(take, ppq_s, pitch)] == true
end

function M.Count() return #entries end
function M.GetAll() return entries end

-- Sweep entries + lookup table and drop any whose take pointer is stale
-- (item deleted externally via REAPER UI, take swapped, etc.). Cheap —
-- only ValidatePtr per entry. Call once per defer tick from the main loop
-- so dead entries don't bloat the lookup table over a session.
function M.PurgeStale()
  if not reaper.ValidatePtr then return 0 end
  local kept = {}
  local new_lookup = {}
  local dropped = 0
  for _, e in ipairs(entries) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      kept[#kept + 1] = e
      new_lookup[k(e.take, e.ppq_s, e.pitch)] = true
    else
      dropped = dropped + 1
    end
  end
  entries = kept
  lookup  = new_lookup
  return dropped
end

-- =============================================================================
-- internal: for-each-selected helper that re-resolves the note in its take.
-- Calls fn(take, note_idx) — returning false from fn means "skip this entry"
-- but still continue. Sorts + UpdateItemInProject per touched take at end.
-- =============================================================================
local function for_each_resolved(fn)
  local touched = {}
  for _, e in ipairs(entries) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, _, _, pitch = reaper.MIDI_GetNote(e.take, i)
        if ok and pitch == e.pitch and math.abs(ppq_s - e.ppq_s) < 1 then
          fn(e.take, i)
          touched[e.take] = true
          break
        end
      end
    end
  end
  for take, _ in pairs(touched) do
    reaper.MIDI_Sort(take)
    local item = reaper.GetMediaItemTake_Item(take)
    if item then reaper.UpdateItemInProject(item) end
  end
end

-- =============================================================================
-- bulk ops
-- =============================================================================

function M.ClearSelected()
  if #entries == 0 then return 0 end
  -- Collect indices per take so we can delete in reverse order.
  local per_take = {}
  for _, e in ipairs(entries) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, _, _, pitch = reaper.MIDI_GetNote(e.take, i)
        if ok and pitch == e.pitch and math.abs(ppq_s - e.ppq_s) < 1 then
          per_take[e.take] = per_take[e.take] or {}
          table.insert(per_take[e.take], i)
          break
        end
      end
    end
  end
  reaper.Undo_BeginBlock()
  local removed = 0
  for take, idxs in pairs(per_take) do
    table.sort(idxs, function(a, b) return a > b end)
    for _, idx in ipairs(idxs) do
      reaper.MIDI_DeleteNote(take, idx)
      removed = removed + 1
    end
    reaper.MIDI_Sort(take)
    local item = reaper.GetMediaItemTake_Item(take)
    if item then reaper.UpdateItemInProject(item) end
  end
  reaper.Undo_EndBlock('EON DM: clear selected cells', -1)
  M.Clear()
  return removed
end

function M.AdjustVelocity(delta)
  if #entries == 0 then return 0 end
  reaper.Undo_BeginBlock()
  local touched = 0
  for_each_resolved(function(take, idx)
    local ok, _, _, _, _, _, _, vel = reaper.MIDI_GetNote(take, idx)
    if ok then
      local new_vel = vel + delta
      if new_vel < 1 then new_vel = 1 elseif new_vel > 127 then new_vel = 127 end
      reaper.MIDI_SetNote(take, idx, nil, nil, nil, nil, nil, nil, new_vel, true)
      touched = touched + 1
    end
  end)
  reaper.Undo_EndBlock(string.format('EON DM: selection velocity %+d', delta), -1)
  return touched
end

-- Shift all selected notes by `qn_delta` quarter notes. Updates the selection
-- entries with the new ppq positions so subsequent ops still find them.
function M.ShiftBy(qn_delta)
  if #entries == 0 or qn_delta == 0 then return 0 end
  local new_entries = {}
  reaper.Undo_BeginBlock()
  local touched_takes = {}
  for _, e in ipairs(entries) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(e.take, i)
        if ok and pitch == e.pitch and math.abs(ppq_s - e.ppq_s) < 1 then
          local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(e.take, ppq_s)
          local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(e.take, ppq_e)
          local qn_s   = reaper.TimeMap_timeToQN(proj_s) + qn_delta
          local qn_e   = reaper.TimeMap_timeToQN(proj_e) + qn_delta
          local new_t_s = reaper.TimeMap_QNToTime(qn_s)
          local new_t_e = reaper.TimeMap_QNToTime(qn_e)
          local nppq_s  = reaper.MIDI_GetPPQPosFromProjTime(e.take, new_t_s)
          local nppq_e  = reaper.MIDI_GetPPQPosFromProjTime(e.take, new_t_e)
          reaper.MIDI_SetNote(e.take, i, nil, nil, nppq_s, nppq_e, nil, nil, nil, true)
          touched_takes[e.take] = true
          new_entries[#new_entries + 1] = { take = e.take, ppq_s = nppq_s, pitch = e.pitch }
          break
        end
      end
    end
  end
  for take, _ in pairs(touched_takes) do
    reaper.MIDI_Sort(take)
    local item = reaper.GetMediaItemTake_Item(take)
    if item then reaper.UpdateItemInProject(item) end
  end
  -- Re-index selection with the post-shift ppq values.
  M.Clear()
  for _, e in ipairs(new_entries) do M.Add(e.take, e.ppq_s, e.pitch) end
  reaper.Undo_EndBlock(string.format('EON DM: selection shift %s',
    qn_delta > 0 and 'right' or 'left'), -1)
  return #new_entries
end

-- Move all selected notes by qn_delta (time, quarter notes) AND d_semi (pitch).
-- Pitch clamps to 0..127. Re-keys the selection with the new ppq + pitch so
-- subsequent ops still resolve them. Used by group-move (drag) and nudge
-- (arrows). One Undo block (nests harmlessly inside a caller's block).
function M.MoveBy(qn_delta, d_semi)
  qn_delta = qn_delta or 0
  d_semi   = d_semi or 0
  if #entries == 0 or (qn_delta == 0 and d_semi == 0) then return 0 end
  -- Snapshot every selected note (data + its index) BEFORE touching the take,
  -- then delete all originals and re-insert at the delta. An in-place move
  -- (SetNote per entry) is unsafe for stacked chords: moving one note onto a
  -- pitch still held by another selected note makes the next entry re-resolve
  -- to the already-moved note (matched by pitch+ppq), so a chord note never
  -- moves and looks "cut off". Delete-then-insert removes that re-match hazard.
  local src = {}      -- { take, ppq_s, ppq_e, pitch, vel }
  local del = {}      -- take -> { note_idx, ... }
  for _, e in ipairs(entries) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(e.take, i)
        if ok and pitch == e.pitch and math.abs(ppq_s - e.ppq_s) < 1 then
          src[#src + 1] = { take = e.take, ppq_s = ppq_s, ppq_e = ppq_e, pitch = pitch, vel = vel }
          del[e.take] = del[e.take] or {}
          table.insert(del[e.take], i)
          break
        end
      end
    end
  end
  if #src == 0 then return 0 end
  reaper.Undo_BeginBlock()
  -- Delete originals, reverse index order per take so indices stay valid.
  for take, idxs in pairs(del) do
    table.sort(idxs, function(a, b) return a > b end)
    for _, idx in ipairs(idxs) do reaper.MIDI_DeleteNote(take, idx) end
  end
  -- Re-insert at the moved (time, pitch) delta.
  local touched, new_entries = {}, {}
  for _, s in ipairs(src) do
    local nppq_s, nppq_e = s.ppq_s, s.ppq_e
    if qn_delta ~= 0 then
      local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(s.take, s.ppq_s)
      local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(s.take, s.ppq_e)
      local ns = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(proj_s) + qn_delta)
      local ne = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(proj_e) + qn_delta)
      nppq_s = reaper.MIDI_GetPPQPosFromProjTime(s.take, ns)
      nppq_e = reaper.MIDI_GetPPQPosFromProjTime(s.take, ne)
    end
    local npitch = s.pitch + d_semi
    if npitch < 0 then npitch = 0 elseif npitch > 127 then npitch = 127 end
    reaper.MIDI_InsertNote(s.take, false, false, nppq_s, nppq_e, 0, npitch, s.vel, true)
    touched[s.take] = true
    new_entries[#new_entries + 1] = { take = s.take, ppq_s = nppq_s, pitch = npitch }
  end
  for take, _ in pairs(touched) do
    reaper.MIDI_Sort(take)
    local item = reaper.GetMediaItemTake_Item(take)
    if item then reaper.UpdateItemInProject(item) end
  end
  M.Clear()
  for _, e in ipairs(new_entries) do M.Add(e.take, e.ppq_s, e.pitch) end
  reaper.Undo_EndBlock('EON DM: move selection', -1)
  return #new_entries
end

-- Transpose-only convenience (pitch nudge).
function M.TransposeBy(d_semi) return M.MoveBy(0, d_semi) end

-- Duplicate every selected note by (qn_delta time, d_semi pitch): the originals
-- stay put, a copy is inserted at the delta, and the selection becomes the new
-- copies (so a follow-up drag/nudge acts on them — matches FL clone). Pitch
-- clamps 0..127. One Undo block.
function M.DuplicateBy(qn_delta, d_semi)
  qn_delta = qn_delta or 0
  d_semi   = d_semi or 0
  if #entries == 0 then return 0 end
  -- Snapshot source notes first (project time) so inserts don't perturb the scan.
  local src = {}
  for _, e in ipairs(entries) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(e.take, i)
        if ok and pitch == e.pitch and math.abs(ppq_s - e.ppq_s) < 1 then
          src[#src + 1] = { take = e.take, ppq_s = ppq_s, ppq_e = ppq_e, pitch = pitch, vel = vel }
          break
        end
      end
    end
  end
  if #src == 0 then return 0 end
  reaper.Undo_BeginBlock()
  local touched, new_entries = {}, {}
  for _, s in ipairs(src) do
    local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(s.take, s.ppq_s)
    local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(s.take, s.ppq_e)
    local ns = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(proj_s) + qn_delta)
    local ne = reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(proj_e) + qn_delta)
    local nppq_s = reaper.MIDI_GetPPQPosFromProjTime(s.take, ns)
    local nppq_e = reaper.MIDI_GetPPQPosFromProjTime(s.take, ne)
    local npitch = s.pitch + d_semi
    if npitch < 0 then npitch = 0 elseif npitch > 127 then npitch = 127 end
    reaper.MIDI_InsertNote(s.take, false, false, nppq_s, nppq_e, 0, npitch, s.vel, true)
    touched[s.take] = true
    new_entries[#new_entries + 1] = { take = s.take, ppq_s = nppq_s, pitch = npitch }
  end
  for take, _ in pairs(touched) do
    reaper.MIDI_Sort(take)
    local item = reaper.GetMediaItemTake_Item(take)
    if item then reaper.UpdateItemInProject(item) end
  end
  M.Clear()
  for _, e in ipairs(new_entries) do M.Add(e.take, e.ppq_s, e.pitch) end
  reaper.Undo_EndBlock('EON DM: duplicate selection', -1)
  return #new_entries
end

if package.loaded then package.loaded['eon_dm_selection'] = M end
return M
