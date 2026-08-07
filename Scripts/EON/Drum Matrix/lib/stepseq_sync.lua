-- stepseq_sync.lua -- EON. Foundation layer for StepSeq <-> Drum Matrix "two views
-- of one pattern" sync (see the plan). PHASE 0: data layer only — namespace, the
-- pattern binding store, uid mint/resolve, the dm_rev/origin echo-suppression
-- store, and the gmem-band mirror. NOTHING here drives behaviour yet; it is the
-- scaffolding the bridge + later phases build on.
--
-- Identity model (the "binding triple"):
--   * region_uid          -- a project-stable numeric id we MINT (REAPER region
--                            index numbers renumber on delete, so the index is a
--                            CACHE, not the key). Fits one gmem double (<2^53).
--   * swing_instance_guid -- which Swing instance/kit the pattern belongs to.
--   * lane-set-by-pad-note -- resolved at apply time (handled elsewhere).
-- A uid re-resolves to a live region by ANCHOR (start time + name) the way
-- pattern_song.SongList self-heals, so renames/reorders/deletes don't lose it.

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

-- Guarded json load (same graceful-degrade pattern as the other DM modules).
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.encode then json = mod end
end

-- ProjExtState namespace (per-project, survives reload). Separate from
-- EON_DRUM_MATRIX so DM's pattern/song membership is untouched.
local SECTION   = 'EON_STEPSEQ_SYNC'
local K_BINDINGS = 'bindings'   -- json: { [uid]= {swing_guid, ss_fxguid, anchor={start,name}, region_idx, sidecar_ver} }
local K_UIDSEQ   = 'uid_seq'    -- monotonic uid counter
local K_REVS     = 'revs'       -- json: { [uid]= {rev, origin} } (echo suppression)
local K_SIDECAR  = 'sidecar:'   -- prefix; per-uid extras blob (written in later phases)

-- gmem SYNC band — byte-exact mirror of EON_StepSeq.jsfx EON_SS_SYNC_*. The bridge
-- reads/writes these per paired Swing registry slot.
M.GMEM = {
  SYNC_BASE   = 26030000,
  SYNC_STRIDE = 64,
  EPOCH = 0, DIGEST = 1, DMREV = 2, ORIGIN = 3,
  UID_LO = 4, UID_HI = 5, EXPORTREQ = 6, EXPORTACK = 7, DMPUSH = 8,
}
-- origin_tag values (who last wrote a region's canonical data).
M.ORIGIN = { NONE = 0, DM = 1, SS = 2 }

-- Address of a field within a slot's sync band.
function M.slot_addr(slot, field)
  return M.GMEM.SYNC_BASE + (slot or 0) * M.GMEM.SYNC_STRIDE + (field or 0)
end

-- ── ProjExtState helpers ────────────────────────────────────────────────────
local function read_json(key, fallback)
  local _, raw = reaper.GetProjExtState(0, SECTION, key)
  if not raw or raw == '' or not json then return fallback end
  local ok, t = pcall(json.decode, raw)
  if ok and type(t) == 'table' then return t end
  return fallback
end

local function write_json(key, tbl)
  if not json then return false end
  local ok, enc = pcall(json.encode, tbl)
  if ok and enc then reaper.SetProjExtState(0, SECTION, key, enc); return true end
  return false
end

-- ── uid mint ────────────────────────────────────────────────────────────────
-- Monotonic per-project counter. Numeric (fits a single gmem double) and never
-- reused within a project, so a stale gmem uid can never alias a fresh pattern.
function M.mint_uid()
  local _, raw = reaper.GetProjExtState(0, SECTION, K_UIDSEQ)
  local n = (tonumber(raw) or 0) + 1
  reaper.SetProjExtState(0, SECTION, K_UIDSEQ, tostring(n))
  return n
end

-- ── binding store ───────────────────────────────────────────────────────────
-- A binding records which region (by uid) belongs to which Swing instance, plus
-- the anchor used to re-find the region and a cache of its last-known index.
function M.get_binding(uid)
  if not uid then return nil end
  return read_json(K_BINDINGS, {})[tostring(uid)]
end

function M.set_binding(uid, b)
  if not uid or type(b) ~= 'table' then return false end
  local all = read_json(K_BINDINGS, {})
  all[tostring(uid)] = b
  return write_json(K_BINDINGS, all)
end

function M.del_binding(uid)
  if not uid then return false end
  local all = read_json(K_BINDINGS, {})
  all[tostring(uid)] = nil
  reaper.SetProjExtState(0, SECTION, K_SIDECAR .. tostring(uid), '')  -- GC the sidecar
  local revs = read_json(K_REVS, {})
  revs[tostring(uid)] = nil
  write_json(K_REVS, revs)
  return write_json(K_BINDINGS, all)
end

function M.all_bindings()
  return read_json(K_BINDINGS, {})
end

-- ── region resolve (uid -> live region) ─────────────────────────────────────
-- Enumerate regions and pick the best match for a binding's anchor: prefer the
-- cached index if it still names the same region near the same start; else the
-- nearest region by start time that shares the name. Returns the region descriptor
-- {idx,name,start,end_} or nil, and refreshes the cached index on a confident hit.
local function enum_regions()
  local out, i = {}, 0
  while true do
    local rv, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    if rv == 0 then break end
    if isrgn then out[#out + 1] = { idx = idx, name = name or '', start = pos, end_ = rgnend } end
    i = i + 1
  end
  return out
end

function M.resolve_region(uid)
  local b = M.get_binding(uid)
  if not b or type(b.anchor) ~= 'table' then return nil end
  local want_name  = b.anchor.name or ''
  local want_start = tonumber(b.anchor.start) or 0
  local regions = enum_regions()
  local best, best_d
  for _, r in ipairs(regions) do
    if r.name == want_name then
      local d = math.abs(r.start - want_start)
      if not best_d or d < best_d then best, best_d = r, d end
    end
  end
  -- No name match -> fall back to the cached index if it still exists.
  if not best and b.region_idx then
    for _, r in ipairs(regions) do
      if r.idx == b.region_idx then best = r; break end
    end
  end
  if best and best.idx ~= b.region_idx then           -- refresh the index cache
    b.region_idx = best.idx
    M.set_binding(uid, b)
  end
  return best
end

-- ── dm_rev / origin store (echo suppression) ────────────────────────────────
-- One monotonic revision per region uid + the tag of who last wrote it. A consumer
-- re-materializes only when rev advanced AND origin != self (see the plan).
function M.get_rev(uid)
  local e = read_json(K_REVS, {})[tostring(uid)]
  if type(e) ~= 'table' then return 0, M.ORIGIN.NONE end
  return tonumber(e.rev) or 0, tonumber(e.origin) or M.ORIGIN.NONE
end

function M.bump_rev(uid, origin)
  if not uid then return 0 end
  local revs = read_json(K_REVS, {})
  local cur  = revs[tostring(uid)]
  local n    = ((type(cur) == 'table' and tonumber(cur.rev)) or 0) + 1
  revs[tostring(uid)] = { rev = n, origin = origin or M.ORIGIN.NONE }
  write_json(K_REVS, revs)
  return n
end

-- ── sidecar (StepSeq extras) — accessors only in Phase 0 ────────────────────
function M.get_sidecar(uid)
  return read_json(K_SIDECAR .. tostring(uid), nil)
end
function M.set_sidecar(uid, blob)
  if not uid then return false end
  return write_json(K_SIDECAR .. tostring(uid), blob or {})
end

M.SECTION = SECTION
return M
