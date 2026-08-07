-- @description EON: Actions Menu (all)
-- @version 3.0
-- @author EON Studios
-- @about
--   The all-in-one EON command menu: toggles up top (with live checkmarks) then
--   Build / Kit / Pattern / Tools submenus. Handy on a keybind. The per-category
--   buttons (EON_Menu_Build/Kit/Pattern/Tools) show just their own list.
--   Shares one menu tree — see EON/eon_menu_lib.lua.
local sep = package.config:sub(1, 1)
local dir = (({reaper.get_action_context()})[2]:match("^(.*)[/\\]") or "."):gsub("[/\\]", sep)
local M = dofile(dir .. sep .. "EON" .. sep .. "eon_menu_lib.lua")
M.show(M.ALL, dir)
