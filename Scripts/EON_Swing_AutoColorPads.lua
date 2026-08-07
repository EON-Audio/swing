-- @description EON Swing: Auto-Color Pads
-- @version 1.0
-- @author EON Studios
-- @about Auto-assigns pad colors on the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(23)
