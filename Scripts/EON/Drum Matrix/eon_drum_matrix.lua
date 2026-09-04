-- EON Drum Matrix — Phase 4 entry point (v0.x)
-- Transparent ReaImGui overlay over REAPER arrange view.
-- Phase 3 adds: melodic-track auto-zoom renderer + MIDI-hash cache.
-- Phase 4 adds: paint mode (click/drag to place notes on drum lanes).

local r = reaper

-- Seed Lua's PRNG so randomize ops actually vary each session. Without this
-- math.random returns the same sequence every script invocation, which made
-- Randomize Kit + Random pattern + RandomizeLane appear "broken" (same
-- results every press). Uses sub-millisecond precision so back-to-back
-- script restarts also seed differently.
do
  local seed = math.floor((reaper.time_precise() * 1e6) % 2147483647)
  math.randomseed(seed)
  -- Discard first few samples (classic Lua randomness warm-up).
  math.random(); math.random(); math.random()
end

-- ReaImGui + js_ReaScriptAPI hard requires
if not r.ImGui_CreateContext then
  r.ShowMessageBox('EON Drum Matrix requires ReaImGui (install via ReaPack).', 'EON Drum Matrix', 0)
  return
end
if not r.JS_Window_FindChildByID then
  r.ShowMessageBox('EON Drum Matrix requires js_ReaScriptAPI (install via ReaPack).', 'EON Drum Matrix', 0)
  return
end

-- Resolve our own directory and add lib/ to package.path so requires work regardless of cwd
local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path

local overlay     = dofile(SCRIPT_DIR .. 'lib/overlay_window.lua')
local coords      = dofile(SCRIPT_DIR .. 'lib/arrange_coords.lua')
local detect      = dofile(SCRIPT_DIR .. 'lib/track_detection.lua')
local renderer    = dofile(SCRIPT_DIR .. 'lib/render_drum_matrix.lua')
local swing_state = dofile(SCRIPT_DIR .. 'lib/swing_state_reader.lua')
local auto_zoom   = dofile(SCRIPT_DIR .. 'lib/render_auto_zoom.lua')
local midi_cache  = dofile(SCRIPT_DIR .. 'lib/midi_cache.lua')
local paint_mode  = dofile(SCRIPT_DIR .. 'lib/paint_mode.lua')
local lane_tools  = dofile(SCRIPT_DIR .. 'lib/lane_tools.lua')
local item_style    = dofile(SCRIPT_DIR .. 'lib/item_style.lua')
local grid_state    = dofile(SCRIPT_DIR .. 'lib/grid_state.lua')
local settings      = dofile(SCRIPT_DIR .. 'lib/settings_store.lua')
local settings_win  = dofile(SCRIPT_DIR .. 'lib/settings_window.lua')
local keymap        = dofile(SCRIPT_DIR .. 'lib/keymap.lua')
local lane_integrity = dofile(SCRIPT_DIR .. 'lib/lane_integrity.lua')
local cat_glyphs     = dofile(SCRIPT_DIR .. 'lib/cat_glyphs_bridge.lua')  -- 46-cat vector glyphs (graceful no-op if shared modules absent)
local safety        = dofile(SCRIPT_DIR .. 'lib/safety.lua')
local selection     = dofile(SCRIPT_DIR .. 'lib/selection.lua')
local swing_sync    = dofile(SCRIPT_DIR .. 'lib/swing_sync.lua')
local pattern_bar   = dofile(SCRIPT_DIR .. 'lib/pattern_bar.lua')
local grid_widget   = dofile(SCRIPT_DIR .. 'lib/grid_widget.lua')
local pattern_regions = dofile(SCRIPT_DIR .. 'lib/pattern_regions.lua')
local pattern_song  = dofile(SCRIPT_DIR .. 'lib/pattern_song.lua')
local pattern_manager = dofile(SCRIPT_DIR .. 'lib/pattern_manager.lua')

-- Hover tooltip (#14): let the renderer ask paint_mode whether a drag is in
-- flight, so it suppresses the cursor-following tooltip mid-gesture. Injected
-- here (not require'd inside the renderer) to avoid a mutual-dofile cycle
-- between render_drum_matrix and paint_mode.
if renderer.SetDragQuery then renderer.SetDragQuery(paint_mode.IsAnyDragActive) end
-- Stereo lanes follow the LIVE pad map (2026-09-02): the renderer's rows/key
-- guide and the integrity badge resolve their pitch window through
-- lane_tools.LaneRange (tag window ∪ live pitches) instead of the tag frozen
-- at seeding. Injected the same way as the drag query: every host dofile()s
-- its own module instances, so paint_mode wires its own lane_integrity too.
if renderer.SetRangeResolver then renderer.SetRangeResolver(lane_tools.LaneRange) end
if lane_integrity.SetRangeResolver then lane_integrity.SetRangeResolver(lane_tools.LaneRange) end

-- ── Overlay keymap dispatch table ──────────────────────────────────────────
-- One handler per keymap.Registry action id. Each closes over the modules
-- above and resolves its own runtime state (playhead, selected lane), so the
-- dispatcher in MainLoopBody is just: for each action, if its effective chord
-- is pressed, call the handler. `sel`-marked actions are additionally gated on
-- a non-empty selection by the dispatcher.
local function _paste_at_playhead()
  local playing = (reaper.GetPlayState() & 1) == 1
  local at = playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  paint_mode.PasteSelection(coords.SnapDownToCell(at))
end
local function _dup_bar_lane()
  local l = lane_tools.GetSelectedLane()
  if l then
    lane_tools.DuplicateBarToNext(l)
  elseif reaper.Help_Set then
    reaper.Help_Set('EON DM: select a Drum Matrix track first', false)
  end
end
local KEYMAP_HANDLERS = {
  transport_play   = function() reaper.Main_OnCommand(40044, 0) end,
  transport_record = function() reaper.Main_OnCommand(1013,  0) end,
  transport_play2  = function() reaper.Main_OnCommand(1007,  0) end,
  transport_stop2  = function() reaper.Main_OnCommand(1016,  0) end,
  cursor_start     = function() reaper.Main_OnCommand(40042, 0) end,
  cursor_end       = function() reaper.Main_OnCommand(40043, 0) end,
  zoom_pattern     = function() pattern_regions.ZoomToCurrent() end,
  undo             = function() reaper.Main_OnCommand(40029, 0) end,
  redo             = function() reaper.Main_OnCommand(40030, 0) end,
  redo_alt         = function() reaper.Main_OnCommand(40030, 0) end,
  dup_bar_all      = function() lane_tools.DuplicateBarAllLanes() end,
  dup_bar_lane     = _dup_bar_lane,
  nudge_left       = function() paint_mode.NudgeSelection(-1,  0) end,
  nudge_right      = function() paint_mode.NudgeSelection( 1,  0) end,
  nudge_up         = function() paint_mode.NudgeSelection( 0,  1) end,
  nudge_down       = function() paint_mode.NudgeSelection( 0, -1) end,
  delete_sel       = function() paint_mode.DeleteSelection() end,
  delete_sel2      = function() paint_mode.DeleteSelection() end,
  copy_sel         = function() paint_mode.CopySelection() end,
  cut_sel          = function() paint_mode.CutSelection() end,
  dup_sel          = function() paint_mode.DuplicateSelection() end,
  paste_sel        = _paste_at_playhead,
}

-- Singleton lock — case #2 in hardening plan. If the user mashes the toolbar
-- button while the overlay is already running, the second invocation
-- silently exits instead of spawning a duplicate ImGui context that fights
-- the first one over the arrange bounds.
if not safety.AcquireScriptLock('main_overlay', 5) then
  safety.ConsoleWarn('Drum Matrix already running — exiting duplicate invocation')
  return
end

-- Toggle-action support (REAPER shows checkmark next to action in list)
local _, _, section_id, cmd_id = r.get_action_context()
r.SetToggleCommandState(section_id, cmd_id, 1)
r.RefreshToolbar2(section_id, cmd_id)

-- Cleanup runs on script exit. Registered HERE (before the init block below)
-- so that if any init call throws, atexit still fires — clears the stuck
-- toolbar checkmark and releases the singleton lock. Each step is SafePcall'd
-- so one failing restore (e.g. a stale item pointer) can't starve the rest.
local function Cleanup()
  safety.SafePcall('atexit.toggle', function()
    r.SetToggleCommandState(section_id, cmd_id, 0)
    r.RefreshToolbar2(section_id, cmd_id)
  end)
  safety.SafePcall('atexit.midi_cache.Clear',      midi_cache.Clear)
  safety.SafePcall('atexit.lane_integrity.Clear',  lane_integrity.Clear)
  -- Restore vibrant track colors on lane items so the project looks normal
  -- after the overlay closes.
  safety.SafePcall('atexit.item_style.RestoreAll', item_style.RestoreAll)
  -- Restore the project grid to whatever it was BEFORE we opened. Any grid
  -- changes the user made during the session were for Drum Matrix only.
  safety.SafePcall('atexit.grid_state.Restore',    grid_state.Restore)
  -- Restore the 'smoothseek' config var if a song was driving playback.
  safety.SafePcall('atexit.pattern_song.Cleanup',  pattern_song.Cleanup)
  safety.SafePcall('atexit.overlay.Shutdown',      overlay.Shutdown)
  safety.SafePcall('atexit.ReleaseScriptLock', function()
    safety.ReleaseScriptLock('main_overlay')
  end)
end
r.atexit(Cleanup)

overlay.Init('EON Drum Matrix')
swing_state.Init()
paint_mode.Init()
settings.Load()
-- Snapshot the project grid so we can restore it in atexit. The user can
-- change grid on the fly (via REAPER, EON_DM_CycleGrid, or the settings menu)
-- and we'll put it back exactly when the overlay closes.
grid_state.SaveCurrent()
-- Apply dim styling to every existing P_EXT:EON_DRUM_LANE item so the step
-- cells dominate visually. atexit (below) clears I_CUSTOMCOLOR so items
-- revert to their vibrant rainbow track color when the overlay stops.
item_style.DimAll(swing_state)
local ctx = overlay.GetCtx()

-- Visible-track range. A linear scan rather than a binary search on
-- I_TCPY / I_TCPH: TCP-hidden tracks (closed folders) report I_TCPH == 0 and
-- an unreliable I_TCPY, which breaks the monotonic-Y invariant a binary search
-- needs — it could skip a genuinely visible drum lane (silent non-render).
-- track_count is small (tens of tracks), so the linear pass costs nothing
-- measurable next to the per-lane item walks the renderer already does.
-- view_bottom_px is the arrange client-area height, approximated from
-- overlay.GetBounds() (B - T) in ImGui pixels.
local function find_visible_range(track_count, view_bottom_px)
  local first, last = -1, -1
  for i = 0, track_count - 1 do
    local tr = r.GetTrack(0, i)
    if tr then
      local ty = r.GetMediaTrackInfo_Value(tr, 'I_TCPY')
      local th = r.GetMediaTrackInfo_Value(tr, 'I_TCPH')
      -- On-screen iff the track has non-zero TCP height AND its band
      -- intersects [0, view_bottom_px]. Hidden tracks (th == 0) are skipped.
      if th and th > 0 and (ty + th) >= 0 and ty < view_bottom_px then
        if first < 0 then first = i end
        last = i
      end
    end
  end
  return first, last
end

-- Compute the dim REAPER native color used for new auto-created MIDI items.
-- Dim factor lives in settings (Display tab, default 0.18). Keeps lane hue
-- identity but drops intensity so items blend behind step cells. `slot` is
-- the lane's resolved Swing registry slot (nil = legacy shared block).
local function dim_item_color(pad_idx, slot)
  local pr, pg, pb = swing_state.GetPadColor(pad_idx, slot)
  local f = settings.Get('item_dim_factor') or 0.18
  local R = math.floor(pr * 255 * f + 0.5)
  local G = math.floor(pg * 255 * f + 0.5)
  local B = math.floor(pb * 255 * f + 0.5)
  return r.ColorToNative(R, G, B) | 0x1000000
end

-- Per-lane menu button — a three-dot vertical "kebab", not a cog (name kept
-- for call-site stability), rendered via DrawList. Hit detection happens in
-- paint_mode.lua against the rect stored in lane_targets.
-- Returns the rect {x, y, w, h} so the caller can store it for click detection.
local COG_SIZE = 16
local function draw_lane_cog(dl, x, y, mx, my)
  local cx = x + COG_SIZE / 2
  local hovered = (mx and my and mx >= x and mx <= x + COG_SIZE
                                  and my >= y and my <= y + COG_SIZE)
  local color = hovered and 0xFFFFFFFF or 0xCCCCCCDD
  if hovered then
    -- Background pill so user knows it's a click target
    r.ImGui_DrawList_AddRectFilled(dl, x, y, x + COG_SIZE, y + COG_SIZE, 0x33333388, 4)
  end
  -- 3 vertical dots, centered.
  r.ImGui_DrawList_AddCircleFilled(dl, cx, y + 4,  1.6, color)
  r.ImGui_DrawList_AddCircleFilled(dl, cx, y + 8,  1.6, color)
  r.ImGui_DrawList_AddCircleFilled(dl, cx, y + 12, 1.6, color)
  return { x = x, y = y, w = COG_SIZE, h = COG_SIZE }
end

-- Per-lane Mute / Solo toggle buttons, drawn just right of the cog. State is
-- read fresh from REAPER's track flags every frame (not cached), so external
-- TCP changes reflect immediately. Hit detection happens in paint_mode.lua
-- against the rects stored in lane_targets. Each returns its {x,y,w,h} rect.
local MS_SIZE = 14
local MS_GAP  = 4
local LABEL_X_OFFSET = COG_SIZE + MS_GAP + MS_SIZE + MS_GAP + MS_SIZE + 6  -- = 58

local function draw_mute_button(dl, x, y, muted, pad_r, pad_g, pad_b, mx, my)
  local x2, y2 = x + MS_SIZE, y + MS_SIZE
  local hovered = (mx and my and mx >= x and mx <= x2 and my >= y and my <= y2)
  local border_col = hovered and 0xFFFFFFFF or 0x888888CC
  if muted then
    local fill = r.ImGui_ColorConvertDouble4ToU32(pad_r, pad_g, pad_b, 0.85)
    r.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, fill, 2)
  end
  r.ImGui_DrawList_AddRect(dl, x, y, x2, y2, border_col, 2, 0, 1)
  local glyph_col = muted and 0x000000FF or 0xAAAAAACC
  r.ImGui_DrawList_AddText(dl, x + 3, y + 1, glyph_col, 'M')
  return { x = x, y = y, w = MS_SIZE, h = MS_SIZE }
end

local function draw_solo_button(dl, x, y, solo, mx, my)
  local x2, y2 = x + MS_SIZE, y + MS_SIZE
  local hovered = (mx and my and mx >= x and mx <= x2 and my >= y and my <= y2)
  local border_col = hovered and 0xFFFFFFFF or 0x888888CC
  if solo ~= 0 then
    -- REAPER's solo: 1 = solo, 2 = solo-in-place. Either visualizes the same.
    r.ImGui_DrawList_AddRectFilled(dl, x, y, x2, y2, 0xFFCC33E0, 2)
  end
  r.ImGui_DrawList_AddRect(dl, x, y, x2, y2, border_col, 2, 0, 1)
  local glyph_col = (solo ~= 0) and 0x000000FF or 0xAAAAAACC
  r.ImGui_DrawList_AddText(dl, x + 4, y + 1, glyph_col, 'S')
  return { x = x, y = y, w = MS_SIZE, h = MS_SIZE }
end

-- Pad name label drawn at the left edge of a drum lane (with shadow for legibility).
-- Visibility + format respect Display-tab settings. Also draws a per-lane cog
-- icon to the LEFT of the label and returns its hit-test rect.
local function draw_pad_label(dl, track, lane_info, coords, swing_state, L, mx, my, collapsed)
  if not lane_info or not lane_info.pad_index then return nil end
  local y1, _, h = coords.GetTrackY(track)
  if not h or h <= 0 then return nil end

  -- Lane's own Swing instance (multi-Swing): resolve once per label draw,
  -- pass to every reader so the name/color come from the RIGHT kit.
  local slot = swing_state.SlotForLane(lane_info)

  -- Cog + Mute / Solo buttons. Normally drawn on every lane; when
  -- 'lane_controls_on_hover' is on they appear only for the lane under the
  -- cursor (declutters the left edge). When hidden, the rects are nil — the
  -- caller / paint_mode tolerate nil cog/mute/solo rects.
  local cog_rect, mute_rect, solo_rect
  local controls_visible = true
  if settings.Get('lane_controls_on_hover') then
    controls_visible = (my ~= nil and my >= y1 and my <= y1 + h)
  end
  -- Floating-FX cutout (paint mode): hide the whole control cluster when it
  -- falls inside a hole — an invisible click target must not swallow clicks.
  if controls_visible and renderer.RectHidden
     and renderer.RectHidden(L + 2, y1 + 2,
                             L + 2 + COG_SIZE + (MS_GAP + MS_SIZE) * 2, y1 + 2 + COG_SIZE) then
    controls_visible = false
  end
  if controls_visible then
    -- Cog at the very-left of the lane (the only click target if labels hidden).
    cog_rect = draw_lane_cog(dl, L + 2, y1 + 2, mx, my)

    -- Pad color (with blank-pad grey fallback) tints the M fill; state read fresh.
    local pr, pg, pb = swing_state.GetPadColor(lane_info.pad_index, slot)
    local pname = swing_state.GetPadName(lane_info.pad_index, slot)
    if (pname == '' or pname == nil) and (lane_info.pad_name or '') == '' then
      pr, pg, pb = 0.30, 0.30, 0.32
    end
    local mute_val  = r.GetMediaTrackInfo_Value(track, 'B_MUTE') or 0
    local solo_val  = r.GetMediaTrackInfo_Value(track, 'I_SOLO') or 0
    mute_rect = draw_mute_button(dl, L + 2 + COG_SIZE + MS_GAP, y1 + 2,
      mute_val > 0.5, pr, pg, pb, mx, my)
    solo_rect = draw_solo_button(dl, L + 2 + COG_SIZE + MS_GAP + MS_SIZE + MS_GAP, y1 + 2,
      solo_val, mx, my)
  end

  if settings.Get('show_labels') and not settings.Get('minimal_mode')
     and not (renderer.PtHidden and renderer.PtHidden(L + 2 + LABEL_X_OFFSET, y1 + 2)) then
    local name
    if lane_info.stereo == true then
      -- Stereo lane spans the whole kit — label with the LIVE kit name when
      -- one is published ("808"), else the label stamped at build time.
      -- Never pad 1's name.
      name = (swing_state.GetKitName and swing_state.GetKitName()) or ''
      if name == '' then name = lane_info.pad_name or 'Drums' end
    else
      name = swing_state.GetPadName(lane_info.pad_index, slot)
      if name == '' then name = lane_info.pad_name or '' end
    end
    local text
    if settings.Get('show_pitch_in_label') then
      if lane_info.stereo == true then
        -- Whole-kit lane: show the live pitch window, not the frozen tag's
        -- pad_pitch (which is just the seed-time low bound).
        local slo, shi = lane_tools.LaneRange(lane_info)
        text = string.format('%s (%d-%d)', name, slo or 0, shi or 0)
      else
        text = string.format('%s (%d)', name, lane_info.pad_pitch or 0)
      end
    else
      text = name
    end
    local x, y = L + 2 + LABEL_X_OFFSET, y1 + 2
    -- EON ICONS: category glyph before per-pad lane labels. Stereo lanes skip
    -- it (their label is the KIT name; the per-pad rows get glyphs in the
    -- pitch guide instead). Everything after (badges) shifts with x.
    if lane_info.stereo ~= true and settings.Get('show_lane_icons') then
      local gid = cat_glyphs.IdForName(name)
      if gid then
        cat_glyphs.Draw(dl, gid, x + 8, y + 8, 7, 0xFFFFFFE1, 1.2)
        x = x + 19
      end
    end
    r.ImGui_DrawList_AddText(dl, x + 1, y + 1, 0x000000C0, text)
    r.ImGui_DrawList_AddText(dl, x,     y,     0xFFFFFFFF, text)

    -- Foreign-pitch warning badge: shows when any note on the lane has a
    -- pitch other than lane.pad_pitch. Draw to the right of the label.
    local foreign = lane_integrity.CountForeignOnLane({ track = track, lane_info = lane_info })
    if foreign > 0 then
      local badge_text = string.format('! %d', foreign)
      local badge_x = x + 110     -- approx label width offset
      r.ImGui_DrawList_AddText(dl, badge_x + 1, y + 1, 0x000000C0, badge_text)
      r.ImGui_DrawList_AddText(dl, badge_x,     y,     0xFFFF66FF, badge_text)
    end

    -- Piano-view collapse badge: the lane's range is too tall for its height,
    -- so sub-rows fell back to composite blocks (spec §6.5). "↕" cues the user
    -- to grow the track height to see per-pitch rows.
    if collapsed then
      local cb_x = x + 145
      r.ImGui_DrawList_AddText(dl, cb_x + 1, y + 1, 0x000000C0, '\xE2\x86\x95')
      r.ImGui_DrawList_AddText(dl, cb_x,     y,     0x66CCFFFF, '\xE2\x86\x95')
    end
  end
  return { cog = cog_rect, mute = mute_rect, solo = solo_rect }
end

-- Playhead removed in Phase 4 polish — REAPER's native play cursor is already
-- visible and our extra line was creating a double-playhead artifact.

-- Command queue: companion action scripts (bound to keys by the user) post a
-- command + nonce to ExtState; the running overlay executes it using its live
-- selection/clipboard, so the ops work even when the overlay is UNFOCUSED
-- (ImGui only delivers keys while focused). Seed last-seen with the current
-- nonce so a command left over from a previous press doesn't fire on startup.
local CMD_SECTION   = 'EON_DRUM_MATRIX'
local last_cmd_nonce = reaper.GetExtState(CMD_SECTION, 'cmd_nonce')

-- Inner frame body — separated so we can pcall it without nesting r.defer
-- inside the pcall (defer must always re-arm, even after an error).
local function MainLoopBody()
  -- Update DPI scale each frame (cheap)
  local ds = r.ImGui_GetWindowDpiScale(ctx)
  coords.SetScale((ds and ds > 0) and ds or 1)

  -- Phase I: pull Swing-side kit/pad changes into the lanes. Own SafePcall so
  -- a sync hiccup can't abort the rest of the frame's rendering.
  safety.SafePcall('swing_sync.Tick', swing_sync.Tick)

  -- Read paint mode state from ExtState each frame so the external toggle action
  -- can flip it without us restarting. Cheap: ExtState lookup is in-memory.
  local pm_str = r.GetExtState("EON_DRUM_MATRIX", "paint_mode")
  local PAINT_MODE = (pm_str == "1")

  -- Floating-FX cutout: while painting, the overlay's OS window sits ABOVE
  -- floating FX windows, so the lanes would draw right over Swing. Collect the
  -- rect of every visible floating FX window (all Swing instances + any other
  -- floated FX) and (a) have the renderer punch holes there, (b) drop the
  -- overlay's mouse input while the cursor is inside one, so the click goes to
  -- the FX window the user can SEE — not an invisible lane behind it.
  local fx_excl = nil
  if PAINT_MODE and settings.Get('paint_fx_cutout') ~= false then
    fx_excl = overlay.GetFXExclusionRects()
  end
  renderer.SetExclusionRects(fx_excl)
  local hole_hover = false
  if fx_excl then
    local hmx, hmy = r.ImGui_GetMousePos(ctx)
    -- Keep the overlay interactive mid-gesture: a paint drag that started on a
    -- lane shouldn't hand the mouse to Swing when it crosses a hole.
    if hmx and not (paint_mode.IsAnyDragActive and paint_mode.IsAnyDragActive()) then
      hole_hover = renderer.PtHidden(hmx, hmy)
    end
  end

  local visible = overlay.BeginFrame(PAINT_MODE, hole_hover)
  local L, T, R, B = overlay.GetBounds()
  if visible then
    coords.SetBounds(L, T, R, B, overlay.GetScrollSize())
    -- Single per-frame snapshot of view range + grid lines. Every renderer
    -- + paint helper reads from the cache instead of re-querying REAPER.
    coords.BeginFrame()
    local dl = overlay.GetDrawList()
    -- Case #3: GetDrawList can return nil if ImGui's window state went
    -- inconsistent (ctx dropped, Begin failed). Skip the renderer block but
    -- keep going so the cog button + settings window below still draw —
    -- otherwise the user couldn't open settings to recover.
    if dl then

    -- Bar markers (#13): float dim bar numbers at the top of the grid, aligned
    -- to bar lines. Drawn before lanes so lane content paints over the band area.
    renderer.DrawBarNumbers(ctx, dl, coords, L, T, R)

    local tc = r.CountTracks(0)
    local view_h_px = B - T   -- ImGui pixels, used as approximate culling bound
    local first, last = find_visible_range(tc, view_h_px)
    if first < 0 or last < 0 then first, last = 0, tc - 1 end

    local mx, my = r.ImGui_GetMousePos(ctx)
    local lane_targets = {}
    for i = first, last do
      local track = r.GetTrack(0, i)
      if track then
        local kind, lane_info = detect.Classify(track)
        if kind == 'drum_lane' then
          local collapsed, lo, hi, piano = renderer.RenderLane(ctx, dl, track, lane_info, coords, swing_state)
          local rects = draw_pad_label(dl, track, lane_info, coords, swing_state, L, mx, my, collapsed)
          local cog_rect = rects and rects.cog or nil
          local ty1, ty2 = coords.GetTrackY(track)
          if ty1 and ty2 then
            local sy1, sy2 = coords.Snap(ty1), coords.Snap(ty2)
            local strip = renderer.GetStripRectForLane(sy1, sy2, track, lane_info)
            -- Cell-area bounds (top + bottom), same for both modes; piano also
            -- gets sub_row_h. paint_mode maps pitch<->Y from these with the SAME
            -- math the renderer drew; the phantom-cell pass uses them to draw.
            -- Stereo lanes reserve a header band for the label/cog/M/S cluster
            -- so the top pitch row starts BELOW the control rects (its first
            -- cells stay paintable). Must match the renderer's hdr exactly.
            local hdr = (piano and lane_info.stereo == true) and (renderer.STEREO_HDR or 0) or 0
            local item_top = sy1 + 2 + hdr
            local cells_y2 = (strip and strip.y1 - 1) or (sy2 - 2)
            local sub_row_h
            if piano and lo and hi then
              _, sub_row_h = renderer.PianoRowGeometry(sy1, sy2, strip, lo, hi, hdr)
            end
            -- Pad render color (matches the renderer, incl. blank-pad grey) so
            -- the phantom cell color-matches the real one it precedes. Slot
            -- routes the read to this lane's own Swing instance (multi-Swing).
            local lane_slot = swing_state.SlotForLane(lane_info)
            local pad_r, pad_g, pad_b = swing_state.GetPadColor(lane_info.pad_index, lane_slot)
            if (lane_info.pad_name or '') == '' then pad_r, pad_g, pad_b = 0.30, 0.30, 0.32 end
            lane_targets[#lane_targets + 1] = {
              track = track,
              lane_info = lane_info,
              y1 = ty1, y2 = ty2,
              item_color = dim_item_color(lane_info.pad_index, lane_slot),
              cog = cog_rect,                                          -- rect for hit-testing
              mute = rects and rects.mute,                             -- M button rect
              solo = rects and rects.solo,                             -- S button rect
              strip = strip,
              piano = piano or false,
              note_lo = lo,
              note_hi = hi,
              item_top = item_top,
              cells_y2 = cells_y2,
              sub_row_h = sub_row_h,
              pad_r = pad_r, pad_g = pad_g, pad_b = pad_b,
            }
          end
        elseif kind == 'midi_track' then
          auto_zoom.RenderTrack(ctx, dl, track, coords, midi_cache)
        end
      end
    end

    -- Hover tooltip (#14): the lane passes queued a bar.beat + velocity if the
    -- cursor was over a painted cell this frame. Emit it now, once, after every
    -- lane has drawn — so it renders on top and only the last-hovered cell wins.
    renderer.EmitPendingTooltip(ctx)

    -- Tell paint mode when the cursor is over the cog button or the open
    -- settings window, so a click on that UI doesn't bleed through and paint a
    -- stray cell in the lane behind it. (The lane-tools popup is handled inside
    -- paint_mode itself.) The cog rect mirrors the settings-cog block below.
    local ui_over = false
    if L and T and R then
      local cw = 44 + 4 * 2                    -- COG_BTN + COG_PAD*2 (see below)
      local cx1, cy1 = R - cw - 4, T + 4
      if mx and my and mx >= cx1 and mx <= cx1 + cw and my >= cy1 and my <= cy1 + cw then
        ui_over = true
      end
      -- Tool Mode selector, stacked just below the cog (mirror its geometry).
      local tw, th = 4 * 2 + 26 * 3 + 2 * 2, 4 * 2 + 26
      local tx1, ty1 = R - tw - 4, T + 4 + 52 + 4
      if mx and my and mx >= tx1 and mx <= tx1 + tw and my >= ty1 and my <= ty1 + th then
        ui_over = true
      end
    end
    if not ui_over and settings.IsWindowOpen() and settings_win.IsHovered and settings_win.IsHovered() then
      ui_over = true
    end
    -- Pattern bar lives in its own window just left of the cog; suppress paint
    -- click-through when the cursor is over it (or a popup/modal is open).
    if not ui_over and settings.Get('show_pattern_bar') and not settings.Get('minimal_mode')
       and pattern_bar.IsHovered and pattern_bar.IsHovered(ctx, R, T) then
      ui_over = true
    end
    -- Grid cog: suppress paint click/scroll bleed-through over its rect.
    if not ui_over and settings.Get('grid_widget_enabled') and not settings.Get('minimal_mode')
       and grid_widget.IsHovered and grid_widget.IsHovered(ctx, R, T) then
      ui_over = true
    end
    -- Floating-FX cutout holes: never paint through one. Clicks there belong to
    -- the FX window (BeginFrame already dropped mouse input for the frame; this
    -- guard covers the one-frame lag before that flag applies).
    if not ui_over and fx_excl and mx and my and renderer.PtHidden(mx, my) then
      ui_over = true
    end
    paint_mode.SetMouseBlocked(ui_over)

    -- Tool cursor (#1, FL-like): swap the OS mouse cursor to reflect the active
    -- paint tool while hovering a lane band (and not over our UI). ImGui only
    -- owns the cursor when it wants the mouse; the overlay is NoMouseInputs, so
    -- REAPER may re-assert the arrange cursor over the grid — verify live.
    --   Brush    → Hand       (paint/grab)
    --   Velocity → ResizeNS   (vertical velocity drag)
    --   Eraser   → NotAllowed (closest 'remove' glyph ImGui ships)
    if not ui_over and mx and my and reaper.ImGui_SetMouseCursor then
      local over_lane = false
      for _, lt in ipairs(lane_targets) do
        if my >= lt.y1 and my <= lt.y2 then over_lane = true break end
      end
      if over_lane then
        reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_Hand())
      end
    end

    -- Phase 4: paint mode handles mouse input when active.
    paint_mode.Update(ctx, lane_targets, coords)

    -- Phantom-cell pass: paint_mode.Update ran AFTER the renderer this frame, so
    -- any note just inserted wouldn't be drawn until next frame (a ~1-frame
    -- lag). Draw those cells now, to THIS frame's drawlist, so they appear on
    -- the click frame. Next frame the renderer draws them for real; the list is
    -- already drained, so no double-draw persists.
    if paint_mode.TakeJustPainted then
      local jp = paint_mode.TakeJustPainted()
      if jp then
        for _, rec in ipairs(jp) do
          for _, lt in ipairs(lane_targets) do
            if lt.track == rec.track and lt.item_top and lt.cells_y2 then
              local cx1 = coords.Snap(coords.TimeToPixel(rec.t_start))
              local cx2 = coords.Snap(coords.TimeToPixel(rec.t_end))
              if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
              local cy1, cy2
              if lt.piano and lt.sub_row_h and lt.sub_row_h > 0 and lt.note_hi then
                cy1 = lt.item_top + (lt.note_hi - rec.pitch) * lt.sub_row_h + 1
                cy2 = cy1 + lt.sub_row_h - 1
              else
                cy1, cy2 = lt.item_top, lt.cells_y2
              end
              if cy2 > cy1 and cx2 > cx1 then
                renderer.DrawCellRect(dl, cx1, cy1, cx2, cy2, lt.pad_r, lt.pad_g, lt.pad_b, rec.vel)
              end
              break
            end
          end
        end
      end
    end

    -- ── Key pass-throughs ────────────────────────────────────────────────
    -- ReaImGui captures keyboard while one of its windows has focus, so the
    -- usual REAPER shortcuts (transport, undo, navigation) would silently
    -- die in the overlay. Re-fire each as a Main_OnCommand using the action
    -- IDs that match REAPER's default bindings. Paint mode itself only
    -- watches mouse + bare modifier keys (Shift/Ctrl/Alt) so forwarding
    -- character keys here doesn't collide with its own input handling.
    --
    -- Two global guards keep these well-behaved:
    --   * IsAnyItemActive(ctx) — bails when an overlay button is being held
    --     or a slider is being dragged, so those gestures aren't double-fed.
    --   * IsKeyPressed(...,repeat=false) — fires only on the key-down
    --     transition, never on auto-repeat (no transport hammering).
    if not reaper.ImGui_IsAnyItemActive(ctx)
       and not (settings_win.IsCapturingKey and settings_win.IsCapturingKey()) then
      -- Registry-driven dispatch (Feature A2). Each action's effective chord
      -- (user override from settings_store `keymap`, else the registry
      -- default) is a single `mods | key` int. IsKeyChordPressed compares the
      -- modifier set EXACTLY and fires once per key-down (no auto-repeat), so
      -- Ctrl+Z does not also trigger on Ctrl+Alt+Z. `sel`-marked actions only
      -- fire when a note selection exists.
      local _sel_n = paint_mode.SelectionCount and paint_mode.SelectionCount() or 0
      for _, act in ipairs(keymap.Registry) do
        if not (act.sel and _sel_n == 0) then
          local c = keymap.EffectiveChord(act.id)
          if keymap.IsChordPressed(ctx, c) then
            local fn = KEYMAP_HANDLERS[act.id]
            if fn then fn() end
          end
        end
      end
    end

    -- ── External command queue (focus-independent hotkeys) ───────────────
    -- A companion action posts cmd+nonce to ExtState. We consume each nonce
    -- once. When the overlay is FOCUSED, ImGui already handled the key above,
    -- so we just swallow the nonce; when UNFOCUSED, ImGui never saw the key,
    -- so we run the command here. This keeps exactly one execution per press
    -- regardless of whether ReaImGui forwarded the key to REAPER.
    do
      local nonce = reaper.GetExtState(CMD_SECTION, 'cmd_nonce')
      if nonce ~= '' and nonce ~= last_cmd_nonce then
        last_cmd_nonce = nonce
        if not overlay.IsFocused() then
          local cmd = reaper.GetExtState(CMD_SECTION, 'cmd')
          if cmd == 'copy' then
            paint_mode.CopySelection()
          elseif cmd == 'cut' then
            paint_mode.CutSelection()
          elseif cmd == 'paste' then
            local _playing = (reaper.GetPlayState() & 1) == 1
            local _at = _playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
            paint_mode.PasteSelection(coords.SnapDownToCell(_at))
          elseif cmd == 'dup_sel' then
            paint_mode.DuplicateSelection()
          elseif cmd == 'dup_bar_all' then
            lane_tools.DuplicateBarAllLanes()
          elseif cmd == 'dup_bar_lane' then
            local _l = lane_tools.GetSelectedLane()
            if _l then lane_tools.DuplicateBarToNext(_l)
            elseif reaper.Help_Set then reaper.Help_Set('EON DM: select a Drum Matrix track first', false) end
          elseif cmd == 'stamp_pattern' then
            local _playing = (reaper.GetPlayState() & 1) == 1
            local _at = _playing and reaper.GetPlayPosition() or reaper.GetCursorPosition()
            pattern_regions.StampCurrent(coords.SnapDownToCell(_at))
          elseif cmd == 'next_pattern' then
            pattern_regions.Next()
          elseif cmd == 'prev_pattern' then
            pattern_regions.Prev()
          elseif cmd == 'new_pattern' then
            pattern_regions.New(nil)
          elseif cmd == 'song_play' then
            pattern_song.SongToggle()
          elseif cmd == 'song_loop' then
            pattern_song.ToggleLoop()
          elseif cmd == 'song_add' then
            local _cur = pattern_regions.GetCurrent()
            if _cur then pattern_song.SongAppend(_cur)
            elseif reaper.Help_Set then reaper.Help_Set('EON DM: no current pattern to add', false) end
          elseif cmd == 'toggle_manager' then
            pattern_manager.Toggle()
          end
        end
      end
    end

    end   -- close `if dl then`

    overlay.EndFrame()
  end

  -- ---- Settings cog: standalone ImGui window top-right of arrange.
  -- Separate window so it doesn't inherit the overlay's NoMouseInputs flag
  -- (clicks work regardless of paint mode). Sized big enough to spot easily.
  if L and T and R then
    local COG_BTN  = 44   -- settings button size (px)
    local COG_PAD  = 4
    local CLOSE_H  = 22   -- dedicated "close overlay" button height
    local COG_GAP  = 4
    local COG_WIN  = COG_BTN + COG_PAD * 2
    -- Tall enough to stack the gear button + a close button beneath it.
    local COG_WIN_H = COG_PAD * 2 + COG_BTN + COG_GAP + CLOSE_H
    reaper.ImGui_SetNextWindowPos(ctx, R - COG_WIN - 4, T + 4)
    reaper.ImGui_SetNextWindowSize(ctx, COG_WIN, COG_WIN_H)
    local cog_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoResize()
                    | reaper.ImGui_WindowFlags_NoMove()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoSavedSettings()
                    | reaper.ImGui_WindowFlags_NoFocusOnAppearing()
                    | reaper.ImGui_WindowFlags_NoDocking()
                    | reaper.ImGui_WindowFlags_NoBackground()
                    | reaper.ImGui_WindowFlags_NoCollapse()
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), COG_PAD, COG_PAD)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), COG_BTN / 2)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), COG_PAD, COG_GAP)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x222222C0)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x555555FF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0xFF6666FF)
    if reaper.ImGui_Begin(ctx, 'EON_DM_Cog', false, cog_flags) then
      -- Settings toggle. Label: closed = three dim dots, open = X.
      local label = settings.IsWindowOpen() and 'X' or '...'
      if reaper.ImGui_Button(ctx, label, COG_BTN, COG_BTN) then
        settings.ToggleWindow()
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, settings.IsWindowOpen()
          and 'Close EON Drum Matrix settings'
          or  'Open EON Drum Matrix settings')
      end
      -- Dedicated "close the whole overlay" button (red), beneath the gear. Sets
      -- the same overlay_close flag the Swing GRID button / bridge use; the main
      -- loop consumes it next frame and exits gracefully (atexit restores state).
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x802020D0)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xCC3333FF)
      if reaper.ImGui_Button(ctx, 'X##dm_close', COG_BTN, CLOSE_H) then
        reaper.SetExtState('EON_DRUM_MATRIX', 'overlay_close', '1', false)
      end
      if reaper.ImGui_IsItemHovered(ctx) then
        reaper.ImGui_SetTooltip(ctx, 'Close Drum Matrix')
      end
      reaper.ImGui_PopStyleColor(ctx, 2)
      reaper.ImGui_End(ctx)
    end
    reaper.ImGui_PopStyleColor(ctx, 3)
    reaper.ImGui_PopStyleVar(ctx, 3)
  end

  -- ---- Pattern bar (#4): its own ImGui window just left of the cog, so the
  -- buttons work regardless of paint mode (the overlay window is NoMouseInputs
  -- when paint is off). Patterns are visible REAPER regions. Drawn here
  -- alongside the cog.
  if L and T and R and settings.Get('show_pattern_bar') and not settings.Get('minimal_mode') then
    pattern_bar.Render(ctx, L, T, R, B)
  end

  -- ---- Grid cog (#5): tiny standalone window showing the current project grid
  -- division; hover + wheel changes it. Its own window (not the NoMouseInputs
  -- overlay) so the wheel works whether or not paint mode is on. Opt-out via
  -- the 'grid_widget_enabled' setting.
  if L and T and R and settings.Get('grid_widget_enabled') and not settings.Get('minimal_mode') then
    grid_widget.Render(ctx, L, T, R, B)
  end

  -- ---- Pattern Manager: dockable panel (own top-level window). No-op unless
  -- the user has opened it. Data shared with the pattern bar (regions + song).
  safety.SafePcall('pattern_manager.Render', pattern_manager.Render, ctx)

  -- ---- Settings window: independent floating ImGui window. Drawn AFTER the
  -- overlay's End so it doesn't inherit the NoMouseInputs flag. The window
  -- is shown only while the toggle action has flipped the open flag.
  if settings.IsWindowOpen() then
    settings_win.Draw(ctx, { L = L, T = T, R = R, B = B })
  end
end

-- Public MainLoop — pcall-protected so a single bad frame doesn't kill the
-- defer. Caches are also purged each tick (cheap) so stale take pointers
-- don't accumulate when items are deleted externally. Lock TTL is refreshed
-- so another instance can't steal the singleton while we're still alive.
local function MainLoop()
  -- External close request (Swing GRID button / bridge sets this ExtState).
  -- Self-exit gracefully by NOT re-arming the defer: ending the chain triggers
  -- atexit(Cleanup) below, which releases the singleton lock, restores the
  -- project grid, and clears the toolbar toggle state. Clear the flag on
  -- consume so a later re-open isn't immediately closed by a stale '1'.
  if reaper.GetExtState('EON_DRUM_MATRIX', 'overlay_close') == '1' then
    reaper.SetExtState('EON_DRUM_MATRIX', 'overlay_close', '', false)
    return
  end

  safety.RefreshScriptLock('main_overlay')

  safety.SafePcall('MainLoopBody', MainLoopBody)

  -- Song-mode driver: keeps the next pattern region queued via GoToRegion so
  -- the chain plays one after another. Runs every frame, independent of overlay
  -- focus or paint mode; cheap no-op when no song is playing.
  safety.SafePcall('pattern_song.SongTick', pattern_song.SongTick)

  -- Pointer-validity sweeps — pcall'd individually so one bad cache can't
  -- starve the others.
  safety.SafePcall('midi_cache.PurgeStale',     midi_cache.PurgeStale)
  safety.SafePcall('lane_integrity.PurgeStale', lane_integrity.PurgeStale)
  safety.SafePcall('selection.PurgeStale',      selection.PurgeStale)

  r.defer(MainLoop)
end

r.defer(MainLoop)
