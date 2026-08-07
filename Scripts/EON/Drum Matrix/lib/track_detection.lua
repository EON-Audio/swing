-- track_detection.lua — classify REAPER tracks for EON Drum Matrix renderer
-- (drum_lane | midi_track | skip).
--
-- Hardening pass changes:
--   * Validate pad_pitch (0..127) and pad_index (1..16) at decode time;
--     reject + warn if missing/out-of-range (case #23 in plan).
--   * Surface malformed JSON via safety.ConsoleWarnOnce — keyed per track so
--     we don't spam (case #22).
--   * Self-heal pad_name on track rename: if the track's display name has
--     changed since P_EXT was last written, update P_EXT in place (case #40).
--     Throttled per-track to avoid hammering P_EXT writes when nothing
--     changed — only re-write when the strings actually differ.
--   * Graceful degrade if json.lua is missing: log once at first call and
--     refuse to detect drum lanes (case #26).

local M = {}

local _SCRIPT_DIR_TD = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

-- json.lua: hard-required for proper detection. We load it lazily so a
-- borked install logs a single warning instead of failing to dofile this
-- module at all.
local json
do
  local ok, mod = pcall(dofile, _SCRIPT_DIR_TD .. 'json.lua')
  if ok and type(mod) == 'table' and mod.decode then json = mod end
end

-- safety.lua: optional but expected; lets us warn the user about corrupt
-- P_EXT or missing JSON dep.
local _safety
do
  local ok, mod = pcall(dofile, _SCRIPT_DIR_TD .. 'safety.lua')
  if ok and type(mod) == 'table' then _safety = mod end
end
local function warn_once(key, msg)
  if _safety then _safety.ConsoleWarnOnce(key, msg) end
end

-- swing_state_reader: used ONLY to gate the REAPER→P_EXT reverse-sync while
-- Swing is alive. Loaded via pcall so a broken/missing reader doesn't break
-- track detection. When the reader is unavailable we treat Swing as absent
-- (no gating) — falls back to the prior pre-P4 behavior.
local _swing_state
do
  local ok, mod = pcall(dofile, _SCRIPT_DIR_TD .. 'swing_state_reader.lua')
  if ok and type(mod) == 'table' and mod.IsAlive then _swing_state = mod end
end
local _ss_init_done = false
local function is_swing_alive()
  if not _swing_state then return false end
  if not _ss_init_done then
    _ss_init_done = true
    if _swing_state.Init then _swing_state.Init() end
  end
  return _swing_state.IsAlive()
end

local _json_warned = false
local function ensure_json()
  if json then return true end
  if not _json_warned then
    _json_warned = true
    if _safety then
      _safety.ConsoleWarn('track_detection: json.lua missing — drum lanes will not be detected. Reinstall.')
    end
  end
  return false
end

-- Track-pointer keyed cache for the rename self-heal so we don't write P_EXT
-- every defer tick. Re-keyed on track pointer (REAPER reuses pointers across
-- delete/recreate, but the pad_name in P_EXT is the source of truth, so a
-- stale cache only delays one self-heal write — harmless).
local _last_name_for_track = {}

function M.IsVisible(track)
  return reaper.GetMediaTrackInfo_Value(track, 'B_SHOWINTCP') == 1
end

function M.HasMIDIItems(track)
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    local item = reaper.GetTrackMediaItem(track, i)
    local take = reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then return true end
  end
  return false
end

-- Validate the decoded lane_info shape. Returns true if it's safe to use.
-- Reject lanes whose pad_pitch is missing/out of MIDI range or whose
-- pad_index is missing/out of the 1..16 pad layout — those almost always
-- indicate a corrupt P_EXT we don't want to render against.
local function validate_lane_info(decoded, warn_key)
  if type(decoded) ~= 'table' then return false end
  local p = decoded.pad_pitch
  if type(p) ~= 'number' or p < 0 or p > 127 or p ~= math.floor(p) then
    warn_once('td:bad_pitch:' .. tostring(warn_key),
              'drum_lane P_EXT has invalid pad_pitch (' .. tostring(p) .. ') — lane skipped')
    return false
  end
  local idx = decoded.pad_index
  if type(idx) ~= 'number' or idx < 1 or idx > 16 or idx ~= math.floor(idx) then
    warn_once('td:bad_index:' .. tostring(warn_key),
              'drum_lane P_EXT has invalid pad_index (' .. tostring(idx) .. ') — lane skipped')
    return false
  end
  -- Optional per-pad pitch range (piano view). Both bounds must be present,
  -- be 0..127 integers, and satisfy note_lo <= note_hi. A malformed range is a
  -- corrupt P_EXT we won't render against — skip + warn-once. Absent fields are
  -- fine: the lane defaults to drum mode at pad_pitch downstream.
  local lo, hi = decoded.note_lo, decoded.note_hi
  if lo ~= nil or hi ~= nil then
    local lo_ok = type(lo) == 'number' and lo >= 0 and lo <= 127 and lo == math.floor(lo)
    local hi_ok = type(hi) == 'number' and hi >= 0 and hi <= 127 and hi == math.floor(hi)
    if not (lo_ok and hi_ok) or lo > hi then
      warn_once('td:bad_range:' .. tostring(warn_key),
                'drum_lane P_EXT has invalid note_lo/note_hi (' .. tostring(lo) ..
                '/' .. tostring(hi) .. ') — lane skipped')
      return false
    end
  end
  -- Optional per-lane swing (#8): -1..1. Unlike pitch/range, a bad swing value
  -- is NOT fatal — we clamp/zero it in place (decoded is the lane_info handed
  -- downstream) so a hand-edited or corrupt field can't reach the swing math or
  -- the slider. Absent = straight (0), resolved downstream.
  local sw = decoded.swing_amount
  if sw ~= nil then
    if type(sw) ~= 'number' then
      warn_once('td:bad_swing:' .. tostring(warn_key),
                'drum_lane P_EXT has non-numeric swing_amount (' .. tostring(sw) .. ') — reset to 0')
      decoded.swing_amount = 0
    elseif sw < -1 or sw > 1 then
      warn_once('td:clamp_swing:' .. tostring(warn_key),
                'drum_lane P_EXT swing_amount out of range (' .. tostring(sw) .. ') — clamped')
      decoded.swing_amount = (sw < -1) and -1 or 1
    end
  end
  -- Optional per-lane swing SUBDIVISION (#8 follow-up): a QN grid division the
  -- swing math runs on, independent of the project/paint grid. Absent / 0 =
  -- follow the project grid (the default, unchanged behavior). Like swing_amount
  -- a bad value is non-fatal: drop to nil (follow project) + warn-once so a
  -- hand-edited field can't reach the swing math. Allowed set mirrors the cog
  -- combo: 1/8, 1/16 (binary) and 1/8T, 1/16T (triplet).
  local sd = decoded.swing_subdiv
  if sd ~= nil and sd ~= 0 then
    local ALLOWED = { 0.5, 0.25, 1/12, 1/24 }
    local ok = type(sd) == 'number'
    if ok then
      ok = false
      for _, d in ipairs(ALLOWED) do
        if math.abs(sd - d) < 1e-6 then ok = true break end
      end
    end
    if not ok then
      warn_once('td:bad_subdiv:' .. tostring(warn_key),
                'drum_lane P_EXT swing_subdiv invalid (' .. tostring(sd) .. ') — follow project grid')
      decoded.swing_subdiv = nil
    end
  end
  return true
end

-- Self-heal pad_name when the user renames the REAPER track. Compares the
-- live track name against the value cached in P_EXT; if they differ, updates
-- P_EXT in place and mutates the in-memory lane_info so this frame sees the
-- new name. Throttled — only re-reads/writes when the cached name differs
-- from the live track name for that track pointer.
--
-- Sync direction note (Phase H vs Phase I):
--   * THIS function handles REAPER track rename -> P_EXT (the user typing a
--     new track name in the TCP).
--   * lib/swing_sync.lua handles the OTHER direction: Swing pad rename / kit
--     change / pad-pitch change -> P_EXT + REAPER track name.
--
-- Crucial detail: the TCP track name carries an "NN " display prefix (Build
-- and swing_sync write "01 Kick"), but P_EXT pad_name stays BARE ("Kick") so
-- it matches the bare names Swing publishes to gmem. So before comparing, we
-- strip the exact "NN " prefix for this lane's pad_index. Without this, the
-- self-heal would copy "01 Kick" into pad_name, swing_sync would reset it to
-- "Kick", and the two would tug back and forth.
local function self_heal_pad_name(track, lane_info)
  if not (track and lane_info) then return end
  -- Stereo-mode lane: the "track" IS the Swing track — its name is the user's
  -- (or the bridge's) business, never a pad_name source. Without this guard a
  -- renamed Swing track would rewrite pad_name whenever the FX is offline.
  if lane_info.stereo == true then return end
  -- P4 — neuter the REAPER→P_EXT reverse-sync while Swing owns identity.
  -- swing_sync.lua is the single forward path (Swing gmem → P_EXT + P_NAME).
  -- If the user renames a lane track in the TCP while Swing is publishing,
  -- the change is ephemeral: the next sync writes the kit's name back, so a
  -- self-heal here would just open a tug-of-war and risk clobbering Swing's
  -- live name with a stale TCP edit captured mid-frame. Rename pads from
  -- the Swing UI instead. When Swing is absent (e.g. removed from the FX
  -- chain), the self-heal re-enables automatically.
  if is_swing_alive() then return end
  local _, track_name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
  if not track_name or track_name == '' then return end

  -- Strip the "NN " display prefix (exact match on this pad's index only, so a
  -- pad genuinely named "808 Bass" isn't mangled).
  local idx = lane_info.pad_index
  if type(idx) == 'number' then
    local prefix = string.format('%02d ', idx)
    if track_name:sub(1, #prefix) == prefix then
      track_name = track_name:sub(#prefix + 1)
    end
  end

  -- Cheap short-circuit: if we already saw this (stripped) name for this track
  -- pointer, skip the comparison + write.
  if _last_name_for_track[track] == track_name then return end
  _last_name_for_track[track] = track_name

  if lane_info.pad_name == track_name then return end   -- nothing to do
  lane_info.pad_name = track_name

  -- Persist via re-encode. Failure here is logged but non-fatal — the
  -- in-memory lane_info still reflects the new name for the current frame.
  if not json or not json.encode then return end
  local ok, encoded = pcall(json.encode, lane_info)
  if ok and encoded then
    reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', encoded, true)
  end
end

function M.GetLaneInfo(track)
  if not ensure_json() then return nil end
  local ok, raw = reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', '', false)
  if not ok or raw == '' then return nil end

  local decoded_ok, decoded = pcall(json.decode, raw)
  if not decoded_ok or type(decoded) ~= 'table' then
    warn_once('td:bad_json:' .. tostring(track),
              'drum_lane P_EXT JSON failed to decode — lane skipped (reinstall or re-Build).')
    return nil
  end
  if not validate_lane_info(decoded, track) then return nil end
  return decoded
end

function M.Classify(track)
  if not M.IsVisible(track) then return 'skip', nil end
  local lane = M.GetLaneInfo(track)
  if lane then
    self_heal_pad_name(track, lane)
    return 'drum_lane', lane
  end
  if M.HasMIDIItems(track) then return 'midi_track', nil end
  return 'skip', nil
end

return M
