-- swing_sync.lua -- EON Drum Matrix Phase I. Propagates Swing-side changes
-- (kit load, sample swap, pad rename, pad MIDI-note change) DOWN into the
-- drum_lane tracks: updates each lane's P_EXT pad_name / pad_pitch and the
-- REAPER track name so the matrix reflects the live kit.
--
-- Direction: Swing -> Drum Matrix only. The reverse (REAPER track rename ->
-- P_EXT) is handled by track_detection.lua's self-heal (Phase H). Between the
-- two, Swing is the source of truth for kit identity; REAPER track names just
-- mirror it.
--
-- Cadence: M.Tick() runs every defer frame. It computes a cheap digest of the
-- live Swing pad state (kit name + 16 pad names + 16 pad pitches) and short-
-- circuits when nothing changed, so the expensive per-lane write pass only
-- runs on actual changes. Writes are SILENT (no Undo block) — reflecting the
-- current kit isn't a project edit the user would want to Ctrl+Z.
--
-- Multi-Swing: lanes are grouped by the swing_instance_guid each carries in
-- P_EXT (the Swing TRACK guid Build stamps). Each group resolves to its
-- instance's registry slot (swing_state_reader.SlotForGuid) and syncs from
-- THAT instance's per-slot IDENT/PADNAME bands — two kits' lanes no longer
-- fight over the legacy shared block. A group whose instance can't be
-- resolved (track deleted, FX offline, stale heartbeat) is left untouched,
-- EXCEPT the degenerate single-group case, which falls back to the legacy
-- shared-block read so pre-registry Swing builds keep syncing exactly as
-- before.

local M = {}

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local swing_state    = dofile(_SCRIPT_DIR .. 'swing_state_reader.lua')
local lane_tools     = dofile(_SCRIPT_DIR .. 'lane_tools.lua')
local lane_integrity = dofile(_SCRIPT_DIR .. 'lane_integrity.lua')
local track_reflect  = dofile(_SCRIPT_DIR .. 'track_reflect.lua')

-- P2 — icons. The categorizer (used by the browser to classify drop-ins into
-- drum types) is the SAME source of truth we use for per-track icons, so the
-- icon and the kit hue ALWAYS agree on what kind of drum a pad is. Resolver
-- maps the category string to an absolute icon path. Both modules are pcall
-- dofile'd — a missing module just disables icons, never breaks the sync.
local _icons, _categorizer
do
  local scripts_root = _SCRIPT_DIR .. '../../../'  -- lib → DM → EON → Scripts/
  local ok1, m1 = pcall(dofile, scripts_root .. 'rk_lua_icons.lua')
  if ok1 and type(m1) == 'table' and m1.resolve then _icons = m1 end
  local ok2, m2 = pcall(dofile, scripts_root .. 'eon_filename_categorizer.lua')
  if ok2 and type(m2) == 'table' and m2.classify then _categorizer = m2 end
end
-- Returns the absolute icon path for a pad's display name, or '' to clear
-- the track's icon (used for blank pads). Returns nil when modules are
-- absent, signalling "leave P_ICON unchanged" to track_reflect.
-- color_native (optional): the lane's I_CUSTOMCOLOR — when given, picks the
-- hue-tinted variant (resolve_tinted) so the icon follows the kit hue.
local function icon_for_pad_name(name, color_native)
  if not (_icons and _categorizer) then return nil end
  if not name or name == '' then return '' end
  local cat = _categorizer.classify(name)
  if color_native and _icons.resolve_tinted then
    return _icons.resolve_tinted(cat, color_native) or ''
  end
  return _icons.resolve(cat) or ''
end

local json
do
  local ok, mod = pcall(dofile, _SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.encode then json = mod end
end

local _safety
do
  local ok, mod = pcall(dofile, _SCRIPT_DIR .. 'safety.lua')
  if ok and type(mod) == 'table' then _safety = mod end
end
local function warn_once(key, msg)
  if _safety then _safety.ConsoleWarnOnce(key, msg) end
end

-- Unified lane track color (P1). The ONE color source is the live kit hue that
-- Swing publishes (META +12), folded with the theme S/L — exactly what the pad
-- face and the bridge's audio tracks use. `swing_state.GetPadColor` resolves
-- the hue (incl. B&W sentinels + positional fallback); we just convert to a
-- native I_CUSTOMCOLOR int with REAPER's custom-color-enabled bit (|0x1000000),
-- byte-identical to the bridge. No more separate positional rainbow — pad,
-- overlay cell, lane track, audio track, and browser all show the same color.
local function kit_color_native(pad_index, slot)
  local r, g, b = swing_state.GetPadColor(pad_index, slot)
  return reaper.ColorToNative(
    math.floor(r * 255 + 0.5),
    math.floor(g * 255 + 0.5),
    math.floor(b * 255 + 0.5)) | 0x1000000
end

-- ── Lane track-color policy ────────────────────────────────────────────────
-- P_EXT:EON_LANE_COLOR_POLICY on the Swing ENGINE track, per instance:
--   "swing"  (default) — Swing owns the MIDI-lane track colors: we write them.
--   "reaper"           — REAPER/SWS owns them: never write.
--   "none"             — fully decoupled: never write.
-- Decoded to two booleans so each call site reads as a plain gate. Inside DM
-- write_tracks does all the work; read_tracks is threaded for parity with the
-- bridge (its only distinct consumer lives there). See
-- .docs/specs/Spec_Lane_Color_Ownership.md.
local POLICY = {
  swing  = { write_tracks = true,  read_tracks = true  },
  reaper = { write_tracks = false, read_tracks = true  },
  none   = { write_tracks = false, read_tracks = false },
}

-- One P_EXT read per lane GROUP per Tick (not per lane). MUST be called AFTER
-- slot_for_group(), which primes swing_state's _slot_cache so TrackForGuid is a
-- free peek. Absent/unrecognised value → "swing", so existing projects are
-- unchanged. Legacy guid == '' → "swing" too (byte-identical to today).
local function policy_for_guid(guid)
  local name = 'swing'
  if guid and guid ~= '' and swing_state.TrackForGuid then
    local tr = swing_state.TrackForGuid(guid)
    if tr then
      local _, v = reaper.GetSetMediaTrackInfo_String(
        tr, 'P_EXT:EON_LANE_COLOR_POLICY', '', false)
      if POLICY[v] then name = v end
    end
  end
  return POLICY[name], name
end

-- Cached digest of the last-seen Swing state, PER lane group (keyed by the
-- group's swing_instance_guid; '' for guid-less legacy lanes). A missing key
-- forces a full compare on that group's first Tick.
local last_digest = {}

-- Lane-membership signature per group. New lanes appearing for a guid whose
-- digest is already cached (e.g. lanes built while the overlay runs — the
-- STEREO lane primes the guid's digest before the lane tracks exist) must
-- force a re-sync even though the Swing snapshot itself hasn't changed;
-- otherwise the fresh lanes never receive their first name/color/icon pass.
local last_lane_sig = {}

-- This module dofile's its OWN copy of swing_state_reader, which has its own
-- module-scoped `attached` flag. gmem_attach is process-global + idempotent,
-- but the per-copy flag must still be set or IsAlive() short-circuits to
-- false. Ensure our copy is initialised before first use.
local _init_done = false
local function ensure_init()
  if _init_done then return end
  _init_done = true
  swing_state.Init()
end

-- Swing JSFX only republishes pad metadata to gmem while the bridge-alive
-- slot (99) holds a RECENT os.time() value (see EON_DM_Build.lua header). The
-- overlay must therefore keep bumping it, or Swing goes quiet and we'd read
-- stale names after the first kit change. Throttled to ~once/second so we
-- don't ask Swing to republish on every audio block.
-- Phase A1: source the bridge-alive slot from the shared map via
-- swing_state_reader.GMEM (one core.GMEM load, shared). Falls back to the
-- verified literal 99 if the cross-tool map didn't resolve.
local KIT_GMEM_BRIDGE_ALIVE = (swing_state.GMEM and swing_state.GMEM.BRIDGE_ALIVE) or 99
local _last_heartbeat_t = 0
-- Kept comfortably below any reasonable Swing freshness window so the bridge
-- never has a "dead" gap during which a user change could be missed. Swing
-- only republishes on an actual change (not on every heartbeat), so a tighter
-- interval costs nothing extra on the JSFX side — it's one gmem_write/0.5s.
local HEARTBEAT_INTERVAL = 0.5   -- seconds
local function pump_bridge_heartbeat()
  local now = reaper.time_precise()
  if (now - _last_heartbeat_t) < HEARTBEAT_INTERVAL then return end
  _last_heartbeat_t = now
  reaper.gmem_write(KIT_GMEM_BRIDGE_ALIVE, os.time())
end

-- Build a digest of the live Swing pad state. Cheap enough to run per frame
-- (~500 gmem reads). Returns the digest string AND a snapshot table so the
-- write pass doesn't have to re-read gmem. `slot` (registry slot) reads the
-- per-instance bands; nil reads the legacy shared block.
local function read_swing_snapshot(slot)
  -- Per-instance gmem carries no kit NAME — digest against the kit-hash the
  -- instance self-reports every @block instead (same change signal).
  local kit
  if slot ~= nil then
    kit = '#' .. tostring(swing_state.SlotKitHash(slot))
  else
    kit = swing_state.GetKitName() or ''
  end
  local pads = {}
  local parts = { kit }
  for i = 1, 16 do
    local name  = swing_state.GetPadName(i, slot) or ''
    local pitch = swing_state.GetPadPitch(i, slot)   -- may be nil
    -- Defensive: treat note 0 (C-1) as "unpublished / no real trigger". Swing
    -- pads never trigger on C-1; a 0 here means gmem hasn't published a valid
    -- pitch (mid kit-load, empty pad). Without this, a transient 0 makes
    -- sync_lane adopt pad_pitch=0 AND FollowNoteRemap transpose the lane's
    -- existing MIDI down to C-1 — silently wrecking the pattern. Nil = skip.
    if pitch == 0 then pitch = nil end
    -- Blank state comes from the ONE authoritative signal Swing publishes
    -- every frame — AUDIOLEN (via swing_state.IsPadBlank). Do NOT infer from
    -- the name: the gmem name can go stale on emptied pads. Every consumer
    -- (Drum Matrix, bridge, browser) reads this same signal so they can't
    -- disagree. (Step 1 of the shared-state architecture.)
    local blank = swing_state.IsPadBlank(i, slot)
    -- Unified kit color (P1). Loaded pad → the live kit-hue native color;
    -- blank pad → 0 (REAPER default). Computed here so lane_diff and sync_lane
    -- share the value and a pure hue change (kit recolor with no rename) is
    -- captured in the digest below and trips a resync.
    local color = blank and 0 or kit_color_native(i, slot)
    -- P2 — icon path derived from the same name→category mapping the browser
    -- uses, so the icon, color, and name share one source of truth. Blank
    -- pads pass '' (clears P_ICON). nil means "no resolver available" and
    -- track_reflect leaves the existing P_ICON alone.
    local icon = blank and '' or icon_for_pad_name(name, color)
    pads[i] = { name = name, pitch = pitch, blank = blank, color = color, icon = icon }
    -- Digest includes blank-state, color, AND icon so any one of them
    -- changing (without name change) trips a resync.
    parts[#parts + 1] = name
    parts[#parts + 1] = tostring(pitch or '-')
    parts[#parts + 1] = blank and 'B' or '.'
    parts[#parts + 1] = tostring(color)
    parts[#parts + 1] = tostring(icon or '~')
  end
  return table.concat(parts, '\0'), pads
end

-- Does this lane's live Swing state differ from its stored P_EXT? Used both
-- Icon target for a lane under the current policy. Under "reaper" the tint
-- follows the lane's LIVE track color (REAPER/SWS owns it — matching what the
-- bridge already does for the audio multi-outs); under "swing"/"none" it
-- follows the kit hue (pad.icon, precomputed in the snapshot). This MUST be
-- the one resolver for BOTH lane_diff and sync_lane: if they compute different
-- targets, a locked lane diffs forever and the group's digest starves (same
-- failure mode the color gate exists to prevent).
local function want_icon(lane, pad, policy)
  if pad.blank then return pad.icon end
  if policy.read_tracks and not policy.write_tracks then
    local cur = math.floor(reaper.GetMediaTrackInfo_Value(lane.track, 'I_CUSTOMCOLOR') or 0)
    if (cur & 0x1000000) ~= 0 then
      return icon_for_pad_name(pad.name, cur)
    end
  end
  return pad.icon
end

-- Under "reaper", lane colors are an INPUT (they drive the icon tint), so they
-- must be part of the change signature — an SWS/user recolor has to trip a
-- resync or icons never retint. Under "swing" they're an output (folding them
-- in would just echo our own writes) and under "none" they're irrelevant:
-- both return ''. Sorted by pad index so lane order can't churn the digest.
local function lane_color_sig(lanes, policy)
  if policy.write_tracks or not policy.read_tracks then return '' end
  local sig = {}
  for _, l in ipairs(lanes) do
    sig[#sig + 1] = tostring(l.lane_info.pad_index) .. ':'
      .. tostring(math.floor(reaper.GetMediaTrackInfo_Value(l.track, 'I_CUSTOMCOLOR') or 0))
  end
  table.sort(sig)
  return '\0' .. table.concat(sig, ',')
end

-- to decide whether to write (unlocked) and to detect a "pending change held
-- back by a lock" (locked).
local function lane_diff(lane, snapshot, policy)
  local info = lane.lane_info
  local idx  = info.pad_index
  if type(idx) ~= 'number' or idx < 1 or idx > 16 then return false end
  local pad = snapshot[idx]
  if not pad then return false end

  -- Track-color state, so a stale color triggers a resync even when the name
  -- already matches (the exact case that left blank pads rainbow-colored).
  -- Read ONLY when we're allowed to write it back: under "reaper"/"none" the
  -- lane's I_CUSTOMCOLOR is not ours, so a permanent mismatch must not enter the
  -- diff — otherwise every LOCKED lane diffs forever, deferred never hits 0, and
  -- last_digest[guid] never commits (the whole group re-walks every defer frame
  -- while warn_once claims a change is "held back" that can never land). nil =
  -- "don't compare color".
  local cur_color = nil
  if policy.write_tracks then
    cur_color = reaper.GetMediaTrackInfo_Value(lane.track, 'I_CUSTOMCOLOR') or 0
  end

  if pad.blank then
    -- Blank pad wants: empty name AND (when we own the color) no custom color.
    if (info.pad_name or '') ~= '' then return true end
    if cur_color ~= nil and cur_color ~= 0 then return true end
    return false
  end
  -- Loaded pad: non-empty live name that differs, valid live pitch diff, or a
  -- track color that no longer matches the unified kit color (covers both a
  -- missing color AND a kit recolor — pad.color is the exact desired native).
  if pad.name ~= '' and pad.name ~= info.pad_name then return true end
  if pad.pitch ~= nil and pad.pitch ~= info.pad_pitch then return true end
  if cur_color ~= nil and cur_color ~= pad.color then return true end
  -- Icon drift: a lane that never received its first icon pass (fresh build
  -- whose name/color happened to already match) must still diff. Only when
  -- the resolver produced a target (nil = no resolver, leave P_ICON alone)
  -- and the track still wears OUR icon (cur == EON_ICON_AUTO; a user-set or
  -- user-cleared icon is hands-off, mirroring the track_reflect guard).
  -- want_icon (NOT pad.icon) so the target matches what sync_lane will write
  -- under every policy — see the starvation note on want_icon.
  local wicon = want_icon(lane, pad, policy)
  if wicon ~= nil then
    local _, cur_icon = reaper.GetSetMediaTrackInfo_String(lane.track, 'P_ICON', '', false)
    if cur_icon ~= wicon then
      local _, auto = reaper.GetSetMediaTrackInfo_String(lane.track, 'P_EXT:EON_ICON_AUTO', '', false)
      if cur_icon == auto then return true end
    end
  end
  return false
end

-- Persist the (mutated) lane_info table back to P_EXT. Silent — no Undo block.
local function write_pext(lane)
  if not (json and json.encode) then return end
  local ok, encoded = pcall(json.encode, lane.lane_info)
  if ok and encoded then
    reaper.GetSetMediaTrackInfo_String(lane.track, 'P_EXT:EON_DRUM_LANE', encoded, true)
  end
end

-- Apply a snapshot to one lane. Returns true if anything was written.
local function sync_lane(lane, snapshot, policy)
  local info = lane.lane_info
  local idx  = info.pad_index
  local pad  = snapshot[idx]

  if pad.blank then
    -- Empty pad → empty lane: clear the name and reset the track color to
    -- REAPER default. Track shows just its number. P_EXT cleared first so
    -- the lane_info we return reflects the empty state.
    info.pad_name = ''
    write_pext(lane)
    -- icon_path = '' clears the track icon back to REAPER default so an
    -- emptied pad doesn't keep the previous kit's drum-type icon. color = nil
    -- under "reaper"/"none" = leave the track's color alone (the 0 reset is a
    -- Swing-owned decision, not a mechanism).
    local want_color = nil
    if policy.write_tracks then want_color = 0 end
    track_reflect.Reflect(lane.track, { name = '', color = want_color, icon_path = '' })
    return true
  end

  -- Loaded pad: adopt the live name + pitch, set the unified kit track color.
  if pad.name ~= '' then info.pad_name = pad.name end
  -- P3 — pattern auto-follow: if the kit remapped this pad's trigger-note,
  -- transpose the lane's existing notes old->new BEFORE adopting the new pitch,
  -- so the painted beat keeps triggering this pad. Silent (no Undo). Only when
  -- both pitches are valid and actually differ; blank pads never reach here.
  if pad.pitch ~= nil and info.pad_pitch ~= nil and pad.pitch ~= info.pad_pitch then
    lane_integrity.FollowNoteRemap(lane, info.pad_pitch, pad.pitch)
  end
  if pad.pitch ~= nil then info.pad_pitch = pad.pitch end
  write_pext(lane)
  -- P4 — one writer. Build the identity record (TCP "NN Name" prefix; P_EXT
  -- keeps the bare name, set above) and hand off to track_reflect. pad.color
  -- is the snapshot's precomputed kit-hue native int, so diff and write can't
  -- disagree. P_ICON intentionally nil here — P2 will set it from the same
  -- shared identity once icons publish.
  -- color = nil under "reaper"/"none" (track_reflect leaves it unchanged).
  local want_color = nil
  if policy.write_tracks then want_color = pad.color end
  track_reflect.Reflect(lane.track, {
    name      = string.format('%02d %s', idx, info.pad_name or ''),
    color     = want_color,
    -- want_icon: live-track-color tint under "reaper", kit-hue tint otherwise.
    icon_path = want_icon(lane, pad, policy),   -- nil = leave alone; '' = clear
  })
  return true
end

-- Internal worker shared by Tick (digest-gated) and ForceResync.
-- Returns (touched, deferred):
--   touched  = lanes actually written this pass
--   deferred = locked lanes that HAD a pending change we suppressed. The
--              caller uses this to decide whether to advance the digest cache
--              — if a lock is holding back a change, we must keep re-checking
--              so the moment the user unlocks, the change lands.
-- Edge case #4 — surface (don't silently absorb) a kit that maps two loaded
-- pads to the SAME trigger-note. Lanes are one-track-per-pad, so the auto-
-- follow transpose can't merge their MIDI; but the user should know two lanes
-- now drive the same note. Warn-once per offending note so it isn't spammy.
local function warn_pitch_collisions(snapshot)
  local seen = {}
  for i = 1, 16 do
    local pad = snapshot[i]
    if pad and not pad.blank and pad.pitch then
      local owner = seen[pad.pitch]
      if owner then
        warn_once('swing_sync:pitchcol:' .. tostring(pad.pitch),
          'swing_sync: kit maps pads ' .. tostring(owner) .. ' and ' ..
          tostring(i) .. ' to the same note ' .. tostring(pad.pitch) ..
          ' — both lanes will trigger it')
      else
        seen[pad.pitch] = i
      end
    end
  end
end

-- Partition the project's drum lanes by the Swing instance they belong to
-- (swing_instance_guid from P_EXT; '' for legacy lanes built before the guid
-- was stamped). Returns the map plus the group count.
local function group_lanes_by_guid()
  local groups, n = {}, 0
  for _, lane in ipairs(lane_tools.GetLanes()) do
    local g = lane.lane_info.swing_instance_guid
    if type(g) ~= 'string' then g = '' end
    local grp = groups[g]
    if not grp then grp = {}; groups[g] = grp; n = n + 1 end
    grp[#grp + 1] = lane
  end
  return groups, n
end

-- Resolve one lane group → the registry slot to read from.
-- Returns slot (number) for a live per-instance read, false for "use the
-- legacy shared block", or nil for "don't sync this group this frame".
local function slot_for_group(guid, n_groups)
  local slot = (guid ~= '') and swing_state.SlotForGuid(guid) or nil
  if slot ~= nil then return slot end
  -- Degenerate single-group case: behave exactly like the old single-Swing
  -- sync — any live Swing publishes the shared block and the lanes follow it.
  -- With SEVERAL groups that would cross-feed kits, so unresolved groups
  -- freeze instead.
  if n_groups == 1 and swing_state.IsAlive() then return false end
  return nil
end

local function do_sync(snapshot, lanes, policy)
  local touched, deferred = 0, 0
  for _, lane in ipairs(lanes) do
    if lane.lane_info.stereo == true then
      -- Stereo-mode lane: the tag lives on the Swing track itself. Its track
      -- name/color are owned by the bridge (renaming it "01 <pad>" here would
      -- clobber the Swing track), and FollowNoteRemap must never transpose a
      -- multi-pitch pattern. What DOES follow the pads is the pitch WINDOW
      -- (2026-09-02): note_lo/note_hi were frozen when the bridge first saw the
      -- Swing (root..root+15), so a kit or remap that moved a pad outside it
      -- left the tag lying about the kit -- the overlay and the StepSeq sync
      -- resolve the live window at read time (lane_tools.LaneRange), but an
      -- OFFLINE Swing can only fall back to the tag. Heal it here: this branch
      -- runs only when the group's digest changed (kit load / remap / first
      -- pass), so it is naturally throttled. Write contract = track_detection's
      -- validator: integers, 0 <= lo <= hi <= 127, or the whole lane vanishes.
      local lo, hi, n = nil, nil, 0
      for i = 1, 16 do
        local p = snapshot[i] and snapshot[i].pitch
        if type(p) == 'number' and p == math.floor(p) and p >= 0 and p <= 127 then
          n = n + 1
          if not lo or p < lo then lo = p end
          if not hi or p > hi then hi = p end
        end
      end
      local info = lane.lane_info
      if n >= 2 and lo and hi and hi >= lo
         and (info.note_lo ~= lo or info.note_hi ~= hi or info.pad_pitch ~= lo) then
        info.note_lo, info.note_hi = lo, hi
        info.pad_pitch = lo                 -- BuildStereo's own convention
        info.range_source = 'live'
        write_pext(lane)
        touched = touched + 1
        -- Grow-only track height, same numbers as EON_DM_BuildStereo (20 px per
        -- row + the 20 px header band, clamped 200..640). Never shrink.
        local want_h = (hi - lo + 1) * 20 + 20
        if want_h < 200 then want_h = 200 end
        if want_h > 640 then want_h = 640 end
        if (reaper.GetMediaTrackInfo_Value(lane.track, 'I_HEIGHTOVERRIDE') or 0) < want_h then
          reaper.SetMediaTrackInfo_Value(lane.track, 'I_HEIGHTOVERRIDE', want_h)
          reaper.TrackList_AdjustWindows(false)
        end
      end
    elseif lane.lane_info.merged == true then
      -- Merged-mode lane: the tag rides one of Swing's multi-out AUDIO tracks,
      -- whose name, colour and icon belong to the Kit Bridge (sync_lane would
      -- rename it "01 <pad>" and then fight make_track_name on every pass).
      -- Same ownership reasoning as the stereo lane above, so skip entirely;
      -- a changed pad pitch is picked up by re-running EON_DM_BuildMerged.
    elseif not lane_diff(lane, snapshot, policy) then
      -- nothing to do for this lane
    elseif lane.lane_info.locked == true then
      deferred = deferred + 1
      warn_once('swing_sync:locked:' .. tostring(lane.lane_info.pad_index),
                'swing_sync: change held back by locked lane ' ..
                tostring(lane.lane_info.pad_index) .. ' (' ..
                tostring(lane.lane_info.pad_name) .. ') — unlock to apply')
    else
      if sync_lane(lane, snapshot, policy) then touched = touched + 1 end
    end
  end
  return touched, deferred
end

-- =============================================================================
-- public
-- =============================================================================

-- Per-frame entry. Cheap when nothing changed (one digest compare per
-- instance group).
function M.Tick()
  ensure_init()
  -- Keep the bridge warm so Swing keeps publishing live names/pitches. This
  -- runs even when no lanes exist yet (harmless) and is self-throttled.
  pump_bridge_heartbeat()
  -- Skip while a kit load is in flight so we never sync against a half-
  -- published block. Digests are left untouched, so the next idle frame
  -- re-reads the fully-published state. (Edge case #2.)
  if swing_state.IsLoadInFlight() then return end
  local groups, n_groups = group_lanes_by_guid()
  for guid, lanes in pairs(groups) do
    -- Lane membership changed (lanes built/removed while the overlay runs)
    -- -> drop the cached digest so the group gets a full first-pass sync.
    -- Track pointers are session-stable, so a sorted join is a cheap set key.
    local lsig = {}
    for _, l in ipairs(lanes) do lsig[#lsig + 1] = tostring(l.track) end
    table.sort(lsig)
    lsig = table.concat(lsig, '|')
    if last_lane_sig[guid] ~= lsig then
      last_lane_sig[guid] = lsig
      last_digest[guid] = nil
    end
    local slot = slot_for_group(guid, n_groups)
    if slot ~= nil then
      -- AFTER slot_for_group: it ran SlotForGuid, priming swing_state's cache,
      -- so TrackForGuid is a free peek. Policy rides the digest below — flipping
      -- EON_LANE_COLOR_POLICY changes the digest, forcing exactly one resync
      -- pass (the same mechanism a kit change uses). No cache to invalidate.
      local policy, pol_name = policy_for_guid(guid)
      if slot == false then slot = nil end   -- legacy shared-block read
      local digest, snapshot = read_swing_snapshot(slot)
      -- Policy + (reaper-mode only) live lane colors ride the digest: a flip
      -- OR an external recolor forces exactly one resync pass.
      digest = pol_name .. '\0' .. digest .. lane_color_sig(lanes, policy)
      if digest ~= last_digest[guid] then
        warn_pitch_collisions(snapshot)
        local _, deferred = do_sync(snapshot, lanes, policy)
        -- Only commit the digest when nothing is being held back by a lock.
        -- If a locked lane has a pending change, leave the digest stale so we
        -- re-walk next frame and pick the change up the instant the lane is
        -- unlocked.
        if deferred == 0 then last_digest[guid] = digest end
      end
    end
  end
end

-- Manual override: re-pull from gmem and apply to every lane regardless of
-- the digest cache. Used by the Settings "Resync all from Swing" button and
-- the EON_DM_ResyncFromSwing.lua action. Returns the number of lanes changed,
-- or -1 if no lane group's Swing could be reached.
function M.ForceResync()
  ensure_init()
  -- Don't resync mid-load (edge case #2); clear the digests so a normal
  -- Tick completes the sync once the load settles.
  if swing_state.IsLoadInFlight() then last_digest = {}; return 0 end
  local groups, n_groups = group_lanes_by_guid()
  local touched, any = 0, false
  for guid, lanes in pairs(groups) do
    local slot = slot_for_group(guid, n_groups)
    if slot ~= nil then
      any = true
      local policy, pol_name = policy_for_guid(guid)
      if slot == false then slot = nil end
      local digest, snapshot = read_swing_snapshot(slot)
      digest = pol_name .. '\0' .. digest .. lane_color_sig(lanes, policy)
      warn_pitch_collisions(snapshot)
      local t, deferred = do_sync(snapshot, lanes, policy)
      touched = touched + t
      -- Same digest discipline as Tick: don't cache while a lock holds a change.
      last_digest[guid] = (deferred == 0) and digest or nil
    end
  end
  if not any then return -1 end
  return touched
end

function M.GetLastDigest()
  -- Debug helper. Joins the per-group digests (stable order) so callers that
  -- only compare for change keep working.
  local keys = {}
  for k in pairs(last_digest) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. last_digest[k] end
  return table.concat(parts, '\1')
end

return M
