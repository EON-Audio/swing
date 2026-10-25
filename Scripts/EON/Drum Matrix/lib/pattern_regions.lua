-- pattern_regions.lua -- EON Drum Matrix. Region-based patterns (#4, redesign).
--
-- A "pattern" is a named REAPER REGION you can SEE in the timeline ruler. This
-- replaces the old hidden A/B/C/D ExtState snapshots: nothing is stored
-- invisibly, recall is never destructive. Reusing a pattern = STAMPING an
-- independent copy of its content at the cursor (lane_tools.StampRangeAllLanes).
--
-- Which regions are "ours" is tracked in PROJECT ExtState
-- (EON_DRUM_MATRIX:patterns = JSON array of region index numbers) so we don't
-- hijack regions the user made for other purposes. The list is SELF-HEALED on
-- every read: a region the user deletes in the ruler simply drops out, and the
-- membership set is rewritten to match what actually exists.

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

-- Guarded loads (match the json/lane_tools pattern used across the project): a
-- missing or broken dependency degrades gracefully instead of taking the module
-- (and everything that dofiles it) down.
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.encode then json = mod end
end
local lane_tools
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'lane_tools.lua')
  if ok and type(mod) == 'table' then lane_tools = mod end
end
local settings
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'settings_store.lua')
  if ok and type(mod) == 'table' and mod.Get then settings = mod end
end

local SECTION  = 'EON_DRUM_MATRIX'
local KEY      = 'patterns'
local CUR_KEY  = 'current'   -- "current pattern" region idx, shared via ExtState
-- The FIXED LINK (Swing's song, the user's choice 2026-10-23: "a region keeps its pattern by a fixed
-- link", not by its place in time): JSON { "<region idx>": pattern0 }, a key of its own beside KEY, keyed
-- by the region idx the membership set and the song chain use. KEY's format is left alone: an older
-- reader skips any entry that is not a number, and its next write would wipe the membership.
local LINK_KEY = 'pattern_link'

-- Pattern color palette. Each new pattern cycles to the next swatch so patterns
-- are individually color-coded — and we apply the SAME color to the actual
-- REAPER region, so the toolbar chips and the ruler regions visually agree.
-- The 0x1000000 high bit flags "use this custom color" to REAPER.
local PALETTE_RGB = {
  {  60, 175, 205 },  -- teal
  { 235, 170,  50 },  -- amber
  { 205,  80, 180 },  -- magenta
  { 110, 190,  90 },  -- green
  { 150, 110, 220 },  -- purple
  { 230,  95,  85 },  -- coral
  {  80, 140, 230 },  -- blue
  { 200, 200,  70 },  -- lime
}
local PALETTE = {}
for i, c in ipairs(PALETTE_RGB) do
  PALETTE[i] = reaper.ColorToNative(c[1], c[2], c[3]) | 0x1000000
end
local PAT_COLOR = PALETTE[1]   -- fallback when a count is unavailable

-- Choose the swatch for the Nth pattern (0-based), cycling the palette.
local function pick_color(n)
  return PALETTE[(n % #PALETTE) + 1]
end

-- Convert a REAPER native region color to a ReaImGui 0xRRGGBBAA color the
-- toolbar chips draw with. alpha defaults to fully opaque.
function M.ImGuiColor(native, alpha)
  alpha = alpha or 0xFF
  if not native or native == 0 then native = PAT_COLOR end
  local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return (r << 24) | (g << 16) | (b << 8) | alpha
end

-- "Current pattern" (region index number). Drives the next/prev/stamp hotkey
-- commands AND the manager/bar highlight. Stored in PROJECT ExtState rather than
-- a module local because pattern_regions.lua is dofile'd by several modules
-- (bar, manager, the main script) — each would otherwise get its OWN local, so
-- a chip click in one wouldn't be visible to a hotkey handled in another.
local function get_current()
  local _, v = reaper.GetProjExtState(0, SECTION, CUR_KEY)
  return tonumber(v)   -- nil if unset / non-numeric
end
local function set_current(idx)
  reaper.SetProjExtState(0, SECTION, CUR_KEY, idx and tostring(idx) or '')
end

local function status(msg)
  if msg and reaper.Help_Set then reaper.Help_Set(msg, false) end
end

-- =============================================================================
-- membership set (project ExtState) <-> live regions
-- =============================================================================

local function read_set()
  if not json then return {} end
  local _, raw = reaper.GetProjExtState(0, SECTION, KEY)
  if not raw or raw == '' then return {} end
  local ok, arr = pcall(json.decode, raw)
  if not ok or type(arr) ~= 'table' then return {} end
  local set = {}
  for _, idx in ipairs(arr) do
    if type(idx) == 'number' then set[idx] = true end
  end
  return set
end

local function write_set(set)
  if not json then return end
  local arr = {}
  for idx in pairs(set) do arr[#arr + 1] = idx end
  table.sort(arr)
  local ok, enc = pcall(json.encode, arr)
  if ok and enc then reaper.SetProjExtState(0, SECTION, KEY, enc) end
end

-- The link as stored: { [idx] = pattern0 } (a fresh copy: callers edit it). The decode is cached by the
-- stored text, so the courier's once-a-tick read costs one GetProjExtState. A missing or unreadable
-- key reads as an empty link: every member then gets its pattern on first sight (M.LinkMap).
local link_raw, link_tbl = nil, nil
local function read_link()
  local out = {}
  if not json then return out end
  local _, raw = reaper.GetProjExtState(0, SECTION, LINK_KEY)
  raw = raw or ''
  if raw ~= link_raw then
    local t = {}
    if raw ~= '' then
      local ok, obj = pcall(json.decode, raw)
      if ok and type(obj) == 'table' then
        for k, v in pairs(obj) do
          local idx = tonumber(k)
          if idx and type(v) == 'number' and v >= 0 and v == math.floor(v) then
            t[math.floor(idx)] = math.floor(v)
          end
        end
      end
    end
    link_raw, link_tbl = raw, t
  end
  for idx, p in pairs(link_tbl) do out[idx] = p end
  return out
end

local function write_link(t)
  if not json then return end
  local obj = {}
  for idx, p in pairs(t) do obj[tostring(math.floor(idx))] = p end
  local ok, enc = pcall(json.encode, obj)
  if ok and enc then
    reaper.SetProjExtState(0, SECTION, LINK_KEY, enc)
    link_raw, link_tbl = nil, nil   -- the next read decodes what was written
  end
end

-- The lowest pattern no entry of `link` holds.
local function lowest_free(link)
  local used = {}
  for _, p in pairs(link) do used[p] = true end
  local p = 0
  while used[p] do p = p + 1 end
  return p
end

-- Drop the link entries of regions that are no longer members (the self-heal's half for the link).
local function drop_dead_links(alive)
  local link = read_link()
  local changed = false
  for idx in pairs(link) do
    if not alive[idx] then link[idx] = nil; changed = true end
  end
  if changed then write_link(link) end
end

-- Enumerate every region in the project, keyed by its index number.
local function enum_regions()
  local out = {}
  local i = 0
  while true do
    local retval, isrgn, pos, rgnend, name, idx, color = reaper.EnumProjectMarkers3(0, i)
    if retval == 0 then break end
    if isrgn then out[idx] = { idx = idx, name = name or '', start = pos, end_ = rgnend, color = color } end
    i = i + 1
  end
  return out
end

-- =============================================================================
-- public listing
-- =============================================================================

-- Ordered list of our pattern regions (by start time). Self-heals the
-- membership set against what actually exists. Returns
-- { { idx, name, start, end_, color }, ... }.
function M.List()
  local set     = read_set()
  local regions = enum_regions()
  local out, kept, changed = {}, {}, false
  for idx in pairs(set) do
    local r = regions[idx]
    if r then out[#out + 1] = r; kept[idx] = true else changed = true end
  end
  if changed then
    write_set(kept)
    -- A gone region's link goes with it: REAPER hands its idx to the next region it makes.
    drop_dead_links(kept)
  end
  table.sort(out, function(a, b) return a.start < b.start end)
  -- Drop a stale "current" if its region is gone.
  local cur = get_current()
  if cur and not kept[cur] then set_current(nil) end
  return out
end

-- The FIXED LINK, healed: { [region idx] = pattern0 } for every member, and nothing else. A member
-- with no link -- a project from before the link, a region Adopt()ed by the Song Starter or the DM's
-- Adopt Regions, one an undo brought back -- gets the lowest pattern no region holds, members taken
-- in time order; so a project from before the link keeps exactly what it played (ordinal - 1) and a
-- new pattern fills the first hole. Entries of regions that are no longer members are dropped. Writes
-- the key only when something changed. `list` = a fresh M.List() if the caller holds one.
-- Two regions may share a pattern (nothing here makes that, nothing here undoes it).
function M.LinkMap(list)
  list = list or M.List()
  local link = read_link()
  local out, alive, changed = {}, {}, false
  for _, r in ipairs(list) do alive[r.idx] = true end
  for idx, p in pairs(link) do
    if alive[idx] then out[idx] = p else changed = true end
  end
  for _, r in ipairs(list) do
    if out[r.idx] == nil then
      out[r.idx] = lowest_free(out)
      changed = true
    end
  end
  if changed then write_link(out) end
  return out
end

-- The pattern region `idx` plays by the fixed link (nil when it is not a member).
function M.PatternOf(idx)
  return M.LinkMap()[idx]
end

function M.GetByIndex(idx)
  return enum_regions()[idx]
end

-- Adopt an EXISTING region (by region index number) into the pattern
-- membership set. For EON tools that lay out their own regions (the Song
-- Starter's Intro/Verse/... sections): List() deliberately returns members
-- only — it must not hijack regions the user made for other purposes — so an
-- unadopted region has no DM chip, no bridge name/colour publish, and no
-- StepSeq sync binding. Set semantics (re-adopting is a no-op write-skip);
-- a bogus idx self-heals out on the next List() like any other stale member.
function M.Adopt(idx)
  idx = tonumber(idx)
  if not idx or idx < 0 then return false end
  local set = read_set()
  if not set[idx] then
    set[idx] = true
    write_set(set)
  end
  return true
end

function M.GetCurrent() return get_current() end
function M.SetCurrent(idx) set_current(idx) end

-- =============================================================================
-- create / rename / delete
-- =============================================================================

-- Configured default length (bars) for a new pattern. Clamped >= 1; falls back
-- to 1 when settings_store is unavailable.
local function default_bars()
  local n = 1
  if settings then n = tonumber(settings.Get('pattern_default_bars')) or 1 end
  return math.max(1, math.floor(n))
end

-- The 0-based measure index containing time `t`. Uses the TimeMap2_timeToBeats
-- pair (consistent 0-based convention) rather than TimeMap_QNToMeasures, which
-- is 1-based and mismatches the 0-based GetMeasureInfo -- that off-by-one put
-- the first pattern on the NEXT bar.
local function measure_at(t)
  local _, measures = reaper.TimeMap2_timeToBeats(0, t)
  return measures
end

-- Start time of the bar `nbars` after the bar containing `t` (0 = start of t's
-- own bar). beatsToTime with the measures arg treats tpos as beats-in-measure.
local function bar_line_after(t, nbars)
  return reaper.TimeMap2_beatsToTime(0, 0.0, measure_at(t) + nbars)
end

-- An explicit time selection, if the user made one (else nil, nil). IGNORES a selection
-- that exactly matches an existing pattern region: that's almost certainly the loop/highlight
-- left behind by SELECTING that region (StepSeq pattern select sets the loop points, and with
-- "loop linked to time selection" on, that becomes the time selection) -- NOT a deliberate
-- range for a NEW pattern. Falling through to append keeps "New" tiling left-to-right instead
-- of stacking every new pattern on top of the selected one.
local function selection_range()
  local s, e = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if e and s and e > s + 1e-6 then
    for _, r in ipairs(M.List()) do
      if r.start and r.end_ and math.abs(r.start - s) < 1e-4 and math.abs(r.end_ - e) < 1e-4 then
        return nil, nil   -- selection coincides with an existing region -> treat as "no selection"
      end
    end
    return s, e
  end
  return nil, nil
end

-- Sequential layout (McSequencer-style): drop the next pattern immediately AFTER
-- the last existing one so patterns tile left-to-right as you build a song. The
-- very first pattern starts at the cursor's bar. Length = the configured
-- pattern_default_bars, measured in musical bars (tempo / time-sig aware).
local function append_range()
  local list = M.List()
  local start
  if #list == 0 then
    start = bar_line_after(reaper.GetCursorPosition(), 0)  -- start of cursor's bar
  else
    local last = list[1]
    for _, r in ipairs(list) do if r.end_ > last.end_ then last = r end end
    start = last.end_
  end
  return start, bar_line_after(start, default_bars())
end

-- Create a pattern region over [t0, t1). With no explicit range, placement follows the
-- 'pattern_new_at_selection' setting: ON = use the time selection/loop if one exists (place
-- it where you want), else append; OFF (default) = ALWAYS append right after the last pattern
-- (sequential, McSequencer-style) and ignore the loop, which the user reserves for auditioning.
-- (A caller that wants a specific span passes t0,t1 explicitly.) Returns the new region's
-- index number, or nil on failure.
function M.New(name, t0, t1)
  if not (t0 and t1) then
    if settings and settings.Get('pattern_new_at_selection') then
      t0, t1 = selection_range()
    end
    if not (t0 and t1) then t0, t1 = append_range() end
  end
  if not (t0 and t1) or t1 <= t0 then status('EON DM: could not determine a range for the new pattern'); return nil end
  local list = M.List()
  local count = #list
  -- The fixed link: the members there are get theirs first (a project from before the link migrates
  -- as it played, before this region can shift anyone's place in time); the new one then takes the
  -- lowest free pattern, and its default name says that pattern, so "Pattern 3" plays pattern 3 even
  -- after pattern 2's region was deleted.
  local link = M.LinkMap(list)
  local pat = lowest_free(link)
  if not name or name == '' then
    name = 'Pattern ' .. tostring(pat + 1)
  end
  local idx = reaper.AddProjectMarker2(0, true, t0, t1, name, -1, pick_color(count))
  if not idx or idx < 0 then return nil end
  local set = read_set()
  set[idx] = true
  write_set(set)
  link[idx] = pat
  write_link(link)
  set_current(idx)
  return idx
end

function M.Rename(idx, name)
  local r = M.GetByIndex(idx)
  if not r then return false end
  return reaper.SetProjectMarker3(0, idx, true, r.start, r.end_, name or '', r.color)
end

-- color = native OS colour (what GR_SelectColor returns); the 0x1000000
-- "custom colour" flag is OR'd in here so callers don't have to know about it.
function M.SetColor(idx, color)
  local r = M.GetByIndex(idx)
  if not r then return false end
  return reaper.SetProjectMarker3(0, idx, true, r.start, r.end_, r.name or '',
                                  (math.floor(color) % 16777216) | 0x1000000)
end

function M.Delete(idx)
  local set = read_set()
  set[idx] = nil
  write_set(set)
  local link = read_link()
  if link[idx] ~= nil then link[idx] = nil; write_link(link) end   -- its pattern is free again
  if get_current() == idx then set_current(nil) end
  return reaper.DeleteProjectMarker(0, idx, true)
end

-- =============================================================================
-- jump / stamp
-- =============================================================================

-- Move the edit cursor to a pattern's start and frame it in the arrange so the
-- overlay (which re-reads coords each frame) scrolls to follow.
function M.JumpTo(idx)
  local r = M.GetByIndex(idx)
  if not r then return false end
  set_current(idx)
  reaper.SetEditCurPos(r.start, true, false)   -- moveview = scroll if offscreen
  local pad = (r.end_ - r.start) * 0.15
  reaper.GetSet_ArrangeView2(0, true, 0, 0, r.start - pad, r.end_ + pad)
  return true
end

-- =============================================================================
-- zoom (pure arrange-view framing -- never moves the edit cursor)
-- =============================================================================

-- Frame [t0, t1] in the arrange view, padding each side by `frac` of the span.
local function frame_range(t0, t1, frac)
  if not (t0 and t1) or t1 <= t0 then return false end
  local pad = (t1 - t0) * (frac or 0.1)
  reaper.GetSet_ArrangeView2(0, true, 0, 0, math.max(0, t0 - pad), t1 + pad)
  reaper.UpdateArrange()
  return true
end

-- The pattern to treat as "current": the explicit current, else the one under
-- the edit cursor, else the first. nil when there are no patterns.
local function current_region()
  local list = M.List()
  if #list == 0 then return nil end
  local cur = get_current()
  if cur then
    for _, r in ipairs(list) do if r.idx == cur then return r end end
  end
  local pos = reaper.GetCursorPosition()
  for _, r in ipairs(list) do
    if pos >= r.start - 1e-6 and pos < r.end_ - 1e-6 then return r end
  end
  return list[1]
end

-- Zoom the arrange view to the current pattern region (15% pad, matching JumpTo).
function M.ZoomToCurrent()
  local r = current_region()
  if not r then status('EON DM: no patterns to zoom to'); return false end
  set_current(r.idx)
  return frame_range(r.start, r.end_, 0.15)
end

-- Zoom the arrange view to one pattern region by region index (15% pad, same
-- framing as ZoomToCurrent) and make it the current pattern. Used by the
-- StepSeq song-command courier (op 11, ZOOM_PATTERN).
function M.ZoomToRegion(idx)
  local r = M.GetByIndex(idx)
  if not r then status('EON DM: pattern not found'); return false end
  set_current(idx)
  return frame_range(r.start, r.end_, 0.15)
end

-- Zoom the arrange view to the whole song: the span of all pattern regions
-- (first start -> last end), 5% pad (matching ZoomToAllItemsOnDMLanes).
function M.ZoomToSong()
  local list = M.List()
  if #list == 0 then status('EON DM: no patterns to zoom to'); return false end
  local min_s, max_e = math.huge, -math.huge
  for _, r in ipairs(list) do
    if r.start < min_s then min_s = r.start end
    if r.end_  > max_e then max_e = r.end_  end
  end
  return frame_range(min_s, max_e, 0.05)
end

-- Loop-select the WHOLE pattern set + repeat on ("loop all patterns", user
-- 2026-08-26). Same span math as ZoomToSong above -- deliberately no zoom here;
-- the callers (bridge song-op 12) pair it with op 10 when they want both.
function M.LoopAll()
  local list = M.List()
  if #list == 0 then status('EON DM: no patterns to loop'); return false end
  local min_s, max_e = math.huge, -math.huge
  for _, r in ipairs(list) do
    if r.start < min_s then min_s = r.start end
    if r.end_  > max_e then max_e = r.end_  end
  end
  if max_e <= min_s then return false end
  reaper.GetSet_LoopTimeRange2(0, true, true, min_s, max_e, false)
  if reaper.GetSetRepeat(-1) ~= 1 then reaper.GetSetRepeat(1) end
  return true
end

-- Stamp an independent copy of the pattern's content at dest_t (nil = play
-- cursor when rolling, else edit cursor — resolved inside lane_tools). Returns
-- the number of notes inserted.
function M.Stamp(idx, dest_t)
  if not lane_tools then status('EON DM: lane_tools unavailable — cannot stamp'); return 0 end
  local r = M.GetByIndex(idx)
  if not r then status('EON DM: pattern not found'); return 0 end
  set_current(idx)
  local n = lane_tools.StampRangeAllLanes(r.start, r.end_, dest_t)
  if n > 0 then status(string.format('EON DM: stamped "%s" (%d notes)', r.name ~= '' and r.name or ('#' .. idx), n)) end
  return n
end

-- Hotkey helpers (operate on the "current" pattern, or the first one).
local function current_or_first()
  local cur = get_current()
  if cur then return cur end
  local list = M.List()
  return list[1] and list[1].idx or nil
end

function M.StampCurrent(dest_t)
  local idx = current_or_first()
  if not idx then status('EON DM: no patterns yet — make one first'); return 0 end
  return M.Stamp(idx, dest_t)
end

-- Jump to the pattern before/after the current one (wraps). dir = +1 or -1.
local function step(dir)
  local list = M.List()
  if #list == 0 then status('EON DM: no patterns yet'); return end
  local pos, cur = 1, get_current()
  for i, r in ipairs(list) do if r.idx == cur then pos = i; break end end
  pos = ((pos - 1 + dir) % #list) + 1
  M.JumpTo(list[pos].idx)
end

function M.Next() step(1)  end
function M.Prev() step(-1) end

-- Note count across all lanes inside a pattern region's range (for the Pattern
-- Manager's note-count column). Returns 0 if lane_tools is unavailable.
function M.NoteCount(idx)
  if not lane_tools or not lane_tools.CountNotesInRange then return 0 end
  local r = M.GetByIndex(idx)
  if not r then return 0 end
  return lane_tools.CountNotesInRange(r.start, r.end_)
end

return M
