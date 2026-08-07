-- EON_DM_ZoomToPattern.lua -- One-shot. Fit the arrange view to the CURRENT
-- pattern region (the explicit current pattern, else the one under the edit
-- cursor, else the first). Non-destructive view change; never moves the cursor.
--
-- Three entry points share one implementation in lib/pattern_regions.lua so
-- tweaks to "what counts as the current pattern" propagate everywhere at once:
--   * The overlay's Z key (when the EON Drum Matrix overlay is focused).
--   * Settings → Tools → "Zoom to pattern" button + the toolbar / Manager
--     "Fit pattern" buttons.
--   * THIS action — add it via Action List → New → ReaScript → pick this
--     file, then bind a key, drag to a toolbar, or assign to a MIDI
--     controller. Works whether the overlay is open or not.
-- (See EON_DM_ZoomSong.lua for the whole-song counterpart.)

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
-- Add lib/ to package.path so any module reached transitively can use a bare
-- require() — matches eon_drum_matrix.lua and the sibling action scripts.
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local patterns = dofile(SCRIPT_DIR .. 'lib/pattern_regions.lua')

if not (patterns and patterns.ZoomToCurrent) then
  r.ShowMessageBox(
    'EON Drum Matrix: lib/pattern_regions.lua not found alongside this script.\n\n' ..
    'Make sure the EON Drum Matrix package is fully installed.',
    'EON DM: Zoom to Pattern', 0)
  return
end

patterns.ZoomToCurrent()
-- ZoomToCurrent sets its own "no patterns" status when there's nothing to
-- frame, so we don't double-message here.
