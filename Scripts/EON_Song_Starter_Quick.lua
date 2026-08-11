-- @description EON: New Song (quick — no prompt)
-- @version 1.0
-- @author EON Studios
-- @about
--   Same as "EON: New Song" but skips the dialog: 120 BPM, four 8-bar sections
--   (Intro / Verse / Chorus / Outro), Swing track, the Drum Matrix lanes and
--   the multi-out audio children (the lanes are the writing surface, so no
--   extra items land on the Swing track). Bind this to a key for a one-press
--   session start.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local S = dofile(dir .. "/EON/eon_song_starter.lua")
local T = dofile(dir .. "/EON/eon_action_target.lua")

S.build({
  bpm          = S.DEFAULT_BPM,
  bars         = S.DEFAULT_BARS,
  sections     = S.DEFAULT_SECTIONS,
  insert_swing = true,
  midi_items   = true,
  build_lanes  = true,
  multi_out    = true,
  target       = T,
})
