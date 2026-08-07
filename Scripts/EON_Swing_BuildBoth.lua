-- @description EON Swing: Build Both (Multi-Out + MIDI Lanes)
-- @version 1.0
-- @author EON Studios
-- @about Builds multi-out audio routing then the Drum Matrix MIDI lanes for the focused Swing instance.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(74)
