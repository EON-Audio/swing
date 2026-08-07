-- @description EON Swing: Lane Colors — Independent
-- @version 1.0
-- @author EON Studios
-- @about Focused Swing neither writes nor reads lane track colors — pad and track color are unrelated.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local L = dofile(dir .. "/EON/eon_lane_color.lua")
L.SetFocused("none")
