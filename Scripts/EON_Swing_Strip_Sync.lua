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
-- Which copy runs: this file's own folder (debug.getinfo; get_action_context would name a dofile host). A rig that
-- stages another checkout's scripts reads it to prove the Strip Sync under test is the staged one. Non-persistent.
reaper.SetExtState(core.ALIVE_STRIP_SYNC_SECTION, "script_dir", SCRIPT_DIR, false)

-- Status reports (mode reconcile, takeover state) are diagnostics, not errors —
-- routine and noisy once you have a couple of Swing instances. Silent unless:
--   reaper.SetExtState("EON_Swing", "strip_sync_debug", "1", false)
local function DBG(msg)
  if reaper.GetExtState("EON_Swing", "strip_sync_debug") ~= "1" then return end
  reaper.ShowConsoleMsg(msg)
end

local NUM_PADS = G.NUM_PADS
-- Banks B..D's Drum Strips (2026-10-15; the user: "link bank B to D pads to their Drum Strips the way bank A works").
-- A B..D pad has a track of its own only while it is split out onto pair SPLIT0 + k (k < SPLIT_N); that track's
-- strip belongs to the pair's OWNER, the lowest playable slot on it, which Swing publishes in its split band
-- (G.GS_SPLIT_*) with that slot's record. A child's key is its bank A pad (0..15) or its split pair (22..31).
local SPLIT0, SPLIT_N = G.GS_SPLIT_PAIR0, G.GS_SPLIT_N

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
  [G.FX_PID_SND_SMASH]    = "Smash Send",
}

-- ⚠️ These used to derive the add-name from SCRIPT_DIR's parent + "/Swing/",
-- which assumes Scripts/ and Swing/ are SIBLINGS. That is true ONLY in the dev
-- repo. Both shipped layouts put Lua under <resource>/Scripts/... and JSFX under
-- <resource>/Effects/..., so the derived path pointed into Scripts/, no file was
-- there, AddByName returned -1, and the strip silently never appeared -- on every
-- customer install, every platform, every channel. core.jsfx_addname resolves
-- against the Effects tree itself and verifies the file exists.
-- Resolved LAZILY (not at load) so a hint track can be supplied and so a failure
-- is reported at the moment of use rather than losing the reason at startup.
local ADDNAME_WARNED = {}
-- A MISS is remembered for ADDNAME_RETRY_S (core caches only hits, so a mid-session install still heals):
-- every miss is a full recursive walk of the Effects tree with forced rescans, and the scan asked once per pad
-- track per pass -- a missing EON_Drum_Strip.jsfx cost ~96 walks a second per multi-out instance, for the
-- whole session, since hb_ok never turned true and the scan stayed at 6 Hz.
local ADDNAME_MISS_AT = {}
local ADDNAME_RETRY_S = 30
local function addname_for(basename, hint_tr, hint_fx)
  local miss_at = ADDNAME_MISS_AT[basename]
  if miss_at and reaper.time_precise() - miss_at < ADDNAME_RETRY_S then return nil end
  local name, _, why = core.jsfx_addname(basename, hint_tr, hint_fx)
  if not name then ADDNAME_MISS_AT[basename] = reaper.time_precise() end
  if not name and not ADDNAME_WARNED[basename] then
    -- ONE console line, unconditionally. This class of bug survived to release
    -- precisely because its only diagnostic went to a DBG() that is off by
    -- default -- see the note on DBG above. Do not route this through it.
    ADDNAME_WARNED[basename] = true
    reaper.ShowConsoleMsg("[EON] Could not locate " .. basename ..
      " under the Effects folder -- it will not be inserted.\n  " ..
      tostring(why) .. "\n  Reinstall Swing, or check the plugin is present.\n")
  end
  return name
end
local function strip_addname(hint_tr, hint_fx)
  return addname_for("EON_Drum_Strip.jsfx", hint_tr, hint_fx)
end
local function viewer_addname(hint_tr, hint_fx)
  return addname_for("EON_FX_Return_View.jsfx", hint_tr, hint_fx)
end

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
  [G.FX_PID_SND_SMASH]    = 0,
}
local DEF_EPS = 1e-3   -- defaults are exact; loose enough for quantized freqs

-- FX_PID → the strip slider's STEP (mirrors EON_Drum_Strip.jsfx; um_test.py compares). REAPER keeps a JSFX slider on
-- its steps: Swing's EQ Q 0.7071 pushed onto a strip reads back 0.71 (measured 2026-10-27, the UndoMap rig's trace).
-- A strip met for the first time (a saved project, or one the Kit Bridge put on inside a build) that holds Swing's
-- value as near as its slider can is not the user's edit: without this its 0.71 "won" and was written into Swing,
-- the next undo / redo brought Swing's 0.7071 back, and the sync pushed it onto the strip again -- an undo point of
-- its own on top of the redone build.
local STRIP_STEP = {
  [G.FX_PID_HPF_FREQ] = 1,      [G.FX_PID_LPF_FREQ] = 1,      [G.FX_PID_RESO] = 0.001,
  [G.FX_PID_EQ_LO] = 0.1,       [G.FX_PID_EQ_LO_FREQ] = 1,    [G.FX_PID_EQ_LO_Q] = 0.01,
  [G.FX_PID_EQ_MID] = 0.1,      [G.FX_PID_EQ_MID_FREQ] = 1,   [G.FX_PID_EQ_MID_Q] = 0.01,
  [G.FX_PID_EQ_MID2] = 0.1,     [G.FX_PID_EQ_MID2_FREQ] = 1,  [G.FX_PID_EQ_MID2_Q] = 0.01,
  [G.FX_PID_EQ_HI] = 0.1,       [G.FX_PID_EQ_HI_FREQ] = 1,    [G.FX_PID_EQ_HI_Q] = 0.01,
  [G.FX_PID_CMP_AMT] = 0.01,    [G.FX_PID_CMP_MODE] = 1,      [G.FX_PID_BC_RATE] = 0.01,
  [G.FX_PID_BC_BITS] = 1,       [G.FX_PID_SAT_DRV] = 0.01,    [G.FX_PID_DRV_MODE] = 1,
  [G.FX_PID_SND_DLY] = 0.01,    [G.FX_PID_SND_RVB] = 0.01,    [G.FX_PID_SND_SMASH] = 0.01,
}

-- ── State ──────────────────────────────────────────────────────────────────
-- instances[inst_id] = {
--   track, slot, band, multi_out, hb_ok,
--   children[pad] = { tr, fxidx, guid, pmap = {pid→param_idx} },
--   cache[pad][pid], expected[pad][pid], band_seq, cmd_seq, queue = {}
-- }
local instances = {}
local hb_counter = 0
local tick = 0
-- A child whose strip left its track (an undo, the user's FX window) or moved in the chain is dropped by
-- validate_children on the next tick, which asks for a structure scan right away through this flag (2026-10-16).
local strip_rescan = false
-- Set while ensure_strip's insert holds an undo block open; the scan closes it after the migration push.
local strip_undo_open = false
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

local function _find_viewer_fx(tr)   -- by its file, never the shown name (a renamed viewer was not found)
  for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if core.fx_file(tr, fx) == "eon_fx_return_view.jsfx" then return fx end
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
      local _, sm = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:EON_SMASH_RETURN", "", false)
      local bus = (vt == "1") and 0 or ((dd == "1") and 1 or ((sm == "1") and 2 or nil))
      if bus then
        local vfx = _find_viewer_fx(dt)
        -- The strip's rules (ensure_strip), which the viewer lacked: a viewer the USER took out stays out
        -- (the P_EXT mark, set when the viewer we tracked -- eon_viewer_guid -- is gone from the track, lifted
        -- by one put back by hand); never inserted while REAPER can redo (the insert is an undo point of its
        -- own and throws the redo history away); one undo block for the insert and its mixer embed. Without
        -- them a removed viewer came back within a second of every scan, as a fresh "Add FX" point.
        local _, removed = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:eon_viewer_user_removed", "", false)
        local _, vg0 = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:eon_viewer_guid", "", false)
        if vfx < 0 then
          if removed ~= "1" and vg0 ~= "" then
            reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:eon_viewer_user_removed", "1", true)
            removed = "1"
            DBG("[strip_sync] return track: FX Return View removed by the user -- not re-adding\n")
          end
          local redo = reaper.Undo_CanRedo2 and reaper.Undo_CanRedo2(0)
          if removed ~= "1" and (redo == nil or redo == "") then
            -- Find-or-add, same pattern the strips use (query 0 → insert 1).
            local vname = viewer_addname(tr, 0)
            if vname then
              reaper.Undo_BeginBlock2(0)
              vfx = reaper.TrackFX_AddByName(dt, vname, false, 1)
              -- House default: fresh viewers open embedded in the MCP.
              if vfx >= 0 then core.fx_embed_mcp(dt, "EON_FX_Return_View") end
              local _, tn = reaper.GetSetMediaTrackInfo_String(dt, "P_NAME", "", false)
              reaper.Undo_EndBlock2(0, "Swing: EON FX Return View on " .. (tn ~= "" and tn or "a return track"), -1)
            end
          end
        elseif removed == "1" then
          reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:eon_viewer_user_removed", "", true)   -- put back by hand
        end
        -- The links below are heals of a background script: none while REAPER can redo (2026-10-27). A parameter
        -- write is an undo point of its own, so a link that an undo put back to its old value and that was written
        -- again at once emptied the redo list -- the Kit Bridge's identity sweep did exactly that after a Multi-Out
        -- build. A build sets these itself, inside its own block (eon_viewers_put); the heal lands once the user acts.
        local hold = reaper.Undo_CanRedo2 and (reaper.Undo_CanRedo2(0) or "") ~= ""
        if vfx >= 0 then
          local vg = reaper.TrackFX_GetFXGUID(dt, vfx) or ""
          if vg ~= vg0 then reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:eon_viewer_guid", vg, true) end
          if not hold then
            _set_param_named(dt, vfx, "Linked registry slot", inst.slot)
            _set_param_named(dt, vfx, "Bus", bus)
          end
        end
        if bus == 2 and not hold then
          -- Smash return: also hand the EON Weld its registry slot so the viewer
          -- deck and the comp meet on the same GS_BC_LINK row. Never pushed to
          -- the drum-bus instance (stays -1 → band-inert). Insert-if-absent is
          -- the BRIDGE's job at build; here we only re-link an existing one.
          for fx = 0, reaper.TrackFX_GetCount(dt) - 1 do
            if core.fx_file(dt, fx) == "eon_weld.jsfx" then   -- by its file (a renamed Weld lost its link)
              _set_param_named(dt, fx, "Link Slot", inst.slot)
              break
            end
          end
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
-- (or nil + reason). was_new = we INSERTED the strip — only that gets the
-- explicit migration push. A GUID re-adoption (saved projects) or an adopted
-- untracked strip (the GUID drifted, the strip is still there) keeps its
-- live values and converges via the first band publish, which avoids the
-- visible value flash on project open.
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
    local sname = strip_addname(tr, 0)
    if not sname then return nil, "EON_Drum_Strip.jsfx not found under Effects" end
    fxidx = reaper.TrackFX_AddByName(tr, sname, false, 0)   -- query only
    if fxidx < 0 then
      -- Never while REAPER can redo (2026-10-15): the insert is an undo point of its own ("Add FX: ..."), and a new
      -- undo point throws the redo history away -- the bridge's rule for the tracks it makes. Found with the split
      -- tracks of banks B..D (BanksTracks U): undoing an automatic split track now takes the strip's step, then the
      -- track's, and a strip put back between them would have thrown away the redo of both. The pad keeps its
      -- effects in Swing meanwhile (no strip, no mask bit); the strip goes in once the user acts again.
      local redo = reaper.Undo_CanRedo2 and reaper.Undo_CanRedo2(0)
      if redo ~= nil and redo ~= "" then return nil, "waiting: REAPER can redo" end
      -- ONE undo point for the whole insert (2026-10-16): the strip, its mixer embed (a chunk rewrite) and the
      -- migration push of Swing's values. Without the block REAPER made the insert its own "Add FX" point and,
      -- most of a second later, a second "Edit FX parameter" point for what followed it, so undoing an automatic
      -- split track took three presses (BanksTracks U.1, red only when the undo came that late), and undoing that
      -- second point alone put the strip back to its defaults, which the sync then took for the user's edit. The
      -- scan closes the block after the migration (strip_undo_open), whatever this function returns -- since
      -- 2026-10-27 after the instance's last pad track: every strip one scan puts on is ONE point (it was a point per
      -- strip, sixteen for a kit). A Multi-Out build puts its strips on itself, inside its own block (the Kit Bridge's
      -- eon_strips_put); what is left here is an older project's, or a strip that could not go on then.
      if not strip_undo_open then reaper.Undo_BeginBlock2(0) end
      strip_undo_open = true
      fxidx = reaper.TrackFX_AddByName(tr, sname, false, 1) -- insert new
      if fxidx < 0 then return nil, "AddByName failed (" .. sname .. ")" end
      was_new = true
      -- House default: EON JSFX open embedded in the MCP. Fresh inserts only —
      -- an adopted/re-found strip keeps whatever the user set.
      core.fx_embed_mcp(tr, "EON_Drum_Strip")
    end
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:eon_strip_guid",
      reaper.TrackFX_GetFXGUID(tr, fxidx) or "", true)
  end
  local pmap, missing = build_pmap(tr, fxidx)
  if missing then return nil, "param names not found: " .. missing end
  return fxidx, pmap, was_new
end

-- A child's record: bank A pad `key` in the strip band, split pair `key` in the split band.
local function band_value(inst, key, pid)
  if key < NUM_PADS then
    return reaper.gmem_read(inst.band + G.GS_STRIP_PADS + key * G.GS_STRIP_PAD_STRIDE + pid)
  end
  return reaper.gmem_read(inst.sband + (key - SPLIT0) * G.GS_STRIP_PAD_STRIDE + pid)
end
-- The slot a split child's strip speaks for (its pair's owner), -1 = nobody plays on the pair; a bank A child's pad.
local function child_slot(inst, key)
  if key < NUM_PADS then return key end
  return math.floor(reaper.gmem_read(inst.sband + G.GS_SPLIT_OFF_OWNER + key - SPLIT0) or 0) - 1
end
-- The console tie's write-back: bank A's through INCMD_GAIN / PAN, a split child's through the split band's own
-- mailbox for its owner (value first, the slot LAST -- Swing takes a cell pair once its slot cell is set).
local function tie_post(inst, key, incmd_off, v)
  if key < NUM_PADS then core.post_pad_incmd(inst.slot, incmd_off, key, v); return end
  local o = child_slot(inst, key)
  if o < 0 then return end
  local t = inst.sband + G.GS_SPLIT_OFF_TIE + (key - SPLIT0) * 4 + ((incmd_off == G.INCMD_GAIN_OFF) and 0 or 2)
  reaper.gmem_write(t + 1, v)
  reaper.gmem_write(t, o + 1)
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
        tie_post(inst, pad, incmd_off, st.pend)
      elseif st.pbv == nil or math.abs(bv - st.pbv) > TIE_EPS then
        -- Band moved but not to our pend: the echo of an intermediate post
        -- from this same drag trailing the newest payload. Re-assert the
        -- value the user's surface holds and re-baseline. A concurrent LCD
        -- edit lands here too → the physically-held fader wins,
        -- deterministically, and the tie converges on the next confirm.
        st.pbv = bv
        tie_post(inst, pad, incmd_off, st.pend)
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
      tie_post(inst, pad, incmd_off, st.pend)
    end
  elseif math.abs(tv - st.exp) > TIE_EPS then
    -- Track moved → Swing follows.
    st.exp = tv
    st.pend = math.max(lo, math.min(hi, tv))
    st.pbv = bv
    tie_post(inst, pad, incmd_off, st.pend)
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
    local bv = band_value(inst, pad, G.GS_STRIP_PAD_OFF_VOL)
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
          local bp = band_value(inst, pad, G.GS_STRIP_PAD_OFF_PAN)
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
        band_value(inst, pad, G.GS_STRIP_PAD_OFF_PAN), "D_PAN", G.INCMD_PAN_OFF, -1, 1)
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
    elseif ch.guid and reaper.TrackFX_GetFXGUID(ch.tr, ch.fxidx) ~= ch.guid then
      -- The strip is no longer at ch.fxidx (2026-10-16): an undo took it off a track that stays, the user removed or
      -- moved it. Until the next ~1 Hz scan every tick read that slot's parameters -- -1 each with nothing there,
      -- another plugin's otherwise -- took them for the user's edits and wrote them into Swing's pad through the
      -- mailbox (BanksTracks U / SX: bank C pad 3 came back with its LPF at 20 Hz). Drop it now and scan now; the
      -- scan re-finds a moved strip by its GUID.
      inst.children[pad] = nil
      if inst.tie then inst.tie[pad] = nil end
      strip_rescan = true
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
      -- The plugin's file, never its shown name (the bridge's rule) -- and never Swing Lite: it claims a registry
      -- slot like Swing but writes no strip band, so this scan read whatever a multi-out Swing had left in that
      -- slot's band (MULTIOUT = 1 silenced the Lite's track; a virgin band re-ticked its master send every pass).
      if core.is_swing_fx(tr, fx) and core.fx_file(tr, fx) ~= "swing_lite.jsfx" then
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
            for p = SPLIT0, SPLIT0 + SPLIT_N - 1 do
              inst.cache[p] = {}; inst.expected[p] = {}; inst.inflight[p] = {}
            end
            instances[id] = inst
          end
          inst.id    = id
          inst.track = tr
          inst.slot  = slot
          inst.band  = G.GS_STRIP_BASE + slot * G.GS_STRIP_STRIDE
          inst.sband = G.GS_SPLIT_BASE + slot * G.GS_SPLIT_STRIDE
          -- a Swing that publishes the split records and honours their mask (an older one: no strip on a split track,
          -- it would run that pad's effects twice)
          inst.split_ok = (reaper.gmem_read(inst.sband + G.GS_SPLIT_OFF_VER) or 0) >= 1
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
          -- The stereo half is a ONE-SHOT: on the multi-out -> stereo transition
          -- this script sees, and on the first sight of a stereo Swing whose track
          -- still carries the bridge's build mark (P_EXT:EON_OUT_MADE, cleared by
          -- the bridge's own teardown, which restores the send itself). Enforced
          -- every pass, it re-ticked the master send of a plain stereo Swing the
          -- user routes through sends only -- within a second, for ever, drums
          -- twice on the master -- and the box could not be kept unticked.
          do
            local was_multi = inst.multi_out_seen          -- nil on first sight
            inst.multi_out_seen = inst.multi_out
            local want_main
            if inst.multi_out then
              want_main = 0
            elseif was_multi == true then
              want_main = 1
            elseif was_multi == nil then
              local _, made = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_OUT_MADE", "", false)
              if made ~= "" then want_main = 1 end
            end
            if want_main and reaper.GetMediaTrackInfo_Value(tr, "B_MAINSEND") ~= want_main then
              reaper.SetMediaTrackInfo_Value(tr, "B_MAINSEND", want_main)
              DBG(string.format(
                "[strip_sync] inst %d: %s — master send %s\n",
                id, inst.multi_out and "multi-out" or "stereo",
                want_main == 1 and "restored" or "off"))
            end
            local want_send_mute = inst.multi_out and 0 or 1
            local nsends = reaper.GetTrackNumSends(tr, 0)
            for s = 0, nsends - 1 do
              local src_pad = core.swing_send_pad(tr, s)   -- Swing's own pad tracks only (2026-10-10)
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
            local put = {}   -- the pad tracks this scan put a strip on (one undo point for them all, after the loop)
            local sends = reaper.GetTrackNumSends(tr, 0)
            for s = 0, sends - 1 do
              local pad = core.swing_send_pad(tr, s)   -- Swing's own pad tracks only: never a Drum Strip on a user's bus (2026-10-10)
              -- banks B..D: a split pad's own track (tagged with its pair, core.swing_send_pair) -- keyed by the pair
              if pad < 0 and inst.split_ok then
                local sp = core.swing_send_pair(tr, s)
                if sp >= SPLIT0 and sp < SPLIT0 + SPLIT_N then pad = sp end
              end
              if pad >= 0 then
                -- (nesting kept: core.srcchan_pad already rejects no-audio/odd)
                if pad < NUM_PADS or pad >= SPLIT0 then
                  local dest = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
                  if dest then
                    local ch = inst.children[pad]
                    -- A strip the USER took out stays out. A tracked strip
                    -- (guid mark) that is gone while no strip at all is on the
                    -- track was removed on purpose -- REAPER's FX window or the
                    -- picker's swap -- so remember that instead of re-adding
                    -- it. Putting one back by hand lifts the mark. A pad with
                    -- no strip leaves inst.children: Swing processes that pad's
                    -- FX, gain and pan itself (per-pad takeover mask below).
                    local _, removed = reaper.GetSetMediaTrackInfo_String(dest, "P_EXT:eon_strip_user_removed", "", false)
                    local sname0 = strip_addname(dest, 0)
                    local has_strip = sname0 and reaper.TrackFX_AddByName(dest, sname0, false, 0) >= 0
                    if removed ~= "1" then
                      local _, g0 = reaper.GetSetMediaTrackInfo_String(dest, "P_EXT:eon_strip_guid", "", false)
                      -- sname0 nil = the JSFX could not even be located, so
                      -- "no strip found" proves nothing: never mark on that.
                      if sname0 and g0 ~= "" and not has_strip and find_fx_by_guid(dest, g0) < 0 then
                        reaper.GetSetMediaTrackInfo_String(dest, "P_EXT:eon_strip_user_removed", "1", true)
                        removed = "1"
                        DBG(string.format("[strip_sync] pad %d: Drum Strip removed by the user -- not re-adding\n", pad))
                      end
                    elseif has_strip then
                      reaper.GetSetMediaTrackInfo_String(dest, "P_EXT:eon_strip_user_removed", "", true)
                      removed = ""
                    end
                    local fxidx, pmap, was_new
                    if removed == "1" then
                      inst.report = inst.report .. string.format("  pad %d: no strip (removed by the user) -- Swing processes it\n", pad)
                    else
                      fxidx, pmap, was_new = ensure_strip(dest)
                    end
                    if not fxidx then
                      inst.report = inst.report .. string.format("  pad %d: SKIPPED — %s\n", pad, tostring(pmap))
                    end
                    if fxidx then
                      if not ch or ch.tr ~= dest or ch.fxidx ~= fxidx then
                        local prev_tr = ch and ch.tr
                        ch = { tr = dest, fxidx = fxidx, pmap = pmap,
                               guid = reaper.TrackFX_GetFXGUID(dest, fxidx) }   -- validate_children's strip check
                        inst.children[pad] = ch
                        -- One-Mixer tie: a re-mapped child TRACK invalidates the
                        -- tie bookkeeping (exp refers to the old track) → reset
                        -- so the next sync pass re-adopts (console wins).
                        if inst.tie and prev_tr ~= dest then inst.tie[pad] = nil end
                        if was_new and child_slot(inst, pad) < 0 then
                          -- a split track whose pair nobody plays on: nothing to carry over; the strip's own values
                          -- count as what we set, so the first owner's values replace them (band wins)
                          for pid in pairs(PID_TO_STRIP) do
                            inst.expected[pad][pid] = reaper.TrackFX_GetParam(dest, fxidx, pmap[pid])
                          end
                          ch.owner = -1
                        elseif was_new then
                          -- Freshly inserted strip: migrate Swing's current
                          -- values onto it (Swing = source of truth).
                          ch.owner = child_slot(inst, pad)
                          for pid in pairs(PID_TO_STRIP) do
                            local v = band_value(inst, pad, pid)
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
                            local bv = band_value(inst, pad, G.GS_STRIP_PAD_OFF_VOL)
                            if bv >= 0 then
                              local bp = band_value(inst, pad, G.GS_STRIP_PAD_OFF_PAN)
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
                        ch.guid = reaper.TrackFX_GetFXGUID(dest, fxidx)
                      end
                      found[pad] = true
                    end
                    -- the insert's undo block (ensure_strip) stays open for the instance's next pad tracks: closed
                    -- after the loop below, on every path -- one point for every strip this scan puts on
                    if was_new then
                      local _, tn = reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", "", false)
                      put[#put + 1] = (tn ~= "" and tn or "a pad track")
                    end
                  end
                end
              end
            end
            -- the strips' one undo block (ensure_strip opened it at the first insert), closed on every path
            if strip_undo_open then
              strip_undo_open = false
              reaper.Undo_EndBlock2(0, #put == 1 and ("Swing: EON Drum Strip on " .. put[1])
                or ("Swing: EON Drum Strips on " .. #put .. " pad tracks"), -1)
            end
            -- Drop children whose track/send disappeared.
            for pad in pairs(inst.children) do
              if not found[pad] then
                inst.children[pad] = nil
                if inst.tie then inst.tie[pad] = nil end
              end
            end
            inst.hb_ok = next(inst.children) ~= nil
            -- Per-pad takeover mask: bit i = pad i has a live strip. Swing
            -- keeps the pads that are NOT in it processing internally, so a
            -- pad whose strip the user replaced never goes dry.
            -- ⚠ DIALECT FLAG FIRST, mask second. Swing widens a 0 mask to all
            -- sixteen pads unless the flag says the writer means it, so writing
            -- the mask first would leave a one-tick window where an honest
            -- "no strips" reads as "every pad handed off".
            local mask, smask = 0, 0
            for pad in pairs(inst.children) do
              if pad < NUM_PADS then mask = mask | (1 << pad) else smask = smask | (1 << (pad - SPLIT0)) end
            end
            reaper.gmem_write(inst.band + G.GS_STRIP_OFF_MASK_VER, 1)
            reaper.gmem_write(inst.band + G.GS_STRIP_OFF_ALIVE_MASK, mask)
            -- banks B..D: bit k = split pair k's track has a live strip (Swing hands its owner over)
            if inst.split_ok then reaper.gmem_write(inst.sband + G.GS_SPLIT_OFF_MASK, smask) end
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
            reaper.gmem_write(inst.band + G.GS_STRIP_OFF_MASK_VER, 1)   -- flag first, see above
            reaper.gmem_write(inst.band + G.GS_STRIP_OFF_ALIVE_MASK, 0)
            if inst.split_ok then reaper.gmem_write(inst.sband + G.GS_SPLIT_OFF_MASK, 0) end
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

-- Banks B..D: a split child speaks for its pair's owner. When the owner changes (the pair handed to another pad, a
-- swap) the strip takes the new owner's values -- what it holds now counts as what we set, so the band wins -- its
-- queued edits for the old owner are dropped, its durable record forgotten, and the console tie seeds from Swing (as
-- for a pad that just got a sample). The first sight of a child (a fresh insert, a saved project) only records it.
-- Returns the children that speak for a slot this tick: bank A's, and the split ones whose pair has an owner.
local function split_owners(inst)
  local kids = {}
  for key, ch in pairs(inst.children) do
    if key >= SPLIT0 then
      local o = child_slot(inst, key)
      if ch.owner == nil then
        ch.owner = o
      elseif ch.owner ~= o then
        ch.owner = o
        for pid in pairs(PID_TO_STRIP) do
          inst.expected[key][pid] = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
        end
        inst.cache[key] = {}; inst.inflight[key] = {}
        local qi = 1
        while qi <= #inst.queue do
          if inst.queue[qi].pad == key then table.remove(inst.queue, qi) else qi = qi + 1 end
        end
        if inst.tie then inst.tie[key] = { seen_blank = true } end
        if inst.id and last_good[inst.id] then last_good[inst.id][key] = nil end
        DBG(string.format("[strip_sync] split pair %d: now slot %d's strip\n", key, o))
      end
      if o >= 0 then kids[key] = ch end
    else
      kids[key] = ch
    end
  end
  return kids
end

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
  local kids = split_owners(inst)

  -- Heartbeat: strips are adopted+migrated → Swing may go dry.
  reaper.gmem_write(inst.band + G.GS_STRIP_OFF_LUA_HB, hb_counter)


  -- ── Re-instantiation restore (the "EQ/HPF reverts on minimize" root fix) ──
  -- A minimize closes the audio device; on restore REAPER RE-INSTANTIATES the
  -- strip JSFX and may restore a STALE state chunk, so the strip's sliders come
  -- back at FACTORY DEFAULT and a live edit is lost (trace-confirmed: strip
  -- collapses to default; the band stays correct for several seconds, then the
  -- rebuilt instance's "strip wins" branch propagates the wipe into Swing).
  -- The strip's FIRST @init (a fresh instance: load, insert, project open, a true
  -- re-instantiation -- never a play start or an enable since 2026-10-14) bumps
  -- GS_STRIP_REINIT_PULSE; `reinit` is true for a generous window after that (it
  -- must outlast the instance drop/rebuild). During it, any param sitting at its
  -- exact default is a suspected wipe → restore it from the durable intended value
  -- (last_good, else the band) and RE-ASSERT into Swing so a wiped Swing pad heals
  -- too. Only runs inside the pulse window, so normal editing (incl. deliberately
  -- turning a filter OFF, or a double-click back to default) is untouched.
  if reinit then
    local now0 = reaper.time_precise()
    for pad, ch in pairs(kids) do
      for pid in pairs(PID_TO_STRIP) do
        local def = STRIP_DEFAULT[pid]
        if def ~= nil and not inst.inflight[pad][pid] then
          local sv = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
          if math.abs(sv - def) <= DEF_EPS then
            -- strip is at factory default — find the durable intended value.
            local good = inst.id and lg_get(inst.id, pad, pid)
            if good == nil then
              local bv = band_value(inst, pad, pid)
              if math.abs(bv - def) > DEF_EPS then good = bv end
            end
            if good ~= nil and math.abs(good - def) > DEF_EPS then
              push_to_strip(inst, pad, pid, good)        -- expected = readback
              local rb = inst.expected[pad][pid]
              inst.cache[pad][pid] = rb
              -- re-assert into Swing too (band may also have been wiped)
              inst.inflight[pad][pid] = { v = rb }
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
  local seq = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_SEQ)
  if seq ~= inst.band_seq then
    inst.band_seq = seq
    for pad, ch in pairs(kids) do
      for pid in pairs(PID_TO_STRIP) do
        local bv = band_value(inst, pad, pid)
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
          elseif math.abs(sv - bv) > (ev == nil and (STRIP_STEP[pid] or 0) / 2 or 0) + EPS then
            -- (first sight, ev nil: within half the slider's step is Swing's own value as the strip can hold it --
            -- STRIP_STEP -- and goes to the bookkeeping below, Swing's value kept)
            -- The strip holds a value Swing's band does not (a user edit, or a
            -- re-adoption after a heartbeat-stall wipe). STRIP WINS: keep it and
            -- propagate strip→Swing so Swing's pad converges to the strip.
            inst.cache[pad][pid] = sv
            inst.expected[pad][pid] = sv
            inst.inflight[pad][pid] = { v = sv }
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
  for pad, ch in pairs(kids) do
    for pid in pairs(PID_TO_STRIP) do
      local sv = reaper.TrackFX_GetParam(ch.tr, ch.fxidx, ch.pmap[pid])
      local ev = inst.expected[pad][pid]
      if ev ~= nil and math.abs(sv - ev) > EPS then
        inst.expected[pad][pid] = sv
        inst.cache[pad][pid] = sv
        inst.inflight[pad][pid] = { v = sv }
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
    -- the slot it addresses: a bank A pad, or a split child's owner (Swing takes an absolute slot past bank A only
    -- while it owns a split pair); a split pair nobody plays on takes nothing
    local cslot = child_slot(inst, cmd.pad)
    if cslot >= 0 then
      reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_PAD, cslot)
      reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_PID, cmd.pid)
      reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_VAL, cmd.val)
      -- Seed from the cell's RESIDENT seq on EVERY write (sweep PLG4, the other half of the FX Return
      -- View's vcmd_write_pid): the Verb / Delay / Smash viewers write this same cell from counters
      -- of their own, so a write that repeated the seq Swing had just consumed was dropped. The
      -- rebind seed above covers only the first write after a bind. Never regress; a corrupt huge
      -- value is ignored so the counter cannot be driven to Inf.
      local rs = reaper.gmem_read(inst.band + G.GS_STRIP_OFF_CMD_SEQ) or 0
      if rs > inst.cmd_seq and rs < 1e9 then inst.cmd_seq = rs end
      inst.cmd_seq = inst.cmd_seq + 1
      reaper.gmem_write(inst.band + G.GS_STRIP_OFF_CMD_SEQ, inst.cmd_seq)
    end
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
  local vevent = false
  if vreq and vreq > 0.5 then
    reaper.gmem_write(inst.band + G.GS_STRIP_OFF_VU_REQ, 0)    -- consume the request
    -- 20 faces, -1 = AUTO .. 19 = Cobalt (rk_swing_ui_state wraps at 19; the strip decodes up to 19). The old
    -- clamp of 10 was the eleven-face range: Neve, API, Ableton, FL, Red .. Cobalt all landed on the strips as 10.
    inst.vu_style = math.max(-1, math.min(19, math.floor(vreq + 0.5) - 2))
    vevent = true
  end

  -- 2. Push the shared view mode / VU face to every sibling whose pushed value is stale.
  -- On a broadcast EVENT (req / vevent) a sibling whose pushed value already equals the mode gets
  -- the idle 0 instead (sweep PLG14): the strip adopts on an EDGE of View Push / VU Set, so a
  -- sibling that changed its view locally since the last push saw no edge and stayed out of step
  -- while SYNC ALL read ON. The strip ignores a value under 0.5; the stale test writes the mode
  -- again on the next pass, and that edge lands.
  if inst.view_mode ~= nil then
    local want = inst.view_mode + 1
    for pad, ch in pairs(inst.children) do
      local si = ch.pmap and ch.pmap.vset
      if si and reaper.ValidatePtr2(0, ch.tr, "MediaTrack*") then
        local cur = math.floor((reaper.TrackFX_GetParam(ch.tr, ch.fxidx, si)) + 0.5)
        if cur ~= want then reaper.TrackFX_SetParam(ch.tr, ch.fxidx, si, want)
        elseif req ~= nil then reaper.TrackFX_SetParam(ch.tr, ch.fxidx, si, 0) end
      end
    end
  end
  if inst.vu_style ~= nil then
    local vwant = inst.vu_style + 2   -- encode style+2 (1 = AUTO .. 21 = Cobalt; the strip's VU Set runs 0..21)
    for pad, ch in pairs(inst.children) do
      local vi = ch.pmap and ch.pmap.vuset
      if vi and reaper.ValidatePtr2(0, ch.tr, "MediaTrack*") then
        local cur = math.floor((reaper.TrackFX_GetParam(ch.tr, ch.fxidx, vi)) + 0.5)
        if cur ~= vwant then reaper.TrackFX_SetParam(ch.tr, ch.fxidx, vi, vwant)
        elseif vevent then reaper.TrackFX_SetParam(ch.tr, ch.fxidx, vi, 0) end
      end
    end
  end
end

-- ── Main loop ──────────────────────────────────────────────────────────────

local function loop()
  -- A stop marker the loop honours (wiki 06: a re-run of a set_action_options script is a RESTART, never a stop):
  -- the dev / rig way to end this copy, as the Kit Bridge's EON_Bridge/exit_req. The loop ends here WITHOUT a fresh
  -- heartbeat, so the bridge reads it stale after core.ALIVE_STALE_S and -- while it is still in its start-up grace,
  -- before it has confirmed a running copy -- launches its own sibling copy (a rig stages one). A bridge past that
  -- grace does not relaunch: the designed fail-safe then is Swing's own strip takeover lapsing. Non-persistent: a
  -- request cannot outlive the session. Nothing in production sets it.
  if reaper.GetExtState(core.ALIVE_STRIP_SYNC_SECTION, "exit_req") == "1" then
    reaper.SetExtState(core.ALIVE_STRIP_SYNC_SECTION, "exit_req", "", false)
    return
  end
  tick = tick + 1
  hb_counter = hb_counter + 1

  -- Script-level "I am running" heartbeat, read by the Kit Bridge so it can
  -- start this script when nothing else has. Both names live in rk_lua_core so
  -- the writer and the reader cannot drift apart.
  -- ⚠️ Deliberately NOT the per-instance GS_STRIP_OFF_LUA_HB heartbeat: that one
  -- only begins once an instance's strips are inserted and migrated, so it reads
  -- "dead" in exactly the situation the bridge needs to detect — no strips yet.
  -- ExtState rather than a gmem cell: no new cell to claim, and a non-persistent
  -- ExtState is cleared by REAPER on restart, so a value can never outlive the
  -- session that wrote it. time_precise is session-relative, so both sides agree.
  reaper.SetExtState(core.ALIVE_STRIP_SYNC_SECTION, core.ALIVE_STRIP_SYNC_KEY,
                     tostring(reaper.time_precise()), false)

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
  if tick % scan_every == 1 or strip_rescan then strip_rescan = false; scan_structure() end

  -- Strip re-instantiation detection: the strip JSFX bumps GS_STRIP_REINIT_PULSE
  -- in its first @init (once per instance since 2026-10-14; a play start or an
  -- enable re-runs @init without bumping). On any change, arm a generous TIME
  -- window (REINIT_HOLD_S) during which sync_instance restores wiped-to-default
  -- strips from last_good. Must be time-based (not a tick count): a minimize
  -- drops+rebuilds the instance and the wipe can surface several seconds after
  -- the pulse.
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

-- Rewrite __startup.lua via tmp-file + rename instead of truncating in place.
-- The file is SHARED -- other vendors' startup lines live in it too -- so a
-- crash or full disk mid-write must never be able to eat it. Returns true
-- only once the new content is fully on disk under `path`. Global on purpose:
-- same helper as the other EON self-registering scripts.
function eon_write_startup(path, content)
  local tmp, prev = path .. ".eon-tmp", path .. ".eon-prev"
  -- A stranded original goes back first (see eon_recover_startup). If it
  -- cannot, nothing below may run: the os.remove(prev) further down would eat
  -- the only copy of the shared file.
  if not eon_recover_startup(path) then return false end
  -- A read-only __startup.lua is the user's call. Windows would still let the
  -- renames below replace it -- and strand a read-only .eon-prev that blocks
  -- every later rewrite -- so refuse up front.
  local ro = io.open(path, "r")
  if ro then ro:close(); local ap = io.open(path, "a"); if not ap then return false end; ap:close() end
  local f = io.open(tmp, "w")
  if not f then return false end
  local wok = f:write(content)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return false end
  -- Windows os.rename won't overwrite, so the old file steps aside first --
  -- and steps back if the new one cannot take its place. Nothing is ever
  -- deleted before the replacement is in (2026-09-07: the old remove-then-
  -- rename left the shared file GONE whenever the rename failed, e.g. an
  -- antivirus hold on the freshly written tmp file).
  os.remove(prev)
  local had_old = os.rename(path, prev)
  if os.rename(tmp, path) then
    os.remove(prev)
    return true
  end
  if had_old then os.rename(prev, path) end
  os.remove(tmp)
  return false
end

-- ⚠ A rewrite that fails half-way leaves __startup.lua GONE and the original
-- in .eon-prev: the new file could not take the old one's place AND the old
-- one could not step back (an antivirus hold on both the fresh tmp and the
-- just-renamed .eon-prev -- the same hold the 2026-09-07 fix met on one side).
-- Nothing runs at the next launch to notice, and the writer's first act on
-- the retry used to be os.remove(prev): every vendor's startup lines gone,
-- then a file written holding only our block. So the writer and every
-- self_register put a stranded original back before reading or writing, and
-- a .eon-prev is only ever removed while the real file exists. Returns false
-- when a stranded original is there and could not be put back, or when
-- __startup.lua is there but cannot be read. Global, identical in all five
-- self-registering scripts.
function eon_recover_startup(path)
  local f, _, ocode = io.open(path, "r")
  if f then f:close() return true end
  -- Present but unreadable (a lock, a permission) is not absent: nothing is
  -- put back over it. On macOS / Linux rename REPLACES an existing file, so a
  -- stale .eon-prev overwrote the current one (outside audit 2026-10-02; on
  -- Windows the rename failed). ENOENT (2) is the one open failure that means
  -- there is no file.
  if ocode ~= 2 then return false end
  -- No file. Put a stepped-aside original back. rename needs no read access,
  -- so an unreadable-but-present .eon-prev is never mistaken for absent
  -- (Codex 2026-09-23); ENOENT (2) is the one failure that means there is
  -- nothing to recover.
  local ok, _, code = os.rename(path .. ".eon-prev", path)
  return (ok or code == 2) and true or false
end

-- ⭐ Strip one script's block from __startup.lua text, in WHOLE LINES. The file is
-- shared with other vendors. The old gsub('\n?BEGIN.-END\n?') ate the newline on
-- BOTH sides, gluing a neighbour line that had no trailing newline onto the next
-- vendor's line (a comment then swallowed their command), and a stray BEGIN with
-- no END stretched the match over foreign lines down to our real END. Here a block
-- goes only when its BEGIN line is followed by its END line with no second BEGIN
-- in between -- anything unmatched stays verbatim -- together with the one blank
-- line we write above it, so re-registering never grows the file. The v1/v2 form
-- (a bare "-- EON:<name>" line plus the line after it) goes too. Returns the text
-- and whether anything was removed. Global, and identical in all five
-- self-registering EON scripts: .dev_tests/startup_file_test.py holds them to it.
function eon_strip_startup_block(text, name)
  local B, E, OLD = "-- EON:" .. name .. " BEGIN", "-- EON:" .. name .. " END", "-- EON:" .. name
  local out, pend, skip, hit = {}, nil, false, false
  local nl = text:sub(-1) == "\n"
  for l in (nl and text or text .. "\n"):gmatch("([^\n]*)\n") do
    local k = l:gsub("\r$", "")
    if skip then
      skip, hit = false, true
    elseif pend then
      if k == E then
        if out[#out] and out[#out]:gsub("\r$", "") == "" then out[#out] = nil end
        pend, hit = nil, true
      elseif k == B then
        for _, x in ipairs(pend) do out[#out + 1] = x end
        pend = { l }
      else
        pend[#pend + 1] = l
      end
    elseif k == B then
      pend = { l }
    elseif k == OLD then
      skip = true
    else
      out[#out + 1] = l
    end
  end
  if pend then for _, x in ipairs(pend) do out[#out + 1] = x end end
  local s = table.concat(out, "\n")
  if nl and #out > 0 then s = s .. "\n" end
  return s, hit
end

-- The uninstall half of the block written into __startup.lua (the `else` branch,
-- reached once the script's command no longer resolves). It removes the block by
-- the same whole-line rule as eon_strip_startup_block -- inlined, because nothing
-- of ours is left to call -- skips a read-only file, and clears the flag.
function eon_startup_selfclean_src(name, section, key)
  return
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    -- a stranded .eon-prev (an earlier replacement that failed both ways) goes back first, only while the real
    -- file is absent: the writer's own recovery rule (outside audit 3, 2026-10-05)
    "  do local pb=io.open(p..'.eon-prev','r'); if pb then pb:close(); local pf=io.open(p,'r'); if pf then pf:close() else os.rename(p..'.eon-prev',p) end end end\n" ..
    "  local f=io.open(p,'r'); local c=f and f:read('*a'); if f then f:close() end\n" ..
    "  local w=c and io.open(p,'a'); if w then w:close()\n" ..
    -- Markers assembled at run time: the literal "-- EON:<name> END" must never appear
    -- INSIDE the block, or an older copy's lazy BEGIN.-END match would stop there and
    -- leave half a block (broken Lua) behind.
    "    local N='-- EON:'..'" .. name .. "'; local B,E,o,q=N..' BEGIN',N..' END',{}\n" ..
    "    local nl=c:sub(-1)=='\\n'\n" ..
    "    for l in (nl and c or c..'\\n'):gmatch('([^\\n]*)\\n') do local k=l:gsub('\\r$','')\n" ..
    "      if q then\n" ..
    "        if k==E then if o[#o] and o[#o]:gsub('\\r$','')=='' then o[#o]=nil end q=nil\n" ..
    "        elseif k==B then for _,x in ipairs(q) do o[#o+1]=x end q={l}\n" ..
    "        else q[#q+1]=l end\n" ..
    "      elseif k==B then q={l} else o[#o+1]=l end\n" ..
    "    end\n" ..
    "    if q then for _,x in ipairs(q) do o[#o+1]=x end end\n" ..
    "    c=table.concat(o,'\\n')..((nl and #o>0) and '\\n' or '')\n" ..
    "    local t,b=p..'.eon-tmp',p..'.eon-prev'; local fw=io.open(t,'w'); local ok=false\n" ..
    "    if fw then ok=fw:write(c) and true or false; if not fw:close() then ok=false end end\n" ..
    "    if ok then os.remove(b); local h=os.rename(p,b); if os.rename(t,p) then os.remove(b) elseif h then os.rename(b,p) end end\n" ..
    "    os.remove(t) end\n" ..
    -- the flag is cleared only while the start-up file is there; a replacement that failed both ways keeps it, so
    -- the next launch tries again (the original waits in .eon-prev)
    "  do local pf=io.open(p,'r'); if pf then pf:close(); reaper.SetExtState('" .. section .. "','" .. key .. "','',true) end end\n"
end

-- ── Self-register as startup action (one-time, first manual run) ──────────
-- Same self-cleaning __startup.lua block the Kit Bridge uses: runs this
-- script on every REAPER launch; if the file is removed (uninstall), the
-- block strips itself out and clears the ExtState so reinstalls re-register.
local SCRIPT_NAME = "EON_Swing_Strip_Sync"
local function self_register()
  local _, script_path = reaper.get_action_context()
  local key = SCRIPT_NAME .. "_registered_v3"   -- v3 (2026-10-14): the block checks the script file (every install re-registers once)
  local marker = "-- EON:" .. SCRIPT_NAME
  -- A rewrite that failed half-way may have left the file stepped aside as
  -- .eon-prev; put it back before anything below reads it. If it cannot be put
  -- back, do NOTHING this run: registering anyway would read an empty file
  -- and, once the hold lifts, the writer's own recovery would restore the
  -- original only for the write to replace it with a file holding just our
  -- block (Codex 2026-09-23). The next run retries.
  if not eon_recover_startup(reaper.GetResourcePath() .. "/Scripts/__startup.lua") then return end

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

  local had_block
  existing, had_block = eon_strip_startup_block(existing, SCRIPT_NAME)

  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  -- The action must resolve AND the script file must open (2026-10-14: a folder deleted by hand leaves the action
  -- behind, and REAPER showed "Can't load file" at every start); else the block strips itself. %q: a ]] in the path.
  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    string.format("local sf=io.open(%q,'r'); if sf then sf:close() end\n", script_path) ..
    "if id~=0 and sf then reaper.Main_OnCommand(id,0) else\n" ..
    eon_startup_selfclean_src(SCRIPT_NAME, SCRIPT_NAME, key) ..
    "end end\n" ..
    marker .. " END\n"

  -- Flag as registered only once the block is really on disk; a failed write
  -- leaves the ExtState clear so the next run simply retries.
  if eon_write_startup(startup_path, existing .. block) then
    reaper.SetExtState(SCRIPT_NAME, key, "1", true)
    -- Only a genuine first registration speaks: replacing an existing block (every
    -- updated install after a key bump) must not pop the console open for users.
    if not had_block then
      reaper.ShowConsoleMsg("[strip_sync] registered as startup action (auto-starts with REAPER).\n")
    end
  end
end
-- A rig hosting a STAGED copy sets no_self_register (as it does for the Kit Bridge, EON_Bridge/no_self_register): the
-- sandbox shares the user's resource folder, and a staged copy must not rewrite the real __startup.lua or register a
-- %TEMP% path in the real reaper-kb.ini (the review of 2026-10-18). Non-persistent; nothing in production sets it.
if reaper.GetExtState(core.ALIVE_STRIP_SYNC_SECTION, "no_self_register") ~= "1" then self_register() end

-- The add-name is resolved lazily (see addname_for): only a debug run pays the lookup here.
if reaper.GetExtState("EON_Swing", "strip_sync_debug") == "1" then
  DBG("[strip_sync] started: " .. tostring(strip_addname()) .. "\n")
end
loop()
