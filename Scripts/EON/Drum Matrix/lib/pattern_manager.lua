-- pattern_manager.lua -- EON Drum Matrix. Dockable "Pattern Manager" panel.
--
-- A region-manager-style window (the native Region/Marker Manager has no
-- pattern concept, so we own this): ONE sortable PATTERNS table — color swatch,
-- inline-editable Name, Bars, Start bar.beat, Note count + per-row action
-- buttons (Jump / Stamp / +Song / Delete). Click a header to sort.
--
-- The SONG chain deliberately has NO surface here: the toolbar song row
-- (pattern_bar.lua) is its single home — play/loop, chips, wheel-repeats,
-- right-click ops and the named-arrangement picker. A second chain editor
-- here was pure duplication and would have needed its own arrangement
-- awareness (removed 2026-07-03; +Song below still feeds the toolbar chain).
--
-- The window is dockable into a REAPER docker (cfillion Song-switcher pattern:
-- GetWindowDockID / SetNextWindowDockID, last dock persisted in global ExtState)
-- and its open state persists across sessions. All data lives in
-- pattern_regions.lua + pattern_song.lua — this module is pure UI.

local M = {}

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local patterns = dofile(_SCRIPT_DIR .. 'pattern_regions.lua')
local song     = dofile(_SCRIPT_DIR .. 'pattern_song.lua')

local SECTION   = 'EON_DRUM_MATRIX'
local OPEN_KEY  = 'mgr_open'
local DOCK_KEY  = 'mgr_dock'

-- =============================================================================
-- open-state persistence (global ExtState, survives restarts)
-- =============================================================================

function M.IsOpen() return reaper.GetExtState(SECTION, OPEN_KEY) == '1' end
function M.SetOpen(on) reaper.SetExtState(SECTION, OPEN_KEY, on and '1' or '0', true) end
function M.Toggle() M.SetOpen(not M.IsOpen()) end

-- =============================================================================
-- module-scoped UI state
-- =============================================================================

local name_bufs  = {}     -- idx -> in-progress inline-rename buffer
local set_dock   = nil    -- pending dock id to apply next frame (nil = none)
local counts     = {}     -- idx -> note count (throttled cache)
local counts_t   = 0

-- =============================================================================
-- small helpers
-- =============================================================================

-- Bar (1-based), beat-in-bar (1-based), and length in bars for a region. Uses
-- TimeMap2_timeToBeats so meter/tempo changes are handled; exact for the common
-- whole-bar drum pattern, sensible (fractional) otherwise.
local function describe(r)
  local bbeat, bmeas, cml = reaper.TimeMap2_timeToBeats(0, r.start)
  local ebeat, emeas      = reaper.TimeMap2_timeToBeats(0, r.end_)
  local bar  = (bmeas or 0) + 1
  local beat = math.floor(bbeat or 0) + 1
  local per  = (cml and cml > 0) and cml or 4
  local bars = ((emeas or 0) - (bmeas or 0)) + ((ebeat or 0) - (bbeat or 0)) / per
  return bar, beat, bars
end

local function fmt_bars(bars)
  if math.abs(bars - math.floor(bars + 0.5)) < 0.02 then
    return tostring(math.floor(bars + 0.5))
  end
  return string.format('%.2f', bars)
end

-- Throttled note-count refresh (scanning every take each frame would be wasteful
-- with many items; counts barely change between paints).
local function refresh_counts(list)
  local now = reaper.time_precise()
  if now - counts_t < 0.5 and next(counts) ~= nil then return end
  counts_t = now
  local fresh = {}
  for _, r in ipairs(list) do fresh[r.idx] = patterns.NoteCount(r.idx) end
  counts = fresh
end

local function stamp_at_cursor(idx) patterns.Stamp(idx, nil) end

-- =============================================================================
-- patterns table
-- =============================================================================

local function sort_rows(ctx, rows)
  local ok, col_idx, _, dir = reaper.ImGui_TableGetColumnSortSpecs(ctx, 0)
  if not ok then return end
  local asc = (dir == reaper.ImGui_SortDirection_Ascending())
  local key
  if     col_idx == 1 then key = 'name'
  elseif col_idx == 2 then key = 'bars'
  elseif col_idx == 3 then key = 'start'
  elseif col_idx == 4 then key = 'notes'
  else return end
  table.sort(rows, function(a, b)
    if a[key] == b[key] then return a.start < b.start end
    if asc then return a[key] < b[key] else return a[key] > b[key] end
  end)
end

local function render_patterns_table(ctx, list)
  local flags = reaper.ImGui_TableFlags_Sortable()
              | reaper.ImGui_TableFlags_Resizable()
              | reaper.ImGui_TableFlags_RowBg()
              | reaper.ImGui_TableFlags_Borders()
              | reaper.ImGui_TableFlags_ScrollY()
  -- The table is the panel's only section — let it fill the window.
  local avail_h = select(2, reaper.ImGui_GetContentRegionAvail(ctx))
  local table_h = math.max(80, avail_h)
  if not reaper.ImGui_BeginTable(ctx, 'pat_tbl', 6, flags, 0, table_h) then return end

  local FIX = reaper.ImGui_TableColumnFlags_WidthFixed()
  local NOSORT = reaper.ImGui_TableColumnFlags_NoSort()
  reaper.ImGui_TableSetupColumn(ctx, '##c',   FIX | NOSORT, 22)
  reaper.ImGui_TableSetupColumn(ctx, 'Name',  reaper.ImGui_TableColumnFlags_WidthStretch())
  reaper.ImGui_TableSetupColumn(ctx, 'Bars',  FIX, 44)
  reaper.ImGui_TableSetupColumn(ctx, 'Start', FIX, 64)
  reaper.ImGui_TableSetupColumn(ctx, 'Notes', FIX, 50)
  reaper.ImGui_TableSetupColumn(ctx, '##a',   FIX | NOSORT, 200)
  reaper.ImGui_TableSetupScrollFreeze(ctx, 0, 1)
  reaper.ImGui_TableHeadersRow(ctx)

  -- Build display rows with derived fields, then sort per the header specs.
  local rows = {}
  for _, r in ipairs(list) do
    local bar, beat, bars = describe(r)
    rows[#rows + 1] = {
      idx = r.idx, name = (r.name ~= '' and r.name or ('#' .. r.idx)),
      color = r.color, start = r.start, end_ = r.end_,
      bar = bar, beat = beat, bars = bars,
      notes = counts[r.idx] or 0,
    }
  end
  sort_rows(ctx, rows)

  local cur = reaper.GetCursorPosition()
  for _, row in ipairs(rows) do
    local idx = row.idx
    reaper.ImGui_TableNextRow(ctx)
    reaper.ImGui_PushID(ctx, idx)

    -- col 0: color swatch
    reaper.ImGui_TableSetColumnIndex(ctx, 0)
    local swatch = patterns.ImGuiColor(row.color, 0xFF)
    reaper.ImGui_ColorButton(ctx, '##sw', swatch,
      reaper.ImGui_ColorEditFlags_NoTooltip() | reaper.ImGui_ColorEditFlags_NoPicker(), 14, 14)

    -- col 1: inline-editable name (commit on deactivate)
    reaper.ImGui_TableSetColumnIndex(ctx, 1)
    if name_bufs[idx] == nil then name_bufs[idx] = row.name end
    reaper.ImGui_SetNextItemWidth(ctx, -1)
    local rv, nv = reaper.ImGui_InputText(ctx, '##nm', name_bufs[idx])
    if rv then name_bufs[idx] = nv end
    if reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
      patterns.Rename(idx, name_bufs[idx])
    elseif not reaper.ImGui_IsItemActive(ctx) then
      name_bufs[idx] = row.name   -- keep synced with external renames
    end

    -- col 2: bars
    reaper.ImGui_TableSetColumnIndex(ctx, 2)
    reaper.ImGui_Text(ctx, fmt_bars(row.bars))

    -- col 3: start bar.beat (highlight the pattern under the edit cursor)
    reaper.ImGui_TableSetColumnIndex(ctx, 3)
    local here = (cur >= row.start - 1e-6 and cur < row.end_ - 1e-6)
    local lbl = string.format('%d.%d', row.bar, row.beat)
    if here then reaper.ImGui_TextColored(ctx, 0x66FF99FF, lbl) else reaper.ImGui_Text(ctx, lbl) end

    -- col 4: note count
    reaper.ImGui_TableSetColumnIndex(ctx, 4)
    reaper.ImGui_Text(ctx, tostring(row.notes))

    -- col 5: actions
    reaper.ImGui_TableSetColumnIndex(ctx, 5)
    if reaper.ImGui_SmallButton(ctx, 'Jump') then patterns.JumpTo(idx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Stamp') then stamp_at_cursor(idx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, '+Song') then song.SongAppend(idx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, 'Del') then
      patterns.Delete(idx); name_bufs[idx] = nil
    end

    reaper.ImGui_PopID(ctx)
  end

  reaper.ImGui_EndTable(ctx)
end

-- =============================================================================
-- docking helpers (cfillion Song-switcher pattern)
-- =============================================================================

local function toggle_dock(ctx)
  local dock_id = reaper.ImGui_GetWindowDockID(ctx)
  if dock_id >= 0 then
    -- currently floating -> dock into the last-used (or first) REAPER docker
    local last = tonumber(reaper.GetExtState(SECTION, DOCK_KEY))
    if not last or last < 0 or last > 16 then last = 0 end
    set_dock = ~last
  else
    -- currently docked -> remember where, then float
    reaper.SetExtState(SECTION, DOCK_KEY, tostring(~dock_id), true)
    set_dock = 0
  end
end

-- =============================================================================
-- top-level render — call every frame from the overlay defer loop
-- =============================================================================

function M.Render(ctx)
  if not M.IsOpen() then return end
  refresh_counts(patterns.List())

  reaper.ImGui_SetNextWindowSize(ctx, 560, 460, reaper.ImGui_Cond_FirstUseEver())
  if set_dock then
    reaper.ImGui_SetNextWindowDockID(ctx, set_dock, reaper.ImGui_Cond_Always())
    set_dock = nil
  end

  local flags = reaper.ImGui_WindowFlags_NoCollapse()
  local visible, open = reaper.ImGui_Begin(ctx, 'EON Drum Matrix — Patterns', true, flags)
  if visible then
    -- header: new pattern + dock/undock
    if reaper.ImGui_Button(ctx, '+ New pattern') then
      local idx = patterns.New(nil)
      if idx then
        patterns.JumpTo(idx)   -- land on the new region (placed after the last)
        name_bufs[idx] = (patterns.GetByIndex(idx) or {}).name or ''
      end
    end
    reaper.ImGui_SameLine(ctx)
    local dock_lbl = reaper.ImGui_IsWindowDocked(ctx) and 'Undock' or 'Dock'
    if reaper.ImGui_SmallButton(ctx, dock_lbl .. '###dock') then toggle_dock(ctx) end

    reaper.ImGui_Separator(ctx)
    render_patterns_table(ctx, patterns.List())
  end
  reaper.ImGui_End(ctx)   -- Begin/End must always pair, even when not visible.

  if open == false then M.SetOpen(false) end
end

return M
