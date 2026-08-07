-- @description EON: New Song (starter — regions + Swing + lanes)
-- @version 1.0
-- @author EON Studios
-- @about
--   Builds a song skeleton in one go: sets the tempo, drops four named regions
--   on the timeline, adds a Swing track with an empty MIDI item per region, and
--   builds the Drum Matrix lanes. Prompts for tempo, section length and section
--   names first — take the defaults for a standard 4-part, 8-bar-each layout.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local S = dofile(dir .. "/EON/eon_song_starter.lua")
local T = dofile(dir .. "/EON/eon_action_target.lua")

local opts = S.prompt()
if opts then
  opts.insert_swing = true
  opts.midi_items   = true
  opts.build_lanes  = true
  opts.target       = T
  S.build(opts)
end
