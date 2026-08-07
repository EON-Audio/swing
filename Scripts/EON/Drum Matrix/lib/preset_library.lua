-- preset_library.lua -- EON Drum Matrix. Loads JSON pattern presets from the
-- presets/ directory tree, lets the cog popup + Tools tab query by genre +
-- category, and applies a preset's steps to a lane (destructive).
--
-- Directory layout:
--   presets/<genre>/<category>__<descriptor>.json
-- Each JSON file:
--   { "name": "...", "genre": "trap", "category": "kick",
--     "step_division": "1/16", "steps": [127, 0, 0, 110, ...] }
--
-- step_division values supported: "1/4", "1/8", "1/16", "1/32"
-- (translated to QN durations 1.0, 0.5, 0.25, 0.125).

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
-- Match SCRIPT_DIR's native separator instead of hard-coding '/', so the path
-- isn't mixed like  C:\...\lib\../presets/  on Windows.
local SEP = SCRIPT_DIR:match('[\\/]$') or '/'
local PRESETS_ROOT = SCRIPT_DIR .. '..' .. SEP .. 'presets' .. SEP
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.decode then json = mod end
end

-- Optional safety module for console warnings on malformed presets / unknown
-- step_divisions. Failure to load is non-fatal (we just don't warn).
local _safety
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'safety.lua')
  if ok and type(mod) == 'table' then _safety = mod end
end
local function warn_once(key, msg)
  if _safety then _safety.ConsoleWarnOnce(key, msg)
  else reaper.ShowConsoleMsg('[EON DM] ' .. msg .. '\n') end
end

-- Optional tempo-on-apply. settings_store provides the opt-in flag,
-- bpm.lua resolves the pattern/genre BPM. Both load defensively; if either
-- is missing the feature simply no-ops and apply inserts notes as normal.
local _settings
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'settings_store.lua')
  if ok and type(mod) == 'table' then _settings = mod end
end
local _bpm
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'bpm.lua')
  if ok and type(mod) == 'table' then _bpm = mod end
end

-- Tracks step_division strings we've already warned about so the console
-- doesn't get spammed when many presets share an unknown division.
local _div_warned = {}

-- =============================================================================
-- in-memory cache
-- =============================================================================
local cache       = nil   -- list of preset tables (sorted by name)
local cache_built = false

local STEP_DIV_QN = {
  ['1/4']   = 1.0,
  ['1/8']   = 0.5,
  ['1/16']  = 0.25,
  ['1/32']  = 0.125,
  ['1/64']  = 0.0625,
  ['1/8T']  = 1/12,      -- 8th-note triplet (3 per quarter)
  ['1/16T'] = 1/24,      -- 16th-note triplet (6 per quarter)
  ['1/32T'] = 1/48,      -- 32nd-note triplet
}

local function step_div_to_qn(s)
  local key = s or '1/16'
  local qn  = STEP_DIV_QN[key]
  if qn then return qn end
  -- Unknown step division — warn once per offending string and fall back to
  -- 1/16. The user's pattern will play at wrong tempo if we silently accept
  -- it, so we surface it instead of pretending the division was valid.
  if not _div_warned[key] then
    _div_warned[key] = true
    warn_once('preset:bad_div:' .. key,
              'preset uses unsupported step_division "' .. tostring(key) .. '" — falling back to 1/16')
  end
  return 0.25
end

-- Read a single JSON file as a preset table. Returns nil + reason on failure.
local function read_preset_file(path)
  if not json then return nil, 'no_json_lib' end
  local file = io.open(path, 'r')
  if not file then return nil, 'open_failed' end
  local content = file:read('*all')
  file:close()
  if not content or content == '' then return nil, 'empty' end
  local ok, decoded = pcall(json.decode, content)
  if not ok or type(decoded) ~= 'table' then return nil, 'json_decode' end
  -- Format-version gate: format 1 = grid `steps`; format 2 adds a raw `notes`
  -- list (preserves human timing) plus bars/tags/group. Reject a future format
  -- we don't understand rather than parsing it blind. A missing format field is
  -- treated as legacy/OK for back-compat.
  local fmt = tonumber(decoded.format)
  if fmt and fmt > 2 then return nil, 'unsupported_format' end
  -- A preset carries EITHER a grid `steps` array OR a raw `notes` list. Require
  -- exactly one usable form; an empty/absent pattern is a skip.
  local has_steps = type(decoded.steps) == 'table' and #decoded.steps > 0
  local has_notes = type(decoded.notes) == 'table' and #decoded.notes > 0
  if not (has_steps or has_notes) then return nil, 'no_pattern' end
  decoded.step_division = decoded.step_division or '1/16'
  decoded.name          = decoded.name          or 'Unnamed'
  decoded.genre         = string.lower(decoded.genre or 'misc')
  decoded.category      = string.lower(decoded.category or 'other')
  decoded.bars          = tonumber(decoded.bars) or 1
  if decoded.bars < 1 then decoded.bars = 1 end
  if type(decoded.tags) ~= 'table' then decoded.tags = {} end
  -- decoded.group stays nil when absent (a one-off, ungrouped preset).
  return decoded
end

-- Enumerate files in a directory (one level). Uses reaper.EnumerateFiles.
local function list_files(dir)
  local out = {}
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    out[#out + 1] = f
    i = i + 1
  end
  return out
end

local function list_subdirs(dir)
  local out = {}
  local i = 0
  while true do
    local d = reaper.EnumerateSubdirectories(dir, i)
    if not d then break end
    out[#out + 1] = d
    i = i + 1
  end
  return out
end

function M.LoadAll()
  if cache_built then return cache end
  cache = {}
  local skipped = 0
  local genre_dirs = list_subdirs(PRESETS_ROOT)
  for _, genre in ipairs(genre_dirs) do
    local genre_dir = PRESETS_ROOT .. genre .. SEP
    local files = list_files(genre_dir)
    for _, fname in ipairs(files) do
      if fname:lower():sub(-5) == '.json' then
        local preset, reason = read_preset_file(genre_dir .. fname)
        if preset then
          cache[#cache + 1] = preset
        else
          -- Skipped a preset file — surface why so the user knows the library
          -- is incomplete. Keyed by full path so each bad file warns once
          -- (not once per LoadAll call).
          skipped = skipped + 1
          warn_once('preset:skipped:' .. genre_dir .. fname,
                    'preset skipped: ' .. genre_dir .. fname ..
                    ' (' .. tostring(reason) .. ')')
        end
      end
    end
  end
  table.sort(cache, function(a, b) return a.name < b.name end)
  cache_built = true
  if skipped > 0 then
    warn_once('preset:summary',
              string.format('%d preset(s) skipped — see warnings above', skipped))
  end
  return cache
end

-- Drop the in-memory cache so the next LoadAll/Get re-scans the presets/ tree.
-- Call after an import writes new files so the UI picks them up without a full
-- overlay restart.
function M.Reload()
  cache = nil
  cache_built = false
end

-- Return all presets matching (genre, category). genre or category can be nil
-- to skip that filter. Both case-insensitive.
function M.Get(genre, category)
  M.LoadAll()
  local out = {}
  local g = genre    and string.lower(genre)    or nil
  local c = category and string.lower(category) or nil
  for _, p in ipairs(cache) do
    local ok_g = (g == nil) or (p.genre    == g)
    local ok_c = (c == nil) or (p.category == c)
    if ok_g and ok_c then out[#out + 1] = p end
  end
  return out
end

-- Random preset matching (genre, category). If the exact category has no
-- presets in this genre, walks the related-category fallback chain (see
-- category.RELATED) so e.g. a 'crash' lane in trap falls back to 'ride' etc.
-- Avoids exclude_name when possible so reroll feels fresh.
function M.GetRandom(genre, category, exclude_name)
  -- Lazy-load category fallback table (avoid circular requires).
  local category_lib
  do
    local ok, lib = pcall(dofile, SCRIPT_DIR .. 'category.lua')
    if ok then category_lib = lib end
  end

  local chain = (category_lib and category_lib.GetFallbackChain(category))
                or { category }

  for _, c in ipairs(chain) do
    local all = M.Get(genre, c)
    if #all > 0 then
      if #all == 1 then return all[1] end
      if exclude_name then
        local filtered = {}
        for _, p in ipairs(all) do
          if p.name ~= exclude_name then filtered[#filtered + 1] = p end
        end
        if #filtered > 0 then all = filtered end
      end
      return all[math.random(1, #all)]
    end
  end
  return nil
end

function M.AvailableGenres()
  M.LoadAll()
  local seen, out = {}, {}
  for _, p in ipairs(cache) do
    if not seen[p.genre] then seen[p.genre] = true; out[#out + 1] = p.genre end
  end
  table.sort(out)
  return out
end

-- Unique `group` ids present for a genre. A group = the per-lane fragments that
-- were imported together from one source loop (a coherent full kit). genre nil
-- = all genres. Sorted.
function M.AvailableGroups(genre)
  M.LoadAll()
  local g = genre and string.lower(genre) or nil
  local seen, out = {}, {}
  for _, p in ipairs(cache) do
    if p.group and p.group ~= '' and (g == nil or p.genre == g) then
      if not seen[p.group] then seen[p.group] = true; out[#out + 1] = p.group end
    end
  end
  table.sort(out)
  return out
end

-- The preset in `group` for a given category, or nil. Stamps a whole kit
-- lane-by-lane (category nil returns the first member of the group).
function M.GetGroupPreset(group, category)
  if not group then return nil end
  M.LoadAll()
  local c = category and string.lower(category) or nil
  for _, p in ipairs(cache) do
    if p.group == group and (c == nil or p.category == c) then return p end
  end
  return nil
end

-- A random group id for a genre (optionally avoiding exclude_group). nil if the
-- genre has no grouped kits.
function M.GetRandomGroup(genre, exclude_group)
  local groups = M.AvailableGroups(genre)
  if #groups == 0 then return nil end
  if exclude_group and #groups > 1 then
    local filtered = {}
    for _, gid in ipairs(groups) do if gid ~= exclude_group then filtered[#filtered + 1] = gid end end
    if #filtered > 0 then groups = filtered end
  end
  return groups[math.random(1, #groups)]
end

-- =============================================================================
-- apply
-- =============================================================================

-- Pick a take to apply the preset into. Prefers the first MIDI take whose
-- range contains the edit cursor; falls back to the first MIDI take on the
-- track. If the track has no MIDI items at all, auto-create a 4-bar item at
-- the edit cursor (matches `paint_mode.GetOrCreateMidiItemAt`'s defensive
-- fallback).
local function pick_target_take(track)
  local cur = reaper.GetCursorPosition()
  if cur < 0 then cur = 0 end
  local n = reaper.CountTrackMediaItems(track)
  local first_take, cursor_take, cursor_item = nil, nil, nil
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local s = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      local l = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local in_range = (cur >= s - 1e-6 and cur < s + l + 1e-6)
      -- A SELECTED item under the cursor wins outright — deterministic when
      -- lane items overlap, instead of "whichever enumerates first".
      if in_range and reaper.IsMediaItemSelected(item) then return item, take end
      if in_range and not cursor_take then cursor_item, cursor_take = item, take end
      if not first_take then first_take = { item = item, take = take } end
    end
  end
  if cursor_take then return cursor_item, cursor_take end
  if first_take then return first_take.item, first_take.take end
  -- Empty lane: auto-create a 4-bar MIDI item at the cursor. No existing
  -- item to preserve, so this is safe.
  local end_qn  = reaper.TimeMap_timeToQN(cur) + 16
  local end_t   = reaper.TimeMap_QNToTime(end_qn)
  local new_item = reaper.CreateNewMIDIItemInProj(track, cur, end_t, false)
  if not new_item then return nil, nil end
  return new_item, reaper.GetActiveTake(new_item)
end

-- Build the per-cycle event list + cycle length (QN) for a preset, unifying the
-- grid `steps` form and the raw `notes` form so one tiling loop serves both.
-- Each event = { off, vel, dur } in QN (off = offset within the cycle). For the
-- notes form, when the apply_quantize setting is on, each offset snaps to the
-- nearest step_division cell (velocity + duration preserved either way).
local function build_events(preset, div_qn)
  local events = {}
  local function clampv(v)
    v = tonumber(v) or 0
    if v <= 0 then return nil end                      -- 0/negative = no hit
    if v < 1 then v = 1 elseif v > 127 then v = 127 end -- match legacy clamp
    return math.floor(v + 0.5)
  end

  if type(preset.notes) == 'table' and #preset.notes > 0 then
    -- Raw notes form: place each note at its true QN offset to preserve feel,
    -- optionally quantized on apply. Cycle length is the loop's exact QN span
    -- (`len_qn`, set by the importer for non-4/4 safety); falls back to bars*4
    -- (4 QN/bar, 4/4) for hand-authored presets that omit it.
    local bars = tonumber(preset.bars) or 1
    if bars < 1 then bars = 1 end
    local cycle_len_qn = tonumber(preset.len_qn) or (bars * 4)
    if cycle_len_qn <= 0 then cycle_len_qn = bars * 4 end
    local quantize = _settings and _settings.Get and _settings.Get('apply_quantize')
    for _, n in ipairs(preset.notes) do
      local vel = clampv(n.v)
      if vel then
        local off = tonumber(n.q) or 0
        if off < 0 then off = 0 end
        if quantize and div_qn > 0 then
          off = math.floor(off / div_qn + 0.5) * div_qn
        end
        if off < cycle_len_qn - 1e-9 then      -- drop anything past pattern end
          local dur = tonumber(n.d) or div_qn
          if dur <= 0 then dur = div_qn end
          events[#events + 1] = { off = off, vel = vel, dur = dur }
        end
      end
    end
    return events, cycle_len_qn
  end

  -- Grid steps form (legacy + quantized fragments).
  local steps   = preset.steps or {}
  local n_steps = #steps
  for i = 1, n_steps do
    local vel = clampv(steps[i])
    if vel then events[#events + 1] = { off = (i - 1) * div_qn, vel = vel, dur = div_qn } end
  end
  return events, n_steps * div_qn
end

-- Destructively replace the lane's notes with the preset's pattern (grid steps
-- or raw notes). Wraps in one Undo block. Returns the number of notes inserted.
function M.Apply(lane, preset)
  if not (lane and lane.track and lane.lane_info and preset
          and (preset.steps or preset.notes)) then return 0 end
  local item, take = pick_target_take(lane.track)
  if not take then
    -- Empty lane AND CreateNewMIDIItemInProj failed — surface so the user
    -- knows their click didn't disappear silently.
    if reaper.Help_Set then
      reaper.Help_Set('EON DM: could not place preset (no item & item creation failed)', false)
    end
    warn_once('preset:no_target:' .. tostring(lane.track),
              'preset apply skipped: no MIDI item on lane and CreateNewMIDIItemInProj returned nil')
    return 0
  end

  local pitch    = lane.lane_info.pad_pitch
  local div_qn   = step_div_to_qn(preset.step_division)
  local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local item_end   = item_start + item_len
  local item_start_qn = reaper.TimeMap_timeToQN(item_start)

  reaper.Undo_BeginBlock()

  -- Wipe existing notes on this pitch within the item.
  local _, ncount = reaper.MIDI_CountEvts(take)
  local victims = {}
  for i = 0, ncount - 1 do
    local ok, _, _, _, _, _, p = reaper.MIDI_GetNote(take, i)
    if ok and p == pitch then victims[#victims + 1] = i end
  end
  table.sort(victims, function(a, b) return a > b end)
  for _, idx in ipairs(victims) do reaper.MIDI_DeleteNote(take, idx) end

  -- Tile the pattern across the entire item duration. Standard drum-machine
  -- behavior — a 1-bar pattern repeats through a 4-bar item. The unified events
  -- list + cycle length cover both the grid `steps` and raw `notes` forms.
  -- Stops when the next cycle would start past the item's end.
  local events, cycle_len_qn = build_events(preset, div_qn)
  local inserted = 0
  if #events > 0 and cycle_len_qn > 0 then
    local cycle = 0
    while true do
      local cycle_start_qn = item_start_qn + cycle * cycle_len_qn
      local cycle_start_t  = reaper.TimeMap_QNToTime(cycle_start_qn)
      if cycle_start_t >= item_end - 1e-6 then break end
      for _, ev in ipairs(events) do
        local note_qn = cycle_start_qn + ev.off
        local note_t  = reaper.TimeMap_QNToTime(note_qn)
        if note_t < item_end - 1e-6 then
          local end_qn = note_qn + ev.dur
          local end_t  = reaper.TimeMap_QNToTime(end_qn)
          if end_t > item_end then end_t = item_end end
          local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, note_t)
          local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, end_t)
          reaper.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0,
                                 pitch, ev.vel, true)
          inserted = inserted + 1
        end
      end
      cycle = cycle + 1
      if cycle > 256 then break end   -- safety against infinite loop
    end
  end
  reaper.MIDI_Sort(take)
  reaper.UpdateItemInProject(item)

  -- Opt-in: match project tempo to this pattern's BPM, inside the same
  -- Undo block so one undo reverts both the notes and the tempo change.
  if _settings and _bpm and _settings.Get('apply_sets_tempo') and reaper.SetCurrentBPM then
    local bpm = _bpm.Resolve(preset)
    if bpm then reaper.SetCurrentBPM(0, bpm, false) end
  end

  reaper.Undo_EndBlock(
    string.format("EON DM: apply preset '%s'", preset.name),
    -1)
  return inserted
end

return M
