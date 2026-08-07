-- pattern_bar.lua -- EON Drum Matrix. Color-chip pattern strip + song chain.
--
-- TWO rows, drawn in our own ImGui window just left of the settings cog:
--
--   PATTERNS row  — one color-coded chip per pattern region (chip fill = the
--                   region's own color, so toolbar and ruler agree):
--                     * Left-click  -> JUMP to the pattern
--                     * Shift+click -> STAMP a copy at the cursor
--                     * Right-click -> menu (Stamp / Jump / Add to song / Rename / Delete)
--                   A trailing "+" chip makes a new pattern from the bar / time sel.
--
--   SONG row      — native song mode (no SWS): a Play/Stop toggle, a Loop
--                   toggle, an ARRANGEMENT cell (active letter; click -> picker
--                   to switch/new/duplicate/rename/delete named arrangements),
--                   then the ordered chain of pattern chips with "xN"
--                   repeat badges. The chip that's currently sounding pulses.
--                     * Left-click  -> jump to that region
--                     * Mouse wheel -> change its repeat count
--                     * Right-click -> menu (Remove / Move L-R / Repeats +/-)
--                   Playback rides reaper.GoToRegion (see pattern_song.lua).
--
-- ARCHITECTURE NOTE: this lives in its OWN window (like the cog), NOT the main
-- overlay window, because the overlay is flagged NoMouseInputs whenever paint
-- mode is OFF — an InvisibleButton there would be dead half the time.
--
-- Data/ops: pattern_regions.lua (regions) + pattern_song.lua (chain + driver).
-- This module is pure UI + the rename modal.

local M = {}

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local patterns = dofile(_SCRIPT_DIR .. 'pattern_regions.lua')
local song     = dofile(_SCRIPT_DIR .. 'pattern_song.lua')
local manager  = dofile(_SCRIPT_DIR .. 'pattern_manager.lua')

-- Module-scoped UI state.
local rename_target = nil   -- region idx being renamed (modal open while non-nil)
local rename_buffer = ''
local popup_target  = nil   -- region idx the pattern right-click menu acts on
local song_target   = nil   -- chain position the song right-click menu acts on
local arr_menu_open = false -- arrangement picker popup showing
local arr_rename    = nil   -- arrangement index being renamed (modal open while non-nil)
local arr_rename_buffer = ''

-- Layout metrics.
local CHIP_W   = 64    -- pattern chip
local CHIP_H   = 22
local PLUS_W   = 24
local MGR_W    = 34    -- "Mgr" panel-toggle button
local ZOOM_W   = 22    -- each of the two zoom buttons (fit pattern / fit song)
local GAP      = 4
local ROW_GAP  = 6     -- vertical gap between the two rows
local WIN_PAD  = 6
local PLAY_W   = 26    -- transport buttons
local LOOP_W   = 26
local ARR_W    = 30    -- arrangement cell (letter + caret)
local ARROW_W  = 12    -- "->" connector between song chips
local SONG_W   = 60    -- song chip
local COG_WIN    = 52
local COG_MARGIN = 4
local COG_GAP    = 8

-- =============================================================================
-- color helpers
-- =============================================================================

local function brighten(rgba, amt)
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >> 8)  & 0xFF
  local a =  rgba        & 0xFF
  r = math.floor(r + (255 - r) * amt)
  g = math.floor(g + (255 - g) * amt)
  b = math.floor(b + (255 - b) * amt)
  return (r << 24) | (g << 16) | (b << 8) | a
end

-- Pick black or white text for legibility on a given fill.
local function text_on(rgba)
  local r = (rgba >> 24) & 0xFF
  local g = (rgba >> 16) & 0xFF
  local b = (rgba >> 8)  & 0xFF
  return (0.299 * r + 0.587 * g + 0.114 * b) > 150 and 0x111111FF or 0xFFFFFFFF
end

local function chip_color(region)
  return patterns.ImGuiColor(region and region.color, 0xE6)
end

-- =============================================================================
-- geometry
-- =============================================================================

local function pattern_row_w(n)
  return n * CHIP_W + n * GAP + PLUS_W + GAP + MGR_W + GAP + ZOOM_W + GAP + ZOOM_W
end

local function song_row_w(m)
  local chips = (m > 0) and (m * SONG_W + (m - 1) * ARROW_W) or 80  -- min for hint text
  return PLAY_W + GAP + LOOP_W + GAP + ARR_W + GAP + chips
end

-- Screen-space rect of the strip window. Single source of truth shared by
-- Render AND the paint-suppression hover check. Returns x, y, w, h.
function M.GetStripRect(R, T)
  if not R or not T then return nil end
  local n = #patterns.List()
  local m = #song.SongList()
  local inner = math.max(pattern_row_w(n), song_row_w(m))
  local win_w = inner + WIN_PAD * 2
  local win_h = WIN_PAD * 2 + CHIP_H * 2 + ROW_GAP
  local cog_left = R - COG_WIN - COG_MARGIN
  local x = cog_left - COG_GAP - win_w
  local y = T + 4
  return x, y, win_w, win_h
end

function M.IsHovered(ctx, R, T)
  if popup_target or song_target or rename_target or arr_menu_open or arr_rename then return true end
  local x, y, w, h = M.GetStripRect(R, T)
  if not x then return false end
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  return mx ~= nil and mx >= x and mx <= x + w and my >= y and my <= y + h
end

-- =============================================================================
-- actions
-- =============================================================================

local function stamp_at_cursor(idx)
  patterns.Stamp(idx, nil)   -- nil dest -> lane_tools resolves play/edit cursor
end

-- =============================================================================
-- chip drawing
-- =============================================================================

local function fit_label(ctx, label, max_w)
  if reaper.ImGui_CalcTextSize(ctx, label) <= max_w then return label end
  while #label > 1 and reaper.ImGui_CalcTextSize(ctx, label .. '..') > max_w do
    label = label:sub(1, #label - 1)
  end
  return label .. '..'
end

-- Generic chip. Returns clicked(L), hovered, rclicked(R).
-- opts: { here=bool (white outline), glow=0..1 (now-playing pulse ring),
--         badge=string (drawn top-right) }
local function draw_chip(ctx, dl, id, x, y, w, h, fill, label, opts)
  opts = opts or {}
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, id, w, h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local rclick  = reaper.ImGui_IsItemClicked(ctx, 1)
  local x2, y2  = x + w, y + h

  if opts.glow and opts.glow > 0 then
    local a    = math.floor(0x77 * opts.glow)
    local gcol = (brighten(fill, 0.3) & 0xFFFFFF00) | a
    reaper.ImGui_DrawList_AddRectFilled(dl, x - 3, y - 3, x2 + 3, y2 + 3, gcol, 6)
  end

  local f = hovered and brighten(fill, 0.22) or fill
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, f, 4)

  local border = opts.here and 0xFFFFFFFF or (hovered and 0xFFFFFFCC or 0x00000066)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, border, 4, 0, opts.here and 2 or 1)

  local tcol  = text_on(fill)
  local reserve = opts.badge and (reaper.ImGui_CalcTextSize(ctx, opts.badge) + 6) or 0
  local lab   = fit_label(ctx, label, w - 9 - reserve)
  reaper.ImGui_DrawList_AddText(dl, x + 5, y + math.floor((h - 14) / 2), tcol, lab)

  if opts.badge then
    local bw = reaper.ImGui_CalcTextSize(ctx, opts.badge)
    reaper.ImGui_DrawList_AddText(dl, x2 - bw - 4, y + math.floor((h - 14) / 2),
      (tcol == 0xFFFFFFFF) and 0xFFFFFFB0 or 0x111111B0, opts.badge)
  end
  return clicked, hovered, rclick
end

-- =============================================================================
-- pattern row
-- =============================================================================

local function render_pattern_chip(ctx, dl, pat, x, y, is_here)
  local clicked, hovered, rclick = draw_chip(ctx, dl, 'pat##' .. pat.idx, x, y,
    CHIP_W, CHIP_H, chip_color(pat),
    pat.name ~= '' and pat.name or ('#' .. pat.idx), { here = is_here })
  if hovered then
    reaper.ImGui_SetTooltip(ctx, 'Click: jump   Shift+click: stamp at cursor   Right-click: menu')
  end
  if clicked then
    local mods  = reaper.ImGui_GetKeyMods(ctx) or 0
    local shift = (mods & reaper.ImGui_Mod_Shift()) ~= 0
    if shift then stamp_at_cursor(pat.idx) else patterns.JumpTo(pat.idx) end
  elseif rclick then
    popup_target = pat.idx
    reaper.ImGui_OpenPopup(ctx, 'pat_popup')
  end
end

local function render_plus_chip(ctx, dl, x, y)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, 'pat_add', PLUS_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x2, y2  = x + PLUS_W, y + CHIP_H
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, hovered and 0x335533E0 or 0x2A2A2AC0, 4)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, hovered and 0xFFFFFFFF or 0x888888CC, 4, 0, 1)
  local tw = reaper.ImGui_CalcTextSize(ctx, '+')
  reaper.ImGui_DrawList_AddText(dl, x + math.floor((PLUS_W - tw) / 2),
    y + math.floor((CHIP_H - 14) / 2), 0xCCFFCCFF, '+')
  if hovered then
    reaper.ImGui_SetTooltip(ctx, 'New pattern -- placed right after the last one (or the time selection)')
  end
  if clicked then
    local idx = patterns.New(nil)
    if idx then
      patterns.JumpTo(idx)   -- land on the new region so you can build it
      rename_target = idx
      rename_buffer = (patterns.GetByIndex(idx) or {}).name or ''
      reaper.ImGui_OpenPopup(ctx, 'pat_rename')
    end
  end
end

local function render_mgr_button(ctx, dl, x, y)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, 'pat_mgr', MGR_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local open    = manager.IsOpen()
  local x2, y2  = x + MGR_W, y + CHIP_H
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2,
    open and 0x33558899 or (hovered and 0x333333E0 or 0x2A2A2AC0), 4)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, hovered and 0xFFFFFFFF or 0x888888CC, 4, 0, 1)
  local tw = reaper.ImGui_CalcTextSize(ctx, 'Mgr')
  reaper.ImGui_DrawList_AddText(dl, x + math.floor((MGR_W - tw) / 2),
    y + math.floor((CHIP_H - 14) / 2), open and 0x99CCFFFF or 0xCCCCCCFF, 'Mgr')
  if hovered then
    reaper.ImGui_SetTooltip(ctx, open and 'Close the Pattern Manager' or 'Open the dockable Pattern Manager')
  end
  if clicked then manager.Toggle() end
end

-- One zoom button: a magnifier glyph (lens + handle). `kind` adds a dot in the
-- lens for "pattern" (single) vs a short bar for "song" (whole span). Returns
-- clicked.
local function draw_zoom_button(ctx, dl, id, x, y, kind, tip)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, id, ZOOM_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local x2, y2  = x + ZOOM_W, y + CHIP_H
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, hovered and 0x333333E0 or 0x2A2A2AC0, 4)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, hovered and 0xFFFFFFFF or 0x888888CC, 4, 0, 1)
  local col    = hovered and 0xFFFFFFFF or 0xCCCCCCFF
  local cx, cy = x + ZOOM_W / 2 - 1, y + CHIP_H / 2 - 1
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, 4.5, col, 0, 1.4)            -- lens
  reaper.ImGui_DrawList_AddLine(dl, cx + 3.3, cy + 3.3, cx + 6.4, cy + 6.4, col, 1.6) -- handle
  if kind == 'pattern' then
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, 1.3, col)           -- dot = one pattern
  else
    reaper.ImGui_DrawList_AddLine(dl, cx - 2.3, cy, cx + 2.3, cy, col, 1.4) -- bar = whole song
  end
  if hovered then reaper.ImGui_SetTooltip(ctx, tip) end
  return clicked
end

-- The two zoom buttons (fit current pattern / fit whole song), drawn left to
-- right starting at x. Width consumed = ZOOM_W + GAP + ZOOM_W.
local function render_zoom_buttons(ctx, dl, x, y)
  if draw_zoom_button(ctx, dl, 'zoom_pat', x, y, 'pattern', 'Zoom to current pattern') then
    patterns.ZoomToCurrent()
  end
  x = x + ZOOM_W + GAP
  if draw_zoom_button(ctx, dl, 'zoom_song', x, y, 'song', 'Zoom to entire song') then
    patterns.ZoomToSong()
  end
end

-- =============================================================================
-- song row: transport + chain
-- =============================================================================

local function render_play_button(ctx, dl, x, y)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, 'song_play', PLAY_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local playing = song.IsPlaying()
  local x2, y2  = x + PLAY_W, y + CHIP_H
  local fill    = playing and 0x55222288 or (hovered and 0x335533E0 or 0x2A2A2AC0)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, fill, 4)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, hovered and 0xFFFFFFFF or 0x888888CC, 4, 0, 1)
  local cx, cy = x + PLAY_W / 2, y + CHIP_H / 2
  if playing then
    -- stop = square
    reaper.ImGui_DrawList_AddRectFilled(dl, cx - 5, cy - 5, cx + 5, cy + 5, 0xFF6666FF, 1)
  else
    -- play = right-pointing triangle
    reaper.ImGui_DrawList_AddTriangleFilled(dl, cx - 5, cy - 6, cx - 5, cy + 6, cx + 6, cy, 0xCCFFCCFF)
  end
  if hovered then
    reaper.ImGui_SetTooltip(ctx, playing and 'Stop song' or 'Play song (patterns one after another)')
  end
  if clicked then song.SongToggle() end
end

local function render_loop_button(ctx, dl, x, y)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, 'song_loop', LOOP_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local on      = song.GetLoop()
  local x2, y2  = x + LOOP_W, y + CHIP_H
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2,
    on and 0x33558899 or (hovered and 0x333333E0 or 0x2A2A2AC0), 4)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, hovered and 0xFFFFFFFF or 0x888888CC, 4, 0, 1)
  -- loop glyph: a ring + an arrowhead (font-independent, ASCII-free)
  local cx, cy = x + LOOP_W / 2, y + CHIP_H / 2
  local col    = on and 0x99CCFFFF or 0xAAAAAAFF
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, 6, col, 0, 1.6)
  reaper.ImGui_DrawList_AddTriangleFilled(dl, cx + 6, cy - 6, cx + 6, cy + 1, cx + 11, cy - 3, col)
  if hovered then
    reaper.ImGui_SetTooltip(ctx, on and 'Loop song: ON' or 'Loop song: OFF')
  end
  if clicked then song.ToggleLoop() end
end

-- Arrangement cell: the active arrangement's letter + a caret. Click opens the
-- picker (switch / new / duplicate / rename / delete). Named arrangements are
-- parked chains in pattern_song's store; the live chain stays in 'song'.
local function render_arr_button(ctx, dl, x, y)
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, 'song_arr', ARR_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local _, letter, name = song.ArrActive()
  local x2, y2  = x + ARR_W, y + CHIP_H
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, hovered and 0x333333E0 or 0x2A2A2AC0, 4)
  reaper.ImGui_DrawList_AddRect(dl, x, y, x2, y2, hovered and 0xFFFFFFFF or 0x7F77DDCC, 4, 0, 1)
  local lw = reaper.ImGui_CalcTextSize(ctx, letter)
  reaper.ImGui_DrawList_AddText(dl, x + math.floor((ARR_W - lw) / 2) - 3,
    y + math.floor((CHIP_H - 14) / 2), 0xAFA9ECFF, letter)
  local cx, cy = x + ARR_W - 8, y + CHIP_H / 2
  reaper.ImGui_DrawList_AddTriangleFilled(dl, cx - 3, cy - 1.5, cx + 3, cy - 1.5, cx, cy + 2.5,
    hovered and 0xFFFFFFFF or 0x8A91A3FF)
  if hovered then
    reaper.ImGui_SetTooltip(ctx, 'Arrangement ' .. letter .. (name ~= '' and (' - ' .. name) or '')
      .. '\nClick: switch / manage arrangements')
  end
  if clicked then
    arr_menu_open = true
    reaper.ImGui_OpenPopup(ctx, 'arr_popup')
  end
end

local function render_arr_popup(ctx)
  if reaper.ImGui_BeginPopup(ctx, 'arr_popup') then
    local list, act = song.ArrList()
    for i, a in ipairs(list) do
      local label = a.letter .. (a.name ~= '' and ('  ' .. a.name) or '')
        .. '  (' .. a.steps .. (a.steps == 1 and ' step)' or ' steps)')
      if reaper.ImGui_MenuItem(ctx, label, nil, a.active) and not a.active then
        song.ArrSwitch(i)
      end
    end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_MenuItem(ctx, 'New arrangement') then song.ArrNew() end
    if reaper.ImGui_MenuItem(ctx, 'Duplicate ' .. song.ArrLetter(act)) then song.ArrDuplicate(act) end
    if reaper.ImGui_MenuItem(ctx, 'Rename...') then
      local sel = select(3, song.ArrActive())
      arr_rename = act
      arr_rename_buffer = sel or ''
      reaper.ImGui_OpenPopup(ctx, 'arr_rename')
    end
    if #list > 1 then
      if reaper.ImGui_MenuItem(ctx, 'Delete ' .. song.ArrLetter(act) .. '...') then
        local ok = reaper.ShowMessageBox(
          'Delete arrangement ' .. song.ArrLetter(act) .. '? The chain is discarded (patterns are untouched).',
          'EON Drum Matrix', 4)
        if ok == 6 then song.ArrDelete(act) end
      end
    end
    reaper.ImGui_EndPopup(ctx)
  else
    arr_menu_open = false
  end
end

local function render_arr_rename_modal(ctx)
  if not arr_rename then return end
  local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, 'arr_rename', true, flags)
  if visible then
    reaper.ImGui_Text(ctx, 'Arrangement ' .. song.ArrLetter(arr_rename) .. ' name')
    local changed, new_text = reaper.ImGui_InputText(ctx, '##arrname', arr_rename_buffer, 64)
    if changed then arr_rename_buffer = new_text end
    local commit = reaper.ImGui_Button(ctx, 'OK') or
                   reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
    reaper.ImGui_SameLine(ctx)
    local cancel = reaper.ImGui_Button(ctx, 'Cancel') or
                   reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
    if commit then
      song.ArrRename(arr_rename, arr_rename_buffer)
      arr_rename, arr_rename_buffer = nil, ''
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif cancel then
      arr_rename, arr_rename_buffer = nil, ''
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  elseif open == false then
    arr_rename, arr_rename_buffer = nil, ''
  end
end

local function render_song_chip(ctx, dl, entry, x, y, pos, playing_pos, cur)
  local reg  = entry.region
  local glow = (pos == playing_pos) and (0.45 + 0.55 * math.abs(math.sin(reaper.ImGui_GetTime(ctx) * 5))) or 0
  local here = (not playing_pos) and cur and (cur >= reg.start - 1e-6 and cur < reg.end_ - 1e-6)
  local badge = entry.repeats > 1 and ('x' .. entry.repeats) or nil
  local clicked, hovered, rclick = draw_chip(ctx, dl, 'song##' .. pos, x, y,
    SONG_W, CHIP_H, chip_color(reg), reg.name ~= '' and reg.name or ('#' .. reg.idx),
    { here = here, glow = glow, badge = badge })
  if hovered then
    reaper.ImGui_SetTooltip(ctx, 'Click: jump   Wheel: repeats   Right-click: menu')
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    if wheel and wheel ~= 0 then song.SongBumpRepeats(pos, wheel > 0 and 1 or -1) end
  end
  if clicked then
    patterns.JumpTo(reg.idx)
  elseif rclick then
    song_target = pos
    reaper.ImGui_OpenPopup(ctx, 'song_popup')
  end
end

-- =============================================================================
-- popups + modal
-- =============================================================================

local function render_pattern_popup(ctx)
  if reaper.ImGui_BeginPopup(ctx, 'pat_popup') then
    local idx = popup_target
    if reaper.ImGui_MenuItem(ctx, 'Stamp at cursor') then stamp_at_cursor(idx) end
    if reaper.ImGui_MenuItem(ctx, 'Jump to') then patterns.JumpTo(idx) end
    if reaper.ImGui_MenuItem(ctx, 'Add to song') then song.SongAppend(idx) end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_MenuItem(ctx, 'Rename...') then
      rename_target = idx
      rename_buffer = (patterns.GetByIndex(idx) or {}).name or ''
      reaper.ImGui_OpenPopup(ctx, 'pat_rename')
    end
    if reaper.ImGui_MenuItem(ctx, 'Delete pattern') then patterns.Delete(idx) end
    reaper.ImGui_EndPopup(ctx)
  else
    popup_target = nil
  end
end

local function render_song_popup(ctx)
  if reaper.ImGui_BeginPopup(ctx, 'song_popup') then
    local pos = song_target
    if reaper.ImGui_MenuItem(ctx, 'Repeats +1') then song.SongBumpRepeats(pos, 1) end
    if reaper.ImGui_MenuItem(ctx, 'Repeats -1') then song.SongBumpRepeats(pos, -1) end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_MenuItem(ctx, 'Move left')  then song.SongMove(pos, -1) end
    if reaper.ImGui_MenuItem(ctx, 'Move right') then song.SongMove(pos,  1) end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_MenuItem(ctx, 'Remove from song') then song.SongRemoveAt(pos) end
    if reaper.ImGui_MenuItem(ctx, 'Clear song') then song.SongClear() end
    reaper.ImGui_EndPopup(ctx)
  else
    song_target = nil
  end
end

local function render_rename_modal(ctx)
  if not rename_target then return end
  local flags = reaper.ImGui_WindowFlags_AlwaysAutoResize()
  local visible, open = reaper.ImGui_BeginPopupModal(ctx, 'pat_rename', true, flags)
  if visible then
    local idx = rename_target
    reaper.ImGui_Text(ctx, 'Pattern name')
    local changed, new_text = reaper.ImGui_InputText(ctx, '##patname', rename_buffer, 64)
    if changed then rename_buffer = new_text end
    local commit = reaper.ImGui_Button(ctx, 'OK') or
                   reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
    reaper.ImGui_SameLine(ctx)
    local cancel = reaper.ImGui_Button(ctx, 'Cancel') or
                   reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
    if commit then
      patterns.Rename(idx, rename_buffer)
      rename_target, rename_buffer = nil, ''
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif cancel then
      rename_target, rename_buffer = nil, ''
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  elseif open == false then
    rename_target, rename_buffer = nil, ''
  end
end

-- =============================================================================
-- top-level render
-- =============================================================================

function M.Render(ctx, L, T, R, B)
  local x, y, win_w, win_h = M.GetStripRect(R, T)
  if not x then return end
  local plist = patterns.List()
  local slist = song.SongList()
  local cur   = reaper.GetCursorPosition()
  local playing_pos = song.CurrentEntryPos()

  reaper.ImGui_SetNextWindowPos(ctx, x, y)
  reaper.ImGui_SetNextWindowSize(ctx, win_w, win_h)
  local flags = reaper.ImGui_WindowFlags_NoTitleBar()
              | reaper.ImGui_WindowFlags_NoResize()
              | reaper.ImGui_WindowFlags_NoMove()
              | reaper.ImGui_WindowFlags_NoScrollbar()
              | reaper.ImGui_WindowFlags_NoSavedSettings()
              | reaper.ImGui_WindowFlags_NoFocusOnAppearing()
              | reaper.ImGui_WindowFlags_NoDocking()
              | reaper.ImGui_WindowFlags_NoBackground()
              | reaper.ImGui_WindowFlags_NoCollapse()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), WIN_PAD, WIN_PAD)
  if reaper.ImGui_Begin(ctx, 'EON_DM_Patterns', false, flags) then
    local dl    = reaper.ImGui_GetWindowDrawList(ctx)
    local row1y = y + WIN_PAD
    local row2y = row1y + CHIP_H + ROW_GAP

    -- Row 1: patterns + "+"
    local bx = x + WIN_PAD
    for _, pat in ipairs(plist) do
      local is_here = (cur >= pat.start - 1e-6 and cur < pat.end_ - 1e-6)
      render_pattern_chip(ctx, dl, pat, bx, row1y, is_here)
      bx = bx + CHIP_W + GAP
    end
    render_plus_chip(ctx, dl, bx, row1y); bx = bx + PLUS_W + GAP
    render_mgr_button(ctx, dl, bx, row1y); bx = bx + MGR_W + GAP
    render_zoom_buttons(ctx, dl, bx, row1y)

    -- Row 2: transport + song chain
    local sx = x + WIN_PAD
    render_play_button(ctx, dl, sx, row2y);  sx = sx + PLAY_W + GAP
    render_loop_button(ctx, dl, sx, row2y);  sx = sx + LOOP_W + GAP
    render_arr_button(ctx, dl, sx, row2y);   sx = sx + ARR_W + GAP
    if #slist == 0 then
      reaper.ImGui_DrawList_AddText(dl, sx + 2, row2y + math.floor((CHIP_H - 14) / 2),
        0x888888FF, 'right-click a pattern -> Add to song')
    else
      for pos, entry in ipairs(slist) do
        if pos > 1 then
          reaper.ImGui_DrawList_AddText(dl, sx + 1, row2y + math.floor((CHIP_H - 14) / 2),
            0xAAAAAAFF, '->')
          sx = sx + ARROW_W
        end
        render_song_chip(ctx, dl, entry, sx, row2y, pos, playing_pos, cur)
        sx = sx + SONG_W
      end
    end

    render_pattern_popup(ctx)
    render_song_popup(ctx)
    render_arr_popup(ctx)
    render_rename_modal(ctx)
    render_arr_rename_modal(ctx)
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx, 1)
end

return M
