-- @description EON Swing: Import SFZ Kit
-- @version 1.0
-- @author EON Studios
-- EON_SB_ImportKit.lua
-- Companion script: Open file dialog to import a .sfz kit file.
-- Mirrors the LOAD button's "Import SFZ Kit..." right-click menu item.
-- (c) EON Studios

reaper.gmem_attach("Swing_Media_Transfer")
local CMD = 26090300     -- v1 header relocated 2026-07-09 (cells 0..35 dead; see rk_lua_core GMEM)
local BRIDGE_ALIVE = 99

-- Need bridge alive to handle kit import
if reaper.gmem_read(BRIDGE_ALIVE) > 0 and math.floor(reaper.gmem_read(CMD)) == 0 then
  local retval, filename = reaper.GetUserFileNameForRead(
    "", "Import SFZ Kit", "sfz"
  )
  if retval then
    -- Store path in ExtState for bridge to pick up
    reaper.SetExtState("Swing", "import_file", filename, false)
    -- Open browser to handle the import
    reaper.gmem_write(26090301, 0)     -- PARAM1 = pad 0 (relocated cell)
    reaper.gmem_write(CMD, 60)  -- CMD 60 = open browser
  end
end
