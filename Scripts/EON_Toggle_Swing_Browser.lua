-- @description EON Swing: Toggle Sample Browser
-- @version 1.0
-- @author EON Studios
-- EON_Toggle_Swing_Browser.lua
--
-- Toggles the EON Swing browser open/closed as a standalone REAPER action.
-- No Swing JSFX required — sample preview, search, categories, BPM/key
-- analysis, and recursive scan all work without Swing on a track. Loading
-- samples to a Swing pad still requires the Swing JSFX + bridge running,
-- but otherwise the browser is fully usable as a generic media browser.
--
-- Behaviour:
--   - If browser is closed → open it
--   - If browser is open   → close it (signals the running instance to exit)
--
-- ─── HOW TO INSTALL AS A REAPER ACTION ───────────────────────────────
--   1. REAPER → Actions → Action List…
--   2. Click "ReaScript: Load…" (top-right of the dialog)
--   3. Browse to this file (EON_Toggle_Swing_Browser.lua) → Open
--   4. The action now appears in the action list as
--        "Script: EON_Toggle_Swing_Browser.lua"
--      Bind a keyboard shortcut or add it to a toolbar.

local sep = package.config:sub(1, 1)

local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)") or ""
  return path:match("^(.*)[/\\]") or ""
end

local script_dir   = _get_script_dir()
local browser_path = script_dir .. sep .. "Swing_Browser.lua"

-- The browser must live alongside this launcher (both ship inside the
-- EON Scripts folder via the installer). If someone moved the launcher
-- out by hand, fail loudly rather than silently.
local f = io.open(browser_path, "r")
if not f then
  reaper.MB(
    "Swing_Browser.lua not found in:\n" .. script_dir ..
    "\n\nThis launcher must live in the same folder as the browser.",
    "EON Toggle Swing Browser",
    0
  )
  return
end
f:close()

-- If the browser is already running, signal it to close. The browser's
-- defer loop checks the "browser_close" ExtState every frame and exits
-- gracefully when it sees "1" — that hook is at Swing_Browser.lua:~4414.
--
-- Stale-state recovery: cross-check ExtState against gmem[GS_BROWSER_OPEN].
-- If ExtState says running but gmem disagrees, the previous browser session
-- crashed/died without cleanup. Clear the stale flag and proceed to launch
-- a fresh window.
--
-- Constants mirror rk_lua_core (GMEM_NAME / core.GMEM.GS_BROWSER_OPEN);
-- kept as locals so this launcher stays dependency-free as an action.
-- History: this attach once said "DrumKit_ReaKit" — a pre-rename segment
-- name nothing else uses — so the read was always 0, every toggle-while-open
-- looked "stale", and the close signal never fired (fixed 2026-07-29).
local GMEM_NAME       = "Swing_Media_Transfer"
local GS_BROWSER_OPEN = 1382
if reaper.GetExtState("Swing", "browser_running") == "1" then
  reaper.gmem_attach(GMEM_NAME)
  if reaper.gmem_read(GS_BROWSER_OPEN) == 0 then
    -- Stale: ExtState says running but gmem says closed. Clear and relaunch.
    reaper.SetExtState("Swing", "browser_running", "0", false)
  else
    -- Genuinely running — signal close
    reaper.SetExtState("Swing", "browser_close", "1", false)
    return
  end
end

-- Browser not running → register Swing_Browser.lua as a REAPER action and
-- fire it. The browser itself owns its defer loop — Main_OnCommand returns
-- immediately and the loop keeps spinning in its own context until the
-- user closes the window (or this script is run again to toggle).
--
-- Deliberately NOT unregistered afterwards. AddRemoveReaScript(false, path)
-- removes the action for that PATH no matter who registered it — so the old
-- register-run-unregister dance here silently stripped any permanent
-- registration the user held of Swing_Browser.lua itself (it works standalone
-- as a generic media browser, so loading it straight into the Action List is
-- plausible; the same bug class killed the user's Dock View action on
-- 2026-08-26). Registering is idempotent — the same path always yields the
-- same _RS command id, no duplicates — so the worst cost of leaving it is one
-- stable Action List entry, which is also exactly what keeps shortcuts and
-- menu buttons on that id alive.
local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
if cmd_id and cmd_id > 0 then
  reaper.Main_OnCommand(cmd_id, 0)
else
  reaper.MB(
    "REAPER could not register Swing_Browser.lua.\n\n" ..
    "Check that the file is readable and not blocked by antivirus.",
    "EON Toggle Swing Browser",
    0
  )
end
