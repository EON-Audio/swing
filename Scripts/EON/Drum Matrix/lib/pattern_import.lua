-- pattern_import.lua -- EON Drum Matrix. Imports external .mid drum patterns
-- into the format:2 preset library (raw `notes`, feel preserved).
--
-- Drop loops under  <DrumMatrix>/import/<genre>/*.mid  (genre = folder name).
-- For each file:
--   * REAPER parses the SMF on a temp track (robust, no hand-rolled parser);
--   * notes are read in MUSICAL QN via MIDI_GetProjQNFromPPQPos (tempo-
--     independent, so the project's tempo map doesn't affect the result);
--   * each pitch maps to a category via gm_map (GM + Roland/GMD extensions);
--   * notes de-interleave into one per-lane format:2 preset per category, all
--     sharing a `group` id so a whole loop can be re-stamped as a coherent kit;
--   * presets are written to  presets/<genre>/<category>__<group>.json.
--
-- BPM is intentionally NOT written: bpm.lua's per-genre default supplies it at
-- apply time, so we never bake the user's current project tempo into a preset.
--
-- Run it on a scratch/empty project. The importer only writes JSON files and
-- deletes its temp track, but InsertMedia of a tempo-bearing MIDI can add tempo
-- points, so an empty project keeps things tidy (the whole run is one undo).

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local SEP  = SCRIPT_DIR:match('[\\/]$') or '/'
local ROOT = SCRIPT_DIR .. '..' .. SEP          -- Drum Matrix root
local IMPORT_ROOT  = ROOT .. 'import'  .. SEP
local PRESETS_ROOT = ROOT .. 'presets' .. SEP

local function load(name)
  local ok, mod = pcall(dofile, SCRIPT_DIR .. name)
  if ok and type(mod) == 'table' then return mod end
  return nil
end
local json   = load('json.lua')
local gm_map = load('gm_map.lua')
local _safety = load('safety.lua')

local function warn(msg)
  if _safety and _safety.ConsoleWarn then _safety.ConsoleWarn(msg)
  else reaper.ShowConsoleMsg('[EON DM import] ' .. msg .. '\n') end
end

-- ---------------------------------------------------------------------------
-- small helpers
-- ---------------------------------------------------------------------------
local function round4(x) return math.floor((tonumber(x) or 0) * 10000 + 0.5) / 10000 end

local function basename_noext(path)
  local b = path:match('[^\\/]+$') or path
  return (b:gsub('%.[Mm][Ii][Dd][Ii]?$', ''))
end

-- Filesystem-safe, stable slug for group ids + filenames.
local function slug(s)
  s = tostring(s or ''):lower()
  s = s:gsub('[^%w]+', '_'):gsub('^_+', ''):gsub('_+$', '')
  if s == '' then s = 'pattern' end
  return s
end

-- Genre normalizer: lowercase + hyphen-joined, PRESERVING hyphens so the DM
-- convention "hip-hop"/"boom-bap" survives (slug() would mangle them to
-- "hip_hop"). Spaces/underscores -> hyphen; other punctuation dropped.
local function norm_genre(s)
  s = tostring(s or ''):lower()
  s = s:gsub('[%s_]+', '-')          -- spaces/underscores -> hyphen
  s = s:gsub('[^%w%-]+', '')         -- drop anything not alnum or hyphen
  s = s:gsub('%-+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
  if s == '' then s = 'misc' end
  return s
end

local ROLE_ABBR = {
  kick='Kick', snare='Snare', clap='Clap', rim='Rim', closed_hat='CH',
  open_hat='OH', ride='Ride', crash='Crash', tom='Tom', perc='Perc', other='Other',
}
local function title_genre(g)
  -- Capitalize each alpha run, preserving hyphens: boom-bap -> Boom-Bap.
  return (tostring(g):gsub('%a+', function(w) return w:sub(1,1):upper() .. w:sub(2) end))
end
local function display_name(genre, cat, group)
  return string.format('%s %s — %s', title_genre(genre), ROLE_ABBR[cat] or cat, group)
end

local function list_subdirs(dir)
  local out, i = {}, 0
  while true do local d = reaper.EnumerateSubdirectories(dir, i); if not d then break end
    out[#out+1] = d; i = i + 1 end
  return out
end
local function list_midis(dir)
  local out, i = {}, 0
  while true do local f = reaper.EnumerateFiles(dir, i); if not f then break end
    if f:lower():match('%.midi?$') then out[#out+1] = f end
    i = i + 1
  end
  return out
end

local function write_file(path, text)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(text); f:close()
  return true
end

-- Save / restore the user's track selection across our temp-track shuffle.
local function snapshot_selection()
  local sel = {}
  for i = 0, reaper.CountSelectedTracks(0) - 1 do sel[#sel+1] = reaper.GetSelectedTrack(0, i) end
  return sel
end
local function restore_selection(sel)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    if tr then reaper.SetTrackSelected(tr, false) end
  end
  for _, tr in ipairs(sel) do
    if reaper.ValidatePtr(tr, 'MediaTrack*') then reaper.SetTrackSelected(tr, true) end
  end
end

-- ---------------------------------------------------------------------------
-- read one .mid into per-category note buckets (on a temp track)
-- ---------------------------------------------------------------------------
-- Returns buckets = { [category] = { {q,v,d}, ... } }, len_qn, n_notes
-- or nil + reason on failure. Cleans up its temp track regardless.
local function read_midi(path, override)
  if not reaper.InsertMedia then return nil, 'no_InsertMedia_api' end

  local cur = reaper.GetCursorPosition()
  local sel = snapshot_selection()
  reaper.PreventUIRefresh(1)

  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local temp = reaper.GetTrack(0, idx)
  if not temp then
    reaper.PreventUIRefresh(-1)
    return nil, 'temp_track_failed'
  end

  -- Delete every track we appended (temp + any InsertMedia spun up), restore the
  -- user's cursor + selection. Indices >= idx are all ours.
  local function cleanup()
    for i = reaper.CountTracks(0) - 1, idx, -1 do
      local tr = reaper.GetTrack(0, i)
      if tr then reaper.DeleteTrack(tr) end
    end
    restore_selection(sel)
    reaper.SetEditCurPos(cur, false, false)
    reaper.PreventUIRefresh(-1)
  end

  reaper.SetOnlyTrackSelected(temp)
  reaper.SetEditCurPos(0, false, false)
  reaper.InsertMedia(path, 0)                       -- 0 = add to current (temp) track

  -- InsertMedia may place the item on `temp` (mode 0) OR create its own track.
  -- Scan every track from idx onward for the first MIDI take.
  local item, take
  for ti = idx, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    local nitems = tr and reaper.CountTrackMediaItems(tr) or 0
    for ii = 0, nitems - 1 do
      local it = reaper.GetTrackMediaItem(tr, ii)
      local tk = it and reaper.GetActiveTake(it)
      if tk and reaper.TakeIsMIDI and reaper.TakeIsMIDI(tk) then item, take = it, tk; break end
    end
    if take then break end
  end
  if not take then cleanup(); return nil, 'not_midi' end

  local item_start    = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local item_len      = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local item_start_qn = reaper.TimeMap_timeToQN(item_start)
  local len_qn        = reaper.TimeMap_timeToQN(item_start + item_len) - item_start_qn

  local buckets, n_notes = {}, 0
  local _, ncount = reaper.MIDI_CountEvts(take)
  for i = 0, ncount - 1 do
    local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok then
      local qn_s = reaper.MIDI_GetProjQNFromPPQPos(take, ppq_s)
      local qn_e = reaper.MIDI_GetProjQNFromPPQPos(take, ppq_e)
      local off  = qn_s - item_start_qn
      local dur  = qn_e - qn_s
      if off < 0 then off = 0 end
      if dur <= 0 then dur = 0.05 end
      local cat = gm_map.GetCategory(pitch, override)
      local b = buckets[cat]; if not b then b = {}; buckets[cat] = b end
      b[#b+1] = { q = round4(off), v = math.max(1, math.min(127, math.floor(vel + 0.5))), d = round4(dur) }
      n_notes = n_notes + 1
    end
  end

  cleanup()
  if n_notes == 0 then return nil, 'no_notes' end
  return buckets, round4(len_qn), n_notes
end

-- ---------------------------------------------------------------------------
-- public: import a single file
-- ---------------------------------------------------------------------------
-- Returns { group, len_qn, bars, categories = {cat,...}, notes = n } or nil+reason.
function M.ImportFile(path, genre, opts)
  opts = opts or {}
  if not json then return nil, 'no_json_lib' end
  if not gm_map then return nil, 'no_gm_map' end

  local buckets, len_qn, n_notes = read_midi(path, opts.override)
  if not buckets then return nil, len_qn end        -- len_qn holds the reason here

  genre = norm_genre(genre)
  local group = slug(basename_noext(path))
  local bars  = math.max(1, math.floor((len_qn or 4) / 4 + 0.5))

  local genre_dir = PRESETS_ROOT .. genre .. SEP
  reaper.RecursiveCreateDirectory(genre_dir, 0)

  local written = {}
  for cat, notes in pairs(buckets) do
    table.sort(notes, function(a, b) return a.q < b.q end)
    local preset = {
      format   = 2,
      name     = display_name(genre, cat, group),
      genre    = genre,
      category = cat,
      bars     = bars,
      len_qn   = len_qn,
      group    = group,
      tags     = {},
      notes    = notes,
    }
    local fname = genre_dir .. cat .. '__' .. group .. '.json'
    if write_file(fname, json.encode(preset)) then
      written[#written + 1] = cat
    else
      warn('could not write ' .. fname)
    end
  end

  if #written == 0 then return nil, 'write_failed' end
  table.sort(written)
  return { group = group, len_qn = len_qn, bars = bars, categories = written, notes = n_notes }
end

-- ---------------------------------------------------------------------------
-- public: scan import/<genre>/*.mid and import everything
-- ---------------------------------------------------------------------------
-- Returns a summary table { files, presets, skipped, genres = {...}, lines = {...} }.
function M.Run(opts)
  opts = opts or {}
  local summary = { files = 0, presets = 0, skipped = 0, genres = {}, lines = {} }

  local genre_dirs = list_subdirs(IMPORT_ROOT)
  if #genre_dirs == 0 then
    summary.lines[#summary.lines + 1] =
      'No genre folders under ' .. IMPORT_ROOT .. ' — create import/<genre>/ and add .mid files.'
    return summary
  end

  reaper.Undo_BeginBlock()
  for _, genre in ipairs(genre_dirs) do
    local gdir  = IMPORT_ROOT .. genre .. SEP
    local files = list_midis(gdir)
    local g_presets = 0
    for _, fname in ipairs(files) do
      summary.files = summary.files + 1
      local res, reason = M.ImportFile(gdir .. fname, genre, opts)
      if res then
        summary.presets = summary.presets + #res.categories
        g_presets = g_presets + #res.categories
        summary.lines[#summary.lines + 1] = string.format(
          '  ok  %s/%s  ->  %d lanes [%s]  (%.2g QN / %d bars)',
          genre, fname, #res.categories, table.concat(res.categories, ','), res.len_qn, res.bars)
      else
        summary.skipped = summary.skipped + 1
        summary.lines[#summary.lines + 1] = string.format('  skip %s/%s  (%s)', genre, fname, tostring(reason))
      end
    end
    if g_presets > 0 then summary.genres[#summary.genres + 1] = genre end
  end
  reaper.Undo_EndBlock('EON DM: Import MIDI patterns', -1)

  return summary
end

return M
