-- EON_DM_AdoptRegions.lua -- One-shot. Adopt EVERY project region into the
-- Drum Matrix pattern membership set (EON_DRUM_MATRIX:patterns ProjExtState).
--
-- The pattern system deliberately tracks membership instead of claiming every
-- region in the ruler, so regions created OUTSIDE it -- an older Song Starter
-- run, hand-made song sections, an imported project -- are invisible to the DM
-- bar, the bridge's name/colour publish and a synced StepSeq, even though they
-- look identical in the timeline. Running this action is the explicit "yes,
-- these are my patterns" gesture: every current region becomes a pattern.
-- Idempotent (set semantics) and self-healing like the rest of the membership
-- set; regions added later still need adopting (or create them via the DM /
-- StepSeq "+" / the current Song Starter, which all register their own).
--   * Add it via Action List -> New -> ReaScript -> pick this file. Works
--     whether the overlay is open or not.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
-- Add lib/ to package.path so any module reached transitively can use a bare
-- require() -- matches eon_drum_matrix.lua and the sibling action scripts.
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local patterns = dofile(SCRIPT_DIR .. 'lib/pattern_regions.lua')

if not (patterns and patterns.Adopt) then
  r.ShowMessageBox(
    'EON Drum Matrix: lib/pattern_regions.lua not found alongside this script.\n\n' ..
    'Make sure the EON Drum Matrix package is fully installed.',
    'EON DM: Adopt Regions', 0)
  return
end

-- Enumerate regions directly (EnumProjectMarkers3, isrgn only) rather than via
-- patterns.List(), which by design only returns what is ALREADY adopted.
local total, i = 0, 0
while true do
  local retval, isrgn, _, _, _, idx = r.EnumProjectMarkers3(0, i)
  if retval == 0 then break end
  if isrgn then
    total = total + 1
    patterns.Adopt(idx)   -- no-op write-skip when already a member
  end
  i = i + 1
end

if total == 0 then
  r.ShowMessageBox('No regions in this project -- nothing to adopt.',
    'EON DM: Adopt Regions', 0)
else
  -- Help-bar status like the sibling one-shots; List() also self-heals the set.
  local n = #patterns.List()
  if r.Help_Set then
    r.Help_Set(('EON DM: %d region%s adopted as patterns.')
      :format(n, n == 1 and '' or 's'), false)
  end
end
