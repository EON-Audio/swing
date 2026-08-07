-- EON_DM_Copy.lua — post a 'copy' command to the running EON Drum Matrix
-- overlay, which copies the current note selection to its clipboard. Works
-- regardless of overlay focus (ImGui only delivers keys while focused), so
-- bind this to your copy key (e.g. Ctrl+C). No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'copy', false)
