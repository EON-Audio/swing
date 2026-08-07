-- EON_DM_TogglePaint.lua -- toggle paint mode for EON Drum Matrix overlay.
-- Bind to a keyboard shortcut or toolbar button. Flips the ExtState
-- ("EON_DRUM_MATRIX", "paint_mode") that the running eon_drum_matrix.lua
-- reads each frame to gate click capture. One-shot, no UI, no defer.

local r = reaper

local SECTION = "EON_DRUM_MATRIX"
local KEY     = "paint_mode"

local current   = r.GetExtState(SECTION, KEY)
local on        = (current == "1")
local new_value = on and "0" or "1"

r.SetExtState(SECTION, KEY, new_value, true)

local _, _, section_id, cmd_id = r.get_action_context()
if section_id and cmd_id and cmd_id ~= 0 then
  r.SetToggleCommandState(section_id, cmd_id, new_value == "1" and 1 or 0)
  r.RefreshToolbar2(section_id, cmd_id)
end
