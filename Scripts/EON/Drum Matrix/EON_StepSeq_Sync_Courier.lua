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
-- dm_push). So if the bridge is alive (it writes os.time() to gmem[99]=BRIDGE_ALIVE
-- while running, 0 on exit), self-disable and let the bridge own it. The standalone
-- only matters now as a bare-DM fallback when the bridge isn't running.
if (reaper.gmem_read(99) or 0) > 0 then
  reaper.ShowConsoleMsg(
    '[StepSeq Sync Courier] Bridge is alive and now owns this courier ' ..
    '(eon_courier_tick) -- standalone copy exiting to avoid a double-push.\n')
  return
end

-- gmem map -- byte-exact mirror of EON_StepSeq.jsfx EON_SS_SYNC_* / EON_SS_XFER_*.
local SYNC_BASE, SYNC_STRIDE = 26030000, 64
local F_DMPUSH, F_LISTLEN, F_SPB, F_SYNCON = 8, 9, 10, 11
local XFER_BASE, XFER_DATA = 26171536, 26171544   -- XFER v2 (Package 2, 2026-09-03); planes 16 x 128
local XFER_OFF, XFER_LEN, XFER_SUBDIV = 26173592, 26175640, 26177688

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
  -- zero the grid
  for pad = 0, 15 do
    for s = 0, listlen - 1 do
      local cell = pad * listlen + s
      gw(XFER_DATA + cell, 0); gw(XFER_OFF + cell, 0); gw(XFER_LEN + cell, 0); gw(XFER_SUBDIV + cell, 0)   -- no stale planes from a bridge push
    end
  end
  -- fill: pad_index (1-based) -> pad (0-based); note QN offset -> step.
  for pad_index, lane in pairs(blob.lanes or {}) do
    local pad = (tonumber(pad_index) or 0) - 1
    if pad >= 0 and pad < 16 then
      for _, n in ipairs(lane.notes or {}) do
        local step = math.floor((tonumber(n.q) or 0) * spb + 0.5)
        if step >= 0 and step < listlen then
          local v = math.floor(tonumber(n.v) or 0)
          if v > 0 then
            local addr = XFER_DATA + pad * listlen + step
            if v > (gr(addr) or 0) then gw(addr, v) end   -- keep the loudest hit per cell
          end
        end
      end
    end
  end

  gw(base + F_DMPUSH, push_seq[slot])   -- signal: import staged
end

local function tick()
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
