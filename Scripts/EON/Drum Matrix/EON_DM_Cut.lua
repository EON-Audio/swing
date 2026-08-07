-- EON_DM_Cut.lua — post a 'cut' command to the running EON Drum Matrix overlay
-- (copy the note selection, then delete it). Works regardless of overlay focus;
-- bind this to your cut key (e.g. Ctrl+X). No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'cut', false)
