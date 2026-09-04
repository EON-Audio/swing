-- settings_window.lua -- EON Drum Matrix settings UI.
--
-- Visual style + structure adapted from TK_Trackname_in_Arrange.lua (lines
-- 1520-1610, 3095-3160):
--   * Dark theme: 0x111111 window, 0x333333 frame, accent for tab-selected.
--   * Window/frame/grab rounding 12/6/12 for premium feel.
--   * Header row: red "EON" + white "DRUM MATRIX" + version, close button top-right.
--   * Tab bar (Display / Paint / Pattern / Tools / Patterns / Pads).
--   * Footer with Reset All button.
--   * Save-on-change: every widget writes through settings.Set immediately.
--   * Right-click any control -> "Reset to default" context menu item.
--   * Tooltips on every control via SetItemTooltip + settings.GetDoc(key).
--
-- API:
--   M.Draw(ctx)  -- call inside MainLoop each frame WHEN settings.IsWindowOpen()
--                   returns. The function handles its own Begin/End and the
--                   close button. Returns true if the window was visible.

local M = {}

-- True when the cursor was over the settings window last frame (set in Draw).
-- The main script reads this to suppress paint-click bleed behind the window.
local _hovered = false
function M.IsHovered() return _hovered end

local SCRIPT_DIR    = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local settings      = dofile(SCRIPT_DIR .. 'settings_store.lua')
local lane_tools    = dofile(SCRIPT_DIR .. 'lane_tools.lua')
local pattern_regions = dofile(SCRIPT_DIR .. 'pattern_regions.lua')
local category      = dofile(SCRIPT_DIR .. 'category.lua')
local cat_glyphs    = dofile(SCRIPT_DIR .. 'cat_glyphs_bridge.lua')  -- 46-cat vector glyphs (graceful no-op if absent)
local preset_lib    = dofile(SCRIPT_DIR .. 'preset_library.lua')
local swing_sync    = dofile(SCRIPT_DIR .. 'swing_sync.lua')
local keymap        = dofile(SCRIPT_DIR .. 'keymap.lua')

local r = reaper

-- Keys tab: the action id currently armed for rebind capture (nil = none).
local _rebind_arm = nil

-- True while the Keys tab is waiting to capture a rebind keypress. The main
-- overlay reads this to suppress its own shortcut dispatch so the captured key
-- doesn't also trigger an action mid-rebind.
function M.IsCapturingKey() return _rebind_arm ~= nil end

-- Drawn to the customer in the settings header (see the header block below).
-- Drum Matrix versions independently of Swing — it is its own SKU — so this
-- does NOT track the Swing product version. It was '0.x' up to here, which
-- read as an unfinished placeholder inside a shipping product.
local SCRIPT_VERSION = '1.0'

-- Currently selected tab (1..6). Defaults to Display.
local active_tab = 1

-- Last full-kit `group` stamped per genre, so "Full Kit" reroll avoids an
-- immediate repeat. Frame-persistent (module scope), not saved to disk.
local last_full_kit_group = {}

-- Deferred "Reset All" flag (case #11). Clicking the button only sets this;
-- the actual reset runs at the TOP of the next Draw() call, before any
-- widget reads settings. Prevents mid-frame inconsistency where some
-- widgets in the current frame see new values and others still see old.
local _reset_all_pending = false

-- Tools tab local state
local tools_selected_lane_idx = 1   -- 1-based index into lane_tools.GetLanes()
local tools_fill_n            = 2   -- "every Nth" picker
local tools_fill_clear_first  = true

-- =============================================================================
-- helpers
-- =============================================================================

-- Right-click context menu on the most recently drawn widget. Shows a single
-- "Reset to default" item that resets just this setting.
local function reset_context(ctx, key)
  if r.ImGui_BeginPopupContextItem(ctx, 'ctx_' .. key) then
    if r.ImGui_MenuItem(ctx, 'Reset to default') then
      settings.Reset(key)
    end
    r.ImGui_EndPopup(ctx)
  end
end

local function tooltip(ctx, key)
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_BeginTooltip(ctx)
    r.ImGui_PushTextWrapPos(ctx, 280)
    r.ImGui_Text(ctx, settings.GetDoc(key))
    r.ImGui_PopTextWrapPos(ctx)
    r.ImGui_EndTooltip(ctx)
  end
end

-- Slider that reads/writes a settings key in one line.
local function slider_int(ctx, key, label, lo, hi, width)
  r.ImGui_SetNextItemWidth(ctx, width)
  local cur = settings.Get(key)
  local changed, new_val = r.ImGui_SliderInt(ctx, '##' .. key, cur, lo, hi, label .. ': %d')
  if changed then settings.Set(key, new_val) end
  tooltip(ctx, key)
  reset_context(ctx, key)
end

local function slider_double(ctx, key, label, lo, hi, width)
  r.ImGui_SetNextItemWidth(ctx, width)
  local cur = settings.Get(key)
  local changed, new_val = r.ImGui_SliderDouble(ctx, '##' .. key, cur, lo, hi, label .. ': %.2f')
  if changed then settings.Set(key, new_val) end
  tooltip(ctx, key)
  reset_context(ctx, key)
end

local function checkbox(ctx, key, label)
  local cur = settings.Get(key)
  local changed, new_val = r.ImGui_Checkbox(ctx, label .. '##' .. key, cur)
  if changed then settings.Set(key, new_val) end
  tooltip(ctx, key)
  reset_context(ctx, key)
end

local function combo(ctx, key, label, options, width)
  r.ImGui_SetNextItemWidth(ctx, width)
  local cur = settings.Get(key)
  if r.ImGui_BeginCombo(ctx, label .. '##' .. key, tostring(cur)) then
    for _, opt in ipairs(options) do
      local selected = (cur == opt)
      if r.ImGui_Selectable(ctx, tostring(opt), selected) then
        settings.Set(key, opt)
      end
    end
    r.ImGui_EndCombo(ctx)
  end
  tooltip(ctx, key)
  reset_context(ctx, key)
end

-- =============================================================================
-- tabs
-- =============================================================================

local function draw_display_tab(ctx, slider_width)
  r.ImGui_SeparatorText(ctx, 'Clean view')
  checkbox(ctx, 'minimal_mode',           'Minimal mode (hide chrome)')
  checkbox(ctx, 'show_pattern_bar',       'Show pattern bar')
  checkbox(ctx, 'lane_controls_on_hover', 'Lane cog / M / S on hover only')

  r.ImGui_SeparatorText(ctx, 'Lane fill')
  slider_int(ctx, 'lane_bg_brightness', 'Background brightness', 0, 96, slider_width)
  slider_int(ctx, 'lane_tint_alpha', 'Lane tint alpha', 0, 255, slider_width)
  slider_double(ctx, 'item_dim_factor', 'Item dim factor', 0.0, 1.0, slider_width)

  r.ImGui_SeparatorText(ctx, 'Grid lines (vertical)')
  slider_int(ctx, 'grid_bar_alpha',     'Bar alpha',      0, 255, slider_width)
  slider_int(ctx, 'grid_bar_thickness', 'Bar thickness',  1,   4, slider_width)
  slider_int(ctx, 'grid_beat_alpha',    'Beat alpha',     0, 255, slider_width)
  slider_int(ctx, 'grid_subbeat_alpha', 'Sub-beat alpha', 0, 255, slider_width)

  r.ImGui_SeparatorText(ctx, 'Bar markers')
  checkbox(ctx, 'bar_line_accent',     'Accent bar lines')
  checkbox(ctx, 'bar_numbers_enabled', 'Show bar numbers')

  r.ImGui_SeparatorText(ctx, 'Lane separators (horizontal)')
  slider_int(ctx, 'lane_border_alpha', 'Separator alpha', 0, 255, slider_width)

  r.ImGui_SeparatorText(ctx, 'Labels')
  checkbox(ctx, 'show_labels',         'Show pad labels')
  checkbox(ctx, 'show_pitch_in_label', 'Show pitch number in label')
  checkbox(ctx, 'show_lane_icons',     'Show category icons')

  r.ImGui_SeparatorText(ctx, 'Piano lanes')
  combo(ctx, 'piano_keyboard', 'Pitch guide', { 'keys', 'labels', 'off' }, slider_width)

  r.ImGui_SeparatorText(ctx, 'Graph editor')
  checkbox(ctx, 'graph_editor_enabled', 'Master toggle: velocity strip')
  combo(ctx, 'graph_strip_scope', 'Show on', { 'selected', 'all', 'off' }, slider_width)
  slider_int(ctx, 'graph_strip_height', 'Strip height', 6, 28, slider_width)
end

local function draw_paint_tab(ctx, slider_width)
  r.ImGui_SeparatorText(ctx, 'Note painting')
  slider_int(ctx, 'default_velocity', 'Default velocity', 1, 127, slider_width)
  checkbox(ctx, 'live_trigger', 'Live trigger on paint')

  r.ImGui_SeparatorText(ctx, 'Interaction')
  combo(ctx, 'right_click_action', 'Right-click', { 'delete', 'toggle', 'off' }, slider_width)
  combo(ctx, 'snap_mode',          'Snap mode',   { 'floor', 'nearest', 'off' }, slider_width)

  r.ImGui_SeparatorText(ctx, 'Grid control')
  checkbox(ctx, 'grid_widget_enabled',  'Show grid cog (hover + wheel)')
  checkbox(ctx, 'grid_scroll_in_paint', 'Wheel over empty grid cycles grid')

  r.ImGui_SeparatorText(ctx, 'Floating FX')
  checkbox(ctx, 'paint_fx_cutout', 'Keep floating FX visible (cut lanes around them)')
end

local function draw_pattern_tab(ctx, slider_width)
  r.ImGui_SeparatorText(ctx, 'Item creation')
  combo(ctx, 'new_item_bars', 'New item length (bars)', { 1, 2, 4, 8 }, slider_width)
  checkbox(ctx, 'auto_extend', 'Auto-extend item on overshoot')

  r.ImGui_SeparatorText(ctx, 'Tempo')
  checkbox(ctx, 'apply_sets_tempo', 'Match project tempo to pattern on apply')

  r.ImGui_SeparatorText(ctx, 'Apply')
  checkbox(ctx, 'apply_quantize', 'Quantize imported patterns to grid on apply')
end

local function draw_tools_tab(ctx)
  local lanes = lane_tools.GetLanes()
  if #lanes == 0 then
    r.ImGui_TextWrapped(ctx, 'No drum lanes found. Run EON_DM_Build.lua to set up a kit.')
    return
  end

  -- Target = whichever REAPER track is selected, IF it's a drum lane.
  -- Auto-tracking: change the track selection in REAPER and the target retargets.
  local selected = lane_tools.GetSelectedLane()

  r.ImGui_SeparatorText(ctx, 'Target lane')
  if selected then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x66FF66FF)
    r.ImGui_Text(ctx, string.format('%02d  %s  (pitch %d)',
                                    selected.lane_info.pad_index or 0,
                                    selected.lane_info.pad_name or '?',
                                    selected.lane_info.pad_pitch or 0))
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_TextDisabled(ctx, 'Select a different lane track in REAPER to retarget.')
  else
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFFAA66FF)
    r.ImGui_Text(ctx, 'No drum lane selected.')
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_TextDisabled(ctx, 'Click a drum-lane track in REAPER to enable the tools.')
  end

  -- Single-lane ops (disabled when no target).
  r.ImGui_SeparatorText(ctx, 'Single-lane operations')
  if not selected then r.ImGui_BeginDisabled(ctx) end
  if r.ImGui_Button(ctx, 'Clear lane', 130, 0)    then lane_tools.ClearLane(selected) end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'Quantize lane', 130, 0) then lane_tools.QuantizeLane(selected) end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'Mirror lane', 130, 0)   then lane_tools.MirrorLane(selected) end
  if r.ImGui_Button(ctx, 'Shift left', 130, 0)    then lane_tools.ShiftLane(selected, -1) end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'Shift right', 130, 0)   then lane_tools.ShiftLane(selected, 1) end

  -- Fill every N
  r.ImGui_SeparatorText(ctx, 'Fill every N steps')
  r.ImGui_SetNextItemWidth(ctx, 200)
  local changed_n, new_n = r.ImGui_SliderInt(ctx, 'Every N grid steps', tools_fill_n, 1, 16)
  if changed_n then tools_fill_n = new_n end
  r.ImGui_SetItemTooltip(ctx, 'Step interval. 1 = fill every cell; 2 = every other; 4 = quarter-bar; etc. Useful for hi-hat patterns.')

  local changed_c, new_c = r.ImGui_Checkbox(ctx, 'Clear existing notes on this lane first', tools_fill_clear_first)
  if changed_c then tools_fill_clear_first = new_c end

  if r.ImGui_Button(ctx, 'Fill lane', 130, 0) then
    lane_tools.FillEveryN(selected, tools_fill_n, tools_fill_clear_first)
  end
  if not selected then r.ImGui_EndDisabled(ctx) end

  -- Destructive multi-lane
  r.ImGui_SeparatorText(ctx, 'All lanes')
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        0x661111FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), 0x882222FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  0xAA3333FF)
  if r.ImGui_Button(ctx, 'Clear ALL lanes', 200, 0) then
    if r.ShowMessageBox('Delete every note across all 16 drum lanes?\nThis can be undone with Ctrl+Z.',
                        'EON Drum Matrix', 4) == 6 then
      lane_tools.ClearAllLanes()
    end
  end
  r.ImGui_PopStyleColor(ctx, 3)

  r.ImGui_Separator(ctx)
  -- View actions. Same functions the overlay's Z key / toolbar / Manager zoom
  -- buttons call — single source of truth in pattern_regions, so a future
  -- change to framing updates every entry point at once.
  if r.ImGui_Button(ctx, 'Zoom to pattern', 98, 0) then
    pattern_regions.ZoomToCurrent()
  end
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_SetTooltip(ctx,
      'Fit the arrange view to the current pattern region. ' ..
      'Keyboard: Z (with the overlay focused).')
  end
  r.ImGui_SameLine(ctx)
  if r.ImGui_Button(ctx, 'Zoom to song', 98, 0) then
    pattern_regions.ZoomToSong()
  end
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_SetTooltip(ctx,
      'Fit the arrange view to the whole song: the span of every pattern region.')
  end

  r.ImGui_SeparatorText(ctx, 'Commit')
  if r.ImGui_Button(ctx, 'Commit pattern to item', 200, 0) then
    lane_tools.CommitPatternToItem()
  end
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_SetTooltip(ctx,
      'Flatten every lane into one MIDI item on a new track below the kit, ' ..
      'routed into Swing like the lanes. Source lanes are untouched; one undo step.')
  end
end

local function draw_patterns_tab(ctx, slider_width)
  r.ImGui_TextWrapped(ctx, 'Patterns are named REAPER regions you can see in the timeline ruler. Make a new pattern from the current bar (or time selection), jump to one, or stamp an independent copy of its notes across all lanes at the edit/play cursor. Nothing is hidden, and stamping never wipes existing notes. The same patterns appear as quick-access buttons on the overlay header.')
  r.ImGui_Separator(ctx)

  if r.ImGui_Button(ctx, 'New pattern from current bar / selection', 0, 0) then
    pattern_regions.New(nil)
  end
  combo(ctx, 'pattern_default_bars', 'Default new-pattern length (bars)', { 1, 2, 4, 8 }, slider_width)
  checkbox(ctx, 'pattern_new_at_selection', 'New pattern at time selection (else append after last)')
  r.ImGui_Separator(ctx)

  local list = pattern_regions.List()
  if #list == 0 then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x888888FF)
    r.ImGui_TextWrapped(ctx, 'No patterns yet. Select a bar (or a time range) and click the button above.')
    r.ImGui_PopStyleColor(ctx)
    return
  end

  for _, pat in ipairs(list) do
    r.ImGui_PushID(ctx, 'pat_' .. pat.idx)

    -- Inline rename: commit the name on edit.
    r.ImGui_SetNextItemWidth(ctx, 160)
    local changed, new_name = r.ImGui_InputText(ctx, '##name', pat.name, 64)
    if changed then pattern_regions.Rename(pat.idx, new_name) end
    r.ImGui_SameLine(ctx)

    if r.ImGui_Button(ctx, 'Jump', 60, 0) then pattern_regions.JumpTo(pat.idx) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Stamp', 60, 0) then pattern_regions.Stamp(pat.idx, nil) end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Delete', 60, 0) then pattern_regions.Delete(pat.idx) end

    r.ImGui_PopID(ctx)
  end
end

-- =============================================================================
-- Pads tab — per-lane lock toggle + display order
-- =============================================================================
-- Lock state lives in the lane's own P_EXT (added to the JSON as 'locked'=true).
-- Display order is a separate ExtState array (pad_order JSON list of pad_index).
-- For Phase D we'll surface the lock toggle and a placeholder for reorder UI.

local function draw_pads_tab(ctx)
  local lanes = lane_tools.GetLanes()
  if #lanes == 0 then
    r.ImGui_TextWrapped(ctx, 'No drum lanes found. Run EON_DM_Build.lua first.')
    return
  end

  r.ImGui_TextWrapped(ctx, 'Lock a lane to make paint mode ignore clicks on it. Useful when you want to protect a finished pattern while editing other lanes.')

  -- Resync from Swing: pull live kit/pad names + pitches from the Swing JSFX
  -- into every (unlocked) lane. Normally automatic, but this forces it if the
  -- user suspects the live sync missed something.
  if r.ImGui_Button(ctx, 'Resync all from Swing', 200, 0) then
    local n = swing_sync.ForceResync()
    if n == -1 then
      r.Help_Set('EON DM: Swing not detected — nothing to sync', false)
    else
      r.Help_Set(string.format('EON DM: resynced %d lane%s from Swing',
        n, n == 1 and '' or 's'), false)
    end
  end
  if r.ImGui_IsItemHovered(ctx) then
    r.ImGui_SetTooltip(ctx, 'Copy current Swing pad names + MIDI notes into the lanes. Locked lanes are left untouched.')
  end
  r.ImGui_Separator(ctx)

  r.ImGui_BeginTable(ctx, 'pads_table', 4,
    r.ImGui_TableFlags_BordersInnerH() | r.ImGui_TableFlags_SizingFixedFit())
  r.ImGui_TableSetupColumn(ctx, 'Pad',      r.ImGui_TableColumnFlags_WidthFixed(),   32)
  r.ImGui_TableSetupColumn(ctx, 'Name',     r.ImGui_TableColumnFlags_WidthStretch())
  r.ImGui_TableSetupColumn(ctx, 'Category', r.ImGui_TableColumnFlags_WidthFixed(),  120)
  r.ImGui_TableSetupColumn(ctx, 'Lock',     r.ImGui_TableColumnFlags_WidthFixed(),   60)
  r.ImGui_TableHeadersRow(ctx)

  for _, lane in ipairs(lanes) do
    local pad_idx = lane.lane_info.pad_index or '?'
    local name    = lane.lane_info.pad_name   or '?'
    local locked  = lane.lane_info.locked == true
    local cat     = category.GetForLane(lane.lane_info)
    r.ImGui_PushID(ctx, 'pad_' .. tostring(pad_idx))
    r.ImGui_TableNextRow(ctx)
    r.ImGui_TableSetColumnIndex(ctx, 0); r.ImGui_Text(ctx, tostring(pad_idx))
    -- Name column: category glyph (detailed tier at s=11) before the name.
    r.ImGui_TableSetColumnIndex(ctx, 1)
    local gid = cat_glyphs.IdForName(name)
    if gid then
      local gcx, gcy = r.ImGui_GetCursorScreenPos(ctx)
      cat_glyphs.Draw(r.ImGui_GetWindowDrawList(ctx), gid, gcx + 12, gcy + 11, 11, 0xE8ECF0E6, 1.2)
      r.ImGui_Dummy(ctx, 24, 22)
      r.ImGui_SameLine(ctx)
    end
    r.ImGui_Text(ctx, name)

    -- Category dropdown — drives which presets match this lane.
    r.ImGui_TableSetColumnIndex(ctx, 2)
    r.ImGui_SetNextItemWidth(ctx, -1)
    if r.ImGui_BeginCombo(ctx, '##cat', cat) then
      for _, c in ipairs(category.CATEGORIES) do
        if r.ImGui_Selectable(ctx, c, c == cat) then
          category.SetForLane(lane.track, lane.lane_info, c)
        end
      end
      r.ImGui_EndCombo(ctx)
    end

    -- Lock toggle.
    r.ImGui_TableSetColumnIndex(ctx, 3)
    local changed, new_locked = r.ImGui_Checkbox(ctx, '##lock', locked)
    if changed then
      local json_ok, json_lib = pcall(dofile, SCRIPT_DIR .. 'json.lua')
      if json_ok and json_lib then
        lane.lane_info.locked = new_locked
        local encoded = json_lib.encode(lane.lane_info)
        r.GetSetMediaTrackInfo_String(lane.track, 'P_EXT:EON_DRUM_LANE', encoded, true)
      end
    end
    r.ImGui_PopID(ctx)
  end
  r.ImGui_EndTable(ctx)

  r.ImGui_Separator(ctx)
  r.ImGui_TextDisabled(ctx, 'Display reorder coming in a later phase — for now lanes follow REAPER track order.')
end

-- ── Keys tab (Feature A2) ────────────────────────────────────────────────
-- Lists every overlay keyboard action (keymap.Registry) with its current
-- bind, a Rebind button, and a per-row Reset. Rebind arms capture; the next
-- non-modifier key press (scanned from keymap.CAPTURE_KEYS) plus the current
-- modifiers becomes the new chord. Escape cancels. These shortcuts only fire
-- while the overlay has keyboard focus.
local function capture_pressed_chord(ctx)
  -- Returns the chord (mods | key) for the first capturable key pressed this
  -- frame, or nil. Modifier-only presses are ignored (we wait for a real key).
  local mods = r.ImGui_GetKeyMods(ctx) or 0
  for _, kv in ipairs(keymap.CAPTURE_KEYS) do
    if r.ImGui_IsKeyPressed(ctx, kv, false) then
      return (mods & keymap.MOD_MASK) | kv
    end
  end
  return nil
end

local function draw_keys_tab(ctx)
  r.ImGui_TextWrapped(ctx,
    'Overlay keyboard shortcuts. These fire while the Drum Matrix overlay has ' ..
    'keyboard focus. Click Rebind, then press the new key combo (hold Ctrl/Shift/' ..
    'Alt as needed). Escape cancels.')
  r.ImGui_Separator(ctx)

  -- Handle an armed capture before drawing rows so the table reflects it.
  if _rebind_arm then
    if keymap.KEY_ESCAPE and r.ImGui_IsKeyPressed(ctx, keymap.KEY_ESCAPE, false) then
      _rebind_arm = nil
    else
      local c = capture_pressed_chord(ctx)
      if c then
        keymap.SetChord(_rebind_arm, c)
        _rebind_arm = nil
      end
    end
  end

  if r.ImGui_BeginTable(ctx, 'keys_table', 4,
      r.ImGui_TableFlags_BordersInnerH() | r.ImGui_TableFlags_SizingFixedFit()) then
    r.ImGui_TableSetupColumn(ctx, 'Action', r.ImGui_TableColumnFlags_WidthStretch())
    r.ImGui_TableSetupColumn(ctx, 'Bind',   r.ImGui_TableColumnFlags_WidthFixed(), 130)
    r.ImGui_TableSetupColumn(ctx, '',       r.ImGui_TableColumnFlags_WidthFixed(),  70)
    r.ImGui_TableSetupColumn(ctx, '',       r.ImGui_TableColumnFlags_WidthFixed(),  56)
    r.ImGui_TableHeadersRow(ctx)

    local last_group = nil
    for _, act in ipairs(keymap.Registry) do
      if act.group ~= last_group then
        last_group = act.group
        r.ImGui_TableNextRow(ctx)
        r.ImGui_TableSetColumnIndex(ctx, 0)
        r.ImGui_TextDisabled(ctx, act.group)
      end

      r.ImGui_PushID(ctx, 'key_' .. act.id)
      r.ImGui_TableNextRow(ctx)

      r.ImGui_TableSetColumnIndex(ctx, 0)
      r.ImGui_Text(ctx, act.label .. (act.sel and ' *' or ''))

      r.ImGui_TableSetColumnIndex(ctx, 1)
      local eff = keymap.EffectiveChord(act.id)
      if _rebind_arm == act.id then
        r.ImGui_TextColored(ctx, 0xFFCC44FF, 'press a key…')
      else
        r.ImGui_Text(ctx, keymap.ChordName(eff))
        -- Soft duplicate warning: another action shares this chord.
        local conflict = keymap.FindConflict(eff, act.id)
        if conflict then
          r.ImGui_SameLine(ctx)
          r.ImGui_TextColored(ctx, 0xFF6666FF, '!')
          if r.ImGui_IsItemHovered(ctx) then
            r.ImGui_SetTooltip(ctx, 'Also bound to: ' .. conflict ..
              ' (both fire — last one still wins on conflicting actions).')
          end
        end
      end

      r.ImGui_TableSetColumnIndex(ctx, 2)
      if _rebind_arm == act.id then
        if r.ImGui_Button(ctx, 'Cancel', -1, 0) then _rebind_arm = nil end
      else
        if r.ImGui_Button(ctx, 'Rebind', -1, 0) then _rebind_arm = act.id end
      end

      r.ImGui_TableSetColumnIndex(ctx, 3)
      if r.ImGui_Button(ctx, 'Reset', -1, 0) then
        keymap.ResetChord(act.id)
        if _rebind_arm == act.id then _rebind_arm = nil end
      end

      r.ImGui_PopID(ctx)
    end
    r.ImGui_EndTable(ctx)
  end

  r.ImGui_Separator(ctx)
  if r.ImGui_Button(ctx, 'Reset all keys', 130, 0) then
    keymap.ResetAll()
    _rebind_arm = nil
  end
  r.ImGui_SetItemTooltip(ctx, 'Clear every custom keybind and restore the defaults.')
  r.ImGui_SameLine(ctx)
  r.ImGui_TextDisabled(ctx, '*  = only fires when notes are selected')
end

-- =============================================================================
-- public entry
-- =============================================================================

function M.Draw(ctx, overlay_bounds)
  if not settings.IsWindowOpen() then _hovered = false; return false end

  -- Apply any deferred ResetAll from the previous frame BEFORE drawing this
  -- frame's widgets so every slider this frame reads consistent values.
  if _reset_all_pending then
    _reset_all_pending = false
    settings.ResetAll()
  end

  -- First-use position: centered over the overlay's arrange area.
  if overlay_bounds then
    local L, T, R_, B = overlay_bounds.L, overlay_bounds.T, overlay_bounds.R, overlay_bounds.B
    if L and T and R_ and B then
      local px = L + ((R_ - L) - 560) * 0.5
      local py = T + ((B - T) - 580) * 0.5
      r.ImGui_SetNextWindowPos(ctx, px, py, r.ImGui_Cond_FirstUseEver())
    end
  end
  r.ImGui_SetNextWindowSize(ctx, 560, 580, r.ImGui_Cond_FirstUseEver())

  -- Style push (matches TK exactly).
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_WindowRounding(), 12.0)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(),  6.0)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_PopupRounding(),  6.0)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabRounding(),  12.0)
  r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_GrabMinSize(),    8.0)

  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_WindowBg(),        0x111111FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBg(),         0x333333FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgHovered(),  0x444444FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_FrameBgActive(),   0x555555FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrab(),      0x999999FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_SliderGrabActive(),0xAAAAAAFF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_CheckMark(),       0x999999FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),          0x333333FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(),   0x444444FF)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),    0x555555FF)

  local flags = r.ImGui_WindowFlags_NoCollapse() | r.ImGui_WindowFlags_NoDocking()
  local visible, open = r.ImGui_Begin(ctx, 'EON Drum Matrix Settings', true, flags)

  -- Record whether the cursor is over this window (incl. its child popups) so
  -- the main script can tell paint_mode to suppress click-bleed into the lanes.
  _hovered = visible and r.ImGui_IsWindowHovered(ctx, r.ImGui_HoveredFlags_RootAndChildWindows()) or false

  if visible then
    -- Header row: accent EON + title + version + close button.
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0xFF6666FF)
    r.ImGui_Text(ctx, 'EON')
    r.ImGui_PopStyleColor(ctx)
    r.ImGui_SameLine(ctx)
    r.ImGui_Text(ctx, 'DRUM MATRIX')
    r.ImGui_SameLine(ctx)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), 0x888888FF)
    r.ImGui_Text(ctx, 'v' .. SCRIPT_VERSION)
    r.ImGui_PopStyleColor(ctx)

    local window_width = r.ImGui_GetWindowWidth(ctx)
    local pad         = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_WindowPadding())
    local item_sp     = r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing())
    local content_w   = window_width - (pad * 2)
    local column_w    = content_w / 4
    local slider_w    = column_w - item_sp

    r.ImGui_Separator(ctx)

    -- Genre selector at the top — global filter for the preset library.
    r.ImGui_Text(ctx, 'Genre')
    r.ImGui_SameLine(ctx, 60)
    r.ImGui_SetNextItemWidth(ctx, 200)
    local genres = preset_lib.AvailableGenres()
    if #genres == 0 then genres = { 'hip-hop' } end
    local cur_genre = settings.Get('genre') or 'hip-hop'
    if r.ImGui_BeginCombo(ctx, '##genre_picker', cur_genre) then
      for _, g in ipairs(genres) do
        if r.ImGui_Selectable(ctx, g, g == cur_genre) then
          settings.Set('genre', g)
        end
      end
      r.ImGui_EndCombo(ctx)
    end
    r.ImGui_SetItemTooltip(ctx, 'Active genre. Presets in lane cog popups + Randomize Kit pick from this genre.')
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Reload', 60, 0) then
      -- Re-scan the presets/ tree (e.g. after running EON_DM_ImportMIDI) without
      -- restarting the overlay. The library caches on first load, so new files
      -- are invisible until this drops + rebuilds the cache.
      preset_lib.Reload()
      reaper.Help_Set('EON DM: preset library reloaded', false)
    end
    r.ImGui_SetItemTooltip(ctx, 'Re-scan the presets folder after importing new MIDI patterns.')
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Randomize Kit', 130, 0) then
      -- Roll a random preset per lane in current genre × that lane's category.
      -- Respects locked lanes; falls back through related categories so lanes
      -- without an exact (genre, category) match still get patterns. Reports
      -- counts via status bar so the user knows what happened.
      local picked_genre = settings.Get('genre') or 'hip-hop'
      reaper.Undo_BeginBlock()
      local rolled, skipped_locked, skipped_nopreset, skipped_stereo = 0, 0, 0, 0
      for _, lane in ipairs(lane_tools.GetLanes()) do
        if lane.lane_info.locked then
          skipped_locked = skipped_locked + 1
        elseif lane.lane_info.stereo == true then
          -- whole-kit lane: a per-pad preset has no single row to land on
          skipped_stereo = skipped_stereo + 1
        else
          local cat = category.GetForLane(lane.lane_info)
          local preset = preset_lib.GetRandom(picked_genre, cat)
          if preset then
            preset_lib.Apply(lane, preset)
            rolled = rolled + 1
          else
            skipped_nopreset = skipped_nopreset + 1
          end
        end
      end
      reaper.Undo_EndBlock(string.format("EON DM: randomize kit (%s)", picked_genre), -1)
      reaper.Help_Set(string.format(
        'EON DM Randomize Kit: %d rolled, %d locked, %d no preset%s',
        rolled, skipped_locked, skipped_nopreset,
        skipped_stereo > 0 and string.format(', %d stereo grid lane skipped', skipped_stereo) or ''), false)
    end
    r.ImGui_SetItemTooltip(ctx, "Roll a random preset on every unlocked lane whose category has presets in the current genre. Lanes without a matching preset stay untouched — not every sound fits every genre.")

    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Full Kit', 90, 0) then
      -- Stamp ONE coherent imported loop across all lanes: pick a random `group`
      -- in the current genre, then apply that group's fragment to each unlocked
      -- lane by category. Unlike Randomize Kit (independent per-lane rolls), the
      -- lanes come from the same human-made loop, so they stay mutually musical.
      local picked_genre = settings.Get('genre') or 'hip-hop'
      local group = preset_lib.GetRandomGroup(picked_genre, last_full_kit_group[picked_genre])
      if not group then
        reaper.Help_Set(string.format(
          'EON DM Full Kit: no imported kits for "%s" — run EON_DM_ImportMIDI first', picked_genre), false)
      else
        last_full_kit_group[picked_genre] = group
        reaper.Undo_BeginBlock()
        local rolled, skipped_locked, cleared, skipped_stereo = 0, 0, 0, 0
        for _, lane in ipairs(lane_tools.GetLanes()) do
          if lane.lane_info.locked then
            skipped_locked = skipped_locked + 1
          elseif lane.lane_info.stereo == true then
            -- whole-kit lane: neither a per-pad fragment nor the "no fragment ->
            -- ClearLane" fallback may touch it (that would wipe the whole pattern)
            skipped_stereo = skipped_stereo + 1
          else
            local cat = category.GetForLane(lane.lane_info)
            local preset = preset_lib.GetGroupPreset(group, cat)
            if preset then
              preset_lib.Apply(lane, preset)
              rolled = rolled + 1
            else
              -- This loop's kit has no fragment for this lane's category. CLEAR
              -- the lane so a stale pattern from a previous kit/genre doesn't
              -- linger (e.g. tom fills left under a trap kit, which uses no toms)
              -- — a Full Kit should be exactly that loop, nothing else.
              lane_tools.ClearLane(lane)
              cleared = cleared + 1
            end
          end
        end
        reaper.Undo_EndBlock(string.format("EON DM: full kit (%s / %s)", picked_genre, group), -1)
        reaper.Help_Set(string.format(
          'EON DM Full Kit "%s": %d lanes stamped, %d cleared, %d locked%s',
          group, rolled, cleared, skipped_locked,
          skipped_stereo > 0 and string.format(', %d stereo grid lane skipped', skipped_stereo) or ''), false)
      end
    end
    r.ImGui_SetItemTooltip(ctx, "Stamp one imported loop as a coherent full kit: every unlocked lane gets that same loop's fragment for its category. Click again to roll a different kit. Needs imported MIDI (EON_DM_ImportMIDI).")

    r.ImGui_Separator(ctx)

    -- Tab bar (TK styling on tabs)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Tab(),         0x404040FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabHovered(),  0xFF6666FF)
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_TabSelected(), 0xFF3333FF)

    if r.ImGui_BeginTabBar(ctx, 'EON_DM_SettingsTabs') then
      if r.ImGui_BeginTabItem(ctx, 'Display')  then active_tab = 1; r.ImGui_EndTabItem(ctx) end
      if r.ImGui_BeginTabItem(ctx, 'Paint')    then active_tab = 2; r.ImGui_EndTabItem(ctx) end
      if r.ImGui_BeginTabItem(ctx, 'Pattern')  then active_tab = 3; r.ImGui_EndTabItem(ctx) end
      if r.ImGui_BeginTabItem(ctx, 'Tools')    then active_tab = 4; r.ImGui_EndTabItem(ctx) end
      if r.ImGui_BeginTabItem(ctx, 'Patterns') then active_tab = 5; r.ImGui_EndTabItem(ctx) end
      if r.ImGui_BeginTabItem(ctx, 'Pads')     then active_tab = 6; r.ImGui_EndTabItem(ctx) end
      if r.ImGui_BeginTabItem(ctx, 'Keys')     then active_tab = 7; r.ImGui_EndTabItem(ctx) end
      r.ImGui_EndTabBar(ctx)
    end
    r.ImGui_PopStyleColor(ctx, 3)

    r.ImGui_Separator(ctx)

    -- Tab body (scroll if it overflows).
    local footer_h = 40
    r.ImGui_BeginChild(ctx, 'tab_body', 0, -(footer_h + 4))
    if     active_tab == 1 then draw_display_tab(ctx, slider_w)
    elseif active_tab == 2 then draw_paint_tab(ctx, slider_w)
    elseif active_tab == 3 then draw_pattern_tab(ctx, slider_w)
    elseif active_tab == 4 then draw_tools_tab(ctx)
    elseif active_tab == 5 then draw_patterns_tab(ctx, slider_w)
    elseif active_tab == 6 then draw_pads_tab(ctx)
    elseif active_tab == 7 then draw_keys_tab(ctx)
    end
    r.ImGui_EndChild(ctx)

    -- Footer: Reset All button + Close button.
    r.ImGui_Separator(ctx)
    if r.ImGui_Button(ctx, 'Reset All', 100, 0) then
      -- Defer to next frame: ResetAll() is applied at the TOP of Draw (before
      -- any widget reads its value this frame), so flag it rather than mutating
      -- mid-frame while sliders downstream may have already cached old values.
      _reset_all_pending = true
    end
    r.ImGui_SetItemTooltip(ctx, 'Restore every setting to its default value.')

    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Close', 100, 0) then
      settings.SetWindowOpen(false)
    end
  end

  -- ImGui_Begin must always be paired with ImGui_End, even when not visible.
  r.ImGui_End(ctx)

  -- Unwind the style stack: 10 PushStyleColor + 5 PushStyleVar from above.
  r.ImGui_PopStyleColor(ctx, 10)
  r.ImGui_PopStyleVar(ctx, 5)

  -- Window title-bar close (the 'X') sets open=false; mirror it to our state.
  if not open then settings.SetWindowOpen(false) end

  return open
end

return M