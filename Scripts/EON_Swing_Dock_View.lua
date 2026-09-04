-- EON Swing Dock View.lua — one action, whole bottom-strip view. A real toggle.
--
-- The view = up to four windows in the docker:
--   Swing Dock      (EON Swing Dock.lua, this folder — pads follow selection)
--   Steppa Dock     (EON Steppa Dock.lua, this folder — sequencer follows too)
--   Sample Browser  (Swing_Browser.lua, bundle scripts)
--   Pad FX          (Swing_PadFX.lua, bundle scripts)
--
-- WHICH of them make up the view is the active LAYOUT — picked from
-- EON Dock Layout.lua (menu action, this folder), stored as a pane list in
-- ExtState (EON_DockView/panes), default = all four. The layout menu invokes
-- this script in "apply" mode (EON_DockView/apply=1): open the layout's
-- missing panes and close the ones it doesn't carry — never a full toggle.
--
-- Behaviour (normal press):
--   * Something missing  → open it (windows land in their remembered dock
--     spots; already-open windows are left exactly as they are). An APPLY
--     from the layout picker additionally pre-seeds the remembered spot of
--     each still-closed pane that has none, from the landing plan the
--     picker's cards drew — so the first landing matches the card.
--   * Everything open    → close the whole view.
--   * Toolbar button lights while the view is up (state set on each press;
--     closing windows by hand un-lights on the next press).
--   * Project has no Swing at all → offers to add a "Swing" track first, so
--     one press takes an empty project to a working drum station.
--
-- With the EON Hub extension loaded, the two dock scripts refuse to run (two
-- window-captors fight), so this action silently skips them and manages just
-- Browser + Pad FX whatever the layout says — on Hub setups the rig button
-- is "Build Swing Rig".
--
-- Installed with Swing: the bridge registers it in the Action List (EON_Register_Actions).

local sep = package.config:sub(1, 1)

local function script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)") or ""
  return path:match("^(.*)[/\\]") or ""
end

local here = script_dir()
-- The bundle's scripts (Swing_Browser, Swing_PadFX, EON_Song_Starter, EON/…)
-- live in THIS folder: the dock rig ships inside .Scripts since 2026-09-04.
-- ⛔ Not a resource-path constant -- the old one named the author's repo
-- checkout and resolved nowhere on a customer install.
local bundle_scripts = here

local hub_present = reaper.NamedCommandLookup("_EON_HUB_NUDGE") ~= 0

-- ── window state ─────────────────────────────────────────────────────────────

local function dock_window_open(title)
  return reaper.JS_Window_Find and reaper.JS_Window_Find(title, true) ~= nil
end

-- Browser: ExtState flag cross-checked against gmem GS_BROWSER_OPEN (a crashed
-- session can leave the flag stale — same recovery its own toggle uses).
local function browser_open()
  if reaper.GetExtState("Swing", "browser_running") ~= "1" then return false end
  reaper.gmem_attach("Swing_Media_Transfer")
  if reaper.gmem_read(1382) ~= 0 then return true end
  reaper.SetExtState("Swing", "browser_running", "0", false)
  return false
end

-- Pad FX: ExtState flag plus a per-frame heartbeat; stale heartbeat = dead.
local function padfx_open()
  if reaper.GetExtState("Swing", "padfx_running") ~= "1" then return false end
  local hb = tonumber(reaper.GetExtState("Swing", "padfx_heartbeat")) or 0
  if (os.time() - hb) < 3 then return true end
  reaper.SetExtState("Swing", "padfx_running", "0", false)
  return false
end

-- ── helpers ──────────────────────────────────────────────────────────────────

-- Register a script as a temporary action, fire it, unregister (keeps the
-- action list free of duplicate entries — same pattern as the EON toggles).
local function run_script(path, what)
  local f = io.open(path, "r")
  if not f then
    reaper.MB(what .. " not found:\n" .. path, "EON Swing Dock View", 0)
    return false
  end
  f:close()
  local cmd = reaper.AddRemoveReaScript(true, 0, path, true)
  if cmd and cmd > 0 then
    reaper.Main_OnCommand(cmd, 0)
    -- Deliberately NOT unregistered afterwards. AddRemoveReaScript(false, path)
    -- removes the action for that PATH no matter who registered it -- so the old
    -- register-run-unregister dance here silently stripped the user's own
    -- permanent registration of the same script (menu items and shortcuts died
    -- with it; bitten 2026-08-26 by the wordmark layout pick unregistering the
    -- user's Dock View action). Registering is idempotent -- the same path
    -- always yields the same _RS command id, no duplicates -- so the worst cost
    -- of leaving it is one stable Action List entry, which is also exactly what
    -- keeps menu buttons on that id alive.
    return true
  end
  reaper.MB("REAPER could not register " .. what .. ".", "EON Swing Dock View", 0)
  return false
end

local function fx_name_contains(tr, needle)
  for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local ok, name = reaper.TrackFX_GetFXName(tr, i, "")
    if ok and name and name:lower():find(needle, 1, true) then return true end
  end
  return false
end

local function project_has_swing()
  if fx_name_contains(reaper.GetMasterTrack(0), "swing") then return true end
  for i = 0, reaper.CountTracks(0) - 1 do
    if fx_name_contains(reaper.GetTrack(0, i), "swing") then return true end
  end
  return false
end

-- Mini version of rk_lua_core's jsfx_addname (same candidate order, same
-- "JS:" + Effects-relative format). The core resolver stays the canonical one.
local function swing_addname()
  local eff = reaper.GetResourcePath() .. sep .. "Effects" .. sep
  for _, c in ipairs({ "EON/Swing/", "", "EON_ReaKit_Bundle/installer/src/Swing/" }) do
    local rel = c .. "Swing_ReaKit.jsfx"
    local f = io.open(eff .. rel:gsub("/", sep), "r")
    if f then f:close() return "JS:" .. rel end
  end
end

local function create_swing_track()
  local addname = swing_addname()
  if not addname then
    reaper.MB("Swing_ReaKit.jsfx was not found under the Effects folder.",
      "EON Swing Dock View", 0)
    return
  end
  reaper.Undo_BeginBlock()
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local tr = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "Swing", true)
  local fx = reaper.TrackFX_AddByName(tr, addname, false, -1)
  if fx >= 0 then reaper.SetOnlyTrackSelected(tr) end
  reaper.Undo_EndBlock("Add Swing track (EON Swing Dock View)", -1)
  if fx < 0 then
    reaper.MB("Couldn't add Swing (" .. addname .. ").", "EON Swing Dock View", 0)
  end
end

-- Captured at LOAD, not per call: the no-Swing prompt is async, so set_lit can
-- now run from a defer callback long after the action context that launched us
-- has moved on. Reading it there would light the wrong button, or none.
local _, _, ACT_SEC, ACT_CMD = reaper.get_action_context()
local function set_lit(on)
  if ACT_CMD and ACT_CMD ~= 0 then
    reaper.SetToggleCommandState(ACT_SEC, ACT_CMD, on and 1 or 0)
    reaper.RefreshToolbar2(ACT_SEC, ACT_CMD)
  end
end

-- ── the toggle ───────────────────────────────────────────────────────────────

-- Active layout: which panes make up the view (EON Dock Layout.lua writes it).
local panes = reaper.GetExtState("EON_DockView", "panes")
if panes == "" then panes = "swing,steppa,browser,padfx" end
local want = {}
for w in panes:gmatch("[^,]+") do want[w] = true end

-- Hub setups: the dock panes can't be managed here (two captors fight), so
-- the view there is always Browser + Pad FX, whatever the layout says.
local want_dock    = (not hub_present) and (want.swing == true)
local want_steppa  = (not hub_present) and (want.steppa == true)
local want_browser = hub_present or (want.browser == true)
local want_padfx   = hub_present or (want.padfx == true)

-- Apply signal from the layout menu: make reality match the layout instead
-- of toggling.
local apply = reaper.GetExtState("EON_DockView", "apply") == "1"
if apply then reaper.SetExtState("EON_DockView", "apply", "0", false) end

local d  = dock_window_open("Swing Dock")
local st = dock_window_open("Steppa Dock")
local b  = browser_open()
local p  = padfx_open()

local all_open = (not want_dock or d) and (not want_steppa or st)
             and (not want_browser or b) and (not want_padfx or p)

-- No Swing to show. THREE ways forward, not two: one bare track is the right
-- answer inside a project you are already working in, and a whole song
-- skeleton -- tempo, regions, Drum Matrix lanes -- is the right answer for a
-- new one. ⛔ Never conflate them: the Song Starter SETS THE TEMPO and DROPS
-- REGIONS, so wiring it to a plain "yes" would let a dock-view toggle rewrite
-- somebody's in-progress session.
--
-- The EON dialog rather than MB(): a Yes/No box cannot label three outcomes,
-- and "Yes" told you nothing about which one you were about to get. Same module
-- the Song Starter and the bridge use, so the prompt looks like the rest of EON
-- instead of like Windows. ⚠️ It is ASYNC by nature -- ReaImGui runs on the
-- defer loop -- so the answer arrives in a callback and this one-shot script
-- has already returned. Everything that must wait for the answer therefore
-- lives in open_panes, which the callback calls itself.
--
-- The module's own rule is that a caller keeps a non-ReaImGui path and gates on
-- available(): ReaImGui is a ReaPack extension a customer may simply not have,
-- and the Lite rig has no bundle folder to load the module from at all. That
-- path is the native menu, which is synchronous -- hence two returns below.
local dlg
do
  local ok, mod = pcall(dofile, bundle_scripts .. sep .. "EON" .. sep .. "eon_imgui_dialog.lua")
  if ok and type(mod) == "table" then dlg = mod end
end

-- Fills in below: everything after the Swing question, so the async callback
-- can run it once the answer is in. Lua locals are position-scoped.
local open_panes

-- Returns true to carry on opening panes SYNCHRONOUSLY, false to stop here --
-- which means either the user backed out, or the answer is coming later.
local function ensure_swing()
  if project_has_swing() then return true end

  -- Labels carry their own consequence: the difference that matters is that
  -- one of them rewrites your tempo and timeline.
  local items = { { "Add a Swing track \226\128\148 one track, nothing else touched", "add" } }
  local starter = bundle_scripts .. sep .. "EON_Song_Starter.lua"
  local sf = io.open(starter, "r")
  if sf then
    sf:close()
    items[#items + 1] =
      { "New song\226\128\166 \226\128\148 tempo, regions, lanes (sets project tempo)", "song" }
  end

  -- What each choice does. Shared by both prompt styles so they cannot drift.
  local function act(action)
    if action == "add" then
      create_swing_track()
      return true
    end
    if action == "song" then
      -- Hand off ENTIRELY -- we cannot launch the starter and then build the
      -- view. ⚠️ Its S.prompt is ASYNC too, and this script is long gone before
      -- the user clicks Create, so there is no song here to build a view
      -- around. The starter opens the view itself once the build lands; this
      -- flag is how it knows to. It consumes the flag at ITS load rather than
      -- in the callback, so cancelling that dialog can never leave it armed for
      -- a later plain "New Song" run.
      reaper.SetExtState("EON_DockView", "after_song", "1", false)
      run_script(starter, "EON_Song_Starter.lua")
    end
    return false
  end

  local labels = {}
  for i, it in ipairs(items) do labels[i] = it[1] end

  if dlg and dlg.available() then
    dlg.open({
      title    = "EON Swing Dock View",
      width    = 430,
      ok_label = "Build",
      fields   = {
        -- Height reserved the way M.confirm does it (28 + 17 per extra line),
        -- so the message is pre-broken rather than left to wrap into space
        -- that was never allocated for it.
        { key = "_msg", kind = "block", height = 45, draw = function(ctx)
            reaper.ImGui_TextWrapped(ctx,
              "There's no Swing in this project yet, so the dock view has\n" ..
              "nothing to show. What should it start with?")
          end },
        { key = "what", label = "Start with", kind = "choice", value = 1,
          choices = labels,
          sub = "adding a track leaves your tempo and timeline alone" },
      },
      on_ok = function(v)
        local it = items[tonumber(v.what) or 1]
        if it and act(it[2]) then
          -- The answer came back after we returned, so finish the job here.
          open_panes()
          set_lit(true)
        end
      end,
    })
    return false   -- answer pending; the callback owns what happens next
  end

  -- Fallback: native menu at the mouse, and synchronous. Items are indexed BY
  -- POSITION -- gfx.showmenu numbers exactly what it lists, so the conditional
  -- Song Starter entry must never become a hand-counted offset.
  local mlabels = {}
  for i, it in ipairs(items) do mlabels[i] = it[1] end
  mlabels[#mlabels + 1] = "Cancel"
  local x, y = reaper.GetMousePosition()
  gfx.init("EON Swing Dock View", 0, 0, 0, x, y)
  local choice = gfx.showmenu(table.concat(mlabels, "|"))
  gfx.quit()
  local it = (choice >= 1) and items[choice] or nil
  return it ~= nil and act(it[2]) or false
end

open_panes = function()
  if want_dock    and not d  then run_script(here .. sep .. "EON_Swing_Dock.lua",  "EON_Swing_Dock.lua")  end
  if want_steppa  and not st then run_script(here .. sep .. "EON_Steppa_Dock.lua", "EON_Steppa_Dock.lua") end
  if want_browser and not b  then run_script(bundle_scripts .. sep .. "Swing_Browser.lua", "Swing_Browser.lua") end
  if want_padfx   and not p  then run_script(bundle_scripts .. sep .. "Swing_PadFX.lua",   "Swing_PadFX.lua")   end
end

local function open_missing()
  if not ensure_swing() then return false end
  open_panes()
  return true
end

if apply then
  -- Landing pre-seed — reality must match the picker's card. EON Dock Layout
  -- ships the landing plan its cards drew (ExtState EON_DockView/plan:
  -- "pane=dockerindex" for every carried pane that has NO saved docked
  -- home). For the ones still closed, write that target into the slot each
  -- pane already restores from: the gfx panes read <ns>/dockstate at
  -- gfx.init, Pad FX reads Swing/padfx_dock at start, Browser consumes the
  -- one-shot Swing/browser_dock_stage override on its first frame. Open
  -- panes and saved homes are never touched — REAPER's memory of your
  -- arrangement still wins. (ReaImGui dock id -1..-16 = REAPER docker 0..15;
  -- gfx dockstate = 1 + index*256.)
  local target = {}
  for k, v in reaper.GetExtState("EON_DockView", "plan"):gmatch("(%w+)=(%d+)") do
    target[k] = tonumber(v)
  end
  reaper.DeleteExtState("EON_DockView", "plan", false)
  reaper.DeleteExtState("Swing", "browser_dock_stage", false)  -- no stale stage survives an apply
  if target.swing and want_dock and not d then
    reaper.SetExtState("EON_SwingDock", "dockstate", tostring(1 + target.swing * 256), true)
  end
  if target.steppa and want_steppa and not st then
    reaper.SetExtState("EON_SteppaDock", "dockstate", tostring(1 + target.steppa * 256), true)
  end
  if target.browser and want_browser and not b then
    reaper.SetExtState("Swing", "browser_dock_stage", tostring(-(target.browser + 1)), false)
  end
  if target.padfx and want_padfx and not p then
    reaper.SetExtState("Swing", "padfx_dock", tostring(-(target.padfx + 1)), true)
  end
  -- Open what the layout wants, close what it doesn't carry.
  if d  and not want_dock    then reaper.SetExtState("EON_SwingDock",  "close", "1", false) end
  if st and not want_steppa  then reaper.SetExtState("EON_SteppaDock", "close", "1", false) end
  if b  and not want_browser then reaper.SetExtState("Swing", "browser_close", "1", false) end
  if p  and not want_padfx   then reaper.SetExtState("Swing", "padfx_close",   "1", false) end
  -- Backed out at the no-Swing menu: nothing opened, so the toolbar must not
  -- light. "New song…" leaves the button dark until the starter opens the view
  -- itself, which is honest -- the rig genuinely is not up yet.
  if not open_missing() then return end
  set_lit(true)
elseif all_open then
  -- Close whatever is up — the raw open set, so a pane orphaned by an old
  -- layout still goes down with the view.
  if d  then reaper.SetExtState("EON_SwingDock",  "close", "1", false) end
  if st then reaper.SetExtState("EON_SteppaDock", "close", "1", false) end
  if b  then reaper.SetExtState("Swing", "browser_close", "1", false) end
  if p  then reaper.SetExtState("Swing", "padfx_close",   "1", false) end
  set_lit(false)
else
  if not open_missing() then return end
  set_lit(true)
end
