-- track_reflect.lua — EON ReaKit P4. The ONE writer of REAPER TCP track
-- identity (name / color / icon) from the published Swing pad state.
--
-- Why this exists
-- ───────────────
-- Before P4 there were FIVE writer paths painting track state from gmem:
--   1. swing_sync.sync_lane()                — Drum Matrix MIDI lanes
--   2. do_build_multiout() BUILD path        — fresh audio multi-out tracks
--   3. do_build_multiout() UPDATE path       — existing multi-outs after CMD 40
--   4. refresh_multiout_colors_if_changed()  — live audio-track color refresh
--   5. refresh_multiout_names_if_changed()   — live audio-track name refresh
-- Each could (and did) disagree with the others — colors lagging names,
-- different blank-detection paths, drifting "NN " prefix discipline. The
-- single-writer rule collapses all of that into this one module: callers
-- assemble an identity record and ask `Reflect()` to apply it.
--
-- What this is NOT
-- ────────────────
-- This module is a sink, not a source. It does not read gmem, does not
-- decide what a pad's identity is, and does not choose blank-vs-loaded.
-- Callers (swing_sync, the bridge's multi-out refreshers) own those
-- decisions; track_reflect is the one place where the resulting identity
-- becomes a track's I_CUSTOMCOLOR / P_NAME / P_ICON. Keeping the policy
-- with the caller and the mechanism here is what kills the tug-of-wars.
--
-- Identity record (table passed to Reflect)
-- ─────────────────────────────────────────
--   name       string or nil  — P_NAME to write; nil = leave unchanged
--   color      int    or nil  — I_CUSTOMCOLOR (with REAPER's 0x1000000
--                                "custom-color-enabled" bit), 0 = REAPER
--                                default, nil = leave unchanged
--   icon_path  string or nil  — P_ICON path; nil = leave unchanged, ""
--                                clears, "/abs/path.png" sets (P2 will
--                                populate; today every caller passes nil)
--
-- Reflect() is silent (no Undo block — track identity is published state,
-- not a user edit) and idempotent: re-applying the same identity to a
-- track that already has it is a cheap no-op (skipped via cheap reads).

local M = {}

-- Apply an identity record to one track. Safe to call against a stale
-- track pointer — validated via ValidatePtr when available. Returns true
-- if anything actually changed, false if all reads matched.
function M.Reflect(track, ident)
  if not (track and ident) then return false end
  if reaper.ValidatePtr and not reaper.ValidatePtr(track, 'MediaTrack*') then
    return false
  end

  local changed = false

  -- ─── Name ─────────────────────────────────────────────────────────────
  if ident.name ~= nil then
    local _, cur_name = reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', '', false)
    if cur_name ~= ident.name then
      reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', ident.name, true)
      changed = true
    end
  end

  -- ─── Color ────────────────────────────────────────────────────────────
  -- GetMediaTrackInfo_Value returns a float; for integral I_CUSTOMCOLOR
  -- values up to ~2^24 (REAPER's range) the round-trip is exact, so a
  -- direct == compare is stable. Native 0 = "no custom color, use REAPER
  -- default" — that's how blank pads land on REAPER grey.
  if ident.color ~= nil then
    local cur_color = reaper.GetMediaTrackInfo_Value(track, 'I_CUSTOMCOLOR') or 0
    if cur_color ~= ident.color then
      reaper.SetMediaTrackInfo_Value(track, 'I_CUSTOMCOLOR', ident.color)
      changed = true
    end
  end

  -- ─── Icon ─────────────────────────────────────────────────────────────
  -- "" clears the icon back to track-default, nil leaves it unchanged.
  -- GUARDED write: only touch P_ICON while the track still carries the
  -- icon WE last wrote (remembered in P_EXT:EON_ICON_AUTO, persists in
  -- the project). If the user picked their own icon — or cleared ours —
  -- via REAPER's track-icon dialog, hands off: auto-icons must never
  -- fight a manual choice. cur == icon_path also claims tracks iconed by
  -- pre-guard builds. Mirrors rk_lua_icons.M.apply (duplicated because
  -- this sink is dependency-free by design) — keep the two in lockstep.
  if ident.icon_path ~= nil then
    local _, cur_icon  = reaper.GetSetMediaTrackInfo_String(track, 'P_ICON', '', false)
    local _, auto_icon = reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_ICON_AUTO', '', false)
    if cur_icon == auto_icon or cur_icon == ident.icon_path then
      if auto_icon ~= ident.icon_path then
        reaper.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_ICON_AUTO', ident.icon_path, true)
      end
      if cur_icon ~= ident.icon_path then
        reaper.GetSetMediaTrackInfo_String(track, 'P_ICON', ident.icon_path, true)
        changed = true
      end
    end
  end

  return changed
end

-- Convenience: apply a per-pad identity map to a per-pad track map. Both
-- keyed by pad_index (1-based). Callers that already have a {pad → track}
-- mapping (the bridge walks Swing's sends to build it; swing_sync iterates
-- lane_tools.GetLanes()) can pass it straight through. Returns the count
-- of tracks that actually changed.
function M.ReflectMany(tracks_by_pad, idents_by_pad)
  if not (tracks_by_pad and idents_by_pad) then return 0 end
  local n = 0
  for pad, track in pairs(tracks_by_pad) do
    local ident = idents_by_pad[pad]
    if ident and M.Reflect(track, ident) then n = n + 1 end
  end
  return n
end

return M
