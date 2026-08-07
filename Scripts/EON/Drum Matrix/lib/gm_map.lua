-- gm_map.lua -- EON Drum Matrix. Maps a MIDI pitch to a Drum Matrix category
-- (the same enum as category.lua M.CATEGORIES) when importing external .mid
-- drum patterns. Covers the General MIDI percussion map plus the common
-- Roland V-Drums / TD-11 extensions used by humanized datasets (e.g. the
-- Groove MIDI Dataset), which place hat edge/bow and cymbal bow/bell on extra
-- notes.
--
-- Categories produced (must stay a subset of category.lua M.CATEGORIES):
--   kick snare clap rim closed_hat open_hat ride crash tom perc other
--
-- Usage:
--   local gm = dofile(SCRIPT_DIR .. 'gm_map.lua')
--   local cat = gm.GetCategory(pitch)                 -- default GM/Roland map
--   local cat = gm.GetCategory(pitch, my_override)    -- per-pack override table
--
-- An override table is { [pitch] = 'category', ... }; any pitch it lists wins
-- over the built-in map, so a non-GM pack can be remapped without editing this
-- file. Pitches with no mapping return 'perc' (a safe musical default for
-- unknown percussion) rather than 'other', so imported hits are never dropped.

local M = {}

-- Built-in pitch -> category. GM standard with Roland/GMD additions noted.
M.DEFAULT = {
  -- Kick
  [35] = 'kick',        -- Acoustic Bass Drum
  [36] = 'kick',        -- Bass Drum 1

  -- Snare + rim/x-stick
  [37] = 'rim',         -- Side Stick / cross-stick
  [38] = 'snare',       -- Acoustic Snare (head)
  [40] = 'snare',       -- Electric Snare (rim shot on Roland)

  -- Clap
  [39] = 'clap',        -- Hand Clap

  -- Toms
  [41] = 'tom',         -- Low Floor Tom
  [43] = 'tom',         -- High Floor Tom
  [45] = 'tom',         -- Low Tom
  [47] = 'tom',         -- Low-Mid Tom
  [48] = 'tom',         -- Hi-Mid Tom
  [50] = 'tom',         -- High Tom

  -- Hi-hats (closed/pedal vs open). Roland edge/bow extras: 22/26.
  [22] = 'closed_hat',  -- Roland: Hi-Hat Closed (edge)
  [42] = 'closed_hat',  -- Closed Hi-Hat
  [44] = 'closed_hat',  -- Pedal Hi-Hat
  [26] = 'open_hat',    -- Roland: Hi-Hat Open (edge)
  [46] = 'open_hat',    -- Open Hi-Hat

  -- Ride (bow/bell/edge)
  [51] = 'ride',        -- Ride Cymbal 1
  [53] = 'ride',        -- Ride Bell
  [59] = 'ride',        -- Ride Cymbal 2 (Roland ride edge)

  -- Crash (incl. China/Splash -> crash family)
  [49] = 'crash',       -- Crash Cymbal 1
  [52] = 'crash',       -- Chinese Cymbal
  [55] = 'crash',       -- Splash Cymbal
  [57] = 'crash',       -- Crash Cymbal 2

  -- Aux percussion
  [54] = 'perc',        -- Tambourine
  [56] = 'perc',        -- Cowbell
  [58] = 'perc',        -- Vibraslap
  [60] = 'perc',        -- Hi Bongo
  [61] = 'perc',        -- Low Bongo
  [62] = 'perc',        -- Mute Hi Conga
  [63] = 'perc',        -- Open Hi Conga
  [64] = 'perc',        -- Low Conga
  [65] = 'perc',        -- High Timbale
  [66] = 'perc',        -- Low Timbale
  [67] = 'perc',        -- High Agogo
  [68] = 'perc',        -- Low Agogo
  [69] = 'perc',        -- Cabasa
  [70] = 'perc',        -- Maracas
  [71] = 'perc',        -- Short Whistle
  [72] = 'perc',        -- Long Whistle
  [73] = 'perc',        -- Short Guiro
  [74] = 'perc',        -- Long Guiro
  [75] = 'perc',        -- Claves
  [76] = 'perc',        -- Hi Wood Block
  [77] = 'perc',        -- Low Wood Block
  [78] = 'perc',        -- Mute Cuica
  [79] = 'perc',        -- Open Cuica
  [80] = 'perc',        -- Mute Triangle
  [81] = 'perc',        -- Open Triangle
}

-- Return the category for a MIDI pitch. `override` (optional) is a per-pack
-- { [pitch] = category } table that takes precedence. Unknown pitches fall back
-- to 'perc' so no imported hit is silently lost.
function M.GetCategory(pitch, override)
  pitch = math.floor(tonumber(pitch) or -1)
  if override and override[pitch] then return override[pitch] end
  return M.DEFAULT[pitch] or 'perc'
end

-- True if the pitch has an explicit (non-fallback) mapping. Lets callers tell a
-- known drum voice from a guessed-'perc' catch-all (e.g. to warn on odd packs).
function M.IsMapped(pitch, override)
  pitch = math.floor(tonumber(pitch) or -1)
  if override and override[pitch] then return true end
  return M.DEFAULT[pitch] ~= nil
end

return M
