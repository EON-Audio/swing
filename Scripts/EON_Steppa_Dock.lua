-- EON_Steppa_Dock.lua — EON Steppa in a REAPER docker, following the selected track.
--
-- Docks Steppa's GUI in a docker tab. Click a track: the dock swaps to that
-- track's Steppa. Click a track without one: the dock keeps the last Steppa it
-- found. No floating windows to manage.
--
-- AUTO-ADD: a track that carries Swing but no Steppa gets one inserted ABOVE
-- Swing (sequencer MIDI feeds the sampler) the first time the dock lands on
-- it — so opening the rig, or selecting a fresh Swing track, completes the
-- drum station without a trip to the FX browser. One attempt per track per
-- run: delete the Steppa and it stays deleted until the rig is relaunched.
-- Kill switch: SetExtState("EON_SteppaDock", "autoload", "0", true).
--
-- Companion pane to EON Swing Dock — the sequencer half of the no-Hub rig.
-- On full-bundle systems EON Hub owns window docking (role homes / Swing Rig /
-- follow mode, Spec_EON_Hub_Swing_Integration.md §5b); two captors reparenting
-- the same float fight each other on the UI thread, so this script REFUSES to
-- run when the Hub extension is present. That check is the first thing below.
--
-- Mechanism: float the FX (TrackFX_Show 3), take the float's JSFX canvas child
-- (window class "jsfx_gfx" — exactly the drawing surface, so none of REAPER's
-- preset-bar chrome comes along), reparent it into this script's dockable gfx
-- window, and hide the emptied float. On release the canvas is handed BACK to
-- REAPER's float first — this window closing must never destroy REAPER's child.
--
-- Requires js_ReaScriptAPI (ReaPack). Windows-only: cross-window reparenting
-- is not dependable on macOS/Linux.
--
-- Idea credit: yimbot's "Docked Plugin Display" (forum.cockos.com t=310791)
-- proved the workflow. This is an independent implementation.

local DEV_ALLOW_WITH_HUB = false  -- bench-testing override; never ship true

local FX_MATCH   = "steppa"        -- lowercase substring of the FX name ("JS: EON Steppa")
local WIN_TITLE  = "Steppa Dock"   -- dock tab label; also how this script finds its own window
local WIN_W, WIN_H = 860, 594     -- Steppa's @gfx aspect; only matters undocked
local FLOAT_WAIT_TICKS  = 60      -- give TrackFX_Show this many defer ticks to produce a float
local CANVAS_WAIT_TICKS = 30      -- then this many for the jsfx_gfx child to exist

local EXT = "EON_SteppaDock"

-- ── gates ────────────────────────────────────────────────────────────────────

if not DEV_ALLOW_WITH_HUB and reaper.NamedCommandLookup("_EON_HUB_NUDGE") ~= 0 then
  reaper.MB(
    "EON Hub manages Steppa docking on this system.\n\n" ..
    "Put Steppa in a Hub pane instead (right-click a pane > EON Hub).\n" ..
    "This script is for setups without the Hub extension.",
    "EON Steppa Dock", 0)
  return
end

if not reaper.GetOS():match("^Win") then
  reaper.MB("EON Steppa Dock is Windows-only for now.", "EON Steppa Dock", 0)
  return
end

if not reaper.APIExists("JS_Window_SetParent") then
  reaper.MB(
    "This script needs the js_ReaScriptAPI extension.\n" ..
    "Extensions > ReaPack > Browse packages > js_ReaScriptAPI.",
    "EON Steppa Dock", 0)
  return
end

-- ── state ────────────────────────────────────────────────────────────────────

local dock_hwnd                 -- this script's own gfx window
local tgt_track, tgt_fx         -- instance the dock currently follows
local tgt_guid                  -- its FX GUID (dedupe key; track pointers recycle)
local wrapper, canvas           -- REAPER's float and the jsfx_gfx child inside it
local wait_float, wait_canvas = 0, 0
local shown_w, shown_h = -1, -1
local last_sel                  -- selection last tick (pointer compare)
local scan_cool = 0             -- throttle for the project-wide fallback scan
-- Canvas home geometry inside the wrapper, saved at capture — every release
-- must restore it byte-exact: REAPER never reclaims a child moved outside
-- its tree (see EON Swing Dock.lua for the glued-canvas failure this fixes).
local canvas_dx, canvas_dy, canvas_w0, canvas_h0

-- ── helpers ──────────────────────────────────────────────────────────────────

local function track_alive(tr)
  return tr and reaper.ValidatePtr2(0, tr, "MediaTrack*")
end

-- FX identity via the JSFX file ident, not the display name: rename-proof
-- and collision-proof (mirrors is_swing_fx in EON Swing Dock.lua). Falls
-- back to the display-name substring on REAPER builds without fx_ident.
local function fx_ident_is(tr, i, needle, name_fallback)
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, i, "fx_ident")
  if ok and ident and ident ~= "" then
    return ident:lower():gsub("\\", "/"):find(needle, 1, true) ~= nil
  end
  local ok2, name = reaper.TrackFX_GetFXName(tr, i, "")
  return (ok2 and name and name:lower():find(name_fallback, 1, true)) and true or false
end

-- First Steppa on the track, or nil.
local function find_steppa(tr)
  if not tr then return nil end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if fx_ident_is(tr, i, "eon_stepseq.jsfx", FX_MATCH) then return i end
  end
  return nil
end

-- First Steppa anywhere in the project, master track first (a Steppa on the
-- master is valid). Used so the dock never sits empty: no selection, or a
-- selection without Steppa, still shows the project's instance until a
-- selection takes over.
local function find_first_steppa()
  local m = reaper.GetMasterTrack(0)
  local fx = find_steppa(m)
  if fx then return m, fx end
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    fx = find_steppa(tr)
    if fx then return tr, fx end
  end
end

-- ── Steppa auto-add (a Swing track without a sequencer gets one) ─────────────

local sep = package.config:sub(1, 1)
local auto_tried = {}           -- track GUID → true once we attempted an add

-- Mini version of rk_lua_core's jsfx_addname (same candidate order, same
-- "JS:" + Effects-relative format) — EON Swing Dock View carries the same
-- mini resolver for Swing; the core resolver stays the canonical one. The
-- flat Effects-root copy is StepSeq's canonical runtime location (existing
-- projects reference it), so the "" candidate is the one that matches there.
local function steppa_addname()
  local eff = reaper.GetResourcePath() .. sep .. "Effects" .. sep
  for _, c in ipairs({ "EON/Swing/", "", "EON_ReaKit_Bundle/installer/src/Swing/" }) do
    local rel = c .. "EON_StepSeq.jsfx"
    local f = io.open(eff .. rel:gsub("/", sep), "r")
    if f then f:close() return "JS:" .. rel end
  end
end

-- First Swing on the track, or nil — the guard that keeps the auto-add from
-- spraying sequencers onto arbitrary selections: only a track already
-- carrying Swing qualifies. (FX index 0 is a valid, truthy return in Lua.)
local function find_swing_on(tr)
  if not tr then return nil end
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if fx_ident_is(tr, i, "swing_reakit.jsfx", "swing")
       or fx_ident_is(tr, i, "swing_lite.jsfx", "swing") then return i end
  end
  return nil
end

-- Add Steppa to a Swing-bearing track that has none, ABOVE Swing so the
-- sequencer's MIDI feeds the sampler — the same find-or-insert + move the
-- Song Starter's step_seq option uses. Returns the new FX index, or nil.
local function autoload_steppa(tr)
  if reaper.GetExtState(EXT, "autoload") == "0" then return nil end
  local swing_fx = find_swing_on(tr)
  if not swing_fx then return nil end
  local g = reaper.GetTrackGUID(tr)
  if auto_tried[g] then return nil end
  auto_tried[g] = true
  local addname = steppa_addname()
  if not addname then return nil end   -- StepSeq JSFX missing on this install
  reaper.Undo_BeginBlock()
  local si = reaper.TrackFX_AddByName(tr, addname, false, -1)
  if si and si >= 0 and si > swing_fx then
    reaper.TrackFX_CopyToTrack(tr, si, tr, swing_fx, true)
    si = swing_fx
  end
  reaper.Undo_EndBlock("Add Steppa to Swing track (Steppa Dock)", -1)
  return (si and si >= 0) and si or nil
end

-- The float's JSFX drawing surface: the descendant of class "jsfx_gfx".
local function find_canvas(float_hwnd)
  local ok, list = reaper.JS_Window_ListAllChild(float_hwnd)
  if not ok or not list or list == "" then return nil end
  for addr in list:gmatch("[^,]+") do
    local a = tonumber(addr)
    local h = a and reaper.JS_Window_HandleFromAddress(a)
    if h and reaper.JS_Window_GetClassName(h) == "jsfx_gfx" then return h end
  end
  return nil
end

-- Put the canvas back inside the wrapper at its captured home geometry.
-- Returns true only when the canvas genuinely landed back in REAPER's tree.
local function restore_canvas_to_wrapper()
  if not (canvas and wrapper and reaper.JS_Window_IsWindow(canvas)
          and reaper.JS_Window_IsWindow(wrapper)) then return false end
  reaper.JS_Window_SetParent(canvas, wrapper)
  if canvas_dx then
    reaper.JS_Window_Move(canvas, canvas_dx, canvas_dy)
    reaper.JS_Window_Resize(canvas, canvas_w0, canvas_h0)
  end
  return true
end

-- Hand everything back to REAPER and forget the capture. Give the canvas back
-- BEFORE hiding: while it is parented here, closing this window would take
-- REAPER's child down with it.
-- ── Dock-rig signalling ─────────────────────────────────────────────────────
-- Two halves, because neither alone is enough.
--
-- The PER-INSTANCE half is a parameter on the exact FX whose canvas we captured
-- ("EON Rig Docked"). Only this script knows which instance that is — the JSFX
-- itself cannot tell "I am in the dock" from "some instance is", and window
-- shape only correlates with the answer (it correlated wrongly for Steppa,
-- whose own default window is already wider than the old aspect threshold).
--
-- The LIVENESS half is gmem cell 2626, stamped every tick. A parameter lives in
-- the FX chunk, so a REAPER crash mid-capture would leave a floated window
-- pinned to the dock face forever. Both plugins ignore the parameter unless this
-- heartbeat is fresh, which makes that stale case impossible: no script running,
-- no dock face — the shape trigger simply takes back over.
--
-- Protocol: .refs/swing_gmem_bridge_protocol.md, cell 2626 (claimed 2026-08-26).
local GS_RIG_ALIVE   = 2626
-- ⚠️ 2626 means "SOME pane is up" -- Swing's pane stamps it too, so a plugin
-- gating its dock flag on 2626 believes a stale flag whenever the OTHER pane is
-- running. That cost Swing its wordmark click (2026-08-30). This cell is OURS
-- alone and EON_StepSeq gates on it; 2626 keeps its documented meaning.
local GS_RIG_ALIVE_STEPPA = 2634
-- Pop-out mailbox: the plugin's wordmark bumps this cell (read-modify-write)
-- to ask US to un-dock it. The consumer just re-shows the float -- the
-- existing handoff watcher then restores the canvas and closes this pane,
-- so none of that delicate code is duplicated. Baselined on first sighting
-- so a bump posted while no pane was running can't fire on a fresh launch.
local POP_REQ        = 2628
local pop_base       = nil
-- One-shot diagnostic trace: SetExtState(EXT, "debug", "1") in a ReaScript
-- console (or EON menu), reproduce, read the console. "0"/unset = silent.
-- inst_tag tells two copies of this script apart -- the two-captor fight is
-- exactly the failure this exists to catch.
local inst_tag = tostring(math.floor((reaper.time_precise()%1000)*1000))
local function dbg(msg)
  if reaper.GetExtState(EXT, "debug") == "1" then
    reaper.ShowConsoleMsg(string.format("[%s#%s %.2f] %s\n", EXT, inst_tag, reaper.time_precise(), msg))
  end
end
local RIG_PARAM_NAME = "EON Rig Docked"
reaper.gmem_attach('Swing_Media_Transfer')

-- Resolve the parameter BY NAME, cached per FX GUID. The index would be brittle:
-- a JSFX param index is the ordinal position among DECLARED sliders, so adding a
-- slider anywhere earlier silently renumbers every one after it.
local rig_param_cache = {}
local function rig_param(tr, fx, guid)
  local hit = rig_param_cache[guid]
  if hit ~= nil then return hit end
  local found = -1
  local n = reaper.TrackFX_GetNumParams(tr, fx)
  for i = 0, n - 1 do
    local _, nm = reaper.TrackFX_GetParamName(tr, fx, i, "")
    -- PREFIX match, not equality: a JSFX reports its whole slider description
    -- as the parameter name, so ours comes back as "EON Rig Docked (set by
    -- the dock rig script, ...)". Exact match silently found nothing and the
    -- flag never landed (bitten 2026-08-26: every docked pane showed full UI).
    if nm and nm:find(RIG_PARAM_NAME, 1, true) == 1 then found = i break end
  end
  rig_param_cache[guid] = found
  return found
end

-- Tell one instance whether we are holding it. Written only on CHANGE: a param
-- write dirties the project, and the dock re-acquires on every selection change.
local function rig_flag(tr, fx, guid, on)
  if not (tr and fx and guid) then return end
  if not reaper.ValidatePtr2(0, tr, "MediaTrack*") then return end
  local p = rig_param(tr, fx, guid)
  if p < 0 then return end          -- older build without the slider: no-op
  local want = on and 1 or 0
  local cur = reaper.TrackFX_GetParam(tr, fx, p)
  if cur and math.abs(cur - want) < 0.5 then return end
  reaper.TrackFX_SetParam(tr, fx, p, want)
end

local function release()
  restore_canvas_to_wrapper()
  if wrapper and reaper.JS_Window_IsWindow(wrapper) then
    reaper.JS_Window_Show(wrapper, "HIDE")
  end
  dbg("release fx=" .. tostring(tgt_fx))
  rig_flag(tgt_track, tgt_fx, tgt_guid, false)   -- before the nils below
  if track_alive(tgt_track) and tgt_fx then
    reaper.TrackFX_Show(tgt_track, tgt_fx, 2)
  end
  tgt_track, tgt_fx, tgt_guid, wrapper, canvas = nil, nil, nil, nil, nil
  wait_float, wait_canvas, shown_w, shown_h = 0, 0, -1, -1
  canvas_dx, canvas_dy, canvas_w0, canvas_h0 = nil, nil, nil, nil
end

-- Fit the captured canvas to this window's client area.
local function fit_canvas()
  if not (dock_hwnd and canvas) then return end
  local ok, w, h = reaper.JS_Window_GetClientSize(dock_hwnd)
  if not ok or not w or w < 2 or h < 2 then return end
  if w == shown_w and h == shown_h then return end
  reaper.JS_Window_Move(canvas, 0, 0)
  reaper.JS_Window_Resize(canvas, w, h)
  reaper.JS_Window_InvalidateRect(canvas, 0, 0, w, h, true)
  shown_w, shown_h = w, h
end

-- Start following (tr, fx): release whatever is held, float the new target.
local function acquire(tr, fx)
  release()
  tgt_track, tgt_fx = tr, fx
  tgt_guid = reaper.TrackFX_GetFXGUID(tr, fx)
  rig_flag(tr, fx, tgt_guid, true)
  dbg("acquire fx=" .. tostring(fx))
  -- Chain view already on this FX: close it — the dock is taking the UI
  -- over, and leaving it open would trip the chain-handoff watcher on the
  -- very next tick (dock opens, instantly hands back, closes itself).
  if reaper.TrackFX_GetChainVisible(tr) == fx then
    reaper.TrackFX_Show(tr, fx, 0)
  end
  reaper.TrackFX_Show(tr, fx, 3)
  wait_float = FLOAT_WAIT_TICKS
end

-- ── per-tick stages ──────────────────────────────────────────────────────────

-- Waiting for REAPER to create the float, then for its jsfx_gfx child, then
-- capture. Split across ticks because both can lag the TrackFX_Show call.
local function tick_capture()
  if not wrapper then
    wrapper = reaper.TrackFX_GetFloatingWindow(tgt_track, tgt_fx)
    if not wrapper then
      wait_float = wait_float - 1
      if wait_float <= 0 then release() end
      return
    end
    wait_canvas = CANVAS_WAIT_TICKS
  end
  if not canvas then
    canvas = find_canvas(wrapper)
    if not canvas then
      wait_canvas = wait_canvas - 1
      if wait_canvas <= 0 then release() end  -- no canvas child = nothing safe to show
      return
    end
    -- Save the canvas's home geometry (wrapper-client coords + size) BEFORE
    -- taking it — the restore on every release path must be byte-exact.
    local okc, cl, ct, cr, cb = reaper.JS_Window_GetRect(canvas)
    if okc then
      canvas_w0, canvas_h0 = cr - cl, cb - ct
      canvas_dx, canvas_dy = reaper.JS_Window_ScreenToClient(wrapper, cl, ct)
    end
    reaper.JS_Window_SetParent(canvas, dock_hwnd)
    reaper.JS_Window_Show(wrapper, "HIDE")
    shown_w, shown_h = -1, -1
  end
  fit_canvas()
end

local function tick_follow()
  local sel = reaper.GetSelectedTrack2(0, 0, true)  -- master counts
  if sel ~= last_sel then
    last_sel = sel
    local tr, fx = sel, find_steppa(sel)
    if not fx and sel then
      -- Satellite selection resolves to the kit's home track first: multi-out
      -- audio children and Drum Matrix MIDI lanes live inside the Swing
      -- track's folder (mirrors resolve_swing in EON Swing Dock.lua).
      local home = sel
      if not find_swing_on(home) then
        local p = reaper.GetParentTrack(sel)
        while p and not find_swing_on(p) do p = reaper.GetParentTrack(p) end
        if p then home = p end
      end
      fx = find_steppa(home)
      -- Swing track with no sequencer: complete the rig (auto-add above Swing).
      if not fx then fx = autoload_steppa(home) end
      if fx then tr = home end
    end
    if fx then
      -- Same instance re-selected (pad-click track-select, etc.): no-op.
      if not (tr == tgt_track and reaper.TrackFX_GetFXGUID(tr, fx) == tgt_guid) then
        acquire(tr, fx)
      end
    end
    -- No Steppa on or above the new track: keep showing the last one.
  end

  -- Holding nothing at all (startup with no useful selection, or the last
  -- target died): adopt the project's first Steppa rather than sit empty.
  -- Throttled to ~1 s so a Steppa-less project doesn't pay a scan per tick.
  if not tgt_track then
    if scan_cool > 0 then
      scan_cool = scan_cool - 1
    else
      scan_cool = 30
      local tr, fx = find_first_steppa()
      -- No Steppa anywhere: put one on the project's first Swing track, so
      -- opening the rig on a Swing-only project completes it without a click.
      if not tr then
        local m = reaper.GetMasterTrack(0)
        if find_swing_on(m) then
          tr = m
        else
          for i = 0, reaper.CountTracks(0) - 1 do
            local t2 = reaper.GetTrack(0, i)
            if find_swing_on(t2) then tr = t2; break end
          end
        end
        if tr then fx = autoload_steppa(tr) end
      end
      if tr and fx then acquire(tr, fx) end
    end
  end

  if tgt_track then
    if not track_alive(tgt_track)
       or (canvas and not reaper.JS_Window_IsWindow(canvas)) then
      -- Track gone or REAPER rebuilt the FX view: drop and re-resolve.
      release()
      last_sel = nil
      return
    end
    tick_capture()
  end
end

-- ── main loop / init ─────────────────────────────────────────────────────────

-- Save the dock position exactly once per shutdown: after gfx.quit the
-- gfx.dock query returns garbage, so a second save would clobber the real one.
--
-- This pane used to publish its docker on every change as well, because the
-- layout picker resolved "who is sharing a docker" from this key, and a value
-- written only at shutdown meant a pane the user had dragged reported
-- yesterday's home for its whole run. The picker reads the window tree now
-- (`live_refresh` in EON Dock Layout.lua), so that publishing was duplicating
-- what Windows already knows and is gone. What this key still owes anyone is a
-- CLOSED pane's home -- our own restore below, and the picker's fallback for a
-- pane it cannot see -- and a shutdown write covers both.
-- Twin of the block in EON Swing Dock.lua -- keep them in step.

local dock_saved = false
local function save_dock()
  if dock_saved then return end
  dock_saved = true
  reaper.SetExtState(EXT, "dockstate", tostring(gfx.dock(-1)), true)
  -- Kill our liveness stamp NOW, not by decay: every exit path funnels through
  -- here, and a freshly-quit pane whose stamp is still <2s old made the
  -- bridge's redock relay think a pane was running -- so it selected a track
  -- and launched NOTHING. The user's next clicks landed dead, the selection
  -- churned the other pane, and the late launch arrived as a burst of window
  -- flashing ("a whole lot of blinking", 2026-08-26).
  reaper.SetExtState(EXT, "alive", "0", false)
end

local function loop()
  -- Heartbeat first, unconditionally: every early return below is still a
  -- tick in which this script is alive and holding what it holds.
  reaper.gmem_write(GS_RIG_ALIVE, reaper.time_precise())
  -- Ours alone, stamped in the same breath: EON_StepSeq gates its dock flag on
  -- this, never on the shared 2626 above. See the note at the declaration.
  reaper.gmem_write(GS_RIG_ALIVE_STEPPA, reaper.time_precise())
  -- Per-kind liveness for the bridge's redock relay (launch vs reuse):
  -- gmem 2626 says "some pane is up", this says WHICH kind.
  reaper.SetExtState(EXT, "alive", tostring(reaper.time_precise()), false)
  -- GUID drift guard -- BEFORE anything uses tgt_fx this tick. tgt_fx is an
  -- INDEX, and indexes shift when any FX is inserted or removed above us; the
  -- Steppa pane's auto-add inserts ABOVE Swing, so the Swing pane's stored
  -- index ended up pointing AT the Steppa (trace 2026-08-26: pop showed the
  -- wrong FX's float, BOTH watchers fired, both panes handed off and died --
  -- the "first time blinks" report). The GUID is stable; re-find by it.
  if tgt_track and tgt_fx and tgt_guid and track_alive(tgt_track) then
    if reaper.TrackFX_GetFXGUID(tgt_track, tgt_fx) ~= tgt_guid then
      local found = nil
      for i = 0, reaper.TrackFX_GetCount(tgt_track) - 1 do
        if reaper.TrackFX_GetFXGUID(tgt_track, i) == tgt_guid then found = i break end
      end
      if found then
        dbg("index drift " .. tostring(tgt_fx) .. " -> " .. tostring(found))
        tgt_fx = found
      else
        dbg("target vanished (guid gone)")
        release()
        last_sel = nil
      end
    end
  end
  local pv = math.floor(reaper.gmem_read(POP_REQ) or 0)
  if pop_base == nil then
    pop_base = pv
  elseif pv ~= pop_base then
    pop_base = pv
    dbg("pop request")
    if canvas and track_alive(tgt_track) and tgt_fx then
      -- Show the float: the handoff watcher below sees it visible on this
      -- same tick and runs the full battle-tested hand-back + close.
      reaper.TrackFX_Show(tgt_track, tgt_fx, 3)
    end
  end
  -- Live re-dock signal (EON Dock Layout's "Spread panes" sets EXT/dock_req to
  -- a REAPER docker index): move this window to that docker without closing it.
  -- Twin of the block in EON Swing Dock.lua -- keep them in step.
  --
  -- ⚠️ The canvas must be back inside REAPER's own float BEFORE the move.
  -- gfx.dock can hand us a different HWND, and REAPER NEVER reclaims a
  -- jsfx_gfx child left behind in a window it no longer owns -- that is the
  -- orphan that painted itself over the arrange on 2026-08-25. release() is
  -- exactly that hand-back and every other exit path already trusts it, so
  -- re-dock is release -> move -> re-adopt rather than anything bespoke.
  local dock_req = reaper.GetExtState(EXT, "dock_req")
  if dock_req ~= "" then
    reaper.DeleteExtState(EXT, "dock_req", false)
    local idx = tonumber(dock_req)
    if idx and idx >= 0 and idx <= 15 then
      dbg("re-dock -> docker " .. idx)
      release()
      gfx.dock(1 + idx * 256)
      gfx.update()
      -- gfx.dock may have rebuilt the window; re-find ours by title, and
      -- persist the target we ASKED for rather than querying it straight
      -- back (the query can still report the pre-move state).
      dock_hwnd = reaper.JS_Window_Find(WIN_TITLE, true) or dock_hwnd
      reaper.SetExtState(EXT, "dockstate", tostring(1 + idx * 256), true)
      last_sel, scan_cool = nil, 0
    end
  end
  -- external close signal (the Dock View toggle sets EXT/close=1)
  if reaper.GetExtState(EXT, "close") == "1" then
    reaper.SetExtState(EXT, "close", "0", false)
    save_dock()
    release()
    gfx.quit()
    return
  end
  -- HANDOFF: the user is looking at this FX somewhere else — hand the canvas
  -- back and close this dock window. Watches all three routes: the hidden
  -- float re-shown, the float REBUILT as a new window (refresh the handle
  -- from TrackFX_GetFloatingWindow each tick), and the FX CHAIN opened on
  -- this FX (the TCP FX button's default — the float never re-shows there).
  -- Chain path closes the phantom float (2) then shows the chain (1) so
  -- REAPER re-hosts the UI where the user is looking; float path re-seats
  -- with hide+show (2,3). Dead wrapper ⇒ park the canvas under REAPER's
  -- main window — closing this dock must never destroy REAPER's child.
  -- Lives HERE (not tick_follow) so save_dock is in scope (Lua position-
  -- scoped locals). Mirrors EON Swing Dock.lua exactly.
  if canvas and track_alive(tgt_track) and tgt_fx then
    local fw = reaper.TrackFX_GetFloatingWindow(tgt_track, tgt_fx)
    if fw then wrapper = fw end   -- REAPER may have rebuilt the float
    local float_back = wrapper and reaper.JS_Window_IsWindow(wrapper)
                   and reaper.JS_Window_IsVisible(wrapper)
    local chain_back = reaper.TrackFX_GetChainVisible(tgt_track) == tgt_fx
    if float_back or chain_back then
      dbg("handoff float=" .. tostring(float_back) .. " chain=" .. tostring(chain_back))
      -- Canvas back inside REAPER's window at its home offset BEFORE any
      -- show-state change — REAPER does not reclaim a child moved outside
      -- its tree. REAPER can DESTROY the hidden float when the chain takes
      -- over — no restore target, handoff deadlock ("blinking") — so force
      -- a fresh float into existence first; the chain path closes it again
      -- one line later anyway.
      if not (wrapper and reaper.JS_Window_IsWindow(wrapper)) then
        reaper.TrackFX_Show(tgt_track, tgt_fx, 3)
        wrapper = reaper.TrackFX_GetFloatingWindow(tgt_track, tgt_fx)
      end
      if restore_canvas_to_wrapper() then
        if chain_back and not float_back then
          reaper.TrackFX_Show(tgt_track, tgt_fx, 2)  -- REAPER re-hosts in the visible chain
        end
        -- Clear the per-instance dock flag BEFORE forgetting the target -- this
        -- handoff branch predates the rig flag and is the ONE exit that doesn't
        -- go through release(). Without this the popped-out plugin keeps
        -- slider "EON Rig Docked" = 1 while the OTHER pane keeps the shared
        -- heartbeat fresh, so the floating window snaps straight back to its
        -- dock face ("toggles to full then docks", 2026-08-26).
        rig_flag(tgt_track, tgt_fx, tgt_guid, false)
        tgt_track, tgt_fx, tgt_guid, wrapper, canvas = nil, nil, nil, nil, nil
        canvas_dx, canvas_dy, canvas_w0, canvas_h0 = nil, nil, nil, nil
        save_dock()
        gfx.quit()
        return
      end
    end
  end
  tick_follow()
  gfx.update()
  if gfx.getchar() >= 0 then
    reaper.defer(loop)
  else
    save_dock()
    release()
  end
end

local function main()
  -- gfx windows don't remember docking on their own; default to docked (1).
  local dock = tonumber(reaper.GetExtState(EXT, "dockstate")) or 1
  gfx.init(WIN_TITLE, WIN_W, WIN_H, dock)
  gfx.update()
  dock_hwnd = reaper.JS_Window_Find(WIN_TITLE, true)
  if not dock_hwnd then
    reaper.MB("Couldn't find this script's own window — run the action again.",
      "EON Steppa Dock", 0)
    return
  end

  pcall(function() reaper.set_action_options(1) end)  -- relaunch replaces the running instance
  reaper.SetExtState(EXT, "close", "0", false)  -- a stale signal must not kill a fresh launch

  reaper.atexit(function()
    pcall(save_dock)
    release()
  end)

  loop()
end

main()
