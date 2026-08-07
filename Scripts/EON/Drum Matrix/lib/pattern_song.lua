-- pattern_song.lua -- EON Drum Matrix. Native "song mode": play pattern regions
-- one after another, in a user-defined order, seamlessly.
--
-- NO SWS DEPENDENCY for playback. The whole thing rides on REAPER's native
-- reaper.GoToRegion(proj, region_index, use_timeline_order): it QUEUES a seek
-- that fires exactly when the current region finishes, so transitions are
-- sample-accurate. We just keep the correct "next region" queued each frame.
--
-- The song is OUR data: an ordered list of { region_idx, repeats } stored in
-- PROJECT ExtState (EON_DRUM_MATRIX:song), self-healed against the live pattern
-- regions on every read (a deleted region drops out of the chain). This is the
-- piece SWS's Region Playlist gives scripts no API for, so we own it — which
-- also lets the whole song-building UI live in our toolbar.
--
-- Smooth seek: GoToRegion queues to the region boundary inherently, but for a
-- truly glitch-free transport transition we also flip REAPER's 'smoothseek'
-- config to "seek at next region" while a song plays, restoring it on stop.
-- Setting a config var needs SWS's SNM_SetIntConfigVar; if SWS is absent we
-- simply skip it (GoToRegion still queues to the boundary).

-- SINGLETON GUARD. This module holds LIVE playback state (playing / seq /
-- step_i / last_pp) in upvalues. It is dofile'd by several files (pattern_bar,
-- pattern_manager, the main script), and each dofile would otherwise produce an
-- INDEPENDENT instance — so a Play button (one instance) would flip `playing`
-- while SongTick (a different instance) still sees `playing == false` and never
-- drives the chain. We register the first instance globally and hand the SAME
-- table to every later dofile, so all callers share one playback engine.
do
  local shared = rawget(_G, '__EON_DM_pattern_song')
  if shared then return shared end
end

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.encode then json = mod end
end
local patterns
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'pattern_regions.lua')
  if ok and type(mod) == 'table' then patterns = mod end
end

local SECTION   = 'EON_DRUM_MATRIX'
local KEY       = 'song'
-- Named arrangements (Phase A of the PRINT project). The ACTIVE arrangement's
-- chain always lives in KEY ('song') so playback, the courier's SONG-band
-- publisher and every existing chain-edit function stay untouched; the store
-- below only holds the parked copies. Switching = park the live chain into its
-- slot, then load another slot into 'song'.
local KEY_ARRS   = 'song_arrs'        -- JSON: [ { name = '', chain = [{r,n},...] }, ... ]
local KEY_ARRACT = 'song_arr_active'  -- 1-based index into KEY_ARRS
-- (the old 'song_loop' ExtState flag is retired: LOOP now IS the transport
-- repeat — see GetLoop/SetLoop down in the playback-driver section)

-- 'smoothseek' value used while a song plays. 3 = seek at end of region (the
-- value the community "GoTo Region Player" uses). Tunable if transitions feel
-- off — verify in REAPER.
local SMOOTHSEEK_SONG = 3

local function status(msg)
  if msg and reaper.Help_Set then reaper.Help_Set(msg, false) end
end

-- =============================================================================
-- persistence (project ExtState)
-- =============================================================================

local function read_song()
  if not json then return {} end
  local _, raw = reaper.GetProjExtState(0, SECTION, KEY)
  if not raw or raw == '' then return {} end
  local ok, arr = pcall(json.decode, raw)
  if not ok or type(arr) ~= 'table' then return {} end
  local clean = {}
  for _, e in ipairs(arr) do
    if type(e) == 'table' and type(e.r) == 'number' then
      clean[#clean + 1] = { r = e.r, n = (type(e.n) == 'number' and e.n or 1) }
    end
  end
  return clean
end

local function write_song(arr)
  if not json then return end
  local ok, enc = pcall(json.encode, arr)
  if ok and enc then reaper.SetProjExtState(0, SECTION, KEY, enc) end
end

-- =============================================================================
-- named arrangements (store + switch; the live chain stays in KEY)
-- =============================================================================

local function read_arrs()
  if not json then return {} end
  local _, raw = reaper.GetProjExtState(0, SECTION, KEY_ARRS)
  if not raw or raw == '' then return {} end
  local ok, arr = pcall(json.decode, raw)
  if not ok or type(arr) ~= 'table' then return {} end
  local clean = {}
  for _, a in ipairs(arr) do
    if type(a) == 'table' and type(a.chain) == 'table' then
      local ch = {}
      for _, e in ipairs(a.chain) do
        if type(e) == 'table' and type(e.r) == 'number' then
          ch[#ch + 1] = { r = e.r, n = (type(e.n) == 'number' and e.n or 1) }
        end
      end
      clean[#clean + 1] = { name = (type(a.name) == 'string' and a.name or ''), chain = ch }
    end
  end
  return clean
end

local function write_arrs(arrs)
  if not json then return end
  local ok, enc = pcall(json.encode, arrs)
  if ok and enc then reaper.SetProjExtState(0, SECTION, KEY_ARRS, enc) end
end

local function read_arr_active(nmax)
  local _, raw = reaper.GetProjExtState(0, SECTION, KEY_ARRACT)
  local i = math.floor(tonumber(raw) or 1)
  if i < 1 then i = 1 end
  if nmax and i > nmax then i = nmax end
  return i
end

local function write_arr_active(i)
  reaper.SetProjExtState(0, SECTION, KEY_ARRACT, tostring(i))
end

-- Lazy migration: a project from before this feature has a 'song' chain but no
-- store — wrap it as arrangement 1. Also parks the LIVE chain into the active
-- slot so the store is current before any structural operation.
local function ensure_arrs()
  local arrs = read_arrs()
  if #arrs == 0 then arrs = { { name = '', chain = {} } } end
  local act = read_arr_active(#arrs)
  arrs[act].chain = read_song()
  return arrs, act
end

function M.ArrLetter(i)
  if i >= 1 and i <= 26 then return string.char(64 + i) end
  return tostring(i)
end

-- { { letter, name, steps, active }, ... } for the picker menu.
function M.ArrList()
  local arrs, act = ensure_arrs()
  local out = {}
  for i, a in ipairs(arrs) do
    out[#out + 1] = { letter = M.ArrLetter(i), name = a.name or '',
                      steps = #a.chain, active = (i == act) }
  end
  return out, act
end

function M.ArrActive()
  local arrs = read_arrs()
  local act = read_arr_active(math.max(1, #arrs))
  local a = arrs[act]
  return act, M.ArrLetter(act), (a and a.name or '')
end

-- Park the live chain, load slot i into 'song'. If a song is playing, restart
-- it so playback follows the newly active arrangement (instant A/B).
function M.ArrSwitch(i)
  local arrs, act = ensure_arrs()
  if i < 1 or i > #arrs then return end
  if i ~= act then
    write_arrs(arrs)
    write_arr_active(i)
    write_song(arrs[i].chain)
    M.QueueChainSwitch()   -- "play next": hand over at the current pattern's end
  end
end

-- Append a fresh empty arrangement and switch to it. Returns its index.
function M.ArrNew()
  local arrs = select(1, ensure_arrs())
  arrs[#arrs + 1] = { name = '', chain = {} }
  write_arrs(arrs)
  M.ArrSwitch(#arrs)
  return #arrs
end

-- Duplicate slot i (default: active) and switch to the copy — the original is
-- always retained (never edit-in-place someone's saved arrangement).
function M.ArrDuplicate(i)
  local arrs, act = ensure_arrs()
  i = i or act
  if i < 1 or i > #arrs then return end
  local copy = { name = arrs[i].name or '', chain = {} }
  for _, e in ipairs(arrs[i].chain) do
    copy.chain[#copy.chain + 1] = { r = e.r, n = e.n }
  end
  arrs[#arrs + 1] = copy
  write_arrs(arrs)
  M.ArrSwitch(#arrs)
  return #arrs
end

function M.ArrRename(i, name)
  local arrs = select(1, ensure_arrs())
  if i < 1 or i > #arrs then return end
  arrs[i].name = tostring(name or '')
  write_arrs(arrs)
end

-- Delete slot i. The last remaining arrangement can't be deleted (clear the
-- song instead). If the active one goes, its nearest neighbor takes over.
function M.ArrDelete(i)
  local arrs, act = ensure_arrs()
  if #arrs <= 1 or i < 1 or i > #arrs then return end
  table.remove(arrs, i)
  local nact = act
  if i < act then nact = act - 1
  elseif i == act then nact = math.min(i, #arrs) end
  write_arrs(arrs)
  write_arr_active(nact)
  if i == act then
    write_song(arrs[nact].chain)
    M.QueueChainSwitch()
  end
end

-- =============================================================================
-- public list (self-healed against live pattern regions)
-- =============================================================================

-- Returns ordered chain: { { idx, repeats, region = {idx,name,start,end_,color} }, ... }
-- Steps whose region no longer exists are dropped (and the stored chain rewritten).
function M.SongList()
  local arr = read_song()
  local byidx = {}
  if patterns then
    for _, r in ipairs(patterns.List()) do byidx[r.idx] = r end
  end
  local out, clean, changed = {}, {}, false
  for _, e in ipairs(arr) do
    local r = byidx[e.r]
    if r then
      out[#out + 1]   = { idx = e.r, repeats = e.n or 1, region = r }
      clean[#clean + 1] = { r = e.r, n = e.n or 1 }
    else
      changed = true
    end
  end
  if changed then write_song(clean) end
  return out
end

-- =============================================================================
-- chain editing
-- =============================================================================

function M.SongAppend(idx)
  if not idx then return end
  local arr = read_song()
  arr[#arr + 1] = { r = idx, n = 1 }
  write_song(arr)
end

function M.SongRemoveAt(pos)
  local arr = read_song()
  if pos >= 1 and pos <= #arr then table.remove(arr, pos); write_song(arr) end
end

-- Move the step at `pos` by `dir` (-1 left / +1 right), swapping with neighbor.
function M.SongMove(pos, dir)
  local arr = read_song()
  local j = pos + dir
  if pos >= 1 and pos <= #arr and j >= 1 and j <= #arr then
    arr[pos], arr[j] = arr[j], arr[pos]
    write_song(arr)
  end
end

-- Move the step at `from` to position `to` (drag-reorder; arbitrary distance).
-- Unlike SongMove (neighbor swap), this lifts the entry out and reinserts it,
-- shifting everything between. No-op if indices are equal or out of range.
function M.SongReorder(from, to)
  local arr = read_song()
  if from < 1 or from > #arr or to < 1 or to > #arr or from == to then return end
  local moved = table.remove(arr, from)
  table.insert(arr, to, moved)
  write_song(arr)
end

function M.SongSetRepeats(pos, n)
  local arr = read_song()
  if pos >= 1 and pos <= #arr then
    arr[pos].n = math.max(1, math.min(64, math.floor(n or 1)))
    write_song(arr)
  end
end

-- Bump repeats by delta (clamped 1..64). Convenience for +/- buttons.
function M.SongBumpRepeats(pos, delta)
  local arr = read_song()
  if pos >= 1 and pos <= #arr then
    M.SongSetRepeats(pos, (arr[pos].n or 1) + (delta or 0))
  end
end

function M.SongClear() write_song({}) end

-- GetLoop / SetLoop / ToggleLoop live below the playback-driver locals they
-- capture (playing / saved_rep). LOOP = REAPER's transport REPEAT now — one
-- state, visually in sync with the DAW's repeat button from every UI.

-- =============================================================================
-- playback driver
-- =============================================================================

local playing  = false       -- song-mode engaged?
local loop     = false        -- snapshot of GetLoop() taken at SongPlay
local seq      = {}           -- flattened steps: { {idx, start, end_, entry}, ... }
local step_i   = 1            -- index into seq of the region we believe is playing
local last_pp  = 0            -- previous play position (wrap detection)
local pending  = nil          -- "play next": a freshly built seq (arrangement
                              -- switch) that takes over at the CURRENT region's
                              -- boundary instead of restarting the transport
local saved_ss  = nil         -- saved 'smoothseek' to restore on stop
local saved_rep = nil         -- saved transport REPEAT state (forced OFF during song play)

local function save_smoothseek()
  if reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar then
    saved_ss = reaper.SNM_GetIntConfigVar('smoothseek', -1)
    reaper.SNM_SetIntConfigVar('smoothseek', SMOOTHSEEK_SONG)
  end
  -- Transport REPEAT would loop the current region highlight (we set the loop
  -- points on every pattern select) and fight the queued GoToRegion chain seek —
  -- force it OFF for the duration of the song, restore whatever it was on stop.
  saved_rep = reaper.GetSetRepeat(-1)
  if saved_rep == 1 then reaper.GetSetRepeat(0) end
end

local function restore_smoothseek()
  if saved_ss ~= nil and reaper.SNM_SetIntConfigVar then
    reaper.SNM_SetIntConfigVar('smoothseek', saved_ss)
  end
  saved_ss = nil
  if saved_rep == 1 then reaper.GetSetRepeat(1) end
  saved_rep = nil
end

-- =============================================================================
-- LOOP = REAPER's transport REPEAT (single source of truth, DAW-synced)
-- =============================================================================
-- Idle: read/write the DAW's repeat toggle directly, so the song-strip cell,
-- the DM chips and REAPER's own repeat button always agree. During song
-- playback native repeat is PARKED (it would loop the region-highlight loop
-- points and fight the queued GoToRegion chain seek), so the user's intent
-- lives in saved_rep: toggles update it live (the tick re-reads it for the
-- chain wrap) and restore_smoothseek writes it back to the DAW on stop.
function M.GetLoop()
  if playing then return saved_rep == 1 end
  return reaper.GetSetRepeat(-1) == 1
end
function M.SetLoop(on)
  if playing then saved_rep = on and 1 or 0
  else reaper.GetSetRepeat(on and 1 or 0) end
end
function M.ToggleLoop() M.SetLoop(not M.GetLoop()) end

-- Flatten the chain into one step per repeat, carrying each step's source
-- chain-entry position (1-based) so the UI can highlight the playing entry.
local function build_seq()
  local out = {}
  for entry, e in ipairs(M.SongList()) do
    local reps = math.max(1, e.repeats or 1)
    for _ = 1, reps do
      out[#out + 1] = { idx = e.idx, start = e.region.start, end_ = e.region.end_, entry = entry }
    end
  end
  return out
end

function M.IsPlaying() return playing end

-- Which chain-entry position is currently playing (for the now-playing glow),
-- or nil when not in song playback.
function M.CurrentEntryPos()
  if playing and seq[step_i] then return seq[step_i].entry end
  return nil
end

-- "Play next" for arrangement switches: while a song plays, rebuild the
-- flattened seq from the (already swapped) live chain and park it in `pending`
-- — SongTick hands over at the current region's end, no transport hiccup.
-- Switching to an EMPTY arrangement is the one case that still stops.
function M.QueueChainSwitch()
  if not playing then return end
  local ns = build_seq()
  if #ns == 0 then M.SongStop(); return end
  pending = ns
  status('EON DM: arrangement queued — takes over at the next pattern boundary')
end

function M.SongPlay()
  seq = build_seq()
  pending = nil
  if #seq == 0 then status('EON DM: song is empty — add patterns first'); return false end
  loop = M.GetLoop()
  save_smoothseek()
  local first = seq[1]
  reaper.SetEditCurPos(first.start, true, false)   -- moveview so the start is visible
  reaper.OnPlayButton()                            -- play from edit cursor
  step_i  = 1
  last_pp = first.start
  playing = true
  status(string.format('EON DM: playing song (%d step%s)%s',
    #seq, #seq == 1 and '' or 's', loop and ' \u{21BB}' or ''))
  return true
end

function M.SongStop()
  if not playing then return end
  playing = false
  pending = nil
  restore_smoothseek()
  if (reaper.GetPlayState() & 1) == 1 then reaper.OnStopButton() end
  status('EON DM: song stopped')
end

function M.SongToggle()
  if playing then M.SongStop() else M.SongPlay() end
end

-- Per-frame driver. Call every frame from the overlay defer loop. Cheap no-op
-- when not in song playback.
function M.SongTick()
  if not playing then return end
  -- Transport stopped externally (user hit stop) -> leave song mode cleanly.
  if (reaper.GetPlayState() & 1) == 0 then M.SongStop(); return end
  if #seq == 0 then M.SongStop(); return end

  -- A native repeat click during song play would re-arm the region-loop race —
  -- absorb it as "loop the song" intent and keep native repeat parked.
  if reaper.GetSetRepeat(-1) == 1 then saved_rep = 1; reaper.GetSetRepeat(0) end
  -- Live re-read: a LOOP toggle mid-playback (strip cell, DM chip, checkbox —
  -- all routes land in saved_rep while playing) applies to the RUNNING chain,
  -- not just the next SongPlay.
  loop = M.GetLoop()

  local pp  = reaper.GetPlayPosition()
  local cur = seq[step_i]

  -- Has the queued boundary seek FIRED since last frame?
  --   forward to a later region  -> pp >= cur.end_  (lands at next.start)
  --   loop/jump to earlier region -> pp <  cur.start
  --   repeat of the SAME region   -> pp wrapped (dropped well below last frame)
  local left_current  = (pp < cur.start - 1e-4) or (pp >= cur.end_ - 1e-4)
  local same_rep_wrap = (pp < last_pp - 0.05)

  if left_current or same_rep_wrap then
    if pending then
      -- Arrangement handover: the boundary seek we queued pointed at the new
      -- chain's first region — adopt the new seq from its top.
      seq, pending, step_i = pending, nil, 1
    else
      local next_i = step_i + 1
      if next_i > #seq then
        if loop then
          step_i = 1
        else
          M.SongStop(); return            -- final region finished, no loop
        end
      else
        step_i = next_i
      end
    end
    cur = seq[step_i]
  end

  -- Queue the jump to the step AFTER the current one (idempotent each frame;
  -- REAPER fires it at the current region's end). use_timeline_order = false,
  -- so the index is the region's own marker/region index number. A pending
  -- arrangement switch overrides: next stop is the NEW chain's first region.
  local after
  if pending then
    after = pending[1]
  else
    local after_i = step_i + 1
    if after_i > #seq then
      if loop then after = seq[1] end
    else
      after = seq[after_i]
    end
  end
  if after then reaper.GoToRegion(0, after.idx, false) end

  last_pp = pp
end

-- Restore any config we changed (called from the script's atexit).
function M.Cleanup()
  restore_smoothseek()
end

rawset(_G, '__EON_DM_pattern_song', M)   -- register the singleton (see top)
return M
