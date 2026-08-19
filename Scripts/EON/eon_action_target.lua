-- @noindex
-- eon_action_target.lua
-- Shared helper for the EON action wrappers (loaded via dofile, not an action).
--
-- Every keybindable EON action is a thin wrapper that (a) points the instance
-- LOCK at the Swing you're looking at ("focused Swing wins") and (b) posts a
-- command code onto one of the two gmem buses the running system already
-- consumes. Centralising both here keeps each wrapper to three lines and keeps
-- the "focused wins" logic in exactly one place.
--
-- Buses (must match the JSFX / bridge):
--   gmem[0]    CMD               -- the BRIDGE bus (build/toggle/routing/etc.)
--   gmem[1710] GS_COMPANION_CMD  -- the JSFX bus (EON_SB_* companion commands)
--   gmem[97]   LOCK              -- instance the bridge routes the command to
--
-- LOCK is per-command transient: the bridge releases it (LOCK=0) after every
-- completed command, so each action must set it fresh before posting.
-- (c) EON Studios

local M = {}

local SEG  = "Swing_Media_Transfer"
local CMD  = 26090300  -- v1 header relocated 2026-07-09 (cells 0..35 dead)
local COMP = 1710
local COMPT = 2250     -- companion TARGET (instance id; 0 = broadcast)
local LOCK = 97
-- GS_CMD_LUA_POST (rk_lua_core): "posted from Lua, no armed consumer" stamp.
-- A Lua-posted op's completion code has no JSFX waiting on it; the bridge
-- tracks this stamp and releases an orphan 98 immediately instead of letting
-- it block the bus for the watchdog's 5s fuse. Written BEFORE CMD.
local LUAPOST = 26090342

-- Mirror of Swing_Kit_Bridge.lua is_swing_fx(): fx_ident is the reliable key,
-- with JS: display-name fallbacks for older/unidentified instances.
local function fx_is_swing(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and ident and ident:find("DrumKit_ReaKit") then return true end
  if fname and fname:find("DrumKit_ReaKit") then return true end
  if fname and (fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad")) then return true end
  return false
end

-- Exported so actions that need to FIND a Swing slot do not each grow their own
-- copy of the predicate — there were already three, and they drift.
M.fx_is_swing = fx_is_swing

-- Point LOCK at the currently focused Swing FX. If nothing (or a non-Swing FX)
-- is focused, LOCK is left untouched — the bridge then falls back to whatever
-- was last selected, or the first instance found.
function M.focus_lock()
  reaper.gmem_attach(SEG)
  local retval, tnum, _, fxnum = reaper.GetFocusedFX2()
  -- bit 0 = track FX; input/monitor FX carry a 0x1000000 offset we can't read
  -- via TrackFX_GetParam, so ignore those and let the fallback handle them.
  if retval and (retval & 1) == 1 and fxnum and fxnum >= 0 and fxnum < 0x1000000 then
    local tr = (tnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, tnum - 1)
    if tr and fx_is_swing(tr, fxnum) then
      local iid = reaper.TrackFX_GetParam(tr, fxnum, 3)  -- slider4 = instance_id (0..99999999)
      if iid and iid > 0 then reaper.gmem_write(LOCK, math.floor(iid)) end
    end
  end
end

-- Post to the BRIDGE bus (gmem[0]) only if it's idle, so we never stomp a
-- command already in flight.
function M.bridge(code)
  reaper.gmem_attach(SEG)
  if math.floor(reaper.gmem_read(CMD)) == 0 then
    reaper.gmem_write(CMD, code)
  end
end

-- Post to the JSFX companion bus (gmem[1710]) only if idle. Stamps the
-- TARGET cell 0 (broadcast) so a stale address from an interrupted
-- targeted arm can never mis-route this post.
function M.companion(code)
  reaper.gmem_attach(SEG)
  if math.floor(reaper.gmem_read(COMP)) == 0 then
    reaper.gmem_write(COMPT, 0)
    reaper.gmem_write(COMP, code)
  end
end

-- Convenience: focus-lock, then post to the bridge bus in one call. This is the
-- common case for the Swing-panel wrappers.
function M.fire(code)
  M.focus_lock()
  M.bridge(code)
end

-- Post `code` routed at a SPECIFIC instance id, bypassing the focus heuristic —
-- for callers that just CREATED the instance (the Song Starter): a windowless
-- TrackFX_AddByName is never the focused FX, so focus_lock() would leave a
-- stale LOCK and the bridge would build against the FIRST Swing it finds
-- instead of the new one. Posts only when the bus is idle (M.bridge's posture)
-- but REPORTS the result, so callers can retry on a defer tick instead of
-- silently losing the command. Returns true when the command was posted.
function M.post_locked(iid, code)
  reaper.gmem_attach(SEG)
  if math.floor(reaper.gmem_read(CMD)) ~= 0 then return false end
  if iid and iid > 0 then reaper.gmem_write(LOCK, math.floor(iid)) end
  reaper.gmem_write(CMD, code)
  return true
end

-- ── Big-view actions ────────────────────────────────────────────────────────
-- The views are otherwise reachable ONLY by clicking a specific button in the
-- panel: swing_bigview_open is called from click handlers and nowhere else. The
-- EON_VIEW_REQ mailbox (Swing_ReaKit.jsfx) is what makes them bindable.
local VIEW_REQ = 26004520      -- +0 seq (LAST), +1 slot, +2 VIEW_* id

-- Registry constants, mirrored from rk_lua_core GMEM. Inlined rather than
-- dofile'ing core: these wrappers must stay three lines and dependency-free.
local REG_BASE, REG_STRIDE, REG_MAX, REG_TIMEOUT = 2556, 4, 16, 3.0

-- instance_id → live registry slot. ⚠️ NOT id-1: the registry is the authority
-- and slots are claimed in whatever order instances start, so the mapping is a
-- lookup. Heartbeat-checked so a dead instance's stale row is never matched.
local function slot_of(iid)
  local now = reaper.time_precise()
  for s = 0, REG_MAX - 1 do
    local b = REG_BASE + s * REG_STRIDE
    if math.floor(reaper.gmem_read(b) or 0) == iid then
      if (now - (reaper.gmem_read(b + 1) or 0)) <= REG_TIMEOUT then return s end
    end
  end
end

-- Open a big view on the focused Swing (VIEW_NONE = 0 closes). Silent when no
-- Swing is focused — same posture as focus_lock, which leaves LOCK alone.
function M.view(id)
  reaper.gmem_attach(SEG)
  local retval, tnum, _, fxnum = reaper.GetFocusedFX2()
  if not (retval and (retval & 1) == 1 and fxnum and fxnum >= 0
          and fxnum < 0x1000000) then return end
  local tr = (tnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, tnum - 1)
  if not (tr and fx_is_swing(tr, fxnum)) then return end
  local iid = math.floor(reaper.TrackFX_GetParam(tr, fxnum, 3) or 0)
  local slot = iid > 0 and slot_of(iid) or nil
  if not slot then return end
  reaper.gmem_write(VIEW_REQ + 1, slot)
  reaper.gmem_write(VIEW_REQ + 2, id)
  -- seq LAST: the JSFX is edge-triggered on it, so payload must be in place.
  reaper.gmem_write(VIEW_REQ, math.floor(reaper.gmem_read(VIEW_REQ) or 0) + 1)
end

return M
