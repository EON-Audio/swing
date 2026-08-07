-- EON_DM_PrevPattern.lua — post a 'prev_pattern' command to the running EON
-- Drum Matrix overlay, which jumps the edit cursor/view to the PREVIOUS pattern
-- (region) in timeline order (wraps). Works regardless of overlay focus; bind
-- to your key. No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'prev_pattern', false)
