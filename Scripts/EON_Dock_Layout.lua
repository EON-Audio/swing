-- EON_Dock_Layout.lua — pick which panes make up the Swing Dock View.
--
-- A small ReaImGui card picker (one card per layout, each drawn as a mini
-- SCREEN: arrange in the middle, panes on the docker edges they will REALLY
-- occupy). Click a card = the pick is stored (ExtState EON_DockView/layout
-- + /panes, persistent) and applied on the spot: EON Swing Dock View.lua is
-- invoked in "apply" mode, which opens the layout's missing panes and closes
-- the ones it doesn't carry. From then on the Dock View toolbar toggle opens
-- and closes exactly that layout.
--
-- Cards draw the LANDING PLAN — the same resolver whose targets a pick ships
-- to the Dock View (ExtState EON_DockView/plan), so the drawing is a promise,
-- not an illustration:
--   * a pane with a saved docked home is drawn there and keeps it;
--   * a homeless pane is assigned a docker on its conventional edge (Browser
--     left, Pad FX right, the gfx panes bottom) and the Dock View pre-seeds
--     that exact target into the pane's own remembered-dock slot before
--     launching it — so the first landing matches the card;
--   * an edge with no docker to land on means the pane floats (drawn as a
--     lifted mini window); two panes on one docker draw as one tabbed slot.
-- A plain layout pick never moves a pane that is already open, and once you
-- dock a pane somewhere REAPER remembers, the plan (and the card) follows YOUR
-- spot. Sizes and tab order inside a docker stay REAPER's.
--
-- THREE things here deliberately DO move panes, and all three are explicit:
--   * "Spread panes" — push the current layout's panes onto separate dockers
--     instead of letting them tab together. Only when pressed.
--   * a TEMPLATE card (Ableton, Bitwig — the ones with a coloured dot) — those
--     carry per-pane EDGES and an ORDER, and placing panes is the whole point.
--     An ordered template re-docks its panes one at a time, so the row builds
--     up left to right over about a second; the footer counts the steps.
--   * "Save dock shape" — ⛔ DEAD on the build this was written against: SWS
--     cannot reach REAPER's dockposflags, so both shape buttons stay HIDDEN.
--     See dockpos_get. Screensets are the real answer if this is revisited.
--
-- "Keep open" (footer checkbox, remembered) turns the picker into a little
-- layout palette: picks apply without closing the window, so you can hop
-- between layouts; Esc still closes.
--
-- No ReaImGui installed -> the old native text menu (picks still ship the
-- same plan).
--
-- Add layouts freely — the picker builds itself from this table. Pane keys:
-- swing (pads), steppa (sequencer), browser (samples), padfx (per-pad FX).
-- ⚠️ Swing's wordmark menu draws its OWN mini glyphs for these rows
-- (rk_swing_popup.jsfx-inc, sp_layout_glyph) — INDEX is the contract there
-- too: add a layout here, add its glyph case there.
--
-- Installed with Swing: the bridge registers it in the Action List (EON_Register_Actions).

-- ⚠️ Declared HERE, above LAYOUTS, because LAYOUTS uses it. Lua locals are
-- position-scoped: defined lower down this is a nil GLOBAL at the table
-- literal, and `dockpos` would silently be nil rather than erroring.
-- OBSERVED on 2026-08-27, not guessed: double-clicking the docker border took
-- dockposflags from 1 to 0, and that is exactly the corner priority in
-- question -- 0 = the LEFT dock owns the corner and runs full height, 1 = the
-- BOTTOM dock owns it and spans full width. That border double-click is also
-- ONE-WAY in practice (user: "no it doesnt go back to that layout, it stays"),
-- so writing the value here is the only reliable way back.
-- Recorded for whoever picks this up next -- there is no constant here any
-- more because nothing can use it: SWS cannot reach dockposflags on this
-- build (see dockpos_get), so the value is knowledge, not a lever.

-- ⚠️ APPEND ONLY, never reorder or insert. Swing's wordmark menu carries its
-- own copy of these labels and the INDEX is the contract between them
-- (rk_swing_popup.jsfx-inc, sp_layout_glyph). Adding at the end leaves 1..4
-- untouched, so that menu keeps working; it simply lists the first four and
-- the templates below live in this picker, which is the fuller surface anyway.
--
-- `edges` makes a layout a TEMPLATE: it names the screen edge each pane should
-- live on, and picking it PLACES the panes rather than only opening them. The
-- four originals have no edges and keep the doctrine that a pick never moves
-- anything you arranged yourself.
--
-- `order` is the template's left-to-right row, and it is real -- but not for
-- the reason it first looks. ⚠️ REAPER does NOT lay same-edge dockers out by
-- index: measured 2026-08-27, Swing sat in docker 3 at screen x 436, Steppa in
-- docker 0 at x 940, Pad FX in docker 2 further right. Screen order 3, 0, 2.
-- ⭐ What DOES hold is that re-docking a pane APPENDS it to the end of its
-- edge's row -- same session, Steppa moved docker 0 -> 5 and jumped from the
-- middle of the bottom row to the far right, past a Pad FX that never moved.
-- So visible order is DOCKING order, and `order` is delivered by re-docking
-- the panes one at a time in that sequence (see the sequencer in loop()).
-- Which is also why an ordered pane is never assigned the docker it is already
-- in: the move has to be real or it takes no place in the row.
-- ⚠️ An edge is a wish, not a guarantee: a docker's edge is REAPER's own
-- setting and no script can change it, so a template asking for "right" on a
-- rig with no right-hand docker falls back the same way anything else does.
local LAYOUTS = {
  { name = "Full",         panes = "swing,steppa,browser,padfx" },
  { name = "Beatmaking",   panes = "swing,steppa" },
  { name = "Sound design", panes = "swing,browser,padfx" },
  { name = "Pads only",    panes = "swing" },
  -- Live's Drum Rack sits in the device chain along the BOTTOM with the
  -- browser pinned LEFT, and a pad's controls appear beside the rack rather
  -- than in their own window — so Pad FX joins the bottom row.
  { name = "Ableton",      panes = "swing,steppa,browser,padfx",
    note  = "Drum Rack feel: browser down the left, rack + pad controls along the bottom",
    tint  = 0xF2C230FF,
    edges = { browser = "left", swing = "bottom", steppa = "bottom", padfx = "bottom" },
    -- ⛔ DEPTH IS PER EDGE, never per pane -- measured, and the reason there is
    -- no `swing = 400` here: everything along the bottom shares one height.
    -- SHARE is per pane, and does divide the row. The rack gets the most, the
    -- sequencer next, and Pad FX a fifth -- which is still far more than the
    -- 139px it was squeezed into when REAPER shared the row its own way.
    depths = { left = 380, bottom = 400 },
    shares = { swing = 0.45, steppa = 0.33, padfx = 0.22 },
    -- Rack first, its controls beside it, sequencer last -- and `order` is what
    -- finally makes this differ from "Full" on a rig that is already arranged:
    -- without it every pane kept the docker it was already in.
    -- ⛔ No `dockpos` default. 0 IS the observed value for "left dock owns the
    -- corner", but SWS cannot write dockposflags on this build, so shipping it
    -- would only promise the full-height column and never deliver it.
    order = "browser,swing,padfx,steppa" },
  -- Bitwig mirrors it: browser on the far side, device chain along the bottom.
  { name = "Bitwig",       panes = "swing,steppa,browser,padfx",
    note  = "Browser down the right, device chain along the bottom",
    tint  = 0xE8622AFF,
    edges = { browser = "right", swing = "bottom", steppa = "bottom", padfx = "bottom" },
    depths = { right = 380, bottom = 400 },
    shares = { swing = 0.45, steppa = 0.33, padfx = 0.22 },
    order = "browser,swing,padfx,steppa" },
}

-- Draw order + conventional edges. `ext` = the pane script's ExtState
-- namespace; it doubles as "gfx pane" — those always dock somewhere, while
-- Browser/Pad FX are ReaImGui windows that may float.
local PANES = {
  { key = "swing",   ext = "EON_SwingDock",  def = "bottom" },
  { key = "steppa",  ext = "EON_SteppaDock", def = "bottom" },
  { key = "browser", ext = nil,              def = "left"   },
  { key = "padfx",   ext = nil,              def = "right"  },
}

-- ── your own arrangement ────────────────────────────────────────────────────
-- Ableton and Bitwig are somebody else's opinion, baked in. This one is yours:
-- the "Arrange" button under the cards edits which edge each pane lives on and
-- what order they sit in, and it behaves as a template like any other -- same
-- resolver, same sequencer. Kept in ExtState, so it outlives REAPER.
--
-- Defaults are exactly the arrangement asked for on 2026-08-27: browser down
-- the left, then swing, steppa, padfx along the bottom.
local CUSTOM_DEF_EDGES = "browser=left,swing=bottom,steppa=bottom,padfx=bottom"
local CUSTOM_DEF_ORDER = "browser,swing,steppa,padfx"
-- ⛔ ONE DEPTH PER EDGE, not per pane. Measured: resizing one docker on an
-- edge resized every docker on that edge. A per-pane depth control would be
-- offering something the engine provably cannot deliver.
local CUSTOM_DEF_DEPTHS = "bottom=400,left=380,right=380,top=240"
-- Whole numbers, and they do not have to add up: the sizing pass normalises
-- each edge's row against its own total, so "45" beside "33" and "22" means
-- the same as 0.45/0.33/0.22. A pane alone on its edge takes all of it
-- whatever this says.
local CUSTOM_DEF_SHARES = "swing=45,steppa=33,padfx=22,browser=33"
local CUSTOM_DEF_NATIVES = ""
local EDGE_CHOICES = { "left", "right", "top", "bottom" }

-- ── REAPER's own windows (opt-in, Custom card only) ─────────────────────────
--
-- `ident` is the name REAPER files a window under in reaper.ini's
-- [REAPERdockpref] — read out of the user's own file and confirmed again in a
-- saved window set, not guessed. `cmd` is the window's show/toggle action,
-- taken from REAPER's action list rather than memory.
--
-- ⚠️ `Dock_UpdateDockID` only decides where a window opens NEXT. A native that
-- is already up has to be closed and reopened to move, which is why the
-- sequencer has a "reopen" stage.
-- ⛔ Deliberately NOT in the four presets. Pressing "Beatmaking" should never
-- rearrange windows the user does not think of as ours.
local NATIVES = {
  { key = "regmgr",    ident = "regmgr",    cmd = 40326, label = "Region/Marker Manager" },
  { key = "explorer",  ident = "explorer",  cmd = 50124, label = "Media Explorer" },
  { key = "mixer",     ident = "mixer",     cmd = 40078, label = "Mixer" },
  { key = "trackmgr",  ident = "trackmgr",  cmd = 40906, label = "Track Manager" },
  { key = "fxbrowser", ident = "fxbrowser", cmd = 40271, label = "FX Browser" },
  { key = "navigator", ident = "navigator", cmd = 40268, label = "Navigator" },
  { key = "bigclock",  ident = "bigclock",  cmd = 40378, label = "Big Clock" },
  { key = "projbay_0", ident = "projbay_0", cmd = 41157, label = "Project Bay" },
}

local function parse_pairs(s, numeric)
  local t = {}
  for k, v in s:gmatch("(%w+)=(%w+)") do
    t[k] = numeric and tonumber(v) or v
  end
  return t
end

local function custom_load()
  local e = reaper.GetExtState("EON_DockView", "custom_edges")
  local o = reaper.GetExtState("EON_DockView", "custom_order")
  local d = reaper.GetExtState("EON_DockView", "custom_depths")
  local h = reaper.GetExtState("EON_DockView", "custom_shares")
  local n = reaper.GetExtState("EON_DockView", "custom_natives")
  if e == "" then e = CUSTOM_DEF_EDGES end
  if o == "" then o = CUSTOM_DEF_ORDER end
  if d == "" then d = CUSTOM_DEF_DEPTHS end
  if h == "" then h = CUSTOM_DEF_SHARES end
  if n == "" then n = CUSTOM_DEF_NATIVES end
  local edges   = parse_pairs(e)
  local depths  = parse_pairs(d, true)
  local shares  = parse_pairs(h, true)
  -- Absent by default and absent unless asked for: an empty table here is the
  -- whole of "opt-in".
  local natives = parse_pairs(n)
  -- A pane missing from a hand-edited or older stored value still needs an
  -- edge, or the resolver silently falls back to its conventional one and the
  -- card stops matching what the editor shows. Same for the sizes: a value the
  -- editor cannot show is a value the user cannot correct.
  for _, p in ipairs(PANES) do
    edges[p.key]  = edges[p.key] or p.def
    shares[p.key] = shares[p.key] or 33
  end
  for _, ed in ipairs(EDGE_CHOICES) do
    depths[ed] = depths[ed] or ((ed == "bottom" or ed == "top") and 400 or 380)
  end
  return edges, o, depths, shares, natives
end

local function custom_save(edges, order, depths, shares, natives)
  local ep, sp, dp, np = {}, {}, {}, {}
  for _, n in ipairs(NATIVES) do
    if natives[n.key] then np[#np + 1] = n.key .. "=" .. natives[n.key] end
  end
  for _, p in ipairs(PANES) do
    ep[#ep + 1] = p.key .. "=" .. (edges[p.key] or p.def)
    sp[#sp + 1] = p.key .. "=" .. math.floor(shares[p.key] or 33)
  end
  for _, ed in ipairs(EDGE_CHOICES) do
    dp[#dp + 1] = ed .. "=" .. math.floor(depths[ed] or 400)
  end
  reaper.SetExtState("EON_DockView", "custom_edges",  table.concat(ep, ","), true)
  reaper.SetExtState("EON_DockView", "custom_order",  order,                 true)
  reaper.SetExtState("EON_DockView", "custom_depths", table.concat(dp, ","), true)
  reaper.SetExtState("EON_DockView", "custom_shares", table.concat(sp, ","), true)
  reaper.SetExtState("EON_DockView", "custom_natives", table.concat(np, ","), true)
end

-- Appended LAST, keeping the index contract with Swing's wordmark menu intact.
local CUSTOM = {
  name  = "Custom",
  panes = "swing,steppa,browser,padfx",
  note  = "Yours — press Arrange to set the edges, order, shares and depths",
  tint  = 0x6FD08CFF,
}
CUSTOM.edges, CUSTOM.order, CUSTOM.depths, CUSTOM.shares, CUSTOM.natives = custom_load()
LAYOUTS[#LAYOUTS + 1] = CUSTOM

local sep = package.config:sub(1, 1)

local function script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)") or ""
  return path:match("^(.*)[/\\]") or ""
end

-- Same temp-register pattern as EON Swing Dock View's run_script.
local function run_script(path, what)
  local f = io.open(path, "r")
  if not f then
    reaper.MB(what .. " not found:\n" .. path, "EON Dock Layout", 0)
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
  reaper.MB("REAPER could not register " .. what .. ".", "EON Dock Layout", 0)
  return false
end

-- ── the landing plan ────────────────────────────────────────────────────────

local POS_EDGE = { [0] = "bottom", [1] = "left", [2] = "top", [3] = "right" }

-- Browser's dock home lives in its settings file, not ExtState. Re-read at
-- most once a second: with "Keep open" the picker outlives Browser dock
-- moves, which only reach the file when the Browser saves.
local browser_saved_dock
local browser_dock_read_t
local function browser_dock()
  local now = reaper.time_precise()
  if browser_dock_read_t and now - browser_dock_read_t < 1 then
    return browser_saved_dock
  end
  browser_dock_read_t = now
  browser_saved_dock = nil
  local f = io.open(reaper.GetResourcePath() .. sep .. "Data" .. sep ..
                    "EON_Swing" .. sep .. "Swing_Browser_Settings.lua", "r")
  if f then
    local body = f:read("*a") or ""
    f:close()
    browser_saved_dock = tonumber(body:match("dock_id%s*=%s*(%-?%d+)"))
  end
  return browser_saved_dock
end

-- ── live layout truth ───────────────────────────────────────────────────────
--
-- Every docker is a window whose TITLE is "REAPER_dock" — its class is
-- something else, so match on the title. Walk a pane's parent chain until one
-- turns up and you have its docker, from Windows itself, with nothing that can
-- go stale. Measured 2026-08-27; see `.docs/specs/Spec_Dock_Layout_Engine.md`.
--
-- This replaces trusting what each pane says about itself. That reporting is
-- still there and still correct, but it is no longer what the resolver reads —
-- an OPEN pane is now read from the window tree, and the stored value is
-- consulted only for a pane that is CLOSED, where there is no window to ask.

local PANE_WINDOW = {
  swing   = { "Swing Dock",         true  },  -- gfx panes title themselves exactly
  steppa  = { "Steppa Dock",        true  },
  padfx   = { "EON Pad FX",         false },  -- ReaImGui appends " — Swing"
  browser = { "EON Sample Browser", false },
}

-- Re-surveyed at most four times a second. The picker redraws every frame and
-- this is a window walk, not a table lookup; a quarter second still tracks a
-- drag as it happens, which is what makes the cards feel live.
local live_t, live_idx, live_open, live_hwnd = nil, {}, {}, {}

-- `force` skips the throttle. Anything that just moved a pane must re-read
-- before acting on the result: a gfx pane rebuilds its window when it re-docks,
-- so a cached handle from a quarter second ago can be a window that no longer
-- exists.
local function live_refresh(force)
  local now = reaper.time_precise()
  if not force and live_t and now - live_t < 0.25 then return end
  live_t = now
  live_idx, live_open, live_hwnd = {}, {}, {}
  if not reaper.APIExists("JS_Window_Find") then return end

  for key, w in pairs(PANE_WINDOW) do
    local h = reaper.JS_Window_Find(w[1], w[2])
    if h then
      live_open[key] = true
      live_hwnd[key] = h
      local p, guard = reaper.JS_Window_GetParent(h), 0
      while p and guard < 64 do
        if reaper.JS_Window_GetTitle(p) == "REAPER_dock" then
          local idx = reaper.DockIsChildOfDock(p)
          if idx and idx >= 0 then live_idx[key] = idx end
          break
        end
        p = reaper.JS_Window_GetParent(p)
        guard = guard + 1
      end
    end
  end
end

-- ── moving a docker to another screen edge ──────────────────────────────────
--
-- REAPER's own actions. ⭐ MEASURED 2026-08-27 (`EON Dock Aiming Probe.lua`):
-- bring the PANE to the foreground first and the action moves the docker that
-- pane sits in. Aim at anything else and it moves docker 0 instead —
-- `JS_Window_SetFocus` on the DOCKER window fails silently, and
-- `DockWindowActivate` on the pane is not enough either. Both were measured
-- misses; do not "simplify" this back to one of them.
--
-- ⚠️ Steals focus by construction, so it only ever runs from an apply, never
-- from a tick.
-- ⚠️ Moves the whole DOCKER — anything sharing it travels too, which is why
-- the resolver hands an edge-moving pane a docker of its own first.
-- ⚠️ A docker that changes edge can come back a different SIZE. Depth and
-- shares are set after placement (P3), which is what heals that.
local EDGE_ACTION = { bottom = 41598, left = 41599, top = 41600, right = 41601 }

local function docker_edge(idx)
  if not idx then return nil end
  return POS_EDGE[reaper.DockGetPosition(idx)]
end

-- Docker index → { pos = edge name or nil, vis = is it showing }.
--
-- ⭐ MEASURED 2026-08-27: REAPER keeps all sixteen dockers alive as windows the
-- whole time and simply HIDES the ones holding nothing — twelve of the user's
-- sixteen were invisible and contained nothing but their own tab strip. So
-- "not visible" is a cheap and reliable "empty, safe to repurpose", and it is
-- what keeps the edge-moving tier below from picking up a docker that holds
-- the user's Mixer and carrying it to an edge they never asked about.
local function docker_state()
  local st = {}
  for i = 0, 15 do
    st[i] = { pos = POS_EDGE[reaper.DockGetPosition(i)], vis = false }
  end
  if not reaper.APIExists("JS_Window_ListFind") then return st end
  local cnt, list = reaper.JS_Window_ListFind("REAPER_dock", true)
  if cnt and cnt > 0 then
    for tok in (list .. ","):gmatch("(.-),") do
      local a = tonumber(tok)
      local h = a and reaper.JS_Window_HandleFromAddress(a)
      local idx = h and reaper.DockIsChildOfDock(h)
      if idx and st[idx] then
        st[idx].hwnd = h
        st[idx].vis = reaper.JS_Window_IsVisible(h)
        local ok, l, t, r, b = reaper.JS_Window_GetRect(h)
        if ok then
          st[idx].x, st[idx].y = l, t
          st[idx].w, st[idx].h = r - l, b - t
        end
      end
    end
  end
  return st
end

-- The window sitting in a docker, found by looking INSIDE that docker rather
-- than by title. Native window titles are localised and some carry the project
-- or track name; the docker we just put one in does not change. Skips the tab
-- strip, which is a child like any other.
-- ⚠️ Only meaningful for a docker we know holds one thing — natives are always
-- given an EMPTY docker, so the first real child is the one we mean.
local function docked_child(idx)
  local st = docker_state()
  local dh = st[idx] and st[idx].hwnd
  if not dh then return nil end
  local cnt, list = reaper.JS_Window_ListAllChild(dh)
  if not cnt or cnt <= 0 then return nil end
  for tok in (list .. ","):gmatch("(.-),") do
    local a = tonumber(tok)
    local h = a and reaper.JS_Window_HandleFromAddress(a)
    if h and reaper.JS_Window_GetParent(h) == dh
       and reaper.JS_Window_GetClassName(h) ~= "WDLTabCtrl" then
      return h
    end
  end
  return nil
end

-- An empty docker for a native to open into: one already on the edge it wants
-- if there is one, otherwise any empty docker, which the edge push will then
-- carry over. Empty only, for the same reason the pane resolver insists on it.
local function free_docker_for(edge)
  local st = docker_state()
  for pass = 1, 2 do            -- pass 1: already on that edge. pass 2: anywhere.
    for i = 1, 16 do
      local d = i % 16
      if st[d].pos and not st[d].vis and (pass == 2 or st[d].pos == edge) then
        return d
      end
    end
  end
  return nil
end

-- ── sizing: how deep an edge is, and how it is shared ───────────────────────
--
-- Edgemeal's technique by way of talagan's Docking Tools (MIT): send a fake
-- press and release to the docker's own resize grip. `EON Dock Resize Probe.lua`
-- measured it on 2026-08-27 and it is pixel-exact — asked 299, got 299.
--
-- ⛔ DEPTH IS PER EDGE, NEVER PER PANE. Confirmed five times on a three-docker
-- bottom edge: resizing one resized all three. Two panes along the bottom can
-- never have different heights. Anything that offers per-pane depth is lying.
-- ⚠️ REAPER CLAMPS SILENTLY — the probe asked for 10 and got 37, asked for
-- 5000 and got 800, with no error either time. Every set is measured back and
-- the difference reported rather than assumed away.
local function drag(h, x0, x1, y0, y1)
  reaper.JS_WindowMessage_Send(h, "WM_LBUTTONDOWN", 1, 0, x0, y0)
  reaper.JS_WindowMessage_Send(h, "WM_LBUTTONUP", 0, 0, x1, y1)
end

local function client_wh(h)
  local ok, l, t, r, b = reaper.JS_Window_GetClientRect(h)
  if not ok then return nil end
  return r - l, b - t
end

-- Grab the grip on the docker's inner face and pull it by the difference
-- between where it is and where we want it. talagan's geometry, unchanged.
local function set_depth(h, edge, base, want)
  local d = base - want
  if edge == "bottom" then
    drag(h, 0, 0, 0, d)
  elseif edge == "top" then
    drag(h, 0, 0, base, base - d)
  elseif edge == "left" then
    drag(h, base, base - d, 0, 0)
  elseif edge == "right" then
    drag(h, 0, d, 0, 0)
  end
end

-- Move the boundary on a docker's FAR side by `delta`, which takes the pixels
-- from the neighbour along the same edge (measured: +80 on one docker was −80
-- on the next, and the third never moved).
local function nudge_divider(h, edge, delta)
  local cw, ch = client_wh(h)
  if not cw then return false end
  if edge == "bottom" or edge == "top" then
    drag(h, cw, cw + delta, math.floor(ch / 2), math.floor(ch / 2))
  else
    drag(h, math.floor(cw / 2), math.floor(cw / 2), ch, ch + delta)
  end
  return true
end

local function push_edge_hwnd(h, edge)
  local act = EDGE_ACTION[edge]
  if not (act and h) then return false end
  reaper.JS_Window_SetForeground(h)
  reaper.JS_Window_SetFocus(h)
  reaper.Main_OnCommand(act, 0)
  return true
end

local function push_edge(key, edge)
  live_refresh(true)
  return push_edge_hwnd(live_hwnd[key], edge)
end

-- Where a pane lives → REAPER docker index (or nil), plus "has a home at all".
--
-- Open pane: the window tree answers, and a pane with no docker above it is
-- floating — no home, nothing to avoid, nothing to stage.
--
-- Closed pane: fall back to what it persisted. The gfx panes store a gfx.dock
-- state (bit0 = docked, bits 8+ = docker index); the ReaImGui panes store an
-- ImGui dock id where -1..-16 means REAPER docker 0..15. A POSITIVE ImGui id is
-- a home no docker index describes (docked inside another ImGui window) — draw
-- it on its conventional edge and never re-stage it.
local function saved_docker(key)
  live_refresh()
  if live_open[key] then
    local idx = live_idx[key]
    if idx then return idx, true end
    return nil, false
  end
  if key == "swing" or key == "steppa" then
    local ds = tonumber(reaper.GetExtState(key == "swing" and "EON_SwingDock"
                                           or "EON_SteppaDock", "dockstate")) or 0
    if ds % 2 == 1 then return math.floor(ds / 256), true end
    return nil, false
  end
  local id = (key == "padfx")
    and (tonumber(reaper.GetExtState("Swing", "padfx_dock")) or 0)
    or (browser_dock() or 0)
  if id < 0 then return -id - 1, true end
  return nil, id > 0
end

-- plan[key] = { idx = docker index (nil = none), edge = "bottom"/"left"/
-- "top"/"right"/"float", stage = true when the pick must pre-seed this
-- target for the pane to land there }
--
-- `spread` (the "Spread panes" button, never a layout pick) breaks collisions
-- instead of honouring them: a saved home only survives if no earlier pane in
-- PANES order already claimed that docker, and a pane pushed off its home will
-- take a spare docker on ANY edge before it agrees to share one. Normal picks
-- pass nothing and behave exactly as before -- your arrangement wins.
-- Pane visit order. `order` (a template's comma list) decides who claims a
-- docker FIRST, and the searches below always take the LOWEST free index on an
-- edge — so on a rig where several dockers share an edge, listing panes in the
-- order you want to see them is what actually puts them in that order. Panes a
-- template does not list keep their PANES position, after the listed ones.
--
-- ⚠️ This is the ONLY ordering a script can reach. Which docker sits
-- left-of-which on the same edge is REAPER's own layout of its docker indices,
-- and tab order INSIDE one docker is REAPER's too — neither has an API. So
-- ordering here means "who gets docker 0, who gets docker 1", and it only
-- shows up on a rig that actually has several dockers on that edge.
local function visit_order(order)
  if not order then return PANES end
  local by_key = {}
  for _, p in ipairs(PANES) do by_key[p.key] = p end
  local out, seen = {}, {}
  for k in order:gmatch("[^,]+") do
    if by_key[k] and not seen[k] then out[#out + 1] = by_key[k]; seen[k] = true end
  end
  for _, p in ipairs(PANES) do
    if not seen[p.key] then out[#out + 1] = p end
  end
  return out
end

-- `edges` (a template's table, or nil) overrides each pane's conventional edge
-- for this resolve only — it is where a template's opinion actually lands.
-- `order` additionally makes the template, not the saved home, decide WHICH
-- docker on that edge each listed pane gets.
local function build_plan(spread, edges, order)
  local ranked = {}
  if order then for k in order:gmatch("[^,]+") do ranked[k] = true end end
  local panes_in_order = visit_order(order)
  local pos, empty = {}, {}
  local st = docker_state()
  for i = 0, 15 do
    pos[i] = st[i].pos
    empty[i] = not st[i].vis
  end
  -- Read each home ONCE. Both passes need it, the ordered search needs it to
  -- know which docker to avoid, and the Browser's costs a file read.
  local home_idx, home_any = {}, {}
  for _, p in ipairs(PANES) do
    home_idx[p.key], home_any[p.key] = saved_docker(p.key)
  end
  local plan, claimed, claimed_edge = {}, {}, {}
  -- saved homes first: they always win, and their dockers are spoken for
  for _, p in ipairs(panes_in_order) do
    local dfl = (edges and edges[p.key]) or p.def
    local idx, home = home_idx[p.key], home_any[p.key]
    -- A template ignores a saved home that is on the WRONG EDGE: "browser on
    -- the left" is the entire content of picking Ableton, so honouring a
    -- browser last left at the bottom would make the template a no-op on every
    -- rig that has ever been arranged — which is every rig that wants one.
    -- ⚠️ A pane the template ORDERS is placed by the template, full stop.
    -- Honouring its saved home would hand it back the docker it already has
    -- and the ordering could never take effect -- which is exactly why Full
    -- and Ableton came out identical on an already-arranged rig.
    local home_ok = idx and not (spread and claimed[idx])
                        and not (edges and pos[idx] and pos[idx] ~= dfl)
                        and not ranked[p.key]
    if home_ok then
      plan[p.key] = { idx = idx, edge = pos[idx] or dfl, stage = false }
      claimed[idx] = true
      claimed_edge[pos[idx] or dfl] = true
    elseif home and not spread then
      plan[p.key] = { edge = dfl, stage = false }
    end
  end
  -- then assign the homeless: a spare docker on their edge if one exists,
  -- sharing (= REAPER tabs) if not, floating / docker 0 as the last resort
  for _, p in ipairs(panes_in_order) do
    local dfl = (edges and edges[p.key]) or p.def
    if not plan[p.key] then
      local pick
      -- ⭐ MEASURED 2026-08-27: re-docking APPENDS a pane to the end of its
      -- edge's row (Steppa moved docker 0 -> 5 and jumped from the middle of
      -- the bottom row to the far right, past a Pad FX that never moved). So
      -- visible order = DOCKING order, and an ordered template gets it by
      -- re-docking its panes one at a time in sequence.
      -- ⚠️ Which means every ordered pane must genuinely MOVE. A pane handed
      -- the docker it is already in would either no-op or, at best, be a bet
      -- on unmeasured behaviour -- so an ordered pane is never assigned its
      -- current docker, and the sequence is guaranteed to be real moves.
      local avoid = order and home_idx[p.key] or nil
      for i = 0, 15 do
        if pos[i] == dfl and not claimed[i] and i ~= avoid then pick = i; break end
      end
      -- Spreading, and the pane's own edge is full. Prefer a spare docker on
      -- an edge NO pane has claimed yet, and only then any spare docker at all.
      -- ⚠️ A different docker INDEX is not always visibly apart: REAPER can
      -- render several dockers that share a screen edge as one tab strip, so
      -- moving a pane from bottom-docker-4 to bottom-docker-1 can look like
      -- nothing happened (2026-08-27). A free EDGE is the only separation we
      -- can actually promise, since a docker's edge is REAPER's own setting
      -- and no script can change it.
      -- Order is 1..15 then 0: docker 0 is REAPER's main dock and the most
      -- likely to already hold the user's own windows (Mixer, Media Explorer),
      -- which we cannot see -- so it is the last resort, not the first.
      -- Dockers REAPER reports no edge for (floating, or never configured)
      -- are skipped: pos[i] is nil for them.
      -- ⛔ NOT for a template. `edges` is an explicit instruction, and Ableton
      -- deliberately wants three panes along the bottom — chasing a free edge
      -- there would exile the step sequencer to the left and call it tidy.
      -- A template that runs out of bottom dockers should SHARE the bottom.
      if not pick and spread and not edges then
        for i = 1, 16 do
          local d = i % 16
          if pos[d] and not claimed[d] and not claimed_edge[pos[d]] then pick = d; break end
        end
        if not pick then
          for i = 1, 16 do
            local d = i % 16
            if pos[d] and not claimed[d] then pick = d; break end
          end
        end
      end
      -- ⭐⭐ Nothing free on the wanted edge — so MOVE a docker there. A
      -- docker's edge is settable now (foreground the pane, run REAPER's own
      -- "Docker: show in <edge>" action; measured 2026-08-27, see push_edge).
      -- This is the tier that makes "browser on the right" land on a rig that
      -- has never had a right-hand docker, which used to be the whole reason
      -- the Bitwig template could not work.
      --
      -- ⛔ EMPTY dockers only. Repurposing a docker that is showing would
      -- carry whatever lives in it — the user's Mixer, their Media Explorer —
      -- to an edge they never asked about, and they would have no idea what
      -- did it. If nothing empty is going, fall through and share instead:
      -- sharing is a worse layout, hijacking is a worse surprise.
      -- Same 1..15-then-0 preference as the spread search: docker 0 is
      -- REAPER's main dock and the likeliest to be holding something of
      -- theirs. A docker REAPER reports no edge for (floating) is skipped —
      -- those are not ours to reposition.
      local move_edge = false
      if not pick then
        for i = 1, 16 do
          local d = i % 16
          if pos[d] and empty[d] and not claimed[d] and d ~= avoid then
            pick, move_edge = d, true
            break
          end
        end
      end
      -- Still nothing: share the edge, which is what the tab nubs draw.
      if not pick then
        for i = 0, 15 do
          if pos[i] == dfl then pick = i; break end
        end
      end
      if pick then
        -- Where the card must draw it. For the two conventional-edge searches
        -- pos[pick] IS dfl; the spread search can land on another edge and the
        -- card has to say so; and a docker we are about to move belongs on the
        -- edge we are moving it to, not the one it is leaving.
        local eff = move_edge and dfl or (pos[pick] or dfl)
        plan[p.key] = { idx = pick, edge = eff, stage = true }
        claimed[pick] = true
        claimed_edge[eff] = true
      elseif p.ext then
        -- gfx panes always dock; docker 0 is wherever REAPER has it
        plan[p.key] = { idx = 0, edge = pos[0] or dfl, stage = true }
        claimed[0] = true
        claimed_edge[pos[0] or dfl] = true
      else
        plan[p.key] = { edge = "float", stage = false }
      end
    end
  end
  return plan
end

-- ── dock shape (REAPER's dockposflags) ──────────────────────────────────────
-- "Browser down the ENTIRE left side" is not something a pane can ask for.
-- Whether the left dock runs full height or the bottom dock spans the full
-- width is ONE REAPER-wide setting -- dockposflags -- and no pane, edge or
-- docker index reaches it. There is no native API either, only SWS's config-var
-- accessors, so everything here degrades to a no-op rather than pretending.
--
-- ⚠️⚠️ The value is CAPTURED, NEVER COMPUTED. The bit layout is undocumented,
-- and writing a guessed mask into a global setting would rearrange the user's
-- entire window on a wrong guess -- with no undo, on their working session.
-- So: arrange the docks by hand once, press "Save dock shape", and the layout
-- replays the exact number REAPER itself produced. Whatever was in effect
-- before the first replay is kept under dockpos_prev, so there is a way back.
-- ⚠️⚠️ MEASURED 2026-08-27 and it does NOT work on this build: SWS returns the
-- error sentinel for "dockposflags", so it cannot read the variable, let alone
-- write it. reaper.ini holds the value and it genuinely IS the right one --
-- double-clicking the docker border moved it 1 -> 0 -- but SWS has no handle on
-- it. Every path below therefore no-ops, and the two buttons are HIDDEN rather
-- than left sitting there reporting success.
-- ⛔ Do not "fix" this by writing reaper.ini: REAPER holds its config in memory
-- and rewrites the file on exit, so an edit underneath it is discarded at best.
-- The real answer is REAPER's own SCREENSETS, which capture dock shape AND
-- sizes natively with no extension at all.
--
-- Checking the FUNCTION exists was never enough -- that is what made this look
-- like it worked. Probe the variable itself.
local DOCKPOS_ERR = -2147483647   -- sentinel: "no such var on this build"
local function dockpos_get()
  if not (reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar) then return nil end
  local v = reaper.SNM_GetIntConfigVar("dockposflags", DOCKPOS_ERR)
  if v == DOCKPOS_ERR then return nil end
  return v
end

local function dockpos_available()
  return dockpos_get() ~= nil
end

-- A shape the user saved for this layout wins; `fallback` is the layout's own
-- shipped default, used when they never saved one.
local function dockpos_apply(name, fallback)
  local want = tonumber(reaper.GetExtState("EON_DockView", "dockpos_" .. name)) or fallback
  if not want or not dockpos_available() then return nil end
  local cur = dockpos_get()
  if not cur or cur == want then return nil end
  if reaper.GetExtState("EON_DockView", "dockpos_prev") == "" then
    reaper.SetExtState("EON_DockView", "dockpos_prev", tostring(cur), true)
  end
  reaper.SNM_SetIntConfigVar("dockposflags", want)
  if reaper.DockWindowRefresh then reaper.DockWindowRefresh() end
  return "dock shape restored"
end

local function dockpos_save(name)
  if not dockpos_available() then
    return "dock shape needs the SWS extension"
  end
  local cur = dockpos_get()
  if not cur then return "REAPER did not report dockposflags" end
  reaper.SetExtState("EON_DockView", "dockpos_" .. name, tostring(cur), true)
  return "dock shape saved for " .. name
end

-- The door for the safety net. dockpos_prev holds whatever was in effect
-- before the FIRST time a layout replayed a shape; this puts it back and
-- forgets it, so the undo is one-shot and the next replay stashes afresh
-- rather than the "before" drifting to mean something else.
local function dockpos_restore()
  if not dockpos_available() then return "dock shape needs the SWS extension" end
  local prev = tonumber(reaper.GetExtState("EON_DockView", "dockpos_prev"))
  if not prev then return "nothing to undo — no earlier dock shape stored" end
  reaper.SNM_SetIntConfigVar("dockposflags", prev)
  if reaper.DockWindowRefresh then reaper.DockWindowRefresh() end
  reaper.DeleteExtState("EON_DockView", "dockpos_prev", true)
  return "dock shape put back to what it was"
end

-- Forward declarations: these need pane_running / send_to_docker, which are
-- defined below with the rest of the Spread machinery, but apply() needs them
-- here. Lua locals are position-scoped -- the trap that silently broke the
-- bridge relay -- so the names are claimed now and filled in there.
local report, plan_moves

local function apply(choice)
  local L = LAYOUTS[choice]
  if not L then return end
  reaper.SetExtState("EON_DockView", "layout", L.name,  true)
  reaper.SetExtState("EON_DockView", "panes",  L.panes, true)
  local out, msg, queue, queue_stuck, sizing = {}, nil, nil, nil, nil
  if L.edges then
    -- TEMPLATE: it owns where its panes go, so it writes every carried pane's
    -- restore slot itself and moves the ones already open. Nothing is left for
    -- the Dock View pre-seed -- shipping a plan as well would have the two
    -- writing different targets into the same key, last one wins.
    -- Dock SHAPE before pane PLACEMENT: changing dockposflags re-lays the
    -- whole docker frame, so moving panes first would only have them shuffled
    -- again underneath. (Dead on the current build -- see dockpos_get.)
    local shape = dockpos_apply(L.name, L.dockpos)
    local moves, stuck = plan_moves(L.panes, L.edges, L.order)
    -- REAPER's own windows go LAST, after every pane has landed. By then the
    -- panes' dockers are occupied, so the empty-docker search cannot hand a
    -- native a slot a pane was about to take.
    if L.natives then
      for _, n in ipairs(NATIVES) do
        local e = L.natives[n.key]
        if e then moves[#moves + 1] = { kind = "native", nat = n, edge = e } end
      end
    end
    -- Sizes run whether or not anything had to move: a layout picked on a rig
    -- already arranged that way still owes you its depths and shares.
    if L.depths or L.shares then
      sizing = { depths = L.depths, shares = L.shares, panes = L.panes }
    end
    if #moves > 0 then
      -- ALWAYS the queue now, ordered template or not. Two reasons to walk the
      -- moves one at a time: visible order is docking order, and a step may
      -- also have to move its docker to another EDGE, which can only happen
      -- once the pane is actually in that docker. Firing them together is a
      -- race between four defer loops — neither an order nor a placement.
      queue, queue_stuck = moves, stuck
    else
      msg = report({}, stuck) or (L.name .. ": already arranged")
    end
    if shape and msg then msg = shape .. "  ·  " .. msg end
  else
    -- Ship the staged landings (only carried panes with no saved home get one)
    -- so the Dock View can pre-seed them — the card just clicked stays true.
    local plan = build_plan()
    for k in L.panes:gmatch("[^,]+") do
      local t = plan[k]
      if t and t.stage and t.idx then out[#out + 1] = k .. "=" .. t.idx end
    end
  end
  reaper.SetExtState("EON_DockView", "plan",  table.concat(out, ","), false)
  reaper.SetExtState("EON_DockView", "apply", "1", false)
  run_script(script_dir() .. sep .. "EON_Swing_Dock_View.lua", "EON_Swing_Dock_View.lua")
  -- msg = something to say now; queue = moves the caller must walk one at a
  -- time, with the edges it could not reach alongside. Never both. `sizing`
  -- rides along either way and runs once the moves are done.
  return msg, queue, queue_stuck, sizing
end

-- ── "Spread panes" ──────────────────────────────────────────────────────────
-- Layout picks deliberately never move a pane you already placed: a saved home
-- always beats the plan, and open panes are left alone. The cost is that once
-- several panes end up sharing one docker, nothing ever pulls them apart --
-- REAPER remembers the tab stack, so every reopen rebuilds it (user 2026-08-27:
-- "it opens back to however they were last configured which is great. but if i
-- move them ... becomes hard to move back").
--
-- This button is the explicit opposite, and ONLY runs when pressed: resolve the
-- plan with collisions broken (build_plan(true)), then push every pane the
-- active layout carries to its target -- live for the ones that are open, into
-- the slot they restore from for the ones that are not.
--
-- ⚠️ What no script can do is choose which EDGE a docker sits on; that is
-- REAPER's own docker setting. We can put a pane in docker 4 -- whether docker
-- 4 is at the bottom or the right is the user's. With fewer dockers than panes
-- the resolver falls back to sharing, which is exactly what the cards draw.
local function pane_running(key)
  if key == "swing" or key == "steppa" then
    -- Per-kind liveness stamp, written every pane tick and zeroed in save_dock.
    local hb = tonumber(reaper.GetExtState(key == "swing" and "EON_SwingDock"
                                           or "EON_SteppaDock", "alive")) or 0
    return hb > 0 and (reaper.time_precise() - hb) < 2
  elseif key == "padfx" then
    if reaper.GetExtState("Swing", "padfx_running") ~= "1" then return false end
    return (os.time() - (tonumber(reaper.GetExtState("Swing", "padfx_heartbeat")) or 0)) < 3
  end
  if reaper.GetExtState("Swing", "browser_running") ~= "1" then return false end
  reaper.gmem_attach("Swing_Media_Transfer")
  return reaper.gmem_read(1382) ~= 0   -- GS_BROWSER_OPEN; stale flag recovery
end

-- Ask a pane to move: a live request when it is up, and ALWAYS the slot it
-- restores from as well. Both, deliberately -- a pane running a build without
-- the dock_req handler (they do not hot-reload) would otherwise swallow the
-- request AND have nothing persisted, so the button did nothing at all and
-- left no trace. Each pane republishes its real dock on change, so a target
-- written here is corrected within a tick if the pane lands somewhere else.
-- Browser is the exception: its restore slot is a ONE-SHOT override consumed
-- on first frame, so staging it for a running Browser would re-apply on its
-- next launch, long after the user moved it.
local function send_to_docker(key, idx, live)
  if key == "swing" or key == "steppa" then
    local ext = (key == "swing") and "EON_SwingDock" or "EON_SteppaDock"
    reaper.SetExtState(ext, "dockstate", tostring(1 + idx * 256), true)
    if live then reaper.SetExtState(ext, "dock_req", tostring(idx), false) end
  elseif key == "padfx" then
    -- ReaImGui dock id units: -1..-16 = REAPER docker 0..15.
    reaper.SetExtState("Swing", "padfx_dock", tostring(-(idx + 1)), true)
    if live then reaper.SetExtState("Swing", "padfx_dock_req", tostring(-(idx + 1)), false) end
  elseif live then
    reaper.SetExtState("Swing", "browser_dock_req", tostring(-(idx + 1)), false)
  else
    reaper.SetExtState("Swing", "browser_dock_stage", tostring(-(idx + 1)), false)
  end
end

-- Returns a report string for the footer. Says WHERE each pane went, because
-- "it did nothing" and "it moved things you cannot see moving" look identical
-- from the outside -- and on a rig whose dockers all share one screen edge the
-- second is the common case (2026-08-27).
-- Fills the forward declaration above apply(). Two callers: the Spread button
-- (no edges, the active layout's panes) and a template pick (the template's
-- edges and panes).
-- Work out the moves WITHOUT performing them. Two callers want different
-- things from the same answer: "Spread panes" fires them all at once (it only
-- cares that panes stop sharing, not what order they end up in), while an
-- ordered template has to walk them ONE AT A TIME -- because visible order is
-- docking order, and firing four requests together is a race between four
-- defer loops, which is no order at all.
-- ⚠️ `plan_moves = function`, filling the forward declaration above apply().
-- `local function` here would declare a SECOND local and leave the
-- forward-declared one nil -- the same trap that shipped `report` broken.
-- ── seat the panes by declared order, without moving a single docker ────────
--
-- `order` used to be delivered by the APPEND sequence: re-dock the panes one
-- after another and each lands to the right of the last. That has a hole. A
-- pane already sitting in its target docker on the right edge is deliberately
-- skipped (see the note in plan_moves — re-docking a gfx pane churns its
-- canvas capture for nothing), and one skip puts the whole row out. Observed
-- 2026-08-29: Ableton asks for swing,padfx,steppa and delivers
-- steppa,swing,padfx, because Steppa was already at the bottom, kept its slot,
-- and the other two appended to its right.
--
-- This does it the other way round and never touches a docker. Take the
-- dockers the plan already chose on each edge, put them in SCREEN order, and
-- hand them out to that edge's panes in DECLARED order. Same dockers, same
-- edges, same sizes — the only thing that changes is which pane sits in which.
--
-- ⚠️ Only permutes among dockers the plan ALREADY picked, so it can never
-- invent a docker, strand a pane, or change an edge. A pane the resolver could
-- not place has no plan entry and is passed over here too.
local function seat_by_order(plan, order)
  if not order then return plan end
  local st, by_edge = docker_state(), {}
  for k in order:gmatch("[^,]+") do
    local t = plan[k]
    if t and t.idx and t.edge then
      by_edge[t.edge] = by_edge[t.edge] or {}
      table.insert(by_edge[t.edge], k)
    end
  end
  for edge, keys in pairs(by_edge) do
    -- One pane on an edge has nothing to trade places with.
    if #keys > 1 then
      local idxs = {}
      for _, k in ipairs(keys) do idxs[#idxs + 1] = plan[k].idx end
      -- Sorted the way the eye reads that edge: left to right along the
      -- bottom and top, top to bottom down a side. Falls back to docker index
      -- when a rect is missing, so the result is stable rather than arbitrary.
      local horiz = (edge == "bottom" or edge == "top")
      table.sort(idxs, function(a, b)
        local A, B = st[a], st[b]
        if not (A and B and A.w and B.w) then return a < b end
        if horiz then return A.x < B.x end
        return A.y < B.y
      end)
      for i, k in ipairs(keys) do plan[k].idx = idxs[i] end
    end
  end
  return plan
end

plan_moves = function(panes, edges, order)
  local plan = seat_by_order(build_plan(true, edges, order), order)
  local moves, stuck = {}, {}
  for key in panes:gmatch("[^,]+") do
    local t = plan[key]
    if not (t and t.idx) then
      -- Nowhere to put it. Name the EDGE it wanted, not just the failure: on a
      -- rig with no right-hand docker the Bitwig template can never land its
      -- browser, and "no spare dockers" does not tell you that adding one in
      -- REAPER is the fix.
      stuck[#stuck + 1] = key .. " wants " .. ((edges and edges[key]) or (t and t.edge) or "a docker")
    else
      -- A move is warranted when the pane is in the wrong docker, OR when it
      -- is in the right docker but that docker is on the wrong EDGE — the
      -- second is new, and it is how a template gets its edge honoured on a
      -- rig that already put the pane in the only docker going.
      --
      -- ⚠️ `cur` nil means the docker is FLOATING, and REAPER reports no edge
      -- for it. That is not a mismatch to correct: a pane the user has pulled
      -- out into a floating docker stays there unless something else moves it.
      -- Without this guard every floating pane reads as "wrong edge" and gets
      -- dragged back onto a screen edge nobody asked for.
      --
      -- Still skipped: a pane the resolver put back exactly where it already
      -- is. With one docker on an edge the "share" fallback can hand a pane
      -- its own docker again, and moving a pane to itself churns a capture for
      -- nothing.
      local cur = docker_edge(t.idx)
      if t.idx ~= saved_docker(key)
         or (EDGE_ACTION[t.edge] and cur and cur ~= t.edge) then
        moves[#moves + 1] = { key = key, idx = t.idx, edge = t.edge }
      end
    end
  end
  -- ⚠️ ORDERED: walk the template's own order, not the layout's pane list.
  -- The list is just "which panes", while the ORDER is the whole point -- and
  -- a re-dock appends, so the sequence the requests go out in IS the row.
  if order then
    local rank, seq = {}, {}
    local n = 0
    for k in order:gmatch("[^,]+") do n = n + 1; rank[k] = n end
    for _, m in ipairs(moves) do if rank[m.key] then seq[#seq + 1] = m end end
    table.sort(seq, function(a, b) return rank[a.key] < rank[b.key] end)
    for _, m in ipairs(moves) do if not rank[m.key] then seq[#seq + 1] = m end end
    moves = seq
  end
  return moves, stuck
end

-- One report line for both callers. Order matters: what MOVED is the answer to
-- "did anything happen", and an unreachable edge is the answer to "why not".
-- ⚠️ `report = function`, NOT `local function report`: this fills the forward
-- declaration above apply(). `local function` would declare a SECOND local of
-- the same name and leave the forward-declared one nil, which is exactly how
-- this shipped broken for one build ("attempt to call a nil value (upvalue
-- 'report')" the moment a template was picked).
report = function(moved, stuck, idle)
  local parts = {}
  if #moved > 0 then parts[#parts + 1] = table.concat(moved, ", ") end
  if #stuck > 0 then
    parts[#parts + 1] = table.concat(stuck, ", ") ..
                        " — no docker there (REAPER owns docker edges)"
  end
  if #parts == 0 then return idle end
  return table.concat(parts, "  ·  ")
end

-- ── sizing pass ─────────────────────────────────────────────────────────────
--
-- Runs AFTER every pane has landed, and reads live geometry rather than the
-- plan: the plan says where things were asked to go, only the windows know
-- where they actually are, and a move that was clamped or refused must not be
-- sized as though it had worked.

local EDGE_LIST = { "bottom", "left", "top", "right" }

-- Visible dockers on one edge, in screen order, from a docker_state snapshot.
local function edge_row(st, edge)
  local row = {}
  for i = 0, 15 do
    if st[i].vis and st[i].pos == edge and st[i].w then row[#row + 1] = i end
  end
  local horiz = (edge == "bottom" or edge == "top")
  table.sort(row, function(a, b)
    if horiz then return st[a].x < st[b].x end
    return st[a].y < st[b].y
  end)
  return row, horiz
end

-- How wide (or tall) each docker in a row is, and the row's total.
local function row_sizes(st, row, horiz)
  local sz, total = {}, 0
  for n, i in ipairs(row) do
    sz[n] = horiz and st[i].w or st[i].h
    total = total + sz[n]
  end
  return sz, total
end

-- pane key → docker index, for the panes a layout carries.
local function pane_dockers(panes)
  local at = {}
  for key in panes:gmatch("[^,]+") do
    local idx = saved_docker(key)
    if idx then at[idx] = key end
  end
  return at
end

-- One drag per step, so each can settle and be measured before the next.
-- Boundaries are placed left to right and are CUMULATIVE: boundary n is set
-- against wherever boundaries 1..n-1 actually ended up, which is why each step
-- re-reads instead of working from a table computed up front. The last pane
-- takes the remainder — its boundary is the window edge and is never dragged.
local function build_size_steps(depths, shares, panes)
  local st = docker_state()
  local steps = {}
  for _, edge in ipairs(EDGE_LIST) do
    local row = edge_row(st, edge)
    if #row > 0 then
      if depths and depths[edge] then
        steps[#steps + 1] = { kind = "depth", edge = edge, want = depths[edge] }
      end
      if shares and #row > 1 then
        for n = 1, #row - 1 do
          steps[#steps + 1] = { kind = "share", edge = edge, at = n }
        end
      end
    end
  end
  return steps
end

local function run_size_step(s, shares, panes)
  local st = docker_state()
  local row, horiz = edge_row(st, s.edge)
  if #row == 0 then return end

  if s.kind == "depth" then
    local d = st[row[1]]
    local cw, ch = client_wh(d.hwnd)
    if not cw then return end
    local base = horiz and ch or cw
    if math.abs(base - s.want) > 2 then set_depth(d.hwnd, s.edge, base, s.want) end
    return
  end

  -- share: put boundary `at` where the fractions say it belongs
  if s.at >= #row then return end
  local at = pane_dockers(panes)
  local frac, total = {}, 0
  for n, i in ipairs(row) do
    local f = at[i] and shares[at[i]]
    if not f then return end        -- an unclaimed docker in the row: leave it alone
    frac[n] = f
    total = total + f
  end
  if total <= 0 then return end

  local sz, span = row_sizes(st, row, horiz)
  local want, have = 0, 0
  for n = 1, s.at do
    want = want + span * (frac[n] / total)
    have = have + sz[n]
  end
  local delta = math.floor(want - have + 0.5)
  if math.abs(delta) > 2 then nudge_divider(st[row[s.at]].hwnd, s.edge, delta) end
end

-- What did not land. Silence would be the lie here: REAPER clamps a depth
-- without saying so, and an edge can refuse a share outright.
local function size_report(depths, shares, panes)
  local st = docker_state()
  local bad = {}
  for _, edge in ipairs(EDGE_LIST) do
    local row, horiz = edge_row(st, edge)
    if #row > 0 then
      if depths and depths[edge] then
        local got = horiz and st[row[1]].h or st[row[1]].w
        if math.abs(got - depths[edge]) > 3 then
          bad[#bad + 1] = string.format("%s depth %d, asked %d", edge, got, depths[edge])
        end
      end
      if shares and #row > 1 then
        -- Same completeness rule run_size_step uses: a row we do not wholly
        -- own is never divided, because every boundary drag takes pixels from
        -- whatever is next to it and the neighbour might be the user's Mixer.
        -- Skipping it silently would read as "shares did nothing", so say so.
        local at = pane_dockers(panes)
        local total, complete = 0, true
        for _, i in ipairs(row) do
          local f = at[i] and shares[at[i]]
          if not f then complete = false break end
          total = total + f
        end
        if not complete then
          bad[#bad + 1] = edge .. " row shared with another window, left alone"
        elseif total > 0 then
          local sz, span = row_sizes(st, row, horiz)
          if span > 0 then
            for n, i in ipairs(row) do
              local want = shares[at[i]] / total
              if math.abs(sz[n] / span - want) > 0.08 then
                bad[#bad + 1] = string.format("%s %d%%, asked %d%%",
                  at[i], math.floor(sz[n] / span * 100 + 0.5), math.floor(want * 100 + 0.5))
              end
            end
          end
        end
      end
    end
  end
  if #bad == 0 then return nil end
  return "REAPER clamped: " .. table.concat(bad, ", ")
end

-- Returns (msg, queue, stuck) exactly like apply(), and for the same reason:
-- a step is no longer only "re-dock", it may have to move that docker to
-- another edge afterwards, and that cannot be fired until the pane is in it.
-- So Spread rides the same sequencer instead of sending everything at once.
-- ── which window each SHARED docker is showing ──────────────────────────────
--
-- Spread puts panes on dockers of their own; this is the other half, for the
-- dockers that still have to share. A docker holding several windows shows one
-- and hides the rest behind tabs, and nothing in the API reports which.
--
-- ⭐ MEASURED 2026-08-29 (EON_Dock_Probe6.txt): only the FRONT pane of a tabbed
-- docker reports JS_Window_IsVisible. So the front tab IS readable — ask every
-- pane and take the one that says yes. That is the whole trick.
--
-- ⚠️ Fires DockWindowActivate AND JS_Window_SetForeground, foreground last.
-- The aiming probe measured DockWindowActivate as a miss for reaching into a
-- docker and foreground as the hit; this is the same reach, so it leans on the
-- one that was proven and keeps the other as the polite first ask.
-- ⚠️ Steals focus by construction, exactly like the edge push — button only,
-- never a tick.
-- ⚠️ Skips single-pane dockers on save, so a docker that is alone today cannot
-- leave a stale answer behind for whatever shares it tomorrow.
local function docker_tabs(mode)
  local st, n, miss = docker_state(), 0, 0
  for idx = 0, 15 do
    -- st[].vis is the measured "holds something" test (see docker_state).
    local dh = st[idx] and st[idx].vis and st[idx].hwnd
    local panes = {}
    if dh then
      local cnt, list = reaper.JS_Window_ListAllChild(dh)
      if cnt and cnt > 0 then
        for tok in (list .. ","):gmatch("(.-),") do
          local a = tonumber(tok)
          local h = a and reaper.JS_Window_HandleFromAddress(a)
          if h and reaper.JS_Window_GetParent(h) == dh
             and reaper.JS_Window_GetClassName(h) ~= "WDLTabCtrl" then
            panes[#panes + 1] = h
          end
        end
      end
    end
    if #panes > 1 then
      if mode == "save" then
        for _, h in ipairs(panes) do
          if reaper.JS_Window_IsVisible(h) then
            reaper.SetExtState("EON_DockView", "tab_" .. idx,
                               reaper.JS_Window_GetTitle(h) or "", true)
            n = n + 1
            break
          end
        end
      else
        local want = reaper.GetExtState("EON_DockView", "tab_" .. idx)
        if want ~= "" then
          local hit = false
          for _, h in ipairs(panes) do
            if (reaper.JS_Window_GetTitle(h) or "") == want then
              reaper.DockWindowActivate(h)
              reaper.JS_Window_SetForeground(h)
              n, hit = n + 1, true
              break
            end
          end
          if not hit then miss = miss + 1 end
        end
      end
    end
  end
  if mode == "save" then
    return n > 0 and ("remembered the front tab in " .. n .. " shared docker(s)")
                  or "nothing is sharing a docker — no tabs to remember"
  end
  if n == 0 and miss == 0 then
    return "no tabs remembered yet — press Remember tabs first"
  end
  return "fronted " .. n .. " docker(s)"
       .. (miss > 0 and (", " .. miss .. " remembered window(s) are not open") or "")
end

-- ── the docker tab strip itself ─────────────────────────────────────────────
--
-- REAPER's own answer is Preferences ▸ Appearance ▸ "Hide docker tabs when
-- single window and smaller than: N pixels", toggled by action 41691 and
-- stored in reaper.ini as `dockcompactsingle`.
--
-- ⭐ MEASURED 2026-08-29 (EON_Dock_Probe6.txt), two things the label does not
-- say. It only ever fires on a docker holding ONE window. And it does not
-- remove the strip — below the threshold REAPER swaps the tab for a ~6px
-- handle. All four of the user's live dockers showed exactly that: a 6px
-- WDLTabCtrl, horizontal under the ReaImGui panes, VERTICAL down the left of
-- the gfx panes. Any hide has to work out which side it is on.
--
-- So a docker that SHARES keeps a real tab strip no setting will touch. That
-- is the gap strip_hide fills.
local DOCK_COMPACT_ACTION = 41691

-- Threshold in pixels, or nil when the config var cannot be reached from Lua.
local function compact_px()
  -- Both, not just the getter: the popup only offers "set to always" when this
  -- returns a number, so a readable-but-unwritable var would hand the user a
  -- button that throws. Same guard the dockpos pair uses above.
  if not (reaper.SNM_GetIntConfigVar and reaper.SNM_SetIntConfigVar) then return nil end
  local v = reaper.SNM_GetIntConfigVar("dockcompactsingle", -666)
  return v ~= -666 and v or nil
end

-- ⚠️ Does NOT stick. REAPER re-lays-out its dockers on resize, on edge change
-- and plenty else, and puts the strip back. Pressing again is the fix; making
-- it permanent needs code sitting in the window message stream, which is a
-- script's hard limit and the extension's job.
-- ⚠️ On a SHARED docker this removes the only way to switch between the windows
-- in it. Remember/Restore tabs is the way back, which is why they are neighbours.
local function strip_hide(shared_only)
  local st, hid, grew, left = docker_state(), 0, 0, 0
  for idx = 0, 15 do
    local D = st[idx]
    -- ⚠️ D.w only exists when docker_state's JS_Window_GetRect succeeded — it
    -- sets hwnd and vis unconditionally but the rect only on success. Without
    -- this every side test and growth sum below is arithmetic on nil.
    local dh = D and D.vis and D.w and D.hwnd
    if dh then
      local panes, strip = {}, nil
      local cnt, list = reaper.JS_Window_ListAllChild(dh)
      if cnt and cnt > 0 then
        for tok in (list .. ","):gmatch("(.-),") do
          local a = tonumber(tok)
          local h = a and reaper.JS_Window_HandleFromAddress(a)
          if h and reaper.JS_Window_GetParent(h) == dh then
            if reaper.JS_Window_GetClassName(h) == "WDLTabCtrl" then strip = strip or h
            else panes[#panes + 1] = h end
          end
        end
      end
      if strip and reaper.JS_Window_IsVisible(strip) and #panes > 0 then
        if shared_only and #panes < 2 then
          left = left + 1
        else
          local ok, sl, stp, sr, sb = reaper.JS_Window_GetRect(strip)
          if ok then
            local sw, sh = sr - sl, sb - stp
            -- Which edge does it hug? Full height means a vertical sliver.
            local side
            if sh >= D.h - 6 then
              side = (sl - D.x) <= ((D.x + D.w) - sr) and "left" or "right"
            else
              side = (stp - D.y) <= ((D.y + D.h) - sb) and "top" or "bottom"
            end
            reaper.JS_Window_Show(strip, "HIDE")
            hid = hid + 1
            for _, p in ipairs(panes) do
              local pok, pl, pt, pr, pb = reaper.JS_Window_GetRect(p)
              if pok then
                local touch =
                  (side == "bottom" and math.abs(((D.y + D.h) - pb) - sh) <= 3) or
                  (side == "top"    and math.abs((pt - D.y) - sh) <= 3) or
                  (side == "left"   and math.abs((pl - D.x) - sw) <= 3) or
                  (side == "right"  and math.abs(((D.x + D.w) - pr) - sw) <= 3)
                if touch then
                  local x, y = pl - D.x, pt - D.y
                  local w, h = pr - pl, pb - pt
                  if     side == "bottom" then h = h + sh
                  elseif side == "top"    then y = y - sh; h = h + sh
                  elseif side == "left"   then x = x - sw; w = w + sw
                  elseif side == "right"  then w = w + sw end
                  reaper.JS_Window_SetPosition(p, x, y, w, h)
                  grew = grew + 1
                end
              end
            end
          end
        end
      end
    end
  end
  if hid == 0 then
    return left > 0 and "nothing shared right now — REAPER already compacted the rest"
                     or "no tab strips showing"
  end
  return ("hid %d strip(s), grew %d pane(s)%s — until REAPER lays out again")
    :format(hid, grew, left > 0 and (", left %d single-window one(s) alone"):format(left) or "")
end

-- Put every strip back and make REAPER re-run its own layout over the panes.
local function strip_show()
  local st, n = docker_state(), 0
  for idx = 0, 15 do
    local dh = st[idx] and st[idx].vis and st[idx].hwnd
    if dh then
      local cnt, list = reaper.JS_Window_ListAllChild(dh)
      if cnt and cnt > 0 then
        for tok in (list .. ","):gmatch("(.-),") do
          local a = tonumber(tok)
          local h = a and reaper.JS_Window_HandleFromAddress(a)
          if h and reaper.JS_Window_GetParent(h) == dh
             and reaper.JS_Window_GetClassName(h) == "WDLTabCtrl"
             and not reaper.JS_Window_IsVisible(h) then
            reaper.JS_Window_Show(h, "SHOWNA"); n = n + 1
          end
        end
      end
      -- One-pixel nudge: cheaper and safer than re-deriving every pane rect.
      local D = st[idx]
      if D.w and D.h then
        reaper.JS_Window_SetPosition(dh, D.x, D.y, D.w, D.h - 1)
        reaper.JS_Window_SetPosition(dh, D.x, D.y, D.w, D.h)
      end
    end
  end
  return n > 0 and ("put %d strip(s) back"):format(n) or "no hidden strips"
end

local function spread_panes()
  local panes = reaper.GetExtState("EON_DockView", "panes")
  if panes == "" then panes = LAYOUTS[1].panes end
  local moves, stuck = plan_moves(panes, nil, nil)
  if #moves == 0 then
    return report({}, stuck, "already on separate dockers")
  end
  return nil, moves, stuck
end

-- Bridge relay fast-path: Swing's wordmark menu already picked a layout
-- (Swing_Kit_Bridge stamps ExtState EON_DockView/pick on GS_DOCK_LAYOUT_REQ,
-- then runs this script) — apply that pick directly, no UI of any kind.
local staged = tonumber(reaper.GetExtState("EON_DockView", "pick")) or 0
reaper.DeleteExtState("EON_DockView", "pick", false)
if staged >= 1 and LAYOUTS[staged] then
  apply(staged)
  return
end

-- ── Fallback: the original native text menu (no ReaImGui installed) ─────────
if not reaper.ImGui_GetBuiltinPath then
  local cur = reaper.GetExtState("EON_DockView", "layout")
  if cur == "" then cur = LAYOUTS[1].name end
  local items = {}
  for i, L in ipairs(LAYOUTS) do
    items[i] = (L.name == cur and "!" or "") .. L.name
  end
  local x, y = reaper.GetMousePosition()
  gfx.init("EON Dock Layout", 0, 0, 0, x, y)
  local choice = gfx.showmenu(table.concat(items, "|"))
  gfx.quit()
  if choice and choice >= 1 then apply(choice) end
  return
end

-- ── ReaImGui card picker ────────────────────────────────────────────────────
package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.9"

local ctx = ImGui.CreateContext("EON Dock Layout")

-- card geometry
-- ⚠️ CH must clear the ACTIVE line, not just the name. The name is drawn at
-- GH+13 and ACTIVE at GH+27 (= y+93), and a text row is ~14px — so the content
-- runs to y+107. At the old CH of 100 the badge spilled 7px past the card's own
-- border and collided with the footer row below it, which is only visible on
-- whichever card happens to be active.
local CW, CH   = 132, 110      -- card
local GW, GH   = 118, 66       -- wireframe area inside the card
local CARDS_PER_ROW = 4        -- wrap point; the layout list grows past one strip
local mx, my   = reaper.GetMousePosition()

-- palette (0xRRGGBBAA)
local C_CARD   = 0x22252BFF
local C_CARDHV = 0x282C33FF
local C_CARDAC = 0x233036FF
local C_BORD   = 0x3A3E46FF
local C_BORDAC = 0x35B6C9FF
local C_MON    = 0x191C20FF
local C_MONBR  = 0x4D525AFF
local C_ARR    = 0x2C3138FF
local C_ON     = 0x8FD6E2FF    -- included pane ink
local C_ONAC   = 0x35D5EAFF    -- included ink on the active card
local C_ONBG   = 0x2B3138FF
local C_OFF    = 0x4A4E55FF    -- excluded pane (ghost outline)
local C_TXT    = 0xD5D8DDFF
local C_TXTAC  = 0x9FE8F2FF

-- type-specific inner detail, drawn inside a block rect
local function pane_detail(dl, key, x, y, w, h, col)
  if key == "swing" then                       -- pad dots, 3x3
    local dw, dh = w / 5.4, h / 5.4
    for r = 0, 2 do for c = 0, 2 do
      local px = x + w * (0.14 + c * 0.30)
      local py = y + h * (0.14 + r * 0.30)
      ImGui.DrawList_AddRectFilled(dl, px, py, px + dw, py + dh, col)
    end end
  elseif key == "steppa" then                  -- lane stubs + lines
    for r = 0, 2 do
      local py = y + h * (0.20 + r * 0.28)
      ImGui.DrawList_AddRectFilled(dl, x + w * 0.10, py, x + w * 0.30, py + h * 0.12, col)
      ImGui.DrawList_AddRectFilled(dl, x + w * 0.38, py + h * 0.03, x + w * 0.92, py + h * 0.09, col)
    end
  elseif key == "browser" then                 -- list lines
    for r = 0, 3 do
      local py = y + h * (0.12 + r * 0.22)
      ImGui.DrawList_AddRectFilled(dl, x + w * 0.20, py, x + w * 0.80, py + h * 0.05, col)
    end
  else                                         -- padfx: knobs
    for r = 0, 2 do
      local cy = y + h * (0.20 + r * 0.30)
      ImGui.DrawList_AddCircleFilled(dl, x + w * 0.5, cy, math.min(w, h) * 0.14, col)
    end
  end
end

-- one wireframe: monitor + arrange + pane blocks on the edges the PLAN
-- resolves. Panes sharing one docker collapse into a tabbed slot (nubs along
-- the slot's bottom, REAPER-style); panes that will float draw as lifted
-- mini windows over the arrange. Ghosts (excluded panes) keep their
-- conventional edge and never share — they have no landing.
-- `tint` (a template's brand accent, or nil) replaces the default pane ink so
-- the templates read as their own family at a glance rather than as two more
-- cyan cards in the row.
local function draw_glyph(dl, x, y, active, panes_set, plan, tint)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + GW, y + GH, C_MON, 2)
  ImGui.DrawList_AddRect(dl, x, y, x + GW, y + GH, C_MONBR, 2)

  local by_edge = { left = {}, right = {}, top = {}, bottom = {} }
  local floats = {}
  for _, p in ipairs(PANES) do
    local on = panes_set[p.key] or false
    local t = on and plan[p.key] or nil
    local edge = t and t.edge or p.def
    -- The four bands above are the only edges there are. A stored Custom
    -- arrangement carrying anything else -- a hand-edited custom_edges, a
    -- half-written save -- would look up a band that does not exist and take
    -- the picker down on every frame it draws. Fall back to the pane's
    -- conventional edge instead: wrong on the card beats no card at all.
    if edge ~= "float" and not by_edge[edge] then edge = p.def end
    if edge == "float" then
      floats[#floats + 1] = { key = p.key, on = on }
    else
      local slots = by_edge[edge]
      local slot
      if t and t.idx then
        for _, s in ipairs(slots) do
          if s.idx == t.idx then slot = s; break end
        end
      end
      if slot then
        slot.panes[#slot.panes + 1] = { key = p.key, on = on }
      else
        slots[#slots + 1] = { idx = t and t.idx or nil,
                              panes = { { key = p.key, on = on } } }
      end
    end
  end

  -- ⚠️⚠️ DO NOT sort these bands by docker index. That was tried on 2026-08-27
  -- to make a template's `order` visible, and it made the card LIE: measured on
  -- the user's rig, docker index is NOT screen position.
  --     Swing Dock  = docker 3, on screen x 436..934  (leftmost)
  --     Steppa Dock = docker 0, on screen x 940..1401 (middle)
  --     Pad FX      = docker 2,                        (rightmost)
  -- Screen order 3, 0, 2. So a band sorted by index promises an arrangement
  -- REAPER will not produce. Until ordering works by a mechanism that actually
  -- controls position, the card stays in PANES order -- arbitrary, but it
  -- claims nothing.
  local m = 3                                    -- outer margin
  local x0, y0, x1, y1 = x + m, y + m, x + GW - m, y + GH - m
  local band = { left = 0, right = 0, top = 0, bottom = 0 }
  if #by_edge.left   > 0 then band.left   = GW * 0.14 end
  if #by_edge.right  > 0 then band.right  = GW * 0.14 end
  if #by_edge.top    > 0 then band.top    = GH * 0.22 end
  if #by_edge.bottom > 0 then band.bottom = GH * 0.52 end

  -- arrange hint in whatever the bands leave over
  local ax0, ay0 = x0 + band.left + 2, y0 + band.top + 2
  local ax1, ay1 = x1 - band.right - 2, y1 - band.bottom - 2
  if ay1 > ay0 + 6 then
    for r = 0, 2 do
      local py = ay0 + 2 + r * 6
      if py + 2 < ay1 then
        ImGui.DrawList_AddRectFilled(dl, ax0 + 2, py, ax1 - 2, py + 2.5, C_ARR)
      end
    end
  end

  local ink   = tint or (active and C_ONAC or C_ON)
  local function block(p, bx0, by0, bx1, by1)
    if p.on then
      ImGui.DrawList_AddRectFilled(dl, bx0, by0, bx1, by1, C_ONBG, 1.5)
      ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, ink, 1.5)
      pane_detail(dl, p.key, bx0, by0, bx1 - bx0, by1 - by0, ink)
    else
      ImGui.DrawList_AddRect(dl, bx0, by0, bx1, by1, C_OFF, 1.5, nil, 1)
      pane_detail(dl, p.key, bx0, by0, bx1 - bx0, by1 - by0, C_OFF & 0xFFFFFF88)
    end
  end

  -- one slot = one docker: a lone pane fills it; tab-mates share it with a
  -- nub per tab (front pane's detail shown, REAPER shows one tab at a time)
  local function slot_block(slot, bx0, by0, bx1, by1)
    if #slot.panes == 1 then
      block(slot.panes[1], bx0, by0, bx1, by1)
    else
      block(slot.panes[1], bx0, by0, bx1, by1 - 4)
      for i = 1, #slot.panes do
        local nx = bx0 + (i - 1) * 9
        ImGui.DrawList_AddRectFilled(dl, nx, by1 - 3, math.min(nx + 7, bx1), by1,
                                     i == 1 and ink or C_OFF)
      end
    end
  end

  -- side bands: stack slots vertically; top/bottom bands: side by side
  local function fill_band(list, bx0, by0, bx1, by1, horiz)
    local n = #list
    if n == 0 then return end
    for i, s in ipairs(list) do
      if horiz then
        local w = (bx1 - bx0 - (n - 1) * 2) / n
        local px = bx0 + (i - 1) * (w + 2)
        slot_block(s, px, by0, px + w, by1)
      else
        local h = (by1 - by0 - (n - 1) * 2) / n
        local py = by0 + (i - 1) * (h + 2)
        slot_block(s, bx0, py, bx1, py + h)
      end
    end
  end
  fill_band(by_edge.left,   x0, y0, x0 + band.left, y1, false)
  fill_band(by_edge.right,  x1 - band.right, y0, x1, y1, false)
  fill_band(by_edge.top,    x0 + band.left + 2, y0, x1 - band.right - 2, y0 + band.top, true)
  fill_band(by_edge.bottom, x0 + band.left + 2, y1 - band.bottom, x1 - band.right - 2, y1, true)

  -- floating panes: lifted mini windows over the arrange
  for i, p in ipairs(floats) do
    local fw = (ax1 - ax0) * 0.42
    local fh = math.max((ay1 - ay0) * 0.62, 9)
    local fx = ax0 + 4 + (i - 1) * (fw * 0.55)
    local fy = ay0 + 2 + (i - 1) * 4
    ImGui.DrawList_AddRectFilled(dl, fx + 2, fy + 2, fx + fw + 2, fy + fh + 2, 0x00000066, 1.5)
    block(p, fx, fy, fx + fw, fy + fh)
  end
end

local function draw_card(i, L, cur, plan)
  local active = (L.name == cur)
  local cx, cy = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, "##lay" .. i, CW, CH)
  local hovered = ImGui.IsItemHovered(ctx)
  local clicked = ImGui.IsItemClicked(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)

  local bg = active and C_CARDAC or (hovered and C_CARDHV or C_CARD)
  ImGui.DrawList_AddRectFilled(dl, cx, cy, cx + CW, cy + CH, bg, 4)
  ImGui.DrawList_AddRect(dl, cx, cy, cx + CW, cy + CH,
                         (L.tint and (active or hovered) and L.tint)
                         or (active and C_BORDAC or (hovered and 0x5A5F68FF or C_BORD)), 4)

  local set = {}
  for k in L.panes:gmatch("[^,]+") do set[k] = true end
  draw_glyph(dl, cx + (CW - GW) / 2, cy + 7, active, set, plan, L.tint)

  -- Template marker: a small dot top-right. Templates are the only cards that
  -- MOVE things, and that difference has to be visible before the click, not
  -- explained after it. The tooltip carries the rest.
  if L.edges then
    ImGui.DrawList_AddCircleFilled(dl, cx + CW - 9, cy + 9, 3,
                                   L.tint or (active and C_ONAC or C_BORDAC))
  end
  if hovered then
    local tip = L.panes:gsub(",", " · ")
    if L.note then
      tip = L.note .. "\n" .. tip ..
            "\n\nTEMPLATE — picking this MOVES your panes onto those edges," ..
            "\nin the order shown, claiming dockers from the lowest index up." ..
            "\nAn edge with no docker falls back; REAPER owns where dockers sit."
    end
    ImGui.SetTooltip(ctx, tip)
  end

  local label = L.name
  local tw = ImGui.CalcTextSize(ctx, label)
  ImGui.DrawList_AddText(dl, cx + (CW - tw) / 2, cy + GH + 13,
                         (L.tint and (active or hovered) and L.tint)
                         or (active and C_TXTAC or C_TXT), label)
  if active then
    local at = "ACTIVE"
    local aw = ImGui.CalcTextSize(ctx, at)
    ImGui.DrawList_AddText(dl, cx + (CW - aw) / 2, cy + GH + 27, C_BORDAC, at)
  end
  return clicked
end

local picked = nil
local first  = true
local keep   = reaper.GetExtState("EON_DockView", "keep_open") == "1"
-- "Spread panes" is a tidy action, not a layout choice: it never closes the
-- picker (so you can see the cards redraw onto their new dockers) and it is
-- not remembered anywhere -- pressing it is the whole opt-in.
local spread, spread_msg, spread_msg_t = false, nil, 0
-- "save" or "load", set by the two tab buttons and consumed after End like the
-- dock-shape pair. Not remembered: pressing it is the whole opt-in.
local tabs_req = nil
-- Tab-strip actions from the Dock tabs popup: "compact", "always", "hide",
-- "hideall", "show". Consumed after End — two of them steal focus or fire a
-- REAPER action, and neither belongs mid-draw.
local strip_req = nil
-- ── the live map ────────────────────────────────────────────────────────────
-- Panel open? Remembered, like the arrange editor.
local map_open = reaper.GetExtState("EON_DockView", "map_open") == "1"
-- One drop per frame: { what = "pane:swing" | "native:mixer", idx = n } or
-- { what = ..., edge = "bottom" } for the per-edge "any free docker" slot.
-- ⚠️ Declared ABOVE draw_map because draw_map writes it. A local below its
-- reader is a nil GLOBAL, which is how the PIN gesture shipped broken.
local map_drop = nil

-- Friendlier than the internal keys, and the only place they are spelled for
-- a human.
local MAP_PANE_LABEL = {
  swing = "Swing", steppa = "Steppa", browser = "Browser", padfx = "Pad FX",
}

-- What is sitting in each docker right now. Three kinds, because three
-- different things can be done with them:
--   pane   — ours, re-seats instantly by asking it to move (send_to_docker)
--   native — REAPER's, moves by close-and-reopen through the step sequencer
--   fixed  — visible but unmovable; the MIDI editor has no ident to key on,
--            so it can only travel by moving the DOCKER it lives in
local function map_occupancy()
  live_refresh()
  local occ = {}
  local function put(idx, e)
    if idx and idx >= 0 and idx <= 15 then
      occ[idx] = occ[idx] or {}
      occ[idx][#occ[idx] + 1] = e
    end
  end
  for _, p in ipairs(PANES) do
    if live_open[p.key] then
      put(live_idx[p.key], { kind = "pane", key = p.key,
                             label = MAP_PANE_LABEL[p.key] or p.key })
    end
  end
  -- GetConfigWantsDock is the cheap way to place a native: REAPER keeps the
  -- preference in step with where the window actually is, so no window hunt
  -- and no title matching (native titles are localised).
  if reaper.APIExists("GetConfigWantsDock") then
    for _, n in ipairs(NATIVES) do
      if reaper.GetToggleCommandState(n.cmd) == 1 then
        put(reaper.GetConfigWantsDock(n.ident),
            { kind = "native", key = n.key, nat = n, label = n.label })
      end
    end
  end
  local me = reaper.MIDIEditor_GetActive()
  if me and reaper.APIExists("JS_Window_GetParent") then
    local p, guard = reaper.JS_Window_GetParent(me), 0
    while p and guard < 64 do
      if reaper.JS_Window_GetTitle(p) == "REAPER_dock" then
        put(reaper.DockIsChildOfDock(p), { kind = "fixed", label = "MIDI Editor" })
        break
      end
      p = reaper.JS_Window_GetParent(p)
      guard = guard + 1
    end
  end
  return occ
end

local MAP_EDGES = { "left", "top", "bottom", "right" }

-- ── card + bay geometry ─────────────────────────────────────────────────────
-- A BAY is one docker drawn as a console insert slot. The CARDS inside it are
-- what that docker is holding, in the same block-and-line language as the
-- layout cards above -- so a Swing card here wears the same 3x3 pad dots it
-- wears on the Full card.
local MAP_CW, MAP_CH = 66, 50           -- card
local MAP_PAD        = 5                -- bay inner padding
local MAP_BH         = MAP_CH + 20      -- bay: card, plus the number strip
local MAP_BMIN       = MAP_CW + MAP_PAD * 2
local MAP_PER_ROW    = 6                -- wrap: an edge can hold all sixteen

-- ⚠️ Where the mouse went DOWN. BeginDragDropSource only fires once the drag
-- is under way, by which point the cursor has left the card that was grabbed --
-- so the press position picks the card, never the live cursor.
local map_grab_x, map_grab_y = 0, 0

-- Glyphs for REAPER's own windows. Not portraits: just enough to tell them
-- apart at 66px, and most of them genuinely are lists.
local function native_detail(dl, key, x, y, w, h, col)
  if key == "mixer" then                          -- fader strips
    for c = 0, 3 do
      local px = x + w * (0.13 + c * 0.22)
      ImGui.DrawList_AddRectFilled(dl, px, y + h * 0.16, px + w * 0.09, y + h * 0.84, col)
    end
  elseif key == "bigclock" then                   -- a face
    ImGui.DrawList_AddCircleFilled(dl, x + w * 0.5, y + h * 0.5, math.min(w, h) * 0.34, col)
  elseif key == "navigator" then                  -- viewport inside the project
    ImGui.DrawList_AddRect(dl, x + w * 0.10, y + h * 0.20, x + w * 0.90, y + h * 0.80, col, 1)
    ImGui.DrawList_AddRectFilled(dl, x + w * 0.18, y + h * 0.30, x + w * 0.50, y + h * 0.70, col)
  elseif key == "fxbrowser" then                  -- stacked plugin slots
    for r = 0, 2 do
      local py = y + h * (0.16 + r * 0.28)
      ImGui.DrawList_AddRect(dl, x + w * 0.16, py, x + w * 0.84, py + h * 0.18, col, 1)
    end
  else                                            -- list rows
    for r = 0, 3 do
      local py = y + h * (0.14 + r * 0.22)
      ImGui.DrawList_AddRectFilled(dl, x + w * 0.14, py, x + w * 0.86, py + h * 0.07, col)
    end
  end
end

-- Trim to the card rather than let AddText run past its border: there is no
-- clip rect around a DrawList call, so an over-long name would print across
-- the bay and into the next one.
local function map_fit(label)
  local s = label
  if ImGui.CalcTextSize(ctx, s) <= MAP_CW - 6 then return s end
  while #s > 1 and ImGui.CalcTextSize(ctx, s .. "…") > MAP_CW - 6 do
    s = s:sub(1, #s - 1)
  end
  return s .. "…"
end

local function map_card(dl, e, x, y, lifted)
  local bg, bd, ink = C_CARD, C_BORD, C_ON
  if lifted then bg, bd, ink = C_CARDAC, C_BORDAC, C_ONAC end
  -- The MIDI editor has no ident, so it cannot be picked up. Drawn as a ghost
  -- so it is visibly present but visibly not a card you can take.
  if e.kind == "fixed" then bg, bd, ink = C_MON, C_BORD, C_OFF end

  ImGui.DrawList_AddRectFilled(dl, x, y, x + MAP_CW, y + MAP_CH, bg, 3)
  ImGui.DrawList_AddRect(dl, x, y, x + MAP_CW, y + MAP_CH, bd, 3)

  local gx, gy, gw, gh = x + 5, y + 5, MAP_CW - 10, 25
  ImGui.DrawList_AddRectFilled(dl, gx, gy, gx + gw, gy + gh, C_ONBG, 2)
  if e.kind == "pane" then pane_detail(dl, e.key, gx, gy, gw, gh, ink)
  else                     native_detail(dl, e.key or "", gx, gy, gw, gh, ink) end

  local s  = map_fit(e.label)
  local tw = ImGui.CalcTextSize(ctx, s)
  ImGui.DrawList_AddText(dl, x + (MAP_CW - tw) / 2, y + MAP_CH - 16,
                         e.kind == "fixed" and C_OFF or C_TXT, s)
end

-- One bay. `idx` nil means the "+ new" bay for `edge`, which resolves to a
-- free docker at drop time rather than naming one now.
local function draw_bay(dl, id, list, idx, edge)
  local n  = list and #list or 0
  local bw = math.max(MAP_BMIN, n * (MAP_CW + 4) - 4 + MAP_PAD * 2)
  local bx, by = ImGui.GetCursorScreenPos(ctx)

  -- ONE item for the whole bay, serving as both drag source and drop target.
  -- Cards are DrawList only: nesting real items inside the bay's item would
  -- put two overlapping hit boxes on the same pixels, and ImGui gives that to
  -- whichever it feels like.
  ImGui.InvisibleButton(ctx, "##bay" .. id, bw, MAP_BH)
  local hovered = ImGui.IsItemHovered(ctx)
  if ImGui.IsItemActivated(ctx) then
    map_grab_x, map_grab_y = ImGui.GetMousePos(ctx)
  end

  local bg = idx and C_MON or C_ARR
  ImGui.DrawList_AddRectFilled(dl, bx, by, bx + bw, by + MAP_BH, bg, 4)
  ImGui.DrawList_AddRect(dl, bx, by, bx + bw, by + MAP_BH,
                         hovered and C_BORDAC or C_MONBR, 4)

  -- Which card is under a given point? Also the geometry the cards draw at.
  local function card_at(px, py)
    for k = 1, n do
      local cx = bx + MAP_PAD + (k - 1) * (MAP_CW + 4)
      local cy = by + MAP_PAD
      if px >= cx and px <= cx + MAP_CW and py >= cy and py <= cy + MAP_CH then
        return k
      end
    end
  end

  local grabbed = hovered and ImGui.IsItemActive(ctx) and card_at(map_grab_x, map_grab_y)
  for k = 1, n do
    map_card(dl, list[k], bx + MAP_PAD + (k - 1) * (MAP_CW + 4), by + MAP_PAD,
             grabbed == k)
  end

  local tag = idx and ("dock " .. idx) or ("+ new on " .. edge)
  ImGui.DrawList_AddText(dl, bx + MAP_PAD, by + MAP_BH - 15,
                         idx and C_TXT or C_OFF, tag)
  if n == 0 and idx then
    ImGui.DrawList_AddText(dl, bx + MAP_PAD, by + MAP_PAD + 16, C_OFF, "empty")
  end

  -- Source: the card the press landed on, if it is one that can move.
  if n > 0 and ImGui.BeginDragDropSource(ctx) then
    local k = card_at(map_grab_x, map_grab_y)
    local e = k and list[k]
    if e and e.kind ~= "fixed" then
      ImGui.SetDragDropPayload(ctx, "EON_DOCKCHIP", e.kind .. ":" .. e.key)
      ImGui.TextDisabled(ctx, e.label)
    else
      -- Still has to publish something or the drag reads as a live one that
      -- every bay will accept.
      ImGui.SetDragDropPayload(ctx, "EON_DOCKCHIP", "")
      ImGui.TextDisabled(ctx, e and "can't move the MIDI editor" or "—")
    end
    ImGui.EndDragDropSource(ctx)
  end

  if ImGui.BeginDragDropTarget(ctx) then
    local ok, payload = ImGui.AcceptDragDropPayload(ctx, "EON_DOCKCHIP")
    if ok and payload and payload ~= "" then
      map_drop = idx and { what = payload, idx = idx }
                      or { what = payload, edge = edge }
    end
    ImGui.EndDragDropTarget(ctx)
  end

  if hovered and n > 0 then
    local k = card_at(ImGui.GetMousePos(ctx))
    local e = k and list[k]
    if e and e.kind == "native" then
      ImGui.SetTooltip(ctx,
        "One of REAPER's own. Moving it means closing and reopening it,\n" ..
        "so it blinks — the only way a script can relocate a window it\n" ..
        "does not own.")
    elseif e and e.kind == "fixed" then
      ImGui.SetTooltip(ctx,
        "The MIDI editor has no window identifier, so it cannot be\n" ..
        "re-seated. It travels by moving this whole dock instead.")
    end
  end
end

-- Rebuilt every frame off live state, so moving something by hand in REAPER
-- makes the map follow. live_refresh throttles itself to 4Hz, which is what
-- keeps that cheap.
local function draw_map()
  local st, occ = docker_state(), map_occupancy()
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.TextDisabled(ctx,
    "Drag a card into another bay. Ours move at once; REAPER's own blink.")

  for _, edge in ipairs(MAP_EDGES) do
    local row = {}
    for i = 0, 15 do
      if st[i] and st[i].vis and st[i].pos == edge then row[#row + 1] = i end
    end
    -- Screen order, so the map reads the way the screen does.
    local horiz = (edge == "bottom" or edge == "top")
    table.sort(row, function(a, b)
      local A, B = st[a], st[b]
      if not (A and B and A.w and B.w) then return a < b end
      if horiz then return A.x < B.x end
      return A.y < B.y
    end)

    ImGui.Separator(ctx)
    ImGui.TextDisabled(ctx, edge:upper())
    local col = 0
    for _, i in ipairs(row) do
      if col > 0 and col % MAP_PER_ROW ~= 0 then ImGui.SameLine(ctx) end
      draw_bay(dl, "d" .. i, occ[i], i, edge)
      col = col + 1
    end
    if col > 0 and col % MAP_PER_ROW ~= 0 then ImGui.SameLine(ctx) end
    draw_bay(dl, "n" .. edge, nil, nil, edge)
  end
end
local save_shape, undo_shape = false, false
-- The ordering queue, walked one step per frame by the loop below.
local seq = nil
-- The sizing pass, which runs once the moves are done. Frames between drags:
-- REAPER re-lays the whole edge after each one, and the next step measures
-- what the last one actually achieved -- so measuring too early would build
-- the next drag out of stale numbers.
local szq = nil
local SIZE_SETTLE = 3
-- Editor panel open? Remembered, so someone who lives in it does not reopen
-- it every launch.
local arrange_open = reaper.GetExtState("EON_DockView", "arrange_open") == "1"
-- Per step. Generous on purpose: a gfx pane's re-dock hands its captured
-- canvas back to REAPER's float and re-acquires it, and the Browser's dock
-- home is read from a file on a 1s throttle, so an ack can legitimately be
-- slow. Better a beat of waiting than an order that gives up half way.
local SEQ_STEP_TIMEOUT = 2.5

local function loop()
  if first then
    ImGui.SetNextWindowPos(ctx, mx - 40, my - 20, ImGui.Cond_Once)
    first = false
  end
  local flags = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_AlwaysAutoResize
              | ImGui.WindowFlags_TopMost | ImGui.WindowFlags_NoDocking
  local visible, open = ImGui.Begin(ctx, "EON Dock Layout", true, flags)
  if visible then
    local cur = reaper.GetExtState("EON_DockView", "layout")
    if cur == "" then cur = LAYOUTS[1].name end
    -- Four to a row: six cards in one strip made the picker wider than most
    -- of the screens it pops up over, and the list only grows from here.
    local base = build_plan()
    for i, L in ipairs(LAYOUTS) do
      if (i - 1) % CARDS_PER_ROW ~= 0 then ImGui.SameLine(ctx) end
      -- A template card draws ITS OWN placement, not the current arrangement.
      -- The drawing is a promise about what the click does, and for a template
      -- the click changes where things are.
      -- Seated the same way the apply will seat it, or the card would promise
      -- a row the click does not deliver — the drawing is the promise.
      if draw_card(i, L, cur,
            L.edges and seat_by_order(build_plan(true, L.edges, L.order), L.order)
                     or base) then picked = i end
    end
    -- ── Custom arrangement editor ─────────────────────────────────────────
    -- One row per pane: move it up or down to change where it sits, pick the
    -- edge it lives on. TOP TO BOTTOM HERE IS LEFT TO RIGHT on the edge --
    -- because the row is delivered by re-docking in this sequence, and a
    -- re-dock appends. Every edit saves immediately; there is no OK button to
    -- forget to press, and the Custom card redraws under you as you go.
    if map_open then
      ImGui.Separator(ctx)
      draw_map()
    end
    if arrange_open then
      ImGui.Separator(ctx)
      ImGui.TextDisabled(ctx, "Custom arrangement — top to bottom is left to right on each edge")
      local ord = {}
      for k in CUSTOM.order:gmatch("[^,]+") do ord[#ord + 1] = k end
      -- Any pane the stored order forgot still gets a row, or it would be
      -- unreachable in the editor while still being placed by the resolver.
      for _, p in ipairs(PANES) do
        local seen = false
        for _, k in ipairs(ord) do if k == p.key then seen = true end end
        if not seen then ord[#ord + 1] = p.key end
      end

      -- How many panes sit on each edge. Decides two things: which depth
      -- sliders are worth showing, and whether a pane's share means anything
      -- (a pane alone on its edge takes all of it, whatever a slider says).
      local on_edge = {}
      for _, p in ipairs(PANES) do
        local e = CUSTOM.edges[p.key] or p.def
        on_edge[e] = (on_edge[e] or 0) + 1
      end

      -- The swap is APPLIED AFTER the loop. Swapping mid-iteration would move
      -- the same pane twice in one frame.
      local swap, dirty = nil, false
      for i, key in ipairs(ord) do
        ImGui.PushID(ctx, "arr" .. i)
        if ImGui.Button(ctx, "\226\150\178", 24, 20) and i > 1 then swap = { i, i - 1 } end
        ImGui.SameLine(ctx)
        if ImGui.Button(ctx, "\226\150\188", 24, 20) and i < #ord then swap = { i, i + 1 } end
        ImGui.SameLine(ctx)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, string.format("%d.", i))
        ImGui.SameLine(ctx)
        ImGui.TextColored(ctx, CUSTOM.tint, key)
        ImGui.SameLine(ctx, 132)
        ImGui.SetNextItemWidth(ctx, 92)
        local cur_edge = CUSTOM.edges[key] or "bottom"
        if ImGui.BeginCombo(ctx, "##edge", cur_edge) then
          for _, e in ipairs(EDGE_CHOICES) do
            if ImGui.Selectable(ctx, e, e == cur_edge) then
              CUSTOM.edges[key] = e
              dirty = true
            end
          end
          ImGui.EndCombo(ctx)
        end
        -- Share of that edge. Only offered where it can do something: with one
        -- pane on an edge there is no boundary to move, and a slider there
        -- would be a control that silently does nothing.
        ImGui.SameLine(ctx, 236)
        if (on_edge[cur_edge] or 0) > 1 then
          ImGui.SetNextItemWidth(ctx, 108)
          local ch, v = ImGui.SliderInt(ctx, "##share", CUSTOM.shares[key] or 33,
                                        5, 90, "%d%%")
          if ch then
            CUSTOM.shares[key] = v
            dirty = true
          end
        else
          ImGui.AlignTextToFramePadding(ctx)
          ImGui.TextDisabled(ctx, "whole edge")
        end
        ImGui.PopID(ctx)
      end
      if swap then
        ord[swap[1]], ord[swap[2]] = ord[swap[2]], ord[swap[1]]
        dirty = true
      end
      CUSTOM.order = table.concat(ord, ",")

      -- ⛔ DEPTH IS PER EDGE. Measured on a three-docker bottom edge: resizing
      -- one resized all three. So this is a list of EDGES, not of panes, and
      -- only the edges something actually sits on are worth a slider.
      ImGui.Spacing(ctx)
      ImGui.TextDisabled(ctx, "Depth — one per edge, because every pane on an edge shares it")
      for _, e in ipairs(EDGE_CHOICES) do
        if on_edge[e] then
          local horiz = (e == "bottom" or e == "top")
          ImGui.PushID(ctx, "dep" .. e)
          ImGui.AlignTextToFramePadding(ctx)
          ImGui.Text(ctx, e)
          ImGui.SameLine(ctx, 132)
          ImGui.SetNextItemWidth(ctx, 212)
          local ch, v = ImGui.SliderInt(ctx, "##depth",
            CUSTOM.depths[e] or (horiz and 400 or 380), 80, 1200,
            horiz and "%d px tall" or "%d px wide")
          if ch then
            CUSTOM.depths[e] = v
            dirty = true
          end
          ImGui.PopID(ctx)
        end
      end

      -- ── REAPER's own windows ────────────────────────────────────────────
      -- Opt-in, and only here. A preset must never rearrange windows the user
      -- does not think of as ours.
      -- ⚠️ Adding one to an edge our panes share means that row is no longer
      -- wholly ours, so the share sliders stop dividing it -- the sizing pass
      -- says so in the footer rather than quietly ignoring them.
      ImGui.Spacing(ctx)
      ImGui.TextDisabled(ctx, "REAPER's own windows — optional, and only on this card")
      for _, n in ipairs(NATIVES) do
        ImGui.PushID(ctx, "nat" .. n.key)
        local rv, v = ImGui.Checkbox(ctx, n.label, CUSTOM.natives[n.key] ~= nil)
        if rv then
          CUSTOM.natives[n.key] = v and (CUSTOM.natives[n.key] or "bottom") or nil
          dirty = true
        end
        if CUSTOM.natives[n.key] then
          ImGui.SameLine(ctx, 236)
          ImGui.SetNextItemWidth(ctx, 108)
          local cur = CUSTOM.natives[n.key]
          if ImGui.BeginCombo(ctx, "##nedge", cur) then
            for _, e in ipairs(EDGE_CHOICES) do
              if ImGui.Selectable(ctx, e, e == cur) then
                CUSTOM.natives[n.key] = e
                dirty = true
              end
            end
            ImGui.EndCombo(ctx)
          end
        end
        ImGui.PopID(ctx)
      end

      if dirty then
        custom_save(CUSTOM.edges, CUSTOM.order, CUSTOM.depths, CUSTOM.shares,
                    CUSTOM.natives)
      end
      ImGui.TextDisabled(ctx,
        "an edge with no docker gets an empty one moved there; REAPER clamps sizes silently, so the footer says what actually landed")
      ImGui.Separator(ctx)
    end

    local rv, kv = ImGui.Checkbox(ctx, "Keep open", keep)
    if rv then
      keep = kv
      reaper.SetExtState("EON_DockView", "keep_open", kv and "1" or "0", true)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, arrange_open and "Arrange -" or "Arrange +") then
      arrange_open = not arrange_open
      reaper.SetExtState("EON_DockView", "arrange_open", arrange_open and "1" or "0", true)
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "Edit the Custom card: which edge each pane lives on, the order\n" ..
        "they sit in, how much of the edge each one gets, and how deep\n" ..
        "each edge is. Then click Custom to apply it.")
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Spread panes") then spread = true end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "Put this layout's panes on separate dockers instead of tabbing\n" ..
        "them together. Open panes move now; closed ones land there next\n" ..
        "time. Which edge a docker sits on stays REAPER's own setting, so\n" ..
        "with fewer dockers than panes some still have to share.")
    end
    -- The other half of Spread: for the dockers that DO still share, remember
    -- which window each one is showing and put them all back in one press.
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Remember tabs") then tabs_req = "save" end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "For dockers holding more than one window: note which one each\n" ..
        "is showing right now. Only shared dockers count — one alone on\n" ..
        "its docker has no tab to remember.")
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Restore tabs") then tabs_req = "load" end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "Bring every shared docker back to the window you remembered.\n" ..
        "Takes focus while it works, the same way applying a layout does.")
    end
    -- ── Dock tabs ────────────────────────────────────────────────────────────
    -- Grouped in a popup rather than four more footer buttons: the row is
    -- already at its width, and these belong together.
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, map_open and "Map -" or "Map +") then
      map_open = not map_open
      reaper.SetExtState("EON_DockView", "map_open", map_open and "1" or "0", true)
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "Live map of what is in which dock, right now. Drag a card onto\n" ..
        "another dock to move it there. Ours move instantly; REAPER's own\n" ..
        "windows blink, because relocating one means closing and reopening.")
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "Dock tabs") then ImGui.OpenPopup(ctx, "eon_striptabs") end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx,
        "Get rid of the tab strip along a docker's edge — REAPER's own\n" ..
        "setting for the docks holding one window, and ours for the docks\n" ..
        "that share and which REAPER will not touch.")
    end
    if ImGui.BeginPopup(ctx, "eon_striptabs") then
      local on = reaper.GetToggleCommandState(DOCK_COMPACT_ACTION) == 1
      local px = compact_px()
      ImGui.TextDisabled(ctx, "REAPER's own — single-window docks only")
      local rv, nv = ImGui.Checkbox(ctx, "Compact when small and single tab", on)
      if rv and nv ~= on then strip_req = "compact" end
      if px then
        ImGui.TextDisabled(ctx, ("threshold: %d px  (a dock wider than this keeps its tab)"):format(px))
        if px < 10000 then
          if ImGui.Button(ctx, "Set threshold to always") then strip_req = "always" end
          if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx,
              "Writes 10000, which is past any real dock size — so every\n" ..
              "single-window dock is compacted whatever its size.")
          end
        end
      else
        ImGui.TextDisabled(ctx, "threshold: set it in Preferences ▸ Appearance")
      end
      ImGui.Separator(ctx)
      ImGui.TextDisabled(ctx, "Ours — the docks REAPER leaves alone")
      if ImGui.Button(ctx, "Hide tabs on shared docks") then strip_req = "hide" end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx,
          "Docks holding two or more windows keep a real tab strip that no\n" ..
          "REAPER setting removes. This hides it and gives the pane the band\n" ..
          "back.\n\nIt does NOT stick — REAPER redraws the strip next time it\n" ..
          "lays the dock out. And it takes away the only way to switch between\n" ..
          "those windows, so use Remember/Restore tabs alongside it.")
      end
      if ImGui.Button(ctx, "Hide every tab strip") then strip_req = "hideall" end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx,
          "The shared ones plus the ~6px handles REAPER leaves on the\n" ..
          "single-window docks. Reclaims the last sliver.")
      end
      if ImGui.Button(ctx, "Put every strip back") then strip_req = "show" end
      ImGui.EndPopup(ctx)
    end
    ImGui.SameLine(ctx)
    -- Both dock-shape buttons are HIDDEN unless the variable is genuinely
    -- reachable. On the build this was written against it is not (see
    -- dockpos_get), and a button that quietly does nothing is worse than no
    -- button -- it spends the user's time proving it is broken.
    if dockpos_available() then
      -- Arrange the docks by hand once (full-height left column, whatever you
      -- want), press this, and picking that layout replays the shape. Stored
      -- per layout name, so each can have its own.
      if ImGui.Button(ctx, "Save dock shape") then save_shape = true end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx,
          "Remember REAPER's current dock SHAPE for \"" .. cur .. "\" —\n" ..
          "whether the left/right docks run full height or the bottom\n" ..
          "dock spans the full width. Picking that layout restores it.\n\n" ..
          "This is one REAPER-wide setting, not a per-pane one, and the\n" ..
          "number is captured from your own arrangement rather than\n" ..
          "guessed. Needs the SWS extension.")
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "\226\134\186") then undo_shape = true end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx,
          "Put the dock SHAPE back to what it was before a template\n" ..
          "first changed it. One-shot: after this there is nothing left\n" ..
          "to undo until a template changes it again.")
      end
      ImGui.SameLine(ctx)
    end
    ImGui.TextDisabled(ctx, "· click a layout to apply · Esc closes")
    -- Own line, not SameLine: the report names every pane that moved and the
    -- window auto-resizes, so hanging it off the button made the picker jump
    -- wider. The button is a no-op often enough -- already apart, no spare
    -- dockers -- that silence would read as "it broke", and when it DOES move
    -- something on a rig whose dockers share a screen edge, saying where it
    -- went is the only way to tell that apart from doing nothing.
    if seq and seq.steps[seq.i] then
      -- Named through whatever the step actually carries. One of REAPER's own
      -- windows has no pane key, and its docker is not picked until the step
      -- runs -- a frame later than this draw -- so the number is genuinely not
      -- there yet, and the edge it is headed for is all there is to say.
      local s    = seq.steps[seq.i]
      local what = (s.nat and s.nat.label) or s.key or "?"
      local dest = s.idx and ("docker " .. s.idx) or (s.edge or "?")
      ImGui.TextDisabled(ctx, string.format("placing %d/%d: %s → %s",
        seq.i, #seq.steps, what, dest))
    elseif spread_msg and reaper.time_precise() - spread_msg_t < 6 then
      ImGui.TextDisabled(ctx, "spread: " .. spread_msg)
    end
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then open = false end
    ImGui.End(ctx)
  end
  if spread then
    spread = false
    local msg, queue, stuck = spread_panes()
    if queue then
      seq = { steps = queue, i = 1, done = {}, late = 0, stuck = stuck }
    else
      spread_msg   = msg
      spread_msg_t = reaper.time_precise()
    end
  end
  if tabs_req then
    -- After End, like every other action here: it takes focus, and doing that
    -- mid-draw fights the picker for it.
    spread_msg   = docker_tabs(tabs_req)
    spread_msg_t = reaper.time_precise()
    tabs_req     = nil
  end
  if map_drop then
    -- After End like the rest: a pane re-dock rebuilds a gfx window, and a
    -- native move hands the whole thing to the step sequencer.
    local d = map_drop
    map_drop = nil
    local kind, key = d.what:match("^(%a+):(.+)$")
    local idx = d.idx or (d.edge and free_docker_for(d.edge))
    if not idx then
      spread_msg = "no free docker on the " .. tostring(d.edge) ..
                   " edge — all sixteen are spoken for"
    elseif kind == "pane" then
      send_to_docker(key, idx, true)
      live_refresh(true)      -- the handle we had is gone; re-read before drawing
      spread_msg = (MAP_PANE_LABEL[key] or key) .. " → docker " .. idx
    elseif kind == "native" then
      local nat
      for _, n in ipairs(NATIVES) do if n.key == key then nat = n end end
      if not nat then
        spread_msg = "unknown window: " .. tostring(key)
      elseif seq then
        -- One sequence at a time; the second would race the first for dockers.
        spread_msg = "still placing the last one — try again in a moment"
      else
        seq = { steps = { { kind = "native", nat = nat, idx = idx,
                            edge = docker_edge(idx) } },
                i = 1, done = {}, late = 0, stuck = {} }
      end
    end
    spread_msg_t = reaper.time_precise()
  end
  if strip_req then
    local r = strip_req
    strip_req = nil
    if r == "compact" then
      reaper.Main_OnCommand(DOCK_COMPACT_ACTION, 0)
      local px = compact_px()
      spread_msg = "compact " ..
        (reaper.GetToggleCommandState(DOCK_COMPACT_ACTION) == 1 and "on" or "off") ..
        (px and (", threshold " .. px .. " px") or "")
    elseif r == "always" then
      -- Only offered when the var reads back, so it is writable too.
      reaper.SNM_SetIntConfigVar("dockcompactsingle", 10000)
      spread_msg = "threshold set to 10000 px — every single-window dock compacts"
    elseif r == "hide"    then spread_msg = strip_hide(true)
    elseif r == "hideall" then spread_msg = strip_hide(false)
    elseif r == "show"    then spread_msg = strip_show() end
    spread_msg_t = reaper.time_precise()
  end
  if undo_shape then
    undo_shape   = false
    spread_msg   = dockpos_restore()
    spread_msg_t = reaper.time_precise()
  end
  if save_shape then
    save_shape = false
    local nm = reaper.GetExtState("EON_DockView", "layout")
    if nm == "" then nm = LAYOUTS[1].name end
    spread_msg   = dockpos_save(nm)
    spread_msg_t = reaper.time_precise()
  end
  if picked then
    local msg, queue, stuck, sizing = apply(picked)
    picked = nil                 -- Keep open: stay a palette, arm the next pick
    -- Templates MOVE things, so they owe the same account of themselves the
    -- Spread button gives. A plain pick returns nil and says nothing.
    if msg then spread_msg, spread_msg_t = msg, reaper.time_precise() end
    if queue then
      seq = { steps = queue, i = 1, done = {}, late = 0, stuck = stuck, sizing = sizing }
    elseif sizing then
      szq = { sz = sizing, i = 1, wait = SIZE_SETTLE }
    elseif not keep then
      return                     -- picked: stop deferring, window closes with us
    end
  end

  -- ── the ordering sequencer ────────────────────────────────────────────────
  -- Visible left-to-right order is DOCKING order (measured: re-docking a pane
  -- appends it to the end of its edge's row). So the requests have to go out
  -- ONE AT A TIME, each one landed before the next is sent -- fire them
  -- together and four defer loops race, which is not an order at all.
  --
  -- The ack is the window tree: where the pane REALLY is, read back after each
  -- request. A step that never acks times out rather than wedging the queue --
  -- a pane can be closed, mid-launch, or busy handing its canvas back.
  --
  -- Each step now has two stages, and the second is what makes a layout land:
  --   "dock" -- ask the pane to move into its docker, wait until it is there
  --   "edge" -- if that docker is on the wrong screen edge, move the docker
  --
  -- The edge push MUST come second. It aims by foregrounding the pane, so the
  -- pane has to be inside the docker we mean to move before it can name it.
  if seq then
    local step = seq.steps[seq.i]
    if not step then
      local tail = (#seq.done > 0 and seq.late > 0)
        and ("  ·  " .. seq.late .. " did not confirm") or ""
      spread_msg = report(seq.done, seq.stuck or {},
        (seq.late > 0) and (seq.late .. " did not confirm") or "already arranged") .. tail
      spread_msg_t = reaper.time_precise()
      local sizing = seq.sizing
      seq = nil
      -- The pick that started this was allowed to skip its close so the loop
      -- could keep running; honour it now -- unless the sizing pass still has
      -- to run, in which case the close waits for that instead.
      if sizing then
        szq = { sz = sizing, i = 1, wait = SIZE_SETTLE }
      elseif not keep then
        return
      end
    elseif step.kind == "native" then
      -- One of REAPER's own windows. Dock_UpdateDockID only decides where it
      -- opens NEXT, so one that is already up gets closed and reopened.
      if not step.stage then
        -- ⚠️ `or`, not plain assignment: a template asks for "somewhere on this
        -- edge" and gets a free docker, but a MAP DROP names the exact docker
        -- the user let go over. Overwriting it here would silently move the
        -- window somewhere else and the drop would look broken.
        step.idx = step.idx or free_docker_for(step.edge)
        if not step.idx then
          seq.late = seq.late + 1
          seq.i = seq.i + 1
        else
          -- Read the state BEFORE firing. These are toggles: asking afterwards
          -- tells you what you just did, not what it was, and acting on that
          -- closes the window you have only this moment opened.
          -- A -1 (no toggle state reported) is treated as closed: one press,
          -- and if it was in fact open the footer will show it did not land.
          local was_open = reaper.GetToggleCommandState(step.nat.cmd) == 1
          reaper.Dock_UpdateDockID(step.nat.ident, step.idx)
          reaper.Main_OnCommand(step.nat.cmd, 0)
          step.stage = was_open and "reopen" or "edge"
          step.t = reaper.time_precise()
        end
      elseif step.stage == "reopen" then
        reaper.Main_OnCommand(step.nat.cmd, 0)   -- it was open; that closed it
        step.stage, step.t = "edge", reaper.time_precise()
      elseif docker_edge(step.idx) == step.edge then
        seq.done[#seq.done + 1] = step.nat.label .. " → " .. step.edge
        seq.i = seq.i + 1
      elseif reaper.time_precise() - step.t > SEQ_STEP_TIMEOUT then
        seq.late = seq.late + 1
        seq.i = seq.i + 1
      elseif not step.pushed then
        -- Wait, without burning the step, until the window is actually in the
        -- docker -- there is nothing to foreground until then.
        local h = docked_child(step.idx)
        if h then
          step.pushed = true
          push_edge_hwnd(h, step.edge)
        end
      end
    elseif not step.stage then
      send_to_docker(step.key, step.idx, pane_running(step.key))
      step.stage, step.t = "dock", reaper.time_precise()
    elseif step.stage == "dock" then
      -- Tested ONCE, at the hand-off: after an edge move a gfx pane rebuilds
      -- its window, and re-testing the docker through that would read a
      -- half-built pane as a pane that never arrived.
      if saved_docker(step.key) == step.idx then
        step.stage, step.t = "edge", reaper.time_precise()
      elseif reaper.time_precise() - step.t > SEQ_STEP_TIMEOUT then
        seq.late = seq.late + 1
        seq.i = seq.i + 1
      end
    elseif step.stage == "edge" then
      if not EDGE_ACTION[step.edge] or docker_edge(step.idx) == step.edge then
        seq.done[#seq.done + 1] = step.key .. " → docker " .. step.idx ..
                                  " (" .. (step.edge or "?") .. ")"
        seq.i = seq.i + 1
      elseif not step.pushed then
        step.pushed, step.t = true, reaper.time_precise()
        if not push_edge(step.key, step.edge) then
          -- Nothing to foreground -- the pane is closed, or mid-launch. Firing
          -- the action anyway would move docker 0, which belongs to somebody
          -- else, so the step is abandoned instead of aimed blind.
          seq.late = seq.late + 1
          seq.i = seq.i + 1
        end
      elseif reaper.time_precise() - step.t > SEQ_STEP_TIMEOUT then
        seq.late = seq.late + 1
        seq.i = seq.i + 1
      end
    end
  end

  -- ── the sizing pass ───────────────────────────────────────────────────────
  -- One drag per tick with frames between, because each step is built from
  -- what the previous one actually achieved. The step list is built here and
  -- not at plan time, for the same reason: only the windows know where the
  -- panes really ended up.
  if szq then
    if szq.wait > 0 then
      szq.wait = szq.wait - 1
    elseif not szq.steps then
      szq.steps = build_size_steps(szq.sz.depths, szq.sz.shares, szq.sz.panes)
      szq.wait  = SIZE_SETTLE
    elseif szq.steps[szq.i] then
      run_size_step(szq.steps[szq.i], szq.sz.shares, szq.sz.panes)
      szq.i    = szq.i + 1
      szq.wait = SIZE_SETTLE
    else
      -- Measure what actually landed. REAPER clamps a depth without a word --
      -- 5000 quietly becomes 800 -- so saying nothing here would be the lie.
      local note = size_report(szq.sz.depths, szq.sz.shares, szq.sz.panes)
      if note then
        spread_msg = (spread_msg and spread_msg ~= "")
          and (spread_msg .. "  ·  " .. note) or note
        spread_msg_t = reaper.time_precise()
      end
      szq = nil
      if not keep then return end
    end
  end

  if open then reaper.defer(loop) end
end

reaper.defer(loop)
