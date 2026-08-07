-- @description EON Swing: Toggle Drum Matrix Grid
-- @version 1.0
-- @author EON Studios
-- @about Toggles the Drum Matrix grid overlay for the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(76)
