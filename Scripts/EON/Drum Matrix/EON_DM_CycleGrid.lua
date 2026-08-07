-- EON_DM_CycleGrid.lua -- cycle the project grid through common drum-pattern
-- divisions. Bind to a key for fast grid switching while painting.
-- The grid change here is TEMPORARY for the Drum Matrix session — when the
-- overlay closes, eon_drum_matrix.lua's atexit restores the original grid.
--
-- Cycle: 1/4 -> 1/8 -> 1/16 -> 1/32 -> 1/8T -> 1/16T -> 1/4
--
-- Division list + cycle logic live in lib/grid.lua (single source of truth,
-- shared with the paint-mode wheel + the grid-cog widget). Cycling preserves
-- the project's swing mode/amount.

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local grid = dofile(_SCRIPT_DIR .. 'lib/grid.lua')
grid.Cycle(1)
