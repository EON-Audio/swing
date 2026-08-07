-- @description EON Swing: Toggle Media Explorer
-- @version 1.0
-- @author EON Studios
-- @about Toggles REAPER's Media Explorer (routed through the bridge so Swing tracks its open state).
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(45)
