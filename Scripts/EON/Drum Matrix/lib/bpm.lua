-- bpm.lua -- EON Drum Matrix. Resolves a recommended BPM for a preset.
-- Priority: preset.bpm (explicit per-pattern override) > GENRE_BPM[genre] > nil.
-- Consumed by preset_library.Apply when the 'apply_sets_tempo' setting is ON.

local M = {}

-- Per-genre default tempos (researched typical production BPMs). Trap is
-- written at its true tempo (~140) even though it is felt half-time (~70).
M.GENRE_BPM = {
  ['trap']     = 140,
  ['hip-hop']  = 90,
  ['boom-bap'] = 94,
  ['rnb']      = 80,
  ['house']    = 124,
  ['techno']   = 130,
  ['dnb']      = 174,
  ['rock']     = 120,
}

local MIN_BPM, MAX_BPM = 40, 300

local function clamp(b)
  b = tonumber(b)
  if not b then return nil end
  if b < MIN_BPM then b = MIN_BPM elseif b > MAX_BPM then b = MAX_BPM end
  return b
end

-- Numeric BPM for the preset, or nil if none can be resolved.
function M.Resolve(preset)
  if type(preset) ~= 'table' then return nil end
  local explicit = clamp(preset.bpm)
  if explicit then return explicit end
  local g = preset.genre and string.lower(preset.genre) or nil
  if g and M.GENRE_BPM[g] then return clamp(M.GENRE_BPM[g]) end
  return nil
end

return M
