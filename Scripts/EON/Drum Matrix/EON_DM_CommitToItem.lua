-- EON_DM_CommitToItem.lua -- Flatten the painted Drum Matrix pattern into a
-- single MIDI item on a NEW track placed just below the kit, routed into Swing
-- like the lanes. Source lanes are left untouched; the whole operation is one
-- undo step. Bindable action; sibling of EON_DM_Build.lua.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local lane_tools = dofile(SCRIPT_DIR .. 'lib/lane_tools.lua')
if not (lane_tools and lane_tools.CommitPatternToItem) then
  r.ShowMessageBox('lib/lane_tools.lua missing or invalid.', 'EON DM Commit', 0)
  return
end

lane_tools.CommitPatternToItem()
