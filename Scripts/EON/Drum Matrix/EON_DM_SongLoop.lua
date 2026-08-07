-- EON_DM_SongLoop.lua — post a 'song_loop' command to the running EON Drum
-- Matrix overlay, which toggles whether song-mode playback loops the whole
-- chain or stops after the last pattern. Works regardless of overlay focus;
-- bind to your key. No-op if the overlay isn't running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'song_loop', false)
