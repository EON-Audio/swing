-- EON_DM_Roll3.lua -- Insert a 3-stroke triplet roll inside the grid cell at
-- the edit cursor, on the currently selected drum lane. Bind to a key.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local lane_tools = dofile(SCRIPT_DIR .. 'lib/lane_tools.lua')

local lane = lane_tools.GetSelectedLane()
if not lane then
  r.Help_Set('EON DM Roll: select a drum-lane track in REAPER first.', false)
  return
end

local n = lane_tools.Roll(lane, r.GetCursorPosition(), 3)
r.Help_Set(string.format('EON DM Roll x3: %d note(s) on %s', n, lane.lane_info.pad_name or '?'), false)
