-- category.lua -- EON Drum Matrix. Per-pad category enum + auto-infer from
-- pad name via a synonym table. Used by the preset library to map
-- (genre, category) -> applicable presets, and shown as a dropdown in the
-- Settings -> Pads tab so the user can override the guess for any pad.

local M = {}

local _SCRIPT_DIR_CAT = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

-- Lazy-load json + safety so a malformed install doesn't crash the module.
local _json, _safety
local function get_json()
  if _json ~= nil then return _json or nil end
  local ok, mod = pcall(dofile, _SCRIPT_DIR_CAT .. 'json.lua')
  _json = (ok and type(mod) == 'table' and mod.encode) and mod or false
  return _json or nil
end
local function get_safety()
  if _safety ~= nil then return _safety or nil end
  local ok, mod = pcall(dofile, _SCRIPT_DIR_CAT .. 'safety.lua')
  _safety = (ok and type(mod) == 'table') and mod or false
  return _safety or nil
end
local function warn(msg)
  local s = get_safety()
  if s then s.ConsoleWarn(msg) end
end

M.CATEGORIES = {
  'kick', 'snare', 'closed_hat', 'open_hat', 'clap',
  'ride', 'crash', 'tom', 'rim', 'perc', 'other',
}

-- Synonym table. Substring matches (case-insensitive). Order matters within a
-- key: more specific synonyms first so 'closed hh' beats the generic 'hh'.
M.SYNONYMS = {
  closed_hat = { 'closed hat', 'closed hh', 'chh', 'pedal hh', 'ch ', 'c.hat' },
  open_hat   = { 'open hat',   'open hh',   'ohh', 'o.hat', 'oh '            },
  kick       = { 'kick', 'kik', 'bd', 'bass drum', 'sub'                     },
  snare      = { 'snare', 'snr', 'sn ', 'sd '                                },
  hat        = { 'hat', 'hh', 'hi-hat', 'hihat'                              },  -- fallback bucket -> closed
  clap       = { 'clap', 'cp '                                               },
  ride       = { 'ride'                                                       },
  crash      = { 'crash', 'cymbal', 'cym'                                    },
  tom        = { 'tom'                                                        },
  rim        = { 'rim', 'side stick', 'sidestick', 'ss '                     },
  perc       = { 'cowbell', 'clave', 'shaker', 'maracas', 'tambourine',
                 'tamb', 'conga', 'bongo', 'cabasa', 'guiro', 'triangle',
                 'block', 'agogo', 'cuica', 'vibraslap', 'whistle'           },
}

-- Order in which we check synonyms for inference. Most specific first.
local CHECK_ORDER = {
  'closed_hat', 'open_hat',          -- specific hats first
  'kick', 'snare',
  'hat',                              -- generic hat falls back to closed_hat
  'clap', 'ride', 'crash', 'tom', 'rim', 'perc',
}

local function contains_ci(haystack, needle)
  return string.find(string.lower(haystack), needle, 1, true) ~= nil
end

function M.InferFromName(pad_name)
  if not pad_name or pad_name == '' then return 'other' end
  for _, category in ipairs(CHECK_ORDER) do
    local synonyms = M.SYNONYMS[category]
    if synonyms then
      for _, s in ipairs(synonyms) do
        if contains_ci(pad_name, s) then
          -- 'hat' bucket maps to closed_hat (the most common interpretation).
          if category == 'hat' then return 'closed_hat' end
          return category
        end
      end
    end
  end
  return 'other'
end

-- Read category off lane_info. Falls back to name-inferred when not set.
function M.GetForLane(lane_info)
  if not lane_info then return 'other' end
  if lane_info.category and M.IsValid(lane_info.category) then
    return lane_info.category
  end
  return M.InferFromName(lane_info.pad_name or '')
end

-- No cross-category fallback. Presets are picked by EXACT (genre, category).
-- If a genre doesn't have a preset for a lane's category, the lane stays
-- untouched — that's intentional: not every drum sound belongs in every genre
-- (e.g., trap doesn't typically use crash patterns; house doesn't lean on
-- toms). The Randomize Kit status bar reports how many lanes were skipped so
-- the user knows what happened. To populate a missing slot, add a preset
-- JSON to that genre's folder.
function M.GetFallbackChain(cat)
  return { cat or 'other' }
end

function M.IsValid(category)
  for _, c in ipairs(M.CATEGORIES) do
    if c == category then return true end
  end
  return false
end

-- Persist a category change on the track's P_EXT.
-- track: MediaTrack, lane_info: the decoded P_EXT table (passed for caller
-- convenience; the live P_EXT is re-read so any concurrent writes from other
-- modules survive), category: new category string.
--
-- Critical: read-decode-MERGE-write. Without the merge, a stale lane_info
-- passed in by a caller (e.g. cached from N frames ago) would overwrite any
-- other field another module wrote in the meantime (live_trigger, locked,
-- show_strip, etc.).
function M.SetForLane(track, lane_info, category)
  if not (track and M.IsValid(category)) then return false end
  local json = get_json()
  if not json then
    warn('category.SetForLane: json.lua missing — cannot persist')
    return false
  end

  -- Read the LIVE P_EXT JSON so we merge with whatever's currently stored.
  local _, raw = reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', '', false)
  local merged = {}
  if raw and raw ~= '' then
    local ok_dec, decoded = pcall(json.decode, raw)
    if ok_dec and type(decoded) == 'table' then
      for k, v in pairs(decoded) do merged[k] = v end
    end
  end
  -- Also merge in fields from the caller's lane_info (in case track was just
  -- built and the P_EXT hasn't been committed yet).
  if type(lane_info) == 'table' then
    for k, v in pairs(lane_info) do
      if merged[k] == nil then merged[k] = v end
    end
  end
  merged.category = category

  local ok_enc, encoded = pcall(json.encode, merged)
  if not ok_enc or not encoded then
    warn('category.SetForLane: json.encode failed (' .. tostring(encoded) .. ')')
    return false
  end
  reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', encoded, true)

  -- Keep the caller's lane_info table in sync so a subsequent read doesn't
  -- show stale data within the same frame.
  if type(lane_info) == 'table' then lane_info.category = category end
  return true
end

return M
