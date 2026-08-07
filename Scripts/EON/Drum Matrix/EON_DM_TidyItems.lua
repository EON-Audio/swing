-- EON_DM_TidyItems.lua -- retroactive cleanup: dim-style every MIDI item on
-- EON Drum Matrix lanes (tracks with P_EXT:EON_DRUM_LANE) so they blend in
-- with the overlay's bright step cells. Items the BuildKit/SeedLane scripts
-- create from now on already get this styling; this script handles items
-- painted before the styling was added.
--
-- One-shot. Bind to a key, or run from the Action list.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path

local swing_state = dofile(SCRIPT_DIR .. 'lib/swing_state_reader.lua')
local item_style  = dofile(SCRIPT_DIR .. 'lib/item_style.lua')
swing_state.Init()

r.Undo_BeginBlock()
local items, lanes = item_style.DimAll(swing_state)
r.Undo_EndBlock('EON DM: tidy existing items', -1)

r.Help_Set(
  string.format('EON DM tidied %d item(s) across %d lane(s).', items or 0, lanes or 0),
  false
)
