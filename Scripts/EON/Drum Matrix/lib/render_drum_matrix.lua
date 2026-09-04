-- render_drum_matrix.lua -- EON Drum Matrix overlay renderer (Phase 2)
-- Paints lane background + per-note step cells + velocity-scaled fill per drum_lane track.
-- Pad colors come from swing_state (position-based palette modulated by Swing theme S/L).
-- Display tuning (lane tint, grid line alphas/widths) lives in settings_store.

local M = {}

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local settings = dofile(_SCRIPT_DIR .. 'settings_store.lua')
local selection = dofile(_SCRIPT_DIR .. 'selection.lua')
local cat_glyphs = dofile(_SCRIPT_DIR .. 'cat_glyphs_bridge.lua')  -- 46-cat vector glyphs (graceful no-op if absent)

-- Optional safety module — used to skip lanes whose track pointer went stale
-- mid-frame (case where user deletes a track via the TCP context menu while
-- the overlay is iterating). Without this guard we'd hit
-- GetMediaTrackInfo_Value on a dead pointer.
local _safety
do
  local ok, mod = pcall(dofile, _SCRIPT_DIR .. 'safety.lua')
  if ok and type(mod) == 'table' then _safety = mod end
end

-- Per-frame render budget: when a single lane has thousands of notes (rare
-- but possible after a Randomize Kit on a long item, or after pasting a
-- huge import), we cap the per-lane note loop so one runaway take can't
-- stall the entire defer tick. The hidden notes are still present in MIDI —
-- they just don't draw a cell that frame.
local MAX_NOTES_PER_LANE_PER_FRAME = 500
local _budget_warned_for_take = {}

-- ── Floating-FX cutout (paint mode) ─────────────────────────────────────────
-- Defined BEFORE any function that draws (Lua locals bind at definition time —
-- referencing these from a function defined above this point would silently
-- compile as a nil global and crash the frame).
--
-- In paint mode the overlay's OS window sits ABOVE floating FX windows, so the
-- lanes would paint right over Swing. Instead of fighting the window z-order
-- (which ReaImGui re-asserts on every paint click), the renderer punches holes:
-- `_excl` holds the screen rects (ImGui coords) of every visible floating FX
-- window, and each draw below skips/clips against them so the FX GUIs show
-- through the transparent overlay. nil = zero-cost fast path (paint mode off).
-- Stereo-lane pitch-range resolver, injected by the host (eon_drum_matrix
-- passes lane_tools.LaneRange). A stereo lane's tag note_lo/note_hi were frozen
-- when the bridge first saw the Swing; lane_tools resolves the LIVE pad map and
-- unions it with the tag (2026-09-02), so rows, the key guide and every
-- paint_mode consumer downstream of lane_targets follow the pads as they are
-- now. nil = tag only (the pre-injection behaviour).
local _range_resolver = nil
function M.SetRangeResolver(fn) _range_resolver = fn end

local _excl = nil
function M.SetExclusionRects(rects)
  _excl = (rects and #rects > 0) and rects or nil
end

-- True when point (x,y) falls inside any exclusion rect. Used to gate text
-- (labels, bar numbers) and the hover tooltip, which can't be sub-rect split.
local function pt_hidden(x, y)
  if not _excl then return false end
  for _, ex in ipairs(_excl) do
    if x >= ex.x1 and x <= ex.x2 and y >= ex.y1 and y <= ex.y2 then return true end
  end
  return false
end
M.PtHidden = pt_hidden

-- True when the rect intersects any exclusion rect. Exposed for the main
-- script's lane cog / M / S click targets (a half-hidden click target is worse
-- than a hidden one, so those hide on ANY intersection).
local function rect_touched(x1, y1, x2, y2)
  if not _excl then return false end
  for _, ex in ipairs(_excl) do
    if x1 < ex.x2 and x2 > ex.x1 and y1 < ex.y2 and y2 > ex.y1 then return true end
  end
  return false
end
M.RectHidden = rect_touched

-- AddRectFilled with the exclusion rects subtracted: splits the rect into its
-- visible pieces (classic rect subtraction — top/bottom bands then left/right)
-- and fills each. Fast paths: no exclusions → one plain AddRectFilled; a piece
-- list that empties out → nothing drawn.
local function fill_ex(dl, x1, y1, x2, y2, col)
  if not _excl then
    reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, col)
    return
  end
  local pieces = { { x1, y1, x2, y2 } }
  for _, ex in ipairs(_excl) do
    local nxt = {}
    for _, p in ipairs(pieces) do
      if p[3] <= ex.x1 or p[1] >= ex.x2 or p[4] <= ex.y1 or p[2] >= ex.y2 then
        nxt[#nxt + 1] = p                                   -- no overlap: keep
      else
        if p[2] < ex.y1 then nxt[#nxt + 1] = { p[1], p[2], p[3], ex.y1 } end
        if p[4] > ex.y2 then nxt[#nxt + 1] = { p[1], ex.y2, p[3], p[4] } end
        local ty1 = math.max(p[2], ex.y1)
        local ty2 = math.min(p[4], ex.y2)
        if p[1] < ex.x1 then nxt[#nxt + 1] = { p[1], ty1, ex.x1, ty2 } end
        if p[3] > ex.x2 then nxt[#nxt + 1] = { ex.x2, ty1, p[3], ty2 } end
      end
    end
    pieces = nxt
    if #pieces == 0 then return end
  end
  for _, p in ipairs(pieces) do
    reaper.ImGui_DrawList_AddRectFilled(dl, p[1], p[2], p[3], p[4], col)
  end
end

-- Outline that respects the cutouts: plain AddRect when clear of every
-- exclusion (the common case), else four thin fill_ex strips so no outline
-- segment crosses a hole.
local function frame_ex(dl, x1, y1, x2, y2, col, thick)
  thick = thick or 1
  if not rect_touched(x1, y1, x2, y2) then
    reaper.ImGui_DrawList_AddRect(dl, x1, y1, x2, y2, col, 0, 0, thick)
    return
  end
  fill_ex(dl, x1, y1, x2, y1 + thick, col)
  fill_ex(dl, x1, y2 - thick, x2, y2, col)
  fill_ex(dl, x1, y1, x1 + thick, y2, col)
  fill_ex(dl, x2 - thick, y1, x2, y2, col)
end

-- Hover tooltip (#14). When the cursor is over a painted cell we record its
-- musical position + velocity; the main loop calls M.EmitPendingTooltip once
-- after the lane loop to render it at the mouse. Only one cell can contain the
-- cursor, so last-writer-wins across lanes is correct.
--
-- _drag_query is injected by the main script (M.SetDragQuery) and returns true
-- while any paint-mode drag is in flight. We gate the hit-test on it so a drag
-- never spawns a cursor-following tooltip (noise) AND we skip the per-cell
-- FormatBarBeat cost mid-drag. Dependency injection avoids a mutual-dofile
-- cycle between this module and paint_mode.lua.
local _drag_query     = nil
local _tooltip_pending = nil

function M.SetDragQuery(fn) _drag_query = fn end

local function queue_tooltip(coords, n_start, vel)
  _tooltip_pending = { bb = coords.FormatBarBeat(n_start), vel = vel or 0 }
end

-- Called once per frame by the main loop AFTER the lane loop. Renders the
-- queued tooltip (if any) and clears it, so a stale tooltip never persists
-- into a frame where the cursor sits over no cell.
function M.EmitPendingTooltip(ctx)
  local tt = _tooltip_pending
  _tooltip_pending = nil
  if not tt or not ctx then return end
  reaper.ImGui_BeginTooltip(ctx)
  reaper.ImGui_Text(ctx, tt.bb)
  reaper.ImGui_Text(ctx, string.format('Vel %d', tt.vel))
  reaper.ImGui_EndTooltip(ctx)
end

-- Bar markers (#13, reduced). Float dim bar numbers at the very top of the
-- grid, aligned to bar (tier-1) grid lines. Deliberately NOT a ruler band:
-- no background fill, no border, no layout shift — just text painted over the
-- top of the arrange/overlay region. Called once per frame from the main loop
-- AFTER coords.BeginFrame(), BEFORE the lane loop, so lanes draw on top.
function M.DrawBarNumbers(ctx, dl, coords, x_left, y_top, x_right)
  if not ctx or not dl or not coords then return end
  if settings.Get('bar_numbers_enabled') == false then return end
  local lines = coords.GetGridLines()
  if not lines or #lines == 0 then return end
  local col = reaper.ImGui_ColorConvertDouble4ToU32(1.0, 0.82, 0.5, 0.72)
  local y = y_top + 1
  local last_label_rx = -math.huge
  for _, gl in ipairs(lines) do
    if gl.tier == 1 then
      local x = math.floor(gl.x_raw + 0.5)
      if x >= x_left and x <= x_right then
        -- TimeMap_QNToMeasures returns a 1-based measure number already
        -- (qn 0 -> measure 1), matching REAPER's native ruler. No +1.
        local meas = math.floor(reaper.TimeMap_QNToMeasures(0, gl.qn) + 0.5)
        local label = string.format('%d', meas)
        -- Skip-overlap: only draw if clear of the previous label. Also skip
        -- labels inside a floating-FX cutout hole (paint mode).
        if x - last_label_rx >= 6 and not pt_hidden(x + 2, y) then
          local tw = reaper.ImGui_CalcTextSize(ctx, label)
          reaper.ImGui_DrawList_AddText(dl, x + 2, y, col, label)
          last_label_rx = x + 2 + tw
        end
      end
    end
  end
end

local function rgba_u32(r, g, b, alpha_0_255)
  alpha_0_255 = alpha_0_255 or 255
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, alpha_0_255 / 255)
end

local function darker(r, g, b, factor)
  factor = factor or 0.55
  return r * factor, g * factor, b * factor
end

-- Lane tint alpha lives in settings_store (Display tab). CycleLaneTint script
-- still works — it writes to the same ExtState key the store reads from.
local function lane_tint_alpha()
  local n = settings.Get('lane_tint_alpha') or 0
  if n < 0 then n = 0 elseif n > 255 then n = 255 end
  return n
end

-- Draw vertical grid lines inside a lane band, CLIPPED to the X ranges where
-- the lane actually has MIDI items. Grid lines only exist where the matrix
-- exists — they don't extend across empty arrange space. Drawn BEFORE step
-- cells so cells render on top.
--
--   bar lines      = full alpha (configurable), `grid_bar_thickness` px wide
--   beat lines     = configurable alpha, 1 px
--   sub-beat lines = configurable alpha, 1 px
--
-- Lines drawn as filled rects (NOT AddLine) at integer pixels so they render
-- without anti-aliasing. y1/y2 are passed in already pixel-snapped.
local function line_rect_x(x_raw, thickness)
  local x_int = math.floor(x_raw + 0.5)
  local half_l = math.floor(thickness / 2)
  local half_r = thickness - half_l
  return x_int - half_l, x_int + half_r
end

local function draw_lane_grid(dl, coords, lane_items, y1, y2, lane_info)
  local lines = coords.GetGridLines()
  if not lines or #lines == 0 then return end

  -- Per-lane swing (#8): off-beat (odd-index) sub-beat lines shift later. Only
  -- recompute pixels for lines that actually move (SwingTransformQN returns the
  -- input unchanged for on-beats / non-swingable grids), keeping the hot path
  -- off bar/beat/even lines.
  local swing   = (lane_info and tonumber(lane_info.swing_amount)) or 0
  local gdiv    = coords.GetGridDivQN()
  -- Effective swing grid. When a lane carries its own swing_subdiv, g_eff differs
  -- from the project grid: the project lines stay straight (structural reference)
  -- and we draw finer SWUNG guide ticks at g_eff so paint snapping is visible.
  local g_eff   = (coords.EffectiveSwingDivQN and coords.EffectiveSwingDivQN(lane_info)) or gdiv
  local lane_subdiv_mode = g_eff and gdiv and g_eff > 0 and math.abs(g_eff - gdiv) > 1e-9
  -- Project-grid lines only swing when the lane swings ON the project grid (no
  -- independent subdivision); otherwise the swing lives on the g_eff guides.
  local do_swing = swing ~= 0 and not lane_subdiv_mode
                   and coords.IsSwingableDiv and coords.IsSwingableDiv(gdiv)

  -- Build the list of item X ranges (in pixel space) from the pre-gathered
  -- lane item list. Grid lines are CLIPPED to fall inside one of these ranges.
  local ranges = {}
  for _, it in ipairs(lane_items) do
    local lx = coords.TimeToPixel(it.s)
    local rx = coords.TimeToPixel(it.e)
    if rx > lx then ranges[#ranges + 1] = { lx = lx, rx = rx } end
  end
  if #ranges == 0 then return end

  local col_subbeat = reaper.ImGui_ColorConvertDouble4ToU32(1, 1, 1, (settings.Get('grid_subbeat_alpha') or 80)  / 255)
  local col_beat    = reaper.ImGui_ColorConvertDouble4ToU32(1, 1, 1, (settings.Get('grid_beat_alpha')    or 170) / 255)
  -- Bar lines: a distinct warm accent (when enabled) so measure starts read at a
  -- glance vs the white beat/sub-beat lines; falls back to white when off.
  local bar_alpha   = (settings.Get('grid_bar_alpha') or 255) / 255
  local col_bar     = settings.Get('bar_line_accent') ~= false
                        and reaper.ImGui_ColorConvertDouble4ToU32(1.0, 0.78, 0.42, bar_alpha)
                        or  reaper.ImGui_ColorConvertDouble4ToU32(1, 1, 1, bar_alpha)
  local bar_thick   = settings.Get('grid_bar_thickness') or 2

  local function x_in_any_range(xv)
    for _, r in ipairs(ranges) do
      if xv >= r.lx - 1 and xv <= r.rx + 1 then return true end
    end
    return false
  end

  -- Independent-subdivision guides: when this lane swings on its own grid
  -- (g_eff ~= project), draw finer (swung) tick lines at g_eff across each item
  -- so the snap grid is visible where it diverges from the project grid. Drawn
  -- first so the project bar/beat lines overdraw them. Only runs on lanes that
  -- actually set swing_subdiv, so the common default case pays zero cost.
  if lane_subdiv_mode and coords.IsSwingableDiv and coords.IsSwingableDiv(g_eff) then
    for _, it in ipairs(lane_items) do
      local s_qn  = reaper.TimeMap_timeToQN(it.s)
      local e_qn  = reaper.TimeMap_timeToQN(it.e)
      local first = math.ceil(s_qn / g_eff - 1e-6)
      local last  = math.floor(e_qn / g_eff + 1e-6)
      for idx = first, last do
        local base_qn = idx * g_eff
        local sq      = (swing ~= 0) and coords.SwingTransformQN(base_qn, g_eff, swing) or base_qn
        local xv      = coords.TimeToPixel(reaper.TimeMap_QNToTime(sq))
        if x_in_any_range(xv) then
          local lx, rx = line_rect_x(xv, 1)
          fill_ex(dl, lx, y1, rx, y2, col_subbeat)
        end
      end
    end
  end

  for _, gl in ipairs(lines) do
    local x_raw = gl.x_raw
    if do_swing and gl.tier == 3 then
      local sq = coords.SwingTransformQN(gl.qn, gdiv, swing)
      if sq ~= gl.qn then x_raw = coords.TimeToPixel(reaper.TimeMap_QNToTime(sq)) end
    end
    -- Only draw the line if it falls inside at least one item on this lane.
    if x_in_any_range(x_raw) then
      if gl.tier == 1 then
        local lx, rx = line_rect_x(x_raw, bar_thick)
        fill_ex(dl, lx, y1, rx, y2, col_bar)
      elseif gl.tier == 2 then
        local lx, rx = line_rect_x(x_raw, 1)
        fill_ex(dl, lx, y1, rx, y2, col_beat)
      else
        local lx, rx = line_rect_x(x_raw, 1)
        fill_ex(dl, lx, y1, rx, y2, col_subbeat)
      end
    end
  end
end

-- Compute and return the velocity-strip rect for a lane, given its y bounds.
-- Returns nil if the strip should NOT be drawn.
-- Per-lane override (lane_info.show_strip == true) forces strip on regardless
-- of the global scope setting. Otherwise the scope setting decides.
local function strip_rect_for_lane(y1, y2, track, lane_info)
  if not settings.Get('graph_editor_enabled') then return nil end
  local pinned = lane_info and lane_info.show_strip == true
  if not pinned then
    local scope = settings.Get('graph_strip_scope') or 'selected'
    if scope == 'off' then return nil end
    if scope == 'selected' then
      local sel = reaper.GetSelectedTrack(0, 0)
      if not sel or sel ~= track then return nil end
    end
    -- scope == 'all' falls through
  end
  local sh = settings.Get('graph_strip_height') or 14
  if sh < 4 then return nil end
  if (y2 - y1) < (sh + 10) then return nil end
  return { y1 = y2 - sh, y2 = y2, h = sh }
end

-- Resolve a lane's pitch range. Priority (spec §4):
--   1. Swing-published gmem range (Phase 2; returns nil until Swing publishes)
--   2. lane_info.note_lo / note_hi (DM-local, validated at decode time)
--   3. default to the single pad pitch -> drum mode
-- Returns lo, hi with lo <= hi guaranteed.
local function resolve_pad_range(lane_info, swing_state)
  local pitch = lane_info.pad_pitch
  -- Stereo lane: the tag's note_lo/note_hi IS the mode (whole kit in one
  -- lane). Its pad_index is a placeholder 1 — a per-pad published range for
  -- pad 1 must never collapse the lane back to drum view.
  if lane_info.stereo == true then
    -- Live-first: the injected resolver (lane_tools.LaneRange) unions the tag
    -- window with the paired Swing's live pad pitches; the frozen tag is only
    -- the offline fallback.
    if _range_resolver then
      local ok, rlo, rhi = pcall(_range_resolver, lane_info)
      if ok and type(rlo) == 'number' and type(rhi) == 'number' and rhi >= rlo then
        return rlo, rhi
      end
    end
    local slo, shi = lane_info.note_lo, lane_info.note_hi
    if type(slo) == 'number' and type(shi) == 'number' and shi >= slo then
      return slo, shi
    end
  end
  if swing_state and swing_state.GetPadRange and lane_info.pad_index then
    local slot = swing_state.SlotForLane and swing_state.SlotForLane(lane_info) or nil
    local lo, hi = swing_state.GetPadRange(lane_info.pad_index, slot)
    if lo and hi and hi >= lo then return lo, hi end
  end
  local lo, hi = lane_info.note_lo, lane_info.note_hi
  if type(lo) == 'number' and type(hi) == 'number' and hi >= lo then
    return lo, hi
  end
  return pitch, pitch
end

-- MIDI black-key set (pitch % 12) and note names for the piano-view key strip.
local BLACK_KEY  = { [1] = true, [3] = true, [6] = true, [8] = true, [10] = true }
local NOTE_NAMES = { [0] = 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }

-- Subtle every-other-octave tint inside an item rect, to orient the eye on
-- ranges wider than one octave (spec §6.4). ~5% luminance shift on lane color.
local function draw_octave_shading(dl, x1, x2, item_top, lo, hi, sub_row_h, pr, pg, pb)
  if (hi - lo) <= 11 then return end
  local tint = rgba_u32(pr, pg, pb, 14)
  for pitch = lo, hi do
    if (math.floor(pitch / 12) % 2) == 0 then
      local ry1 = item_top + (hi - pitch) * sub_row_h
      fill_ex(dl, x1, ry1, x2, ry1 + sub_row_h, tint)
    end
  end
end

-- Pitch keyboard / label guide on the left edge of an item rect (spec §6.3).
-- Drawn BEFORE the note pass so notes render ON TOP of it — keys never hide a
-- note's start (e.g. at bar 1); they show through between notes as a faint
-- pitch reference. Honors the `piano_keyboard` Display setting:
--   'keys'   (default) -> ~24px semi-transparent black/white keys, C labels
--   'labels'           -> text-only note labels (no key rects)
--   'off'              -> nothing; the grid alone communicates pitch
-- No return value (notes are no longer clamped to its right edge).
-- row_names (optional, stereo lanes): { [pitch] = pad name } — preferred over
-- the plain note name so rows read Kick/Snare instead of C1/C#1. Truncated so
-- a long pad name doesn't wash across the whole item.
local function row_label(pitch, row_names)
  local nm = row_names and row_names[pitch]
  if nm and nm ~= '' then
    if #nm > 12 then nm = nm:sub(1, 12) end
    return nm
  end
  return NOTE_NAMES[pitch % 12] .. (math.floor(pitch / 12) - 1)
end
-- EON ICONS: small category glyph before a PAD row's label (row_names set =
-- stereo lane pad rows; plain note-name rows get none). Returns the extra x
-- offset the label should shift by (0 when no glyph drew). Ink follows the
-- label's contrast. Cost: <=6 primitives per visible pad row (name→id memoized
-- in cat_glyphs_bridge), well inside the guide's existing per-row text budget.
local function row_glyph(dl, x, ky1, sub_row_h, pitch, row_names, col)
  local nm = row_names and row_names[pitch]
  if not nm or nm == '' or sub_row_h < 12 then return 0 end
  if not settings.Get('show_lane_icons') then return 0 end
  local gid = cat_glyphs.IdForName(nm)
  if not gid then return 0 end
  local s = math.min(6, sub_row_h * 0.5 - 2)
  cat_glyphs.Draw(dl, gid, x + 6, ky1 + sub_row_h * 0.5, s, col, 1)
  return 13
end

local function draw_pitch_guide(dl, item_left, item_top, item_w, lo, hi, sub_row_h, row_names)
  local mode = settings.Get('piano_keyboard') or 'keys'
  if mode == 'off' then return end
  if mode ~= 'labels' and item_w >= 30 then
    -- Semi-transparent so notes + grid read through where they overlap.
    local kx2 = item_left + 24
    for pitch = lo, hi do
      local ky1 = item_top + (hi - pitch) * sub_row_h
      local ky2 = ky1 + sub_row_h - 1
      if ky2 > ky1 then
        local is_black = BLACK_KEY[pitch % 12]
        local key_col = is_black and 0x2020248C or 0xD8D8DC8C
        fill_ex(dl, item_left, ky1, kx2, ky2, key_col)
        -- Note name on every key when the row is tall enough (light text on
        -- black keys, dark on white). Drawn before notes so the note pass
        -- covers any spillover past the key strip.
        if sub_row_h >= 10 and not pt_hidden(item_left + 2, ky1 + 1) then
          local txt_col = is_black and 0xE6E6E6E1 or 0x000000C8
          local gx = row_glyph(dl, item_left + 2, ky1, sub_row_h, pitch, row_names, txt_col)
          reaper.ImGui_DrawList_AddText(dl, item_left + 2 + gx, ky1 + 1,
            txt_col, row_label(pitch, row_names))
        end
      end
    end
  elseif sub_row_h >= 10 then
    for pitch = lo, hi do
      local ky1 = item_top + (hi - pitch) * sub_row_h
      if not pt_hidden(item_left + 1, ky1 + 1) then
        local gx = row_glyph(dl, item_left + 1, ky1, sub_row_h, pitch, row_names, 0xCCCCCCC8)
        reaper.ImGui_DrawList_AddText(dl, item_left + 1 + gx, ky1 + 1, 0xCCCCCCC8,
          row_label(pitch, row_names))
      end
    end
  end
end

-- Shared piano-row geometry so the renderer and paint_mode map pitch<->Y with
-- IDENTICAL math (a click must land on the exact row the renderer drew).
--   cells_y2 = bottom of the cell area (above the velocity strip, if any)
--   item_top = top of the cell area
--   sub_row_h = pixel height of one pitch row
local function piano_cells_y2(y2_i, strip)
  return strip and (strip.y1 - 1) or (y2_i - 2)
end
-- Stereo lanes reserve a header band at the top of the lane for the label +
-- cog + M/S cluster (drawn at y1+2 by draw_pad_label), so the control rects
-- never sit ON the top pitch row — its first cells stay paintable. All three
-- geometry consumers (renderer, main-script lane_target stash, paint_mode via
-- the stash) MUST apply the same hdr or clicks land one row off.
M.STEREO_HDR = 20
local function piano_row_geometry(y1_i, cells_y2, lo, hi, hdr)
  local item_top  = y1_i + 2 + (hdr or 0)
  local sub_row_h = (cells_y2 - item_top) / ((hi - lo) + 1)
  return item_top, sub_row_h
end
-- Exposed for paint_mode: resolve item_top + sub_row_h from snapped lane bounds.
function M.PianoRowGeometry(y1_i, y2_i, strip, lo, hi, hdr)
  local cells_y2 = piano_cells_y2(y2_i, strip)
  local item_top, sub_row_h = piano_row_geometry(y1_i, cells_y2, lo, hi, hdr)
  return item_top, sub_row_h, cells_y2
end

-- Stereo-lane row banding: each mapped pad's row gets a faint wash of its own
-- pad color plus a 1px separator line, so 16 rows read at a glance (the
-- octave shading alone is too subtle for a whole-kit grid). Unmapped pitches
-- stay dark — real pad rows visibly pop against gap rows.
local function draw_row_banding(dl, x1, x2, item_top, lo, hi, sub_row_h, row_colors)
  local sep = 0x00000078
  for pitch = lo, hi do
    local ry1 = item_top + (hi - pitch) * sub_row_h
    local rc = row_colors[pitch]
    if rc then
      fill_ex(dl, x1, ry1, x2, ry1 + sub_row_h, rgba_u32(rc[1], rc[2], rc[3], 30))
    end
    if sub_row_h >= 5 then
      fill_ex(dl, x1, ry1, x2, ry1 + 1, sep)
    end
  end
end

-- Piano-roll cell pass for a multi-pitch lane (note_lo < note_hi). Mirrors the
-- drum cell pass (velocity->alpha, selection outline, velocity strip) but draws
-- per-item Y rects with one sub-row per pitch (ported from render_auto_zoom).
-- The caller's opaque LANE_BG already covers gaps between items, so we draw
-- ONLY inside item rects. Returns true if any item collapsed to the <3px
-- composite fallback (drives the "↕" lane-label badge, spec §6.5).
local function render_lane_piano(dl, coords, lane_items, lo, hi, view_start, view_end,
                                 y1_i, cells_y2, strip, pad_r, pad_g, pad_b, border,
                                 mx, my, hover_ok, row_names, row_colors, hdr)
  local item_top, sub_row_h = piano_row_geometry(y1_i, cells_y2, lo, hi, hdr)
  if (cells_y2 - item_top) <= 0 then return false end
  local fallback  = sub_row_h < 3   -- matches render_auto_zoom convention
  local x_left_view = coords.Snap(coords.TimeToPixel(view_start))
  local notes_rendered = 0
  local collapsed_any = false

  for _, it in ipairs(lane_items) do
    if notes_rendered >= MAX_NOTES_PER_LANE_PER_FRAME then break end
    if it.e >= view_start and it.s <= view_end then
      local fx1 = coords.Snap(coords.TimeToPixel(it.s))
      local fx2 = coords.Snap(coords.TimeToPixel(it.e))
      if fx2 > fx1 then
        if fallback then
          collapsed_any = true
        else
          -- Stereo lanes swap the octave shading for per-pad row banding —
          -- 16 kit-colored rows instead of a flat wash.
          if row_colors then
            draw_row_banding(dl, fx1, fx2, item_top, lo, hi, sub_row_h, row_colors)
          else
            draw_octave_shading(dl, fx1, fx2, item_top, lo, hi, sub_row_h, pad_r, pad_g, pad_b)
          end
          -- Keyboard drawn first; notes (below) render on top, so item-starts
          -- are never hidden behind the keys.
          draw_pitch_guide(dl, fx1, item_top, fx2 - fx1, lo, hi, sub_row_h, row_names)
        end

        local take = it.take
        local _, note_count = reaper.MIDI_CountEvts(take)
        for ni = 0, note_count - 1 do
          if notes_rendered >= MAX_NOTES_PER_LANE_PER_FRAME then break end
          local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(take, ni)
          if ok and pitch >= lo and pitch <= hi then
            local n_start = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
            local n_end   = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
            if n_end >= view_start and n_start <= view_end then
              local cx1 = coords.Snap(coords.TimeToPixel(n_start))
              local cx2 = coords.Snap(coords.TimeToPixel(n_end))
              if cx1 < x_left_view then cx1 = x_left_view end
              if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
              local cy1, cy2
              if fallback then
                cy1, cy2 = item_top, cells_y2
              else
                cy1 = item_top + (hi - pitch) * sub_row_h + 1
                cy2 = cy1 + sub_row_h - 1
              end
              if cy2 > cy1 and cx2 > cx1 then
                -- Stereo lanes color each note with ITS pad's hue (row_colors),
                -- not the lane-wide pad-1 color — the note tells you the pad.
                local nr, ng, nb = pad_r, pad_g, pad_b
                local rc = row_colors and row_colors[pitch]
                if rc then nr, ng, nb = rc[1], rc[2], rc[3] end
                local alpha = 130 + math.floor((vel / 127) * 110 + 0.5)  -- 130..240
                local cell_fill = rgba_u32(nr, ng, nb, alpha)
                -- Inset the right edge 1px so back-to-back notes leave a dark
                -- seam (lane bg shows through): one long note stays solid, while
                -- N consecutive notes read as N segments.
                local rx2 = (cx2 - cx1 > 3) and (cx2 - 1) or cx2
                fill_ex(dl, cx1, cy1, rx2, cy2, cell_fill)
                if not fallback and sub_row_h >= 4 then
                  frame_ex(dl, cx1, cy1, rx2, cy2, border, 1)
                end
                -- Note-onset accent: a 1px bright line at the attack so every
                -- note reads distinctly even when narrow or abutting.
                if not fallback then
                  fill_ex(dl, cx1, cy1, cx1 + 1, cy2, 0xFFFFFF66)
                end
                if selection.Contains(take, ppq_s, pitch) then
                  frame_ex(dl, cx1 - 1, cy1 - 1, cx2 + 1, cy2 + 1, 0xFFFFFFFF, 2)
                end
                -- Hover tooltip (#14): cursor inside this note rect → queue it.
                -- Not when the cursor sits in a floating-FX cutout hole.
                if hover_ok and mx >= cx1 and mx <= cx2 and my >= cy1 and my <= cy2
                   and not pt_hidden(mx, my) then
                  queue_tooltip(coords, n_start, vel)
                end
                notes_rendered = notes_rendered + 1

                if strip then
                  local bar_h    = math.floor((vel / 127) * strip.h + 0.5)
                  local bar_w    = math.max(2, cx2 - cx1 - 1)
                  local bar_fill = rgba_u32(nr, ng, nb, 180)
                  fill_ex(dl, cx1, strip.y2 - bar_h, cx1 + bar_w, strip.y2, bar_fill)
                end
              end
            end
          end
        end
      end
    end
  end
  return collapsed_any
end

function M.RenderLane(ctx, dl, track, lane_info, coords, swing_state)
  if not lane_info then return end
  if not lane_info.pad_index or not lane_info.pad_pitch then return end
  -- Track pointer may have been invalidated since Classify ran this frame
  -- (e.g. user deleted the track from the TCP context menu between iterator
  -- steps). Skip rather than crash inside GetMediaTrackInfo_Value.
  if _safety and not _safety.ValidateTrack(track) then return end

  local y1, y2, h = coords.GetTrackY(track)
  if not h or h <= 0 then return end

  local view_start, view_end = coords.GetVisibleTimeRange()
  if not view_start or not view_end or view_end <= view_start then return end

  -- Hover-tooltip (#14): grab the mouse once per lane. hover_ok gates the
  -- per-cell hit-test — false while any drag is active (no tooltip mid-drag,
  -- and skip the FormatBarBeat cost). ctx may be nil in some call paths; guard.
  local mx, my = nil, nil
  if ctx then mx, my = reaper.ImGui_GetMousePos(ctx) end
  local hover_ok = (mx ~= nil) and not (_drag_query and _drag_query())

  -- Gather the MIDI items on this lane's track ONCE. All three draw passes
  -- below (grid lines, item frames, step cells) reuse this list instead of
  -- each independently re-walking the track's media-item list every frame.
  local lane_items = {}
  do
    local n = reaper.CountTrackMediaItems(track)
    for i = 0, n - 1 do
      local item = reaper.GetTrackMediaItem(track, i)
      local take = item and reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local s = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
        local e = s + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
        lane_items[#lane_items + 1] = { item = item, take = take, s = s, e = e }
      end
    end
  end

  -- Resolve the lane's pitch range and pick the render mode. lo == hi → drum
  -- (single-pitch step cells); lo < hi → piano (mini roll). Fixed-lane / free-
  -- item-positioning tracks (I_FREEMODE ≠ 0, covering both REAPER free mode and
  -- fixed lanes) place items at per-item Y; piano view's flat per-track Y would
  -- misplace them, so they fall back to drum mode (spec §13).
  local lo, hi = resolve_pad_range(lane_info, swing_state)
  local is_free = (reaper.GetMediaTrackInfo_Value(track, 'I_FREEMODE') or 0) ~= 0
  local piano_mode = (lo < hi) and not is_free

  -- Snap lane bounds + view bounds to integer pixels so border / background /
  -- grid lines / cells all sit on the same pixel grid.
  local x_left  = coords.Snap(coords.TimeToPixel(view_start))
  local x_right = coords.Snap(coords.TimeToPixel(view_end))
  if x_right <= x_left then return end
  local y1_i = coords.Snap(y1)
  local y2_i = coords.Snap(y2)

  -- Pad color from the unified live kit hue (P1) — the same color the pad face,
  -- the lane TCP track, and the audio TCP track use, so they all match. The
  -- lane's resolved registry slot routes the read to its OWN Swing instance
  -- when several are live (multi-Swing).
  local lane_slot = swing_state.SlotForLane and swing_state.SlotForLane(lane_info) or nil
  local pad_r, pad_g, pad_b = swing_state.GetPadColor(lane_info.pad_index, lane_slot)
  -- Blank pad (no sample) → render the lane COLORLESS (neutral grey) instead of
  -- its kit hue, so empty lanes read as empty — matching the
  -- blank-pad treatment on the TCP tracks + Swing grid. swing_sync keeps
  -- pad_name cleared to '' for empty pads, and its Tick runs before this render
  -- loop each frame, so lane_info.pad_name is current here.
  if (lane_info.pad_name or '') == '' then
    pad_r, pad_g, pad_b = 0.30, 0.30, 0.32
  end
  local border_r, border_g, border_b = darker(pad_r, pad_g, pad_b, 0.55)
  local border = rgba_u32(border_r, border_g, border_b, 200)

  -- 1a) OPAQUE lane background. This masks REAPER's native arrange grid +
  -- items beneath us, so the only grid/cells the user sees are OURS — which
  -- share one coordinate system with our cells = perfect alignment. The
  -- masked items are visually replaced by lane bg + thin item frames (1b).
  -- Color: REAPER's default arrange bg-ish dark.
  -- Stays OPAQUE by design (it must mask REAPER's native grid/items so our
  -- cells own the pixels) — only the grey level is user-adjustable
  -- (Display tab -> "Background brightness"; 18 = the original 0x121212).
  local bgv = (settings.Get('lane_bg_brightness') or 18) / 255
  local LANE_BG = rgba_u32(bgv, bgv, bgv, 255)
  fill_ex(dl, x_left, y1_i, x_right, y2_i, LANE_BG)

  -- Optional translucent tint on top of the opaque bg (user-controllable
  -- via Display tab; defaults to off for a clean step-cell look). Piano mode
  -- halves it: a full-lane wash fights the per-pitch row contrast that's the
  -- whole point of the mini-roll, so we keep just enough for lane identity.
  local tint = lane_tint_alpha()
  if piano_mode then tint = math.floor(tint * 0.5) end
  if tint > 0 then
    local bg = rgba_u32(pad_r, pad_g, pad_b, tint)
    fill_ex(dl, x_left, y1_i, x_right, y2_i, bg)
  end

  -- 1b) Thin item frames — replaces the dim MIDI items hidden by the opaque
  -- background. Just a 1px outline at each item's x range inside the lane
  -- band, in the lane's pad color (dimmed). Tells the user "matrix lives
  -- here" without competing with the cells.
  local frame_col = rgba_u32(border_r, border_g, border_b, 130)
  for _, it in ipairs(lane_items) do
    if it.e >= view_start and it.s <= view_end then
      local fx1 = coords.Snap(coords.TimeToPixel(it.s))
      local fx2 = coords.Snap(coords.TimeToPixel(it.e))
      if fx2 > fx1 then
        frame_ex(dl, fx1, y1_i + 1, fx2, y2_i - 1, frame_col, 1)
      end
    end
  end

  -- Lane separators: horizontal top + bottom edges of the lane band. Alpha is
  -- user-configurable (Display tab → lane_border_alpha). 0 = invisible so lanes
  -- visually blend; default 200 = clearly delineated rows. Vertical sides of
  -- the lane rect are intentionally NOT drawn — empty arrange space to the left
  -- and right of items shouldn't have a colored frame around it.
  local sep_alpha = settings.Get('lane_border_alpha') or 200
  if sep_alpha > 0 then
    local sep_col = rgba_u32(border_r, border_g, border_b, sep_alpha)
    fill_ex(dl, x_left, y1_i,     x_right, y1_i + 1, sep_col)
    fill_ex(dl, x_left, y2_i - 1, x_right, y2_i,     sep_col)
  end

  -- 1.5) Grid lines inside the lane's items only. They don't extend across
  -- empty arrange space — only where the matrix actually exists.
  draw_lane_grid(dl, coords, lane_items, y1_i, y2_i, lane_info)

  -- Strip occupies the bottom of the lane (Phase F). Scope decides which
  -- lanes actually render it; cells use full lane height when strip is absent.
  local strip = strip_rect_for_lane(y1_i, y2_i, track, lane_info)
  local cells_y2 = strip and (strip.y1 - 1) or (y2_i - 2)
  if strip then
    -- Subtle separator above the strip + dim background.
    local sep = rgba_u32(border_r, border_g, border_b, 120)
    fill_ex(dl, x_left, strip.y1 - 1, x_right, strip.y1, sep)
    local strip_bg = rgba_u32(pad_r, pad_g, pad_b, 35)
    fill_ex(dl, x_left, strip.y1, x_right, strip.y2, strip_bg)
  end

  -- Piano mode forks here: the shared prelude above (validation, opaque bg,
  -- item frames, separators, grid lines, strip) runs identically; only the
  -- cell pass differs. RenderLane returns: collapsed, lo, hi, piano_mode —
  -- the caller stashes the range + mode on the lane_target so paint_mode can
  -- map pitch<->Y. render_lane_piano returns one value (collapsed), truncated
  -- to a single slot here since it's not the last item in the return list.
  if piano_mode then
    -- Stereo lane: per-row pad names for the key guide (Kick/Snare instead of
    -- C1/C#1) and per-row pad COLORS (row banding + note tint), from the
    -- lane's own Swing instance. nil when the instance is offline — the guide
    -- falls back to plain note names and the flat lane color.
    local row_names, row_colors
    if lane_info.stereo == true and lane_slot ~= nil then
      row_names, row_colors = {}, {}
      for pad = 1, 16 do
        local p = swing_state.GetPadPitch(pad, lane_slot)
        if p and p > 0 and p >= lo and p <= hi then
          local nm = swing_state.GetPadName(pad, lane_slot)
          if nm and nm ~= '' then row_names[p] = nm end
          local cr, cg, cb = swing_state.GetPadColor(pad, lane_slot)
          if cr then row_colors[p] = { cr, cg, cb } end
        end
      end
    end
    local hdr = (lane_info.stereo == true) and M.STEREO_HDR or 0
    return render_lane_piano(dl, coords, lane_items, lo, hi, view_start, view_end,
                             y1_i, cells_y2, strip, pad_r, pad_g, pad_b, border,
                             mx, my, hover_ok, row_names, row_colors, hdr),
           lo, hi, piano_mode
  end

  -- 2) Step cells + velocity bars: iterate the pre-gathered MIDI items
  local target_pitch = lane_info.pad_pitch
  -- Per-lane note budget. Counts notes WE actually rendered (matching pitch
  -- and inside the view); not raw take note count. Lets a lane with 5000
  -- foreign-pitch notes still draw all of its matching ones cheaply.
  local notes_rendered_this_lane = 0
  for _, it in ipairs(lane_items) do
    if notes_rendered_this_lane >= MAX_NOTES_PER_LANE_PER_FRAME then break end
    local item_start = it.s
    local item_end   = it.e

    -- Culling: skip items entirely outside view
    if item_end >= view_start and item_start <= view_end then
      local take = it.take
      if take then
        local _, note_count = reaper.MIDI_CountEvts(take)
        for ni = 0, note_count - 1 do
          if notes_rendered_this_lane >= MAX_NOTES_PER_LANE_PER_FRAME then
            if not _budget_warned_for_take[take] then
              _budget_warned_for_take[take] = true
              if _safety then
                _safety.ConsoleWarn(string.format(
                  'render budget: lane pitch %d has >%d visible cells — capping render this frame',
                  target_pitch, MAX_NOTES_PER_LANE_PER_FRAME))
              end
            end
            break
          end
          local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(take, ni)
          if ok and pitch == target_pitch then
            -- Cell width = the NOTE's actual MIDI duration (frozen at paint time).
            local n_start = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
            local n_end   = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
            if n_end >= view_start and n_start <= view_end then
              -- Round via shared coords.Snap so cell edges sit on the same
              -- pixel as the grid lines.
              local cx1 = coords.Snap(coords.TimeToPixel(n_start))
              local cx2 = coords.Snap(coords.TimeToPixel(n_end))
              if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
              local cy1 = y1_i + 2
              local cy2 = cells_y2
              if cy2 > cy1 then
                local alpha = 130 + math.floor((vel / 127) * 110 + 0.5)  -- 130..240
                local cell_fill = rgba_u32(pad_r, pad_g, pad_b, alpha)
                fill_ex(dl, cx1, cy1, cx2, cy2, cell_fill)
                frame_ex(dl, cx1, cy1, cx2, cy2, border, 1)
                -- Selection highlight: bright white outline on selected cells.
                if selection.Contains(take, ppq_s, target_pitch) then
                  frame_ex(dl, cx1 - 1, cy1 - 1, cx2 + 1, cy2 + 1, 0xFFFFFFFF, 2)
                end
                -- Hover tooltip (#14): cursor inside this cell → queue bar.beat + vel.
                -- Not when the cursor sits in a floating-FX cutout hole.
                if hover_ok and mx >= cx1 and mx <= cx2 and my >= cy1 and my <= cy2
                   and not pt_hidden(mx, my) then
                  queue_tooltip(coords, n_start, vel)
                end
                notes_rendered_this_lane = notes_rendered_this_lane + 1
              end

              -- Velocity bar in the strip: height proportional to velocity.
              -- Lower alpha (180 vs 230) so a dense pattern doesn't visually
              -- compete with the cells above.
              if strip then
                local bar_h    = math.floor((vel / 127) * strip.h + 0.5)
                local bar_y1   = strip.y2 - bar_h
                local bar_w    = math.max(2, cx2 - cx1 - 1)
                local bar_fill = rgba_u32(pad_r, pad_g, pad_b, 180)
                fill_ex(dl, cx1, bar_y1, cx1 + bar_w, strip.y2, bar_fill)
              end
            end
          end
        end
      end
    end
  end
  -- Drum path: report the resolved range + mode (piano_mode is false here) so
  -- the caller can stash it on the lane_target uniformly with the piano path.
  return false, lo, hi, piano_mode
end

-- Exposed so paint_mode can hit-test the strip and convert mouse-Y to velocity.
M.GetStripRectForLane = strip_rect_for_lane

-- Draw a single painted cell (fill + border), matching the look of the cells
-- the per-lane passes draw. Used by the main loop's phantom-cell pass so a
-- just-painted note appears on the click frame instead of one frame later.
-- vel modulates fill alpha exactly like the real passes (130..240).
function M.DrawCellRect(dl, cx1, cy1, cx2, cy2, pad_r, pad_g, pad_b, vel)
  local alpha = 130 + math.floor(((vel or 100) / 127) * 110 + 0.5)
  local rx2 = (cx2 - cx1 > 3) and (cx2 - 1) or cx2   -- match the seam in the live passes
  fill_ex(dl, cx1, cy1, rx2, cy2, rgba_u32(pad_r, pad_g, pad_b, alpha))
  local br, bg, bb = darker(pad_r, pad_g, pad_b, 0.55)
  frame_ex(dl, cx1, cy1, rx2, cy2, rgba_u32(br, bg, bb, 200), 1)
  fill_ex(dl, cx1, cy1, cx1 + 1, cy2, 0xFFFFFF66)
end

return M
