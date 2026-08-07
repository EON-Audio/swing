-- EON_DM_SongAddStep.lua — post a 'song_add' command to the running EON Drum
-- Matrix overlay, which appends the CURRENT pattern (the last one you touched)
-- to the end of the song chain. Works regardless of overlay focus; bind to your
-- key. No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'song_add', false)
