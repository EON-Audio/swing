-- Swing Pad FX — ImGui GUI
-- (c) EON Studios — All Rights Reserved
--
-- A standalone, dockable ReaImGui window that follows Swing's SELECTED pad and
-- shows/edits that pad's per-pad FX (EQ / Comp / Drive / Crush / Sends). Reads
-- the FX-focused pad + its live params from gmem (Swing_Media_Transfer) and
-- writes edits back via the FX action channel — the JSFX applies each like its
-- own overlay edit (recalc_fx + mark_dirty_pad: audible, undoable, persisted).
--
-- Companion to Swing_Browser.lua; shares rk_lua_core + rk_lua_widgets. Targets
-- the same instance the Browser does (gmem INSTANCE). Designed to be racked as
-- its own pane by the EON Hub, beside Swing's grid.
--
-- TYPE:   system
-- SCOPE:  project_tracks
-- INSTALLATION:
--   Actions → Show action list → ReaScript: Load → select this file, or use
--   EON_Toggle_Swing_PadFX.lua.

-- ═══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCY CHECK
-- ═══════════════════════════════════════════════════════════════════════════════
if not reaper.ImGui_GetBuiltinPath then
  -- Signal the JSFX so its "ReaImGui not installed" banner appears (same path
  -- the Browser uses). Use the canonical slot, not a literal.
  reaper.gmem_attach("Swing_Media_Transfer")
  reaper.gmem_write(2624, 1)  -- GS_REAIMGUI_MISSING
  reaper.MB(
    "Swing Pad FX requires the ReaImGui extension.\n\n"..
    "Install it from ReaPack:\n"..
    "  Extensions → ReaPack → Browse packages → search 'ReaImGui'\n\n"..
    "Then restart REAPER and try again.",
    "Swing Pad FX — Missing Dependency", 0)
  return
end
reaper.gmem_attach("Swing_Media_Transfer")
reaper.gmem_write(2624, 0)  -- clear stale GS_REAIMGUI_MISSING

local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end
local _SCRIPT_DIR = _get_script_dir()
local _sep = package.config:sub(1,1)
package.path = _SCRIPT_DIR .. _sep .. "?.lua;" ..
               reaper.ImGui_GetBuiltinPath() .. "/?.lua;" ..
               (package.path or "")
local ImGui = require 'imgui' '0.9.3.2'

local core    = require("rk_lua_core")
local widgets = require("rk_lua_widgets")
widgets.init(ImGui, core)

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════════
local SCRIPT_NAME = "EON Pad FX — Swing"
local VERSION     = "1.0"
local G           = core.GMEM
local INSTANCE    = G.INSTANCE
local GMEM_NAME   = core.GMEM_NAME

-- Compact FX layout. The interactive EQ graph owns all the EQ band params
-- (HPF/LPF + Lo/Mid/Hi-Mid/Hi freq+gain) via draggable nodes, so the only EQ knob is
-- the shared filter Q. Everything else lives in side-by-side columns so the
-- panel stays short. Ranges/defaults mirror rk_swing_ui_grid_overlay_fx.jsfx-inc.
-- EQ band params the graph reflects. Synced from gmem each frame so the curve +
-- nodes track Swing's ACTUAL values (the graph IS the EQ control now — there are
-- no EQ knobs to refresh them otherwise). RESO (filter Q) has no on-panel control
-- after the Q knob was removed; it's still read here so the HPF/LPF curve is right.
local EQ_BAND_PIDS = {
  G.FX_PID_HPF_FREQ, G.FX_PID_LPF_FREQ, G.FX_PID_RESO,
  G.FX_PID_EQ_LO, G.FX_PID_EQ_LO_FREQ,
  G.FX_PID_EQ_MID, G.FX_PID_EQ_MID_FREQ,
  G.FX_PID_EQ_MID2, G.FX_PID_EQ_MID2_FREQ,   -- v46: 4th band (hi-mid bell)
  G.FX_PID_EQ_MID_Q, G.FX_PID_EQ_MID2_Q,     -- v46: per-bell Q (wheel)
  G.FX_PID_EQ_LO_Q, G.FX_PID_EQ_HI_Q,        -- v48: shelf Q (wheel)
  G.FX_PID_EQ_HI, G.FX_PID_EQ_HI_FREQ,
}

-- Knob role (1..6) tints the cap from the active theme's role-hue row (rk_lua_theme
-- T.ROLES): 1 drive · 2 gain/output · 3 freq · 4 Q/shape · 5 dynamics · 6 time/mix.
-- Six distinct hues across the panel; Reverb borrows gain(2) purely to read apart
-- from Delay's send hue (the band has only one combined time/mix role).

-- Per-mode cap colours for COMP/DRIVE — the knob follows its selected type, 1:1
-- with the per-pad overlay (rk_swing_ui_grid_overlay_fx.jsfx-inc lines ~1001/1049).
-- Indexed by mode value (0-based). Overrides the static role hue when present.
local DRIVE_MODE_COLS = { [0] = 0xD94040FF, [1] = 0xE69926FF, [2] = 0xB38C4DFF,  -- SOFT/TUBE/TAPE
                          [3] = 0xE6338CFF, [4] = 0x80BFE6FF }                    -- FUZZ/CLIP
local COMP_MODE_COLS  = { [0] = 0xF2801AFF, [1] = 0xCCB34DFF, [2] = 0xE6401AFF }  -- PUNCH/GLUE/SQUASH

local DYN_COLS = {
  { title = "COMP", items = {
    { pid = G.FX_PID_CMP_AMT,  label = "Amount", min = 0, max = 1, fmt = "%.2f", default = 0, role = 5,
      mode_pid = G.FX_PID_CMP_MODE, mode_cols = COMP_MODE_COLS },
    { pid = G.FX_PID_CMP_MODE, label = "Mode",   pill = true, modes = { "PUNCH", "GLUE", "SQUASH" } },
  }},
  { title = "DRIVE", items = {
    { pid = G.FX_PID_SAT_DRV,  label = "Drive", min = 0, max = 1, fmt = "%.2f", default = 0, role = 1,
      mode_pid = G.FX_PID_DRV_MODE, mode_cols = DRIVE_MODE_COLS },
    { pid = G.FX_PID_DRV_MODE, label = "Mode",  pill = true, modes = { "SOFT", "TUBE", "TAPE", "FUZZ", "CLIP" } },
  }},
  { title = "CRUSH", items = {
    { pid = G.FX_PID_BC_RATE, label = "Rate", min = 0, max = 1,  fmt = "%.2f", default = 0,  role = 3 },
    { pid = G.FX_PID_BC_BITS, label = "Bits", min = 1, max = 16, fmt = "%.0f", default = 16, role = 4 },
  }},
  { title = "SENDS", items = {
    { pid = G.FX_PID_SND_DLY, label = "Delay",  min = 0, max = 1, fmt = "%.2f", default = 0, role = 6 },
    { pid = G.FX_PID_SND_RVB, label = "Reverb", min = 0, max = 1, fmt = "%.2f", default = 0, role = 2 },
    { pid = G.FX_PID_SND_SMASH, label = "Smash", min = 0, max = 1, fmt = "%.2f", default = 0, role = 1 },
  }},
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- STATE
-- ═══════════════════════════════════════════════════════════════════════════════
local ui = { ctx = nil, is_open = true, first_frame = true,
             want_dock_change = false, pending_dock_id = 0,
             was_docked = nil, dock_skip = 0 }
local settings = { theme = "eon", follow = true, pinned = 0, dock_id = 0,
                   window_w = 360, window_h = 460 }

local display     = {}   -- pid -> last value shown (cache; suppresses drag jitter)
local pending     = {}   -- pid -> value queued to send (drained one/frame)
local active_pid  = nil  -- pid dragged LAST frame (suppresses its gmem refresh this frame)
local next_active = nil  -- pid dragged THIS frame (becomes active_pid after the draw)
local last_pad    = -2   -- pad the cache/pending belong to
local eq_drag     = nil  -- index of the EQ-graph node being dragged
local eq_drag_pids = {}  -- pids the EQ graph is editing this frame (suppress gmem refresh)
local active_inst_id = 0

-- Swing-alive tracking via the monotonic heartbeat (GS_SWING_ALIVE).
local hb_last, hb_at = -1, 0

-- ═══════════════════════════════════════════════════════════════════════════════
-- SETTINGS (ExtState — simple + crash-safe)
-- ═══════════════════════════════════════════════════════════════════════════════
local function load_settings()
  -- Shared across all EON tools (one selector re-skins everything).
  local t = reaper.GetExtState("Swing", "eon_theme")
  if t == "" then t = reaper.GetExtState("Swing", "padfx_theme") end  -- migrate old key
  if t ~= "" then settings.theme = t end
  settings.follow   = reaper.GetExtState("Swing", "padfx_follow") ~= "0"
  settings.pinned   = tonumber(reaper.GetExtState("Swing", "padfx_pinned")) or 0
  settings.dock_id  = tonumber(reaper.GetExtState("Swing", "padfx_dock"))   or 0
  settings.window_w = tonumber(reaper.GetExtState("Swing", "padfx_w"))      or 360
  settings.window_h = tonumber(reaper.GetExtState("Swing", "padfx_h"))      or 360
end
local function save_settings()
  reaper.SetExtState("Swing", "eon_theme",    settings.theme, true)
  reaper.SetExtState("Swing", "padfx_follow", settings.follow and "1" or "0", true)
  reaper.SetExtState("Swing", "padfx_pinned", tostring(settings.pinned), true)
  reaper.SetExtState("Swing", "padfx_dock",   tostring(settings.dock_id or 0), true)
  reaper.SetExtState("Swing", "padfx_w",      tostring(math.floor(settings.window_w)), true)
  reaper.SetExtState("Swing", "padfx_h",      tostring(math.floor(settings.window_h)), true)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- INSTANCE RESOLUTION (mirrors Swing_Browser.enumerate_swing_instances)
-- ═══════════════════════════════════════════════════════════════════════════════
local function enumerate_instances()
  local list, alive = {}, {}
  local now = reaper.time_precise()
  for s = 0, G.GS_INST_REG_MAX - 1 do
    local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
    local id = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID))
    local hb = reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT)
    if id > 0 and hb > 0 and (now - hb) < G.GS_INST_REG_TIMEOUT then alive[id] = true end
  end
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
      local rv, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
      local is_swing = (rv and ident:find("DrumKit_ReaKit"))
                    or fname:find("DrumKit_ReaKit")
                    or fname:match("^JS: Swing")
                    or fname:match("Swing %— 16%-Pad")
      if is_swing then
        local id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        if alive[id] then
          local tn = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
          local _, tname = reaper.GetTrackName(tr)
          list[#list + 1] = { inst_id = id, track_num = tn, track_name = tname }
        end
      end
    end
  end
  return list
end

local function auto_pick_instance()
  active_inst_id = math.floor(reaper.gmem_read(INSTANCE))
  -- Identity rollout (2026-07-08): a cached/inherited id can be re-minted
  -- mid-session (duplicate duel in the JSFX reconciler); a stale id would
  -- mistarget every read/post forever. Staleness = the id is ABSENT from
  -- the registry — NOT a stale heartbeat (heartbeats freeze whenever the
  -- audio device closes; keying on liveness is the app-focus disease).
  if active_inst_id > 0 then
    local present = false
    for s = 0, G.GS_INST_REG_MAX - 1 do
      local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
      if math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID) or 0) == active_inst_id then
        present = true
        break
      end
    end
    if not present then
      -- Only release the shared routing cell if it still carries the stale
      -- id (another surface may have already re-pointed it).
      if math.floor(reaper.gmem_read(INSTANCE) or 0) == active_inst_id then
        reaper.gmem_write(INSTANCE, 0)
      end
      active_inst_id = 0
    end
  end
  if active_inst_id == 0 then
    local list = enumerate_instances()
    if #list > 0 then
      active_inst_id = list[1].inst_id
      reaper.gmem_write(INSTANCE, active_inst_id)
    end
  end
end

local function swing_alive()
  local v = reaper.gmem_read(G.GS_SWING_ALIVE) or 0
  local now = reaper.time_precise()
  if v ~= hb_last then hb_last = v; hb_at = now end
  return v > 0 and (now - hb_at) < 1.5
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- LIFECYCLE
-- ═══════════════════════════════════════════════════════════════════════════════
local function cleanup()
  save_settings()
  reaper.SetExtState("Swing", "padfx_running", "0", false)
  reaper.SetExtState("Swing", "padfx_heartbeat", "0", false)
  if core.hub_notify then core.hub_notify("close", "padfx") end
end

local function init()
  reaper.gmem_attach(GMEM_NAME)
  load_settings()
  ui.ctx = ImGui.CreateContext(SCRIPT_NAME)
  reaper.SetExtState("Swing", "padfx_running", "1", false)
  -- Re-assert INSTANCE so the JSFX gate lets the targeted instance publish/act.
  auto_pick_instance()
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- UI HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════
local function draw_pad_header(ctx, pad)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = ImGui.GetCursorScreenPos(ctx)
  -- color swatch matching the JSFX pad face
  local col = core.get_pad_color(pad)
  ImGui.DrawList_AddRectFilled(dl, x, y, x + 18, y + 18, col, 3)
  ImGui.DrawList_AddRect(dl, x, y, x + 18, y + 18, widgets.colors.border_default, 3)
  ImGui.Dummy(ctx, 22, 18)
  ImGui.SameLine(ctx)
  local name = core.read_pad_name(pad)
  local note = core.midi_to_note_name(core.read_pad_note(pad))
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, widgets.colors.text_gold)
  ImGui.Text(ctx, string.format("Pad %d", pad + 1))
  ImGui.PopStyleColor(ctx)
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, (name ~= "" and name or "(unnamed)") .. "   " .. note)
end

-- ── EQ frequency-response graph ──────────────────────────────────────────────
-- RBJ biquad magnitude (cookbook), evaluated for the curve. Display-only, so a
-- fixed 48k reference is fine — the JSFX does the real DSP.
local EQ_SR = 48000
local function clampn(v, a, b) return v < a and a or (v > b and b or v) end

local function biquad(kind, f0, dbgain, Q)
  local w0 = 2 * math.pi * f0 / EQ_SR
  local cw, sw = math.cos(w0), math.sin(w0)
  local A = 10 ^ (dbgain / 40)
  local alpha = sw / (2 * Q)
  local b0, b1, b2, a0, a1, a2
  if kind == "peak" then
    b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A
    a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A
  elseif kind == "lowshelf" then
    local sa = 2 * math.sqrt(A) * alpha
    b0 = A * ((A + 1) - (A - 1) * cw + sa); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - sa)
    a0 = (A + 1) + (A - 1) * cw + sa;       a1 = -2 * ((A - 1) + (A + 1) * cw);    a2 = (A + 1) + (A - 1) * cw - sa
  elseif kind == "highshelf" then
    local sa = 2 * math.sqrt(A) * alpha
    b0 = A * ((A + 1) + (A - 1) * cw + sa); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - sa)
    a0 = (A + 1) - (A - 1) * cw + sa;       a1 = 2 * ((A - 1) - (A + 1) * cw);      a2 = (A + 1) - (A - 1) * cw - sa
  elseif kind == "hp" then
    b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
  else -- "lp"
    b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha
  end
  return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
end

local function biquad_db(c, f)
  local w = 2 * math.pi * f / EQ_SR
  local c1, s1 = math.cos(w), math.sin(w)
  local c2, s2 = math.cos(2 * w), math.sin(2 * w)
  local nr = c[1] + c[2] * c1 + c[3] * c2
  local ni = -(c[2] * s1 + c[3] * s2)
  local dr = 1 + c[4] * c1 + c[5] * c2
  local di = -(c[4] * s1 + c[5] * s2)
  return 10 * math.log((nr * nr + ni * ni) / (dr * dr + di * di), 10)  -- 20*log10(mag) == 10*log10(mag^2)
end

local function draw_eq_graph(ctx, fx_live, graph_h)
  -- Sync the band params from gmem so the curve + nodes reflect Swing's actual
  -- values — but NOT while a local edit for that param is still queued (drag or
  -- Q-scroll), so the round-trip lag doesn't make the curve flicker.
  if fx_live then
    for _, pid in ipairs(EQ_BAND_PIDS) do
      if fx_live[pid] ~= nil and pending[pid] == nil then display[pid] = fx_live[pid] end
    end
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local W = (select(1, ImGui.GetContentRegionAvail(ctx))) - 2
  if W < 140 then W = 140 end
  local H = graph_h or 112       -- responsive: scales with the panel height
  if H < 40 then H = 40 end      -- low floor so the caller can shrink it to fit
  ImGui.InvisibleButton(ctx, "##eqgraph", W, H)
  local hovered = ImGui.IsItemHovered(ctx)
  local active  = ImGui.IsItemActive(ctx)

  local FMIN, FMAX, DBMAX, DBMIN = 20, 20000, 15, -15
  local lf0, lf1 = math.log(FMIN), math.log(FMAX)
  local function FX(f)  return x0 + (math.log(f) - lf0) / (lf1 - lf0) * W end
  local function XF(px) return math.exp(lf0 + (px - x0) / W * (lf1 - lf0)) end
  local function GY(db) return y0 + (DBMAX - db) / (DBMAX - DBMIN) * H end
  local function YG(py) return DBMAX - (py - y0) / H * (DBMAX - DBMIN) end

  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + W, y0 + H, 0x12131AFF, 4)
  for _, f in ipairs({ 50, 100, 200, 500, 1000, 2000, 5000, 10000 }) do
    local px = FX(f)
    ImGui.DrawList_AddLine(dl, px, y0, px, y0 + H, 0xFFFFFF12)
    ImGui.DrawList_AddText(dl, px + 2, y0 + H - 12, 0xFFFFFF55, f >= 1000 and (f / 1000) .. "k" or tostring(f))
  end
  for _, d in ipairs({ 12, 6, 0, -6, -12 }) do
    local py = GY(d)
    ImGui.DrawList_AddLine(dl, x0, py, x0 + W, py, d == 0 and 0xFFFFFF30 or 0xFFFFFF12)
    ImGui.DrawList_AddText(dl, x0 + 2, py - 12, 0xFFFFFF40, d > 0 and ("+" .. d) or tostring(d))
  end

  -- Current band values from the cache.
  local function dv(pid, def) return display[pid] ~= nil and display[pid] or def end
  local hpf, lpf, reso = dv(G.FX_PID_HPF_FREQ, 20), dv(G.FX_PID_LPF_FREQ, 20000), dv(G.FX_PID_RESO, 0.707)
  local lo, lof  = dv(G.FX_PID_EQ_LO, 0),  dv(G.FX_PID_EQ_LO_FREQ, 200)
  local mid, midf = dv(G.FX_PID_EQ_MID, 0), dv(G.FX_PID_EQ_MID_FREQ, 1000)
  local mid2, mid2f = dv(G.FX_PID_EQ_MID2, 0), dv(G.FX_PID_EQ_MID2_FREQ, 3000)
  local midq, mid2q = dv(G.FX_PID_EQ_MID_Q, 0.8), dv(G.FX_PID_EQ_MID2_Q, 0.8)
  local loq, hiq = dv(G.FX_PID_EQ_LO_Q, 0.7071), dv(G.FX_PID_EQ_HI_Q, 0.7071)
  local hi, hif  = dv(G.FX_PID_EQ_HI, 0),  dv(G.FX_PID_EQ_HI_FREQ, 5000)

  local coeffs = {}
  if hpf > 25     then coeffs[#coeffs + 1] = { biquad("hp", hpf, 0, reso) } end
  if lpf < 19500  then coeffs[#coeffs + 1] = { biquad("lp", lpf, 0, reso) } end
  coeffs[#coeffs + 1] = { biquad("lowshelf",  lof,   lo,   loq) }
  coeffs[#coeffs + 1] = { biquad("peak",      midf,  mid,  midq) }
  coeffs[#coeffs + 1] = { biquad("peak",      mid2f, mid2, mid2q) }
  coeffs[#coeffs + 1] = { biquad("highshelf", hif,   hi,   hiq) }

  -- Response curve + soft fill to the 0 line.
  local ACC, y_zero = widgets.colors.accent, GY(0)
  local pcx, pcy
  local px = 0
  while px <= W do
    local sum = 0
    local f = XF(x0 + px)
    for _, c in ipairs(coeffs) do sum = sum + biquad_db(c, f) end
    sum = clampn(sum, DBMIN, DBMAX)
    local cx, cy = x0 + px, GY(sum)
    ImGui.DrawList_AddLine(dl, cx, y_zero, cx, cy, 0xFF8C3222)  -- accent @ low alpha fill
    if pcx then ImGui.DrawList_AddLine(dl, pcx, pcy, cx, cy, ACC, 2) end
    pcx, pcy = cx, cy
    px = px + 3
  end

  -- Draggable nodes (rebuilt each frame from live values; index order stable).
  local nodes = {
    { name = "HPF",  fpid = G.FX_PID_HPF_FREQ,    f = hpf,  db = 0,   col = 0x49C0E1FF, fmin = 20,   fmax = 8000  },
    { name = "LPF",  fpid = G.FX_PID_LPF_FREQ,    f = lpf,  db = 0,   col = 0x49C0E1FF, fmin = 200,  fmax = 20000 },
    { name = "Low",  fpid = G.FX_PID_EQ_LO_FREQ,  gpid = G.FX_PID_EQ_LO,  qpid = G.FX_PID_EQ_LO_Q, q = loq, f = lof,  db = lo,  col = 0xE15D49FF, fmin = 40,   fmax = 500,   gmin = -12, gmax = 12 },
    { name = "Mid",  fpid = G.FX_PID_EQ_MID_FREQ, gpid = G.FX_PID_EQ_MID, qpid = G.FX_PID_EQ_MID_Q, q = midq, f = midf, db = mid, col = 0x6BCB5AFF, fmin = 200,  fmax = 8000,  gmin = -12, gmax = 12 },
    { name = "Hi-Mid", fpid = G.FX_PID_EQ_MID2_FREQ, gpid = G.FX_PID_EQ_MID2, qpid = G.FX_PID_EQ_MID2_Q, q = mid2q, f = mid2f, db = mid2, col = 0xBF73D9FF, fmin = 500, fmax = 12000, gmin = -12, gmax = 12 },
    { name = "High", fpid = G.FX_PID_EQ_HI_FREQ,  gpid = G.FX_PID_EQ_HI,  qpid = G.FX_PID_EQ_HI_Q, q = hiq, f = hif,  db = hi,  col = 0xE1B349FF, fmin = 2000, fmax = 16000, gmin = -12, gmax = 12 },
  }

  -- Begin a drag: grab the nearest node within radius.
  if ImGui.IsItemActivated(ctx) then
    local mx, my = ImGui.GetMousePos(ctx)
    eq_drag = nil
    local best = 16 * 16
    for i, n in ipairs(nodes) do
      local ddx, ddy = FX(n.f) - mx, GY(n.db) - my
      local d = ddx * ddx + ddy * ddy
      if d < best then best = d; eq_drag = i end
    end
  end
  if active and eq_drag then
    local mx, my = ImGui.GetMousePos(ctx)
    local n = nodes[eq_drag]
    local nf = clampn(XF(mx), n.fmin, n.fmax)
    display[n.fpid] = nf; pending[n.fpid] = nf; eq_drag_pids[n.fpid] = true
    if n.gpid then
      local ng = clampn(YG(my), n.gmin, n.gmax)
      display[n.gpid] = ng; pending[n.gpid] = ng; eq_drag_pids[n.gpid] = true
    end
  end
  if not active then eq_drag = nil end

  -- Hover hit-test for the value readout (replaces the dropped band knobs).
  local hover_node = nil
  if hovered then
    local mx, my = ImGui.GetMousePos(ctx)
    local best = 16 * 16
    for i, n in ipairs(nodes) do
      local ddx, ddy = FX(n.f) - mx, GY(n.db) - my
      local d = ddx * ddx + ddy * ddy
      if d < best then best = d; hover_node = i end
    end
  end

  -- Scroll over the HPF or LPF node sets the shared filter Q (there's no Q knob
  -- now). nodes[1]=HPF, nodes[2]=LPF; both use fx_reso for resonance. Shift=fine.
  -- Scroll over a bell node (Mid / Hi-Mid) sets that bell's own Q.
  if hover_node then
    local wheel = select(1, ImGui.GetMouseWheel(ctx))
    if wheel ~= 0 then
      local step = ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) and 0.03 or 0.12
      if hover_node == 1 or hover_node == 2 then
        local q = display[G.FX_PID_RESO] or 0.707
        q = clampn(q * (1 + wheel * step), 0.707, 12)
        display[G.FX_PID_RESO] = q
        pending[G.FX_PID_RESO] = q
      else
        local n = nodes[hover_node]
        if n.qpid then
          local q = display[n.qpid] or 0.8
          q = clampn(q * (1 + wheel * step), 0.3, 6)
          display[n.qpid] = q
          pending[n.qpid] = q
        end
      end
    end
  end

  for i, n in ipairs(nodes) do
    local nx, ny = FX(n.f), GY(n.db)
    local r = (eq_drag == i or hover_node == i) and 7 or 5
    ImGui.DrawList_AddCircleFilled(dl, nx, ny, r, n.col, 16)
    ImGui.DrawList_AddCircle(dl, nx, ny, r, 0x000000AA, 16, 1.5)
  end

  local readout = eq_drag or hover_node
  if readout then
    local n = nodes[readout]
    local fhz = n.f >= 1000 and string.format("%.1fk", n.f / 1000) or string.format("%.0f Hz", n.f)
    if n.qpid then
      -- Bell: per-band Q (set via scroll).
      ImGui.SetTooltip(ctx, string.format("%s   %s   %+.1f dB   Q %.2f", n.name, fhz, n.db, display[n.qpid] or 0.8))
    elseif n.gpid then
      ImGui.SetTooltip(ctx, string.format("%s   %s   %+.1f dB", n.name, fhz, n.db))
    else
      -- HPF/LPF: show the shared Q (set via scroll).
      ImGui.SetTooltip(ctx, string.format("%s   %s   Q %.2f", n.name, fhz, display[G.FX_PID_RESO] or 0.707))
    end
  elseif hovered then
    ImGui.SetTooltip(ctx, "Drag a node — filters: drag = freq, scroll = Q · bells: scroll = band Q")
  end
end

-- Refresh + draw a single FX control (knob or pill); queues edits. Caller
-- handles layout (SameLine / groups).
local function draw_fx_control(ctx, item, fx_live, knob_size, pill_w, compact)
  local pid = item.pid
  -- Refresh cache from gmem unless this control is being dragged (knob or graph node).
  if pid ~= active_pid and not eq_drag_pids[pid] and fx_live and fx_live[pid] ~= nil then
    display[pid] = fx_live[pid]
  end
  if display[pid] == nil then display[pid] = (item.default or 0) end

  if item.pill then
    ImGui.BeginGroup(ctx)
    local idx = math.floor((display[pid] or 0) + 0.5)
    if idx < 0 then idx = 0 end
    local changed, nidx = widgets.mode_pill(ctx, tostring(pid), item.modes, idx, pill_w or 56)
    if not compact then
      -- compact rung: the pill face already names the current mode
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, widgets.colors.text_dim)
      ImGui.Text(ctx, item.label)
      ImGui.PopStyleColor(ctx)
    end
    ImGui.EndGroup(ctx)
    if changed then display[pid] = nidx; pending[pid] = nidx end
  else
    -- Mode-typed knobs (COMP/DRIVE) take the selected type's cap colour, matching
    -- the per-pad overlay; falls back to the static role hue when no mode is set.
    local hue
    if item.mode_pid and item.mode_cols then
      local mv = display[item.mode_pid]
      if mv == nil and fx_live then mv = fx_live[item.mode_pid] end
      hue = item.mode_cols[math.floor((mv or 0) + 0.5)]
    end
    local changed, nv, act = widgets.knob(ctx, tostring(pid), display[pid],
      item.min, item.max, { log = item.log, fmt = item.fmt, default = item.default,
                            label = item.label, size = knob_size, role = item.role, hue = hue,
                            compact = compact })
    if act then next_active = pid end
    if changed then display[pid] = nv; pending[pid] = nv end
  end
end

-- Send at most one queued edit per frame (channel is single-slot, last-wins;
-- a knob drag changes one pid per frame so this stays smooth).
local function drain_pending(pad)
  if pad < 0 then pending = {}; return end
  for pid, val in pairs(pending) do
    core.send_fx_action(pad, pid, val)
    pending[pid] = nil
    return  -- one per frame
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ═══════════════════════════════════════════════════════════════════════════════
local loop

local function frame()
  -- Toggle-script close request.
  if reaper.GetExtState("Swing", "padfx_close") == "1" then
    reaper.SetExtState("Swing", "padfx_close", "0", false)
    ui.is_open = false
    cleanup()
    return
  end
  reaper.SetExtState("Swing", "padfx_heartbeat", tostring(os.time()), false)

  -- Live re-dock request — EON Dock Layout's "Spread panes" asks an ALREADY
  -- OPEN pane to move to a named docker instead of sharing one. Value is an
  -- ImGui dock id in this pane's own units (-1..-16 = REAPER docker 0..15,
  -- 0 = float), and it rides the exact pending_dock_id path the Dock button
  -- drives, so SetNextWindowDockID still has only one caller. dock_id is
  -- written + saved here rather than waiting for the frame that applies it:
  -- the picker reads this key back to draw where the pane now lives, and a
  -- card that lags the move would break the drawing==landing promise.
  local dock_req = reaper.GetExtState("Swing", "padfx_dock_req")
  if dock_req ~= "" then
    reaper.DeleteExtState("Swing", "padfx_dock_req", false)
    ui.pending_dock_id  = tonumber(dock_req) or 0
    ui.want_dock_change = true
    settings.dock_id    = ui.pending_dock_id
    save_settings()
  end

  -- Identity rollout: ~1Hz target revalidation (auto_pick_instance clears a
  -- registry-absent id and re-picks; no-op while the target is healthy).
  do
    local now_t = reaper.time_precise()
    if (ui.inst_check_t or 0) + 1.0 < now_t then
      ui.inst_check_t = now_t
      auto_pick_instance()
    end
  end

  local ctx = ui.ctx
  -- Follow the shared theme each frame so changing it in any EON tool re-skins here too.
  local _sh = reaper.GetExtState("Swing", "eon_theme")
  if _sh ~= "" and _sh ~= settings.theme then settings.theme = _sh end
  widgets.push_theme(ctx, settings.theme)
  local window_flags = ImGui.WindowFlags_NoCollapse

  if ui.first_frame then
    ImGui.SetNextWindowSize(ctx, settings.window_w, settings.window_h, ImGui.Cond_Appearing)
    if ImGui.SetNextWindowDockID and (settings.dock_id or 0) ~= 0 then
      ImGui.SetNextWindowDockID(ctx, settings.dock_id, ImGui.Cond_Always)
    end
    ui.first_frame = false
  elseif ui.want_dock_change and ImGui.SetNextWindowDockID then
    ImGui.SetNextWindowDockID(ctx, ui.pending_dock_id, ImGui.Cond_Always)
    settings.dock_id = ui.pending_dock_id
    ui.want_dock_change = false
  end

  ImGui.SetNextWindowSizeConstraints(ctx, 300, 280, 99999, 99999)
  local visible, open = ImGui.Begin(ctx, SCRIPT_NAME .. " v" .. VERSION .. "###swing_padfx", true, window_flags)
  ui.is_open = open

  if visible then
    settings.window_w, settings.window_h = ImGui.GetWindowSize(ctx)
    -- signature red left border
    local wx, wy = ImGui.GetWindowPos(ctx)
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), wx, wy, wx + 3, wy + settings.window_h, widgets.colors.swing_red)
    -- Compact spacing for the rack panel (denser than the shared theme defaults).
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 4, 3)
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4, 2)

    -- ── Toolbar ────────────────────────────────────────────────────────────
    -- Theme
    local THEME_OPTS = { {"eon","EON"}, {"dark","Dark"}, {"light","Light"},
                         {"reaper","REAPER"}, {"reaper_panel","REAPER Panel"}, {"reaper_color","REAPER Color"},
                         {"ssl","SSL"}, {"neve","Neve"}, {"api","API"}, {"tube","Tube"},
                         {"ableton","Ableton"}, {"fl","FL Studio"}, {"protools","Pro Tools"},
                         {"protools_light","PT Light"} }
    local theme_label = "EON"
    for _, o in ipairs(THEME_OPTS) do if settings.theme == o[1] then theme_label = o[2] end end
    if ImGui.Button(ctx, theme_label .. "##theme", 54, 22) then ImGui.OpenPopup(ctx, "theme_menu") end
    if ImGui.IsItemHovered(ctx) then   -- hover + mouse-wheel cycles through themes
      local _wv = ImGui.GetMouseWheel(ctx)
      if _wv ~= 0 then
        local _i = 1; for k, o in ipairs(THEME_OPTS) do if settings.theme == o[1] then _i = k end end
        _i = ((_i - 1 + (_wv > 0 and 1 or -1)) % #THEME_OPTS) + 1
        settings.theme = THEME_OPTS[_i][1]; save_settings()
      end
    end
    if ImGui.BeginPopup(ctx, "theme_menu") then
      for _, o in ipairs(THEME_OPTS) do
        if ImGui.Selectable(ctx, o[2], settings.theme == o[1]) then settings.theme = o[1]; save_settings() end
      end
      ImGui.EndPopup(ctx)
    end
    ImGui.SameLine(ctx)

    -- Knob style (per-theme override; saved in ExtState "eon_knob_<theme>", "" = the
    -- theme's built-in knob). The bridge picks it up and republishes GS_THEME_KNOB_P
    -- live, so the themed knobs (Drum Strip / FX) update at once.
    local KNOB_OPTS = { {0,"Default"}, {1,"SSL"}, {2,"Vari-Mu"}, {3,"API"}, {4,"Witti"}, {5,"Neve"},
                        {6,"Joanny"}, {7,"MPC"}, {8,"Jog"}, {10,"Spice"}, {11,"Encoder"}, {12,"Pultec"},
                        {13,"Ableton"}, {14,"FL"}, {15,"Pro Tools"}, {16,"FabFilter"}, {17,"Serum"}, {18,"Roland"},
                        {19,"Pultec Cream"}, {20,"Neve Alt"} }
    local _kov  = reaper.GetExtState("Swing", "eon_knob_" .. settings.theme)
    local _kcur = (_kov ~= "" and tonumber(_kov)) or 0
    local knob_label = "Default"
    for _, o in ipairs(KNOB_OPTS) do if o[1] == _kcur then knob_label = o[2] end end
    if ImGui.Button(ctx, knob_label .. "##knob", 66, 22) then ImGui.OpenPopup(ctx, "knob_menu") end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Knob style for the " .. theme_label .. " theme (saved per theme)")
      local _kw = ImGui.GetMouseWheel(ctx)
      if _kw ~= 0 then
        local _i = 1; for k, o in ipairs(KNOB_OPTS) do if o[1] == _kcur then _i = k end end
        _i = ((_i - 1 + (_kw > 0 and 1 or -1)) % #KNOB_OPTS) + 1
        reaper.SetExtState("Swing", "eon_knob_" .. settings.theme, KNOB_OPTS[_i][1] == 0 and "" or tostring(KNOB_OPTS[_i][1]), true)
      end
    end
    if ImGui.BeginPopup(ctx, "knob_menu") then
      for _, o in ipairs(KNOB_OPTS) do
        if ImGui.Selectable(ctx, o[2], o[1] == _kcur) then
          reaper.SetExtState("Swing", "eon_knob_" .. settings.theme, o[1] == 0 and "" or tostring(o[1]), true)
        end
      end
      ImGui.EndPopup(ctx)
    end
    ImGui.SameLine(ctx)

    -- Follow / Pin
    local mode_label = settings.follow and "Follow" or ("Pin " .. (settings.pinned + 1))
    if ImGui.Button(ctx, mode_label .. "##follow", 70, 22) then
      settings.follow = not settings.follow
      if not settings.follow then settings.pinned = math.max(0, core.read_selected_pad()) end
      save_settings()
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, settings.follow
        and "Following Swing's selected pad — click to PIN to the current pad"
        or  "Pinned to one pad — click to FOLLOW the selection again")
    end
    ImGui.SameLine(ctx)

    -- Instance picker
    if ImGui.Button(ctx, "Inst##inst", 48, 22) then ImGui.OpenPopup(ctx, "inst_menu") end
    if ImGui.BeginPopup(ctx, "inst_menu") then
      local list = enumerate_instances()
      if #list == 0 then
        ImGui.TextDisabled(ctx, "No live Swing instances")
      else
        for _, it in ipairs(list) do
          local lbl = string.format("Track %d: %s", it.track_num, (it.track_name ~= "" and it.track_name or "Swing"))
          if ImGui.Selectable(ctx, lbl, it.inst_id == active_inst_id) then
            active_inst_id = it.inst_id
            reaper.gmem_write(INSTANCE, active_inst_id)
          end
        end
      end
      ImGui.EndPopup(ctx)
    end
    ImGui.SameLine(ctx)

    -- Dock / Undock (mirrors Swing Browser). pending_dock_id -1 = REAPER docker
    -- (REAPER fills the frame and remembers the last-used docker), 0 = float. The
    -- next Begin applies it via SetNextWindowDockID(Cond_Always); REAPER handles
    -- the fill, so no manual stretching.
    local is_docked  = (settings.dock_id or 0) ~= 0
    local dock_label = is_docked and "Undock##dock" or "Dock##dock"
    if ImGui.Button(ctx, dock_label, 58, 22) then
      ui.pending_dock_id  = is_docked and 0 or -1
      ui.want_dock_change = true
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, is_docked
        and "Undock (float the Pad FX window)"
        or  "Dock to REAPER docker\n(right-click the docked tab to pick top/bottom/left/right)")
    end
    ImGui.SameLine(ctx)

    -- Alive dot
    local alive = swing_alive()
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, alive and widgets.colors.status_ok or widgets.colors.status_err)
    ImGui.Text(ctx, "\xE2\x97\x8F")
    ImGui.PopStyleColor(ctx)
    if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, alive and "Swing: running" or "Swing: not detected") end

    ImGui.SameLine(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button, 0xCC2222FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
    if ImGui.Button(ctx, "X##close") then ui.is_open = false end
    ImGui.PopStyleColor(ctx, 2)

    ImGui.Separator(ctx)

    -- FOLLOW the shared INSTANCE target (the Browser owns the same slot). Only
    -- READ it here — writing every frame races the Browser and makes the JSFX
    -- target gate flip, which flickers everything that reads Swing's gmem.
    -- INSTANCE is written only on init auto-pick and explicit picks below.
    local cur_inst = math.floor(reaper.gmem_read(INSTANCE))
    if cur_inst > 0 then active_inst_id = cur_inst end

    -- ── Resolve pad ─────────────────────────────────────────────────────────
    local pad
    if settings.follow then pad = core.read_selected_pad() else pad = settings.pinned end
    if pad and pad > 15 then pad = 15 end

    -- Pad changed → drop queued writes + drag latches so we never push a stale
    -- pid to the new pad. KEEP `display` (it refreshes from gmem next read) —
    -- clearing it blanked every control for a frame, which read as flicker on
    -- each selection change.
    if pad ~= last_pad then
      pending, active_pid, eq_drag = {}, nil, nil
      last_pad = pad
    end

    if not alive then
      ImGui.Dummy(ctx, 1, 12)
      ImGui.TextColored(ctx, widgets.colors.status_err, "Swing not detected.")
      ImGui.TextWrapped(ctx, "Insert Swing on a track (or pick an instance above).")
    elseif not pad or pad < 0 then
      ImGui.Dummy(ctx, 1, 12)
      ImGui.TextWrapped(ctx, "Select a pad in Swing to edit its FX.")
    else
      draw_pad_header(ctx, pad)
      ImGui.Dummy(ctx, 1, 2)
      local fx_live = core.read_pad_fx(pad)  -- nil during a pad-switch frame
      next_active = nil                      -- collected during this frame's draw
      eq_drag_pids = {}                      -- repopulated by the EQ graph if dragging

      -- Auto-fit layout: the panel scales its contents (EQ + knobs) to the
      -- docked size — but controls have a FLOOR (user 2026-08-25: "buttons
      -- always stay big"). Below the floor the window scrolls instead of
      -- miniaturizing; the EQ curve is the compression victim (down to its
      -- own 40px floor) before the knobs give up anything.
      local avail_h = select(2, ImGui.GetContentRegionAvail(ctx))
      -- Reflow the four columns to as many per row as fit; shrink 4→2→1 so every
      -- control stays reachable as the panel narrows (the window only scrolls at
      -- the very smallest sizes).
      --
      -- ⚠️ Decide from a width THE SCROLLBAR CANNOT MOVE. GetContentRegionAvail
      -- loses the scrollbar's ~14px the instant one appears, and the ladder
      -- below sizes the EQ to consume exactly whatever height is left — so the
      -- content permanently sits on the overflow knife-edge. A pane whose avail
      -- width straddled 300 (the user's bottom docker, 322px wide) therefore
      -- flipped EVERY FRAME: no scrollbar → 306 → 4 cols/1 row → content height
      -- changes → scrollbar → 292 → 2 cols/2 rows → … (user 2026-08-27: "Pad FX
      -- is blinking when I'm in dock mode"; resizing the neighbouring panes
      -- moved it off the boundary and it stopped). Measuring off the WINDOW
      -- width, which a scrollbar never changes, breaks the feedback loop rather
      -- than damping it, and keeps the original thresholds: window_w - padding
      -- IS avail_w in the no-scrollbar case the numbers were chosen for.
      local _padx = ImGui.GetStyleVar(ctx, ImGui.StyleVar_WindowPadding)  -- x only
      local col_w = settings.window_w - 2 * _padx
      local ncols = (col_w >= 300) and 4 or ((col_w >= 150) and 2 or 1)
      local nrows = math.ceil(4 / ncols)

      -- Overheads are measured generously: each stacked knob reserves its diameter
      -- PLUS ~31px (value + label rows + item spacing), the column title ~17px, and
      -- table cell padding. Slightly over-reserving leaves a small gap below the
      -- knobs instead of clipping the bottom row — which is the bug we're avoiding.
      local SEPS    = 54                        -- two SeparatorText rows ("EQ" + "DYNAMICS")
      local GRIDGAP = (nrows - 1) * 10          -- gap between rows in the 2-/1-wide reflow
      -- FIT LADDER (user 2026-08-25: "no scroll on Pad FX"): the dials never
      -- shrink below 34px and the pane never scrolls at real sizes. What
      -- gives way instead, in order: the EQ curve compresses (40 → 24px thin
      -- strip, still draggable), then the knob value/label rows fold away
      -- (compact mode — names and values live on in the hover tooltips).
      -- Scrolling survives only below the ladder's absolute floor (~230px),
      -- which no real rig pane reaches.
      local ROW_OVH = 90                        -- per knob-row: title + 2×(value/label+spacing) + cell pad
      local KNOB_MIN, KNOB_MAX = 34, 54
      local EQ_FULL, EQ_THIN   = 40, 24
      local compact = false
      local scal = avail_h - SEPS - nrows * ROW_OVH - GRIDGAP
      if scal < 40 then scal = 40 end
      local knob_size = (scal * 0.55) / (2 * nrows)
      if knob_size > KNOB_MAX then knob_size = KNOB_MAX end
      if knob_size < KNOB_MIN then knob_size = KNOB_MIN end
      local dyn_h = nrows * (2 * knob_size + ROW_OVH) + GRIDGAP
      if avail_h - SEPS - dyn_h < EQ_FULL then
        -- Rung 1: dials to the floor, EQ allowed thin.
        knob_size = KNOB_MIN
        dyn_h = nrows * (2 * knob_size + ROW_OVH) + GRIDGAP
        if avail_h - SEPS - dyn_h < EQ_THIN then
          -- Rung 2: fold the text rows under the dials.
          compact = true
          ROW_OVH = 46                          -- title + cell pad only
          dyn_h = nrows * (2 * knob_size + ROW_OVH) + GRIDGAP
        end
      end
      local eq_h = avail_h - SEPS - dyn_h       -- EQ takes the rest
      if eq_h < EQ_THIN then eq_h = EQ_THIN end

      -- EQ: the interactive graph owns the bands (HPF/LPF + Lo/Mid/Hi); the
      -- only EQ knob is the shared filter Q.
      ImGui.SeparatorText(ctx, "EQ")
      draw_eq_graph(ctx, fx_live, eq_h)

      -- Dynamics: COMP / DRIVE / CRUSH / SENDS as equal-width columns that fill
      -- the panel. A stretch-table keeps the columns even and reflows 4→2 when
      -- narrow; each column's controls are centred in their cell.
      ImGui.SeparatorText(ctx, "DYNAMICS")
      if ImGui.BeginTable(ctx, "##dyncols", ncols,
                          ImGui.TableFlags_SizingStretchSame | ImGui.TableFlags_NoClip) then
        for ci, col in ipairs(DYN_COLS) do
          if (ci - 1) % ncols == 0 then ImGui.TableNextRow(ctx) end
          ImGui.TableSetColumnIndex(ctx, (ci - 1) % ncols)
          local cell_w = (select(1, ImGui.GetContentRegionAvail(ctx)))
          local pill_w = cell_w * 0.8
          if pill_w < 48 then pill_w = 48 end
          if pill_w > 96 then pill_w = 96 end
          local function center(px)
            local off = (cell_w - px) * 0.5
            if off > 0 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + off) end
          end
          center(ImGui.CalcTextSize(ctx, col.title))
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, widgets.colors.text_gold)
          ImGui.Text(ctx, col.title)
          ImGui.PopStyleColor(ctx)
          for _, item in ipairs(col.items) do
            center(item.pill and pill_w or knob_size)
            draw_fx_control(ctx, item, fx_live, knob_size, pill_w, compact)
          end
        end
        ImGui.EndTable(ctx)
      end

      active_pid = next_active               -- latch for next frame's suppression
      drain_pending(pad)
    end

    -- Publish dock changes the moment they happen, the way Swing_Browser
    -- already does. In-memory-until-cleanup was wrong: EON Dock Layout reads
    -- this key to work out which panes are sharing a docker, so a pane the
    -- user had dragged reported yesterday's home for as long as it ran, and
    -- "Spread panes" kept concluding there was nothing to separate
    -- (2026-08-27, "spread panes aint working... everytime").
    -- The old note here warned that saving churned ExtState "every frame" —
    -- that was save-unconditionally; this saves only on an actual CHANGE, so a
    -- settled dock costs one write and a drag costs a handful.
    if ImGui.GetWindowDockID then
      local cur = ImGui.GetWindowDockID(ctx)
      if cur ~= settings.dock_id then
        settings.dock_id = cur
        save_settings()
      end
    end

    ImGui.PopStyleVar(ctx, 2)
    ImGui.End(ctx)
  end

  widgets.pop_theme(ctx)

  if ui.is_open then reaper.defer(loop) else cleanup() end
end

loop = function()
  local ok, err = xpcall(frame, debug.traceback)
  if not ok then
    reaper.ShowConsoleMsg('\n[EON PAD FX ERROR]\n' .. tostring(err) .. '\n')
    cleanup()
  end
end

local function main()
  -- Single-instance guard via ExtState + heartbeat freshness (no gmem open-slot).
  if reaper.GetExtState("Swing", "padfx_running") == "1" then
    local hb = tonumber(reaper.GetExtState("Swing", "padfx_heartbeat")) or 0
    if (os.time() - hb) < 3 then return end  -- genuinely running
    reaper.SetExtState("Swing", "padfx_running", "0", false)  -- stale; relaunch
  end
  init()
  reaper.atexit(cleanup)
  -- EON Hub push IPC: window materializes on the first defer frame; the
  -- Hub's capture burst absorbs the gap (spec §3).
  if core.hub_notify then core.hub_notify("open", "padfx") end
  reaper.defer(loop)
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  reaper.ShowConsoleMsg('\n[EON PAD FX INIT ERROR]\n' .. tostring(err) .. '\n')
end
