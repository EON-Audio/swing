-- EON_DM_DuplicateBar.lua — post a 'dup_bar_all' command to the running EON
-- Drum Matrix overlay, which duplicates the bar under the playhead/cursor
-- forward one bar across EVERY lane, then advances the cursor (when stopped).
-- Works regardless of overlay focus; bind to your key (e.g. Ctrl+B). No-op if
-- the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'dup_bar_all', false)
