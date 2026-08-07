-- @description EON: New Song — regions only
-- @version 1.0
-- @author EON Studios
-- @about
--   Drops the four named song regions on the timeline and nothing else — no
--   track, no Swing, no lanes, and the project tempo is left alone. For adding
--   a section map to a project that is already underway. Regions start at the
--   bar under the edit cursor, so this appends rather than overlaying bar 1.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local S = dofile(dir .. "/EON/eon_song_starter.lua")

S.build({
  bars     = S.DEFAULT_BARS,
  sections = S.DEFAULT_SECTIONS,
})
