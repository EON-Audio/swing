-- @description EON Swing: Build Merged (one track per drum)
-- @version 1.0
-- @author EON Studios
-- @about One click to merged mode: builds Swing's multi-out audio tracks, then moves each pad's pattern item onto its own one. Same entry as Swing's build menu.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(83)
