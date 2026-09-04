-- @description EON: Open FX Picker
-- @version 1.0
-- @author EON Studios
-- @about
--   The FX picker, full-window over the pad grid.
--   Acts on whichever Swing you last focused ("focused Swing wins"), so bind it
--   to a key or a toolbar button and it follows you between instances.
--
--   This action is also the test for VIEW_FXPICK's registration: the request
--   goes through EON_VIEW_REQ, whose ceiling silently drops any view id above
--   it. If the view opens by click but this action does nothing, the ceiling in
--   Swing_ReaKit.jsfx was not raised alongside the id.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.view(11)
