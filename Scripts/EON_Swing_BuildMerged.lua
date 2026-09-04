-- @description EON Swing: Build Merged (one track per drum)
-- @version 1.0
-- @author EON Studios
-- @about One click to merged mode: builds Swing's multi-out audio tracks, then gives each pad's track its own pattern item, so one track per drum carries the notes and the channel strip. Same entry as Swing's build menu.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(92)
