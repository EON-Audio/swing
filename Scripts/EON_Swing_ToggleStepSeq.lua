-- @description EON Swing: Toggle Step Sequencer
-- @version 1.0
-- @author EON Studios
-- @about Opens/floats the EON Step Sequencer paired to the focused Swing instance's track.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(70)
