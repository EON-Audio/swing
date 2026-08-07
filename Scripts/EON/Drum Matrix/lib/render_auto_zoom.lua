-- render_auto_zoom.lua -- EON Drum Matrix v0.x melodic-track renderer (Phase 3).
-- Paints non-Swing MIDI tracks as a mini piano-roll: one sub-row per pitch in
-- the take's pitch range, with a < 3px fallback to full-height per-note blocks.

local M = {}

-- Per-frame render budget — mirrors render_drum_matrix.lua. A melodic track
-- with thousands of notes can't be allowed to stall the defer tick; notes past
-- the cap just don't draw a block this frame (they remain present in MIDI).
local MAX_NOTES_PER_TRACK_PER_FRAME = 500

local function track_rgb(track)
  local native = reaper.GetTrackColor(track)
  if native == 0 then return 0.55, 0.55, 0.55 end
  local r, g, b = reaper.ColorFromNative(native)
  return r / 255, g / 255, b / 255
end

local function rgba_u32(r, g, b, alpha_0_255)
  alpha_0_255 = alpha_0_255 or 255
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, alpha_0_255 / 255)
end

local function darker(r, g, b, factor)
  factor = factor or 0.55
  return r * factor, g * factor, b * factor
end

function M.RenderTrack(ctx, dl, track, coords, midi_cache)
  local y1, y2, h = coords.GetTrackY(track)
  if not h or h <= 0 then return end

  local view_start, view_end = coords.GetVisibleTimeRange()
  if not view_start or not view_end or view_end <= view_start then return end

  local r, g, b = track_rgb(track)
  local border_r, border_g, border_b = darker(r, g, b, 0.55)
  local border = rgba_u32(border_r, border_g, border_b, 180)

  -- Snapped left view edge: notes straddling the start of the view are clamped
  -- to it so a far-negative cx1 can't reach ImGui's DrawList.
  local x_left = coords.Snap(coords.TimeToPixel(view_start))
  local notes_rendered = 0

  local item_count = reaper.CountTrackMediaItems(track)
  for ii = 0, item_count - 1 do
    if notes_rendered >= MAX_NOTES_PER_TRACK_PER_FRAME then break end
    local item = reaper.GetTrackMediaItem(track, ii)
    local item_start = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local item_len   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local item_end   = item_start + item_len

    if item_end >= view_start and item_start <= view_end then
      local take = reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local min_p, max_p, n = midi_cache.GetPitchRange(take)
        if n and n > 0 and min_p and max_p then
          local pitch_span = (max_p - min_p) + 1
          local sub_row_h = h / pitch_span
          local fallback = sub_row_h < 3   -- < 3px sub-rows -> full-height blocks
          local _, note_count = reaper.MIDI_CountEvts(take)
          for ni = 0, note_count - 1 do
            if notes_rendered >= MAX_NOTES_PER_TRACK_PER_FRAME then break end
            local ok, _, _, ppq_s, ppq_e, _, pitch, vel = reaper.MIDI_GetNote(take, ni)
            if ok then
              local n_start = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_s)
              local n_end   = reaper.MIDI_GetProjTimeFromPPQPos(take, ppq_e)
              if n_end >= view_start and n_start <= view_end then
                -- Snap to integer pixels so blocks align with the drum-matrix
                -- grid; clamp the left edge to the visible start.
                local cx1 = coords.Snap(coords.TimeToPixel(n_start))
                local cx2 = coords.Snap(coords.TimeToPixel(n_end))
                if cx1 < x_left then cx1 = x_left end
                if (cx2 - cx1) < 2 then cx2 = cx1 + 2 end
                local cy1, cy2
                if fallback then
                  cy1, cy2 = y1 + 1, y2 - 1
                else
                  local pitch_offset = max_p - pitch
                  cy1 = y1 + pitch_offset * sub_row_h + 1
                  cy2 = cy1 + sub_row_h - 1
                end
                if cy2 > cy1 then
                  local alpha = 50 + math.floor((vel / 127) * 170 + 0.5)
                  local fill = rgba_u32(r, g, b, alpha)
                  reaper.ImGui_DrawList_AddRectFilled(dl, cx1, cy1, cx2, cy2, fill, 0)
                  if not fallback and sub_row_h >= 4 then
                    reaper.ImGui_DrawList_AddRect(dl, cx1, cy1, cx2, cy2, border, 0, 0, 1)
                  end
                  notes_rendered = notes_rendered + 1
                end
              end
            end
          end
        end
      end
    end
  end
end

return M
