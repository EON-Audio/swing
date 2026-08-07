-- @description EON Swing: Build Multi-Out Routing
-- @version 1.0
-- @author EON Studios
-- @about Builds per-pad multi-output audio routing on the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(40)
