-- @description EON Swing: Chop Audio to Pads
-- @version 1.0
-- @author EON Studios
-- @about Slices the arrangement/selection to pads on the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(30)
