-- ============================================================================
-- EON_Choppa.lua — Audio slicer / chopper for REAPER
-- ============================================================================
-- (c) EON Studios — All Rights Reserved
--
-- General-purpose onset detection UI that works with Swing (and future JSFX).
-- Detects transients in drum loops, displays interactive waveform with
-- movable slice markers, and applies slices to Swing pads or exports WAVs.
--
-- Backend: C++ Extension onset detector (transient + spectral + spectral flux via pffft)
-- BPM: Phase-aware tempo estimation from onset intervals (ported from ReaBeat)
-- UI: ReaImGui
-- Communication: ExtState (Extension ↔ Lua); pad pushes = slice WAVs into
--                the sample store + per-pad CMD 63 path loads over gmem
-- ============================================================================

local SCRIPT_NAME = "EON Choppa"
local VERSION     = "0.1.0"

-- ═══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCY CHECKS
-- ═══════════════════════════════════════════════════════════════════════════════

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB(
    SCRIPT_NAME .. " requires the ReaImGui extension.\n\n"
    .. "Install it from ReaPack:\n"
    .. "Extensions > ReaPack > Browse packages > search 'ReaImGui'",
    "Missing Dependency", 0)
  return
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MODULE REQUIRES
-- ═══════════════════════════════════════════════════════════════════════════════

local _sep = package.config:sub(1,1)
local _SCRIPT_DIR = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]") or ""

package.path = _SCRIPT_DIR .. _sep .. "?.lua;" ..
               reaper.ImGui_GetBuiltinPath() .. "/?.lua;" ..
               (package.path or "")

local ImGui   = require 'imgui' '0.9.3.2'
local core    = dofile(_SCRIPT_DIR .. _sep .. "rk_lua_core.lua")
local widgets = dofile(_SCRIPT_DIR .. _sep .. "rk_lua_widgets.lua")

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════════

local EXTSTATE_SECTION = "EON_Choppa"

-- Swing instance-registry slots — imported from rk_lua_core.lua's GMEM table
-- (single source of truth). Hardcoded copies here went stale when the
-- registry relocated 2300 → 2556 (the scan read dead cells and never found
-- an instance, so every push aborted with "No live Swing instance found").
local GS_INST_REG_BASE     = core.GMEM.GS_INST_REG_BASE
local GS_INST_REG_STRIDE   = core.GMEM.GS_INST_REG_STRIDE
local GS_INST_REG_MAX      = core.GMEM.GS_INST_REG_MAX
local GS_INST_REG_TIMEOUT  = core.GMEM.GS_INST_REG_TIMEOUT

-- ReCycle-inspired palette (light waveform area, blue accent)
local COL_WAVEFORM      = 0x2A5898E0  -- dark navy/steel blue waveform fill
local COL_WAVEFORM_BG   = 0xCCCCD4FF  -- light warm gray background
local COL_MARKER        = 0x1177DDFF  -- strong blue marker line
local COL_MARKER_HOVER  = 0x33AAFFFF  -- lighter blue on hover
local COL_MARKER_DRAG   = 0x55CCFFFF  -- bright cyan while dragging
local COL_SLICE_FILL    = 0x1177DD18  -- subtle blue fill for selected slice
local COL_PAD_EMPTY     = 0x2A2A32FF
local COL_PAD_FILLED    = 0x3A4A60FF  -- slate blue filled pad
local COL_PAD_PLAYING   = 0x1177DDFF
local COL_ENERGY_BAR    = 0x1177DD80
local COL_CENTER_LINE   = 0x66666630  -- subtle center line on light bg
local COL_GRID_LINE     = 0x00000015  -- very subtle amplitude grid
local COL_GRID_TEXT     = 0x777777FF  -- dB label text
local COL_MARKER_LABEL  = 0x111133FF  -- dark text on light background
local COL_OVERVIEW_BG   = 0xBBBBC2FF  -- slightly darker for overview area
local COL_OVERVIEW_VP   = 0x1177DD30  -- viewport rectangle fill
local COL_OVERVIEW_VPBR = 0x1177DD90  -- viewport rectangle border
local COL_OVERVIEW_WAVE = 0x3A6898C0  -- overview waveform mini
local COL_BORDER        = 0x00000050  -- thin border around panels

-- Alternating slice region fills (pastel tints on light background)
local SLICE_COLORS = {
  0x4488CC18,  -- cool blue
  0x7755AA18,  -- soft purple
  0x44AA7718,  -- sage green
  0xAA884418,  -- warm amber
}
local SLICE_COLORS_SEL = {
  0x4488CC45, 0x7755AA45, 0x44AA7745, 0xAA884445,
}

local OVERVIEW_HEIGHT = 42  -- minimap height in pixels

-- ═══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════════

local ui = {
  ctx          = nil,
  is_open      = true,
  window_flags = 0,
}

local audio = {
  loaded       = false,
  samples      = nil,    -- reaper.new_array or nil
  peaks_pos    = {},     -- positive peaks for drawing
  peaks_neg    = {},     -- negative peaks
  sample_rate  = 44100,
  num_frames   = 0,
  num_channels = 1,
  item_name    = "",
  take         = nil,
  item         = nil,
}

local slicer = {
  slices       = {},     -- {pos=, endpos=, energy=} — sorted by pos
  count        = 0,
  sensitivity  = 0.5,
  mode         = 0,      -- 0=transient, 1=spectral, 2=spectral_flux
  max_slices   = 16,
  state        = "idle", -- idle, analyzing, ready, error
  selected     = -1,     -- index of selected slice (-1 = none)
  dragging     = -1,     -- index of marker being dragged (-1 = none)
  last_result_check = 0, -- time of last ExtState poll
  start_pad    = 1,      -- first pad to assign slices to (1–16)
  bpm          = 0,      -- estimated BPM from onset analysis (0 = unknown)
}

local view = {
  scroll       = 0.0,   -- 0.0–1.0, horizontal scroll position
  zoom         = 1.0,   -- 1.0 = fit whole file, higher = zoomed in
  waveform_h   = 200,   -- waveform area height in pixels
}

local pad_assign = {}  -- [1..16] = slice index or nil

-- Recalculate pad assignment based on start_pad
local function recalc_pad_assign()
  pad_assign = {}
  local avail = 16 - slicer.start_pad + 1
  for i = 1, math.min(slicer.count, avail) do
    pad_assign[slicer.start_pad + i - 1] = i
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- AUDIO LOADING
-- ═══════════════════════════════════════════════════════════════════════════════

local function load_selected_item_audio()
  if reaper.CountSelectedMediaItems(0) == 0 then return false end

  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then return false end

  local take = reaper.GetActiveTake(item)
  if not take then return false end

  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return false end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  local length = reaper.GetMediaSourceLength(src)
  if sr <= 0 or nch < 1 or length <= 0 then return false end

  local name = reaper.GetTakeName(take)

  -- Read via AudioAccessor (handles time-stretch, FX, etc.)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then return false end

  local aa_start = reaper.GetAudioAccessorStartTime(aa)
  local aa_end   = reaper.GetAudioAccessorEndTime(aa)
  local duration = aa_end - aa_start
  if duration <= 0 then
    reaper.DestroyAudioAccessor(aa)
    return false
  end

  local total_frames = math.floor(duration * sr + 0.5)
  local block_frames = math.floor(sr / 10)  -- 100ms blocks

  -- Read all audio into a flat array (mono downmix)
  local all_samples = {}
  local offset = aa_start
  local frames_read = 0

  while frames_read < total_frames do
    local to_read = math.min(block_frames, total_frames - frames_read)
    local buf = reaper.new_array(to_read * nch)
    buf.clear()

    local ret = reaper.GetAudioAccessorSamples(aa, sr, nch, offset, to_read, buf)
    if ret == 1 or ret == 0 then
      local arr = buf.table()
      for f = 0, to_read - 1 do
        local sum = 0
        for ch = 1, nch do
          sum = sum + (arr[f * nch + ch] or 0)
        end
        all_samples[#all_samples + 1] = sum / nch
      end
    else
      break
    end

    frames_read = frames_read + to_read
    offset = offset + to_read / sr
  end

  reaper.DestroyAudioAccessor(aa)

  if #all_samples == 0 then return false end

  -- Store
  audio.loaded      = true
  audio.sample_rate = sr
  audio.num_frames  = #all_samples
  audio.num_channels = nch
  audio.item_name   = name or "(unnamed)"
  audio.item        = item
  audio.take        = take

  -- Generate peaks for waveform display (downsample to ~2000 points max)
  local peak_count = math.min(2000, audio.num_frames)
  local samples_per_peak = math.max(1, math.floor(audio.num_frames / peak_count))
  audio.peaks_pos = {}
  audio.peaks_neg = {}

  for p = 1, peak_count do
    local start_idx = (p - 1) * samples_per_peak + 1
    local end_idx   = math.min(p * samples_per_peak, audio.num_frames)
    local hi, lo = -math.huge, math.huge
    for i = start_idx, end_idx do
      local s = all_samples[i] or 0
      if s > hi then hi = s end
      if s < lo then lo = s end
    end
    audio.peaks_pos[p] = hi
    audio.peaks_neg[p] = lo
  end

  -- Store raw samples for energy calculation and apply
  audio.samples = all_samples

  return true
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- ONSET DETECTION (via Extension action + ExtState)
-- ═══════════════════════════════════════════════════════════════════════════════

local function request_detection()
  if not audio.loaded then return end

  -- Write params to ExtState for the Extension to read
  reaper.SetExtState(EXTSTATE_SECTION, "sensitivity",
                     tostring(slicer.sensitivity), false)
  reaper.SetExtState(EXTSTATE_SECTION, "mode",
                     tostring(slicer.mode), false)
  reaper.SetExtState(EXTSTATE_SECTION, "max_slices",
                     tostring(slicer.max_slices), false)

  -- Clear previous state
  reaper.SetExtState(EXTSTATE_SECTION, "state", "analyzing", false)
  slicer.state = "analyzing"

  -- Fire the Extension action (logs to console, writes better C++ results)
  local cmd = reaper.NamedCommandLookup("_EON_CHOPPA_SLICE_ITEM")
  if cmd and cmd ~= 0 then
    reaper.Main_OnCommand(cmd, 0)
  end

  -- Always run Lua detection for immediate UI feedback.
  -- When the Extension writes ExtState results, poll_extension_results()
  -- will upgrade to the C++ results automatically.
  do_lua_fallback_detection()
end

-- Simple energy-based onset detection (Lua fallback when Extension is absent)
local function do_lua_fallback_detection_impl()
  if not audio.samples or #audio.samples == 0 then
    slicer.state = "error"
    return
  end

  local sr = audio.sample_rate
  local samples = audio.samples
  local n = #samples
  local min_gap = math.max(1, math.floor(slicer.sensitivity * 0.001 * sr))

  -- Simple energy envelope detection
  local window_ms = 10
  local window_samples = math.max(1, math.floor(window_ms * 0.001 * sr))
  local threshold = 0.15 - slicer.sensitivity * 0.12  -- 0.03–0.15
  local min_gap_samples = math.floor(50 * 0.001 * sr) -- 50ms min gap

  -- Compute windowed energy
  local energies = {}
  for i = 1, n, window_samples do
    local sum = 0
    local count = 0
    for j = i, math.min(i + window_samples - 1, n) do
      sum = sum + samples[j] * samples[j]
      count = count + 1
    end
    energies[#energies + 1] = { pos = i, energy = math.sqrt(sum / count) }
  end

  -- Find max energy for normalization
  local max_e = 0
  for _, e in ipairs(energies) do
    if e.energy > max_e then max_e = e.energy end
  end
  if max_e == 0 then max_e = 1 end

  -- Detect onsets: rising edges above threshold
  local onsets = { 1 }  -- always include start
  local last_onset = 1
  local prev_e = 0

  for _, e in ipairs(energies) do
    local norm = e.energy / max_e
    if norm > threshold and prev_e <= threshold then
      if e.pos - last_onset >= min_gap_samples then
        onsets[#onsets + 1] = e.pos
        last_onset = e.pos
      end
    end
    prev_e = norm
  end

  -- Trim to max_slices (keep start + highest energy)
  if #onsets > slicer.max_slices then
    -- Simple: just keep first max_slices
    local trimmed = {}
    for i = 1, slicer.max_slices do
      trimmed[i] = onsets[i]
    end
    onsets = trimmed
  end

  -- Build slice table
  slicer.slices = {}
  for i, pos in ipairs(onsets) do
    local endpos = (i < #onsets) and onsets[i + 1] or (n + 1)
    -- Compute slice energy
    local sum = 0
    local count = 0
    for j = pos, math.min(endpos - 1, n) do
      sum = sum + samples[j] * samples[j]
      count = count + 1
    end
    local rms = (count > 0) and math.sqrt(sum / count) or 0
    slicer.slices[i] = {
      pos    = pos - 1,  -- 0-based sample position
      endpos = endpos - 1,
      energy = rms,
    }
  end

  -- Normalize energies
  local max_slice_e = 0
  for _, s in ipairs(slicer.slices) do
    if s.energy > max_slice_e then max_slice_e = s.energy end
  end
  if max_slice_e > 0 then
    for _, s in ipairs(slicer.slices) do
      s.energy = s.energy / max_slice_e
    end
  end

  slicer.count = #slicer.slices
  slicer.state = "ready"

  -- Auto-assign to pads
  recalc_pad_assign()
end

-- Wrap fallback so it can be called as forward-declared
function do_lua_fallback_detection()
  do_lua_fallback_detection_impl()
end

-- Poll ExtState for results from the C++ Extension
local function poll_extension_results()
  local now = reaper.time_precise()
  if now - slicer.last_result_check < 0.05 then return end -- 20 Hz poll
  slicer.last_result_check = now

  if slicer.state ~= "analyzing" then return end

  local state = reaper.GetExtState(EXTSTATE_SECTION, "state")
  if state == "ready" then
    -- Read results
    local count = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "slice_count")) or 0
    local pos_str = reaper.GetExtState(EXTSTATE_SECTION, "positions")
    local end_str = reaper.GetExtState(EXTSTATE_SECTION, "ends")
    local energy_str = reaper.GetExtState(EXTSTATE_SECTION, "energies")

    slicer.slices = {}
    if count > 0 and pos_str ~= "" then
      local positions = {}
      for v in pos_str:gmatch("[^,]+") do positions[#positions + 1] = tonumber(v) or 0 end
      local ends = {}
      for v in end_str:gmatch("[^,]+") do ends[#ends + 1] = tonumber(v) or 0 end
      local energies_arr = {}
      for v in energy_str:gmatch("[^,]+") do energies_arr[#energies_arr + 1] = tonumber(v) or 0 end

      for i = 1, math.min(count, #positions) do
        slicer.slices[i] = {
          pos    = positions[i],
          endpos = ends[i] or audio.num_frames,
          energy = energies_arr[i] or 0,
        }
      end
    end

    slicer.count = #slicer.slices
    slicer.bpm   = tonumber(reaper.GetExtState(EXTSTATE_SECTION, "bpm")) or 0
    slicer.state = "ready"

    -- Auto-assign to pads
    recalc_pad_assign()

  elseif state == "error" then
    slicer.state = "error"
  end
end


-- ═══════════════════════════════════════════════════════════════════════════════
-- WAVEFORM DRAWING
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_waveform(ctx, draw_list, x, y, w, h)
  -- Background — light area like ReCycle
  ImGui.DrawList_AddRectFilled(draw_list, x, y, x + w, y + h, COL_WAVEFORM_BG)

  if not audio.loaded or #audio.peaks_pos == 0 then
    -- Empty state — dark text on light background
    local text = audio.loaded and "No peaks" or "Select a media item and click Load"
    local tw = ImGui.CalcTextSize(ctx, text)
    ImGui.DrawList_AddText(draw_list, x + (w - tw) / 2, y + h / 2 - 7,
                           0x666666FF, text)
    -- Border
    ImGui.DrawList_AddRect(draw_list, x, y, x + w, y + h, COL_BORDER, 0, 0, 1.0)
    return
  end

  local peak_count = #audio.peaks_pos
  local mid_y = y + h / 2

  -- Visible range based on scroll + zoom
  local visible_frac = 1.0 / view.zoom
  local scroll_frac  = view.scroll * (1.0 - visible_frac)
  local start_peak   = math.floor(scroll_frac * peak_count) + 1
  local end_peak     = math.min(math.floor((scroll_frac + visible_frac) * peak_count) + 1,
                                peak_count)
  local visible_peaks = end_peak - start_peak + 1
  if visible_peaks < 1 then return end

  local px_per_peak = w / visible_peaks

  -- ── dB amplitude grid lines ──────────────────────────────────────────
  local db_levels = { -6, -12, -18, -24 }
  for _, db in ipairs(db_levels) do
    local amp = 10 ^ (db / 20)  -- dB → linear amplitude
    local y_pos = mid_y - amp * (h / 2) * 0.95
    local y_neg = mid_y + amp * (h / 2) * 0.95
    -- Positive side
    ImGui.DrawList_AddLine(draw_list, x, y_pos, x + w, y_pos, COL_GRID_LINE, 1.0)
    -- Negative side (mirror)
    ImGui.DrawList_AddLine(draw_list, x, y_neg, x + w, y_neg, COL_GRID_LINE, 1.0)
    -- Label on left edge (positive side only)
    local label = tostring(db) .. " dB"
    ImGui.DrawList_AddText(draw_list, x + 3, y_pos - 11, COL_GRID_TEXT, label)
  end

  -- Center line (0 dB reference)
  ImGui.DrawList_AddLine(draw_list, x, mid_y, x + w, mid_y, COL_CENTER_LINE, 1.0)

  -- ── Slice region fills (behind waveform) ─────────────────────────────
  if slicer.count > 0 then
    for si, slice in ipairs(slicer.slices) do
      local s_frac = slice.pos / audio.num_frames
      local e_frac = slice.endpos / audio.num_frames
      local vis_end = scroll_frac + visible_frac
      if e_frac > scroll_frac and s_frac < vis_end then
        local rx0 = x + math.max(0, (s_frac - scroll_frac) / visible_frac * w)
        local rx1 = x + math.min(w, (e_frac - scroll_frac) / visible_frac * w)
        local ci = ((si - 1) % #SLICE_COLORS) + 1
        local col = (si == slicer.selected) and SLICE_COLORS_SEL[ci] or SLICE_COLORS[ci]
        ImGui.DrawList_AddRectFilled(draw_list, rx0, y, rx1, y + h, col)
      end
    end
  end

  -- ── Waveform peaks ───────────────────────────────────────────────────
  for i = start_peak, end_peak do
    local px = x + (i - start_peak) * px_per_peak
    local top = mid_y - audio.peaks_pos[i] * (h / 2) * 0.95
    local bot = mid_y - audio.peaks_neg[i] * (h / 2) * 0.95
    if bot - top < 1 then bot = top + 1 end
    ImGui.DrawList_AddRectFilled(draw_list, px, top, px + math.max(1, px_per_peak), bot,
                                 COL_WAVEFORM)
  end

  -- ── Slice markers ────────────────────────────────────────────────────
  for i, slice in ipairs(slicer.slices) do
    local frac = slice.pos / audio.num_frames
    if frac >= scroll_frac and frac <= scroll_frac + visible_frac then
      local mx = x + (frac - scroll_frac) / visible_frac * w
      local col = COL_MARKER
      if i == slicer.dragging then col = COL_MARKER_DRAG
      elseif i == slicer.selected then col = COL_MARKER_HOVER end

      -- Vertical line
      ImGui.DrawList_AddLine(draw_list, mx, y, mx, y + h, col, 2.0)
      -- Flag / tab at top
      ImGui.DrawList_AddTriangleFilled(draw_list,
        mx - 6, y, mx + 6, y, mx, y + 9, col)

      -- Slice number label (dark on light background)
      local label = tostring(i)
      ImGui.DrawList_AddText(draw_list, mx + 4, y + 1, COL_MARKER_LABEL, label)
    end
  end

  -- ── Border ───────────────────────────────────────────────────────────
  ImGui.DrawList_AddRect(draw_list, x, y, x + w, y + h, COL_BORDER, 0, 0, 1.0)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- WAVEFORM INTERACTION (click, drag markers)
-- ═══════════════════════════════════════════════════════════════════════════════

local function handle_waveform_input(ctx, x, y, w, h)
  if not audio.loaded or slicer.count == 0 then return end

  local mx, my = ImGui.GetMousePos(ctx)
  if mx < x or mx > x + w or my < y or my > y + h then
    return
  end

  local visible_frac = 1.0 / view.zoom
  local scroll_frac  = view.scroll * (1.0 - visible_frac)

  -- Convert mouse X to sample position
  local frac = scroll_frac + (mx - x) / w * visible_frac
  local sample_pos = math.floor(frac * audio.num_frames)

  -- Find nearest marker (within 8 pixels)
  local nearest_idx = -1
  local nearest_dist = 999999

  for i, slice in ipairs(slicer.slices) do
    if i > 1 then  -- don't allow dragging the first marker (always at 0)
      local marker_frac = slice.pos / audio.num_frames
      local marker_px = x + (marker_frac - scroll_frac) / visible_frac * w
      local dist = math.abs(mx - marker_px)
      if dist < 8 and dist < nearest_dist then
        nearest_dist = dist
        nearest_idx = i
      end
    end
  end

  -- Hover cursor change
  if nearest_idx > 0 then
    ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_ResizeEW)
  end

  -- Click to select slice
  if ImGui.IsMouseClicked(ctx, 0) then
    if nearest_idx > 0 then
      slicer.dragging = nearest_idx
      slicer.selected = nearest_idx
    else
      -- Click in a slice region — select that slice
      for i, slice in ipairs(slicer.slices) do
        if sample_pos >= slice.pos and sample_pos < slice.endpos then
          slicer.selected = i
          break
        end
      end
    end
  end

  -- Drag marker
  if slicer.dragging > 0 and ImGui.IsMouseDown(ctx, 0) then
    local new_pos = math.max(0, math.min(audio.num_frames - 1, sample_pos))

    -- Clamp: can't go past adjacent markers
    local prev_pos = (slicer.dragging > 1) and
      (slicer.slices[slicer.dragging - 1].pos + 1) or 0
    local next_pos = (slicer.dragging < slicer.count) and
      (slicer.slices[slicer.dragging + 1].pos - 1) or (audio.num_frames - 1)
    new_pos = math.max(prev_pos, math.min(next_pos, new_pos))

    slicer.slices[slicer.dragging].pos = new_pos
    -- Update previous slice's endpos
    if slicer.dragging > 1 then
      slicer.slices[slicer.dragging - 1].endpos = new_pos
    end
  end

  -- Release drag
  if slicer.dragging > 0 and ImGui.IsMouseReleased(ctx, 0) then
    slicer.dragging = -1
  end

  -- Right-click: delete marker (if not first)
  if ImGui.IsMouseClicked(ctx, 1) and nearest_idx > 1 then
    table.remove(slicer.slices, nearest_idx)
    slicer.count = #slicer.slices
    -- Fix endpos of previous slice
    if nearest_idx > 1 and nearest_idx <= #slicer.slices + 1 then
      local prev = nearest_idx - 1
      slicer.slices[prev].endpos =
        (prev < #slicer.slices) and slicer.slices[prev + 1].pos or audio.num_frames
    end
    -- Re-assign pads
    recalc_pad_assign()
    slicer.selected = -1
  end

  -- Double-click: add marker at position
  if ImGui.IsMouseDoubleClicked(ctx, 0) and nearest_idx < 0 then
    -- Insert new onset at sample_pos
    local insert_at = #slicer.slices + 1
    for i, slice in ipairs(slicer.slices) do
      if slice.pos > sample_pos then
        insert_at = i
        break
      end
    end

    if #slicer.slices < 16 then
      local new_slice = {
        pos    = sample_pos,
        endpos = (insert_at <= #slicer.slices) and
                  slicer.slices[insert_at].pos or audio.num_frames,
        energy = 0.5,
      }
      table.insert(slicer.slices, insert_at, new_slice)
      -- Fix previous slice endpos
      if insert_at > 1 then
        slicer.slices[insert_at - 1].endpos = sample_pos
      end
      slicer.count = #slicer.slices
      -- Re-assign pads
      recalc_pad_assign()
    end
  end

  -- Mouse wheel: zoom
  local wheel = ImGui.GetMouseWheel(ctx) or 0
  if wheel ~= 0 then
    local old_zoom = view.zoom
    view.zoom = math.max(1.0, math.min(64.0, view.zoom * (1 + wheel * 0.15)))
    -- Keep mouse position stable during zoom
    local mouse_frac = (mx - x) / w
    local old_start = view.scroll * (1.0 - 1.0 / old_zoom)
    local new_visible = 1.0 / view.zoom
    local new_start = old_start + mouse_frac * (1.0 / old_zoom - new_visible)
    view.scroll = (view.zoom > 1.0) and
                  math.max(0, math.min(1, new_start / (1.0 - new_visible))) or 0
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONTROLS PANEL
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_controls(ctx)
  ImGui.Separator(ctx)

  -- Load button
  if ImGui.Button(ctx, "Load Selected Item", 155, 26) then
    if load_selected_item_audio() then
      request_detection()
    end
  end
  ImGui.SameLine(ctx)

  -- Status
  local status_text = "Idle"
  local status_col = 0x888888FF
  if slicer.state == "analyzing" then
    status_text = "Analyzing..."
    status_col = 0xFFCC44FF
  elseif slicer.state == "ready" then
    status_text = slicer.count .. " slices"
    status_col = 0x44DD44FF
  elseif slicer.state == "error" then
    status_text = "Error"
    status_col = 0xFF4444FF
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, status_col)
  ImGui.Text(ctx, status_text)
  ImGui.PopStyleColor(ctx)

  ImGui.SameLine(ctx, 0, 20)

  -- Item name
  if audio.loaded then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xAAAAAAFF)
    ImGui.Text(ctx, audio.item_name)
    ImGui.PopStyleColor(ctx)
  end

  ImGui.Spacing(ctx)

  -- Sensitivity slider
  ImGui.SetNextItemWidth(ctx, 200)
  local changed_sens, new_sens = ImGui.SliderDouble(ctx, "Sensitivity",
    slicer.sensitivity, 0.0, 1.0, "%.2f")
  if changed_sens then
    slicer.sensitivity = new_sens
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and audio.loaded then
    request_detection()
  end

  ImGui.SameLine(ctx, 0, 20)

  -- Mode toggle
  local mode_labels = { "Transient", "Spectral", "Spectral Flux" }
  ImGui.SetNextItemWidth(ctx, 140)
  local changed_mode, new_mode = ImGui.Combo(ctx, "Mode",
    slicer.mode, "Transient\0Spectral\0Spectral Flux\0")
  if changed_mode then
    slicer.mode = new_mode
    if audio.loaded then request_detection() end
  end

  ImGui.SameLine(ctx, 0, 20)

  -- Max slices spinner
  ImGui.SetNextItemWidth(ctx, 80)
  local changed_max, new_max = ImGui.SliderInt(ctx, "Max Slices",
    slicer.max_slices, 2, 16)
  if changed_max then
    slicer.max_slices = new_max
  end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) and audio.loaded then
    request_detection()
  end

  ImGui.SameLine(ctx, 0, 20)

  -- Re-detect button
  if ImGui.Button(ctx, "Re-detect", 85, 26) then
    if audio.loaded then request_detection() end
  end

  ImGui.SameLine(ctx, 0, 20)

  -- Start Pad picker
  ImGui.SetNextItemWidth(ctx, 80)
  local changed_sp, new_sp = ImGui.SliderInt(ctx, "Start Pad",
    slicer.start_pad, 1, 16)
  if changed_sp then
    slicer.start_pad = new_sp
    recalc_pad_assign()
  end

  -- BPM display (from onset-based tempo estimation)
  if slicer.bpm > 0 then
    ImGui.SameLine(ctx, 0, 25)
    ImGui.Text(ctx, string.format("%.1f BPM", slicer.bpm))
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- PAD ASSIGNMENT ROW
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_pad_row(ctx)
  ImGui.Separator(ctx)
  ImGui.Text(ctx, "Pad Assignment:  (click empty pad to set start)")
  ImGui.Spacing(ctx)

  local pad_size = 48
  local pad_gap  = 4

  for p = 1, 16 do
    if p > 1 then ImGui.SameLine(ctx, 0, pad_gap) end

    local slice_idx = pad_assign[p]
    local has_slice = slice_idx and slicer.slices[slice_idx]
    local is_selected = slicer.selected == slice_idx

    local bg_col = COL_PAD_EMPTY
    if has_slice then
      bg_col = is_selected and COL_PAD_PLAYING or COL_PAD_FILLED
    end

    ImGui.PushStyleColor(ctx, ImGui.Col_Button, bg_col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,
      has_slice and 0x4A5A72FF or 0x3A3A42FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, COL_PAD_PLAYING)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 4.0)

    -- Show pad number + slice index (or just pad number)
    local label = has_slice
      and (tostring(p) .. "\n S" .. tostring(slice_idx))
      or tostring(p)
    if ImGui.Button(ctx, label .. "##pad" .. p, pad_size, pad_size) then
      if has_slice then
        slicer.selected = slice_idx
      else
        -- Click empty pad → set it as start pad
        slicer.start_pad = p
        recalc_pad_assign()
      end
    end

    ImGui.PopStyleVar(ctx, 1)
    ImGui.PopStyleColor(ctx, 3)

    -- Energy bar under each pad
    if has_slice then
      local slice = slicer.slices[slice_idx]
      local cx, cy = ImGui.GetItemRectMin(ctx)
      local cw = pad_size
      local bar_h = 3
      local bar_y = cy + pad_size + 1
      local draw_list = ImGui.GetWindowDrawList(ctx)
      ImGui.DrawList_AddRectFilled(draw_list,
        cx, bar_y, cx + cw * slice.energy, bar_y + bar_h, COL_ENERGY_BAR)
    end

    -- Tooltip
    if ImGui.IsItemHovered(ctx) and has_slice then
      local slice = slicer.slices[slice_idx]
      local dur_ms = (slice.endpos - slice.pos) / audio.sample_rate * 1000
      ImGui.SetTooltip(ctx, string.format(
        "Pad %d: Slice %d\nStart: %d samples\nDuration: %.1f ms\nEnergy: %.0f%%",
        p, slice_idx, slice.pos, dur_ms, slice.energy * 100))
    end
  end

  ImGui.Spacing(ctx)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY ADAPTERS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Slice push — modern per-pad path loads (CMD 63).
--
-- Choppa originally staged packed audio + META in gmem and fired the CMD=3
-- kit import (the pre-VER-200 protocol). Today the kit import routes on
-- KIT_GMEM_VER: after any bridge load the KIT_GMEM_AUDIO band holds file
-- PATHS (VER-201) or is a blob scratch window (VER-26), and the AUDIOLEN
-- band is blast-published by the JSFX every @block — so raw-gmem staging is
-- dead protocol (verified live 2026-07-16: the VER-201 import treated the
-- staged audio as paths and blanked the pushed pad). The supported route for
-- "Lua PCM → one pad, others untouched" is the browser-drop channel: write
-- each slice as a WAV into the sample store (same dir layout as the bridge's
-- chop pump) and post CMD 63 per pad. clear_pad + load + naming + undo
-- (mark_dirty_pad) all happen JSFX-side; unassigned pads are never touched.
-- On first project save the bridge migrates unsaved-store chop WAVs into the
-- project store (CMD-86 flow) via the manifest written below.

local push = {
  queue   = {},     -- pending { pad=, path=, tries= } items
  active  = false,
  inst_id = 0,
  sent    = 0,
  state   = "idle", -- per-item: post → wait → settle
  at      = 0,      -- time_precise stamp for wait/settle deadlines
}

-- Slice → 16-bit stereo WAV (mono duplicated to L+R — byte-identical format
-- to the bridge chop pump / kit store WAVs).
local function write_slice_wav(path, sr, mono, s0, len)
  local pieces, j = {}, 0
  while j < len do
    local n = math.min(2048, len - j)
    local vals = {}
    for k = 1, n do
      local v = mono[s0 + j + k - 1] or 0
      if v > 1 then v = 1 elseif v < -1 then v = -1 end
      local q = math.floor(v * 32767 + 0.5)
      vals[k * 2 - 1] = q
      vals[k * 2]     = q
    end
    pieces[#pieces + 1] = string.pack("<" .. ("i2"):rep(n * 2), table.unpack(vals))
    j = j + n
  end
  local data = table.concat(pieces)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write("RIFF", string.pack("<I4", 36 + #data), "WAVEfmt ",
    string.pack("<I4I2I2I4I4I2I2", 16, 1, 2, sr, sr * 4, 4, 16),
    "data", string.pack("<I4", #data), data)
  f:close()
  return true
end

-- <projdir>/Swing/samples for saved projects, else the persistent unsaved
-- store (mirrors the bridge's eon_store_root; NOT %TEMP% — that is swept on
-- exit). Second return: true when the unsaved store was used.
local function store_root()
  local _, projfn = reaper.EnumProjects(-1)
  if projfn and projfn ~= "" then
    local proj_dir = projfn:match("(.*[/\\])")
    if proj_dir then return proj_dir .. "Swing/samples", false end
  end
  return reaper.GetResourcePath() .. "/Data/EON_Swing/unsaved", true
end

-- True if inst_id currently owns a live instance-registry slot.
local function registry_live(inst_id)
  if not inst_id or inst_id <= 0 then return false end
  local now = reaper.time_precise()
  for i = 0, GS_INST_REG_MAX - 1 do
    local slot = GS_INST_REG_BASE + i * GS_INST_REG_STRIDE
    if math.floor(reaper.gmem_read(slot + core.GMEM.GS_INST_REG_OFF_ID) or 0) == inst_id then
      local hb = reaper.gmem_read(slot + core.GMEM.GS_INST_REG_OFF_HEARTBEAT) or 0
      return (now - hb) <= GS_INST_REG_TIMEOUT
    end
  end
  return false
end

-- Swing JSFX detector — same conditions as the bridge's is_swing_fx.
local function is_swing_fx(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if retval and ident:find("DrumKit_ReaKit") then return true end
  if fname:find("DrumKit_ReaKit") then return true end
  if fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad") then return true end
  return false
end

-- Track-GUID token of the target Swing (chop-dir naming — same convention as
-- the bridge so first-save migration and the 30-day sweep treat these WAVs
-- exactly like bridge chops).
local function target_guid_token(inst_id)
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx)
         and math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0) == inst_id then
        local tok = (reaper.GetTrackGUID(tr) or ""):gsub("[^%w]", "")
        if tok ~= "" then return tok end
      end
    end
  end
  return "choppa"
end

-- Find the first live Swing JSFX instance from the instance registry
local function find_swing_instance_id()
  local now = reaper.time_precise()
  for i = 0, GS_INST_REG_MAX - 1 do
    local slot = GS_INST_REG_BASE + i * GS_INST_REG_STRIDE
    local id = math.floor(reaper.gmem_read(slot + core.GMEM.GS_INST_REG_OFF_ID))
    local hb = reaper.gmem_read(slot + core.GMEM.GS_INST_REG_OFF_HEARTBEAT)
    if id > 0 and (now - hb) <= GS_INST_REG_TIMEOUT then
      return id
    end
  end
  return 0
end

local function apply_to_swing_pads()
  if slicer.count == 0 or not audio.loaded then return end
  if push.active then
    reaper.ShowConsoleMsg("EON Choppa: previous send still in progress\n")
    return
  end

  reaper.gmem_attach(core.GMEM_NAME)
  local G = core.GMEM

  -- Check Bridge is alive
  if math.floor(reaper.gmem_read(G.BRIDGE_ALIVE)) == 0 then
    reaper.ShowConsoleMsg("EON Choppa: Swing Bridge not running. "
      .. "Load Swing on a track and ensure Kit Bridge is active.\n")
    return
  end

  -- Target: the browser-picked instance when it's alive (so a multi-Swing
  -- session sends to the user's pick), else the first live registry entry.
  local target_inst = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  if not registry_live(target_inst) then target_inst = find_swing_instance_id() end
  if target_inst == 0 then
    reaper.ShowConsoleMsg("EON Choppa: No live Swing instance found in registry.\n")
    return
  end

  local base_name = audio.item_name:gsub("[^%w%-_ ]", "")
  if base_name == "" then base_name = "Choppa" end
  local fsbase = base_name:gsub("[^%w%-]", "_"):sub(1, 24)

  local root, unsaved = store_root()
  local dir = root .. "/chops/" .. target_guid_token(target_inst)
  reaper.RecursiveCreateDirectory(dir, 0)
  local gen = os.time()

  -- Write one WAV per assigned pad + build the CMD 63 queue.
  local queue = {}
  for pad_num = 1, G.NUM_PADS do
    local slice_idx = pad_assign[pad_num]
    local slice = slice_idx and slicer.slices[slice_idx]
    if slice then
      local pad_idx = pad_num - 1
      local ss = slice.pos + 1      -- 1-based Lua index
      local se = math.min(slice.endpos, audio.num_frames)
      local slen = se - ss + 1
      if slen > 0 then
        slen = math.min(slen, math.floor(G.SLOT_SIZE / 2))
        local path = ("%s/pad%02d_g%d_%s.wav"):format(dir, pad_idx, gen, fsbase)
        if #path >= G.GS_BROWSER_PATH_MAX then
          reaper.ShowConsoleMsg("EON Choppa: store path too long for pad load:\n  "
            .. path .. "\n")
          return
        end
        if not write_slice_wav(path, audio.sample_rate, audio.samples, ss, slen) then
          reaper.ShowConsoleMsg("EON Choppa: WAV write failed: " .. path .. "\n")
          return
        end
        queue[#queue + 1] = { pad = pad_idx, path = path, tries = 0 }
      end
    end
  end

  if #queue == 0 then
    reaper.ShowConsoleMsg("EON Choppa: No slices to send\n")
    return
  end

  -- Store housekeeping: LRU stamp for the 30-day sweep + (unsaved store
  -- only) a manifest so the bridge's first-save migration finds the WAVs.
  local sf = io.open(dir .. "/.eon_stamp", "wb")
  if sf then sf:write(tostring(gen)); sf:close() end
  if unsaved then
    local mf = io.open(dir .. "/manifest.lua", "w")
    if mf then
      local _, projfn = reaper.EnumProjects(-1)
      mf:write("return {\n  created = ", tostring(gen),
               ",\n  proj = ", string.format("%q", projfn or ""), ",\n  files = {\n")
      for _, it in ipairs(queue) do mf:write(string.format("    %q,\n", it.path)) end
      mf:write("  },\n}\n")
      mf:close()
    end
  end

  push.queue   = queue
  push.active  = true
  push.inst_id = target_inst
  push.sent    = 0
  push.state   = "post"
  push.at      = reaper.time_precise()
  reaper.ShowConsoleMsg(("EON Choppa: sending %d slice(s) to Swing instance %d\n")
    :format(#queue, target_inst))
end

-- Per-tick driver for the CMD 63 queue (called from the main defer loop).
--   post   — stage path + pad and post CMD 63 (only when the bus is idle).
--   wait   — the JSFX consumed the load when CMD returns to 0.
--   settle — one beat for the @block AUDIOLEN republish, then verify the
--            audio landed. Transient file-open failures (AV/indexer holding
--            a just-written WAV) get up to 2 re-posts — same heal as the
--            bridge chop pump's verify phase.
-- CMD 63 consumes only on the browser-target instance, so INSTANCE is
-- pointed at the target before each post (also flips the AUDIOLEN mirror
-- to that instance, which the landed-check reads).
local function pump_push()
  if not push.active then return end
  local G = core.GMEM
  local now = reaper.time_precise()
  local item = push.queue[1]

  if not item then
    push.active = false
    reaper.ShowConsoleMsg(("EON Choppa: Sent %d slice(s) to Swing pads "
      .. "(unassigned pads untouched)\n"):format(push.sent))
    return
  end

  if push.state == "post" then
    if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then
      if now - push.at > 5.0 then
        push.active = false
        reaper.ShowConsoleMsg("EON Choppa: Swing command bus busy — send aborted\n")
      end
      return
    end
    reaper.gmem_write(G.INSTANCE, push.inst_id)
    for i = 0, #item.path - 1 do
      reaper.gmem_write(G.GS_BROWSER_PATH + i, item.path:byte(i + 1))
    end
    reaper.gmem_write(G.GS_BROWSER_PATH_LEN, #item.path)
    reaper.gmem_write(G.GS_BROWSE_PAD, item.pad)
    reaper.gmem_write(G.CMD, 63)
    push.state, push.at = "wait", now

  elseif push.state == "wait" then
    if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then
      if now - push.at > 5.0 then
        push.active = false
        reaper.ShowConsoleMsg(("EON Choppa: pad %d load not consumed — send aborted\n")
          :format(item.pad))
      end
      return
    end
    push.state, push.at = "settle", now

  elseif push.state == "settle" then
    if now - push.at < 0.25 then return end
    -- AUDIOLEN republish: >1 = real length, 1 = layered sentinel, 0 = blank
    if math.floor(reaper.gmem_read(G.AUDIOLEN_BASE + item.pad) or 0) > 1 then
      push.sent = push.sent + 1
      table.remove(push.queue, 1)
      push.state, push.at = "post", now
    elseif item.tries < 2 then
      item.tries = item.tries + 1
      reaper.ShowConsoleMsg(("EON Choppa: pad %d blank after load — retry %d\n")
        :format(item.pad, item.tries))
      push.state, push.at = "post", now
    else
      reaper.ShowConsoleMsg(("EON Choppa: pad %d still blank after retries — "
        .. "check disk/AV\n"):format(item.pad))
      table.remove(push.queue, 1)
      push.state, push.at = "post", now
    end
  end
end

local function apply_export_wavs()
  if slicer.count == 0 or not audio.loaded or not audio.take then return end

  local retval, folder = reaper.JS_Dialog_BrowseForFolder and
    reaper.JS_Dialog_BrowseForFolder("Select export folder", "") or false, ""

  if not retval or folder == "" then
    -- Fallback: use project path
    local proj_path = reaper.GetProjectPathEx(0)
    folder = proj_path .. core.sep .. "Choppa_Export"
    reaper.RecursiveCreateDirectory(folder, 0)
  end

  -- Write each slice with the same writer the Apply-to-pads path uses
  -- (write_slice_wav: 16-bit stereo RIFF from the decoded mono buffer). The
  -- samples are already in memory from the load, so no AudioAccessor pass is
  -- needed here. This used to log filenames and print "Export complete"
  -- without writing anything.
  local base    = audio.item_name:gsub("[^%w%-_]", "_")
  local written, failed = 0, {}
  for i, slice in ipairs(slicer.slices) do
    local ss   = slice.pos + 1                                  -- 1-based
    local se   = math.min(slice.endpos, audio.num_frames)
    local slen = se - ss + 1
    if slen > 0 then
      local path = string.format("%s%s%s_slice_%02d.wav", folder, core.sep, base, i)
      if write_slice_wav(path, audio.sample_rate, audio.samples, ss, slen) then
        written = written + 1
      else
        failed[#failed + 1] = path
      end
    end
  end

  -- Only ever report what actually happened. A failure here is a real disk or
  -- permission problem the user has to see, so it is not gated.
  if #failed > 0 then
    reaper.ShowConsoleMsg(("EON Choppa: exported %d of %d slice(s) to %s — %d FAILED:\n")
      :format(written, slicer.count, folder, #failed))
    for _, p in ipairs(failed) do reaper.ShowConsoleMsg("  " .. p .. "\n") end
  else
    reaper.MB(("Exported %d slice%s to:\n\n%s"):format(
      written, written == 1 and "" or "s", folder), "EON Choppa", 0)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- APPLY BUTTONS
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_apply_buttons(ctx)
  ImGui.Separator(ctx)

  local can_apply = slicer.count > 0 and audio.loaded

  if not can_apply then ImGui.BeginDisabled(ctx) end

  -- Primary action — highlighted blue
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0x1166BBFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x2288DDFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, 0x0055AAFF)
  if ImGui.Button(ctx, "Apply to Swing Pads", 170, 30) then
    apply_to_swing_pads()
  end
  ImGui.PopStyleColor(ctx, 3)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Write slices to the sample store and load them\n"
      .. "onto the assigned Swing pads (other pads untouched)")
  end

  ImGui.SameLine(ctx, 0, 10)

  if ImGui.Button(ctx, "Export WAVs", 120, 30) then
    apply_export_wavs()
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Export each slice as a separate WAV file")
  end

  if not can_apply then ImGui.EndDisabled(ctx) end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- OVERVIEW MINIMAP
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_overview(ctx, draw_list, x, y, w, h)
  -- Background — slightly darker than waveform for visual separation
  ImGui.DrawList_AddRectFilled(draw_list, x, y, x + w, y + h, COL_OVERVIEW_BG)

  if not audio.loaded or #audio.peaks_pos == 0 then
    ImGui.DrawList_AddRect(draw_list, x, y, x + w, y + h, COL_BORDER, 0, 0, 1.0)
    return
  end

  local peak_count = #audio.peaks_pos
  local mid_y = y + h / 2
  local px_per_peak = w / peak_count

  -- Slice region fills (always show the full file)
  if slicer.count > 0 then
    for si, slice in ipairs(slicer.slices) do
      local s_frac = slice.pos / audio.num_frames
      local e_frac = slice.endpos / audio.num_frames
      local rx0 = x + s_frac * w
      local rx1 = x + e_frac * w
      local ci = ((si - 1) % #SLICE_COLORS) + 1
      local col = (si == slicer.selected) and SLICE_COLORS_SEL[ci] or SLICE_COLORS[ci]
      ImGui.DrawList_AddRectFilled(draw_list, rx0, y, rx1, y + h, col)
    end
  end

  -- Miniature waveform (full file)
  for i = 1, peak_count do
    local px = x + (i - 1) * px_per_peak
    local top = mid_y - audio.peaks_pos[i] * (h / 2) * 0.85
    local bot = mid_y - audio.peaks_neg[i] * (h / 2) * 0.85
    if bot - top < 1 then bot = top + 1 end
    ImGui.DrawList_AddRectFilled(draw_list, px, top,
      px + math.max(1, px_per_peak), bot, COL_OVERVIEW_WAVE)
  end

  -- Slice marker ticks
  for _, slice in ipairs(slicer.slices) do
    local frac = slice.pos / audio.num_frames
    local mx = x + frac * w
    ImGui.DrawList_AddLine(draw_list, mx, y, mx, y + h, COL_MARKER, 1.0)
  end

  -- Viewport rectangle (shows what the main waveform is displaying)
  if view.zoom > 1.0 then
    local vis_frac = 1.0 / view.zoom
    local scroll_frac = view.scroll * (1.0 - vis_frac)
    local vx0 = x + scroll_frac * w
    local vx1 = x + (scroll_frac + vis_frac) * w
    ImGui.DrawList_AddRectFilled(draw_list, vx0, y, vx1, y + h, COL_OVERVIEW_VP)
    ImGui.DrawList_AddRect(draw_list, vx0, y, vx1, y + h, COL_OVERVIEW_VPBR, 0, 0, 1.5)
  end

  -- Border
  ImGui.DrawList_AddRect(draw_list, x, y, x + w, y + h, COL_BORDER, 0, 0, 1.0)
end

-- Handle click-to-scroll on the overview minimap
local function handle_overview_input(ctx, x, y, w, h)
  if not audio.loaded or view.zoom <= 1.0 then return end

  local mx, my = ImGui.GetMousePos(ctx)
  if mx < x or mx > x + w or my < y or my > y + h then return end

  if ImGui.IsMouseDown(ctx, 0) then
    local frac = (mx - x) / w
    local vis_frac = 1.0 / view.zoom
    local start = frac - vis_frac / 2
    local max_scroll = 1.0 - vis_frac
    if max_scroll > 0 then
      view.scroll = math.max(0, math.min(1, start / max_scroll))
    end
  end

  -- Mouse wheel zoom on overview too
  local wheel = ImGui.GetMouseWheel(ctx) or 0
  if wheel ~= 0 then
    view.zoom = math.max(1.0, math.min(64.0, view.zoom * (1 + wheel * 0.15)))
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- SCROLL BAR
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_scrollbar(ctx)
  if view.zoom <= 1.0 then return end

  ImGui.SetNextItemWidth(ctx, -1)
  local changed, new_scroll = ImGui.SliderDouble(ctx, "##scroll",
    view.scroll, 0.0, 1.0, "")
  if changed then
    view.scroll = new_scroll
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MAIN FRAME
-- ═══════════════════════════════════════════════════════════════════════════════

local function frame()
  -- Poll for Extension results
  poll_extension_results()

  -- Window setup
  ImGui.SetNextWindowSize(ui.ctx, 960, 580, ImGui.Cond_Appearing)
  ImGui.SetNextWindowSizeConstraints(ui.ctx, 640, 420, 99999, 99999)

  ImGui.PushStyleColor(ui.ctx, ImGui.Col_WindowBg, 0x1E1E24FF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_TitleBg, 0x14141CFF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_TitleBgActive, 0x1A2030FF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_Button, 0x2A3A50FF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_ButtonHovered, 0x3A5070FF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_ButtonActive, 0x1177DDFF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_SliderGrab, 0x1177DDFF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_SliderGrabActive, 0x33AAFFFF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_FrameBg, 0x2A2A34FF)
  ImGui.PushStyleColor(ui.ctx, ImGui.Col_FrameBgHovered, 0x3A3A48FF)
  ImGui.PushStyleVar(ui.ctx, ImGui.StyleVar_WindowRounding, 4.0)
  ImGui.PushStyleVar(ui.ctx, ImGui.StyleVar_FrameRounding, 3.0)

  local visible, open = ImGui.Begin(ui.ctx,
    SCRIPT_NAME .. " v" .. VERSION .. "###eon_choppa", true,
    ImGui.WindowFlags_NoCollapse)

  ImGui.PopStyleVar(ui.ctx, 2)
  ImGui.PopStyleColor(ui.ctx, 10)

  ui.is_open = open

  if visible then
    -- Controls (top)
    draw_controls(ui.ctx)

    ImGui.Spacing(ui.ctx)

    -- Waveform area (fills available width, fixed height)
    local avail_w = ImGui.GetContentRegionAvail(ui.ctx)
    view.waveform_h = math.max(120, math.min(400,
      select(2, ImGui.GetContentRegionAvail(ui.ctx)) - 220))

    local cx, cy = ImGui.GetCursorScreenPos(ui.ctx)

    -- Reserve space for the waveform
    ImGui.Dummy(ui.ctx, avail_w, view.waveform_h)

    local draw_list = ImGui.GetWindowDrawList(ui.ctx)
    draw_waveform(ui.ctx, draw_list, cx, cy, avail_w, view.waveform_h)
    handle_waveform_input(ui.ctx, cx, cy, avail_w, view.waveform_h)

    -- Scrollbar (only when zoomed)
    draw_scrollbar(ui.ctx)

    -- Overview minimap (full waveform with viewport indicator)
    ImGui.Spacing(ui.ctx)
    local ov_x, ov_y = ImGui.GetCursorScreenPos(ui.ctx)
    ImGui.Dummy(ui.ctx, avail_w, OVERVIEW_HEIGHT)
    draw_overview(ui.ctx, draw_list, ov_x, ov_y, avail_w, OVERVIEW_HEIGHT)
    handle_overview_input(ui.ctx, ov_x, ov_y, avail_w, OVERVIEW_HEIGHT)

    -- Pad assignment row
    draw_pad_row(ui.ctx)

    -- Apply buttons (bottom)
    draw_apply_buttons(ui.ctx)

    ImGui.End(ui.ctx)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════════════════

local function cleanup()
  -- Clear ExtState on exit
  reaper.DeleteExtState(EXTSTATE_SECTION, "state", false)
  reaper.DeleteExtState(EXTSTATE_SECTION, "sensitivity", false)
  reaper.DeleteExtState(EXTSTATE_SECTION, "mode", false)
  reaper.DeleteExtState(EXTSTATE_SECTION, "max_slices", false)
end

local function init()
  ui.ctx = ImGui.CreateContext(SCRIPT_NAME)
  widgets.init(ImGui, core)
end

local loop

loop = function()
  local ok, err = xpcall(function()
    pump_push()   -- drive any in-flight CMD 63 slice sends
    frame()
  end, debug.traceback)
  if not ok then
    reaper.ShowConsoleMsg("\n[EON CHOPPA ERROR]\n" .. tostring(err) .. "\n")
    cleanup()
    return
  end
  if ui.is_open then
    reaper.defer(loop)
  else
    cleanup()
  end
end

local function main()
  init()
  reaper.atexit(cleanup)
  reaper.defer(loop)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  reaper.ShowConsoleMsg("\n[EON CHOPPA INIT ERROR]\n" .. tostring(err) .. "\n")
end
