-- EON_DM_ToggleLiveTrigger.lua -- toggle live MIDI preview when painting.
-- One-shot. Bind to a key. When ON, each inserted note fires an immediate
-- Note On via REAPER's virtual MIDI keyboard input (StuffMIDIMessage mode 1),
-- followed by a Note Off ~150ms later.
--
-- IMPORTANT — for sound to actually reach Swing, each kit track needs:
--   * Record arm ON
--   * Monitor input ON  (the speaker icon, set to "Monitor input")
--   * Record input = "Virtual MIDI keyboard"
-- Without that setup, the toggle does nothing audible. Default is OFF.
--
-- Writes through settings_store so the settings window's Paint tab checkbox
-- stays in sync with this action.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local settings = dofile(SCRIPT_DIR .. 'lib/settings_store.lua')
settings.Load()

local new_value = not (settings.Get('live_trigger') == true)
settings.Set('live_trigger', new_value)

local _, _, section_id, cmd_id = r.get_action_context()
if section_id and cmd_id and cmd_id ~= 0 then
  r.SetToggleCommandState(section_id, cmd_id, new_value and 1 or 0)
  r.RefreshToolbar2(section_id, cmd_id)
end

r.Help_Set(
  string.format('EON Drum Matrix: live trigger %s', new_value and 'ON' or 'OFF'),
  false
)
