-- EON_Dock_Debug.lua — toggle the dock-rig diagnostic trace on/off.
--
-- Run once: both pane scripts (EON Swing Dock / EON Steppa Dock) start printing
-- their decisive moments to the ReaScript console — acquire, release, handoff,
-- pop-out requests — each line tagged with a per-instance id, so two copies of
-- the same pane script fighting over one FX (the classic blink loop) show up as
-- two different tags interleaving. Run again: silence.
--
-- Installed with Swing: the bridge registers it in the Action List (EON_Register_Actions).

local on = reaper.GetExtState("EON_SwingDock", "debug") ~= "1"
local v = on and "1" or "0"
reaper.SetExtState("EON_SwingDock",  "debug", v, false)
reaper.SetExtState("EON_SteppaDock", "debug", v, false)
if on then
  reaper.ClearConsole()
  reaper.ShowConsoleMsg("[EON Dock Debug] trace ON — reproduce the problem now, then send/read this console.\n")
else
  reaper.ShowConsoleMsg("[EON Dock Debug] trace OFF.\n")
end
