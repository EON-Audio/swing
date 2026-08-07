-- swing_state_reader.lua — EON Drum Matrix read-only bridge to Swing JSFX state.
-- gmem namespace: 'Swing_Media_Transfer'
-- Slots used (legacy single-shared block):
--   3            KIT_GMEM_NAMELEN       (kit name length)
--   4..          KIT_GMEM_NAME          (kit name chars, null-terminated)
--   99           KIT_GMEM_BRIDGE_ALIVE  (read-reserved; not consumed here)
--   100+(i-1)*80+10  per-pad MIDI note  (KIT_GMEM_META; stride 80, pitch at offset 10)
--   1432/1433    GS_COL_EFFECTIVE_S / GS_COL_EFFECTIVE_L  (theme S, L floats)
--   1711         GS_SWING_ALIVE         (JSFX heartbeat counter)
--   1720..2231   KIT_GMEM_PADNAMES      (16 pads x 32 chars, null-terminated)
-- Per-instance bands (multi-Swing, P1 unified identity):
--   2556+slot*4  GS_INST_REG            (instance_id, heartbeat, pad_count, kit_hash)
--   26000000+slot*128   INST_IDENT      (per-pad ver/hue/mute/solo/note/output/icon)
--   26010000+slot*512   INST_PADNAME    (16 pads x 32 chars, null-terminated)
-- Every read function below takes an optional `slot` (registry slot from
-- SlotForLane/SlotForGuid): non-nil routes to that instance's band, nil keeps
-- the legacy shared block — so single-Swing sessions behave exactly as before.
--
-- Offsets here are kept in lock-step with EON_DM_Build.lua's gmem readers —
-- if Build changes the slot map, update both.

local M = {}

-- Phase A1: consume the shared gmem map (`rk_lua_core.lua → core.GMEM`) instead
-- of re-declaring slot constants here. core.GMEM lives at the Scripts/ root,
-- three levels above this lib dir (lib → Drum Matrix → EON → Scripts).
--
-- Fallback discipline: if the cross-tool load fails for any reason, we fall
-- back to the previously-hardcoded literals so this module CANNOT regress —
-- worst case it behaves exactly as before A1. The values below were verified
-- against the shipped Swing JSFX, so the fallbacks match what core.GMEM holds.
local _SSR_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local G
do
  local ok, mod = pcall(dofile, _SSR_DIR .. '../../../rk_lua_core.lua')
  if ok and type(mod) == 'table' and type(mod.GMEM) == 'table' then G = mod.GMEM end
end

-- Slot bases: prefer core.GMEM, fall back to verified literals.
local KIT_GMEM_NAMELEN  = (G and G.NAMELEN)       or 3
local KIT_GMEM_NAME     = (G and G.NAME_BASE)     or 4
local KIT_META_BASE     = (G and G.META_BASE)     or 100
local KIT_META_STRIDE   = (G and G.META_PP)       or 80
local KIT_GMEM_AUDIOLEN = (G and G.AUDIOLEN_BASE) or 2256
local GS_SWING_ALIVE    = (G and G.GS_SWING_ALIVE) or 1711
local GS_COL_S          = (G and G.GS_COL_EFFECTIVE_S) or 1432
local GS_COL_L          = (G and G.GS_COL_EFFECTIVE_L) or 1433
local KIT_GMEM_PADNAMES = (G and G.PADNAME_BASE)  or 1720
local KIT_GMEM_PADNAME_LEN = (G and G.PADNAME_LEN) or 32
-- Kit-load mutex: Swing holds gmem[LOCK] = requesting instance_id while a kit
-- load is in flight, 0 when idle. Readers gate on this so they never act on a
-- half-published META block (edge case #2).
local GS_LOCK           = (G and G.LOCK)          or 97
-- Per-pad FIELD offset within the 80-slot block. core.GMEM does not yet name
-- the per-pad field offsets (pitch@10, color@12, …) — that's Phase B (the
-- per-pad record). Until then this stays a documented literal verified against
-- the JSFX (`gmem[KIT_GMEM_META + i*META_PP + 10] = p_note`).
local KIT_META_PITCH    = 10
-- Per-pad effective hue (0..1). Verified against the JSFX:
--   gmem[KIT_GMEM_META + i*META_PP + 12] = col_auto_mode_id > 0
--       ? col_auto_hue[i] : p_color[i]
-- i.e. it already folds in auto-color-by-drumtype AND manual overrides, so a
-- pure read here gives the SAME color the pad face shows (edge case #6).
local KIT_META_COLOR    = 12
-- Per-pad note range (piano view, Phase 2 dependency). Offsets +14/+15/+16 are
-- currently FREE in the 80-slot block — the shipped Swing build never writes
-- them, so they read 0 and GetPadRange returns nil (callers fall back to their
-- lane_info range). When Swing publishes p_note_lo/p_note_hi these light up
-- automatically with no DM change. +16 (key-track) is reserved, not yet used.
local KIT_META_NOTE_LO  = 14
local KIT_META_NOTE_HI  = 15
local KIT_META_KEYTRACK = 16

-- ── Per-instance identity (multi-Swing) ────────────────────────────────────
-- Registry: every live Swing claims a slot and heartbeats it each @block
-- (Swing_ReaKit.jsfx swing_registry_claim). IDENT/PADNAME: each instance
-- publishes its OWN per-pad identity strided by that slot (rk_lua_core
-- INST_IDENT contract, same bands the bridge's per-instance multi-out sync
-- consumes). Resolving a lane's swing_instance_guid → registry slot lets the
-- readers below serve the RIGHT kit when several Swings are live at once.
-- Fallback literals verified against rk_lua_core.lua / Swing_ReaKit.jsfx.
local REG_BASE          = (G and G.GS_INST_REG_BASE)          or 2556
local REG_STRIDE        = (G and G.GS_INST_REG_STRIDE)        or 4
local REG_MAX           = (G and G.GS_INST_REG_MAX)           or 16
local REG_TIMEOUT       = (G and G.GS_INST_REG_TIMEOUT)       or 3.0
local REG_OFF_ID        = (G and G.GS_INST_REG_OFF_ID)        or 0
local REG_OFF_HB        = (G and G.GS_INST_REG_OFF_HEARTBEAT) or 1
local REG_OFF_PAD_COUNT = (G and G.GS_INST_REG_OFF_PAD_COUNT) or 2
local REG_OFF_KIT_HASH  = (G and G.GS_INST_REG_OFF_KIT_HASH)  or 3
local ID_BASE     = (G and G.INST_IDENT_BASE)          or 26000000
local ID_STRIDE   = (G and G.INST_IDENT_INST_STRIDE)   or 128
local ID_FIELDS   = (G and G.INST_IDENT_PAD_FIELDS)    or 8
local ID_OFF_VER   = (G and G.IDENT_OFF_VER)           or 0
local ID_OFF_HUE   = (G and G.IDENT_OFF_HUE)           or 1
local ID_OFF_NOTE  = (G and G.IDENT_OFF_NOTE)          or 4
local ID_OFF_AUDIO = (G and G.IDENT_OFF_AUDIO)         or 7
local NM_BASE     = (G and G.INST_PADNAME_BASE)        or 26010000
local NM_STRIDE   = (G and G.INST_PADNAME_INST_STRIDE) or 512
local NM_LEN      = (G and G.INST_PADNAME_PAD_LEN)     or 32

-- Legacy shared META block base. Multi-instance reads do NOT stride this
-- block — they route through the per-instance IDENT/PADNAME bands above via
-- the optional `slot` argument on each reader. The shared block stays the
-- single-Swing fallback (only the LOCK/browser-target instance publishes it).
local function block_base()
  return KIT_META_BASE
end

-- Expose the resolved shared map (or nil if the cross-tool load fell back) so
-- sibling Drum Matrix modules can consume the SAME core.GMEM without a second
-- dofile. nil => callers use their own verified fallback literals.
M.GMEM = G

local attached = false
local last_alive_counter = 0
local last_change_time = 0
local first_read_done = false

function M.Init()
  if attached then return end
  reaper.gmem_attach('Swing_Media_Transfer')
  attached = true
end

function M.IsAlive()
  if not attached then return false end
  local now = reaper.time_precise()
  local cur = reaper.gmem_read(GS_SWING_ALIVE) or 0
  if not first_read_done then
    first_read_done = true
    last_alive_counter = cur
    last_change_time = now
    return cur ~= 0
  end
  if cur ~= last_alive_counter then
    last_alive_counter = cur
    last_change_time = now
    return true
  end
  return (now - last_change_time) < 1.5
end

-- Theme S/L for the HSL pad colors. Fallback is the JSFX canonical (S=0.75,
-- L=0.55, see Swing_ReaKit.jsfx "fixed S=0.75, L=0.55") so a Swing-less read
-- matches what the pad face / bridge would produce.
-- True while Swing is mid kit-load (holds the gmem LOCK). Sync passes skip when
-- this is true so we never read color/note/name from a half-published block;
-- the next idle frame re-reads the fully-published state. (Edge case #2.)
function M.IsLoadInFlight()
  if not attached then return false end
  local v = reaper.gmem_read(GS_LOCK) or 0
  return v ~= 0
end

-- ── Instance → registry-slot resolution ────────────────────────────────────

-- Same Swing-FX matching the bridge ships (is_swing_fx), so every EON tool
-- agrees on what counts as a Swing instance.
function M.IsSwingFX(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, '')
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, 'fx_ident')
  if ok and ident and ident:find('DrumKit_ReaKit') then return true end
  if fname and fname:find('DrumKit_ReaKit') then return true end
  if fname and (fname:match('^JS: Swing') or fname:match('Swing %— 16%-Pad')) then return true end
  return false
end

-- instance_id lives on hidden slider4 ("Instance ID (internal)"). Swing's
-- slider list is dense at the top, so param index 3 == slider4 — the same
-- access every shipped per-instance bridge feature uses.
function M.GetInstanceId(tr, fx)
  return math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
end

-- instance_id → live registry slot. nil when the instance isn't registered
-- or its heartbeat is stale (FX offline / project tab not processing).
function M.ResolveSlot(inst_id)
  if not attached or not inst_id or inst_id <= 0 then return nil end
  local now = reaper.time_precise()
  for slot = 0, REG_MAX - 1 do
    local base = REG_BASE + slot * REG_STRIDE
    if math.floor(reaper.gmem_read(base + REG_OFF_ID) or 0) == inst_id then
      if (now - (reaper.gmem_read(base + REG_OFF_HB) or 0)) <= REG_TIMEOUT then
        return slot
      end
    end
  end
  return nil
end

-- Self-reported display fields from the instance registry. kit_hash is the
-- only per-instance "kit changed" signal gmem carries (no per-slot kit NAME
-- exists), so swing_sync digests against it.
function M.SlotKitHash(slot)
  if not attached or not slot then return 0 end
  return reaper.gmem_read(REG_BASE + slot * REG_STRIDE + REG_OFF_KIT_HASH) or 0
end

function M.SlotPadCount(slot)
  if not attached or not slot then return 0 end
  return math.floor(reaper.gmem_read(REG_BASE + slot * REG_STRIDE + REG_OFF_PAD_COUNT) or 0)
end

-- track-GUID → slot, cached. Lanes persist the Swing TRACK guid
-- (EON_DM_Build writes swing_instance_guid = GetTrackGUID); we re-find that
-- track, read its Swing FX's instance_id and scan the registry. The cache
-- avoids a tracks×FX walk per call: a fresh hit is trusted for 0.25 s, then
-- revalidated cheaply (pointer + param + heartbeat); a MISSING instance only
-- re-triggers the full walk once per second.
local _slot_cache = {}   -- guid -> { track=, fx=, inst_id=, slot=, ok_t= } | { bad_t= }

local function resolve_guid_uncached(guid)
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local tr = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(tr) == guid then
      for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
        if M.IsSwingFX(tr, fx) then
          local id = M.GetInstanceId(tr, fx)
          local slot = M.ResolveSlot(id)
          if slot then
            return { track = tr, fx = fx, inst_id = id, slot = slot }
          end
        end
      end
      return nil   -- track exists but carries no LIVE Swing
    end
  end
  return nil
end

function M.SlotForGuid(guid)
  if not attached or type(guid) ~= 'string' or guid == '' then return nil end
  local now = reaper.time_precise()
  local c = _slot_cache[guid]
  if c and c.track then
    -- Trust window: overlay call sites resolve the same lane several times
    -- per frame — don't re-touch the FX API for each one.
    if c.ok_t and (now - c.ok_t) < 0.25 then return c.slot end
    if reaper.ValidatePtr(c.track, 'MediaTrack*')
       and M.GetInstanceId(c.track, c.fx) == c.inst_id then
      local base = REG_BASE + c.slot * REG_STRIDE
      if math.floor(reaper.gmem_read(base + REG_OFF_ID) or 0) == c.inst_id
         and (now - (reaper.gmem_read(base + REG_OFF_HB) or 0)) <= REG_TIMEOUT then
        c.ok_t = now
        return c.slot
      end
      -- Registry churn (slot reclaimed after collision/reload): rescan it.
      local slot = M.ResolveSlot(c.inst_id)
      if slot then c.slot = slot; c.ok_t = now; return slot end
    end
    c = nil   -- cached pointer/identity no longer valid → full re-resolve below
  end
  if c and c.bad_t and (now - c.bad_t) < 1.0 then return nil end
  local hit = resolve_guid_uncached(guid)
  if hit then
    hit.ok_t = now
    _slot_cache[guid] = hit
    return hit.slot
  end
  _slot_cache[guid] = { bad_t = now }
  return nil
end

-- Peek the Swing ENGINE track for a guid. Pure cache read — no track walk, no
-- FX API, no gmem. Returns nil unless SlotForGuid(guid) already resolved this
-- guid (every color-policy caller runs slot_for_group first, which primes the
-- cache via SlotForGuid). resolve_guid_uncached already captures `.track`; this
-- just stops discarding it.
function M.TrackForGuid(guid)
  if type(guid) ~= 'string' or guid == '' then return nil end
  local c = _slot_cache[guid]
  if not (c and c.track) then return nil end
  if not reaper.ValidatePtr(c.track, 'MediaTrack*') then return nil end
  return c.track
end

-- Lane-record convenience: drum lanes carry swing_instance_guid in P_EXT.
function M.SlotForLane(lane_info)
  local g = lane_info and lane_info.swing_instance_guid
  if type(g) ~= 'string' or g == '' then return nil end
  return M.SlotForGuid(g)
end

function M.GetEffectiveSL()
  if not attached then return 0.75, 0.55 end
  local s = reaper.gmem_read(GS_COL_S) or 0
  local l = reaper.gmem_read(GS_COL_L) or 0
  if s <= 0 or s > 1 then s = 0.75 end
  if l <= 0 or l > 1 then l = 0.55 end
  return s, l
end

function M.GetPadName(pad_idx, slot)
  if not attached or pad_idx < 1 or pad_idx > 16 then return '' end
  if slot ~= nil then
    -- Per-instance band. Multi-word read, so seqlock against the per-pad VER
    -- stamp the owner bumps LAST on every name rewrite: ver / chars / ver,
    -- retry on mismatch. A persistently-torn read (rename storm) returns ''
    -- for this frame; the next read settles.
    local vb = ID_BASE + slot * ID_STRIDE + (pad_idx - 1) * ID_FIELDS + ID_OFF_VER
    local nb = NM_BASE + slot * NM_STRIDE + (pad_idx - 1) * NM_LEN
    for _ = 1, 3 do
      local ver = reaper.gmem_read(vb) or 0
      local bytes = {}
      for i = 0, NM_LEN - 1 do
        local c = reaper.gmem_read(nb + i) or 0
        if c == 0 then break end
        bytes[#bytes + 1] = string.char(math.floor(c) & 0xFF)
      end
      if (reaper.gmem_read(vb) or 0) == ver then
        return table.concat(bytes)
      end
    end
    return ''
  end
  local base = KIT_GMEM_PADNAMES + (pad_idx - 1) * KIT_GMEM_PADNAME_LEN
  local bytes = {}
  for i = 0, KIT_GMEM_PADNAME_LEN - 1 do
    local c = reaper.gmem_read(base + i) or 0
    if c == 0 then break end
    bytes[#bytes + 1] = string.char(math.floor(c) & 0xFF)
  end
  return table.concat(bytes)
end

-- Live kit name from gmem (length-prefixed at slot 3, chars from slot 4).
-- Returns '' if Swing hasn't published or the value looks invalid.
function M.GetKitName()
  if not attached then return '' end
  local len = math.floor((reaper.gmem_read(KIT_GMEM_NAMELEN) or 0) + 0.5)
  if len <= 0 or len > 64 then return '' end
  local bytes = {}
  for i = 0, len - 1 do
    local c = reaper.gmem_read(KIT_GMEM_NAME + i) or 0
    if c == 0 then break end
    bytes[#bytes + 1] = string.char(math.floor(c) & 0xFF)
  end
  return table.concat(bytes)
end

-- Live MIDI note for a 1-based pad index. Returns nil if out of range or the
-- published value isn't a valid 0..127 pitch (so callers can keep their
-- current pitch instead of corrupting it). `slot` (registry slot) routes to
-- that instance's IDENT band; nil reads the legacy shared META block.
function M.GetPadPitch(pad_idx, slot)
  if not attached or pad_idx < 1 or pad_idx > 16 then return nil end
  local raw
  if slot ~= nil then
    raw = reaper.gmem_read(ID_BASE + slot * ID_STRIDE + (pad_idx - 1) * ID_FIELDS + ID_OFF_NOTE) or 0
  else
    raw = reaper.gmem_read(block_base() + (pad_idx - 1) * KIT_META_STRIDE + KIT_META_PITCH) or 0
  end
  local pitch = math.floor(raw + 0.5)
  if pitch < 0 or pitch > 127 then return nil end
  return pitch
end

-- Live per-pad note range for a 1-based pad. Returns lo, hi, key_track when
-- Swing has published a real range (META +14/+15); returns nil when the range
-- is UNPUBLISHED (both offsets read 0 — the current Swing build) so callers
-- fall back to their own lane_info range. The per-instance IDENT band carries
-- no range fields yet, so a slot-routed call returns nil (lane_info fallback)
-- until Swing publishes one. key_track (+16) is reserved; not consumed by
-- piano view v1.
function M.GetPadRange(pad_idx, slot)
  if not attached or pad_idx < 1 or pad_idx > 16 then return nil end
  if slot ~= nil then return nil end
  local base = block_base() + (pad_idx - 1) * KIT_META_STRIDE
  local lo = math.floor((reaper.gmem_read(base + KIT_META_NOTE_LO) or 0) + 0.5)
  local hi = math.floor((reaper.gmem_read(base + KIT_META_NOTE_HI) or 0) + 0.5)
  -- Unpublished (both zero), out of MIDI range, or inverted → treat as no
  -- published range so the lane_info fallback (or drum default) takes over.
  if (lo == 0 and hi == 0) or lo < 0 or lo > 127 or hi < 0 or hi > 127 or hi < lo then
    return nil
  end
  local kt = math.floor((reaper.gmem_read(base + KIT_META_KEYTRACK) or 0) + 0.5)
  return lo, hi, kt
end

-- True when a 1-based pad has NO sample loaded.
-- Legacy path: reads the per-pad audio-length slot Swing publishes (0 = empty,
-- >0 = loaded, with a sentinel 1 for layered pads) — the authoritative blank
-- signal, more reliable than testing the pad-name string, which can lag.
-- Slot path: AUDIOLEN is not strided per instance, so blank comes from the
-- IDENT band's explicit AUDIO flag (+7: 1 = loaded, -1 = blank). A 0 means a
-- pre-flag Swing build — fall back to the hue sentinel (-2 = blank), which is
-- ambiguous with the manual-BLACK color but was the only signal back then.
function M.IsPadBlank(pad_idx, slot)
  if not attached or pad_idx < 1 or pad_idx > 16 then return false end
  if slot ~= nil then
    local base = ID_BASE + slot * ID_STRIDE + (pad_idx - 1) * ID_FIELDS
    local af = reaper.gmem_read(base + ID_OFF_AUDIO) or 0
    if af >= 1 then return false end
    if af <= -1 then return true end
    local hue = reaper.gmem_read(base + ID_OFF_HUE)
    return (hue or -2) <= -1.5
  end
  local len = reaper.gmem_read(KIT_GMEM_AUDIOLEN + (pad_idx - 1)) or 0
  return len <= 0
end

local function hsl_to_rgb(h, s, l)
  if s <= 0 then return l, l, l end
  local q = l < 0.5 and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  local function hue2rgb(t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end
  return hue2rgb(h + 1/3), hue2rgb(h), hue2rgb(h - 1/3)
end

-- Per-pad color from the LIVE kit: the same hue Swing publishes (META +12)
-- combined with the theme's effective S/L. This is the ONE color source for
-- the overlay lane cell, the lane TCP track, the audio TCP track, the pad
-- face, and the browser — load a kit and they all recolor together. (P1.)
--
-- `slot` (registry slot) reads the per-instance IDENT hue; nil reads the
-- legacy shared META block. gmem retains the last-published hue even after
-- Swing goes quiet, so a closed/idle Swing keeps the last kit's identity
-- (edge case #1) rather than resetting to grey. Falls back to the legacy
-- positional hue ONLY when gmem was never attached (no Swing in the session
-- at all), so a Swing-less overlay still shows distinct lanes.
function M.GetPadColor(pad_idx, slot)
  if pad_idx < 1 or pad_idx > 16 then return 0.5, 0.5, 0.5 end
  local s, l = M.GetEffectiveSL()
  if not attached then
    return hsl_to_rgb((pad_idx - 1) / 16, s, l)
  end
  local h
  if slot ~= nil then
    h = reaper.gmem_read(ID_BASE + slot * ID_STRIDE + (pad_idx - 1) * ID_FIELDS + ID_OFF_HUE) or 0
  else
    h = reaper.gmem_read(block_base() + (pad_idx - 1) * KIT_META_STRIDE + KIT_META_COLOR) or 0
  end
  if type(h) ~= 'number' then h = (pad_idx - 1) / 16 end
  -- B&W sentinels from the overlay color picker — handled identically to the
  -- bridge's audio-track coloring (and the JSFX pad face) so all three match:
  --   h <= -1.5 → black (0.20,0.20,0.22) ; -1.5 < h < 0 → white (0.82,0.82,0.85)
  if h <= -1.5 then return 0.20, 0.20, 0.22 end
  if h < 0     then return 0.82, 0.82, 0.85 end
  if h > 1     then h = (pad_idx - 1) / 16 end   -- unpublished slot → positional
  return hsl_to_rgb(h, s, l)
end

return M
