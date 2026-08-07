-- EON_DM_DuplicateSelection.lua — post a 'dup_sel' command to the running EON
-- Drum Matrix overlay, which duplicates the note selection one bar to the right
-- (repeated presses tile forward). Works regardless of overlay focus; bind to
-- your duplicate key (e.g. Ctrl+D). No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'dup_sel', false)
