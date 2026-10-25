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

-- Mirror of rk_lua_core's core.is_swing_fx (the owner; the bridge asks it too),
-- written out because these wrappers stay dependency-free (see the registry
-- constants below): the plugin's FILE, compared whole -- never the shown name,
-- which is the user's rename, or a path when REAPER's name cache is blank.
local function fx_file(tr, fx)
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  return ok and ((ident or ""):match("[^/\\]+$") or ""):lower() or ""
end
local function fx_is_swing(tr, fx)
  local f = fx_file(tr, fx)
  return f == "swing_reakit.jsfx" or f == "swing_lite.jsfx" or f == "drumkit_reakit.jsfx"
end

-- The plugins whose @gfx consumes the companion bus. Swing Lite never reads it,
-- so a command addressed to a Lite would sit there until the bridge's 15 s
-- watchdog cleared it.
local function fx_takes_companion(tr, fx)
  local f = fx_file(tr, fx)
  return f == "swing_reakit.jsfx" or f == "drumkit_reakit.jsfx"
end

-- Exported so actions that need to FIND a Swing slot do not each grow their own
-- copy of the predicate — there were already three, and they drift.
M.fx_is_swing = fx_is_swing

-- The focused Swing FX as (track, fx), or nil. bit 0 = track FX; input/monitor
-- FX carry a 0x1000000 offset we can't read via TrackFX_GetParam, so those are
-- left to each caller's fallback. An FX inside a container (REAPER 7) has an
-- address of 0x2000000 and up, read through the same TrackFX_* calls: only
-- companion_target asks for those (contained = true), since it counts contained
-- Swings too (audit H04 round 2); focus_lock and view keep to top-level FX, as
-- before. One copy for all three: the same lookup written three times would drift.
local function focused_swing(contained)
  local retval, tnum, _, fxnum = reaper.GetFocusedFX2()
  if not (retval and (retval & 1) == 1 and fxnum and fxnum >= 0) then return nil end
  if fxnum >= 0x1000000 and not (contained and fxnum >= 0x2000000) then return nil end
  local tr = (tnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, tnum - 1)
  if not (tr and fx_is_swing(tr, fxnum)) then return nil end
  return tr, fxnum
end

-- slider4 = instance_id (0..99999999); nil while the instance has none yet.
local function iid_of(tr, fx)
  local iid = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
  return iid > 0 and iid or nil
end

-- Every companion consumer at FX address `fx` on `tr`, and inside it when it is
-- a container (REAPER 7: container_count, and container_item.N for each child's
-- address; an older REAPER answers neither): acc.n counts them, acc.iid keeps
-- the last one's id. A contained Swing left out made a contained one plus a
-- top-level one read as "the only Swing" (audit H04 round 2).
local function count_consumers(tr, fx, acc)
  if fx_takes_companion(tr, fx) then acc.n = acc.n + 1; acc.iid = iid_of(tr, fx) end
  local ok, cnt = reaper.TrackFX_GetNamedConfigParm(tr, fx, "container_count")
  for i = 0, ((ok and tonumber(cnt)) or 0) - 1 do
    local ok2, child = reaper.TrackFX_GetNamedConfigParm(tr, fx, "container_item." .. i)
    local c = ok2 and tonumber(child)
    if c then count_consumers(tr, c, acc) end
  end
end

-- Point LOCK at the currently focused Swing FX. If nothing (or a non-Swing FX)
-- is focused, LOCK is left untouched — the bridge then falls back to whatever
-- was last selected, or the first instance found.
function M.focus_lock()
  reaper.gmem_attach(SEG)
  local tr, fx = focused_swing()
  local iid = tr and iid_of(tr, fx)
  if iid then reaper.gmem_write(LOCK, iid) end
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
-- ⚠️ A broadcast goes to whichever instance's @gfx ticks first, not to the
-- Swing the user means: anything that acts on ONE kit uses companion_to.
function M.companion(code)
  reaper.gmem_attach(SEG)
  if math.floor(reaper.gmem_read(COMP)) == 0 then
    reaper.gmem_write(COMPT, 0)
    reaper.gmem_write(COMP, code)
  end
end

-- The Swing a companion command is FOR (user decision 2026-10-23, audit H04):
-- the focused Swing; with none focused, the project's only Swing. Returns its
-- instance id, or nil plus why not: "lite" (the focused one is a Swing Lite,
-- which never reads the bus), "none" (no Swing in the project, or no id yet),
-- "many" (several, none focused -- the caller asks the user to open one).
-- Swings inside FX containers count, focused or not (round 2). A focused window
-- that is no longer in front but still open (GetFocusedFX2 bit 2) still counts as
-- focused, deliberately: choosing New Kit from the EON menu always takes focus
-- off the Swing window, so refusing it would show the message every time.
function M.companion_target()
  local tr, fx = focused_swing(true)
  if tr then
    if not fx_takes_companion(tr, fx) then return nil, "lite" end
    local iid = iid_of(tr, fx)
    if iid then return iid end
    return nil, "none"
  end
  local acc = { n = 0 }
  for i = -1, reaper.CountTracks(0) - 1 do
    local t = (i < 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i)
    for f = 0, reaper.TrackFX_GetCount(t) - 1 do count_consumers(t, f, acc) end
  end
  if acc.n > 1 then return nil, "many" end
  if acc.iid then return acc.iid end
  return nil, "none"
end

-- Post `code` on the companion bus for ONE instance. TARGET is written FIRST:
-- the JSFX polls the cmd cell, so the address is in place when it sees it.
-- Only when the bus is idle; returns true when posted.
function M.companion_to(iid, code)
  reaper.gmem_attach(SEG)
  if not (iid and iid > 0) then return false end
  if math.floor(reaper.gmem_read(COMP)) ~= 0 then return false end
  reaper.gmem_write(COMPT, math.floor(iid))
  reaper.gmem_write(COMP, code)
  return true
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
  local tr, fx = focused_swing()
  if not tr then return end
  local iid = iid_of(tr, fx)
  local slot = iid and slot_of(iid) or nil
  if not slot then return end
  reaper.gmem_write(VIEW_REQ + 1, slot)
  reaper.gmem_write(VIEW_REQ + 2, id)
  -- seq LAST: the JSFX is edge-triggered on it, so payload must be in place.
  reaper.gmem_write(VIEW_REQ, math.floor(reaper.gmem_read(VIEW_REQ) or 0) + 1)
end

return M
