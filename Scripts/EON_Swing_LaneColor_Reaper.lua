-- @description EON Swing: Lane Colors — REAPER owns
-- @version 1.0
-- @author EON Studios
-- @about Focused Swing stops painting lane tracks; REAPER/SWS colors flow into the pads.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local L = dofile(dir .. "/EON/eon_lane_color.lua")
L.SetFocused("reaper")
