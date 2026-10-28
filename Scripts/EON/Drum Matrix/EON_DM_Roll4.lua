-- EON_DM_Roll4.lua -- Insert a 4-stroke roll (64th notes) inside the grid cell
-- at the edit cursor, on the currently selected drum lane. Bind to a key.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local lane_tools = dofile(SCRIPT_DIR .. 'lib/lane_tools.lua')

local lane = lane_tools.GetSelectedLane()
if not lane then
  r.Help_Set('EON DM Roll: select a drum-lane track in REAPER first.', false)
  return
end
-- A stereo-grid lane holds every pad in one item: lane_tools.Roll would clear
-- the whole cell (every pad) and roll at the lowest pad's pitch. An action has
-- no row to aim at, so refuse (audit DM11, 2026-10-26; Roll2 / Roll3 alike).
if lane.lane_info.stereo == true then
  r.Help_Set('EON DM Roll: the stereo grid lane has no single pad to roll; select a per-pad lane.', false)
  return
end

local n = lane_tools.Roll(lane, r.GetCursorPosition(), 4)
r.Help_Set(string.format('EON DM Roll x4: %d note(s) on %s', n, lane.lane_info.pad_name or '?'), false)
