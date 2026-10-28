-- grid_state.lua -- EON Drum Matrix. Save/restore REAPER's project grid
-- around the overlay's lifetime so the user can change the grid on the fly
-- (via REAPER, EON_DM_CycleGrid, or the settings menu) without permanently
-- mutating the project. SaveCurrent on overlay startup; Restore on atexit.
--
-- Stores division, swing mode, and swing amount — the full GetSetProjectGrid
-- return so we can put back exactly what was there.

local M = {}

local saved        = false
local s_division   = nil
local s_swingmode  = nil
local s_swingamt   = nil
-- The project the grid was read from, so Restore writes it back THERE whatever tab is current at exit
-- (DM218, 2026-10-26: project 0 is the current tab, so stopping the overlay from another tab wrote tab A's
-- grid into tab B). A closed tab is left alone.
local s_proj       = nil

function M.SaveCurrent()
  if saved then return end
  s_proj = reaper.EnumProjects and reaper.EnumProjects(-1) or nil
  local _, div, mode, amt = reaper.GetSetProjectGrid(s_proj or 0, false)
  s_division  = div
  s_swingmode = mode
  s_swingamt  = amt
  saved = true
end

function M.Restore()
  if not saved then return end
  saved = false
  if s_proj and reaper.ValidatePtr and not reaper.ValidatePtr(s_proj, 'ReaProject*') then return end
  -- Even if div/mode/amt didn't change during the session, this is a no-op
  -- in REAPER terms (writes the same value back). Cheap.
  reaper.GetSetProjectGrid(s_proj or 0, true, s_division, s_swingmode, s_swingamt)
end

return M
