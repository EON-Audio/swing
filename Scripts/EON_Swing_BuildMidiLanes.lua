-- @description EON Swing: Build MIDI Lanes (Drum Matrix)
-- @version 1.0
-- @author EON Studios
-- @about Builds the classic Drum Matrix MIDI lanes for the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(73)
