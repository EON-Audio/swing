-- @description EON: New Song (starter — regions + Swing + lanes)
-- @version 1.0
-- @author EON Studios
-- @about
--   Builds a song skeleton in one go: sets the tempo, drops the named regions
--   on the timeline, adds a Swing track, and builds the Drum Matrix lanes +
--   multi-out audio (the lanes are the writing surface; per-region MIDI items
--   on the Swing track are created only when lanes are OFF). Prompts for
--   tempo, section length and section names first.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local S = dofile(dir .. "/EON/eon_song_starter.lua")
local T = dofile(dir .. "/EON/eon_action_target.lua")

-- ⚠️ S.prompt is ASYNC (the dialog runs on the defer loop) — the build has to
-- happen inside the callback. Nothing may follow this call that assumes the
-- song exists; the main chunk returns long before the user clicks Create.
S.prompt(function(opts)
  opts.insert_swing = true
  -- ⚠️ Default these only when ABSENT. The ReaImGui dialog supplies them from
  -- its "Also build" checkboxes; the GetUserInputs fallback cannot, and setting
  -- them unconditionally here would quietly ignore whatever the user ticked.
  if opts.midi_items  == nil then opts.midi_items  = true end
  if opts.build_lanes == nil then opts.build_lanes = true end
  opts.target = T
  S.build(opts)
end)
