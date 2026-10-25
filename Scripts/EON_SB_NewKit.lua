-- @description EON Swing: New Kit
-- @version 1.1
-- @author EON Studios
-- EON_SB_NewKit.lua
-- Companion script: empty one Swing (all four banks, the kit name and the
-- master FX) and start a new kit.
-- Addressed to ONE Swing (audit H04, user decision 2026-10-23): the focused
-- Swing, else the project's only Swing, else a message. Never a broadcast: a
-- TARGET-0 cmd 4 wiped whichever instance's @gfx ticked first.
-- (c) EON Studios

local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_action_target.lua")

local iid, why = T.companion_target()
if iid then
  T.companion_to(iid, 4)  -- 4 = new kit; silent when a companion cmd is still pending, as before
elseif why == "lite" then
  reaper.MB("New Kit works on Swing, not on Swing Lite.", "EON Swing: New Kit", 0)
elseif why == "many" then
  reaper.MB("This project has more than one Swing.\n\nOpen the Swing you want to start a new kit in, then run New Kit again.",
            "EON Swing: New Kit", 0)
else
  reaper.MB("No Swing found to start a new kit in.\n\nOpen the Swing you want first, then run New Kit again.",
            "EON Swing: New Kit", 0)
end
