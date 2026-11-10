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
-- The strip grows left from the cog and STOPS at the arrange's left edge (audit
-- DM112: 20+ chips ran onto the track panel and the next monitor). A row whose
-- chips do not fit shows as many as fit between two arrows, chips at full size;
-- the wheel over the patterns row, Shift+wheel or a horizontal wheel over the
-- song row (a plain wheel on a song chip stays its repeat count), or a click on
-- an arrow moves it one chip. The pattern under the cursor and the song step
-- that is playing scroll into view when they change.
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
local rename_guid   = nil   -- that region's GUID: the number is read back through it on apply (live_idx)
local rename_buffer = ''
local popup_target  = nil   -- region idx the pattern right-click menu acts on
local popup_guid    = nil   -- that region's GUID (live_idx)
local song_target   = nil   -- chain position the song right-click menu acts on
local arr_menu_open = false -- arrangement picker popup showing
local arr_rename    = nil   -- arrangement index being renamed (modal open while non-nil)
local arr_rename_buffer = ''
-- A rename modal a menu asked for: its popup id, opened by Render at WINDOW
-- scope once the menus are done. ImGui hashes a popup id in the current ID
-- stack, so an OpenPopup made inside the pattern / arrangement menu popup named
-- an id BeginPopupModal at window scope never found: no modal, the rename
-- target stuck set, and IsHovered blocked every paint click until a restart
-- (audit DM113, 2026-10-26). The "+" chip opens its modal at window scope.
local open_modal    = nil   -- 'pat_rename' | 'arr_rename' | nil

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
local EDGE_W     = 12  -- the "more" arrow at each end of a row whose chips do not fit (DM112)

-- Sideways scroll state (DM112), in whole chips: never a chip cut in half.
local pat_first, song_first   = 0, 0     -- chips hidden off the left of each row
local pat_wheel, song_wheel   = 0, 0     -- a touchpad's fractional wheel, carried between frames
local pat_follow, song_follow = nil, nil -- the chip last scrolled into view (follow on a change only)

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

-- Row 1 = the pattern chips, then a fixed tail ("+", Mgr, two zooms) next to
-- the cog. Row 2 = a fixed head (play, loop, arrangement), then the song chain.
local PAT_TAIL_W  = PLUS_W + GAP + MGR_W + GAP + ZOOM_W + GAP + ZOOM_W
local SONG_HEAD_W = PLAY_W + GAP + LOOP_W + GAP + ARR_W + GAP

local function pattern_row_w(n)
  return n * (CHIP_W + GAP) + PAT_TAIL_W
end

local function song_chips_w(k)
  return (k > 0) and (k * SONG_W + (k - 1) * ARROW_W) or 80  -- min for hint text
end

local function song_row_w(m)
  return SONG_HEAD_W + song_chips_w(m)
end

-- How many chips of a row fit in `inner` px: all (over = false), or as many as
-- fit between the row's two edge arrows (over = true), at least one.
local function pat_fit(n, inner)
  if pattern_row_w(n) <= inner then return n, false end
  return math.max(1, math.floor((inner - PAT_TAIL_W - 2 * EDGE_W) / (CHIP_W + GAP))), true
end

local function song_fit(m, inner)
  if song_row_w(m) <= inner then return m, false end
  return math.max(1, math.floor((inner - SONG_HEAD_W - 2 * EDGE_W + ARROW_W) / (SONG_W + ARROW_W))), true
end

-- The narrowest strip: each row's fixed part, its two arrows and one chip. An
-- arrange narrower than this is the one case the strip still crosses L.
local MIN_INNER = math.max(PAT_TAIL_W + 2 * EDGE_W + CHIP_W + GAP, SONG_HEAD_W + 2 * EDGE_W + SONG_W)

-- The strip's layout: x, y, w, h of its window, then per row the chips shown
-- (pk / sk) and whether the row scrolls (pover / sover). L nil = no left stop.
local function layout(R, T, L)
  local n = #patterns.List()
  local m = #song.SongList()
  local inner = math.max(pattern_row_w(n), song_row_w(m))
  local right = R - COG_WIN - COG_MARGIN - COG_GAP
  local pk, pover, sk, sover = n, false, m, false
  if L and inner > right - L - WIN_PAD * 2 then
    -- Stop at the arrange's left edge (DM112), then hug what the rows show so
    -- no slack opens between the last chip and the cog.
    local avail = math.max(MIN_INNER, right - L - WIN_PAD * 2)
    pk, pover = pat_fit(n, avail)
    sk, sover = song_fit(m, avail)
    local w1 = pover and (2 * EDGE_W + pk * (CHIP_W + GAP) + PAT_TAIL_W) or pattern_row_w(n)
    local w2 = sover and (SONG_HEAD_W + 2 * EDGE_W + song_chips_w(sk)) or song_row_w(m)
    inner = math.max(w1, w2)
  end
  local win_w = inner + WIN_PAD * 2
  local win_h = WIN_PAD * 2 + CHIP_H * 2 + ROW_GAP
  return right - win_w, T + 4, win_w, win_h, pk, pover, sk, sover
end

-- Screen-space rect of the strip window. Single source of truth shared by
-- Render AND the paint-suppression hover check. Returns x, y, w, h. L is the
-- arrange's left edge (nil: the strip grows without a stop, the old geometry).
function M.GetStripRect(R, T, L)
  if not R or not T then return nil end
  local x, y, w, h = layout(R, T, L)
  return x, y, w, h
end

function M.IsHovered(ctx, R, T, L)
  if popup_target or song_target or rename_target or arr_menu_open or arr_rename then return true end
  local x, y, w, h = M.GetStripRect(R, T, L)
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

-- A region NUMBER held across frames (the open pattern menu, the rename box) is read back through the region's GUID
-- when it is used: a renumber made meanwhile (the ruler, REAPER's region manager) hands the number to another region,
-- and the rename / delete / stamp hit that one (Swing_Solid_R2_Region_GUIDs_2026-10-29.md, "Limits and follow-ups";
-- fixed 2026-10-30). nil = the region is gone. No GUID (a REAPER without region GUIDs): the number, as before.
local function live_idx(idx, guid)
  if guid == nil then return idx end
  return patterns.NumberOfGuid(guid)
end

local function guid_of(idx)
  for _, r in ipairs(patterns.List()) do
    if r.idx == idx then return r.guid end
  end
  return nil
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
    popup_guid   = pat.guid
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
      rename_guid   = guid_of(idx)
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
      open_modal = 'arr_rename'   -- opened by Render at window scope (see open_modal)
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

-- Returns true when the wheel went to the repeat count (the row then does not
-- scroll on it). `scrolls`: the song row is scrolling (DM112), for the tooltip.
local function render_song_chip(ctx, dl, entry, x, y, pos, playing_pos, cur, scrolls)
  local reg  = entry.region
  local glow = (pos == playing_pos) and (0.45 + 0.55 * math.abs(math.sin(reaper.ImGui_GetTime(ctx) * 5))) or 0
  local here = (not playing_pos) and cur and (cur >= reg.start - 1e-6 and cur < reg.end_ - 1e-6)
  local badge = entry.repeats > 1 and ('x' .. entry.repeats) or nil
  local clicked, hovered, rclick = draw_chip(ctx, dl, 'song##' .. pos, x, y,
    SONG_W, CHIP_H, chip_color(reg), reg.name ~= '' and reg.name or ('#' .. reg.idx),
    { here = here, glow = glow, badge = badge })
  local used_wheel = false
  if hovered then
    reaper.ImGui_SetTooltip(ctx, scrolls and 'Click: jump   Wheel: repeats   Shift+wheel: scroll   Right-click: menu'
                                          or 'Click: jump   Wheel: repeats   Right-click: menu')
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    local shift = ((reaper.ImGui_GetKeyMods(ctx) or 0) & reaper.ImGui_Mod_Shift()) ~= 0
    if wheel and wheel ~= 0 and not (shift and scrolls) then   -- Shift+wheel scrolls a row that scrolls (DM112)
      song.SongBumpRepeats(pos, wheel > 0 and 1 or -1)
      used_wheel = true
    end
  end
  if clicked then
    patterns.JumpTo(reg.idx)
  elseif rclick then
    song_target = pos
    reaper.ImGui_OpenPopup(ctx, 'song_popup')
  end
  return used_wheel
end

-- A row's end arrow, drawn (and clickable) only while `hidden` chips lie that
-- way (DM112). dir -1 = left, 1 = right. Returns clicked.
local function draw_more(ctx, dl, id, x, y, dir, hidden)
  if hidden <= 0 then return false end
  reaper.ImGui_SetCursorScreenPos(ctx, x, y)
  local clicked = reaper.ImGui_InvisibleButton(ctx, id, EDGE_W, CHIP_H)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local col     = hovered and 0xFFFFFFFF or 0xAAAAAAFF
  local cx, cy  = x + EDGE_W / 2, y + CHIP_H / 2
  if dir < 0 then
    reaper.ImGui_DrawList_AddTriangleFilled(dl, cx + 3, cy - 5, cx + 3, cy + 5, cx - 3, cy, col)
  else
    reaper.ImGui_DrawList_AddTriangleFilled(dl, cx - 3, cy - 5, cx - 3, cy + 5, cx + 3, cy, col)
  end
  if hovered then
    reaper.ImGui_SetTooltip(ctx, string.format('%d more -- click, or the wheel, to scroll', hidden))
  end
  return clicked
end

local function clamp_first(first, count, shown)
  return math.max(0, math.min(first, count - shown))
end

-- The first-chip offset that puts chip i (1-based) in view, moving as little as it can.
local function into_view(first, shown, i)
  if i - 1 < first then return i - 1 end
  if i > first + shown then return i - shown end
  return first
end

-- Whole-chip steps out of a (fractional) wheel, carrying the remainder.
local function wheel_steps(acc, d)
  acc = acc + d
  local s = (acc >= 0) and math.floor(acc) or -math.floor(-acc)
  return s, acc - s
end

-- =============================================================================
-- popups + modal
-- =============================================================================

local function render_pattern_popup(ctx)
  if reaper.ImGui_BeginPopup(ctx, 'pat_popup') then
    local idx = live_idx(popup_target, popup_guid)   -- its number NOW (a renumber while the menu is up)
    if idx == nil then
      reaper.ImGui_CloseCurrentPopup(ctx)   -- the region went while the menu was up: nothing to act on
    else
      if reaper.ImGui_MenuItem(ctx, 'Stamp at cursor') then stamp_at_cursor(idx) end
      if reaper.ImGui_MenuItem(ctx, 'Jump to') then patterns.JumpTo(idx) end
      if reaper.ImGui_MenuItem(ctx, 'Add to song') then song.SongAppend(idx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Rename...') then
        rename_target = idx
        rename_guid   = popup_guid
        rename_buffer = (patterns.GetByIndex(idx) or {}).name or ''
        open_modal = 'pat_rename'   -- opened by Render at window scope (see open_modal)
      end
      if reaper.ImGui_MenuItem(ctx, 'Delete pattern') then patterns.Delete(idx) end
    end
    reaper.ImGui_EndPopup(ctx)
  else
    popup_target, popup_guid = nil, nil
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
    reaper.ImGui_Text(ctx, 'Pattern name')
    local changed, new_text = reaper.ImGui_InputText(ctx, '##patname', rename_buffer, 64)
    if changed then rename_buffer = new_text end
    local commit = reaper.ImGui_Button(ctx, 'OK') or
                   reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter())
    reaper.ImGui_SameLine(ctx)
    local cancel = reaper.ImGui_Button(ctx, 'Cancel') or
                   reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape())
    if commit then
      local idx = live_idx(rename_target, rename_guid)   -- the region's number NOW; nil = it went: nothing renamed
      if idx then patterns.Rename(idx, rename_buffer) end
      rename_target, rename_guid, rename_buffer = nil, nil, ''
      reaper.ImGui_CloseCurrentPopup(ctx)
    elseif cancel then
      rename_target, rename_guid, rename_buffer = nil, nil, ''
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_EndPopup(ctx)
  elseif open == false then
    rename_target, rename_guid, rename_buffer = nil, nil, ''
  end
end

-- =============================================================================
-- top-level render
-- =============================================================================

function M.Render(ctx, L, T, R, B)
  if not R or not T then return end
  local x, y, win_w, win_h, pk, pover, sk, sover = layout(R, T, L)
  local plist = patterns.List()
  local slist = song.SongList()
  local cur   = reaper.GetCursorPosition()
  local playing_pos = song.CurrentEntryPos()
  local n, m  = #plist, #slist

  -- The pattern under the cursor and the playing song step scroll into view
  -- when they CHANGE (DM112); between changes the user's scroll stands.
  local here_i = nil
  for i, pat in ipairs(plist) do
    if cur >= pat.start - 1e-6 and cur < pat.end_ - 1e-6 then here_i = i; break end
  end
  if here_i ~= pat_follow then
    pat_follow = here_i
    if here_i then pat_first = into_view(pat_first, pk, here_i) end
  end
  if playing_pos ~= song_follow then
    song_follow = playing_pos
    if playing_pos then song_first = into_view(song_first, sk, playing_pos) end
  end
  pat_first  = clamp_first(pat_first, n, pk)
  song_first = clamp_first(song_first, m, sk)

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

    -- Row 1: patterns + "+" (the chips pat_first+1 .. pat_first+pk when it scrolls)
    local bx = x + WIN_PAD
    if pover then
      if draw_more(ctx, dl, 'pat_more_l', bx, row1y, -1, pat_first) then pat_first = pat_first - 1 end
      bx = bx + EDGE_W
    end
    for i = pat_first + 1, math.min(n, pat_first + pk) do
      local pat = plist[i]
      local is_here = (cur >= pat.start - 1e-6 and cur < pat.end_ - 1e-6)
      render_pattern_chip(ctx, dl, pat, bx, row1y, is_here)
      bx = bx + CHIP_W + GAP
    end
    if pover then
      if draw_more(ctx, dl, 'pat_more_r', bx, row1y, 1, n - pat_first - pk) then pat_first = pat_first + 1 end
      bx = bx + EDGE_W
    end
    render_plus_chip(ctx, dl, bx, row1y); bx = bx + PLUS_W + GAP
    render_mgr_button(ctx, dl, bx, row1y); bx = bx + MGR_W + GAP
    render_zoom_buttons(ctx, dl, bx, row1y)

    -- Row 2: transport + song chain (the steps song_first+1 .. song_first+sk when it scrolls)
    local sx = x + WIN_PAD
    local wheel_on_chip = false
    render_play_button(ctx, dl, sx, row2y);  sx = sx + PLAY_W + GAP
    render_loop_button(ctx, dl, sx, row2y);  sx = sx + LOOP_W + GAP
    render_arr_button(ctx, dl, sx, row2y);   sx = sx + ARR_W + GAP
    if #slist == 0 then
      reaper.ImGui_DrawList_AddText(dl, sx + 2, row2y + math.floor((CHIP_H - 14) / 2),
        0x888888FF, 'right-click a pattern -> Add to song')
    else
      if sover then
        if draw_more(ctx, dl, 'song_more_l', sx, row2y, -1, song_first) then song_first = song_first - 1 end
        sx = sx + EDGE_W
      end
      for pos = song_first + 1, math.min(m, song_first + sk) do
        if pos > song_first + 1 then
          reaper.ImGui_DrawList_AddText(dl, sx + 1, row2y + math.floor((CHIP_H - 14) / 2),
            0xAAAAAAFF, '->')
          sx = sx + ARROW_W
        end
        if render_song_chip(ctx, dl, slist[pos], sx, row2y, pos, playing_pos, cur, sover) then
          wheel_on_chip = true
        end
        sx = sx + SONG_W
      end
      if sover and draw_more(ctx, dl, 'song_more_r', sx, row2y, 1, m - song_first - sk) then
        song_first = song_first + 1
      end
    end

    -- Sideways scroll (DM112): the wheel over the patterns row; over the song
    -- row Shift+wheel, a horizontal wheel, or a plain wheel off the chips (on a
    -- chip it is the repeat count). Up / a left tilt = towards the first chip.
    if (pover or sover) and reaper.ImGui_IsWindowHovered(ctx) then
      local wv, wh = reaper.ImGui_GetMouseWheel(ctx)
      wv, wh = wv or 0, wh or 0
      local d = (wh ~= 0) and wh or wv
      local _, my = reaper.ImGui_GetMousePos(ctx)
      if d ~= 0 and my then
        local s
        if my < row2y - ROW_GAP / 2 then
          if pover then
            s, pat_wheel = wheel_steps(pat_wheel, d)
            pat_first = clamp_first(pat_first - s, n, pk)
          end
        elseif sover and not wheel_on_chip then
          s, song_wheel = wheel_steps(song_wheel, d)
          song_first = clamp_first(song_first - s, m, sk)
        end
      end
    end

    render_pattern_popup(ctx)
    render_song_popup(ctx)
    render_arr_popup(ctx)
    -- The rename modals open HERE, in the window's own ID scope (see open_modal).
    if open_modal then
      reaper.ImGui_OpenPopup(ctx, open_modal)
      open_modal = nil
    end
    render_rename_modal(ctx)
    render_arr_rename_modal(ctx)
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx, 1)
end

return M
