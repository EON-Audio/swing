-- paint_mode.lua
-- EON Drum Matrix v0.x - Phase 4: Paint Mode Handler
--
-- Owns paint-mode toggle (persisted to ExtState), per-frame mouse handling,
-- and MIDI mutation (insert/delete notes) with auto-creation of MIDI items.
--
-- HARD CONTRACT (read before editing):
--   1. Every MIDI_InsertNote / MIDI_DeleteNote MUST be followed by
--      MIDI_Sort(take) AND UpdateItemInProject(item).
--   2. Undo_BeginBlock opens on drag-start; Undo_EndBlock closes on
--      drag-release. ONE block per gesture.
--   3. Typed MIDI API only (MIDI_GetNote / MIDI_InsertNote / MIDI_DeleteNote).
--      NEVER use MIDI_GetEvt / MIDI_InsertEvt.
--   4. NO globals - all state is module-scoped.
--
-- ExtState contract:
--   Section "EON_DRUM_MATRIX", Key "paint_mode", Value "1" or "0".

local M = {}

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local settings    = dofile(_SCRIPT_DIR .. 'settings_store.lua')
local lane_tools     = dofile(_SCRIPT_DIR .. 'lane_tools.lua')
local category       = dofile(_SCRIPT_DIR .. 'category.lua')
local preset_lib     = dofile(_SCRIPT_DIR .. 'preset_library.lua')
local lane_integrity = dofile(_SCRIPT_DIR .. 'lane_integrity.lua')
local selection     = dofile(_SCRIPT_DIR .. 'selection.lua')
local grid          = dofile(_SCRIPT_DIR .. 'grid.lua')

-- Multi-cell rectangle selection state (Phase D / multi-select).
-- Ctrl+drag draws a rectangle; on release every painted note whose cell
-- overlaps the rect is added to the selection.
local select_rect_active = false
local select_rect_ax, select_rect_ay = 0, 0   -- anchor (drag start)
local select_rect_bx, select_rect_by = 0, 0   -- current mouse during drag

-- Expose selection module to other paint_mode subscribers (render path).
M._selection_module = selection

-- Slots toolbar (#4) highlight-clear hook. Injected by eon_drum_matrix so the
-- SAME slots_strip module instance (and its last_loaded_letter state) is
-- notified. We must NOT dofile slots_strip here: that would create a SECOND
-- copy with its own state, and clearing the highlight on the copy would leave
-- the rendered strip still showing a stale "recalled" badge. Called on any
-- successful note mutation (paint/erase/velocity/length) so the lanes no
-- longer match the recalled slot.
local _note_user_edit = nil
function M.SetNoteUserEditHook(fn) _note_user_edit = fn end
local function note_user_edit()
  if _note_user_edit then _note_user_edit() end
end

-- Last preset applied per LANE TRACK (keyed by track GUID — handles parallel
-- kits where pad_index can collide). Session-only; cleared on restart.
local last_preset_by_track = {}

-- Name filter for the cog Patterns submenu. Only shown when a (genre, category)
-- cell has many presets (post-import); session-only.
local pattern_filter = ''
local PATTERN_FILTER_THRESHOLD = 12

-- Phase F: graph-editor strip drag state. Independent from cell paint drag.
local strip_drag_active = false
local strip_drag_take   = nil
local strip_drag_idx    = nil
local strip_drag_strip  = nil   -- captured strip rect

-- Phase 5 (Length painting): drag the right edge of a cell to extend / shrink
-- its note's length. Edge detection: cursor within EDGE_PIXELS of the cell's
-- right edge when LMB is clicked enters this mode instead of toggle.
local EDGE_PIXELS = 6   -- right-edge grab zone for length-drag (catchable)
local length_drag_active   = false
local length_drag_take     = nil
local length_drag_idx      = nil
local length_drag_start_t  = 0      -- the note's start time (anchor)
local length_drag_min_len  = 0      -- smallest allowed length (one tick)
local length_drag_grid_qn  = 0      -- frozen grid divider (QN) at drag-start
                                    -- (case #14: user cycling grid mid-drag
                                    -- previously caused the snapped end to
                                    -- jump). Snapshot once, use for the
                                    -- entire gesture.
local length_drag_edge     = 'right' -- 'right' (move end) | 'left' (move start)
local length_drag_end_t    = 0      -- note's fixed END time (anchor for left-edge)

-- Note-move drag (piano lanes only): grab a note BODY and reposition it to a
-- new row (pitch) + grid-snapped time. Click-vs-drag: a press that never moves
-- past NOTE_MOVE_THRESHOLD px is treated as a normal toggle (delete) on
-- release, preserving drum-style click-to-remove. The move is previewed with a
-- ghost rect and committed in ONE MIDI_SetNote on release (no per-frame
-- re-indexing). length_drag claims right-edge clicks first, so this only ever
-- arms on a body click.
local NOTE_MOVE_THRESHOLD  = 3
local note_move_active     = false
local note_move_started    = false   -- moved past threshold this gesture?
local note_move_take       = nil
local note_move_idx        = nil
local note_move_len_ppq    = 0        -- preserved musical duration
local note_move_orig_pitch = nil      -- grabbed note's pitch at drag-start
local note_move_orig_ppq_s = nil      -- grabbed note's start ppq at drag-start
local note_move_orig_vel   = 100      -- grabbed note's velocity (for duplicate)
local note_move_dup        = false    -- Shift held at grab → duplicate, don't move
local note_move_lt         = nil      -- lane geometry for Y->pitch + ghost
local note_move_anchor_mx  = 0
local note_move_anchor_my  = 0

-- Note-draw drag (piano lanes only): FL draw-with-length. Mousedown on EMPTY
-- space arms a draw; a plain click commits a 1-grid-step note, a drag sets the
-- length (cursor-X) and pitch (cursor-Y). Previewed with a ghost, committed in
-- ONE InsertNoteAtCell on release. Item is auto-created on commit, not mousedown.
local note_draw_active     = false
local note_draw_started    = false
local note_draw_lt         = nil
local note_draw_anchor_t   = 0        -- the note's start time (snapped cell)
local note_draw_anchor_mx  = 0
local note_draw_anchor_my  = 0

-- Lane mute/solo bulk-drag. The first click toggles the lane's state; while
-- the button stays held, every other lane's matching button the cursor crosses
-- gets set to that SAME target state. One Undo block per drag.
local ms_drag_active   = false   -- a drag is in progress
local ms_drag_kind     = nil     -- 'mute' | 'solo'
local ms_drag_target_v = 0       -- value to write (B_MUTE: 0/1; I_SOLO: 0/2)
local ms_drag_touched  = {}      -- { [track] = true } so a lane isn't toggled twice

local function reset_ms_drag()
  ms_drag_active   = false
  ms_drag_kind     = nil
  ms_drag_target_v = 0
  ms_drag_touched  = {}
end

-- Set by the main script each frame: true when the mouse is over the cog button
-- or the open settings window, so click-initiation in Update is suppressed and
-- the click can't bleed through into the lane behind that UI.
local mouse_blocked = false
function M.SetMouseBlocked(v) mouse_blocked = v and true or false end

-- Compute velocity (1..127) from a mouse-Y inside a strip rect.
local function velocity_from_strip_y(my, strip)
  if not strip then return 100 end
  if my <= strip.y1 then return 127 end
  if my >= strip.y2 then return 1   end
  local ratio = (strip.y2 - my) / strip.h
  local v = math.floor(ratio * 127 + 0.5)
  if v < 1   then v = 1   end
  if v > 127 then v = 127 end
  return v
end

local function set_note_velocity(take, idx, vel)
  if not take or not idx then return end
  reaper.MIDI_SetNote(take, idx, nil, nil, nil, nil, nil, nil, vel, true)
  reaper.MIDI_Sort(take)
  local item = reaper.GetMediaItemTake_Item(take)
  if item then reaper.UpdateItemInProject(item) end
  note_user_edit()
end

-- Grid-division cycling lives in lib/grid.lua (shared with the grid-cog widget
-- + the EON_DM_CycleGrid keybind; preserves project swing). The paint-mode
-- wheel handler in M.Update calls grid.Cycle directly.

-- =============================================================================
-- Per-lane tools popup (Alt + Right-click on a lane)
-- =============================================================================
local pending_tools_lane = nil
local TOOLS_POPUP_ID     = 'eon_dm_lane_tools'

-- ============================================================================
-- Module-scoped state (NO GLOBALS)
-- ============================================================================
local EXT_SECTION = "EON_DRUM_MATRIX"
local EXT_KEY     = "paint_mode"

local initialized        = false
local active             = false
local drag_active        = false
local drag_mode          = nil   -- 'insert' | 'delete'
local drag_button        = 0     -- 0 = LMB (paint/erase per cell state), 1 = RMB (erase-drag)
local drag_anchor_time   = 0
local drag_last_time     = nil
local drag_anchor_pitch  = nil
local drag_anchor_track  = nil
local drag_anchor_lane_info = nil
local drag_anchor_take   = nil
local drag_anchor_item_color = nil   -- dim pad-color int for auto-created items
local drag_created_items     = {}    -- [item] = true; items auto-created this drag
-- Piano-mode paint state. When the anchor lane is piano-mode, the painted pitch
-- follows the mouse-Y row instead of being the fixed pad pitch. drag_anchor_lt
-- snapshots the lane geometry at drag-start; current_paint_pitch is refreshed
-- from mouse-Y each frame so a diagonal drag paints a chromatic run.
local drag_anchor_piano      = false
local drag_anchor_lt         = nil
local current_paint_pitch    = nil
-- Resolved effective swing subdivision (QN) for the lane under the active drag,
-- or nil when the lane follows the project grid. Snapshotted at gesture start so
-- ApplyAtCell / PaintCellsBetween size steps and walk cells on the lane's grid.
local drag_anchor_subdiv     = nil

-- Phantom-cell list (closes the 1-frame paint lag). paint_mode.Update runs
-- AFTER the renderer each frame, so a note inserted now first appears next
-- frame. We record each inserted cell here; the main loop drains this list
-- right after Update and draws the cells to the SAME frame's drawlist, so the
-- painted cell shows up on the click frame. Drained every frame (see
-- M.TakeJustPainted) — never accumulates.
local just_painted = {}

-- Copy/paste clipboard (Wave C). Each entry stores the note in PROJECT TIME
-- (portable across takes/tempo) plus its source track; clipboard_anchor is the
-- earliest start so paste can offset the whole group to the edit cursor.
local clipboard = {}
local clipboard_anchor = 0
local pending_offs           = {}    -- list of { off_at, pitch } scheduled note-offs

-- Live trigger: when settings.Get('live_trigger') is true, every inserted
-- note also fires a one-shot Note On via REAPER's virtual MIDI keyboard
-- input (StuffMIDIMessage mode 1). The kit track must have input = Virtual
-- MIDI keyboard, be armed, and have monitor input on for the sound to reach
-- Swing. Default off.
local function live_trigger_enabled()
  return settings.Get('live_trigger') == true
end

local function send_live_note(pad_pitch, vel)
  if not pad_pitch then return end
  if not live_trigger_enabled() then return end
  local NOTE_ON = 0x90  -- channel 0 == MIDI channel 1
  reaper.StuffMIDIMessage(1, NOTE_ON, pad_pitch, vel or 100)
  table.insert(pending_offs, {
    off_at = reaper.time_precise() + 0.15,
    pitch  = pad_pitch,
  })
end

local function process_pending_offs()
  if #pending_offs == 0 then return end
  local now = reaper.time_precise()
  local NOTE_OFF = 0x80
  for i = #pending_offs, 1, -1 do
    if pending_offs[i].off_at <= now then
      reaper.StuffMIDIMessage(1, NOTE_OFF, pending_offs[i].pitch, 0)
      table.remove(pending_offs, i)
    end
  end
end

-- ============================================================================
-- Internal helpers (NOT exposed on M)
-- ============================================================================

local function bar_end_time(start_time, bar_count)
  local start_qn = reaper.TimeMap_timeToQN(start_time)
  local start_meas = math.floor(reaper.TimeMap_QNToMeasures(0, start_qn))
  local _, end_qn = reaper.TimeMap_GetMeasureInfo(0, start_meas + bar_count)
  return reaper.TimeMap_QNToTime(end_qn)
end

-- Length (in seconds) of one grid step starting at `time`. Tempo-aware.
-- `gdiv_override` (optional, QN) lets a lane with its own swing subdivision ask
-- for a finer step so swung 1/16 notes don't overlap; absent -> project grid
-- (the default, identical to before).
local function grid_length(time, gdiv_override)
  local grid_div_qn = gdiv_override
  if not grid_div_qn or grid_div_qn <= 0 then
    local _, gd = reaper.GetSetProjectGrid(0, false)
    grid_div_qn = gd
  end
  if not grid_div_qn or grid_div_qn == 0 then grid_div_qn = 0.25 end
  local qn = reaper.TimeMap_timeToQN(time)
  return reaper.TimeMap_QNToTime(qn + grid_div_qn) - time
end

-- Find an existing MIDI item on `track` whose [start, end] contains `time`.
-- If none, create a 1-bar item starting AT `time` and style it so it visually
-- blends in: dim pad-colored background + empty take name. The 1-bar default
-- gives the drag enough canvas to paint into; the item is trimmed to fit its
-- actual MIDI content on drag-release (see TrimItemToFitNotes).
-- Returns (item, take, was_newly_created).
local function GetOrCreateMidiItemAt(track, time, dim_item_color)
  local item_count = reaper.CountTrackMediaItems(track)

  -- 1) Click is INSIDE an existing item -> use it as-is.
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local item_end   = item_start + item_len
      if time >= item_start and time <= item_end then
        return item, take, false
      end
    end
  end

  -- 2) Click is OUTSIDE every item -> find the closest existing MIDI item
  --    by distance from `time`. If the click is to the RIGHT of that item,
  --    extend it to cover the click (auto-extend behavior).
  local nearest_item, nearest_take, nearest_dist = nil, nil, math.huge
  local nearest_start, nearest_end = 0, 0
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      local item_end   = item_start + item_len
      local dist
      if time < item_start then dist = item_start - time
      else                       dist = time - item_end end
      if dist < nearest_dist then
        nearest_item   = item
        nearest_take   = take
        nearest_dist   = dist
        nearest_start  = item_start
        nearest_end    = item_end
      end
    end
  end
  if nearest_item and time >= nearest_start - 1e-6 and settings.Get('auto_extend') then
    -- We only auto-extend the right edge. Moving D_POSITION (the left edge)
    -- would shift the take origin and break PPQ positions of existing notes.
    local need_end = time + grid_length(time)
    if need_end > nearest_end then
      reaper.SetMediaItemInfo_Value(nearest_item, 'D_LENGTH', need_end - nearest_start)
      reaper.UpdateItemInProject(nearest_item)
    end
    return nearest_item, nearest_take, false
  end

  -- 3) No item to extend (or click is before the only item) -> fresh-create
  --    an N-bar item starting at the click cell. Defensive fallback.
  local bars       = settings.Get('new_item_bars') or 4
  local start_time = time
  -- Meter-aware bar span — handles 3/4, 6/8 and meter changes inside the
  -- item, unlike the old `start_qn + bars*4` which assumed 4 QN per bar.
  local end_time   = bar_end_time(start_time, bars)
  local new_item   = reaper.CreateNewMIDIItemInProj(track, start_time, end_time, false)
  if not new_item then return nil, nil, false end
  local new_take = reaper.GetActiveTake(new_item)
  if dim_item_color then
    reaper.SetMediaItemInfo_Value(new_item, 'I_CUSTOMCOLOR', dim_item_color)
  end
  if new_take then
    reaper.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME', '', true)
  end
  return new_item, new_take, true
end

-- Trim an item's right edge to match the latest note end inside it. Called on
-- drag-release for items the drag auto-created, so single-click items don't
-- leave a 1-bar "tail" stretching past the only note.
local function TrimItemToFitNotes(item)
  if not item or not reaper.ValidatePtr(item, 'MediaItem*') then return end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then return end
  local _, note_count = reaper.MIDI_CountEvts(take)
  if note_count == 0 then return end
  local max_end = 0
  for i = 0, note_count - 1 do
    local ok, _, _, _, ppq_e = reaper.MIDI_GetNote(take, i)
    if ok then
      local t = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
      if t > max_end then max_end = t end
    end
  end
  local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local new_len = max_end - item_start
  if new_len > 0 then
    reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', new_len)
    reaper.UpdateItemInProject(item)
  end
end

-- Locate a note in `take` at given pitch whose start falls inside the grid
-- cell [cell_start, cell_end). Step-sequencer semantics: each cell holds at
-- most one trigger; click toggles it. Returns the note index, or nil.
local function NoteInCell(take, pitch, cell_start, cell_end)
  if not take then return nil end
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local ok, _, _, startppq, _, _, np, _ = reaper.MIDI_GetNote(take, i)
    if ok and np == pitch then
      local nt = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
      if nt >= cell_start - 1e-6 and nt < cell_end - 1e-6 then
        return i
      end
    end
  end
  return nil
end

-- Piano-mode pitch from a mouse-Y inside a lane. Drum lanes (or lanes without
-- resolved piano geometry) return the single pad pitch. Mirrors the renderer:
-- the top row is note_hi, increasing downward to note_lo at the bottom (see
-- render_drum_matrix.PianoRowGeometry / render_lane_piano).
local function lane_pitch_at_y(lt, my)
  if lt and lt.piano and lt.note_lo and lt.note_hi
     and lt.item_top and lt.sub_row_h and lt.sub_row_h > 0 then
    local off   = math.floor((my - lt.item_top) / lt.sub_row_h)
    local pitch = lt.note_hi - off
    if pitch < lt.note_lo then pitch = lt.note_lo end
    if pitch > lt.note_hi then pitch = lt.note_hi end
    return pitch
  end
  return lt and lt.lane_info and lt.lane_info.pad_pitch
end

-- During a GROUPED note-move drag, preview a ghost rect for every OTHER
-- selected note (the grabbed note already drew its own ghost), offset by the
-- same (qn_delta, d_pitch) the release-time selection.MoveBy will apply — so
-- the preview matches the commit exactly. Reads each note's real length and
-- lane geometry per frame; hand-drag selections are small so the per-note
-- MIDI scan is cheap.
local function draw_group_move_ghosts(ctx, lane_targets, coords, qn_delta, d_pitch,
                                      skip_take, skip_ppq_s, skip_pitch)
  if not (ctx and lane_targets and coords) or selection.Count() < 2 then return end
  local lt_by_track = {}
  for _, lt in ipairs(lane_targets) do
    if lt.track then lt_by_track[tostring(lt.track)] = lt end
  end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  for _, e in ipairs(selection.GetAll()) do
    local is_skip = (e.take == skip_take) and (e.pitch == skip_pitch)
      and (math.abs(e.ppq_s - (skip_ppq_s or -1e18)) < 1)
    if not is_skip and reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      local ppq_e = nil
      for i = 0, ncount - 1 do
        local ok, _, _, ps, pe, _, p = reaper.MIDI_GetNote(e.take, i)
        if ok and p == e.pitch and math.abs(ps - e.ppq_s) < 1 then ppq_e = pe; break end
      end
      if ppq_e then
        local proj_s = reaper.MIDI_GetProjTimeFromPPQPos(e.take, e.ppq_s)
        local proj_e = reaper.MIDI_GetProjTimeFromPPQPos(e.take, ppq_e)
        local ns = (qn_delta ~= 0)
          and reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(proj_s) + qn_delta) or proj_s
        local ne = (qn_delta ~= 0)
          and reaper.TimeMap_QNToTime(reaper.TimeMap_timeToQN(proj_e) + qn_delta) or proj_e
        local npitch = e.pitch + d_pitch
        if npitch < 0 then npitch = 0 elseif npitch > 127 then npitch = 127 end
        local item  = reaper.GetMediaItemTake_Item(e.take)
        local track = item and reaper.GetMediaItem_Track(item)
        local lt    = track and lt_by_track[tostring(track)]
        if lt then
          local cx1 = coords.Snap(coords.TimeToPixel(ns))
          local cx2 = coords.Snap(coords.TimeToPixel(ne))
          if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
          local cy1, cy2
          if lt.sub_row_h and lt.sub_row_h > 0 and lt.note_hi then
            cy1 = lt.item_top + (lt.note_hi - npitch) * lt.sub_row_h + 1
            cy2 = cy1 + lt.sub_row_h - 1
          else
            cy1, cy2 = lt.item_top, lt.cells_y2
          end
          if cy1 and cy2 and cy2 > cy1 then
            reaper.ImGui_DrawList_AddRectFilled(dl, cx1, cy1, cx2, cy2, 0xFFFFFF33, 0)
            reaper.ImGui_DrawList_AddRect      (dl, cx1, cy1, cx2, cy2, 0xFFFFFFCC, 0, 0, 2)
          end
        end
      end
    end
  end
end

-- Range variant of NoteInCell for piano lanes, where one time cell can hold
-- notes at several pitches. Returns the first note in [lo..hi] whose start is
-- inside the cell, as (idx, pitch), or nil.
local function NoteInCellRange(take, lo, hi, cell_start, cell_end)
  if not take then return nil end
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local ok, _, _, startppq, _, _, np = reaper.MIDI_GetNote(take, i)
    if ok and np >= lo and np <= hi then
      local nt = reaper.MIDI_GetProjTimeFromPPQPos(take, startppq)
      if nt >= cell_start - 1e-6 and nt < cell_end - 1e-6 then
        return i, np
      end
    end
  end
  return nil
end

-- Find a note at `pitch` whose [start,end] SPANS `time` (unlike NoteInCell, which
-- only matches notes that START in a given cell). Lets the user grab a long note
-- anywhere along its body, not just its head. Returns idx or nil.
local function find_note_at(take, pitch, time)
  if not take then return nil end
  local _, note_count = reaper.MIDI_CountEvts(take)
  for i = 0, note_count - 1 do
    local ok, _, _, ppq_s, ppq_e, _, np = reaper.MIDI_GetNote(take, i)
    if ok and np == pitch then
      local s = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
      local e = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
      if time >= s - 1e-6 and time < e - 1e-6 then return i end
    end
  end
  return nil
end

-- INVARIANT: Every MIDI_InsertNote MUST be followed by MIDI_Sort + UpdateItemInProject.
-- Optional ghost_vel override (used by Shift+click ghost-note paint).
local function InsertNoteAtCell(take, pitch, time, length, ghost_vel)
  if not take then return end
  local vel = ghost_vel or settings.Get('default_velocity') or 100
  if vel < 1 then vel = 1 elseif vel > 127 then vel = 127 end
  local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, time)
  local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, time + length)
  reaper.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0, pitch, vel, false)
  reaper.MIDI_Sort(take)
  local item = reaper.GetMediaItemTake_Item(take)
  if item then reaper.UpdateItemInProject(item) end
  -- Record for the phantom-cell draw so the cell shows on the click frame.
  local track = item and reaper.GetMediaItem_Track(item)
  if track then
    just_painted[#just_painted + 1] =
      { track = track, t_start = time, t_end = time + length, pitch = pitch, vel = vel }
  end
  -- Optional live preview — only fires when the user has toggled it on.
  send_live_note(pitch, vel)
  note_user_edit()
end

-- Compute the velocity to use for a paint click given current keyboard mods.
-- Shift+click = ghost note at settings.ghost_velocity_factor of default vel.
local function paint_velocity_for_mods(ctx)
  local default_vel = settings.Get('default_velocity') or 100
  local mods = reaper.ImGui_GetKeyMods(ctx) or 0
  if (mods & reaper.ImGui_Mod_Shift()) ~= 0 then
    local factor = settings.Get('ghost_velocity_factor') or 0.4
    if factor < 0 then factor = 0 elseif factor > 1 then factor = 1 end
    return math.max(1, math.floor(default_vel * factor + 0.5))
  end
  return default_vel
end

-- INVARIANT: Every MIDI_DeleteNote MUST be followed by MIDI_Sort + UpdateItemInProject.
local function DeleteNoteAtCell(take, note_idx)
  if not take or not note_idx then return end
  reaper.MIDI_DeleteNote(take, note_idx)
  reaper.MIDI_Sort(take)
  local item = reaper.GetMediaItemTake_Item(take)
  if item then reaper.UpdateItemInProject(item) end
  note_user_edit()
end

-- Find the existing MIDI take whose item contains `time` on `track`, WITHOUT
-- creating anything. Used by erase so dragging across empty space never spawns
-- a MIDI item — you can only erase from items that already exist.
local function find_existing_take_at(track, time)
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local s = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local e = s + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    if time >= s and time < e then
      local take = reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then return take end
      return nil
    end
  end
  return nil
end

-- Apply current drag_mode at a particular cell-time on the anchor lane/track.
-- 'insert' is idempotent (no duplicates) and may auto-create/extend the item.
-- 'delete' is safe (no-op on empty cell) and NEVER creates an item.
local function ApplyAtCell(cell_start)
  if not drag_anchor_track or not drag_anchor_lane_info then return end
  -- Piano lanes paint at the mouse-Y row (current_paint_pitch, refreshed per
  -- frame); drum lanes paint at the fixed pad pitch.
  local pitch    = (drag_anchor_piano and current_paint_pitch) or drag_anchor_lane_info.pad_pitch
  -- Match the anchor click: a subdivision lane steps at its own g_eff (resolved
  -- once at gesture start into drag_anchor_subdiv) so a step-paint drag lays
  -- swung finer notes that don't overlap. nil = project grid (default lanes).
  local step_len = grid_length(cell_start, drag_anchor_subdiv)
  local cell_end = cell_start + step_len
  if drag_mode == 'insert' then
    local item, take, created = GetOrCreateMidiItemAt(drag_anchor_track, cell_start, drag_anchor_item_color)
    if not take then return end
    if created then drag_created_items[item] = true end
    local idx = NoteInCell(take, pitch, cell_start, cell_end)
    if not idx then
      InsertNoteAtCell(take, pitch, cell_start, step_len)
    end
  elseif drag_mode == 'delete' then
    -- Right-click erase-drag. NEVER creates an item (find_existing_take_at).
    local take = find_existing_take_at(drag_anchor_track, cell_start)
    if take then
      local idx = NoteInCell(take, pitch, cell_start, cell_end)
      if idx then DeleteNoteAtCell(take, idx) end
    end
  end
end

-- Paint every grid step between a and b (exclusive of a, inclusive of b).
-- QN-indexed walking: each cell_start is computed from an integer index *
-- grid_div_qn, so there's no float accumulation between cells. Direction-aware
-- so fast drags work in either direction and never skip a cell.
local function PaintCellsBetween(a, b)
  if a == b then return end
  -- Walk at the lane's own swing subdivision when it has one (snapshotted in
  -- drag_anchor_subdiv at gesture start); otherwise the project grid.
  local grid_div_qn = drag_anchor_subdiv
  if not grid_div_qn or grid_div_qn <= 0 then
    local _, gd = reaper.GetSetProjectGrid(0, false)
    grid_div_qn = gd
  end
  if not grid_div_qn or grid_div_qn == 0 then return end

  local a_qn = reaper.TimeMap_timeToQN(a)
  local b_qn = reaper.TimeMap_timeToQN(b)
  -- Cell index = which grid cell the time falls into (floor-snap).
  local a_idx = math.floor(a_qn / grid_div_qn + 1e-9)
  local b_idx = math.floor(b_qn / grid_div_qn + 1e-9)
  if a_idx == b_idx then return end

  if b_idx > a_idx then
    for idx = a_idx + 1, b_idx do
      ApplyAtCell(reaper.TimeMap_QNToTime(idx * grid_div_qn))
    end
  else
    for idx = a_idx - 1, b_idx, -1 do
      ApplyAtCell(reaper.TimeMap_QNToTime(idx * grid_div_qn))
    end
  end
end

local function find_lane_target_for_y(lane_targets, my)
  if not lane_targets then return nil end
  for i = 1, #lane_targets do
    local lt = lane_targets[i]
    if my >= lt.y1 and my <= lt.y2 then
      -- Honor per-lane lock (settings menu Pads tab). Locked lanes return nil
      -- so paint mode silently no-ops on clicks targeting them.
      if lt.lane_info and lt.lane_info.locked == true then return nil end
      return lt
    end
  end
  return nil
end

-- Variant that returns the lane EVEN if locked, plus a locked flag. Used by
-- the right-click handler so we can show "Lane locked" feedback instead of
-- silently no-op'ing — silent failure was confusing users into thinking
-- right-click was broken.
local function find_lane_target_for_y_with_lock(lane_targets, my)
  if not lane_targets then return nil, false end
  for i = 1, #lane_targets do
    local lt = lane_targets[i]
    if my >= lt.y1 and my <= lt.y2 then
      local locked = lt.lane_info and lt.lane_info.locked == true
      return lt, locked or false
    end
  end
  return nil, false
end

-- True when the mouse has wandered far outside the lane band (e.g. user
-- Alt-Tabbed mid-drag, or moused way above the timeline). Used to cancel
-- stuck drag states so a click somewhere else later doesn't finalize the
-- old gesture in the wrong place.
local function mouse_far_from_lanes(my, lane_targets, margin)
  if not lane_targets or #lane_targets == 0 then return false end
  margin = margin or 80
  local top_y    = lane_targets[1].y1
  local bottom_y = lane_targets[#lane_targets].y2
  return my < (top_y - margin) or my > (bottom_y + margin)
end

-- Snap a click time using whichever mode the user selected in settings. When
-- the painted lane (or, at 0, the project) has swing, the click snaps to the
-- SWUNG cell start so notes land under the swung grid lines.
local function snap_click_time(coords, raw_time, lane_info)
  local mode = settings.Get('snap_mode') or 'floor'
  if mode == 'off' then return raw_time end

  -- Effective swing: a non-zero lane swing wins; otherwise follow the project
  -- swing (GetSetProjectGrid swingmode/swingamt). On a power-of-2 grid this
  -- routes through the closed-form swung-cell snap. Swing collapses 'nearest'
  -- to floor — swung-cell step semantics are floor by nature.
  local _, gdiv, swingmode, swingamt = reaper.GetSetProjectGrid(0, false)
  -- Effective swing grid: a lane's own swing_subdiv (cog "Swing grid" combo)
  -- overrides the project grid; absent -> project grid (identical to before).
  local g_eff   = (coords.EffectiveSwingDivQN and coords.EffectiveSwingDivQN(lane_info)) or gdiv
  local lane_sw = (lane_info and tonumber(lane_info.swing_amount)) or 0
  local eff_sw  = 0
  if lane_sw ~= 0 then eff_sw = lane_sw
  elseif swingmode == 1 then eff_sw = tonumber(swingamt) or 0 end
  -- Route through the swung-cell snap when there's swing OR when this lane uses
  -- its own subdivision (so straight notes still land on the lane's finer grid).
  -- With eff_sw == 0 the snap reduces to a plain floor onto g_eff cells.
  local lane_subdiv = lane_info and lane_info.swing_subdiv and lane_info.swing_subdiv > 0
  if g_eff and g_eff > 0 and coords.IsSwingableDiv and coords.IsSwingableDiv(g_eff)
     and (eff_sw ~= 0 or lane_subdiv) then
    local cqn = coords.SwingSnapDownToCellQN(reaper.TimeMap_timeToQN(raw_time), g_eff, eff_sw)
    return reaper.TimeMap_QNToTime(cqn)
  end

  if     mode == 'floor'   then return coords.SnapDownToCell(raw_time)
  elseif mode == 'nearest' then return coords.SnapTimeToGrid(raw_time)
  else                          return raw_time end
end

local function reset_drag_state()
  drag_active             = false
  drag_mode               = nil
  drag_button             = 0
  drag_anchor_time        = 0
  drag_last_time          = nil
  drag_anchor_pitch       = nil
  drag_anchor_track       = nil
  drag_anchor_lane_info   = nil
  drag_anchor_take        = nil
  drag_anchor_item_color  = nil
  drag_created_items      = {}
  drag_anchor_piano       = false
  drag_anchor_lt          = nil
  drag_anchor_subdiv      = nil
  current_paint_pitch     = nil
end

-- True when an LMB press at (mx,my) lands on a note that's already selected.
-- Used to STOP the plain-click selection-clear in that case, so grabbing a
-- highlighted note becomes a group-move instead of a deselect. Read-only.
local function click_on_selected_note(lane_targets, mx, my, coords)
  local lt = find_lane_target_for_y(lane_targets, my)
  if not (lt and lt.track and coords) then return false end
  local t = coords.PixelToTime(mx)
  if not t then return false end
  local take = find_existing_take_at(lt.track, t)
  if not take then return false end
  local pitch = lane_pitch_at_y(lt, my)
  local idx = find_note_at(take, pitch, t)
  if not idx then return false end
  local ok, _, _, ppq_s = reaper.MIDI_GetNote(take, idx)
  return (ok and selection.Contains(take, ppq_s, pitch)) and true or false
end

local function reset_note_move()
  note_move_active   = false
  note_move_started  = false
  note_move_take     = nil
  note_move_idx      = nil
  note_move_len_ppq  = 0
  note_move_orig_pitch = nil
  note_move_orig_ppq_s = nil
  note_move_orig_vel = 100
  note_move_dup      = false
  note_move_lt       = nil
end

local function reset_note_draw()
  note_draw_active  = false
  note_draw_started = false
  note_draw_lt      = nil
  note_draw_anchor_t = 0
end

-- ============================================================================
-- Public API
-- ============================================================================

-- Drain the phantom-cell list: returns cells inserted since the last call and
-- clears it. Called by the main loop each frame, right after M.Update, to draw
-- just-painted cells on the current frame (see `just_painted` note above).
function M.TakeJustPainted()
  if #just_painted == 0 then return nil end
  local list = just_painted
  just_painted = {}
  return list
end

-- True while ANY paint-mode drag gesture is in progress (cell paint, velocity
-- strip, length edge, note move/draw, rectangle select, or mute/solo bulk
-- drag). The renderer queries this to suppress hover tooltips (#14) mid-drag —
-- a tooltip following the cursor during a drag is noise. Mirror of the
-- drag-cancel guard's combined condition in M.Update.
function M.IsAnyDragActive()
  return drag_active or strip_drag_active or length_drag_active
      or note_move_active or note_draw_active or select_rect_active
      or ms_drag_active
end

-- ── Selection editing (Wave C) — driven by the main loop's key handler ──────
function M.SelectionCount() return selection.Count() end

-- Nudge the selection: d_step grid cells in time, d_semi semitones in pitch.
function M.NudgeSelection(d_step, d_semi)
  if selection.Count() == 0 then return end
  reaper.Undo_BeginBlock()
  if d_step and d_step ~= 0 then
    local _, grid = reaper.GetSetProjectGrid(0, false)
    if grid and grid > 0 then selection.ShiftBy(d_step * grid) end
  end
  if d_semi and d_semi ~= 0 then selection.TransposeBy(d_semi) end
  reaper.Undo_EndBlock('EON DM: nudge selection', -1)
end

function M.DeleteSelection()
  if selection.Count() == 0 then return 0 end
  return selection.ClearSelected()
end

-- Snapshot the current selection into the clipboard (project-time coords).
function M.CopySelection()
  local all = selection.GetAll()
  if #all == 0 then return 0 end
  clipboard = {}
  local anchor = math.huge
  for _, e in ipairs(all) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local _, ncount = reaper.MIDI_CountEvts(e.take)
      for i = 0, ncount - 1 do
        local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(e.take, i)
        if ok and pitch == e.pitch and math.abs(ppq_s - e.ppq_s) < 1 then
          local item  = reaper.GetMediaItemTake_Item(e.take)
          local track = item and reaper.GetMediaItem_Track(item)
          local t_s   = reaper.MIDI_GetProjTimeFromPPQPos(e.take, ppq_s)
          local t_e   = reaper.MIDI_GetProjTimeFromPPQPos(e.take, ppq_e)
          clipboard[#clipboard + 1] =
            { track = track, t_start = t_s, t_end = t_e, pitch = pitch, vel = vel }
          if t_s < anchor then anchor = t_s end
          break
        end
      end
    end
  end
  clipboard_anchor = (anchor == math.huge) and 0 or anchor
  if #clipboard > 0 and reaper.Help_Set then
    reaper.Help_Set(string.format('EON DM: copied %d note(s)', #clipboard), false)
  end
  return #clipboard
end

-- Paste the clipboard so its earliest note lands at the edit cursor; each note
-- goes back onto its source track (item auto-created if needed). Selects the
-- pasted notes. Raw MIDI_InsertNote (no phantom/live-trigger side effects).
-- at_time = where the clipboard's EARLIEST note should land (mouse cell from
-- the key handler). Falls back to the edit cursor when nil.
function M.PasteSelection(at_time)
  if #clipboard == 0 then return 0 end
  local cursor = at_time or reaper.GetCursorPosition()
  if not cursor or cursor < 0 then cursor = 0 end
  reaper.Undo_BeginBlock()
  selection.Clear()
  local pasted = 0
  for _, c in ipairs(clipboard) do
    if c.track and reaper.ValidatePtr(c.track, 'MediaTrack*') then
      local new_s = cursor + (c.t_start - clipboard_anchor)
      local len   = c.t_end - c.t_start
      if len < 0.005 then len = 0.005 end
      local _, take = GetOrCreateMidiItemAt(c.track, new_s, nil)
      if take then
        local ppq_s = reaper.MIDI_GetPPQPosFromProjTime(take, new_s)
        local ppq_e = reaper.MIDI_GetPPQPosFromProjTime(take, new_s + len)
        reaper.MIDI_InsertNote(take, false, false, ppq_s, ppq_e, 0, c.pitch, c.vel, true)
        reaper.MIDI_Sort(take)
        local it = reaper.GetMediaItemTake_Item(take)
        if it then reaper.UpdateItemInProject(it) end
        selection.Add(take, ppq_s, c.pitch)
        pasted = pasted + 1
      end
    end
  end
  reaper.Undo_EndBlock(string.format('EON DM: paste %d note(s)', pasted), -1)
  if pasted > 0 and reaper.Help_Set then
    reaper.Help_Set(string.format('EON DM: pasted %d note(s) at cursor', pasted), false)
  end
  return pasted
end

-- Cut = copy then delete. Copy doesn't mutate, so DeleteSelection's own Undo
-- block is the whole gesture.
function M.CutSelection()
  if selection.Count() == 0 then return 0 end
  -- Outer block so the undo point reads "cut", not the nested ClearSelected
  -- block's "clear selected cells" (REAPER names the point after the outermost
  -- block). Copy doesn't mutate; the delete does the work.
  reaper.Undo_BeginBlock()
  M.CopySelection()
  local n = M.DeleteSelection()
  reaper.Undo_EndBlock(string.format('EON DM: cut %d note(s)', n), -1)
  return n
end

-- Duplicate the selection one bar to the right. DuplicateBy re-keys the
-- selection to the new copies, so repeated Ctrl+D tiles forward bar-by-bar.
-- The bar length is taken at the EARLIEST selected note (honors meter changes).
function M.DuplicateSelection()
  local all = selection.GetAll()
  if #all == 0 then return 0 end
  local t0 = math.huge
  for _, e in ipairs(all) do
    if reaper.ValidatePtr(e.take, 'MediaItem_Take*') then
      local t = reaper.MIDI_GetProjTimeFromPPQPos(e.take, e.ppq_s)
      if t < t0 then t0 = t end
    end
  end
  if t0 == math.huge then return 0 end
  -- Bar length at the earliest selected note, taken from its measure index
  -- directly (no boundary round-trip — that can mis-round to a 0 delta).
  local qn   = reaper.TimeMap_timeToQN(t0)
  local meas = math.floor(reaper.TimeMap_QNToMeasures(0, qn))
  local _, qs, qe = reaper.TimeMap_GetMeasureInfo(0, meas)
  local qn_delta  = qe - qs
  if qn_delta <= 0 then return 0 end
  return selection.DuplicateBy(qn_delta, 0)
end

function M.Init()
  local v = reaper.GetExtState(EXT_SECTION, EXT_KEY)
  active = (v == "1")
  initialized = true
  -- Case #17: drop any selection from a previous run. Lua module reload
  -- normally wipes this, but a deferred cached module wouldn't — explicit
  -- clear is cheap insurance.
  if selection and selection.Clear then selection.Clear() end
end

function M.IsActive()
  if not initialized then M.Init() end
  -- Always re-read ExtState so the external toggle action can flip us live.
  local v = reaper.GetExtState(EXT_SECTION, EXT_KEY)
  active = (v == "1")
  return active
end

function M.Set(on)
  active = on and true or false
  reaper.SetExtState(EXT_SECTION, EXT_KEY, active and "1" or "0", true)
  initialized = true
end

function M.Toggle()
  if not initialized then M.Init() end
  M.Set(not active)
  return active
end

function M.Update(ctx, lane_targets, coords)
  -- Always drain pending note-offs first (even when paint mode is off — if the
  -- user toggled paint mode mid-trigger, we still want to send the matching off).
  process_pending_offs()

  if not M.IsActive() then
    if drag_active then
      -- Paint mode turned off mid-drag: close the Undo block cleanly.
      reaper.Undo_EndBlock(string.format('EON DM: paint %s', tostring(drag_mode or 'cancel')), -1)
      reset_drag_state()
    end
    if strip_drag_active then
      reaper.Undo_EndBlock('EON DM: edit velocity in strip', -1)
      strip_drag_active = false
      strip_drag_take   = nil
      strip_drag_idx    = nil
      strip_drag_strip  = nil
    end
    if length_drag_active then
      reaper.Undo_EndBlock('EON DM: edit note length', -1)
      length_drag_active  = false
      length_drag_take    = nil
      length_drag_idx     = nil
      length_drag_start_t = 0
    end
    if note_move_active then
      reaper.Undo_EndBlock('EON DM: move note', -1)
      reset_note_move()
    end
    if note_draw_active then
      reaper.Undo_EndBlock('EON DM: draw note', -1)
      reset_note_draw()
    end
    if ms_drag_active then
      reaper.Undo_EndBlock('EON DM: bulk mute/solo', -1)
      reset_ms_drag()
    end
    return
  end
  if not ctx or not lane_targets or not coords then return end

  local mx, my = reaper.ImGui_GetMousePos(ctx)

  -- ---- Dropped-release recovery (case: a mouse-up event is missed — focus
  -- loss, ImGui swallowing the event — while the cursor is still over the lane
  -- band, which mouse_far_from_lanes below cannot detect). If a gesture is
  -- flagged active but its button is no longer held, close the orphaned Undo
  -- block. Gated on `not IsMouseReleased` so this never pre-empts a legitimate
  -- release frame, where the real per-gesture handler does its catch-up work.
  if drag_active
     and not reaper.ImGui_IsMouseDown(ctx, drag_button)
     and not reaper.ImGui_IsMouseReleased(ctx, drag_button) then
    reaper.Undo_EndBlock(string.format('EON DM: paint %s', drag_mode or 'cancel'), -1)
    reset_drag_state()
    return
  end
  if strip_drag_active
     and not reaper.ImGui_IsMouseDown(ctx, 0)
     and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    reaper.Undo_EndBlock('EON DM: edit velocity in strip', -1)
    strip_drag_active = false
    strip_drag_take   = nil
    strip_drag_idx    = nil
    strip_drag_strip  = nil
    return
  end
  if length_drag_active
     and not reaper.ImGui_IsMouseDown(ctx, 0)
     and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    reaper.Undo_EndBlock('EON DM: edit note length', -1)
    length_drag_active  = false
    length_drag_take    = nil
    length_drag_idx     = nil
    length_drag_start_t = 0
    length_drag_grid_qn = 0
    return
  end
  if note_move_active
     and not reaper.ImGui_IsMouseDown(ctx, 0)
     and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    reaper.Undo_EndBlock('EON DM: move note', -1)
    reset_note_move()
    return
  end
  if note_draw_active
     and not reaper.ImGui_IsMouseDown(ctx, 0)
     and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    reaper.Undo_EndBlock('EON DM: draw note', -1)
    reset_note_draw()
    return
  end
  if ms_drag_active
     and not reaper.ImGui_IsMouseDown(ctx, 0)
     and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    reaper.Undo_EndBlock('EON DM: bulk mute/solo', -1)
    reset_ms_drag()
    return
  end
  if select_rect_active
     and not reaper.ImGui_IsMouseDown(ctx, 0)
     and not reaper.ImGui_IsMouseReleased(ctx, 0) then
    select_rect_active = false
  end

  -- ---- Mouse wheel (paint mode):
  --   over a note  → adjust velocity (Shift = fine ±1, else ±4). If the note is
  --                  in a multi-note selection, nudge the WHOLE selection
  --                  (FL-style: Alt+wheel over a selected note moves them all).
  --   over empty   → cycle the project grid, but ONLY if opted in via
  --                  'grid_scroll_in_paint'. The dedicated grid cog is the
  --                  always-on way to change the grid (works paint on/off).
  -- Skip when a DM UI element owns the mouse (grid cog, pattern bar, settings,
  -- tool-mode) — that widget handles its own wheel; we must not double-act.
  local wheel = reaper.ImGui_GetMouseWheel(ctx) or 0
  if wheel ~= 0 and not mouse_blocked then
    local dir   = wheel > 0 and 1 or -1
    local mods  = reaper.ImGui_GetKeyMods(ctx) or 0
    local fine  = (mods & reaper.ImGui_Mod_Shift()) ~= 0
    local delta = (fine and 1 or 4) * dir

    local handled = false
    local lt = lane_targets and find_lane_target_for_y(lane_targets, my)
    if lt and lt.track and coords then
      local t = coords.PixelToTime(mx)
      if t then
        local take  = find_existing_take_at(lt.track, t)
        local pitch = lane_pitch_at_y(lt, my)
        local idx   = (take and pitch) and find_note_at(take, pitch, t) or nil
        if idx then
          local ok, _, _, ppq_s, _, _, _, vel = reaper.MIDI_GetNote(take, idx)
          if ok then
            if selection.Count() > 1 and selection.Contains(take, ppq_s, pitch) then
              selection.AdjustVelocity(delta)              -- self-wraps Undo
            else
              local nv = vel + delta
              if nv < 1 then nv = 1 elseif nv > 127 then nv = 127 end
              reaper.Undo_BeginBlock()
              set_note_velocity(take, idx, nv)
              reaper.Undo_EndBlock('EON DM: note velocity (wheel)', -1)
              reaper.Help_Set('EON DM velocity: ' .. nv, false)
            end
            handled = true
          end
        end
      end
    end

    if not handled and settings.Get('grid_scroll_in_paint') then
      grid.Cycle(dir)
    end
  end

  -- ---- Drag-cancel guard (case #13): when a drag is active but the mouse
  -- has wandered far outside the lane band — user Alt-Tabbed away, dragged
  -- into the timeline, or clicked off REAPER — clean up the drag state so
  -- we don't finalize the gesture at stale coordinates on the next click.
  if (drag_active or strip_drag_active or length_drag_active or note_move_active or note_draw_active or select_rect_active or ms_drag_active)
     and mouse_far_from_lanes(my, lane_targets, 80) then
    if ms_drag_active then
      reaper.Undo_EndBlock('EON DM: bulk mute/solo', -1)
      reset_ms_drag()
    end
    if drag_active then
      reaper.Undo_EndBlock('EON DM: paint (cancelled — mouse left overlay)', -1)
      reset_drag_state()
    end
    if note_move_active then
      reaper.Undo_EndBlock('EON DM: move note (cancelled — mouse left overlay)', -1)
      reset_note_move()
    end
    if note_draw_active then
      reaper.Undo_EndBlock('EON DM: draw note (cancelled — mouse left overlay)', -1)
      reset_note_draw()
    end
    if strip_drag_active then
      reaper.Undo_EndBlock('EON DM: edit velocity in strip (cancelled)', -1)
      strip_drag_active = false
      strip_drag_take   = nil
      strip_drag_idx    = nil
      strip_drag_strip  = nil
    end
    if length_drag_active then
      reaper.Undo_EndBlock('EON DM: edit note length (cancelled)', -1)
      length_drag_active  = false
      length_drag_take    = nil
      length_drag_idx     = nil
      length_drag_start_t = 0
      length_drag_grid_qn = 0
    end
    if select_rect_active then
      select_rect_active = false
    end
    return
  end

  -- ---- Multi-cell rectangle select: Ctrl+drag = draw selection rect.
  local _mods    = reaper.ImGui_GetKeyMods(ctx) or 0
  local _ctrl    = (_mods & reaper.ImGui_Mod_Ctrl()) ~= 0

  -- Does ImGui own the mouse this frame? True when our lane-tools popup is open
  -- or when the main script flagged the cursor as being over the cog button /
  -- settings window. In that case a click belongs to that UI, so we zero the
  -- click-initiation flags below — otherwise the click also "bleeds through"
  -- and paints/selects in the lane behind the menu. Ongoing drags use
  -- IsMouseDown/Released and are unaffected, so an in-progress gesture finishes.
  local ui_owns_mouse = mouse_blocked
    or (reaper.ImGui_IsPopupOpen and reaper.ImGui_IsPopupOpen(ctx, TOOLS_POPUP_ID))
  local _click0 = (not ui_owns_mouse) and reaper.ImGui_IsMouseClicked(ctx, 0)
  local _click1 = (not ui_owns_mouse) and reaper.ImGui_IsMouseClicked(ctx, 1)

  if select_rect_active then
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      select_rect_bx, select_rect_by = mx, my
      -- Draw the live selection rectangle on top of everything else.
      local dl = reaper.ImGui_GetWindowDrawList(ctx)
      local x1 = math.min(select_rect_ax, select_rect_bx)
      local x2 = math.max(select_rect_ax, select_rect_bx)
      local y1 = math.min(select_rect_ay, select_rect_by)
      local y2 = math.max(select_rect_ay, select_rect_by)
      reaper.ImGui_DrawList_AddRectFilled(dl, x1, y1, x2, y2, 0xFFFFFF20)
      reaper.ImGui_DrawList_AddRect      (dl, x1, y1, x2, y2, 0xFFFFFFAA, 0, 0, 1)
      return
    elseif reaper.ImGui_IsMouseReleased(ctx, 0) then
      -- Commit: find every note whose cell overlaps the rect and add to selection.
      local rx1 = math.min(select_rect_ax, select_rect_bx)
      local rx2 = math.max(select_rect_ax, select_rect_bx)
      local ry1 = math.min(select_rect_ay, select_rect_by)
      local ry2 = math.max(select_rect_ay, select_rect_by)
      for _, lt in ipairs(lane_targets) do
        local lane_overlaps_y = (lt.y2 >= ry1 and lt.y1 <= ry2)
        if lane_overlaps_y and not lt.lane_info.locked then
          -- Piano lanes select any pitch in the range; drum lanes only the pad pitch.
          local sel_lo = (lt.piano and lt.note_lo) or lt.lane_info.pad_pitch
          local sel_hi = (lt.piano and lt.note_hi) or lt.lane_info.pad_pitch
          local nitems = reaper.CountTrackMediaItems(lt.track)
          for i = 0, nitems - 1 do
            local item = reaper.GetTrackMediaItem(lt.track, i)
            local take = reaper.GetActiveTake(item)
            if take and reaper.TakeIsMIDI(take) then
              local _, ncount = reaper.MIDI_CountEvts(take)
              for ni = 0, ncount - 1 do
                local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
                if ok and pitch >= sel_lo and pitch <= sel_hi then
                  local ts = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
                  local te = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
                  local cx1 = coords.TimeToPixel(ts)
                  local cx2 = coords.TimeToPixel(te)
                  -- Cell overlaps rect horizontally?
                  if cx2 >= rx1 and cx1 <= rx2 then
                    selection.Add(take, ppq_s, pitch)
                  end
                end
              end
            end
          end
        end
      end
      select_rect_active = false
      return
    end
  end

  if _ctrl and _click0 and not drag_active
     and not strip_drag_active and not length_drag_active then
    -- Start rectangle selection; clear any prior selection first.
    selection.Clear()
    select_rect_active = true
    select_rect_ax, select_rect_ay = mx, my
    select_rect_bx, select_rect_by = mx, my
    return
  end

  -- ---- Lane mute / solo. The M/S rects sit at each lane's top-left, clear of
  -- the cells, so this is handled BEFORE paint/strip/note init: a click on M/S
  -- toggles that lane and arms a bulk-drag; dragging across other lanes paints
  -- the same state. Ctrl is reserved for rect-select, so M/S ignores Ctrl.
  if ms_drag_active then
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      local prop = (ms_drag_kind == 'mute') and 'B_MUTE' or 'I_SOLO'
      for _, lt in ipairs(lane_targets) do
        if lt.track and not ms_drag_touched[lt.track] then
          local rr = (ms_drag_kind == 'mute') and lt.mute or lt.solo
          if rr and mx >= rr.x and mx <= rr.x + rr.w and my >= rr.y and my <= rr.y + rr.h then
            reaper.SetMediaTrackInfo_Value(lt.track, prop, ms_drag_target_v)
            ms_drag_touched[lt.track] = true
          end
        end
      end
      return
    elseif reaper.ImGui_IsMouseReleased(ctx, 0) then
      reaper.Undo_EndBlock(('EON DM: bulk %s'):format(ms_drag_kind == 'mute' and 'mute' or 'solo'), -1)
      reset_ms_drag()
      return
    end
  end

  if _click0 and not _ctrl
     and not ms_drag_active and not drag_active and not strip_drag_active
     and not length_drag_active and not note_move_active and not note_draw_active
     and not select_rect_active then
    for _, lt in ipairs(lane_targets) do
      local rm = lt.mute
      if rm and mx >= rm.x and mx <= rm.x + rm.w and my >= rm.y and my <= rm.y + rm.h then
        local cur  = reaper.GetMediaTrackInfo_Value(lt.track, 'B_MUTE') or 0
        local newv = (cur > 0.5) and 0 or 1
        reaper.Undo_BeginBlock()
        reaper.SetMediaTrackInfo_Value(lt.track, 'B_MUTE', newv)
        ms_drag_active = true; ms_drag_kind = 'mute'; ms_drag_target_v = newv
        ms_drag_touched = { [lt.track] = true }
        return
      end
      local rs = lt.solo
      if rs and mx >= rs.x and mx <= rs.x + rs.w and my >= rs.y and my <= rs.y + rs.h then
        local cur  = reaper.GetMediaTrackInfo_Value(lt.track, 'I_SOLO') or 0
        local newv = (cur > 0.5) and 0 or 2
        reaper.Undo_BeginBlock()
        reaper.SetMediaTrackInfo_Value(lt.track, 'I_SOLO', newv)
        ms_drag_active = true; ms_drag_kind = 'solo'; ms_drag_target_v = newv
        ms_drag_touched = { [lt.track] = true }
        return
      end
    end
  end

  -- Plain LMB click WITHOUT Ctrl while a selection exists -> clear selection.
  if not _ctrl and _click0 and selection.Count() > 0
     and not drag_active and not strip_drag_active and not length_drag_active then
    -- Don't clear if click is on a cog (we'll let the cog handler run AFTER this)
    local on_cog = false
    for _, lt in ipairs(lane_targets) do
      local c = lt.cog
      if c and mx >= c.x and mx <= c.x + c.w and my >= c.y and my <= c.y + c.h then
        on_cog = true; break
      end
    end
    -- ALSO keep the selection when the click lands on an already-selected note:
    -- the user is grabbing the group to drag (group-move) or Shift-duplicate, not
    -- deselecting. Without this the clear fires first and the move sees an empty
    -- selection → only the single grabbed note moves.
    if not on_cog and not click_on_selected_note(lane_targets, mx, my, coords) then
      selection.Clear()
    end
    -- Fall through to normal paint click handling.
  end

  -- ---- Length-drag (Phase 5 + Wave D): edit a note's RIGHT edge (move end) or
  -- LEFT edge (move start, keep end). length_drag_edge selects which.
  if length_drag_active then
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      local raw_time = coords.PixelToTime(mx)
      if raw_time then
        -- Snap using the FROZEN grid captured at drag-start. Reading the live
        -- grid here would let a wheel-cycle mid-drag (case #14) jump the snap.
        local snapped
        if length_drag_grid_qn > 0 then
          local qn = reaper.TimeMap_timeToQN(raw_time)
          snapped = reaper.TimeMap_QNToTime(
            math.floor(qn / length_drag_grid_qn + 0.5) * length_drag_grid_qn)
        else
          snapped = coords.SnapTimeToGrid(raw_time)
        end
        if length_drag_edge == 'left' then
          -- Move START, keep END fixed. Clamp start <= end - min.
          if snapped > length_drag_end_t - length_drag_min_len then
            snapped = length_drag_end_t - length_drag_min_len
          end
          local new_ppq_s = reaper.MIDI_GetPPQPosFromProjTime(length_drag_take, snapped)
          reaper.MIDI_SetNote(length_drag_take, length_drag_idx,
            nil, nil, new_ppq_s, nil, nil, nil, nil, true)
        else
          -- Move END, keep START fixed. Clamp end >= start + min.
          if snapped < length_drag_start_t + length_drag_min_len then
            snapped = length_drag_start_t + length_drag_min_len
          end
          local new_ppq_e = reaper.MIDI_GetPPQPosFromProjTime(length_drag_take, snapped)
          reaper.MIDI_SetNote(length_drag_take, length_drag_idx,
            nil, nil, nil, new_ppq_e, nil, nil, nil, true)
        end
        reaper.MIDI_Sort(length_drag_take)
        local item = reaper.GetMediaItemTake_Item(length_drag_take)
        if item then reaper.UpdateItemInProject(item) end
        note_user_edit()
      end
      return
    elseif reaper.ImGui_IsMouseReleased(ctx, 0) then
      reaper.Undo_EndBlock('EON DM: edit note length', -1)
      length_drag_active  = false
      length_drag_take    = nil
      length_drag_idx     = nil
      length_drag_start_t = 0
      length_drag_end_t   = 0
      length_drag_edge    = 'right'
      length_drag_grid_qn = 0
      return
    end
  end

  -- ---- Note-move (piano lanes): preview a ghost while held, commit on release.
  -- A press that never crosses NOTE_MOVE_THRESHOLD is a plain click -> toggle
  -- the note off, matching drum-lane click-to-remove.
  if note_move_active then
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      if not note_move_started
         and (math.abs(mx - note_move_anchor_mx) > NOTE_MOVE_THRESHOLD
              or math.abs(my - note_move_anchor_my) > NOTE_MOVE_THRESHOLD) then
        note_move_started = true
      end
      if note_move_started then
        local lt       = note_move_lt
        local raw_time = coords.PixelToTime(mx)
        if lt and raw_time then
          local cell_start = snap_click_time(coords, raw_time, lt.lane_info)
          local pitch      = lane_pitch_at_y(lt, my)
          -- Ghost rect at the target time + row (no MIDI change until release).
          local ppq_s    = reaper.MIDI_GetPPQPosFromProjTime(note_move_take, cell_start)
          local end_time = reaper.MIDI_GetProjTimeFromPPQPos(note_move_take, ppq_s + note_move_len_ppq)
          local cx1 = coords.Snap(coords.TimeToPixel(cell_start))
          local cx2 = coords.Snap(coords.TimeToPixel(end_time))
          if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
          local cy1, cy2
          if lt.sub_row_h and lt.sub_row_h > 0 and lt.note_hi then
            cy1 = lt.item_top + (lt.note_hi - pitch) * lt.sub_row_h + 1
            cy2 = cy1 + lt.sub_row_h - 1
          else
            cy1, cy2 = lt.item_top, lt.cells_y2
          end
          if cy2 > cy1 then
            local dl = reaper.ImGui_GetWindowDrawList(ctx)
            reaper.ImGui_DrawList_AddRectFilled(dl, cx1, cy1, cx2, cy2, 0xFFFFFF33, 0)
            reaper.ImGui_DrawList_AddRect      (dl, cx1, cy1, cx2, cy2, 0xFFFFFFCC, 0, 0, 2)
          end
          -- Grouped drag: also ghost every other selected note by the same
          -- delta the release will apply (selection.MoveBy / DuplicateBy).
          if note_move_orig_ppq_s and selection.Count() > 1
             and selection.Contains(note_move_take, note_move_orig_ppq_s, note_move_orig_pitch) then
            local orig_t = reaper.MIDI_GetProjTimeFromPPQPos(note_move_take, note_move_orig_ppq_s)
            local g_qn_delta = reaper.TimeMap_timeToQN(cell_start) - reaper.TimeMap_timeToQN(orig_t)
            local g_d_pitch  = pitch - (note_move_orig_pitch or pitch)
            draw_group_move_ghosts(ctx, lane_targets, coords, g_qn_delta, g_d_pitch,
              note_move_take, note_move_orig_ppq_s, note_move_orig_pitch)
          end
        end
      end
      return
    elseif reaper.ImGui_IsMouseReleased(ctx, 0) then
      local valid = (not reaper.ValidatePtr)
        or reaper.ValidatePtr(note_move_take, 'MediaItem_Take*')
      if note_move_started and valid then
        local raw_time = coords.PixelToTime(mx)
        if raw_time then
          local cell_start = snap_click_time(coords, raw_time, note_move_lt.lane_info)
          local pitch      = lane_pitch_at_y(note_move_lt, my)
          -- Grouped = grabbed note is part of a multi-note selection: the whole
          -- selection moves/duplicates by the same (time, pitch) delta.
          local grouped = note_move_orig_ppq_s
            and selection.Contains(note_move_take, note_move_orig_ppq_s, note_move_orig_pitch)
            and selection.Count() > 1
          local orig_t   = note_move_orig_ppq_s
            and reaper.MIDI_GetProjTimeFromPPQPos(note_move_take, note_move_orig_ppq_s) or cell_start
          local qn_delta = reaper.TimeMap_timeToQN(cell_start) - reaper.TimeMap_timeToQN(orig_t)
          local d_pitch  = pitch - (note_move_orig_pitch or pitch)
          local new_ppq_s = reaper.MIDI_GetPPQPosFromProjTime(note_move_take, cell_start)
          local new_ppq_e = new_ppq_s + note_move_len_ppq
          if note_move_dup then
            -- Shift+drag → leave originals, drop a copy at the dragged delta.
            if grouped then
              selection.DuplicateBy(qn_delta, d_pitch)
            else
              reaper.MIDI_InsertNote(note_move_take, false, false,
                new_ppq_s, new_ppq_e, 0, pitch, note_move_orig_vel, true)
              reaper.MIDI_Sort(note_move_take)
              local item = reaper.GetMediaItemTake_Item(note_move_take)
              if item then reaper.UpdateItemInProject(item) end
            end
          elseif grouped then
            selection.MoveBy(qn_delta, d_pitch)
          else
            reaper.MIDI_SetNote(note_move_take, note_move_idx,
              nil, nil, new_ppq_s, new_ppq_e, nil, pitch, nil, true)
            reaper.MIDI_Sort(note_move_take)
            local item = reaper.GetMediaItemTake_Item(note_move_take)
            if item then reaper.UpdateItemInProject(item) end
          end
        end
        reaper.Undo_EndBlock(note_move_dup and 'EON DM: duplicate note' or 'EON DM: move note', -1)
        note_user_edit()
      elseif valid then
        -- No drag -> plain click: toggle the note off (preserves old behavior).
        DeleteNoteAtCell(note_move_take, note_move_idx)
        reaper.Undo_EndBlock('EON DM: toggle note', -1)
      else
        reaper.Undo_EndBlock('EON DM: move note (cancelled — take gone)', -1)
      end
      reset_note_move()
      return
    end
  end

  -- ---- Note-draw (piano lanes): FL draw-with-length. Ghost while held; commit
  -- ONE note on release — a plain click = 1 grid step, a drag sets length
  -- (cursor-X, snapped) and pitch (cursor-Y). Item auto-created on commit.
  if note_draw_active then
    local lt       = note_draw_lt
    local start_t  = note_draw_anchor_t
    local min_len  = lt and grid_length(start_t) or 0
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      if not note_draw_started
         and (math.abs(mx - note_draw_anchor_mx) > NOTE_MOVE_THRESHOLD
              or math.abs(my - note_draw_anchor_my) > NOTE_MOVE_THRESHOLD) then
        note_draw_started = true
      end
      local raw_time = coords.PixelToTime(mx)
      if lt and raw_time then
        local end_t = note_draw_started and snap_click_time(coords, raw_time, lt.lane_info)
                      or (start_t + min_len)
        if end_t < start_t + min_len then end_t = start_t + min_len end
        local pitch = lane_pitch_at_y(lt, my)
        local cx1 = coords.Snap(coords.TimeToPixel(start_t))
        local cx2 = coords.Snap(coords.TimeToPixel(end_t))
        if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
        local cy1, cy2
        if lt.sub_row_h and lt.sub_row_h > 0 and lt.note_hi then
          cy1 = lt.item_top + (lt.note_hi - pitch) * lt.sub_row_h + 1
          cy2 = cy1 + lt.sub_row_h - 1
        else
          cy1, cy2 = lt.item_top, lt.cells_y2
        end
        if cy2 > cy1 then
          local dl = reaper.ImGui_GetWindowDrawList(ctx)
          reaper.ImGui_DrawList_AddRectFilled(dl, cx1, cy1, cx2, cy2, 0xFFFFFF33, 0)
          reaper.ImGui_DrawList_AddRect      (dl, cx1, cy1, cx2, cy2, 0xFFFFFFCC, 0, 0, 2)
        end
      end
      return
    elseif reaper.ImGui_IsMouseReleased(ctx, 0) then
      local raw_time = coords.PixelToTime(mx)
      if lt then
        local length = min_len
        if note_draw_started and raw_time then
          local end_t = snap_click_time(coords, raw_time, lt.lane_info)
          length = end_t - start_t
          if length < min_len then length = min_len end
        end
        local pitch    = lane_pitch_at_y(lt, my)
        local item, take = GetOrCreateMidiItemAt(lt.track, start_t, lt.item_color)
        if take and not NoteInCell(take, pitch, start_t, start_t + min_len) then
          InsertNoteAtCell(take, pitch, start_t, length, paint_velocity_for_mods(ctx))
        end
      end
      reaper.Undo_EndBlock('EON DM: draw note', -1)
      reset_note_draw()
      return
    end
  end

  -- ---- Length-drag initiation: LMB click within EDGE_PIXELS of a cell's
  -- right edge starts a length drag instead of paint-toggle. Detection is
  -- O(notes-in-lane) per click but only runs on actual click events so the
  -- frame-level perf hit is negligible.
  if _click0 and not drag_active
     and not strip_drag_active and not length_drag_active then
    for _, lt in ipairs(lane_targets) do
      local in_lane  = (my >= lt.y1 and my <= lt.y2)
      local in_strip = lt.strip and (my >= lt.strip.y1 and my <= lt.strip.y2)
      if in_lane and not in_strip then
        -- Row-aware: only the note on the clicked pitch row is a resize target.
        -- (Drum lanes: lane_pitch_at_y returns pad_pitch, so this is the single
        -- pad pitch as before. Piano lanes: the exact row under the cursor, so a
        -- different-row note with a nearby right edge can't be grabbed.)
        local row_pitch = lane_pitch_at_y(lt, my)
        local nitems = reaper.CountTrackMediaItems(lt.track)
        local found = false
        for i = 0, nitems - 1 do
          if found then break end
          local item = reaper.GetTrackMediaItem(lt.track, i)
          local take = reaper.GetActiveTake(item)
          if take and reaper.TakeIsMIDI(take) then
            local _, ncount = reaper.MIDI_CountEvts(take)
            for ni = 0, ncount - 1 do
              local ok, _, _, ppq_s, ppq_e, _, pitch = reaper.MIDI_GetNote(take, ni)
              if ok and pitch == row_pitch then
                local n_start = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
                local n_end   = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
                local cx1 = coords.TimeToPixel(n_start)
                local cx2 = coords.TimeToPixel(n_end)
                local hit_right = math.abs(mx - cx2) <= EDGE_PIXELS
                local hit_left  = math.abs(mx - cx1) <= EDGE_PIXELS
                -- Right edge wins ties (narrow notes), matching the more common
                -- resize. Body clicks (neither edge) fall through to note-move.
                if hit_right or hit_left then
                  length_drag_active   = true
                  length_drag_take     = take
                  length_drag_idx      = ni
                  length_drag_start_t  = n_start
                  length_drag_end_t    = n_end
                  length_drag_edge     = hit_right and 'right' or 'left'
                  length_drag_min_len  = 0.005
                  -- Freeze the current project grid divider so a mid-drag
                  -- wheel cycle (case #14) doesn't change the snap target.
                  local _, gdiv = reaper.GetSetProjectGrid(0, false)
                  length_drag_grid_qn  = gdiv or 0
                  reaper.Undo_BeginBlock()
                  found = true
                  break
                end
              end
            end
          end
        end
        if found then return end
      end
    end
  end

  -- ---- Strip-drag (Phase F): velocity adjust while LMB held in a strip.
  -- Handled BEFORE the cog/click branches so the strip wins when the mouse
  -- is over the bottom velocity band of a lane.
  if strip_drag_active then
    -- Case #10: strip-drag entered with a strip rect, but the lane's strip
    -- could have been suppressed mid-gesture (settings toggle, lane height
    -- shrank below threshold). Without this guard set_note_velocity gets
    -- called with stale strip math.
    if not strip_drag_strip then
      reaper.Undo_EndBlock('EON DM: edit velocity in strip (cancelled — strip gone)', -1)
      strip_drag_active = false
      strip_drag_take   = nil
      strip_drag_idx    = nil
      return
    end
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      local v = velocity_from_strip_y(my, strip_drag_strip)
      set_note_velocity(strip_drag_take, strip_drag_idx, v)
      return
    elseif reaper.ImGui_IsMouseReleased(ctx, 0) then
      reaper.Undo_EndBlock('EON DM: edit velocity in strip', -1)
      strip_drag_active = false
      strip_drag_take   = nil
      strip_drag_idx    = nil
      strip_drag_strip  = nil
      return
    end
  end

  -- ---- Initiate strip drag: LMB clicked inside a lane's strip.
  if _click0 and not drag_active and not strip_drag_active then
    for _, lt in ipairs(lane_targets) do
      local s = lt.strip
      if s and my >= s.y1 and my <= s.y2 then
        -- Find which note we landed on by hit-testing the cell at this X.
        local raw_time = coords.PixelToTime(mx)
        if raw_time then
          local cell_start = snap_click_time(coords, raw_time, lt.lane_info)
          local cell_end   = cell_start + grid_length(cell_start)
          -- Find the item containing cell_start and its take.
          local n = reaper.CountTrackMediaItems(lt.track)
          for i = 0, n - 1 do
            local item = reaper.GetTrackMediaItem(lt.track, i)
            local s_t = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
            local e_t = s_t + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
            if cell_start >= s_t - 1e-6 and cell_start < e_t - 1e-6 then
              local take = reaper.GetActiveTake(item)
              if take and reaper.TakeIsMIDI(take) then
                local idx
                if lt.piano and lt.note_lo and lt.note_hi then
                  idx = NoteInCellRange(take, lt.note_lo, lt.note_hi, cell_start, cell_end)
                else
                  idx = NoteInCell(take, lt.lane_info.pad_pitch, cell_start, cell_end)
                end
                if idx then
                  reaper.Undo_BeginBlock()
                  strip_drag_active = true
                  strip_drag_take   = take
                  strip_drag_idx    = idx
                  strip_drag_strip  = s
                  -- Immediately commit the velocity at the click position.
                  set_note_velocity(take, idx, velocity_from_strip_y(my, s))
                end
              end
              break
            end
          end
        end
        return
      end
    end
  end

  -- ---- Left-click on a lane's cog icon: open the per-lane tools popup.
  -- This handler runs BEFORE the paint click branch so the cog wins over a
  -- paint-on-empty-cell action when the click is inside the cog rect.
  if _click0 and not drag_active then
    for _, lt in ipairs(lane_targets) do
      local cog = lt.cog
      if cog and mx >= cog.x and mx <= cog.x + cog.w
                and my >= cog.y and my <= cog.y + cog.h then
        pending_tools_lane = lt
        reaper.ImGui_OpenPopup(ctx, TOOLS_POPUP_ID)
        return
      end
    end
  end

  -- ---- Alt + Right-click: open the per-lane tools popup at the clicked lane.
  -- (Plain RMB without Alt is reserved for the right-click action setting:
  -- delete / toggle / off.)
  local mods    = reaper.ImGui_GetKeyMods(ctx) or 0
  local alt_held= (mods & reaper.ImGui_Mod_Alt()) ~= 0
  if alt_held and _click1 and not drag_active then
    local lt = find_lane_target_for_y(lane_targets, my)
    if lt then
      pending_tools_lane = lt
      reaper.ImGui_OpenPopup(ctx, TOOLS_POPUP_ID)
    end
    return
  end

  -- Render the popup (every frame; ImGui handles its open/closed state).
  if reaper.ImGui_BeginPopup(ctx, TOOLS_POPUP_ID) then
    local lane = pending_tools_lane
    if lane and lane.lane_info then
      if lane.lane_info.stereo == true then
      -- ── Stereo-grid variant ─────────────────────────────────────────────
      -- One item holds every pad, so the range-aware lane ops act on the WHOLE
      -- pattern (relabel accordingly). Single-pitch inserters (presets, fills,
      -- randomize) are meaningless at lane level here — they move into the
      -- per-row submenu, where each row runs the SAME ops through a synthetic
      -- single-pitch lane at that row's pad note.
      reaper.ImGui_TextDisabled(ctx, 'STEREO GRID  ' .. (lane.lane_info.pad_name or 'Drums'))
      reaper.ImGui_Separator(ctx)

      if reaper.ImGui_BeginMenu(ctx, 'Pad rows') then
        local rows = lane_tools.StereoRows and lane_tools.StereoRows(lane.lane_info) or {}
        if #rows == 0 then
          reaper.ImGui_TextDisabled(ctx, '(no pad map \xE2\x80\x94 is Swing online?)')
        end
        for _, row in ipairs(rows) do
          if reaper.ImGui_BeginMenu(ctx, string.format('%s (%d)##srow%d', row.name, row.pitch, row.pitch)) then
            local synth = { track = lane.track, lane_info = {
              pad_pitch = row.pitch, pad_index = row.pad, pad_channel = 1,
              pad_name = row.name,
              swing_instance_guid = lane.lane_info.swing_instance_guid,
            } }
            if reaper.ImGui_MenuItem(ctx, 'Clear row')          then lane_tools.ClearLane(synth);          reaper.ImGui_CloseCurrentPopup(ctx) end
            reaper.ImGui_Separator(ctx)
            if reaper.ImGui_MenuItem(ctx, 'Fill every 2 steps') then lane_tools.FillEveryN(synth, 2, true); reaper.ImGui_CloseCurrentPopup(ctx) end
            if reaper.ImGui_MenuItem(ctx, 'Fill every 4 steps') then lane_tools.FillEveryN(synth, 4, true); reaper.ImGui_CloseCurrentPopup(ctx) end
            if reaper.ImGui_MenuItem(ctx, 'Fill every 8 steps') then lane_tools.FillEveryN(synth, 8, true); reaper.ImGui_CloseCurrentPopup(ctx) end
            reaper.ImGui_Separator(ctx)
            if reaper.ImGui_MenuItem(ctx, 'Randomize row (30%)') then lane_tools.RandomizeLane(synth, 30);  reaper.ImGui_CloseCurrentPopup(ctx) end
            if reaper.ImGui_MenuItem(ctx, 'Accent every 4 (+30 vel)') then lane_tools.AccentEveryN(synth, 4, 30); reaper.ImGui_CloseCurrentPopup(ctx) end
            reaper.ImGui_EndMenu(ctx)
          end
        end
        reaper.ImGui_EndMenu(ctx)
      end

      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Clear pattern (all pads)') then lane_tools.ClearLane(lane);    reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Clear clip (all notes)')   then lane_tools.ClearClip(lane);    reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Quantize pattern')         then lane_tools.QuantizeLane(lane); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Mirror pattern')           then lane_tools.MirrorLane(lane);   reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Shift left')               then lane_tools.ShiftLane(lane, -1); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Shift right')              then lane_tools.ShiftLane(lane,  1); reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Duplicate bar \xE2\x86\x92 next') then lane_tools.DuplicateBarToNext(lane); reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_BeginMenu(ctx, 'More tools') then
        if reaper.ImGui_MenuItem(ctx, 'Accent every 4 (+30 vel)') then lane_tools.AccentEveryN(lane, 4, 30); reaper.ImGui_CloseCurrentPopup(ctx) end
        if reaper.ImGui_MenuItem(ctx, 'Accent every 2 (+30 vel)') then lane_tools.AccentEveryN(lane, 2, 30); reaper.ImGui_CloseCurrentPopup(ctx) end
        if reaper.ImGui_MenuItem(ctx, 'Humanize (5ms / 10vel)')   then lane_tools.HumanizeLane(lane, 5, 10);  reaper.ImGui_CloseCurrentPopup(ctx) end
        reaper.ImGui_EndMenu(ctx)
      end

      else
      -- ── Classic single-pad lane menu ────────────────────────────────────
      local pad_idx = lane.lane_info.pad_index or 0
      reaper.ImGui_TextDisabled(ctx, string.format('%02d  %s',
        pad_idx, lane.lane_info.pad_name or '?'))
      local cat = category.GetForLane(lane.lane_info)
      reaper.ImGui_TextDisabled(ctx, 'category: ' .. cat)
      reaper.ImGui_Separator(ctx)

      -- Patterns submenu: filtered by current genre × this lane's category.
      if reaper.ImGui_BeginMenu(ctx, 'Patterns') then
        local cur_genre = settings.Get('genre') or 'hip-hop'
        local matching = preset_lib.Get(cur_genre, cat)
        local track_key = reaper.GetTrackGUID(lane.track) or tostring(pad_idx)
        if #matching == 0 then
          reaper.ImGui_TextDisabled(ctx, string.format('(no %s/%s presets)', cur_genre, cat))
        else
          -- A name filter appears once a cell holds many presets (imports can
          -- make a single category large). Short lists stay clean — no filter.
          local show_filter = (#matching >= PATTERN_FILTER_THRESHOLD)
          if show_filter and reaper.ImGui_InputTextWithHint then
            reaper.ImGui_SetNextItemWidth(ctx, 220)
            local changed, txt = reaper.ImGui_InputTextWithHint(ctx, '##pat_filter', 'filter by name…', pattern_filter)
            if changed then pattern_filter = txt end
            reaper.ImGui_SameLine(ctx)
            if reaper.ImGui_SmallButton(ctx, 'x') then pattern_filter = '' end
            reaper.ImGui_Separator(ctx)
          end
          local needle = show_filter and pattern_filter:lower() or ''
          local shown = 0
          for _, p in ipairs(matching) do
            if needle == '' or p.name:lower():find(needle, 1, true) then
              shown = shown + 1
              if reaper.ImGui_MenuItem(ctx, p.name) then
                preset_lib.Apply(lane, p)
                last_preset_by_track[track_key] = p.name
                reaper.ImGui_CloseCurrentPopup(ctx)
              end
            end
          end
          if shown == 0 then reaper.ImGui_TextDisabled(ctx, '(no match)') end
          reaper.ImGui_Separator(ctx)
          -- Gray out "Random pattern" if only one preset exists.
          if #matching <= 1 then reaper.ImGui_BeginDisabled(ctx) end
          if reaper.ImGui_MenuItem(ctx, 'Random pattern') then
            local picked = preset_lib.GetRandom(cur_genre, cat, last_preset_by_track[track_key])
            if picked then
              preset_lib.Apply(lane, picked)
              last_preset_by_track[track_key] = picked.name
            end
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
          if #matching <= 1 then reaper.ImGui_EndDisabled(ctx) end
        end
        reaper.ImGui_EndMenu(ctx)
      end

      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Clear lane')    then lane_tools.ClearLane(lane);    reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Clear clip (all notes)') then lane_tools.ClearClip(lane); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Quantize lane') then lane_tools.QuantizeLane(lane); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Mirror lane')   then lane_tools.MirrorLane(lane);   reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Shift left')    then lane_tools.ShiftLane(lane, -1); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Shift right')   then lane_tools.ShiftLane(lane,  1); reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_MenuItem(ctx, 'Duplicate bar \xE2\x86\x92 next (this lane)') then lane_tools.DuplicateBarToNext(lane); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Duplicate bar \xE2\x86\x92 next (all lanes)') then lane_tools.DuplicateBarAllLanes();   reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      -- clear_first = true: "Fill every N" SETS the lane to exactly every-N (replace),
      -- not additive. Without it, Fill-2 then Fill-8 stays every-2 (8's steps are a subset
      -- of 2's). The settings window keeps an explicit additive toggle for layering.
      if reaper.ImGui_MenuItem(ctx, 'Fill every 2 steps') then lane_tools.FillEveryN(lane, 2, true); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Fill every 4 steps') then lane_tools.FillEveryN(lane, 4, true); reaper.ImGui_CloseCurrentPopup(ctx) end
      if reaper.ImGui_MenuItem(ctx, 'Fill every 8 steps') then lane_tools.FillEveryN(lane, 8, true); reaper.ImGui_CloseCurrentPopup(ctx) end
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_BeginMenu(ctx, 'More tools') then
        if reaper.ImGui_MenuItem(ctx, 'Accent every 4 (+30 vel)') then lane_tools.AccentEveryN(lane, 4, 30); reaper.ImGui_CloseCurrentPopup(ctx) end
        if reaper.ImGui_MenuItem(ctx, 'Accent every 2 (+30 vel)') then lane_tools.AccentEveryN(lane, 2, 30); reaper.ImGui_CloseCurrentPopup(ctx) end
        if reaper.ImGui_MenuItem(ctx, 'Humanize (5ms / 10vel)')   then lane_tools.HumanizeLane(lane, 5, 10);  reaper.ImGui_CloseCurrentPopup(ctx) end
        if reaper.ImGui_MenuItem(ctx, 'Randomize lane (30%)')     then lane_tools.RandomizeLane(lane, 30);    reaper.ImGui_CloseCurrentPopup(ctx) end
        if reaper.ImGui_MenuItem(ctx, 'Randomize lane (50%)')     then lane_tools.RandomizeLane(lane, 50);    reaper.ImGui_CloseCurrentPopup(ctx) end
        reaper.ImGui_EndMenu(ctx)
      end
      end -- stereo / classic menu variants

      reaper.ImGui_Separator(ctx)

      -- Selection ops (Phase D / multi-cell select). Visible only when the
      -- selection set is non-empty.
      if selection.Count() > 0 then
        if reaper.ImGui_BeginMenu(ctx, string.format('Selection (%d) \xE2\x96\xBE', selection.Count())) then
          if reaper.ImGui_MenuItem(ctx, 'Clear cells')          then selection.ClearSelected();        reaper.ImGui_CloseCurrentPopup(ctx) end
          reaper.ImGui_Separator(ctx)
          if reaper.ImGui_MenuItem(ctx, 'Velocity +10')         then selection.AdjustVelocity( 10);    reaper.ImGui_CloseCurrentPopup(ctx) end
          if reaper.ImGui_MenuItem(ctx, 'Velocity +20')         then selection.AdjustVelocity( 20);    reaper.ImGui_CloseCurrentPopup(ctx) end
          if reaper.ImGui_MenuItem(ctx, 'Velocity -10')         then selection.AdjustVelocity(-10);    reaper.ImGui_CloseCurrentPopup(ctx) end
          if reaper.ImGui_MenuItem(ctx, 'Velocity -20')         then selection.AdjustVelocity(-20);    reaper.ImGui_CloseCurrentPopup(ctx) end
          reaper.ImGui_Separator(ctx)
          local _, grid_qn = reaper.GetSetProjectGrid(0, false)
          if grid_qn and grid_qn > 0 then
            if reaper.ImGui_MenuItem(ctx, 'Shift left 1 step')  then selection.ShiftBy(-grid_qn);      reaper.ImGui_CloseCurrentPopup(ctx) end
            if reaper.ImGui_MenuItem(ctx, 'Shift right 1 step') then selection.ShiftBy( grid_qn);      reaper.ImGui_CloseCurrentPopup(ctx) end
          end
          reaper.ImGui_Separator(ctx)
          if reaper.ImGui_MenuItem(ctx, 'Deselect all')         then selection.Clear();                reaper.ImGui_CloseCurrentPopup(ctx) end
          reaper.ImGui_EndMenu(ctx)
        end
        reaper.ImGui_Separator(ctx)
      end

      -- Lane integrity: only show "Normalize" when there are foreign notes.
      local foreign_count = lane_integrity.CountForeignOnLane(lane)
      if foreign_count > 0 then
        -- Piano lanes DELETE out-of-range notes (transposing into a range is
        -- meaningless); drum lanes transpose to the pad pitch. Match the label
        -- to what NormalizeLane will actually do.
        local verb = lane.piano and 'delete' or 'transpose'
        local label = string.format('Normalize lane (%s %d foreign note%s)',
          verb, foreign_count, foreign_count == 1 and '' or 's')
        if reaper.ImGui_MenuItem(ctx, label) then
          lane_integrity.NormalizeLane(lane)
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_Separator(ctx)
      end

      -- Per-lane velocity-strip pin: overrides the global scope setting.
      -- When checked, the strip is forced ON for THIS lane no matter what
      -- "Show on" is set to in Display tab.
      local pin_cur = lane.lane_info.show_strip == true
      local clicked, new_pin = reaper.ImGui_MenuItem(ctx, 'Pin velocity strip here', nil, pin_cur)
      if clicked then
        lane.lane_info.show_strip = (new_pin == true) and true or nil
        local json_ok, json_lib = pcall(dofile, _SCRIPT_DIR .. 'json.lua')
        if json_ok and json_lib then
          reaper.GetSetMediaTrackInfo_String(lane.track, 'P_EXT:EON_DRUM_LANE',
            json_lib.encode(lane.lane_info), true)
        end
      end

      -- Piano view: a per-lane pitch RANGE turns the lane into a mini piano-
      -- roll (note_lo < note_hi). Equal/absent bounds = normal single-pitch
      -- drum lane. Mirrors the show_strip persistence above (mutate lane_info,
      -- re-encode to P_EXT; the renderer reads it next frame).
      reaper.ImGui_Separator(ctx)
      if reaper.ImGui_BeginMenu(ctx, 'Piano view') then
        local li = lane.lane_info
        local function persist_range()
          local jok, jlib = pcall(dofile, _SCRIPT_DIR .. 'json.lua')
          if jok and jlib and jlib.encode then
            reaper.GetSetMediaTrackInfo_String(lane.track, 'P_EXT:EON_DRUM_LANE',
              jlib.encode(li), true)
          end
        end
        local is_piano = type(li.note_lo) == 'number' and type(li.note_hi) == 'number'
                         and li.note_hi > li.note_lo
        if li.stereo == true then
          -- Stereo grid lane: multi-pitch IS the mode. Turning it off would
          -- collapse the whole-kit pattern to one row (and Normalize could
          -- then transpose every note onto it). Range stays adjustable below.
          reaper.ImGui_TextDisabled(ctx, 'Stereo grid lane \xE2\x80\x94 always multi-pitch')
        else
          local tog, on = reaper.ImGui_Checkbox(ctx, 'Multi-pitch (piano) lane', is_piano)
          if tog then
            if on then
              -- Default to a one-octave range whose BOTTOM row is the pad pitch,
              -- so the lane's existing single-pitch notes stay in view.
              local base = math.max(0, math.min(li.pad_pitch or 60, 115))
              li.note_lo, li.note_hi = base, base + 12
            else
              li.note_lo, li.note_hi = nil, nil
            end
            persist_range()
            is_piano = on
          end
        end
        if is_piano then
          reaper.ImGui_SetNextItemWidth(ctx, 140)
          local lch, lv = reaper.ImGui_SliderInt(ctx, 'low##pv', li.note_lo, 0, 127)
          if lch then li.note_lo = math.max(0, math.min(lv, li.note_hi - 1)); persist_range() end
          reaper.ImGui_SetNextItemWidth(ctx, 140)
          local hch, hv = reaper.ImGui_SliderInt(ctx, 'high##pv', li.note_hi, 0, 127)
          if hch then li.note_hi = math.min(127, math.max(hv, li.note_lo + 1)); persist_range() end
          if (reaper.GetMediaTrackInfo_Value(lane.track, 'I_FREEMODE') or 0) ~= 0 then
            reaper.ImGui_TextDisabled(ctx, 'Track is fixed-lane/free-item \xE2\x80\x94 piano view stays off')
          end
        end
        reaper.ImGui_EndMenu(ctx)
      end

      -- Per-lane swing (#8): off-beats shift late by swing_amount * step/3. A
      -- non-zero lane swing overrides the project swing; 0 follows the project.
      -- Enabled on power-of-2 AND triplet grids (binary off-beat shift / triplet
      -- shift-the-last-of-3); disabled only on dotted/arbitrary grids where the
      -- pairing is undefined. Persistence mirrors the Piano-view idiom above.
      reaper.ImGui_Separator(ctx)
      do
        local li = lane.lane_info
        local function persist_swing()
          local jok, jlib = pcall(dofile, _SCRIPT_DIR .. 'json.lua')
          if jok and jlib and jlib.encode then
            reaper.GetSetMediaTrackInfo_String(lane.track, 'P_EXT:EON_DRUM_LANE',
              jlib.encode(li), true)
          end
        end
        local _, gdiv = reaper.GetSetProjectGrid(0, false)
        -- Swing grid (subdivision): the grid THIS lane's swing math runs on,
        -- independent of the project/paint grid. "Project" (default) follows the
        -- project grid; otherwise a fixed 1/8..1/16T division. Persisted as
        -- swing_subdiv (QN); Project = nil/absent so default lanes are unchanged.
        local SUBDIV_OPTS = {
          { label = 'Project', v = 0    },
          { label = '1/8',     v = 0.5  },
          { label = '1/16',    v = 0.25 },
          { label = '1/8T',    v = 1/12 },
          { label = '1/16T',   v = 1/24 },
        }
        local cur_sd    = tonumber(li.swing_subdiv) or 0
        local cur_label = 'Project'
        for _, o in ipairs(SUBDIV_OPTS) do
          if o.v ~= 0 and math.abs(cur_sd - o.v) < 1e-6 then cur_label = o.label end
        end
        reaper.ImGui_SetNextItemWidth(ctx, 140)
        if reaper.ImGui_BeginCombo(ctx, 'Swing grid##sd', cur_label) then
          for _, o in ipairs(SUBDIV_OPTS) do
            local sel = (o.v == 0 and cur_sd == 0)
                        or (o.v ~= 0 and math.abs(cur_sd - o.v) < 1e-6)
            if reaper.ImGui_Selectable(ctx, o.label, sel) then
              li.swing_subdiv = (o.v == 0) and nil or o.v
              persist_swing()
            end
          end
          reaper.ImGui_EndCombo(ctx)
        end
        -- Gate the slider on the EFFECTIVE grid (g_eff): a lane can pick a
        -- swingable subdivision even when the project grid isn't swingable.
        local g_eff     = (coords and coords.EffectiveSwingDivQN and coords.EffectiveSwingDivQN(li)) or gdiv
        local swingable = coords and coords.IsSwingableDiv and coords.IsSwingableDiv(g_eff)
        local cur = tonumber(li.swing_amount) or 0
        if not swingable then
          reaper.ImGui_TextDisabled(ctx, 'Swing: needs a 1/4\xE2\x80\x931/16 or triplet grid')
        else
          reaper.ImGui_SetNextItemWidth(ctx, 140)
          local ch, v = reaper.ImGui_SliderInt(ctx, 'Swing %##sw',
            math.floor(cur * 100 + 0.5), -100, 100)
          if ch then
            li.swing_amount = math.max(-1, math.min(1, v / 100))
            persist_swing()
          end
          if cur ~= 0 then
            if reaper.ImGui_MenuItem(ctx, 'Apply swing to existing notes') then
              lane_tools.ApplySwingToLane(lane)
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
            if reaper.ImGui_MenuItem(ctx, 'Reset swing to 0') then
              li.swing_amount = 0
              persist_swing()
              reaper.ImGui_CloseCurrentPopup(ctx)
            end
          end
        end
      end
    end
    reaper.ImGui_EndPopup(ctx)
  end

  -- ---- Right-click: behavior controlled by settings.right_click_action
  --   'delete' = unconditional delete of any note in that cell (default)
  --   'toggle' = same logic as left-click anchor: add if empty, remove if not
  --   'off'    = ignored (lets REAPER's native right-click pass through? — overlay
  --              still has NoMouseInputs OFF in paint mode, so right-click stays
  --              with us; we just no-op here)
  local _rmb_action = settings.Get('right_click_action') or 'delete'
  if _rmb_action ~= 'off'
     and _click1 and not drag_active then
    -- Check the lock-aware variant first so we can surface feedback for
    -- locked-lane right-clicks instead of silently no-op'ing (case #15).
    local lt_any, locked = find_lane_target_for_y_with_lock(lane_targets, my)
    if lt_any and locked then
      if reaper.Help_Set then
        reaper.Help_Set('EON DM: lane locked — unlock in Settings → Pads', false)
      end
      return
    end
    local lt = find_lane_target_for_y(lane_targets, my)
    if not lt then return end
    local raw_time = coords.PixelToTime(mx)
    if not raw_time then return end
    local cell_start = snap_click_time(coords, raw_time, lt.lane_info)
    local rc_subdiv  = (coords.EffectiveSwingDivQN and lt.lane_info and lt.lane_info.swing_subdiv
                        and lt.lane_info.swing_subdiv > 0) and coords.EffectiveSwingDivQN(lt.lane_info) or nil
    local cell_end   = cell_start + grid_length(cell_start, rc_subdiv)
    -- 'delete' starts an ERASE-DRAG (FL-style): a tap erases one cell, hold +
    -- drag erases every cell crossed. Reuses the shared drag machinery with
    -- drag_button = 1 so the per-frame down/release blocks below drive it.
    -- Never creates items (find_existing_take_at + ApplyAtCell delete path).
    -- 'toggle' stays a single click (drag-toggle would be confusing).
    if _rmb_action == 'delete' then
      local del_pitch         = lane_pitch_at_y(lt, my)
      drag_mode               = 'delete'
      drag_button             = 1
      drag_anchor_time        = cell_start
      drag_last_time          = cell_start
      drag_anchor_pitch       = del_pitch
      drag_anchor_track       = lt.track
      drag_anchor_lane_info   = lt.lane_info
      drag_anchor_take        = nil
      drag_anchor_item_color  = lt.item_color
      drag_anchor_piano       = lt.piano or false
      drag_anchor_lt          = lt
      drag_anchor_subdiv      = rc_subdiv
      current_paint_pitch     = del_pitch
      reaper.Undo_BeginBlock()   -- closed by the drag-release block (button 1)
      drag_active = true
      -- Erase the anchor cell immediately so a tap deletes one note.
      local take = find_existing_take_at(lt.track, cell_start)
      if take then
        local idx = NoteInCell(take, del_pitch, cell_start, cell_end)
        if idx then DeleteNoteAtCell(take, idx) end
      end
    elseif _rmb_action == 'toggle' then
      -- Open the Undo block BEFORE GetOrCreateMidiItemAt so any item it
      -- creates/extends is captured in the same undo step as the note edit.
      reaper.Undo_BeginBlock()
      local item, take = GetOrCreateMidiItemAt(lt.track, cell_start, lt.item_color)
      if take then
        local pitch = lane_pitch_at_y(lt, my)
        local idx   = NoteInCell(take, pitch, cell_start, cell_end)
        if idx then
          DeleteNoteAtCell(take, idx)
        else
          InsertNoteAtCell(take, pitch, cell_start, grid_length(cell_start))
        end
      end
      -- EndBlock outside the `if take` so the block always closes, even when
      -- item creation failed (an empty undo block is coalesced by REAPER).
      reaper.Undo_EndBlock('EON DM: right-click toggle', -1)
    end
    return
  end

  -- ---- Click (LMB down edge): start a gesture ----
  if _click0 and not drag_active then
    -- Locked-lane feedback before bail (case #15). Same one-liner the
    -- right-click handler uses so left-click and right-click feel
    -- consistent on locked lanes instead of one silently working and one
    -- silently not.
    local lt_any, locked = find_lane_target_for_y_with_lock(lane_targets, my)
    if lt_any and locked then
      if reaper.Help_Set then
        reaper.Help_Set('EON DM: lane locked — unlock in Settings → Pads', false)
      end
      return
    end
    local lt = find_lane_target_for_y(lane_targets, my)
    if not lt then return end

    local raw_time   = coords.PixelToTime(mx)
    if not raw_time then return end
    local cell_start = snap_click_time(coords, raw_time, lt.lane_info)
    -- Lanes with their own swing subdivision get a step sized to THAT grid so
    -- swung finer notes don't overlap; default lanes pass nil = project grid.
    local g_eff      = coords.EffectiveSwingDivQN and coords.EffectiveSwingDivQN(lt.lane_info)
    local lane_subdiv_step = (lt.lane_info and lt.lane_info.swing_subdiv and lt.lane_info.swing_subdiv > 0) and g_eff or nil
    local step_len   = grid_length(cell_start, lane_subdiv_step)
    local cell_end   = cell_start + step_len

    -- ── PIANO dispatch ──────────────────────────────────────────────────────
    -- Resize was already claimed by the length-drag init above. Here: a click
    -- ON a note (anywhere along its body, via find_note_at) arms a MOVE; a click
    -- on EMPTY space arms an FL DRAW (drag = length+pitch, click = 1 step). Item
    -- creation is deferred to the gesture's commit-on-release. One Undo block
    -- opened now, closed by whichever release handler fires. NO item is created
    -- on this mousedown (find_existing_take_at never creates).
    if lt.piano then
      local row_pitch = lane_pitch_at_y(lt, my)
      local take      = find_existing_take_at(lt.track, raw_time)
      local idx       = take and find_note_at(take, row_pitch, raw_time)
      reaper.Undo_BeginBlock()
      if idx then
        local okn, _, _, ppq_s, ppq_e, _, _, vel = reaper.MIDI_GetNote(take, idx)
        local _mm = reaper.ImGui_GetKeyMods(ctx) or 0
        note_move_active    = true
        note_move_started   = false
        note_move_take      = take
        note_move_idx       = idx
        note_move_len_ppq   = (okn and (ppq_e - ppq_s)) or 0
        note_move_orig_pitch = row_pitch   -- (was `pitch`, undefined here → nil,
                                           --  which broke the group-move Contains
                                           --  check so only one note moved)
        note_move_orig_ppq_s = ppq_s
        note_move_orig_vel  = (okn and vel) or 100
        -- Shift held → Wave D duplicate: the drag drops a copy, originals stay.
        note_move_dup       = (_mm & reaper.ImGui_Mod_Shift()) ~= 0
        note_move_lt        = lt
        note_move_anchor_mx = mx
        note_move_anchor_my = my
      else
        note_draw_active    = true
        note_draw_started   = false
        note_draw_lt        = lt
        note_draw_anchor_t  = cell_start
        note_draw_anchor_mx = mx
        note_draw_anchor_my = my
      end
      return
    end

    -- ── DRUM dispatch (step sequencer: insert + step-paint drag) ────────────
    -- INVARIANT: open ONE Undo block per gesture; closed on release.
    -- Opened BEFORE the item auto-create so item creation/extension lands in
    -- the same undo step as the note edit (otherwise undo strands the item).
    -- Left-click PAINTS only: insert on an empty cell, idempotent over a filled
    -- one (never deletes — right-click, handled above, does delete/drag-erase).
    -- May auto-create the lane item. Shift/Ctrl/Alt modifiers stay orthogonal.
    local pitch = lane_pitch_at_y(lt, my)   -- drum lanes: pad_pitch

    reaper.Undo_BeginBlock()

    local item, take, created, idx
    item, take, created = GetOrCreateMidiItemAt(lt.track, cell_start, lt.item_color)
    if not take then
      reaper.Undo_EndBlock('EON DM: paint (cancelled — no take)', -1)
      return
    end
    if created then drag_created_items[item] = true end
    idx       = NoteInCell(take, pitch, cell_start, cell_end)
    drag_mode = 'insert'   -- left-click paints only; filled cells are left intact

    drag_button             = 0     -- left-button gesture
    drag_anchor_time        = cell_start
    drag_last_time          = cell_start
    drag_anchor_pitch       = pitch
    drag_anchor_track       = lt.track
    drag_anchor_lane_info   = lt.lane_info
    drag_anchor_take        = take
    drag_anchor_item_color  = lt.item_color
    drag_anchor_piano       = lt.piano or false
    drag_anchor_lt          = lt
    drag_anchor_subdiv      = lane_subdiv_step   -- nil unless this lane has its own swing grid
    current_paint_pitch     = pitch

    drag_active = true

    -- Apply to the anchor cell so a single click commits. Shift+click paints
    -- a ghost note (40% of default velocity).
    if not idx then
      InsertNoteAtCell(take, pitch, cell_start, step_len, paint_velocity_for_mods(ctx))
    end
    return
  end

  -- ---- Drag (anchor button held): paint/erase any cells crossed since last
  -- frame. drag_button selects LMB (0, paint/erase by cell state) or RMB
  -- (1, erase-drag started by right-click delete).
  if drag_active and reaper.ImGui_IsMouseDown(ctx, drag_button) then
    local raw_time = coords.PixelToTime(mx)
    if raw_time then
      -- Piano: follow the mouse-Y row so a diagonal drag paints a chromatic run.
      if drag_anchor_piano then current_paint_pitch = lane_pitch_at_y(drag_anchor_lt, my) end
      local cell_start = snap_click_time(coords, raw_time, drag_anchor_lane_info)
      if drag_last_time and cell_start ~= drag_last_time then
        PaintCellsBetween(drag_last_time, cell_start)
        drag_last_time = cell_start
      end
    end
    return
  end

  -- ---- Release: paint any cells crossed since last frame, close Undo ----
  if drag_active and reaper.ImGui_IsMouseReleased(ctx, drag_button) then
    -- Catch-up paint: if the user released between frames after fast motion,
    -- the down branch already returned, so the final segment was never painted.
    local raw_time = coords.PixelToTime(mx)
    if raw_time then
      if drag_anchor_piano then current_paint_pitch = lane_pitch_at_y(drag_anchor_lt, my) end
      local cell_start = snap_click_time(coords, raw_time, drag_anchor_lane_info)
      if drag_last_time and cell_start ~= drag_last_time then
        PaintCellsBetween(drag_last_time, cell_start)
        drag_last_time = cell_start
      end
    end
    -- No trim on release. Items are intentional fixed-length canvases; extends
    -- happen inline in GetOrCreateMidiItemAt when clicks land past the edge.
    reaper.Undo_EndBlock(string.format('EON DM: paint %s', drag_mode or 'cancel'), -1)
    reset_drag_state()
    return
  end
end

return M
