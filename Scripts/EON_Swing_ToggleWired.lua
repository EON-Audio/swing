-- @description EON Swing: Toggle Wired
-- @version 1.0
-- @author EON Studios
-- @about Wired: third-party FX on individual pads, on ONE track, still hitting Swing's master bus. Adds an EON Patchbay last in the chain and switches Swing to send each pad out on its own channel pair and bring it back. Costs one audio buffer while on -- a mixing feature, not a playing one. Toggles.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(41)
