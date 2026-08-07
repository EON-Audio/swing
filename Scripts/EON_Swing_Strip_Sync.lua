-- EON Swing Strip Sync — Path B controller (background defer companion)
-- (c) EON Studios — All Rights Reserved
--
-- Turns multi-out mode into a real drum rack: ensures every Swing multi-out
-- child track carries an "EON Drum Strip" JSFX, migrates the pad's internal
-- FX settings onto it, then keeps the two synced BOTH ways (~30 Hz):
--
--   Swing → strip : Swing publishes all 16 pads × FX params to a per-instance
--                   gmem band (GS_STRIP_*); changes are pushed to the strip
--                   via TrackFX_SetParam (params resolved BY NAME — never by
--                   slider index; sparse-slider lesson).
--   strip → Swing : strip param edits are written back through the band's
--                   command mailbox; the JSFX applies them like its own
--                   overlay edits (recalc + mark_dirty_pad: undoable).
--
-- While this script's heartbeat is fresh AND the instance is in multi-out,
-- Swing's internal per-pad FX chain emits DRY (strip carries the processing —
-- internal XOR child-track FX, Groove Agent model). If this script dies, the
-- heartbeat stalls and Swing's internal FX resume automatically.
--
-- The heartbeat for an instance only starts AFTER its strips are inserted
-- and migrated, so enabling sync never leaves a dry gap.
--
-- Child-track mapping: a send on the Swing track with I_SRCCHAN == pad*2
-- identifies that pad's child (same convention the Kit Bridge uses for
-- names and mute/solo). Strips are tracked by FX GUID persisted in
-- P_EXT:eon_strip_guid on the child track (indices shift; GUIDs don't).
--
-- TYPE:   system (background defer; safe to leave running)
-- REQUIRES: SWS (BR_GetMediaTrackSendInfo_Track), same as the Kit Bridge.

local function get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end
local SCRIPT_DIR = get_script_dir()
local sep = package.config:sub(1,1)
package.path = SCRIPT_DIR .. sep .. "?.lua;" .. (package.path or "")
local core = require("rk_lua_core")
local G = core.GMEM

if not reaper.BR_GetMediaTrackSendInfo_Track then
  reaper.MB("EON Swing Strip Sync requires the SWS extension.\n\nInstall from https://sws-extension.org and restart REAPER.",
            "EON Swing Strip Sync — Missing Dependency", 0)
  return
end

reaper.gmem_attach("Swing_Media_Transfer")
if reaper.set_action_options then reaper.set_action_options(1) end

-- Status reports (mode reconcile, takeover state) are diagnostics, not errors —
-- routine and noisy once you have a couple of Swing instances. Silent unless:
--   reaper.SetExtState("EON_Swing", "strip_sync_debug", "1", false)
local function DBG(msg)
  if reaper.GetExtState("EON_Swing", "strip_sync_debug") ~= "1" then return end
  reaper.ShowConsoleMsg(msg)
end

local NUM_PADS = G.NUM_PADS

-- FX_PID → strip slider NAME (stable API — matches EON_Drum_Strip.jsfx).
-- Sends (pids 15/16) included since bff82fa: the strip's send knobs are
-- remote controls (no local DSP) relayed to Swing's internal wet buses.
local PID_TO_STRIP = {
  [G.FX_PID_HPF_FREQ]     = "HPF Freq (Hz)",
  [G.FX_PID_LPF_FREQ]     = "LPF Freq (Hz)",
  [G.FX_PID_RESO]         = "Filter Q",
  [G.FX_PID_EQ_LO]        = "EQ Low Gain (dB)",
  [G.FX_PID_EQ_LO_FREQ]   = "EQ Low Freq (Hz)",
  [G.FX_PID_EQ_MID]       = "EQ Mid Gain (dB)",
  [G.FX_PID_EQ_MID_FREQ]  = "EQ Mid Freq (Hz)",
  [G.FX_PID_EQ_MID_Q]     = "EQ Mid Q",
  [G.FX_PID_EQ_MID2]      = "EQ Hi-Mid Gain (dB)",
  [G.FX_PID_EQ_MID2_FREQ] = "EQ Hi-Mid Freq (Hz)",
  [G.FX_PID_EQ_MID2_Q]    = "EQ Hi-Mid Q",
  [G.FX_PID_EQ_LO_Q]      = "EQ Low Q",
  [G.FX_PID_EQ_HI_Q]      = "EQ High Q",
  [G.FX_PID_EQ_HI]        = "EQ High Gain (dB)",
  [G.FX_PID_EQ_HI_FREQ]   = "EQ High Freq (Hz)",
  [G.FX_PID_CMP_AMT]      = "Comp Amount",
  [G.FX_PID_CMP_MODE]     = "Comp Mode",
  [G.FX_PID_BC_RATE]      = "Crush Rate",
  [G.FX_PID_BC_BITS]      = "Crush Bits",
  [G.FX_PID_SAT_DRV]      = "Drive",
  [G.FX_PID_DRV_MODE]     = "Drive Mode",
  [G.FX_PID_SND_DLY]      = "Delay Send",
  [G.FX_PID_SND_RVB]      = "Reverb Send",
}

-- Strip FX path relative to REAPER's Effects dir, derived from this script's
-- own location so dev (installer/src) and installed layouts both resolve.
local function strip_fx_addname()
  local effects_root = reaper.GetResourcePath() .. sep .. "Effects" .. sep
  -- SCRIPT_DIR = <...>/installer/src/Scripts or .Scripts → strip lives in
  -- the sibling Swing/ dir.
  local src_dir = SCRIPT_DIR:match("^(.*)[/\\]") or SCRIPT_DIR
  local abs = src_dir .. sep .. "Swing" .. sep .. "EON_Drum_Strip.jsfx"
  local rel = abs
  if abs:sub(1, #effects_root):lower() == effects_root:lower() then
    rel = abs:sub(#effects_root + 1)
  end
  return "JS:" .. rel:gsub("\\", "/")
end
local STRIP_ADDNAME = strip_fx_addname()

-- Same derivation for the FX-return contributors viewer (sibling Swing/ dir).
local function viewer_fx_addname()
  local effects_root = reaper.GetResourcePath() .. sep .. "Effects" .. sep
  local src_dir = SCRIPT_DIR:match("^(.*)[/\\]") or SCRIPT_DIR
  local abs = src_dir .. sep .. "Swing" .. sep .. "EON_FX_Return_View.jsfx"
  local rel = abs
  if abs:sub(1, #effects_root):lower() == effects_root:lower() then
    rel = abs:sub(#effects_root + 1)
  end
  return "JS:" .. rel:gsub("\\", "/")
end
local VIEWER_ADDNAME = viewer_fx_addname()

local EPS = 1e-5

-- FX_PID → strip slider FACTORY DEFAULT (mirrors EON_Drum_Strip.jsfx sanitize
-- defaults + slider defaults). Used only by the re-instantiation restore pass:
-- a param sitting at exactly its default after a strip re-init, while the band
-- holds a non-default value, is a stale-chunk wipe to be restored from the band.
local STRIP_DEFAULT = {
  [G.FX_PID_HPF_FREQ]     = 20,
  [G.FX_PID_LPF_FREQ]     = 20000,
  [G.FX_PID_RESO]         = 0.707,
  [G.FX_PID_EQ_LO]        = 0,
  [G.FX_PID_EQ_LO_FREQ]   = 200,
  [G.FX_PID_EQ_LO_Q]      = 0.7071,
  [G.FX_PID_EQ_MID]       = 0,
  [G.FX_PID_EQ_MID_FREQ]  = 1000,
  [G.FX_PID_EQ_MID_Q]     = 0.8,
  [G.FX_PID_EQ_MID2]      = 0,
  [G.FX_PID_EQ_MID2_FREQ] = 3000,
  [G.FX_PID_EQ_MID2_Q]    = 0.8,
  [G.FX_PID_EQ_HI]        = 0,
  [G.FX_PID_EQ_HI_FREQ]   = 5000,
  [G.FX_PID_EQ_HI_Q]      = 0.7071,
  [G.FX_PID_CMP_AMT]      = 0,
  [G.FX_PID_CMP_MODE]     = 0,
  [G.FX_PID_BC_RATE]      = 0,
  [G.FX_PID_BC_BITS]      = 16,
  [G.FX_PID_SAT_DRV]      = 0,
  [G.FX_PID_DRV_MODE]     = 0,
  [G.FX_PID_SND_DLY]      = 0,
  [G.FX_PID_SND_RVB]      = 0,
}
local DEF_EPS = 1e-3   -- defaults are exact; loose enough for quantized freqs

-- ── State ──────────────────────────────────────────────────────────────────
-- instances[inst_id] = {
--   track, slot, band, multi_out, hb_ok,
--   children[pad] = { tr, fxidx, guid, pmap = {pid→param_idx}, ready },
--   cache[pad][pid], expected[pad][pid], band_seq, cmd_seq, queue = {}
-- }
local instances = {}
local hb_counter = 0
local tick = 0
-- Strip re-instantiation pulse (GS_STRIP_REINIT_PULSE): the strip JSFX bumps it
-- in @init. When it changes we open a TIME-based window (re-armed on each pulse,
-- and extended while we are actively healing) during which a strip param sitting
-- at factory default is treated as a wipe and RESTORED. The window is generous
-- because a minimize can drop+rebuild the instance and recovery is observed to
-- take several seconds (trace: strip wiped, band stayed correct ~5 s, then the
-- rebuilt instance's empty cache let the wipe propagate into Swing).
local last_reinit_pulse = nil
local reinit_until = 0           -- time_precise() deadline; reinit active while now < this
local REINIT_HOLD_S = 8.0        -- covers the post-minimize instance rebuild + recovery

-- Durable "last good" strip values, keyed by Swing INSTANCE ID (not the inst
-- table) so they survive an instance drop/rebuild during a minimize. This is the
-- authority the re-instantiation restore falls back to: the band can only restore
-- what Swing still holds, but a minimize can wipe BOTH the strip AND Swing — the
-- Lua defer process keeps running through it, so last_good is the one record that
-- always survives. Updated only during stable (non-reinit) periods.
local last_good = {}
local function lg_get(id, pad, pid)
  local a = last_good[id]; if not a then return nil end
  local b = a[pad]; if not b then return nil end
  return b[pid]
end
local function lg_set(id, pad, pid, v)
  local a = last_good[id]; if not a then a = {}; last_good[id] = a end
  local b = a[pad]; if not b then b = {}; a[pad] = b end
  b[pid] = v
end

-- ── Helpers ────────────────────────────────────────────────────────────────

local function find_fx_by_guid(tr, guid)
  if not guid or guid == "" then return -1 end
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetFXGUID(tr, fx) == guid then return fx end
  end
  return -1
end

-- ── FX-return contributors viewer (EON_FX_Return_View.jsfx) ────────────────
-- The viewer sits on a Verb/Delay Return track and reads this instance's per-pad
-- send band from gmem. It needs the instance's registry SLOT, which is session-
-- volatile — so we push it live here. (bus_id is set by the bridge at build, but
-- we re-assert it from the P_EXT tag for robustness.)
local function _set_param_named(tr, fx, pat, val)
  for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(tr, fx, p, "")
    if pn and pn:find(pat) then
      if math.abs((reaper.TrackFX_GetParam(tr, fx, p) or -1e9) - val) > 1e-6 then
        reaper.TrackFX_SetParam(tr, fx, p, val)
      end
      return true
    end
  end
  return false
end

local function _find_viewer_fx(tr)
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    local _, fn = reaper.TrackFX_GetFXName(tr, fx, "")
    if fn and fn:find("FX Return View") then return fx end
  end
  return -1
end

-- Push inst.slot (+ bus) to the viewer on each of this instance's return tracks.
-- Returns silently when SWS (BR_*) is unavailable or there are no return tracks.
local function push_return_viewers(inst)
  local tr = inst.track
  if not tr or not reaper.BR_GetMediaTrackSendInfo_Track then return end
  local ns = reaper.GetTrackNumSends(tr, 0)
  for s = 0, ns - 1 do
    local dt = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
    if dt then
      local _, vt = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:EON_VERB_RETURN", "", false)
      local _, dd = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:EON_DELAY_RETURN", "", false)
      local bus = (vt == "1") and 0 or ((dd == "1") and 1 or nil)
      if bus then
        local vfx = _find_viewer_fx(dt)
        if vfx < 0 then
          -- Find-or-add, same pattern the strips use (query 0 → insert 1).
          vfx = reaper.TrackFX_AddByName(dt, VIEWER_ADDNAME, false, 1)
        end
        if vfx >= 0 then
          _set_param_named(dt, vfx, "Linked registry slot", inst.slot)
          _set_param_named(dt, vfx, "Bus", bus)
        end
      end
    end
  end
end

local function build_pmap(tr, fxidx)
  local by_name = {}
  for p = 0, reaper.TrackFX_GetNumParams(tr, fxidx) - 1 do
    local _, pname = reaper.TrackFX_GetParamName(tr, fxidx, p, "")
    -- The strip's sliders are hidden with a leading '-' (JSFX convention);
    -- REAPER may or may not include it in the reported name — accept both.
    by_name[pname] = p
    by_name[pname:gsub("^%-+", "")] = p
  end
  local pmap, missing = {}, nil
  for pid, sname in pairs(PID_TO_STRIP) do
    pmap[pid] = by_name[sname]
    if not pmap[pid] then missing = (missing and (missing .. ", ") or "") .. sname end
  end
  -- View-broadcast helper sliders (the ">ALL" feature; string keys, so they
  -- never collide with the numeric pid keys). Looked up by the slider LABEL that
  -- TrackFX_GetParamName reports — NOT the EEL var name. Absent on older strip
  -- builds → nil, in which case sync_view simply no-ops.
  pmap.vbcast = by_name["View Broadcast"]
  pmap.vset   = by_name["View Push"]
  pmap.vuset  = by_name["VU Set"]
  return pmap, missing
end

-- Ensure the strip exists on a child track; returns fxidx, pmap, was_new
-- (or nil + reason). was_new = the GUID didn't resolve, i.e. we inserted it
-- (or adopted an untracked one) — only those get the explicit migration
-- push. GUID re-adoptions (saved projects) keep their restored values and
-- converge via the first band publish, which avoids the visible value
-- flash on project open.
local function ensure_strip(tr)
  local _, guid = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:eon_strip_guid", "", false)
  local fxidx = find_fx_by_guid(tr, guid)
  local was_new = false
  if fxidx < 0 then
    -- GUID didn't resolve. It may have DRIFTED off the stored one (e.g. a JSFX
    -- recompile) while the strip is STILL on the track — so QUERY first and
    -- ADOPT the existing one (keep its live values, converge via the band).
    -- was_new must be true ONLY when we actually had to INSERT a strip: the
    -- migration that pushes Swing's pad values is meant for a brand-new strip,
    -- and running it on an adopted strip wipes the user's edits back to default
    -- (the "HPF reverts to default after alt-tab/recompile" bug).
    fxidx = reaper.TrackFX_AddByName(tr, STRIP_ADDNAME, false, 0)   -- query only
    if fxidx < 0 then
      fxidx = reaper.TrackFX_AddByName(tr, STRIP_ADDNAME, false, 1) -- insert new
      if fxidx < 0 then return nil, "AddByName failed (" .. STRIP_ADDNAME .. ")" end
      was_new = true
    end
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:eon_strip_guid",
      reaper.TrackFX_GetFXGUID(tr, fxidx) or "", true)
  end
  local pmap, missing = build_pmap(tr, fxidx)
  if missing then return nil, "param names not found: " .. missing end
  return fxidx, pmap, was_new
end

local function band_value(band, pad, pid)
  return reaper.gmem_read(band + G.GS_STRIP_PADS + pad * G.GS_STRIP_PAD_STRIDE + pid)
end

-- ── One-Mixer console tie (mixer VOL/PAN ↔ child track D_VOL/D_PAN) ────────
-- Swing publishes live p_gain/p_pan at per-pad band offsets VOL/PAN; while
-- strip_takeover is live the JSFX emits unity gain / center pan (DSP XOR), so
-- the child fader/pan is the ONE audible mix stage and these legs keep the two
-- surfaces equal. Authority model matches the strip params — the surface the
-- user grabbed wins:
--   band moved (LCD mixer drag / kit load / undo)   → drive the track
--   track moved (TCP/MCP fader drag, automation)    → post into Swing via the
--     existing INCMD_GAIN/PAN mailboxes (adopt = clamp + recalc +
--     mark_dirty_pad, exactly like an overlay edit — undoable)
--   first sight of a LOADED pad (script start / re-adoption) → CONSOLE wins
--     (existing sessions keep their REAPER mix; it flows into p_gain and from
--     there into kit saves)
--   pad we saw BLANK becomes loaded (kit load / sample drop) → SWING wins
--     (the kit's mix drives the console; a stale fader must not stomp it)
-- Gated on GS_STRIP_OFF_TIE_VER (=1 from builds that publish VOL/PAN AND carry
-- the DSP XOR): an older Swing leaves the flag 0 → tie fully inert, no
-- double-gain from a mixed-version deploy. Blank pads publish VOL = -1 →
-- fully hands-off (a blank pad's fader is the user's business, same as M/S).
local TIE_EPS = 1e-4

local function tie_channel(inst, pad, ch, st, bv, tr_param, incmd_off, lo, hi)
  local tv = reaper.GetMediaTrackInfo_Value(ch.tr, tr_param)
  if st.pend ~= nil then
    if math.abs(bv - st.pend) <= TIE_EPS then
      st.pend = nil            -- band confirms Swing adopted our post
      st.cache = bv
    else
      -- Unconfirmed. While a post is in flight the band is NEVER allowed to
      -- drive the track (forward-pushing here yanked the fader backwards
      -- mid-drag: during a drag we post a chain of values, Swing consumes
      -- one per block, and the band echoes an EARLIER post before the
      -- newest one lands).
      if math.abs(tv - st.exp) > TIE_EPS then
        -- Fader still moving → refresh the payload.
        st.exp = tv
        st.pend = math.max(lo, math.min(hi, tv))  -- JSFX clamps the same way
        st.pbv = bv
        core.post_pad_incmd(inst.slot, incmd_off, pad, st.pend)
      elseif st.pbv == nil or math.abs(bv - st.pbv) > TIE_EPS then
        -- Band moved but not to our pend: the echo of an intermediate post
        -- from this same drag trailing the newest payload. Re-assert the
        -- value the user's surface holds and re-baseline. A concurrent LCD
        -- edit lands here too → the physically-held fader wins,
        -- deterministically, and the tie converges on the next confirm.
        st.pbv = bv
        core.post_pad_incmd(inst.slot, incmd_off, pad, st.pend)
      end
      return
    end
  end
  if st.exp == nil then
    -- Adoption pass: console wins (see block comment).
    st.exp = tv; st.cache = bv
    if math.abs(tv - bv) > TIE_EPS then
      st.pend = math.max(lo, math.min(hi, tv))
      st.pbv = bv
      core.post_pad_incmd(inst.slot, incmd_off, pad, st.pend)
    end
  elseif math.abs(tv - st.exp) > TIE_EPS then
    -- Track moved → Swing follows.
    st.exp = tv
    st.pend = math.max(lo, math.min(hi, tv))
    st.pbv = bv
    core.post_pad_incmd(inst.slot, incmd_off, pad, st.pend)
  elseif st.cache == nil or math.abs(bv - st.cache) > TIE_EPS then
    -- Band moved → track follows.
    st.cache = bv
    if math.abs(tv - bv) > TIE_EPS then
      reaper.SetMediaTrackInfo_Value(ch.tr, tr_param, bv)
      st.exp = reaper.GetMediaTrackInfo_Value(ch.tr, tr_param)  -- readback
    end
  end
end

local function sync_mixer_tie(inst)
  if (reaper.gmem_read(inst.band + G.GS_STRIP_OFF_TIE_VER) or 0) < 1 then return end
  inst.tie = inst.tie or {}
  for pad, ch in pairs(inst.children) do
    local bv = band_value(inst.band, pad, G.GS_STRIP_PAD_OFF_VOL)
    if bv < -0.5 then
      -- Blank pad → hands-off; the marker makes a later blank→loaded
      -- transition seed the console FROM Swing (kit wins).
      local t = inst.tie[pad]
      if not t or t.vol then
        inst.tie[pad] = { seen_blank = true }
        DBG(string.format("[tie] pad %d blank — hands-off (marker set)\n", pad))
      end
    else
      local t = inst.tie[pad]
      if not t or not t.vol then
        local from_blank = t and t.seen_blank
        t = { vol = {}, pan = {} }
        if from_blank then
          -- Loaded while we watched (kit load / sample drop): Swing's values
          -- drive the console; settle state so no adoption post fires.
          local bp = band_value(inst.band, pad, G.GS_STRIP_PAD_OFF_PAN)
          local pre = reaper.GetMediaTrackInfo_Value(ch.tr, "D_VOL")
          reaper.SetMediaTrackInfo_Value(ch.tr, "D_VOL", bv)
          reaper.SetMediaTrackInfo_Value(ch.tr, "D_PAN", bp)
          t.vol.exp = reaper.GetMediaTrackInfo_Value(ch.tr, "D_VOL"); t.vol.cache = bv
          t.pan.exp = reaper.GetMediaTrackInfo_Value(ch.tr, "D_PAN"); t.pan.cache = bp
          local _, tn = reaper.GetSetMediaTrackInfo_String(ch.tr, "P_NAME", "", false)
          DBG(string.format("[tie] pad %d blank→loaded: SEED tr#%d '%s' D_VOL %.3f → want %.3f, readback %.3f (pan %.2f)\n",
            pad, math.floor(reaper.GetMediaTrackInfo_Value(ch.tr, "IP_TRACKNUMBER") or -1),
            tostring(tn), pre, bv, t.vol.exp, bp))
        else
          DBG(string.format("[tie] pad %d first sight LOADED: adopt pass (console wins), band=%.3f\n", pad, bv))
        end
        inst.tie[pad] = t
      end
      tie_channel(inst, pad, ch, t.vol, bv, "D_VOL", G.INCMD_GAIN_OFF, 0, 8)
      tie_channel(inst, pad, ch, t.pan,
        band_value(inst.band, pad, G.GS_STRIP_PAD_OFF_PAN), "D_PAN", G.INCMD_PAN_OFF, -1, 1)
    end
  end
end

-- Push one value Swing→strip; expected = post-quantization readback so the
-- strip's slider steps (e.g. 1 Hz freqs) can never echo back as fake edits.
local function push_to_strip(inst, pad, pid, v)
  local ch = inst.children[pad]; if not ch then return end
  reaper.TrackFX_SetParam(ch.tr, ch.fxidx, ch.pmap[pid], v)
  local rb = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
  inst.expected[pad][pid] = rb
end

-- Drop children whose MediaTrack pointer went stale (user deleted the
-- multi-out tracks, undo, project switch). Without this the per-tick
-- GetParam calls crash on the dead pointer — the structure rescan only
-- runs ~1 Hz. Returns true if any children remain.
local function validate_children(inst)
  for pad, ch in pairs(inst.children) do
    if not reaper.ValidatePtr2(0, ch.tr, "MediaTrack*") then
      inst.children[pad] = nil
      if inst.tie then inst.tie[pad] = nil end
    end
  end
  if next(inst.children) == nil then
    inst.hb_ok = false   -- heartbeat stops → Swing's internal FX resume
    return false
  end
  return true
end

-- ── Structure scan (~1 Hz): instances, children, strips ───────────────────

local function registry_alive_slots()
  local now = reaper.time_precise()
  local alive = {}
  for s = 0, G.GS_INST_REG_MAX - 1 do
    local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
    local id = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID))
    local hb = reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT)
    if id > 0 and hb > 0 and (now - hb) < G.GS_INST_REG_TIMEOUT then alive[id] = s end
  end
  return alive
end

local function scan_structure()
  local alive = registry_alive_slots()
  local seen = {}

  for ti = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, ti)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
      local rv, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
      local is_swing = (rv and ident:find("DrumKit_ReaKit"))
                    or fname:find("DrumKit_ReaKit")
                    or fname:match("^JS: Swing")
      if is_swing then
        local id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        local slot = alive[id]
        if slot then
          seen[id] = true
          local inst = instances[id]
          if not inst then
            inst = { children = {}, cache = {}, expected = {}, inflight = {},
                     queue = {}, band_seq = -1, cmd_seq = 0, hb_ok = false }
            for p = 0, NUM_PADS - 1 do
              inst.cache[p] = {}; inst.expected[p] = {}; inst.inflight[p] = {}
            end
            instances[id] = inst
          end
          inst.id    = id
          inst.track = tr
          inst.slot  = slot
          inst.band  = G.GS_STRIP_BASE + slot * G.GS_STRIP_STRIDE
          -- Seed cmd_seq from the band's CURRENT counter whenever the band
          -- (re)binds — a fresh inst.cmd_seq of 0 written into a band whose cell
          -- already holds e.g. 47 makes our first CMD_SEQ=1 REGRESS below the
          -- JSFX's strip_cmd_last, so it replays the stale CMD cells (pad-0
          -- stomp, bug A — the Lua-side twin of the JSFX re-adopt). Never
          -- regress: our next write (cmd_seq+1) then lands monotonic above the
          -- cell and the JSFX consumes it as a genuine edit.
          if inst._cmd_band ~= inst.band then
            inst._cmd_band = inst.band
            inst.cmd_seq = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_CMD_SEQ) or 0
          end
          inst.multi_out = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_MULTIOUT) > 0.5
          -- Feed this instance's slot to its Verb/Delay return-track viewers.
          if inst.multi_out then push_return_viewers(inst) end

          -- Mode reconciliation. The bridge sets B_MAINSEND=0 when it BUILDS
          -- multi-out (audio reaches the master via the child sends) but
          -- nothing ever restored it on the way back — switching to stereo
          -- (or deleting the children) left the track orphaned = total
          -- silence. Enforce, idempotently, per mode:
          --   stereo:    master send ON,  pad-channel sends muted
          --   multi-out: master send OFF, pad-channel sends live
          do
            local want_main = inst.multi_out and 0 or 1
            if reaper.GetMediaTrackInfo_Value(tr, "B_MAINSEND") ~= want_main then
              reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", want_main)
              DBG(string.format(
                "[strip_sync] inst %d: %s — master send %s\n",
                id, inst.multi_out and "multi-out" or "stereo",
                want_main == 1 and "restored" or "off"))
            end
            local want_send_mute = inst.multi_out and 0 or 1
            local nsends = reaper.GetTrackNumSends(tr, 0)
            for s = 0, nsends - 1 do
              local src_pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN"))
              if src_pad >= 0 and src_pad < NUM_PADS then
                if reaper.GetTrackSendInfo_Value(tr, 0, s, "B_MUTE") ~= want_send_mute then
                  reaper.SetTrackSendInfo_Value(tr, 0, s, "B_MUTE", want_send_mute)
                end
              end
            end
          end

          if inst.multi_out then
            -- Map pad → child track via the send convention, adopt strips.
            inst.report = ""
            local found = {}
            local sends = reaper.GetTrackNumSends(tr, 0)
            for s = 0, sends - 1 do
              local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN"))
              if pad >= 0 then
                -- (nesting kept: core.srcchan_pad already rejects no-audio/odd)
                if pad < NUM_PADS then
                  local dest = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
                  if dest then
                    local ch = inst.children[pad]
                    local fxidx, pmap, was_new = ensure_strip(dest)
                    if not fxidx then
                      inst.report = inst.report .. string.format("  pad %d: SKIPPED — %s\n", pad, tostring(pmap))
                    end
                    if fxidx then
                      if not ch or ch.tr ~= dest or ch.fxidx ~= fxidx then
                        local prev_tr = ch and ch.tr
                        ch = { tr = dest, fxidx = fxidx, pmap = pmap, ready = true }
                        inst.children[pad] = ch
                        -- One-Mixer tie: a re-mapped child TRACK invalidates the
                        -- tie bookkeeping (exp refers to the old track) → reset
                        -- so the next sync pass re-adopts (console wins).
                        if inst.tie and prev_tr ~= dest then inst.tie[pad] = nil end
                        if was_new then
                          -- Freshly inserted strip: migrate Swing's current
                          -- values onto it (Swing = source of truth).
                          for pid in pairs(PID_TO_STRIP) do
                            local v = band_value(inst.band, pad, pid)
                            inst.cache[pad][pid] = v
                            push_to_strip(inst, pad, pid, v)
                          end
                          -- One-Mixer tie: a fresh console lane starts at unity —
                          -- seed the fader/pan from Swing so the kit's internal
                          -- mix carries over (Swing wins on BUILD), and settle
                          -- the tie state so the first sync pass doesn't adopt
                          -- unity back into p_gain. Old Swing builds (tie flag 0)
                          -- and blank pads (VOL sentinel -1) skip the seed.
                          if (reaper.gmem_read(inst.band + G.GS_STRIP_OFF_TIE_VER) or 0) >= 1 then
                            local bv = band_value(inst.band, pad, G.GS_STRIP_PAD_OFF_VOL)
                            if bv >= 0 then
                              local bp = band_value(inst.band, pad, G.GS_STRIP_PAD_OFF_PAN)
                              reaper.SetMediaTrackInfo_Value(dest, "D_VOL", bv)
                              reaper.SetMediaTrackInfo_Value(dest, "D_PAN", bp)
                              inst.tie = inst.tie or {}
                              inst.tie[pad] = {
                                vol = { exp = reaper.GetMediaTrackInfo_Value(dest, "D_VOL"), cache = bv },
                                pan = { exp = reaper.GetMediaTrackInfo_Value(dest, "D_PAN"), cache = bp },
                              }
                            end
                          end
                        end
                        -- GUID re-adoption: cache/expected stay nil — the
                        -- next band publish (~90 ms) does one convergence
                        -- pass without flashing already-correct values.
                      else
                        ch.pmap = pmap
                      end
                      found[pad] = true
                    end
                  end
                end
              end
            end
            -- Drop children whose track/send disappeared.
            for pad in pairs(inst.children) do
              if not found[pad] then
                inst.children[pad] = nil
                if inst.tie then inst.tie[pad] = nil end
              end
            end
            inst.hb_ok = next(inst.children) ~= nil
            local n = 0; for _ in pairs(inst.children) do n = n + 1 end
            local rep = string.format("[strip_sync] inst %d: multi-out, %d/%d strips ready%s\n",
              id, n, NUM_PADS, inst.hb_ok and " — takeover LIVE" or " — idle (no strips)") .. inst.report
            if rep ~= inst.last_report then
              inst.last_report = rep
              DBG(rep)
            end
          else
            inst.children = {}
            inst.hb_ok = false
            local rep = string.format("[strip_sync] inst %d: not multi-out — idle\n", id)
            if rep ~= inst.last_report then
              inst.last_report = rep
              DBG(rep)
            end
          end
        end
      end
    end
  end

  for id in pairs(instances) do
    if not seen[id] then instances[id] = nil end
  end
end

-- ── Param sync (every tick) ────────────────────────────────────────────────

local function sync_instance(inst, reinit)
  if not inst.multi_out or not inst.hb_ok then return end
  -- The Swing track or the child tracks may have been deleted since the
  -- last structure scan — never touch a stale pointer.
  if not reaper.ValidatePtr2(0, inst.track, "MediaTrack*") then
    inst.children = {}
    inst.hb_ok = false
    return
  end
  if not validate_children(inst) then return end

  -- Heartbeat: strips are adopted+migrated → Swing may go dry.
  reaper.gmem_write(inst.band + G.GS_STRIP_OFF_LUA_HB, hb_counter)


  -- ── Re-instantiation restore (the "EQ/HPF reverts on minimize" root fix) ──
  -- A minimize closes the audio device; on restore REAPER RE-INSTANTIATES the
  -- strip JSFX and may restore a STALE state chunk, so the strip's sliders come
  -- back at FACTORY DEFAULT and a live edit is lost (trace-confirmed: strip
  -- collapses to default; the band stays correct for several seconds, then the
  -- rebuilt instance's "strip wins" branch propagates the wipe into Swing).
  -- The strip @init bumps GS_STRIP_REINIT_PULSE; `reinit` is true for a generous
  -- window after that (it must outlast the instance drop/rebuild). During it, any
  -- param sitting at its exact default is a suspected wipe → restore it from the
  -- durable intended value (last_good, else the band) and RE-ASSERT into Swing so
  -- a wiped Swing pad heals too. Only runs inside the pulse window, so normal
  -- editing (incl. deliberately turning a filter OFF) is untouched.
  if reinit then
    local now0 = reaper.time_precise()
    for pad, ch in pairs(inst.children) do
      for pid in pairs(PID_TO_STRIP) do
        local def = STRIP_DEFAULT[pid]
        if def ~= nil and not inst.inflight[pad][pid] then
          local sv = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
          if math.abs(sv - def) <= DEF_EPS then
            -- strip is at factory default — find the durable intended value.
            local good = inst.id and lg_get(inst.id, pad, pid)
            if good == nil then
              local bv = band_value(inst.band, pad, pid)
              if math.abs(bv - def) > DEF_EPS then good = bv end
            end
            if good ~= nil and math.abs(good - def) > DEF_EPS then
              push_to_strip(inst, pad, pid, good)        -- expected = readback
              local rb = inst.expected[pad][pid]
              inst.cache[pad][pid] = rb
              -- re-assert into Swing too (band may also have been wiped)
              inst.inflight[pad][pid] = { v = rb, t = now0 }
              local found, qi = false, 1
              while qi <= #inst.queue do
                if inst.queue[qi].pad == pad and inst.queue[qi].pid == pid then
                  inst.queue[qi].val = rb; found = true; break
                end
                qi = qi + 1
              end
              if not found then inst.queue[#inst.queue + 1] = { pad = pad, pid = pid, val = rb } end
              -- keep the window alive while we are actively healing
              reinit_until = math.max(reinit_until, now0 + 2.0)
            end
          end
        end
      end
    end
  end

  -- Swing → strip: STRIP-AUTHORITATIVE conflict resolution. Swing's band updates
  -- are applied to the strip ONLY when the user has not changed the strip since we
  -- last set it (sv == expected). Any value the user has set on the strip WINS —
  -- Swing's (often default) pad value must never overwrite it. This fixes "strip
  -- HPF reverts to default after alt-tab / minimize": on those events Swing's
  -- @block and/or the defer stall, the strip→Swing writeback doesn't land in time,
  -- and the band then carries Swing's default. The old code let that default win
  -- two ways — the inflight 1.5 s timeout fell through to a band push, and a
  -- heartbeat-stall instance rebuild (empty cache) pushed the band value — both of
  -- which yanked the user's edit back to default. Now the strip's own value is
  -- re-asserted and propagated to Swing instead.
  local now = reaper.time_precise()
  local seq = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_SEQ)
  if seq ~= inst.band_seq then
    inst.band_seq = seq
    for pad, ch in pairs(inst.children) do
      for pid in pairs(PID_TO_STRIP) do
        local bv = band_value(inst.band, pad, pid)
        local sv = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
        local infl = inst.inflight[pad][pid]
        if infl then
          if math.abs(bv - infl.v) <= EPS then
            -- Swing's band now carries our value → confirmed, settle.
            inst.inflight[pad][pid] = nil; infl = nil
          else
            -- NOT confirmed yet. NO give-up timeout (this matches the INCMD /
            -- adopt-protocol pattern used by every other ReaKit sync): until
            -- Swing adopts our edit, the band still carries Swing's stale/default
            -- value, so it must NEVER be pushed onto the strip — letting it win
            -- after a timeout was the "reverts to default after minimize" bug.
            -- Keep ASSERTING our value to Swing (re-queue, coalesced) so a
            -- writeback that didn't land (defer/audio stalled while minimized)
            -- keeps retrying until the band confirms it.
            local found, qi = false, 1
            while qi <= #inst.queue do
              if inst.queue[qi].pad == pad and inst.queue[qi].pid == pid then
                inst.queue[qi].val = infl.v; found = true; break
              end
              qi = qi + 1
            end
            if not found then inst.queue[#inst.queue + 1] = { pad = pad, pid = pid, val = infl.v } end
          end
          -- while inflight: never push band → strip for this param
        end
        if not infl then
          local ev = inst.expected[pad][pid]
          if ev ~= nil and math.abs(sv - ev) <= EPS then
            -- User hasn't touched the strip → apply Swing's update.
            local cv = inst.cache[pad][pid]
            if cv == nil or math.abs(bv - cv) > EPS then
              inst.cache[pad][pid] = bv
              push_to_strip(inst, pad, pid, bv)
            end
          elseif math.abs(sv - bv) > EPS then
            -- The strip holds a value Swing's band does not (a user edit, or a
            -- re-adoption after a heartbeat-stall wipe). STRIP WINS: keep it and
            -- propagate strip→Swing so Swing's pad converges to the strip.
            inst.cache[pad][pid] = sv
            inst.expected[pad][pid] = sv
            inst.inflight[pad][pid] = { v = sv, t = now }
            local found, qi = false, 1
            while qi <= #inst.queue do
              if inst.queue[qi].pad == pad and inst.queue[qi].pid == pid then
                inst.queue[qi].val = sv; found = true; break
              end
              qi = qi + 1
            end
            if not found then inst.queue[#inst.queue + 1] = { pad = pad, pid = pid, val = sv } end
          else
            -- strip already equals band → just sync bookkeeping.
            inst.cache[pad][pid] = bv
            inst.expected[pad][pid] = sv
          end
        end
      end
    end
  end

  -- strip → Swing: a strip value that differs from what WE last set there is
  -- a user edit; queue it for the mailbox (one per tick — knob drags are one
  -- param at a time, and the JSFX consumes one per block). Queue entries
  -- COALESCE per (pad,pid): during a drag only the latest value matters —
  -- replaying the intermediate history through the mailbox is what built
  -- the stale backlog.
  for pad, ch in pairs(inst.children) do
    for pid in pairs(PID_TO_STRIP) do
      local sv = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
      local ev = inst.expected[pad][pid]
      if ev ~= nil and math.abs(sv - ev) > EPS then
        inst.expected[pad][pid] = sv
        inst.cache[pad][pid] = sv
        inst.inflight[pad][pid] = { v = sv, t = now }
        -- A genuine strip edit observed OUTSIDE a re-init window is the user's
        -- intent → record it as durable. Inside the window we never get here for
        -- a wipe (the restore pass settled expected first), but guard anyway.
        if not reinit and inst.id then lg_set(inst.id, pad, pid, sv) end
        local found = false
        local i = 1
        while i <= #inst.queue do
          local q = inst.queue[i]
          if q.pad == pad and q.pid == pid then q.val = sv; found = true; i = #inst.queue end
          i = i + 1
        end
        if not found then
          inst.queue[#inst.queue + 1] = { pad = pad, pid = pid, val = sv }
        end
      elseif not reinit and inst.id and not inst.inflight[pad][pid] then
        -- Settled value (strip matches what we last set; nothing pending) →
        -- keep the durable record current, including deliberate defaults.
        lg_set(inst.id, pad, pid, sv)
      end
    end
  end

  -- Drain one queued edit into the mailbox (CMD_SEQ written LAST).
  if #inst.queue > 0 then
    local cmd = table.remove(inst.queue, 1)
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_PAD, cmd.pad)
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_PID, cmd.pid)
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_VAL, cmd.val)
    inst.cmd_seq = inst.cmd_seq + 1
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_SEQ, inst.cmd_seq)
  end

  -- One-Mixer console tie: mixer VOL/PAN ↔ child track fader/pan.
  sync_mixer_tie(inst)
end

-- ── Embedded view broadcast (the strip ">ALL" button) ────────────────────────
-- A strip's ">ALL" button sets its strip_view_bcast slider to (mode+1). We read
-- it, clear it, remember the instance's shared view (inst.view_mode), and push
-- that mode to EVERY sibling strip's strip_view_set slider (the JSFX edge-adopts
-- it). New / post-re-init strips converge to inst.view_mode on the next pass.
-- Only writes strip_view_set when it is stale, so there are no continuous param
-- writes once everyone agrees.
local function sync_view(inst)
  if not inst.multi_out or not inst.hb_ok then return end
  if not reaper.ValidatePtr2(0, inst.track, "MediaTrack*") then return end

  -- 1. Detect (and consume) a broadcast request from any sibling.
  local req = nil
  for pad, ch in pairs(inst.children) do
    local bi = ch.pmap and ch.pmap.vbcast
    if bi and reaper.ValidatePtr2(0, ch.tr, "MediaTrack*") then
      local bv = math.floor((reaper.TrackFX_GetParam(ch.tr, ch.fxidx, bi)) + 0.5)
      if bv > 0 then
        reaper.TrackFX_SetParam(ch.tr, ch.fxidx, bi, 0)       -- consume the request
        req = math.max(0, math.min(3, bv - 1))
      end
    end
  end
  -- Swing-header request: the Swing instance writes (mode+1) to the band when its
  -- STRIPS selector changes. Same handling as a strip ">ALL" — either feeds req.
  local breq = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_VIEW_REQ)
  if breq and breq > 0.5 then
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_VIEW_REQ, 0)  -- consume the request
    req = math.max(0, math.min(3, math.floor(breq + 0.5) - 1))
  end
  if req ~= nil then inst.view_mode = req end

  -- Swing-header VU request: header VU selector → (style+2), 0 = idle. -1 = AUTO.
  local vreq = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_VU_REQ)
  if vreq and vreq > 0.5 then
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_VU_REQ, 0)    -- consume the request
    inst.vu_style = math.max(-1, math.min(10, math.floor(vreq + 0.5) - 2))
  end

  -- 2. Push the shared view mode / VU face to every sibling whose pushed value is stale.
  if inst.view_mode ~= nil then
    local want = inst.view_mode + 1
    for pad, ch in pairs(inst.children) do
      local si = ch.pmap and ch.pmap.vset
      if si and reaper.ValidatePtr2(0, ch.tr, "MediaTrack*") then
        local cur = math.floor((reaper.TrackFX_GetParam(ch.tr, ch.fxidx, si)) + 0.5)
        if cur ~= want then reaper.TrackFX_SetParam(ch.tr, ch.fxidx, si, want) end
      end
    end
  end
  if inst.vu_style ~= nil then
    local vwant = inst.vu_style + 2   -- encode style+2 (1 = AUTO .. 12 = Black)
    for pad, ch in pairs(inst.children) do
      local vi = ch.pmap and ch.pmap.vuset
      if vi and reaper.ValidatePtr2(0, ch.tr, "MediaTrack*") then
        local cur = math.floor((reaper.TrackFX_GetParam(ch.tr, ch.fxidx, vi)) + 0.5)
        if cur ~= vwant then reaper.TrackFX_SetParam(ch.tr, ch.fxidx, vi, vwant) end
      end
    end
  end
end

-- ── Main loop ──────────────────────────────────────────────────────────────

local function loop()
  tick = tick + 1
  hb_counter = hb_counter + 1

  -- Fast scan (~170 ms) until every detected multi-out instance has its
  -- strips adopted, then settle to ~1 Hz. Cuts the project-open adoption
  -- lapse from "up to a second per stage" to near-instant without paying
  -- the full track-scan cost forever.
  local all_ready = true
  local any = false
  for _, inst in pairs(instances) do
    any = true
    if inst.multi_out and not inst.hb_ok then all_ready = false end
  end
  -- No Swing found at all: stay fast only for the first ~10 s (startup
  -- race), then settle — don't burn 6 Hz track scans on non-Swing projects.
  local scan_every = ((any and all_ready) or (not any and tick > 300)) and 30 or 5
  if tick % scan_every == 1 then scan_structure() end

  -- Strip re-instantiation detection: the strip JSFX bumps GS_STRIP_REINIT_PULSE
  -- in @init. On any change, arm a generous TIME window (REINIT_HOLD_S) during
  -- which sync_instance restores wiped-to-default strips from last_good. Must be
  -- time-based (not a tick count): a minimize drops+rebuilds the instance and the
  -- wipe can surface several seconds after the pulse.
  local pulse = reaper.gmem_read(G.GS_STRIP_REINIT_PULSE)
  if last_reinit_pulse == nil then
    last_reinit_pulse = pulse
  elseif pulse ~= last_reinit_pulse then
    last_reinit_pulse = pulse
    reinit_until = reaper.time_precise() + REINIT_HOLD_S
  end
  local reinit = reaper.time_precise() < reinit_until
  -- (2026-07-09: the pad-0 stomp kill switch + restore gate that lived here
  -- were removed after the real root causes landed — strip-CMD band re-adopt
  -- in Swing_ReaKit @block, the @gfx/@block scratch-global race fix, and the
  -- v1 header relocation. See project_strip_sync_pad0_stomp.)

  for _, inst in pairs(instances) do sync_instance(inst, reinit); sync_view(inst) end

  reaper.defer(loop)
end

-- ── Self-register as startup action (one-time, first manual run) ──────────
-- Same self-cleaning __startup.lua block the Kit Bridge uses: runs this
-- script on every REAPER launch; if the file is removed (uninstall), the
-- block strips itself out and clears the ExtState so reinstalls re-register.
local SCRIPT_NAME = "EON_Swing_Strip_Sync"
local function self_register()
  local _, script_path = reaper.get_action_context()
  local key = SCRIPT_NAME .. "_registered_v1"
  local marker = "-- EON:" .. SCRIPT_NAME

  if reaper.GetExtState(SCRIPT_NAME, key) == "1" then
    local startup_path = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
    local fr = io.open(startup_path, "r")
    if fr then
      local content = fr:read("*a"); fr:close()
      if content:find(marker .. " BEGIN", 1, true) then return end
    end
    reaper.SetExtState(SCRIPT_NAME, key, "", true)
  end

  local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
  if not cmd_id or cmd_id <= 0 then return end

  local startup_path = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
  local existing = ""
  local fr = io.open(startup_path, "r")
  if fr then existing = fr:read("*a"); fr:close() end

  local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
  existing = existing:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")

  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then reaper.Main_OnCommand(id,0) else\n" ..
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); if f then local c=f:read('*a'); f:close()\n" ..
    "    c=c:gsub('\\n?%-%- EON:" .. SCRIPT_NAME .. " BEGIN.-%-%- EON:" .. SCRIPT_NAME .. " END\\n?','')\n" ..
    "    local fw=io.open(p,'w'); if fw then fw:write(c); fw:close() end end\n" ..
    "  reaper.SetExtState('" .. SCRIPT_NAME .. "','" .. key .. "','',true)\n" ..
    "end end\n" ..
    marker .. " END\n"

  local fw = io.open(startup_path, "w")
  if fw then fw:write(existing .. block); fw:close() end

  reaper.SetExtState(SCRIPT_NAME, key, "1", true)
  reaper.ShowConsoleMsg("[strip_sync] registered as startup action (auto-starts with REAPER).\n")
end
self_register()

DBG("[strip_sync] started: " .. STRIP_ADDNAME .. "\n")
loop()
