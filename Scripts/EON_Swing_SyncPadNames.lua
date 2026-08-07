-- @description EON Swing: Sync Pad Names to MIDI
-- @version 1.0
-- @author EON Studios
-- @about Pushes the focused Swing instance's pad names out to the piano-roll note names and multi-out track names.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(52)
