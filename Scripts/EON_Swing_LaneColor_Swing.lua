-- @description EON Swing: Lane Colors — Swing owns
-- @version 1.0
-- @author EON Studios
-- @about Sets the focused Swing so IT paints the pad/lane track colors (default).
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local L = dofile(dir .. "/EON/eon_lane_color.lua")
L.SetFocused("swing")
