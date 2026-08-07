-- ReaKit Lua Widgets — Shared ImGui UI Components
-- (c) EON Studios — All Rights Reserved
--
-- Theme system, waveform display, pad grid, and reusable UI widgets
-- for all EON ImGui-based scripts.
--
-- Usage:
--   local core    = dofile(script_dir .. sep .. "rk_lua_core.lua")
--   local widgets = dofile(script_dir .. sep .. "rk_lua_widgets.lua")
--   widgets.init(ImGui, core)

local w = {}
local ImGui, core  -- set by init()

-- Shared theme module (REAPER-derivation source of truth). Safe require so a
-- missing file never breaks the widget lib — the "reaper" theme just falls back.
local ok_theme, rktheme = pcall(require, "rk_lua_theme")
if not ok_theme then rktheme = nil end

-- JSFX knob-skin parity (same-named ports of knobs_kbsg.jsfx-inc). Safe require so
-- a missing file falls back to the built-in flat dial instead of breaking the UI.
local ok_knobs, rkknobs = pcall(require, "rk_lua_knobs")
if not ok_knobs then rkknobs = nil end

-- Cache the derived REAPER palette per (file, mode); re-derive only when the
-- active theme FILE or the chosen mode changes (REAPER fires no theme-changed
-- event — snapshot per TK Workbench). mode = "balanced"|"panel"|"color".
local _reaper_pal, _reaper_key = {}, nil
local function reaper_palette(mode)
  mode = mode or "balanced"
  local f = reaper.GetLastColorThemeFile and reaper.GetLastColorThemeFile() or ""
  local key = f .. "|" .. mode
  if key ~= _reaper_key then
    _reaper_pal[mode] = rktheme and rktheme.make_reaper(mode) or nil
    _reaper_key = key
  end
  return _reaper_pal[mode]
end
-- The three REAPER theme entries map to TK derivation modes (matches TK Workbench).
local function _reaper_mode_of(theme)
  return theme == "reaper_panel" and "panel" or (theme == "reaper_color" and "color" or "balanced")
end

function w.init(_ImGui, _core)
  ImGui = _ImGui
  core  = _core
  if rkknobs then rkknobs.init(_ImGui) end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- NAMED COLORS
-- ═══════════════════════════════════════════════════════════════════════════════

w.colors = {
  accent         = 0xFF8C32FF,
  accent_fill    = 0x40C8FFBB,
  accent_edge    = 0x40C8FFDD,
  -- TK Media Browser-matched waveform color: deeper saturated blue at
  -- full opacity. Avoids the soft "bleed-through" look our older cyan
  -- @ 0xBB alpha had vs TK's solid waveform render.
  waveform_blue  = 0x32A0E1FF,
  swing_red      = 0xD9331DFF,
  text_gold      = 0xFFCC44FF,
  status_ok      = 0x50C878FF,
  status_err     = 0xCC4444FF,
  text_info      = 0xBBBBC0FF,
  text_dim       = 0x8C8C96FF,
  text_muted     = 0x6C6C76FF,
  pad_empty      = 0x38383FFF,
  border_default = 0x414148FF,
  white          = 0xFFFFFFFF,
  position_line  = 0xFFFFFFFF,
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- THEME
-- ═══════════════════════════════════════════════════════════════════════════════

local THEME_COLOR_COUNT = 27
local THEME_VAR_COUNT   = 5

-- Apply a semantic palette (bg/panel/text/text_dim/accent/accent2/grid/border)
-- as the 27 ImGui style colours. Shared by the REAPER-derived theme and the
-- console themes (SSL/Neve/API/Witti/Tube) so the mapping lives in ONE place.
function w._apply_semantic(ctx, p)
  local bg, panel, text, tdim = p.bg, p.panel, p.text, p.text_dim
  local acc, acc2, grid, bord = p.accent, p.accent2, p.grid, p.border
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,            bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg,             bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,             panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border,              bord)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,             panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered,      acc2)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,       acc)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,             panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,       acc2)
  ImGui.PushStyleColor(ctx, ImGui.Col_Header,              panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered,       acc2)
  ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,        acc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,              panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,       acc2)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,        acc)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,               text)
  ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled,        tdim)
  ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,         bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,       grid)
  ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabHovered, acc2)
  ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabActive,  acc)
  ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,       panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong,   bord)
  ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight,    grid)
  ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,          bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,       panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_Separator,           grid)
end

function w.push_theme(ctx, theme)
  if theme == "light" then
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         0xF0F0F2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg,          0xF0F0F2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          0xE8E8ECFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,           0xC0C0C8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,          0xE0E0E5FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered,   0xD0D0D8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,    0xC0C0CCFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          0xDCDCE2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    0xD0D0D8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header,           0xD8D8E0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered,    0xC8C8D4FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,     0xB8B8C8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,           0xD5D5DCFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,    0xC5C5D0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,     0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,             0x222228FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled,     0x888890FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,      0xE8E8ECFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,    0xB8B8C0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabHovered, 0xA0A0AAFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabActive,  0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    0xDCDCE2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong, 0xC0C0C8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight,  0xD0D0D8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,        0xF0F0F2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,     0xE8E8ECFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,         0xC0C0C8FF)
  elseif theme == "eon" then
    -- EON cream — pinned 1:1 to the Swing JSFX iMPC housing palette
    -- (swing_ui_set_colors): body RGB(214,207,194)=0xD6CFC2, recessed cream
    -- tray 0xC2BDB3, transport grey 0xADA89E, charcoal header 0x4D4D52.
    -- Borders/striping deepened so the panel carries the plugin's tonal depth
    -- instead of reading as a flat, pale field.
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         0xD6CFC2FF)  -- iMPC body
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg,          0xD6CFC2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          0xC8C0B0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,           0x938A78FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,          0xC2BDB3FF)  -- recessed tray
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered,   0xCBC6BBFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,    0xB6AFA2FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          0x4D4D52FF)  -- charcoal header
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    0x5A5A61FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header,           0xC2BDB3FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered,    0xB8B2A4FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,     0xADA89EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,           0xADA89EFF)  -- transport grey
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,    0xBBB6ABFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,     0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,             0x2B2822FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled,     0x7E776AFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,      0xC8C0B0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,    0xADA89EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabHovered, 0x9C9483FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabActive,  0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    0xC2BDB3FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong, 0x938A78FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight,  0xBDB6A8FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,        0xD6CFC2FF)  -- iMPC body
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,     0xCEC6B6FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,         0x938A78FF)
  elseif (theme == "reaper" or theme == "reaper_panel" or theme == "reaper_color") and reaper_palette(_reaper_mode_of(theme)) then
    w._apply_semantic(ctx, reaper_palette(_reaper_mode_of(theme)))
  elseif rktheme and rktheme.FIXED and rktheme.FIXED[theme] and theme ~= "dark" then
    -- Console themes (SSL/Neve/API/Witti/Tube): same generic semantic mapping as
    -- the REAPER-derived theme, palette resolved from rk_lua_theme.FIXED.
    w._apply_semantic(ctx, rktheme.FIXED[theme])
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg,         0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg,          0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_PopupBg,          0x2A2A30FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Border,           0x414148FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg,          0x2A2A30FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgHovered,   0x3A3A42FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_FrameBgActive,    0x4A4A55FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBg,          0x1A1A1EFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TitleBgActive,    0x28282FFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header,           0x3C3C45FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered,    0x4C4C58FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive,     0x5C5C6AFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,           0x3A3A42FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered,    0x4F4F5AFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,     0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,             0xDDDDE0FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TextDisabled,     0x8C8C96FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarBg,      0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrab,    0x4A4A55FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabHovered, 0x5A5A68FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ScrollbarGrabActive,  0xFF8C32FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableHeaderBg,    0x28282FFF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderStrong, 0x414148FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableBorderLight,  0x333338FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBg,        0x1E1E22FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_TableRowBgAlt,     0x232328FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Separator,         0x414148FF)
  end

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding,  4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding,   3)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding,   8, 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing,     6, 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ScrollbarSize,   12)
  -- Stash the active theme name (field, not a new local) so w.knob can resolve
  -- its JSFX knob style + role hues without threading the name through callers.
  w._cur_theme = theme
end

function w.pop_theme(ctx)
  ImGui.PopStyleColor(ctx, THEME_COLOR_COUNT)
  ImGui.PopStyleVar(ctx, THEME_VAR_COUNT)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- WAVEFORM DISPLAY
-- ═══════════════════════════════════════════════════════════════════════════════

--- Draw a waveform from peak data.
--- @param ctx    ImGui context
--- @param x      number  screen X
--- @param y      number  screen Y
--- @param width  number  pixel width
--- @param height number  pixel height
--- @param peaks  table   array of {min, max} pairs (or empty)
--- @param playback_ratio number|nil  0-1 playback position (nil = no line)
-- TK Media Browser spectral colormap. Input s in 0..1 returns packed
-- u32 RGBA. Reproduces TK's exact gradient (zcr_value branches at
-- 0.25 / 0.50 / 0.75 — see TK_MEDIA_BROWSER(SA).lua:10511).
--   0.00..0.25  red     (255, 51..170,  0)         — sub-bass
--   0.25..0.50  orange  (255..51, 170..204, 0..51) — bass
--   0.50..0.75  green   (51, 204..153, 51..255)    — mids
--   0.75..1.00  blue    (51..170, 153..51, 255)    — highs/cymbals
local function tk_spectral_color(s)
  s = math.max(0, math.min(1, s or 0.5))
  local R, G, B
  if s < 0.25 then
    local t = s / 0.25
    R = 255
    G = 51 + 119 * t
    B = 0
  elseif s < 0.50 then
    local t = (s - 0.25) / 0.25
    R = 255 - 204 * t
    G = 170 + 34 * t
    B = 0 + 51 * t
  elseif s < 0.75 then
    local t = (s - 0.50) / 0.25
    R = 51
    G = 204 - 51 * t
    B = 51 + 204 * t
  else
    local t = (s - 0.75) / 0.25
    R = 51 + 119 * t
    G = 153 - 102 * t
    B = 255
  end
  return math.floor(R + 0.5) * 0x1000000
       + math.floor(G + 0.5) * 0x10000
       + math.floor(B + 0.5) * 0x100
       + 0xFF
end

function w.draw_waveform(ctx, x, y, width, height, peaks, playback_ratio, opts)
  opts = opts or {}
  local spectral     = opts.spectral
  local grid_overlay = opts.grid_overlay
  local draw_list = ImGui.GetWindowDrawList(ctx)

  -- Background
  ImGui.DrawList_AddRectFilled(draw_list, x, y, x + width, y + height, 0x2A2A30FF)

  -- Detect stereo entries (4-tuple {mnL, mxL, mnR, mxR}) vs mono (2-tuple
  -- {mn, mx}). Stereo renders top half = L, bottom half = R as two
  -- separate waveforms (Tukan-style); mono renders classic single
  -- centered waveform.
  local peak_count = peaks and #peaks or 0
  local is_stereo  = peak_count > 0 and peaks[1] and #peaks[1] >= 4

  -- Centerline(s)
  if is_stereo then
    local mid_top = y + height * 0.25
    local mid_bot = y + height * 0.75
    ImGui.DrawList_AddLine(draw_list, x, mid_top, x + width, mid_top, 0x3A3A42FF)
    ImGui.DrawList_AddLine(draw_list, x, mid_bot, x + width, mid_bot, 0x3A3A42FF)
    -- Subtle horizontal divider between L and R
    local mid_y = y + height * 0.5
    ImGui.DrawList_AddLine(draw_list, x, mid_y, x + width, mid_y, 0x44444AFF)
  else
    local mid_y = y + height * 0.5
    ImGui.DrawList_AddLine(draw_list, x, mid_y, x + width, mid_y, 0x3A3A42FF)
  end

  if peak_count > 0 and width > 0 then
    local step = peak_count / width
    local default_col = w.colors.waveform_blue
    local line_thick  = 1.5  -- match TK's default waveform_thickness
    local spectral_n  = spectral and #spectral or 0
    local spec_step   = spectral_n > 0 and (spectral_n / width) or 0
    -- Window aggregation: when we have more peaks than pixels (TK-style
    -- high peakrate), take max-of-window per pixel so high-frequency
    -- detail isn't lost. When peaks ≈ pixels, behaves like the prior
    -- 1-peak-per-pixel render.
    local win = math.max(1, math.floor(step))

    -- Render uses absolute peak amplitude rendered SYMMETRICALLY around
    -- each centerline (matching TK / Sitala / Battery convention). This
    -- means the line always spans both halves of its lane regardless of
    -- whether the audio content is bipolar, all-positive, all-negative,
    -- or DC-offset. Eliminates the "top-half-only" render that happens
    -- when REAPER's min/max for a window are both same-sign.
    if is_stereo then
      -- Stereo: two separate waveforms, each centered in its half
      local mid_top  = y + height * 0.25
      local mid_bot  = y + height * 0.75
      local half_sc  = height * 0.20
      for px = 0, math.floor(width) - 1 do
        local i0 = math.floor(px * step) + 1
        local i1 = math.min(peak_count, i0 + win - 1)
        local ampL, ampR = 0, 0
        for ii = i0, i1 do
          local pk = peaks[ii]
          if pk then
            local aL = math.max(math.abs(pk[1]), math.abs(pk[2]))
            local aR = math.max(math.abs(pk[3]), math.abs(pk[4]))
            if aL > ampL then ampL = aL end
            if aR > ampR then ampR = aR end
          end
        end
        local col = default_col
        if spec_step > 0 then
          local si = math.min(spectral_n, math.floor(px * spec_step) + 1)
          col = tk_spectral_color(spectral[si] or 0.5)
        end
        local yL = ampL * half_sc
        if yL < 0.5 then yL = 0.5 end
        ImGui.DrawList_AddLine(draw_list, x + px + 0.5, mid_top - yL, x + px + 0.5, mid_top + yL, col, line_thick)
        local yR = ampR * half_sc
        if yR < 0.5 then yR = 0.5 end
        ImGui.DrawList_AddLine(draw_list, x + px + 0.5, mid_bot - yR, x + px + 0.5, mid_bot + yR, col, line_thick)
      end
    else
      -- Mono: single waveform centered on mid_y
      local mid_y = y + height * 0.5
      local scale = height * 0.45
      for px = 0, math.floor(width) - 1 do
        local i0 = math.floor(px * step) + 1
        local i1 = math.min(peak_count, i0 + win - 1)
        local amp = 0
        for ii = i0, i1 do
          local pk = peaks[ii]
          if pk then
            local a = math.max(math.abs(pk[1]), math.abs(pk[2]))
            if a > amp then amp = a end
          end
        end
        local col = default_col
        if spec_step > 0 then
          local si = math.min(spectral_n, math.floor(px * spec_step) + 1)
          col = tk_spectral_color(spectral[si] or 0.5)
        end
        local yh = amp * scale
        if yh < 0.5 then yh = 0.5 end
        ImGui.DrawList_AddLine(draw_list, x + px + 0.5, mid_y - yh, x + px + 0.5, mid_y + yh, col, line_thick)
      end
    end
  end

  -- TK-style proportional time-grid overlay (vertical ticks every
  -- ~80px, plus 4 sub-ticks per main interval; main alpha 0.27, sub
  -- alpha 0.13). Drawn over the waveform when grid_overlay is true.
  -- Time labels at each main tick when src_length is provided.
  if grid_overlay then
    local main_count = math.max(4, math.floor(width / 80))
    local main_col = 0xFFFFFF44  -- white @ ~0.27 alpha
    local sub_col  = 0xFFFFFF22  -- white @ ~0.13 alpha
    local label_col = 0xFFFFFF88
    local src_len = opts.src_length or 0
    for i = 0, main_count do
      local mx = x + (i / main_count) * width
      ImGui.DrawList_AddLine(draw_list, mx, y, mx, y + height, main_col, 1)
      if src_len > 0 and i < main_count then
        -- Format: m:ss:ms (TK style — see screenshot 0:00:015)
        local t = (i / main_count) * src_len
        local mins = math.floor(t / 60)
        local secs = math.floor(t) % 60
        local ms   = math.floor((t * 1000) % 1000)
        local label = string.format("%d:%02d:%03d", mins, secs, ms)
        ImGui.DrawList_AddText(draw_list, mx + 2, y + 2, label_col, label)
      end
    end
    for i = 0, main_count - 1 do
      local sx0 = x + (i       * width) / main_count
      local sx1 = x + ((i + 1) * width) / main_count
      local interval = sx1 - sx0
      for j = 1, 4 do
        local sx = sx0 + (j * interval / 5)
        ImGui.DrawList_AddLine(draw_list, sx, y, sx, y + height, sub_col, 1)
      end
    end
  end

  -- Playback position line
  if playback_ratio and playback_ratio > 0 then
    local px = x + playback_ratio * width
    ImGui.DrawList_AddLine(draw_list, px, y, px, y + height, w.colors.position_line)
  end

  -- Border
  ImGui.DrawList_AddRect(draw_list, x, y, x + width, y + height, w.colors.border_default)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- PAD GRID
-- ═══════════════════════════════════════════════════════════════════════════════

--- Draw a 4x4 pad grid.
--- @param ctx  ImGui context
--- @param opts table with fields:
---   target_pad       number   0-15, currently selected pad
---   on_pad_click     function(pad_idx)  called on click
---   on_pad_drop      function(pad_idx, payload)  called on drag-drop accept
---   read_pad_name    function(pad_idx) -> string
---   pad_has_audio    function(pad_idx) -> bool
---   get_pad_color    function(pad_idx) -> uint32 RGBA
---   get_folder_name  function(path) -> string  (for tooltip)
function w.draw_pad_grid(ctx, opts)
  local avail_w = ImGui.GetContentRegionAvail(ctx)
  local spacing = 4
  local pad_w = math.floor((avail_w - 3 * spacing) / 4)
  local pad_h = pad_w

  for row = 0, 3 do
    for col = 0, 3 do
      local p = (3 - row) * 4 + col
      if col > 0 then ImGui.SameLine(ctx, nil, spacing) end

      local has_audio = opts.pad_has_audio(p)
      local name = opts.read_pad_name(p)
      local is_target = (p == opts.target_pad)
      local is_muted = opts.is_pad_muted and opts.is_pad_muted(p) or false

      -- Color — mirror the JSFX GUI's pad-face math exactly so the browser
      -- looks the same as the plugin face:
      --   loaded, not muted: pr * 0.75 + 0.12  (matte mix toward off-white)
      --   loaded, muted:     pr * 0.35 + 0.15  (deeper desaturation)
      --   empty:             pad_empty (dark gray)
      local col_val
      if has_audio then
        col_val = opts.get_pad_color(p)
        local r = (col_val >> 24) & 0xFF
        local g = (col_val >> 16) & 0xFF
        local b = (col_val >>  8) & 0xFF
        local a =  col_val        & 0xFF
        if is_muted then
          local mix = math.floor(0.15 * 255)
          r = math.floor(r * 0.35) + mix
          g = math.floor(g * 0.35) + mix
          b = math.floor(b * 0.35) + mix
        else
          local mix = math.floor(0.12 * 255)
          r = math.floor(r * 0.75) + mix
          g = math.floor(g * 0.75) + mix
          b = math.floor(b * 0.75) + mix
        end
        col_val = (r << 24) | (g << 16) | (b << 8) | a
      else
        col_val = w.colors.pad_empty
      end

      -- Selected: orange border
      if is_target then
        ImGui.PushStyleColor(ctx, ImGui.Col_Border, w.colors.accent)
        ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 3.0)
      end

      ImGui.PushStyleColor(ctx, ImGui.Col_Button, col_val)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, col_val + 0x1A1A1A00)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x000000FF)

      -- Label
      -- Show the pad name whether or not the pad has audio loaded.
      -- Previously gated on `has_audio` — meaning renaming an empty pad
      -- in the JSFX would update gmem and the JSFX grid, but the browser
      -- pad button would silently keep showing just the pad number.
      -- Visually identical to "rename didn't propagate."
      -- Now: name displays as soon as it's set. Empty pads stay dark gray
      -- (color block above keeps its has_audio gate) but the name shows
      -- in dim text so the user can see they reserved the slot.
      local pad_label
      if name ~= "" then
        local short = #name > 6 and name:sub(1, 6) or name
        pad_label = tostring(p + 1) .. "\n" .. short .. "##pad" .. p
      else
        pad_label = tostring(p + 1) .. "##pad" .. p
      end

      if ImGui.Button(ctx, pad_label, pad_w, pad_h) then
        if opts.on_pad_click then opts.on_pad_click(p) end
      end
      -- Tooltip on hover shows the full pad name. The button label is
      -- truncated to 6 chars to fit the cell; users can see the full
      -- name (e.g. "808_kick_punchy" instead of "808_ki") by hovering.
      if name ~= "" and ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, name)
      end
      ImGui.PopStyleColor(ctx, 3)

      if is_target then
        ImGui.PopStyleVar(ctx)
        ImGui.PopStyleColor(ctx)
      end

      -- Drop target (accepts single file or multi-select)
      if opts.on_pad_drop then
        if ImGui.BeginDragDropTarget(ctx) then
          -- Try multi-file payload first, then single-file
          local rv, payload = ImGui.AcceptDragDropPayload(ctx, "SWING_MULTI")
          if rv and payload then
            opts.on_pad_drop(p, payload, "SWING_MULTI")
          else
            rv, payload = ImGui.AcceptDragDropPayload(ctx, "SWING_FILE")
            if rv and payload then
              opts.on_pad_drop(p, payload, "SWING_FILE")
            end
          end
          ImGui.EndDragDropTarget(ctx)
        end
      end

      -- Right-click context menu. The widget owns the popup lifecycle
      -- (BeginPopup/EndPopup) so positioning + click-to-open work
      -- correctly; the caller's on_pad_right_click renders menu items.
      if opts.on_pad_right_click then
        local popup_id = "##pad_ctx_" .. p
        ImGui.OpenPopupOnItemClick(ctx, popup_id, ImGui.MouseButton_Right)
        if ImGui.BeginPopup(ctx, popup_id) then
          opts.on_pad_right_click(ctx, p)
          ImGui.EndPopup(ctx)
        end
      end

      -- Tooltip
      if ImGui.IsItemHovered(ctx) then
        local tip = "Pad " .. (p + 1)
        if has_audio and name ~= "" then
          tip = tip .. ": " .. name
        else
          tip = tip .. ": (empty)"
        end
        ImGui.SetTooltip(ctx, tip)
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- ROTARY KNOB + MODE PILL  (Pad FX panel; reusable)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Map value↔normalized-t, optionally on a log scale (for frequency knobs).
local function _knob_to_t(v, vmin, vmax, log)
  v = math.max(vmin, math.min(vmax, v))
  if log then
    local lo, hi = math.log(vmin), math.log(vmax)
    return (math.log(math.max(v, 1e-9)) - lo) / (hi - lo)
  end
  return (v - vmin) / (vmax - vmin)
end
local function _knob_from_t(t, vmin, vmax, log)
  t = math.max(0, math.min(1, t))
  if log then
    local lo, hi = math.log(vmin), math.log(vmax)
    return math.exp(lo + t * (hi - lo))
  end
  return vmin + t * (vmax - vmin)
end

-- Resolve the JSFX knob STYLE id for the active theme: the per-theme
-- "eon_knob_<theme>" ExtState override wins (0/"" = theme default), else the
-- theme's built-in primary from rk_lua_theme. Returns nil if no port is loaded.
function w.resolve_knob_style(theme)
  if not rkknobs then return nil end
  theme = theme or w._cur_theme or "eon"
  local ov = tonumber(reaper.GetExtState("Swing", "eon_knob_" .. theme) or "")
  if ov and ov > 0 then return ov end
  if rktheme and rktheme.knob_styles then
    local ks = rktheme.knob_styles(theme)
    return ks and ks[1] or 1
  end
  return 1
end

-- Per-id eased hover (0..1) feeding the JSFX knob skins' hover_t brightness.
w._knob_hov = w._knob_hov or {}

--- Rotary knob. Vertical drag changes value (Shift = fine); double-click resets
--- to opts.default. When a JSFX knob-skin port is loaded, the dial is drawn by
--- the active theme's style (1:1 with the plugin); otherwise a flat fallback dial.
--- Returns (changed, new_value, active).
--- @param opts table: { size=px(44), log=bool, default=number, fmt="%.2f",
---                       accent=uint32, label=string, style=int, hue=uint32,
---                       n_detents=int, is_sym=bool }
function w.knob(ctx, id, value, vmin, vmax, opts)
  opts = opts or {}
  local size   = opts.size or 38
  local accent = opts.accent or w.colors.accent
  local log    = opts.log
  local dl     = ImGui.GetWindowDrawList(ctx)

  ImGui.BeginGroup(ctx)
  local cx, cy = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##knob_" .. id, size, size)
  local active  = ImGui.IsItemActive(ctx)
  local hovered = ImGui.IsItemHovered(ctx)
  local changed = false
  local newval  = value

  -- Drag delta computed from mouse Y (GetMousePos + IsItemActivated) rather
  -- than GetMouseDelta, which isn't guaranteed across ReaImGui versions.
  if ImGui.IsItemActivated(ctx) then
    w._knob_drag_y = select(2, ImGui.GetMousePos(ctx))
  end
  if active then
    local my = select(2, ImGui.GetMousePos(ctx))
    local dy = my - (w._knob_drag_y or my)
    if dy ~= 0 then
      local fine  = ImGui.IsKeyDown(ctx, ImGui.Mod_Shift)
      local speed = fine and 0.0009 or 0.005
      newval = _knob_from_t(_knob_to_t(newval, vmin, vmax, log) - dy * speed, vmin, vmax, log)
      changed = true
      w._knob_drag_y = my
    end
  end
  if opts.default and hovered and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left) then
    newval, changed = opts.default, true
  end

  -- Dial geometry
  local r      = size * 0.5
  local ccx    = cx + r
  local ccy    = cy + r
  local radius = r - 3

  -- Ease the hover_t the JSFX skins use for their brightness/cap response.
  local hov_target = (hovered or active) and 1 or 0
  local hov = w._knob_hov[id] or 0
  hov = hov + (hov_target - hov) * 0.25
  w._knob_hov[id] = hov

  local style = opts.style or w.resolve_knob_style(w._cur_theme)
  if rkknobs and style then
    -- JSFX knob-skin parity. Cap hue: explicit opts.hue, else the active theme's
    -- role-hue (opts.role 1..6 from rk_lua_theme T.ROLES), else the control accent.
    local hue = opts.hue
    if not hue and opts.role and rktheme and rktheme.role_band then
      local rb = rktheme.role_band(w._cur_theme or "eon")
      local c  = rb and rb[opts.role]
      if c then
        hue = (math.floor(c[1] * 255 + 0.5) << 24) | (math.floor(c[2] * 255 + 0.5) << 16)
            | (math.floor(c[3] * 255 + 0.5) << 8) | 0xFF
      end
    end
    hue = hue or accent
    local cr = ((hue >> 24) & 0xFF) / 255
    local cg = ((hue >> 16) & 0xFF) / 255
    local cb = ((hue >> 8)  & 0xFF) / 255
    local bg = w.colors.knob_bg or 0x1E1E22FF
    local g = rkknobs.pen(dl)
    rkknobs.draw(style, g, ccx, ccy, radius, newval, vmin, vmax,
      opts.is_sym and 1 or 0, hov, cr, cg, cb, opts.n_detents or 0,
      ((bg >> 24) & 0xFF) / 255, ((bg >> 16) & 0xFF) / 255, ((bg >> 8) & 0xFF) / 255)
  else
    -- Fallback flat dial (no port loaded): filled circle + value arc + pointer.
    ImGui.DrawList_AddCircleFilled(dl, ccx, ccy, radius, 0x2A2A30FF, 32)
    ImGui.DrawList_AddCircle(dl, ccx, ccy, radius, w.colors.border_default, 32, 1.5)
    local a0   = math.rad(135)
    local a1   = math.rad(135 + 270)
    local t    = _knob_to_t(newval, vmin, vmax, log)
    local aval = a0 + (a1 - a0) * t
    local segs = 24
    local ar   = radius - 1.5
    local pa   = a0
    local i = 1
    while i <= segs do
      local nb = a0 + (aval - a0) * (i / segs)
      ImGui.DrawList_AddLine(dl,
        ccx + math.cos(pa) * ar, ccy + math.sin(pa) * ar,
        ccx + math.cos(nb) * ar, ccy + math.sin(nb) * ar, accent, 2.5)
      pa = nb
      i = i + 1
    end
    ImGui.DrawList_AddLine(dl, ccx, ccy,
      ccx + math.cos(aval) * (radius - 2), ccy + math.sin(aval) * (radius - 2),
      w.colors.white, 2)
  end

  -- Value text + optional label, centered under the dial
  local vtxt = string.format(opts.fmt or "%.2f", newval)
  local tw   = ImGui.CalcTextSize(ctx, vtxt)
  ImGui.DrawList_AddText(dl, ccx - tw * 0.5, cy + size + 1, w.colors.text_info, vtxt)
  if opts.label then
    local lw = ImGui.CalcTextSize(ctx, opts.label)
    ImGui.DrawList_AddText(dl, ccx - lw * 0.5, cy + size + 15, w.colors.text_dim, opts.label)
  end
  -- Reserve the text rows in layout so siblings don't overlap.
  ImGui.Dummy(ctx, size, opts.label and 26 or 13)
  ImGui.EndGroup(ctx)

  if hovered and opts.label then ImGui.SetTooltip(ctx, opts.label .. ": " .. vtxt) end
  return changed, newval, active
end

--- Mode pill — a small button that cycles a labelled enum on click.
--- Returns (changed, new_idx). `labels` is a 1-based array; idx is 0-based.
function w.mode_pill(ctx, id, labels, idx, width)
  local cur = labels[(idx % #labels) + 1] or "?"
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, w.colors.accent)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x000000FF)
  local clicked = ImGui.Button(ctx, cur .. "##pill_" .. id, width or 0, 0)
  ImGui.PopStyleColor(ctx, 2)
  if clicked then return true, (idx + 1) % #labels end
  return false, idx
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- BUTTON HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════

--- Button that can be disabled. Returns true if clicked (and was enabled).
function w.button(ctx, label, width, height, enabled)
  if enabled == false then ImGui.BeginDisabled(ctx) end
  local clicked = ImGui.Button(ctx, label, width or 0, height or 0)
  if enabled == false then ImGui.EndDisabled(ctx) end
  return clicked
end

--- Button with a custom background color. Returns true if clicked.
function w.colored_button(ctx, label, color, width, height)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, color)
  local clicked = ImGui.Button(ctx, label, width or 0, height or 0)
  ImGui.PopStyleColor(ctx)
  return clicked
end

return w
