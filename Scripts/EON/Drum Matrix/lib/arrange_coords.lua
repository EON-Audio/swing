-- arrange_coords.lua : pure time/track <-> pixel mapping helpers for EON Drum Matrix

local M = {}

local LEFT, TOP, RIGHT, BOT = 0, 0, 0, 0
local SCROLL_SIZE = 17
local screen_scale = 1

-- Per-frame cache populated by M.BeginFrame(). Eliminates repeated calls to
-- GetSet_ArrangeView2 / GetSetProjectGrid / TimeMap_timeToQN per frame.
local view_start_t, view_end_t, view_inv_span = 0, 0, 0
local grid_div_qn_cached = 0
local grid_lines_cache   = {}    -- list of { x, tier }; tier = 1 bar / 2 beat / 3 sub-beat

function M.SetBounds(l, t, r_, b, scroll)
  LEFT, TOP, RIGHT, BOT = l, t, r_, b
  SCROLL_SIZE = scroll or SCROLL_SIZE
end

function M.SetScale(s)
  screen_scale = (s and s > 0) and s or 1
end

-- Universal integer-pixel snap. Use everywhere we hand a coordinate to ImGui
-- so cells, grid lines, lane borders and labels all sit on the same pixel.
function M.Snap(v) return math.floor((v or 0) + 0.5) end

function M.GetVisibleTimeRange()
  return view_start_t, view_end_t
end

-- Time axis spans the FULL arrange width (LEFT..RIGHT). We do NOT subtract the
-- scrollbar width here — REAPER's visible time range maps across the whole
-- window; the vertical scrollbar just overlays the rightmost sliver. This
-- matches the proven TK_Trackname_in_Arrange mapping exactly (arrange_width =
-- RIGHT - LEFT). Subtracting SCROLL_SIZE here was an old bug that compressed
-- the axis and drifted ~scrollbar-width by the right edge.
function M.TimeToPixel(time)
  if view_inv_span == 0 then return LEFT end
  local w = RIGHT - LEFT
  -- Degenerate-view guard: when arrange is collapsed to less than a pixel
  -- (overlay just opened, minimized, or REAPER being resized), don't try to
  -- map — return LEFT so callers don't see NaN or huge negative offsets.
  if w <= 1 then return LEFT end
  return LEFT + w * ((time - view_start_t) * view_inv_span)
end

function M.PixelToTime(px)
  local w = RIGHT - LEFT
  if w <= 1 then return view_start_t end
  local rel = (px - LEFT) / w
  -- Note: we deliberately DO NOT clamp rel to [0,1]. Allowing negative
  -- view_start (rare but real when REAPER's arrange is scrolled into
  -- negative-time territory) means a click in that zone still maps back to
  -- the right time, instead of trapping at view_start_t. Callers that need
  -- a clamp should do it themselves.
  return view_start_t + rel * (view_end_t - view_start_t)
end

-- Call once per MainLoop tick (after SetBounds) to populate caches that
-- downstream renderers reuse without re-querying REAPER.
function M.BeginFrame()
  local s, e = reaper.GetSet_ArrangeView2(0, false, 0, 0)
  view_start_t = s
  view_end_t   = e
  local span   = e - s
  view_inv_span = (span ~= 0) and (1 / span) or 0

  -- Degenerate view guard: if our window has no usable width (overlay just
  -- created, REAPER mid-resize, project being closed), skip the expensive
  -- grid-line cache build — TimeToPixel will return LEFT for everything so
  -- there's nothing meaningful to render anyway.
  local pw = RIGHT - LEFT
  if pw <= 1 then return end

  -- Cache grid lines (one classification + pixel position per visible grid line).
  local _, gdiv = reaper.GetSetProjectGrid(0, false)
  grid_div_qn_cached = gdiv or 0
  grid_lines_cache   = {}
  if not gdiv or gdiv == 0 then return end
  local s_qn = reaper.TimeMap_timeToQN(s)
  local e_qn = reaper.TimeMap_timeToQN(e)
  local first = math.ceil(s_qn / gdiv - 1e-6)
  local last  = math.floor(e_qn / gdiv + 1e-6)
  for idx = first, last do
    local qn = idx * gdiv
    local t  = reaper.TimeMap_QNToTime(qn)
    local x_raw = M.TimeToPixel(t)
    -- QNToMeasures returns the INTEGER measure index containing qn plus that
    -- measure's start/end QN. Use the start QN to detect a true bar boundary —
    -- comparing the (always-integer) measure index to itself would mark EVERY
    -- grid line as a bar. Bar starts aren't always integer QN (e.g. 3/4, 7/8),
    -- so this is also more correct than an integer-QN test for the bar tier.
    local _, qn_bar_start = reaper.TimeMap_QNToMeasures(0, qn)
    local tier
    if qn_bar_start and math.abs(qn - qn_bar_start) < 1e-4 then tier = 1             -- bar
    elseif math.abs(qn - math.floor(qn + 0.5)) < 1e-4 then tier = 2                  -- beat
    else tier = 3                                                                    -- sub-beat
    end
    grid_lines_cache[#grid_lines_cache + 1] = { x_raw = x_raw, qn = qn, t = t, tier = tier }
  end
end

function M.GetGridLines()
  return grid_lines_cache
end

function M.GetGridDivQN()
  return grid_div_qn_cached
end

-- Effective swing grid division (QN) for one lane. A lane may carry its own
-- swing_subdiv (set via the cog "Swing grid" combo) to swing on a finer/coarser
-- grid than the project/paint grid. Absent / 0 / invalid -> follow the project
-- grid (grid_div_qn_cached, refreshed each frame in BeginFrame). The
-- single source of truth so render, paint snap and the Apply op always agree.
-- Note: track_detection.validate_lane_info already drops bad swing_subdiv to
-- nil, so here we trust the value but still guard for a 0/negative just in case.
function M.EffectiveSwingDivQN(lane_info)
  local sd = lane_info and lane_info.swing_subdiv
  if sd and sd > 0 then return sd end
  return grid_div_qn_cached
end

function M.GetTrackY(track)
  local y = reaper.GetMediaTrackInfo_Value(track, 'I_TCPY') / screen_scale
  local h = reaper.GetMediaTrackInfo_Value(track, 'I_TCPH') / screen_scale
  return TOP + y, TOP + y + h, h
end

function M.SnapTimeToGrid(time)
  local _, grid_div = reaper.GetSetProjectGrid(0, false)
  if grid_div == 0 then return time end
  local beat = reaper.TimeMap_timeToQN(time)
  return reaper.TimeMap_QNToTime(math.floor(beat / grid_div + 0.5) * grid_div)
end

-- Floor-snap to the START of the grid cell containing `time`. Use this for
-- step-sequencer click semantics: a click anywhere inside a cell lands in
-- that cell, not the nearest grid line (which could be the next cell over).
function M.SnapDownToCell(time)
  local _, grid_div = reaper.GetSetProjectGrid(0, false)
  if grid_div == 0 then return time end
  local beat = reaper.TimeMap_timeToQN(time)
  return reaper.TimeMap_QNToTime(math.floor(beat / grid_div) * grid_div)
end

-- Duration (in seconds) of one grid step starting at `time`. Tempo-aware.
function M.GetGridStep(time)
  local _, grid_div = reaper.GetSetProjectGrid(0, false)
  if grid_div == 0 then return 0 end
  local qn = reaper.TimeMap_timeToQN(time)
  return reaper.TimeMap_QNToTime(qn + grid_div) - time
end

-- Format a project time as a "bar.beat.sub" musical position string for the
-- hover tooltip (#14). Returns e.g. "3.2.3" = bar 3, beat 2, sub-step 3.
--
-- Bars/beats are 1-based to match REAPER's own ruler. We lean on
-- TimeMap_QNToMeasures, which returns (measure_index_0based, qnMeasureStart,
-- qnMeasureEnd) — same call the tier classifier in BeginFrame uses — so the
-- bar start is meter-correct (handles 3/4, 7/8, mid-project meter changes)
-- without a second GetMeasureInfo round-trip.
--
-- The sub-step count is derived from the current project grid division
-- (grid_div_qn_cached, refreshed each frame in BeginFrame). When the grid is
-- a whole quarter-note or coarser (gdiv >= 1), there are no meaningful
-- sub-steps, so we emit just "bar.beat".
function M.FormatBarBeat(time)
  local qn = reaper.TimeMap_timeToQN(time)
  -- NOTE: TimeMap_QNToMeasures returns a 1-based measure index here (verified
  -- in-REAPER: a note in bar 1 reports index 1), so we display it directly —
  -- adding 1 would over-count. The 2nd return (bar start QN) is base-agnostic.
  local meas_idx, bar_start_qn = reaper.TimeMap_QNToMeasures(0, qn)
  local meas = math.floor((meas_idx or 1))
  local qn_in_bar = qn - (bar_start_qn or 0)
  if qn_in_bar < 0 then qn_in_bar = 0 end
  local beat = math.floor(qn_in_bar) + 1
  local qn_in_beat = qn_in_bar - (beat - 1)
  local gdiv = grid_div_qn_cached
  if not gdiv or gdiv <= 0 or gdiv >= 1 then
    return string.format('%d.%d', meas, beat)
  end
  local subs_per_beat = math.floor(1 / gdiv + 0.5)
  local sub = math.floor(qn_in_beat / gdiv + 0.5) + 1
  if subs_per_beat > 0 and sub > subs_per_beat then sub = subs_per_beat end
  return string.format('%d.%d.%d', meas, beat, sub)
end

-- =============================================================================
-- per-lane swing (#8)
-- =============================================================================
--
-- Swing pairs adjacent grid cells: the on-beat (even grid-line index) never
-- moves; the off-beat (odd index) shifts LATE by `swing_amount * g/3`, where g
-- is the grid division in QN. swing_amount is -1..1 (REAPER's own swing range);
-- +1 pushes the off-beat by a full g/3 (triplet feel), -1 pulls it early.
--
-- Two grid families swing, each with its own pairing model:
--   * BINARY (power-of-2): cells pair up; the on-beat (even index) never moves,
--     the off-beat (odd index) shifts LATE by s*g/3.
--   * TRIPLET (1/4T, 1/8T, 1/16T): cells group in threes; on-beat (pos 0) and
--     middle (pos 1) stay put, only the LAST of each triplet (pos 2) shifts by
--     s*g/3 — the "1-trip-LET" push, which reads as a coherent triplet shuffle.
-- Dotted / arbitrary grids are not swingable (no defensible pairing) and the UI
-- disables the slider there. Tolerance match against fixed division sets is
-- simpler and safer than a log2 test against float grid values.
local SWING_DIVS   = { 1, 0.5, 0.25, 0.125, 0.0625, 0.03125 }
local TRIPLET_DIVS = { 1/6, 1/12, 1/24 }   -- 1/4T, 1/8T, 1/16T (in QN)

local function in_div_set(g, set)
  if not g or g <= 0 then return false end
  for _, d in ipairs(set) do
    if math.abs(g - d) < 1e-6 then return true end
  end
  return false
end
local function is_triplet_div(g) return in_div_set(g, TRIPLET_DIVS) end
local function swingable_div(g)
  return in_div_set(g, SWING_DIVS) or in_div_set(g, TRIPLET_DIVS)
end
M.IsSwingableDiv  = swingable_div
M.IsTripletDiv    = is_triplet_div

-- Shift a straight grid-line QN to its swung position. Pass-through for cells
-- that never move (binary on-beats; triplet pos 0/1); the moving cell shifts by
-- s*g/3.
function M.SwingTransformQN(qn, g, s)
  if not s or s == 0 or not swingable_div(g) then return qn end
  local idx = math.floor(qn / g + 0.5)
  if is_triplet_div(g) then
    if (idx % 3) == 2 then return qn + s * (g / 3) end
    return qn
  end
  if (idx % 2) == 1 then return qn + s * (g / 3) end
  return qn
end

-- Inverse: given an arbitrary QN (e.g. a click position), return the START of
-- the swung cell it falls into. Closed-form group math; for s in [-1,1] the
-- swung cell starts stay monotonic within a group, so simple comparisons pick
-- the cell. With s=0 (or non-swingable g) this reduces to floor(qn/g)*g.
function M.SwingSnapDownToCellQN(qn, g, s)
  if not g or g <= 0 then return qn end
  if not s or s == 0 or not swingable_div(g) then
    return math.floor(qn / g + 1e-9) * g
  end
  if is_triplet_div(g) then
    -- Group of 3: starts at base, base+g, base+2g + s*g/3.
    local grp        = math.floor(qn / (3 * g) + 1e-9)
    local base       = grp * 3 * g
    local last_start = base + 2 * g + s * (g / 3)
    if    qn >= last_start    then return last_start
    elseif qn >= base + g     then return base + g
    else                           return base end
  end
  -- Binary pair: even cell at 2p*g, odd cell at (2p+1)*g shifted by s*g/3.
  local pair       = math.floor(qn / (2 * g) + 1e-9)
  local even_start = pair * 2 * g
  local odd_start  = even_start + g + s * (g / 3)
  if qn < odd_start then return even_start else return odd_start end
end

return M
