-- EON_DM_ZoomSong.lua -- One-shot. Fit the arrange view to the WHOLE SONG: the
-- span of every pattern region (first start -> last end). Non-destructive view
-- change; never moves the edit cursor.
--
-- Companion to EON_DM_ZoomToPattern.lua (which frames just the current pattern).
-- Shares one implementation with the overlay's toolbar / Manager "Fit song"
-- buttons in lib/pattern_regions.lua, so framing tweaks propagate everywhere.
--   * Add it via Action List -> New -> ReaScript -> pick this file, then bind a
--     key, drag to a toolbar, or assign to a MIDI controller. Works whether the
--     overlay is open or not.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
-- Add lib/ to package.path so any module reached transitively can use a bare
-- require() — matches eon_drum_matrix.lua and the sibling action scripts.
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local patterns = dofile(SCRIPT_DIR .. 'lib/pattern_regions.lua')

if not (patterns and patterns.ZoomToSong) then
  r.ShowMessageBox(
    'EON Drum Matrix: lib/pattern_regions.lua not found alongside this script.\n\n' ..
    'Make sure the EON Drum Matrix package is fully installed.',
    'EON DM: Zoom to Song', 0)
  return
end

patterns.ZoomToSong()
-- ZoomToSong sets its own "no patterns" status when there's nothing to frame,
-- so we don't double-message here.
