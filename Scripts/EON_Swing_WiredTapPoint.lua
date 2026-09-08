-- @description EON Swing: Wired Tap Point (channel / bus)
-- @version 1.0
-- @author EON Studios
-- @about Flips where a Wired pad leaves its channel: ON THE CHANNEL (default -- before the pan, like a console insert; the pan and the reverb/delay sends are applied when it comes back) or ON THE BUS (after the pan, exactly what a multi-out child track hears -- so a plugin moved between a child track and a pad insert sounds the same). Kit-wide. Toggles.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(42)
