-- EON_DM_ImportMIDI.lua -- One-shot REAPER action. Imports drum .mid files from
--   <DrumMatrix>/import/<genre>/*.mid
-- into the format:2 preset library (presets/<genre>/<category>__<group>.json),
-- de-interleaving each loop into per-lane fragments by GM pitch.
--
-- Run on a scratch/empty project. See lib/pattern_import.lua for details.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path

local ok, importer = pcall(dofile, SCRIPT_DIR .. 'lib/pattern_import.lua')
if not (ok and type(importer) == 'table' and importer.Run) then
  r.ShowMessageBox('lib/pattern_import.lua missing or invalid:\n' .. tostring(importer),
                   'EON DM Import MIDI', 0)
  return
end

local summary = importer.Run()

local header = string.format(
  'Imported %d preset(s) from %d file(s) across %d genre(s). %d skipped.\n\n',
  summary.presets, summary.files, #summary.genres, summary.skipped)

-- Detailed per-file log to the console; concise result to a dialog.
r.ShowConsoleMsg('[EON DM Import MIDI]\n' .. table.concat(summary.lines, '\n') .. '\n\n')

local note = (summary.presets > 0)
  and 'Reload EON Drum Matrix (or reopen the cog Patterns menu) to see the new presets.'
  or  'Nothing imported. Put .mid files under import/<genre>/ and try again. See console for details.'

r.ShowMessageBox(header .. note, 'EON DM Import MIDI', 0)
