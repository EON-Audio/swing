-- @description EON Swing: Load Kit from File
-- @version 1.0
-- @author EON Studios
-- EON_SB_LoadAllPads.lua
-- Companion script: Open file dialog to load a .swing kit file
-- (c) EON Studios

reaper.gmem_attach("Swing_Media_Transfer")
local CMD = 26090300     -- v1 header relocated 2026-07-09 (cells 0..35 dead; see rk_lua_core GMEM)
local BRIDGE_ALIVE = 99  -- the bridge writes os.time() here every tick, 0 at exit

-- Need the bridge alive (its stamp has moved within 5 s -- the bridge's own test;
-- a crashed bridge leaves a stale stamp) and no command in flight. Say so when
-- not, instead of returning silently; and point LOCK at the Swing in front first
-- ("focused Swing wins", as the EON_Swing_* wrappers do): the bridge's kit load
-- takes LOCK as its target, else the browser's binding or the first live Swing
-- (sweep SCR111).
local alive = math.floor(reaper.gmem_read(BRIDGE_ALIVE) or 0)
if alive <= 0 or (os.time() - alive) >= 5 then
  reaper.MB("The Swing Kit Bridge is not running, so no kit can be loaded.\n\n" ..
            "Open a Swing (the bridge starts with it), then run Load Kit again.",
            "EON Swing: Load Kit", 0)
elseif math.floor(reaper.gmem_read(CMD)) ~= 0 then
  reaper.MB("Swing is busy with another command. Try again in a moment.",
            "EON Swing: Load Kit", 0)
else
  local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
  local T = dofile(dir .. "/EON/eon_action_target.lua")
  T.focus_lock()
  T.bridge(2)  -- CMD 2 = import kit (opens file browser via bridge); stamps LUAPOST so a cancelled dialog's 98 is released at once
end
