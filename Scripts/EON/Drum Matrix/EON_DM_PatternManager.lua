-- EON_DM_PatternManager.lua — post a 'toggle_manager' command to the running
-- EON Drum Matrix overlay, which shows/hides the dockable Pattern Manager panel
-- (sortable patterns table + drag-reorder song builder). Works regardless of
-- overlay focus; bind to your key. No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'toggle_manager', false)
