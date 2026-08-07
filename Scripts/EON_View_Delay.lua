-- @description EON: Open Delay view
-- @version 1.0
-- @author EON Studios
-- @about
--   Full-size delay page.
--   Acts on whichever Swing you last focused ("focused Swing wins"), so bind it
--   to a key or a toolbar button and it follows you between instances.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")
T.view(6)
