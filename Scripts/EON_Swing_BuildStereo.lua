-- @description EON Swing: Build / Open Stereo Grid
-- @version 1.0
-- @author EON Studios
-- @about One click to the stereo Drum Matrix grid for the focused Swing instance (builds if untagged, opens if tagged).
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(77)
