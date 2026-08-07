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

function M.SaveCurrent()
  if saved then return end
  local _, div, mode, amt = reaper.GetSetProjectGrid(0, false)
  s_division  = div
  s_swingmode = mode
  s_swingamt  = amt
  saved = true
end

function M.Restore()
  if not saved then return end
  -- Even if div/mode/amt didn't change during the session, this is a no-op
  -- in REAPER terms (writes the same value back). Cheap.
  reaper.GetSetProjectGrid(0, true, s_division, s_swingmode, s_swingamt)
  saved = false
end

-- Read-back of saved values (for the settings menu to display "Original grid
-- will restore on close: 1/16, no swing").
function M.GetSaved()
  if not saved then return nil end
  return s_division, s_swingmode, s_swingamt
end

return M
