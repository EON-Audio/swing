-- EON_DM_Paste.lua — post a 'paste' command to the running EON Drum Matrix
-- overlay, which pastes its note clipboard at the playhead (play cursor while
-- running, else edit cursor), snapped to the grid. Works regardless of overlay
-- focus — this is the reliable way to paste after moving the playhead, since
-- clicking the ruler defocuses the overlay and ImGui then can't see Ctrl+V.
-- Bind this to your paste key (e.g. Ctrl+V). No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'paste', false)
