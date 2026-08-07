-- EON_DM_NewPattern.lua — post a 'new_pattern' command to the running EON
-- Drum Matrix overlay, which creates a new pattern (region) from the current
-- time selection, or the bar under the edit cursor when there's no selection.
-- Works regardless of overlay focus; bind to your key. No-op if the overlay
-- isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'new_pattern', false)
