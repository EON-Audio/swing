-- @description EON Swing: Multi-Out to Wired
-- @version 1.0
-- @author EON Studios
-- @about Collapses a Multi-Out Swing back to one track in Wired: each pad track's plugins move onto the Swing track pinned to that pad's pair (chain order kept), a pad track's fader is carried as a Volume plugin at the end of its insert, the pad tracks and return tracks are removed, and Wired switches on with the tap on the bus. Refuses -- changing nothing -- if any pad track holds recorded items, sends, or receives.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(44)
