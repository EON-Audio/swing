-- EON_DM_PlaySong.lua — post a 'song_play' command to the running EON Drum
-- Matrix overlay, which toggles native song-mode playback (plays the pattern
-- chain one after another via GoToRegion; press again to stop). Works
-- regardless of overlay focus; bind to your key. No-op if the overlay isn't
-- running.
local r = reaper
r.SetExtState('EON_DRUM_MATRIX', 'cmd_nonce', tostring(r.time_precise()), false)
r.SetExtState('EON_DRUM_MATRIX', 'cmd', 'song_play', false)
