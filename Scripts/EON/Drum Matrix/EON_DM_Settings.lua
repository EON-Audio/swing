-- EON_DM_Settings.lua -- toggle the EON Drum Matrix settings window.
-- One-shot. Bind to a key. The running eon_drum_matrix.lua polls the
-- "settings_open" ExtState flag each frame and draws the window when set.
-- Pattern lifted directly from TK_Trackname_Settings_Toggle.lua.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local settings = dofile(SCRIPT_DIR .. 'lib/settings_store.lua')

settings.ToggleWindow()

local _, _, section_id, cmd_id = r.get_action_context()
if section_id and cmd_id and cmd_id ~= 0 then
  r.SetToggleCommandState(section_id, cmd_id, settings.IsWindowOpen() and 1 or 0)
  r.RefreshToolbar2(section_id, cmd_id)
end

r.Help_Set(
  string.format('EON Drum Matrix settings: %s', settings.IsWindowOpen() and 'OPEN' or 'CLOSED'),
  false
)
