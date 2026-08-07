-- @description EON Swing: Toggle Paint Mode
-- @version 1.0
-- @author EON Studios
-- @about Toggles Drum Matrix paint mode (opens the grid if it isn't already up).
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(75)
