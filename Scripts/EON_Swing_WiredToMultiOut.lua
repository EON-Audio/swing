-- @description EON Swing: Wired to Multi-Out
-- @version 1.0
-- @author EON Studios
-- @about Converts a Wired Swing to Multi-Out: switches Wired off, runs the normal Multi-Out build, and moves each pad's plugins from its channel pair onto its new child track, chain order kept. Plugins not on a pad pair stay on the Swing track and are listed in the summary.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.fire(43)
