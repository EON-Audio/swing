-- EON_Chain_Dock.lua — the selected track's FX chain, as a rig pane.
--
-- REAPER already has the perfect chain window; what it lacks is FOLLOW. This
-- follower keeps a docked FX chain pointed at the FIRST SELECTED track — the
-- RAW track, no parent-walking: click a DM lane and you see the LANE's chain
-- (its EQ, its sends), which is the whole point while mixing. The instrument
-- panes (Swing / Steppa) resolve to the Swing home; this one deliberately
-- does not.
--
-- Setup, once: run this action, then dock the chain window that appears
-- (right-click its title bar -> Dock FX window in Docker). REAPER remembers
-- chain-dock state forever after.
--
-- Behaviour:
--   * DORMANT WHILE HIDDEN — if the chain tab is behind another pane, nothing
--     follows and your keyboard focus is never touched. Surface the tab and
--     it catches up to the current selection.
--   * Keyboard focus is restored to wherever it was after every follow.
--   * A track whose ONLY FX are the rig-captured Swing/Steppa is NOT
--     followed (their drawing surface lives inside the dock panes — the
--     chain would show a hollow shell). The chain keeps its last view;
--     clicking Swing inside the chain list yourself still hands the window
--     over exactly as the pop-out watcher always has.
--   * Empty chains show as empty chains — that is where you are.
--   * Close the chain tab -> this follower exits. Run the action to relaunch;
--     run it while alive -> it closes (same toggle idiom as the other panes).
--
-- Requires js_ReaScriptAPI (like the rest of the dock rig). Windows-focused.

local EXT = "EON_ChainDock"

if not reaper.JS_Window_Find then
  reaper.MB("EON Chain Dock needs the js_ReaScriptAPI extension (ReaPack).",
            "EON Chain Dock", 0)
  return
end

-- Toggle: a fresh heartbeat means one of us is already running — signal it to
-- close and leave. A stale one is a crash leftover; run anyway.
do
  local hb = tonumber(reaper.GetExtState(EXT, "alive")) or 0
  if (reaper.time_precise() - hb) < 2 then
    reaper.SetExtState(EXT, "close", "1", false)
    return
  end
end
reaper.SetExtState(EXT, "close", "0", false)

local last_guid   = nil     -- track GUID the chain currently shows
local last_tr     = nil
local opened_once = false

-- The captured kinds: their canvas lives in a dock pane, so displaying them in
-- the chain would show chrome with no drawing surface. Matched on fx_ident
-- (stable), display-name substring as a pre-6.37 fallback.
local function is_captured_kind(tr, fx)
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  local hay = (ok and ident or ""):lower()
  if hay == "" then
    local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
    hay = (nm or ""):lower()
  end
  return hay:find("swing_reakit", 1, true) or hay:find("swing_lite", 1, true)
      or hay:find("eon_stepseq", 1, true) or hay:find("swing", 1, true)
      and hay:find("reakit", 1, true) or false
end

-- First FX that is safe to display; nil = chain has FX but every one is
-- captured (skip the follow rather than undock a pane or show a shell).
local function display_fx(tr)
  local n = reaper.TrackFX_GetCount(tr)
  if n == 0 then return 0, true end          -- empty chain: open as empty
  for i = 0, n - 1 do
    if not is_captured_kind(tr, i) then return i, false end
  end
  return nil, false
end

-- The chain window for a track, by title prefix ("FX: Track 7 ..." /
-- "FX: Master Track"). Prefix match survives track renames mid-session.
local function chain_hwnd(tr)
  if not tr then return nil end
  local num = reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")
  if num and num < 0 then
    return reaper.JS_Window_Find("FX: Master Track", false)
  end
  local n = tostring(math.floor(num or 0))
  -- Two-step lookup because a bare prefix "FX: Track 7" also matches track 71:
  -- named tracks title as [FX: Track 7 "Name"] (the quote pins the number),
  -- unnamed ones as exactly [FX: Track 7].
  return reaper.JS_Window_Find('FX: Track ' .. n .. ' "', false)
      or reaper.JS_Window_Find('FX: Track ' .. n, true)
end

local function track_alive(tr)
  return tr and reaper.ValidatePtr2(0, tr, "MediaTrack*")
end

local function follow(tr)
  local disp, empty = display_fx(tr)
  if not disp then return false end          -- captured-only chain: hold
  local focus = reaper.JS_Window_GetFocus()
  -- Chains are PER-TRACK windows: docked, each open chain is its own tab, so a
  -- follower that only opens would carpet the docker in tabs. Hide the one we
  -- opened for the previous track first -- REAPER keeps the dock position for
  -- the next open, which is what makes this read as ONE pane changing content.
  if track_alive(last_tr) and last_tr ~= tr
     and reaper.TrackFX_GetChainVisible(last_tr) >= -1 then
    reaper.TrackFX_Show(last_tr, 0, 0)
  end
  if empty then
    -- TrackFX_Show needs a real index; the stock action opens an empty
    -- chain for the last-touched track — which a click-selection just made
    -- this one.
    reaper.Main_OnCommand(40291, 0)          -- View: show FX chain for last touched track
  else
    reaper.TrackFX_Show(tr, disp, 1)
  end
  if focus and reaper.JS_Window_IsWindow(focus) then
    reaper.JS_Window_SetFocus(focus)
  end
  last_guid, last_tr = reaper.GetTrackGUID(tr), tr
  opened_once = true
  return true
end

local function loop()
  reaper.SetExtState(EXT, "alive", tostring(reaper.time_precise()), false)

  if reaper.GetExtState(EXT, "close") == "1" then
    reaper.SetExtState(EXT, "close", "0", false)
    reaper.SetExtState(EXT, "alive", "0", false)
    if track_alive(last_tr) then
      local h = chain_hwnd(last_tr)
      if h then reaper.JS_Window_Show(h, "HIDE") end
    end
    return
  end

  local sel = reaper.GetSelectedTrack2(0, 0, true)   -- first selected; master counts

  if not opened_once then
    -- Bootstrap: bring a chain window into existence so there is something to
    -- dock. After the user docks it once, REAPER remembers.
    if sel then follow(sel) end
    reaper.defer(loop)
    return
  end

  -- The pane's tab was closed entirely -> the user is done with it; exit like
  -- the other panes do. (Hidden-behind-another-tab is NOT closed — see below.)
  local shown = track_alive(last_tr) and chain_hwnd(last_tr) or nil
  if last_tr and not track_alive(last_tr) then
    last_tr, last_guid = nil, nil
  elseif last_tr and not shown then
    reaper.SetExtState(EXT, "alive", "0", false)
    return
  end

  -- DORMANT WHILE HIDDEN: only follow while the chain tab is the one on
  -- screen. This is what keeps the follower from ever stealing focus while
  -- you work with it tabbed away; surface it and it catches up.
  local visible = shown and reaper.JS_Window_IsVisible(shown)
  if visible and sel then
    local g = reaper.GetTrackGUID(sel)
    if g ~= last_guid then follow(sel) end
  end

  reaper.defer(loop)
end

reaper.defer(loop)
