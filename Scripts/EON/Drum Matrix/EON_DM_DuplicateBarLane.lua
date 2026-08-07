-- EON_DM_DuplicateBarLane.lua — post a 'dup_bar_lane' command to the running
-- EON Drum Matrix overlay, which duplicates the bar under the playhead/cursor
-- forward one bar on the SELECTED lane's track only. Works regardless of
-- overlay focus; bind to your key (e.g. Ctrl+Shift+B). No-op if the overlay
-- isn't running or no Drum Matrix track is selected.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'dup_bar_lane', false)
