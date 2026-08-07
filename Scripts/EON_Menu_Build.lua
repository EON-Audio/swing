-- @description EON: Build Menu
-- @version 1.0
-- @author EON Studios
-- @about Toolbar button — drops the EON Build list (Multi-Out / MIDI Lanes / Both / Stereo).
local sep = package.config:sub(1, 1)
local dir = (({reaper.get_action_context()})[2]:match("^(.*)[/\\]") or "."):gsub("[/\\]", sep)
local M = dofile(dir .. sep .. "EON" .. sep .. "eon_menu_lib.lua")
M.show(M.CAT.build, dir)
