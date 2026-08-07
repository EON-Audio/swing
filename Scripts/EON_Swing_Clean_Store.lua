-- EON: Swing — Clean sample store
-- User action (auto-registered by EON_Register_Actions). Asks the running
-- Swing bridge to reclaim orphaned sample-store dirs for the CURRENT saved
-- project — extracted sample files no loaded kit or sidecar still needs.
-- Saved kits and in-use samples are kept; if any Swing instance can't confirm
-- its live paths, the bridge deletes nothing. The bridge does the work (it
-- owns the store paths + the CMD-87 instance handshake); this action just
-- confirms intent and flags it.

local sep = package.config:sub(1, 1)
local this = ({ reaper.get_action_context() })[2] or ""
local dir = this:match("^(.*)[/\\]") or "."
local ok, core = pcall(dofile, dir .. sep .. "rk_lua_core.lua")
if not ok or not core then
  reaper.ShowMessageBox("Could not load Swing core library.", "EON Swing", 0)
  return
end

reaper.gmem_attach(core.GMEM_NAME)
local alive = math.floor(reaper.gmem_read(core.GMEM.BRIDGE_ALIVE) or 0)
if alive == 0 then
  reaper.ShowMessageBox(
    "The Swing bridge isn't running.\nOpen a project with a Swing instance, then retry.",
    "EON Swing — Clean sample store", 0)
  return
end

local _, projfn = reaper.EnumProjects(-1)
if not projfn or projfn == "" then
  reaper.ShowMessageBox(
    "Clean sample store needs a SAVED project.\nSave the project first, then retry.",
    "EON Swing — Clean sample store", 0)
  return
end

local r = reaper.ShowMessageBox(
  "Reclaim orphaned Swing samples for THIS project?\n\n" ..
  "Deletes extracted sample files that no loaded kit or sidecar still " ..
  "needs (e.g. left behind after re-saving a kit). Saved kits and in-use " ..
  "samples are kept. If any Swing instance can't confirm its samples, " ..
  "nothing is deleted.\n\nResult appears in the ReaScript console.",
  "EON Swing — Clean sample store", 4)   -- 4 = Yes/No
if r ~= 6 then return end                 -- 6 = Yes

reaper.SetExtState("EON_Bridge", "clean_store_req", "1", false)
reaper.ShowConsoleMsg("[EON] Clean sample store requested — the bridge will report the result here.\n")
