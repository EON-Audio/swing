-- EON_StepSeq_Sync_Courier.lua
-- EON. Phase 1 MVP courier for the StepSeq <-> Drum Matrix "Import on engage"
-- direction (single-kit). Runs as a background defer. When a paired StepSeq turns
-- Sync Mode ON (a rising edge on the per-slot SYNCON flag it publishes), this
-- stages the CURRENT DM pattern region's notes into the shared transfer buffer --
-- pad-keyed, in the StepSeq's own published grid resolution -- and bumps dm_push
-- so the StepSeq adopts it into its active pattern (eon_ss_import_grid).
--
-- This is the deliberately-minimal stand-in courier (Phase 1). Later phases move
-- it into the always-on bridge and add the Export direction + live following +
-- multi-kit. It only WRITES the transfer buffer + the per-slot dm_push; it never
-- touches the StepSeq pattern arrays (the JSFX import owns that, safely).

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local SEP = SCRIPT_DIR:match('[\\/]$') or '/'
local LIB = SCRIPT_DIR .. 'lib' .. SEP

local function load_lib(name)
  local ok, m = pcall(dofile, LIB .. name)
  if ok and type(m) == 'table' then return m end
  return nil
end
local lane_tools      = load_lib('lane_tools.lua')
local pattern_regions = load_lib('pattern_regions.lua')

reaper.gmem_attach('Swing_Media_Transfer')

-- This courier now lives INSIDE the always-on bridge (Swing_Kit_Bridge.lua,
-- eon_courier_tick) as of the Phase 2 fold-in. Running this standalone copy at the
-- same time would double-push (two writers staging the same buffer + bumping
-- dm_push). So if the bridge is alive, self-disable and let the bridge own it. The
-- standalone only matters now as a bare-DM fallback when the bridge isn't running.
-- The bridge is alive when BOTH hold: it publishes what it can do in GS_BRIDGE_LEVEL
-- (2636: only a bridge writes it, its atexit zeroes it) AND its BRIDGE_ALIVE stamp
-- (99, os.time() every tick) is fresh -- the 5 s window the bridge's own guard uses.
-- The old test, gmem[99] > 0, was also true after the Drum Matrix overlay's own
-- heartbeat or a Build / SeedLane stamped that cell, so this fallback exited exactly
-- when it was needed (audit DM119, 2026-10-26). Re-checked every tick: a bridge
-- that starts later takes over, and this copy ends.
local GS_BRIDGE_LEVEL = 2636
local BRIDGE_ALIVE    = 99
local function bridge_alive()
  if (reaper.gmem_read(GS_BRIDGE_LEVEL) or 0) <= 0 then return false end
  return (os.time() - (reaper.gmem_read(BRIDGE_ALIVE) or 0)) < 5
end
local function yield_to_bridge()
  reaper.ShowConsoleMsg(
    '[StepSeq Sync Courier] Bridge is alive and now owns this courier ' ..
    '(eon_courier_tick) -- standalone copy exiting to avoid a double-push.\n')
end
if bridge_alive() then
  yield_to_bridge()
  return
end

-- gmem map -- byte-exact mirror of EON_StepSeq.jsfx EON_SS_SYNC_* / EON_SS_XFER_*.
local SYNC_BASE, SYNC_STRIDE = 26030000, 64
local F_DMPUSH, F_LISTLEN, F_SPB, F_SYNCON = 8, 9, 10, 11
local XFER_BASE, XFER_DATA = 26171536, 26171544   -- XFER v2 (Package 2, 2026-09-03); planes 16 x 128
local XFER_OFF, XFER_LEN, XFER_SUBDIV = 26173592, 26175640, 26177688
local XFER_CC, XFER_CCMETA = 26196120, 26196632   -- 2B: CC rows, 4 x 128 steps; per row: cc+1 (0 = no row), channel
-- A note at q lands in step floor(q*spb + RTOL): a hair-early note belongs to the
-- next step, a note past half a step does NOT (the bridge's rule, stage_blob_to_slot).
local RTOL = 0.02   -- steps; ~2.5 ms at 120 bpm 16ths -- above PPQ jitter, below musical offsets

local prev_syncon, push_seq = {}, {}

local function gr(a) return reaper.gmem_read(a) end
local function gw(a, v) reaper.gmem_write(a, v) end

-- Fallback window when no pattern region exists yet: the bounding time-span of
-- all the DM lane items (i.e. "whatever you've painted"). Lets the MVP import
-- work before the user has formally made a pattern region. Returns {start,end_}.
local function lane_items_span()
  if not (lane_tools and lane_tools.GetLanes) then return nil end
  local t0, t1 = math.huge, -math.huge
  for _, lane in ipairs(lane_tools.GetLanes() or {}) do
    local tr = lane.track
    local n = tr and reaper.CountTrackMediaItems(tr) or 0
    for i = 0, n - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local s = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
      local e = s + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
      if s < t0 then t0 = s end
      if e > t1 then t1 = e end
    end
  end
  if t1 > t0 then return { start = t0, end_ = t1 } end
  return nil
end

-- Current DM pattern region: the one containing the play/edit cursor, else the
-- first pattern region (by start time); falls back to the painted lane span when
-- no region exists. Returns {start, end_} or nil.
local function current_region()
  local list = (pattern_regions and pattern_regions.List and pattern_regions.List()) or {}
  if #list > 0 then
    local pos = ((reaper.GetPlayState() & 1) == 1) and reaper.GetPlayPosition()
                or reaper.GetCursorPosition()
    for _, r in ipairs(list) do
      if r.start and r.end_ and pos >= r.start - 1e-6 and pos < r.end_ - 1e-6 then return r end
    end
    return list[1]
  end
  return lane_items_span()   -- no region yet -> use the painted content
end

-- Stage the current region's notes into the transfer buffer for `slot`, then bump
-- that slot's dm_push so the StepSeq imports it.
local function push_region_to_slot(slot)
  if not lane_tools or not lane_tools.CollectRegion then return end
  local base = SYNC_BASE + slot * SYNC_STRIDE
  local listlen = math.floor((gr(base + F_LISTLEN) or 0) + 0.5)
  local spb     = gr(base + F_SPB) or 4
  if listlen < 1 then return end
  if spb < 1 then spb = 4 end
  local reg = current_region()
  if not (reg and reg.start and reg.end_) then return end

  local blob = lane_tools.CollectRegion(reg.start, reg.end_) or { lanes = {} }

  -- header
  gw(XFER_BASE + 0, slot)
  push_seq[slot] = (push_seq[slot] or 0) + 1
  gw(XFER_BASE + 1, push_seq[slot])
  gw(XFER_BASE + 2, 16)        -- numpads
  gw(XFER_BASE + 3, listlen)   -- numsteps (the StepSeq's grid)
  gw(XFER_BASE + 4, spb)
  gw(XFER_BASE + 5, 0)         -- target pattern + 1 (0 = the editor's pattern). Since step 1 the
                               -- StepSeq routes on this field; a stale value left by a bridge push
                               -- would otherwise land this import in another pattern.
  gw(XFER_BASE + 6, 2)         -- layout version: OFF/LEN planes present (as the bridge stages)
  -- zero the grid
  for pad = 0, 15 do
    for s = 0, listlen - 1 do
      local cell = pad * listlen + s
      gw(XFER_DATA + cell, 0); gw(XFER_OFF + cell, 0); gw(XFER_LEN + cell, 0); gw(XFER_SUBDIV + cell, 0)   -- no stale planes from a bridge push
    end
  end
  -- ... and the CC rows: the StepSeq applies any row it finds, so a row left by
  -- its own last export rewrote a CC lane with old values on engage (audit DM120,
  -- 2026-10-26). Same clear + fill as the bridge's stage_blob_to_slot.
  for k = 0, 3 do
    gw(XFER_CCMETA + k * 2, 0); gw(XFER_CCMETA + k * 2 + 1, 0)
    for s = 0, listlen - 1 do gw(XFER_CC + k * 128 + s, 0) end
  end
  -- fill: pad_index (1-based) -> pad (0-based); note QN offset -> step. The
  -- bridge's rule (Package 2): a note at q lands in step floor(q*spb + RTOL), with
  -- OFF = its fraction inside the step and LEN = its length in steps -- the StepSeq
  -- turns OFF into a hand nudge and LEN into ties. Rounding to the NEAREST step
  -- moved a late note onto the next step and the empty OFF/LEN planes dropped every
  -- tie (audit DM121, 2026-10-26). Several notes in one step: the loudest wins (the
  -- bridge's ratchet fit is not ported here).
  for pad_index, lane in pairs(blob.lanes or {}) do
    local pad = (tonumber(pad_index) or 0) - 1
    if pad >= 0 and pad < 16 then
      for _, n in ipairs(lane.notes or {}) do
        local sf   = (tonumber(n.q) or 0) * spb
        local step = math.floor(sf + RTOL)
        if step >= 0 and step < listlen then
          local v = math.floor(tonumber(n.v) or 0)
          if v > 0 then
            local cell = pad * listlen + step
            if v > (gr(XFER_DATA + cell) or 0) then   -- keep the loudest hit per cell
              local f = sf - step
              if f < 0 then f = 0 end
              gw(XFER_DATA + cell, v)
              gw(XFER_OFF + cell, f)
              gw(XFER_LEN + cell, (tonumber(n.d) or 0) * spb)
            end
          end
        end
      end
    end
  end
  -- CC events -> rows (up to 4, one per distinct cc+channel, in first-seen order);
  -- meta = (cc+1, channel), per step 0 = none, 128 + value (the last in a step wins).
  local rows, nrows = {}, 0
  for _, ev in ipairs(blob.cc or {}) do
    local key = tostring(ev.cc) .. ':' .. tostring(ev.chan)
    local row = rows[key]
    if row == nil and nrows < 4 then
      row = nrows; nrows = nrows + 1; rows[key] = row
      gw(XFER_CCMETA + row * 2, (ev.cc or 0) + 1); gw(XFER_CCMETA + row * 2 + 1, ev.chan or 0)
    end
    if row ~= nil then
      local s = math.floor((tonumber(ev.q) or 0) * spb + RTOL)
      if s >= 0 and s < listlen then gw(XFER_CC + row * 128 + s, 128 + math.max(0, math.min(127, math.floor(ev.v or 0)))) end
    end
  end

  gw(base + F_DMPUSH, push_seq[slot])   -- signal: import staged
end

local function tick()
  if bridge_alive() then   -- a bridge started after us: it owns the courier now
    yield_to_bridge()
    return
  end
  pcall(function()
    for slot = 0, 15 do
      local on = (gr(SYNC_BASE + slot * SYNC_STRIDE + F_SYNCON) or 0) > 0.5
      if on and not prev_syncon[slot] then
        push_region_to_slot(slot)   -- rising edge = "Sync Mode just turned on" -> import
      end
      prev_syncon[slot] = on
    end
  end)
  reaper.defer(tick)
end

tick()
