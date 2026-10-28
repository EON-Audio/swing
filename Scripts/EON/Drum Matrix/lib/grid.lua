-- grid.lua — EON Drum Matrix. Single source of truth for the project-grid
-- division cycle, shared by: the paint-mode wheel handler (paint_mode.lua), the
-- grid-cog widget (grid_widget.lua), and the EON_DM_CycleGrid keybind.
--
-- Cycle: 1/4 -> 1/8 -> 1/16 -> 1/32 -> 1/8T -> 1/16T -> (wrap)
--
-- IMPORTANT: cycling preserves the project's swing MODE and AMOUNT — only the
-- grid DIVISION changes. Writing 0/0 would silently disable a user's project
-- swing (there's no restore path when the overlay isn't open).
--
-- THE UNIT: GetSetProjectGrid's division is in WHOLE notes (0.25 = a quarter,
-- 0.0625 = a 16th, 1/12 = an eighth-note triplet), as REAPER's API text says
-- and REAPER 7.83 measured (EON_Probe_G3Live, leg GRID). The Drum Matrix works
-- in quarter notes (QN, the unit of TimeMap_timeToQN), so every read that
-- sizes a cell goes through M.ProjectDivQN, and every write is in whole notes
-- (STEPS). Reading the division as QN drew every grid 4x finer than REAPER's
-- own and made the cog's "1/16" set REAPER's 1/4 (audit DM14, 2026-10-27).
-- No other Drum Matrix file calls GetSetProjectGrid (grid_state.lua's
-- save / restore round-trips the raw value and is the one exception).

local r = reaper
local M = {}

M.QN_PER_WHOLE = 4

-- Each entry: { division in WHOLE notes (REAPER's unit, written as is), label }.
M.STEPS = {
  { div = 1/4,  label = '1/4'   },
  { div = 1/8,  label = '1/8'   },
  { div = 1/16, label = '1/16'  },
  { div = 1/32, label = '1/32'  },
  { div = 1/12, label = '1/8T'  },
  { div = 1/24, label = '1/16T' },
}

-- The project grid in QN (0 when there is none), plus REAPER's swing mode and
-- amount as they are.
function M.ProjectDivQN(proj)
  local _, div, swingmode, swingamt = r.GetSetProjectGrid(proj or 0, false)
  return (tonumber(div) or 0) * M.QN_PER_WHOLE, swingmode, swingamt
end

local EPS = 1e-4

-- 1-based index of the current project grid within STEPS, or nil if no match.
local function current_index(div)
  if not div then return nil end
  for i = 1, #M.STEPS do
    if math.abs(M.STEPS[i].div - div) < EPS then return i end
  end
  return nil
end

-- Cycle the project grid division by `direction` (>=0 forward, <0 back),
-- wrapping at the ends. Preserves swing mode/amount. Returns the new label.
function M.Cycle(direction)
  local _, div, swingmode, swingamt = r.GetSetProjectGrid(0, false)
  local idx = current_index(div) or 1
  idx = idx + ((direction or 1) >= 0 and 1 or -1)
  if idx < 1 then idx = #M.STEPS end
  if idx > #M.STEPS then idx = 1 end
  local step = M.STEPS[idx]
  r.GetSetProjectGrid(0, true, step.div, swingmode or 0, swingamt or 0)
  r.Help_Set('EON DM grid: ' .. step.label, false)
  return step.label
end

-- Label of the current project grid division ("1/16", etc). Falls back to a
-- compact "1/N" readout for a division that doesn't match a known step.
function M.CurrentLabel()
  local _, div = r.GetSetProjectGrid(0, false)
  local idx = current_index(div)
  if idx then return M.STEPS[idx].label end
  if div and div > 0 then return string.format('1/%g', 1 / div) end
  return '—'
end

return M
