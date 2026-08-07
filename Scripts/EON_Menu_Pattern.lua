-- @description EON: Pattern Menu
-- @version 1.0
-- @author EON Studios
-- @about Toolbar button — drops the EON Pattern list (Drum Matrix edit + Song / Grid Tools submenus).
local sep = package.config:sub(1, 1)
local dir = (({reaper.get_action_context()})[2]:match("^(.*)[/\\]") or "."):gsub("[/\\]", sep)
local M = dofile(dir .. sep .. "EON" .. sep .. "eon_menu_lib.lua")
M.show(M.CAT.pattern, dir)
