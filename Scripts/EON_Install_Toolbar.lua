-- @description EON: Install / Refresh Toolbar
-- @version 1.0
-- @author EON Studios
-- @about
--   Creates the EON floating toolbar — Grid, Paint, Step Seq, Pad FX, Media,
--   Browser, New Song, and the four menu buttons — wired to the action IDs your
--   REAPER assigned on THIS machine.
--
--   Adds a NEW floating toolbar in the first free slot; toolbars you already
--   have are never touched, and reaper-menu.ini is backed up first. Restart
--   REAPER afterwards: REAPER holds toolbars in memory and rewrites that file
--   on exit, so the new one only survives a clean restart.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local T = dofile(dir .. "/EON/eon_toolbar.lua")

local slot = T.scan()
if slot then
  reaper.ShowMessageBox(
    "An EON toolbar already exists (Floating toolbar " .. slot .. ").\n\n" ..
    "Delete it in Options > Customize menus/toolbars first if you want this " ..
    "script to rebuild it from scratch.",
    "EON Toolbar", 0)
else
  local ok, msg = T.build(dir)
  reaper.ShowMessageBox(msg, ok and "EON Toolbar" or "EON Toolbar — not created", 0)
end
