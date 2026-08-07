-- @description EON Swing: Batch Import Samples
-- @version 1.0
-- @author EON Studios
-- @about Opens the multi-file sample picker and assigns the selection across pads on the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(20)
