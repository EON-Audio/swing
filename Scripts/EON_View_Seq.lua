-- @description EON: Open Step Sequencer view
-- @version 1.0
-- @author EON Studios
-- @about
--   The built-in step sequencer's grid, full-window (Swing 3.1, phase S1).
--   Acts on whichever Swing you last focused ("focused Swing wins"), so bind it
--   to a key or a toolbar button and it follows you between instances.
--   Goes through EON_VIEW_REQ; VIEW_SEQ = 18 (Swing_ReaKit.jsfx, VIEW_ID_MAX 18).
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.view(18)
