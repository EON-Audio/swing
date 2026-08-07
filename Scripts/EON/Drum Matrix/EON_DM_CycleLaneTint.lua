-- EON_DM_CycleLaneTint.lua -- cycle the drum-lane background tint opacity.
-- One-shot REAPER action. Bind to a key/toolbar button for quick adjustment.
-- Cycles "lane_tint_alpha" through: 0 -> 30 -> 60 -> 90 -> 0.
-- Writes through settings_store so the settings window stays in sync.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local settings = dofile(SCRIPT_DIR .. 'lib/settings_store.lua')
settings.Load()

local STEPS = { 0, 30, 60, 90 }

local current = settings.Get('lane_tint_alpha') or 0
local next_idx = 1
for i = 1, #STEPS do
  if STEPS[i] == current then
    next_idx = (i % #STEPS) + 1
    break
  end
end
local new_value = STEPS[next_idx]
settings.Set('lane_tint_alpha', new_value)

local label = (new_value == 0) and 'OFF (clean cells)' or ('alpha ' .. new_value)
r.Help_Set(string.format('EON Drum Matrix: lane tint %s', label), false)
