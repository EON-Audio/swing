-- @description EON Swing: Build Merged (one track per drum)
-- @version 1.0
-- @author EON Studios
-- @about Moves each pad's pattern item onto its own multi-out audio track, so one track per drum carries both. Needs Multi-Out first.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(79)
