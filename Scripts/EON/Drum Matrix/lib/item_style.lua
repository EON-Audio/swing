-- item_style.lua -- EON Drum Matrix. Shared dim/restore helpers for the MIDI
-- items that sit under each drum lane.
--
-- Two modes:
--   M.DimAll(swing_state)     -> walk every track with P_EXT:EON_DRUM_LANE,
--                                set each item's I_CUSTOMCOLOR to a dim hue of
--                                the pad color and clear the take name. The
--                                overlay calls this at startup so the painted
--                                step cells dominate visually.
--   M.RestoreAll()            -> same walk; clear I_CUSTOMCOLOR (set to 0) so
--                                items inherit the rainbow track color set by
--                                the seed. The overlay calls this in atexit so
--                                vibrant colors come back when the script stops.
--
-- The dim factor is 0.18 (matches the original Tidy/Build helpers).

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.decode then json = mod end
end

local DIM_FACTOR = 0.18

local function dim_color_native(pad_r, pad_g, pad_b)
  local R = math.floor(pad_r * 255 * DIM_FACTOR + 0.5)
  local G = math.floor(pad_g * 255 * DIM_FACTOR + 0.5)
  local B = math.floor(pad_b * 255 * DIM_FACTOR + 0.5)
  return reaper.ColorToNative(R, G, B) | 0x1000000
end

-- Returns pad_index plus the decoded lane record (so callers can resolve the
-- lane's own Swing instance for multi-Swing color reads).
local function get_lane_pad_index(track)
  if not json then return nil end
  local ok, raw = reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', '', false)
  if not ok or raw == '' then return nil end
  local dec_ok, lane = pcall(json.decode, raw)
  if not dec_ok or type(lane) ~= 'table' then return nil end
  return lane.pad_index, lane
end

function M.DimAll(swing_state)
  if not swing_state then return 0, 0 end
  local track_count   = reaper.CountTracks(0)
  local items_touched = 0
  local lanes_touched = 0
  for ti = 0, track_count - 1 do
    local track = reaper.GetTrack(0, ti)
    local pad_idx, lane = get_lane_pad_index(track)
    if pad_idx then
      local slot = swing_state.SlotForLane and swing_state.SlotForLane(lane) or nil
      local pr, pg, pb = swing_state.GetPadColor(pad_idx, slot)
      local color = dim_color_native(pr, pg, pb)
      local item_count = reaper.CountTrackMediaItems(track)
      local any = false
      for ii = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, ii)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', color)
          reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', true)
          items_touched = items_touched + 1
          any = true
        end
      end
      if any then lanes_touched = lanes_touched + 1 end
    end
  end
  reaper.UpdateArrange()
  return items_touched, lanes_touched
end

function M.RestoreAll()
  local track_count   = reaper.CountTracks(0)
  local items_touched = 0
  for ti = 0, track_count - 1 do
    local track = reaper.GetTrack(0, ti)
    local pad_idx = get_lane_pad_index(track)
    if pad_idx then
      local item_count = reaper.CountTrackMediaItems(track)
      for ii = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, ii)
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          reaper.SetMediaItemInfo_Value(item, 'I_CUSTOMCOLOR', 0)
          items_touched = items_touched + 1
        end
      end
    end
  end
  reaper.UpdateArrange()
  return items_touched
end

return M
