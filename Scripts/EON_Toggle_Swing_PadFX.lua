-- EON_Toggle_Swing_PadFX.lua
--
-- Toggles the EON Swing Pad FX window open/closed as a standalone REAPER action.
-- Requires the Swing JSFX running to do anything useful (it reads/writes the
-- selected pad's FX over gmem), but the window opens regardless.
--
-- Behaviour:
--   - If the Pad FX window is closed → open it
--   - If it is open                  → close it (signals the running instance)
--
-- ─── HOW TO INSTALL AS A REAPER ACTION ───────────────────────────────
--   1. REAPER → Actions → Action List…
--   2. Click "ReaScript: Load…" (top-right of the dialog)
--   3. Browse to this file (EON_Toggle_Swing_PadFX.lua) → Open
--   4. Bind a keyboard shortcut or add it to a toolbar.

local sep = package.config:sub(1, 1)

local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)") or ""
  return path:match("^(.*)[/\\]") or ""
end

local script_dir = _get_script_dir()
local padfx_path = script_dir .. sep .. "Swing_PadFX.lua"

local f = io.open(padfx_path, "r")
if not f then
  reaper.MB(
    "Swing_PadFX.lua not found in:\n" .. script_dir ..
    "\n\nThis launcher must live in the same folder as the Pad FX window.",
    "EON Toggle Swing Pad FX",
    0
  )
  return
end
f:close()

-- If the window is already running, signal it to close. The window's defer loop
-- checks the "padfx_close" ExtState every frame and exits gracefully.
--
-- Stale-state recovery: the window stamps "padfx_heartbeat" (os.time) every
-- frame. If "padfx_running" says running but the heartbeat is older than a few
-- seconds, the previous session crashed without cleanup — clear and relaunch.
if reaper.GetExtState("Swing", "padfx_running") == "1" then
  local hb = tonumber(reaper.GetExtState("Swing", "padfx_heartbeat")) or 0
  if (os.time() - hb) < 3 then
    reaper.SetExtState("Swing", "padfx_close", "1", false)
    return
  end
  reaper.SetExtState("Swing", "padfx_running", "0", false)  -- stale; fall through to launch
end

-- Not running → register Swing_PadFX.lua as a temporary REAPER action, fire it,
-- then unregister so it doesn't add a duplicate action-list entry every run.
local cmd_id = reaper.AddRemoveReaScript(true, 0, padfx_path, true)
if cmd_id and cmd_id > 0 then
  reaper.Main_OnCommand(cmd_id, 0)
  reaper.AddRemoveReaScript(false, 0, padfx_path, true)
else
  reaper.MB(
    "REAPER could not register Swing_PadFX.lua.\n\n" ..
    "Check that the file is readable and not blocked by antivirus.",
    "EON Toggle Swing Pad FX",
    0
  )
end
