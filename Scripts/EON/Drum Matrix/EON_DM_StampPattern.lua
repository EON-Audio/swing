-- EON_DM_StampPattern.lua — post a 'stamp_pattern' command to the running EON
-- Drum Matrix overlay, which stamps an independent copy of the CURRENT pattern
-- (region) across every lane at the playhead/cursor. Non-destructive; advances
-- the cursor when stopped. Works regardless of overlay focus; bind to your key.
-- No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'stamp_pattern', false)
