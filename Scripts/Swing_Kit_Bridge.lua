-- Swing Kit Bridge v4 — Full Companion ReaScript
-- (c) EON Studios — All Rights Reserved
--
-- Bridges Swing JSFX ↔ filesystem + REAPER API via gmem shared memory.
-- Features: Kit save/load (.swing), multi-out track builder, batch import,
--           chop-to-pads, auto-color, media explorer toggle.
-- v4: Instance lock system for multi-instance support.
--
-- INSTALLATION:
--   Actions → Show action list → ReaScript: Load → select this file.
--   Run once — stays in the background until REAPER closes.
--   Add to SWS Startup Actions for auto-start.
--
-- FILE FORMATS:
--   .swing v1 (binary, legacy — kept for read-only backwards compat):
--     Header:   magic(8B) + version(8B) + num_pads(8B)
--               + name_len(8B) + name(32×8B)
--               + author_len(8B) + author(32×8B)
--               + desc_len(8B) + desc(64×8B)
--               + timestamp(8B)
--     Per pad:  80 doubles metadata + 16 doubles pad name
--     Audio:    per-pad: length(8B) + sample_rate(8B) + 16-bit PCM data (2B each)
--
--   .swing v2 (Lua text, legacy — path-only, kept for read-only backwards compat):
--     Plain Lua `return { ... }` table with per-pad `path` referring to external
--     sample files. Not self-contained; breaks if source files move.
--
--   .swing v3 — RETIRED 2026-07-31, reader and writer both removed. It was the
--     live write format for under 7 hours on 2026-04-26 (added 14:28, superseded
--     by v4 at 21:13 the same day) and was never reachable in a shipped build —
--     v2.1.1/v2.1.4/v2.1.5 all define write_kit_v3 but never call it. So no user
--     kit can be v3. validate_swing still recognises the "SWINGv03" magic purely
--     so a stray dev-era file reports something useful instead of "Not a .swing
--     file".
--
--   .swing v4 (hybrid, CURRENT — self-contained + per-pad multi-layer audio):
--     magic "SWINGv04"; full byte layout is documented at the v4 HYBRID SAVE
--     section further down.
--
--   .swing v5 (zip bundle, self-contained) — opt-in only, gated behind
--     ExtState EON_Swing/save_format=v5. See the v5 section.

local SCRIPT_NAME = "Swing Kit Bridge"
local FORMAT_VER  = 22  -- v22: pad names widened from 16 to 32 chars
local MAGIC       = 0x5357494E  -- "SWIN"

-- ═══════════════════════════════════════════════════════════════════════════════
-- SHARED MODULES (ReaKit Lua library)
-- ═══════════════════════════════════════════════════════════════════════════════
local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end
local _SCRIPT_DIR = _get_script_dir()
local _sep = package.config:sub(1,1)

-- Path of a companion script that ships NEXT TO this file. Every script the
-- bridge launches (strip sync, the FX picker bridge, the dock rig) lives in the
-- same folder as the bridge on every install -- the installer, ReaPack and the
-- dev tree all keep them together -- so "next to me" is the only lookup that is
-- right everywhere. ⛔ Never a hard-coded resource-path folder: the dock rig
-- shipped pointing at the author's own Scripts/EON Scripts/ and was unreachable
-- on every customer install (portable-install report, 2026-09-04).
function eon_sibling_script(name)
  return _SCRIPT_DIR:gsub("[/\\]+", "/"):gsub("/+$", "") .. "/" .. name
end

package.path = _SCRIPT_DIR .. _sep .. "?.lua;" .. (package.path or "")
local core = require("rk_lua_core")

-- Styled dialog module (ReaImGui). pcall'd: a missing file or missing ReaImGui
-- is fine -- every call site keeps its native GetUserInputs/ShowMessageBox
-- fallback and gates on eon_dlg.available() per the module's contract.
-- ⚠️ its prompts are ASYNC (callback) -- do the work inside on_ok, never after
-- the call.
local eon_dlg
do
  local ok, m = pcall(dofile, _SCRIPT_DIR .. _sep .. "EON" .. _sep .. "eon_imgui_dialog.lua")
  if ok and type(m) == "table" then eon_dlg = m end
end

-- One-line styled notice (message + OK), native ShowMessageBox when ReaImGui is
-- absent. Every fire-and-forget box in this file routes through here so the
-- fallback lives in ONE place instead of 40-odd copies.
--
-- ⚠️⚠️ THE RE-ENTRANCY GUARD IS LOAD-BEARING, NOT TIDINESS. ShowMessageBox
-- BLOCKED, and that blocking silently rate-limited every notice raised from
-- inside the defer poll loop: the box stopped the loop, so a failing per-tick
-- path could only ever produce ONE. The house dialog returns immediately, so
-- the same path would stack a fresh dialog every tick until REAPER buckles.
-- While a notice is up we drop further ones — a per-tick storm is the same
-- message repeated anyway, and the alternative (a queue) would just replay the
-- storm one OK-click at a time. The native branch keeps its own blocking
-- behaviour and needs no guard.
local _notice_up = false
local function eon_notice(msg, title)
  title = title or SCRIPT_NAME
  if not (eon_dlg and eon_dlg.available() and eon_dlg.info) then
    reaper.ShowMessageBox(msg, title, 0)
    return
  end
  if _notice_up then return end
  _notice_up = true
  -- info() routes BOTH the OK button and window-dismiss to on_ok, so the flag
  -- clears on every exit path; a false return means it never opened.
  if not eon_dlg.info({ title = title, message = msg,
                        on_ok = function() _notice_up = false end }) then
    _notice_up = false
    reaper.ShowMessageBox(msg, title, 0)
  end
end

-- EON unified theme publisher → JSFX gmem color band. rk_lua_theme resolves the
-- selected palette (EON / Dark / Light / REAPER); core.publish_theme_band writes
-- it to the shared band so the Swing + StepSeq JSFX re-skin in step with the
-- Browser / Pad-FX theme selector. pcall so a bare-Swing install missing the
-- module just skips theming (the JSFX fall back to their hardcoded defaults).
-- Unified-theme publisher state in ONE table. Kept as a single main-chunk local
-- (not 6+) to stay under Lua's 200-locals-per-function limit; the pcall temporaries
-- are do-scoped so they don't count. .mod = rk_lua_theme (nil on a bare install);
-- names/idx map the GS_THEME_REQ / GS_THEME_CUR selector codes (1..4) ↔ name.
local _theme = {
  gen = 0, last_name = nil, last_file = nil,
  names = { "eon", "dark", "light", "reaper", "reaper_panel", "reaper_color", "ssl", "neve", "api", "tube", "ableton", "fl", "protools", "protools_light" },
  idx   = { eon = 1, dark = 2, light = 3, reaper = 4, reaper_panel = 5, reaper_color = 6, ssl = 7, neve = 8, api = 9, tube = 10, ableton = 11, fl = 12, protools = 13, protools_light = 14 },
}
do local ok, m = pcall(require, "rk_lua_theme"); if ok then _theme.mod = m end end

-- P2 — icons for audio multi-out tracks. Use the SAME resolver + categorizer
-- the Drum Matrix uses for MIDI lanes, so pads/lanes/multi-outs all show the
-- same icon per pad. Both modules loaded via pcall(require) — bare-Swing
-- users without one of them just won't get icons; everything else works.
local _icons_ok, _bridge_icons = pcall(require, "rk_lua_icons")
if not (_icons_ok and type(_bridge_icons) == "table" and _bridge_icons.resolve) then
  _bridge_icons = nil
end
local _cat_ok, _bridge_categorizer = pcall(require, "eon_filename_categorizer")
if not (_cat_ok and type(_bridge_categorizer) == "table" and _bridge_categorizer.classify) then
  _bridge_categorizer = nil
end

-- ── Kit categories, phase ① (Spec_Swing_Kit_Categories §7a rev 2026-07-23) ──
-- Publish each pad's category to the INST_PADCAT gmem band so the JSFX pad
-- badge + a paired Steppa's lane icons share ONE identity. Bridge = band owner
-- (IDENT is JSFX-owned; two writers on one band is how collisions happen).
-- Per-pad seqlock: VER written LAST, monotonic; VER==0 = never published →
-- consumers fall back to name inference (today's behavior). `other` publishes
-- as -1 (uncategorised, spec 8d).
-- ⚠️ GLOBALS by necessity: the main chunk sits AT Lua's 200-local cap (adding
-- main-chunk locals here breaks the whole script at load: "too many local
-- variables"). Same precedent as eon_preset_*/eon_apply_seq. Do NOT localize.
EON_PADCAT_BASE, EON_PADCAT_STRIDE = 26003000, 64   -- = core.GMEM.INST_PADCAT_*
-- ⭐ THREE distinct states live in the CAT cell, and conflating any two of them
-- is the bug this constant exists to prevent:
--   VER == 0            never published — the band has nothing to say
--   CAT  == -1          published, but nothing classified confidently. Glyph
--                       consumers still infer from the pad NAME; that inference
--                       is what bootstraps a rack nobody has categorised yet.
--   CAT  == EON_PADCAT_NONE  the user said this pad has NO job. Consumers draw
--                       nothing and infer nothing — an explicit answer, not a
--                       missing one. Persists as "-" in P_EXT.
EON_PADCAT_NONE = -3
eon_padcat_idxmap = nil          -- category name -> 0-based CATEGORY_ORDER index
eon_padcat_ver = 0
function eon_padcat_index(catname)
  if not catname then return -1 end
  if not eon_padcat_idxmap then
    -- ⚠️ FROZEN glyph ids from rk_cat_glyphs.jsfx-inc:16-23 (append-only; ids
    -- persist in lane_icon_override — never renumber). Do NOT derive from the
    -- categorizer's CATEGORY_ORDER: that list is MATCH PRIORITY, not id order
    -- (deriving from it shifted every pad badge — live bug 2026-07-24).
    local G = { "kick","snare","rimshot","clap","closed_hat","open_hat","hihat",
      "cymbal","crash","ride","floor_tom","rack_tom","tom","conga","bongo",
      "cowbell","clave","tambourine","shaker","maraca","percussion","bass",
      "synth","pad","keys","guitar","strings","brass","vocal","fx","loop",
      "other","snap","splash","china","sidestick","triangle","woodblock",
      "cabasa","guiro","timbale","agogo","djembe","cajon","vibraslap","whistle" }
    eon_padcat_idxmap = {}
    eon_padcat_names = {}
    for i, c in ipairs(G) do eon_padcat_idxmap[c] = i - 1; eon_padcat_names[i - 1] = c end
  end
  local ix = eon_padcat_idxmap[catname]
  if ix == nil or catname == "other" then return -1 end
  return ix
end
-- Adopt + publish one pad's category during a kit load. kit_cat = the v4 file's
-- explicit field (may be nil on older kits); name = the pad's display name;
-- path = the pad's informational original path (may be "" / another machine's).
-- Loader contract (spec §1): p.category or classify(p.name). Slot from the LOCK
-- cell (97) — the loaders run inside the lock window, same source
-- register_kit_source_after_save trusts.
function eon_padcat_from_load(pad, kit_cat, name, path)
  -- Band slot = the requesting instance's REGISTRY slot, resolved id -> slot
  -- through the registry (cell 97 holds the instance ID). The old `id - 1`
  -- shortcut diverges after churn (add/delete/reopen reclaims slots out of id
  -- order) and then this writer + the ADAPT snapshot use a DIFFERENT band than
  -- pext_restore / the backfill / the Steppa badges (all registry-keyed) — the
  -- exact trap the eon_padcat_track_for_slot comment documents. Fallback to
  -- id - 1 only when the id is not in the registry (matches old behaviour).
  local _id = math.floor((reaper.gmem_read(97) or 0) + 0.5)
  local slot = -1
  if _id > 0 then
    for _s = 0, core.GMEM.GS_INST_REG_MAX - 1 do
      if math.floor(reaper.gmem_read(
           core.GMEM.GS_INST_REG_BASE + _s * core.GMEM.GS_INST_REG_STRIDE
           + core.GMEM.GS_INST_REG_OFF_ID) or 0) == _id then slot = _s break end
    end
    if slot < 0 then slot = _id - 1 end
  end
  if slot < 0 or slot > 15 or pad < 0 or pad > 15 then return end
  local cat = kit_cat
  if (not cat or cat == "") and _bridge_categorizer and name and name ~= "" then
    -- `name` is the 32-char gmem transport name; long pack names lose the tail
    -- word that distinguishes the articulation ("...808 Hi Hat Open 04" arrives
    -- as "...808 Hi Hat " -> generic-hihat rule -> closed_hat for an OPEN hat).
    -- When the stored name is literally a truncated prefix of the file's real
    -- basename (i.e. the pad was auto-named, never renamed), classify the FULL
    -- basename + folder instead. A renamed pad fails the prefix test and keeps
    -- name authority — the 707-class "path names a different sound" rule holds.
    local nm, fold = name, ""
    if path and path ~= "" then
      local base = path:match("[/\\]([^/\\]+)$") or path
      local stem = base:match("^(.*)%.[^.]+$") or base
      if #stem > #name and stem:sub(1, #name) == name then
        nm = stem
        fold = path:sub(1, #path - #base)
      end
    end
    local c, conf = _bridge_categorizer.classify(nm, fold)
    cat = conf and c or nil
  end
  local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
  -- ③ ADAPT snapshot: at the sweep's FIRST pad, capture the PRE-load category
  -- map (the lanes' current jobs) — the permutation source. Before the lock
  -- check: a locked pad 0 must not skip the snapshot.
  if pad == 0 then
    eon_padcat_prev = {}
    eon_padcat_prev_slot = slot   -- tag: compute() refuses a mismatched slot (aborted-sweep guard)
    for p2 = 0, 15 do
      local b2 = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + p2 * 4
      eon_padcat_prev[p2] = (reaper.gmem_read(b2) or 0) > 0
        and math.floor((reaper.gmem_read(b2 + 1) or -1) + 0.5) or -1
    end
  end
  -- ② LOCK: a locked pad is untouched by kit loads — keep category AND flag.
  if (reaper.gmem_read(b + 3) or 0) > 0.5 then
    if pad == 15 then eon_padcat_pext_write(slot); eon_padcat_adapt_compute(slot) end
    return
  end
  eon_padcat_ver = eon_padcat_ver + 1
  reaper.gmem_write(b + 1, eon_padcat_index(cat))   -- CAT
  reaper.gmem_write(b + 2, 0)                       -- SRC: kit/inferred (phase ①)
  reaper.gmem_write(b + 3, 0)                       -- LOCK stays off for unlocked pads
  reaper.gmem_write(b + 0, eon_padcat_ver)          -- VER LAST (seqlock)
  if pad == 15 then eon_padcat_pext_write(slot); eon_padcat_adapt_compute(slot) end
end
-- User pad-RENAME → category re-inference (user 2026-08-10: renaming a pad to
-- an instrument name should move its badge to that category). Direct sibling
-- of the REQ mailbox's Auto branch (same classify, same confidence gate) —
-- but a rename is FRESH name authority, so it also refreshes a pad the user
-- had previously badged (the rename is the newer intent). Hard guards only:
-- the audio LOCK (+3) always wins, NONE (-3) always wins (an ANSWER,
-- published verbatim, never re-inferred — same contract as the Auto branch),
-- and an unconfident / "other" classification keeps the current badge rather
-- than clearing a working lane mapping ("Blorp 3" is not a category). SRC
-- (+2) is left untouched — renaming doesn't change where the pad's sample
-- came from (FILL's SRC==2 refusal must survive a rename).
-- Core takes a KNOWN (slot, pad): shared by the CMD-50 rename dialog (slot
-- from the LOCK cell) and the TCP child-track rename adoption (slot from the
-- identity walker).
function eon_padcat_apply_rename(slot, pad, name)
  if not _bridge_categorizer or not name or name == "" then return end
  if slot < 0 or slot > 15 or pad < 0 or pad > 15 then return end
  -- A name filling the whole 32-char transport is a suspected TRUNCATION
  -- (same rule as the backfill): classifying a chopped tail flips hat
  -- articulations ("...Hi Hat Open" -> "...Hi Hat "). Keep the badge.
  if #name >= 32 then return end
  local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
  if (reaper.gmem_read(b + 3) or 0) > 0.5 then return end       -- LOCKed pad
  local curix = math.floor((reaper.gmem_read(b + 1) or -1) + 0.5)
  if (reaper.gmem_read(b) or 0) > 0 and curix == EON_PADCAT_NONE then return end
  local c, conf = _bridge_categorizer.classify(name)
  if not (conf and c) then return end
  local newix = eon_padcat_index(c)                             -- -1 for "other"/unknown
  if newix < 0 then return end
  if (reaper.gmem_read(b) or 0) > 0 and newix == curix then return end
  eon_padcat_ver = eon_padcat_ver + 1
  reaper.gmem_write(b + 1, newix)
  reaper.gmem_write(b + 0, eon_padcat_ver)                      -- VER LAST (seqlock)
  eon_padcat_pext_write(slot)
end
-- Dialog-route wrapper: slot from the LOCK cell, same as the loaders — the
-- CMD-50 rename flow holds it until the JSFX consumes CMD 51.
function eon_padcat_from_rename(pad, name)
  local _id = math.floor((reaper.gmem_read(97) or 0) + 0.5)
  local slot = -1
  if _id > 0 then
    for _s = 0, core.GMEM.GS_INST_REG_MAX - 1 do
      if math.floor(reaper.gmem_read(
           core.GMEM.GS_INST_REG_BASE + _s * core.GMEM.GS_INST_REG_STRIDE
           + core.GMEM.GS_INST_REG_OFF_ID) or 0) == _id then slot = _s break end
    end
    if slot < 0 then slot = _id - 1 end
  end
  eon_padcat_apply_rename(slot, pad, name)
end
-- ③ ADAPT (spec rev 2026-07-23; articulation-safe rework 2026-08-04): after a
-- positional load, compute the LANE PERMUTATION that re-aims patterns at their
-- old jobs. Per category: IDENTITY pins first (a lane already aimed right
-- never moves), then zip old pads (ascending) onto new pads (ascending); a
-- hat-FAMILY fallback pass lets unmatched closed/open lanes take a generic-hat
-- pad (and generic take either) with closed<->open BANNED; completion to a
-- strict permutation honours the same ban (identity-preferred, then first free
-- ascending, final unconditional sweep so nothing merges and nothing is lost).
-- The ban exists because category-less kits fragment the hat family ("CH" and
-- "Hi Hat" -> closed, bare "Hat" -> generic, often zero open) and the old
-- category-blind completion handed a surplus CLOSED-hat lane the first free
-- pad ascending — typically the adjacent OPEN hat (real repro: Linn Drum_v2 ->
-- 808_v2 put the 'Hi Hat' lane on 'Open Hat'). A hat lane landing on a NON-hat
-- pad is strictly better than the opposite articulation. Published to the
-- ADAPT band (26004600: [0]=seq LAST, [1]=slot, [2..17]=dst pad for src pad
-- 0..15); Steppa lights its ADAPT button when the perm is non-identity.
EON_PADCAT_ADAPT = 26004600
eon_padcat_adapt_seq = 0
function eon_padcat_adapt_compute(slot)
  -- Consume the snapshot EXACTLY ONCE: nil it up front so an aborted sweep can
  -- never leave a stale prev for a later pad-15 to publish a bogus perm from,
  -- and refuse a snapshot taken for a different slot (same failure family).
  local prev = eon_padcat_prev
  eon_padcat_prev = nil
  if not prev or eon_padcat_prev_slot ~= slot then return end
  local new = {}
  for p = 0, 15 do
    local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + p * 4
    new[p] = (reaper.gmem_read(b) or 0) > 0
      and math.floor((reaper.gmem_read(b + 1) or -1) + 0.5) or -1
  end
  local dst_for_src, dst_taken = {}, {}
  -- LOCKED pads are PINNED to identity and excluded from the zip on BOTH
  -- sides: their audio never moved, so their pattern must not move either —
  -- and no other lane may be re-aimed onto them.
  local locked = {}
  for p = 0, 15 do
    local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + p * 4
    if (reaper.gmem_read(b + 3) or 0) > 0.5 then
      locked[p] = true; dst_for_src[p] = p; dst_taken[p] = true
    end
  end
  -- Hat family (FROZEN glyph ids, rk_cat_glyphs.jsfx-inc): closed=4 open=5
  -- generic=6. closed<->open is the one re-aim strictly worse than anything.
  local CAT_CH, CAT_OH, CAT_HH = 4, 5, 6
  local hat_cat = { [CAT_CH] = true, [CAT_OH] = true, [CAT_HH] = true }
  local function artic_conflict(s, d)
    return (s == CAT_CH and d == CAT_OH) or (s == CAT_OH and d == CAT_CH)
  end
  -- pass 1, exact category: identity pins first, then ascending zip of the rest
  for cat = 0, 45 do
    for p = 0, 15 do
      if not locked[p] and dst_for_src[p] == nil and not dst_taken[p]
         and prev[p] == cat and new[p] == cat then
        dst_for_src[p] = p; dst_taken[p] = true
      end
    end
    local srcs, dsts = {}, {}
    for p = 0, 15 do
      if not locked[p] and dst_for_src[p] == nil and prev[p] == cat then srcs[#srcs + 1] = p end
      if not dst_taken[p] and new[p] == cat then dsts[#dsts + 1] = p end
    end
    for i = 1, math.min(#srcs, #dsts) do
      dst_for_src[srcs[i]] = dsts[i]; dst_taken[dsts[i]] = true
    end
  end
  -- pass 2, hat-family fallback: an unmatched closed/open lane may take a free
  -- generic-hat pad, a generic lane may take any free hat — never closed<->open.
  -- Identity preferred, then ascending.
  for p = 0, 15 do
    if not locked[p] and dst_for_src[p] == nil and hat_cat[prev[p]]
       and not dst_taken[p] and hat_cat[new[p]] and not artic_conflict(prev[p], new[p]) then
      dst_for_src[p] = p; dst_taken[p] = true
    end
  end
  for p = 0, 15 do
    if not locked[p] and dst_for_src[p] == nil and hat_cat[prev[p]] then
      for d = 0, 15 do
        if not dst_taken[d] and hat_cat[new[d]] and not artic_conflict(prev[p], new[d]) then
          dst_for_src[p] = d; dst_taken[d] = true
          break
        end
      end
    end
  end
  -- complete to a permutation: identity when free — unless that would put a
  -- hat lane on the opposite articulation — then first free ascending with the
  -- same ban (a non-hat pad beats the wrong hat)...
  for p = 0, 15 do
    if dst_for_src[p] == nil and not dst_taken[p]
       and not artic_conflict(prev[p], new[p]) then
      dst_for_src[p] = p; dst_taken[p] = true
    end
  end
  -- Ban-constrained lanes (closed/open) pick FIRST — review-confirmed hole in
  -- the first cut: a non-hat lane grabbing the last ban-free pad in plain
  -- ascending order forced the sweep to flip a hat lane although a legal
  -- assignment existed. Hat-first is optimal here: by this point a homeless
  -- closed lane can only use neutral pads (its exact + generic dsts are
  -- consumed), same for open, so the two never contend for anything a later
  -- unconstrained lane can't absorb.
  for p = 0, 15 do
    if dst_for_src[p] == nil and (prev[p] == CAT_CH or prev[p] == CAT_OH) then
      for d = 0, 15 do
        if not dst_taken[d] and not artic_conflict(prev[p], new[d]) then
          dst_for_src[p] = d; dst_taken[d] = true
          break
        end
      end
    end
  end
  for p = 0, 15 do
    if dst_for_src[p] == nil and prev[p] ~= CAT_CH and prev[p] ~= CAT_OH then
      for d = 0, 15 do                            -- non-articulated: no ban can apply
        if not dst_taken[d] then
          dst_for_src[p] = d; dst_taken[d] = true
          break
        end
      end
    end
  end
  -- ...and an unconditional final sweep: a STRICT permutation is mandatory
  -- (StepSeq's apply moves rows by it — a hole merges/loses lanes). Only
  -- reachable when a closed/open lane genuinely has nothing but the opposite
  -- articulation left (no legal ban-respecting completion existed at all).
  local free = {}
  for p = 0, 15 do if not dst_taken[p] then free[#free + 1] = p end end
  local fi = 1
  for p = 0, 15 do
    if dst_for_src[p] == nil then dst_for_src[p] = free[fi]; fi = fi + 1 end
  end
  local identity = true
  for p = 0, 15 do if dst_for_src[p] ~= p then identity = false break end end
  if identity then return end                       -- nothing to adapt; button stays dark
  for p = 0, 15 do
    reaper.gmem_write(EON_PADCAT_ADAPT + 2 + p, dst_for_src[p])
  end
  reaper.gmem_write(EON_PADCAT_ADAPT + 1, slot)
  eon_padcat_adapt_seq = eon_padcat_adapt_seq + 1
  reaper.gmem_write(EON_PADCAT_ADAPT + 0, eon_padcat_adapt_seq)  -- seq LAST
end

-- ── Change-map band (Spec_Swing_Change_Map_And_Reroll §3.2) ─────────────────
-- What the LAST kit operation did to each pad, so the KIT-tab grid can report
-- WHICH pads moved and why. Bridge is the sole writer; the JSFX only reads.
-- SEQ written LAST (same torn-read discipline as PADCAT/ADAPT).
--   codes[pad] : 0 empty · 1 changed · 2 changed-shared(cycle) · 3 locked ·
--                4 custom · 5 no-match · 6 synth
-- ⚠️ 0 and 5 are different answers — 0 is "nothing was here", 5 is "we looked
-- and found nothing". Only 5 means the user should go add sources.
-- GLOBALS by necessity: the main chunk is at Lua's 200-local ceiling.
EON_CHGMAP_BASE, EON_CHGMAP_STRIDE = 26004700, 32   -- = core.GMEM.INST_CHANGEMAP_*
CHGMAP_OP_NONE, CHGMAP_OP_LOAD, CHGMAP_OP_FILL = 0, 1, 2
CHGMAP_OP_REROLL_KIT, CHGMAP_OP_REROLL_PAD     = 3, 4
eon_chgmap_seq = 0

-- codes = { [0..15] = code }, counts = { chg, lock, custom, nomatch, surplus }
function eon_chgmap_publish(inst_id, op, codes, counts)
  local slot = math.floor(inst_id or 0) - 1
  if slot < 0 or slot > 15 then return end
  local b = EON_CHGMAP_BASE + slot * EON_CHGMAP_STRIDE
  codes  = codes  or {}
  counts = counts or {}
  for p = 0, 15 do
    reaper.gmem_write(b + 8 + p, math.floor(codes[p] or 0))
  end
  reaper.gmem_write(b + 1, op)
  reaper.gmem_write(b + 2, math.floor(counts.chg     or 0))
  reaper.gmem_write(b + 3, math.floor(counts.lock    or 0))
  reaper.gmem_write(b + 4, math.floor(counts.custom  or 0))
  reaper.gmem_write(b + 5, math.floor(counts.nomatch or 0))
  reaper.gmem_write(b + 6, math.floor(counts.surplus or 0))
  reaper.gmem_write(b + 7, reaper.time_precise())
  eon_chgmap_seq = eon_chgmap_seq + 1
  reaper.gmem_write(b + 0, eon_chgmap_seq)            -- SEQ LAST
end

-- Tally helper so producers can't drift on what each count means: derives the
-- five counters from the code table rather than having each caller add up its
-- own. `surplus` is the only figure the codes can't express (those samples
-- landed on no pad at all), so it is passed in.
function eon_chgmap_counts(codes, surplus)
  local c = { chg = 0, lock = 0, custom = 0, nomatch = 0, surplus = surplus or 0 }
  for p = 0, 15 do
    local v = math.floor((codes or {})[p] or 0)
    if     v == 1 or v == 2 then c.chg     = c.chg     + 1
    elseif v == 3           then c.lock    = c.lock    + 1
    elseif v == 4           then c.custom  = c.custom  + 1
    elseif v == 5           then c.nomatch = c.nomatch + 1 end
  end
  return c
end
-- ── P_EXT persistence (spec §7b): categories survive REAPER restarts without
-- a kit re-load. Record on the Swing TRACK: P_EXT:EON_SWING_PADS =
-- "cat,src,lock;cat,src,lock;..." (16 flat records, cat = vocab NAME or "").
-- Bridge is the only writer, and it owns all 16 records -> plain overwrite.
-- Param 3 is Swing's slider4 = instance_id, a MONOTONIC counter from gmem[94]
-- that is never reused. A registry SLOT is a first-free claim over 16 cells and
-- IS reused. They coincide only while instances are added and never removed, so
-- `== slot + 1` resolved the wrong track after any churn (add three, delete the
-- first, add a fourth: id 4 reclaims slot 0). Go through the registry, which is
-- the only thing that knows slot -> id.
--
-- core.GMEM, not G: `local G = core.GMEM` is declared at ~2251 and Lua locals
-- are invisible above their declaration, so G here would index a nil global and
-- throw — silently, since the restore below runs under pcall. Nothing new is
-- hoisted to a main-chunk local either; this file sits near Lua's 200-local cap.
function eon_padcat_track_for_slot(slot)
  if not slot or slot < 0 or slot >= core.GMEM.GS_INST_REG_MAX then return nil end
  local want = math.floor(reaper.gmem_read(
    core.GMEM.GS_INST_REG_BASE + slot * core.GMEM.GS_INST_REG_STRIDE
    + core.GMEM.GS_INST_REG_OFF_ID) or 0)
  -- Load-bearing, not padding: an unclaimed slot reads 0 and most normalized FX
  -- params floor to 0, so without this an empty slot matches the first arbitrary
  -- FX on the first track. The old code was accidentally immune (slot+1 >= 1).
  if want <= 0 then return nil end
  for tr_idx = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, tr_idx)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0) == want then return tr end
    end
  end
  return nil
end
function eon_padcat_pext_write(slot)
  local tr = eon_padcat_track_for_slot(slot)
  if not tr then return end
  eon_padcat_index("kick")                          -- ensure name maps built
  local parts = {}
  for pad = 0, 15 do
    local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
    local cat = ""
    if (reaper.gmem_read(b) or 0) > 0 then
      local id = math.floor((reaper.gmem_read(b + 1) or -1) + 0.5)
      -- "-" is the NONE token, and it is NOT the same as "" (never classified).
      -- "" restores as -1, which every glyph consumer treats as "infer from the
      -- name" — so without a distinct token a pad the user explicitly cleared
      -- grows its old glyph back on the next project open.
      cat = id == EON_PADCAT_NONE and "-" or (eon_padcat_names[id] or "")
    end
    parts[#parts + 1] = cat .. "," ..
      math.floor((reaper.gmem_read(b + 2) or 0) + 0.5) .. "," ..
      math.floor((reaper.gmem_read(b + 3) or 0) + 0.5)
  end
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_SWING_PADS",
    table.concat(parts, ";"), true)
end
-- Publish one saved P_EXT:EON_SWING_PADS record into a slot's PADCAT band.
-- Shared by the startup restore and the cold-start backfill (which must
-- PREFER a saved record over name inference — see eon_padcat_backfill_tick).
function eon_padcat_record_to_band(slot, rec)
  local pad = 0
  for entry in string.gmatch(rec, "([^;]*)") do
    if pad > 15 then break end
    local cat, src, lock = string.match(entry, "([^,]*),([^,]*),([^,]*)")
    if cat ~= nil then
      local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
      eon_padcat_ver = eon_padcat_ver + 1
      reaper.gmem_write(b + 1, cat == "-" and EON_PADCAT_NONE
                                or eon_padcat_index(cat ~= "" and cat or nil))
      reaper.gmem_write(b + 2, tonumber(src) or 0)
      reaper.gmem_write(b + 3, tonumber(lock) or 0)
      reaper.gmem_write(b + 0, eon_padcat_ver)  -- VER LAST
      pad = pad + 1
    end
  end
end
-- Startup republish: every Swing instance's saved record -> its PADCAT band,
-- so badges/lane icons are correct BEFORE any kit load this session.
function eon_padcat_pext_restore()
  eon_padcat_index("kick")
  for tr_idx = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, tr_idx)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      -- Inverse of eon_padcat_track_for_slot: id -> slot, again via the registry
      -- rather than `- 1`. Deliberately NOT ss_resolve_slot(): that gates on
      -- heartbeat freshness, and this runs once at bridge load — exactly when an
      -- instance may not have claimed a slot or heartbeated yet. That would swap
      -- a wrong-instance bug for an intermittent restores-nothing bug. The
      -- question here is identity, not liveness.
      local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
      local slot = nil
      if inst_id > 0 then
        for s = 0, core.GMEM.GS_INST_REG_MAX - 1 do
          if math.floor(reaper.gmem_read(
               core.GMEM.GS_INST_REG_BASE + s * core.GMEM.GS_INST_REG_STRIDE
               + core.GMEM.GS_INST_REG_OFF_ID) or 0) == inst_id then slot = s; break end
        end
      end
      if slot then
        local ok, rec = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_SWING_PADS", "", false)
        if ok and rec and rec ~= "" then
          eon_padcat_record_to_band(slot, rec)
        end
      end
    end
  end
end
-- Category write-back mailbox (26004500: [0]=seq LAST [1]=slot [2]=note
-- [3]=cat request [4]=SRC hint). Resolves the note to a pad via the IDENT band
-- (26000000, NOTE field 4), then single-pad seqlock republish. Polled beside
-- eon_preset_nav_tick. Writers: Steppa's lane icon-pick, and Swing's own LCD
-- pill / pad badge / picker overlay / Clear Pad (swing_lcd_padcat_post_ex).
--
-- [3] cat request: 0..45 = that category · -1 = Auto (re-infer from the pad's
--     name) · -2 = toggle the audio LOCK · EON_PADCAT_NONE (-3) = the user says
--     this pad has no job (published verbatim, never re-inferred).
-- [4] SRC hint: -1 leaves the pad's provenance alone (every historical writer
--     means this, and a pre-update Steppa leaves the cell at 0 — see the guard
--     below) · 0..2 sets it, 2 = "the user's own sample", which FILL refuses to
--     stomp.
eon_padcat_req_last = nil
function eon_padcat_req_tick()
  local gr, gw = reaper.gmem_read, reaper.gmem_write
  local seq = math.floor((gr(26004500) or 0) + 0.5)
  if eon_padcat_req_last == nil then eon_padcat_req_last = seq return end  -- baseline stale
  if seq == eon_padcat_req_last then return end
  eon_padcat_req_last = seq
  local slot = math.floor((gr(26004501) or -1) + 0.5)
  local note = math.floor((gr(26004502) or -1) + 0.5)
  local cat  = math.floor((gr(26004503) or -1) + 0.5)
  -- A writer that predates the SRC arg never touches 26004504, so the cell holds
  -- whatever the last SRC-aware post left there. Only a request that is ITSELF
  -- SRC-aware may set provenance; the arg is stamped -1 on every post from the
  -- updated JSFX, so a stale 0..2 can only come from an older one. Reset the
  -- cell after reading so the next unaware writer reads the neutral -1.
  local srch = math.floor((gr(26004504) or -1) + 0.5)
  gw(26004504, -1)
  if slot < 0 or slot > 15 then return end
  for pad = 0, 15 do
    local nb = 26000000 + slot * 128 + pad * 8      -- INST_IDENT: pad's NOTE at +4
    if math.floor((gr(nb + 4) or -1) + 0.5) == note then
      if cat == -2 then                             -- ② LOCK TOGGLE sentinel
        local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
        eon_padcat_ver = eon_padcat_ver + 1
        gw(b + 3, (gr(b + 3) or 0) > 0.5 and 0 or 1)
        gw(b + 0, eon_padcat_ver)                   -- VER LAST
        eon_padcat_pext_write(slot)
        return
      end
      -- NONE is an ANSWER, so it skips the Auto branch below (which exists to
      -- turn "I don't know" into a guess). Everything else negative is Auto.
      if cat < 0 and cat ~= EON_PADCAT_NONE and _bridge_categorizer then
        local nmb, chars = 26010000 + slot * 512 + pad * 32, {}
        for i = 0, 31 do
          local ch = math.floor((gr(nmb + i) or 0) + 0.5)
          if ch <= 0 then break end
          chars[#chars + 1] = string.char(math.min(255, math.max(1, ch)))
        end
        local nm = table.concat(chars)
        if nm ~= "" then
          local c, conf = _bridge_categorizer.classify(nm)
          cat = (conf and c ~= "other") and eon_padcat_index(c) or -1
        end
      end
      local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
      eon_padcat_ver = eon_padcat_ver + 1
      gw(b + 1, cat)                                -- glyph id direct (Steppa sent vocab id)
      if srch >= 0 then gw(b + 2, srch) end         -- SRC only when the writer asked
      gw(b + 0, eon_padcat_ver)                     -- VER LAST
    end
  end
  eon_padcat_pext_write(slot)                       -- persist the edit (survives restart)
end
-- Browser-origin category posts (sample load, drag-drop, multi-select import).
-- Queue format "slot:pad:catname" joined by ";" — see queue_pad_category in
-- Swing_Browser.lua for why this rides ExtState instead of the 26004500 mailbox
-- (that mailbox is single-slot with two writers already; a burst of pad loads
-- would drop all but the last, and a racing post could mis-target a pad).
--
-- ⭐ SRC=2 is written HERE and nowhere else. The band reserved offset +2 for
-- provenance and eon_fill_begin already refuses to stomp SRC==2 ("custom
-- sample") — but nothing ever set it, so FILL would happily overwrite a pad the
-- user had loaded their own sample onto. A browser load IS that event.
function eon_padcat_queue_tick()
  local q = reaper.GetExtState("EON_Swing", "padcat_queue")
  if q == "" then return end
  reaper.SetExtState("EON_Swing", "padcat_queue", "", false)
  local gr, gw = reaper.gmem_read, reaper.gmem_write
  eon_padcat_index("kick")                          -- ensure the name map is built
  local touched = {}
  for entry in q:gmatch("[^;]+") do
    local slot, pad, cat = entry:match("^(%d+):(%d+):(.+)$")
    slot, pad = tonumber(slot), tonumber(pad)
    if slot and pad and slot <= 15 and pad <= 15 then
      local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
      -- LOCK wins over everything — the same rule kit loads and FILL follow.
      if (gr(b + 3) or 0) < 0.5 then
        local id = eon_padcat_index(cat)
        if id >= 0 then
          eon_padcat_ver = eon_padcat_ver + 1
          gw(b + 1, id)                             -- glyph id
          gw(b + 2, 2)                              -- SRC: the user's own sample
          gw(b + 0, eon_padcat_ver)                 -- VER LAST (publish barrier)
          touched[slot] = true
        end
      end
    end
  end
  -- One P_EXT write per touched instance, not per pad: a 16-pad drop would
  -- otherwise rewrite the same track's extended state sixteen times.
  for slot in pairs(touched) do eon_padcat_pext_write(slot) end
end

-- kit-categories: COLD-START BACKFILL. A rack that predates the category era
-- (a fresh project sitting on the default kit, or an old project with no
-- P_EXT record) has an all-zero PADCAT band — so the ADAPT snapshot taken at
-- the NEXT kit load has no "before" map, the permutation collapses to
-- identity, and the chip can never light. Observed exactly as "default kit ->
-- 909 played the OH where the CH lane was": the load was positional (by
-- design) and the one-click rescue was structurally dark.
-- Once per slot: every pad still VER==0 whose live name mirror is non-empty
-- gets its name classified and published (SRC=0, P_EXT persisted). Published
-- pads are never touched, so restored/loaded racks are a no-op pass. Names
-- may lag instance registration by a few blocks, so an empty rack retries
-- for ~10s before giving up (a genuinely blank rack has nothing to protect;
-- any later load publishes through eon_padcat_from_load anyway).
-- Review-hardened 2026-08-04 (three confirmed findings on the first cut):
--   * bf_done stores the OBSERVED instance id, not `true` — registry slots are
--     freed and re-claimed, and a later cold rack reusing the slot must re-arm.
--   * before inferring, the slot's TRACK is checked for a saved
--     P_EXT:EON_SWING_PADS record — a record the one-shot startup restore
--     missed (project opened mid-session, instance claimed its slot late) is
--     RESTORED, never overwritten with inference; the first cut permanently
--     clobbered saved locks/custom categories via pext_write.
--   * pads whose name mirror fills the full 32-char transport are SKIPPED:
--     the tail word is likely lost ("...808 Hi Hat Open" -> "...808 Hi Hat")
--     and a confident-but-wrong closed/open verdict here would poison the
--     ADAPT prev map as an exact-category match the articulation ban cannot
--     see. Left VER==0, such a pad heals at the next kit load, where
--     eon_padcat_from_load has the full path to classify.
eon_padcat_bf_done = {}
eon_padcat_bf_tries = {}
function eon_padcat_backfill_tick()
  if not _bridge_categorizer then return end
  local gr, gw = reaper.gmem_read, reaper.gmem_write
  local GM = core.GMEM
  for s = 0, GM.GS_INST_REG_MAX - 1 do
    local id = math.floor((gr(GM.GS_INST_REG_BASE + s * GM.GS_INST_REG_STRIDE
                              + GM.GS_INST_REG_OFF_ID) or 0) + 0.5)
    if id > 0 and eon_padcat_bf_done[s] ~= id then
      eon_padcat_index("kick")                    -- ensure the name map is built
      -- A saved record beats inference, always. Covers the restore windows the
      -- startup one-shot misses (late slot claim, project switched mid-session).
      local tr = eon_padcat_track_for_slot(s)
      local rec = nil
      if tr then
        local ok, r = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_SWING_PADS", "", false)
        if ok and r and r ~= "" then rec = r end
      end
      if rec then
        local allzero = true
        for pad = 0, 15 do
          if (gr(EON_PADCAT_BASE + s * EON_PADCAT_STRIDE + pad * 4) or 0) > 0.5 then
            allzero = false break
          end
        end
        if allzero then eon_padcat_record_to_band(s, rec) end   -- live band wins over disk
        eon_padcat_bf_done[s] = id                              -- record present: never infer
        eon_padcat_bf_tries[s] = 0
      else
        local touched, sawname = false, false
        for pad = 0, 15 do
          local b = EON_PADCAT_BASE + s * EON_PADCAT_STRIDE + pad * 4
          local nmb, chars = GM.INST_PADNAME_BASE + s * GM.INST_PADNAME_INST_STRIDE
                             + pad * GM.INST_PADNAME_PAD_LEN, {}
          for i = 0, GM.INST_PADNAME_PAD_LEN - 1 do
            local ch = math.floor((gr(nmb + i) or 0) + 0.5)
            if ch <= 0 then break end
            chars[#chars + 1] = string.char(math.min(255, math.max(1, ch)))
          end
          local nm = table.concat(chars)
          if nm ~= "" then sawname = true end
          if nm ~= "" and #nm < GM.INST_PADNAME_PAD_LEN   -- full mirror = suspected truncation
             and (gr(b) or 0) < 0.5 then                  -- VER==0: never published
            local c, conf = _bridge_categorizer.classify(nm)
            if conf and c ~= "other" then
              eon_padcat_ver = eon_padcat_ver + 1
              gw(b + 1, eon_padcat_index(c))        -- CAT
              gw(b + 2, 0)                          -- SRC: inferred
              gw(b + 3, 0)                          -- LOCK stays off
              gw(b + 0, eon_padcat_ver)             -- VER LAST (seqlock)
              touched = true
            end
          end
        end
        if touched then eon_padcat_pext_write(s) end
        if sawname then
          eon_padcat_bf_done[s] = id                -- names were live: one pass is final
          eon_padcat_bf_tries[s] = 0
        else
          eon_padcat_bf_tries[s] = (eon_padcat_bf_tries[s] or 0) + 1
          if eon_padcat_bf_tries[s] > 300 then
            eon_padcat_bf_done[s] = id              -- blank rack: stand down (re-arms on occupant change)
            eon_padcat_bf_tries[s] = 0
          end
        end
      end
    end
  end
end

-- color_native (optional): the track's I_CUSTOMCOLOR — when given, picks the
-- hue-tinted glyph variant (rk_lua_icons.resolve_tinted) so multi-out icons
-- follow the kit hue, matching the DM lane tracks.
local function bridge_icon_for_name(name, color_native)
  if not (_bridge_icons and _bridge_categorizer) then return nil end
  if not name or name == "" then return "" end
  local cat = _bridge_categorizer.classify(name)
  if color_native and _bridge_icons.resolve_tinted then
    return _bridge_icons.resolve_tinted(cat, color_native) or ""
  end
  return _bridge_icons.resolve(cat) or ""
end
-- Apply icon to a multi-out track. Loaded pad → resolved icon path (or ""
-- when category has no art). Blank pad → "" (clears P_ICON to REAPER
-- default) regardless of resolver availability so emptied multi-outs don't
-- keep the previous kit's drum icon. Caller passes the raw pad name.
local function bridge_apply_icon(track, pad_idx_0, pad_name)
  if not track then return end
  local icon_path
  if core.pad_has_audio(pad_idx_0) and _bridge_icons and _bridge_categorizer then
    local tcol = reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR")
    icon_path = bridge_icon_for_name(pad_name, tcol) or ""
  else
    icon_path = ""
  end
  -- Guarded write — never stomp an icon the user set by hand (the guard
  -- lives in rk_lua_icons.apply; legacy direct write only if the module
  -- is missing/older, preserving the blank-pad clear behaviour).
  if _bridge_icons and _bridge_icons.apply then
    _bridge_icons.apply(track, icon_path)
  else
    reaper.GetSetMediaTrackInfo_String(track, "P_ICON", icon_path, true)
  end
end

-- Drum Matrix lane sync (optional). The bridge always runs, so loading the
-- Drum Matrix's swing_sync here and ticking it in our defer loop makes the
-- MIDI-lane tracks (P_EXT:EON_DRUM_LANE) reflect the live kit ALL the time —
-- not only while the Drum Matrix overlay window is open. It's the EXACT same
-- code the overlay uses (no duplication, can't drift). Graceful if the Drum
-- Matrix isn't installed: dm_swing_sync stays nil and we skip it.
-- Folder-layout reorganiser (lives in the Drum Matrix lib because that's where
-- folder_layout.lua sits — same path-relative dofile pattern as swing_sync).
-- It REFINES the multi-sub-folder arrangement (audio sub + DM sub as siblings)
-- when present. It is NOT required for a valid layout: do_build_multiout now
-- closes the audio sub-folder itself (self-contained -1 on the last child), so
-- bare-Swing users without the Drum Matrix get a properly-closed audio sub even
-- when folder_layout is absent. (Pre-fix, the self-close was deleted in d417cfa
-- and the only closer was this module — so a missing/failed load silently broke
-- the layout. Surface the failure now, the same way dm_swing_sync does.)
-- Resolve a Drum Matrix lib file ("EON/Drum Matrix/lib/<rel>") to an absolute path.
-- Since the 2026-07-02 layout cleanup the DM single-tree lives in the bridge's OWN
-- .Scripts/EON tree (the dotless Scripts/ sibling is gone), so the _SCRIPT_DIR base
-- resolves first; the de-dotted Scripts/ twin stays as a legacy fallback. REAPER's
-- registered action path carries DOUBLED backslashes + a TRAILING separator -- so
-- normalise every run of separators to "/" and strip the trailing one BEFORE de-dotting.
-- Returns the first base where the file exists (else the de-dotted path, for the error
-- msg). io.open/dofile accept "/" on Windows. Module-GLOBAL (no `local`) to dodge the
-- ~200-local ceiling and so all three loaders below share ONE resolver.
function eon_dm_lib_path(rel)
  local base = _SCRIPT_DIR:gsub("[/\\]+", "/"):gsub("/+$", "")
  local b2   = base:gsub("/%.Scripts$", "/Scripts")
  local bases = (b2 ~= base) and { base, b2 } or { base }
  local i = 1
  while i <= #bases do
    local p = bases[i] .. "/EON/Drum Matrix/lib/" .. rel
    local f = io.open(p, "r")
    if f then f:close(); return p end
    i = i + 1
  end
  return bases[#bases] .. "/EON/Drum Matrix/lib/" .. rel
end

local folder_layout
do
  local fl_path = eon_dm_lib_path("folder_layout.lua")
  local _f = io.open(fl_path, "r")
  if _f then
    _f:close()
    local ok, mod = pcall(dofile, fl_path)
    if ok and type(mod) == "table" and mod.EnsureSwingParentLayout then
      folder_layout = mod
    else
      reaper.ShowConsoleMsg(
        "[Swing Bridge] folder_layout FAILED to load: " .. tostring(mod) ..
        "\n  (multi-out audio sub still closes itself; audio+DM sibling " ..
        "grouping won't be refined)\n")
    end
  end
end

local dm_swing_sync
do
  local dm_path = eon_dm_lib_path("swing_sync.lua")
  -- Silent skip when the Drum Matrix isn't installed (bare-Swing users see
  -- nothing on startup). When it IS present but load fails, SURFACE the error
  -- — do not go back to silently swallowing it. That single visible line is
  -- what unblocked the always-on sync after eight days of stale-code debugging.
  -- (Until the de-dot fix above, this resolved to the deleted .Scripts/EON tree and
  -- silently no-op'd from the bridge -- so lane icons/names only appeared once the DM
  -- overlay was opened. Now the always-on reflect paints them right after a build.)
  local _f = io.open(dm_path, "r")
  if _f then
    _f:close()
    local ok, mod = pcall(dofile, dm_path)
    if ok and type(mod) == "table" and mod.Tick then
      dm_swing_sync = mod
    else
      reaper.ShowConsoleMsg(
        "[Swing Bridge] Drum Matrix lane sync FAILED to load: " .. tostring(mod) ..
        "\n  (lanes will only sync while the Drum Matrix overlay is open)\n")
    end
  end
end

-- StepSeq <-> Drum Matrix "Import on engage" courier (Phase 1 -> 2 fold-in).
-- Folded in from the former standalone EON_StepSeq_Sync_Courier.lua so Sync just
-- works with no second defer script to launch (that standalone now self-disables
-- when it sees the bridge alive). Loads the two DM libs it needs (same path-relative
-- dofile pattern as dm_swing_sync above) and is ticked once per poll by
-- eon_courier_tick(). Module-GLOBAL state (no `local`) to respect the ~200-local
-- ceiling on the bridge main chunk. WRITE-ONLY into gmem: it stages the transfer
-- buffer + bumps the per-slot dm_push; the JSFX import owns the pattern arrays.
-- When a paired StepSeq turns Sync ON (rising edge of the per-slot SYNCON flag it
-- publishes — and the JSFX only raises SYNCON when sync-mode is ON *and* paired,
-- so the scan is already slot-gated) the current DM region's notes are staged into
-- its grid. eon_courier stays nil when the Drum Matrix isn't installed (bare-Swing).
eon_courier = nil   -- {lane_tools, pattern_regions, prev={}, seq={}} or nil
do
  -- Resolve a DM lib by file name via the shared eon_dm_lib_path resolver. Since the
  -- 2026-07-02 layout cleanup the DM single-tree lives in the bridge's OWN
  -- .Scripts/EON tree, so the _SCRIPT_DIR base resolves first (the de-dotted
  -- Scripts/ base remains as a legacy fallback). The dm_swing_sync / folder_layout
  -- loaders above use the same resolver.
  local function _try(rel)
    local p = eon_dm_lib_path(rel)   -- shared de-dot resolver (defined near the top)
    local f = io.open(p, "r")
    if not f then return nil end
    f:close()
    local ok, m = pcall(dofile, p)
    return (ok and type(m) == "table") and m or nil
  end
  local lt = _try("lane_tools.lua")
  local pr = _try("pattern_regions.lua")
  -- P3b-4c: song engine for the StepSeq SONG strip. Note this is the BRIDGE's
  -- own Lua state — the DM overlay (a separate ReaScript) has its own engine
  -- instance; chain DATA stays consistent via project ExtState, but a chain
  -- PLAYING from the overlay won't light the JSFX strip (and vice versa).
  local ps = _try("pattern_song.lua")
  -- CollectRegion is the one method the courier hard-needs; pattern_regions is
  -- optional (the painted-lane-span fallback covers "no region made yet").
  if lt and lt.CollectRegion then
    eon_courier = { lane_tools = lt, pattern_regions = pr, pattern_song = ps,
                    prev = {}, seq = {}, exp = {} }
  end
  -- Startup banner is a diagnostic; silent unless EON_Bridge/debug_startup=1.
  if reaper.GetExtState("EON_Bridge", "debug_startup") == "1" then
    reaper.ShowConsoleMsg(eon_courier
      and "[bridge] StepSeq<->DM Import courier: ACTIVE\n"
      or  "[bridge] StepSeq<->DM Import courier: inactive (DM libs not found)\n")
  end
  -- Opt-in courier trace (OFF by default; enable with ExtState EON_Bridge/courier_diag=1).
  -- Writes .Scripts/_courier_diag.txt: load status, per-100-tick heartbeat, push/skip events,
  -- and a raw per-lane scan when a push finds no notes. Zero file I/O unless enabled. Kept in
  -- (rather than ripped out) because the Export/live phases will want the same visibility.
  eon_courier_diag_on  = reaper.GetExtState("EON_Bridge", "courier_diag") == "1"
  eon_courier_diagpath = _SCRIPT_DIR .. _sep .. "_courier_diag.txt"
  if eon_courier_diag_on then
    local f = io.open(eon_courier_diagpath, "w")
    if f then
      f:write(string.format("[%s] LOAD eon_courier=%s lane_tools=%s(CollectRegion=%s) pattern_regions=%s scriptdir=%s\n",
        os.date("%H:%M:%S"), tostring(eon_courier ~= nil),
        tostring(lt ~= nil), tostring(lt ~= nil and lt.CollectRegion ~= nil),
        tostring(pr ~= nil), _SCRIPT_DIR))
      f:close()
    end
  end
end

-- EON: merged-mode trigger mirror (folded in the same way the courier above was).
-- Merged mode puts each pad's pattern item on the pad's own multi-out AUDIO
-- track. Such a track cannot send its MIDI to Swing — it already receives audio
-- from Swing, and a track that is both upstream and downstream of another is a
-- routing cycle REAPER culls (the silent ADAPT attempt noted at
-- EON_DM_Build.lua:495). The notes therefore reach Swing through ONE hidden
-- trigger track, and this keeps that track equal to the lanes. Living in the
-- bridge is what makes merged mode work with no second script to launch;
-- EON_DM_MergedMirror.lua self-disables when it sees the bridge alive.
-- Stays nil on bare-Swing installs (no Drum Matrix tree = no merged mode).
eon_merged_mirror = nil
do
  local p = eon_dm_lib_path("merged_mirror.lua")
  local f = io.open(p, "r")
  if f then
    f:close()
    local ok, m = pcall(dofile, p)
    if ok and type(m) == "table" and m.Sync then eon_merged_mirror = m end
  end
  if reaper.GetExtState("EON_Bridge", "debug_startup") == "1" then
    reaper.ShowConsoleMsg(eon_merged_mirror
      and "[bridge] Merged-mode trigger mirror: ACTIVE\n"
      or  "[bridge] Merged-mode trigger mirror: inactive (DM libs not found)\n")
  end
end

-- Merged-mirror tick. Runs at a fraction of the poll rate: the work is a digest
-- string compare per merged kit, and a rebuild only when that digest moves, so
-- an idle project costs three P_EXT reads per track per pass (MergedInstances,
-- then MergedLanes and FindTrigger inside Sync) and one MIDI_GetHash per pattern
-- item. Untagged tracks stop at the empty-string check and never reach json.
-- Module-GLOBAL (no
-- `local`) for the ~200-local ceiling; the poll loop pcall-guards it.
function eon_merged_mirror_tick()
  local M = eon_merged_mirror
  if not M then return end
  eon_mm_tick = (eon_mm_tick or 0) + 1
  if eon_mm_tick % 8 ~= 0 then return end
  -- Project-pointer watch, ported from EON_DM_MergedMirror's own tick. The
  -- mirror's digest cache is keyed by Swing GUID alone, and GUIDs repeat across
  -- tabs and across reopens of the same file — so without this the mirror finds a
  -- matching cached digest in a freshly-activated project, calls that project's
  -- trigger track up to date, and never rebuilds it. Nothing then fires. The
  -- bridge outlives every project it sees, so it needs this guard MORE than the
  -- standalone that shipped with it, not less.
  -- Deliberately NOT folded into the prev_proj_filename watcher above: that one
  -- keys on the FILENAME, so it cannot see a switch between two tabs holding the
  -- same file, and it drives Save-As sidecar migration, not this tick's business.
  local proj = reaper.EnumProjects(-1)
  if proj ~= eon_mm_proj then
    eon_mm_proj = proj
    M.Reset()
  end
  local list = M.MergedInstances()
  -- Guard each instance, the way the standalone's SafePcall does. The poll
  -- loop's outer pcall abandons the whole list on the first fault, so with two
  -- merged kits open a fault on the first would starve the second every tick.
  for i = 1, #list do pcall(M.Sync, list[i]) end
end

-- ── Sync playback ownership (2026-09-02) ─────────────────────────────────────
-- While a paired StepSeq has Sync ON, its grid is ALSO in the project -- the
-- stereo "Pattern 1" item on the Swing track, or the classic/merged lanes -- and
-- that copy plays into the same FX chain. Every hit reached Swing twice: the
-- item's note through the StepSeq's passthrough, then the StepSeq's own note in
-- the same block (Swing's _blk_trig dedup hid most of it; the classic/merged
-- builders refuse to rely on that and delete the redundant copy instead).
-- Decision (user, 2026-09-02): the STEPSEQ PLAYS. The bridge mutes the project
-- copy inside the bound region window and releases it when sync goes off, the
-- StepSeq unpairs, or it disappears.
--
-- Marker = item P_EXT:EON_SYNC_MUTE. Values: the Swing track GUID = "muted by
-- us for this Swing"; "user" = the user unmuted an item we had muted, so it is
-- theirs until it leaves the wanted set. Invariants:
--   * only mute an item that is unmuted AND unmarked, marking it in the same pass;
--   * only unmute an item that carries OUR guid marker, clearing it in the same pass;
--   * marked (guid) but already unmuted = the user (or an undo) took it back:
--     re-mark "user", leave it alone -- doubles are their choice;
--   * unmarked but muted = the user's own mute: never touched, never claimed.
-- SYNCON alone is NOT trusted: the JSFX writes it only for the slot it is in and
-- never clears the slot it left, so a deleted or re-paired StepSeq leaves a
-- stale 1 behind. Pairing existence (_seq_ms_owned, refresh_stepseq_pairing)
-- is ANDed in by the caller, which passes the set of truly synced slots.
-- Item-level mute is used for every lane shape: it is region-scoped, silent
-- (deferred-script writes create no undo points), and merged_mirror's Digest
-- already honours item B_MUTE, so a muted merged lane drops out of the hidden
-- trigger item on the next mirror pass. Module-GLOBAL: the bridge main chunk
-- sits at Lua's 200-local ceiling.
-- Scroll the arrange VERTICALLY so a slot's KIT TRACKS are in view: its Swing track and
-- every Drum Matrix lane tagged with that Swing's guid (untagged lanes count when none
-- is tagged: a pre-identity build). REAPER has no scroll-to-track call without the JS
-- extension, so this borrows the track selection for one action (40913, "Vertical
-- scroll selected tracks into view", the Swing track selected first so it leads when
-- the kit is taller than the view) and puts the selection back exactly. Used by the
-- zoom ops (10/11) and zoom-on-select (user 2026-09-03: "add the vertical scroll to
-- the kit tracks"). Module-GLOBAL: the bridge main chunk sits at Lua's 200-local ceiling.
function eon_scroll_kit_into_view(C, slot)
  local tr = eon_padcat_track_for_slot(slot)
  if not tr then return false end
  local lt, guid = C.lane_tools, reaper.GetTrackGUID(tr)
  local kit, tagged, untagged = { tr }, {}, {}
  if lt and lt.GetLanes then
    for _, lane in ipairs(lt.GetLanes() or {}) do
      local lg = (lane.lane_info or {}).swing_instance_guid
      if lane.track and lane.track ~= tr then
        if lg == guid then tagged[#tagged + 1] = lane.track
        elseif lg == nil or lg == '' then untagged[#untagged + 1] = lane.track end
      end
    end
  end
  for _, t in ipairs(#tagged > 0 and tagged or untagged) do kit[#kit + 1] = t end
  local saved = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    if reaper.IsTrackSelected(t) then saved[#saved + 1] = t end
  end
  local master = reaper.GetMasterTrack(0)                -- audit 2026-09-03: 40297 clears it too
  local master_sel = master and reaper.IsTrackSelected(master)
  reaper.PreventUIRefresh(1)
  reaper.SetOnlyTrackSelected(kit[1])
  for i = 2, #kit do reaper.SetTrackSelected(kit[i], true) end
  reaper.Main_OnCommand(40913, 0)   -- Track: Vertical scroll selected tracks into view
  reaper.Main_OnCommand(40297, 0)   -- Track: Unselect all tracks
  for _, t in ipairs(saved) do reaper.SetTrackSelected(t, true) end
  if master_sel then reaper.SetTrackSelected(master, true) end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  return true
end

function eon_sync_mute_pass(C, synced, windows_fn, diag)
  local lt = C.lane_tools
  if not (lt and lt.GetLanes) then return end
  local lanes = lt.GetLanes() or {}
  local nsynced = 0
  for _ in pairs(synced) do nsynced = nsynced + 1 end
  -- 1) WANTED: every MIDI item on the synced Swing's own lanes that overlaps one of
  --    the windows the StepSeq now PLAYS (step 3: every mapped region whose pattern
  --    it reports loaded; with no regions, the painted span it duplicates). A
  --    section not loaded yet keeps its item audible, so nothing can go silent.
  local want = {}
  for slot in pairs(synced) do
    local tr = eon_padcat_track_for_slot(slot)
    local wins = windows_fn(slot) or {}
    if tr and #wins > 0 then
      local guid = reaper.GetTrackGUID(tr)
      for _, lane in ipairs(lanes) do
        local li = lane.lane_info or {}
        local lg = li.swing_instance_guid
        -- a lane tagged with no guid (pre-identity build) can only mean this
        -- Swing when it is the only synced one
        if lane.track and (lg == guid or ((lg == nil or lg == '') and nsynced == 1)) then
          for i = 0, reaper.CountTrackMediaItems(lane.track) - 1 do
            local it = reaper.GetTrackMediaItem(lane.track, i)
            local tk = it and reaper.GetActiveTake(it)
            if tk and reaper.TakeIsMIDI(tk) then
              local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
              local e = p + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
              for _, w in ipairs(wins) do
                if e > w.start + 1e-6 and p < w.end_ - 1e-6 then want[it] = guid end
              end
            end
          end
        end
      end
    end
  end
  -- 2) RECONCILE every lane item against the invariants above.
  local touched, muted_n, freed_n = false, 0, 0
  reaper.PreventUIRefresh(1)
  for _, lane in ipairs(lanes) do
    if lane.track then
      for i = 0, reaper.CountTrackMediaItems(lane.track) - 1 do
        local it = reaper.GetTrackMediaItem(lane.track, i)
        local tk = it and reaper.GetActiveTake(it)
        if tk and reaper.TakeIsMIDI(tk) then
          local _, mark = reaper.GetSetMediaItemInfo_String(it, 'P_EXT:EON_SYNC_MUTE', '', false)
          mark = mark or ''
          local muted = reaper.GetMediaItemInfo_Value(it, 'B_MUTE') == 1
          local w = want[it]
          if w then
            if not muted and mark == '' then
              reaper.SetMediaItemInfo_Value(it, 'B_MUTE', 1)
              reaper.GetSetMediaItemInfo_String(it, 'P_EXT:EON_SYNC_MUTE', w, true)
              touched = true; muted_n = muted_n + 1
            elseif not muted and mark ~= 'user' then
              -- we muted it, the user unmuted it: theirs while it stays wanted
              reaper.GetSetMediaItemInfo_String(it, 'P_EXT:EON_SYNC_MUTE', 'user', true)
            end
          elseif mark ~= '' then
            if muted and mark ~= 'user' then
              reaper.SetMediaItemInfo_Value(it, 'B_MUTE', 0)
              freed_n = freed_n + 1
            end
            reaper.GetSetMediaItemInfo_String(it, 'P_EXT:EON_SYNC_MUTE', '', true)
            touched = true
          end
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  if touched then
    reaper.UpdateArrange()
    if diag then
      diag(string.format("[%s] SYNC-MUTE muted=%d released=%d synced_slots=%d",
        os.date("%H:%M:%S"), muted_n, freed_n, nsynced))
    end
  end
end

-- Courier tick — ported verbatim from the former standalone defer script. Helpers
-- are locals INSIDE the fn (it runs at the bridge poll rate; the closures are cheap
-- and this keeps the only new module-global the fn itself, not five of them). gmem
-- map is a byte-exact mirror of EON_StepSeq.jsfx EON_SS_SYNC_* / EON_SS_XFER_*.
-- Module-GLOBAL (no `local`), like refresh_stepseq_pairing, to dodge the 200-local
-- ceiling. The poll loop calls it pcall-guarded so a fault can't stall the bridge.
function eon_courier_tick()
  local C = eon_courier
  if not C then return end
  local SYNC_BASE, SYNC_STRIDE = 26030000, 64
  local F_DMREV, F_ORIGIN = 2, 3   -- echo control: monotonic rev + last-writer tag (1=DM, 2=StepSeq)
  local F_EXPORTREQ, F_EXPORTACK = 6, 7
  local F_DMPUSH, F_LISTLEN, F_SPB, F_SYNCON = 8, 9, 10, 11
  -- Region-pick policy (StepSeq -> courier): F_PATIDX = active pattern index (AUTO maps
  -- it to the Nth region by start time); F_RGNSEL = per-pattern override (0 = Auto, k>=1
  -- = pin to region ordinal k). F_RGNCNT (courier -> StepSeq) publishes the live region
  -- count so the JSFX picker can clamp its cycle.
  local F_PATIDX, F_RGNSEL, F_RGNCNT = 12, 13, 14
  local F_SEED_REQ = 21   -- courier -> StepSeq: empty region on engage -> please export-seed it
  -- P3b-4 (region ops + paging): REN/DEL are counters bumped by the JSFX right-click menu
  -- with the 1-based region ordinal in F_OP_ORD (payload written first, bump last).
  -- F_PAGE = the JSFX pattern-row page base (page*8): colours 22..37 are published as the
  -- window base+1..base+16. F_SELORD = ABSOLUTE selected ordinal (0 = old JSFX/unset ->
  -- fall back to the positional PATIDX map).
  local F_REN_REQ, F_OP_ORD, F_DEL_REQ, F_PAGE, F_SELORD = 17, 18, 19, 40, 41
  local F_COL_REQ = 54  -- change-color request (52 = seq-window heartbeat, NOT free)
  -- P3b-4b region NAMES (courier -> StepSeq): per-slot char band at
  -- RGNNAME_BASE + slot*320 = 8 windowed names x 32 chars 0-terminated (window =
  -- the F_PAGE colour window) + the SELECTED ordinal's name at +256. Key fields
  -- (written LAST, chars first): F_NAMEPAGE = page base+1 the window describes
  -- (0 = never written), F_NAMESEL = ordinal in the SEL sub-band (0 = none).
  local F_NAMEPAGE, F_NAMESEL = 42, 43
  local RGNNAME_BASE, RGNNAME_STRIDE, RGNNAME_SEL = 26022000, 320, 256
  -- P3b-4c SONG strip: the JSFX posts one command per gesture (args in OP/A1/A2
  -- written first, REQ bumped LAST; edge-detected per slot below) and renders the
  -- chain snapshot the bridge publishes into the per-slot SONG band: header
  -- +0 GEN (bumped LAST) +1 LEN +2 PLAYING +3 CURENT +4 LOOP, entries at
  -- +8+e*2 = { ordinal + repeats*256, packed colour }.
  local F_SONG_OP, F_SONG_A1, F_SONG_A2, F_SONG_REQ = 44, 45, 46, 47
  -- P3b-5a length-follow: bound region length in QN (0 = no bound region); the JSFX
  -- adopts listlength = round(region_QN x steps_per_beat) while synced (Match rule).
  local F_RGNQN = 48
  -- "Steppa plays everywhere" step 1 (2026-09-03). StepSeq -> bridge: which patterns hold
  -- their region (3 x 32-bit words, pattern k = bit k%32 of word k/32) and its max grid
  -- length (sizes a region's pattern). Bridge -> StepSeq: the SECTION MAP band, per slot:
  -- +0 GEN (bumped LAST), +1 COUNT, +2+i*3 start QN / +3+i*3 end QN / +4+i*3 pattern.
  local F_LOADED0, F_LOADED1, F_LOADED2, F_MAXLEN = 55, 56, 57, 58
  local F_DMPUSH_ACK = 59   -- StepSeq -> bridge: last DMPUSH seq consumed (priming waits for it)
  local MAP_BASE, MAP_STRIDE, MAP_MAXRGN = 26160200, 512, 64   -- 4 cells/region since step 4 (+ colour)
  local PAT_CAP = 96   -- StepSeq's hard pattern ceiling (npatterns 48, XtraPatts 96)
  -- SONG_ENTRY_MAX caps entries INSIDE one slot's 112-cell record (entries at
  -- +8, two cells each: 8 + 32*2 = 72 <= 112), NOT the number of slots. Slots
  -- are the 16 instance-registry slots. Mirrors EON_SS_SONG_ENTRY_MAX in
  -- EON_StepSeq.jsfx; rename the two together.
  local SONG_BASE, SONG_STRIDE, SONG_ENTRY_MAX = 26028000, 112, 32
  -- P3b-4e: per-entry region names for the song chips (off-page ordinals can't
  -- use the page-windowed RGNNAME band). 16 chars/entry 0-term, chars written
  -- BEFORE the SONG band's GEN bump. Above INCMD's end (..26116383).
  local SONGNAME_BASE, SONGNAME_STRIDE = 26120000, 512
  -- Package 2 (2026-09-03): XFER v2, one claim at 26171536, every plane 16 x 128 cells
  -- (the old 64-step planes overran on 86+/125+ step patterns). Mirrors EON_StepSeq.jsfx.
  local XFER_BASE, XFER_DATA = 26171536, 26171544
  local XFER_OFF    = 26173592   -- note start inside its step, in steps (nudge + groove/swing)
  local XFER_LEN    = 26175640   -- note length in steps (tied runs + the note-length setting)
  local XFER_SUBDIV = 26177688   -- P3b-5b: per-cell packed subdivision = sdn | (mask<<4)
  local XFER_SUBVEL = 26179736   -- P3b-5b: per-sub-hit velocities, 8 slots/cell (0 = use the cell velocity)
  local XFER_CC     = 26196120   -- 2B: CC rows, 4 x 128 steps, 0 = no event, 128 + value
  local XFER_CCMETA = 26196632   -- 2B: per row: cc+1 (0 = no row), channel
  local gr, gw = reaper.gmem_read, reaper.gmem_write

  -- ROBUSTNESS + DIAGNOSTIC: gmem_attach is last-attach-wins, ONE active binding per
  -- Lua state, shared across all dofiled modules (Cockos t=240447 / t=248470 "gmem_attach
  -- with dofile"). Re-assert OUR binding here so the courier's reads/writes can never be
  -- silently redirected by some other module that re-attached a different name; the RETURN
  -- value is the previously-bound name, so a mismatch reveals a steal. No-op if already ours.
  local prevname = reaper.gmem_attach('Swing_Media_Transfer')
  C.hb = (C.hb or 0) + 1
  local function diag(line)
    if not eon_courier_diag_on then return end
    local f = io.open(eon_courier_diagpath or '', 'a')
    if f then f:write(line .. '\n'); f:close() end
  end
  -- Heartbeat ~every 100 ticks (opt-in trace): bound name + any slot showing SYNCON/LISTLEN + xfer header.
  if eon_courier_diag_on and (C.hb % 100) == 1 then
    local parts = {}
    for slot = 0, 15 do
      local b = SYNC_BASE + slot * SYNC_STRIDE
      local on, ll = gr(b + F_SYNCON) or 0, gr(b + F_LISTLEN) or 0
      if on > 0.5 or ll > 0 then
        parts[#parts+1] = string.format("s%d(on=%g ll=%g exreq=%g exack=%g push=%g)",
          slot, on, ll, gr(b + F_EXPORTREQ) or 0, gr(b + F_EXPORTACK) or 0, gr(b + F_DMPUSH) or 0)
      end
    end
    diag(string.format("[%s] HB bound=%s active=[%s] xfer_owner=%g xfer_seq=%g",
      os.date("%H:%M:%S"), tostring(prevname),
      table.concat(parts, " "), gr(XFER_BASE) or -1, gr(XFER_BASE + 1) or -1))
  end

  -- Fallback window when no pattern region exists yet: the bounding time-span of
  -- all DM lane items ("whatever you've painted"). Returns {start,end_} or nil.
  local function lane_items_span()
    local lt = C.lane_tools
    if not (lt and lt.GetLanes) then return nil end
    local t0, t1 = math.huge, -math.huge
    for _, lane in ipairs(lt.GetLanes() or {}) do
      local tr = lane.track
      local n = tr and reaper.CountTrackMediaItems(tr) or 0
      for i = 0, n - 1 do
        local it = reaper.GetTrackMediaItem(tr, i)
        local s = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
        local e = s + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if s < t0 then t0 = s end
        if e > t1 then t1 = e end
      end
    end
    if t1 > t0 then return { start = t0, end_ = t1 } end
    return nil
  end

  -- Region list (sorted by start time), cached once per tick so every slot's pick and
  -- the published region count agree on the same ordering.
  local function region_list()
    local pr = C.pattern_regions
    return (pr and pr.List and pr.List()) or {}
  end

  -- Which DM region `slot` syncs against. EXACT, region=pattern model (no fallback):
  --   * RGNSEL >= 1  -> PIN to that 1-based region ordinal (nil if it doesn't exist).
  --   * RGNSEL == 0  -> AUTO: the StepSeq's active pattern index PATIDX maps to the
  --                     (PATIDX+1)th region by start time; nil if there is no Nth region.
  -- Returns NIL when the pattern has no matching region (rather than falling back to the
  -- first region). The old cursor/first fallback belonged to the retired cursor picker and
  -- caused a real regression: selecting pattern N with no region N imported region 1's notes
  -- (looked like "jumped to pattern 1"). No region -> caller does nothing / leaves the
  -- pattern untouched (the zero-state auto-create, P3b-3b, will mint the missing region).
  local function current_region(slot)
    local list = region_list()
    if #list > 0 then
      local base = SYNC_BASE + (slot or 0) * SYNC_STRIDE
      local sel  = math.floor((gr(base + F_RGNSEL) or 0) + 0.5)
      if sel >= 1 then
        return list[sel]                                     -- pinned ordinal (nil if > count)
      else
        -- P3b-4: prefer the ABSOLUTE selected ordinal (works on any page). 0 = old
        -- JSFX / not yet published -> the original positional PATIDX map.
        local selord = math.floor((gr(base + F_SELORD) or 0) + 0.5)
        if selord >= 1 then return list[selord] end          -- nil past count = no target (exact model)
        local pidx = math.floor((gr(base + F_PATIDX) or 0) + 0.5)
        if pidx >= 0 and pidx < #list then return list[pidx + 1] end  -- AUTO: pattern N -> region N
        return nil                                           -- no region for this pattern -> no sync target
      end
    end
    return lane_items_span()
  end

  -- Deterministic content signature of a collected region blob (pad -> notes). Used by
  -- live DM->SS detection to tell a real DM edit from the bridge's OWN write (echo): we
  -- stamp last_hash after every stage/export, so a tick where the region still hashes to
  -- last_hash is our own change and must NOT bounce back. Rounds q/d so float jitter from
  -- a round-trip can't spoof a change. Empty blob -> "".
  local function blob_sig(blob)
    local lanes = (blob and blob.lanes) or {}
    local parts = {}
    for pad = 1, 16 do
      local ln = lanes[pad]
      if ln and ln.notes and #ln.notes > 0 then
        local ns = {}
        for _, n in ipairs(ln.notes) do
          ns[#ns + 1] = string.format("%d:%.4f:%d:%.4f", pad,
            tonumber(n.q) or 0, math.floor(tonumber(n.v) or 0), tonumber(n.d) or 0)
        end
        table.sort(ns)
        parts[#parts + 1] = table.concat(ns, ",")
      end
    end
    -- 2B (audit 2026-09-03): the controller events are part of the region too -- without
    -- them a CC drawn or deleted in the item, with no note touched, never pulled.
    local cs = {}
    for _, ev in ipairs((blob and blob.cc) or {}) do
      cs[#cs + 1] = string.format("c%d:%d:%.4f:%d", math.floor(ev.cc or 0), math.floor(ev.chan or 0),
        tonumber(ev.q) or 0, math.floor(ev.v or 0))
    end
    if #cs > 0 then table.sort(cs); parts[#parts + 1] = table.concat(cs, ",") end
    return table.concat(parts, "|")
  end

  -- Write a collected blob into the transfer buffer for `slot` (PAD-keyed, note QN ->
  -- step), tag ORIGIN, bump dm_push so the StepSeq imports it, and record last_hash so
  -- this write isn't re-detected as a DM edit. Shared by engage-import + live DM->SS.
  -- P3b-5b: also collapses N evenly-spaced sub-hits inside one step back into a RATCHET
  -- (sdn + mask + per-sub-hit velocities), inverting export's expansion. Notes bucket by
  -- containing step; a bucket of >=2 notes that ALL land on a k/(d+1) sub-grid (smallest
  -- d = 1..7 wins, tolerance RTOL steps, >=2 distinct sub-slots) becomes one ratcheted
  -- cell. Everything else -- singles, swung or humanized notes that fit no sub-grid --
  -- keeps the old round-to-nearest-step keep-the-loudest rule, so groove MIDI is never
  -- misread as a ratchet the user didn't play.
  -- `target` (step 1, optional): pattern index to land in. nil = the editor's pattern
  -- (the pre-step-1 contract, header +5 = 0); k = pattern k (header +5 = k+1), which
  -- leaves the editor's grid and its echo baseline alone. One stage per bridge tick
  -- across all slots: the buffer is single and the StepSeq consumes one push per block.
  --
  -- Package 2 (2026-09-03): every note's real start and length ride along. A note at
  -- q lands in step s = floor(q*spb + RTOL) with OFF = its fraction inside the step
  -- and LEN = its length in steps; the StepSeq turns OFF back into a hand nudge
  -- (minus its own groove, which it re-applies) and LEN into ties. Two or more
  -- notes in one step are a RATCHET only when they sit on the engine's own burst
  -- grid -- the burst starts at the first note and spaces the rest evenly over
  -- what is left of the step -- otherwise the loudest wins (a swung note beside a
  -- straight one is not a ratchet, and a note past half a step is not the next
  -- step: both were misread before).
  local function stage_blob_to_slot(slot, base, blob, listlen, spb, origin, target)
    C.staged_tick = C.hb
    gw(XFER_BASE + 0, slot)
    C.seq[slot] = (C.seq[slot] or 0) + 1
    gw(XFER_BASE + 1, C.seq[slot])
    gw(XFER_BASE + 2, 16)        -- numpads
    gw(XFER_BASE + 3, listlen)   -- numsteps (the StepSeq's grid)
    gw(XFER_BASE + 4, spb)
    gw(XFER_BASE + 5, target and (target + 1) or 0)
    gw(XFER_BASE + 6, 2)         -- layout version: OFF/LEN planes present
    for pad = 0, 15 do
      for s = 0, listlen - 1 do
        local cell = pad * listlen + s
        gw(XFER_DATA + cell, 0)
        gw(XFER_OFF + cell, 0)
        gw(XFER_LEN + cell, 0)
        gw(XFER_SUBDIV + cell, 0)   -- stale subdiv from a prior EXPORT must not leak into an import
        for k = 0, 7 do gw(XFER_SUBVEL + cell * 8 + k, 0) end
      end
    end
    local RTOL = 0.02   -- steps; ~2.5ms at 120bpm 16ths -- above PPQ jitter, below musical offsets
    for pad_index, lane in pairs(blob.lanes or {}) do
      local pad = (tonumber(pad_index) or 0) - 1
      if pad >= 0 and pad < 16 then
        local buckets = {}
        for _, n in ipairs(lane.notes or {}) do
          local v  = math.floor(tonumber(n.v) or 0)
          local sf = (tonumber(n.q) or 0) * spb
          local s  = math.floor(sf + RTOL)   -- boundary guard: a hair-early note belongs to the next step
          if v > 0 and s >= 0 and s < listlen then
            local f = sf - s
            if f < 0 then f = 0 end
            local dl = (tonumber(n.d) or 0) * spb   -- length in steps
            buckets[s] = buckets[s] or {}
            local b = buckets[s]
            b[#b + 1] = { f = f, v = v, sf = sf, d = dl }
          end
        end
        for s, b in pairs(buckets) do
          local cell = pad * listlen + s
          local fit = nil
          if #b >= 2 then
            table.sort(b, function(x, y) return x.f < y.f end)
            local off = b[1].f
            for d = 1, 7 do
              local slots = d + 1
              local span = (1 - off) / slots
              local mask, velos, ok = 0, {}, true
              for _, note in ipairs(b) do
                local k = math.floor((note.f - off) / span + 0.5)
                if k < 0 or k > d or math.abs(note.f - (off + k * span)) > RTOL then ok = false; break end
                if not velos[k] then mask = mask + 2 ^ k end
                if note.v > (velos[k] or 0) then velos[k] = note.v end   -- loudest per sub-slot
              end
              if ok then
                local nslots = 0
                for _ in pairs(velos) do nslots = nslots + 1 end
                if nslots >= 2 then fit = { d = d, mask = mask, velos = velos, off = off } end
                break   -- smallest fitting grid decides; a larger d can't separate the ks further
              end
            end
          end
          if fit then
            local cellvel
            for k = 0, fit.d do
              if fit.velos[k] then
                cellvel = cellvel or fit.velos[k]          -- first active sub-hit = the cell velocity
                gw(XFER_SUBVEL + cell * 8 + k, fit.velos[k])
              end
            end
            gw(XFER_DATA + cell, cellvel or 1)
            gw(XFER_OFF + cell, fit.off)
            gw(XFER_SUBDIV + cell, fit.d + fit.mask * 16)  -- sdn | (mask<<4)
          else
            local best = nil
            for _, note in ipairs(b) do
              if not best or note.v > best.v then best = note end   -- keep the loudest hit per cell
            end
            gw(XFER_DATA + cell, best.v)
            gw(XFER_OFF + cell, best.f)
            gw(XFER_LEN + cell, best.d)
          end
        end
      end
    end
    -- 2B: CC events -> rows (up to 4, one per distinct cc+channel, in first-seen order);
    -- meta = (cc+1, channel), per step 0 = none, 128 + value (the last event in a step
    -- wins). The StepSeq lands each row in the lane whose type and channel match.
    for k = 0, 3 do
      gw(XFER_CCMETA + k * 2, 0); gw(XFER_CCMETA + k * 2 + 1, 0)
      for s = 0, listlen - 1 do gw(XFER_CC + k * 128 + s, 0) end
    end
    local rows, nrows = {}, 0
    for _, ev in ipairs(blob.cc or {}) do
      local key = tostring(ev.cc) .. ':' .. tostring(ev.chan)
      local row = rows[key]
      if row == nil and nrows < 4 then
        row = nrows; nrows = nrows + 1; rows[key] = row
        gw(XFER_CCMETA + row * 2, (ev.cc or 0) + 1); gw(XFER_CCMETA + row * 2 + 1, ev.chan or 0)
      end
      if row ~= nil then
        local s = math.floor((tonumber(ev.q) or 0) * spb + RTOL)
        if s >= 0 and s < listlen then gw(XFER_CC + row * 128 + s, 128 + math.max(0, math.min(127, math.floor(ev.v or 0)))) end
      end
    end
    gw(base + F_ORIGIN, origin or 1)
    gw(base + F_DMPUSH, C.seq[slot])   -- signal: import staged
    if target == nil then C.last_hash[slot] = blob_sig(blob) end   -- the editor's region only
  end

  -- Step 1 "plays everywhere": stage region ORDINAL `ord` into pattern ord-1, so every
  -- section lives in its own pattern. Sized from the region's own length (Match rule)
  -- against the StepSeq's published max grid. EMPTY regions push too: an empty pattern is
  -- the truthful mirror of an empty section (the engage guard in push_region_to_slot
  -- protects only the editor's own grid). Records the ordinal's signature so the
  -- change watcher below only re-pushes what actually changed.
  local function push_region_to_pattern(slot, ord, reg)
    local lt = C.lane_tools
    if not (lt and lt.CollectRegion) then return false end
    if not (reg and reg.start and reg.end_) or ord < 1 or ord > PAT_CAP then return false end
    local base = SYNC_BASE + slot * SYNC_STRIDE
    local spb = gr(base + F_SPB) or 4
    if spb < 1 then spb = 4 end
    local maxlen = math.floor((gr(base + F_MAXLEN) or 0) + 0.5)
    if maxlen < 1 then maxlen = 64 end
    local qn = reaper.TimeMap2_timeToQN(0, reg.end_) - reaper.TimeMap2_timeToQN(0, reg.start)
    local listlen = math.floor(qn * spb + 0.5)
    if listlen < 1 then listlen = 1 elseif listlen > maxlen then listlen = maxlen end
    local blob = lt.CollectRegion(reg.start, reg.end_) or { lanes = {} }
    stage_blob_to_slot(slot, base, blob, listlen, spb, 1, ord - 1)
    C.ord_hash = C.ord_hash or {}
    C.ord_hash[slot] = C.ord_hash[slot] or {}
    C.ord_hash[slot][ord] = blob_sig(blob) .. string.format('|%.4f|%.4f', reg.start, reg.end_)
    diag(string.format("[%s] PRIME slot=%d ord=%d -> pattern %d listlen=%d", os.date("%H:%M:%S"), slot, ord, ord - 1, listlen))
    return true
  end

  -- Stage the current region's notes into the transfer buffer for `slot`, then bump
  -- that slot's dm_push so the StepSeq imports it.
  local function push_region_to_slot(slot)
    local lt = C.lane_tools
    if not (lt and lt.CollectRegion) then return end
    local base = SYNC_BASE + slot * SYNC_STRIDE
    local listlen = math.floor((gr(base + F_LISTLEN) or 0) + 0.5)
    local spb     = gr(base + F_SPB) or 4
    if listlen < 1 then diag(string.format("[%s] PUSH-ABORT slot=%d listlen<1 (%g)", os.date("%H:%M:%S"), slot, listlen)); return end
    if spb < 1 then spb = 4 end
    local reg = current_region(slot)
    if not (reg and reg.start and reg.end_) then diag(string.format("[%s] PUSH-ABORT slot=%d no region/span", os.date("%H:%M:%S"), slot)); return end

    local blob = lt.CollectRegion(reg.start, reg.end_) or { lanes = {} }
    local pc, nc = 0, 0
    for _, ln in pairs(blob.lanes or {}) do pc = pc + 1; nc = nc + #(ln.notes or {}) end
    diag(string.format("[%s] PUSH slot=%d region=[%.3f,%.3f] listlen=%d spb=%g lanes=%d notes=%d",
      os.date("%H:%M:%S"), slot, reg.start, reg.end_, listlen, spb, pc, nc))
    -- Record the engage baseline NOW (even if we skip the empty push below) so live
    -- DM->SS detection has a reference and won't immediately push an empty region in.
    C.last_hash[slot] = blob_sig(blob)

    -- SAFETY GUARD (permanent): never import an EMPTY grid. Import-on-engage memset-clears
    -- the StepSeq's active pattern before filling it, so pushing 0 notes would WIPE whatever
    -- the user had. 0 notes => no source data (wrong/empty region, or an unpainted DM) => skip
    -- the push entirely: don't touch the transfer buffer, don't bump dm_push, so the StepSeq
    -- keeps its pattern. (Once live bidirectional sync exists, a deliberate clear will
    -- propagate through the normal edit path, not via an engage against an empty source.)
    if nc == 0 then
      -- Opt-in raw per-lane scan to show WHY 0 notes (empty vs pitch vs window).
      if eon_courier_diag_on and lt.GetLanes then
        for _, lane in ipairs(lt.GetLanes() or {}) do
          local li, tr = lane.lane_info or {}, lane.track
          local nit = tr and reaper.CountTrackMediaItems(tr) or 0
          local raw, atp, pset, tmin, tmax = 0, 0, {}, math.huge, -math.huge
          for ii = 0, nit - 1 do
            local it = reaper.GetTrackMediaItem(tr, ii); local tk = it and reaper.GetActiveTake(it)
            if tk and reaper.TakeIsMIDI(tk) then
              local _, nn = reaper.MIDI_CountEvts(tk)
              for j = 0, nn - 1 do
                local ok, _, _, ps, _, _, pit = reaper.MIDI_GetNote(tk, j)
                if ok then
                  raw = raw + 1; pset[pit] = (pset[pit] or 0) + 1
                  if pit == li.pad_pitch then atp = atp + 1 end
                  local tt = reaper.MIDI_GetProjTimeFromPPQPos(tk, ps)
                  if tt < tmin then tmin = tt end; if tt > tmax then tmax = tt end
                end
              end
            end
          end
          if nit > 0 or raw > 0 then
            local ps = {}; for k, v in pairs(pset) do ps[#ps + 1] = k .. "x" .. v end
            diag(string.format("   lane pad=%s pitch=%s items=%d raw=%d atpitch=%d span=[%.2f,%.2f] pitches{%s}",
              tostring(li.pad_index), tostring(li.pad_pitch), nit, raw, atp,
              (tmin == math.huge and -1 or tmin), (tmax == -math.huge and -1 or tmax),
              table.concat(ps, ",")))
          end
        end
      end
      diag(string.format("[%s] PUSH-SKIP slot=%d empty source (0 notes) -- StepSeq pattern preserved",
        os.date("%H:%M:%S"), slot))
      return false   -- nothing imported (empty region) -> caller may seed it from the grid
    end

    stage_blob_to_slot(slot, base, blob, listlen, spb, 1)   -- ORIGIN = 1 (DM)
    return true
  end

  -- Export (StepSeq -> DM): the JSFX serialized its active grid into the transfer
  -- buffer and bumped EXPORTREQ. Read it back and write it onto the bound region's
  -- lanes via WriteRegion (which CLEARS the region window then inserts -> StepSeq is
  -- authoritative for the region). pitch comes from each lane's own pad_pitch, so the
  -- blob carries only {q, v, d} per pad. Returns true once the write lands (buffer was
  -- ours), so the caller only acks/advances on success -- a contended buffer retries.
  --
  -- Package 2 (2026-09-03): the grid arrives with its feel. OFF = the note's start inside
  -- its step (nudge + groove/swing, as the engine fires it) and LEN = its length in
  -- steps (tied runs + the note-length setting), so the item plays like the grid. A
  -- ratchet starts at OFF and spaces its sub-hits over the rest of the step, exactly
  -- the engine's burst.
  local function export_slot(slot)
    local lt = C.lane_tools                                   -- (not in scope otherwise)
    if not (lt and lt.WriteRegion) then return false end
    if (math.floor((gr(XFER_BASE) or -1) + 0.5)) ~= slot then return false end  -- buffer not ours yet
    local reg = current_region(slot)
    if not (reg and reg.start and reg.end_) then
      diag(string.format("[%s] EXPORT-ABORT slot=%d no region/span", os.date("%H:%M:%S"), slot))
      return false
    end
    local numpads  = math.floor((gr(XFER_BASE + 2) or 0) + 0.5)
    local numsteps = math.floor((gr(XFER_BASE + 3) or 0) + 0.5)
    local spb      = gr(XFER_BASE + 4) or 4
    if numsteps < 1 then return false end
    if spb < 1 then spb = 4 end
    if numpads > 16 then numpads = 16 end
    local blob, total = { lanes = {} }, 0
    for pad = 0, numpads - 1 do
      local notes = {}
      for s = 0, numsteps - 1 do
        local cell = pad * numsteps + s
        local v = math.floor(gr(XFER_DATA + cell) or 0)
        if v > 0 then
          local off = gr(XFER_OFF + cell) or 0
          if off < 0 then off = 0 elseif off > 0.999 then off = 0.999 end
          local sd  = math.floor(gr(XFER_SUBDIV + cell) or 0)
          local sdn = sd % 16
          if sdn > 0 then
            local bm, slots = math.floor(sd / 16), sdn + 1
            local span = (1 - off) / slots
            for k = 0, sdn do
              if (math.floor(bm / (2 ^ k)) % 2) >= 1 then
                local sv = math.floor(gr(XFER_SUBVEL + cell * 8 + k) or 0)
                if sv < 1 or sv > 127 then sv = v end
                notes[#notes + 1] = { q = (s + off + k * span) / spb, v = sv, d = span / spb }
                total = total + 1
              end
            end
          else
            local len = gr(XFER_LEN + cell) or 0
            if len <= 0 then len = 1 - off end            -- pre-package-2 writer: a full step
            notes[#notes + 1] = { q = (s + off) / spb, v = v, d = len / spb }; total = total + 1
          end
        end
      end
      if #notes > 0 then blob.lanes[pad + 1] = { notes = notes } end   -- pad_index is 1-based
    end
    -- 2B: the CC rows -> events on the home lane. cc_lanes lists every row the StepSeq
    -- wrote (even empty ones) so WriteRegion clears those controllers in the window
    -- before inserting; other controllers in the item are not ours and stay.
    blob.cc, blob.cc_lanes = {}, {}
    for k = 0, 3 do
      local ccn = math.floor(gr(XFER_CCMETA + k * 2) or 0) - 1
      if ccn >= 0 then
        local chan = math.floor(gr(XFER_CCMETA + k * 2 + 1) or 0)
        blob.cc_lanes[#blob.cc_lanes + 1] = { cc = ccn, chan = chan }
        for s = 0, numsteps - 1 do
          local v = math.floor(gr(XFER_CC + k * 128 + s) or 0)
          if v >= 128 then
            if ccn == 119 then
              -- 2C (audit 2026-09-03): the CHANCE controller must sit at the exact time of
              -- the notes it gates -- Swing matches it by sample offset, and a swung or
              -- ratcheted hit sits later in the step, often in another audio block. So:
              -- one CC per distinct note time inside the step (any pad); the step start
              -- alone when the step has no notes.
              local times, any = {}, false
              for _, lane in pairs(blob.lanes) do
                for _, nt in ipairs(lane.notes or {}) do
                  local st = nt.q * spb
                  if st >= s - 0.02 and st < s + 1 - 0.02 then
                    local key = string.format('%.6f', nt.q)
                    if not times[key] then times[key] = nt.q; any = true end
                  end
                end
              end
              if any then
                for _, tq in pairs(times) do blob.cc[#blob.cc + 1] = { q = tq, cc = ccn, chan = chan, v = v - 128 } end
              else
                blob.cc[#blob.cc + 1] = { q = s / spb, cc = ccn, chan = chan, v = v - 128 }
              end
            else
              blob.cc[#blob.cc + 1] = { q = s / spb, cc = ccn, chan = chan, v = v - 128 }
            end
          end
        end
      end
    end
    local written = lt.WriteRegion(reg.start, reg.end_, blob) or 0
    -- Record the post-write region signature so live DM->SS detection treats this as
    -- OUR change (echo suppression) and won't bounce it straight back to the StepSeq.
    -- Re-collect (not blob_sig(blob)) so the recorded hash matches exactly what the
    -- detector will compute next tick from the actual region MIDI.
    C.last_hash[slot] = blob_sig(lt.CollectRegion(reg.start, reg.end_) or { lanes = {} })
    diag(string.format("[%s] EXPORT slot=%d region=[%.3f,%.3f] numsteps=%d spb=%g notes=%d written=%d",
      os.date("%H:%M:%S"), slot, reg.start, reg.end_, numsteps, spb, total, written))
    return true
  end

  -- Live DM -> StepSeq (P3b-2): the bound region's MIDI changed and it was NOT our own
  -- write -> push the new grid into the StepSeq. Gated upstream by GetProjectStateChangeCount
  -- (cheap coarse "did anything change") so this only collects+hashes on a real project edit.
  -- Allows an EMPTY result (a deliberate DM clear, or an undo that empties the region, should
  -- propagate -- unlike engage-import, which guards empty to avoid wiping on a wrong region).
  local function live_check_slot(slot)
    local lt = C.lane_tools
    if not (lt and lt.CollectRegion) then return end
    local base = SYNC_BASE + slot * SYNC_STRIDE
    local listlen = math.floor((gr(base + F_LISTLEN) or 0) + 0.5)
    local spb     = gr(base + F_SPB) or 4
    if listlen < 1 then return end
    if spb < 1 then spb = 4 end
    local reg = current_region(slot)
    if not (reg and reg.start and reg.end_) then return end
    local blob = lt.CollectRegion(reg.start, reg.end_) or { lanes = {} }
    local sig = blob_sig(blob)
    -- Never PUSH on the first observation of a slot (e.g. if engage-import was skipped):
    -- just record the baseline. Only a subsequent CHANGE propagates -- this is what stops
    -- a stray empty-region push from wiping the StepSeq.
    if C.last_hash[slot] == nil then C.last_hash[slot] = sig; return end
    if sig == C.last_hash[slot] then return end   -- unchanged, or our own export -> no echo
    diag(string.format("[%s] LIVE-PULL slot=%d region=[%.3f,%.3f] (DM edit detected)",
      os.date("%H:%M:%S"), slot, reg.start, reg.end_))
    stage_blob_to_slot(slot, base, blob, listlen, spb, 1)   -- ORIGIN = 1 (DM); sets last_hash
  end

  C.last_hash = C.last_hash or {}
  C.last_listlen = C.last_listlen or {}
  C.last_spb = C.last_spb or {}
  C.last_patidx = C.last_patidx or {}
  -- Cheap coarse gate (research-recommended): only run live DM->SS detection when the
  -- project actually changed since last tick -- avoids collecting+hashing every region
  -- every tick. Undo/redo bumps this too, so an undo that reverts a region propagates.
  local pcc = reaper.GetProjectStateChangeCount(0)
  local proj_changed = (pcc ~= C.last_pcc)
  C.last_pcc = pcc
  -- Sync playback ownership: first tick / project switch -> 2 s grace before the
  -- mute pass may run, so pairing (_seq_ms_owned) resolves first and we never
  -- release-then-remute on startup. State lives on C, not in locals: this
  -- function is already deep in locals.
  C.mute_now = reaper.time_precise()
  if reaper.EnumProjects(-1) ~= C.mute_proj then
    C.mute_proj = reaper.EnumProjects(-1)
    C.mute_sig = {}
    C.mute_owned = {}
    C.mute_grace_until = C.mute_now + 2.0
    C.mute_dirty = true
    -- Step 1 state is per PROJECT too (audit 2026-09-03): a new tab whose regions hash
    -- the same as the last project's would otherwise never be re-primed, and the map
    -- signature would never republish -- stale patterns in the StepSeq.
    C.ord_hash = {}
    C.map_sig = {}
  end

  local rgncnt = #region_list()
  -- P3b-4c: drive the song engine (cheap no-op when idle) and snapshot the
  -- project-global chain ONCE per tick; the per-slot publisher below writes it
  -- to any SYNCON slot whose copy is stale (sig includes playing/curent/loop, so
  -- the playing-entry highlight advances without a chain edit).
  local song_snap = nil
  if C.pattern_song then
    pcall(C.pattern_song.SongTick)
    local okl, list = pcall(C.pattern_song.SongList)
    if okl and type(list) == 'table' then
      local rl = region_list()
      local ord_of = {}
      for i = 1, #rl do ord_of[rl[i].idx] = i end
      local entries, sigp = {}, {}
      for i = 1, math.min(#list, SONG_ENTRY_MAX) do
        local e = list[i]
        local ord = ord_of[e.idx] or 0
        local rep = math.max(1, math.min(64, math.floor(e.repeats or 1)))
        local col = 0
        if e.region and e.region.color then
          local cr, cg, cb = reaper.ColorFromNative(math.floor(e.region.color) % 16777216)
          col = cr * 65536 + cg * 256 + cb
        end
        local nm = (e.region and e.region.name) or ''
        entries[i] = { ord + rep * 256, col, nm }
        sigp[#sigp + 1] = ord .. 'x' .. rep .. ':' .. col .. ':' .. nm
      end
      -- PLAYING publishes the TRANSPORT state (any source), not just song mode —
      -- the strip's PLAY cell mirrors the DAW visually. Chip rings still key on
      -- CURENT, which is only nonzero while the song engine drives the chain.
      -- LOOP is DAW-synced too: GetLoop reads the transport REPEAT (parked
      -- intent while a song plays).
      local playing = ((reaper.GetPlayState() & 1) == 1) and 1 or 0
      local curent  = C.pattern_song.CurrentEntryPos() or 0
      local lp      = C.pattern_song.GetLoop() and 1 or 0
      song_snap = { entries = entries, len = #entries, playing = playing,
                    curent = curent, loop = lp,
                    sig = table.concat(sigp, '|') .. '#' .. playing .. '#' .. curent .. '#' .. lp }
    end
  end
  for slot = 0, 15 do
    local b = SYNC_BASE + slot * SYNC_STRIDE
    local on = (gr(b + F_SYNCON) or 0) > 0.5
    -- Sync playback ownership: "truly synced" = SYNCON AND a StepSeq is actually
    -- paired to this slot (SYNCON goes stale when a StepSeq leaves a slot). Any
    -- flip re-runs the mute pass; the set is what the pass mutes for.
    C.mute_owned = C.mute_owned or {}
    if C.mute_owned[slot] ~= (on and _seq_ms_owned ~= nil and _seq_ms_owned[slot] == true) then
      C.mute_owned[slot] = (on and _seq_ms_owned ~= nil and _seq_ms_owned[slot] == true)
      C.mute_dirty = true
    end
    -- Publish the live region count so the StepSeq's Region picker can clamp its cycle,
    -- and the region COLOURS (fields 22..37, packed r*65536+g*256+b) so the pattern
    -- buttons match the DM region colours 1:1. P3b-4: the colours are a PAGE WINDOW —
    -- the JSFX publishes its page base in F_PAGE and field 22+i = ordinal base+1+i.
    -- Slots past the list are ZEROED (also fixes stale colours after a region delete).
    if on then
      gw(b + F_RGNCNT, rgncnt)
      -- P3b-5a length-follow: publish the bound region's length in quarter notes so the
      -- grid adopts region_QN x steps_per_beat (Match rule -- the region's time span is
      -- authoritative; dragging a region edge regrows the grid). Real regions only (the
      -- lane-items-span fallback has no .idx and must not drive the grid length).
      local breg, bqn = current_region(slot), 0
      if breg and breg.idx and breg.start and breg.end_ then
        bqn = reaper.TimeMap2_timeToQN(0, breg.end_) - reaper.TimeMap2_timeToQN(0, breg.start)
        if bqn < 0 then bqn = 0 end
      end
      gw(b + F_RGNQN, bqn)
      -- Sync playback ownership: the bound window moved (region switched,
      -- resized, deleted, or the painted-span fallback grew) -> re-run the pass.
      C.mute_sig = C.mute_sig or {}
      if C.mute_sig[slot] ~= (breg and (tostring(breg.idx or 'span') .. '|' .. tostring(breg.start) .. '|' .. tostring(breg.end_)) or '') then
        C.mute_sig[slot] = (breg and (tostring(breg.idx or 'span') .. '|' .. tostring(breg.start) .. '|' .. tostring(breg.end_)) or '')
        C.mute_dirty = true
      end
      local rl = region_list()
      local pbase = math.floor((gr(b + F_PAGE) or 0) + 0.5)
      if pbase < 0 or pbase >= rgncnt then pbase = 0 end
      for i = 1, 16 do
        local reg = rl[pbase + i]
        local packed = 0
        if reg then
          local cr, cg, cb = reaper.ColorFromNative(math.floor(reg.color or 0) % 16777216)
          packed = cr * 65536 + cg * 256 + cb
        end
        gw(b + 22 + (i - 1), packed)
      end
      -- P3b-4b: region NAMES beside the colours — 8 windowed (same pbase window)
      -- + the SELECTED ordinal's name in the +256 sub-band (the selection can sit
      -- on a page other than the visible window). Chars first, key fields LAST so
      -- the JSFX never reads a half-written window; sig-cached so the ~300 gmem
      -- writes only happen when a name / page / selection actually changed (a
      -- rename flows through automatically: region_list() re-reads names per tick).
      do
        local selord = math.floor((gr(b + F_SELORD) or 0) + 0.5)
        if selord < 1 then selord = math.floor((gr(b + F_PATIDX) or 0) + 0.5) + 1 end
        local selreg = rl[selord]
        local names = {}
        for i = 1, 8 do names[i] = (rl[pbase + i] and rl[pbase + i].name) or '' end
        local selname = (selreg and selreg.name) or ''
        local sig = table.concat(names, '\1') .. '|' .. pbase .. '|' .. selord .. '|' .. selname
        C.name_sig = C.name_sig or {}
        if C.name_sig[slot] ~= sig then
          C.name_sig[slot] = sig
          local nb = RGNNAME_BASE + slot * RGNNAME_STRIDE
          for i = 1, 8 do
            local off, nm = nb + (i - 1) * 32, names[i]
            local n = math.min(#nm, 31)
            for k = 1, n do gw(off + k - 1, string.byte(nm, k)) end
            gw(off + n, 0)
          end
          local off = nb + RGNNAME_SEL
          local n = math.min(#selname, 31)
          for k = 1, n do gw(off + k - 1, string.byte(selname, k)) end
          gw(off + n, 0)
          gw(b + F_NAMEPAGE, pbase + 1)
          gw(b + F_NAMESEL, selreg and selord or 0)
        end
      end
      -- P3b-4c: publish the song-chain snapshot (entries first, GEN bumped LAST
      -- so the JSFX never renders a half-written chain).
      if song_snap then
        C.song_sig = C.song_sig or {}
        if C.song_sig[slot] ~= song_snap.sig then
          C.song_sig[slot] = song_snap.sig
          local sb = SONG_BASE + slot * SONG_STRIDE
          local nb = SONGNAME_BASE + slot * SONGNAME_STRIDE
          for i = 1, SONG_ENTRY_MAX do
            local e = song_snap.entries[i]
            gw(sb + 8 + (i - 1) * 2,     e and e[1] or 0)
            gw(sb + 8 + (i - 1) * 2 + 1, e and e[2] or 0)
            local nm = (e and e[3]) or ''
            local noff, n = nb + (i - 1) * 16, math.min(#nm, 15)
            for k = 1, n do gw(noff + k - 1, string.byte(nm, k)) end
            gw(noff + n, 0)
          end
          gw(sb + 1, song_snap.len)
          gw(sb + 2, song_snap.playing)
          gw(sb + 3, song_snap.curent)
          gw(sb + 4, song_snap.loop)
          gw(sb, (gr(sb) or 0) + 1)
        end
      end
    end
    local cur_listlen = math.floor((gr(b + F_LISTLEN) or 0) + 0.5)
    local cur_spb     = gr(b + F_SPB) or 4
    local cur_patidx  = math.floor((gr(b + F_PATIDX) or 0) + 0.5)
    -- Is the StepSeq exporting this tick? A preset/project load forces an export (StepSeq wins);
    -- when so, we must NOT re-import on the same tick or we'd clobber that export with the old region.
    local exreq       = math.floor((gr(b + F_EXPORTREQ) or 0) + 0.5)
    local exporting   = exreq > (C.exp[slot] or 0)
    if on and not C.prev[slot] then
      C.mute_dirty = true   -- sync playback ownership: (re)claim the project copy
      -- rising edge = "Sync Mode just turned on". Region has notes -> import it. Region EMPTY
      -- -> ask the StepSeq to export-seed it from its current grid (user: build a preset, then
      -- engage sync -> push to DM). SEED_REQ is a bump the StepSeq edge-detects.
      if not push_region_to_slot(slot) then
        gw(b + F_SEED_REQ, (gr(b + F_SEED_REQ) or 0) + 1)
      end
    elseif on then
      -- P3b-4: a click on another PAGE keeps the same on-page pattern index (0..7) but
      -- changes the absolute ordinal — so the re-import trigger watches SELORD too.
      local cur_selord = math.floor((gr(b + F_SELORD) or 0) + 0.5)
      C.last_selord = C.last_selord or {}
      local patidx_chg = (C.last_patidx[slot] ~= nil and cur_patidx ~= C.last_patidx[slot])
                      or (C.last_selord[slot] ~= nil and cur_selord ~= C.last_selord[slot])
      local res_chg    = C.last_listlen[slot] ~= nil
                         and (cur_listlen ~= C.last_listlen[slot] or cur_spb ~= C.last_spb[slot])
      if patidx_chg and reaper.GetExtState("EON_StepSeq", "autozoom_select") ~= "0" then
        -- StepSeq PATTERN SELECTED (active pattern index changed) -> navigate the arrange to
        -- that region: JumpTo zooms/scrolls + sets it current, and the loop points highlight it
        -- (user choice 2026-06-23; optional since 2026-07-03 via the SETTINGS "Zoom on select"
        -- toggle -> ExtState EON_StepSeq/autozoom_select, "0" = off, unset = on).
        -- Then the push below loads the region into the now-active pattern.
        local pr, reg = C.pattern_regions, current_region(slot)
        if pr and reg and reg.idx and pr.JumpTo then pr.JumpTo(reg.idx); eon_scroll_kit_into_view(C, slot) end
        if reg and reg.start and reg.end_ then
          reaper.GetSet_LoopTimeRange(true, true, reg.start, reg.end_, false)   -- loop points = highlight
        end
      end
      -- Re-import on a pattern switch OR a resolution/length change (triplet toggle / manual
      -- Steps-per-Beat / Seq Length edit) so the grid re-lands from the now-target region --
      -- UNLESS the StepSeq is exporting (preset load: its content wins, don't clobber it).
      if (patidx_chg or res_chg) and not exporting then push_region_to_slot(slot) end
    end
    if on then
      C.last_listlen[slot] = cur_listlen
      C.last_spb[slot]     = cur_spb
      C.last_patidx[slot]  = cur_patidx
      C.last_selord = C.last_selord or {}
      C.last_selord[slot]  = math.floor((gr(b + F_SELORD) or 0) + 0.5)
      -- Step 1 "plays everywhere": (a) publish the SECTION MAP (regions in time order,
      -- pattern = ordinal-1, -1 past the cap) whenever it changes, GEN bumped LAST;
      -- (b) prime every region into its own pattern, one per tick, and on a project
      -- change re-push any off-screen region whose notes or edges changed. The editor's
      -- own region keeps the existing engage / re-import / live paths; the buffer is
      -- single, so nothing here stages on a tick that already staged or while the
      -- StepSeq is exporting through it.
      local rl = region_list()
      local msig = {}
      for i = 1, #rl do msig[#msig + 1] = string.format('%d:%.4f:%.4f:%d:%s', rl[i].idx or 0, rl[i].start or 0, rl[i].end_ or 0, math.floor(rl[i].color or 0), tostring(rl[i].name or '')) end   -- colour + name too: a recolour / rename repaints the timeline face
      msig = table.concat(msig, ',')
      C.map_sig = C.map_sig or {}
      if C.map_sig[slot] ~= msig then
        C.map_sig[slot] = msig
        local mb = MAP_BASE + slot * MAP_STRIDE
        local n = math.min(#rl, MAP_MAXRGN)
        for i = 1, n do
          gw(mb + 2 + (i - 1) * 4, reaper.TimeMap2_timeToQN(0, rl[i].start))
          gw(mb + 3 + (i - 1) * 4, reaper.TimeMap2_timeToQN(0, rl[i].end_))
          gw(mb + 4 + (i - 1) * 4, (i <= PAT_CAP) and (i - 1) or -1)
          -- step 4: the region colour, packed like the RGNCOL window (r*65536+g*256+b),
          -- so the StepSeq's timeline face can paint every section, not only the page
          local packed = 0
          if rl[i].color and rl[i].color ~= 0 then
            local cr, cg, cb = reaper.ColorFromNative(math.floor(rl[i].color) % 16777216)
            packed = cr * 65536 + cg * 256 + cb
          end
          gw(mb + 5 + (i - 1) * 4, packed)
          -- strip polish (2026-09-03): the region NAME for the timeline face. 12 chars
          -- max, 4 seven-bit chars per cell in 3 cells at +260 + (i-1)*3 (28 bits, so
          -- the StepSeq's 32-bit integer ops read it back exactly); non-ASCII -> '?'.
          local nm = tostring(rl[i].name or '')
          for k = 0, 2 do
            local v = 0
            for c = 1, 4 do
              local ch = string.byte(nm, k * 4 + c) or 0
              if ch >= 128 then ch = 63 end
              v = v + ch * (128 ^ (c - 1))
            end
            gw(mb + 260 + (i - 1) * 3 + k, v)
          end
        end
        gw(mb + 1, n)
        gw(mb, (gr(mb) or 0) + 1)   -- GEN last
      end
      C.ord_hash = C.ord_hash or {}
      C.ord_hash[slot] = C.ord_hash[slot] or {}
      local cur_selord = math.floor((gr(b + F_SELORD) or 0) + 0.5)
      if cur_selord < 1 then cur_selord = cur_patidx + 1 end
      -- Wait for the StepSeq's ack of the previous push: the buffer is single and it
      -- consumes one push per audio block, so a second stage before the ack would
      -- overwrite the first (pattern 1 never primed in the first rig run).
      local acked = math.floor((gr(b + F_DMPUSH_ACK) or 0) + 0.5) == (C.seq[slot] or 0)
      -- The off-screen change scan collects EVERY region's notes; on a busy edit it
      -- fired every tick. At most four scans a second per slot (audit 2026-09-03).
      C.scan_t = C.scan_t or {}
      local do_scan = proj_changed and (C.mute_now - (C.scan_t[slot] or 0)) >= 0.25
      if do_scan then C.scan_t[slot] = C.mute_now end
      if C.staged_tick ~= C.hb and not exporting and acked then
        local pushed = false
        for ord = 1, math.min(#rl, PAT_CAP) do
          if not pushed and ord ~= cur_selord then
            local reg = rl[ord]
            local h = C.ord_hash[slot][ord]
            if h == nil then
              pushed = push_region_to_pattern(slot, ord, reg)
            elseif do_scan then
              local blob = C.lane_tools.CollectRegion(reg.start, reg.end_) or { lanes = {} }
              local sig = blob_sig(blob) .. string.format('|%.4f|%.4f', reg.start, reg.end_)
              if sig ~= h then pushed = push_region_to_pattern(slot, ord, reg) end
            end
          end
        end
      end
    end
    if C.prev[slot] ~= on then
      C.mute_dirty = true   -- sync playback ownership: falling edge releases
      if not on and C.ord_hash then C.ord_hash[slot] = nil end   -- step 1: re-prime every pattern on re-engage
      if not on and C.map_sig then C.map_sig[slot] = nil end     -- and republish the map
    end
    C.prev[slot] = on
    -- Export edge: act once per new EXPORTREQ; ack + advance only when the write lands.
    if exporting and export_slot(slot) then
      C.exp[slot] = exreq
      gw(b + F_EXPORTACK, exreq)
    end
    -- New-region request: the JSFX "+" button bumps field 16. Create a region (append) --
    -- pattern_regions.New(nil) set_current's it, so the DM->SS monitor below then switches
    -- the StepSeq to the new pattern. Baseline on first observation (ignore stale gmem).
    local newreq = math.floor((gr(b + 16) or 0) + 0.5)
    C.new_last = C.new_last or {}
    if C.new_last[slot] == nil then
      C.new_last[slot] = newreq
    elseif newreq ~= C.new_last[slot] then
      C.new_last[slot] = newreq
      if newreq > 0 and on and C.pattern_regions and C.pattern_regions.New then
        local nidx = C.pattern_regions.New(nil)
        -- Name it NOW (user 2026-07-03): a freshly created pattern immediately
        -- asks for its name — cancel keeps the default "Pattern N" (which the
        -- chips render as a plain number). Same modal precedent as the
        -- right-click Rename below; the DM pattern-bar "+" prompts on its own.
        if nidx and C.pattern_regions.Rename then
          local nreg = C.pattern_regions.GetByIndex and C.pattern_regions.GetByIndex(nidx)
          local defname = (nreg and nreg.name) or ''
          -- Styled prompt when ReaImGui is present (ASYNC -- the rename runs in
          -- on_ok); native GetUserInputs otherwise. Cancel keeps the default.
          local shown = eon_dlg and eon_dlg.available() and eon_dlg.open({
            title = 'Name new pattern', ok_label = 'Name',
            fields = { { key = 'name', label = 'Name', value = defname } },
            on_ok = function(v)
              if v.name and v.name ~= '' then
                -- idx-reuse guard (see the rename handler below)
                local cur = C.pattern_regions.GetByIndex and C.pattern_regions.GetByIndex(nidx)
                if cur and cur.name == defname then C.pattern_regions.Rename(nidx, v.name) end
              end
            end,
          })
          if not shown then
            local okd, nm = reaper.GetUserInputs('Name new pattern', 1,
              'Name:,extrawidth=220', defname)
            if okd and nm and nm ~= '' then C.pattern_regions.Rename(nidx, nm) end
          end
        end
      end
    end
    -- P3b-4: Rename / Delete region (StepSeq right-click menu). Payload = 1-based
    -- ordinal in F_OP_ORD (written before the counter bump). Both open a modal — the
    -- courier is pcall'd and the bridge tolerates a blocked tick (same precedent as
    -- the Rename Pad GetUserInputs dialog). Baseline on first observation.
    -- Tab 1 exists even with ZERO regions (the StepSeq floors its tab count at 1),
    -- so Rename/Change-color on a fresh project used to silently no-op. For that
    -- one tab, seed the first region via the same New() path the '+' uses, then
    -- run the op on it. Delete stays a no-op (the JSFX greys the row instead).
    local function rgn_for_op(ord)
      local rl = region_list()
      local reg = rl[ord]
      if not reg and ord == 1 and #rl == 0
         and C.pattern_regions and C.pattern_regions.New then
        if C.pattern_regions.New(nil) then reg = region_list()[1] end
      end
      return reg
    end
    local renreq = math.floor((gr(b + F_REN_REQ) or 0) + 0.5)
    C.ren_last = C.ren_last or {}
    if C.ren_last[slot] == nil then
      C.ren_last[slot] = renreq
    elseif renreq ~= C.ren_last[slot] then
      C.ren_last[slot] = renreq
      if renreq > 0 and on and C.pattern_regions and C.pattern_regions.Rename then
        local ord = math.floor((gr(b + F_OP_ORD) or 0) + 0.5)
        local reg = rgn_for_op(ord)
        if reg then
          local shown = eon_dlg and eon_dlg.available() and eon_dlg.open({
            title = 'Rename pattern ' .. ord, ok_label = 'Rename',
            fields = { { key = 'name', label = 'Name', value = reg.name or '' } },
            on_ok = function(v)
              -- idx can be REUSED while the dialog sits open (delete the region
              -- in the ruler + add another -> REAPER hands out the lowest free
              -- number). Act only if idx still holds the region we opened on.
              local cur = C.pattern_regions.GetByIndex(reg.idx)
              if cur and cur.name == reg.name then
                C.pattern_regions.Rename(reg.idx, v.name or '')
              end
            end,
          })
          if not shown then
            local okd, nm = reaper.GetUserInputs('Rename pattern ' .. ord, 1,
              'Name:,extrawidth=220', reg.name or '')
            if okd then C.pattern_regions.Rename(reg.idx, nm) end
          end
        end
      end
    end
    local delreq = math.floor((gr(b + F_DEL_REQ) or 0) + 0.5)
    C.del_last = C.del_last or {}
    if C.del_last[slot] == nil then
      C.del_last[slot] = delreq
    elseif delreq ~= C.del_last[slot] then
      C.del_last[slot] = delreq
      if delreq > 0 and on and C.pattern_regions and C.pattern_regions.Delete then
        local ord = math.floor((gr(b + F_OP_ORD) or 0) + 0.5)
        local reg = region_list()[ord]
        if reg then
          local label = (reg.name and reg.name ~= '') and ('"' .. reg.name .. '"') or ('#' .. ord)
          local msg = 'Delete pattern ' .. label .. ' and its region?'
          local function do_delete()
            -- Same idx-reuse guard as Rename: never delete a region that is no
            -- longer the one the confirm was opened on (destructive op).
            local cur = C.pattern_regions.GetByIndex(reg.idx)
            if cur and cur.name == reg.name then C.pattern_regions.Delete(reg.idx) end
          end
          local shown = eon_dlg and eon_dlg.available() and eon_dlg.confirm and eon_dlg.confirm({
            title = 'Delete pattern', ok_label = 'Delete',
            message = msg, on_ok = do_delete,
          })
          if not shown then
            if reaper.ShowMessageBox(msg, 'EON StepSeq', 4) == 6 then do_delete() end
          end
        end
      end
    end
    -- Change color (StepSeq right-click menu): ordinal in F_OP_ORD like REN/DEL.
    -- GR_SelectColor is the native modal picker — same blocked-tick precedent as
    -- the Rename dialog. Cancel returns retval 0 -> no write. The new colour
    -- reaches the StepSeq tabs on its own: the 22..37 colour window republishes
    -- from live region colours every tick.
    local colreq = math.floor((gr(b + F_COL_REQ) or 0) + 0.5)
    C.col_last = C.col_last or {}
    if C.col_last[slot] == nil then
      C.col_last[slot] = colreq
    elseif colreq ~= C.col_last[slot] then
      C.col_last[slot] = colreq
      if colreq > 0 and on and C.pattern_regions and C.pattern_regions.SetColor then
        local ord = math.floor((gr(b + F_OP_ORD) or 0) + 0.5)
        local reg = rgn_for_op(ord)
        if reg then
          local okc, ncol = reaper.GR_SelectColor(nil)
          if okc and okc ~= 0 and ncol then
            C.pattern_regions.SetColor(reg.idx, ncol)
          end
        end
      end
    end
    -- P3b-4c: song-strip commands (field 47 edge-detect; args written first).
    -- The strip renders bridge-published state only, so after any executed
    -- command we just invalidate every slot's song sig -> republish next tick.
    local songreq = math.floor((gr(b + F_SONG_REQ) or 0) + 0.5)
    C.song_last = C.song_last or {}
    if C.song_last[slot] == nil then
      C.song_last[slot] = songreq
    elseif songreq ~= C.song_last[slot] then
      C.song_last[slot] = songreq
      local psg = C.pattern_song
      if songreq > 0 and on and psg then
        local op = math.floor((gr(b + F_SONG_OP) or 0) + 0.5)
        local a1 = math.floor((gr(b + F_SONG_A1) or 0) + 0.5)
        local a2 = math.floor((gr(b + F_SONG_A2) or 0) + 0.5)
        if op == 1 then
          local reg = region_list()[a1]
          if reg then psg.SongAppend(reg.idx) end
        elseif op == 2 then psg.SongRemoveAt(a1)
        elseif op == 3 then psg.SongReorder(a1, a2)
        elseif op == 4 then psg.SongSetRepeats(a1, a2)
        elseif op == 5 then
          -- empty chain -> plain transport play (the cell is a DAW play button
          -- that PREFERS song mode when there's a chain to drive)
          if not psg.SongPlay() then reaper.OnPlayButton() end
        elseif op == 6 then
          -- stop whatever is playing: song mode via the engine (restores
          -- smoothseek/repeat), plain transport otherwise
          if psg.IsPlaying() then psg.SongStop() else reaper.OnStopButton() end
        elseif op == 7 then psg.ToggleLoop()
        elseif op == 8 then psg.SongClear()
        elseif op == 10 then
          -- ZOOM: fit the arrange to the whole song (all pattern regions) —
          -- same helper as the DM's fit-song button
          if C.pattern_regions and C.pattern_regions.ZoomToSong then
            C.pattern_regions.ZoomToSong()
            eon_scroll_kit_into_view(C, slot)   -- and the kit tracks into view (2026-09-03)
          end
        elseif op == 11 then
          -- ZOOM_PATTERN: frame the arrange on one pattern's region. A1 = the
          -- pattern's ordinal in timeline order (same resolution as APPEND /
          -- rename / delete above).
          local reg = region_list()[a1]
          if reg and C.pattern_regions and C.pattern_regions.ZoomToRegion then
            C.pattern_regions.ZoomToRegion(reg.idx)
            eon_scroll_kit_into_view(C, slot)   -- and the kit tracks into view (2026-09-03)
          end
        elseif op == 12 then
          -- LOOP_ALL: loop selection across EVERY pattern region + repeat ON
          -- (Steppa's "Loop / All patterns" row + the full-UI L cell; zoom
          -- stays op 10 so the two stay independently composable).
          if C.pattern_regions and C.pattern_regions.LoopAll then
            C.pattern_regions.LoopAll()
          end
        elseif op == 13 then
          -- LOCATE (step 4): put the transport at region A1's start and play if it
          -- is stopped. The StepSeq's timeline face double-click; its engine follows
          -- the playhead, so this is "play from this section".
          local reg = region_list()[a1]
          if reg and reg.start then
            reaper.SetEditCurPos(reg.start, true, true)
            if (reaper.GetPlayState() & 1) == 0 then reaper.OnPlayButton() end
          end
        elseif op == 14 then
          -- APPEND_REP (strip polish): region A1 onto the chain with A2 repeats -- the
          -- timeline block menu's "Add to chain x2/x4". One op, so it can't half-land.
          local reg = region_list()[a1]
          if reg then
            psg.SongAppend(reg.idx)
            local list = psg.SongList()
            if #list > 0 and a2 > 1 then psg.SongSetRepeats(#list, a2) end
          end
        elseif op == 15 then
          -- LOOP_SECTION (strip polish): time selection = region A1 and repeat ON, so the
          -- section under edit loops while the engine follows the playhead through it.
          local reg = region_list()[a1]
          if reg and reg.start and reg.end_ then
            reaper.GetSet_LoopTimeRange2(0, true, true, reg.start, reg.end_, false)
            if reaper.GetSetRepeatEx(0, -1) == 0 then reaper.GetSetRepeatEx(0, 1) end
          end
        elseif op == 9 and C.pattern_regions and C.pattern_regions.Stamp then
          -- COMMIT: stamp the flattened chain (entry x repeats) to the timeline
          -- from the edit cursor, one undo point for the whole write.
          local list = psg.SongList()
          if #list > 0 then
            reaper.Undo_BeginBlock()
            local t = reaper.GetCursorPosition()
            for _, e in ipairs(list) do
              local dur = (e.region.end_ or 0) - (e.region.start or 0)
              if dur > 0 then
                for _ = 1, math.max(1, e.repeats or 1) do
                  C.pattern_regions.Stamp(e.idx, t)
                  t = t + dur
                end
              end
            end
            reaper.Undo_EndBlock('EON StepSeq: commit song to timeline', -1)
          end
        end
        C.song_sig = {}   -- chain/engine state changed -> republish to all slots
      end
    end
    -- Live DM -> StepSeq: after engage/export above (so our own writes are baselined),
    -- detect a real DM-side edit and push it back. Only on a project change.
    if on and proj_changed then live_check_slot(slot) end
    -- SETTINGS option mirror (machine-global, sync-band fields 49-51): the
    -- StepSeq panel's "Zoom on select" / "Sync on by default" toggles write
    -- fields 49/50 + bump 51; we persist the bump to ExtState, and otherwise
    -- republish the canonical ExtState values every tick so every instance's
    -- panel shows the same machine-wide state ("0" = off, unset = on).
    do
      local optreq = math.floor((gr(b + 51) or 0) + 0.5)
      C.opt_last = C.opt_last or {}
      if C.opt_last[slot] == nil then
        C.opt_last[slot] = optreq
      elseif optreq ~= C.opt_last[slot] then
        C.opt_last[slot] = optreq
        reaper.SetExtState("EON_StepSeq", "autozoom_select",
          (gr(b + 49) or 0) > 0.5 and "1" or "0", true)
        reaper.SetExtState("EON_StepSeq", "sync_on_open",
          (gr(b + 50) or 0) > 0.5 and "1" or "0", true)
        reaper.SetExtState("EON_StepSeq", "auto_adapt",
          (gr(b + 53) or 0) > 0.5 and "1" or "0", true)
      end
      gw(b + 49, reaper.GetExtState("EON_StepSeq", "autozoom_select") ~= "0" and 1 or 0)
      gw(b + 50, reaper.GetExtState("EON_StepSeq", "sync_on_open") ~= "0" and 1 or 0)
      -- ⚠️ auto_adapt is INVERTED vs the two above: "1" = on, unset/other = OFF.
      -- (③ ADAPT auto-apply defaults off; field 53 — 52 is the seq-open heartbeat.)
      gw(b + 53, reaper.GetExtState("EON_StepSeq", "auto_adapt") == "1" and 1 or 0)
    end
  end

  -- Sync playback ownership: mute the project copy of every truly synced
  -- StepSeq's grid (see eon_sync_mute_pass). Runs on any edge (dirty), on a
  -- project change at most every 0.25 s, and as a sweep every 1 s while a slot is
  -- synced / every 2 s when none is -- the sweep is what releases orphans left by
  -- a dead bridge, by sync switched off while the bridge was down, or by a stale
  -- SYNCON with no StepSeq behind it. Never before pairing has resolved.
  if _seq_ms_owned ~= nil and C.mute_now >= (C.mute_grace_until or 0) then
    C.mute_synced = C.mute_synced or {}
    C.mute_any = false
    for s = 0, 15 do
      C.mute_synced[s] = (C.mute_owned and C.mute_owned[s]) and true or nil
      if C.mute_synced[s] then C.mute_any = true end
    end
    if C.mute_dirty
       or (proj_changed and C.mute_now - (C.mute_last_run or 0) >= 0.25)
       or C.mute_now - (C.mute_last_run or 0) >= (C.mute_any and 1.0 or 2.0) then
      -- Step 3: the windows the StepSeq plays = every mapped region whose pattern it
      -- reports LOADED (SYNC 55-57, 2^k words); with no regions, the bound span.
      local function mute_windows(slot)
        local rl = region_list()
        if #rl == 0 then local reg = current_region(slot); return reg and { reg } or {} end
        local b = SYNC_BASE + slot * SYNC_STRIDE
        local w = { gr(b + F_LOADED0) or 0, gr(b + F_LOADED1) or 0, gr(b + F_LOADED2) or 0 }
        local out = {}
        for ord = 1, math.min(#rl, PAT_CAP) do
          local k = ord - 1
          if math.floor(w[math.floor(k / 32) + 1] / 2 ^ (k % 32)) % 2 >= 1 then out[#out + 1] = rl[ord] end
        end
        return out
      end
      pcall(eon_sync_mute_pass, C, C.mute_synced, mute_windows, diag)
      C.mute_dirty = false
      C.mute_last_run = C.mute_now
    end
  end

  -- DM -> StepSeq pattern SELECT: clicking a DM pattern chip calls pattern_regions.JumpTo,
  -- which stores the chosen region in the EON_DRUM_MATRIX:current ProjExtState. Watch it;
  -- when it changes, map that region to a pattern index (its ordinal in the start-sorted
  -- list, mirroring the AUTO map) and push it to each synced StepSeq via fields 15/20 --
  -- but ONLY to a slot whose JSFX pattern differs (so our own F_PATIDX nav doesn't echo).
  local _, curstr = reaper.GetProjExtState(0, 'EON_DRUM_MATRIX', 'current')
  local cur_idx = tonumber(curstr)
  if not C.dm_cur_primed then
    C.dm_cur_primed = true; C.last_dm_current = cur_idx     -- baseline: don't switch on first observation/load
  elseif cur_idx ~= C.last_dm_current then
    C.last_dm_current = cur_idx
    if cur_idx then
      local list = region_list()
      local ordinal
      for i = 1, #list do if list[i].idx == cur_idx then ordinal = i; break end end
      if ordinal then
        local pat = ordinal - 1
        for slot = 0, 15 do
          local b = SYNC_BASE + slot * SYNC_STRIDE
          if (gr(b + F_SYNCON) or 0) > 0.5 then
            -- P3b-4: compare against the ABSOLUTE selected ordinal when published (the
            -- on-page PATIDX is 0..7 and would echo-mismatch across pages).
            local cur_sel  = math.floor((gr(b + F_SELORD) or 0) + 0.5)
            local cur_jsfx = cur_sel >= 1 and (cur_sel - 1)
                             or math.floor((gr(b + F_PATIDX) or -1) + 0.5)
            if pat ~= cur_jsfx then
              gw(b + 15, pat)                              -- DM_PATSET (absolute pattern index = ordinal-1)
              C.dm_patseq = (C.dm_patseq or 0) + 1
              gw(b + 20, C.dm_patseq)                      -- DM_PATSEQ (edge-detect)
            end
          end
        end
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- AP-2: StepSeq custom-preset APPLY menu (scroll-audition into the active pattern)
-- ═══════════════════════════════════════════════════════════════════════════════
-- The StepSeq's own preset bank, sourced as plain grids from preset_cache.json (built
-- by gen_presets.py alongside the .ini). The JSFX raises a NAV request over gmem (wheel
-- over its Preset strip); we advance a flat index, stage that grid into the APPLY band,
-- and bump applyreq so the targeted instance drops it into its ACTIVE pattern. Works with
-- NO sync/DM (independent of eon_courier). Module-GLOBAL fns (no `local`) -> 200-ceiling safe.

-- Path resolver for the PatternLibrary tree (sibling of eon_dm_lib_path's Drum Matrix/lib).
function eon_pl_path(rel)
  local base = _SCRIPT_DIR:gsub("[/\\]+", "/"):gsub("/+$", "")
  local b2   = base:gsub("/%.Scripts$", "/Scripts")
  local bases = (b2 ~= base) and { base, b2 } or { base }
  for i = 1, #bases do
    local p = bases[i] .. "/EON/PatternLibrary/" .. rel
    local fh = io.open(p, "r")
    if fh then fh:close(); return p end
  end
  return bases[#bases] .. "/EON/PatternLibrary/" .. rel
end

-- Load preset_cache.json ONCE and flatten to [{name, rows}] over every (preset, variation)
-- pair (user choice: scroll steps through all variations). Returns flat list + category_row
-- map. nil if the cache/json lib is missing (menu just stays inert).
function eon_preset_flat()
  if eon_preset_flat_cache ~= nil then return eon_preset_flat_cache, eon_preset_catrow_cache end
  local okj, json = pcall(dofile, eon_dm_lib_path("json.lua"))
  if not okj or not json or not json.decode then eon_preset_flat_cache = false; return nil end
  local f = io.open(eon_pl_path("preset_cache.json"), "r")
  if not f then eon_preset_flat_cache = false; return nil end
  local txt = f:read("*a"); f:close()
  local okd, data = pcall(json.decode, txt)
  if not okd or type(data) ~= "table" or not data.presets then eon_preset_flat_cache = false; return nil end
  local flat = {}
  for _, p in ipairs(data.presets) do
    -- Every preset is listed — including non-16-step (triplet-grid) ones. The
    -- flat list MUST stay index-aligned with the AP-3 browser, which builds its
    -- own list from the same cache and sends ABSOLUTE indices (a skip here
    -- desyncs every index after it). Grid geometry rides along per entry; the
    -- JSFX apply consumer adopts it (AP-0c change_seqlen + steps_per_beat).
    for _, v in ipairs(p.variations or {}) do
      flat[#flat + 1] = { name = (p.name or "?") .. " - " .. (v.label or "?"), rows = v.rows or {},
                          ns = p.steps_per_bar or 16, spb = p.steps_per_beat or 4 }
    end
  end
  eon_preset_flat_cache   = flat
  eon_preset_catrow_cache = data.category_row or {}
  return flat, eon_preset_catrow_cache
end

-- Stage one flat entry's grid into the APPLY band (ROW-keyed, matching eon_ss_apply_grid),
-- then bump applyreq so the targeted instance consumes it. Ratchet list-cells are staged
-- TWICE: max velocity into the vel plane (old JSFX = flatten, unchanged behavior) PLUS a
-- sparse SUBDIV list after the plane (AD + 256): [count, then per ratchet: cellindex(row*NS+s),
-- K, v0..v7]. Header [5] carries the same seq as [1]; the JSFX only parses the subdiv list
-- when [5]==[1], so an OLD bridge (never writes [5]) can't feed a NEW JSFX stale subdivs,
-- and an OLD JSFX simply ignores the extra data. Fits the band: 1 + 72*10 = 721 <= 736 free
-- (APPLY_DATA 26044008 + 256 vel .. PCTRL 26045000).
-- Resolve a preset row category to the LANE that actually plays that sound on
-- THIS rack. The vel plane is consumed positionally (JSFX: lane r = plane row r,
-- and paired lane r IS pad r), while catrow is a FIXED canonical layout baked
-- into preset_cache.json — any kit whose pad order deviates got every deviating
-- row on the wrong lane. Audible worst case (user repro, 2026-08-04): Fischer
-- 808 F puts CH HAT on pad 4 / OH HAT on pad 5, the canonical map says open=4 /
-- closed=5, so every trap preset played its BUSY closed-hat row on the OPEN hat.
-- Now: prefer the pad whose PUBLISHED band category matches the row's category
-- (lowest unclaimed pad wins; same 8a ascending-zip spirit as ADAPT/FILL), fall
-- back to the canonical catrow row — a rack with no published categories, or no
-- pad for that sound, behaves exactly as before. Preset row names are mapped to
-- the 46-glyph vocabulary ids the band stores (aliases per gen_presets.py).
EON_PRESET_CAT_ALIAS = {
  ["808"] = "bass", sub = "bass", ohat = "open_hat", chat = "closed_hat",
  hat = "closed_hat",                 -- 2026-07-27 user rule: generic hat = closed
  bell = "cowbell", cymbal2 = "crash", cymbal = "ride",
  shaker = "shaker", maracas = "maraca", perc = "percussion",
  rim = "rimshot", tom_lo = "floor_tom", tom1 = "rack_tom", tom_mid = "rack_tom",
  tom2 = "tom", tom_hi = "tom",
}
-- Cymbal-family SECOND choice (user call 2026-08-04): a ride/crash row on a
-- generic CYMBAL pad beats the fixed-row fallback, which can park a busy ride
-- pattern on a tom lane (808 F row 9 = TOM MID). Claiming stays first-come in
-- sorted-cat order, so a preset with BOTH rows and one CYMBAL pad resolves
-- deterministically: "crash" sorts before "ride" and takes the pad.
EON_PRESET_CAT_FALLBACK = {
  ride = "cymbal", cymbal = "cymbal", crash = "cymbal", cymbal2 = "cymbal",
}
function eon_preset_lane_for_cat(cat, slot, taken, catrow)
  local fallback = catrow[cat]
  local gr = reaper.gmem_read
  local names = { EON_PRESET_CAT_ALIAS[cat] or cat, EON_PRESET_CAT_FALLBACK[cat] }
  for n = 1, #names do
    local id = eon_padcat_index and eon_padcat_index(names[n]) or -1
    if id and id >= 0 and EON_PADCAT_BASE then
      for pad = 0, 15 do
        local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + pad * 4
        if (gr(b) or 0) > 0 and math.floor((gr(b + 1) or -1) + 0.5) == id
           and not taken[pad] then
          taken[pad] = true
          return pad
        end
      end
    end
  end
  return fallback
end

function eon_preset_stage_apply(slot, entry, catrow)
  local gw = reaper.gmem_write
  local AB, AD = 26044000, 26044008
  local SD = AD + 16 * 16                               -- 26044264: sparse ratchet list
  -- Per-entry grid geometry (triplet presets: ns=12, spb=3; default 16/4).
  -- The JSFX adopts it (AP-0c: change_seqlen + steps_per_beat) on consume.
  local ns  = entry.ns or 16
  local spb = entry.spb or 4
  local seq = (eon_apply_seq or 0) + 1
  for i = 0, 16 * 16 - 1 do gw(AD + i, 0) end          -- zero the full vel plane
  local rats = {}
  local taken = {}
  -- Deterministic row order (pairs() order is arbitrary): sort categories so
  -- the band scan claims pads identically on every apply of the same preset.
  local cats = {}
  for cat in pairs(entry.rows) do cats[#cats + 1] = cat end
  table.sort(cats)
  for _, cat in ipairs(cats) do
    local steps = entry.rows[cat]
    local row = eon_preset_lane_for_cat(cat, slot, taken, catrow)
    if row and type(steps) == "table" then
      for s = 0, ns - 1 do
        local v = steps[s + 1]
        if type(v) == "table" then                      -- ratchet: flatten for the plane...
          local m = 0; for _, x in ipairs(v) do if (x or 0) > m then m = x end end
          if m > 0 and #v > 1 and #rats < 72 then       -- ...and record for the subdiv list
            rats[#rats + 1] = { cell = row * ns + s, vels = v }
          end
          v = m
        end
        v = math.floor(tonumber(v) or 0)
        if v > 0 then gw(AD + row * ns + s, v) end      -- plane addressed by ns (matches JSFX r*buf_ns+s)
      end
    end
  end
  gw(SD, #rats)
  for i, rc in ipairs(rats) do
    local p = SD + 1 + (i - 1) * 10
    local K = math.min(#rc.vels, 8)
    gw(p, rc.cell); gw(p + 1, K)
    for k = 1, 8 do gw(p + 1 + k, math.floor(tonumber(rc.vels[k]) or 0)) end
  end
  gw(AB + 0, slot); gw(AB + 2, 16); gw(AB + 3, ns); gw(AB + 4, spb)
  gw(AB + 5, seq)                                       -- subdiv-list-valid stamp
  eon_apply_seq = seq
  gw(AB + 1, seq)                                       -- bump LAST (after grid is in place)
end

-- Write an ASCII name into a gmem char band (null-terminated), like the JSFX roster reader.
function eon_preset_write_name(base, name, maxc)
  local gw = reaper.gmem_write
  local n = math.min(#name, maxc)
  for i = 0, n - 1 do gw(base + i, string.byte(name, i + 1)) end
  gw(base + n, 0)
end

-- Per-poll: scan each slot's PCTRL nav mailbox; on a new NAV request, advance that slot's
-- flat index by NAV_DIR, stage the grid, and publish idx/count/name back for the JSFX strip.
function eon_preset_nav_tick()
  local flat, catrow = eon_preset_flat()
  if not flat or #flat == 0 then return end
  local gr, gw = reaper.gmem_read, reaper.gmem_write
  local PB, PS = 26045000, 64                            -- EON_SS_PCTRL_BASE / STRIDE
  eon_pnav_last = eon_pnav_last or {}
  eon_psel_last = eon_psel_last or {}
  eon_pidx      = eon_pidx or {}
  -- Apply flat[idx] to `slot`: stage the grid, record the index, publish idx/count/name.
  local function apply_idx(slot, nb, idx)
    idx = idx % #flat
    eon_pidx[slot] = idx
    eon_preset_stage_apply(slot, flat[idx + 1], catrow)
    gw(nb + 2, idx); gw(nb + 3, #flat)
    eon_preset_write_name(nb + 16, flat[idx + 1].name, 31)
  end
  for slot = 0, 15 do
    local nb = PB + slot * PS
    -- Relative nav from the in-window strip (wheel / arrows): step by NAV_DIR.
    local navseq = math.floor((gr(nb + 0) or 0) + 0.5)
    if navseq ~= (eon_pnav_last[slot] or 0) then
      eon_pnav_last[slot] = navseq
      if navseq > 0 then                                 -- 0 = never navigated (open blank)
        local dir = (gr(nb + 1) or 0) >= 0 and 1 or -1
        apply_idx(slot, nb, (eon_pidx[slot] or 0) + dir)
      end
    end
    -- Absolute select from the AP-3 browser panel: jump straight to SELECT_IDX.
    local selseq = math.floor((gr(nb + 5) or 0) + 0.5)
    if selseq ~= (eon_psel_last[slot] or 0) then
      eon_psel_last[slot] = selseq
      if selseq > 0 then
        apply_idx(slot, nb, math.floor((gr(nb + 6) or 0) + 0.5))
      end
    end
  end
end

-- AP-4: the JSFX Preset strip (right-click, or center-click on the name) bumps
-- BROWSER_OPEN_REQ; the JSFX can't launch a ReaScript, so we register + run
-- the browser here (same idiom as the Swing browser CMD). ALIVE is a
-- time_precise heartbeat the browser writes each frame — a bump while one is
-- alive is a TOGGLE: we bump CLOSE_REQ (26046103) and the browser quits on it.
--
-- Launched scripts are deliberately left REGISTERED -- here and at every other
-- launch site in this file (groove browser, dock-layout relay, DM scripts,
-- CMD 60/71). AddRemoveReaScript(false, path) removes the action for that PATH
-- no matter who registered it, so the old register-run-unregister dance
-- silently stripped any permanent registration the user held of the same
-- script: shortcuts, menu items, and toolbar buttons on that id died with it
-- (bitten 2026-08-26 when the dock scripts' relay unregistered the user's own
-- Dock View action; CMD 71's unregister killed the EON toolbar's Pad FX button
-- the same way, since eon_toolbar.lua bakes that id into reaper-menu.ini).
-- Registering is idempotent -- the same path always yields the same _RS
-- command id, no duplicates -- so the worst cost is one stable Action List
-- entry per script, which is exactly what keeps user bindings alive. The ONE
-- deliberate unregister left in the bundle is EON Floatter's RETIREMENT of the
-- FloatSize pair it replaced (wiki §11.3) -- that one is correct.
function eon_preset_browser_launch_tick()
  local gr = reaper.gmem_read
  local req = math.floor((gr(26046100) or 0) + 0.5)        -- EON_SS_BROWSER_OPEN_REQ
  if eon_browser_req_last == nil then eon_browser_req_last = req; return end  -- baseline; ignore stale
  if req == eon_browser_req_last then return end
  eon_browser_req_last = req
  if req <= 0 then return end
  local now = reaper.time_precise()
  if (now - (gr(26046101) or 0)) < 0.6 then                -- alive -> this bump means CLOSE
    reaper.gmem_write(26046103, math.floor((gr(26046103) or 0) + 0.5) + 1)
    return
  end
  -- Launch-in-flight guard: the browser needs a frame or two before its ALIVE
  -- heartbeat starts, so a fast second bump would double-launch without this.
  if eon_browser_launch_t and (now - eon_browser_launch_t) < 1.5 then return end
  local base = _SCRIPT_DIR:gsub("[/\\]+", "/"):gsub("/+$", "")
  local browser_path = base .. "/EON_StepSeq_Preset_Browser.lua"
  local f = io.open(browser_path, "r")
  if not f then return end
  f:close()
  local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
  if cmd_id and cmd_id > 0 then
    reaper.Main_OnCommand(cmd_id, 0)
    eon_browser_launch_t = now
  end
end

-- ── Start EON_Swing_Strip_Sync if nothing else has ───────────────────────────
-- That script is what puts an EON Drum Strip on each multi-out child track --
-- it is the ONLY file that inserts one. It is a background defer script, so it
-- has to be RUNNING, and it only adds itself to __startup.lua after a human has
-- run it once from the Action List.
-- ⚠️ Nothing ever did that for a customer: neither installer nor ReaPack writes
-- a startup entry for it, and no guide mentions it. On a real install it was not
-- even in the action list, so multi-out never grew strips -- while dev machines
-- had the startup entry from an old manual run, which is why this looked fine
-- here and worked nowhere else. The bridge is the right place to fix it: it is
-- already running everywhere, and it is the one script customers ARE told to run.
--
-- ⛔ Launched at most ONCE per bridge session, never retried. Re-running a live
-- defer script makes REAPER put up a modal "already running" prompt, and
-- strip_sync itself MB()s and exits when SWS is missing -- a retry loop would
-- turn either into a dialog storm the user cannot dismiss.
-- ⛔ Registered and left registered: strip_sync's own self_register() writes the
-- resulting command ID into __startup.lua, so unregistering after launch (the
-- register-run-unregister idiom the rest of this file has since dropped -- see
-- AP-4 above) would leave a dead ID there and it would strip itself back out
-- on next launch.
--
-- After launching, we watch for its heartbeat and print ONE console line if it
-- fails to appear -- strip_sync exits with a MB() when SWS is missing, and
-- without this the bridge would just look like it had done nothing at all.
local eon_ss_state        = 'init'   -- 'init' → 'launched' → 'confirmed' | 'unresponsive'
local eon_ss_ensure_first = nil
local eon_ss_launch_t     = nil
function eon_strip_sync_ensure_tick()
  if eon_ss_state == 'confirmed' or eon_ss_state == 'unresponsive' then return end
  local now = reaper.time_precise()

  -- Post-launch watch: give strip_sync a window to write its first heartbeat,
  -- then warn once if none appears. Do NOT retry the launch itself — that risks
  -- the dialog storm the top-of-function comment describes.
  if eon_ss_state == 'launched' then
    local stamp = tonumber(reaper.GetExtState(core.ALIVE_STRIP_SYNC_SECTION,
                                              core.ALIVE_STRIP_SYNC_KEY) or "")
    if stamp and (now - stamp) < core.ALIVE_STALE_S then
      eon_ss_state = 'confirmed'
      return
    end
    if (now - eon_ss_launch_t) > 8.0 then
      eon_ss_state = 'unresponsive'
      reaper.ShowConsoleMsg("[EON] EON_Swing_Strip_Sync.lua was launched but is not " ..
        "writing heartbeats -- it likely exited on startup (SWS extension missing?).\n" ..
        "  Multi-out tracks will not get an EON Drum Strip.\n")
    end
    return
  end

  -- Grace period. Both scripts can sit in __startup.lua, and the bridge may well
  -- get its first tick in before strip_sync has written a single heartbeat.
  -- Without this the bridge would race its own sibling and launch a second copy.
  if not eon_ss_ensure_first then eon_ss_ensure_first = now; return end
  if (now - eon_ss_ensure_first) < 5.0 then return end

  local stamp = tonumber(reaper.GetExtState(core.ALIVE_STRIP_SYNC_SECTION,
                                            core.ALIVE_STRIP_SYNC_KEY) or "")
  if stamp and (now - stamp) < core.ALIVE_STALE_S then
    eon_ss_state = 'confirmed'         -- already running (startup entry, or by hand)
    return
  end

  local path = eon_sibling_script("EON_Swing_Strip_Sync.lua")
  local f = io.open(path, "r")
  if not f then
    eon_ss_state = 'unresponsive'
    reaper.ShowConsoleMsg("[EON] EON_Swing_Strip_Sync.lua is missing (" .. path ..
      ")\n  Multi-out tracks will not get an EON Drum Strip. Reinstall Swing.\n")
    return
  end
  f:close()
  local cmd_id = reaper.AddRemoveReaScript(true, 0, path, true)
  if not cmd_id or cmd_id <= 0 then
    eon_ss_state = 'unresponsive'
    reaper.ShowConsoleMsg("[EON] Could not add EON_Swing_Strip_Sync.lua to the " ..
      "Action List -- multi-out tracks will not get an EON Drum Strip.\n")
    return
  end
  reaper.Main_OnCommand(cmd_id, 0)
  eon_ss_state    = 'launched'
  eon_ss_launch_t = now
end

-- ── Start EON Floatter if nothing else has ───────────────────────────────────
-- The floating-window sizer: EON plugins open at the size EON set for them.
-- Same contract as strip_sync above -- heartbeat, grace, launch at most ONCE
-- per session, never unregister -- with one addition: the launch stamps
-- core.FLOATTER_LAUNCH_KEY first, so the instance knows the bridge (not the
-- user) started it and keeps its panel closed. Floatter's own set_action_options
-- makes a launch-while-alive a restart, so the heartbeat gate is what keeps
-- this from ever restarting a healthy instance.
-- GLOBALS by necessity: the main chunk sits at Lua's 200-local ceiling.
eon_fl_state        = 'init'
eon_fl_ensure_first = nil
eon_fl_launch_t     = nil
eon_fl_stale_since  = nil
function eon_floatter_ensure_tick()
  if eon_fl_state == 'confirmed' or eon_fl_state == 'unresponsive' then return end
  local now = reaper.time_precise()

  if eon_fl_state == 'launched' then
    local stamp = tonumber(reaper.GetExtState(core.ALIVE_FLOATTER_SECTION,
                                              core.ALIVE_FLOATTER_KEY) or "")
    if stamp and (now - stamp) < core.ALIVE_STALE_S then
      eon_fl_state = 'confirmed'
      return
    end
    if (now - eon_fl_launch_t) > 8.0 then
      eon_fl_state = 'unresponsive'
      reaper.ShowConsoleMsg("[EON] EON_Floatter.lua was launched but is not writing " ..
        "heartbeats -- it likely exited on startup (js_ReaScriptAPI extension missing?).\n" ..
        "  EON plugins will open at their default window size.\n")
    end
    return
  end

  if not eon_fl_ensure_first then eon_fl_ensure_first = now; return end
  if (now - eon_fl_ensure_first) < 5.0 then return end

  local stamp = tonumber(reaper.GetExtState(core.ALIVE_FLOATTER_SECTION,
                                            core.ALIVE_FLOATTER_KEY) or "")
  if stamp and (now - stamp) < core.ALIVE_STALE_S then
    eon_fl_state = 'confirmed'         -- already running (startup entry, or by hand)
    eon_fl_stale_since = nil
    return
  end
  -- The user switched "starts with REAPER" off in Floatter's panel: respect it.
  if reaper.GetExtState(core.ALIVE_FLOATTER_SECTION, "autostart") == "0" then
    eon_fl_state = 'unresponsive'
    return
  end
  -- A stale stamp right after a main-thread stall belongs to a LIVE instance
  -- that has not had its tick yet; launching would restart it (Floatter's
  -- set_action_options makes a launch-while-alive a restart) and close its
  -- panel. Only a stamp that stays stale for 3 s more is a dead one.
  if not eon_fl_stale_since then eon_fl_stale_since = now; return end
  if (now - eon_fl_stale_since) < 3.0 then return end

  local path = eon_sibling_script("EON_Floatter.lua")
  local f = io.open(path, "r")
  if not f then
    eon_fl_state = 'unresponsive'      -- not installed here: nothing to say, nothing to do
    return
  end
  f:close()
  local cmd_id = reaper.AddRemoveReaScript(true, 0, path, true)
  if not cmd_id or cmd_id <= 0 then
    eon_fl_state = 'unresponsive'
    reaper.ShowConsoleMsg("[EON] Could not add EON_Floatter.lua to the Action List -- " ..
      "EON plugins will open at their default window size.\n")
    return
  end
  reaper.SetExtState(core.ALIVE_FLOATTER_SECTION, core.FLOATTER_LAUNCH_KEY,
                     "bridge:" .. reaper.time_precise(), false)
  reaper.Main_OnCommand(cmd_id, 0)
  eon_fl_state    = 'launched'
  eon_fl_launch_t = now
end

-- ── Start EON_FXPicker_Bridge if nothing else has ────────────────────────────
-- The FX picker (Swing's FX / INST / VEND panel and the Console's compact
-- picker) is fed by its own defer script, EON_FXPicker_Bridge.lua. Like every
-- background companion it only writes itself into __startup.lua after it has
-- been run ONCE — and, exactly as with strip_sync above, nothing ever ran it
-- for a customer: not the installer, not the guide, not this bridge. Dev
-- machines had the startup entry from an old manual run, so the panel filled
-- here and sat on "waiting for the bridge..." on every fresh install
-- (portable-install report, 2026-09-04). Same fix, same shape: the one script
-- customers ARE told to run launches it, once per session, and its own
-- self-register then makes it a startup action from the next launch on.
--
-- Liveness is the picker's own toggle flag: it sets EON_FXPICK/running to "1"
-- synchronously at the top of its file and clears it in atexit. Non-persistent
-- ExtState, so a crashed REAPER cannot leave it stale across launches.
-- ⛔ That flag is a TOGGLE — running the script while it reads "1" STOPS the
-- live copy. Hence the grace period (a startup entry may not have ticked yet)
-- and the hard rule of launching only while the flag says nobody is running.
-- ⛔ Launched at most ONCE per bridge session, never retried: a second launch
-- against a live copy is either the toggle-off above or REAPER's "already
-- running" task-control modal.
-- One table, not three locals: this file sits under Lua's 200-top-level-local cap.
local eon_fxp = { state = 'init', ensure_first = nil, launch_t = nil }
                 -- state: 'init' → 'launched' → 'confirmed' | 'unresponsive'
function eon_fxpick_ensure_tick()
  if eon_fxp.state == 'confirmed' or eon_fxp.state == 'unresponsive' then return end
  local now     = reaper.time_precise()
  local running = reaper.GetExtState("EON_FXPICK", "running") == "1"

  if eon_fxp.state == 'launched' then
    if running then eon_fxp.state = 'confirmed'; return end
    if (now - eon_fxp.launch_t) > 8.0 then
      eon_fxp.state = 'unresponsive'
      reaper.ShowConsoleMsg("[EON] EON_FXPicker_Bridge.lua was launched but never reported " ..
        "running -- it likely exited on startup.\n" ..
        "  The FX picker will show 'waiting for the bridge'. Run it from the Action List " ..
        "to see its error.\n")
    end
    return
  end

  -- Grace period: both scripts can sit in __startup.lua, and this bridge may
  -- tick before the picker's startup entry has set its flag.
  if not eon_fxp.ensure_first then eon_fxp.ensure_first = now; return end
  if (now - eon_fxp.ensure_first) < 5.0 then return end

  if running then
    eon_fxp.state = 'confirmed'        -- already running (startup entry, or by hand)
    return
  end

  local path = eon_sibling_script("EON_FXPicker_Bridge.lua")
  local f = io.open(path, "r")
  if not f then
    eon_fxp.state = 'unresponsive'
    reaper.ShowConsoleMsg("[EON] EON_FXPicker_Bridge.lua is missing (" .. path ..
      ")\n  The FX picker will show 'waiting for the bridge'. Reinstall Swing.\n")
    return
  end
  f:close()
  local cmd_id = reaper.AddRemoveReaScript(true, 0, path, true)
  if not cmd_id or cmd_id <= 0 then
    eon_fxp.state = 'unresponsive'
    reaper.ShowConsoleMsg("[EON] Could not add EON_FXPicker_Bridge.lua to the Action List " ..
      "-- the FX picker will show 'waiting for the bridge'.\n")
    return
  end
  reaper.Main_OnCommand(cmd_id, 0)
  eon_fxp.state    = 'launched'
  eon_fxp.launch_t = now
end

-- GROOVE S3: the StepSeq groove menu's "Import grooves..." row bumps GRV_OPEN_REQ
-- (26140200); launch the .rgt groove browser the same way as the preset browser above.
-- ALIVE (26140201) is the browser's time_precise heartbeat -> skip if one's already up.
function eon_groove_browser_launch_tick()
  local gr = reaper.gmem_read
  local req = math.floor((gr(26140200) or 0) + 0.5)        -- EON_SS_GRV_OPEN_REQ
  if eon_grvbrowser_req_last == nil then eon_grvbrowser_req_last = req; return end
  if req == eon_grvbrowser_req_last then return end
  eon_grvbrowser_req_last = req
  if req <= 0 then return end
  if (reaper.time_precise() - (gr(26140201) or 0)) < 0.6 then return end      -- already open
  local base = _SCRIPT_DIR:gsub("[/\\]+", "/"):gsub("/+$", "")
  local browser_path = base .. "/EON_StepSeq_Groove_Browser.lua"
  local f = io.open(browser_path, "r")
  if not f then return end
  f:close()
  local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
  if cmd_id and cmd_id > 0 then
    reaper.Main_OnCommand(cmd_id, 0)
    -- Left registered (the browser's own header invites running it straight
    -- from the Action List, so a user registration is likely) -- see AP-4.
  end
end

-- Dock-rig layout relay: Swing's wordmark menu picked a layout and wrote its
-- 1-based index to GS_DOCK_LAYOUT_REQ (JSFX can't touch ExtState or actions —
-- same reason the theme picker rides GS_THEME_REQ). Stamp the pick into
-- ExtState and run EON Dock Layout.lua, which applies that layout without
-- showing its menu when a pick is staged. The script lives with the no-Hub
-- rig scripts, not the bundle Scripts dir; missing file = one console note.
-- ═══════════════════════════════════════════════════════════════════════════════
-- EON_SWBROWSE — publisher for the in-JSFX mini file browser
--
-- Swing's face can draw, scroll and drag; the one thing EEL2 cannot do is
-- ENUMERATE a directory. So this rides the bridge's existing tick, lists one
-- folder, and publishes it into the band declared in
-- .refs/gmem_regions_supplement.tsv (26607616..26673151). Same shape as
-- EON_FXPicker_Bridge's publish(): seqlock, windowed page, index-back-not-path.
--
-- ⚠️⚠️ THE ONE RULE THAT SHAPES THIS WHOLE MODULE — MEASURED, NOT ASSUMED:
-- REAPER's directory listing cache holds exactly ONE directory. Reading folder
-- A, then B, then A again re-lists A from disk EVERY time you switch. Measured
-- 2026-08-29: same folder repeatedly = 0.0037 ms/call; two folders alternating
-- = 0.45 ms/call; alternating when one holds 5000 entries = 5.6 ms/call, i.e.
-- 200 round-trips cost 2.2 SECONDS. Drawing 40 folder rows while a scan was in
-- flight ran 100x slower than the same 40 rows with no scan running.
-- ⇒ AT MOST ONE FOLDER IS ENUMERATED PER TICK, ACROSS ALL SLOTS. `eon_fb.scan`
--   is a single global, not per-slot, precisely so two slots can never
--   interleave. Cache the result in Lua and never ask twice.
--
-- Module-GLOBAL state (no `local`) to respect the ~200 top-level local cap —
-- same convention as eon_courier_tick above.
-- ═══════════════════════════════════════════════════════════════════════════════

eon_fb        = { slots = {}, scan = nil, hb = 0 }
eon_fb_sep    = package.config:sub(1, 1)
eon_fb_bs     = string.char(92)                 -- no literal backslash anywhere
eon_fb_notsep = "[^/" .. eon_fb_bs .. "]"
eon_fb_CHUNK  = 400                             -- entries per tick within ONE folder
-- Subfolder caps, same numbers the big browser settled on
-- (Swing_Browser.lua:1109). 20k covers commercial libraries; depth 8 stops a
-- symlink loop walking forever.
eon_fb_MAXFILES = 20000
eon_fb_MAXDEPTH = 8

-- Non-ASCII folds to '?'. Display only — the face sends back a row INDEX and
-- this module resolves the real path, so a folded name still loads correctly.
function eon_fb_fold(s)
  if not s then return "" end
  return (s:gsub("[\128-\255]", "?"))
end

function eon_fb_ext(name)
  local e = name:match("%.([^.]+)$")
  return e and e:lower() or ""
end

-- Trailing separator stripped, so two spellings of one folder cannot become two
-- cache entries and start the alternation the rule above forbids.
function eon_fb_norm(p)
  if not p or p == "" then return nil end
  p = p:gsub("[/" .. eon_fb_bs .. "]+$", "")
  if p == "" then return nil end
  -- ⚠️⚠️ A DRIVE keeps its separator. Stripping it leaves "C:", which to Windows
  -- means "the current directory on C:" and not the root at all -- and it made
  -- a starred drive and the drive-scan entry look like two different folders,
  -- so the rail showed "C:" AND "C:\" as separate roots. eon_fb_parent has kept
  -- this rule since it was written; norm did not, and the two disagreed.
  if p:match("^%a:$") then p = p .. eon_fb_sep end
  return p
end

-- Join a folder to a child name. A DRIVE ROOT already ends with the separator
-- ("C:\" -- eon_fb_parent keeps it that way on purpose), so the naive concat
-- produced "C:\\Windows". Windows tolerates the doubled separator, which is
-- exactly why it survived unnoticed; the folder TREE matches paths as strings,
-- and two spellings of one folder break that outright.
-- Folders nobody is browsing for samples in. This did not matter while the tree
-- was rooted on your own folder; rooting it at the DRIVE puts $Recycle.Bin and
-- System Volume Information at the top of the very first thing you see.
-- Leading "." covers the Unix/dotfile convention, leading "$" covers Windows'
-- own ($Recycle.Bin, $WinREAgent, $Windows.~WS).
-- ⚠️⚠️ CROSS-PLATFORM. "Every drive" means three different things:
--   Windows  drive LETTERS, C..Z (an external lands wherever a letter is free,
--            routinely F: or G: -- the old hardcoded { C:, D:, E: } made those
--            unreachable from PLACES too, not just from the rail)
--   macOS    "/" plus whatever is mounted under /Volumes
--   Linux    "/" plus /media/<user> and /mnt
-- A letter scan on a Mac would simply return nothing and leave the rail with no
-- roots at all, which is why this is not one loop.
function eon_fb_os()
  local o = reaper.GetOS and reaper.GetOS() or ""
  if o:find("Win", 1, true) then return "win" end
  if o:find("OSX", 1, true) or o:find("macOS", 1, true) then return "mac" end
  return "other"
end

function eon_fb_drives()
  local out = {}
  local os_ = eon_fb_os()
  if os_ == "win" then
    for c = 67, 90 do                                -- 'C'..'Z'
      local root = string.char(c) .. ":" .. eon_fb_sep
      -- ⚠️ NOT EnumerateSubdirectories: a real but EMPTY drive root (a freshly
      -- formatted stick) has none and would be reported as absent. It also
      -- costs a directory LISTING per letter -- 24 of them, on 24 different
      -- paths, which is precisely the single-slot cache thrash. os.rename does
      -- neither.
      if eon_fb_dir_exists(root) then out[#out + 1] = root end
    end
    return out
  end
  out[#out + 1] = "/"                                -- the filesystem root
  local mounts = {}
  if os_ == "mac" then
    mounts[#mounts + 1] = "/Volumes"
  else
    local user = os.getenv("USER") or os.getenv("LOGNAME")
    if user then mounts[#mounts + 1] = "/media/" .. user end
    mounts[#mounts + 1] = "/media"
    mounts[#mounts + 1] = "/mnt"
  end
  for _, m in ipairs(mounts) do
    local i = 0
    while true do
      local d = reaper.EnumerateSubdirectories(m, i)
      if not d then break end
      out[#out + 1] = m .. "/" .. d
      i = i + 1
    end
  end
  return out
end

-- Linux localises the user folders (Schreibtisch, Escritorio...) and records the
-- real paths in ~/.config/user-dirs.dirs. Read them rather than guessing at
-- English names that may simply not exist.
function eon_fb_xdg(home)
  local t = {}
  if not home or eon_fb_os() ~= "other" then return t end
  local f = io.open(home .. "/.config/user-dirs.dirs", "r")
  if not f then return t end
  for line in f:lines() do
    local k, v = line:match('^%s*XDG_(%u+)_DIR%s*=%s*"(.-)"')
    if k and v then t[k] = (v:gsub("%$HOME", home)) end
  end
  f:close()
  return t
end

function eon_fb_hide_dir(name)
  local c = name:sub(1, 1)
  if c == "." or c == "$" then return true end
  local l = name:lower()
  return l == "system volume information" or l == "recovery"
      or l == "config.msi" or l == "msocache"
end

function eon_fb_join(dir, name)
  local last = dir:sub(-1)
  if last == "/" or last == eon_fb_bs then return dir .. name end
  return dir .. eon_fb_sep .. name
end

function eon_fb_parent(p)
  local up = p:match("^(.*)[/" .. eon_fb_bs .. "]" .. eon_fb_notsep .. "+$")
  -- "C:" is not a browsable folder; keep the root as "C:\"
  if up and up:match("^%a:$") then up = up .. eon_fb_sep end
  return up
end

-- Where the mini browser opens: whatever the BIG browser already points at.
-- Two browsers, one idea — you never set your folders up twice.
function eon_fb_default_dir()
  local f = io.open(reaper.GetResourcePath() .. eon_fb_sep .. "Data" ..
                    eon_fb_sep .. "EON_Swing" .. eon_fb_sep ..
                    "Swing_Browser_Settings.lua", "r")
  if f then
    local body = f:read("a"); f:close()
    local chunk = load("return " .. (body:match("return%s*(%b{})") or "{}"), "fb", "t", {})
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then
      local cand = (t.recent_folders and t.recent_folders[1])
                or (t.favorites and t.favorites[1] and t.favorites[1].path)
      cand = eon_fb_norm(cand)
      if cand and reaper.EnumerateSubdirectories(cand, 0) ~= nil then return cand end
      if cand and reaper.EnumerateFiles(cand, 0) ~= nil then return cand end
    end
  end
  return eon_fb_norm(os.getenv("USERPROFILE") or os.getenv("HOME")) or "C:" .. eon_fb_sep
end

function eon_fb_slot(i)
  local st = eon_fb.slots[i]
  if not st then
    st = { cwd = nil, entries = {}, gen = 0, pub_seq = nil,
           req_seen = 0, act_seen = 0, off = 0, n = 0, flags = 0, active = false }
    eon_fb.slots[i] = st
  end
  return st
end

-- ── scanning ────────────────────────────────────────────────────────────────
-- Begin a scan. Refuses to start a second one: the previous must finish first,
-- or we would alternate folders and pay the cost documented at the top.
function eon_fb_scan_begin(slot, path, recurse)
  if eon_fb.scan then return false end
  eon_fb.scan = { slot = slot, path = path, root = path, di = 0, fi = 0,
                  dirs = {}, files = {}, phase = "dirs",
                  recurse = recurse and true or false, depth = 0, queue = {} }
  return true
end

function eon_fb_scan_step()
  local sc = eon_fb.scan
  if not sc then return end
  local st = eon_fb_slot(sc.slot)
  local budget = eon_fb_CHUNK

  -- Folders first, then files — BOTH on sc.path and nothing else, so the whole
  -- scan stays inside one directory and the listing cache is never evicted.
  -- Recurse mode discards folder rows entirely (the files ARE the listing), so
  -- collecting them here was a second full read of the root for nothing.
  if sc.recurse and sc.phase == "dirs" then sc.phase = "files" end
  while budget > 0 and sc.phase == "dirs" do
    local d = reaper.EnumerateSubdirectories(sc.path, sc.di)
    if not d then sc.phase = "files" break end
    if not eon_fb_hide_dir(d) then sc.dirs[#sc.dirs + 1] = d end
    sc.di = sc.di + 1
    budget = budget - 1
  end
  while budget > 0 and sc.phase == "files" do
    local fn = reaper.EnumerateFiles(sc.path, sc.fi)
    if not fn then
      if sc.recurse and #sc.files < eon_fb_MAXFILES then
        -- queue this directory's children, then move to the NEXT directory.
        -- One directory is finished before the next is touched -- interleaving
        -- them is the 100x cache thrash probe 1 measured.
        if sc.depth < eon_fb_MAXDEPTH then
          local di = 0
          while true do
            local sub = reaper.EnumerateSubdirectories(sc.path, di)
            if not sub then break end
            if not eon_fb_hide_dir(sub) then
              sc.queue[#sc.queue + 1] = { path = eon_fb_join(sc.path, sub), depth = sc.depth + 1 }
            end
            di = di + 1
          end
        end
        local nx = table.remove(sc.queue, 1)
        if nx then
          sc.path, sc.depth, sc.fi = nx.path, nx.depth, 0
          -- ⚠️ Do NOT break here. Breaking ended the whole TICK on every folder
          -- change, so a 450-folder library took 450 ticks (~15 s at 30 Hz)
          -- when probe 1 measured the entire walk at 0.4 s. Spend the rest of
          -- this tick's budget on the new folder instead. Still strictly
          -- sequential -- one directory finished before the next is touched --
          -- which is what keeps the single-slot listing cache from thrashing.
          budget = budget - 1
        else
          sc.phase = "done"
          break
        end
      else
        sc.phase = "done"
        break
      end
    else
      -- ⚠️⚠️ THIS `else` IS THE WHOLE POINT. Removing the `break` above (so a
      -- folder change no longer ends the tick) left the nil-fn path FALLING
      -- THROUGH into the file handler, because Lua has no `continue` -- and
      -- `eon_fb_ext(nil)` threw on EVERY folder transition in subfolder mode:
      --   "Swing_Kit_Bridge.lua:2326: attempt to index a nil value (local 'name')"
      -- The two paths are mutually exclusive; say so structurally rather than
      -- relying on a control-flow statement that is no longer there.
      local ext = eon_fb_ext(fn)
      if core.SWBROWSE_EXT[ext] and #sc.files < eon_fb_MAXFILES then
        -- In subfolder mode the name alone is useless -- six kits each have a
        -- "Snare". Carry the path RELATIVE to where the walk started.
        local rel = ""
        if sc.recurse and sc.path ~= sc.root then
          rel = sc.path:sub(#sc.root + 2)
          if #rel > 22 then rel = "~" .. rel:sub(#rel - 20) end
        end
        sc.files[#sc.files + 1] = { name = fn, ext = ext, dir = sc.path, rel = rel }
      end
      sc.fi = sc.fi + 1
      budget = budget - 1
    end
  end

  if sc.phase ~= "done" then
    st.flags = 1                                   -- bit0 scanning
    return
  end

  table.sort(sc.dirs, function(a, b) return a:lower() < b:lower() end)
  -- Sort by what the row actually SHOWS. In subfolder mode a row reads
  -- "Pack_A\kick.wav" but this used to sort on "kick.wav" alone, so the visible
  -- list came out in an order with no relation to the strings in it -- packs
  -- interleaved at random and the same folder's samples scattered down the
  -- page. Folder first, then name, is the order the eye is looking for.
  table.sort(sc.files, function(a, b)
    local ka = ((a.rel or "") ~= "") and (a.rel .. eon_fb_sep .. a.name) or a.name
    local kb = ((b.rel or "") ~= "") and (b.rel .. eon_fb_sep .. b.name) or b.name
    return ka:lower() < kb:lower()
  end)

  local ent = {}
  if eon_fb_parent(sc.root) then
    ent[#ent + 1] = { name = "..", kind = 2, ext = "", path = eon_fb_parent(sc.root) }
  end
  if not sc.recurse then
    for _, d in ipairs(sc.dirs) do
      ent[#ent + 1] = { name = d, kind = 1, ext = "", path = eon_fb_join(sc.root, d) }
    end
  end
  for _, fl in ipairs(sc.files) do
    ent[#ent + 1] = {
      name = (fl.rel ~= nil and fl.rel ~= "") and (fl.rel .. eon_fb_sep .. fl.name) or fl.name,
      kind = 0, ext = fl.ext,
      path = eon_fb_join(fl.dir or sc.root, fl.name) }
  end

  -- Remember where we were, unless this move IS a back-step.
  if st.cwd and st.cwd ~= sc.root and not st.nohist then
    st.hist = st.hist or {}
    st.hist[#st.hist + 1] = st.cwd
    while #st.hist > 32 do table.remove(st.hist, 1) end
  end
  st.nohist  = false
  st.cwd     = sc.root
  st.filter  = nil          -- a new folder starts unfiltered
  st.entries = ent
  st.ndirs   = (sc.recurse and 0 or #sc.dirs) + (eon_fb_parent(sc.root) and 1 or 0)
  st.gen     = st.gen + 1
  eon_fb_refresh_fav(st)
  -- bit1 = nothing playable here. Counted from real CONTENT, not from #ent:
  -- every folder that HAS a parent carries a ".." row, so `#ent == 0` could
  -- only ever be true at a drive root and the flag was effectively unreachable
  -- (found in the 2026-08-29 audit, via fbscan_test).
  st.flags   = ((#sc.files == 0) and (sc.recurse or #sc.dirs == 0)) and 2 or 0
  if not eon_fb_parent(sc.root) then st.flags = st.flags + 4 end   -- bit2 at root
  eon_fb.scan = nil
end

-- PLACES. Published as ordinary rows with kind 3, so the face needs no second
-- format and no extra band -- it draws them like folders and clicking one goes
-- there. Source is the BIG browser's own settings file: two browsers, one idea,
-- and you never set your folders up twice.
function eon_fb_places(st)
  local ent = {}
  local f = io.open(reaper.GetResourcePath() .. eon_fb_sep .. "Data" ..
                    eon_fb_sep .. "EON_Swing" .. eon_fb_sep ..
                    "Swing_Browser_Settings.lua", "r")
  if f then
    local body = f:read("a"); f:close()
    local chunk = load("return " .. (body:match("return%s*(%b{})") or "{}"), "fb", "t", {})
    local ok, t = pcall(chunk)
    if ok and type(t) == "table" then
      for _, fav in ipairs(t.favorites or {}) do
        local pth = eon_fb_norm(fav.path)
        if pth then
          ent[#ent+1] = { name = fav.name or eon_fb_leaf(pth), kind = 3,
                          plkind = 1, ext = "", path = pth }   -- 1 = starred
        end
      end
      for _, r in ipairs(t.recent_folders or {}) do
        local pth = eon_fb_norm(r)
        -- a folder can be both a favourite and recent; show it once
        local dupe = false
        for _, e in ipairs(ent) do if e.path == pth then dupe = true break end end
        if pth and not dupe then
          ent[#ent+1] = { name = eon_fb_place_label(pth), kind = 3,
                          plkind = 2, ext = "", path = pth }   -- 2 = recent
        end
      end
    end
  end
  -- Always offer the drive roots, so an empty settings file is still navigable
  -- rather than a dead end. ⚠️ This used to be a hardcoded { C:, D:, E: } --
  -- an external drive on F: or G: was simply unreachable from PLACES.
  for _, root in ipairs(eon_fb_drives()) do
    ent[#ent+1] = { name = root, kind = 3, plkind = 3, ext = "", path = root }  -- 3 = drive
  end
  st.entries = ent
  st.ndirs   = #ent
  st.cwd     = nil          -- so leaving places re-scans whatever we go to
  st.places  = true
  st.fav     = false      -- the places list itself is not a folder
  st.gen     = st.gen + 1
  -- bit2 = "nowhere to go up to". The places list has no parent, and without
  -- this the up-arrow would look live and then do nothing when clicked.
  -- bit2 = nowhere to go up to; bit4 = "this is the places list", so the face
  -- can say what it is. A feature the user has to ask about is not finished.
  st.flags   = ((#ent == 0) and 2 or 0) + 4 + 16
end

function eon_fb_leaf(pth)
  return pth:match("([^/" .. eon_fb_bs .. "]+)[/" .. eon_fb_bs .. "]*$") or pth
end

-- A recent folder shown by its LAST component alone is often useless: a library
-- of six kits has six folders called "Snare". Show parent/leaf so the entry
-- says which one it is.
function eon_fb_place_label(pth)
  local leaf = eon_fb_leaf(pth)
  local up   = eon_fb_parent(pth)
  local par  = up and eon_fb_leaf(up)
  -- Skip the parent when it IS the drive ("C:\samples" needs no "C: /" prefix)
  if par and not par:match("^%a:$") and par ~= leaf then
    -- keep it inside the row's 48 chars: trim the parent, never the leaf
    if #par > 22 then par = par:sub(1, 21) .. "~" end
    return par .. " / " .. leaf
  end
  return leaf
end

-- Read the shared settings table once. Callers cache the result: this opens and
-- parses a file, and it must never sit on a per-publish path.
function eon_fb_settings_path()
  return reaper.GetResourcePath() .. eon_fb_sep .. "Data" .. eon_fb_sep ..
         "EON_Swing" .. eon_fb_sep .. "Swing_Browser_Settings.lua"
end

function eon_fb_settings_read()
  local f = io.open(eon_fb_settings_path(), "r")
  if not f then return {} end
  local body = f:read("a"); f:close()
  local chunk = load("return " .. (body:match("return%s*(%b{})") or "{}"), "fb", "t", {})
  if not chunk then return {} end
  local ok, t = pcall(chunk)
  return (ok and type(t) == "table") and t or {}
end

-- Serialise ANY value the settings table holds, nested tables included.
-- ⚠️ The previous version wrote back only top-level scalars, so a table key the
-- big browser might add later would have been silently DROPPED on every star.
-- That file holds 20+ of its settings; losing one would look like a random
-- preference reset with nothing to trace it to.
-- ⚠️ Newlines are string.char(10), never an escape: this file gets edited through
-- tooling that has twice cooked a backslash-n into a real line break.
function eon_fb_ser(v, indent)
  local NL = string.char(10)
  if type(v) == "string"  then return string.format("%q", v) end
  if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
  if type(v) ~= "table"   then return "nil" end
  local pad, out = string.rep("  ", indent), { "{" }
  local n = #v
  for i = 1, n do
    out[#out + 1] = pad .. "  " .. eon_fb_ser(v[i], indent + 1) .. ","
  end
  local keys = {}
  for k in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  for _, k in ipairs(keys) do
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      out[#out + 1] = pad .. "  " .. k .. " = " .. eon_fb_ser(v[k], indent + 1) .. ","
    end
  end
  out[#out + 1] = pad .. "}"
  return table.concat(out, NL)
end

-- Star or unstar st.cwd. Returns the new state.
-- ⚠️ Swing_Browser_Settings.lua is REWRITTEN WHOLESALE by the big browser at
-- runtime (wiki 11.3), so this read-modify-writes at click time and the big
-- browser wins any race. Rare, user-initiated, recoverable by starring again --
-- but nothing that must survive should live in this file.
-- Remove one starred folder by PATH. The tree's roots are shown from this
-- list, so "how do I get that out of the menu" has to be answerable from the
-- rail itself and not only from whichever browser starred it.
-- ⚠️ Same caveat as eon_fb_toggle_fav: the big browser rewrites this file
-- wholesale, so this read-modify-writes at the moment of the click.
function eon_fb_unfav(path)
  local want = eon_fb_norm(path)
  if not want then return false end
  local t = eon_fb_settings_read()
  t.favorites = t.favorites or {}
  local hit
  for i, fav in ipairs(t.favorites) do
    if eon_fb_norm(fav.path) == want then hit = i break end
  end
  if not hit then return false end
  table.remove(t.favorites, hit)
  local w = io.open(eon_fb_settings_path(), "w")
  if w then
    w:write("return " .. eon_fb_ser(t, 0))
    w:write(string.char(10))
    w:close()
  end
  return true
end

function eon_fb_toggle_fav(st)
  if not st.cwd then return false end
  local t = eon_fb_settings_read()
  t.favorites = t.favorites or {}
  local hit
  for i, fav in ipairs(t.favorites) do
    if eon_fb_norm(fav.path) == st.cwd then hit = i break end
  end
  if hit then
    table.remove(t.favorites, hit)
  else
    t.favorites[#t.favorites + 1] = { path = st.cwd, name = eon_fb_leaf(st.cwd) }
  end
  local w = io.open(eon_fb_settings_path(), "w")
  if w then
    w:write("return " .. eon_fb_ser(t, 0))
    w:write(string.char(10))
    w:close()
  end
  st.fav = not hit
  return st.fav
end

-- Recompute the cached star state. Called only when it can actually change:
-- a scan finishing, or the star being clicked. NOT from publish.
function eon_fb_refresh_fav(st)
  st.fav = false
  if not st.cwd then return end
  for _, fav in ipairs(eon_fb_settings_read().favorites or {}) do
    if eon_fb_norm(fav.path) == st.cwd then st.fav = true; return end
  end
end

-- ── publish ─────────────────────────────────────────────────────────────────
function eon_fb_publish(slot, answering)
  local B  = core.SWBROWSE
  local st = eon_fb_slot(slot)
  local b  = B.BASE + slot * B.STRIDE
  -- The filter builds a VIEW of indices, never a new entry list: a published
  -- row's handle must keep pointing into the REAL listing, or the moment a
  -- filter is on, clicking a row would load whatever happened to sit at that
  -- position unfiltered. (FR_RIDX is documented as exactly this.)
  st.view = nil
  if st.filter and st.filter ~= "" then
    local pat = st.filter:lower()
    st.view = {}
    for i, e in ipairs(st.entries) do
      -- folders and the parent row always survive, or a filter would trap you
      -- in the folder you are standing in with no way back out.
      if e.kind ~= 0 or e.name:lower():find(pat, 1, true) then st.view[#st.view + 1] = i end
    end
  end
  local total = st.view and #st.view or #st.entries
  local off = math.max(0, math.min(math.max(0, total - 1), math.floor(st.off or 0)))
  local n   = math.max(0, math.min(B.REC_MAX, math.floor(st.n or 0)))
  if off + n > total then n = math.max(0, total - off) end

  -- Seed the counter from the BAND, not from 1. Restarting the bridge makes
  -- fresh locals, and republishing with a seq the face already consumed leaves
  -- it sitting on pre-restart rows forever while the heartbeat says "alive".
  -- (EON_FXPicker_Bridge.publish learned this the hard way.)
  st.pub_seq = st.pub_seq or math.floor((reaper.gmem_read(b + B.PUB_SEQ) or 0) / 2)
  st.pub_seq = st.pub_seq + 1
  local seq = st.pub_seq * 2
  reaper.gmem_write(b + B.PUB_SEQ, seq - 1)        -- ODD = mid-write

  for i = 0, n - 1 do
    local vi = st.view and st.view[off + i + 1] or (off + i + 1)
    local e  = st.entries[vi]
    local p  = b + B.ROWS + i * B.REC
    local nm = eon_fb_fold(e.name)
    local ln = math.min(B.FR_NAME_MAX, #nm)
    reaper.gmem_write(p + B.FR_LEN, ln)
    for c = 1, ln do reaper.gmem_write(p + B.FR_NAME + c - 1, nm:byte(c)) end
    reaper.gmem_write(p + B.FR_KIND, e.kind)
    reaper.gmem_write(p + B.FR_EXT,  core.SWBROWSE_EXT[e.ext] or 0)
    reaper.gmem_write(p + B.FR_RIDX, vi - 1)       -- handle into the REAL list
    reaper.gmem_write(p + B.FR_SIZE_KB, e.size_kb or 0)
    -- SR/CH/MS stay 0 on purpose: per-row probing would open every file in the
    -- folder. Poise puts detail in a bottom status line for the SELECTED file
    -- only, and that is the cheap shape — fill these for one row on demand.
    reaper.gmem_write(p + B.FR_SR, e.sr or 0)
    reaper.gmem_write(p + B.FR_CH, e.ch or 0)
    reaper.gmem_write(p + B.FR_MS, e.ms or 0)
    reaper.gmem_write(p + B.FR_PLKIND, e.plkind or 0)
  end
  -- Blank the tail, or a shorter page leaves the previous page showing under it.
  for i = n, B.REC_MAX - 1 do
    reaper.gmem_write(b + B.ROWS + i * B.REC + B.FR_LEN, 0)
  end

  -- Keep the TAIL, not the head. A deep library path overruns 128 chars easily
  -- and the half that identifies where you are is the deepest folders, not the
  -- drive letter. Head-truncation also makes two different folders publish the
  -- SAME string, which is exactly how the first probe run mis-reported "did not
  -- move" on a navigation that had in fact worked.
  -- ⚠️ Never a "..." prefix. Three dots read as an overflow MENU, and the user
  -- asked what the button at the top did -- it was not a button at all.
  -- A path that will not fit becomes "parent / leaf", which reads as a place.
  local cwd = st.places and "PLACES" or eon_fb_fold(st.cwd or "")
  if #cwd > 34 and st.cwd and not st.places then
    cwd = eon_fb_fold(eon_fb_place_label(st.cwd))
  end
  if #cwd > B.CWD_MAX then cwd = cwd:sub(#cwd - B.CWD_MAX + 1) end
  local cl  = math.min(B.CWD_MAX, #cwd)
  reaper.gmem_write(b + B.CWD_LEN, cl)
  for c = 1, cl do reaper.gmem_write(b + B.CWD + c - 1, cwd:byte(c)) end

  reaper.gmem_write(b + B.TOTAL,   total)
  reaper.gmem_write(b + B.WIN_OFF, off)
  reaper.gmem_write(b + B.WIN_N,   n)
  reaper.gmem_write(b + B.NDIRS,   st.ndirs or 0)
  -- bit3 = this folder is a favourite, so the star can show its state
  -- bit3 from the CACHED flag. Calling the disk here would parse the settings
  -- file on every publish -- once per keystroke while filtering.
  reaper.gmem_write(b + B.FLAGS, (st.flags or 0) + (st.fav and 8 or 0)
                    + ((st.hist and #st.hist > 0) and 32 or 0))
  reaper.gmem_write(b + B.ANS_REQ, answering or 0)
  reaper.gmem_write(b + B.GEN,     st.gen)
  reaper.gmem_write(b + B.FMT_VER, 1)
  reaper.gmem_write(b + B.PUB_SEQ, seq)            -- EVEN, written LAST
end

-- Detail for ONE row. Doing this per row at publish time would open every file
-- in the folder; the bottom status line exists precisely so a single file can be
-- described properly instead of all of them thinly. Cached on the entry.
function eon_fb_describe(st, ridx)
  local e = st.entries[ridx + 1]
  if not e or e.kind ~= 0 or e.described then return end
  e.described = true          -- set FIRST: a source that will not open must not
                              -- be retried on every click
  local src = reaper.PCM_Source_CreateFromFile(e.path)
  if src then
    e.sr = math.floor(reaper.GetMediaSourceSampleRate(src) or 0)
    e.ch = reaper.GetMediaSourceNumChannels(src) or 0
    local len, isqn = reaper.GetMediaSourceLength(src)
    -- A QN length is a tempo multiple, not seconds. Nothing here should be, but
    -- publishing it as milliseconds would be a lie rather than a rounding error.
    e.ms = (not isqn) and math.floor((len or 0) * 1000) or 0
    reaper.PCM_Source_Destroy(src)
  end
  local f = io.open(e.path, "rb")
  if f then e.size_kb = math.floor(f:seek("end") / 1024); f:close() end
end

-- Peaks for ONE row, straight into the peaks band. Called only from describe,
-- so this is one file open per SELECTION and nothing per row -- a folder of 900
-- samples still opens exactly one file.
function eon_fb_peaks(slot, path, ms)
  local B = core.SWBROWSE
  local pb = core.SWBROWSE.PK_BASE + slot * core.SWBROWSE.PK_STRIDE
  local n  = core.SWBROWSE.PK_N
  for i = 0, n * 4 - 1 do reaper.gmem_write(pb + i, 0) end   -- clear first, so a
                                                            -- failure shows as flat
                                                            -- rather than as the
                                                            -- previous file
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return end
  local secs = (ms or 0) / 1000
  if secs > 0 then
    -- peakrate is columns per second: ask for exactly the n we can draw
    -- ⭐ TWO channels when the file has them. Folding a stereo sample to one
    -- lane threw away exactly what you open a stereo sample to look at.
    local nch = math.max(1, math.min(2, reaper.GetMediaSourceNumChannels(src) or 1))
    local buf = reaper.new_array(n * nch * 3)
    buf.clear()
    local got = reaper.PCM_Source_GetPeaks(src, n / secs, 0, nch, n, 0, buf)
    -- ⚠️⚠️ A file REAPER has never touched has no .reapeaks yet, and GetPeaks
    -- then hands back silence -- which drew as a flat line with correct length
    -- and size beside it. That is the "sometimes it shows nothing": it depended
    -- entirely on whether that sample had been used in a project before.
    -- Build them once, bounded, then ask again. Short samples finish instantly;
    -- the guard stops a long file from stalling the tick.
    local flat = true
    if got and got > 0 then
      local probe = buf.table(1, n * 2)
      for i = 1, n * 2 do
        if (probe[i] or 0) ~= 0 then flat = false break end
      end
    end
    if flat and reaper.PCM_Source_BuildPeaks then
      reaper.PCM_Source_BuildPeaks(src, 0)
      local guard = 0
      while guard < 400 do
        -- ⚠️ `~= 0` alone treats a NIL return as "not finished" and burns the
        -- whole guard on every flat file. Anything that is not a positive
        -- number means there is nothing left to build.
        local more = reaper.PCM_Source_BuildPeaks(src, 1)
        if type(more) ~= "number" or more <= 0 then break end
        guard = guard + 1
      end
      reaper.PCM_Source_BuildPeaks(src, 2)
      buf.clear()
      got = reaper.PCM_Source_GetPeaks(src, n / secs, 0, 1, n, 0, buf)
    end
    if got and got > 0 then
      -- ⚠️ Layout is [maxima, channels INTERLEAVED][minima, interleaved], so a
      -- stereo read is L,R,L,R... and the stride is nch, not 1.
      local t = buf.table(1, n * nch * 2)
      for i = 0, n - 1 do
        reaper.gmem_write(pb + i,         t[i * nch + 1] or 0)
        reaper.gmem_write(pb + n + i,     t[n * nch + i * nch + 1] or 0)
        if nch > 1 then
          reaper.gmem_write(pb + 2 * n + i, t[i * nch + 2] or 0)
          reaper.gmem_write(pb + 3 * n + i, t[n * nch + i * nch + 2] or 0)
        end
      end
    end
  end
  reaper.PCM_Source_Destroy(src)
end

-- ── requests ────────────────────────────────────────────────────────────────
function eon_fb_handle_req(slot)
  local B  = core.SWBROWSE
  local st = eon_fb_slot(slot)
  local b  = B.BASE + slot * B.STRIDE
  local rs = math.floor(reaper.gmem_read(b + B.REQ_SEQ) or 0)
  if rs == 0 or rs == st.req_seen then return false end
  st.req_seen = rs
  st.active   = true

  local verb = math.floor(reaper.gmem_read(b + B.REQ_VERB) or 0)
  local ridx = math.floor(reaper.gmem_read(b + B.REQ_RIDX) or 0)
  st.off = math.floor(reaper.gmem_read(b + B.REQ_OFF) or 0)
  st.n   = math.floor(reaper.gmem_read(b + B.REQ_N) or 0)

  if verb == 6 then                                 -- show places
    eon_fb_places(st)
    st.off = 0
  elseif verb == 1 then                             -- enter folder, or a place
    local e = st.entries[ridx + 1]
    if e and (e.kind == 1 or e.kind == 2 or e.kind == 3) then
      st.want = e.path; st.off = 0; st.places = false
    end
  elseif verb == 2 then                             -- up
    local up = st.cwd and eon_fb_parent(st.cwd)
    if up then st.want = up; st.off = 0 end
  elseif verb == 13 then                            -- BACK
    -- Up walks the TREE; back walks what you actually DID. They are different
    -- journeys and a browser needs both -- jumping via PLACES has no parent to
    -- go up to at all.
    st.hist = st.hist or {}
    local prev = table.remove(st.hist)
    if prev then
      st.want, st.cwd, st.off, st.places = prev, nil, 0, false
      st.nohist = true                              -- do not record the way back
    end
  elseif verb == 12 then                            -- preview ONLY, no pad load
    local e = st.entries[ridx + 1]
    if e and e.kind == 0 and e.ext ~= "sfz" then
      st.queue, st.qi = { { path = e.path, pad = -1, kind = 1 } }, 1
      st.qinst = math.floor(reaper.gmem_read(b + B.REQ_INST) or 0)
      eon_fb_describe(st, ridx)
      eon_fb_peaks(slot, e.path, e.ms)
    end
  elseif verb == 11 then                            -- star / unstar this folder
    -- ⚠️ Swing_Browser_Settings.lua is REWRITTEN WHOLESALE by the big browser at
    -- runtime (wiki 11.3). So this read-modify-writes at the moment of the
    -- click rather than caching, and if the big browser saves afterwards it
    -- wins. Rare, user-initiated, and recoverable by starring again -- but do
    -- not build anything on this file that has to survive.
    eon_fb_toggle_fav(st)
    eon_fb_places(st)                               -- reflect it immediately
    st.off = 0
  elseif verb == 10 then                            -- toggle subfolder walking
    st.want = st.cwd; st.cwd = nil; st.off = 0     -- rescan the same place
  elseif verb == 9 then                             -- set the filter text
    local n = math.floor(reaper.gmem_read(b + B.REQ_FILT_LEN) or 0)
    n = math.max(0, math.min(B.REQ_FILT_MAX, n))
    local t = {}
    for k = 0, n - 1 do
      t[#t + 1] = string.char(math.max(32, math.min(126,
        math.floor(reaper.gmem_read(b + B.REQ_FILT + k) or 32))))
    end
    st.filter = table.concat(t)
    st.off = 0
  elseif verb == 8 then                             -- load a RANGE across pads
    -- One CMD is in flight at a time (the channel is serialised and the busy
    -- guard refuses a second), so a multi-drop cannot fire N loads at once --
    -- it QUEUES them and the tick drains one per pass. Fill order matches the
    -- big browser's: consecutive pads from the one dropped on, stopping at 16.
    local cnt = math.floor(reaper.gmem_read(b + B.REQ_COUNT) or 1)
    local pad = math.floor(reaper.gmem_read(b + B.REQ_PAD) or -1)
    local ins = math.floor(reaper.gmem_read(b + B.REQ_INST) or 0)
    if pad >= 0 and pad < 16 and cnt > 0 then
      st.queue, st.qi, st.qinst = {}, 1, ins
      local n = 0
      for k = 0, cnt - 1 do
        local e = st.entries[ridx + k + 1]
        if pad + n > 15 then break end
        if e and e.kind == 0 and e.ext ~= "sfz" then
          st.queue[#st.queue + 1] = { path = e.path, pad = pad + n }
          eon_fb_describe(st, ridx + k)
          n = n + 1
        end
      end
    end
  elseif verb == 7 then                             -- stack onto a LAYER (CMD 64)
    -- Alt+drop, matching the big browser's own convention (Swing_Browser.lua
    -- :4772 -- Alt = layer on this pad, plain = replace). CMD 64 is additive:
    -- it does NOT clear the pad, and it needs an EXPLICIT layer index, so the
    -- face picks the next free one from p_layer_cnt and sends it in REQ_LAYER.
    local e   = st.entries[ridx + 1]
    local pad = math.floor(reaper.gmem_read(b + B.REQ_PAD) or -1)
    local lay = math.floor(reaper.gmem_read(b + B.REQ_LAYER) or -1)
    local ins = math.floor(reaper.gmem_read(b + B.REQ_INST) or 0)
    if e and e.kind == 0 and e.ext ~= "sfz" and pad >= 0 and pad < 16 and lay >= 0 then
      eon_fb_load_to_layer(e.path, pad, lay, ins)
    end
    eon_fb_describe(st, ridx)
    local pe = st.entries[ridx + 1]
    if pe and pe.kind == 0 then eon_fb_peaks(slot, pe.path, pe.ms) end
  elseif verb == 4 then                             -- refresh the current folder
    -- Re-list from scratch. `want ~= cwd` is what starts a scan, so clear cwd
    -- rather than setting want to the same string, which would be a no-op.
    st.want = st.cwd; st.cwd = nil
  elseif verb == 14 then                            -- reveal in the file manager
    local e = st.entries[ridx + 1]
    if e and e.path then eon_fb_reveal(e.path) end
  elseif verb == 15 then                            -- copy the path
    local e = st.entries[ridx + 1]
    -- ⚠️ Clipboard is SWS-only. Without it this is a no-op rather than an
    -- error; the menu item simply does nothing on a machine that lacks SWS.
    if e and e.path and reaper.CF_SetClipboard then
      reaper.CF_SetClipboard(e.path)
    end
  elseif verb == 5 then                             -- describe ONE row
    eon_fb_describe(st, ridx)
    local e = st.entries[ridx + 1]
    if e and e.kind == 0 then eon_fb_peaks(slot, e.path, e.ms) end
  elseif verb == 3 then                             -- load row onto a pad
    local e = st.entries[ridx + 1]
    local pad = math.floor(reaper.gmem_read(b + B.REQ_PAD) or -1)
    -- ⭐ The face sent an INDEX, not a path — so this resolves the REAL path and
    -- a non-ASCII name loads fine even though the wire folded it to '?' for
    -- display. Loading itself reuses the shipping CMD 63 route unchanged, which
    -- is why the mini browser inherits exactly the big browser's undo behaviour
    -- (measured 2026-08-29: no REAPER undo point, one level of Swing's own).
    local inst = math.floor(reaper.gmem_read(b + B.REQ_INST) or 0)
    local aud  = math.floor(reaper.gmem_read(b + B.REQ_AUD) or 0) > 0
    if e and e.kind == 0 and e.ext ~= "sfz" then
      -- Queue rather than fire: with autoload AND audition on this is TWO
      -- commands, and only one can be in flight. Pad first, so the preview
      -- never delays the thing that changes the kit.
      st.queue, st.qi, st.qinst = {}, 1, inst
      if pad >= 0 and pad < 16 then
        st.queue[#st.queue + 1] = { path = e.path, pad = pad, kind = 0 }
      end
      if aud then
        st.queue[#st.queue + 1] = { path = e.path, pad = -1, kind = 1 }
      end
    end
    -- Describe on the SAME request. The face must not fire verb 5 as well: the
    -- bridge reads REQ_SEQ once per tick, so a second bump in the same frame
    -- silently replaces the first and one of the two verbs never happens.
    eon_fb_describe(st, ridx)
    -- ⚠️ And the PEAKS. The queueing rewrite of this verb dropped this call, so
    -- a click gave you the numbers and a FLAT line -- the panel looked broken
    -- when it was simply never sent anything to draw. describe() must run first:
    -- peaks needs the duration it works out.
    local pe = st.entries[ridx + 1]
    if pe and pe.kind == 0 then eon_fb_peaks(slot, pe.path, pe.ms) end
  end
  return true
end

-- CMD 63, byte-identical to Swing_Browser.lua's load_sample_to_pad — including
-- its busy guard, which is also what stops a held-down arrow key queueing loads
-- faster than the ~60 ms each takes to finish.
-- CMD 64. Same protocol as the pad load plus GS_BROWSE_LAYER, and the same
-- INSTANCE requirement -- without it Swing ignores the command silently.
function eon_fb_load_to_layer(path, pad, layer, inst)
  local G = core.GMEM
  if math.floor(reaper.gmem_read(G.CMD)) ~= 0 then return false end
  if math.floor(reaper.gmem_read(G.LOCK)) ~= 0 then return false end
  local n = math.min(#path, G.GS_BROWSER_PATH_MAX - 1)
  for i = 0, n - 1 do reaper.gmem_write(G.GS_BROWSER_PATH + i, path:byte(i + 1)) end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, n)
  reaper.gmem_write(G.INSTANCE, inst or 0)
  reaper.gmem_write(G.GS_BROWSE_PAD, pad)
  reaper.gmem_write(G.GS_BROWSE_LAYER, layer)
  reaper.gmem_write(G.CMD, 64)
  return true
end

-- CMD 69: into the browser's own preview buffer. No pad, no undo, no kit state.
function eon_fb_load_preview(path, inst)
  local G = core.GMEM
  if math.floor(reaper.gmem_read(G.CMD)) ~= 0 then return false end
  if math.floor(reaper.gmem_read(G.LOCK)) ~= 0 then return false end
  local n = math.min(#path, G.GS_BROWSER_PATH_MAX - 1)
  for i = 0, n - 1 do reaper.gmem_write(G.GS_BROWSER_PATH + i, path:byte(i + 1)) end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, n)
  reaper.gmem_write(G.INSTANCE, inst or 0)   -- same silent-drop trap as CMD 63
  reaper.gmem_write(G.CMD, 69)
  return true
end

function eon_fb_load_to_pad(path, pad, inst)
  local G = core.GMEM
  if math.floor(reaper.gmem_read(G.CMD)) ~= 0 then return false end
  if math.floor(reaper.gmem_read(G.LOCK)) ~= 0 then return false end
  local n = math.min(#path, G.GS_BROWSER_PATH_MAX - 1)
  for i = 0, n - 1 do reaper.gmem_write(G.GS_BROWSER_PATH + i, path:byte(i + 1)) end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, n)
  -- ⚠️⚠️ WITHOUT THIS THE LOAD SILENTLY DOES NOTHING. Swing ignores a CMD 63
  -- whose INSTANCE does not match its own instance_id, so a request with no
  -- instance set is dropped by every instance -- no error, no load, no sound.
  -- Swing_Browser.lua:3091 does the same re-assert for the same reason.
  reaper.gmem_write(G.INSTANCE, inst or 0)
  reaper.gmem_write(G.GS_BROWSE_PAD, pad)
  reaper.gmem_write(G.CMD, 63)
  return true
end

-- ── tick ────────────────────────────────────────────────────────────────────
-- ── window growth ───────────────────────────────────────────────────────────
-- The strip used to take its width off the pads. It no longer has to: a
-- floating FX window CAN be widened from Lua and the JSFX canvas takes every
-- pixel of it. Measured 2026-08-29 by .dev_tests/fbwin_probe.lua -- +200 asked
-- gave canvas +200 and gfx_w +200 with the height untouched, restore was exact,
-- and the real Swing behaved identically at +300. So `@gfx 780 780` is a
-- STARTING SIZE, not an aspect lock, and the "extend like Poise" plan is real.
--
-- ⭐ The pads do not move. Growth keeps the window's LEFT edge, and the strip
-- draws at gfx_w - swing_fb_width(), so the new space appears exactly where the
-- strip goes and every pane keeps the x it already had.
--
-- ⚠️ Growth is RELATIVE, never absolute: this remembers only how much IT added
-- and gives back exactly that much, so a window the user dragged wider while
-- the strip was open keeps that size after the strip closes.
--
-- Interop: EON Floatter also sizes float windows, but only ONCE as each
-- window first appears, so it cannot fight a growth that happens later.

-- param 3 = slider4 = instance_id, the same routing key CMD 63 uses. The name
-- check is not redundant: another plugin's param 3 can hold the same number.
--
-- Resolved once and REMEMBERED: a project-wide FX walk on every open and close
-- is pure waste on a big session, and the answer changes only when the user
-- moves the plugin. The cached pair is re-validated with one GetParam before it
-- is trusted, so a deleted or reordered FX falls back to the walk instead of
-- resizing some other plugin's window.
--
-- ⚠️ Same reach as the rest of this bridge: track FX only. Swing inside a v7
-- CONTAINER, or as a take/input FX, is not found — growth simply does not
-- happen there and the strip keeps the squeeze.
function eon_fb_find_fx(inst, st)
  if not inst or inst <= 0 then return nil end
  if st and st.gfx_tr and reaper.ValidatePtr2(0, st.gfx_tr, "MediaTrack*")
     and math.floor(reaper.TrackFX_GetParam(st.gfx_tr, st.gfx_fx, 3) or 0) == inst then
    return st.gfx_tr, st.gfx_fx
  end
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0) == inst then
        local _, nm = reaper.TrackFX_GetFXName(tr, fx, "")
        if nm and nm:find("Swing", 1, true) then
          if st then st.gfx_tr, st.gfx_fx = tr, fx end
          return tr, fx
        end
      end
    end
  end
  if st then st.gfx_tr = nil end
end

-- CANVAS pixels per WINDOW pixel. The face asks in canvas px and this resizes
-- in window px; they are the same number today because Swing never sets
-- gfx_ext_retina -- but EON Anvil, Drum Strip and FX Return View all do, so the
-- day Swing follows, an assumed 1:1 would silently under-deliver on a scaled
-- display with nothing on screen to say why. Measuring costs one child-window
-- lookup per open and removes the assumption entirely.
function eon_fb_canvas_ratio(hw, gfxw)
  if not gfxw or gfxw <= 0 or not reaper.JS_Window_ArrayAllChild then return 1 end
  local arr = reaper.new_array({}, 256)
  local n = reaper.JS_Window_ArrayAllChild(hw, arr)
  if not n or n == 0 then return 1 end
  local t = arr.table(1, n)
  for i = 1, n do
    local h = reaper.JS_Window_HandleFromAddress(t[i])
    if h then
      -- js_ReaScriptAPI has returned the class in either slot across versions.
      local a, b2 = reaper.JS_Window_GetClassName(h, "")
      local cls = ""
      if type(a) == "string" and a ~= "" then cls = a
      elseif type(b2) == "string" then cls = b2 end
      if cls:lower():find("jsfx_gfx", 1, true) then
        local ok, l, _, r2 = reaper.JS_Window_GetRect(h)
        if ok then
          local ratio = (r2 - l) / gfxw
          -- A wild ratio means we measured the wrong thing; 1:1 is the safe read.
          if ratio > 0.5 and ratio < 4 then return ratio end
        end
        return 1
      end
    end
  end
  return 1
end

-- st.grow_want = the last request acted on (so a steady state costs nothing).
-- st.grown     = px actually ADDED to the window, and therefore the only px
--                this is ever entitled to take back.
function eon_fb_grow(slot, st, want)
  want = math.floor(math.max(0, math.min(1000, want or 0)) + 0.5)
  -- FIRST SIGHT: adopt without acting. A bridge restart finds the window
  -- already wide and the face still asking for width; growing again would
  -- double it. Under-growing (bridge died mid-open) only shows the old squeeze
  -- until the strip is toggled -- self-healing, unlike a runaway.
  if st.grow_want == nil then st.grow_want = want; st.grown = want; return end
  if want == st.grow_want then return end
  -- ⚠️ RATE LIMIT, as insurance rather than as a fix. The face's request is a
  -- constant now, so this should never bite -- but a request that somehow
  -- oscillates must not turn into a window resize on every tick, which is what
  -- made docking Swing and Steppa stiff. Note it does NOT consume the request:
  -- grow_want is left alone so the change still lands, just a tick or two later.
  if st.grow_at and (eon_fb.hb - st.grow_at) % 1000000 < 8 then return end
  st.grow_at   = eon_fb.hb
  st.grow_want = want
  if not reaper.JS_Window_SetPosition then return end   -- no extension: squeeze

  local B    = core.SWBROWSE
  local b    = B.BASE + slot * B.STRIDE
  local inst = math.floor(reaper.gmem_read(b + B.REQ_INST) or 0)
  local tr, fx = eon_fb_find_fx(inst, st)
  local hw = tr and reaper.TrackFX_GetFloatingWindow(tr, fx)
  -- A float captured into a dock or a Hub pane still EXISTS but is hidden and
  -- reparented (see eon_fx_float_visible) -- resizing it would fight its
  -- container. Docked and TCP-embedded instances keep the squeeze instead,
  -- which on the RIGHT edge reads as the pads giving up width rather than as
  -- the overlap the left-side version produced.
  if not hw or (reaper.JS_Window_IsVisible and not reaper.JS_Window_IsVisible(hw)) then
    -- Disown: we cannot act on this window, so we are owed nothing back. Cost
    -- of the corner (dock while the strip is open, then close it) is one extra
    -- strip toggle, not a window that shrinks by width it never gained.
    st.grown = 0
    return
  end

  -- Bookkeeping stays in CANVAS px -- the face's own language -- and only the
  -- resize converts to window px. That also keeps the first-sight adopt honest:
  -- it runs with no window handle and so has nothing to measure a ratio with.
  local gfxw  = math.floor(reaper.gmem_read(b + B.REQ_GFXW) or 0)
  local delta = math.floor((want - (st.grown or 0)) * eon_fb_canvas_ratio(hw, gfxw) + 0.5)
  if delta == 0 then return end
  local ok, l, t, rt, bt = reaper.JS_Window_GetRect(hw)
  if not ok then return end
  local w, h = rt - l, bt - t
  local nw = w + delta
  if nw < 200 then return end          -- refuse to shrink into nothing
  local nl = l
  -- Keep it on screen: the window grows rightward, so on a window already near
  -- the edge the newly-created space -- which is exactly where the strip draws
  -- -- would be the part that fell off the monitor.
  if reaper.JS_Window_GetViewportFromRect then
    local vl, _, vr = reaper.JS_Window_GetViewportFromRect(l, t, l + nw, t + h, true)
    if vr and nl + nw > vr then nl = math.max(vl or nl, vr - nw) end
  end
  reaper.JS_Window_SetPosition(hw, nl, t, nw, h)
  st.grown = want
end

-- ── folder tree ─────────────────────────────────────────────────────────────
-- The rail beside the file list: the folder you are in, and everything under
-- it, expandable. The list follows the tree; the tree does NOT follow the list,
-- so opening a pack does not throw away where you were.
--
-- ⚠️⚠️ THE ONE RULE THIS IS BUILT AROUND: REAPER's directory listing cache is
-- SINGLE-SLOT (probe 1, 2026-08-29 — alternating two folders re-lists one of
-- them on every call, 100x slower on a 5000-entry directory). So expansion
-- costs exactly ONE directory per tick, and never runs while the file scanner
-- holds the enumerator. For the same reason there is NO has-children probe per
-- row: every unexpanded folder shows a twisty and expanding reveals emptiness.
-- Probing 40 visible rows would BE the pathological case, and it is what the
-- big browser's has_children() is suspected of doing already.
eon_fb_tree = { slots = {} }

function eon_fb_tree_slot(i)
  local tr = eon_fb_tree.slots[i]
  if not tr then
    tr = { root = nil, nodes = {}, vis = {}, gen = 0, off = 0,
           req_seen = 0, pub = 0, active = false, dirty = true }
    eon_fb_tree.slots[i] = tr
  end
  return tr
end

function eon_fb_tree_leaf(p)
  if not p or p == "" then return "?" end
  local n = p:match("([^/" .. eon_fb_bs .. "]+)[/" .. eon_fb_bs .. "]*$")
  return n or p
end

-- Is `p` inside `root`? Windows paths are case-insensitive, and the same folder
-- reached two ways must not re-root the tree.
-- ⚠️⚠️ The prefix must end in EXACTLY ONE separator. A drive root already
-- carries its own ("C:\"), so appending another gave "c:\\" and every path on
-- the drive tested as OUTSIDE it -- which made the tick re-root the tree on
-- every single pass, so the expansion never finished and the rail sat at one
-- row forever. Comparing against `root .. sep` also has to be a WHOLE
-- component or "C:\samples" would swallow "C:\samplesX".
function eon_fb_tree_under(p, root)
  if not p or not root then return false end
  local a, b = p:lower(), root:lower()
  if a == b then return true end
  local last = b:sub(-1)
  local pre = (last == "/" or last == eon_fb_bs) and b or (b .. eon_fb_sep:lower())
  return a:sub(1, #pre) == pre
end

-- Walk to the top of the chain: C:\samples\kits -> C:\
function eon_fb_tree_top(path)
  local p = path
  local guard = 0
  while p and guard < 64 do
    local up = eon_fb_parent(p)
    if not up or up == p then return p end
    p = up
    guard = guard + 1
  end
  return p
end

-- Every ancestor strictly BELOW `top`, down to and including `path`, in order.
function eon_fb_tree_chain(top, path)
  local out, p, guard = {}, path, 0
  while p and p:lower() ~= top:lower() and guard < 64 do
    table.insert(out, 1, p)
    local up = eon_fb_parent(p)
    if not up or up == p then break end
    p = up
    guard = guard + 1
  end
  return out
end

function eon_fb_tree_find(tr, path)
  local want = path:lower()
  for id = 1, #tr.nodes do
    if tr.nodes[id].path:lower() == want then return id end
  end
end

-- ⭐⭐ ROOTED AT THE DRIVE, not at where you happen to be standing. The first
-- build rooted the tree on the current folder, which meant the rail could only
-- ever go DEEPER -- you could not walk up, sideways, or anywhere else, and a
-- tree you cannot navigate out of is not a tree. Now the whole chain is there
-- and the folder you are in is revealed inside it.
-- The rail's TOP LEVEL: your starred folders first, then every drive.
--
-- ⭐⭐ Rooting on ONE drive was still wrong. An external drive, a second
-- internal, a network path -- none of them were reachable from the rail at all.
-- REAPER's own Media Explorer answers this with a shortcuts sidebar whose
-- entries include "My Computer"; this is the same idea, except the shortcuts
-- are the ones you already starred in the big browser, so you never set your
-- folders up twice.
-- Does this folder exist? ⚠️ NOT EnumerateSubdirectories: that answers "false"
-- for a real but EMPTY folder (an untouched Downloads), and it evicts the
-- single-slot listing cache. os.rename(p, p) succeeds for a directory that is
-- there, costs no listing, and changes nothing.
function eon_fb_dir_exists(p)
  if not p then return false end
  if os.rename(p, p) then return true end
  -- Locked or permission-odd folders can refuse the rename but still list.
  return reaper.EnumerateSubdirectories(p, 0) ~= nil
      or reaper.EnumerateFiles(p, 0) ~= nil
end

-- What a user who has starred NOTHING should still find waiting for them.
-- Modelled on REAPER's own Media Explorer shortcut list (reaper.ini
-- [reaper_explorer]: Track Templates, Project Directory, My Computer, Desktop,
-- Documents...) minus the parts that are not folders.
function eon_fb_std_places()
  local out, by_name = {}, {}
  local function add(name, p)
    if by_name[name] then return end          -- OneDrive vs local: take one
    p = p and eon_fb_norm(p)
    if p and eon_fb_dir_exists(p) then
      by_name[name] = true
      out[#out + 1] = { path = p, name = name }
    end
  end

  -- ⭐ The PROJECT first: it is the only root that changes with what you are
  -- working on, and it is where your own recordings and renders land.
  local _, fn = reaper.EnumProjects(-1, "")
  if fn and fn ~= "" then
    add("Project", fn:match("^(.*)[/" .. eon_fb_bs .. "][^/" .. eon_fb_bs .. "]+$"))
  end
  if #out == 0 then add("Project", reaper.GetProjectPath("")) end

  local home = os.getenv("USERPROFILE") or os.getenv("HOME")
  local one  = os.getenv("OneDrive")
  -- Linux first: these are the REAL paths, localised or not.
  local x = eon_fb_xdg(home)
  add("Desktop",   x.DESKTOP)
  add("Downloads", x.DOWNLOAD)
  add("Documents", x.DOCUMENTS)
  add("Music",     x.MUSIC)
  -- ⚠️ OneDrive REDIRECTS Desktop and Documents on a lot of machines -- this
  -- user's own REAPER lastdir sits under OneDrive\Desktop. Offer the redirected
  -- one first and fall back, rather than pointing at a folder nobody uses.
  if one then add("Desktop", eon_fb_join(one, "Desktop")) end
  if home then
    add("Desktop",   eon_fb_join(home, "Desktop"))
    add("Downloads", eon_fb_join(home, "Downloads"))
  end
  if one then add("Documents", eon_fb_join(one, "Documents")) end
  if home then
    add("Documents", eon_fb_join(home, "Documents"))
    add("Music",     eon_fb_join(home, "Music"))
    add("Home",      home)
  end
  return out
end

-- Order: the project, then anything YOU starred, then the standard folders,
-- then every drive ("My Computer", spelled as rows).
function eon_fb_tree_roots()
  local out, seen = {}, {}
  -- kind: 1 starred (yours, removable) · 2 standard place · 3 drive.
  -- The rail groups and icons by this, so a list of eleven rows reads as three
  -- short lists instead of one jumble.
  local function add(p, name, kind)
    p = eon_fb_norm(p)
    if not p then return end
    local k = p:lower()
    if seen[k] then return end
    seen[k] = true
    out[#out + 1] = { path = p, name = name or eon_fb_tree_leaf(p), kind = kind }
  end

  local std = eon_fb_std_places()
  if std[1] and std[1].name == "Project" then add(std[1].path, "Project", 2) end
  for _, fav in ipairs(eon_fb_settings_read().favorites or {}) do
    add(fav.path, fav.name, 1)
  end
  for _, s in ipairs(std) do
    if s.name ~= "Project" then add(s.path, s.name, 2) end
  end
  for _, d in ipairs(eon_fb_drives()) do add(d, d, 3) end
  return out
end

-- Which root holds `path`? The LONGEST match, so a starred "D:\Samples" wins
-- over the "D:\" drive entry that also contains it.
function eon_fb_tree_root_for(tr, path)
  local best, bestlen = nil, -1
  for _, id in ipairs(tr.roots or {}) do
    local rp = tr.nodes[id].path
    if eon_fb_tree_under(path, rp) and #rp > bestlen then best, bestlen = id, #rp end
  end
  return best
end

function eon_fb_tree_root(tr, path)
  tr.nodes, tr.roots = {}, {}
  for _, r in ipairs(eon_fb_tree_roots()) do
    tr.nodes[#tr.nodes + 1] = { path = r.path, name = r.name, depth = 0, parent = 0,
                                expanded = false, loaded = false, kids = {},
                                rkind = r.kind or 0 }
    tr.roots[#tr.roots + 1] = #tr.nodes
  end
  -- A drive we could not list at all leaves an empty forest; fall back to the
  -- folder we were given so the rail is never a blank panel.
  if #tr.nodes == 0 then
    local top = eon_fb_tree_top(path) or path
    tr.nodes[1] = { path = top, name = eon_fb_tree_leaf(top), depth = 0, parent = 0,
                    expanded = false, loaded = false, kids = {} }
    tr.roots[1] = 1
  end
  tr.off   = 0
  tr.gen   = tr.gen + 1
  tr.dirty = true
  tr.reveal, tr.pending = nil, nil
  if path then eon_fb_tree_reveal(tr, path) end
end

-- One step of the auto-reveal: having just loaded `nd`, is the next folder on
-- the way to the current one among its children? If so, open that and queue it.
function eon_fb_tree_advance(tr, nd)
  if not tr.reveal or #tr.reveal == 0 then tr.reveal = nil return end
  local want = tr.reveal[1]:lower()
  for _, kid in ipairs(nd.kids) do
    if tr.nodes[kid].path:lower() == want then
      table.remove(tr.reveal, 1)
      tr.nodes[kid].expanded = true
      tr.pending = kid
      return
    end
  end
  -- Not there: a hidden or unreadable folder, or one that has been renamed.
  -- Stop rather than retry forever -- the rail is still usable, it just did not
  -- open all the way down.
  tr.reveal = nil
end

-- Re-open the chain down to `cwd` using whatever is already in the tree, so
-- navigating in the LIST makes the rail follow without rebuilding it.
function eon_fb_tree_reveal(tr, cwd)
  if not cwd or not tr.roots then return end
  local rootid = eon_fb_tree_root_for(tr, cwd)
  if not rootid then return end          -- cwd is not under anything we show
  tr.reveal = eon_fb_tree_chain(tr.nodes[rootid].path, cwd)
  local startid = rootid
  for i = #tr.reveal, 1, -1 do
    local id = eon_fb_tree_find(tr, tr.reveal[i])
    if id then
      startid = id
      for _ = 1, i do table.remove(tr.reveal, 1) end
      break
    end
  end
  tr.nodes[startid].expanded = true
  tr.pending = startid
  tr.dirty   = true
end

-- ONE directory, then stop. Called once per bridge tick, and only when the file
-- scanner is not mid-walk.
function eon_fb_tree_step()
  if eon_fb.scan then return false end
  for slot = 0, core.SWBTREE.SLOTS - 1 do
    local tr = eon_fb_tree.slots[slot]
    if tr and tr.pending then
      local id = tr.pending
      tr.pending = nil
      local nd = tr.nodes[id]
      if nd then
        -- Already known? Then this is the auto-reveal passing THROUGH a folder
        -- it opened earlier. Re-enumerating would duplicate every child, so the
        -- two cases share one path out and only one of them touches the disk.
        if not nd.loaded then
          local subs, i = {}, 0
          while true do
            local d = reaper.EnumerateSubdirectories(nd.path, i)
            if not d then break end
            if not eon_fb_hide_dir(d) then subs[#subs + 1] = d end
            i = i + 1
          end
          table.sort(subs, function(a, b) return a:lower() < b:lower() end)
          nd.kids = {}
          for _, d in ipairs(subs) do
            tr.nodes[#tr.nodes + 1] = {
              path = eon_fb_join(nd.path, d), name = d,
              depth = nd.depth + 1, parent = id,
              expanded = false, loaded = false, kids = {} }
            nd.kids[#nd.kids + 1] = #tr.nodes
          end
          nd.loaded = true
        end
        eon_fb_tree_advance(tr, nd)
        tr.dirty = true
      end
      return true
    end
  end
  return false
end

function eon_fb_tree_flatten(tr)
  local vis = {}
  local function walk(id)
    vis[#vis + 1] = id
    local nd = tr.nodes[id]
    if nd and nd.expanded then
      for _, k in ipairs(nd.kids) do walk(k) end
    end
  end
  -- A FOREST, not a tree: every starred folder and every drive is a top-level
  -- row, in that order.
  for _, id in ipairs(tr.roots or {}) do walk(id) end
  tr.vis = vis
end

function eon_fb_tree_publish(slot, cwd)
  local T  = core.SWBTREE
  local tr = eon_fb_tree_slot(slot)
  local b  = T.BASE + slot * T.STRIDE
  eon_fb_tree_flatten(tr)

  local off = math.max(0, math.min(math.max(0, #tr.vis - 1), tr.off))
  local n   = math.max(0, math.min(T.REC_MAX, #tr.vis - off))
  local sel = -1

  tr.pub = (tr.pub or 0) + 1
  reaper.gmem_write(b + T.PUB_SEQ, tr.pub)          -- ODD: mid-write
  for i = 0, n - 1 do
    local id = tr.vis[off + i + 1]
    local nd = tr.nodes[id]
    local rb = b + T.ROWS + i * T.REC
    local nm = eon_fb_fold(nd.name)
    if #nm > T.TR_NAME_MAX then nm = nm:sub(1, T.TR_NAME_MAX) end
    reaper.gmem_write(rb + T.TR_LEN, #nm)
    for k = 1, #nm do reaper.gmem_write(rb + T.TR_NAME + k - 1, nm:byte(k)) end
    local is_cwd = (cwd ~= nil) and (nd.path:lower() == cwd:lower())
    if is_cwd then sel = off + i end
    reaper.gmem_write(rb + T.TR_DEPTH, nd.depth)
    -- bits 0..2 as documented; bits 3..4 carry the ROOT KIND (0 none, 1 star,
    -- 2 place, 3 drive) so the rail can group and icon its top level.
    reaper.gmem_write(rb + T.TR_FLAGS,
      (nd.expanded and 1 or 0) + (is_cwd and 2 or 0)
      + ((nd.loaded and #nd.kids == 0) and 4 or 0)
      + ((nd.rkind or 0) * 8))
    reaper.gmem_write(rb + T.TR_TIDX, id)
  end
  -- Blank the tail so a shorter tree cannot leave last frame's rows on screen.
  for i = n, T.REC_MAX - 1 do
    reaper.gmem_write(b + T.ROWS + i * T.REC + T.TR_LEN, 0)
  end
  reaper.gmem_write(b + T.TOTAL,   #tr.vis)
  reaper.gmem_write(b + T.WIN_OFF, off)
  reaper.gmem_write(b + T.WIN_N,   n)
  reaper.gmem_write(b + T.SEL,     sel)
  reaper.gmem_write(b + T.FLAGS,   tr.pending and 1 or 0)
  reaper.gmem_write(b + T.GEN,     tr.gen)
  tr.pub = tr.pub + 1
  reaper.gmem_write(b + T.PUB_SEQ, tr.pub)          -- EVEN: stable, written LAST
  tr.dirty = false
end

function eon_fb_tree_req(slot, st)
  local T  = core.SWBTREE
  local tr = eon_fb_tree_slot(slot)
  local b  = T.BASE + slot * T.STRIDE
  local rs = math.floor(reaper.gmem_read(b + T.REQ_SEQ) or 0)
  if rs == 0 or rs == tr.req_seen then return false end
  tr.req_seen = rs
  tr.active   = true

  local verb = math.floor(reaper.gmem_read(b + T.REQ_VERB) or 0)
  local tidx = math.floor(reaper.gmem_read(b + T.REQ_TIDX) or 0)
  tr.off = math.max(0, math.floor(reaper.gmem_read(b + T.REQ_OFF) or 0))

  if verb == 1 then                                  -- twisty
    local nd = tr.nodes[tidx]
    if nd then
      nd.expanded = not nd.expanded
      if nd.expanded and not nd.loaded then tr.pending = tidx end
    end
  elseif verb == 2 then                              -- point the FILE list here
    local nd = tr.nodes[tidx]
    if nd then
      st.want = nd.path; st.off = 0; st.places = false
      -- Selecting also opens it: clicking a folder and seeing nothing move is
      -- the tree's version of a dead control.
      if not nd.expanded then
        nd.expanded = true
        if not nd.loaded then tr.pending = tidx end
      end
    end
  elseif verb == 3 then                              -- (re)build from the list
    if st.cwd then eon_fb_tree_root(tr, st.cwd) end
  elseif verb == 5 then                              -- reveal this folder
    local nd = tr.nodes[tidx]
    if nd then eon_fb_reveal(nd.path) end
  elseif verb == 4 then                              -- drop this root from the rail
    local nd = tr.nodes[tidx]
    -- Only a STARRED root can be removed: a drive or a standard place is not
    -- ours to take away, and silently doing nothing is clearer than an item
    -- that appears to work and does not.
    if nd and eon_fb_unfav(nd.path) and st.cwd then
      eon_fb_tree_root(tr, st.cwd)
    end
  end
  tr.dirty = true
  return true
end

function eon_fb_tree_tick(slot, st)
  local T  = core.SWBTREE
  local tr = eon_fb_tree_slot(slot)
  eon_fb_tree_req(slot, st)
  if not tr.active then return end
  reaper.gmem_write(T.BASE + slot * T.STRIDE + T.HB, eon_fb.hb)
  -- Re-root only when the file list has walked OUT of the tree (up past the
  -- root, or a jump to a place). Navigating INSIDE it must not throw the tree
  -- away -- that is the whole reason the rail is worth having.
  if st.cwd and (not tr.roots or not eon_fb_tree_root_for(tr, st.cwd)) then
    -- Under no root we currently show: a drive that was not there when the rail
    -- was built (a stick just plugged in), or a newly starred folder. Rebuild
    -- the top level rather than leaving the folder unreachable.
    eon_fb_tree_root(tr, st.cwd)
  elseif st.cwd and st.cwd ~= tr.last_cwd then
    -- Same drive, new folder: open the chain down to it using what the tree
    -- already holds. The rail FOLLOWS the list without being rebuilt.
    eon_fb_tree_reveal(tr, st.cwd)
  end
  if st.cwd ~= tr.last_cwd then tr.last_cwd = st.cwd; tr.dirty = true end
  if tr.dirty then eon_fb_tree_publish(slot, st.cwd) end
end

function eon_fb_tick()
  local B = core.SWBROWSE
  -- ⚠ gmem_attach is last-wins / one-binding-per-Lua-state, and this bridge
  -- mirrors the theme into other FX segments mid-loop (core.publish_theme_fx_segments).
  -- That block restores GMEM_NAME itself, but this module writes a band nobody
  -- else owns -- so re-assert the segment rather than trust every future caller
  -- to have left it bound. One lookup per tick; the failure it prevents is
  -- publishing a folder listing into some other plugin's memory.
  reaper.gmem_attach(core.GMEM_NAME)
  eon_fb.hb = (eon_fb.hb + 1) % 1000000

  -- Advance the single in-flight scan first, so a slot waiting on one is served
  -- before anything else can claim the enumerator. Capture the slot BEFORE
  -- stepping: a completing step clears eon_fb.scan, and publishing the wrong
  -- slot would leave the requester staring at another instance's folder.
  if eon_fb.scan then
    local scanning = eon_fb.scan.slot
    eon_fb_scan_step()
    if not eon_fb.scan then eon_fb_publish(scanning, eon_fb_slot(scanning).req_seen) end
  else
    -- The tree expands ONE directory, and only with the enumerator free. Two
    -- folders touched in a tick is the single-slot-cache thrash probe 1 caught.
    eon_fb_tree_step()
  end

  -- Drain any multi-drop queue BEFORE handling new requests: one load per tick,
  -- and only while the CMD channel is idle. eon_fb_load_to_pad already refuses
  -- when it is busy, so a failed attempt simply retries next tick rather than
  -- dropping the file.
  for slot = 0, B.SLOTS - 1 do
    local st = eon_fb.slots[slot]
    if st and st.queue and st.qi <= #st.queue then
      local job = st.queue[st.qi]
      -- kind 1 = the browser's own PREVIEW voice (CMD 69), kind 0 = a pad load
      -- (CMD 63). Both ride this queue because ONE command is in flight at a
      -- time; a click with autoload AND audition on needs both, in order.
      -- ⚠️ NOT `cond and A or B`. Both A and B return FALSE when the command
      -- channel is busy, and `and/or` then falls through to B -- so a preview
      -- that merely had to wait was turning into a PAD LOAD with pad = -1,
      -- writing a bogus CMD 63 into a channel everything else queues behind.
      local sent
      if job.kind == 1 then
        sent = eon_fb_load_preview(job.path, st.qinst)
      else
        sent = eon_fb_load_to_pad(job.path, job.pad, st.qinst)
      end
      if sent then st.qi = st.qi + 1 end
      break                      -- one command per tick across ALL slots
    elseif st and st.queue then
      st.queue = nil             -- finished
    end
  end

  for slot = 0, B.SLOTS - 1 do
    local b  = B.BASE + slot * B.STRIDE
    local st = eon_fb.slots[slot]
    local changed = eon_fb_handle_req(slot)
    st = eon_fb.slots[slot]
    if st and st.active then
      reaper.gmem_write(b + B.HB, eon_fb.hb)
      -- Widen the window instead of squeezing the pads. Cheap at rest: this
      -- returns on the first line unless the request actually changed.
      eon_fb_grow(slot, st, reaper.gmem_read(b + B.REQ_GROW) or 0)
      eon_fb_tree_tick(slot, st)
      -- First sight of this slot: open where the big browser already points.
      -- ⚠️ `and not st.places` is LOAD-BEARING. eon_fb_places clears st.cwd (so
      -- that leaving places always rescans), and without this guard the very
      -- next tick read that as "no folder yet", scanned the default folder and
      -- WIPED the places list a frame after it appeared. The list looked like
      -- it did nothing at all.
      if not st.cwd and not st.want and not st.places then
        st.want = eon_fb_default_dir()
      end
      -- ONE folder per tick, globally — see the rule at the top of this module.
      if st.want and st.want ~= st.cwd and not eon_fb.scan then
        if eon_fb_scan_begin(slot, st.want,
             math.floor(reaper.gmem_read(b + B.REQ_RECURSE) or 0) > 0.5) then
          st.want = nil
        end
      end
      if changed then eon_fb_publish(slot, st.req_seen) end
    end
  end
end

function eon_dock_layout_tick()
  -- ⚠️ core.GMEM, not G: this function sits ABOVE the `local G = core.GMEM`
  -- declaration (~:2910), so `G` here would be a nil GLOBAL and the pcall at
  -- the call site would eat the error silently — which is exactly how this
  -- shipped broken on 2026-08-25. Same trap the :500 comment documents; the
  -- groove tick above dodges it with raw literals.
  local DLR = core.GMEM.GS_DOCK_LAYOUT_REQ
  -- First sighting after a bridge (re)start: clear without acting, so a pick
  -- posted while no bridge was running can't apply minutes later out of the
  -- blue (same baseline idiom as the groove tick above).
  if eon_dock_layout_baselined == nil then
    eon_dock_layout_baselined = true
    reaper.gmem_write(DLR, 0)
    return
  end
  local req = math.floor((reaper.gmem_read(DLR) or 0) + 0.5)
  if req <= 0 then return end
  reaper.gmem_write(DLR, 0)
  -- Ships next to this file (see eon_sibling_script) -- the dock rig is part
  -- of the bundle since 2026-09-04, not a separate install.
  local path = eon_sibling_script("EON_Dock_Layout.lua")
  local f = io.open(path, "r")
  if not f then
    reaper.ShowConsoleMsg("[EON] EON_Dock_Layout.lua not found (" .. path ..
      ")\n  The wordmark menu's DOCK LAYOUT section needs it. Reinstall Swing.\n")
    return
  end
  f:close()
  reaper.SetExtState("EON_DockView", "pick", tostring(req), false)
  local cmd_id = reaper.AddRemoveReaScript(true, 0, path, true)
  if cmd_id and cmd_id > 0 then
    reaper.Main_OnCommand(cmd_id, 0)
    -- Left registered: the dock-rig scripts tell the user to install THIS
    -- file as an action (menu item / shortcut), and this relay's old
    -- unregister is exactly what stripped it on 2026-08-26 -- see AP-4.
  end
end

-- Redock relay: a FLOATING Swing/Steppa wordmark click asks to be docked
-- (GS_REDOCK_REQ_* bump; payload cell written first). We select the target's
-- track -- the pane scripts follow selection, so pointing the selection points
-- the capture -- then launch the pane script unless its per-kind heartbeat
-- (ExtState <EXT>/alive, stamped every pane tick) says one is already running,
-- in which case the selection change alone makes the live pane swap over.
-- Launching a second captor would have two scripts fighting over one float.
function eon_redock_tick()
  -- core.GMEM, not G: this sits ABOVE `local G = core.GMEM` (~:2910) -- the
  -- same position-scoping trap the layout tick above documents.
  local GM = core.GMEM
  if eon_redock_baselined == nil then
    -- First sighting after a bridge (re)start: clear without acting, so a
    -- click posted while no bridge was running can't fire minutes later.
    eon_redock_baselined = true
    reaper.gmem_write(GM.GS_REDOCK_REQ_SWING, 0)
    reaper.gmem_write(GM.GS_REDOCK_REQ_STEPPA, 0)
    return
  end
  local function pane_alive(ext)
    local hb = tonumber(reaper.GetExtState(ext, "alive")) or 0
    return (reaper.time_precise() - hb) < 2
  end
  local function launch_pane(name)
    local path = eon_sibling_script(name)   -- ships next to this file
    local f = io.open(path, "r")
    if not f then
      reaper.ShowConsoleMsg("[EON] " .. name .. " not found (" .. path .. ")\n"
        .. "  The wordmark dock toggle needs it. Reinstall Swing.\n")
      return
    end
    f:close()
    local cmd_id = reaper.AddRemoveReaScript(true, 0, path, true)
    if cmd_id and cmd_id > 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      -- Left registered on purpose -- see the layout tick above (AP-4; the
      -- 2026-08-26 unregister bug stripped users' own registrations).
    end
  end
  local rq = math.floor(reaper.gmem_read(GM.GS_REDOCK_REQ_SWING) or 0)
  if rq > 0 then
    reaper.gmem_write(GM.GS_REDOCK_REQ_SWING, 0)
    local id = math.floor(reaper.gmem_read(GM.GS_REDOCK_ID_SWING) or 0)
    local tr = eon_padcat_track_for_slot(ss_resolve_slot(id))
    if tr then reaper.SetOnlyTrackSelected(tr) end
    if not pane_alive("EON_SwingDock") then launch_pane("EON_Swing_Dock.lua") end
  end
  rq = math.floor(reaper.gmem_read(GM.GS_REDOCK_REQ_STEPPA) or 0)
  if rq > 0 then
    reaper.gmem_write(GM.GS_REDOCK_REQ_STEPPA, 0)
    local slot = math.floor(reaper.gmem_read(GM.GS_REDOCK_SLOT_STEPPA) or -1)
    if slot >= 0 then
      local tr = eon_padcat_track_for_slot(slot)   -- paired Swing's track = Steppa's home
      if tr then reaper.SetOnlyTrackSelected(tr) end
    end
    if not pane_alive("EON_SteppaDock") then launch_pane("EON_Steppa_Dock.lua") end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- v5 KIT BUNDLE FORMAT  (Phase 2 scaffolding)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Self-contained zip-STORE bundle: kit.json manifest + pad_NN.wav files.
-- Loaded but not yet wired into the save path; the Phase 1 AUDIOLEN fix
-- unblocks v4 saves meanwhile.
--
-- Inlined here (single-file bridge) rather than a separate module so install
-- stays one file. Self-test via ExtState EON_Swing/v5_selftest = "1".
local swing_kit_v5 = (function()
  local M = {}

  -- ── JSON  (encode + decode, no external dependencies) ────────────────────
  local json = {}

  local function _json_escape_str(s)
    s = s:gsub("\\", "\\\\")
         :gsub('"',  '\\"')
         :gsub("\b", "\\b")
         :gsub("\f", "\\f")
         :gsub("\n", "\\n")
         :gsub("\r", "\\r")
         :gsub("\t", "\\t")
    s = s:gsub("[%z\1-\31]", function(c)
      return string.format("\\u%04x", c:byte())
    end)
    return s
  end

  local function _json_is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k, _ in pairs(t) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
        return false
      end
    end
    for i = 1, n do
      if t[i] == nil then return false end
    end
    return true, n
  end

  local function _json_encode(v, depth)
    depth = depth or 0
    if depth > 64 then error("json.encode: max depth exceeded") end
    local tv = type(v)
    if v == nil then
      return "null"
    elseif tv == "boolean" then
      return v and "true" or "false"
    elseif tv == "number" then
      if v ~= v then return "null" end
      if v == math.huge or v == -math.huge then return "null" end
      if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
      end
      return string.format("%.17g", v)
    elseif tv == "string" then
      return '"' .. _json_escape_str(v) .. '"'
    elseif tv == "table" then
      local is_arr, n = _json_is_array(v)
      if is_arr then
        if n == 0 then return "[]" end
        local parts = {}
        for i = 1, n do
          parts[i] = _json_encode(v[i], depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
      else
        local keys = {}
        for k, _ in pairs(v) do
          if type(k) == "string" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        if #keys == 0 then return "{}" end
        local parts = {}
        for i, k in ipairs(keys) do
          parts[i] = '"' .. _json_escape_str(k) .. '":' .. _json_encode(v[k], depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
      end
    else
      error("json.encode: unsupported type " .. tv)
    end
  end

  function json.encode(v)
    local ok, res = pcall(_json_encode, v, 0)
    if not ok then return nil, res end
    return res
  end

  local _json_decode

  local function _json_skip_ws(s, i)
    while i <= #s do
      local c = s:byte(i)
      if c == 32 or c == 9 or c == 10 or c == 13 then
        i = i + 1
      else
        return i
      end
    end
    return i
  end

  local function _json_parse_string(s, i)
    i = i + 1
    local out = {}
    while i <= #s do
      local c = s:sub(i, i)
      if c == '"' then
        return table.concat(out), i + 1
      elseif c == "\\" then
        local nc = s:sub(i + 1, i + 1)
        if nc == "n" then out[#out+1] = "\n"; i = i + 2
        elseif nc == "t" then out[#out+1] = "\t"; i = i + 2
        elseif nc == "r" then out[#out+1] = "\r"; i = i + 2
        elseif nc == "b" then out[#out+1] = "\b"; i = i + 2
        elseif nc == "f" then out[#out+1] = "\f"; i = i + 2
        elseif nc == '"' then out[#out+1] = '"';  i = i + 2
        elseif nc == "\\" then out[#out+1] = "\\"; i = i + 2
        elseif nc == "/" then out[#out+1] = "/"; i = i + 2
        elseif nc == "u" then
          local hex = s:sub(i + 2, i + 5)
          if not hex:match("^%x%x%x%x$") then
            error("json.decode: bad \\u escape at " .. i)
          end
          local code = tonumber(hex, 16)
          if code < 0x80 then
            out[#out+1] = string.char(code)
          elseif code < 0x800 then
            out[#out+1] = string.char(0xC0 + math.floor(code / 0x40),
                                     0x80 + (code % 0x40))
          else
            out[#out+1] = string.char(0xE0 + math.floor(code / 0x1000),
                                     0x80 + math.floor((code % 0x1000) / 0x40),
                                     0x80 + (code % 0x40))
          end
          i = i + 6
        else
          error("json.decode: bad escape \\" .. nc .. " at " .. i)
        end
      else
        out[#out+1] = c
        i = i + 1
      end
    end
    error("json.decode: unterminated string")
  end

  local function _json_parse_number(s, i)
    local j = i
    if s:sub(j, j) == "-" then j = j + 1 end
    while j <= #s do
      local c = s:byte(j)
      if (c >= 48 and c <= 57) or c == 46 or c == 43 or c == 45 or c == 69 or c == 101 then
        j = j + 1
      else
        break
      end
    end
    local num = tonumber(s:sub(i, j - 1))
    if not num then error("json.decode: bad number at " .. i) end
    return num, j
  end

  local function _json_parse_array(s, i)
    i = _json_skip_ws(s, i + 1)
    local arr = {}
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while i <= #s do
      local v
      v, i = _json_decode(s, i)
      arr[#arr + 1] = v
      i = _json_skip_ws(s, i)
      local c = s:sub(i, i)
      if c == "," then
        i = _json_skip_ws(s, i + 1)
      elseif c == "]" then
        return arr, i + 1
      else
        error("json.decode: expected , or ] at " .. i)
      end
    end
    error("json.decode: unterminated array")
  end

  local function _json_parse_object(s, i)
    i = _json_skip_ws(s, i + 1)
    local obj = {}
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while i <= #s do
      if s:sub(i, i) ~= '"' then
        error("json.decode: expected string key at " .. i)
      end
      local key
      key, i = _json_parse_string(s, i)
      i = _json_skip_ws(s, i)
      if s:sub(i, i) ~= ":" then
        error("json.decode: expected : at " .. i)
      end
      i = _json_skip_ws(s, i + 1)
      local val
      val, i = _json_decode(s, i)
      obj[key] = val
      i = _json_skip_ws(s, i)
      local c = s:sub(i, i)
      if c == "," then
        i = _json_skip_ws(s, i + 1)
      elseif c == "}" then
        return obj, i + 1
      else
        error("json.decode: expected , or } at " .. i)
      end
    end
    error("json.decode: unterminated object")
  end

  _json_decode = function(s, i)
    i = _json_skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then return _json_parse_object(s, i)
    elseif c == "[" then return _json_parse_array(s, i)
    elseif c == '"' then return _json_parse_string(s, i)
    elseif c == "-" or (c >= "0" and c <= "9") then return _json_parse_number(s, i)
    elseif s:sub(i, i + 3) == "true"  then return true,  i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null"  then return nil,   i + 4
    end
    error("json.decode: unexpected char '" .. c .. "' at " .. i)
  end

  function json.decode(text)
    if type(text) ~= "string" then return nil, "expected string" end
    local ok, val_or_err = pcall(function()
      local v, ni = _json_decode(text, 1)
      return v, ni
    end)
    if not ok then return nil, tostring(val_or_err) end
    return val_or_err
  end

  M.json = json

  -- ── WAV  (RIFF 16-bit PCM read/write) ────────────────────────────────────
  local wav = {}

  local function _le16(n)
    n = n & 0xFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF)
  end

  local function _le32(n)
    n = n & 0xFFFFFFFF
    return string.char(n & 0xFF, (n >> 8) & 0xFF, (n >> 16) & 0xFF, (n >> 24) & 0xFF)
  end

  local function _read_le16(s, i)
    local b1, b2 = s:byte(i, i + 1)
    local v = b1 | (b2 << 8)
    if v >= 0x8000 then v = v - 0x10000 end
    return v
  end

  local function _read_u16(s, i)
    local b1, b2 = s:byte(i, i + 1)
    return b1 | (b2 << 8)
  end

  local function _read_u32(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24)
  end

  -- samples: array of int16 (-32768..32767), interleaved if stereo
  function wav.write_int16(samples, sample_rate, channels)
    if type(samples) ~= "table" then return nil, "samples must be a table" end
    channels = channels or 2
    sample_rate = math.floor(sample_rate or 44100)
    local n = #samples
    local data_size = n * 2
    local byte_rate = sample_rate * channels * 2
    local block_align = channels * 2

    local parts = {}
    local chunk = {}
    for i = 1, n do
      local s = samples[i]
      if s < -32768 then s = -32768 elseif s > 32767 then s = 32767 end
      if s < 0 then s = s + 0x10000 end
      chunk[#chunk + 1] = string.char(s & 0xFF, (s >> 8) & 0xFF)
      if #chunk >= 8192 then
        parts[#parts + 1] = table.concat(chunk)
        chunk = {}
      end
    end
    if #chunk > 0 then parts[#parts + 1] = table.concat(chunk) end
    local pcm = table.concat(parts)

    local header =
      "RIFF" .. _le32(36 + data_size) .. "WAVE" ..
      "fmt " .. _le32(16) ..
        _le16(1) ..
        _le16(channels) ..
        _le32(sample_rate) ..
        _le32(byte_rate) ..
        _le16(block_align) ..
        _le16(16) ..
      "data" .. _le32(data_size)
    return header .. pcm
  end

  -- Returns: samples, sample_rate, channels, err. PCM 16-bit only.
  function wav.read(bytes)
    if type(bytes) ~= "string" or #bytes < 44 then
      return nil, nil, nil, "wav: too short"
    end
    if bytes:sub(1, 4) ~= "RIFF" or bytes:sub(9, 12) ~= "WAVE" then
      return nil, nil, nil, "wav: not RIFF/WAVE"
    end
    local i = 13
    local fmt_found, data_off, data_len = false, nil, nil
    local channels, sample_rate, bits_per_sample, format_code
    while i + 8 <= #bytes do
      local id = bytes:sub(i, i + 3)
      local sz = _read_u32(bytes, i + 4)
      local body = i + 8
      if id == "fmt " then
        format_code     = _read_u16(bytes, body)
        channels        = _read_u16(bytes, body + 2)
        sample_rate     = _read_u32(bytes, body + 4)
        bits_per_sample = _read_u16(bytes, body + 14)
        fmt_found = true
      elseif id == "data" then
        data_off, data_len = body, sz
        break
      end
      i = body + sz
      if sz % 2 == 1 then i = i + 1 end
    end
    if not fmt_found then return nil, nil, nil, "wav: no fmt chunk" end
    if not data_off  then return nil, nil, nil, "wav: no data chunk" end
    if format_code ~= 1 then
      return nil, nil, nil, "wav: not PCM (format " .. tostring(format_code) .. ")"
    end
    if bits_per_sample ~= 16 then
      return nil, nil, nil, "wav: only 16-bit supported (got " .. tostring(bits_per_sample) .. ")"
    end
    if channels ~= 1 and channels ~= 2 then return nil, nil, nil, "wav: unsupported channels" end

    -- Clamp the declared data length to the bytes actually present. A header
    -- is free to claim data_len = 0xFFFFFFFF; iterating that would build a
    -- ~2-billion-entry samples table (OOM) and read past EOF. After this
    -- clamp the table is bounded by the real file size.
    local data_avail = #bytes - data_off + 1
    if data_len > data_avail then data_len = math.max(0, data_avail) end

    local frames = math.floor(data_len / (channels * 2))
    local total  = frames * channels
    local samples = {}
    for k = 0, total - 1 do
      samples[k + 1] = _read_le16(bytes, data_off + k * 2)
    end
    return samples, sample_rate, channels, nil
  end

  M.wav = wav

  -- ── ZIP-STORE  (no compression — STORE method only) ──────────────────────
  -- Format: PKZIP appnote.txt sections 4.3.6–4.4. Little-endian throughout.
  -- Method 0 (STORE). CRC-32 computed over uncompressed data.
  local zip = {}

  local _crc_tbl = {}
  do
    for i = 0, 255 do
      local c = i
      for _ = 1, 8 do
        if c & 1 == 1 then
          c = (c >> 1) ~ 0xEDB88320
        else
          c = c >> 1
        end
      end
      _crc_tbl[i] = c
    end
  end

  local function _crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
      c = (c >> 8) ~ _crc_tbl[((c ~ s:byte(i)) & 0xFF)]
    end
    return (c ~ 0xFFFFFFFF) & 0xFFFFFFFF
  end

  zip.crc32 = _crc32

  -- Hard-coded DOS time/date (2026-01-01 00:00) — metadata only.
  local _DOS_TIME = 0
  local _DOS_DATE = ((2026 - 1980) << 9) | (1 << 5) | 1

  -- entries = { {name="kit.json", data="..."}, {name="pad_01.wav", data="..."}, ... }
  function zip.write(entries)
    if type(entries) ~= "table" then return nil, "entries must be a table" end

    local parts = {}
    local cdir  = {}
    local offset = 0

    for _, e in ipairs(entries) do
      local name = e.name
      local data = e.data or ""
      if type(name) ~= "string" or name == "" then
        return nil, "entry missing name"
      end
      local name_bytes = #name
      local size = #data
      local crc = _crc32(data)

      local lfh =
        "\x50\x4B\x03\x04" ..
        _le16(20) .. _le16(0) .. _le16(0) ..
        _le16(_DOS_TIME) .. _le16(_DOS_DATE) ..
        _le32(crc) .. _le32(size) .. _le32(size) ..
        _le16(name_bytes) .. _le16(0) ..
        name

      parts[#parts + 1] = lfh
      parts[#parts + 1] = data

      cdir[#cdir + 1] =
        "\x50\x4B\x01\x02" ..
        _le16(20) .. _le16(20) .. _le16(0) .. _le16(0) ..
        _le16(_DOS_TIME) .. _le16(_DOS_DATE) ..
        _le32(crc) .. _le32(size) .. _le32(size) ..
        _le16(name_bytes) .. _le16(0) .. _le16(0) ..
        _le16(0) .. _le16(0) .. _le32(0) .. _le32(offset) ..
        name

      offset = offset + #lfh + size
    end

    local cdir_offset = offset
    local cdir_concat = table.concat(cdir)
    parts[#parts + 1] = cdir_concat

    local eocd =
      "\x50\x4B\x05\x06" ..
      _le16(0) .. _le16(0) ..
      _le16(#cdir) .. _le16(#cdir) ..
      _le32(#cdir_concat) .. _le32(cdir_offset) ..
      _le16(0)
    parts[#parts + 1] = eocd

    return table.concat(parts)
  end

  -- Returns: { {name=..., data=...}, ... }, err. STORE only.
  function zip.read(bytes)
    if type(bytes) ~= "string" or #bytes < 22 then
      return nil, "zip: too short"
    end

    local eocd_off
    for i = #bytes - 21, math.max(1, #bytes - 65557), -1 do
      if bytes:sub(i, i + 3) == "\x50\x4B\x05\x06" then
        eocd_off = i
        break
      end
    end
    if not eocd_off then return nil, "zip: no EOCD record" end

    local total_entries = _read_u16(bytes, eocd_off + 10)
    local cdir_size     = _read_u32(bytes, eocd_off + 12)
    local cdir_off      = _read_u32(bytes, eocd_off + 16)

    if cdir_off + cdir_size > #bytes then
      return nil, "zip: truncated central directory"
    end

    local entries = {}
    local p = cdir_off + 1

    for _ = 1, total_entries do
      if bytes:sub(p, p + 3) ~= "\x50\x4B\x01\x02" then
        return nil, "zip: bad central directory entry signature"
      end
      local method   = _read_u16(bytes, p + 10)
      local size     = _read_u32(bytes, p + 24)
      local name_len = _read_u16(bytes, p + 28)
      local extra    = _read_u16(bytes, p + 30)
      local comment  = _read_u16(bytes, p + 32)
      local lfh_off  = _read_u32(bytes, p + 42)
      local name     = bytes:sub(p + 46, p + 46 + name_len - 1)

      if method ~= 0 then
        return nil, "zip: entry '" .. name .. "' uses unsupported compression (method " .. method .. "); STORE only"
      end

      local lp = lfh_off + 1
      if bytes:sub(lp, lp + 3) ~= "\x50\x4B\x03\x04" then
        return nil, "zip: bad local file header signature for '" .. name .. "'"
      end
      local lname_len = _read_u16(bytes, lp + 26)
      local lextra    = _read_u16(bytes, lp + 28)
      local data_off  = lp + 30 + lname_len + lextra
      local data = bytes:sub(data_off, data_off + size - 1)

      entries[#entries + 1] = { name = name, data = data }

      p = p + 46 + name_len + extra + comment
    end

    return entries, nil
  end

  M.zip = zip

  -- ── write_kit / load_kit  (STUBS — wired next session) ───────────────────
  -- Interface contract:
  --   manifest = {
  --     version = 5, kit_name = "Chops", author=..., description=...,
  --     timestamp = ..., globals = {...},
  --     pads = {
  --       [1] = { params={...}, audio="pad_01.wav", layers=nil },
  --       [2] = { params={...}, audio=nil, layers={
  --                 [1]={ params={...}, audio="pad_02_layer_01.wav" }, ... } },
  --       ...
  --     },
  --   }
  --   pad_buffers = {
  --     ["pad_01.wav"] = { samples={...}, sample_rate=44100, channels=2 }, ...
  --   }
  -- Choppa pads land in pad_buffers the same way bridge-loaded ones do —
  -- no special case at the file-format layer.

  function M.write_kit(filepath, manifest, pad_buffers)
    if type(filepath) ~= "string" or filepath == "" then
      return false, "write_kit: bad filepath"
    end
    if type(manifest) ~= "table" then
      return false, "write_kit: manifest must be a table"
    end
    if type(pad_buffers) ~= "table" then
      return false, "write_kit: pad_buffers must be a table"
    end

    manifest.version = 5

    local mtext, mjerr = json.encode(manifest)
    if not mtext then return false, "write_kit: json encode failed: " .. tostring(mjerr) end

    local entries = { { name = "kit.json", data = mtext } }
    local buf_names = {}
    for name, _ in pairs(pad_buffers) do
      if type(name) == "string" then buf_names[#buf_names + 1] = name end
    end
    table.sort(buf_names)
    for _, name in ipairs(buf_names) do
      local b = pad_buffers[name]
      if type(b) == "table" and type(b.samples) == "table" then
        local wbytes, werr = wav.write_int16(b.samples, b.sample_rate or 44100, b.channels or 2)
        if not wbytes then return false, "write_kit: wav encode for '" .. name .. "': " .. tostring(werr) end
        entries[#entries + 1] = { name = name, data = wbytes }
      end
    end

    local zbytes, zerr = zip.write(entries)
    if not zbytes then return false, "write_kit: zip write: " .. tostring(zerr) end

    local f, ferr = io.open(filepath, "wb")
    if not f then return false, "write_kit: cannot open '" .. filepath .. "' for write: " .. tostring(ferr) end
    f:write(zbytes)
    f:close()
    return true, nil
  end

  function M.load_kit(filepath)
    if type(filepath) ~= "string" or filepath == "" then
      return nil, nil, "load_kit: bad filepath"
    end
    local f, ferr = io.open(filepath, "rb")
    if not f then return nil, nil, "load_kit: cannot open '" .. filepath .. "': " .. tostring(ferr) end
    local bytes = f:read("*a")
    f:close()
    if not bytes or #bytes == 0 then return nil, nil, "load_kit: empty file" end

    -- Parse under pcall. zip.read / json.decode / wav.read each return
    -- (nil, err) for the malformed inputs they anticipate, but a HOSTILE
    -- archive (a header length pointing past EOF) can still make an internal
    -- read throw a hard Lua error. Unwrapped, that error unwinds out through
    -- the bridge's poll dispatch -- which is itself not pcall-guarded -- and
    -- stops the defer loop, so one crafted .swing would kill kit-loading until
    -- REAPER restarts. Wrapping turns every throw into a clean load failure.
    local ok, a, b, c = pcall(function()
      local entries, zerr = zip.read(bytes)
      if not entries then return nil, nil, "zip read: " .. tostring(zerr) end

      local mf, pb = nil, {}
      for _, e in ipairs(entries) do
        if e.name == "kit.json" then
          local m, jerr = json.decode(e.data)
          if not m then return nil, nil, "bad kit.json: " .. tostring(jerr) end
          mf = m
        elseif e.name:match("%.wav$") then
          local samples, sr, ch, werr = wav.read(e.data)
          if not samples then return nil, nil, "bad wav '" .. e.name .. "': " .. tostring(werr) end
          pb[e.name] = { samples = samples, sample_rate = sr, channels = ch }
        end
      end
      if not mf then return nil, nil, "no kit.json in archive" end
      return mf, pb, nil
    end)

    if not ok then
      -- `a` carries the runtime error message from the caught throw.
      return nil, nil, "load_kit: parse error: " .. tostring(a)
    end
    -- Success path: a = manifest, b = pad_buffers, c = anticipated-error string.
    if not a then return nil, nil, "load_kit: " .. tostring(c) end
    return a, b, nil
  end

  function M._selftest()
    -- JSON round-trip
    local obj = { name = "Chops", bpm = 120.5, tags = { "808", "trap" }, on = true, off = false }
    local txt = assert(json.encode(obj))
    local dec, derr = json.decode(txt)
    assert(dec, derr)
    assert(dec.name == "Chops")
    assert(dec.bpm == 120.5)
    assert(dec.on == true and dec.off == false)
    assert(dec.tags[1] == "808" and dec.tags[2] == "trap")

    -- WAV round-trip
    local samples = { 100, -200, 32767, -32768, 0, 0, 1, -1 }
    local wb = assert(wav.write_int16(samples, 44100, 2))
    local s2, sr2, ch2, werr = wav.read(wb)
    assert(s2, werr)
    assert(sr2 == 44100 and ch2 == 2)
    for i = 1, #samples do assert(s2[i] == samples[i], "wav sample mismatch at " .. i) end

    -- ZIP round-trip
    local entries = {
      { name = "kit.json", data = txt },
      { name = "pad_01.wav", data = wb },
      { name = "pad_02.wav", data = "small data" },
    }
    local zb = assert(zip.write(entries))
    local e2, zerr = zip.read(zb)
    assert(e2, zerr)
    assert(#e2 == 3)
    assert(e2[1].name == "kit.json" and e2[1].data == txt)
    assert(e2[2].name == "pad_01.wav" and e2[2].data == wb)
    assert(e2[3].name == "pad_02.wav" and e2[3].data == "small data")

    return true
  end

  return M
end)()

-- Optional self-test on bridge start. Enable via:
--   reaper.SetExtState("EON_Swing", "v5_selftest", "1", false)
-- Console prints "swing_kit_v5 selftest OK" or the specific failure.
if reaper.GetExtState and reaper.GetExtState("EON_Swing", "v5_selftest") == "1" then
  local ok, err = pcall(swing_kit_v5._selftest)
  reaper.ShowConsoleMsg(
    ok and "swing_kit_v5 selftest OK\n"
        or ("swing_kit_v5 selftest FAILED: " .. tostring(err) .. "\n"))
end

-- ── gmem layout ──────────────────────────────────────────────────────────────
-- Referenced as G.NAME at every call site on purpose. Lua caps a chunk at 200
-- top-level locals and the main chunk here was sitting at exactly 200/200 —
-- a block of ~50 one-alias-per-address locals (local CMD = G.CMD, …) was eating
-- a quarter of the budget. Folded back to G.NAME 2026-07-31; now 150/200.
-- Do NOT reintroduce `local FOO = G.FOO`.
local G = core.GMEM
-- Exception, deliberate: refresh_multiout_identity_per_instance() binds its own
-- `NAME_BASE` to G.INST_PADNAME_BASE, a DIFFERENT address. Folding this one to
-- G.NAME_BASE would silently re-point the shadowed uses in there, so it stays.
local NAME_BASE     = G.NAME_BASE

-- Styled yes/no confirm for a decision sitting INSIDE a CMD handler, with the
-- async plumbing that makes it safe. One local (the budget above allows it);
-- lives here rather than beside eon_notice because it needs G, which is the
-- line above.
--
-- ⚠️ THE PROBLEM IT SOLVES: the dispatcher is LEVEL-triggered (`if cmd == 10 or
-- cmd == 12 …`, no else, nothing clears CMD on entry), so a handler that
-- returns while a dialog is still open would be re-entered on the very next
-- poll tick, opening another dialog, forever. Parking CMD at 97 ("prompt
-- pending", see .refs/swing_gmem_bridge_protocol.md) matches no branch, so the
-- handler stops re-firing, the mailbox stays claimed against other producers,
-- and the tail's lock-release (which only fires on 0/98/99) correctly HOLDS the
-- instance lock until a real terminal code lands. Same seam as
-- do_build_multiout's FX-returns prompt (a04e384).
--
-- RETURN VALUE IS THE CONTRACT: true = the decision went async, the caller must
-- return IMMEDIATELY and do nothing else (on_yes/on_no will fire later). false =
-- no ReaImGui, so the native box already blocked and the matching callback has
-- ALREADY RUN synchronously — the caller must still just return. Either way the
-- call site reads `eon_confirm_cmd(...) ; return`.
local function eon_confirm_cmd(msg, ok_label, on_yes, on_no)
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.confirm and eon_dlg.confirm({
    title    = SCRIPT_NAME,
    message  = msg,
    ok_label = ok_label or "OK",
    cancel_label = "Cancel",
    on_ok    = on_yes,
    on_cancel = on_no,
  })
  if shown then
    reaper.gmem_write(G.CMD, 97)   -- park the mailbox while the dialog is up
    return true
  end
  if reaper.ShowMessageBox(msg, SCRIPT_NAME, 4) == 6 then on_yes() else on_no() end
  return false
end

-- ── SYN slot band (synth layer Batch 4; .refs/swing_gmem_bridge_protocol.md §3)
-- JSFX publishes live synth state at 26090400 + pad*14; kit save reads it,
-- kit load stages it back and raises the flag at +SYN_STAGED_OFF (the JSFX
-- import tick adopts + consumes). Old kits without syn keys stage nothing —
-- live synth state survives the load (the ratified clear-semantics table).
-- ZERO new locals (when this was written the main chunk sat AT Lua's 200-local
-- cap — six separate locals blew it, then even one did, 2026-07-29; the alias
-- fold has since bought headroom, but riding the G table is still the pattern).
G.SYN = { BASE = 26090400, PP = 14, STAGED_OFF = 224 }

function G.SYN.any_enabled()
  for pad = 0, G.NUM_PADS - 1 do
    if (reaper.gmem_read(G.SYN.BASE + pad * G.SYN.PP) or 0) > 0.5 then return true end
  end
  return false
end

function G.SYN.stage_pad(pad, s)
  local b = G.SYN.BASE + pad * G.SYN.PP
  s = s or {}
  local m = s.macros or {}
  reaper.gmem_write(b + 0, (tonumber(s.enable) or 0) > 0.5 and 1 or 0)
  reaper.gmem_write(b + 1, tonumber(s.engine) or 0)
  reaper.gmem_write(b + 2, tonumber(s.level) or 1)
  reaper.gmem_write(b + 3, tonumber(s.vel_lo) or 0)
  reaper.gmem_write(b + 4, tonumber(s.vel_hi) or 1)
  reaper.gmem_write(b + 5, tonumber(s.rr_order) or 4)
  for k = 1, 8 do reaper.gmem_write(b + 5 + k, tonumber(m[k]) or 0.5) end
end

-- Stage a whole kit's syn tables + raise the adopt flag. No-op for kits
-- without syn keys (pre-synth kits).
function G.SYN.stage_kit(pads)
  local kit_has_syn = false
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1]
    if p and p.syn then kit_has_syn = true break end
  end
  if not kit_has_syn then return end
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    G.SYN.stage_pad(pad, p.syn)
  end
  reaper.gmem_write(G.SYN.BASE + G.SYN.STAGED_OFF, 1)
end

-- EON StepSeq -> multi-out track mute/solo mirror (gmem slots match EON_StepSeq.jsfx).
local EON_SS_ALIVE     = 2700  -- incrementing heartbeat (advancing = StepSeq GUI live)
local EON_SS_MUTE_BASE = 2710  -- per-pad mute  (pad 0..15)
local EON_SS_SOLO_BASE = 2730  -- per-pad solo  (pad 0..15)
local GS_PROJ_DIRTY = 2620  -- JSFX project-dirty signal (Phase 1B); literal slot matches Swing_ReaKit.jsfx
-- Audio-only reload flag (project-open sidecar / Undo audio-repair). When set,
-- the JSFX preserves its @serialize-restored live params instead of taking the
-- kit file's values. Set per-load in drive_load_queue; cleared by every other
-- load via load_swing_dispatch.
-- JSFX-published per-pad pitch MODE band (0=Repitch, 1=Tuned, 2=Stretch). Read
-- to decide which pads need their baked Tuned audio re-injected after a
-- preserve reload overwrote the buffer with the kit's original samples.
local STRETCH_MODE_TUNED = 1
local STRETCH_MODE_STRETCH = 2
-- B1b — per-instance Tuned injection: route the pad-audio swap (CMD 65) to a
-- specific instance by writing its registry slot here, and read the per-slot
-- MODE band / instance registry to map instance<->slot and disambiguate reverts.
-- Per-instance identity band constants are read inside the consumer function
-- (function scope) via G.* — NOT as module-level locals, to stay under Lua's
-- 200-local-per-function limit on this large bridge main chunk.
local GMEM_AUDIO_MAX = G.NUM_PADS * G.SLOT_SIZE  -- 64M max total audio in gmem

-- ─── EON Swing pitch protocol — per-pad path publish to Extension ─────────
-- The Extension's BakeWorker (Tuned mode) needs the file path of each pad's
-- sample so it can pre-render the pitched buffer. JSFX can't call REAPER's
-- API, so the bridge publishes the path to ExtState under the
-- "EON_Swing_Pitch" namespace using the key "inst_<N>_pad_<M>_path". The
-- Extension reads it on RENDER_REQ via GetExtState.
--
-- This is called immediately after every existing
-- `SetExtState("Swing", "pad_path_<pad>", ...)` site (kit-load v2/v3/v4/v5,
-- browser drag-drop, kit-wide clear) so the Extension's view stays in
-- lockstep with the bridge's own breadcrumb storage. Passing an empty
-- `path` clears the Extension's cache for that (inst, pad).
--
-- `inst_id` defaults to the current LOCK holder (gmem[LOCK]) — set by the
-- JSFX before any kit-load CMD reaches the bridge, so it's reliable at all
-- the documented hook sites. Callers can override when they have the
-- inst-id from a different source (e.g. browser CMDs that read it from
-- a separate slot).
-- B1b — per-instance Tuned. The C++ Extension keys every Tuned ExtState entry
-- by REGISTRY SLOT (0..15) and reconciles all live slots, so the bridge keys by
-- the owning instance's registry slot too (NOT a fixed inst_0, and NOT the raw
-- LOCK id). We map instance_id -> slot via the gmem instance registry the JSFX
-- maintains every @block. (Old single-instance pin removed; multi-instance Tuned
-- now works — each instance's bakes route to it via GS_PENDING_PITCH_INST.)

-- Map a JSFX instance_id to its registry slot (0..15). Returns the slot whose
-- registry id matches; otherwise falls back to the single live slot (or 0) when
-- AT MOST ONE instance is registered, and nil only when 2+ instances are live
-- and none matches.
--
-- Why the fallback: the registry id is written by the JSFX in @block (not @init),
-- but the kit auto-load that publishes source paths can run before that first
-- @block lands — so a strict id match would skip the publish entirely and the
-- Extension would never get a source (Tuned plays the original, Stretch plays
-- nothing). Slot 0 is the single-instance home and the Extension reconciles
-- every slot, so a single-instance fallback restores the old pinned-inst-0
-- behavior. We only refuse (nil) when multiple instances are live, to avoid
-- publishing one instance's path under a sibling's slot.
local function pitch_slot_for_inst(inst_id)
  inst_id = inst_id or 0
  local live_count, first_live = 0, nil
  for slot = 0, G.GS_INST_REG_MAX - 1 do
    local id = math.floor(reaper.gmem_read(
      G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
    if id ~= 0 then
      live_count = live_count + 1
      if not first_live then first_live = slot end
      if inst_id > 0 and id == inst_id then return slot end
    end
  end
  if live_count <= 1 then return first_live or 0 end
  return nil
end

-- Is registry slot `slot` held by a LIVE instance (id set + fresh heartbeat)?
-- Lets the poller probe ExtState only for slots with a running instance.
local function pitch_slot_live(slot)
  local id = math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
  if id <= 0 then return false end
  local hb = reaper.gmem_read(G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_HEARTBEAT) or 0
  return (reaper.time_precise() - hb) <= G.GS_INST_REG_TIMEOUT
end

-- A registry slot's live per-pad pitch MODE band (0=Repitch/1=Tuned/2=Stretch).
local function pitch_slot_pad_mode(slot, pad)
  return math.floor(reaper.gmem_read(G.STRETCH_PER_PAD_MODE_BASE + slot * G.STRETCH_CONTROL_INSTANCE_STRIDE + pad) or 0)
end

-- B1b — per-instance source-path publishing. The Extension keys source/baked
-- ExtState by REGISTRY SLOT, but the slot for a freshly-inserted instance isn't
-- written to the registry until its first @block, which can land AFTER its kit
-- auto-load tries to publish. Resolving the slot at publish time therefore
-- mis-routes or drops a 2nd instance's paths permanently. Instead we RETAIN the
-- path keyed by the stable, unique JSFX instance_id (known at publish time via
-- LOCK), and RE-PUBLISH per live slot from poll_pitch_bake_results once the
-- registry has settled. _eon_src_paths[inst_id][pad] = path ("" = cleared).
local _eon_src_paths      = {}   -- inst_id -> { pad -> path }
local _eon_published_src  = {}   -- slot    -> { pad -> last-published path } (dedup)
local _eon_published_src_id = {} -- slot    -> inst_id last published under this slot

-- True when `id` is a currently-registered, heartbeating instance. Used to
-- validate a routing-slot attribution before trusting it: a stale GS_PENDING_
-- LOAD_INST / browser-target value must not mis-attribute a source path to a
-- dead or wrong instance.
local function _pub_inst_is_live(id)
  if not id or id <= 0 then return false end
  for slot = 0, G.GS_INST_REG_MAX - 1 do
    if math.floor(reaper.gmem_read(
         G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0) == id then
      local hb = reaper.gmem_read(G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_HEARTBEAT) or 0
      if (reaper.time_precise() - hb) <= G.GS_INST_REG_TIMEOUT then return true end
    end
  end
  return false
end

-- Resolve the instance_id a publish should be attributed to. Prefer the passed
-- id, else the current LOCK holder (set during kit-loads). When LOCK is idle
-- (e.g. a drag-drop or browser load that doesn't hold the lock) consult the
-- routing slots that identify the load TARGET — GS_PENDING_LOAD_INST (auto-load
-- / pending-load wire) and INSTANCE (slot 98, the browser-target id that the
-- JSFX's _is_browser_target() gates on). Each is validated against the live
-- registry so a stale value can't mis-attribute. Only THEN fall back to the sole
-- registered instance (single-instance source publishing never needs LOCK).
--
-- History: previously this returned nil whenever LOCK was idle AND 2+ instances
-- were live, silently DROPPING the source path. A pad loaded via browser/drag on
-- a 2nd instance therefore retained no source, so Stretch mode (the only mode
-- that hard-requires the Extension-side source preload) was SILENT until a kit
-- reload re-published it under LOCK. The routing-slot lookup below fixes that.
-- Deduped diagnostic: enable with
--   reaper.SetExtState("EON_Swing", "pitch_attrib_debug", "1", false)
-- Prints which path resolved a source-publish attribution (or that it was
-- dropped). Decisive for the 2-instance Stretch-silence repro. Silent unless
-- the flag is set; deduped so a per-publish call doesn't spam the console.
local _pub_attrib_last = nil
local function _pub_attrib_log(msg)
  if reaper.GetExtState("EON_Swing", "pitch_attrib_debug") ~= "1" then return end
  if msg == _pub_attrib_last then return end
  _pub_attrib_last = msg
  reaper.ShowConsoleMsg("[EON pitch-attrib] " .. msg .. "\n")
end

local function resolve_pub_inst(inst_id)
  inst_id = inst_id or math.floor(reaper.gmem_read(G.LOCK) or 0)
  if inst_id > 0 then _pub_attrib_log("LOCK/explicit -> id=" .. inst_id); return inst_id end
  -- Load-target routing slots (validated live), in priority order.
  local pending = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0)
  if _pub_inst_is_live(pending) then _pub_attrib_log("PENDING_LOAD -> id=" .. pending); return pending end
  local btarget = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  if _pub_inst_is_live(btarget) then _pub_attrib_log("BROWSER_TARGET -> id=" .. btarget); return btarget end
  -- Sole live instance — single-instance source publishing never needs LOCK.
  local found, count = nil, 0
  for slot = 0, G.GS_INST_REG_MAX - 1 do
    local id = math.floor(reaper.gmem_read(
      G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
    if id ~= 0 then count = count + 1; found = id end
  end
  if count == 1 then _pub_attrib_log("SOLE_INSTANCE -> id=" .. found); return found end
  _pub_attrib_log("DROPPED (LOCK idle, " .. count .. " live, no routing slot matched)")
  return nil
end

-- Publish a pad's source-sample path so the Extension's BakeWorker can pre-
-- render the pitched buffer (and the StretchPreloadWorker can preload). RETAINS
-- it keyed by the owning instance_id; the actual ExtState write happens in the
-- poll loop's per-slot re-publish pass.
local function publish_pitch_path(pad_idx, path, inst_id)
  if not pad_idx or pad_idx < 0 or pad_idx > 15 then return end
  inst_id = resolve_pub_inst(inst_id)
  if not inst_id then return end
  local t = _eon_src_paths[inst_id]
  if not t then t = {}; _eon_src_paths[inst_id] = t end
  t[pad_idx] = path or ""
  -- Root-note detection hooks HERE, and deliberately NOT in load_audio_to_pad.
  -- That loader has been bake/revert-only since the delivery rewrite — its only
  -- two surviving callers both pass preserve_name=true — so a hook inside its
  -- `not preserve_name` branch is unreachable dead code (the first attempt at
  -- this was exactly that, and rendered nothing for any load). publish_pitch_path
  -- is the real choke point for kit loads: v2 (:6703, :6886) and v4/v5 (:7535,
  -- :7717), plus invalidation (:7542) which must CLEAR rather than analyse.
  -- inst_id is already resolved above and the nil-inst DROP has already run.
  -- JSFX-side routes (browser CMD 63, drag-drop, Choppa) never reach here at
  -- all; they are covered by the re-analysis mailbox the JSFX fires on load.
  if eon_rootnote_enqueue then
    if path and path ~= "" then
      eon_rootnote_enqueue(pad_idx, path, inst_id)
    else
      eon_rootnote_clear(pad_idx, inst_id)
    end
  end
end

-- ─── Stage 1: Drag-drop file-copy to escape OneDrive Files-On-Demand ─────
-- The Extension's BakeWorker uses dr_wav, which can't open OneDrive
-- placeholder files (std::filesystem::status fails on the reparse point).
-- REAPER's own PCM_Source_CreateFromFileEx DOES handle them (it triggers
-- the shell auto-download), so by the time we get to load_audio_to_pad
-- the file's bytes are guaranteed local. We binary-copy to a stable temp
-- location and publish THAT path so the Extension always reads from a
-- non-cloud-only mirror.
--
-- Kit-load paths (v2/v3/v4/v5) are NOT serialized here yet — the prior
-- attempt at WAV serialization crashed REAPER (suspected: multi-second
-- blocking I/O during project auto-load made REAPER appear hung). Stage 2
-- will re-add that incrementally with deferred I/O and explicit logging.
local _eon_temp_dir_created = false

-- TEMP/TMP are Windows; macOS and Linux use TMPDIR, and often set none of the
-- three, so the last resort has to be per-platform too. Previously this fell
-- through to a literal "C:\Windows\Temp" and joined with a hard-coded "\",
-- which on a Mac or Linux install produced a nonsense path — and both are
-- shipped platforms (Swing_2_Setup_Mac.command / _Linux.sh).
local function _eon_temp_audio_dir()
  local sep = package.config:sub(1, 1)
  local t = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR")
  if not t or t == "" then
    t = (sep == "\\") and "C:\\Windows\\Temp" or "/tmp"
  end
  t = t:gsub("[/\\]+$", "")   -- no trailing sep, so the join can't double it
  return t .. sep .. "eon_swing_pitch"
end

-- `seq`, when supplied, makes the filename UNIQUE per (re)publish. The Extension
-- caches its decoded source by the published path STRING, so a stable name would
-- never re-decode after a sample swap (it would resurrect the OLD audio). Every
-- publish bumps _eon_pub_seq so a changed source always lands under a new name.
local function _eon_temp_audio_path(inst_id, pad_idx, seq)
  return _eon_temp_audio_dir() .. package.config:sub(1, 1) .. "inst_"
         .. inst_id .. "_pad_" .. pad_idx
         .. (seq and ("_s" .. seq) or "") .. ".wav"
end

local function _eon_ensure_temp_dir()
  if _eon_temp_dir_created then return end
  reaper.RecursiveCreateDirectory(_eon_temp_audio_dir(), 0)
  _eon_temp_dir_created = true
end

-- Issue C: clean the bake temp folder so it doesn't accumulate. Both the
-- Extension (baked_inst_N_pad_M.wav) and this bridge (inst_<id>_pad_M.wav)
-- write into %TEMP%\eon_swing_pitch and neither deleted them before, so they
-- piled up across sessions. Called from atexit (REAPER close) — a safe point:
-- no further bakes are requested. Names are collected first, then removed, so
-- os.remove() doesn't shift the EnumerateFiles index mid-walk.
-- Cross-instance note: if a second REAPER is open with active bakes, its temps
-- may be removed too — harmless, the bake system regenerates them on demand.
local function _eon_sweep_temp_audio()
  local dir = _eon_temp_audio_dir()
  local files = {}
  local i = 0
  while true do
    local fname = reaper.EnumerateFiles(dir, i)
    if not fname or fname == "" then break end
    if fname:lower():match("%.wav$") then
      -- ⚠️ Was a hard-coded "\\" — the one join in this group that did not use
      -- the platform separator (_eon_temp_audio_dir and _eon_temp_audio_path
      -- both do). os.remove then got "/tmp/eon_swing_pitch\name.wav", which
      -- matches nothing on Mac or Linux, and its return value is discarded
      -- below, so the sweep reported nothing and deleted nothing. One
      -- full-size WAV per pad per kit load accumulated for ever — and on
      -- Linux /tmp is usually tmpfs, so that is RAM until reboot.
      files[#files + 1] = dir .. package.config:sub(1, 1) .. fname
    end
    i = i + 1
  end
  local j = 1
  while j <= #files do os.remove(files[j]); j = j + 1 end
end

-- ── P5: 30-day age sweep of the UNSAVED sample store ────────────────────────
-- The ONLY automatic deletion anywhere. Confined to
-- <resource>/Data/EON_Swing/unsaved/{kits,chops} — a SAVED project's store
-- (<projdir>/Swing/samples) is NEVER touched here; that's the manual
-- Clean-sample-store op's job. Age is a .eon_stamp (os.time) refreshed on
-- every extraction (eon_stage_kit_store_paths), so an actively-reused kit
-- never ages out (LRU, not birth-age). A dir with NO stamp is stamped now —
-- first sighting gets a full 30-day grace, never deleted on the spot.
-- REAPER/Lua can't portably rmdir, so an aged dir's WAV bytes are reclaimed
-- (the disk weight) and an empty skeleton dir may remain (~0 bytes, harmless).
EON_UNSAVED_STORE_MAX_AGE = 30 * 24 * 60 * 60   -- global (bridge at 200-local ceiling)
function _eon_unsaved_store_root()
  return reaper.GetResourcePath() .. "/Data/EON_Swing/unsaved"
end
function _eon_store_stamp_read(dir)
  local f = io.open(dir .. "/.eon_stamp", "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return tonumber(s)
end
function _eon_store_stamp_write(dir)
  local f = io.open(dir .. "/.eon_stamp", "wb")
  if f then f:write(tostring(os.time())); f:close() end
end
function _eon_sweep_unsaved_store()
  local root = _eon_unsaved_store_root()
  local now = os.time()
  local swept = 0
  for _, sub in ipairs({ "kits", "chops" }) do
    local base = root .. "/" .. sub
    -- collect subdir names first (os.remove inside would shift the index)
    local dirs, i = {}, 0
    while true do
      local dn = reaper.EnumerateSubdirectories(base, i)
      if not dn or dn == "" then break end
      dirs[#dirs + 1] = dn; i = i + 1
    end
    for _, dn in ipairs(dirs) do
      local dir = base .. "/" .. dn
      local stamp = _eon_store_stamp_read(dir)
      if not stamp then
        _eon_store_stamp_write(dir)   -- first sighting: full grace, never delete now
      elseif now - stamp > EON_UNSAVED_STORE_MAX_AGE then
        local files, k = {}, 0
        while true do
          local fn = reaper.EnumerateFiles(dir, k)
          if not fn or fn == "" then break end
          files[#files + 1] = fn; k = k + 1
        end
        for _, fn in ipairs(files) do os.remove(dir .. "/" .. fn) end
        swept = swept + 1
        -- Receipt for deleting user-adjacent files — but into the bounded
        -- session log, not the console: eon_load_report tees there and stays
        -- invisible unless load_debug is on (console-noise sweep 2026-08-05).
        eon_load_report(("store: swept aged unsaved %s dir (%d days idle): %s")
          :format(sub, math.floor((now - stamp) / 86400), dir))
      end
    end
  end
  return swept
end

-- Binary file copy. Returns true on success. Reads entire src file into
-- memory (one Lua string) and writes to dst — fine for typical kit
-- samples (sub-50 MB); if we ever need to handle multi-hundred-MB
-- samples, switch to chunked I/O.
local function _eon_copy_file_bin(src, dst)
  if not src or src == "" then return false end
  local fin = io.open(src, "rb")
  if not fin then return false end
  local data = fin:read("*a")
  fin:close()
  if not data then return false end
  local fout = io.open(dst, "wb")
  if not fout then return false end
  fout:write(data)
  fout:close()
  return true
end

-- Publish a pad path via temp copy. Used by drag-drop (load_audio_to_pad).
-- If the copy fails, falls back to publishing the original path so the
-- Extension can still try (and surface a useful diagnostic on its end).
local function publish_pitch_path_from_file(pad_idx, src_path, inst_id)
  if not pad_idx or pad_idx < 0 or pad_idx > 15 then return end
  inst_id = resolve_pub_inst(inst_id)
  if not inst_id then return end
  if not src_path or src_path == "" then
    publish_pitch_path(pad_idx, "", inst_id); return
  end
  _eon_ensure_temp_dir()
  -- Unique per-publish name so a re-loaded sample forces an Extension re-decode
  -- (it caches by path string; a stable name would replay the OLD audio).
  _eon_pub_seq = (_eon_pub_seq or 0) + 1
  local dst = _eon_temp_audio_path(inst_id, pad_idx, _eon_pub_seq)
  if _eon_copy_file_bin(src_path, dst) then
    publish_pitch_path(pad_idx, dst, inst_id)
  else
    publish_pitch_path(pad_idx, src_path, inst_id)
  end
end

-- ─── Stage 2: kit-load WAV serialization from raw s16 bytes ──────────────
-- v3/v4 kit binaries store per-pad audio as 16-bit little-endian PCM
-- (stereo-interleaved, `alen` interleaved samples). We can publish the
-- pad's audio to the Extension by wrapping the kit's raw s16 bytes with
-- a WAV header — no decode, no per-sample Lua loop, no string.pack of
-- huge tables. Just a 44-byte header + memcpy.
--
-- v5 (zip-bundled WAVs in Lua tables) is NOT served from here yet —
-- that's Stage 3, deferred because the Lua-table-to-bytes pack is the
-- suspected source of the earlier crash.

local function _eon_write_wav_s16_bytes(path, channels, sr, s16_bytes)
  channels = math.max(1, math.floor(channels or 2))
  sr       = math.max(1, math.floor(sr or 44100))
  local data_size = #s16_bytes
  local block_align = channels * 2     -- 16-bit = 2 bytes per sample
  local byte_rate   = sr * block_align
  local f = io.open(path, "wb")
  if not f then return false end
  f:write("RIFF")
  f:write(string.pack("<I4", 36 + data_size))
  f:write("WAVEfmt ")
  f:write(string.pack("<I4I2I2I4I4I2I2",
    16,            -- fmt chunk size
    1,             -- format = PCM
    channels,
    sr,
    byte_rate,
    block_align,
    16))           -- bits per sample
  f:write("data")
  f:write(string.pack("<I4", data_size))
  f:write(s16_bytes)
  f:close()
  return true
end

-- Publish a pad path by serializing s16 bytes to a temp WAV. Used by
-- v3/v4 kit-load — bypasses the OneDrive/breadcrumb-path problem by
-- writing the kit's own baked audio out as a standalone file.
local function publish_pitch_path_from_s16_bytes(pad_idx, channels, sr, s16_bytes, inst_id)
  if not pad_idx or pad_idx < 0 or pad_idx > 15 then return end
  inst_id = resolve_pub_inst(inst_id)
  if not inst_id then return end
  if not s16_bytes or #s16_bytes == 0 then
    publish_pitch_path(pad_idx, "", inst_id); return
  end
  _eon_ensure_temp_dir()
  -- Unique per-publish name (see publish_pitch_path_from_file) so a re-captured
  -- pad source forces the Extension to re-decode the NEW audio.
  _eon_pub_seq = (_eon_pub_seq or 0) + 1
  local dst = _eon_temp_audio_path(inst_id, pad_idx, _eon_pub_seq)
  if _eon_write_wav_s16_bytes(dst, channels, sr, s16_bytes) then
    publish_pitch_path(pad_idx, dst, inst_id)
  else
    publish_pitch_path(pad_idx, "", inst_id)
  end
end

-- (Phase 2b poll function is defined further down, after load_audio_to_pad,
-- since Lua locals aren't hoisted.)
-- B1b: per-(registry slot, pad) so two instances' same-pad bakes don't fight
-- over one shadow. _eon_baked_ver_shadow[slot][pad] = last-seen baked_ver string.
local _eon_baked_ver_shadow = {}
for s = 0, 15 do
  _eon_baked_ver_shadow[s] = {}
  for p = 0, 15 do _eon_baked_ver_shadow[s][p] = "" end
end

-- ─── A4/A5 per-layer Tuned bake state ────────────────────────────────────────
-- Velocity-layered pads (Sum / VelSplit / RR) sound layers 1+ as well as layer
-- 0, so each non-empty layer is baked to pitch independently. Layer 0 keeps the
-- legacy single-layer path (inst_<N>_pad_<M>_*, CMD 65); layers 1.. use
-- _layer_<L>_ ExtState channels and CMD 67.
--
-- All per-layer bake state lives in ONE table (the bridge main chunk is at
-- Lua's 200-local-per-chunk limit — adding 8 separate top-level locals would
-- break the whole bridge load, so they're fields here and the layer helper
-- functions below are GLOBAL, same escape hatch as is_stepseq_fx). Fields:
--   .src_paths[id][pad][layer]        retained ORIGINAL layer source (temp WAV),
--                                     captured once via CMD-66-layer while still
--                                     unpitched; keyed by stable instance_id.
--   .pub[slot][pad][layer]/.pub_id[slot]   per-slot republish dedup (mirror of
--                                     _eon_published_src for layers).
--   .baked_ver[slot][pad][layer]      last-seen baked_ver for the delivery swap.
--   .export_tried[id][pad][layer]={t,n}  source-capture backoff.
--   .export                           the one in-flight CMD-66 layer request.
--   .mode_shadow[slot][pad]           last-seen pitch mode (Tuned->non-Tuned detect).
--   .revert_pending[slot][pad][layer] queued per-layer reverts to original.
--   .src_gen[id][pad]                 last-seen JSFX source-generation counter
--                                     (poll_src_gen diffs it to invalidate stale
--                                     Extension sources after a sample swap).
local _eon_layer = {
  src_paths = {}, pub = {}, pub_id = {}, baked_ver = {},
  export_tried = {}, export = nil, mode_shadow = {}, revert_pending = {},
  src_gen = {},
}
for s = 0, 15 do
  _eon_layer.baked_ver[s]      = {}
  _eon_layer.mode_shadow[s]    = {}
  _eon_layer.revert_pending[s] = {}
  for p = 0, 15 do
    _eon_layer.baked_ver[s][p]      = {}
    _eon_layer.mode_shadow[s][p]    = -1
    _eon_layer.revert_pending[s][p] = {}
    for l = 1, G.MAX_LAYERS - 1 do _eon_layer.baked_ver[s][p][l] = "" end
  end
end

-- Temp-WAV path for a captured ORIGINAL layer source (stable name → the
-- Extension caches its decode by path string, so later baked overwrites of the
-- same name never re-decode; the original stays the bake source).
-- GLOBAL (not local) — see the _eon_layer table comment: bridge is at the
-- 200-local chunk limit, so the per-layer helpers are module-global like
-- is_stepseq_fx. They still close over the main-chunk locals above.
function _eon_temp_layer_audio_path(inst_id, pad_idx, layer, seq)
  return _eon_temp_audio_dir() .. package.config:sub(1, 1) .. "inst_" .. inst_id
         .. "_pad_" .. pad_idx .. "_layer_" .. layer
         .. (seq and ("_s" .. seq) or "") .. ".wav"
end

-- Retain a captured layer source path keyed by instance_id (republished per
-- live slot in poll_pitch_bake_results, same as layer 0).
function publish_layer_pitch_path(pad_idx, layer, path, inst_id)
  inst_id = resolve_pub_inst(inst_id)
  if not inst_id then return end
  local t = _eon_layer.src_paths[inst_id]
  if not t then t = {}; _eon_layer.src_paths[inst_id] = t end
  local pt = t[pad_idx]
  if not pt then pt = {}; t[pad_idx] = pt end
  pt[layer] = path or ""
end

-- Serialize captured s16 layer bytes to a stable temp WAV and retain it.
function publish_layer_path_from_s16_bytes(pad_idx, layer, channels, sr, s16_bytes, inst_id)
  inst_id = resolve_pub_inst(inst_id)
  if not inst_id then return end
  if not s16_bytes or #s16_bytes == 0 then return end
  _eon_ensure_temp_dir()
  -- Unique per-publish name so a re-captured layer source re-decodes (path-keyed cache).
  _eon_pub_seq = (_eon_pub_seq or 0) + 1
  local dst = _eon_temp_layer_audio_path(inst_id, pad_idx, layer, _eon_pub_seq)
  if _eon_write_wav_s16_bytes(dst, channels, sr, s16_bytes) then
    publish_layer_pitch_path(pad_idx, layer, dst, inst_id)
  end
end

-- AUTO-KIT-SIDECAR — kit_sources tracks which file each instance was loaded
-- from, so on project save we can simply COPY the source file to the
-- project's sidecar location instead of rebuilding the kit from gmem
-- (which is racy across multi-window @gfx mirrors). Hook is in
-- load_swing_dispatch — every kit-load route ends up there. Declared at
-- top of file so the lexical scope sees it before the function definition.
local kit_sources = {}

-- (Kit-undo helpers live after is_swing_fx — they capture locals declared
-- between here and there: pending_export, is_swing_fx.)

-- Register a saved kit file as the kit source for the LOCK-holding instance.
-- Called after every successful kit save so that:
--   1. auto_save_all_sidecars() copies the right file on project save
--   2. P_EXT:swing_kit_src survives REAPER restarts for sidecar recovery
-- Without this, Choppa-applied kits and any save-without-prior-load would
-- have no source path → no sidecar → blank pads after chunk truncation.
local function register_kit_source_after_save(filepath)
  if not filepath or filepath == "" then return end
  -- Every bridge-side kit write funnels through here — bump the epoch that
  -- invalidates the sidecar skip-unchanged cache (see auto_save_all_sidecars)
  -- so a freshly saved kit ALWAYS re-copies on the next project save.
  -- Global (not local): this fn is defined above the cache block.
  _kit_write_epoch = (_kit_write_epoch or 0) + 1
  local lock_id = math.floor(reaper.gmem_read(97) or 0)  -- LOCK slot
  if lock_id <= 0 then return end
  -- Find the LOCK-holding track and key kit_sources by its GUID (project-unique,
  -- collision-free) — not the session-counter integer id. Also persist to track
  -- ExtState so it survives bridge restarts.
  for tr_idx = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, tr_idx)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
      if inst_id == lock_id then
        local guid = reaper.GetTrackGUID(tr)
        if guid and guid ~= "" then kit_sources[guid] = filepath end
        reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", filepath, true)
        return
      end
    end
  end
end

-- Reverse of register_kit_source_after_save: which file is the LOCK-holding
-- instance's kit? Same GUID-keyed lookup, with the P_EXT fallback that makes
-- it survive a bridge restart (kit_sources starts empty on a fresh project
-- open; the track attribute does not). GLOBAL, not local — this chunk is at
-- Lua's 200-local limit.
function eon_kit_src_for_lock()
  local lock_id = math.floor(reaper.gmem_read(97) or 0)  -- LOCK slot
  if lock_id <= 0 then return nil end
  for tr_idx = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, tr_idx)
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0) == lock_id then
        local guid = reaper.GetTrackGUID(tr)
        if guid and guid ~= "" and kit_sources[guid] then return kit_sources[guid] end
        local ok, p = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", "", false)
        if ok and p and p ~= "" then
          if guid and guid ~= "" then kit_sources[guid] = p end  -- rehydrate
          return p
        end
        return nil
      end
    end
  end
  return nil
end

-- Is this path one of the SHIPPED kits? Factory kits install into the same
-- directory users save into (core.get_kits_dir() = <resource>/Data/Swing_Kits)
-- and Swing_2_Setup.iss writes them with `ignoreversion`, i.e. EVERY update
-- overwrites them — so an in-place SAVE onto one is guaranteed to be lost
-- eventually. There is no read-only marker in the .swing format, so the test
-- is the shipped subfolder set (see the SrcKits block in Swing_2_Setup.iss).
-- ⚠️ Deliberately conservative: a user folder that happens to share a factory
-- name reads as factory and merely gets Save As instead of Save — the safe
-- direction to fail. Extend EON_FACTORY_KIT_DIRS when kits ship in new folders.
EON_FACTORY_KIT_DIRS = { ["fischer 808"] = true, ["vintage synth"] = true }

function eon_kit_is_factory(filepath)
  if not filepath or filepath == "" then return false end
  local norm = filepath:gsub("\\", "/")
  local dir  = norm:match("^(.*)/[^/]*$")
  if not dir then return false end
  local leaf = dir:match("([^/]+)$")
  if not leaf then return false end
  return EON_FACTORY_KIT_DIRS[leaf:lower()] == true
end

-- ── CMD protocol ───────────────────────────────────────────────────────────
-- Kit ops (10-19):
--   10 = JSFX → Lua: export — prompt for name
--   11 = Lua → JSFX: name ready, proceed with data copy
--   12 = JSFX → Lua: SAVE IN PLACE — overwrite the loaded kit, no dialog.
--        Falls through to the CMD 10 prompt (name prefilled) when the
--        instance has no kit source yet or its kit is a factory kit, so the
--        button never dead-ends. See do_save_in_place.
--   1  = JSFX → Lua: data ready, write file
--   2  = JSFX → Lua: import — show browser, load file
--   3  = Lua → JSFX: import data ready in gmem
--   15 = JSFX → Lua: save to custom path (full PC browse)
--   16 = JSFX → Lua: load from custom path (full PC browse)
--   19 = JSFX → Lua: export current kit as SFZ sample map (file dialog)
--   17 = JSFX → Lua: import SFZ kit (file dialog)
--   18 = JSFX → Lua: import SFZ kit from gmem path (drag-drop on pad grid)
--   22 = JSFX → Lua: auto-load default 808 kit (fires once per fresh instance)
-- Sample ops (20-29):
--   20 = JSFX → Lua: batch import folder to pads
--   23 = JSFX → Lua: auto-color pads by drum type
-- Arrangement ops (30-39):
--   30 = JSFX → Lua: chop selected item to pads
-- Routing ops (40-49):
--   40 = JSFX → Lua: build multi-out tracks
--   45 = JSFX → Lua: toggle Media Explorer
--   46 = JSFX → Lua: open undo block (phase 1 — bridge sets ACK=1)
--   48 = JSFX → Lua: close undo block (phase 2 — action complete)
-- Pad naming (50-59):
--   50 = JSFX → Lua: rename pad (PARAM1=pad index, name in PADNAME area)
--   51 = Lua → JSFX: rename done (new name in PADNAME area)
--   52 = JSFX → Lua: sync MIDI note names to REAPER piano roll
-- Browser (60-62):
--   60 = JSFX → Lua: toggle Swing Browser open/close
--   61 = RETIRED (was: sample assigned via ExtState — never produced; browser uses 63/64)
--   62 = JSFX → Lua: close browser
-- Status:
--   98 = cancel / error
--   99 = success
-- LOCK: gmem[97] = instance_id of requesting JSFX (0=free)

-- ═════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ═════════════════════════════════════════════════════════════════════════════


-- Function aliases from core

local pending_export = nil
-- (Phase 1B) The CMD 46/48 structural handshake no longer opens REAPER undo
-- blocks, so the old pending_undo_descs / undo_block_times stacks are gone.

-- Global parameter keys for v2 kit format (shared between read and write)
local KIT_GLOBAL_KEYS = {
  "repeat_div", "vel_curve", "swing_amt", "hpf_freq", "lpf_freq",
  "sat_drv", "dly_div", "dly_fb", "dly_mix", "dly_hpf_hz",
  "dly_lpf_hz", "dly_ping", "rvb_size", "rvb_damp", "rvb_mix",
  "rvb_width", "eq_lo", "eq_mid", "eq_hi", "lim_on",
  "lim_thr", "lim_rel", "eq_lo_freq", "eq_mid_freq", "eq_hi_freq",
  "meq_lo_bell", "meq_hi_bell", "note_map", "multi_out", "color_palette",
  "meq_bypass", "cmp_thresh", "cmp_ratio", "cmp_attack", "cmp_release",
  "cmp_knee", "cmp_makeup", "cmp_mix", "cmp_bypass", "rvb_predelay",
  "rvb_hpf", "oneshot_global", "rvb_on", "dly_on",
}
-- Globals whose "absent from the file" value is NOT zero. Every key not listed
-- defaults to 0. The bus enables MUST live here: kits saved before they existed
-- carry no rvb_on/dly_on, and a 0 default would load every one of them with the
-- reverb and delay switched off. Same reason oneshot_global has always been 1.
local KIT_GLOBAL_DEFAULTS = {
  oneshot_global = 1,
  rvb_on         = 1,
  dly_on         = 1,
}
local KIT_GMEM_GLOBALS = 40  -- gmem base for global settings

local function pack_double(val)
  return string.pack("<d", val)
end

local function unpack_double(bytes, pos)
  if pos + 7 > #bytes then return 0, pos + 8 end
  return string.unpack("<d", bytes, pos)
end

local function pack_s16(val)
  local clamped = math.max(-1.0, math.min(1.0, val))
  local i = math.floor(clamped * 32767 + 0.5)
  return string.pack("<i2", math.max(-32768, math.min(32767, i)))
end

local function unpack_s16(bytes, pos)
  if pos + 1 > #bytes then return 0.0, pos + 2 end
  local i
  i, pos = string.unpack("<i2", bytes, pos)
  return i / 32767.0, pos
end

local function write_string_field(f, str, max_len)
  local len = math.min(#str, max_len)
  f:write(pack_double(len))
  for i = 1, max_len do
    f:write(pack_double(i <= len and string.byte(str, i) or 0))
  end
end

local function read_string_field(content, pos, max_len)
  local slen
  slen, pos = unpack_double(content, pos)
  slen = math.min(math.floor(slen), max_len)
  local chars = {}
  for i = 1, max_len do
    local c
    c, pos = unpack_double(content, pos)
    if i <= slen and c > 0 then
      chars[#chars + 1] = string.char(math.floor(c))
    end
  end
  return table.concat(chars), pos
end

local function write_gmem_string(f, gmem_base, gmem_len_addr, max_len)
  local len = math.min(math.floor(reaper.gmem_read(gmem_len_addr)), max_len)
  f:write(pack_double(len))
  for i = 0, max_len - 1 do
    f:write(pack_double(reaper.gmem_read(gmem_base + i)))
  end
end

local function read_string_to_gmem(content, pos, gmem_base, gmem_len_addr, max_len)
  local slen
  slen, pos = unpack_double(content, pos)
  slen = math.min(math.floor(slen), max_len)
  reaper.gmem_write(gmem_len_addr, slen)
  for i = 0, max_len - 1 do
    local c
    c, pos = unpack_double(content, pos)
    reaper.gmem_write(gmem_base + i, c)
  end
  return pos
end

local function enumerate_kits()
  local kits_dir = core.get_kits_dir()
  local kits = {}
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(kits_dir, idx)
    if not fname then break end
    if fname:match("%.swing$") then
      local fpath = kits_dir .. core.sep .. fname
      local f = io.open(fpath, "rb")
      local fsize = 0
      if f then fsize = f:seek("end"); f:close() end
      kits[#kits + 1] = {
        name = fname:gsub("%.swing$", ""),
        filename = fname,
        path = fpath,
        size = fsize
      }
    end
    idx = idx + 1
  end
  table.sort(kits, function(a, b) return a.name:lower() < b.name:lower() end)
  return kits, kits_dir
end

-- ── Kits-view roster publish (Spec_Swing_Kits_View.md §3/§5) ─────────────────
-- The in-JSFX kits view (VIEW_KITS) can't read the disk; the bridge scans
-- Data/Swing_Kits (root + ONE level of subdirs = user categories) and
-- publishes name/folder/type/pads/size rows to the EON_KITLIST band.
-- Type is DERIVED from the kit file (sample/synth/hybrid), never authored.
-- ZERO new main-chunk locals (200-local cap) — everything rides G.KITLIST.
-- Publisher discipline: payload first, SEQ even LAST (odd = mid-write).
G.KITLIST = {
  BASE = 26240000, FOLDERS = 26240032, RECORDS = 26241024,
  REC_SIZE = 56, MAX_KITS = 128, MAX_FOLDERS = 31, NAME_MAX = 40,
  cache = {},        -- "path|size|mtime" -> { typ, pads }
  req_last = nil,    -- REQ cell baseline (stale-eaten on bridge start; a
                     -- startup publish below covers the missed bump)
}

-- Quiet per-file classifier: NEVER raises a modal, never reads *a (kit files
-- run to 3MB; the lua slice is <=34KB). Returns typ (0=?,1=SMP,2=SYN,3=HYB),
-- pad count, file size. Any failure -> 0,0,size.
function G.KITLIST.classify(path)
  local typ, pads, size, ckey = 0, 0, 0, nil
  local okk = pcall(function()
    local f = io.open(path, "rb")
    if not f then return end
    size = f:seek("end") or 0
    local mt = ""
    if reaper.JS_File_Stat then
      -- 4th return = modifiedTime (3rd is accessedTime — audit 2026-07-30)
      local rv, _, _, m = reaper.JS_File_Stat(path)
      if rv == 0 then mt = tostring(m) end
    end
    local key = path .. "|" .. size .. "|" .. mt
    local hit = G.KITLIST.cache[key]
    if hit then f:close(); typ = hit[1]; pads = hit[2]; return end
    ckey = key   -- cache the OUTCOME below, success or failure (a corrupt
                 -- file shouldn't re-parse on every rescan)
    f:seek("set", 0)
    local hdr = f:read(16)
    if not hdr or #hdr < 16 then f:close(); return end
    local magic = hdr:sub(1, 8)
    if magic ~= "SWINGv04" and magic ~= "SWINGv03" then f:close(); return end
    local lua_len = math.floor(string.unpack("<d", hdr, 9))
    -- positive-form guard: NaN / negative / huge all fall through to close
    if lua_len > 0 and 16 + lua_len <= size and lua_len <= 2097152 then
      local text = f:read(lua_len)
      f:close()
      -- cheap hostile-file check before load(): the writer's lua section is a
      -- comment line + "return {" — require "return {" within the head
      if not text or not text:sub(1, 200):find("return%s*{") then return end
      local chunk = load(text, "kit_scan", "t", {})
      if not chunk then return end
      local okc, kit = pcall(chunk)
      if not okc or type(kit) ~= "table" or type(kit.pads) ~= "table" then return end
      local smp, syn = false, false
      local i = 1
      while i <= 16 do
        local p = kit.pads[i]
        if type(p) == "table" then
          local s = (tonumber(p.s_len) or 0) > 0 or (tonumber(p.layer_cnt) or 0) > 0
          local y = type(p.syn) == "table" and (tonumber(p.syn.enable) or 0) > 0.5
          if s then smp = true end
          if y then syn = true end
          if s or y then pads = pads + 1 end
        end
        i = i + 1
      end
      typ = (smp and syn) and 3 or (syn and 2) or (smp and 1) or 0
    else
      f:close()
    end
  end)
  if not okk then typ = 0 end
  if ckey then G.KITLIST.cache[ckey] = { typ, pads } end
  return typ, pads, size
end

function G.KITLIST.publish()
  local gw, gr = reaper.gmem_write, reaper.gmem_read
  local kits_dir = core.get_kits_dir()
  -- flush REAPER's directory cache or kits saved elsewhere stay invisible
  reaper.EnumerateFiles(kits_dir, -1)
  reaper.EnumerateSubdirectories(kits_dir, -1)
  local folders = { "Kits" }   -- index 0 = root-level kits
  local rows = {}
  local function scan_dir(dir, fidx)
    local i = 0
    while true do
      local fn = reaper.EnumerateFiles(dir, i)
      if not fn or fn == "" then break end
      if fn:match("%.swing$") and #rows < G.KITLIST.MAX_KITS then
        local nm = fn:gsub("%.swing$", "")
        -- names longer than the record field would truncate in the roster
        -- and reconstruct a nonexistent path on pick (silent dead click) —
        -- skip them; Browse PC still loads them (audit 2026-07-30)
        if #nm <= G.KITLIST.NAME_MAX then
          local path = dir .. core.sep .. fn
          local typ, pads, size = G.KITLIST.classify(path)
          rows[#rows + 1] = { name = nm, folder = fidx,
                              typ = typ, pads = pads,
                              kb = math.floor((size or 0) / 1024), path = path }
        end
      end
      i = i + 1
    end
  end
  scan_dir(kits_dir, 0)
  local si = 0
  while true do
    local sd = reaper.EnumerateSubdirectories(kits_dir, si)
    if not sd or sd == "" then break end
    -- cap: MAX_FOLDERS table slots INCLUDING root idx 0, so the next index
    -- (#folders) must stay <= MAX_FOLDERS-1 (audit: old form admitted a
    -- 32nd folder with no table slot). Over-long folder names would break
    -- pick reconstruction — skip those subdirs entirely.
    if #folders < G.KITLIST.MAX_FOLDERS and #sd <= 31 then
      reaper.EnumerateFiles(kits_dir .. core.sep .. sd, -1)   -- per-subdir flush
      local before = #rows
      scan_dir(kits_dir .. core.sep .. sd, #folders)
      -- only folders that actually yielded kits become categories (hides
      -- sample dirs like "My Kit Samples"); rows already carry the right idx
      if #rows > before then folders[#folders + 1] = sd end
    end
    si = si + 1
  end
  table.sort(rows, function(a, b)
    if a.folder ~= b.folder then return a.folder < b.folder end
    return a.name:lower() < b.name:lower()
  end)
  G.KITLIST.rows = rows   -- kept for the CMD-24 probe path / debugging
  local B = G.KITLIST.BASE
  local seq = math.floor(gr(B) or 0)
  if seq % 2 == 0 then gw(B, seq + 1); seq = seq + 1 end   -- odd = writing
  gw(B + 2, #rows)
  gw(B + 3, #folders)
  gw(B + 4, 1)                                   -- FMT_VER
  gw(B + 6, os.time())                           -- heartbeat
  local fi = 0
  while fi < G.KITLIST.MAX_FOLDERS do
    local fb = G.KITLIST.FOLDERS + fi * 32
    local nm = folders[fi + 1] or ""
    gw(fb, math.min(#nm, 31))
    local ci = 1
    while ci <= 31 do
      gw(fb + ci, ci <= #nm and nm:byte(ci) or 0)
      ci = ci + 1
    end
    fi = fi + 1
  end
  local ri = 0
  while ri < G.KITLIST.MAX_KITS do
    local rb = G.KITLIST.RECORDS + ri * G.KITLIST.REC_SIZE
    local r = rows[ri + 1]
    if r then
      local nm = r.name:sub(1, G.KITLIST.NAME_MAX)
      gw(rb, #nm)
      local ci = 1
      while ci <= G.KITLIST.NAME_MAX do
        gw(rb + ci, ci <= #nm and nm:byte(ci) or 0)
        ci = ci + 1
      end
      gw(rb + 41, r.folder)
      gw(rb + 42, r.typ)
      gw(rb + 43, r.pads)
      gw(rb + 44, r.kb)
    else
      gw(rb, 0)
    end
    ri = ri + 1
  end
  gw(B + 1, math.floor(gr(B + 1) or 0) + 1)      -- GEN bump
  gw(B, seq + 1)                                 -- SEQ even LAST
end

-- REQ poll — the JSFX bumps BASE+5 when the kits view opens; one scan per
-- bump. Baseline-stale on first tick (padcat_req_tick pattern); the startup
-- publish at script init covers a bump that happened while the bridge was
-- down.
function G.KITLIST.tick()
  local req = math.floor(reaper.gmem_read(G.KITLIST.BASE + 5) or 0)
  if G.KITLIST.req_last == nil then G.KITLIST.req_last = req return end
  if req ~= G.KITLIST.req_last then
    G.KITLIST.req_last = req
    pcall(G.KITLIST.publish)
  end
end

local function validate_swing(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil, "Cannot open file" end
  local header = f:read(32)
  f:close()
  if not header or #header < 8 then return nil, "File too small" end

  -- Check for v5 (zip bundle — kit.json + pad_NN.wav files inside)
  if header:sub(1, 4) == "\x50\x4B\x03\x04" or header:sub(1, 4) == "\x50\x4B\x05\x06" then
    return true, "v5"
  end

  -- Check for v4 (hybrid w/ per-pad multi-layer audio, ASCII magic)
  if header:sub(1, 8) == "SWINGv04" then
    return true, "v4"
  end

  -- v3 RETIRED 2026-07-31 (never shipped as a write format — see file header).
  -- The magic is still matched so a stray dev-era file gets a real explanation
  -- rather than falling through to the v1 reader and dying as "Not a .swing
  -- file". Nothing loads v3 any more.
  if header:sub(1, 8) == "SWINGv03" then
    return nil, "legacy v3 kit format is no longer supported"
  end

  -- Check for v2 (Lua table format — path-only, legacy)
  if header:match("^%-%- Swing") or header:match("^return {") or header:match("^return%s*{") then
    return true, "v2"
  end

  -- Check for v1 (binary format — legacy)
  local magic = string.unpack("<d", header, 1)
  if math.floor(magic) ~= MAGIC then return nil, "Not a .swing file" end
  return true, "v1"
end

-- Write default pad metadata + name + audio length to gmem for a single pad
local function write_default_pad_meta(pad_idx, interleaved_len, sr, hue, pad_name)
  local mb = G.META_BASE + pad_idx * G.META_PP
  reaper.gmem_write(mb + 0, 0.707)    -- gain (default -3dB)
  reaper.gmem_write(mb + 1, 0.0)      -- pan
  reaper.gmem_write(mb + 2, 0.0)      -- tune
  reaper.gmem_write(mb + 3, 0.001)    -- attack
  reaper.gmem_write(mb + 4, 0.0)      -- decay
  reaper.gmem_write(mb + 5, 1.0)      -- sustain
  reaper.gmem_write(mb + 6, 0.02)     -- release
  reaper.gmem_write(mb + 7, 0)        -- mute
  reaper.gmem_write(mb + 8, 0)        -- solo
  reaper.gmem_write(mb + 9, 0)        -- output
  reaper.gmem_write(mb + 10, 36 + pad_idx) -- note (C2 + pad index)
  reaper.gmem_write(mb + 11, 0)       -- note_lock
  reaper.gmem_write(mb + 12, hue or (pad_idx / 16.0)) -- color
  reaper.gmem_write(mb + 13, 0)       -- choke
  reaper.gmem_write(mb + 14, -1)      -- oneshot (-1 = follow global)
  reaper.gmem_write(mb + 15, 0)       -- reverse
  reaper.gmem_write(mb + 16, 20)      -- hpf (off)
  reaper.gmem_write(mb + 17, 20000)   -- lpf (off)
  reaper.gmem_write(mb + 18, 0)       -- eq_lo
  reaper.gmem_write(mb + 19, 0)       -- eq_mid
  reaper.gmem_write(mb + 20, 0)       -- eq_hi
  reaper.gmem_write(mb + 21, 0)       -- sat_drv
  reaper.gmem_write(mb + 22, 0)       -- drv_mode
  reaper.gmem_write(mb + 23, 0)       -- bc_rate (0 = off)
  reaper.gmem_write(mb + 24, 16)      -- bc_bits
  reaper.gmem_write(mb + 25, 0)       -- snd_dly
  reaper.gmem_write(G.GS_PAD_SMASH_BASE + pad_idx, 0)  -- snd_smash (overflow band)
  reaper.gmem_write(mb + 26, 0)       -- snd_rvb
  reaper.gmem_write(mb + 27, 200)     -- eq_lo_freq
  reaper.gmem_write(mb + 28, 1000)    -- eq_mid_freq
  reaper.gmem_write(mb + 29, 5000)    -- eq_hi_freq
  reaper.gmem_write(mb + 30, 0)       -- sum_tight
  reaper.gmem_write(mb + 31, 0)       -- rpt_div
  reaper.gmem_write(mb + 32, 0)       -- layer_cnt (non-layered)
  reaper.gmem_write(mb + 33, 0)       -- layer_mode
  reaper.gmem_write(mb + 34, interleaved_len) -- s_len (interleaved)
  reaper.gmem_write(mb + 35, 0.0)     -- s_start
  reaper.gmem_write(mb + 36, 1.0)     -- s_end
  reaper.gmem_write(mb + 37, sr)      -- s_sr
  reaper.gmem_write(mb + 38, 0)       -- s_norm
  reaper.gmem_write(mb + 39, 1.0)     -- s_norm_gain
  reaper.gmem_write(G.AUDIOLEN_BASE + pad_idx, interleaved_len)
  local pname = pad_name:sub(1, G.PADNAME_LEN)
  local pbase = G.PADNAME_BASE + pad_idx * G.PADNAME_LEN
  for j = 0, G.PADNAME_LEN - 1 do
    reaper.gmem_write(pbase + j, j < #pname and string.byte(pname, j + 1) or 0)
  end
end

-- ── Scratch-track helpers ───────────────────────────────────────────────────
-- AudioAccessor requires a media item, which requires a track. Earlier
-- versions used reaper.GetTrack(0, 0) — the user's first track — which
-- briefly polluted it with a temp item and produced a stray undo step.
-- Instead, insert a dedicated scratch track at the END of the project,
-- run the work on it, and delete it. Wrapped in PreventUIRefresh so the
-- TCP/arrange doesn't flicker.
--
-- Always pair acquire / release; release is safe to call with nil (no-op
-- on the track but still decrements the PreventUIRefresh counter).
local function acquire_scratch_track()
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)  -- false = no auto-envelopes
  return reaper.GetTrack(0, idx)
end

local function release_scratch_track(tr)
  if tr then
    -- DeleteTrack also destroys any items still on the track.
    reaper.DeleteTrack(tr)
  end
  reaper.PreventUIRefresh(-1)
end

-- ── Root-note analysis (rk_root_note.lua → EON_ROOTNOTE band) ──────────────
-- When a user-facing load lands audio on a pad, queue that file for root-note
-- detection and publish the result into the PER-INSTANCE band the JSFX reads
-- (EON_ROOTNOTE in Swing_ReaKit.jsfx / ROOTNOTE_* in rk_lua_core).
--
-- ⚠️ QUEUED, NEVER INLINE. Detection costs ~50 ms per file, so analysing a
-- 16-pad kit inside the load itself would stall the defer loop for most of a
-- second. One file per tick drains a full kit in well under a second while
-- keeping the bridge responsive.
--
-- Module-GLOBAL (no `local`) to respect the ~200-local ceiling on this chunk —
-- same reason as _ident_active / eon_courier.
-- Loaded by dofile with an explicit path rather than require(), matching how
-- this file loads its other companions (dm_swing_sync, the courier libs) and
-- avoiding a dependency on package.path being set up first.
-- (Shipping is not a concern either way: gen_manifest.py treats EVERY top-level
-- .Scripts/*.lua as a manifest root, so the module is included regardless of
-- how it is referenced. Its LUA_LITERAL_RE only matters for files nested
-- deeper, which are reached solely through .lua string literals.)
eon_rootnote = nil   -- { mod = <rk_root_note>, q = {}, req_seq = 0 } or nil
do
  local ok, m = pcall(dofile, _SCRIPT_DIR .. _sep .. "rk_root_note.lua")
  if ok and type(m) == "table" and m.detect_file then
    eon_rootnote = { mod = m, q = {}, req_seq = 0 }
  end
end

-- Queue one pad. The band is slot-keyed, so the instance id must resolve to a
-- registry SLOT. A nil slot means 2+ instances are live and no routing slot
-- matched — we DROP rather than publish under a sibling's slot, the same rule
-- publish_pitch_path follows (see resolve_pub_inst's history note).
function eon_rootnote_enqueue(pad_idx, filepath, inst_id)
  local RN = eon_rootnote
  if not RN or not filepath or filepath == "" then return end
  if not pad_idx or pad_idx < 0 or pad_idx >= G.NUM_PADS then return end
  local slot = pitch_slot_for_inst(inst_id or resolve_pub_inst(nil))
  if not slot then return end
  -- Collapse any pending entry for the same slot+pad: a pad re-loaded twice in
  -- quick succession should analyse the CURRENT file once, not both.
  for i = #RN.q, 1, -1 do
    if RN.q[i].slot == slot and RN.q[i].pad == pad_idx then table.remove(RN.q, i) end
  end
  RN.q[#RN.q + 1] = { slot = slot, pad = pad_idx, path = filepath }
end

-- Publish "no root note" for a pad (source removed / pad cleared).
function eon_rootnote_clear(pad_idx, inst_id)
  local RN = eon_rootnote
  if not RN or not pad_idx or pad_idx < 0 or pad_idx >= G.NUM_PADS then return end
  local slot = pitch_slot_for_inst(inst_id or resolve_pub_inst(nil))
  if not slot then return end
  for i = #RN.q, 1, -1 do
    if RN.q[i].slot == slot and RN.q[i].pad == pad_idx then table.remove(RN.q, i) end
  end
  RN.mod.clear(G, slot, pad_idx)
end

-- Pad source path straight from the gmem AUDIO band (the JSFX publishes it
-- there). Duplicated from read_pad_path_from_gmem, which is a `local function`
-- defined ~1800 lines BELOW this point — Lua has no hoisting, so it is simply
-- not in scope here. This is the path the re-analysis mailbox needs, because
-- JSFX-side loads (browser CMD 63, drag-drop) write NO pad_path_N ExtState
-- breadcrumb; an earlier version read that ExtState and always found nothing.
function eon_rootnote_gmem_path(pad)
  local pbase = G.AUDIO_BASE + pad * 260
  local plen = math.floor(reaper.gmem_read(pbase) or 0)
  if plen <= 0 or plen >= 259 then return "" end
  local chars = {}
  for i = 0, plen - 1 do
    local c = math.floor(reaper.gmem_read(pbase + 1 + i) or 0)
    if c > 0 and c < 256 then chars[#chars + 1] = string.char(c) end
  end
  return table.concat(chars)
end

-- Drain one queued analysis and service the JSFX's re-analysis mailbox.
-- Ticked once per poll.
function eon_rootnote_tick()
  local RN = eon_rootnote
  if not RN then return end
  local m = RN.mod

  -- JSFX → bridge re-analysis request; pad -1 means every pad on that slot.
  local req
  req, RN.req_seq = m.poll_request(G, RN.req_seq)
  if req and req.slot and req.slot >= 0 then
    local first, last = req.pad, req.pad
    if req.pad < 0 then first, last = 0, G.NUM_PADS - 1 end
    for pad = first, last do
      -- gmem AUDIO band, NOT the pad_path_N ExtState: JSFX-side loads (browser
      -- CMD 63, native drag-drop, Choppa) never write that ExtState, so reading
      -- it here found nothing for exactly the routes this mailbox exists to
      -- rescue. The JSFX publishes the source path into gmem for every load.
      local path = eon_rootnote_gmem_path(pad)
      if path ~= "" then
        RN.q[#RN.q + 1] = { slot = req.slot, pad = pad, path = path }
      else
        m.clear(G, req.slot, pad)   -- pad has no source → publish "nothing"
      end
    end
  end

  if #RN.q == 0 then return end
  -- detect_file inserts and deletes its own scratch track, so it must not run
  -- while a kit load holds LOCK — the track churn would race the loader's.
  if math.floor(reaper.gmem_read(G.LOCK) or 0) ~= 0 then return end

  local e = table.remove(RN.q, 1)
  local ok, r = pcall(m.detect_file, e.path)
  if ok and type(r) == "table" then
    m.publish(G, e.slot, e.pad, r, G.RN_SRC_DETECTED)
  else
    m.clear(G, e.slot, e.pad)       -- unreadable/failed → explicit "nothing"
  end
end

-- ── Shared audio loader (AudioAccessor — correct PCM, with bounds check) ────
-- Loads audio from a file path onto a pad in gmem. Returns true on success.
-- Uses CreateTakeAudioAccessor for real sample data (not GetPeaks).
-- preserve_name: when true, do NOT overwrite the pad's gmem name from the
-- filename. Set by internal loads (pitch bake injection / Tuned revert) whose
-- source is a temp WAV like "baked_inst_N_pad_M.wav" — those must keep the
-- user's existing pad name. User-facing loads (browser/drag/loader) leave it
-- nil so the pad is named from the file as before.
local function load_audio_to_pad(filepath, pad_idx, preserve_name)
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return false end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local total_samples = math.floor(length * sr)

  -- Cap at SLOT_SIZE/2 (each mono frame → 2 interleaved)
  local num_samples = math.min(total_samples, math.floor(G.SLOT_SIZE / 2))
  -- Zero-length source guard (2026-07-15 boot crash): a mid-write or swept
  -- temp WAV (bake injection races the Extension writer / atexit sweep)
  -- yields total_samples==0 — new_array(0) below is a HARD ERROR that kills
  -- the whole bridge. Bail; the caller's shadow stays unset so the next
  -- poll retries once the file is complete. (The layer variant already had
  -- this exact guard; this pad variant never got it.)
  if num_samples <= 0 then
    reaper.PCM_Source_Destroy(src)
    return false
  end

  -- Audio ALWAYS stages at gmem AUDIO+0; the length travels via PARAM3.
  -- That is the CMD-67 protocol, and since 2026-08-23 it is the only one here.
  --
  -- ⛔ Never derive a staging offset from the AUDIOLEN band. The legacy scheme
  -- summed prior pads' AUDIOLEN cells, but the browser mirror blast-rewrites
  -- that band every @block with has-audio FLAGS (1/0 for layered pads —
  -- "exact length doesn't matter", Swing_ReaKit.jsfx ~2322), so bridge and
  -- JSFX computed DIFFERENT offsets and the swap injected staged path strings
  -- and zeros into pad buffers: ASCII-amplitude "white stripe" waveforms and
  -- blank pads after the first kit load (root-caused 2026-07-16).
  --
  -- That loop survived here under `if not preserve_name`, unreachable once
  -- every caller settled on true. DELETED so a future caller passing false or
  -- nil cannot silently resurrect the corruption. See
  -- .docs/wiki/05-memory-and-gmem.md §5.5.
  local audio_off = 0

  -- Bounds check: ensure we don't exceed GMEM_AUDIO_MAX
  local interleaved_len = num_samples * 2
  if audio_off + interleaved_len > GMEM_AUDIO_MAX then
    num_samples = math.floor((GMEM_AUDIO_MAX - audio_off) / 2)
    interleaved_len = num_samples * 2
    if num_samples <= 0 then
      reaper.PCM_Source_Destroy(src)
      return false
    end
  end

  -- Create a temporary item+take on a dedicated scratch track to get an
  -- AudioAccessor — never touches the user's first track.
  local tr = acquire_scratch_track()
  if not tr then reaper.PCM_Source_Destroy(src); release_scratch_track(nil); return false end

  local temp_item = reaper.AddMediaItemToTrack(tr)
  local temp_take = reaper.AddTakeToMediaItem(temp_item)
  reaper.SetMediaItemTake_Source(temp_take, src)
  reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

  local aa = reaper.CreateTakeAudioAccessor(temp_take)
  if not aa then
    -- release_scratch_track tears down the track + item + take + the
    -- take's source reference. The source was attached via
    -- SetMediaItemTake_Source above so the take owns it now —
    -- calling PCM_Source_Destroy(src) afterward would be a use-after-
    -- free. Just release the scratch track and bail.
    release_scratch_track(tr)
    return false
  end

  -- Read samples in chunks and write interleaved stereo to gmem
  local chunk_size = math.min(num_samples, 1000000)
  local sample_buf = reaper.new_array(chunk_size * nch)
  local samples_read = 0

  while samples_read < num_samples do
    local to_read = math.min(chunk_size, num_samples - samples_read)
    sample_buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, samples_read / sr, to_read, sample_buf)

    -- Write into the JSFX's interleaved L/R audio buffer.
    -- Mono source: duplicate the single channel into both L and R slots so
    --   the JSFX (which always reads buf[i*2] and buf[i*2+1] as L and R)
    --   plays mono samples symmetrically across both outputs.
    -- Stereo source: write channel 0 to L slot, channel 1 to R slot —
    --   preserves the source's L/R separation so the pad waveform display
    --   and any future stereo-aware mixing reads real channel data.
    -- 3+ channels (rare — surround sources): take ch0 → L, ch1 → R and
    --   discard the rest. Approximation, but better than mono-mixing.
    for j = 0, to_read - 1 do
      local valL, valR
      if nch == 1 then
        valL = sample_buf[j + 1]
        valR = valL
      else
        valL = sample_buf[j * nch + 1] or 0
        valR = sample_buf[j * nch + 2] or 0
      end
      local dst = G.AUDIO_BASE + audio_off + (samples_read + j) * 2
      reaper.gmem_write(dst,     valL)
      reaper.gmem_write(dst + 1, valR)
    end
    samples_read = samples_read + to_read
  end

  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)

  -- Write audio length + basic metadata
  reaper.gmem_write(G.AUDIOLEN_BASE + pad_idx, interleaved_len)
  local base = G.META_BASE + pad_idx * G.META_PP
  reaper.gmem_write(base + 0, 1.0)   -- gain
  reaper.gmem_write(base + 34, interleaved_len) -- s_len
  reaper.gmem_write(base + 37, sr)    -- sample rate

  -- Write pad name from filename (skip for internal bake/revert loads —
  -- preserve_name keeps the user's existing pad name instead of stamping the
  -- temp WAV filename like "baked_inst_N_pad_M" onto the pad and its tracks)
  if not preserve_name then
    local fname = filepath:match("[/\\]([^/\\]+)$") or ""
    fname = fname:gsub("%.%w+$", "")
    if #fname > G.PADNAME_LEN then fname = fname:sub(1, G.PADNAME_LEN) end
    for ci = 0, G.PADNAME_LEN - 1 do
      local c = ci < #fname and string.byte(fname, ci + 1) or 0
      reaper.gmem_write(G.PADNAME_BASE + pad_idx * G.PADNAME_LEN + ci, c)
    end
  end

  -- Store path in ExtState for kit save
  reaper.SetExtState("Swing", "pad_path_" .. pad_idx, filepath, false)
  -- Mirror to the Extension's temp location so the bake works even when
  -- the source is in OneDrive (Files-On-Demand placeholders can't be
  -- opened by dr_wav from a worker thread).
  --
  -- ONLY for user-facing loads. Internal injections (preserve_name=true: pitch-
  -- bake delivery via CMD 65/67, Tuned revert) feed the pad BAKED or already-
  -- original audio — they must NOT (re)publish it as the pad's SOURCE. Doing so
  -- makes the Extension's source-aware re-bake treat every bake delivery as a
  -- brand-new source (each now lands under a unique temp name) and re-bake
  -- forever — an infinite bake/deliver/republish loop.
  if not preserve_name then
    publish_pitch_path_from_file(pad_idx, filepath)
  end

  -- Truthy for every legacy `if load_audio_to_pad(...)` caller; CMD-65 senders
  -- pass it through PARAM3 (the CMD-67 pattern — never read back from the
  -- blast-written AUDIOLEN band).
  return interleaved_len
end

-- ── Stage a baked LAYER WAV into the gmem AUDIO band for CMD 67 ───────────────
-- The per-layer sibling of load_audio_to_pad, stripped to JUST the audio copy:
-- decode the baked layer WAV and write its interleaved-stereo samples to
-- AUDIO_BASE+0 (a single transient staging — the bridge delivers one (pad,layer)
-- swap per tick). Deliberately does NOT touch pad name / pad_path ExtState /
-- AUDIOLEN / source publish / pad-main META — those are all pad-main concerns
-- that would corrupt layer state. Returns the interleaved sample count staged
-- (0 on failure); the caller passes it to CMD 67 via PARAM3 (length is NOT read
-- from the blast-written AUDIOLEN band, which is unreliable for layered pads).
function _eon_stage_layer_audio(filepath)   -- GLOBAL (200-local-limit escape hatch)
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return 0 end
  local sr     = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch    = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local num_samples = math.min(math.floor(length * sr), math.floor(G.LAYER_SIZE / 2))
  if num_samples <= 0 then reaper.PCM_Source_Destroy(src); return 0 end

  local tr = acquire_scratch_track()
  if not tr then reaper.PCM_Source_Destroy(src); release_scratch_track(nil); return 0 end
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then release_scratch_track(tr); return 0 end

  local chunk = math.min(num_samples, 1000000)
  local buf = reaper.new_array(chunk * nch)
  local read = 0
  while read < num_samples do
    local to_read = math.min(chunk, num_samples - read)
    buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, read / sr, to_read, buf)
    for j = 0, to_read - 1 do
      local vL, vR
      if nch == 1 then
        vL = buf[j + 1]; vR = vL
      else
        vL = buf[j * nch + 1] or 0; vR = buf[j * nch + 2] or 0
      end
      local dst = G.AUDIO_BASE + (read + j) * 2
      reaper.gmem_write(dst,     vL)
      reaper.gmem_write(dst + 1, vR)
    end
    read = read + to_read
  end
  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)
  return num_samples * 2
end

-- ─── Phase 2b: poll Extension for baked-WAV updates ──────────────────────
-- The Extension's SwingPitchHost writes a pitched WAV to %TEMP% after each
-- successful bake and publishes:
--   ExtState["EON_Swing_Pitch"]["inst_<N>_pad_<M>_baked_path"] = "<path>"
--   ExtState["EON_Swing_Pitch"]["inst_<N>_pad_<M>_baked_ver"]  = "<monotonic>"
-- Order: path written FIRST, then ver. We poll the ver string and, when it
-- changes from our last-seen shadow, we MARK it as pending and apply
-- after a throttle window so rapid knob-drag doesn't fire CMD 65 at
-- audio-rate (each swap causes a 10 ms crossfade — chaining dozens per
-- second sounds choppy even with the fade). Latest-wins: the per-pad
-- baked WAV file is the same name each time (Extension overwrites it),
-- so once the throttle fires we always read the freshest bake.
--
-- Once the pad audio is replaced with the pre-pitched buffer, JSFX plays
-- it at native rate (sp_pitch_mode[pad] == TUNED short-circuits p_tune
-- in rk_swing_core.jsfx-inc — without that gate the multiplier would
-- re-pitch the already-pitched audio).
--
-- Defined here (after load_audio_to_pad) because Lua doesn't hoist locals
-- and we need to call into the ingest function.
-- Throttle window for CMD 65 swap fires per pad. Originally 100ms to avoid
-- chaining swaps during fast knob drags. In practice that made rapid drags
-- audibly broken: bakes complete ~30ms apart, the throttle drops the
-- intermediate ones (without updating the ver-shadow either, so the next
-- tick re-checks and the latest ver eventually wins after a throttle gap).
-- User-perceived effect: "Tuned kinda works but then doesn't" — some knob
-- landings swap in fine, others get skipped while the throttle was hot.
-- Set to 0 — REAPER's CMD 65 swap is cheap (audio copy + 10ms crossfade for
-- click-mask). No rate limit needed.
local _eon_swap_throttle_ms = 0        -- (was 100) — every fresh bake swaps
local _eon_last_swap_t = {}            -- [slot][pad] -> last-swap time_precise() seconds
for s = 0, 15 do
  _eon_last_swap_t[s] = {}
  for p = 0, 15 do _eon_last_swap_t[s][p] = 0 end
end

-- ─── Auto-export: manufacture a source for source-less Stretch pads ──────────
-- A Stretch pad whose audio arrived via @serialize restore (preset/shortcut
-- insert) or an FX duplicate has NO retained _eon_src_paths entry, because no
-- kit-load ran to publish one. Stretch streams realtime from an Extension-side
-- preload of the source WAV, so with no path the pad is SILENT until the user
-- manually re-loads a kit. (Tuned, by contrast, just plays its restored buffer,
-- and that buffer is already-pitched — so Tuned is deliberately NOT handled
-- here; re-publishing a pitched buffer as a source would double-pitch.)
--
-- Fix: command the owning instance to export the pad's ORIGINAL local buffer
-- (CMD 66, see swing_pad_audio_export in rk_swing_block_pitch.jsfx-inc) into the
-- shared AUDIO staging band, read it back, write a temp WAV, and publish it as
-- the source. The existing per-slot re-publish + Extension preload chain then
-- makes the pad audible — no manual reload needed.
--
-- Serialized on the shared CMD channel: one request in flight at a time. While a
-- request is pending this owns the channel (returns true) so the swap/revert
-- staging below doesn't clobber CMD/PARAM1/the AUDIO band before we read the
-- result. Failed/empty attempts back off 1s (so a genuinely empty Stretch pad
-- doesn't spin every tick, but a slightly-late @serialize audio restore retries).
local _eon_autoexport = nil          -- { slot=, pad=, id=, t= } pending request
local _eon_autoexport_tried = {}     -- [inst_id] -> { [pad] -> last-attempt time }

-- Read the exported pad audio (AUDIO band offset 0, len in PARAM2, SR in PARAM3),
-- pack to interleaved-stereo s16, and publish it as the pad's source.
local function _eon_autoexport_finish(pad, id)
  local len = math.floor(reaper.gmem_read(G.PARAM2) or 0)
  local sr  = math.floor(reaper.gmem_read(G.PARAM3) or 0)
  -- Reject a NOT-YET-READY / garbage export: the pad's audio may not have
  -- finished loading for this instance yet, so the JSFX exports a tiny bogus
  -- blob (observed: len=16, sr=3 → an 8-frame "WAV"). Returning false WITHOUT
  -- publishing leaves the pad source-less so the 1 s backoff retries until real
  -- audio is present. Previously the garbage blob got published as the source,
  -- which set srcs[pad] → the scan saw a "valid" source and never retried, so
  -- the Stretch pad stayed corrupt (and its preload kept reloading garbage).
  if len <= 0 or sr < 8000 or len < 64 then return false end
  if len > GMEM_AUDIO_MAX then len = GMEM_AUDIO_MAX end
  local buf = {}
  for j = 0, len - 1 do
    buf[#buf + 1] = pack_s16(reaper.gmem_read(G.AUDIO_BASE + j) or 0)
  end
  -- JSFX exports stereo-interleaved samples (s_audio_start is interleaved L,R).
  publish_pitch_path_from_s16_bytes(pad, 2, sr, table.concat(buf), id)
  return true
end

-- Returns true when it owns the CMD channel this tick (caller should return).
local function poll_autoexport(now)
  -- Resolve a pending request first.
  if _eon_autoexport then
    local req = _eon_autoexport
    if math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      -- JSFX consumed CMD 66 and wrote the result. Only trust it if the same
      -- live instance still owns the routed slot (guards against slot reuse /
      -- the instance vanishing mid-export).
      if pitch_slot_live(req.slot)
         and math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + req.slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0) == req.id then
        _eon_autoexport_finish(req.pad, req.id)
      end
      _eon_autoexport = nil
      return false   -- channel free again; let the rest of the poll run
    end
    -- Still in flight. Time out so a dead/closed instance can't wedge the channel.
    -- Release the latched CMD too (2026-07-15 stale-CMD audit): nil-ing only the
    -- request left the unconsumed 66 in gmem forever — and every CMD~=0 gate in
    -- the bridge (this rescan included) stays starved until a REAPER restart.
    if now - req.t > 2.0 then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 66 then reaper.gmem_write(G.CMD, 0) end
      _eon_autoexport = nil
    end
    return true
  end

  -- No pending request — scan for a Stretch pad that needs a source.
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then return false end
  for slot = 0, 15 do
    if pitch_slot_live(slot) then
      local id = math.floor(reaper.gmem_read(
        G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
      local tried = _eon_autoexport_tried[id]
      for pad = 0, 15 do
        -- Capture the pad-main (layer-0) source for any source-less Stretch OR
        -- Tuned pad. Stretch needs it for the realtime preload; Tuned needs it as
        -- the layer-0 bake source (layers 1+ are handled by poll_layer_export).
        -- poll_src_gen clears srcs[pad] when the JSFX swaps the audio, which is
        -- what re-arms this capture for a re-dropped pad.
        local _pm = pitch_slot_pad_mode(slot, pad)
        if _pm == STRETCH_MODE_STRETCH or _pm == STRETCH_MODE_TUNED then
          local srcs = _eon_src_paths[id]
          if srcs and srcs[pad] and srcs[pad] ~= "" then
            -- Already have a source (kit-load or a prior auto-export) — clear any
            -- backoff so a later mode toggle can re-export if the source is dropped.
            if tried then tried[pad] = nil end
          else
            local last = tried and tried[pad]
            if (not last) or (now - last) >= 1.0 then
              reaper.gmem_write(G.GS_PENDING_PITCH_INST, slot)
              reaper.gmem_write(G.PARAM1, pad)
              reaper.gmem_write(G.CMD, 66)
              if not tried then tried = {}; _eon_autoexport_tried[id] = tried end
              tried[pad] = now
              _eon_autoexport = { slot = slot, pad = pad, id = id, t = now }
              return true
            end
          end
        elseif tried and tried[pad] then
          tried[pad] = nil   -- pad left Stretch; drop its backoff
        end
      end
    end
  end
  return false
end

-- ── Per-layer source auto-capture (A4/A5) ────────────────────────────────────
-- The per-layer sibling of poll_autoexport: for the layers (1+) of TUNED layered
-- pads, capture each layer's ORIGINAL (unpitched) audio so the Extension can bake
-- it. Export via CMD 66 with the layer encoded in PARAM1 (layer*NUM_PADS+pad);
-- the JSFX refuses to export a layer whose bake anchor is already set (returns
-- len 0), so a capture during the bake-settle window always reads original audio.
-- Capture-once per (id,pad,layer); a layer that exports empty is retried up to a
-- few times (covers a brief load race) then given up — bounds CMD-channel use on
-- non-layered pads' phantom layers. Backoff is cleared when the pad leaves Tuned.
-- Owns the CMD channel while a request is in flight (returns true → caller
-- returns). Runs AFTER poll_autoexport so the two CMD-66 users serialize.
function poll_layer_export(now)   -- GLOBAL (200-local-limit escape hatch)
  -- Resolve a pending request first.
  if _eon_layer.export then
    local req = _eon_layer.export
    if math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      if pitch_slot_live(req.slot)
         and math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + req.slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0) == req.id then
        local len = math.floor(reaper.gmem_read(G.PARAM2) or 0)
        local sr  = math.floor(reaper.gmem_read(G.PARAM3) or 0)
        -- Same garbage/not-ready guard as poll_autoexport. len 0 = empty layer
        -- (or already baked) → leave unpublished; the bounded retry handles a
        -- genuinely-mid-load layer and then gives up on phantom layers.
        if len > 0 and sr >= 8000 and len >= 64 then
          if len > GMEM_AUDIO_MAX then len = GMEM_AUDIO_MAX end
          local buf = {}
          for j = 0, len - 1 do
            buf[#buf + 1] = pack_s16(reaper.gmem_read(G.AUDIO_BASE + j) or 0)
          end
          publish_layer_path_from_s16_bytes(req.pad, req.layer, 2, sr, table.concat(buf), req.id)
        end
      end
      _eon_layer.export = nil
      return false
    end
    -- Same latched-66 release as poll_autoexport's timeout (2026-07-15 audit).
    if now - req.t > 2.0 then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 66 then reaper.gmem_write(G.CMD, 0) end
      _eon_layer.export = nil
    end
    return true
  end

  -- No pending request — scan for a Tuned layered layer needing a source.
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then return false end
  for slot = 0, 15 do
    if pitch_slot_live(slot) then
      local id = math.floor(reaper.gmem_read(
        G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
      local tried = _eon_layer.export_tried[id]
      for pad = 0, 15 do
        if pitch_slot_pad_mode(slot, pad) == STRETCH_MODE_TUNED then
          local srcs = _eon_layer.src_paths[id]
          local pads = srcs and srcs[pad]
          for layer = 1, G.MAX_LAYERS - 1 do
            local have = pads and pads[layer] and pads[layer] ~= ""
            if not have then
              local tp = tried and tried[pad] and tried[pad][layer]
              -- tp = { t = last-attempt time, n = attempts }. Give up after 3.
              if (not tp) or ((tp.n < 3) and (now - tp.t) >= 2.0) then
                reaper.gmem_write(G.GS_PENDING_PITCH_INST, slot)
                reaper.gmem_write(G.PARAM1, layer * G.NUM_PADS + pad)  -- combined pad+layer
                reaper.gmem_write(G.CMD, 66)
                if not tried then tried = {}; _eon_layer.export_tried[id] = tried end
                if not tried[pad] then tried[pad] = {} end
                tried[pad][layer] = { t = now, n = (tp and tp.n or 0) + 1 }
                _eon_layer.export = { slot = slot, pad = pad, layer = layer, id = id, t = now }
                return true
              end
            end
          end
        elseif tried and tried[pad] then
          tried[pad] = nil   -- pad left Tuned; drop its capture backoff
        end
      end
    end
  end
  return false
end

-- Per-pad SOURCE-GENERATION watcher. The JSFX bumps STRETCH_PER_PAD_SRCGEN_BASE
-- for a pad whenever its audio is swapped by any JSFX-side route the bridge never
-- sees directly — grid/overlay drag-drop, browser load, pad clear. On a bump we
-- INVALIDATE the Extension's cached bake/preload source for that pad (drop the
-- retained path + capture backoff) so poll_autoexport / poll_layer_export grab the
-- NEW audio and republish it under a fresh unique temp path. Without this, switching
-- a re-dropped pad to Tuned/Stretch resurrects the OLD sample (the Extension keys
-- its decode cache on a path that was otherwise stable across the swap). Reads gmem
-- + mutates Lua tables only (no CMD channel) → always runs to completion, never
-- early-returns. GLOBAL (200-local-limit escape hatch), like poll_layer_export.
function poll_src_gen()   -- GLOBAL (200-local-limit escape hatch)
  local base = G.STRETCH_PER_PAD_SRCGEN_BASE
  for slot = 0, 15 do
    if pitch_slot_live(slot) then
      local id = math.floor(reaper.gmem_read(
        G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
      local seen = _eon_layer.src_gen[id]
      if not seen then seen = {}; _eon_layer.src_gen[id] = seen end
      for pad = 0, 15 do
        local g = math.floor(reaper.gmem_read(base + slot * G.STRETCH_CONTROL_INSTANCE_STRIDE + pad) or 0)
        local prev = seen[pad]
        if prev == nil then
          seen[pad] = g                       -- first sight: record, don't invalidate
        elseif g ~= prev then
          seen[pad] = g
          -- Audio changed under us → drop the Extension's stale source for this pad
          -- (both layer-0 and per-layer channels) + reset the capture backoff so the
          -- pollers re-capture the new audio and republish a fresh path string.
          local sp = _eon_src_paths[id];          if sp then sp[pad] = nil end
          local lp = _eon_layer.src_paths[id];    if lp then lp[pad] = nil end
          local at = _eon_autoexport_tried[id];   if at then at[pad] = nil end
          local lt = _eon_layer.export_tried[id]; if lt then lt[pad] = nil end
          -- Critically: BLANK the Extension's published source + baked output NOW.
          -- The Extension's bake dedup keys only on (tune, algo), so a same-tune
          -- sample swap would otherwise (a) bake the OLD source if it fires before
          -- the new path is re-captured, and (b) keep serving the stale baked WAV.
          -- An empty source path makes ensure_source_loaded return null → the
          -- Extension SKIPS the bake WITHOUT marking (tune,algo) done, so it re-bakes
          -- cleanly once poll_autoexport republishes the fresh source. Blanking the
          -- baked_ver/_path + resetting the swap shadow stops the bridge delivering
          -- the old bake during that re-capture gap (the first-hit-old symptom).
          local kp = "inst_" .. slot .. "_pad_" .. pad
          reaper.SetExtState("EON_Swing_Pitch", kp .. "_path", "", false)
          reaper.SetExtState("EON_Swing_Pitch", kp .. "_baked_path", "", false)
          reaper.SetExtState("EON_Swing_Pitch", kp .. "_baked_ver", "", false)
          local bs = _eon_baked_ver_shadow[slot]; if bs then bs[pad] = "" end
          local lbs = _eon_layer.baked_ver[slot] and _eon_layer.baked_ver[slot][pad]
          for layer = 1, G.MAX_LAYERS - 1 do
            local kl = kp .. "_layer_" .. layer
            reaper.SetExtState("EON_Swing_Pitch", kl .. "_path", "", false)
            reaper.SetExtState("EON_Swing_Pitch", kl .. "_baked_path", "", false)
            reaper.SetExtState("EON_Swing_Pitch", kl .. "_baked_ver", "", false)
            if lbs then lbs[layer] = "" end
          end
        end
      end
    end
  end
end

local function poll_pitch_bake_results()
  local now = reaper.time_precise()

  -- B1b: re-publish each live slot's RETAINED source paths under its current
  -- registry-slot ExtState key. Retention is keyed by stable instance_id (set in
  -- publish_pitch_path at kit-load); here we map slot -> live instance_id and
  -- write inst_<slot>_pad_<M>_path. Running continuously with the registry
  -- settled is what makes a 2nd instance work: its source publishes as soon as it
  -- registers, even though its slot wasn't known at load time. Dedup'd — only
  -- writes ExtState on change, so steady-state cost is cheap reads.
  for slot = 0, 15 do
    if pitch_slot_live(slot) then
      local id = math.floor(reaper.gmem_read(
        G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
      -- Slot reuse: a different instance now owns this slot — drop stale dedup so
      -- the new occupant's paths republish fresh.
      if _eon_published_src_id[slot] ~= id then
        _eon_published_src[slot] = {}
        _eon_published_src_id[slot] = id
      end
      local srcs = _eon_src_paths[id]
      if srcs then
        local pub = _eon_published_src[slot]
        for pad = 0, 15 do
          local p = srcs[pad]
          if p and pub[pad] ~= p then
            reaper.SetExtState("EON_Swing_Pitch",
              "inst_" .. slot .. "_pad_" .. pad .. "_path", p, false)
            pub[pad] = p
          end
        end
      end

      -- A4/A5: republish retained per-LAYER source paths the same way (keyed by
      -- the same stable instance_id, written under the live registry slot key).
      if _eon_layer.pub_id[slot] ~= id then
        _eon_layer.pub[slot] = {}
        _eon_layer.pub_id[slot] = id
      end
      local lsrcs = _eon_layer.src_paths[id]
      if lsrcs then
        local lpub = _eon_layer.pub[slot]
        for pad = 0, 15 do
          local pl = lsrcs[pad]
          if pl then
            local pubpad = lpub[pad]
            if not pubpad then pubpad = {}; lpub[pad] = pubpad end
            for layer = 1, G.MAX_LAYERS - 1 do
              local lp = pl[layer]
              if lp and pubpad[layer] ~= lp then
                reaper.SetExtState("EON_Swing_Pitch",
                  "inst_" .. slot .. "_pad_" .. pad .. "_layer_" .. layer .. "_path", lp, false)
                pubpad[layer] = lp
              end
            end
          end
        end
      end
    end
  end

  -- A4/A5: detect each pad leaving Tuned so its layers 1+ (which hold pitched
  -- audio) get reverted to original. Layer 0 reverts via the existing Extension
  -- SP_PITCH_MODE_REVERT_PAD path below; this only covers the higher layers. Runs
  -- every tick (independent of the CMD channel) — it only QUEUES; the drain in the
  -- swap section does one revert per tick. A layer is queued only if it was baked
  -- (its baked-ver shadow is non-empty).
  for slot = 0, 15 do
    if pitch_slot_live(slot) then
      local mshadow = _eon_layer.mode_shadow[slot]
      for pad = 0, 15 do
        local m = pitch_slot_pad_mode(slot, pad)
        if mshadow[pad] == STRETCH_MODE_TUNED and m ~= STRETCH_MODE_TUNED then
          local pend = _eon_layer.revert_pending[slot][pad]
          local lsh  = _eon_layer.baked_ver[slot][pad]
          for layer = 1, G.MAX_LAYERS - 1 do
            if lsh[layer] ~= "" then pend[layer] = true end
          end
        end
        mshadow[pad] = m
      end
    end
  end

  -- Invalidate the Extension's cached source for any pad whose JSFX audio was
  -- swapped since last tick (grid/overlay drop, browser load, clear) so the
  -- capture pollers below re-grab the new audio. No CMD channel — runs always.
  poll_src_gen()

  -- Auto-export a source for any source-less Stretch pad before staging swaps.
  -- Owns the shared CMD channel while a request is in flight, so it runs first
  -- and short-circuits the rest of the poll until its result is read.
  if poll_autoexport(now) then return end

  -- A4/A5: capture original layer sources for Tuned layered pads (also CMD 66 —
  -- runs after poll_autoexport so the two serialize on the shared channel).
  if poll_layer_export(now) then return end

  -- B1b: don't stage a new pad-audio swap while the previous CMD is still
  -- unconsumed. The gmem AUDIO staging band + CMD/PARAM1 channel are shared
  -- across instances and commands, so overwriting them before the target
  -- copies would corrupt the swap (and could clobber an in-flight kit-load
  -- CMD). Wait for the JSFX to clear CMD back to 0.
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then return end

  -- Per-instance bake injection. The Extension publishes each Tuned bake under
  -- inst_<slot>_pad_<M>_baked_{ver,path}, keyed by REGISTRY SLOT, for every live
  -- slot. Scan live slots; on the first eligible fresh bake, route the swap to
  -- that instance via GS_PENDING_PITCH_INST so only it consumes CMD 65. ONE swap
  -- per tick (shared channel): break out of both loops and let the next ~33ms
  -- tick round-robin to the next (slot, pad) — their shadows still differ.
  local done = false
  for slot = 0, 15 do
    if done then break end
    if pitch_slot_live(slot) then
      local ver_shadow = _eon_baked_ver_shadow[slot]
      local swap_t     = _eon_last_swap_t[slot]
      for pad = 0, 15 do
        local ver = reaper.GetExtState("EON_Swing_Pitch",
          "inst_" .. slot .. "_pad_" .. pad .. "_baked_ver")
        if ver and ver ~= "" and ver ~= ver_shadow[pad] then
          if (now - swap_t[pad]) * 1000 >= _eon_swap_throttle_ms then
            local path = reaper.GetExtState("EON_Swing_Pitch",
              "inst_" .. slot .. "_pad_" .. pad .. "_baked_path")
            local swap_len = path and path ~= "" and load_audio_to_pad(path, pad, true)
            if swap_len and swap_len ~= true and swap_len > 0 then
              reaper.gmem_write(G.GS_PENDING_PITCH_INST, slot)  -- route to this instance
              reaper.gmem_write(G.PARAM1, pad)
              reaper.gmem_write(G.PARAM3, swap_len)  -- staged at AUDIO+0 (CMD-67 protocol)
              reaper.gmem_write(G.CMD, 65)
              ver_shadow[pad] = ver
              swap_t[pad]     = now
              done = true
              break
            end
            -- load failed: leave shadow + clock so we retry next tick.
          end
        end
      end
    end
  end

  -- A4/A5: per-LAYER bake injection (layers 1+). Same structure as the pad-main
  -- swap above but keyed by inst_<slot>_pad_<M>_layer_<L>_baked_{ver,path} and
  -- delivered via CMD 67. Only runs if the pad-main loop didn't already swap this
  -- tick (one swap per tick — shared CMD channel).
  if not done then
    for slot = 0, 15 do
      if done then break end
      if pitch_slot_live(slot) then
        local lshadow = _eon_layer.baked_ver[slot]
        for pad = 0, 15 do
          if done then break end
          local padshadow = lshadow[pad]
          for layer = 1, G.MAX_LAYERS - 1 do
            local ver = reaper.GetExtState("EON_Swing_Pitch",
              "inst_" .. slot .. "_pad_" .. pad .. "_layer_" .. layer .. "_baked_ver")
            if ver and ver ~= "" and ver ~= padshadow[layer] then
              local path = reaper.GetExtState("EON_Swing_Pitch",
                "inst_" .. slot .. "_pad_" .. pad .. "_layer_" .. layer .. "_baked_path")
              if path and path ~= "" then
                local len = _eon_stage_layer_audio(path)
                if len > 0 then
                  reaper.gmem_write(G.GS_PENDING_PITCH_INST, slot)
                  reaper.gmem_write(G.PARAM1, pad)
                  reaper.gmem_write(G.PARAM2, layer)   -- slot 2 = layer
                  reaper.gmem_write(G.PARAM3, len)     -- slot 3 = interleaved len
                  reaper.gmem_write(G.CMD, 67)
                  padshadow[layer] = ver
                  done = true
                  break
                end
                -- stage failed: leave shadow so we retry next tick.
              end
            end
          end
        end
      end
    end
  end

  -- A4/A5: drain ONE pending per-layer revert (set on a Tuned->non-Tuned flip).
  -- Restores the layer's ORIGINAL audio (retained capture) via CMD 67. If no
  -- retained source exists (e.g. after a REAPER restart) we still clear the
  -- pending+shadow so the revert makes progress — that layer stays pitched until
  -- the user re-tunes (which re-bakes it), better than wedging the channel.
  if not done then
    for slot = 0, 15 do
      if done then break end
      for pad = 0, 15 do
        if done then break end
        local pend = _eon_layer.revert_pending[slot][pad]
        for layer = 1, G.MAX_LAYERS - 1 do
          if pend[layer] then
            local id = math.floor(reaper.gmem_read(
              G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
            local lsrcs = _eon_layer.src_paths[id]
            local lp = lsrcs and lsrcs[pad] and lsrcs[pad][layer]
            if lp and lp ~= "" then
              local len = _eon_stage_layer_audio(lp)
              if len > 0 then
                reaper.gmem_write(G.GS_PENDING_PITCH_INST, slot)
                reaper.gmem_write(G.PARAM1, pad)
                reaper.gmem_write(G.PARAM2, layer)
                reaper.gmem_write(G.PARAM3, len)
                reaper.gmem_write(G.CMD, 67)
                done = true
              end
            end
            pend[layer] = nil
            _eon_layer.baked_ver[slot][pad][layer] = ""  -- re-bake on Tuned re-entry
            if done then break end
          end
        end
      end
    end
  end

  -- Mode-flip-out-of-Tuned revert (A+ multi-instance). The Extension writes
  -- SP_PITCH_MODE_REVERT_PAD = pad — a SINGLETON with no instance dimension —
  -- when it sees a pad flip Tuned->other on some slot. To restore the ORIGINAL
  -- audio on the RIGHT instance (and never un-pitch a sibling that is STILL
  -- Tuned on the same pad), pick the slot we'd pitched (shadow set) whose LIVE
  -- MODE band for this pad is no longer Tuned. Skipped if a bake swap already
  -- fired this tick (shared CMD channel) — revert_pad persists for the next tick.
  if not done then
    local revert_pad = math.floor(reaper.gmem_read(core.GMEM.SP_PITCH_MODE_REVERT_PAD) or -1)
    if revert_pad >= 0 and revert_pad < 16 then
      for slot = 0, 15 do
        if _eon_baked_ver_shadow[slot][revert_pad] ~= ""
           and pitch_slot_pad_mode(slot, revert_pad) ~= STRETCH_MODE_TUNED then
          local orig = reaper.GetExtState("EON_Swing_Pitch",
            "inst_" .. slot .. "_pad_" .. revert_pad .. "_path")
          local rev_len = orig and orig ~= "" and load_audio_to_pad(orig, revert_pad, true)
          if rev_len and rev_len ~= true and rev_len > 0 then
            reaper.gmem_write(G.GS_PENDING_PITCH_INST, slot)
            reaper.gmem_write(G.PARAM1, revert_pad)
            reaper.gmem_write(G.PARAM3, rev_len)  -- staged at AUDIO+0 (CMD-67 protocol)
            reaper.gmem_write(G.CMD, 65)
            -- Reset this slot's baked shadow so re-entering Tuned with the SAME
            -- shift re-loads (we just overwrote the staged buffer with original).
            _eon_baked_ver_shadow[slot][revert_pad] = ""
            _eon_last_swap_t[slot][revert_pad] = now
          end
          break   -- one swap per tick (shared channel)
        end
      end
      -- Ack regardless: the bridge doesn't retry mode-flips. If no pitched slot
      -- matched (nothing to restore) or the original WAV was missing, clearing
      -- the request is still correct — JSFX keeps current audio.
      reaper.gmem_write(core.GMEM.SP_PITCH_MODE_REVERT_PAD, -1)
    end
  end
end

-- HSL to RGB (returns 0-255 ints for REAPER ColorToNative)
-- Handles B/W sentinel values: -2 = black, -1 = white (from overlay color picker)
local function hsl_to_rgb(h, s, l)
  if h <= -1.5 then return 51, 51, 56 end   -- black  (matches JSFX 0.20, 0.20, 0.22)
  if h < 0     then return 209, 209, 217 end -- white  (matches JSFX 0.82, 0.82, 0.85)
  local r, g, b = core.hsl_to_rgb(h, s, l)
  return math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5)
end

-- Check if an FX slot is a Swing instance
local function is_swing_fx(tr, fx)
  if _eon_perf then _eon_perf.probes = _eon_perf.probes + 1 end
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if retval and ident:find("DrumKit_ReaKit") then return true end
  if fname:find("DrumKit_ReaKit") then return true end
  if fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad") then return true end
  return false
end

-- EON: detect the StepSeq JSFX (forked megababy "EON Step Sequencer"). Declared
-- module-GLOBAL (no `local`) on purpose — this bridge main chunk is at Lua's
-- 200-local limit. Used by same-track auto-pairing and (later) the manual picker.
-- fx_ident matches the .jsfx filename; the name fallbacks cover the JS: display name.
function is_stepseq_fx(tr, fx)
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and ident:find("EON_StepSeq") then return true end
  if fname:find("EON_StepSeq") then return true end
  if fname:find("EON Steppa") then return true end
  if fname:find("EON Step Sequencer") then return true end   -- pre-Steppa display name
  return false
end

-- Find the Swing instance that currently holds the gmem lock (slider4 = instance_id)
-- Falls back to first Swing found if no lock or lock doesn't match
local function find_swing_track()
  if _eon_perf then _eon_perf.walks = _eon_perf.walks + 1 end
  local lock_id = math.floor(reaper.gmem_read(G.LOCK))
  local first_tr, first_fx = nil, nil

  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        -- Check if this instance's slider4 matches the lock
        if lock_id > 0 then
          local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
          if inst_id == lock_id then
            if reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN") < 32 then
              reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", 32)
            end
            return tr, fx
          end
        end
        if not first_tr then first_tr, first_fx = tr, fx end
      end
    end
  end
  -- Ensure 32 channels on the Swing track for multi-out routing
  if first_tr and reaper.GetMediaTrackInfo_Value(first_tr, "I_NCHAN") < 32 then
    reaper.SetMediaTrackInfo_Value(first_tr, "I_NCHAN", 32)
  end
  return first_tr, first_fx
end

-- ═════════════════════════════════════════════════════════════════════════════
-- KIT-LEVEL UNDO (disk-based)
-- Before a kit load / New Kit / Clear All, ask the JSFX to silently dump its
-- CURRENT live kit (CMD 83 → export state 11 → CMD 1), write it to a
-- per-instance temp .swing next to the auto-sidecars, ack with CMD 85
-- (LOCK-preserving). Orange UNDO on a kit op fires CMD 82 → reload that file.
-- Captures LIVE state (unsaved edits, scratch kits) — unlike a source-file
-- copy. 1-level: the file is overwritten on each kit op.
-- ═════════════════════════════════════════════════════════════════════════════
local kit_undo_avail = {}   -- guid -> undo .swing path (armed after a dump)
local kit_undo_job   = nil  -- in-flight dump: {phase, guid, inst, deadline, after}

local function get_undo_sidecar_path(guid)
  if not guid or guid == "" then return nil end
  local tok = guid:match("[%x]+") or ""
  tok = tok:sub(1, 8)
  if tok == "" then return nil end
  local _, proj_filename = reaper.EnumProjects(-1)
  if not proj_filename or proj_filename == "" then return nil end
  local proj_dir = proj_filename:match("(.*[/\\])")
  if not proj_dir then return nil end
  local dir = proj_dir .. "Swing"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. core.sep .. "swing_" .. tok .. "_undo.swing"
end

-- Resolve the instance that owns the current operation (mirrors
-- load_swing_dispatch's order: LOCK -> PENDING_LOAD_INST -> INSTANCE) and its
-- track GUID. Returns inst_id, guid (either may be nil).
local function resolve_undo_target()
  local lock_id    = math.floor(reaper.gmem_read(G.LOCK) or 0)
  local pending_id = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0)
  local inst_gmem  = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  local target = lock_id > 0 and lock_id or (pending_id > 0 and pending_id) or inst_gmem
  if target <= 0 then return nil, nil end
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        if inst_id == target then
          return target, reaper.GetTrackGUID(tr)
        end
      end
    end
  end
  return target, nil
end

-- Kick off a silent dump of the target instance's live kit. `after(ok)` runs
-- when the dump completes/fails; the job is driven by kit_undo_job_tick().
-- Never blocks a load: every failure path still calls after(false).
local function start_kit_undo_dump(after)
  if kit_undo_job or pending_export then after(false) return end
  local inst, guid = resolve_undo_target()
  local upath = guid and get_undo_sidecar_path(guid)
  if not upath then after(false) return end
  -- nothing loaded = nothing to undo to; skip (e.g. fresh-instance auto-808)
  local any_audio = 0
  for pad = 0, G.NUM_PADS - 1 do
    any_audio = any_audio + (reaper.gmem_read(G.AUDIOLEN_BASE + pad) or 0)
  end
  if any_audio <= 0 then after(false) return end
  pending_export = { filepath = upath, undo_dump = true, author = "", desc = "kit-undo snapshot" }
  kit_undo_job = { phase = 1, guid = guid, inst = inst, upath = upath,
                   after = after, deadline = reaper.time_precise() + 2.5 }
  reaper.gmem_write(G.CMD, 83)
end

-- Per-tick driver for the in-flight dump job. Phase 1: waiting for the JSFX
-- to stage + CMD=1 (the cmd==1 branch writes the file, acks CMD 85, flips us
-- to phase 2). Phase 2: waiting for the JSFX to consume the 85 (CMD back to
-- 0) so the follow-up load can't collide on the mailbox.
local function kit_undo_job_tick()
  if not kit_undo_job then return end
  local j = kit_undo_job
  local c = math.floor(reaper.gmem_read(G.CMD) or 0)
  if j.phase == 1 then
    -- Late completion: the JSFX finished staging just as/after we timed out and
    -- emitted CMD 84. Ack it (85) so it returns to idle instead of stranding in
    -- export state 3 with kit_busy=1 — the wedge the old CMD-1 ack hole caused.
    if c == 84 then
      pending_export = nil
      kit_undo_job = nil
      reaper.gmem_write(G.CMD, 85)
      j.after(false)                                  -- no undo coverage, but clean
    elseif reaper.time_precise() > j.deadline then
      kit_undo_job = nil
      pending_export = nil
      -- c==83: JSFX never caught it (old build / @gfx starved). c==84 handled
      -- above. Anything else: leave the mailbox for its own handler.
      if c == 83 then reaper.gmem_write(G.CMD, 0) end
      j.after(false)                                  -- proceed without undo coverage
    end
  elseif j.phase == 2 then
    if c == 0 or reaper.time_precise() > j.deadline then
      kit_undo_job = nil
      if j.inst and j.inst > 0 then reaper.gmem_write(G.LOCK, j.inst) end
      j.after(true)
    end
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- FOLDER TRACK HELPERS
-- ═════════════════════════════════════════════════════════════════════════════

-- Find the folder track that parents the Swing track (if multi-out was built)
local function find_folder_track(swing_track)
  if not swing_track then return nil end
  local sw_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, "IP_TRACKNUMBER")) - 1
  if sw_idx < 1 then return nil end
  local above = reaper.GetTrack(0, sw_idx - 1)
  if not above then return nil end
  local depth = reaper.GetMediaTrackInfo_Value(above, "I_FOLDERDEPTH")
  if depth == 1 then return above end
  return nil
end

-- Find the audio multi-out SUB-folder track: the track immediately AFTER Swing
-- with FOLDERDEPTH=1. This is the new layout — Swing's parent folder contains
-- the Swing JSFX track + an audio sub-folder (holding the 16 multi-outs) +
-- the Drum Matrix folder. Returns nil for the legacy layout where multi-outs
-- live directly under the parent as siblings of Swing.
local function find_audio_subfolder(swing_track)
  if not swing_track then return nil end
  local sw_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, "IP_TRACKNUMBER")) - 1
  local next_tr = reaper.GetTrack(0, sw_idx + 1)
  if not next_tr then return nil end
  local depth = reaper.GetMediaTrackInfo_Value(next_tr, "I_FOLDERDEPTH")
  if depth ~= 1 then return nil end
  -- The track right after Swing is a sub-folder header — but it might be the
  -- Drum Matrix (MIDI) folder, NOT the audio sub. When DM is built FIRST it
  -- sits immediately after Swing at depth 1; without this guard the audio build
  -- mistook it for the audio sub, dumped the 16 multi-outs inside the MIDI
  -- folder, and double-tagged the DM header. Reject anything carrying the DM
  -- tag so MIDI-first builds get their own Audio sub created (mirrors how
  -- folder_layout.FindDMSubfolder identifies the MIDI sub structurally by tag).
  local _, dm = reaper.GetSetMediaTrackInfo_String(next_tr, "P_EXT:EON_DRUM_KIT_FOLDER", "", false)
  if dm and dm ~= "" then return nil end
  return next_tr
end

-- Paint the three SESSION-track identities — color + tinted EON glyph — on the
-- Swing engine track, the Audio sub-folder, and the MIDI (Drum Matrix) sub-
-- folder. The glyphs (engine/audio_bus/midi_bus, drawn by Swing/icons/
-- gen_icons.py) tint to follow each track's color via resolve_tinted, exactly
-- like the pad/lane icons. Color is guarded by P_EXT:EON_COLOR_AUTO (we set our
-- brand color when the track is uncolored or still wears the color WE set; once
-- the user recolors, we back off) and the icon by rk_lua_icons.apply's
-- EON_ICON_AUTO guard. Declared module-GLOBAL (no `local`) on purpose: this main
-- chunk sits near Lua's 200-local ceiling, so a global adds zero local slots.
function bridge_reflect_struct(swing_track)
  if not swing_track then return end
  local function paint(track, native, category)
    if not track then return end
    -- Guarded color: honour a user recolor, else (re)assert our brand color.
    local cur  = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR"))
    local _, a = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:EON_COLOR_AUTO", "", false)
    local an   = tonumber(a)
    if (cur & 0x1000000) == 0 or (an and cur == an) then
      if cur ~= native then reaper.SetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR", native) end
      if an ~= native then
        reaper.GetSetMediaTrackInfo_String(track, "P_EXT:EON_COLOR_AUTO", tostring(native), true)
      end
    end
    -- Guarded, color-tinted icon (resolve_tinted snaps to the track-color hue).
    if _bridge_icons then
      local tcol = reaper.GetMediaTrackInfo_Value(track, "I_CUSTOMCOLOR")
      local icon = (_bridge_icons.resolve_tinted and _bridge_icons.resolve_tinted(category, tcol))
                   or (_bridge_icons.resolve and _bridge_icons.resolve(category)) or ""
      if _bridge_icons.apply then _bridge_icons.apply(track, icon)
      else reaper.GetSetMediaTrackInfo_String(track, "P_ICON", icon, true) end
    end
  end
  -- Parent housing recedes: neutral charcoal → resolve_tinted's grey guard
  -- leaves the groovebox glyph plain white, so it frames the colourful children.
  paint(find_folder_track(swing_track), reaper.ColorToNative(52, 52, 58) | 0x1000000, "groovebox")
  paint(swing_track, reaper.ColorToNative(255, 140, 50) | 0x1000000, "engine")
  paint(find_audio_subfolder(swing_track), reaper.ColorToNative(62, 107, 140) | 0x1000000, "audio_bus")
  local dm = folder_layout and folder_layout.FindDMSubfolder and folder_layout.FindDMSubfolder(swing_track)
  paint(dm, reaper.ColorToNative(122, 94, 168) | 0x1000000, "midi_bus")
end

-- Read current kit name from gmem
local function read_kit_name_from_gmem()
  return core.gmem_read_string(NAME_BASE, G.NAMELEN, 32)
end

-- Keep the parent folder's kit label current. The canonical layout is:
--   * `Swing — <kit>` — the PARENT folder (carries the live instrument+kit
--                       label; this is the only kit-dependent name).
--   * `Swing`         — the JSFX engine track.
--   * `Audio`         — the audio multi-out sub-folder (built here).
--   * `MIDI`          — the Drum Matrix MIDI-lane sub-folder (built by
--                       EON_DM_Build.lua, tagged P_EXT:EON_DRUM_KIT_FOLDER so
--                       folder_layout can find it).
-- Only the parent follows the live kit name; the sub-folder names are static
-- functional labels (kept idempotent/self-healing here). Pre-rename the kit
-- name rode the audio sub-folder and the parent stayed blank.
local function update_folder_track_name(swing_track, explicit_name)
  -- explicit_name (Phase 2): the gmem name cells are a browser-target-only
  -- mirror — for a load delivered to a NON-browser-bound instance they hold
  -- the wrong (stale) kit. The load queue passes the loaded kit's name
  -- explicitly at ack time; other callers keep the gmem read.
  local kit_name  = (explicit_name and explicit_name ~= "") and explicit_name
                 or read_kit_name_from_gmem()
  local kit_label = (kit_name ~= "" and kit_name) or "Sampler"
  local parent_label = "Swing — " .. kit_label

  -- Naming scheme: the PARENT carries the live instrument+kit label; the
  -- sub-folders use static functional names ("Audio" / "MIDI") since the kit
  -- already shows on the parent (repeating it there is noise). Pre-rename the
  -- parent stayed blank and the kit name rode the audio sub-folder — inverted
  -- here for a cleaner TCP. Setting the static names every sync is harmless
  -- (idempotent) and self-heals a sub created/renamed wrong.
  local audio_sub = find_audio_subfolder(swing_track)
  if audio_sub then
    reaper.GetSetMediaTrackInfo_String(audio_sub, "P_NAME", "Audio", true)
  end
  if folder_layout and folder_layout.FindDMSubfolder then
    local dm_sub = folder_layout.FindDMSubfolder(swing_track)
    if dm_sub then
      reaper.GetSetMediaTrackInfo_String(dm_sub, "P_NAME", "MIDI", true)
    end
  end
  -- Name the parent when Swing is in a folder (whether or not sub-folders
  -- exist yet — e.g. DM built before multi-out, or multi-out before DM).
  local folder = find_folder_track(swing_track)
  if folder then
    reaper.GetSetMediaTrackInfo_String(folder, "P_NAME", parent_label, true)
  end
  -- Same pass paints the three session-track icons + colors (engine / audio /
  -- MIDI). Idempotent + guarded, so this is safe on every name sync.
  bridge_reflect_struct(swing_track)
end

-- Sync pad names from gmem to MIDI piano roll + multi-out child tracks.
-- Shared by CMD 48 (post-undo) and CMD 52 (explicit sync_note_names).
local function sync_names_and_tracks(swing_track)
  if not swing_track then return end
  -- P4-2: redundant while the per-instance identity refresher is servicing
  -- slotted instances — it writes each instance's OWN piano-roll note names
  -- (edge-triggered) and child names/colors. This legacy writer only ever
  -- served the ACTIVE instance and clears all 128 note names wholesale.
  if _ident_active or _ident_seen then return end
  local pad_names_l = {}
  local pad_notes_l = {}
  for i = 0, G.NUM_PADS - 1 do
    local name = ""
    for j = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + i * G.PADNAME_LEN + j))
      if c > 0 then name = name .. string.char(c) end
    end
    pad_names_l[i] = name
    pad_notes_l[i] = math.floor(reaper.gmem_read(G.META_BASE + i * G.META_PP + 10))
  end
  for n = 0, 127 do
    reaper.SetTrackMIDINoteNameEx(0, swing_track, n, 0, "")
  end
  for i = 0, G.NUM_PADS - 1 do
    local note = pad_notes_l[i]
    if note >= 0 and note <= 127 and #pad_names_l[i] > 0 then
      reaper.SetTrackMIDINoteNameEx(0, swing_track, note, 0, pad_names_l[i])
    end
  end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends >= G.NUM_PADS then
    reaper.PreventUIRefresh(1)
    for s = 0, sends - 1 do
      local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
      if pad >= 0 then
        -- (nesting kept: core.srcchan_pad already rejects no-audio and odd channels)
        if pad >= 0 and pad < G.NUM_PADS then
          local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
          if dest_tr then
            local pname = pad_names_l[pad]
            if pname == "" or pname == string.format("Pad %d", pad + 1) then
              pname = string.format("%02d", pad + 1)
            end
            reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", pname, true)
            _lane_rename_touch()  -- CMD-48/52 renamer: the primary SWS trigger on kit load
          end
        end
      end
    end
    reaper.PreventUIRefresh(-1)
  end
end

-- ─── EON StepSeq → multi-out track Mute/Solo mirror ──────────────────────────
-- EON_StepSeq.jsfx publishes per-pad lane mute/solo to gmem (2710/2730) plus an
-- advancing heartbeat (2700). While the heartbeat advances (StepSeq GUI live),
-- drive each pad's multi-out child track B_MUTE / I_SOLO from it. When StepSeq
-- goes away (heartbeat stalls), RELEASE only the mute/solo this mirror applied —
-- never clobber the user's own track mute/solo.
local ss_last_alive  = nil
local ss_alive_stall = 0
local ss_applied     = {}   -- pad → { m = appliedMute, s = appliedSolo }

local function eon_mirror_stepseq_ms(swing_track)
  if not swing_track then return end
  local alive = math.floor(reaper.gmem_read(EON_SS_ALIVE) or 0)
  local live
  if alive ~= ss_last_alive then
    ss_last_alive = alive; ss_alive_stall = 0; live = true
  else
    ss_alive_stall = ss_alive_stall + 1
    live = ss_alive_stall < 20            -- tolerate a few stalled polls before "dead"
  end
  if (not live) and next(ss_applied) == nil then return end   -- nothing to do

  local sends = reaper.GetTrackNumSends(swing_track, 0)
  for s = 0, sends - 1 do
    local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if pad >= 0 then
      -- (nesting kept: core.srcchan_pad already rejects no-audio and odd channels)
      if pad >= 0 and pad < G.NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr and reaper.ValidatePtr(dest_tr, 'MediaTrack*') then
          local want_m, want_s
          if live then
            want_m = (math.floor(reaper.gmem_read(EON_SS_MUTE_BASE + pad) or 0) > 0) and 1 or 0
            want_s = (math.floor(reaper.gmem_read(EON_SS_SOLO_BASE + pad) or 0) > 0) and 1 or 0
          else
            want_m, want_s = 0, 0          -- StepSeq gone → release what we set
          end
          local prev = ss_applied[pad]
          if live or (prev and prev.m == 1) then
            if (reaper.GetMediaTrackInfo_Value(dest_tr, "B_MUTE") or 0) ~= want_m then
              if reaper.GetExtState("EON_Bridge","debug_ms")=="1" then reaper.ShowConsoleMsg(("[ms] LEGACY mute pad %d -> %d\n"):format(pad, want_m)) end
              reaper.SetMediaTrackInfo_Value(dest_tr, "B_MUTE", want_m)
            end
          end
          if live or (prev and prev.s == 1) then
            local cur_s = ((reaper.GetMediaTrackInfo_Value(dest_tr, "I_SOLO") or 0) > 0) and 1 or 0
            if cur_s ~= want_s then
              reaper.SetMediaTrackInfo_Value(dest_tr, "I_SOLO", want_s)
            end
          end
          if live and (want_m == 1 or want_s == 1) then
            ss_applied[pad] = { m = want_m, s = want_s }
          else
            ss_applied[pad] = nil
          end
        end
      end
    end
  end
  if not live then ss_applied = {} end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- KIT EXPORT (CMD 10 → 11 → 1)
-- ═════════════════════════════════════════════════════════════════════════════

-- Read back the metadata a promptless save has no dialog to ask for. `author`
-- exists ONLY in the prompt → pending_export table today — nothing retains it
-- after a load — so re-read it from the file we are about to overwrite,
-- exactly the pattern eon_kit_cover_for_save uses for the artwork tail.
-- Without this, one silent SAVE would quietly blank a kit's credit line.
-- The v4/v5 body is Lua source, so the field is a plain quoted assignment
-- (core.lua_quote emits double quotes; single-quote form accepted for
-- hand-edited kits). Missing/unparseable file ⇒ "", same as a fresh save.
--
-- `desc` now round-trips too (write_kit_v4/v5 emit it), so a promptless save
-- recovers it exactly like the credit line. `created` is recovered by the
-- WRITERS rather than here — see write_kit_v4 — because every save route has
-- to preserve it, not just the promptless one.
function eon_kit_meta_from_file(filepath, field)
  if not filepath or filepath == "" or not field or field == "" then return "" end
  local f = io.open(filepath, "rb")
  if not f then return "" end
  -- Header only: pad blobs (and any binary tail) run to megabytes, and the
  -- metadata block is always at the top. 16 KB covers the short fields plus a
  -- long hand-written description.
  local head = f:read(16384) or ""
  f:close()

  -- Anchored to a line start: every metadata field is written on its own line,
  -- and core.lua_quote turns real newlines into the two characters \ and n, so
  -- no VALUE can contain one. Without the anchor an author string containing
  -- `created = "..."` would shadow the field written below it.
  local _, qpos = head:find("\n%s*" .. field .. "%s*=%s*")
  if not qpos then return "" end
  local q = head:sub(qpos + 1, qpos + 1)
  if q ~= '"' and q ~= "'" then return "" end

  -- Walk to the closing quote HONOURING BACKSLASH ESCAPES. A plain
  -- '([^"]*)' pattern stops at the first \" inside the value, and that
  -- truncated read gets written straight back by the next silent save — i.e.
  -- it would corrupt the very field this exists to preserve. core.lua_quote
  -- escapes \ " \n \r, so those are what we undo.
  local i, out = qpos + 2, {}
  while i <= #head do
    local c = head:sub(i, i)
    if c == "\\" then
      local e = head:sub(i + 1, i + 1)
      out[#out + 1] = (e == "n" and "\n") or (e == "r" and "\r") or e
      i = i + 2
    elseif c == q then
      return table.concat(out)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return ""   -- unterminated (truncated header / binary v5 zip) ⇒ treat as absent
end

function eon_kit_author_from_file(filepath)
  return eon_kit_meta_from_file(filepath, "author")
end

local function do_export_name_prompt()
  -- Everything downstream of the NAME prompt, so the prompt itself can be async.
  -- Reached from both the styled form (values arrive in a table) and the native
  -- GetUserInputs fallback (values arrive from the CSV split), so it trims its
  -- own inputs rather than trusting either caller.
  local function proceed(kit_name, author, desc)
    kit_name = (kit_name or ""):match("^%s*(.-)%s*$")
    author   = (author   or ""):match("^%s*(.-)%s*$")
    desc     = (desc     or ""):match("^%s*(.-)%s*$")

    if kit_name == "" then
      eon_notice("Kit name cannot be empty.")
      reaper.gmem_write(G.CMD, 98)
      return
    end

    local filename = kit_name:gsub('[<>:"/\\|%?%*]', '_')
    local kits_dir = core.get_kits_dir()
    local filepath = kits_dir .. core.sep .. filename .. ".swing"

    -- Everything past the overwrite decision, so the confirm can be async too.
    local function commit()
      core.gmem_write_string(kit_name, NAME_BASE, G.NAMELEN, 32)

      pending_export = {
        filepath = filepath, kit_name = kit_name,
        author = author, desc = desc, filename = filename
      }

      reaper.gmem_write(G.CMD, 11)
    end

    local f_check = io.open(filepath, "rb")
    if not f_check then commit() return end
    f_check:close()
    -- See eon_confirm_cmd: async when ReaImGui is present (CMD parks at 97),
    -- native-blocking when it isn't. Both paths run one of the callbacks, so
    -- there is nothing to do after the call but return.
    eon_confirm_cmd('"' .. filename .. '.swing" exists. Overwrite?', "Overwrite",
      commit,
      function() reaper.gmem_write(G.CMD, 98) end)
  end

  -- Styled form first. This is the box the whole save flow OPENS with, so
  -- leaving it native made the styled overwrite confirm behind it invisible.
  -- ⭐It also fixes a real defect: GetUserInputs returns its fields CSV-encoded,
  -- so a kit name (or author, or description) containing a comma is split at
  -- the comma and silently mangled. The form hands back a keyed table instead,
  -- and has no such limit.
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.open and eon_dlg.open({
    title = "Save Swing Kit", width = 420, ok_label = "Save",
    fields = {
      { key = "name",   label = "Kit Name:",              value = "My Kit" },
      { key = "author", label = "Author (optional):",     value = "" },
      { key = "desc",   label = "Description (optional):", value = "" },
    },
    on_ok     = function(v) proceed(v.name, v.author, v.desc) end,
    on_cancel = function() reaper.gmem_write(G.CMD, 98) end,
  })
  if shown then
    reaper.gmem_write(G.CMD, 97)   -- park the mailbox while the form is up
    return
  end

  -- Native fallback (no ReaImGui) — unchanged behaviour, comma limit included.
  local retval, csv = reaper.GetUserInputs(
    "Save Swing Kit", 3,
    "Kit Name:,Author (optional):,Description (optional):,extrawidth=220",
    "My Kit,,"
  )
  if not retval then
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local fields = {}
  for field in (csv .. ","):gmatch("(.-),") do
    fields[#fields + 1] = field
  end
  proceed(fields[1], fields[2], fields[3])
end

-- CMD 12: SAVE IN PLACE. Overwrite the kit this instance was loaded from, no
-- dialog, no overwrite confirm — the whole point is that re-saving a kit you
-- are already working on costs one click.
--
-- Deflects to the CMD 10 prompt (do_export_name_prompt) in the two cases where
-- silence would be wrong, so the button never dead-ends:
--   no kit source  — nothing has been loaded/saved yet, so there is no file to
--                    overwrite. This is a first save: it needs a name.
--   factory kit    — see eon_kit_is_factory. Every installer update rewrites
--                    those files, so an in-place save there is guaranteed to be
--                    lost; Save As sends the edit somewhere it survives.
--
-- Everything downstream is the EXISTING export path: it reuses pending_export
-- and hands off with CMD 11, so the JSFX state-11 dump and write_kit_v4 run
-- byte-identically to a normal save. That inheritance is deliberate — it is
-- what gives a silent save the artwork-tail carry-over (eon_kit_cover_for_save)
-- and the .bak auto-backup for free, rather than a second write path that
-- would have to re-earn both.
local function do_save_in_place()
  local filepath = eon_kit_src_for_lock()

  if not filepath or filepath == "" or eon_kit_is_factory(filepath) then
    do_export_name_prompt()
    return
  end

  -- The kit name the file already carries. gmem NAME_BASE is the live display
  -- name (#kit_name, serialized JSFX-side), which is what the user sees in the
  -- LCD and therefore what they expect to be saving.
  local kit_name = core.gmem_read_string(NAME_BASE, G.NAMELEN, 32) or ""
  kit_name = kit_name:match("^%s*(.-)%s*$")
  if kit_name == "" then
    kit_name = (filepath:match("([^/\\]+)%.[Ss][Ww][Ii][Nn][Gg]$") or "Kit")
  end

  local filename = filepath:match("([^/\\]+)%.[Ss][Ww][Ii][Nn][Gg]$") or kit_name

  pending_export = {
    filepath = filepath, kit_name = kit_name,
    -- Recovered from the file, not asked for — a silent save must not blank
    -- the kit's credit line or description just because no dialog collected them.
    author = eon_kit_author_from_file(filepath),
    desc   = eon_kit_meta_from_file(filepath, "desc"),
    filename = filename
  }

  reaper.gmem_write(G.CMD, 11)
end

-- Save-dialog wrapper with the js_ReaScriptAPI guard the export path was missing.
--
-- js_ReaScriptAPI is a SOFT dependency everywhere else in this file — the IMPORT
-- side already checks before it calls (do_import_browse, do_batch_import). The
-- three export entry points below did not, and a missing JS_ there does not
-- merely fail the save: the nil call throws from inside the defer loop and takes
-- the whole bridge down with it, so Swing loses multi-out and kit loading until
-- the user re-runs the script. Same guard, same GetUserInputs fallback shape.
--
-- Global (not local) to match this file's eon_* helper convention and because
-- the main chunk sits near Lua's 200-local ceiling — see the rk_export note below.
--
-- The suggested default is dropped when the path contains a comma:
-- GetUserInputs parses its defaults as CSV, so a comma would split the field.
function eon_browse_save(title, dir, default_name, filter)
  if reaper.JS_Dialog_BrowseForSaveFile then
    return reaper.JS_Dialog_BrowseForSaveFile(title, dir, default_name, filter)
  end
  local suggested = dir .. _sep .. default_name
  local ok, input = reaper.GetUserInputs(title, 1, "Full save path:,extrawidth=300",
                                         suggested:find(",", 1, true) and "" or suggested)
  if not ok or input == "" then return false, "" end
  return true, input
end

-- CMD 15: Save to custom path (full PC browse)
local function do_export_browse()
  local kits_dir = core.get_kits_dir()
  local retval, filepath = eon_browse_save(
    "Save Swing Kit", kits_dir, "My Kit.swing", "Swing Kit Files (*.swing)\0*.swing\0All Files (*.*)\0*.*\0"
  )
  if not retval or filepath == "" then
    reaper.gmem_write(G.CMD, 98)
    return
  end
  -- Ensure .swing extension
  if not filepath:match("%.swing$") then filepath = filepath .. ".swing" end

  local kit_name = filepath:match("([^/\\]+)%.swing$") or "Kit"

  -- Everything past the overwrite decision, so the confirm can be async.
  local function commit()
    core.gmem_write_string(kit_name, NAME_BASE, G.NAMELEN, 32)

    pending_export = {
      filepath = filepath, kit_name = kit_name,
      author = "", desc = "", filename = kit_name
    }

    reaper.gmem_write(G.CMD, 11)
  end

  -- Check overwrite (see eon_confirm_cmd — async when ReaImGui is present)
  local f_check = io.open(filepath, "rb")
  if not f_check then commit() return end
  f_check:close()
  eon_confirm_cmd('"' .. kit_name .. '.swing" exists. Overwrite?', "Overwrite",
    commit,
    function() reaper.gmem_write(G.CMD, 98) end)
end

-- Export/dump subsystem helpers live on ONE table, not separate top-level
-- locals — the bridge's main chunk sits at Lua's 200-local ceiling, so every
-- `local function` is a scarce slot. Grouping the SFZ + RS5k export functions
-- here keeps their cost at a single local.
local rk_export = {}

-- CMD 19: Export current kit as an SFZ sample map (browse for .sfz path).
-- Reuses the CMD 11 dump handshake exactly like the .swing saves — the JSFX
-- dumps per-pad paths + metadata to gmem, then do_export_write_file branches
-- on pending_export.format == "sfz" and calls write_kit_sfz. SFZ only reads a
-- subset of the dump (paths + note/tune/gain/pan), so no JSFX change is needed.
function rk_export.do_export_sfz_browse()
  local kits_dir = core.get_kits_dir()
  local retval, filepath = eon_browse_save(
    "Export Kit as SFZ Sample Map", kits_dir, "My Kit.sfz",
    "SFZ Files (*.sfz)\0*.sfz\0All Files (*.*)\0*.*\0"
  )
  if not retval or filepath == "" then
    reaper.gmem_write(G.CMD, 98)
    return
  end
  if not filepath:match("%.sfz$") then filepath = filepath .. ".sfz" end

  local kit_name = filepath:match("([^/\\]+)%.sfz$") or "Kit"

  -- Everything past the overwrite decision, so the confirm can be async.
  local function commit()
    core.gmem_write_string(kit_name, NAME_BASE, G.NAMELEN, 32)

    pending_export = {
      filepath = filepath, kit_name = kit_name,
      author = "", desc = "", filename = kit_name, format = "sfz"
    }

    reaper.gmem_write(G.CMD, 11)  -- reuse the same per-pad dump the .swing saves use
  end

  local f_check = io.open(filepath, "rb")
  if not f_check then commit() return end
  f_check:close()
  eon_confirm_cmd('"' .. kit_name .. '.sfz" exists. Overwrite?', "Overwrite",
    commit,
    function() reaper.gmem_write(G.CMD, 98) end)
end

-- CMD 21: Export current kit as a ReaSamplOmatic5000 rack. Like the SFZ export
-- it kicks the SAME per-pad dump (CMD 11) and lands in do_export_write_file via
-- pending_export.format == "rs5k", but instead of a sample-map file it bakes the
-- WAVs and builds an RS5k rack on a new track. We reuse the .sfz save dialog as
-- a naming vehicle (basename = kit/rack name, dir = where the sample folder
-- goes); no file is actually written at the chosen path.
function rk_export.do_export_rs5k_browse()
  local kits_dir = core.get_kits_dir()
  local retval, filepath = eon_browse_save(
    "Export Kit as RS5k Rack — pick a name + folder for the sample WAVs",
    kits_dir, "My Kit", "All Files (*.*)\0*.*\0"
  )
  if not retval or filepath == "" then
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local kit_name = (filepath:match("([^/\\]+)$") or "Kit"):gsub("%.%w+$", "")
  if kit_name == "" then kit_name = "Kit" end
  local dest_dir = filepath:match("^(.*)[/\\]") or kits_dir

  core.gmem_write_string(kit_name, NAME_BASE, G.NAMELEN, 32)

  pending_export = {
    dest_dir = dest_dir, kit_name = kit_name,
    author = "", desc = "", filename = kit_name, format = "rs5k"
  }

  reaper.gmem_write(G.CMD, 11)  -- same per-pad dump the .swing / SFZ exports use
end

local function write_kit_v2(filepath, info)
  local f = io.open(filepath, "w")
  if not f then
    eon_notice("Could not create file:\n" .. filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local write_ok, write_err = pcall(function()
  f:write("-- Swing Kit v2 — EON Studios — proprietary\n")
  f:write("return {\n")
  f:write('  version  = 2,\n')
  f:write('  kit_name = ' .. core.lua_quote(info.kit_name or "") .. ',\n')
  f:write('  author   = ' .. core.lua_quote(info.author or "") .. ',\n')
  f:write('  created  = ' .. core.lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  f:write('  modified = ' .. core.lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  f:write('\n')

  -- Global settings
  f:write('  globals = {\n')
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    f:write('    ' .. name .. ' = ' .. reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1) .. ',\n')
  end
  f:write('  },\n\n')

  -- Per-pad data
  f:write('  pads = {\n')
  for pad = 0, G.NUM_PADS - 1 do
    local base = G.META_BASE + pad * G.META_PP
    -- Read path from ExtState (reliable source — gmem audio area may be overwritten)
    local path = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""

    -- Read pad name
    local name_base = G.PADNAME_BASE + pad * G.PADNAME_LEN
    local name_chars = {}
    for i = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(name_base + i))
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    local name = table.concat(name_chars)

    f:write('    [' .. (pad + 1) .. '] = {\n')
    f:write('      path   = ' .. core.lua_quote(path) .. ',\n')
    f:write('      name   = ' .. core.lua_quote(name) .. ',\n')
    f:write('      gain   = ' .. reaper.gmem_read(base + 0) .. ',\n')
    f:write('      pan    = ' .. reaper.gmem_read(base + 1) .. ',\n')
    f:write('      pitch  = ' .. reaper.gmem_read(base + 2) .. ',\n')
    f:write('      attack = ' .. reaper.gmem_read(base + 3) .. ',\n')
    f:write('      decay  = ' .. reaper.gmem_read(base + 4) .. ',\n')
    f:write('      sustain = ' .. reaper.gmem_read(base + 5) .. ',\n')
    f:write('      release = ' .. reaper.gmem_read(base + 6) .. ',\n')
    f:write('      mute   = ' .. reaper.gmem_read(base + 7) .. ',\n')
    f:write('      solo   = ' .. reaper.gmem_read(base + 8) .. ',\n')
    f:write('      output = ' .. reaper.gmem_read(base + 9) .. ',\n')
    f:write('      note   = ' .. reaper.gmem_read(base + 10) .. ',\n')
    f:write('      note_lock = ' .. reaper.gmem_read(base + 11) .. ',\n')
    f:write('      color  = ' .. reaper.gmem_read(base + 12) .. ',\n')
    f:write('      choke  = ' .. reaper.gmem_read(base + 13) .. ',\n')
    f:write('      oneshot = ' .. reaper.gmem_read(base + 14) .. ',\n')
    f:write('      reverse = ' .. reaper.gmem_read(base + 15) .. ',\n')
    f:write('      fx_hpf = ' .. reaper.gmem_read(base + 16) .. ',\n')
    f:write('      fx_lpf = ' .. reaper.gmem_read(base + 17) .. ',\n')
    f:write('      fx_eq_lo = ' .. reaper.gmem_read(base + 18) .. ',\n')
    f:write('      fx_eq_mid = ' .. reaper.gmem_read(base + 19) .. ',\n')
    f:write('      fx_eq_hi = ' .. reaper.gmem_read(base + 20) .. ',\n')
    f:write('      fx_sat = ' .. reaper.gmem_read(base + 21) .. ',\n')
    f:write('      fx_drv_mode = ' .. reaper.gmem_read(base + 22) .. ',\n')
    f:write('      fx_bc_rate = ' .. reaper.gmem_read(base + 23) .. ',\n')
    f:write('      fx_bc_bits = ' .. reaper.gmem_read(base + 24) .. ',\n')
    f:write('      fx_snd_dly = ' .. reaper.gmem_read(base + 25) .. ',\n')
    f:write('      fx_snd_rvb = ' .. reaper.gmem_read(base + 26) .. ',\n')
    f:write('      fx_snd_smash = ' .. reaper.gmem_read(G.GS_PAD_SMASH_BASE + pad) .. ',\n')
    f:write('      fx_eq_lo_freq = ' .. reaper.gmem_read(base + 27) .. ',\n')
    f:write('      fx_eq_mid_freq = ' .. reaper.gmem_read(base + 28) .. ',\n')
    f:write('      fx_eq_hi_freq = ' .. reaper.gmem_read(base + 29) .. ',\n')
    f:write('      sum_tight = ' .. reaper.gmem_read(base + 30) .. ',\n')
    f:write('      rpt_div = ' .. reaper.gmem_read(base + 31) .. ',\n')
    f:write('      layer_cnt = ' .. reaper.gmem_read(base + 32) .. ',\n')
    f:write('      layer_mode = ' .. reaper.gmem_read(base + 33) .. ',\n')
    f:write('      s_len   = ' .. reaper.gmem_read(base + 34) .. ',\n')
    f:write('      s_start = ' .. reaper.gmem_read(base + 35) .. ',\n')
    f:write('      s_end   = ' .. reaper.gmem_read(base + 36) .. ',\n')
    f:write('      s_sr    = ' .. reaper.gmem_read(base + 37) .. ',\n')
    f:write('      s_norm  = ' .. reaper.gmem_read(base + 38) .. ',\n')
    f:write('      s_norm_gain = ' .. reaper.gmem_read(base + 39) .. ',\n')
    f:write('      sample_offset = ' .. reaper.gmem_read(G.GS_PAD_OFFSET_BASE + pad) .. ',\n')
    f:write('    },\n')
  end
  f:write('  },\n')
  f:write('}\n')
  end) -- pcall write block
  f:close()

  if not write_ok then
    eon_notice("Error writing kit file (disk full?):\n" .. tostring(write_err))
    os.remove(filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  reaper.gmem_write(G.CMD, 99)
  -- Signal browser to refresh kit list
  reaper.SetExtState("Swing", "kit_saved", "1", false)
  eon_notice(
    'Kit saved (v2)!\n\n' ..
    'Name: ' .. info.kit_name .. '\n' ..
    'Location: ' .. filepath)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SFZ EXPORT — write the current kit as a portable SFZ sample map.
--
-- Reads the SAME gmem dump the .swing saves consume (per-pad path via ExtState,
-- note/gain/pan/pitch from META). Emits one <region> per pad with an external
-- sample file. This is a SAMPLE MAP, not a full kit backup: SFZ has no concept
-- of Swing's per-pad FX/EQ, choke groups, Tuned/Stretch layers, or embedded
-- audio, so those are intentionally dropped. `.swing` stays the lossless format.
--
-- Units (verified against the load-apply block):
--   gain  (META+0) is LINEAR (1.0 = 0 dB)        → SFZ volume in dB (20·log10)
--   pan   (META+1) is -1..1, 0 = center          → SFZ pan -100..100
--   pitch (META+2) is semitones, 0 = no shift    → SFZ transpose (int) + tune (cents)
--   note  (META+10) is the MIDI note             → SFZ key (lokey=hikey=keycenter)
-- Sample start/end (META+35/36) are deliberately NOT emitted yet — their
-- frames-vs-interleaved units are unconfirmed and most one-shots use the full
-- sample; emitting them wrong would silently truncate. Add once verified.

-- Extract a pad's audio from the JSFX state-11 gmem dump, writing a 16-bit WAV
-- per LAYER into `samples_dir`, and return one region descriptor per written
-- pad. SHARED by the SFZ export (uses layer 0 only, by RELATIVE path) and the
-- RS5k export (writes ALL layers as FILE0..n by ABSOLUTE path). Each region:
--   sample/wav_abs = layer 0's relative/absolute path (back-compat for SFZ)
--   layers         = { {sample=, wav_abs=}, ... } in layer order (ALL layers)
--   layer_mode     = META+33 (0=single 1=vel-split 2=round-robin 3=sum)
--   note (MIDI), gain (linear), pan (-1..1), pitch (semitones) from META.
-- The state-11 dump (rk_swing_ui_state.jsfx-inc ~296) packs each pad's audio
-- back-to-back at AUDIO_BASE+AUDIO_DUMP_OFFSET; within a pad's block the layers
-- sit sequentially. Legacy single-sample pads (layer_cnt==0) read s_len/s_sr and
-- count as one layer. META slots: 32=layer_cnt 33=layer_mode 34=s_len 37=s_sr
-- 40+layer*10+{0=l_len,3=l_sr}.
--
-- mix_sum (RS5k export only): when a pad is in SUM mode (layer_mode 3) with >1
-- layer, mix every layer down to ONE WAV instead of emitting them separately.
-- A summed pad plays all layers at once, so the mixdown is its faithful single-
-- sample render — RS5k can't sum multiple files inside one instance. SFZ export
-- passes this false, so its output is byte-identical to before.
function rk_export.extract_kit_to_wavs(samples_dir, samples_subdir, mix_sum)
  local AUDIO_DUMP_OFFSET = G.NUM_PADS * 260 + G.NUM_PADS * G.MAX_LAYERS * 260
  local regions = {}
  local audio_off = 0
  local dir_made = false

  -- Write `count` interleaved s16 samples at dump offset `off` to wav_name;
  -- returns the absolute path on success (nil on empty / overflow / IO fail).
  local function write_wav(off, count, sr, wav_name)
    local capped = count
    if off + capped > GMEM_AUDIO_MAX then capped = math.max(0, GMEM_AUDIO_MAX - off) end
    if capped <= 0 then return nil end
    if not dir_made then reaper.RecursiveCreateDirectory(samples_dir, 0); dir_made = true end
    local buf = {}
    for j = 0, capped - 1 do
      buf[#buf + 1] = pack_s16(reaper.gmem_read(G.AUDIO_BASE + AUDIO_DUMP_OFFSET + off + j) or 0)
    end
    local wav_abs = samples_dir .. core.sep .. wav_name
    if _eon_write_wav_s16_bytes(wav_abs, 2, sr, table.concat(buf)) then return wav_abs end
    return nil
  end

  -- Mix every layer of a sum-mode pad into one buffer (float accumulate + hard
  -- clamp at ±1) and write a single WAV. `infos` = { {off=,len=,sr=}, ... }
  -- relative to this pad's block; base_off = the pad's start in the dump.
  -- Differing layer SRs are summed by sample index (uses layer 0's SR for the
  -- output) — fine for the uniform-SR kits this targets; gross SR mismatches
  -- would detune, but Swing layers are virtually always one rate.
  local function write_mixed(infos, base_off, wav_name)
    local total = 0
    for _, L in ipairs(infos) do if L.len > total then total = L.len end end
    if base_off + total > GMEM_AUDIO_MAX then total = math.max(0, GMEM_AUDIO_MAX - base_off) end
    if total <= 0 then return nil end
    if not dir_made then reaper.RecursiveCreateDirectory(samples_dir, 0); dir_made = true end
    local acc = {}
    for j = 1, total do acc[j] = 0 end
    for _, L in ipairs(infos) do
      local n = math.min(L.len, total)
      local rbase = G.AUDIO_BASE + AUDIO_DUMP_OFFSET + base_off + L.off
      for j = 0, n - 1 do acc[j + 1] = acc[j + 1] + (reaper.gmem_read(rbase + j) or 0) end
    end
    local buf = {}
    for j = 1, total do
      local v = acc[j]
      v = (v < -1) and -1 or ((v > 1) and 1 or v)  -- hard-clamp summed peaks
      buf[#buf + 1] = pack_s16(v)
    end
    local wav_abs = samples_dir .. core.sep .. wav_name
    if _eon_write_wav_s16_bytes(wav_abs, 2, (infos[1] and infos[1].sr) or 44100, table.concat(buf)) then
      return wav_abs
    end
    return nil
  end

  for pad = 0, G.NUM_PADS - 1 do
    local base = G.META_BASE + pad * G.META_PP
    local layer_cnt = math.floor(reaper.gmem_read(base + 32) or 0)
    local layer_mode = math.floor(reaper.gmem_read(base + 33) or 0)  -- 0/1/2/3

    -- Pad name → WAV base name (re-import recovers name + drum-type colour).
    local pname = ""
    local nb = G.PADNAME_BASE + pad * G.PADNAME_LEN
    for i = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(nb + i) or 0)
      if c > 0 then pname = pname .. string.char(c) end
    end
    pname = pname:gsub('[<>:"/\\|%?%*]', '_'):gsub('%s+$', '')
    local namebase = (pname ~= "") and string.format("%02d_%s", pad + 1, pname)
                                   or  string.format("pad_%02d", pad + 1)

    local layers = {}
    local pad_total = 0

    if layer_cnt > 0 then
      -- Collect each active layer's (offset within the pad block, length, SR).
      local infos = {}
      local local_off = 0
      local ly = 0
      while ly < layer_cnt do
        local llen = math.floor(reaper.gmem_read(base + 40 + ly * 10 + 0) or 0)  -- l_len
        local lsr  = math.floor(reaper.gmem_read(base + 40 + ly * 10 + 3) or 0)  -- l_sr
        if lsr <= 0 then lsr = 44100 end
        if llen > 0 then infos[#infos + 1] = { off = local_off, len = llen, sr = lsr, idx = ly } end
        local_off = local_off + llen
        ly = ly + 1
      end
      pad_total = local_off

      if mix_sum and layer_mode == 3 and #infos > 1 then
        -- SUM pad → one mixed sample (faithful render of all-layers-at-once).
        local wname = namebase .. ".wav"
        local wav_abs = write_mixed(infos, audio_off, wname)
        if wav_abs then
          layers[#layers + 1] = { sample = samples_subdir .. "/" .. wname, wav_abs = wav_abs }
        end
      else
        for _, L in ipairs(infos) do
          -- Layer 0 keeps the bare pad name (SFZ + name-recovery); 1+ get _L#.
          local wname = (L.idx == 0) and (namebase .. ".wav")
                                     or  string.format("%s_L%d.wav", namebase, L.idx + 1)
          local wav_abs = write_wav(audio_off + L.off, L.len, L.sr, wname)
          if wav_abs then
            layers[#layers + 1] = { sample = samples_subdir .. "/" .. wname, wav_abs = wav_abs }
          end
        end
      end
    else
      local slen = math.floor(reaper.gmem_read(base + 34) or 0)  -- s_len
      local ssr  = math.floor(reaper.gmem_read(base + 37) or 0)  -- s_sr
      if ssr <= 0 then ssr = 44100 end
      if slen > 0 then
        local wname = namebase .. ".wav"
        local wav_abs = write_wav(audio_off, slen, ssr, wname)
        if wav_abs then
          layers[#layers + 1] = { sample = samples_subdir .. "/" .. wname, wav_abs = wav_abs }
        end
      end
      pad_total = slen
    end

    if #layers > 0 then
      regions[#regions + 1] = {
        sample     = layers[1].sample,   -- layer 0 (SFZ export uses just this)
        wav_abs    = layers[1].wav_abs,
        layers     = layers,             -- all layers (RS5k export writes FILE0..n)
        layer_mode = layer_mode,
        note       = math.floor(reaper.gmem_read(base + 10) + 0.5),
        gain       = reaper.gmem_read(base + 0),
        pan        = reaper.gmem_read(base + 1),
        pitch      = reaper.gmem_read(base + 2),
      }
    end

    audio_off = audio_off + pad_total  -- advance past ALL of this pad's layers
  end
  return regions
end

function rk_export.write_kit_sfz(filepath, info)
  -- SELF-CONTAINED SFZ export: write each pad's audio as a 16-bit WAV into a
  -- sibling "<kit> Samples" folder and reference it by RELATIVE path. The audio
  -- comes from the JSFX state-11 gmem dump (AUDIO_BASE + AUDIO_DUMP_OFFSET) — the
  -- SAME source Swing's v5 self-contained save uses — so it works for embedded /
  -- Choppa / moved-source pads where the recorded disk path is stale or absent.
  -- That is the whole point: SFZ-by-reference broke whenever the original WAVs
  -- moved; emitting our own WAVs makes the export portable and path-independent.
  local sfz_dir = filepath:match("^(.*)[/\\]") or "."
  local safe_label = (info.kit_name or "Kit"):gsub('[<>:"/\\|%?%*]', '_')
  local samples_subdir = safe_label .. " Samples"
  local samples_dir = sfz_dir .. core.sep .. samples_subdir

  local regions = rk_export.extract_kit_to_wavs(samples_dir, samples_subdir)

  if #regions == 0 then
    reaper.gmem_write(G.CMD, 98)
    eon_notice(
      "This kit has no pad audio to export.\n\n" ..
      "Load or build a kit with samples on the pads, then export.")
    return
  end

  local f = io.open(filepath, "w")
  if not f then
    eon_notice("Could not create file:\n" .. filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local write_ok, write_err = pcall(function()
    f:write("// Self-contained SFZ sample map exported from EON Swing\n")
    f:write("// Kit: " .. (info.kit_name or "") .. "\n")
    f:write("// Generated: " .. os.date("%Y-%m-%d") .. "\n")
    f:write("// Audio lives in the sibling folder \"" .. samples_subdir .. "\" —\n")
    f:write("//   keep it next to this .sfz when you move or share the kit.\n")
    f:write("// NOTE: zones + tune/level/pan only. Per-pad FX, EQ, choke groups and\n")
    f:write("//       Tuned/Stretch layers are NOT captured. Save as .swing for those.\n\n")

    for _, r in ipairs(regions) do
      f:write("<region>\n")
      f:write("sample=" .. r.sample .. "\n")
      f:write("key=" .. r.note .. "\n")

      -- pitch (semitones) → transpose (integer) + tune (cents remainder)
      if r.pitch ~= 0 then
        local tr = (r.pitch >= 0) and math.floor(r.pitch) or math.ceil(r.pitch)
        local cents = math.floor((r.pitch - tr) * 100 + (r.pitch >= 0 and 0.5 or -0.5))
        if tr ~= 0 then f:write("transpose=" .. tr .. "\n") end
        if cents ~= 0 then f:write("tune=" .. cents .. "\n") end
      end

      -- gain (linear) → volume (dB)
      if r.gain > 0 and math.abs(r.gain - 1.0) > 1e-4 then
        local db = 20.0 * (math.log(r.gain) / math.log(10))
        f:write(string.format("volume=%.1f\n", db))
      elseif r.gain <= 0 then
        f:write("volume=-144.0\n")
      end

      -- pan (-1..1) → SFZ pan (-100..100)
      if r.pan ~= 0 then
        local p = math.floor(r.pan * 100 + (r.pan >= 0 and 0.5 or -0.5))
        if p < -100 then p = -100 elseif p > 100 then p = 100 end
        if p ~= 0 then f:write("pan=" .. p .. "\n") end
      end

      f:write("\n")
    end
  end)
  f:close()

  if not write_ok then
    eon_notice("Error writing SFZ file (disk full?):\n" .. tostring(write_err))
    os.remove(filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  reaper.gmem_write(G.CMD, 99)
  eon_notice(
    'Exported self-contained SFZ.\n\n' ..
    'Kit: ' .. (info.kit_name or "") .. '\n' ..
    'Pads written: ' .. #regions .. ' of ' .. G.NUM_PADS .. '\n' ..
    'SFZ: ' .. filepath .. '\n' ..
    'Samples folder: "' .. samples_subdir .. '" (kept next to the .sfz)')
end

-- ═════════════════════════════════════════════════════════════════════════════
-- RS5k RACK EXPORT — build a ReaSamplOmatic5000 drum rack from the current kit.
--
-- RS5k needs real WAVs on disk (it can't read Swing's embedded audio), so this
-- reuses extract_kit_to_wavs to bake a "<kit> Samples" folder, then adds one
-- RS5k per pad on a new track, pointing FILE0 at each WAV and setting the same
-- note/tune/pan/volume the SFZ export captures. The param indices mirror what
-- the importer reads, so a round-trip (Swing→RS5k→Swing) reproduces the kit.
-- ═════════════════════════════════════════════════════════════════════════════

-- Set a param to a target NUMERIC display value by bisecting normalized 0..1
-- against its FORMATTED readout — curve-agnostic, so it works for any monotonic
-- numeric param without modeling its mapping. Used for RS5k volume (param 0,
-- target dB) and Pitch-adjust tune (param 15, target semitones). One-time +
-- export-only (not on the audio thread); relies on the param being
-- monotonic-increasing in norm (both volume and pitch are).
function rk_export.set_fx_param_to_num(track, fx, pidx, target_db)
  local function read_db(norm)
    reaper.TrackFX_SetParamNormalized(track, fx, pidx, norm)
    local ok, disp = reaper.TrackFX_GetFormattedParamValue(track, fx, pidx)
    if not ok then return nil end
    if disp:lower():find("inf") then return -150.0 end
    return tonumber(disp:match("[%-%+]?%d+%.?%d*"))
  end
  local dlo, dhi = read_db(0.0), read_db(1.0)
  if not dlo or not dhi then return end
  if target_db <= dlo then reaper.TrackFX_SetParamNormalized(track, fx, pidx, 0.0); return end
  if target_db >= dhi then reaper.TrackFX_SetParamNormalized(track, fx, pidx, 1.0); return end
  local lo, hi, norm = 0.0, 1.0, 0.5
  local i = 0
  while i < 16 do
    norm = (lo + hi) * 0.5
    local d = read_db(norm)
    if not d then break end
    if math.abs(d - target_db) <= 0.05 then break end
    if d < target_db then lo = norm else hi = norm end
    i = i + 1
  end
  reaper.TrackFX_SetParamNormalized(track, fx, pidx, norm)
end

-- Add one ReaSamplOmatic5000 to `track` holding `files` (FILE0..n) and set the
-- pad-level params (note/tune/pan/volume) from region `r`. `opts` (optional)
-- drives the multi-instance round-robin construct RS5k requires (it has no
-- single-instance RR): prob = "probability of hitting" (param 19, 0..1),
-- rr = the round-robin NoteOn toggle (param 20), filter = "filter played notes"
-- so a fired instance removes the note from the chain (param 21). Returns true
-- if the FX was added. (Param 19/21 indices + the method are research-verified;
-- param 20's exact on-value is a best estimate — see project memory.)
function rk_export.build_rs5k_instance(track, files, r, opts)
  local fx = reaper.TrackFX_AddByName(track, "ReaSamplOmatic5000 (Cockos)", false, -1)
  if fx < 0 then return false end
  for i, wav in ipairs(files) do
    reaper.TrackFX_SetNamedConfigParm(track, fx, "FILE" .. (i - 1), wav)
  end
  reaper.TrackFX_SetNamedConfigParm(track, fx, "DONE", "")
  -- note: single-note zone (range start == end == keycenter), norm = note/127.
  local nnorm = math.min(math.max(r.note / 127, 0), 1)
  reaper.TrackFX_SetParamNormalized(track, fx, 3, nnorm)
  reaper.TrackFX_SetParamNormalized(track, fx, 4, nnorm)
  -- tune (semitones) → param 15 "Pitch adjust" (RS5k's actual tune; default 0).
  -- NOT param 5/6 — those are keyboard-tracking pitch (param 5 default -24) and
  -- are ignored in RS5k's default "Sample" mode, so they'd never pitch the
  -- sample AND would re-import as a huge bogus tune. Matched via formatted value.
  if r.pitch and math.abs(r.pitch) > 1e-4 then
    rk_export.set_fx_param_to_num(track, fx, 15, r.pitch)
  end
  -- pan (-1..1) → param 1 norm (0..1).
  reaper.TrackFX_SetParamNormalized(track, fx, 1, math.min(math.max((r.pan + 1) / 2, 0), 1))
  -- volume: Swing gain is linear → dB, matched on RS5k's volume param.
  if r.gain and r.gain > 0 and math.abs(r.gain - 1.0) > 1e-4 then
    rk_export.set_fx_param_to_num(track, fx, 0, 20.0 * (math.log(r.gain) / math.log(10)))
  end
  if opts then
    if opts.prob   then reaper.TrackFX_SetParamNormalized(track, fx, 19, opts.prob) end
    if opts.rr     then reaper.TrackFX_SetParamNormalized(track, fx, 20, 1.0) end
    if opts.filter then reaper.TrackFX_SetParamNormalized(track, fx, 21, 1.0) end
  end
  return true
end

function rk_export.write_kit_rs5k(info)
  local dest_dir = info.dest_dir or core.get_kits_dir()
  local safe_label = (info.kit_name or "Kit"):gsub('[<>:"/\\|%?%*]', '_')
  local samples_subdir = safe_label .. " Samples"
  local samples_dir = dest_dir .. core.sep .. samples_subdir

  -- mix_sum=true: sum-mode pads render to one mixed WAV (RS5k can't sum files).
  local regions = rk_export.extract_kit_to_wavs(samples_dir, samples_subdir, true)
  if #regions == 0 then
    reaper.gmem_write(G.CMD, 98)
    eon_notice(
      "This kit has no pad audio to export.\n\n" ..
      "Load or build a kit with samples on the pads, then export.")
    return
  end

  -- Build the rack on a fresh track at the end of the project.
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", (info.kit_name or "RS5k Kit") .. " (RS5k)", true)

  local built, pads_done = 0, 0
  for _, r in ipairs(regions) do
    local lyrs = r.layers or { { wav_abs = r.wav_abs } }
    local files = {}
    for _, lyr in ipairs(lyrs) do files[#files + 1] = lyr.wav_abs end

    if r.layer_mode == 2 and #files > 1 then
      -- Round-robin: RS5k has NO single-instance round-robin (verified), so emit
      -- ONE instance per layer on the SAME note with graduated probability — in
      -- chain order the i-th of N fires with prob 1/(N-i+1) (1/N … 1/2, 1/1) and
      -- "filter played notes" removes a fired note so exactly one layer sounds
      -- per hit. This is the documented multi-instance RR method.
      local n = #files
      for i = 1, n do
        if rk_export.build_rs5k_instance(track, { files[i] }, r,
             { prob = 1 / (n - i + 1), rr = true, filter = true }) then
          built = built + 1
        end
      end
    else
      -- vel-split / sum / single → one instance. Multiple files auto-spread
      -- across velocity (matches Swing vel-split); sum pads arrive pre-mixed.
      if rk_export.build_rs5k_instance(track, files, r, nil) then built = built + 1 end
    end
    pads_done = pads_done + 1
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  reaper.gmem_write(G.CMD, 99)
  eon_notice(
    'Built RS5k rack.\n\n' ..
    'Kit: ' .. (info.kit_name or "") .. '\n' ..
    'RS5k instances: ' .. built .. ' across ' .. pads_done .. ' pad(s)\n' ..
    'New track: "' .. (info.kit_name or "RS5k Kit") .. ' (RS5k)"\n' ..
    'Samples folder: ' .. samples_dir)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- SHARED SAVE HELPERS — gmem path readers and the per-pad audio dump used by
-- the v4 and v5 writers. (Was the "v3 HYBRID SAVE" block; v3 retired 2026-07-31,
-- but these helpers were always shared, so only write_kit_v3 itself went.)
-- ═════════════════════════════════════════════════════════════════════════════

-- Read a NUL-terminated path written by the JSFX into the path area of gmem
-- (AUDIO_BASE + pad * 260 — see Swing_ReaKit.jsfx state 11, line ~219).
-- Falls back to empty string on missing / invalid data.
local function read_pad_path_from_gmem(pad)
  local pbase = G.AUDIO_BASE + pad * 260
  local plen = math.floor(reaper.gmem_read(pbase))
  if plen <= 0 or plen >= 259 then return "" end
  local chars = {}
  for i = 0, plen - 1 do
    local c = math.floor(reaper.gmem_read(pbase + 1 + i))
    if c > 0 and c < 256 then
      chars[#chars + 1] = string.char(c)
    end
  end
  return table.concat(chars)
end

-- v4: per-layer paths region in gmem starts after the pad-paths block.
--   layout: AUDIO_BASE + NUM_PADS*260 + (pad*MAX_LAYERS + layer)*260
-- The JSFX writes these in state 11 (rk_swing_ui_state.jsfx-inc, after pad paths).
local LAYER_PATH_BASE = G.AUDIO_BASE + G.NUM_PADS * 260
local function read_layer_path_from_gmem(pad, layer)
  local lbase = LAYER_PATH_BASE + (pad * G.MAX_LAYERS + layer) * 260
  local plen = math.floor(reaper.gmem_read(lbase))
  if plen <= 0 or plen >= 259 then return "" end
  local chars = {}
  for i = 0, plen - 1 do
    local c = math.floor(reaper.gmem_read(lbase + 1 + i))
    if c > 0 and c < 256 then
      chars[#chars + 1] = string.char(c)
    end
  end
  return table.concat(chars)
end

-- Per-pad audio dump region — JSFX state 11 writes internal s_audio_start[]
-- here so the bridge can reliably read pad audio for kits whose pads have
-- no disk source (Choppa slices, gmem-imported, etc.). Without this region,
-- the bridge was reading from AUDIO_BASE + 0 which state 11 overwrites with
-- path strings — that's the "blank kit" / "wrong pad" bug.
--
-- Layout: AUDIO_BASE + AUDIO_DUMP_OFFSET + cumulative s_len, in pad order.
-- Layered pads dump each layer in sequence.
--
-- ⛔ Readers walk this region and accumulate their own offset as they go (the
-- v4 save and the v5 snapshot both do). Never re-derive the offset by summing
-- AUDIOLEN: that band is a @gfx blast-mirror gated on _is_browser_target, so it
-- reads zero on pads that hold audio. See .docs/wiki/05-memory-and-gmem.md §5.5.
local AUDIO_DUMP_OFFSET = G.NUM_PADS * 260 + G.NUM_PADS * G.MAX_LAYERS * 260  -- 20800 for 16 pads × 4 layers

-- Stream a sample file to an already-open binary-mode file handle as
-- [interleaved_len:double][sr:double][int16 × interleaved_len] (stereo, L=R for mono).
-- Uses PCM_Source + AudioAccessor (same approach as load_audio_to_pad) but writes
-- directly to disk in chunks so we don't hold the full audio buffer in Lua memory.
--
-- max_frames (optional): cap source samples in *frames* (mono frame count, NOT
-- interleaved samples). Defaults to SLOT_SIZE/2 (matches v3 single-blob-per-pad
-- behaviour). v4 layered save passes LAYER_SIZE/2 so each layer fits in its
-- per-pad slot exactly the way the JSFX expects (see load_layer_from_path).
--
-- Returns (interleaved_len, sr). On failure, writes zero-length placeholder and returns 0, 0.
local function stream_pcm_to_file(f, filepath, max_frames)
  max_frames = max_frames or math.floor(G.SLOT_SIZE / 2)
  if not filepath or filepath == "" then
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local total_samples = math.floor(length * sr)
  local num_samples = math.min(total_samples, max_frames)
  if num_samples <= 0 then
    reaper.PCM_Source_Destroy(src)
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  local tr = acquire_scratch_track()
  if not tr then
    release_scratch_track(nil)
    reaper.PCM_Source_Destroy(src)
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  local temp_item = reaper.AddMediaItemToTrack(tr)
  local temp_take = reaper.AddTakeToMediaItem(temp_item)
  reaper.SetMediaItemTake_Source(temp_take, src)
  reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

  local aa = reaper.CreateTakeAudioAccessor(temp_take)
  if not aa then
    -- Take owns src after SetMediaItemTake_Source above; release_scratch
    -- _track destroys the track which drops the take's source ref.
    -- Calling PCM_Source_Destroy(src) here would be a use-after-free.
    release_scratch_track(tr)
    f:write(pack_double(0)); f:write(pack_double(0))
    return 0, 0
  end

  -- interleaved stereo (mono duplicated L=R) — matches what gmem expects
  local interleaved_len = num_samples * 2

  -- Header for this pad
  f:write(pack_double(interleaved_len))
  f:write(pack_double(sr))

  local chunk_size = math.min(num_samples, 250000)
  local sample_buf = reaper.new_array(chunk_size * nch)
  local samples_read = 0
  local write_buf = {}

  while samples_read < num_samples do
    local to_read = math.min(chunk_size, num_samples - samples_read)
    sample_buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, samples_read / sr, to_read, sample_buf)

    for j = 0, to_read - 1 do
      local val
      if nch == 1 then
        val = sample_buf[j + 1] or 0
      else
        val = 0
        for ch = 0, nch - 1 do val = val + (sample_buf[j * nch + ch + 1] or 0) end
        val = val / nch
      end
      -- Pack as interleaved stereo int16 (L, R)
      local s = pack_s16(val)
      write_buf[#write_buf + 1] = s
      write_buf[#write_buf + 1] = s
    end

    -- Flush to disk periodically to avoid holding huge Lua tables
    if #write_buf >= 20000 then
      f:write(table.concat(write_buf))
      write_buf = {}
    end

    samples_read = samples_read + to_read
  end

  if #write_buf > 0 then f:write(table.concat(write_buf)) end

  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)

  return interleaved_len, sr
end

-- ═════════════════════════════════════════════════════════════════════════════
-- v4 HYBRID SAVE — same as v3 plus per-pad multi-layer audio (velocity layers,
-- round-robin, vel-split kits all round-trip cleanly).
-- ═════════════════════════════════════════════════════════════════════════════
--
-- File format:
--   Bytes 0..7   : "SWINGv04"
--   Bytes 8..15  : lua_len (double)
--   Bytes 16..   : Lua text (return { version=4, …, pads={[i]={…, layers={[1]={…},…}}} })
--   Then per pad 0..NUM_PADS-1 (TAGGED UNION based on num_layers):
--     [num_layers : 8B double]                         -- 0..MAX_LAYERS
--     If num_layers == 0:  (non-layered pad — drag-drop, single sample)
--       [s_len : 8B][s_sr : 8B][int16 PCM × s_len]
--     If num_layers > 0:   (layered pad — RR, VelSplit, Sum)
--       For each layer 0..num_layers-1:
--         [l_len : 8B][l_sr : 8B][int16 PCM × l_len]
--
-- This tagged layout matches the JSFX's kit_import_state==3 copy loop
-- (rk_swing_ui_state.jsfx-inc lines 515-565) which reads EITHER s_len[pad]
-- bytes OR sum(l_len[pad,layer]) bytes per pad — never both. Writing a
-- pad-main blob ahead of layer blobs would shift the layered audio out of
-- alignment and make the JSFX reproduce noise.
--
-- The JSFX writes per-layer paths to gmem in state 11 (rk_swing_ui_state
-- jsfx-inc, after the pad-paths block) so this writer can re-stream each
-- layer's audio from its source file.
-- ═════════════════════════════════════════════════════════════════════════════
-- v4 TAIL RECORDS — optional data appended after the last pad blob.
-- ═════════════════════════════════════════════════════════════════════════════
--
--   [tag : 8B double][len : 8B double][len bytes]   repeated to EOF
--
-- Safe to append with NO format bump, because nothing that shipped looks past
-- the pads: the loader walks exactly NUM_PADS entries and never checks it
-- reached EOF, validate_swing reads 32 bytes, the Browser's magic probe reads 7,
-- and write_kit_v4 emits no footer or checksum to collide with.
--
-- TAGGED from the first commit on purpose. The macro spec also wants a block in
-- write_kit_v4, and a bare [len][bytes] would leave no way to tell whose bytes
-- these are or to skip a record you don't understand.
--
-- ⚠️ Any tool that round-trips a .swing must carry the tail across or it will
-- silently strip covers and factory macros. AUDITED 2026-08-21 — the earlier
-- version of this note named four tools and only one of them was guilty:
--   make_vintage_kits.py  RE-AUTHORS from scratch. Was the real stripper; now
--                         harvests the tail before its delete sweep and
--                         re-emits it (a re-bake is byte-identical).
--   kit_sanitize.py       rewrites the LUA text only, byte-copies everything
--                         from the first pad blob on. Tail-safe.
--   fischer_kit_finish.py same shape, same verdict. Tail-safe (archived).
--   kitpipe_lib.lua       parses only, never writes a .swing. Tail-safe.
-- The Python side of the format now lives in ONE place — .dev_tests/
-- swing_kit_tail.py, which mirrors the four functions below. New tools import
-- it instead of re-deriving the walk; that re-derivation is what broke covers.
EON_KIT_TAIL_COVER = 1    -- cover image bytes, stored as-is (PNG or JPEG)
EON_KIT_TAIL_MACRO = 2    -- kit-macro model: EON_KMAC_KIT_LEN little-endian
                          -- doubles, the transfer band's +1..+LEN verbatim
                          -- (ver, values, nmap, scope, color, pad, pid, lo,
                          -- hi, curve, snapshots, has, act, then v2's names).
                          -- 486 today; readers take v1's 390 too, so the
                          -- count belongs to the VERSION double, not here.
                          -- Activated 2026-08-21; all 13 factory kits carry
                          -- one as of the same day.
-- Kit-macro transfer band base. MUST match KMAC_KIT_BASE in
-- Swing_ReaKit.jsfx and the gmem map (+0 = staged flag, bridge-written).
EON_KMAC_KIT_BASE = 26090640
EON_KMAC_KIT_LEN  = 486   -- model v2 (+8 names x 12 char cells); v1 = 390

-- Returns a { [tag] = bytes } table. Stops at the first record that doesn't fit
-- rather than guessing: a truncated or foreign tail should cost the records
-- after it, never a mis-parse of the ones before.
function eon_kit_tail_read(content, pos)
  local out = {}
  while pos + 15 <= #content do
    local tag = math.floor(string.unpack("<d", content, pos) or 0); pos = pos + 8
    local len = math.floor(string.unpack("<d", content, pos) or 0); pos = pos + 8
    -- Positive-form guard: a NaN tag would otherwise slip past every "bad"
    -- test and land as a table index -- a hard Lua error.
    if not (tag > 0 and len >= 0 and pos + len - 1 <= #content) then break end
    out[tag] = len > 0 and content:sub(pos, pos + len - 1) or ""
    pos = pos + len
  end
  return out
end

-- Byte offset of the first tail record: just past the last pad blob.
--
-- Mirrors the audio walk in load_kit_v4 exactly, but skips the PCM instead of
-- staging it. The VER-201 "pl" route returns before that walk ever runs, so
-- without this it had no way to locate the tail and covers were invisible on
-- every shipping build (KIT_HS_CAP is 203, so pl is always the chosen route).
--
-- Returns nil if the binary section does not parse cleanly. Callers then behave
-- exactly as they do for a pre-tail kit: no cover, no error.
function eon_kit_tail_offset(content, lua_len)
  -- Bounds are EXACT here, not the conservative `pos + n > #content` form used
  -- by read_blob: reading k bytes at 1-based pos needs pos + k - 1 <= #content.
  -- The conservative form rejects a field that ends exactly on the last byte,
  -- which is precisely the common case — a kit with no tail ends flush with its
  -- final blob. Verified against 24 real kits: every one lands on EOF or on a
  -- valid tail record.
  local pos = 17 + lua_len
  local pad = 0
  while pad < G.NUM_PADS do
    if pos + 7 > #content then return nil end
    local lc = math.floor(string.unpack("<d", content, pos) or 0); pos = pos + 8
    if not (lc >= 0) then return nil end  -- NaN/negative: bail, don't guess
    -- Deliberately NOT clamped to MAX_LAYERS. That clamp in the audio walk is a
    -- staging guard, but the FILE still contains every layer it wrote, so
    -- clamping here would leave pos short and mis-read the tail. A wild value
    -- means the file is not what we think it is — bail rather than guess.
    if lc > 64 then return nil end
    local blobs = lc > 0 and lc or 1
    local b = 0
    while b < blobs do
      if pos + 15 > #content then return nil end
      local alen = math.floor(string.unpack("<d", content, pos) or 0)
      if not (alen >= 0) then return nil end  -- NaN/negative length: bail
      pos = pos + 16                      -- [len:8B][sr:8B]
      if alen > 0 then
        if pos + alen * 2 - 1 > #content then return nil end
        pos = pos + alen * 2              -- PCM is 16-bit
      end
      b = b + 1
    end
    pad = pad + 1
  end
  return pos
end

-- Absorb the tail records of a just-loaded kit: stash the cover so a later
-- re-save carries it over, and extract it to a temp file because gfx_loadimg
-- takes a PATH while the bytes live inside the .swing.
--
-- Shared by BOTH v4 load routes. It used to be inline on the audio-walk route
-- only, which is why the pl route silently dropped every cover.
-- Pack the exporting instance's kit-macro model (published into the
-- transfer band during the export phase) as the tail-tag-2 bytes. Returns
-- nil for a TRIVIAL model (no mappings, no snapshots): a kit saved without
-- macros carries no block, so loading it never wipes a user's live rig.
function eon_kmac_pack()
  if (reaper.gmem_read(EON_KMAC_KIT_BASE + 1) or 0) < 0.5 then return nil end
  local nontrivial = false
  for m = 0, 7 do
    if (reaper.gmem_read(EON_KMAC_KIT_BASE + 10 + m) or 0) > 0.5 then nontrivial = true end
  end
  for s = 0, 3 do
    if (reaper.gmem_read(EON_KMAC_KIT_BASE + 386 + s) or 0) > 0.5 then nontrivial = true end
  end
  for i = 391, EON_KMAC_KIT_LEN do  -- custom names count as authored content too
    if (reaper.gmem_read(EON_KMAC_KIT_BASE + i) or 0) > 0.5 then nontrivial = true end
  end
  if not nontrivial then return nil end
  local t = {}
  for i = 1, EON_KMAC_KIT_LEN do
    t[i] = string.pack("<d", reaper.gmem_read(EON_KMAC_KIT_BASE + i) or 0)
  end
  return table.concat(t)
end

-- Stage a loaded kit's macro block back into the transfer band and raise
-- the staged flag; the JSFX kit-adopt consumes it (same discipline as the
-- SYN staged flag: no block -> no flag -> live macros survive). Length and
-- version are checked positively; a short or foreign record stages nothing.
function eon_kmac_stage(bytes)
  -- v1 blocks are 390 doubles, v2 = 486 (+names). Read the version double
  -- first and demand the matching length; a short or foreign record stages
  -- nothing. A v1 block zeroes the name cells so a prior kit's names can
  -- never bleed into this adopt.
  if not bytes or #bytes < 390 * 8 then return end
  local okv, ver = pcall(string.unpack, "<d", bytes, 1)
  if not okv then return end
  local n = (ver or 0) >= 2 and EON_KMAC_KIT_LEN or 390
  if #bytes < n * 8 then return end
  local pos = 1
  for i = 1, n do
    local ok, v = pcall(string.unpack, "<d", bytes, pos)
    if not ok then return end
    reaper.gmem_write(EON_KMAC_KIT_BASE + i, v or 0)
    pos = pos + 8
  end
  if n < EON_KMAC_KIT_LEN then
    for i = n + 1, EON_KMAC_KIT_LEN do reaper.gmem_write(EON_KMAC_KIT_BASE + i, 0) end
  end
  if (reaper.gmem_read(EON_KMAC_KIT_BASE + 1) or 0) >= 0.5 then
    reaper.gmem_write(EON_KMAC_KIT_BASE, 1)
  end
end

function eon_kit_absorb_tail(content, pos, filepath)
  local tail = pos and eon_kit_tail_read(content, pos) or {}
  eon_kmac_stage(tail[EON_KIT_TAIL_MACRO])
  eon_kit_cover_bytes    = tail[EON_KIT_TAIL_COVER]
  eon_kit_cover_path     = nil
  eon_kit_cover_src_path = filepath   -- guards the carry-over on re-save
  -- Name from the kit path so it changes when the kit does; gfx_loadimg caches
  -- by slot, not by path, but the JSFX reloads on a publish-seq change.
  eon_kit_cover_path = eon_kitcover_extract(
    eon_kit_cover_bytes,
    filepath:match("([^/\\]+)%.[Ss][Ww][Ii][Nn][Gg]$") or "kit")
end

-- Read a kit file's own cover straight off disk. The save-side safety net: it
-- lets a re-save carry over artwork that was never staged in memory.
function eon_kit_cover_from_file(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  if not content or #content < 17 then return nil end
  local ok, lua_len = pcall(string.unpack, "<d", content, 9)
  if not ok or not lua_len then return nil end
  lua_len = math.floor(lua_len)
  if not (lua_len > 0 and 16 + lua_len <= #content) then return nil end
  local pos = eon_kit_tail_offset(content, lua_len)
  if not pos then return nil end
  return eon_kit_tail_read(content, pos)[EON_KIT_TAIL_COVER]
end

-- Writes a { [tag] = bytes } table. Empty records are skipped, so a kit with no
-- cover produces a file byte-identical to one written before tails existed.
function eon_kit_tail_write(f, recs)
  local n = 0
  if recs then
    for tag, bytes in pairs(recs) do
      if bytes and #bytes > 0 then
        f:write(pack_double(tag))
        f:write(pack_double(#bytes))
        f:write(bytes)
        n = n + 1
      end
    end
  end
  return n
end

-- Cover for the kit being saved. A `<kit>.png` (or .jpg) beside the destination
-- wins — that's how you attach one, no UI needed and it works for a folder of
-- factory kits in one pass. Otherwise carry over whatever the loaded kit had, so
-- re-saving a kit never quietly drops its artwork.
-- `prior_path` is where the pre-save file actually lives by the time this runs:
-- write_kit_v4's auto-backup may already have renamed the destination to .bak.
-- Only the last-resort tail re-read uses it — the sidecar-PNG lookup and the
-- src_path guard both want the real destination. Defaults to filepath so the
-- (unrenamed) callers and any future one behave exactly as before.
function eon_kit_cover_for_save(filepath, prior_path)
  -- Kit-undo snapshots must capture the LIVE cover — the whole point of the
  -- dump is live state — so take the staged bytes regardless of src_path (the
  -- temp destination never matches it), and never fall through to the temp
  -- file's own tail, which is a stale previous snapshot at best. Without this
  -- an undo after New Kit / a load restored the audio but dropped the art.
  if pending_export and pending_export.undo_dump then
    return eon_kit_cover_bytes
  end
  local base = filepath:gsub("%.[Ss][Ww][Ii][Nn][Gg]$", "")
  local cand = { base .. ".png", base .. ".PNG", base .. ".jpg", base .. ".jpeg" }
  local i = 1
  while i <= #cand do
    local fh = io.open(cand[i], "rb")
    if fh then
      local bytes = fh:read("*a"); fh:close()
      if bytes and #bytes > 0 then return bytes end
    end
    i = i + 1
  end
  -- Carry-over, but NOT blindly. eon_kit_cover_bytes is a single global while
  -- there can be 16 Swings: without this guard, loading kit A in one instance
  -- and then saving kit B from another would bake A's artwork into B.
  --   src_path == filepath -> re-saving the kit we took it from. Carry over.
  --   src_path == nil      -> it came from a DROP, so it is meant for the next
  --                           save by definition.
  --   src_path == the LOCK-holding instance's loaded kit -> a SAVE-AS of the
  --                           live kit under a new name: same art, new file.
  --                           Refusing this is how a factory-kit Save-As
  --                           minted art-less twins (the 2026-08-19 "808 F"
  --                           root copy). eon_kit_src_for_lock answers for
  --                           the instance actually saving, so another
  --                           instance's staged art still cannot leak in.
  --   otherwise            -> a different kit. Leave it alone.
  if eon_kit_cover_bytes
     and (eon_kit_cover_src_path == nil
          or eon_kit_cover_src_path == filepath
          or eon_kit_cover_src_path == eon_kit_src_for_lock()) then
    return eon_kit_cover_bytes
  end
  -- Nothing staged for this kit. write_kit_v4 opens "wb", so writing a coverless
  -- file over one that HAS artwork destroys it with no way back. Re-read the
  -- destination's own tail and carry it over. Always the destination's own art,
  -- never another kit's, so this cannot cross-contaminate.
  -- ⚠️ Reachable in practice: eon_kit_cover_bytes is a live global, so after a
  -- bridge restart (or any save of a kit this session never loaded) nothing is
  -- staged and this fallback IS the only thing holding the artwork.
  return eon_kit_cover_from_file(prior_path or filepath)
end

-- ── Cover path exchange over the per-instance EON_KITCOVER band ───────────
-- Publish: path first, seq LAST. Called with a nil path too, so an instance
-- that loads a coverless kit clears its tile instead of keeping the last one.
-- `preview` (optional): 1 marks the published path as an UNSAVED drop preview
-- — readers (kit tile + Lens) show the image but keep their UNSAVED cue up
-- until a real bake/load publishes with preview absent.
eon_kitcover_by_inst  = {}   -- inst_id -> last published {path, preview}
_eon_cover_slot_seen  = {}   -- inst_id -> slot the identity sweep last saw it on
function eon_kitcover_publish(slot, path, preview)
  if not slot or slot < 0 or slot >= G.GS_INST_REG_MAX then return end
  local b  = G.KITCOVER_BASE + slot * G.KITCOVER_STRIDE
  local pb = b + G.KITCOVER_PUB_PATH
  local s  = path or ""
  local n  = math.min(#s, G.KITCOVER_PATH_MAX)
  reaper.gmem_write(pb, n)
  for i = 1, n do reaper.gmem_write(pb + i, s:byte(i)) end
  reaper.gmem_write(pb + n + 1, 0)
  reaper.gmem_write(b + G.KITCOVER_PUB_PREVIEW, preview and 1 or 0)
  reaper.gmem_write(b + G.KITCOVER_PUB_SEQ,
                    (reaper.gmem_read(b + G.KITCOVER_PUB_SEQ) or 0) + 1)
  -- Remember what this INSTANCE was last shown, keyed by id, not slot — the
  -- follow pass below re-aims it when the instance migrates. Recorded in the
  -- funnel so every publish flavour (load, save-ack, drop preview, New-Kit
  -- clear) is covered. Freshness-gated like ss_resolve_slot: a stale registry
  -- band must not file the cover under a ghost's id.
  local rb  = G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE
  local iid = math.floor(reaper.gmem_read(rb + G.GS_INST_REG_OFF_ID) or 0)
  if iid > 0 and (reaper.time_precise() - (reaper.gmem_read(rb + G.GS_INST_REG_OFF_HEARTBEAT) or 0))
                 <= G.GS_INST_REG_TIMEOUT then
    eon_kitcover_by_inst[iid] = { path = s, preview = preview and true or false }
  end
end

-- Re-aim the cover when an instance changes registry slots. Slots are session-
-- volatile and DO move mid-session: every Swing recompile migrates (the old
-- incarnation's heartbeat is still fresh, so swing_registry_claim's re-adopt
-- pass refuses the old slot and Pass B takes a new one), and a collision
-- vacate/reclaim can too. The cover is the only ONE-SHOT slot-keyed broadcast
-- — strip/identity/colors re-publish every pass — so the publish stayed behind
-- on the old band: the kit tile fell back to its generated portrait and the
-- Lens to its monogram until the next kit load. Called per slotted instance
-- from the identity sweep; two table reads when nothing changed.
-- (A duplicated instrument's re-minted id has no memory here on purpose — its
-- art arrives with the primed_instances sidecar reload for the new id.)
function eon_kitcover_follow_slot(inst_id, slot)
  local prev = _eon_cover_slot_seen[inst_id]
  _eon_cover_slot_seen[inst_id] = slot
  if prev == nil or prev == slot then return end
  local last = eon_kitcover_by_inst[inst_id]
  if last then
    eon_kitcover_publish(slot, last.path, last.preview)
  else
    -- No memory (bridge restarted since the last load): still scrub the target
    -- band, so the migrated instance cannot wear a dead occupant's stale art.
    eon_kitcover_publish(slot, "")
  end
end

-- ── EON Lens — kit artwork card on the instrument parent folder ────────────
-- Display-only JSFX (Spec_EON_Lens.md) that SECOND-READS the PUB half of the
-- EON_KITCOVER band above: publish is a broadcast, so the card needs no
-- publish-side code at all — only its link_slot slider kept current (slots
-- are session-volatile; same contract as EON_FX_Return_View's link_slot,
-- but owned by the bridge identity sweep, not the strip-sync companion).
EON_LENS_BASENAME = "EON_Lens.jsfx"

-- Resolve the Lens FX on a parent track. Query only (-1 when absent): a
-- user-deleted Lens is respected — only an explicit multi-out Build re-adds.
function eon_lens_query(parent, hint_tr, hint_fx)
  local addname = core.jsfx_addname(EON_LENS_BASENAME, hint_tr, hint_fx)
  if not addname then return -1, nil end
  return reaper.TrackFX_AddByName(parent, addname, false, 0), addname
end

-- Detect the Lens JSFX anywhere. fx_ident is the .jsfx filename, so this
-- survives a display-name change (the card's desc dropped "kit" when standalone
-- mode landed). ONE API call on purpose — it runs per FX per track.
function is_lens_fx(tr, fx)
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and ident and ident:find(EON_LENS_BASENAME, 1, true) then return true end
  return false
end

-- Write link_slot on an already-resolved Lens. Param BY NAME, never by slider
-- index (sparse-slider lesson). Compare-before-write is not an optimisation:
-- TrackFX_SetParam marks the project dirty, so an idempotent pass MUST NOT
-- write, or merely opening a project would leave it unsaved.
function eon_lens_set_slot(tr, fx, slot)
  local p = 0
  while p < reaper.TrackFX_GetNumParams(tr, fx) do
    local _, pn = reaper.TrackFX_GetParamName(tr, fx, p, "")
    if pn and pn:find("Linked registry slot", 1, true) then
      if math.abs((reaper.TrackFX_GetParam(tr, fx, p) or -99) - slot) > 1e-6 then
        reaper.TrackFX_SetParam(tr, fx, p, slot)
      end
      return true
    end
    p = p + 1
  end
  return false
end

-- Keep a parent's Lens pointed at its Swing's registry slot. Called from the
-- identity sweep with the (engine track, slot, fx) it already resolved.
function eon_lens_sync(swing_track, slot, hint_fx)
  local parent = find_folder_track(swing_track)
  if not parent then return end
  local fx = eon_lens_query(parent, swing_track, hint_fx)
  if not fx or fx < 0 then return end
  eon_lens_set_slot(parent, fx, slot)
end

-- ── Stray revocation (Spec_EON_Lens_Standalone.md) ─────────────────────────
-- link_slot rides the FX CHUNK, so it survives an FX drag, a track template and
-- an FX-chain preset. eon_lens_sync above only ever GRANTS a slot — it pushes to
-- Swing parents — so before this, a card dragged off its parent stayed linked
-- forever: it kept showing that kit's cover, and a drop on it still wrote that
-- kit's PEND, silently changing a real kit's art on the next save. Same for an
-- orphaned parent whose Swing was deleted, since slot N gets REUSED later.
--
-- Home test is ANCESTRY, not track equality: a Lens legitimately moved inside
-- its own instrument (onto the Audio header, say) must survive. Anything with no
-- serviced parent above it is revoked to -1, where the JSFX's standalone mode
-- takes over and the card shows its own artwork instead of going dead.
--
-- TWO STRIKES before revoking (~1s apart): a sweep that transiently fails to
-- resolve an instance's slot must not cost a real card its link. The strike
-- table is rebuilt each pass so deleted tracks cannot accumulate in it.
function eon_lens_revoke_strays(found, parents)
  local strikes, revoked = {}, 0
  for i = 1, #found do
    local e = found[i]
    local home, t, guard = nil, e.tr, 0
    while t and guard < 16 do
      if parents[t] then home = parents[t] ; break end
      t = reaper.GetParentTrack(t)
      guard = guard + 1
    end
    if home then
      eon_lens_set_slot(e.tr, e.fx, home)
    else
      local s = ((_eon_lens_strikes and _eon_lens_strikes[e.tr]) or 0) + 1
      strikes[e.tr] = s
      -- Already-standalone cards land here every pass; set_slot compares first,
      -- so they cost a read and never a write.
      if s >= 2 and eon_lens_set_slot(e.tr, e.fx, -1) then revoked = revoked + 1 end
    end
  end
  _eon_lens_strikes = strikes
  return revoked
end

-- Fire REAPER's "Show last focused FX embedded UI in TCP/MCP" action. There
-- is NO API for embedding (see CMD 90/91 for the full story); ids are looked
-- up BY NAME via SWS's CF_EnumerateActions so they cannot drift between
-- REAPER versions. The action is a TOGGLE — callers fire it only on an FX
-- they know is not yet embedded. False when SWS or the action is missing.
function eon_embed_last_focused(want_tcp)
  if not reaper.CF_EnumerateActions then return false end
  local want = want_tcp and "in TCP" or "in MCP"
  -- Bounded: the enumeration ends on a 0 id, but never trust an external
  -- API to terminate a while-true in the middle of the dispatcher.
  local i = 0
  while i < 30000 do
    local cid, nm = reaper.CF_EnumerateActions(0, i, "")
    if not cid or cid == 0 then break end
    -- Both halves matter: "Show next single FX embedded UI in TCP" also
    -- contains "in TCP" but is a different action entirely.
    if nm and nm:find("Show last focused FX embedded UI ", 1, true)
          and nm:find(want, 1, true) then
      reaper.Main_OnCommand(cid, 0)
      return true
    end
    i = i + 1
  end
  return false
end

-- Write cover bytes to a temp file and return its path, because gfx_loadimg
-- takes a path and the bytes live inside the .swing.
--
-- ⚠️ The extension must match the CONTENT, not be assumed. gfx_loadimg
-- dispatches on it, so a JPEG written as "cover_x.png" returns -1 and the tile
-- silently falls back to the generated portrait — which is exactly what a
-- .jpg cover did before this sniffed the magic bytes.
function eon_kitcover_extract(bytes, stem)
  if not bytes or #bytes == 0 then return nil end
  local sep = package.config:sub(1, 1)
  local dir = _eon_temp_audio_dir()
  reaper.RecursiveCreateDirectory(dir, 0)
  local ext = ".png"
  if bytes:sub(1, 3) == "\255\216\255" then ext = ".jpg" end          -- JPEG/JFIF
  local safe = ((stem or "kit"):gsub("[^%w%-_]", "_"))
  local cp = dir .. sep .. "cover_" .. safe .. ext
  local cf = io.open(cp, "wb")
  if not cf then return nil end
  cf:write(bytes)
  cf:close()
  return cp
end

eon_kitcover_pend_seen = {}

-- Poll every slot for a cover dropped onto a JSFX tile. Reads the file into
-- eon_kit_cover_bytes so the next save bakes it through the existing
-- eon_kit_cover_for_save path — no new save code.
function eon_kitcover_poll_pending()
  local slot = 0
  while slot < G.GS_INST_REG_MAX do
    local b   = G.KITCOVER_BASE + slot * G.KITCOVER_STRIDE
    local seq = math.floor(reaper.gmem_read(b + G.KITCOVER_PEND_SEQ) or 0)
    if seq ~= (eon_kitcover_pend_seen[slot] or 0) then
      eon_kitcover_pend_seen[slot] = seq
      if seq > 0 then
        local pb = b + G.KITCOVER_PEND_PATH
        local n  = math.floor(reaper.gmem_read(pb) or 0)
        if n > 0 and n <= G.KITCOVER_PATH_MAX then
          local t = {}
          for i = 1, n do
            t[i] = string.char(math.floor(reaper.gmem_read(pb + i) or 0))
          end
          local dp = table.concat(t)
          local fh = io.open(dp, "rb")
          if fh then
            local bytes = fh:read("*a"); fh:close()
            if bytes and #bytes > 0 then
              eon_kit_cover_bytes    = bytes
              eon_kit_cover_src_path = nil   -- a drop: applies to the next save
              eon_kit_cover_pend_slot = slot -- who to ack once it is really baked
              -- Live preview across every face of this instance: the droppee
              -- shows the file locally, but the OTHER reader (LCD tile vs the
              -- Lens card) only watches the PUB mailbox. preview=1 keeps the
              -- UNSAVED cue up everywhere until a real bake publishes 0.
              eon_kitcover_publish(slot, dp, true)
            end
          end
        elseif n == 0 then
          -- Empty pend = the JSFX hit New Kit: the cover belonged to the kit
          -- that was wiped. Unstage anything waiting for the next save and
          -- broadcast "no cover" so every PUB reader (tile, Lens card)
          -- drops the old art immediately.
          eon_kit_cover_bytes     = nil
          eon_kit_cover_src_path  = nil
          eon_kit_cover_pend_slot = nil
          eon_kitcover_publish(slot, "")
        end
      end
    end
    slot = slot + 1
  end
end

local function write_kit_v4(filepath, info, silent)
  -- Empty-kit refusal. Check the JSFX-owned META truth cells (s_len at +34,
  -- layer_cnt at +32) — same reason pad_has_audio below reads META, not
  -- AUDIOLEN_BASE: the latter is a @gfx blast-mirror gated by
  -- _is_browser_target (rk_swing_ui_state.jsfx-inc:1794), so on a fresh
  -- session or cold-start save it can read zero and false-positive-refuse
  -- a save of a kit that actually holds audio. If every pad reports zero
  -- audio AND zero layers, the resulting file would be a 27KB metadata-
  -- only shell — almost never what the user wants, and destructive when
  -- the destination is an existing real kit (e.g. they typed "808" into
  -- the SAVE name field on a fresh-but-not-yet-loaded instance and nuke
  -- the bundled 808_v2.swing).
  --
  -- Allow it only if the destination doesn't yet exist (legit "save an
  -- empty template" workflow). If overwriting, abort with a dialog so
  -- the user can decide whether to clear pads explicitly.
  do
    local any_audio = false
    for pad = 0, G.NUM_PADS - 1 do
      local _mb = G.META_BASE + pad * G.META_PP
      if math.floor(reaper.gmem_read(_mb + 34) or 0) > 0
         or math.floor(reaper.gmem_read(_mb + 32) or 0) > 0 then
        any_audio = true
        break
      end
    end
    -- A kit of synth-only pads is a REAL kit (metadata IS its content —
    -- the vintage-kit story). Only refuse when there's neither audio nor
    -- an enabled synth anywhere.
    if not any_audio and G.SYN.any_enabled() then any_audio = true end
    if not any_audio then
      local existing = io.open(filepath, "rb")
      if existing then
        existing:close()
        eon_notice(
          "This kit has no audio loaded — saving would overwrite the existing file " ..
          "with a metadata-only shell.\n\n" ..
          "If you really want to clear this kit, delete the .swing file manually " ..
          "and re-save. Otherwise, load samples or a kit first, then save.")
        reaper.gmem_write(G.CMD, 98)
        return
      end
    end
  end

  -- Auto-backup before overwrite. If the destination already exists AND
  -- no .bak file exists yet, rename the current file to .bak first. This
  -- protects users from accidentally overwriting a system kit (e.g. saving
  -- a partial-state kit over the bundled "808_v2.swing") with a corrupted
  -- version. The backup is preserved across multiple bad saves: we only
  -- create .bak if it doesn't already exist, so the first known-good
  -- version survives even if subsequent saves are also broken. To recover,
  -- delete the corrupted .swing and rename .bak back to .swing.
  --
  -- ⚠️⚠️ THE RENAME MOVES THE DESTINATION OUT FROM UNDER ANYTHING THAT WANTS TO
  -- RE-READ IT. Several things downstream recover state from "the file we are
  -- about to overwrite" — the `created` date below, and the artwork tail in
  -- eon_kit_cover_for_save. On a kit's FIRST re-save (no .bak yet) the rename
  -- fires and those re-reads open a path that no longer exists, so they
  -- silently get nothing. `dest_prior` is wherever the pre-save file actually
  -- lives afterwards; re-reads must use it, never `filepath`.
  local dest_prior = filepath
  do
    local existing = io.open(filepath, "rb")
    if existing then
      existing:close()
      local bak_path = filepath .. ".bak"
      local bak_check = io.open(bak_path, "rb")
      if bak_check then
        bak_check:close()
        -- .bak already exists — preserve it (don't overwrite the original
        -- known-good version with a potentially-bad recent version).
      else
        os.rename(filepath, bak_path)
        dest_prior = bak_path
      end
    end
  end

  -- 1. Collect paths + per-pad layer counts from gmem
  local pad_paths = {}
  local layer_paths = {}
  local layer_cnts  = {}
  local pad_has_audio = {}
  for pad = 0, G.NUM_PADS - 1 do
    -- A pad with NO audio at save time is written as a genuinely EMPTY pad:
    -- no source paths, no name (below), layer_cnt 0. Without this, a pad the
    -- user left empty kept the previously-loaded kit's name + dead source
    -- paths in the file, and every future load re-recorded a missing source
    -- → permanent relink banner on pads that hold nothing ("My Kit" pads
    -- 8/10-13/15, 2026-07-16). A missing source the user still wants should
    -- be relinked BEFORE saving — the kit file records what the kit plays.
    -- Read from JSFX-owned META cells (s_len at +34, layer_cnt at +32) —
    -- AUDIOLEN_BASE is a @gfx blast-mirror written only when this instance
    -- is the browser target (rk_swing_ui_state.jsfx-inc:1794 gated by
    -- _is_browser_target), so on a fresh session or immediately after JSFX
    -- re-instantiation it can read zero on a pad that holds audio, and
    -- write_kit_v4 would silently save the pad as empty (wiping paths +
    -- name + layer_cnt). Layered pads store audio per-layer (s_len == 0),
    -- so a nonzero layer_cnt is equivalent presence for them.
    local _mb = G.META_BASE + pad * G.META_PP
    local _pad_slen = math.floor(reaper.gmem_read(_mb + 34) or 0)
    local _pad_lcnt = math.floor(reaper.gmem_read(_mb + 32) or 0)
    pad_has_audio[pad] = _pad_slen > 0 or _pad_lcnt > 0

    local pp = read_pad_path_from_gmem(pad)
    if pp == "" then
      pp = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""
    end

    layer_paths[pad] = {}
    for layer = 0, G.MAX_LAYERS - 1 do
      layer_paths[pad][layer] = read_layer_path_from_gmem(pad, layer)
    end
    -- Layer 0 fallback: drag-drop sets pad path = layer 0 path; if the JSFX
    -- didn't push a separate layer-0 path, use the pad path.
    if layer_paths[pad][0] == "" then layer_paths[pad][0] = pp end

    local lc = _pad_lcnt

    if not pad_has_audio[pad] then
      pp = ""
      for layer = 0, G.MAX_LAYERS - 1 do layer_paths[pad][layer] = "" end
      lc = 0
    end
    pad_paths[pad] = pp
    layer_cnts[pad] = math.max(0, math.min(G.MAX_LAYERS, lc))
  end

  -- 2. Build Lua text (kit metadata + per-pad layer descriptions)
  local lua_buf = {}
  local function w(s) lua_buf[#lua_buf + 1] = s end

  w("-- Swing Kit v4 — EON Studios — self-contained, multi-layer\n")
  w("return {\n")
  w('  version  = 4,\n')
  -- Phase 2: USER saves derive the manifest name from the FILE PATH at
  -- write time, so a freshly-saved kit can never carry a diverged internal
  -- name (the old writer stored the raw typed name while the dialog
  -- sanitized the filename — minting exactly the filename≠manifest split
  -- the loaders now paper over). SILENT dumps (kit-undo sidecars, dev
  -- exports) keep info.kit_name: their token filenames
  -- (swing_<guid>_undo.swing) must never become the kit's name.
  w('  kit_name = ' .. core.lua_quote(silent and (info.kit_name or "")
                                 or eon_kit_display_name(filepath, info.kit_name)) .. ',\n')
  w('  author   = ' .. core.lua_quote(info.author or "") .. ',\n')
  -- `created` is the date the KIT came into being, not the date of this write.
  -- Re-read it from the file we are about to overwrite (same recovery pattern
  -- as the author line and the artwork tail); only a genuinely new file gets
  -- today's date. Before this, every SAVE and SAVE AS stamped `created` with
  -- os.date() and a kit's birthday quietly became the last time it was touched
  -- — leaving `modified` describing the exact same instant, twice.
  -- ⚠️ dest_prior, NOT filepath: the auto-backup above may already have renamed
  -- the destination to .bak, and reading `filepath` then yields "" ⇒ today's
  -- date ⇒ exactly the bug this line exists to fix, on every kit's first re-save.
  local prior_created = eon_kit_meta_from_file(dest_prior, "created")
  w('  created  = ' .. core.lua_quote(prior_created ~= "" and prior_created
                                                          or os.date("%Y-%m-%d")) .. ',\n')
  w('  modified = ' .. core.lua_quote(os.date("%Y-%m-%d")) .. ',\n')
  -- The save dialog has always collected a Description and no writer ever
  -- emitted it, so the field silently discarded whatever was typed. Written
  -- last in the block: it is the only free-length field, and keeping it below
  -- the fixed-width ones means a long one can never push them out of the
  -- header window eon_kit_meta_from_file reads.
  w('  desc     = ' .. core.lua_quote(info.desc or "") .. ',\n')
  w('\n')

  -- Globals
  w('  globals = {\n')
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    w('    ' .. name .. ' = ' .. reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1) .. ',\n')
  end
  w('  },\n\n')

  -- Per-pad data
  w('  pads = {\n')
  for pad = 0, G.NUM_PADS - 1 do
    local base = G.META_BASE + pad * G.META_PP

    local name_base = G.PADNAME_BASE + pad * G.PADNAME_LEN
    local name_chars = {}
    for i = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(name_base + i))
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    -- Empty pad → empty name (same scrub as paths/layer_cnt in step 1: a
    -- leftover label on a pad that holds nothing is previous-kit residue).
    -- Synth-only pads keep their name (the engine auto-name or a user name):
    -- they're not "empty" even with zero sample audio.
    local _syn_on = (reaper.gmem_read(G.SYN.BASE + pad * G.SYN.PP) or 0) > 0.5
    local name = (pad_has_audio[pad] or _syn_on) and table.concat(name_chars) or ""

    w('    [' .. (pad + 1) .. '] = {\n')
    w('      path   = ' .. core.lua_quote(pad_paths[pad] or "") .. ',  -- informational; audio is baked\n')
    w('      name   = ' .. core.lua_quote(name) .. ',\n')
    do -- categories 8g: the kit snapshot carries each pad's JOB (additive field,
       -- no version bump — loaders read `p.category or classify(p.name)`).
       -- Prefer the PUBLISHED band over re-classifying. The band holds what the
       -- user actually picked, or what the browser derived from the full path +
       -- folder; `name` here is the 32-char gmem transport name, and a long pack
       -- name loses the very word that identifies it ("Loopmasters Drum and Bass
       -- Toolkit Closed Hat 12" truncates to "...Drum and Bass Toolki" and
       -- classifies as BASS). Without this a hand-set category could not survive
       -- a save/load round trip. Falls back to the old behaviour whenever the
       -- band has nothing published, so this is never worse than before.
      local _kc = ""
      local _cslot = math.floor((reaper.gmem_read(97) or 0) + 0.5) - 1
      if _cslot >= 0 and _cslot <= 15 then
        eon_padcat_index("kick")                    -- ensure the id->name map exists
        local _cb = EON_PADCAT_BASE + _cslot * EON_PADCAT_STRIDE + pad * 4
        if (reaper.gmem_read(_cb) or 0) > 0 then    -- VER > 0 = actually published
          local _cid = math.floor((reaper.gmem_read(_cb + 1) or -1) + 0.5)
          _kc = eon_padcat_names and eon_padcat_names[_cid] or ""
          if _kc == "other" then _kc = "" end
        end
      end
      if _kc == "" and _bridge_categorizer and name ~= "" then
        local c, conf = _bridge_categorizer.classify(name)
        if conf and c ~= "other" then _kc = c end
      end
      w('      category = ' .. core.lua_quote(_kc) .. ',\n')
    end
    w('      gain   = ' .. reaper.gmem_read(base + 0) .. ',\n')
    w('      pan    = ' .. reaper.gmem_read(base + 1) .. ',\n')
    w('      pitch  = ' .. reaper.gmem_read(base + 2) .. ',\n')
    w('      attack = ' .. reaper.gmem_read(base + 3) .. ',\n')
    w('      decay  = ' .. reaper.gmem_read(base + 4) .. ',\n')
    w('      sustain = ' .. reaper.gmem_read(base + 5) .. ',\n')
    w('      release = ' .. reaper.gmem_read(base + 6) .. ',\n')
    w('      mute   = ' .. reaper.gmem_read(base + 7) .. ',\n')
    w('      solo   = ' .. reaper.gmem_read(base + 8) .. ',\n')
    w('      output = ' .. reaper.gmem_read(base + 9) .. ',\n')
    w('      note   = ' .. reaper.gmem_read(base + 10) .. ',\n')
    w('      note_lock = ' .. reaper.gmem_read(base + 11) .. ',\n')
    w('      color  = ' .. reaper.gmem_read(base + 12) .. ',\n')
    w('      choke  = ' .. reaper.gmem_read(base + 13) .. ',\n')
    w('      oneshot = ' .. reaper.gmem_read(base + 14) .. ',\n')
    w('      reverse = ' .. reaper.gmem_read(base + 15) .. ',\n')
    w('      fx_hpf = ' .. reaper.gmem_read(base + 16) .. ',\n')
    w('      fx_lpf = ' .. reaper.gmem_read(base + 17) .. ',\n')
    w('      fx_eq_lo = ' .. reaper.gmem_read(base + 18) .. ',\n')
    w('      fx_eq_mid = ' .. reaper.gmem_read(base + 19) .. ',\n')
    w('      fx_eq_hi = ' .. reaper.gmem_read(base + 20) .. ',\n')
    w('      fx_sat = ' .. reaper.gmem_read(base + 21) .. ',\n')
    w('      fx_drv_mode = ' .. reaper.gmem_read(base + 22) .. ',\n')
    w('      fx_bc_rate = ' .. reaper.gmem_read(base + 23) .. ',\n')
    w('      fx_bc_bits = ' .. reaper.gmem_read(base + 24) .. ',\n')
    w('      fx_snd_dly = ' .. reaper.gmem_read(base + 25) .. ',\n')
    w('      fx_snd_rvb = ' .. reaper.gmem_read(base + 26) .. ',\n')
    w('      fx_snd_smash = ' .. reaper.gmem_read(G.GS_PAD_SMASH_BASE + pad) .. ',\n')
    w('      fx_eq_lo_freq = ' .. reaper.gmem_read(base + 27) .. ',\n')
    w('      fx_eq_mid_freq = ' .. reaper.gmem_read(base + 28) .. ',\n')
    w('      fx_eq_hi_freq = ' .. reaper.gmem_read(base + 29) .. ',\n')
    w('      sum_tight = ' .. reaper.gmem_read(base + 30) .. ',\n')
    w('      rpt_div = ' .. reaper.gmem_read(base + 31) .. ',\n')
    w('      layer_cnt = ' .. layer_cnts[pad] .. ',\n')
    w('      layer_mode = ' .. reaper.gmem_read(base + 33) .. ',\n')
    w('      s_len   = ' .. reaper.gmem_read(base + 34) .. ',\n')
    w('      s_start = ' .. reaper.gmem_read(base + 35) .. ',\n')
    w('      s_end   = ' .. reaper.gmem_read(base + 36) .. ',\n')
    w('      s_sr    = ' .. reaper.gmem_read(base + 37) .. ',\n')
    w('      s_norm  = ' .. reaper.gmem_read(base + 38) .. ',\n')
    w('      s_norm_gain = ' .. reaper.gmem_read(base + 39) .. ',\n')
    w('      sample_offset = ' .. reaper.gmem_read(G.GS_PAD_OFFSET_BASE + pad) .. ',\n')
    -- Chromatic key-range — unpack lo*128+hi from the packed gmem slot
    local _rpk = reaper.gmem_read(G.GS_PAD_RANGE_BASE + pad)
    local _rlo = math.floor(_rpk / 128)
    w('      rng_lo = ' .. _rlo .. ',\n')
    w('      rng_hi = ' .. (_rpk - _rlo * 128) .. ',\n')
    -- SYN slot (synth layer) — additive field like `category`: loaders
    -- without syn support ignore it; syn-aware loaders stage + adopt.
    local _syb = G.SYN.BASE + pad * G.SYN.PP
    w('      syn = { enable = ' .. reaper.gmem_read(_syb + 0) ..
      ', engine = ' .. reaper.gmem_read(_syb + 1) ..
      ', level = ' .. reaper.gmem_read(_syb + 2) ..
      ', vel_lo = ' .. reaper.gmem_read(_syb + 3) ..
      ', vel_hi = ' .. reaper.gmem_read(_syb + 4) ..
      ', rr_order = ' .. reaper.gmem_read(_syb + 5) .. ',\n')
    w('        macros = { ' .. reaper.gmem_read(_syb + 6) .. ', ' .. reaper.gmem_read(_syb + 7) ..
      ', ' .. reaper.gmem_read(_syb + 8) .. ', ' .. reaper.gmem_read(_syb + 9) ..
      ', ' .. reaper.gmem_read(_syb + 10) .. ', ' .. reaper.gmem_read(_syb + 11) ..
      ', ' .. reaper.gmem_read(_syb + 12) .. ', ' .. reaper.gmem_read(_syb + 13) .. ' } },\n')

    -- Per-layer metadata (only if pad has layers)
    if layer_cnts[pad] > 0 then
      w('      layers = {\n')
      for layer = 0, layer_cnts[pad] - 1 do
        local lo = base + 40 + layer * 10  -- 10 doubles per layer in meta region
        w('        [' .. (layer + 1) .. '] = {\n')
        w('          path = ' .. core.lua_quote(layer_paths[pad][layer] or "") .. ',\n')
        w('          len = ' .. reaper.gmem_read(lo + 0) .. ',\n')
        w('          start = ' .. reaper.gmem_read(lo + 1) .. ',\n')
        w('          ["end"] = ' .. reaper.gmem_read(lo + 2) .. ',\n')
        w('          sr = ' .. reaper.gmem_read(lo + 3) .. ',\n')
        w('          norm = ' .. reaper.gmem_read(lo + 4) .. ',\n')
        w('          norm_gain = ' .. reaper.gmem_read(lo + 5) .. ',\n')
        w('          vel_lo = ' .. reaper.gmem_read(lo + 6) .. ',\n')
        w('          vel_hi = ' .. reaper.gmem_read(lo + 7) .. ',\n')
        w('          rr_order = ' .. reaper.gmem_read(lo + 8) .. ',\n')
        w('          gain = ' .. reaper.gmem_read(lo + 9) .. ',\n')
        w('        },\n')
      end
      w('      },\n')
    end

    w('    },\n')
  end
  w('  },\n')
  w('}\n')

  local lua_text = table.concat(lua_buf)
  local lua_len = #lua_text

  -- 3. Open file and write: magic + lua_len + lua + per-pad audio
  local f = io.open(filepath, "wb")
  if not f then
    eon_notice("Could not create file:\n" .. filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- Audio for BOTH layered and non-layered pads is baked from the JSFX
  -- state-11 gmem dump — the live audio the plugin is actually playing —
  -- never from the pads' disk SOURCE paths. Previously only the non-layered
  -- branch trusted the dump; the layered branch read each layer from its disk
  -- source (stream_pcm_to_file). If those files had moved/been deleted (e.g.
  -- the 808 kit's samples relocated Documents→Desktop) the layered save wrote
  -- silent zero-blobs → a 27KB metadata-only "blank" kit. The dump is immune
  -- to moved sources, giving layered pads the same self-contained guarantee
  -- non-layered pads already had.
  --
  -- Layout mirrors rk_swing_ui_state.jsfx-inc state 11 EXACTLY: pads in order;
  -- within a layered pad, each layer in order; only non-empty blobs advance the
  -- shared read offset. l_len/l_sr (and s_len/s_sr) are read from the per-pad
  -- META slots the JSFX populated in the same save cycle.
  local dump_off = 0
  local function write_dump_blob(len, sr)
    len = math.floor(len or 0)
    if len <= 0 then
      -- Empty pad/layer — zero-blob header (loader reads [0][0], no PCM).
      f:write(pack_double(0)); f:write(pack_double(0))
      return
    end
    local wlen = len
    if dump_off + wlen > GMEM_AUDIO_MAX then
      wlen = math.max(0, GMEM_AUDIO_MAX - dump_off)
    end
    f:write(pack_double(wlen))
    f:write(pack_double(sr or 0))
    for j = 0, wlen - 1 do
      f:write(pack_s16(reaper.gmem_read(G.AUDIO_BASE + AUDIO_DUMP_OFFSET + dump_off + j)))
    end
    dump_off = dump_off + wlen
  end

  -- Resolved BEFORE the write so the same bytes can be echoed back to the tile
  -- afterwards; without that ack the UNSAVED badge never clears and a save that
  -- worked perfectly looks like it did nothing.
  local cover_bytes = eon_kit_cover_for_save(filepath, dest_prior)

  local write_ok, write_err = pcall(function()
    f:write("SWINGv04")
    f:write(pack_double(lua_len))
    f:write(lua_text)

    for pad = 0, G.NUM_PADS - 1 do
      local base = G.META_BASE + pad * G.META_PP
      local lc = layer_cnts[pad]
      f:write(pack_double(lc))
      if lc > 0 then
        -- Layered pad: one blob per layer, pulled from the dump in the same
        -- order state 11 wrote them.
        for layer = 0, lc - 1 do
          local lo = base + 40 + layer * 10  -- per-layer META block (stride 10)
          write_dump_blob(reaper.gmem_read(lo + 0),   -- l_len
                          reaper.gmem_read(lo + 3))    -- l_sr
        end
      else
        -- Non-layered pad: single pad-main blob from the dump.
        write_dump_blob(reaper.gmem_read(base + 34),   -- s_len
                        reaper.gmem_read(base + 37))    -- s_sr
      end
    end

    -- Tail records LAST, after every pad blob — that placement is what keeps
    -- older readers working, since they stop counting at NUM_PADS.
    -- Tag 2 = the kit-macro model (nil when trivial — see eon_kmac_pack).
    eon_kit_tail_write(f, { [EON_KIT_TAIL_COVER] = cover_bytes,
                            [EON_KIT_TAIL_MACRO] = eon_kmac_pack() })
  end)
  f:close()

  -- Ack the cover back to the tile that staged it: the bytes are now really in
  -- the kit, so the UNSAVED badge clears and the tile switches to the baked
  -- image. Also re-anchor the carry-over to this file, so a later re-save of
  -- THIS kit keeps its art while saving a different kit does not inherit it.
  if write_ok and cover_bytes then
    eon_kit_cover_bytes    = cover_bytes
    eon_kit_cover_src_path = filepath
    local stem = filepath:match("([^/\\]+)%.[Ss][Ww][Ii][Nn][Gg]$") or "kit"
    eon_kit_cover_path = eon_kitcover_extract(cover_bytes, stem)
    local ack = eon_kit_cover_pend_slot or eon_kit_cover_load_slot
    if ack then eon_kitcover_publish(ack, eon_kit_cover_path) end
    eon_kit_cover_pend_slot = nil
  end

  if not write_ok then
    eon_notice("Error writing kit file (disk full?):\n" .. tostring(write_err))
    os.remove(filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local fcheck = io.open(filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  -- Silent mode (auto-sidecar): skip CMD=99 write AND the success dialog.
  -- CMD=99 is the kit-import-completion ACK that triggers a global pad-name
  -- re-read in every Swing's @gfx (rk_swing_ui_state.jsfx-inc:614). Setting
  -- it on a SAVE event causes other instances' pad names to get clobbered
  -- by gmem state. The dialog also creates a yield window where @gfx fires
  -- before our cleanup writes CMD=0. Skipping both keeps auto-save invisible
  -- to the JSFX side and prevents cross-instance state pollution.
  -- Register saved file as kit source for sidecar system
  register_kit_source_after_save(filepath)

  if silent then
    reaper.gmem_write(G.CMD, 0)
  else
    reaper.gmem_write(G.CMD, 99)
    reaper.SetExtState("Swing", "kit_saved", "1", false)
    eon_notice(
      'Kit saved (self-contained, multi-layer)!\n\n' ..
      'Name: ' .. info.kit_name .. '\n' ..
      'Size: ' .. core.format_size(fsize) .. '\n' ..
      'Location: ' .. filepath)
  end
  update_folder_track_name(find_swing_track())
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- v5 KIT BUNDLE — self-contained zip (kit.json + pad_NN.wav files)
-- ═══════════════════════════════════════════════════════════════════════════════
-- File format: zip-STORE archive containing
--     kit.json                       — manifest (all metadata)
--     pad_NN.wav                     — non-layered pad audio, 16-bit PCM
--     pad_NN_layer_LL.wav            — layered pad audio per layer
-- Audio inside the bundle is OWNED by the kit (copied at save time), so source
-- files can move/be deleted with no effect on the kit. Choppa pads materialize
-- to wav at save just like any other pad — no special case at format level.
--
-- Round-trip uses the swing_kit_v5 IIFE defined at the top of this file
-- (json / wav / zip / write_kit / load_kit helpers).

-- ── Audio capture: PCM source on disk → int16 samples table ──────────────
-- Mirrors stream_pcm_to_file's behavior: averages multi-channel to mono and
-- duplicates as interleaved stereo (L=R). max_frames caps total mono frames.
local function read_pcm_source_to_int16(filepath, max_frames)
  if not filepath or filepath == "" then return nil, 0 end
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return nil, 0 end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  local total_samples = math.floor(length * sr)
  local num_samples = math.min(total_samples, max_frames or total_samples)
  if num_samples <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil, 0
  end

  local tr = acquire_scratch_track()
  if not tr then
    reaper.PCM_Source_Destroy(src)
    return nil, 0
  end

  local temp_item = reaper.AddMediaItemToTrack(tr)
  local temp_take = reaper.AddTakeToMediaItem(temp_item)
  reaper.SetMediaItemTake_Source(temp_take, src)
  reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

  local aa = reaper.CreateTakeAudioAccessor(temp_take)
  if not aa then
    release_scratch_track(tr)
    return nil, 0
  end

  local chunk_size = math.min(num_samples, 250000)
  local sample_buf = reaper.new_array(chunk_size * nch)
  local samples = {}            -- int16 stereo interleaved
  local samples_read = 0

  while samples_read < num_samples do
    local to_read = math.min(chunk_size, num_samples - samples_read)
    sample_buf.clear()
    reaper.GetAudioAccessorSamples(aa, sr, nch, samples_read / sr, to_read, sample_buf)
    for j = 0, to_read - 1 do
      local val
      if nch == 1 then
        val = sample_buf[j + 1] or 0
      else
        val = 0
        for ch = 0, nch - 1 do val = val + (sample_buf[j * nch + ch + 1] or 0) end
        val = val / nch
      end
      -- Clamp + convert to int16 (matches pack_s16 semantics)
      if val < -1.0 then val = -1.0 elseif val > 1.0 then val = 1.0 end
      local i16 = math.floor(val * 32767 + 0.5)
      if i16 < -32768 then i16 = -32768 elseif i16 > 32767 then i16 = 32767 end
      samples[#samples + 1] = i16   -- L
      samples[#samples + 1] = i16   -- R
    end
    samples_read = samples_read + to_read
  end

  reaper.DestroyAudioAccessor(aa)
  release_scratch_track(tr)
  return samples, sr
end

-- Helper: read a string of bytes for the first N from a file (magic detect).
local function read_file_magic(filepath, n)
  local f = io.open(filepath, "rb")
  if not f then return nil end
  local head = f:read(n or 8)
  f:close()
  return head
end

-- ── write_kit_v5 — produce a self-contained zip kit ──────────────────────
local function write_kit_v5(filepath, info, silent)
  -- ── Snapshot gmem state ONCE up front ─────────────────────────────────
  -- The JSFX @gfx mirror is writing AUDIOLEN_BASE/META continuously on a
  -- separate thread. If we read those values in different loops during the
  -- save, two reads of the same slot can return DIFFERENT values, and the
  -- manifest ends up describing one snapshot of gmem while the wav files
  -- come from another. Symptom: manifest says "pads 1-4 have audio" but
  -- the captured wavs are pad_01/pad_07/pad_10. Snapshotting everything
  -- now means the rest of the function works off frozen locals.
  local snap_audiolen = {}    -- AUDIOLEN_BASE per pad
  local snap_meta     = {}    -- full META block per pad (40 + MAX_LAYERS*10 doubles)
  local snap_padname  = {}    -- raw pad name characters per pad
  local snap_offset   = {}    -- sample offset per pad
  local snap_range    = {}    -- packed chromatic key-range (lo*128+hi) per pad
  local snap_smash    = {}    -- smash send per pad (overflow band; META is full)
  for pad = 0, G.NUM_PADS - 1 do
    snap_audiolen[pad] = math.floor(reaper.gmem_read(G.AUDIOLEN_BASE + pad) or 0)
    local mb = G.META_BASE + pad * G.META_PP
    local row = {}
    for j = 0, G.META_PP - 1 do
      row[j] = reaper.gmem_read(mb + j)
    end
    snap_meta[pad] = row
    snap_padname[pad] = {}
    for i = 0, G.PADNAME_LEN - 1 do
      snap_padname[pad][i] = math.floor(reaper.gmem_read(G.PADNAME_BASE + pad * G.PADNAME_LEN + i))
    end
    snap_offset[pad] = reaper.gmem_read(G.GS_PAD_OFFSET_BASE + pad)
    snap_range[pad]  = reaper.gmem_read(G.GS_PAD_RANGE_BASE + pad)
    snap_smash[pad]  = reaper.gmem_read(G.GS_PAD_SMASH_BASE + pad)
  end

  -- Optional gmem-state dump at save time. Enable via:
  --   reaper.SetExtState("EON_Swing", "save_debug", "1", false)
  -- Prints AUDIOLEN, s_len from META, and pad name for every populated pad,
  -- so we can see exactly what gmem says at the moment SAVE fires (vs what
  -- the JSFX UI shows the user). Toggles off by setting to "0" or clearing.
  if reaper.GetExtState and reaper.GetExtState("EON_Swing", "save_debug") == "1" then
    reaper.ShowConsoleMsg("\n=== write_kit_v5 SAVE DEBUG @ " .. os.date() .. " ===\n")
    reaper.ShowConsoleMsg("Filepath: " .. tostring(filepath) .. "\n")
    for pad = 0, G.NUM_PADS - 1 do
      local alen = snap_audiolen[pad]
      local slen = math.floor(snap_meta[pad][34] or 0)
      local lc = math.floor(snap_meta[pad][32] or 0)
      local pp = read_pad_path_from_gmem(pad)
      local name_chars = {}
      for i = 0, G.PADNAME_LEN - 1 do
        local c = snap_padname[pad][i]
        if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
      end
      local name = table.concat(name_chars)
      if alen > 0 or slen > 0 or lc > 0 or name ~= "" then
        reaper.ShowConsoleMsg(string.format(
          "  pad %2d (UI %2d): AUDIOLEN=%8d  s_len=%8d  layer_cnt=%d  path=%q  name=%q\n",
          pad, pad + 1, alen, slen, lc, pp, name))
      end
    end
    reaper.ShowConsoleMsg("=== end SAVE DEBUG ===\n")
  end

  -- Empty-kit guard. Uses BOTH META s_len (slot 34) AND AUDIOLEN_BASE — if
  -- either source says any pad has audio, allow the save. Single-source is
  -- fragile because META is written only at JSFX state 11 (by the saving
  -- instance) while AUDIOLEN_BASE is written every @gfx frame (by the
  -- browser-target instance). Multi-instance projects or fast SAVE clicks
  -- can leave one source empty even when the other is populated.
  do
    local total_meta = 0
    local total_audiolen = 0
    for pad = 0, G.NUM_PADS - 1 do
      total_meta = total_meta + math.floor(snap_meta[pad][34] or 0)
      total_audiolen = total_audiolen + snap_audiolen[pad]
      local lc = math.floor(snap_meta[pad][32] or 0)
      if lc > 0 then
        for layer = 0, lc - 1 do
          total_meta = total_meta + math.floor(snap_meta[pad][40 + layer * 10] or 0)
        end
      end
    end
    local total_audio = math.max(total_meta, total_audiolen)
    -- Console warning when the two sources disagree — points at a state
    -- machine bug (kit_import not done, instance race, etc.)
    if total_meta == 0 and total_audiolen > 0 then
      reaper.ShowConsoleMsg(string.format(
        "Swing SAVE: META s_len shows empty (0) but AUDIOLEN_BASE shows %d total — "
        .. "state 11 didn't write META. Falling back to AUDIOLEN_BASE.\n", total_audiolen))
    elseif total_meta > 0 and total_audiolen == 0 then
      reaper.ShowConsoleMsg(string.format(
        "Swing SAVE: META s_len shows %d total but AUDIOLEN_BASE is 0 — @gfx mirror "
        .. "didn't update AUDIOLEN. Using META for capture.\n", total_meta))
    end
    if total_audio == 0 then
      eon_notice(
        "This kit has no audio loaded in gmem at the moment SAVE fired — the .swing file " ..
        "would only contain pad names and parameters (no wav data).\n\n" ..
        "Common causes:\n" ..
        "  - Chop was applied but the JSFX state machine didn't fully import before SAVE was clicked\n" ..
        "  - Multiple Swing instances racing on gmem (one cleared what the other wrote)\n" ..
        "  - CLEAR/NEW was clicked between chop and SAVE\n\n" ..
        "Try: redo the chop, wait ~1 second for the audio waveforms to appear on the pads, " ..
        "THEN click SAVE.\n\n" ..
        "Aborting save to avoid creating an empty kit file.")
      reaper.gmem_write(G.CMD, 98)
      return
    end
  end

  -- Auto-backup before overwrite (same as v4)
  do
    local existing = io.open(filepath, "rb")
    if existing then
      existing:close()
      local bak_path = filepath .. ".bak"
      local bak_check = io.open(bak_path, "rb")
      if bak_check then
        bak_check:close()
      else
        os.rename(filepath, bak_path)
      end
    end
  end

  -- 1. Collect paths and layer counts. Paths/layer paths come from a
  -- different gmem region (KIT_GMEM_AUDIO, populated by state 11) which is
  -- stable across the save cycle, so they don't need the snapshot. Layer
  -- count comes from snap_meta to stay consistent with the rest of the
  -- save.
  local pad_paths = {}
  local layer_paths = {}
  local layer_cnts  = {}
  for pad = 0, G.NUM_PADS - 1 do
    local pp = read_pad_path_from_gmem(pad)
    if pp == "" then
      pp = reaper.GetExtState("Swing", "pad_path_" .. pad) or ""
    end
    pad_paths[pad] = pp
    layer_paths[pad] = {}
    for layer = 0, G.MAX_LAYERS - 1 do
      layer_paths[pad][layer] = read_layer_path_from_gmem(pad, layer)
    end
    if layer_paths[pad][0] == "" then layer_paths[pad][0] = pp end
    local lc = math.floor(snap_meta[pad][32])
    layer_cnts[pad] = math.max(0, math.min(G.MAX_LAYERS, lc))
  end

  -- 2. Build the manifest as a Lua table (encoded to JSON inside swing_kit_v5)
  -- Same two metadata fixes as write_kit_v4: preserve the kit's birthday
  -- across a re-save, and actually persist the Description the dialog collects.
  -- ⚠️ v5 writes a ZIP, so eon_kit_meta_from_file (a text-header scan) cannot
  -- read a prior v5 file and `created` falls back to today on a v5→v5 re-save.
  -- Recovering it properly means unzipping to reach kit.json, which today only
  -- swing_kit_v5.load_kit does — and it pulls every pad buffer with it. Left as
  -- is deliberately: v5 is opt-in via the save_format ExtState and off by
  -- default, so no shipping save path hits this. Fix it here if v5 ever ships.
  local prior_created = eon_kit_meta_from_file(filepath, "created")
  local manifest = {
    version  = 5,
    kit_name = info.kit_name,
    author   = info.author or "",
    created  = prior_created ~= "" and prior_created or os.date("%Y-%m-%d"),
    modified = os.date("%Y-%m-%d"),
    desc     = info.desc or "",
    globals  = {},
    pads     = {},
  }
  for i, name in ipairs(KIT_GLOBAL_KEYS) do
    manifest.globals[name] = reaper.gmem_read(KIT_GMEM_GLOBALS + i - 1)
  end

  -- IMPORTANT: this loop now reads exclusively from the snapshot. The
  -- `audio` field is only set for pads that ACTUALLY have audio (snapshot
  -- says alen > 0 or layer_cnts > 0), so we never advertise a wav filename
  -- that won't appear in the bundle. Pads with no audio leave `audio` nil
  -- and the loader correctly treats them as empty.
  for pad = 0, G.NUM_PADS - 1 do
    local m = snap_meta[pad]
    local name_chars = {}
    for i = 0, G.PADNAME_LEN - 1 do
      local c = snap_padname[pad][i]
      if c > 0 then name_chars[#name_chars + 1] = string.char(c) end
    end
    local pad_entry = {
      path          = pad_paths[pad] or "",
      name          = table.concat(name_chars),
      gain          = m[0],
      pan           = m[1],
      pitch         = m[2],
      attack        = m[3],
      decay         = m[4],
      sustain       = m[5],
      release       = m[6],
      mute          = m[7],
      solo          = m[8],
      output        = m[9],
      note          = m[10],
      note_lock     = m[11],
      color         = m[12],
      choke         = m[13],
      oneshot       = m[14],
      reverse       = m[15],
      fx_hpf        = m[16],
      fx_lpf        = m[17],
      fx_eq_lo      = m[18],
      fx_eq_mid     = m[19],
      fx_eq_hi      = m[20],
      fx_sat        = m[21],
      fx_drv_mode   = m[22],
      fx_bc_rate    = m[23],
      fx_bc_bits    = m[24],
      fx_snd_dly    = m[25],
      fx_snd_rvb    = m[26],
      fx_snd_smash  = snap_smash[pad] or 0,
      fx_eq_lo_freq = m[27],
      fx_eq_mid_freq= m[28],
      fx_eq_hi_freq = m[29],
      sum_tight     = m[30],
      rpt_div       = m[31],
      layer_cnt     = layer_cnts[pad],
      layer_mode    = m[33],
      s_len         = m[34],
      s_start       = m[35],
      s_end         = m[36],
      s_sr          = m[37],
      s_norm        = m[38],
      s_norm_gain   = m[39],
      sample_offset = snap_offset[pad],
      rng_lo        = math.floor((snap_range[pad] or 0) / 128),
      rng_hi        = (snap_range[pad] or 0) - math.floor((snap_range[pad] or 0) / 128) * 128,
      audio         = nil,    -- set below ONLY when the pad has captured audio
      layers        = nil,    -- set below if layered
    }

    if layer_cnts[pad] > 0 then
      pad_entry.layers = {}
      for layer = 0, layer_cnts[pad] - 1 do
        local lo_offset = 40 + layer * 10
        pad_entry.layers[layer + 1] = {
          path      = layer_paths[pad][layer] or "",
          len       = m[lo_offset + 0],
          start     = m[lo_offset + 1],
          ["end"]   = m[lo_offset + 2],
          sr        = m[lo_offset + 3],
          norm      = m[lo_offset + 4],
          norm_gain = m[lo_offset + 5],
          vel_lo    = m[lo_offset + 6],
          vel_hi    = m[lo_offset + 7],
          rr_order  = m[lo_offset + 8],
          gain      = m[lo_offset + 9],
          -- `audio` is set ONLY after the wav is actually captured (loop 3
          -- below), so a layered pad with a missing layer-source disk file
          -- doesn't end up with a stale audio reference.
          audio     = nil,
        }
      end
    end
    -- Non-layered pads: pad_entry.audio gets set in loop 3 if and only if
    -- the audio capture succeeds.

    manifest.pads[pad + 1] = pad_entry
  end

  -- 3. Gather pad audio into pad_buffers keyed by wav filename.
  -- IMPORTANT: AUDIOLEN_BASE is read from the snapshot taken at the top
  -- of this function — NOT live gmem — so the alen the manifest used in
  -- the loop above matches the alen this loop sees. Each successful
  -- capture also stamps the manifest pad_entry.audio field, so manifest
  -- audio references and zip wav contents are 1:1.
  local pad_buffers = {}
  local layer_max_frames = math.floor(G.LAYER_SIZE / 2)
  local pad_max_frames   = math.floor(G.SLOT_SIZE / 2)
  for pad = 0, G.NUM_PADS - 1 do
    local lc = layer_cnts[pad]
    local pad_entry = manifest.pads[pad + 1]
    if lc > 0 then
      for layer = 0, lc - 1 do
        local lp = layer_paths[pad][layer]
        if lp and lp ~= "" then
          local samples, sr = read_pcm_source_to_int16(lp, layer_max_frames)
          if samples and #samples > 0 then
            local wav_name = string.format("pad_%02d_layer_%02d.wav", pad + 1, layer + 1)
            pad_buffers[wav_name] = { samples = samples, sample_rate = sr, channels = 2 }
            pad_entry.layers[layer + 1].audio = wav_name
          end
        end
      end
    else
      local pp = pad_paths[pad]
      -- Pick the audio-length source that has a value for this pad. Prefer
      -- META s_len (slot 34) — written by THIS instance's state-11 export.
      -- Fall back to AUDIOLEN_BASE if META is 0 — happens when state 11 didn't
      -- write META (race, partial state) but the @gfx mirror is up-to-date.
      local meta_len     = math.floor(snap_meta[pad][34] or 0)
      local audiolen_len = snap_audiolen[pad]
      local alen = meta_len > 0 and meta_len or audiolen_len
      local samples, sr
      if (not pp or pp == "") and alen > 0 then
        -- Choppa pad: capture from the JSFX-dumped audio region (NOT the
        -- path-overlaid AUDIO_BASE + 0). JSFX state 11 writes s_audio_start[]
        -- to AUDIO_BASE + AUDIO_DUMP_OFFSET right before signalling CMD=1.
        --
        -- Use the SAME source (meta or audiolen) for the offset that we used
        -- for the length — mixing would misalign the read.
        local use_meta = (meta_len > 0)
        local audio_off = 0
        for p = 0, pad - 1 do
          if use_meta then
            audio_off = audio_off + math.floor(snap_meta[p][34] or 0)
          else
            audio_off = audio_off + snap_audiolen[p]
          end
        end
        local capped = alen
        if audio_off + capped > GMEM_AUDIO_MAX then
          capped = math.max(0, GMEM_AUDIO_MAX - audio_off)
        end
        if capped > 0 then
          samples = {}
          for j = 0, capped - 1 do
            -- Read from the dump region (NOT from path-overlaid offset 0)
            local v = reaper.gmem_read(G.AUDIO_BASE + AUDIO_DUMP_OFFSET + audio_off + j) or 0
            local i16
            if v > 1.5 or v < -1.5 then
              i16 = math.floor(v + 0.5)
            else
              if v < -1.0 then v = -1.0 elseif v > 1.0 then v = 1.0 end
              i16 = math.floor(v * 32767 + 0.5)
            end
            if i16 < -32768 then i16 = -32768 elseif i16 > 32767 then i16 = 32767 end
            samples[j + 1] = i16
          end
          sr = math.floor(snap_meta[pad][37] or 0)
        end
      elseif pp and pp ~= "" then
        samples, sr = read_pcm_source_to_int16(pp, pad_max_frames)
      end
      if samples and #samples > 0 then
        local wav_name = string.format("pad_%02d.wav", pad + 1)
        pad_buffers[wav_name] = { samples = samples, sample_rate = sr, channels = 2 }
        pad_entry.audio = wav_name
        -- Update the manifest s_len to reflect captured count so loader's
        -- per-pad audio length always matches the wav payload (single
        -- source of truth from this point on).
        pad_entry.s_len = #samples
        if sr and sr > 0 then pad_entry.s_sr = sr end
      else
        -- No audio captured — make sure s_len reflects that, otherwise the
        -- loader may try to consume nonexistent samples.
        pad_entry.s_len = 0
      end
    end
  end

  -- 4. Hand off to the v5 bundle writer
  local ok, err = swing_kit_v5.write_kit(filepath, manifest, pad_buffers)
  if not ok then
    eon_notice("Error writing v5 kit:\n" .. tostring(err))
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- 5. Trailing: file size, sidecar registration, success dialog/ACK
  local fcheck = io.open(filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  register_kit_source_after_save(filepath)

  if silent then
    reaper.gmem_write(G.CMD, 0)
  else
    reaper.gmem_write(G.CMD, 99)
    reaper.SetExtState("Swing", "kit_saved", "1", false)
    eon_notice(
      'Kit saved (v5 bundle — kit owns its audio)!\n\n' ..
      'Name: ' .. info.kit_name .. '\n' ..
      'Size: ' .. core.format_size(fsize) .. '\n' ..
      'Location: ' .. filepath)
  end
  update_folder_track_name(find_swing_track())
end

function rk_export.do_export_write_file()
  local info = pending_export
  if not info then reaper.gmem_write(G.CMD, 98); return end

  -- SFZ export reads the same per-pad dump but emits a sample map, not a kit
  -- file. Branch before any .swing version logic.
  if info.format == "sfz" then
    rk_export.write_kit_sfz(info.filepath, info)
    pending_export = nil
    return
  end

  -- RS5k rack export: same dump, but build a ReaSamplOmatic5000 rack instead of
  -- writing a sample-map file.
  if info.format == "rs5k" then
    rk_export.write_kit_rs5k(info)
    pending_export = nil
    return
  end

  -- JSFX signals "200" from state 11. Default = v4 (legacy hybrid, works
  -- reliably for kits whose pads have disk source files). v5 (self-contained
  -- zip bundle) is opt-in until we land the JSFX-side audio-dump fix that
  -- makes Choppa pads work reliably with v5.
  --
  -- Opt in to v5: reaper.SetExtState("EON_Swing", "save_format", "v5", false)
  local ver = math.floor(reaper.gmem_read(G.KIT_GMEM_VER))
  if ver == 200 then
    local fmt = (reaper.GetExtState("EON_Swing", "save_format") or ""):lower()
    if fmt == "v5" then
      write_kit_v5(info.filepath, info)
    else
      write_kit_v4(info.filepath, info)
    end
    pending_export = nil
    return
  end

  -- ── Pre-200 legacy writer — LOOKS wrong, is correct. Do not "modernise". ──
  -- Reached only when the JSFX did NOT stamp VER=200, i.e. an older plugin
  -- build paired with this bridge. Traced 2026-08-23: state 11 sets VER=24 at
  -- the top of phase 2 (rk_swing_ui_state.jsfx-inc:209), overwrites it with 200
  -- at :474, and only then signals CMD 1/84 at :478 — the sole CMD-1 site in
  -- the whole JSFX. So on any current build `ver` is always 200 and this path
  -- never runs.
  --
  -- It sums AUDIOLEN for its offset and reads AUDIO_BASE + off WITHOUT
  -- AUDIO_DUMP_OFFSET. Both are banned in new code (see
  -- .docs/wiki/05-memory-and-gmem.md §5.5) — but they are RIGHT here, because
  -- the pre-200 JSFX this serves wrote its audio at exactly those addresses;
  -- the dump region did not exist yet. Porting the modern protocol onto it
  -- would break the only case it exists for.
  local f = io.open(info.filepath, "wb")
  if not f then
    eon_notice("Could not create file:\n" .. info.filepath)
    reaper.gmem_write(G.CMD, 98)
    pending_export = nil
    return
  end

  -- Wrap the v1 binary write in pcall (matches v3/v4 saves at lines
  -- 988-1000 and 1194-1216). A disk-full / quota-exceeded mid-write
  -- without this guard previously crashed the bridge AND left a
  -- partial file behind.
  local total_saved = 0
  local write_ok, write_err = pcall(function()
    -- Header
    f:write(pack_double(MAGIC))
    f:write(pack_double(FORMAT_VER))
    f:write(pack_double(G.NUM_PADS))
    write_gmem_string(f, NAME_BASE, G.NAMELEN, 32)
    write_string_field(f, info.author or "", 32)
    write_string_field(f, info.desc or "", 64)
    f:write(pack_double(os.time()))

    -- Per-pad metadata
    for pad = 0, G.NUM_PADS - 1 do
      local base = G.META_BASE + pad * G.META_PP
      for j = 0, G.META_PP - 1 do
        f:write(pack_double(reaper.gmem_read(base + j)))
      end
    end

    -- Per-pad names
    for pad = 0, G.NUM_PADS - 1 do
      local base = G.PADNAME_BASE + pad * G.PADNAME_LEN
      for j = 0, G.PADNAME_LEN - 1 do
        f:write(pack_double(reaper.gmem_read(base + j)))
      end
    end

    -- Audio as 16-bit PCM
    for pad = 0, G.NUM_PADS - 1 do
      local alen = math.floor(reaper.gmem_read(G.AUDIOLEN_BASE + pad))
      local pad_sr = reaper.gmem_read(G.META_BASE + pad * G.META_PP + 37)
      local audio_off = 0
      for p = 0, pad - 1 do
        audio_off = audio_off + math.floor(reaper.gmem_read(G.AUDIOLEN_BASE + p))
      end
      if audio_off + alen > GMEM_AUDIO_MAX then
        alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
      end
      f:write(pack_double(alen))
      f:write(pack_double(pad_sr))
      for j = 0, alen - 1 do
        f:write(pack_s16(reaper.gmem_read(G.AUDIO_BASE + audio_off + j)))
      end
      total_saved = total_saved + alen
    end
  end)

  f:close()

  if not write_ok then
    -- Disk-full / permission-denied / etc. Remove the partial file and
    -- surface the error rather than leaving corrupted output.
    os.remove(info.filepath)
    eon_notice(
      "Could not write kit (disk full?):\n" .. info.filepath ..
      "\n\nDetails: " .. tostring(write_err))
    reaper.gmem_write(G.CMD, 98)
    pending_export = nil
    return
  end

  local fcheck = io.open(info.filepath, "rb")
  local fsize = 0
  if fcheck then fsize = fcheck:seek("end"); fcheck:close() end

  -- Register saved file as kit source for sidecar system
  register_kit_source_after_save(info.filepath)

  reaper.gmem_write(G.CMD, 99)
  -- Signal browser to refresh kit list
  reaper.SetExtState("Swing", "kit_saved", "1", false)
  eon_notice(
    'Kit saved!\n\n' ..
    'Name: ' .. info.kit_name .. '\n' ..
    (info.author ~= "" and ('Author: ' .. info.author .. '\n') or '') ..
    'Samples: ' .. total_saved .. '\n' ..
    'Size: ' .. core.format_size(fsize) .. '\n' ..
    'Location: ' .. info.filepath)
  update_folder_track_name(find_swing_track())
  pending_export = nil
end

-- ═════════════════════════════════════════════════════════════════════════════
-- KIT IMPORT (CMD 2, 16)
-- ═════════════════════════════════════════════════════════════════════════════

-- Phase 2 (2026-07-17): the FILENAME is the canonical kit name. The browser
-- lists filenames but the loaders used to stage the file's INTERNAL manifest
-- name — when the two diverged (renamed file, hand-copy, save-dialog
-- sanitization) the user picked one name and the header showed another
-- ("kit loaded under the wrong name" with no load bug at all). Every loader
-- now stages the basename; the manifest name is demoted to descriptive
-- metadata (divergence is silent — every re-baked _v2 factory kit diverges,
-- so a console note here fired on every factory load). GLOBAL (bridge chunk
-- is at Lua's 200-local ceiling).
function eon_kit_display_name(filepath, manifest_name)
  local base = (filepath or ""):match("([^/\\]+)%.[sS][wW][iI][nN][gG]$")
            or (filepath or ""):match("([^/\\]+)$")
  -- ...EXCEPT for the token filenames the system generates for itself. A project
  -- sidecar is named for the instance GUID (swing_<32 hex>, or
  -- swing_<32 hex>_undo for an undo dump) — that is an identifier, not a name
  -- anybody chose, and filename-wins turns a reopened project's kit into
  -- "swing_6786EAE03CC94493B33AC22AC27F611C". The kit's real name is in the
  -- manifest, which is exactly why the writer already refuses to let these
  -- tokens become names on the way out; the loader has to agree on the way in.
  if base and base:match("^swing_%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x")
     and manifest_name and manifest_name ~= "" then
    return manifest_name
  end
  if base and base ~= "" then
    -- Divergence is NORMAL and silent (user 2026-08-11): every re-baked _v2
    -- factory kit carries its original internal name, so the old console
    -- note here fired (and popped the console window) on every factory kit
    -- load. Filename wins; the internal name is descriptive metadata only.
    return base
  end
  return (manifest_name and manifest_name ~= "") and manifest_name or "Kit"
end

local function load_swing_file(filepath, internal)
  local f = io.open(filepath, "rb")
  if not f then
    eon_notice("Could not open: " .. filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end
  local content = f:read("*a")
  f:close()

  if #content < 24 then
    eon_notice("File too small to be a valid .swing kit.")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local pos = 1
  local magic
  magic, pos = unpack_double(content, pos)
  if math.floor(magic) ~= MAGIC then
    eon_notice("Invalid .swing file (bad magic).")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local file_ver
  file_ver, pos = unpack_double(content, pos)
  file_ver = math.floor(file_ver)

  local file_npads
  file_npads, pos = unpack_double(content, pos)
  file_npads = math.min(math.floor(file_npads), G.NUM_PADS)

  reaper.gmem_write(G.KIT_GMEM_VER, file_ver)
  reaper.gmem_write(G.KIT_GMEM_NPADS, file_npads)

  -- Kit name: consume the file's name field from the stream, then stage the
  -- FILENAME over it (Phase 2 — filename is canonical; see
  -- eon_kit_display_name above; the legacy binary name is not surfaced).
  pos = read_string_to_gmem(content, pos, NAME_BASE, G.NAMELEN, 32)
  if not internal then
    core.gmem_write_string(eon_kit_display_name(filepath, nil), NAME_BASE, G.NAMELEN, 32)
  end

  -- v21+ fields
  if file_ver >= 21 then
    local _
    _, pos = read_string_field(content, pos, 32)  -- author (file-only)
    _, pos = read_string_field(content, pos, 64)  -- desc (file-only)
    _, pos = unpack_double(content, pos)           -- timestamp
  end

  -- Per-pad metadata
  for pad = 0, file_npads - 1 do
    local base = G.META_BASE + pad * G.META_PP
    for j = 0, G.META_PP - 1 do
      local val
      val, pos = unpack_double(content, pos)
      reaper.gmem_write(base + j, val)
    end
  end

  -- Per-pad names
  -- v21 files stored 16 chars per pad; v22+ stores 32 (PADNAME_LEN).
  -- Read the correct count from the file, zero-fill the rest.
  local file_padname_len = file_ver >= 22 and G.PADNAME_LEN or 16
  for pad = 0, file_npads - 1 do
    local base = G.PADNAME_BASE + pad * G.PADNAME_LEN
    -- Clear the full 32-char slot so old 16-char names don't leave junk
    for j = 0, G.PADNAME_LEN - 1 do
      reaper.gmem_write(base + j, 0)
    end
    -- Read only what the file actually stored
    for j = 0, file_padname_len - 1 do
      local val
      val, pos = unpack_double(content, pos)
      reaper.gmem_write(base + j, val)
    end
  end

  -- Audio
  local audio_offset = 0
  for pad = 0, file_npads - 1 do
    local alen
    alen, pos = unpack_double(content, pos)
    alen = math.floor(alen)
    -- Reject NaN/negative up front (positive-form guard: NaN fails >= too).
    if not (alen >= 0) then alen = 0 end
    -- Clamp a crafted/corrupt length to the gmem audio ceiling so a lying
    -- length field can't drive a multi-billion-iteration write loop. Every
    -- other loader clamps to GMEM_AUDIO_MAX; this legacy binary path was the
    -- one that never did. The per-branch `avail` clamp below then bounds it to
    -- the samples actually left in the file (stops reads walking past EOF).
    if audio_offset + alen > GMEM_AUDIO_MAX then
      alen = math.max(0, GMEM_AUDIO_MAX - audio_offset)
    end

    if file_ver >= 21 then
      local _sr
      _sr, pos = unpack_double(content, pos)
      local avail = math.floor((#content - pos + 1) / 2)  -- int16 samples left
      if alen > avail then alen = math.max(0, avail) end
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, alen)
      for j = 0, alen - 1 do
        local sample
        sample, pos = unpack_s16(content, pos)
        reaper.gmem_write(G.AUDIO_BASE + audio_offset + j, sample)
      end
    else
      local avail = math.floor((#content - pos + 1) / 8)  -- float64 samples left
      if alen > avail then alen = math.max(0, avail) end
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, alen)
      for j = 0, alen - 1 do
        local val
        val, pos = unpack_double(content, pos)
        reaper.gmem_write(G.AUDIO_BASE + audio_offset + j, val)
      end
    end
    audio_offset = audio_offset + alen
  end

  -- Clear remaining pads
  for pad = file_npads, G.NUM_PADS - 1 do
    local base = G.META_BASE + pad * G.META_PP
    for j = 0, G.META_PP - 1 do reaper.gmem_write(base + j, 0) end
    reaper.gmem_write(G.AUDIOLEN_BASE + pad, 0)
  end

  reaper.gmem_write(G.CMD, 3)  -- data ready
  update_folder_track_name(find_swing_track())
end

local function load_kit_v2(filepath, internal)
  -- Load and evaluate the Lua table in a sandboxed environment
  -- (prevents malicious kit files from accessing globals / io / os)
  local chunk, err = loadfile(filepath, "t", {})
  if not chunk then
    eon_notice("Invalid v2 kit file:\n" .. (err or ""))
    reaper.gmem_write(G.CMD, 98)
    return
  end
  local ok, kit = pcall(chunk)
  if not ok or type(kit) ~= "table" then
    eon_notice("Invalid v2 kit data:\n" .. tostring(kit))
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- Write kit name
  local kit_name = internal and (kit.kit_name or "Kit")
                or eon_kit_display_name(filepath, kit.kit_name)  -- Phase 2: filename canonical
  core.gmem_write_string(kit_name, NAME_BASE, G.NAMELEN, 32)

  -- Write globals
  if kit.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = KIT_GLOBAL_DEFAULTS[key] or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, kit.globals[key] or default)
    end
  end

  -- Write per-pad metadata + paths
  local pads = kit.pads or {}
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = G.META_BASE + pad * G.META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(G.GS_PAD_SMASH_BASE + pad, p.fx_snd_smash or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)
    reaper.gmem_write(base + 32, p.layer_cnt or 0)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)

    -- Sample offset (separate gmem region)
    reaper.gmem_write(G.GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)
    reaper.gmem_write(G.GS_PAD_RANGE_BASE + pad, (p.rng_lo or 0) * 128 + (p.rng_hi or 0))
    eon_padcat_from_load(pad, p.category, p.name, p.path)   -- categories §1: p.category or classify(name), full-path rescue

    -- Clear layer data in metadata (layers not supported in v2 yet)
    for lj = 0, 3 do
      for li = 0, 9 do
        reaper.gmem_write(base + 40 + lj * 10 + li, 0)
      end
    end

    -- Write pad name
    local name = p.name or ""
    local name_base = G.PADNAME_BASE + pad * G.PADNAME_LEN
    for i = 0, G.PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Write file path to gmem audio area (for JSFX to load)
    local path = p.path or ""
    local pbase = G.AUDIO_BASE + pad * 260
    reaper.gmem_write(pbase, #path)  -- length prefix
    for i = 0, math.min(#path, 258) - 1 do
      reaper.gmem_write(pbase + 1 + i, path:byte(i + 1))
    end
    reaper.gmem_write(pbase + 1 + math.min(#path, 258), 0)  -- null term

    -- Store path in ExtState for future re-saves
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
    publish_pitch_path(pad, path)
  end
  G.SYN.stage_kit(pads)   -- SYN slot: stage + raise adopt flag (no-op for pre-synth kits)

  reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)  -- NPADS
  reaper.gmem_write(G.KIT_GMEM_VER, 200)       -- VER = 200 (v2 marker)
  reaper.gmem_write(G.CMD, 3)       -- data ready
  update_folder_track_name(find_swing_track())
end

-- ─────────────────────────────────────────────────────────────────────────────
-- v4 HYBRID LOAD — Lua text section + per-pad main + per-layer baked PCM.
-- Round-trips velocity-layered, RR, and Sum kits.
-- ─────────────────────────────────────────────────────────────────────────────
local function load_kit_v4(filepath, internal)
  local f = io.open(filepath, "rb")
  if not f then
    eon_notice("Could not open: " .. filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end
  local content = f:read("*a")
  f:close()

  if #content < 16 then
    eon_notice("Kit file too small to be v4.")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  if content:sub(1, 8) ~= "SWINGv04" then
    eon_notice("Invalid v4 magic in " .. filepath)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local lua_len = math.floor(string.unpack("<d", content, 9))
  -- Positive-form guard (same as the scanner's): NaN fails EVERY comparison,
  -- so require the good case instead of testing for the bad ones -- the
  -- negative form let a NaN lua_len through to :sub() as an uncaught error.
  if not (lua_len > 0 and 16 + lua_len <= #content) then
    eon_notice("Corrupt v4 header (bad lua_len).")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local lua_text = content:sub(17, 16 + lua_len)
  local chunk, err = load(lua_text, "swing_v4_kit", "t", {})
  if not chunk then
    eon_notice("Invalid v4 Lua section:\n" .. (err or ""))
    reaper.gmem_write(G.CMD, 98)
    return
  end
  local ok, kit = pcall(chunk)
  if not ok or type(kit) ~= "table" then
    eon_notice("Invalid v4 kit data:\n" .. tostring(kit))
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- VER-201 path-based load (disk-based kit plan, Phase 2 — DEFAULT ON, kill
  -- switch ExtState EON_Bridge/pathload=0). Route cascade:
  --   pl: every pad's ORIGINAL source file exists on disk → stage those paths
  --       (zero copies; pads keep sample-library provenance).
  --   px: otherwise EXTRACT the kit's baked audio to WAVs in the project
  --       sample store (idempotent, shared across instances) and stage those.
  --   v26 gmem stream / packed VER-24: fallbacks for extraction failure or a
  --       stale (pre-201) JSFX build.
  -- Either path-route means NO audio crosses gmem and the load is layer-aware.
  local caps201 = reaper.GetExtState("EON_Bridge", "pathload") ~= "0"
                  and math.floor(reaper.gmem_read(G.HS_CAP) or 0) >= 201
  local pl = caps201 and eon_kit_paths_resolvable(kit)
  local px = caps201 and not pl

  -- Kit name
  local kit_name = internal and (kit.kit_name or "Kit")
                or eon_kit_display_name(filepath, kit.kit_name)  -- Phase 2: filename canonical
  core.gmem_write_string(kit_name, NAME_BASE, G.NAMELEN, 32)

  -- Globals
  if kit.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = KIT_GLOBAL_DEFAULTS[key] or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, kit.globals[key] or default)
    end
  end

  -- ── Per-pad metadata + per-layer metadata ──────────────────────────────
  local pads = kit.pads or {}
  local pad_layer_cnts = {}   -- remember lc per pad for the binary read below
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = G.META_BASE + pad * G.META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(G.GS_PAD_SMASH_BASE + pad, p.fx_snd_smash or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)

    -- v4 honours layer_cnt (unlike v3 which forced it to 0). The binary
    -- audio section below carries per-layer data when layer_cnt > 0.
    local lc = math.floor(p.layer_cnt or 0)
    if lc < 0 then lc = 0 end
    if lc > G.MAX_LAYERS then lc = G.MAX_LAYERS end
    pad_layer_cnts[pad] = lc

    reaper.gmem_write(base + 32, lc)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)
    reaper.gmem_write(G.GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)
    reaper.gmem_write(G.GS_PAD_RANGE_BASE + pad, (p.rng_lo or 0) * 128 + (p.rng_hi or 0))
    eon_padcat_from_load(pad, p.category, p.name, p.path)   -- categories §1: p.category or classify(name), full-path rescue

    -- Per-layer metadata (10 doubles per layer, stride 10 = v24+ layout).
    -- We must zero ALL MAX_LAYERS slots first because the JSFX iterates
    -- every layer slot (line 378 of rk_swing_ui_state.jsfx-inc) regardless
    -- of layer_cnt — stale data from a prior kit would corrupt playback.
    for lj = 0, G.MAX_LAYERS - 1 do
      local lo = base + 40 + lj * 10
      for li = 0, 9 do
        reaper.gmem_write(lo + li, 0)
      end
    end

    local layers = p.layers or {}
    for layer = 0, lc - 1 do
      local L  = layers[layer + 1] or {}
      local lo = base + 40 + layer * 10
      reaper.gmem_write(lo + 0, L.len or 0)
      reaper.gmem_write(lo + 1, L.start or 0)
      reaper.gmem_write(lo + 2, L["end"] or 1.0)
      reaper.gmem_write(lo + 3, L.sr or 0)
      reaper.gmem_write(lo + 4, L.norm or 0)
      reaper.gmem_write(lo + 5, L.norm_gain or 1.0)
      reaper.gmem_write(lo + 6, L.vel_lo or 0)
      reaper.gmem_write(lo + 7, L.vel_hi or 127)
      reaper.gmem_write(lo + 8, L.rr_order or layer)
      reaper.gmem_write(lo + 9, L.gain or 1.0)
    end

    -- Pad name
    local name = p.name or ""
    local name_base = G.PADNAME_BASE + pad * G.PADNAME_LEN
    for i = 0, G.PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Breadcrumb path in ExtState (audio is baked, but useful for the user
    -- to remember where the source came from).
    local path = p.path or ""
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
    publish_pitch_path(pad, path)
  end
  G.SYN.stage_kit(pads)   -- SYN slot: stage + raise adopt flag (no-op for pre-synth kits)

  -- ── Binary audio section (TAGGED UNION per pad) ────────────────────────
  -- Per pad:
  --   [num_layers:8B]
  --   If num_layers == 0:  [s_len:8B][s_sr:8B][PCM × s_len]
  --   If num_layers >  0:  per layer: [l_len:8B][l_sr:8B][PCM × l_len]
  --
  -- Audio writes go contiguously to AUDIO_BASE in (pad,blob) order. The
  -- JSFX's kit_import_state==3 copy loop consumes either s_len[pad] or
  -- sum(l_len[pad,*]) per pad — see rk_swing_ui_state.jsfx-inc lines 515-565.
  -- For the layered branch the JSFX iterates ALL MAX_LAYERS slots, but
  -- l_len=0 (zeroed above) means 0 bytes consumed for unused layers, so
  -- audio stays aligned.
  if pl then
    -- ── VER-201: stage per-pad + per-layer PATHS; skip the audio walk entirely.
    -- Meta (incl. per-layer vel/RR/gain, zeroed unused slots) is already staged
    -- by the loop above; publish_pitch_path was called there per pad. AUDIOLEN
    -- carries the kit's expected lengths for progress/completeness display —
    -- the loaded truth comes from the files.
    local layer_path_base = G.AUDIO_BASE + G.NUM_PADS * 260
    for pad = 0, G.NUM_PADS - 1 do
      local p = pads[pad + 1] or {}
      local lc = pad_layer_cnts[pad]
      local layers = p.layers or {}
      -- Stage a path ONLY when the pad/layer actually CARRIES AUDIO in this
      -- kit (2026-07-18 catch, kitpipe_diagover): pre-scrub kit files record
      -- "informational" source paths on audio-less pads (dead OneDrive paths
      -- from the pre-move library era). eon_kit_paths_resolvable never vets
      -- those pads — staging them sent the JSFX 13 doomed disk loads per
      -- kit: real fail bits, relink banners, retry churn, and OneDrive
      -- placeholder hydration making it nondeterministic run-to-run (the
      -- user's "older kits misbehave, newer don't" — old kits = OneDrive
      -- paths). An audio-less pad stages "" → the JSFX runs clear_pad, which
      -- is kit truth.
      eon_write_gmem_path(G.AUDIO_BASE + pad * 260,
        (lc == 0 and (p.s_len or 0) > 0) and (p.path or "") or "")
      local exp = (lc == 0) and (p.s_len or 0) or 0
      for layer = 0, G.MAX_LAYERS - 1 do
        local L = (layer < lc) and layers[layer + 1] or nil
        if L then exp = exp + (L.len or 0) end
        eon_write_gmem_path(layer_path_base + (pad * G.MAX_LAYERS + layer) * 260,
                            (L and (L.len or 0) > 0 and L.path) or "")
      end
      if lc > 0 then
        -- Mirror the audio walk's layered-pad fixup (this route skips the
        -- walk): s_len has no role in layered playback — zero the staged
        -- META value so the JSFX doesn't carry a stale pad-main length.
        reaper.gmem_write(G.META_BASE + pad * G.META_PP + 34, 0)
      end
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, exp)
    end
    reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)  -- NPADS
    reaper.gmem_write(G.KIT_GMEM_VER, 201)       -- VER = 201: per-layer path import
    reaper.gmem_write(G.CMD, 3)
    -- This route skips the audio walk, so the tail has to be located by the
    -- header-only walk instead. Without this the cover is never read, the tile
    -- falls back to the generated portrait, and the NEXT save writes the file
    -- without a tail — silently destroying the artwork.
    eon_kit_absorb_tail(content, eon_kit_tail_offset(content, lua_len), filepath)
    eon_load_route_report("pl/original-paths", kit_name)
    update_folder_track_name(find_swing_track())
    return
  end

  local pos = 17 + lua_len
  local audio_off = 0

  -- VER-26 per-pad streaming (Spec_Swing_PerPad_Sidecar_Load): instead of the
  -- packed all-pads write to AUDIO_BASE (whose cumulative offset both exceeds
  -- the named segment's real 32M ceiling on large kits AND drifts every later
  -- pad on any length skew), collect the blobs here and stream them one at a
  -- time through a fixed 4M window with a generation-stamp handshake (pump =
  -- eon_pp_pump, armed at the bottom of this function). Requires a v26-aware
  -- JSFX build (KIT_HS_CAP advertisement) — otherwise fall back to the packed
  -- VER-24 path. Opt out via ExtState EON_Bridge/perpad_load = "0".
  -- Capture mode: needed by the px extraction AND by the v26 stream (px falls
  -- back to the v26 stream on disk trouble — same captured blobs, no re-parse).
  local pp = px or (reaper.GetExtState("EON_Bridge", "perpad_load") ~= "0"
             and math.floor(reaper.gmem_read(G.HS_CAP) or 0) >= 26)
  local pp_blobs = pp and {} or nil

  local function read_blob()
    -- Read [len:8B][sr:8B][PCM×len] from content at pos. Packed mode: writes
    -- audio to gmem at AUDIO_BASE+audio_off. Per-pad mode (pp): no gmem write
    -- here — the caller queues the bytes and the pump stages them per blob.
    -- Returns (alen, sr, s16_bytes) — the third is a memcpy snapshot of
    -- the raw 16-bit PCM bytes, used by the Extension temp-WAV publish.
    if pos + 16 > #content then return 0, 0, "" end
    local alen = math.floor(string.unpack("<d", content, pos));  pos = pos + 8
    local sr   = string.unpack("<d", content, pos);               pos = pos + 8
    -- Positive-form guards (NaN fails every comparison): a NaN/negative
    -- length is an empty blob, a wild sample rate becomes 0 = "unknown".
    if not (sr >= 0 and sr < 1e7) then sr = 0 end
    if not (alen > 0) then return 0, sr, "" end
    if pos + alen * 2 - 1 > #content then
      pos = pos + alen * 2
      return 0, sr, ""
    end

    local file_alen = alen
    if not pp and audio_off + alen > GMEM_AUDIO_MAX then
      alen = math.max(0, GMEM_AUDIO_MAX - audio_off)
    end
    local s16_bytes = content:sub(pos, pos + alen * 2 - 1)
    if pp then
      pos = pos + alen * 2  -- samples are decoded at publish time (spread across ticks)
    else
      for j = 0, alen - 1 do
        local sample
        sample, pos = unpack_s16(content, pos)
        reaper.gmem_write(G.AUDIO_BASE + audio_off + j, sample)
      end
    end
    if file_alen > alen then
      pos = pos + (file_alen - alen) * 2
    end
    audio_off = audio_off + alen
    return alen, sr, s16_bytes
  end

  for pad = 0, G.NUM_PADS - 1 do
    -- 1. Layer count (from binary — source of truth)
    local lc_bin = 0
    if pos + 8 <= #content then
      lc_bin = math.floor(string.unpack("<d", content, pos))
      pos = pos + 8
      if not (lc_bin > 0) then lc_bin = 0 end   -- NaN/negative land on 0 too
      if lc_bin > G.MAX_LAYERS then lc_bin = G.MAX_LAYERS end
    end

    -- Reconcile with Lua section if they disagree (binary wins)
    if lc_bin ~= pad_layer_cnts[pad] then
      pad_layer_cnts[pad] = lc_bin
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 32, lc_bin)
    end

    if lc_bin > 0 then
      -- 2a. Layered: read lc_bin layer blobs. Audio length the JSFX will
      -- consume for this pad = sum of l_len values just unpacked.
      local total_alen = 0
      local first_sr, first_bytes = 0, ""
      for layer = 0, lc_bin - 1 do
        local l_alen, l_sr, l_bytes = read_blob()
        local lo = G.META_BASE + pad * G.META_PP + 40 + layer * 10
        reaper.gmem_write(lo + 0, l_alen)   -- override l_len from binary truth
        reaper.gmem_write(lo + 3, l_sr)     -- override l_sr from binary truth
        total_alen = total_alen + l_alen
        if layer == 0 then
          first_sr, first_bytes = l_sr, l_bytes
        end
        if pp then
          pp_blobs[#pp_blobs + 1] = { pad = pad, layer = layer, len = l_alen,
                                      sr = l_sr, bytes = l_bytes, first = (layer == 0) }
        end
      end
      -- AUDIOLEN drives the JSFX progress counter (line 442) — it sums
      -- per-pad totals to compute kit_total_audio. For layered pads we
      -- report the sum of all layer sizes.
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, total_alen)
      -- s_len has no role in the layered playback path — zero it so UI
      -- doesn't show a stale waveform from before this load.
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 34, 0)
      -- Bake the FIRST layer for now — per-layer bake is a follow-up.
      publish_pitch_path_from_s16_bytes(pad, 2, first_sr, first_bytes)
    else
      -- 2b. Non-layered: read single pad-main blob (mirrors v3).
      local s_alen, s_sr, s_bytes = read_blob()
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, s_alen)
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 34, s_alen)  -- s_len
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 37, s_sr)    -- s_sr
      publish_pitch_path_from_s16_bytes(pad, 2, s_sr, s_bytes)
      if pp then
        -- Queue even zero-length blobs: the pad's first blob carries the
        -- memset flag, so a pad that is EMPTY in the new kit gets cleared
        -- (same semantics as the packed path's global wipe).
        pp_blobs[#pp_blobs + 1] = { pad = pad, layer = 0, len = s_alen,
                                    sr = s_sr, bytes = s_bytes, first = true }
      end
    end
  end

  -- ── Tail records ──
  -- `pos` is now just past the last pad blob, so it IS the tail offset — no
  -- header-only walk needed on this route. Older kits simply have nothing here
  -- and eon_kit_tail_read returns an empty table.
  eon_kit_absorb_tail(content, pos, filepath)

  if px then
    -- ── VER-201 via the project sample store: extract blobs to WAVs (or
    -- reuse an existing extraction) and stage their paths. On any disk
    -- trouble fall through to the v26 stream — the same captured blobs.
    if eon_stage_kit_store_paths(filepath, pad_layer_cnts, pp_blobs) then
      reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)  -- NPADS
      reaper.gmem_write(G.KIT_GMEM_VER, 201)       -- VER = 201: per-layer path import
      reaper.gmem_write(G.CMD, 3)
      eon_load_route_report("px/store-extract", kit_name)
      update_folder_track_name(find_swing_track())
      return
    end
    reaper.ShowConsoleMsg("[Swing] store extraction failed -> falling back to v26 stream\n")
  end

  if pp then
    -- VER-26: meta is fully staged; audio streams pad-by-pad via eon_pp_pump.
    -- The kit-done sentinel moves the JSFX to state 4 (finalize/recalc).
    pp_blobs[#pp_blobs + 1] = { done = true }
    reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)  -- NPADS
    reaper.gmem_write(G.KIT_GMEM_VER, 26)        -- VER = 26: per-pad handshake protocol
    reaper.gmem_write(G.CMD, 3)       -- meta ready; audio follows blob-by-blob
    eon_pp_stream = { blobs = pp_blobs, idx = 0, t0 = os.clock() }
    -- (The report's console line is gated behind EON_Swing/load_debug inside
    -- eon_load_report — the "gate before release" this comment used to demand.
    -- The per-blob pad:layer:len table that was once built here was never
    -- consumed and is gone.)
    eon_load_report(("route=v26/gmem-stream blobs=%d: %s"):format(#pp_blobs - 1, kit_name))
    eon_pp_publish_next()           -- stage the first blob this same tick
  else
    -- Tell the JSFX this is binary-audio ready. v24 marker triggers the v1
    -- binary copy path which handles BOTH layered (p_layer_cnt > 0) and
    -- non-layered (p_layer_cnt == 0) pads in the same loop.
    reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)  -- NPADS
    reaper.gmem_write(G.KIT_GMEM_VER, 24)        -- VER = 24
    reaper.gmem_write(G.CMD, 3)       -- data ready
    eon_load_report("route=packed/v24: " .. (kit_name or "?"))
  end
  update_folder_track_name(find_swing_track())
end

-- ── VER-26 per-pad kit-load stream pump (Spec_Swing_PerPad_Sidecar_Load) ────
-- GLOBALS (main chunk is at the 200-local ceiling). Armed by load_kit_v4 in
-- per-pad mode; eon_pp_pump runs once per defer tick from the main poll:
-- publish one blob into the fixed window at AUDIO_BASE (GEN odd → payload +
-- meta → GEN even LAST), wait for the JSFX echo of that generation, advance.
-- Absolute-time deadlines (Q1 probe: defer ticks stretch to ~140ms under UI
-- stalls) with bounded retries; a skipped blob leaves that pad's OLD audio
-- intact (non-destructive by construction).
function eon_pp_publish_next()
  local st = eon_pp_stream
  if not st then return end
  st.idx = st.idx + 1
  local b = st.blobs[st.idx]
  if not b then eon_pp_stream = nil; return end
  -- Monotonic generation, re-seeded from gmem after a bridge restart so a new
  -- session's generations never collide with a stale echo.
  eon_pp_gen = eon_pp_gen or math.floor(reaper.gmem_read(G.HS_GEN) or 0)
  eon_pp_gen = eon_pp_gen + 1                    -- odd: write in progress
  reaper.gmem_write(G.HS_GEN, eon_pp_gen)
  local len = 0
  if b.done then
    reaper.gmem_write(G.HS_PAD, 0)
    reaper.gmem_write(G.HS_LAYER, 0)
    reaper.gmem_write(G.HS_LEN, 0)
    reaper.gmem_write(G.HS_FLAGS, 2)             -- kit-done sentinel
  else
    len = math.min(b.len or 0, G.SLOT_SIZE)        -- window/resident-slot bound
    local bytes = b.bytes or ""
    local p = 1
    for j = 0, len - 1 do
      local s
      s, p = unpack_s16(bytes, p)
      reaper.gmem_write(G.AUDIO_BASE + j, s)
    end
    reaper.gmem_write(G.HS_PAD, b.pad)
    reaper.gmem_write(G.HS_LAYER, b.layer or 0)
    reaper.gmem_write(G.HS_LEN, len)
    reaper.gmem_write(G.HS_FLAGS, b.first and 1 or 0)
  end
  eon_pp_gen = eon_pp_gen + 1                    -- even: published (LAST write)
  reaper.gmem_write(G.HS_GEN, eon_pp_gen)
  st.cur_gen = eon_pp_gen
  -- Copy allowance: KIT_COPY_CHUNK (200k) per @block. Generous scale (len/1e6:
  -- a full 4M blob gets 4s) so even huge device blocks (4096 ≈ 93ms/block ≈
  -- 1.9s for 4M) never trip a mid-copy republish; a republish is idempotent
  -- but restarts the blob's copy from zero.
  st.deadline = os.clock() + 0.5 + len / 1000000
end

function eon_pp_pump()
  local st = eon_pp_stream
  if not st or not st.cur_gen then
    return
  end
  local echo = math.floor(reaper.gmem_read(G.HS_ECHO) or 0)
  if echo == st.cur_gen then
    if st.blobs[st.idx] and st.blobs[st.idx].done then
      eon_pp_stream = nil        -- stream complete; JSFX is in state 4
    else
      st.retries = 0
      st.skips = 0
      eon_pp_publish_next()
    end
  elseif os.clock() > st.deadline then
    st.retries = (st.retries or 0) + 1
    if st.retries > 3 then
      local b = st.blobs[st.idx] or {}
      reaper.ShowConsoleMsg(("[Swing] per-pad load: pad %s layer %s timed out — skipped (old audio kept)\n")
        :format(tostring(b.pad), tostring(b.layer)))
      st.retries = 0
      st.skips = (st.skips or 0) + 1
      if st.skips >= 3 then
        -- Consumer is gone (audio device closed / stale JSFX build). Stop:
        -- the JSFX-side 10s watchdog finalizes with whatever landed.
        reaper.ShowConsoleMsg("[Swing] per-pad load: 3 consecutive stalls — aborting stream (recompile Swing if this repeats)\n")
        eon_pp_stream = nil
        return
      end
      eon_pp_publish_next()
    else
      st.idx = st.idx - 1        -- republish the SAME blob under a fresh gen
      eon_pp_publish_next()      -- (recopy is idempotent — same content)
    end
  end
end

-- ── VER-201 path-staging helpers (disk-based kit plan, Phase 1) ─────────────
-- GLOBALS (main chunk is at the 200-local ceiling).
function eon_file_exists(path)
  if not path or path == "" or #path > 258 then return false end
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- CLOUD-PLACEHOLDER SAFETY (2026-07-19 — the live "random blank pads" root
-- cause). io.open ALONE SUCCEEDS on a OneDrive / Dropbox / iCloud on-demand
-- PLACEHOLDER whose bytes are not on disk yet: the file "exists", reports its
-- real size, and opens — but contains nothing until a READ triggers the
-- download. So eon_file_exists said "resolvable", the loader took the
-- pl/original-paths route, and then the JSFX's audio-thread file_open hit an
-- unhydrated placeholder and left the pad BLANK. Whichever samples happened to
-- be dehydrated went silent, a different set each load, and loading twice
-- "fixed" it because attempt #1 kicked off the hydration. (User's 808 kit lives
-- under OneDrive\Desktop; 707/Linn load from the local store cache and were
-- always fine — which is why no rig run ever reproduced it.)
--
-- Detection is a CHEAP PATH TEST, deliberately not a read. Reading a byte does
-- prove hydration — but on a placeholder it BLOCKS the bridge for the whole
-- download (measured: ~11s for one kit's samples), trading blank pads for a
-- frozen UI. Instead: treat any source under a known cloud-sync root as
-- unreliable-for-the-audio-thread and let the kit take the px store-extract
-- route, which writes LOCAL WAVs from the kit's own embedded audio — no
-- download, no stall, always openable. Costs a little disk in the sample store;
-- buys loads that cannot silently lose pads. A hydrated cloud file is routed
-- the same way (harmless: same audio, local copy).
EON_CLOUD_ROOTS = {
  "onedrive", "dropbox", "google drive", "googledrive", "gdrive",
  "icloud", "icloudrive", "icloud drive", "box sync", "boxdrive", "pcloud",
  "creative cloud files", "mega", "sync.com", "nextcloud", "yandexdisk",
}
function eon_path_is_cloud(path)
  if not path or path == "" then return false end
  local low = path:lower()
  for _, root in ipairs(EON_CLOUD_ROOTS) do
    -- match as a PATH SEGMENT so a folder merely named "…mega…" doesn't trip it
    if low:find("[/\\]" .. root:gsub("%p", "%%%0") .. "[/\\]") then return true end
  end
  return false
end

function eon_file_readable(path)
  if not eon_file_exists(path) then return false end
  return not eon_path_is_cloud(path)
end

-- Write one path into a 260-slot gmem string cell ([0]=len, [1..]=chars, NUL).
-- Overlong paths (>258 — unstageable in the 260-slot layout) become empty.
function eon_write_gmem_path(pbase, path)
  path = path or ""
  if #path > 258 then path = "" end
  reaper.gmem_write(pbase, #path)
  for i = 0, #path - 1 do
    reaper.gmem_write(pbase + 1 + i, path:byte(i + 1))
  end
  reaper.gmem_write(pbase + 1 + #path, 0)
end

-- ── Phase 2: project sample store (kit extraction) ──────────────────────────
-- Kit audio is extracted ONCE per kit file into a shared store dir and pads
-- reference those WAVs (VER-201). Extractions depend only on the kit file, so
-- they live under samples/kits/ and are shared across instances; per-GUID dirs
-- are reserved for Phase-3 eager captures (chop etc.).
function eon_store_root()
  -- <projdir>/Swing/samples for saved projects; the persistent unsaved store
  -- otherwise. NOT %TEMP% — that is swept on exit (_eon_sweep_temp_audio) and
  -- OS-cleared, which would delete the only copy of extracted audio.
  local _, projfn = reaper.EnumProjects(-1)
  if projfn and projfn ~= "" then
    local proj_dir = projfn:match("(.*[/\\])")
    if proj_dir then return proj_dir .. "Swing/samples" end
  end
  return reaper.GetResourcePath() .. "/Data/EON_Swing/unsaved"
end

-- Deterministic per-kit extraction dir: readable basename + a cheap content
-- key (path + file size + head bytes) so repeat loads of the same kit reuse
-- the same WAVs (idempotent) and a re-saved kit gets a fresh dir.
function eon_kit_store_dir(filepath)
  local base = filepath:match("([^/\\]+)%.swing$") or filepath:match("([^/\\]+)$") or "kit"
  base = base:gsub("[^%w%-_]", "_"):sub(1, 40)
  local size, head = 0, ""
  local f = io.open(filepath, "rb")
  if f then
    size = f:seek("end") or 0
    f:seek("set", 0)
    head = f:read(4096) or ""
    f:close()
  end
  -- Phase 3: the kit file's MTIME joins the key. path|size|head4k missed
  -- in-place re-saves whose byte length and header region didn't change —
  -- the old extraction dir matched, the size-only per-WAV reuse probe below
  -- accepted the stale WAVs, and the "new" kit played the PREVIOUS audio.
  -- JS_File_Stat when available (js_ReaScriptAPI is already a hard dep of
  -- the save dialogs); without it the legacy key applies (stale-reuse risk
  -- returns, logged once per session would be noise — accepted).
  local mtime = ""
  if reaper.JS_File_Stat then
    -- returns: retval, size, accessedTime, modifiedTime, ...
    local rv, _, _, mt = reaper.JS_File_Stat(filepath)
    if rv == 0 and mt then mtime = tostring(mt) end
  end
  local h = 5381
  local key = filepath .. "|" .. tostring(size) .. "|" .. mtime .. "|" .. head
  for i = 1, #key do h = (h * 33 + key:byte(i)) % 4294967296 end
  return string.format("%s/kits/kit_%s_%08x", eon_store_root(), base, h)
end

-- Route observability (2026-07-19, live silent-empty-pads hunt): ONE console
-- line per kit load naming the ROUTE the cascade chose and how many pads
-- actually have a staged path — counted from the staged cells themselves,
-- not from intent. A load that comes up short in the live session now says
-- WHICH route starved it and by how much, closing the silent gap between
-- "staged empty = kit truth" and "staging lost pads". GLOBAL (local budget).
function eon_load_route_report(route, kit_name)
  local layer_base = G.AUDIO_BASE + G.NUM_PADS * 260
  local staged = 0
  for pad = 0, G.NUM_PADS - 1 do
    local has = math.floor(reaper.gmem_read(G.AUDIO_BASE + pad * 260) or 0) > 0
    if not has then
      for layer = 0, G.MAX_LAYERS - 1 do
        if math.floor(reaper.gmem_read(layer_base + (pad * G.MAX_LAYERS + layer) * 260) or 0) > 0 then
          has = true
          break
        end
      end
    end
    if has then staged = staged + 1 end
  end
  eon_load_report(("route=%s staged=%d/%d path-pads: %s")
    :format(route, staged, G.NUM_PADS, kit_name or "?"))
end

-- Extract kit blobs to store WAVs (idempotent: skip when the WAV already has
-- the exact expected size = 44-byte header + len*2 s16 bytes) and stage their
-- paths for a VER-201 load. Returns false on any disk trouble → the caller
-- falls back to the v26 stream (blobs are already captured).
function eon_stage_kit_store_paths(filepath, pad_layer_cnts, blobs)
  local dir = eon_kit_store_dir(filepath)
  reaper.RecursiveCreateDirectory(dir, 0)
  -- P5: refresh the age stamp on every load so a reused unsaved-store kit
  -- never ages out (harmless in a saved-project store — the age sweep only
  -- ever reads stamps under the unsaved root).
  _eon_store_stamp_write(dir)
  local layer_path_base = G.AUDIO_BASE + G.NUM_PADS * 260
  for pad = 0, G.NUM_PADS - 1 do
    eon_write_gmem_path(G.AUDIO_BASE + pad * 260, "")
    for layer = 0, G.MAX_LAYERS - 1 do
      eon_write_gmem_path(layer_path_base + (pad * G.MAX_LAYERS + layer) * 260, "")
    end
  end
  local wrote, reused = 0, 0
  for i = 1, #blobs do
    local b = blobs[i]
    if not b.done and (b.len or 0) > 0 and b.bytes and #b.bytes > 0 then
      local wav = string.format("%s/pad%02d_lay%d.wav", dir, b.pad, b.layer or 0)
      if #wav > 258 then return false end   -- unstageable in the 260-slot cells
      local want = 44 + #b.bytes
      local ex = io.open(wav, "rb")
      local have = ex and ex:seek("end") or -1
      if ex then ex:close() end
      if have == want then
        reused = reused + 1
      else
        if not _eon_write_wav_s16_bytes(wav, 2, (b.sr and b.sr > 0) and b.sr or 44100, b.bytes) then
          return false
        end
        wrote = wrote + 1
      end
      if (pad_layer_cnts[b.pad] or 0) > 0 then
        eon_write_gmem_path(layer_path_base + (b.pad * G.MAX_LAYERS + (b.layer or 0)) * 260, wav)
      else
        eon_write_gmem_path(G.AUDIO_BASE + b.pad * 260, wav)
      end
    end
  end
  return true
end

-- True when EVERY pad that carries audio in this kit has a source file that is
-- READABLE on disk (per layer for layered pads). One missing/unreadable file →
-- the whole load falls back to the audio-carrying route (no partial path loads).
-- Uses eon_file_readable, NOT eon_file_exists: a cloud on-demand placeholder
-- opens fine but has no bytes until hydrated, and the audio thread cannot wait
-- for a download — see the eon_file_readable header for the full failure story.
function eon_kit_paths_resolvable(kit)
  local pads = (kit and kit.pads) or {}
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local lc = math.floor(p.layer_cnt or 0)
    if lc > G.MAX_LAYERS then lc = G.MAX_LAYERS end
    if lc > 0 then
      local layers = p.layers or {}
      for layer = 0, lc - 1 do
        local L = layers[layer + 1] or {}
        if (L.len or 0) > 0 and not eon_file_readable(L.path) then return false end
      end
    elseif (p.s_len or 0) > 0 then
      if not eon_file_readable(p.path) then return false end
    end
  end
  return true
end

-- ── P3 eager capture: deferred Chop-to-Pads pump ─────────────────────────
-- Armed by rk_ops.do_chop_to_pads (HS_CAP >= 201 path). One slice WAV per
-- poll tick (≤16 ticks), then a final tick that stages a VER-201 path load —
-- chop becomes "just another kit load" and its audio has a disk source from
-- birth. Module-GLOBALS (bridge main chunk is at Lua's 200-local ceiling).
-- State: { mono, pts, sr, base (fs-safe), kit_base (display), dir, gen,
--          i, wavs = { [pad] = {path, ilen} }, inst_id, unsaved }
eon_chop_state = nil

function eon_chop_pump()
  local st = eon_chop_state
  if not st then return end
  local n_slices = math.min(#st.pts - 1, G.NUM_PADS)

  if st.i <= n_slices then
    -- ── one slice per tick: mono s16 WAV, batched string.pack ──
    local pad = st.i - 1
    local s0, s1 = st.pts[st.i], st.pts[st.i + 1]
    -- keep the historical audible cap (mono frames per pad slot)
    local slice_len = math.min(s1 - s0, math.floor(G.SLOT_SIZE / 2))
    if slice_len > 0 then
      -- STEREO (mono duplicated to L+R): byte-identical format to the kit
      -- store WAVs. (2026-07-12: the JSFX mono loader was later EXONERATED —
      -- the probe failure that motivated stereo was the layer-count-mirror
      -- session bug, not mono handling. Stereo kept anyway: uniform with the
      -- kit store, and chop sources are mono-summed regardless.)
      local pieces, j = {}, 0
      while j < slice_len do
        local n = math.min(2048, slice_len - j)
        local vals = {}
        for k = 1, n do
          local v = st.mono[s0 + j + k - 1] or 0
          if v > 1 then v = 1 elseif v < -1 then v = -1 end
          local q = math.floor(v * 32767 + 0.5)
          vals[k * 2 - 1] = q
          vals[k * 2]     = q
        end
        pieces[#pieces + 1] = string.pack("<" .. ("i2"):rep(n * 2), table.unpack(vals))
        j = j + n
      end
      local wav = ("%s/pad%02d_g%d_%s.wav"):format(st.dir, pad, st.gen, st.base)
      if _eon_write_wav_s16_bytes(wav, 2, st.sr, table.concat(pieces)) then
        st.wavs[pad] = { path = wav, ilen = slice_len * 2 }
      else
        reaper.ShowConsoleMsg("[Swing] chop: WAV write failed, aborting: " .. wav .. "\n")
        eon_chop_state = nil
        reaper.gmem_write(G.CMD, 98)
        return
      end
    end
    st.i = st.i + 1
    return
  end

  -- ── verify phase: audio actually landed? (transient file-open heal) ──
  -- Windows can transiently fail an open on a just-written file (AV/indexer
  -- holds); the JSFX loader has no retry, so a failed open = silent blank
  -- pad (names land via META re-apply, audio doesn't — observed ~2-in-5 in
  -- live probes). Re-dispatch up to 2x; path cells persist, so a re-post of
  -- PENDING+CMD+REQ is a full retry. Verify only when the name mirror is
  -- publishing for OUR instance (INSTANCE == target), else trust-and-finish.
  if st.phase == "verify" then
    local now2 = reaper.time_precise()
    if now2 < (st.verify_at or 0) then return end
    if math.floor(reaper.gmem_read(G.INSTANCE) or 0) ~= (st.inst_id or -1) then
      eon_chop_state = nil; return   -- mirror not ours: can't observe, trust
    end
    local missing = 0
    for pad = 0, G.NUM_PADS - 1 do
      if st.wavs[pad] and math.floor(reaper.gmem_read(G.AUDIOLEN_BASE + pad) or 0) <= 1 then
        missing = missing + 1
      end
    end
    if missing == 0 then
      eon_chop_state = nil            -- all landed
    elseif (st.retries or 0) < 2 then
      st.retries = (st.retries or 0) + 1
      reaper.ShowConsoleMsg(("[Swing] chop: %d pad(s) blank after import — retry %d\n")
        :format(missing, st.retries))
      -- st.inst_id is guaranteed nonzero here: the verify phase already
      -- bailed unless INSTANCE == st.inst_id. Never write 0 into PENDING —
      -- under the exclusive arm gate a 0-target stage has no consumer.
      reaper.gmem_write(G.GS_PENDING_LOAD_INST, st.inst_id)
      reaper.gmem_write(G.CMD, 3)
      reaper.gmem_write(G.GS_KIT_LOAD_REQ, 2)   -- stale-JSFX compat arm path
      reaper.gmem_write(G.GS_LOAD_EPOCH,      -- Phase 1b arm signal, LAST
        math.floor(reaper.gmem_read(G.GS_LOAD_EPOCH) or 0) + 1)
      st.verify_at = now2 + 2.5
    else
      reaper.ShowConsoleMsg("[Swing] chop: pads still blank after retries — check disk/AV\n")
      eon_chop_state = nil
    end
    return
  end

  -- ── settle tick: one poll gap between the last WAV close and dispatch ──
  if not st.settled then st.settled = true return end

  -- ── final tick: manifest, stage, dispatch ──
  -- Manifest only for the UNSAVED store (project stores are project-scoped
  -- already): bridge-restart recovery for save-migration + the Phase-5 sweep.
  if st.unsaved then
    local mf = io.open(st.dir .. "/manifest.lua", "w")
    if mf then
      local _, projfn = reaper.EnumProjects(-1)
      mf:write("return {\n  created = ", tostring(st.gen),
               ",\n  proj = ", string.format("%q", projfn or ""), ",\n  files = {\n")
      for pad = 0, G.NUM_PADS - 1 do
        if st.wavs[pad] then mf:write(string.format("    %q,\n", st.wavs[pad].path)) end
      end
      mf:write("  },\n}\n")
      mf:close()
    end
  end

  reaper.Undo_BeginBlock()
  -- Zero ALL pad + layer path cells first (same convention as
  -- eon_stage_kit_store_paths), then stage the used pads. Chop pads are
  -- single-layer: pad cell carries the WAV, layer cells stay empty.
  local layer_base = G.AUDIO_BASE + G.NUM_PADS * 260
  for pad = 0, G.NUM_PADS - 1 do
    eon_write_gmem_path(G.AUDIO_BASE + pad * 260, "")
    for L = 0, G.MAX_LAYERS - 1 do
      eon_write_gmem_path(layer_base + (pad * G.MAX_LAYERS + L) * 260, "")
    end
  end
  local used = 0
  for pad = 0, G.NUM_PADS - 1 do
    local wv = st.wavs[pad]
    if wv then
      eon_write_gmem_path(G.AUDIO_BASE + pad * 260, wv.path)
      write_default_pad_meta(pad, wv.ilen, st.sr, pad / 16.0,
                             st.kit_base .. " " .. (pad + 1))
      -- breadcrumbs are now REAL disk sources (pre-P3 chop cleared these)
      reaper.SetExtState("Swing", "pad_path_" .. pad, wv.path, false)
      publish_pitch_path(pad, wv.path)
      used = used + 1
    else
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, 0)
      local mb = G.META_BASE + pad * G.META_PP
      for j = 0, G.META_PP - 1 do reaper.gmem_write(mb + j, 0) end
      reaper.SetExtState("Swing", "pad_path_" .. pad, "", false)
      publish_pitch_path(pad, "")
    end
  end
  core.gmem_write_string(("Chop: " .. st.kit_base):sub(1, 32), NAME_BASE, G.NAMELEN, 32)
  reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)
  reaper.gmem_write(G.KIT_GMEM_VER, 201)
  -- Phase 1 (2026-07-17): the arm gate is PENDING-exclusive — a stage with
  -- no named consumer can never be consumed (it would sit at CMD=3 until
  -- the stale watchdog aborts 98). Resolve a live fallback if the chop's
  -- own instance died mid-capture; abort loudly rather than stage orphaned.
  local _chop_target = (st.inst_id or 0) > 0 and st.inst_id or nil
  if not _chop_target then
    -- First live id from the instance REGISTRY gmem band (enumerate_all_swings
    -- is a chunk-local declared later in the file — not in lexical scope here).
    local _slot = 0
    while _slot < (G.GS_INST_REG_MAX or 16) and not _chop_target do
      local _rid = math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + _slot * G.GS_INST_REG_STRIDE) or 0)
      if _rid > 0 then _chop_target = _rid end
      _slot = _slot + 1
    end
  end
  if not _chop_target then
    reaper.ShowConsoleMsg("[Swing] chop: no live Swing instance to receive slices — aborted\n")
    eon_chop_state = nil
    reaper.Undo_EndBlock("Swing: Chop to Pads (aborted)", -1)
    return
  end
  reaper.gmem_write(G.GS_PENDING_LOAD_INST, _chop_target)
  reaper.gmem_write(G.CMD, 3)              -- staged (latch was held since arming)
  reaper.gmem_write(G.GS_KIT_LOAD_REQ, 2)  -- stale-JSFX compat arm path
  -- Phase 1b: epoch LAST = the current JSFX's arm signal (chop stages
  -- outside the load queue, so it stamps its own; the queue's next
  -- dispatch reads-and-increments, staying monotonic).
  reaper.gmem_write(G.GS_LOAD_EPOCH,
    math.floor(reaper.gmem_read(G.GS_LOAD_EPOCH) or 0) + 1)
  update_folder_track_name(find_swing_track())
  -- A chop kit has NO kit file: clear this instance's kit-source lineage or
  -- the sidecar system resurrects the PREVIOUS kit over the chop on reopen
  -- (auto_save copies kit_sources[guid] → the on-open reload restores that
  -- FILE — observed live: reopen replaced a fresh chop with the boot 808).
  -- Also delete an already-written sidecar; its mere existence re-queues the
  -- reload. Chop pads restore via @serialize until Phase 4 goes path-pure.
  if st.tr and reaper.ValidatePtr2(0, st.tr, "MediaTrack*") then
    local g = reaper.GetTrackGUID(st.tr) or ""
    if g ~= "" then
      kit_sources[g] = nil
      local _, pfn = reaper.EnumProjects(-1)
      local pdir = pfn and pfn:match("^(.*)[/\\]")
      if pdir then
        os.remove(pdir .. "/Swing/swing_" .. g:gsub("[^%w]", "") .. ".swing")
      end
    end
    reaper.GetSetMediaTrackInfo_String(st.tr, "P_EXT:swing_kit_src", "", true)
  end
  reaper.Undo_EndBlock("Swing: Chop to Pads (" .. used .. " slices)", -1)
  st.phase = "verify"
  st.verify_at = reaper.time_precise() + 2.5
end

-- ── load_kit_v5 — read a self-contained zip kit and push to gmem ─────────
-- Symmetric to write_kit_v5: unpack zip → parse kit.json → write meta + per-pad
-- wav samples to gmem at AUDIO_BASE (running offset). Signals JSFX with VER=24
-- (same v1 binary import path that load_kit_v4 uses) so audio gets copied into
-- internal s_audio_start buffers on the next @block.
local function load_kit_v5(filepath, internal)
  local manifest, pad_buffers, err = swing_kit_v5.load_kit(filepath)
  if not manifest then
    eon_notice("Could not load v5 kit:\n" .. tostring(err))
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- Kit name
  core.gmem_write_string(internal and (manifest.kit_name or "Kit")
                or eon_kit_display_name(filepath, manifest.kit_name), NAME_BASE, G.NAMELEN, 32)  -- Phase 2: filename canonical

  -- Globals (object keyed by name, matching write_kit_v5 output)
  if manifest.globals then
    for i, key in ipairs(KIT_GLOBAL_KEYS) do
      local default = KIT_GLOBAL_DEFAULTS[key] or 0
      reaper.gmem_write(KIT_GMEM_GLOBALS + i - 1, manifest.globals[key] or default)
    end
  end

  local pads = manifest.pads or {}
  local pad_layer_cnts = {}

  -- Per-pad metadata (mirrors load_kit_v4 — same param ordering)
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local base = G.META_BASE + pad * G.META_PP

    reaper.gmem_write(base + 0,  p.gain or 1.0)
    reaper.gmem_write(base + 1,  p.pan or 0)
    reaper.gmem_write(base + 2,  p.pitch or 0)
    reaper.gmem_write(base + 3,  p.attack or 0)
    reaper.gmem_write(base + 4,  p.decay or 0.5)
    reaper.gmem_write(base + 5,  p.sustain or 1.0)
    reaper.gmem_write(base + 6,  p.release or 0.02)
    reaper.gmem_write(base + 7,  p.mute or 0)
    reaper.gmem_write(base + 8,  p.solo or 0)
    reaper.gmem_write(base + 9,  p.output or 0)
    reaper.gmem_write(base + 10, p.note or (36 + pad))
    reaper.gmem_write(base + 11, p.note_lock or 0)
    reaper.gmem_write(base + 12, p.color or 0)
    reaper.gmem_write(base + 13, p.choke or 0)
    reaper.gmem_write(base + 14, p.oneshot or -1)
    reaper.gmem_write(base + 15, p.reverse or 0)
    reaper.gmem_write(base + 16, p.fx_hpf or 20)
    reaper.gmem_write(base + 17, p.fx_lpf or 20000)
    reaper.gmem_write(base + 18, p.fx_eq_lo or 0)
    reaper.gmem_write(base + 19, p.fx_eq_mid or 0)
    reaper.gmem_write(base + 20, p.fx_eq_hi or 0)
    reaper.gmem_write(base + 21, p.fx_sat or 0)
    reaper.gmem_write(base + 22, p.fx_drv_mode or 0)
    reaper.gmem_write(base + 23, p.fx_bc_rate or 0)
    reaper.gmem_write(base + 24, p.fx_bc_bits or 16)
    reaper.gmem_write(base + 25, p.fx_snd_dly or 0)
    reaper.gmem_write(base + 26, p.fx_snd_rvb or 0)
    reaper.gmem_write(G.GS_PAD_SMASH_BASE + pad, p.fx_snd_smash or 0)
    reaper.gmem_write(base + 27, p.fx_eq_lo_freq or 200)
    reaper.gmem_write(base + 28, p.fx_eq_mid_freq or 1000)
    reaper.gmem_write(base + 29, p.fx_eq_hi_freq or 5000)
    reaper.gmem_write(base + 30, p.sum_tight or 0)
    reaper.gmem_write(base + 31, p.rpt_div or 0)

    local lc = math.floor(p.layer_cnt or 0)
    if lc < 0 then lc = 0 end
    if lc > G.MAX_LAYERS then lc = G.MAX_LAYERS end
    pad_layer_cnts[pad] = lc

    reaper.gmem_write(base + 32, lc)
    reaper.gmem_write(base + 33, p.layer_mode or 0)
    reaper.gmem_write(base + 34, p.s_len or 0)
    reaper.gmem_write(base + 35, p.s_start or 0)
    reaper.gmem_write(base + 36, p.s_end or 1.0)
    reaper.gmem_write(base + 37, p.s_sr or 0)
    reaper.gmem_write(base + 38, p.s_norm or 0)
    reaper.gmem_write(base + 39, p.s_norm_gain or 0)
    reaper.gmem_write(G.GS_PAD_OFFSET_BASE + pad, p.sample_offset or 0)
    reaper.gmem_write(G.GS_PAD_RANGE_BASE + pad, (p.rng_lo or 0) * 128 + (p.rng_hi or 0))
    eon_padcat_from_load(pad, p.category, p.name, p.path)   -- categories §1: p.category or classify(name), full-path rescue

    -- Zero ALL MAX_LAYERS metadata slots, then fill the active ones
    for lj = 0, G.MAX_LAYERS - 1 do
      local lo = base + 40 + lj * 10
      for li = 0, 9 do reaper.gmem_write(lo + li, 0) end
    end
    local layers = p.layers or {}
    for layer = 0, lc - 1 do
      local L  = layers[layer + 1] or {}
      local lo = base + 40 + layer * 10
      reaper.gmem_write(lo + 0, L.len or 0)
      reaper.gmem_write(lo + 1, L.start or 0)
      reaper.gmem_write(lo + 2, L["end"] or 1.0)
      reaper.gmem_write(lo + 3, L.sr or 0)
      reaper.gmem_write(lo + 4, L.norm or 0)
      reaper.gmem_write(lo + 5, L.norm_gain or 1.0)
      reaper.gmem_write(lo + 6, L.vel_lo or 0)
      reaper.gmem_write(lo + 7, L.vel_hi or 127)
      reaper.gmem_write(lo + 8, L.rr_order or layer)
      reaper.gmem_write(lo + 9, L.gain or 1.0)
    end

    -- Pad name
    local name = p.name or ""
    local name_base = G.PADNAME_BASE + pad * G.PADNAME_LEN
    for i = 0, G.PADNAME_LEN - 1 do
      reaper.gmem_write(name_base + i, i < #name and name:byte(i + 1) or 0)
    end

    -- Breadcrumb (audio is baked, but path is informational)
    local path = p.path or ""
    if path ~= "" then
      reaper.SetExtState("Swing", "pad_path_" .. pad, path, false)
    end
    publish_pitch_path(pad, path)
  end

  -- Per-pad audio: write samples from pad_buffers to gmem AUDIO_BASE at
  -- running offset. wav.read returns int16; gmem expects -1.0..1.0 floats
  -- (matches the v4 unpack_s16 division by 32767.0).
  local audio_off = 0
  for pad = 0, G.NUM_PADS - 1 do
    local p = pads[pad + 1] or {}
    local lc = pad_layer_cnts[pad]
    if lc > 0 then
      -- Layered: concatenate each layer's audio into gmem in order
      local total_alen = 0
      for layer = 0, lc - 1 do
        local L = (p.layers or {})[layer + 1] or {}
        local wav_name = L.audio
        local buf = wav_name and pad_buffers[wav_name]
        local l_alen, l_sr = 0, 0
        if buf and buf.samples then
          local samples = buf.samples
          l_sr = buf.sample_rate or 0
          local count = #samples
          if audio_off + count > GMEM_AUDIO_MAX then
            count = math.max(0, GMEM_AUDIO_MAX - audio_off)
          end
          for j = 0, count - 1 do
            reaper.gmem_write(G.AUDIO_BASE + audio_off + j, samples[j + 1] / 32767.0)
          end
          l_alen = count
          audio_off = audio_off + count
        end
        local lo = G.META_BASE + pad * G.META_PP + 40 + layer * 10
        reaper.gmem_write(lo + 0, l_alen)   -- l_len from wav (binary truth)
        reaper.gmem_write(lo + 3, l_sr)     -- l_sr
        total_alen = total_alen + l_alen
      end
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, total_alen)
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 34, 0)
    else
      -- Non-layered: single pad blob
      local wav_name = p.audio
      local buf = wav_name and pad_buffers[wav_name]
      local s_alen, s_sr = 0, 0
      if buf and buf.samples then
        local samples = buf.samples
        s_sr = buf.sample_rate or 0
        local count = #samples
        if audio_off + count > GMEM_AUDIO_MAX then
          count = math.max(0, GMEM_AUDIO_MAX - audio_off)
        end
        for j = 0, count - 1 do
          reaper.gmem_write(G.AUDIO_BASE + audio_off + j, samples[j + 1] / 32767.0)
        end
        s_alen = count
        audio_off = audio_off + count
      end
      reaper.gmem_write(G.AUDIOLEN_BASE + pad, s_alen)
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 34, s_alen)  -- s_len
      reaper.gmem_write(G.META_BASE + pad * G.META_PP + 37, s_sr)    -- s_sr
    end
  end

  -- Signal JSFX (same VER=24 marker that load_kit_v4 uses)
  reaper.gmem_write(G.KIT_GMEM_NPADS, G.NUM_PADS)
  reaper.gmem_write(G.KIT_GMEM_VER, 24)
  reaper.gmem_write(G.CMD, 3)
  update_folder_track_name(find_swing_track())
end

local function load_swing_dispatch_now(filepath, internal, no_attrib)
  -- Default this load to a NORMAL load (kit values overwrite live params).
  -- drive_load_queue re-asserts the preserve flag (=1) after this returns for
  -- project-open sidecar / Undo audio-repair reloads only. Every kit-load
  -- route funnels through here, so this is the single place to clear it.
  reaper.gmem_write(G.GS_KIT_PRESERVE_LIVE, 0)
  local valid, fmt = validate_swing(filepath)
  if not valid then
    eon_notice("Invalid file: " .. (fmt or ""))
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- MIRROR LATCH (Phase 3, 2026-07-12): hold CMD=3 for the ENTIRE staging
  -- pass, not just at its end. The JSFX browser-target mirror republishes its
  -- LIVE pad cnames into KIT_GMEM_PADNAMES every block, yielding only while
  -- kit_busy or CMD is 3/50/51/63/64 (Swing_ReaKit.jsfx ~2264) — but staging
  -- used to run under CMD==0, so the mirror overwrote freshly staged kit
  -- names mid-stage. pl-route loads masked it (load_from_path re-derives
  -- names from real sample basenames); px/store-route loads (basenames
  -- pad00_lay0.wav) surfaced it as "kit loads, audio switches, names keep
  -- the previous kit" — the load-'stall' red herring probed 2026-07-09/12.
  -- Import still arms only on GS_KIT_LOAD_REQ=2, so an early 3 triggers
  -- nothing; loader failure paths overwrite with 98; the bridge dispatch
  -- chain ignores unmatched CMD 3.
  reaper.gmem_write(G.CMD, 3)

  -- Track this path as the source for the requesting instance, so a
  -- subsequent project save can copy this exact file to the project's
  -- sidecar location (instead of rebuilding from gmem, which is racy
  -- across multi-window @gfx mirrors). Every kit-load route ends up
  -- here, so this single hook covers manual LOAD button, browser kit
  -- pick, drag-drop kit, auto-sidecar reload, etc.
  --
  -- Identify the requesting instance: prefer LOCK (set by JSFX-side
  -- LOAD button as `gmem[LOCK] = instance_id; gmem[CMD] = 2`), fall back
  -- to INSTANCE (browser-target slot, set by the browser picker before
  -- triggering kit_load_req without taking LOCK).
  --
  -- Also persist the path to per-track ExtState (P_EXT:swing_kit_src)
  -- so it survives REAPER restarts and project reopens. Without this,
  -- opening a saved project starts with empty kit_sources and the
  -- chunk-loaded kits can't be saved to sidecar without manual reload.
  -- Phase 3 (vector G): QUEUE loads pass no_attrib — their kit_sources /
  -- P_EXT lineage is written at positive-ACK time in drive_load_queue, so a
  -- kit that never actually landed can no longer become the sidecar the
  -- on-open reload resurrects. The CMD-2/16 dialog flows (JSFX LOAD button,
  -- LOCK-owned) keep this dispatch-time attribution.
  if kit_sources and not no_attrib then
    -- Identifier resolution order (each ID points at the requesting instance):
    --   LOCK                 — JSFX-side LOAD button took it before writing CMD=2
    --   GS_PENDING_LOAD_INST — auto-load 808 / browser-driven path; survives
    --                          the bridge's CMD auto-release (LOCK cleared
    --                          after CMD 22 dispatch but PENDING is still set
    --                          when kit_load_req's deferred dispatch fires)
    --   INSTANCE             — browser picker target, set by browser script
    local lock_id    = math.floor(reaper.gmem_read(G.LOCK) or 0)
    local pending_id = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0)
    local inst_id_gmem = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
    local target_id = lock_id > 0 and lock_id
                   or (pending_id > 0 and pending_id)
                   or inst_id_gmem
    if target_id > 0 then
      -- Find the track that owns this instance and key kit_sources by its GUID
      -- (project-unique) — not the colliding integer target_id. Also stash the
      -- path on the track's ExtState. Use a `done` flag to break out of both
      -- loops; `return` here would exit load_swing_dispatch entirely, skipping
      -- the actual kit load!
      local done = false
      for tr in core.iter_all_tracks() do
        if done then break end
        for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
          if is_swing_fx(tr, fx) then
            local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
            if inst_id == target_id then
              local guid = reaper.GetTrackGUID(tr)
              if guid and guid ~= "" then kit_sources[guid] = filepath end
              reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", filepath, true)
              done = true
              break
            end
          end
        end
      end
    end
  end

  -- Cover: cleared before the load so a kit WITHOUT one blanks the tile rather
  -- than inheriting the previous kit's art. load_kit_v4 refills it from the tail.
  eon_kit_cover_bytes = nil
  eon_kit_cover_path  = nil

  if fmt == "v5" then
    load_kit_v5(filepath, internal)
  elseif fmt == "v4" then
    load_kit_v4(filepath, internal)
  elseif fmt == "v2" then
    -- Legacy path-only format — best-effort load (pads may be blank if source
    -- files have moved). Users should re-save to upgrade these to v5.
    load_kit_v2(filepath, internal)
  else
    -- v1 binary format (already self-contained)
    load_swing_file(filepath, internal)
  end

  -- Publish the cover path to whichever instance asked for this load. Path
  -- first, seq LAST — the JSFX only re-reads (and only hits the disk with
  -- gfx_loadimg) when the seq moves. Published even when there is no cover, so
  -- the JSFX clears a stale image instead of showing the last kit's art.
  --
  -- eon_kit_cover_load_slot is only set when an instance EXPLICITLY asks for a
  -- load (the CMD path, ~line 13963). A load nobody requested — above all the
  -- sidecar reload on project open — leaves it nil, and eon_kitcover_publish
  -- returns immediately on a nil slot. That is the whole of the "artwork is in
  -- the kit file but the tile is blank after reopening" bug: the cover is read,
  -- extracted to disk and then announced to nobody. Fall back to the live
  -- instance so an unrequested load still reaches a tile.
  local cover_slot = eon_kit_cover_load_slot
  if not cover_slot then
    -- Belt and braces for any route that reaches here without going through the
    -- load queue. PENDING_LOAD_INST is the instance THIS load is aimed at;
    -- INSTANCE is only the last one anything talked to, so it is the weaker
    -- guess and goes second.
    local want = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0)
    if want <= 0 then want = math.floor(reaper.gmem_read(G.INSTANCE) or 0) end
    cover_slot = ss_resolve_slot(want)
  end
  eon_kitcover_publish(cover_slot, eon_kit_cover_path)
end

-- Kit-undo wrapper — PARKED (2026-06-29). The disk-based kit undo (pre-load
-- silent dump via start_kit_undo_dump, reload via CMD 82) is fully plumbed but
-- the dump handshake never engaged in live testing; until that's debugged the
-- wrapper is a pass-through so kit loads carry zero extra latency/risk. To
-- revive: replace the body with the start_kit_undo_dump(...) sequencing (see
-- the KIT-LEVEL UNDO block after find_swing_track) and re-arm
-- udo_struct_begin_kit in rk_drumkit_dsp.jsfx-inc.
-- ACK-HOLE FIXED 2026-07-09: the dump now completes with CMD 84 (not the
-- user-save CMD 1), so a phase-1 timeout that nils kit_undo_job can no longer
-- misroute the late completion into do_export_write_file (which wedged
-- kit_busy=1). When reviving, the after(ok) callback must still serialize the
-- follow-up load behind the phase-2 drain (wait for CMD back to 0) — the 84
-- split removes the *classification* race, not the single-CMD-cell ordering
-- the drain exists to handle.
local function load_swing_dispatch(filepath, skip_undo_dump, no_attrib)
  -- skip_undo_dump doubles as the INTERNAL-load marker (Phase 2): sidecar /
  -- undo-restore files carry token filenames (swing_<guid>[_undo].swing)
  -- that must never become the displayed kit name — internal loads keep the
  -- file's manifest name; user loads are filename-canonical.
  return load_swing_dispatch_now(filepath, skip_undo_dump, no_attrib)
end

-- CMD 2: Import from kit browser (Swing_Kits folder)
-- Bridge CMD-handler ops grouped on ONE table (headroom pass) — keeps this
-- cluster of dispatch handlers from each eating a scarce main-chunk local slot.
local rk_ops = {}

function rk_ops.do_import()
  local kits, kits_dir = enumerate_kits()

  -- DEV HOOK (kitpipe_button probe): a one-shot ExtState pick stands in for
  -- the interactive gfx.showmenu choice — the ONLY thing the menu contributes
  -- is `selected`, so everything else here (enumerate above, queue handoff
  -- below) is the production LOAD-button path. Sibling of dev_export_path.
  -- Value = full kit path or bare "<name>.swing"; no match = menu-cancel 98.
  -- Checked BEFORE the no-kits message box: the dev path is headless and must
  -- never raise a modal (a modal freezes every defer loop in the session).
  local selected
  local dev_pick = reaper.GetExtState("EON_Bridge", "dev_kit_pick")
  if dev_pick ~= "" then
    reaper.SetExtState("EON_Bridge", "dev_kit_pick", "", false)
    local pick_base = dev_pick:match("([^/\\]+)$")
    for _, k in ipairs(kits) do
      if k.path == dev_pick or k.filename == pick_base then selected = k; break end
    end
    eon_load_report(string.format("dev_kit_pick %q -> %s (%d kits in %s)",
      dev_pick, selected and selected.name or "NO MATCH", #kits, kits_dir))
    if not selected then
      reaper.gmem_write(G.CMD, 98); return   -- release the armed JSFX
    end
  elseif #kits == 0 then
    eon_notice(
      "No .swing kit files found.\n\nKit directory:\n" .. kits_dir ..
      "\n\nSave a kit first, or place .swing files in this folder.")
    reaper.gmem_write(G.CMD, 98)
    return
  else
    local menu_str = ""
    for i, k in ipairs(kits) do
      if i > 1 then menu_str = menu_str .. "|" end
      menu_str = menu_str .. k.name .. "  (" .. core.format_size(k.size) .. ")"
    end

    -- Wrap gfx.init/showmenu/quit in pcall so a transient failure (display
    -- driver hiccup, exotic OS DPI state, etc.) doesn't leak a gfx context
    -- and brick the bridge. On error: report via console, fail the CMD.
    local ok, choice = pcall(function()
      gfx.init("Swing Kit Browser", 1, 1, 0, 0, 0)
      gfx.x = gfx.mouse_x; gfx.y = gfx.mouse_y
      local c = gfx.showmenu(menu_str)
      gfx.quit()
      return c
    end)
    if not ok then
      -- Defensive cleanup in case gfx.init succeeded but quit didn't run
      pcall(gfx.quit)
      reaper.ShowConsoleMsg("[Swing Bridge] gfx menu failed: " .. tostring(choice) .. "\n")
      reaper.gmem_write(G.CMD, 98); return
    end

    if choice <= 0 then reaper.gmem_write(G.CMD, 98); return end

    selected = kits[choice]
    if not selected then reaper.gmem_write(G.CMD, 98); return end
  end

  -- Through the QUEUE, not a direct dispatch (2026-07-19) — the LOAD button now
  -- gets the pump-drain gate, epoch/ack and retry backstop. CMD back to 0 so the
  -- pop gate opens (it waits for CMD==0); the JSFX is already sitting in
  -- kit_import_state 1 from the button click and consumes the pop's CMD=3.
  if eon_enqueue_kit_load(selected.path) then
    reaper.gmem_write(G.CMD, 0)
  else
    eon_load_report("FAILED: no live Swing instance to receive " .. selected.name)
    reaper.gmem_write(G.CMD, 98)   -- release the JSFX from its armed state
  end
end

-- CMD 16: Import from full PC browse (any folder)
function rk_ops.do_import_browse()
  local has_js = reaper.JS_Dialog_BrowseForOpenFiles ~= nil
  if not has_js then
    -- Fallback: GetUserInputs
    local retval, input = reaper.GetUserInputs("Load Swing Kit", 1, "Full path to .swing file:,extrawidth=300", "")
    if not retval or input == "" then reaper.gmem_write(G.CMD, 98); return end
    reaper.gmem_write(G.CMD, eon_enqueue_kit_load(input) and 0 or 98)  -- queue (see do_import)
    return
  end

  local retval, filepath = reaper.JS_Dialog_BrowseForOpenFiles(
    "Load Swing Kit", core.get_kits_dir(), "", "Swing Kit Files (*.swing)\0*.swing\0All Files (*.*)\0*.*\0", false
  )
  if not retval or filepath == "" then reaper.gmem_write(G.CMD, 98); return end

  reaper.gmem_write(G.CMD, eon_enqueue_kit_load(filepath) and 0 or 98)  -- queue (see do_import)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- MULTI-OUT TRACK BUILDER (CMD 40)
-- ═════════════════════════════════════════════════════════════════════════════

-- opts.fx_returns: true/false to force the FX-return-tracks decision, nil to
-- decide automatically (preserve if return tracks already exist, else ask).
function rk_ops.do_build_multiout(opts)
  -- opts.on_done(ok): fires at every terminal — ok=true after a completed
  -- build/update (CMD left at 99), false on cancel/failure (98). Callers that
  -- used to read G.CMD the moment this returned (Build Both) MUST use this
  -- instead: the FX-returns prompt below is an async house dialog, so the
  -- function can return with the decision still pending.
  local function done(ok)
    if opts and opts.on_done then opts.on_done(ok) end
  end
  local swing_track, swing_fx = find_swing_track()
  if not swing_track then
    eon_notice(
      "Could not find Swing on any track.\n\n" ..
      "Make sure Swing (Swing_ReaKit.jsfx) is loaded as an FX on a track.")
    reaper.gmem_write(G.CMD, 98)
    done(false)
    return
  end

  -- Put Swing into MULTI before the tracks exist. Swing's own right-click
  -- builder calls swing_panels_multiout_prep() before it raises CMD 40, so it
  -- is already in MULTI by the time we finish. Every route that lands here from
  -- LUA instead -- EON_Swing_BuildMultiOut / BuildBoth, the EON menu, the Song
  -- Starter checkbox -- skipped that, and produced the child tracks with Swing
  -- still summing to stereo Out 1. Companion cmd 5 is the JSFX-side half.
  --
  -- ⚠️ MUST come AFTER the find_swing_track() bail, not before it. Posting it
  -- first (as this originally did) left cmd 5 armed FOREVER on the no-Swing
  -- path -- nothing exists to consume it -- so the next Swing inserted into the
  -- project would silently adopt multi-out and reassign all 16 pad outputs out
  -- of nowhere. There is no point commanding an instance we just proved is not
  -- there. Swing runs gfx_idle, so its @gfx consumes this with the window
  -- closed, and the `_ccmd > 0 && !kit_busy` gate holds it pending, not drops it.
  -- ADDRESSED (2026-08-10): stamp the target instance BEFORE the cmd -- the
  -- companion cell is otherwise a broadcast any instance consumes, and in a
  -- multi-Swing project a bystander could adopt the 5 and flip the WRONG kit
  -- to multi-out. 0 (no id readable) keeps legacy broadcast. The poll()
  -- watchdog clears a lingering targeted cmd whose instance died mid-flight.
  local c5tgt = 0
  if swing_fx then
    c5tgt = math.floor(reaper.TrackFX_GetParam(swing_track, swing_fx, 3) or 0)
    if c5tgt < 0 then c5tgt = 0 end
  end
  if G.GS_COMPANION_TARGET then reaper.gmem_write(G.GS_COMPANION_TARGET, c5tgt) end
  reaper.gmem_write(G.GS_COMPANION_CMD, 5)

  -- Read pad names and colors from gmem (JSFX syncs these before sending CMD=40)
  local pad_names = {}
  local pad_hues = {}
  for i = 0, G.NUM_PADS - 1 do
    local chars = {}
    for j = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + i * G.PADNAME_LEN + j))
      if c > 0 and c < 128 then chars[#chars + 1] = string.char(c) end
    end
    local name = table.concat(chars)
    if name == "" then name = "Pad " .. (i + 1) end
    pad_names[i] = name

    local hue = reaper.gmem_read(G.META_BASE + i * G.META_PP + 12)
    -- Allow negative sentinels through (-1 = white, -2 = black)
    if hue > 1 then hue = i / 16.0 end
    pad_hues[i] = hue
  end

  -- Helper: generate track name from pad name. Blank pads (no audio, per the
  -- one shared signal) always get the number — never a stale gmem name.
  local function make_track_name(idx)
    if not core.pad_has_audio(idx) then
      return string.format("%02d", idx + 1)
    end
    local pname = pad_names[idx]
    if pname ~= "" and pname ~= string.format("Pad %d", idx + 1) then
      return pname
    else
      return string.format("%02d", idx + 1)
    end
  end

  -- ── Opt-in: delay/reverb FX return tracks ──────────────────────────────
  -- The wet from Swing's internal delay/reverb is identical in stereo and
  -- multi-out (same engine); only the exit point changes. When ON, the JSFX
  -- routes the wet to dedicated output pairs (verb ch32/33, delay ch34/35) so
  -- it feeds its own return tracks instead of leaking into the Main bus /
  -- child-track 0. Detect existing return tracks NOW (before a Rebuild can
  -- delete them) so the decision can preserve them.
  local function detect_returns()
    local v, d, sm = false, false, false
    local ns = reaper.GetTrackNumSends(swing_track, 0)
    for s = 0, ns - 1 do
      local dt = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
      if dt then
        local _, vt = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:EON_VERB_RETURN", "", false)
        local _, dd = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:EON_DELAY_RETURN", "", false)
        local _, sr = reaper.GetSetMediaTrackInfo_String(dt, "P_EXT:EON_SMASH_RETURN", "", false)
        if vt == "1" then v = true end
        if dd == "1" then d = true end
        if sr == "1" then sm = true end
      end
    end
    return v, d, sm
  end
  local have_verb, have_delay, have_smash = detect_returns()
  -- An existing EON Weld on the Audio submix parent (it survives a Rebuild) is
  -- the user's standing opt-in for the drum-bus comp — preserved, not re-asked.
  local have_buscomp = false
  do
    local pre_sub = find_audio_subfolder(swing_track)
    if pre_sub then
      for fx = 0, reaper.TrackFX_GetCount(pre_sub) - 1 do
        local _, fn = reaper.TrackFX_GetFXName(pre_sub, fx, "")
        if fn and (fn:find("EON Weld", 1, true) or fn:find("EON Anvil", 1, true)) then have_buscomp = true break end
      end
      if not have_buscomp then
        -- a chain insert can't be name-matched; its P_EXT marker is the opt-in
        local _, m = reaper.GetSetMediaTrackInfo_String(pre_sub, "P_EXT:EON_RACK_COMP", "", false)
        if m and m:find("^chain:") then have_buscomp = true end
      end
    end
  end

  -- Existing StepSeq on the Swing track = a standing opt-in, preserved.
  local have_stepseq = false
  do
    local sq = core.jsfx_addname("EON_StepSeq.jsfx")
    if sq and reaper.TrackFX_AddByName(swing_track, sq, false, 0) >= 0 then
      have_stepseq = true
    end
  end

  -- Find-or-insert EON StepSeq just above Swing (the generated MIDI must feed
  -- it — same find/move shape as the Steppa-open toggle) and open it embedded
  -- in the MCP on a fresh insert. Existing instances are left exactly as-is.
  local function ensure_stepseq()
    local sq, _, sq_why = core.jsfx_addname("EON_StepSeq.jsfx")
    if not sq then
      reaper.ShowConsoleMsg("[Swing] EON_StepSeq.jsfx not found -- step sequencer skipped" ..
        string.char(10) .. "  " .. tostring(sq_why) .. string.char(10))
      return
    end
    if reaper.TrackFX_AddByName(swing_track, sq, false, 0) >= 0 then return end
    local seq_idx = reaper.TrackFX_AddByName(swing_track, sq, false, -1)
    if not seq_idx or seq_idx < 0 then return end
    local sw_idx, nfx, fi = -1, reaper.TrackFX_GetCount(swing_track), 0
    while fi < nfx do
      if is_swing_fx(swing_track, fi) then sw_idx = fi; break end
      fi = fi + 1
    end
    local dst = seq_idx
    if sw_idx >= 0 and seq_idx > sw_idx then
      reaper.TrackFX_CopyToTrack(swing_track, seq_idx, swing_track, sw_idx, true)
      dst = sw_idx
    end
    -- Embed in the MCP via the house action path (focus + "Show last focused
    -- FX embedded UI in MCP") — a chunk rewrite on the Swing track would
    -- re-instantiate a loaded multi-MB kit. Chunk flip only as the SWS-less
    -- fallback, where that cost is accepted.
    reaper.TrackFX_SetNamedConfigParm(swing_track, dst, "focused", "1")
    if not eon_embed_last_focused(false) then
      core.fx_embed_mcp(swing_track, "EON_StepSeq")
    end
  end

  -- Find-or-insert an EON Weld on a track. Fresh inserts get the context
  -- defaults (matched by param NAME with plain find — the labels carry
  -- "(dB)" parens) and open EMBEDDED in the MCP; an existing instance keeps
  -- its settings and embed state, so a Rebuild never stomps the user's comp.
  local function ensure_eon76(tr, defaults)
    if not tr then return end
    local name = core.jsfx_addname("EON_Weld.jsfx", swing_track, swing_fx)
    if not name then
      reaper.ShowConsoleMsg("[Swing] EON_Weld.jsfx not found -- bus compressor skipped" .. string.char(10))
      return
    end
    if reaper.TrackFX_AddByName(tr, name, false, 0) >= 0 then return end
    local fx = reaper.TrackFX_AddByName(tr, name, false, 1)
    if fx < 0 then
      reaper.ShowConsoleMsg("[Swing] Could not insert EON Weld (" .. tostring(name) .. ")" .. string.char(10))
      return
    end
    for pat, val in pairs(defaults or {}) do
      for p = 0, reaper.TrackFX_GetNumParams(tr, fx) - 1 do
        local _, pn = reaper.TrackFX_GetParamName(tr, fx, p, "")
        if pn and pn:find(pat, 1, true) then
          reaper.TrackFX_SetParam(tr, fx, p, val)
          break
        end
      end
    end
    core.fx_embed_mcp(tr, "EON_Weld")   -- opens embedded in the MCP by default
  end

  -- ~~ Rack comp choice (2026-08-25): each comp slot is Weld / Anvil / a user
  -- FX chain. Selection is remembered per slot in ExtState; a chain insert
  -- marks the track with P_EXT so a Rebuild neither re-asks nor re-inserts.
  -- Stock JS comps that earn a card in the picker (ship with REAPER).
  -- adds = AddByName idents to try in order; the card PNG is card_<key>.png.
  -- Combo entries carry: sec (menu section), cat (shown after the name),
  -- and EITHER adds (direct AddByName idents -- stock JS, guaranteed paths)
  -- OR find (lowercase substrings matched against REAPER's installed-FX
  -- registry, so ReaKit and third-party comps resolve wherever the user's
  -- installer put them, and vanish from the menu when absent).
  local RACK_STOCKS = {
    -- the card trio (shipped PNG faces; not in the combo)
    { key = "majortom",       label = "Major Tom",
      adds = { "JS:sstillwell/majortom", "sstillwell/majortom" } },
    { key = "fairlychildish", label = "Fairly Childish",
      adds = { "JS:sstillwell/fairlychildish", "sstillwell/fairlychildish" } },
    { key = "eventhorizon",   label = "Event Horizon",
      adds = { "JS:sstillwell/eventhorizon", "sstillwell/eventhorizon" } },
    -- EON ReaKit (resolved by registry: dev tree and customer installs
    -- live at different paths; the _ReaKit stem is the unique handle)
    { key = "rk1175",       label = "1175",         combo = true, sec = "EON ReaKit", cat = "FET",
      find = { "1175_reakit" } },
    { key = "rkexpressbus", label = "Express Bus",  combo = true, sec = "EON ReaKit", cat = "bus VCA",
      find = { "expressbus_reakit" } },
    { key = "rkcompressor", label = "Compressor",   combo = true, sec = "EON ReaKit", cat = "clean VCA",
      find = { "compressor_reakit" } },
    { key = "rkdirt",       label = "Dirt Squeeze", combo = true, sec = "EON ReaKit", cat = "FET dirt",
      find = { "dirtsqueeze_reakit" } },
    { key = "rklimiter",    label = "Limiter",      combo = true, sec = "EON ReaKit", cat = "limiter",
      find = { "limiter_reakit" } },
    -- Stock JS (ship with REAPER; path-qualified so the sstillwell 1175 /
    -- dirtsqueeze never collide with our ReaKit plugins of the same name)
    { key = "1175",        label = "1175",          combo = true, sec = "Stock JS", cat = "FET",
      adds = { "JS:sstillwell/1175", "sstillwell/1175" } },
    { key = "expressbus",  label = "Express Bus",   combo = true, sec = "Stock JS", cat = "bus VCA",
      adds = { "JS:sstillwell/expressbus", "sstillwell/expressbus" } },
    { key = "mastertom",   label = "Master Tom",    combo = true, sec = "Stock JS", cat = "bus VCA",
      adds = { "JS:sstillwell/mastertom", "sstillwell/mastertom" } },
    { key = "dirtsqueeze", label = "Dirt Squeeze",  combo = true, sec = "Stock JS", cat = "FET dirt",
      adds = { "JS:sstillwell/dirtsqueeze", "sstillwell/dirtsqueeze" } },
    { key = "badbussmojo", label = "Bad Buss Mojo", combo = true, sec = "Stock JS", cat = "colour",
      adds = { "JS:sstillwell/badbussmojo", "sstillwell/badbussmojo" } },
    { key = "louderizer",  label = "Louderizer",    combo = true, sec = "Stock JS", cat = "loudness",
      adds = { "JS:sstillwell/louderizer", "sstillwell/louderizer" } },
    { key = "realoud",     label = "ReaLoud",       combo = true, sec = "Stock JS", cat = "loudness",
      adds = { "JS:sstillwell/realoud", "sstillwell/realoud" } },
    { key = "autoexpand",  label = "Auto Expand",   combo = true, sec = "Stock JS", cat = "expander",
      adds = { "JS:sstillwell/autoexpand", "sstillwell/autoexpand" } },
    { key = "thunderkick", label = "Thunder Kick",  combo = true, sec = "Stock JS", cat = "kick tool",
      adds = { "JS:sstillwell/thunderkick", "sstillwell/thunderkick" } },
    { key = "reacomp",     label = "ReaComp",       combo = true, sec = "Stock JS", cat = "Cockos VCA",
      find = { "reacomp" } },
    -- Third party (popular free comps; only listed when actually installed)
    { key = "kotelnikov", label = "TDR Kotelnikov",   combo = true, sec = "Third party", cat = "bus VCA",
      find = { "kotelnikov" } },
    { key = "dc1a",       label = "Klanghelm DC1A",   combo = true, sec = "Third party", cat = "one-knob",
      find = { "dc1a" } },
    { key = "mjuc",       label = "Klanghelm MJUC",   combo = true, sec = "Third party", cat = "vari-mu",
      find = { "mjuc" } },
  }
  local RACK_SECTIONS = { "EON ReaKit", "Stock JS", "Third party" }
  -- Installed-FX registry index, built lazily (EnumInstalledFX; REAPER
  -- 6.37+). nil API = index stays nil = every entry shown, insert-time
  -- fallback carries the risk exactly as before.
  local rack_fx_idx
  local function rack_fx_resolve(st)
    if not st.find then return nil end
    if rack_fx_idx == nil then
      rack_fx_idx = false
      if reaper.EnumInstalledFX then
        rack_fx_idx = {}
        local i = 0
        while true do
          local ok, name, ident = reaper.EnumInstalledFX(i)
          if not ok then break end
          rack_fx_idx[#rack_fx_idx + 1] = {
            name = name or "", ident = ident or "",
            lc = ((name or "") .. "|" .. (ident or "")):lower(),
          }
          i = i + 1
        end
      end
    end
    if not rack_fx_idx then return nil end
    for _, pat in ipairs(st.find) do
      for _, fx in ipairs(rack_fx_idx) do
        if fx.lc:find(pat, 1, true) then return fx end
      end
    end
    return false
  end
  local function rack_available(st)
    if not st.find then return true end          -- adds-based: assumed stock
    if not reaper.EnumInstalledFX then return true end
    return rack_fx_resolve(st) and true or false
  end
  local function rack_stock(key)
    for _, st in ipairs(RACK_STOCKS) do
      if st.key == key then return st end
    end
  end
  local function rack_sel_load(slot, default_kind)
    local v = reaper.GetExtState("EON_Swing", "rack_comp_" .. slot)
    if v == "weld" or v == "anvil" then return { kind = v } end
    local st = v:match("^stock:(.+)$")
    if st and rack_stock(st) then return { kind = "stock", stock = st } end
    local ch = v:match("^chain:(.+)$")
    if ch then return { kind = "chain", chain = ch } end
    return { kind = default_kind }
  end
  local function rack_sel_save(slot, sel)
    local v = sel.kind == "chain" and ("chain:" .. (sel.chain or ""))
           or sel.kind == "stock" and ("stock:" .. (sel.stock or ""))
           or sel.kind
    reaper.SetExtState("EON_Swing", "rack_comp_" .. slot, v, true)
  end
  local function rack_sel_name(sel)
    if sel.kind == "stock" then
      local st = rack_stock(sel.stock or "")
      return (st and st.label or "stock JS") .. " (stock JS)"
    end
    return sel.kind == "anvil" and "EON Anvil"
        or sel.kind == "chain" and ("FX chain: " .. (sel.chain or "?"))
        or "EON Weld"
  end
  local function rack_list_chains()
    -- resource/FXChains, recursive to depth 3, capped: the picker is a
    -- convenience, not a file manager.
    local out = {}
    local root = reaper.GetResourcePath() .. _sep .. "FXChains"
    local function walk(dir, rel, depth)
      if depth > 3 or #out >= 60 then return end
      local i = 0
      while true do
        local fn = reaper.EnumerateFiles(dir, i)
        if not fn then break end
        if fn:lower():sub(-9) == ".rfxchain" then
          out[#out + 1] = (rel == "" and fn or rel .. _sep .. fn)
        end
        i = i + 1
      end
      i = 0
      while true do
        local dn = reaper.EnumerateSubdirectories(dir, i)
        if not dn then break end
        walk(dir .. _sep .. dn, rel == "" and dn or rel .. _sep .. dn, depth + 1)
        i = i + 1
      end
    end
    walk(root, "", 0)
    table.sort(out, function(a, b) return a:lower() < b:lower() end)
    return out
  end
  local function rack_chain_desc(rel)
    -- First few FX names out of the chain chunk, for the picker subtitle.
    local f = io.open(reaper.GetResourcePath() .. _sep .. "FXChains" .. _sep .. rel, "rb")
    if not f then return "" end
    local frag = f:read(32768) or ""
    f:close()
    local names, extra = {}, false
    local function take(nm)
      if #names >= 3 then extra = true return end
      names[#names + 1] = nm
    end
    -- Both loops copy their control variable before trimming it: from Lua 5.5 a
    -- for control variable is const, and assigning to one is a load-time error
    -- rather than a wrong answer at runtime.
    for raw_nm in frag:gmatch('<VST%s+"[^:"]*:%s*([^"(]+)') do
      local nm = raw_nm:gsub("%s+$", "")
      if nm ~= "" then take(nm) end
    end
    for raw_nm in frag:gmatch('<JS%s+([^%s>]+)') do
      local nm = raw_nm:match("([^/\\]+)$") or raw_nm
      nm = nm:gsub("%.[jJ][sS][fF][xX]$", "")
      take(nm)
    end
    -- one line that always fits the dialog: 3 names max, hard char cap
    local out = table.concat(names, " > ")
    if #out > 58 then out = out:sub(1, 55) .. "..."
    elseif extra then out = out .. "  +more" end
    return out
  end
  local function rack_chain_insert(tr, rel)
    local cpath = reaper.GetResourcePath() .. _sep .. "FXChains" .. _sep .. rel
    local f = io.open(cpath, "rb")
    if not f then return false end
    local frag = f:read("*a") or ""
    f:close()
    if frag == "" then return false end
    -- Native path first: modern REAPER accepts .RfxChain files in AddByName.
    local before = reaper.TrackFX_GetCount(tr)
    local fxi = reaper.TrackFX_AddByName(tr, cpath, false, 1)
    if fxi < 0 then fxi = reaper.TrackFX_AddByName(tr, rel, false, 1) end
    if reaper.TrackFX_GetCount(tr) > before then return true end
    -- Chunk splice, FRESH tracks only (no <FXCHAIN> yet): the returns we just
    -- built. A track that already has a chain gets no blind bracket surgery.
    local ok, chunk = reaper.GetTrackStateChunk(tr, "", false)
    if not ok or chunk:find("<FXCHAIN") then return false end
    local nl = string.char(10)
    if frag:sub(-1) ~= nl then frag = frag .. nl end
    local body = "<FXCHAIN" .. nl .. "WNDRECT 0 0 0 0" .. nl .. "SHOW 0" .. nl ..
                 "LASTSEL 0" .. nl .. "DOCKED 0" .. nl .. frag .. ">" .. nl
    local tail = chunk:match("()>%s*$")
    if not tail then return false end
    return reaper.SetTrackStateChunk(tr, chunk:sub(1, tail - 1) .. body .. ">" .. nl, false)
  end
  local function ensure_rack_comp(tr, sel, weld_defaults)
    if not tr then return end
    sel = sel or { kind = "weld" }
    if sel.kind == "chain" and sel.chain and sel.chain ~= "" then
      local _, mark = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_RACK_COMP", "", false)
      if mark == "chain:" .. sel.chain then return end   -- rebuild: already in
      if rack_chain_insert(tr, sel.chain) then
        reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_RACK_COMP", "chain:" .. sel.chain, true)
        return
      end
      reaper.ShowConsoleMsg("[Swing] FX chain '" .. tostring(sel.chain) ..
        "' could not be inserted -- using EON Weld instead" .. string.char(10))
      ensure_eon76(tr, weld_defaults)
      return
    end
    if sel.kind == "stock" then
      local st = rack_stock(sel.stock or "")
      if st then
        local _, mark = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_RACK_COMP", "", false)
        if mark == "stock:" .. st.key then return end   -- rebuild: already in
        local before = reaper.TrackFX_GetCount(tr)
        local tries = {}
        local hit = rack_fx_resolve(st)
        if hit then
          tries[#tries + 1] = hit.name
          tries[#tries + 1] = hit.ident
        end
        for _, nm in ipairs(st.adds or {}) do tries[#tries + 1] = nm end
        for _, nm in ipairs(tries) do
          reaper.TrackFX_AddByName(tr, nm, false, 1)
          if reaper.TrackFX_GetCount(tr) > before then break end
        end
        if reaper.TrackFX_GetCount(tr) > before then
          reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_RACK_COMP", "stock:" .. st.key, true)
          return
        end
      end
      reaper.ShowConsoleMsg("[Swing] stock JS comp '" .. tostring(sel.stock) ..
        "' not found -- using EON Weld" .. string.char(10))
      ensure_eon76(tr, weld_defaults)
      return
    end
    if sel.kind == "anvil" then
      local name = core.jsfx_addname("EON_Anvil.jsfx", swing_track, swing_fx)
      if name then
        if reaper.TrackFX_AddByName(tr, name, false, 0) >= 0 then return end
        if reaper.TrackFX_AddByName(tr, name, false, 1) >= 0 then
          -- Anvil keeps its own ear-tuned defaults: no param pushing here.
          core.fx_embed_mcp(tr, "EON_Anvil")
          return
        end
      end
      reaper.ShowConsoleMsg("[Swing] EON_Anvil.jsfx not found -- using EON Weld" .. string.char(10))
    end
    ensure_eon76(tr, weld_defaults)
  end
  -- want_returns is decided after the Rebuild/Update dialog (creation paths
  -- only) and travels as proceed_build's parameter — see the async seam below.

  -- Set/clear the JSFX fx_returns flag by NAME (slider index mapping is fragile;
  -- resolve via TrackFX_GetParamName like the StepSeq pairing does). slider24
  -- is 0..1 step 1, so normalized 1.0/0.0 maps straight to the value.
  local function set_fx_returns(on)
    if not swing_fx then return end
    local np = reaper.TrackFX_GetNumParams(swing_track, swing_fx)
    local p = 0
    while p < np do
      local _, pn = reaper.TrackFX_GetParamName(swing_track, swing_fx, p, "")
      if pn and pn:find("FX Returns") then
        reaper.TrackFX_SetParamNormalized(swing_track, swing_fx, p, on and 1.0 or 0.0)
        return
      end
      p = p + 1
    end
  end

  -- Check if multi-out tracks already exist (look for sends from Swing track)
  local existing_sends = reaper.GetTrackNumSends(swing_track, 0)
  if existing_sends >= 16 then
    -- Collect existing send destination tracks keyed by PAD, not by raw channel:
    -- a send the user switched to mono carries a width code in I_SRCCHAN, so a
    -- raw key would be stored as 1030 and looked up below as 6, and that pad
    -- would silently be treated as having no existing track.
    local send_dest = {}
    for s = 0, existing_sends - 1 do
      local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
      local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
      if dest_tr and pad >= 0 then send_dest[pad] = dest_tr end
    end

    -- YES = Rebuild (delete + recreate), NO = Update (rename + recolor in place)
    local choice = reaper.ShowMessageBox(
      "Multi-out tracks already exist (" .. existing_sends .. " sends).\n\n" ..
      "YES = Rebuild (delete old tracks, create fresh)\n" ..
      "NO = Update (keep tracks, refresh names & colors)",
      SCRIPT_NAME, 3  -- Yes/No/Cancel → 6=Yes, 7=No, 2=Cancel
    )

    if choice == 7 then
      -- UPDATE: refresh names and colors on existing send destinations
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)
      local updated = 0
      local _bwt = bridge_lane_policy(swing_track)  -- write_tracks: gate lane paint
      for i = 0, G.NUM_PADS - 1 do
        local dest_tr = send_dest[i]
        if dest_tr then
          reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", make_track_name(i), true)
          _lane_rename_touch()
          if _bwt and core.pad_has_audio(i) then
            local s = reaper.gmem_read(G.GS_COL_EFFECTIVE_S)
            local l = reaper.gmem_read(G.GS_COL_EFFECTIVE_L)
            if l <= 0 then s = 0.75; l = 0.55 end
            local r, g, b = hsl_to_rgb(pad_hues[i], s, l)
            local color = reaper.ColorToNative(r, g, b) | 0x1000000
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", color)
          elseif _bwt then
            -- Empty pad → remove custom color (REAPER default)
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", 0)
          end
          -- P2 — kit-driven track icon (same resolver the MIDI lanes use).
          bridge_apply_icon(dest_tr, i, pad_names[i])
          updated = updated + 1
        end
      end
      update_folder_track_name(swing_track)
      -- Ensure the JSFX-hosting track is named "Swing"
      reaper.GetSetMediaTrackInfo_String(swing_track, "P_NAME", "Swing", true)
      -- Normalise folder depths in case the existing layout drifted (older
      -- builds may have used the legacy -2 close that ejected the DM folder).
      if folder_layout then folder_layout.EnsureSwingParentLayout(swing_track) end
      reaper.PreventUIRefresh(-1)
      reaper.TrackList_AdjustWindows(false)
      reaper.Undo_EndBlock("Swing: Update multi-out track names & colors", -1)
      reaper.gmem_write(G.CMD, 99)

      local summary = "Updated " .. updated .. " multi-out tracks:\n\n"
      for i = 0, G.NUM_PADS - 1 do
        summary = summary .. string.format("  Ch %02d → %s\n", i + 1, make_track_name(i))
      end
      eon_notice(summary)
      done(true)
      return

    elseif choice == 6 then
      -- REBUILD: delete old destination tracks and sends, then fall through to create new
      reaper.Undo_BeginBlock()
      reaper.PreventUIRefresh(1)
      -- Remove sends first (reverse order)
      for s = existing_sends - 1, 0, -1 do
        reaper.RemoveTrackSend(swing_track, 0, s)
      end
      -- Delete destination tracks (sort by index descending to avoid shift)
      local tracks_to_delete = {}
      for _, tr in pairs(send_dest) do
        tracks_to_delete[#tracks_to_delete + 1] = tr
      end
      table.sort(tracks_to_delete, function(a, b)
        return reaper.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") >
               reaper.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
      end)
      for _, tr in ipairs(tracks_to_delete) do
        reaper.DeleteTrack(tr)
      end
      reaper.PreventUIRefresh(-1)
      reaper.Undo_EndBlock("Swing: Remove old multi-out tracks", -1)
      -- Fall through to create new tracks below

    else
      -- Cancel / closed dialog
      reaper.gmem_write(G.CMD, 98)
      done(false)
      return
    end
  end

  -- Decide FX returns now — only the creation paths (fresh build or Rebuild)
  -- reach here; Update/Cancel already returned, so we never prompt needlessly.
  -- ⚠️ ASYNC SEAM. The house dialog (eon_dlg) runs on the defer loop and hands
  -- the answer to a callback, so the entire remainder of the build lives in
  -- proceed_build below. While the dialog is up, G.CMD is parked at 97
  -- ("prompt pending"): the dispatcher has no 97 branch and no unknown-else,
  -- so the pending 40/74 cannot re-fire every tick, and the mailbox stays
  -- claimed so no other producer can stage into it. The JSFX side holds
  -- kit_busy until the 98/99 that proceed_build eventually writes — the same
  -- wait it had when the old blocking MessageBox froze the whole bridge,
  -- except the pollers keep ticking now. (97 is registered in
  -- .refs/swing_gmem_bridge_protocol.md next to 98/99.)
  local function proceed_build(want_returns, want_buscomp, want_stepseq, bus_sel, smash_sel)

  bus_sel   = bus_sel   or rack_sel_load("bus",   "weld")
  smash_sel = smash_sel or rack_sel_load("smash", "anvil")

  local swing_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, "IP_TRACKNUMBER")) - 1

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Create parent folder track above Swing (skip if one already exists).
  -- Layout target (names applied by update_folder_track_name):
  --   Swing — <kit>             ← parent folder (instrument + kit)
  --   ├── Swing                  ← the JSFX engine track
  --   ├── Audio                  ← audio multi-out sub-folder
  --   │   └── 16 multi-outs      ← children of the audio sub-folder
  --   └── MIDI                   ← Drum Matrix lane sub-folder (built separately)
  --       └── 16 MIDI lanes
  local existing_folder = find_folder_track(swing_track)
  if not existing_folder then
    reaper.InsertTrackAtIndex(swing_idx, true)
    local folder_tr = reaper.GetTrack(0, swing_idx)
    reaper.SetMediaTrackInfo_Value(folder_tr, "I_FOLDERDEPTH", 1)
    -- Swing track is now at swing_idx + 1
    swing_idx = swing_idx + 1
  end
  -- Ensure the JSFX-hosting track is named "Swing"
  reaper.GetSetMediaTrackInfo_String(swing_track, "P_NAME", "Swing", true)

  -- Find or create the AUDIO sub-folder (immediately after Swing).
  local audio_sub = find_audio_subfolder(swing_track)
  local audio_sub_idx
  if audio_sub then
    audio_sub_idx = math.floor(reaper.GetMediaTrackInfo_Value(audio_sub, "IP_TRACKNUMBER")) - 1
  else
    audio_sub_idx = swing_idx + 1
    reaper.InsertTrackAtIndex(audio_sub_idx, true)
    audio_sub = reaper.GetTrack(0, audio_sub_idx)
    reaper.SetMediaTrackInfo_Value(audio_sub, "I_FOLDERDEPTH", 1)
  end
  -- Tag the audio sub-folder header so folder_layout can identify it
  -- STRUCTURALLY (mirrors the DM folder's P_EXT:EON_DRUM_KIT_FOLDER). Without
  -- this, the layout reorganiser can only spot sub-folders by I_FOLDERDEPTH,
  -- and once interior depths are 0 it can't tell the audio sub from the
  -- adjacent DM sub — they collapse into one folder.
  reaper.GetSetMediaTrackInfo_String(audio_sub, "P_EXT:EON_AUDIO_KIT_FOLDER", "1", true)
  -- Names are applied by update_folder_track_name: parent → "Swing — <kit>",
  -- audio sub → "Audio", DM sub → "MIDI". The kit name rides the PARENT now
  -- (was on the audio sub-folder pre-rename), so the sub-folders stay static.
  update_folder_track_name(swing_track)

  -- EON Lens — kit artwork card on the parent folder (Spec_EON_Lens.md).
  -- Fresh inserts are auto-embedded in TCP+MCP via the CMD-90/91 action
  -- route; an existing Lens is left exactly as the user has it — the embed
  -- actions TOGGLE, so refiring on a Rebuild would un-embed it. "focused"
  -- is re-asserted before each fire so the second toggle cannot land on a
  -- different FX. No FX is inserted after this point in the build.
  do
    local lens_parent = find_folder_track(swing_track)
    if lens_parent then
      local swing_fx = -1
      for f = 0, reaper.TrackFX_GetCount(swing_track) - 1 do
        if is_swing_fx(swing_track, f) then swing_fx = f; break end
      end
      local lfx, laddname = eon_lens_query(lens_parent, swing_track, swing_fx)
      if lfx < 0 and laddname then
        lfx = reaper.TrackFX_AddByName(lens_parent, laddname, false, 1)
        if lfx >= 0 then
          reaper.TrackFX_SetNamedConfigParm(lens_parent, lfx, "focused", "1")
          eon_embed_last_focused(true)   -- TCP
          reaper.TrackFX_SetNamedConfigParm(lens_parent, lfx, "focused", "1")
          eon_embed_last_focused(false)  -- MCP
        end
      end
    end
  end

  -- Create 16 multi-out child tracks INSIDE the audio sub-folder
  local created = {}
  local _bwt = bridge_lane_policy(swing_track)  -- write_tracks: gate lane paint
  for i = 0, G.NUM_PADS - 1 do
    local insert_idx = audio_sub_idx + 1 + i
    reaper.InsertTrackAtIndex(insert_idx, true)
    local tr = reaper.GetTrack(0, insert_idx)
    if not tr then break end

    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", make_track_name(i), true)
    _lane_rename_touch()

    if _bwt and core.pad_has_audio(i) then
      local s = reaper.gmem_read(G.GS_COL_EFFECTIVE_S)
      local l = reaper.gmem_read(G.GS_COL_EFFECTIVE_L)
      if l <= 0 then s = 0.75; l = 0.55 end
      local r, g, b = hsl_to_rgb(pad_hues[i], s, l)
      local color = reaper.ColorToNative(r, g, b) | 0x1000000
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", color)
    elseif _bwt then
      -- Empty pad → no custom color (REAPER default)
      reaper.SetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR", 0)
    end

    -- P2 — kit-driven track icon (same resolver the MIDI lanes use).
    bridge_apply_icon(tr, i, pad_names[i])

    reaper.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", 28)

    local send_idx = reaper.CreateTrackSend(swing_track, tr)
    if send_idx >= 0 then
      reaper.SetTrackSendInfo_Value(swing_track, 0, send_idx, "I_SRCCHAN", i * 2)
      reaper.SetTrackSendInfo_Value(swing_track, 0, send_idx, "I_DSTCHAN", 0)
      reaper.SetTrackSendInfo_Value(swing_track, 0, send_idx, "I_SENDMODE", 0)
    end
    -- P4-2: explicit pad identity on the child — srcchan stops identifying
    -- the pad once the output mirror can retarget sends.
    reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_PAD_IDX", tostring(i), true)

    created[#created + 1] = tr
  end

  -- ── FX return tracks (opt-in) ───────────────────────────────────────────
  -- Two carrier tracks for Swing's already-finished delay/reverb wet, inside
  -- the same Audio sub-folder right after the 16 pads. They receive Swing's
  -- dedicated return pins (verb ch32/33, delay ch34/35). Appended to `created`
  -- so the self-contained folder close below lands on the last return track.
  if want_returns and #created > 0 then
    if reaper.GetMediaTrackInfo_Value(swing_track, "I_NCHAN") < 38 then
      reaper.SetMediaTrackInfo_Value(swing_track, "I_NCHAN", 38)
    end
    local function mk_return(offset, label, tag, srcchan, cat)
      local idx = audio_sub_idx + 1 + G.NUM_PADS + offset
      reaper.InsertTrackAtIndex(idx, true)
      local rtr = reaper.GetTrack(0, idx)
      if not rtr then return end
      reaper.GetSetMediaTrackInfo_String(rtr, "P_NAME", label, true)
      reaper.GetSetMediaTrackInfo_String(rtr, "P_EXT:" .. tag, "1", true)
      reaper.SetMediaTrackInfo_Value(rtr, "I_HEIGHTOVERRIDE", 28)
      -- EON glyph (reverb / delay) — guarded write via rk_lua_icons.apply, which
      -- never stomps a user-set icon; legacy direct write if the module is older.
      if _bridge_icons and cat then
        local icon = (_bridge_icons.resolve and _bridge_icons.resolve(cat)) or ""
        if _bridge_icons.apply then _bridge_icons.apply(rtr, icon)
        else reaper.GetSetMediaTrackInfo_String(rtr, "P_ICON", icon, true) end
      end
      -- Thematic track colour matching the faceplate: verb green, delay orange.
      local cr, cg, cb = 50, 170, 95
      if cat == "delay" then cr, cg, cb = 210, 120, 40 end
      if tag == "EON_SMASH_RETURN" then cr, cg, cb = 190, 70, 60 end
      reaper.SetMediaTrackInfo_Value(rtr, "I_CUSTOMCOLOR", reaper.ColorToNative(cr, cg, cb) | 0x1000000)
      local si = reaper.CreateTrackSend(swing_track, rtr)
      if si >= 0 then
        reaper.SetTrackSendInfo_Value(swing_track, 0, si, "I_SRCCHAN", srcchan)
        reaper.SetTrackSendInfo_Value(swing_track, 0, si, "I_DSTCHAN", 0)
        reaper.SetTrackSendInfo_Value(swing_track, 0, si, "I_SENDMODE", 0)
      end
      created[#created + 1] = rtr
      return rtr
    end
    mk_return(0, "EON Verb Return",  "EON_VERB_RETURN",  32, "reverb")
    mk_return(1, "EON Delay Return", "EON_DELAY_RETURN", 34, "delay")
    local smash_rtr = mk_return(2, "EON Smash Return", "EON_SMASH_RETURN", 36, "fx")
    -- The smasher itself — integral to the smash return (the return is just a
    -- dry copy without it). Fresh-insert defaults = crushed parallel settings.
    ensure_rack_comp(smash_rtr, smash_sel, {
      ["Threshold"] = -25, ["Ratio"] = 10, ["Attack"] = 3,
      ["Release"] = 120, ["Knee"] = 3, ["Makeup"] = 8, ["Mix"] = 1,
    })
  end
  -- Drive the JSFX routing flag to match this build (off → wet stays on Main).
  set_fx_returns(want_returns)

  -- Step sequencer above Swing (opt-in; embedded-first on fresh inserts).
  if want_stepseq then ensure_stepseq() end

  -- Serial glue on the drum submix parent (the separate want_buscomp opt-in;
  -- gentler defaults than the smash-return instance).
  if want_buscomp then
    ensure_rack_comp(audio_sub, bus_sel, {
      ["Threshold"] = -12, ["Ratio"] = 2, ["Attack"] = 10,
      ["Release"] = 200, ["Knee"] = 6, ["Makeup"] = 0, ["Mix"] = 1,
    })
  end

  if #created > 0 then
    reaper.SetMediaTrackInfo_Value(swing_track, "B_MAINSEND", 0)
    -- Self-contained close: the LAST audio child closes the audio sub-folder
    -- (I_FOLDERDEPTH = -1). This makes the layout valid on its own — bare-Swing
    -- (no Drum Matrix → folder_layout nil) gets a properly-closed audio sub
    -- without the reorganiser. folder_layout below then REFINES the multi-sub
    -- arrangement (audio + DM siblings) when present; if it's absent this -1 is
    -- the canonical single-sub close. Was deleted in d417cfa, regressing both
    -- bare-Swing AND (via the depth-only walker) the DM-present case.
    reaper.SetMediaTrackInfo_Value(created[#created], "I_FOLDERDEPTH", -1)
  end

  -- Hand off depth math to the one shared reorganiser. It walks Swing's
  -- parent, identifies all sub-folders (audio + any existing EON DM +
  -- future Sedan), and sets depths to the canonical pattern: last child
  -- of every non-final sub-folder closes that sub (-1); last child of
  -- the final sub-folder closes BOTH the sub AND the parent (-2). Means
  -- this build path doesn't need to know whether the Drum Matrix folder
  -- already exists alongside — the reorganiser figures it out.
  if folder_layout then folder_layout.EnsureSwingParentLayout(swing_track) end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Swing: Build " .. #created .. " multi-out tracks", -1)

  reaper.gmem_write(G.CMD, 99)

  local summary = "Multi-out routing created!\n\n"
  for i = 0, math.min(#created - 1, 15) do
    summary = summary .. string.format("  Ch %02d → %s\n", i + 1, pad_names[i])
  end
  if want_returns then
    summary = summary .. "\n  + EON Verb Return  (ch 33/34)\n  + EON Delay Return (ch 35/36)\n"
    summary = summary .. "  + EON Smash Return (ch 37/38 -> " .. rack_sel_name(smash_sel) .. ")\n"
  end
  if want_buscomp then
    summary = summary .. "  + " .. rack_sel_name(bus_sel) .. " on the Audio bus\n"
  end
  if want_stepseq then
    summary = summary .. "  + EON StepSeq above Swing (embedded)\n"
  end
  summary = summary .. "\nSwing master send muted (audio routes through child tracks)."
  -- Styled + ASYNC. The old ShowMessageBox froze the WHOLE bridge (pollers,
  -- kit loads, companion ticks) until OK was clicked -- right after a build,
  -- which is exactly when the strip-sync work needs the bridge ticking.
  -- (Was a bespoke eon_dlg.open block; M.info is that exact shape now.)
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.info and eon_dlg.info({
    title = SCRIPT_NAME, message = summary,
  })
  if not shown then reaper.ShowMessageBox(summary, SCRIPT_NAME, 0) end
  done(true)
  end  -- proceed_build

  -- The decision itself. Programmatic and preserve paths stay synchronous;
  -- only the genuine question goes through the house dialog. Its two buttons
  -- are two REAL choices — "Keep on Main" is a valid outcome, not an abort —
  -- and dismissing the window (X / Escape) lands on keep-on-main, the
  -- current-behavior default.
  if opts and opts.fx_returns ~= nil then
    proceed_build(opts.fx_returns and true or false, have_buscomp, have_stepseq)
  elseif have_verb or have_delay or have_smash or have_buscomp then
    -- Preserve existing opt-ins across a Rebuild (returns, bus comp; StepSeq
    -- rides along as-is). ⚠️ have_stepseq must NOT trigger this branch — a
    -- StepSeq can exist for reasons that aren't a prior build opt-in (the
    -- Steppa-open toggle, the song builder inserting it BEFORE firing this
    -- build), and treating it as evidence silently skipped the dialog and
    -- built without returns or the EON Weld.
    proceed_build(have_verb or have_delay or have_smash, have_buscomp, have_stepseq)
  else
    -- The comp picker: per slot, two cards (Weld / Anvil, pictures when the
    -- shipped card PNGs exist beside the JSFX icons) or one of the user's own
    -- FX chains. Draws with the dialog module's preflighted widgets only;
    -- image calls are pcall'd so an old ReaImGui degrades to text cards.
    local rk_sel = { bus = rack_sel_load("bus", "weld"), smash = rack_sel_load("smash", "anvil") }
    local RACK_ORDER_BUS   = { "weld", "anvil", "majortom", "fairlychildish", "eventhorizon" }
    local RACK_ORDER_SMASH = { "anvil", "weld", "eventhorizon", "majortom", "fairlychildish" }
    local rk_chains = rack_list_chains()
    local rk_img, rk_img_base = {}, nil
    -- VECTOR-FIRST, EVERYWHERE (direction locked 2026-08-25): the shipped
    -- drawn deck (.fxcards SVG masters -> icons PNGs) is the face of every
    -- entry. A user's captured screenshot is an OPT-IN override ("prefer my
    -- screenshots"), except the five card-row identities, whose designed
    -- cards are product identity and always win.
    local RK_DESIGNED = { weld = true, anvil = true, majortom = true,
                          fairlychildish = true, eventhorizon = true }
    local rk_prefer_shots = reaper.GetExtState("EON_Swing", "rack_prefer_shots") == "1"
    local function rk_thumb_dir()
      return reaper.GetResourcePath() .. _sep .. "EON" .. _sep .. "FXCards"
    end
    local function rk_card_img(ctx, kind)
      local im = rk_img[kind]
      -- ReaImGui destroys image objects that are neither attached to a
      -- context nor drawn every frame (combo rows scrolled out of view
      -- qualify), and a cached dead handle then raises "expected a valid
      -- ImGui_Image*" on every later draw -- the console flood seen live
      -- 2026-08-25. Attach pins new images to the context; the validate
      -- below rescues any entry that died anyway by recreating it.
      if im and reaper.ImGui_ValidatePtr
         and not reaper.ImGui_ValidatePtr(im, 'ImGui_Image*') then
        rk_img[kind] = nil
        im = nil
      end
      if im == nil then
        if rk_img_base == nil then
          local _, wabs = core.jsfx_addname("EON_Weld.jsfx", swing_track, swing_fx)
          rk_img_base = (wabs and wabs:match("^(.*[/\\])")) or false
        end
        rk_img[kind] = false
        -- CreateImage defers the file load to render time, so a missing
        -- PNG errors INSIDE the dialog's frame, past any pcall here
        -- (seen live 2026-08-25). Only files proven present become images.
        local shipped = rk_img_base
          and (rk_img_base .. "icons" .. _sep .. "card_" .. kind .. ".png") or nil
        local shot = rk_thumb_dir() .. _sep .. kind .. ".png"
        local tries = {}
        if RK_DESIGNED[kind] then
          tries[#tries + 1] = shipped
        elseif rk_prefer_shots then
          tries[#tries + 1] = shot
          tries[#tries + 1] = shipped
        else
          tries[#tries + 1] = shipped
          tries[#tries + 1] = shot   -- fallback only where no card ships
        end
        for _, fp in ipairs(tries) do
          local fh = io.open(fp, "rb")
          if fh then
            fh:close()
            local ok, created = pcall(reaper.ImGui_CreateImage, fp)
            if ok and created then
              if reaper.ImGui_Attach then pcall(reaper.ImGui_Attach, ctx, created) end
              rk_img[kind] = created
              break
            end
          end
        end
      end
      return rk_img[kind]
    end
    -- ── The capture rig: photograph each installed menu comp for real.
    -- Extension does the one impossible part (EON_CaptureFXFloat = window
    -- pixels -> PNG); this rig does the choreography: scratch muted track,
    -- insert, float, wait for paint, shoot, tear down, next. The floated
    -- FX windows flash on screen briefly -- that is the trick working.
    local rk_capq, rk_cap_busy = {}, false
    local function rk_capture_next()
      local st = table.remove(rk_capq, 1)
      if not st then
        rk_cap_busy = false
        rk_img = {}          -- drop the image cache so new shots load
        return
      end
      local idx = reaper.CountTracks(0)
      reaper.InsertTrackAtIndex(idx, false)
      local tr = reaper.GetTrack(0, idx)
      if not tr then rk_cap_busy = false return end
      reaper.SetMediaTrackInfo_Value(tr, "B_MUTE", 1)
      reaper.SetMediaTrackInfo_Value(tr, "D_VOL", 0)
      local tries = {}
      local hit = rack_fx_resolve(st)
      if hit then
        tries[#tries + 1] = hit.name
        tries[#tries + 1] = hit.ident
      end
      for _, nm in ipairs(st.adds or {}) do tries[#tries + 1] = nm end
      local got = -1
      for _, nm in ipairs(tries) do
        got = reaper.TrackFX_AddByName(tr, nm, false, 1)
        if got >= 0 then break end
      end
      if got < 0 then
        reaper.DeleteTrack(tr)
        return reaper.defer(rk_capture_next)
      end
      reaper.TrackFX_Show(tr, got, 3)          -- float it so it can paint
      local frames = 0
      local function wait()
        frames = frames + 1
        if frames < 15 then return reaper.defer(wait) end
        local dirp = rk_thumb_dir()
        reaper.RecursiveCreateDirectory(dirp, 0)
        local okc = reaper.EON_CaptureFXFloat(tr, got, dirp .. _sep .. st.key .. ".png", 264)
        reaper.TrackFX_Show(tr, got, 2)
        reaper.DeleteTrack(tr)
        if not okc then
          reaper.ShowConsoleMsg("[Swing] thumb capture failed: " .. st.label .. string.char(10))
        end
        reaper.defer(rk_capture_next)
      end
      reaper.defer(wait)
    end
    local function rk_capture_all()
      if rk_cap_busy or not reaper.EON_CaptureFXFloat then return end
      rk_cap_busy = true
      rk_capq = {}
      for _, st in ipairs(RACK_STOCKS) do
        if st.combo and rack_available(st) then rk_capq[#rk_capq + 1] = st end
      end
      reaper.defer(rk_capture_next)
    end
    local function rk_row(ctx, slot, order)
      local sel = rk_sel[slot]
      -- five cards across the row: image above (when its PNG shipped),
      -- button below. Absolute SameLine offsets keep the two lines aligned.
      local CW, CPITCH = 124, 131
      local any_img = false
      for _, k in ipairs(order) do
        if rk_card_img(ctx, k) then any_img = true break end
      end
      if any_img then
        for i, k in ipairs(order) do
          if i > 1 then reaper.ImGui_SameLine(ctx, 8 + (i - 1) * CPITCH) end
          local img = rk_card_img(ctx, k)
          if img then pcall(reaper.ImGui_Image, ctx, img, CW, 58)
          else reaper.ImGui_Dummy(ctx, CW, 58) end
        end
      end
      local function pk(r_, g_, b_)
        return math.floor(math.min(1, r_) * 255) * 16777216 +
               math.floor(math.min(1, g_) * 255) * 65536 +
               math.floor(math.min(1, b_) * 255) * 256 + 255
      end
      for i, kind in ipairs(order) do
        if i > 1 then reaper.ImGui_SameLine(ctx, 8 + (i - 1) * CPITCH) end
        local st = rack_stock(kind)
        local nm = kind == "weld" and "EON Weld"
                or kind == "anvil" and "EON Anvil"
                or (st and st.label or kind)
        local selp = (sel.kind == kind) or (sel.kind == "stock" and sel.stock == kind)
        local lbl = selp and ("[ " .. nm .. " ]") or nm
        if selp then
          -- the picked card breathes in its identity colour: steel blue
          -- Weld, forge amber Anvil, moss green stock. ImGui redraws every
          -- defer frame, so time IS the animation.
          local pulse = 0.86 + 0.22 * (0.5 + 0.5 * math.sin(reaper.time_precise() * 4.5))
          local cr, cg, cb
          if kind == "weld" then cr, cg, cb = 0.16, 0.40, 0.68
          elseif kind == "anvil" then cr, cg, cb = 0.74, 0.34, 0.10
          else cr, cg, cb = 0.20, 0.50, 0.28 end
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        pk(cr * pulse, cg * pulse, cb * pulse))
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), pk(cr * 1.25, cg * 1.25, cb * 1.25))
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  pk(cr, cg, cb))
        end
        if reaper.ImGui_Button(ctx, lbl .. "##" .. slot .. kind, CW, 0) then
          if st then
            sel.kind = "stock"
            sel.stock = kind
          else
            sel.kind = kind
            sel.stock = nil
          end
          sel.chain = nil
        end
        if selp then reaper.ImGui_PopStyleColor(ctx, 3) end
      end
      reaper.ImGui_SetNextItemWidth(ctx, -1)
      -- the deep bench: grouped menu of the stock JS roster + user chains.
      -- A pick from here owns the slot (cards mute); a card click takes it
      -- back. Preview line always names the current combo pick.
      local combo_stock = sel.kind == "stock" and rack_stock(sel.stock or "")
      if combo_stock and not combo_stock.combo then combo_stock = nil end
      local cur = (sel.kind == "chain" and sel.chain)
               or (combo_stock and (combo_stock.label .. "   (" .. (combo_stock.sec or "?") .. ")"))
               or "more comps + your FX chains..."
      -- HeightLargest = the popup takes all the screen room it can and
      -- scrolls past that, so the whole catalogue is reachable in one look
      local cflags = (reaper.ImGui_ComboFlags_HeightLargest and reaper.ImGui_ComboFlags_HeightLargest()) or 0
      if reaper.ImGui_BeginCombo(ctx, "##chain" .. slot, cur, cflags) then
        if reaper.ImGui_Selectable(ctx, "(use the cards above)##" .. slot,
                                   sel.kind ~= "chain" and not combo_stock) then
          if sel.kind == "chain" or combo_stock then
            sel.kind = (slot == "bus") and "weld" or "anvil"
            sel.chain = nil
            sel.stock = nil
          end
        end
        -- one collapsible branch per category, collapsed by default so the
        -- menu opens compact instead of eating the screen (user call
        -- 2026-08-25); the branch holding the current pick opens itself.
        -- Old ReaImGui without TreeNode degrades to the flat headers.
        local has_tree = reaper.ImGui_TreeNode and reaper.ImGui_TreePop
        local function rk_stock_row(st)
          local timg = rk_card_img(ctx, st.key)
          if timg then
            pcall(reaper.ImGui_Image, ctx, timg, 72, 34)
            reaper.ImGui_SameLine(ctx, 0, 8)
          end
          local row = st.label .. "    -  " .. (st.cat or "")
          if reaper.ImGui_Selectable(ctx, row .. "##s" .. slot .. st.key,
                                     sel.kind == "stock" and sel.stock == st.key) then
            sel.kind = "stock"
            sel.stock = st.key
            sel.chain = nil
            sel.desc = nil
          end
        end
        for _, secname in ipairs(RACK_SECTIONS) do
          local rows = {}
          local holds_pick = false
          for _, st in ipairs(RACK_STOCKS) do
            if st.combo and st.sec == secname and rack_available(st) then
              rows[#rows + 1] = st
              if sel.kind == "stock" and sel.stock == st.key then holds_pick = true end
            end
          end
          if #rows > 0 then
            if has_tree then
              local fl = 0
              if holds_pick and reaper.ImGui_TreeNodeFlags_DefaultOpen then
                fl = reaper.ImGui_TreeNodeFlags_DefaultOpen()
              end
              if reaper.ImGui_TreeNode(ctx,
                   secname .. "  (" .. #rows .. ")##sec" .. slot .. secname, fl) then
                for _, st in ipairs(rows) do rk_stock_row(st) end
                reaper.ImGui_TreePop(ctx)
              end
            else
              reaper.ImGui_Text(ctx, "-- " .. secname .. " --")
              for _, st in ipairs(rows) do rk_stock_row(st) end
            end
          end
        end
        local function rk_chain_row(ci, rel)
          local cimg = rk_card_img(ctx, "chain")
          if cimg then
            pcall(reaper.ImGui_Image, ctx, cimg, 72, 34)
            reaper.ImGui_SameLine(ctx, 0, 8)
          end
          if reaper.ImGui_Selectable(ctx, rel .. "##c" .. slot .. ci,
                                     sel.kind == "chain" and sel.chain == rel) then
            sel.kind = "chain"
            sel.chain = rel
            sel.desc = nil
          end
        end
        if #rk_chains > 0 then
          if has_tree then
            local fl = 0
            if sel.kind == "chain" and reaper.ImGui_TreeNodeFlags_DefaultOpen then
              fl = reaper.ImGui_TreeNodeFlags_DefaultOpen()
            end
            if reaper.ImGui_TreeNode(ctx,
                 "your FX chains  (" .. #rk_chains .. ")##secchains" .. slot, fl) then
              for ci, rel in ipairs(rk_chains) do rk_chain_row(ci, rel) end
              reaper.ImGui_TreePop(ctx)
            end
          else
            reaper.ImGui_Text(ctx, "-- your FX chains --")
            for ci, rel in ipairs(rk_chains) do rk_chain_row(ci, rel) end
          end
        end
        reaper.ImGui_EndCombo(ctx)
      end
      -- an active menu pick is never just a line of text: show its card,
      -- same size as the card row above, so the choice reads as a card
      if combo_stock then
        -- combo_stock is THIS frame's resolve; a click in the combo above can
        -- have just nil'd sel.stock ("use the cards above"), so key off the
        -- resolved entry, never sel.stock (table-index-is-nil, seen 2026-08-25)
        local simg = rk_card_img(ctx, combo_stock.key)
        if simg then
          pcall(reaper.ImGui_Image, ctx, simg, 124, 58)
          reaper.ImGui_SameLine(ctx, 0, 10)
        end
        reaper.ImGui_Text(ctx, "[ " .. combo_stock.label .. " ]   " .. (combo_stock.cat or ""))
      elseif sel.kind == "chain" and sel.chain then
        local simg = rk_card_img(ctx, "chain")
        if simg then
          pcall(reaper.ImGui_Image, ctx, simg, 124, 58)
          reaper.ImGui_SameLine(ctx, 0, 10)
        end
        if sel.desc == nil then sel.desc = rack_chain_desc(sel.chain) end
        reaper.ImGui_Text(ctx, "[ " .. sel.chain .. " ]" ..
          (sel.desc ~= "" and ("   " .. sel.desc) or ""))
      end
    end
    local shown = eon_dlg and eon_dlg.available() and eon_dlg.open and eon_dlg.open({
      title = "Drum Bus Options", width = 680,
      ok_label = "Build", cancel_label = "Skip",
      fields = {
        { key = "opts", label = "Add", kind = "checks",
          sub = "returns = Verb / Delay / Smash tracks; the comps below choose what lands where",
          items = {
            { key = "fx_returns", label = "FX return tracks",  value = true },
            { key = "bus_comp",   label = "Bus compressor",    value = true },
            { key = "step_seq",   label = "Step sequencer",    value = true },
          } },
        { key = "comp_sel", kind = "block", height = 460, value = rk_sel,
          draw = function(ctx)
            reaper.ImGui_Text(ctx, "AUDIO BUS COMP  (serial glue)")
            rk_row(ctx, "bus", RACK_ORDER_BUS)
            reaper.ImGui_Dummy(ctx, 1, 8)
            reaper.ImGui_Text(ctx, "SMASH RETURN COMP  (parallel crush)")
            rk_row(ctx, "smash", RACK_ORDER_SMASH)
            if reaper.EON_CaptureFXFloat then
              reaper.ImGui_Dummy(ctx, 1, 4)
              local chg, v = reaper.ImGui_Checkbox(ctx,
                "prefer my screenshots##rkpref", rk_prefer_shots)
              if chg then
                rk_prefer_shots = v
                reaper.SetExtState("EON_Swing", "rack_prefer_shots", v and "1" or "0", true)
                rk_img = {}
              end
              reaper.ImGui_SameLine(ctx, 0, 16)
              local cap_lbl = rk_cap_busy
                and ("capturing... (" .. tostring(#rk_capq) .. " left)")
                or "Capture my screenshots  (optional override)"
              if reaper.ImGui_Button(ctx, cap_lbl .. "##rkcap", 300, 0) then
                rk_capture_all()
              end
            end
          end },
      },
      on_ok = function(v)
        local ex = v.opts or {}
        rack_sel_save("bus", rk_sel.bus)
        rack_sel_save("smash", rk_sel.smash)
        proceed_build(ex.fx_returns and true or false, ex.bus_comp and true or false,
                      ex.step_seq and true or false, rk_sel.bus, rk_sel.smash)
      end,
      on_cancel = function() proceed_build(false, false, false) end,
    })
    if shown then
      reaper.gmem_write(G.CMD, 97)   -- park the mailbox while the dialog is up
    else
      -- No ReaImGui: two native Yes/No questions, blocking as before.
      local c = reaper.ShowMessageBox(
        "Add FX return tracks?" .. string.char(10,10) ..
        "YES = create EON Verb / Delay / Smash Return tracks and route the wet to them" .. string.char(10) ..
        "NO = keep the wet on the Main bus (current behavior)",
        SCRIPT_NAME, 4)  -- Yes/No -> 6=Yes, 7=No
      local c2 = reaper.ShowMessageBox(
        "Add a bus compressor on the Audio bus?" .. string.char(10) ..
        "(uses the last-picked comp choice; EON Weld by default)",
        SCRIPT_NAME, 4)
      local c3 = reaper.ShowMessageBox(
        "Add the EON step sequencer above Swing?",
        SCRIPT_NAME, 4)
      proceed_build(c == 6, c2 == 6, c3 == 6)
    end
  end
end

-- Run a script from the EON Drum Matrix folder by file name. Shared by CMD 73 /
-- 74 (EON_DM_Build.lua), CMD 75 / 76 (eon_drum_matrix.lua overlay). Since the
-- 2026-07-02 layout cleanup the DM lives in the bridge's OWN tree
-- (.Scripts/EON/Drum Matrix — single tracked dir, the dotless Scripts/ sibling is
-- gone), so try _SCRIPT_DIR-relative FIRST; keep the old dotless-sibling and
-- resource-path bases as legacy fallbacks. All locals are function-scoped, so
-- this adds nothing to the main chunk's ~200-local budget.
local function run_dm_script(fname)
  local sub = "EON" .. core.sep .. "Drum Matrix" .. core.sep .. fname
  local dir = (debug.getinfo(1, "S").source:match("@?(.*)") or ""):match("^(.*)[/\\]") or ""
  local cands = {
    dir .. core.sep .. sub,
    (dir:match("^(.*)[/\\]") or dir) .. core.sep .. "Scripts" .. core.sep .. sub,
    reaper.GetResourcePath() .. core.sep .. "Effects" .. core.sep .. "EON_ReaKit_Bundle"
      .. core.sep .. "installer" .. core.sep .. "src" .. core.sep .. ".Scripts" .. core.sep .. sub,
  }
  local dm_path, df
  for i = 1, #cands do
    df = io.open(cands[i], "r")
    if df then dm_path = cands[i]; break end
  end
  if df then
    df:close()
    local dm_id = reaper.AddRemoveReaScript(true, 0, dm_path, true)
    if dm_id and dm_id > 0 then
      reaper.Main_OnCommand(dm_id, 0)
      -- Left registered: the DM scripts document themselves as user-run
      -- actions (EON_DM_Build's header), so a user registration -- possibly
      -- in the legacy standalone install this resolver still reaches -- is
      -- likely. See AP-4.
    end
  end
end

-- StepSeq SETTINGS commands: open this StepSeq's paired Swing FX window (find the Swing
-- whose registry slot == the requesting slot), and open the Drum Matrix overlay. Module-
-- GLOBAL (200-local ceiling) but defined here so they capture is_swing_fx/ss_resolve_slot/
-- run_dm_script. Hooked into poll() below.
-- EON Hub interop: a float captured into a Hub pane can only be HIDDEN by
-- TrackFX_Show(2) (REAPER can't destroy the reparented child), so
-- GetFloatingWindow alone reads a hidden window as "open" and a toggle
-- sticks on the hide branch forever. Test real visibility via
-- JS_ReaScriptAPI; fall back to the existence check if the API is missing.
function eon_fx_float_visible(tr, fx)
  local hw = reaper.TrackFX_GetFloatingWindow(tr, fx)
  if not hw then return false end
  if reaper.JS_Window_IsVisible then return reaper.JS_Window_IsVisible(hw) end
  return true
end

-- TOGGLE the paired Swing's floating FX window for `slot` (open if closed, close if open).
function eon_toggle_swing_for_slot(slot)
  for tr in core.iter_all_tracks() do
    local nfx = reaper.TrackFX_GetCount(tr)
    local fx = 0
    while fx < nfx do
      if is_swing_fx(tr, fx)
         and ss_resolve_slot(math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)) == slot then
        if eon_fx_float_visible(tr, fx) then
          reaper.TrackFX_Show(tr, fx, 2)
          core.hub_notify("close", "swing", tr, fx)
        else
          reaper.TrackFX_Show(tr, fx, 3)
          core.hub_notify("open", "swing", tr, fx)
        end
        return
      end
      fx = fx + 1
    end
  end
end

function eon_ss_commands_tick()
  local gr, gw = reaper.gmem_read, reaper.gmem_write
  -- Drum Matrix overlay TOGGLE: the overlay refreshes its singleton-lock timestamp each frame
  -- (EON_DRUM_MATRIX_LOCKS:main_overlay); if it's live ask it to close (overlay_close hook),
  -- else launch it. Publish state for the highlight.
  local dm_alive = (reaper.time_precise() -
    (tonumber(reaper.GetExtState('EON_DRUM_MATRIX_LOCKS', 'main_overlay')) or 0)) < 1.0
  local dmreq = math.floor((gr(26046200) or 0) + 0.5)
  if eon_dmopen_last == nil then
    eon_dmopen_last = dmreq
  elseif dmreq ~= eon_dmopen_last then
    eon_dmopen_last = dmreq
    if dmreq > 0 then
      if dm_alive then reaper.SetExtState('EON_DRUM_MATRIX', 'overlay_close', '1', false)
      else run_dm_script("eon_drum_matrix.lua") end
    end
  end
  gw(26046201, dm_alive and 1 or 0)
  -- Open Swing TOGGLE (per-slot SYNC field 38). Baseline on first observation.
  eon_opensw_last = eon_opensw_last or {}
  for slot = 0, 15 do
    local v = math.floor((gr(26030000 + slot * 64 + 38) or 0) + 0.5)
    if eon_opensw_last[slot] == nil then
      eon_opensw_last[slot] = v
    elseif v ~= eon_opensw_last[slot] then
      eon_opensw_last[slot] = v
      if v > 0 then eon_toggle_swing_for_slot(slot) end
    end
  end
  -- Throttled (~5 Hz): publish each slot's Swing-window open state (field 39) for the highlight.
  eon_ss_cmd_cnt = (eon_ss_cmd_cnt or 0) + 1
  if eon_ss_cmd_cnt % 6 == 0 then
    local openset = {}
    for tr in core.iter_all_tracks() do
      local nfx = reaper.TrackFX_GetCount(tr)
      local fx = 0
      while fx < nfx do
        if is_swing_fx(tr, fx) then
          local sl = ss_resolve_slot(math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0))
          if sl and sl >= 0 and sl < 16 and eon_fx_float_visible(tr, fx) then
            openset[sl] = true
          end
        end
        fx = fx + 1
      end
    end
    for slot = 0, 15 do gw(26030000 + slot * 64 + 39, openset[slot] and 1 or 0) end
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- BATCH IMPORT (CMD 20)
-- ═════════════════════════════════════════════════════════════════════════════

function rk_ops.do_batch_import()
  -- Browse for folder
  local folder = nil
  local has_js = reaper.JS_Dialog_BrowseForFolder ~= nil
  if has_js then
    local retval, path = reaper.JS_Dialog_BrowseForFolder("Select sample folder for batch import", core.get_kits_dir())
    if retval == 1 and path ~= "" then folder = path end
  else
    local retval, input = reaper.GetUserInputs("Batch Import", 1, "Folder path:,extrawidth=300", "")
    if retval and input ~= "" then folder = input end
  end

  if not folder then reaper.gmem_write(G.CMD, 98); return end

  -- Enumerate audio files
  local files = {}
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(folder, idx)
    if not fname then break end
    if core.is_native_audio(fname) then
      files[#files + 1] = {
        name = fname,
        path = folder .. core.sep .. fname,
        display = fname:gsub("%.[^.]+$", "")
      }
    end
    idx = idx + 1
  end

  if #files == 0 then
    eon_notice("No audio files found in:\n" .. folder)
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- Sort alphabetically
  table.sort(files, function(a, b) return a.name:lower() < b.name:lower() end)

  -- Limit to 16 pads
  local count = math.min(#files, G.NUM_PADS)

  -- Confirm
  local msg = "Found " .. #files .. " audio files.\n"
  if #files > 16 then msg = msg .. "Only the first 16 will be loaded.\n" end
  msg = msg .. "\nFiles:\n"
  for i = 1, count do
    msg = msg .. "  Pad " .. i .. ": " .. files[i].name .. "\n"
  end
  msg = msg .. "\nLoad these samples?"
  eon_confirm_cmd(msg, "Load",
    function() rk_ops.batch_import_commit(files, count) end,
    function() reaper.gmem_write(G.CMD, 98) end)
end

-- The post-confirm half of do_batch_import, split out rather than nested in a
-- closure so the ~110-line body keeps its original indentation (and its
-- ::next_batch_file:: label keeps working — a goto label is function-scoped).
-- Everything it needs from the caller arrives as an argument; it is not called
-- from anywhere else. Hangs off rk_ops so it costs no top-level local.
function rk_ops.batch_import_commit(files, count)
  -- Acquire one scratch track for the whole batch — placed at the end of
  -- the project so we don't pollute the user's first track. Reused for
  -- every pad's temp item (track stays until release after the loop).
  local scratch_tr = acquire_scratch_track()

  -- Load each file via audio accessor and write to gmem
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  local audio_offset = 0
  for i = 0, count - 1 do
    local file = files[i + 1]
    local source = reaper.PCM_Source_CreateFromFile(file.path)
    if source then
      local sr = reaper.GetMediaSourceSampleRate(source)
      local length = reaper.GetMediaSourceLength(source)
      local nch = ({reaper.GetMediaSourceNumChannels(source)})[1] or 1
      local num_samples = math.floor(length * sr)

      -- Cap at SLOT_SIZE/2 (each mono frame → 2 interleaved) and total gmem capacity
      num_samples = math.min(num_samples, math.floor(G.SLOT_SIZE / 2))
      if num_samples <= 0 then
        -- Zero-length source (see load_audio_to_pad guard): new_array(0)
        -- below is a hard error. Skip this file, keep importing the rest.
        reaper.PCM_Source_Destroy(source)
        goto next_batch_file
      end
      if audio_offset + num_samples * 2 > GMEM_AUDIO_MAX then
        num_samples = math.floor((GMEM_AUDIO_MAX - audio_offset) / 2)
        if num_samples <= 0 then
          reaper.PCM_Source_Destroy(source)
          break
        end
      end

      -- Create a temporary item on the scratch track to get an audio accessor
      if not scratch_tr then break end  -- safety: track creation failed
      local temp_item = reaper.AddMediaItemToTrack(scratch_tr)
      local temp_take = reaper.AddTakeToMediaItem(temp_item)
      reaper.SetMediaItemTake_Source(temp_take, source)
      reaper.SetMediaItemInfo_Value(temp_item, "D_LENGTH", length)

      local aa = reaper.CreateTakeAudioAccessor(temp_take)
      if aa then
        -- Read samples (mono mixdown)
        local chunk_size = math.min(num_samples, 1000000)
        local samples_read = 0
        local start_time = 0.0
        local sample_buf = reaper.new_array(chunk_size * nch)

        while samples_read < num_samples do
          local to_read = math.min(chunk_size, num_samples - samples_read)
          sample_buf.clear()
          reaper.GetAudioAccessorSamples(aa, sr, nch, start_time + samples_read / sr, to_read, sample_buf)

          -- Write to gmem as stereo interleaved (duplicate mono to L+R)
          for j = 0, to_read - 1 do
            local val = 0
            -- Mono source: duplicate; stereo source: preserve L/R; 3+ ch:
            -- take ch0/ch1 and drop the rest (same convention as the
            -- single-file loader above).
            local valL, valR
            if nch == 1 then
              valL = sample_buf[j + 1]
              valR = valL
            else
              valL = sample_buf[j * nch + 1] or 0
              valR = sample_buf[j * nch + 2] or 0
            end
            -- Write L and R (interleaved stereo, matching JSFX playback format)
            local dst = G.AUDIO_BASE + audio_offset + (samples_read + j) * 2
            reaper.gmem_write(dst,     valL)
            reaper.gmem_write(dst + 1, valR)
          end
          samples_read = samples_read + to_read
        end

        reaper.DestroyAudioAccessor(aa)

        -- Write metadata, audio length, and pad name
        local interleaved_len = num_samples * 2
        local _, hue = core.guess_drum_type(file.display)
        write_default_pad_meta(i, interleaved_len, sr, hue, file.display)
        audio_offset = audio_offset + interleaved_len
      end

      -- Clean up temp item (the scratch track itself is released after the loop)
      reaper.DeleteTrackMediaItem(scratch_tr, temp_item)
    end
    ::next_batch_file::   -- zero-length-source skip lands here (end-of-block label)
  end

  reaper.PreventUIRefresh(-1)
  release_scratch_track(scratch_tr)
  -- Was: flag=8 (no undo point) — meant the entire batch-import was
  -- non-undoable. Switched to flag=-1 so the user can Ctrl+Z to revert
  -- a folder import. The scratch-track manipulation is wrapped in
  -- PreventUIRefresh so REAPER doesn't add UI flicker; the chunk diff
  -- captures all the gmem state changes that the JSFX picks up next
  -- frame via CMD 3.
  reaper.Undo_EndBlock("Swing: Batch import", -1)

  -- Clear unused pads
  for i = count, G.NUM_PADS - 1 do
    reaper.gmem_write(G.AUDIOLEN_BASE + i, 0)
    local mb = G.META_BASE + i * G.META_PP
    for j = 0, G.META_PP - 1 do reaper.gmem_write(mb + j, 0) end
  end

  -- Signal JSFX
  reaper.gmem_write(G.CMD, 3)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- CHOP-TO-PADS (CMD 30)
-- ═════════════════════════════════════════════════════════════════════════════

function rk_ops.do_chop_to_pads()
  -- Get selected media item
  local item = reaper.GetSelectedMediaItem(0, 0)
  if not item then
    eon_notice(
      "No media item selected.\n\nSelect an audio item on the timeline, then try again.")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then
    eon_notice("Selected item is not audio.")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  local source = reaper.GetMediaItemTake_Source(take)
  local sr = reaper.GetMediaSourceSampleRate(source)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local nch = ({reaper.GetMediaSourceNumChannels(source)})[1] or 1
  local total_samples = math.floor(item_len * sr)

  -- Ask for number of slices. Dev override: ExtState EON_Bridge/chop_auto="N"
  -- skips the dialog entirely (headless test harness; same pattern as the
  -- pathload dev gate). Cleared after one use so it can't leak into a session.
  local chop_auto = tonumber(reaper.GetExtState("EON_Bridge", "chop_auto"))
  if chop_auto then
    reaper.SetExtState("EON_Bridge", "chop_auto", "", false)
    rk_ops.chop_commit(take, source, sr, nch, total_samples,
                       math.max(2, math.min(16, math.floor(chop_auto))), false)
    return
  end

  -- Styled form. The old prompt asked for "Transient detection (0=equal,
  -- 1=auto)" — a numeric field standing in for a two-way choice because
  -- GetUserInputs has no other control; the form has a real picker, so the
  -- question can be asked in words. Slice count is an int field with its own
  -- 2..16 clamp (applied on accept, not while typing).
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.open and eon_dlg.open({
    title = "Chop to Pads", width = 400, ok_label = "Chop",
    fields = {
      { key = "slices", label = "Number of slices:", kind = "int",
        value = 16, min = 2, max = 16, sub = "2-16, one per pad" },
      { key = "mode", label = "Slice at:", kind = "choice", value = 1,
        choices = { "Equal spacing", "Transients (auto-detect)" } },
    },
    on_ok = function(v)
      rk_ops.chop_commit(take, source, sr, nch, total_samples,
        math.max(2, math.min(16, math.floor(tonumber(v.slices) or 16))),
        (tonumber(v.mode) or 1) == 2)
    end,
    on_cancel = function() reaper.gmem_write(G.CMD, 98) end,
  })
  if shown then
    reaper.gmem_write(G.CMD, 97)   -- park the mailbox while the form is up
    return
  end

  -- Native fallback (no ReaImGui) — unchanged behaviour.
  local retval, input = reaper.GetUserInputs(
    "Chop to Pads", 2,
    "Number of slices (2-16):,Transient detection (0=equal, 1=auto):,extrawidth=180",
    "16,0"
  )
  if not retval then reaper.gmem_write(G.CMD, 98); return end

  local fields = {}
  for field in (input .. ","):gmatch("(.-),") do
    fields[#fields + 1] = field
  end
  rk_ops.chop_commit(take, source, sr, nch, total_samples,
    math.max(2, math.min(16, math.floor(tonumber(fields[1]) or 16))),
    (tonumber(fields[2]) or 0) == 1)
end

-- The post-prompt half of do_chop_to_pads, split out rather than nested in a
-- closure so the ~230-line body keeps its original indentation. Everything it
-- needs arrives as an argument (item/item_len are NOT used past this point);
-- not called from anywhere else. On rk_ops so it costs no top-level local.
function rk_ops.chop_commit(take, source, sr, nch, total_samples,
                            num_slices, use_transients)
  -- Create audio accessor
  local aa = reaper.CreateTakeAudioAccessor(take)
  if not aa then
    eon_notice("Could not create audio accessor.")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- Cap total samples to prevent runaway memory allocation
  local MAX_CHOP_SAMPLES = 12000000
  if total_samples > MAX_CHOP_SAMPLES then total_samples = MAX_CHOP_SAMPLES end

  -- Zero-length guard: new_array(0) is a HARD ERROR that kills the whole
  -- bridge (same trap load_audio_to_pad documents at its own read).
  if total_samples <= 0 then
    reaper.DestroyAudioAccessor(aa)
    eon_notice("Selected item has no audio to chop.")
    reaper.gmem_write(G.CMD, 98)
    return
  end

  -- ⭐ Read in CHUNKS, mixing to mono as we go.
  -- This used to allocate the ENTIRE item in one go —
  -- `reaper.new_array(total_samples * nch)` — which fails outright with
  -- "bad argument #1 to 'new_array' (invalid size)" on any reasonably long
  -- selection: the cap above bounds FRAMES, but the array asked for is
  -- frames × channels, and a reaper.array has its own hard ceiling far below
  -- 12M×2. So chop was broken for long items and nobody had hit it.
  -- Every OTHER accessor reader in this file already chunks at 1M frames
  -- (load_audio_to_pad, the layer variants, batch import); chop was the lone
  -- outlier. Chunking also caps peak memory at one chunk instead of the whole
  -- item, and `mono` stays a plain Lua table, which has no such ceiling.
  local CHUNK = math.min(total_samples, 1000000)
  local buf = reaper.new_array(CHUNK * nch)
  local mono = {}
  local read_frames = 0
  while read_frames < total_samples do
    local to_read = math.min(CHUNK, total_samples - read_frames)
    buf.clear()
    -- 4th arg is a TIME in seconds, not a frame index (same call shape the
    -- chunked readers above use).
    reaper.GetAudioAccessorSamples(aa, sr, nch, read_frames / sr, to_read, buf)
    for j = 0, to_read - 1 do
      if nch == 1 then
        mono[read_frames + j] = buf[j + 1]
      else
        local sum = 0
        for ch = 0, nch - 1 do
          sum = sum + (buf[j * nch + ch + 1] or 0)
        end
        mono[read_frames + j] = sum / nch
      end
    end
    read_frames = read_frames + to_read
  end

  reaper.DestroyAudioAccessor(aa)

  -- Compute slice points
  local slice_points = {}
  if use_transients and num_slices <= 16 then
    -- Energy-based transient detection
    local window = math.floor(sr * 0.01)  -- 10ms window
    local hop = math.floor(window / 2)
    local energies = {}
    local max_energy = 0

    for pos = 0, total_samples - window, hop do
      local sum = 0
      for k = pos, pos + window - 1 do
        local s = mono[k] or 0
        sum = sum + s * s
      end
      local e = sum / window
      energies[#energies + 1] = {pos = pos, energy = e}
      if e > max_energy then max_energy = e end
    end

    -- Find peaks in energy derivative (onsets)
    local onsets = {0}  -- always start at 0
    local threshold = max_energy * 0.05
    local min_gap = math.floor(sr * 0.05)  -- min 50ms between onsets

    for i = 2, #energies do
      local diff = energies[i].energy - energies[i-1].energy
      if diff > threshold then
        local pos = energies[i].pos
        if pos - onsets[#onsets] >= min_gap then
          onsets[#onsets + 1] = pos
        end
      end
    end

    -- If we got more onsets than slices, take the strongest
    if #onsets > num_slices then
      -- Pre-build energy lookup map (avoids O(n²) scan in comparator)
      local energy_map = {}
      for _, e in ipairs(energies) do energy_map[e.pos] = e.energy end
      -- Keep first onset (0), then pick the strongest N-1
      table.sort(onsets, function(a, b)
        return (energy_map[a] or 0) > (energy_map[b] or 0)
      end)
      local top = {0}
      for i = 1, #onsets do
        if onsets[i] ~= 0 then
          top[#top + 1] = onsets[i]
          if #top >= num_slices then break end
        end
      end
      table.sort(top)
      onsets = top
    end

    -- If fewer onsets than slices, fall back to equal
    if #onsets < num_slices then
      onsets = {}
      for i = 0, num_slices - 1 do
        onsets[#onsets + 1] = math.floor(i * total_samples / num_slices)
      end
    end

    slice_points = onsets
  else
    -- Equal division
    for i = 0, num_slices - 1 do
      slice_points[#slice_points + 1] = math.floor(i * total_samples / num_slices)
    end
  end

  -- Add end point
  slice_points[#slice_points + 1] = total_samples

  local source_name = ({reaper.GetMediaSourceFileName(source, "")})[2] or ""
  local base_name = source_name:match("([^/\\]+)%.[^.]+$") or "Chop"

  -- ── P3 eager capture: slices become WAVs on disk + a VER-201 path load ──
  -- (deferred via eon_chop_pump, one slice per poll tick). Falls back to the
  -- legacy packed-gmem path only when the JSFX build predates VER-201.
  local caps201 = reaper.GetExtState("EON_Bridge", "pathload") ~= "0"
                  and math.floor(reaper.gmem_read(G.HS_CAP) or 0) >= 201
  if caps201 then
    -- Chop WAV home: <store>/chops/<guidtok>/ — per-instance capture dirs
    -- (kit extractions share kits/; captures are instance-specific).
    -- Target = LOCK holder (JSFX chop button), else pending/browser slots.
    local target_id = math.floor(reaper.gmem_read(G.LOCK) or 0)
    if target_id <= 0 then target_id = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0) end
    if target_id <= 0 then target_id = math.floor(reaper.gmem_read(G.INSTANCE) or 0) end
    local ttr = nil
    if target_id > 0 then
      for tr in core.iter_all_tracks() do
        for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
          if is_swing_fx(tr, fx)
             and math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0) == target_id then
            ttr = tr; break
          end
        end
        if ttr then break end
      end
    end
    if not ttr then ttr = find_swing_track() end
    local guidtok = "shared"
    if ttr then
      local g = reaper.GetTrackGUID(ttr) or ""
      local tok = g:gsub("[^%w]", "")
      if tok ~= "" then guidtok = tok end
    end
    local _, projfn = reaper.EnumProjects(-1)
    local chop_dir = eon_store_root() .. "/chops/" .. guidtok
    reaper.RecursiveCreateDirectory(chop_dir, 0)
    eon_chop_state = {
      mono = mono, pts = slice_points, sr = sr,
      base = (base_name:gsub("[^%w%-]", "_"):sub(1, 24)),
      kit_base = base_name, dir = chop_dir, gen = os.time(),
      i = 1, wavs = {}, inst_id = target_id, tr = ttr,
      unsaved = (projfn == nil or projfn == ""),
    }
    -- Latch CMD=3 for the whole capture+staging span: suppresses the JSFX
    -- name mirror (same rationale as load_swing_dispatch_now) and stops the
    -- dispatcher re-entering cmd==30. Import arms only on GS_KIT_LOAD_REQ=2,
    -- which the pump's final tick sets.
    reaper.gmem_write(G.CMD, 3)
    return
  end

  -- ── legacy packed fallback (stale JSFX build, HS_CAP < 201) ──
  -- Wrap the gmem mutation in an undo block so the user can Ctrl+Z to
  -- revert a chop operation. Closed at the bottom of the function with
  -- Undo_EndBlock("Swing: Chop to Pads", -1). All early-return paths
  -- bail BEFORE this line, so they don't open an empty block.
  reaper.Undo_BeginBlock()

  -- Write slices to gmem as individual pads
  local audio_offset = 0

  for i = 1, math.min(#slice_points - 1, G.NUM_PADS) do
    local pad = i - 1
    local start_samp = slice_points[i]
    local end_samp = slice_points[i + 1]
    local slice_len = end_samp - start_samp

    if slice_len > 0 then
      -- Cap at SLOT_SIZE/2 (each mono frame becomes 2 interleaved samples)
      slice_len = math.min(slice_len, math.floor(G.SLOT_SIZE / 2))
      -- Cap at total gmem capacity
      if audio_offset + slice_len * 2 > GMEM_AUDIO_MAX then
        slice_len = math.floor((GMEM_AUDIO_MAX - audio_offset) / 2)
        if slice_len <= 0 then break end
      end

      -- Write audio as stereo interleaved (duplicate mono to L+R)
      for j = 0, slice_len - 1 do
        local val = mono[start_samp + j] or 0
        reaper.gmem_write(G.AUDIO_BASE + audio_offset + j * 2,     val)
        reaper.gmem_write(G.AUDIO_BASE + audio_offset + j * 2 + 1, val)
      end

      -- Metadata, audio length, and pad name
      local interleaved_len = slice_len * 2
      local pad_name = base_name .. " " .. i
      write_default_pad_meta(pad, interleaved_len, sr, pad / 16.0, pad_name)
      audio_offset = audio_offset + interleaved_len
    end
  end

  -- Clear unused pads
  local used = math.min(#slice_points - 1, G.NUM_PADS)
  for i = used, G.NUM_PADS - 1 do
    reaper.gmem_write(G.AUDIOLEN_BASE + i, 0)
    local mb = G.META_BASE + i * G.META_PP
    for j = 0, G.META_PP - 1 do reaper.gmem_write(mb + j, 0) end
  end

  -- Write kit name
  local kit_name = "Chop: " .. base_name
  core.gmem_write_string(kit_name:sub(1, 32), NAME_BASE, G.NAMELEN, 32)

  -- Clear stale per-pad disk-path breadcrumbs. Chop replaces pad audio with
  -- gmem-resident slices that have NO disk source. Leaving the previously-
  -- loaded kit's paths in ExtState was confusing the v4 save path before
  -- the bridge was rewritten to ignore ExtState for non-layered pads, and
  -- it still bakes wrong "path = ..." breadcrumbs into the kit's lua
  -- metadata. Clearing them keeps the saved kit file metadata honest.
  for pad = 0, G.NUM_PADS - 1 do
    reaper.SetExtState("Swing", "pad_path_" .. pad, "", false)
    publish_pitch_path(pad, "")   -- invalidate Extension's source cache too
  end

  -- Explicit VER for the packed route. Pre-P3 this was OMITTED, so a resident
  -- VER=201 from any prior path load misrouted the chop through the JSFX
  -- path-import branch against stale path cells (clear_pad storm ate the chop).
  reaper.gmem_write(G.KIT_GMEM_VER, 24)
  reaper.gmem_write(G.CMD, 3)  -- data ready for JSFX
  update_folder_track_name(find_swing_track())
  reaper.Undo_EndBlock("Swing: Chop to Pads (" .. (#slice_points - 1) .. " slices)", -1)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- AUTO-COLOR PADS (CMD 23)
-- ═════════════════════════════════════════════════════════════════════════════

function rk_ops.do_auto_color()
  local colored = 0
  for i = 0, G.NUM_PADS - 1 do
    -- Read pad name
    local chars = {}
    for j = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + i * G.PADNAME_LEN + j))
      if c > 0 then chars[#chars + 1] = string.char(c) end
    end
    local name = table.concat(chars)
    if name ~= "" then
      local _, hue = core.guess_drum_type(name)
      if hue then
        -- Write color to metadata slot 12
        reaper.gmem_write(G.META_BASE + i * G.META_PP + 12, hue)
        colored = colored + 1
      end
    end
  end

  reaper.gmem_write(G.CMD, 99)
end

-- ═════════════════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ═════════════════════════════════════════════════════════════════════════════

-- Self-register as startup action (one-time, first manual run).
-- The block written to __startup.lua is SELF-CLEANING: when the script
-- file is removed (e.g. via ReaPack uninstall), the block detects that
-- its registered command ID can no longer be resolved, strips itself
-- out of __startup.lua, and clears the registered_v3 ExtState so a
-- future reinstall will register fresh. No manual cleanup needed.
--
-- Bump from registered_v2 to registered_v3 forces existing installs
-- (which have the old single-line format) to re-register and pick up
-- the new self-cleaning block on next bridge run.

-- Rewrite __startup.lua via tmp-file + rename instead of truncating in place.
-- The file is SHARED -- other vendors' startup lines live in it too -- so a
-- crash or full disk mid-write must never be able to eat it. Returns true
-- only once the new content is fully on disk under `path`. Global, not local:
-- this chunk runs at Lua's 200-local ceiling (same helper rides in every EON
-- self-registering script).
function eon_write_startup(path, content)
  local tmp = path .. ".eon-tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local wok = f:write(content)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return false end
  os.remove(path)                    -- Windows os.rename won't overwrite
  return os.rename(tmp, path) and true or false
end

local function self_register()
  -- Probe/host opt-out (kitpipe harness, any dofile host): registration
  -- records get_action_context()'s script path — the HOSTING script, not
  -- this file. A probe that dofile'd the bridge got ITSELF installed as a
  -- REAPER startup action, so every later session in that resource dir
  -- silently re-ran the whole probe at boot (ghost Swing instances, ghost
  -- exports, deleted fixture kits — kitpipe post-mortem 2026-07-17).
  if reaper.GetExtState("EON_Bridge", "no_self_register") == "1" then return end
  local _, script_path = reaper.get_action_context()
  local key = SCRIPT_NAME .. "_registered_v3"
  local marker = "-- EON:" .. SCRIPT_NAME

  -- Check both ExtState AND __startup.lua. If the ExtState says registered
  -- but __startup.lua is missing or doesn't contain our block, re-register.
  -- This handles the case where the installer's uninstall step (or anything
  -- else) deletes/corrupts __startup.lua without clearing the ExtState.
  if reaper.GetExtState(SCRIPT_NAME, key) == "1" then
    local res_path = reaper.GetResourcePath()
    local startup_path = res_path .. "/Scripts/__startup.lua"
    local fr = io.open(startup_path, "r")
    if fr then
      local content = fr:read("*a"); fr:close()
      if content:find(marker .. " BEGIN", 1, true) then return end  -- genuinely registered
    end
    -- ExtState stale: __startup.lua missing or our block is gone. Clear and re-register.
    reaper.SetExtState(SCRIPT_NAME, key, "", true)
  end

  -- Register in action list (so manual invocation still works)
  local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
  if not cmd_id or cmd_id <= 0 then return end

  local res_path = reaper.GetResourcePath()
  local startup_path = res_path .. "/Scripts/__startup.lua"

  local existing = ""
  local fr = io.open(startup_path, "r")
  if fr then existing = fr:read("*a"); fr:close() end

  -- Strip ALL prior versions of our block so re-registration is idempotent:
  --   v3+: BEGIN...END block (new self-cleaning format)
  --   v1/v2: single-line format ("-- EON:NAME" marker + next line)
  local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
  existing = existing:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")
  existing = existing:gsub("\n?" .. esc .. "\n[^\n]*\n?", "")

  -- Resolve a stable command token. Named command IDs ("_RSxxxxx") survive
  -- action-list rebuilds; the raw int can change.
  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  -- Self-cleaning block. When `id` resolves (script file present), runs
  -- the bridge as usual. When `id == 0` (file removed via ReaPack uninstall),
  -- strips this block from __startup.lua and clears the registered_v3
  -- ExtState. The cleanup runs at most once per uninstall — once the block
  -- is gone, this code never executes again.
  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then reaper.Main_OnCommand(id,0) else\n" ..
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); if f then local c=f:read('*a'); f:close()\n" ..
    "    c=c:gsub('\\n?%-%- EON:" .. SCRIPT_NAME .. " BEGIN.-%-%- EON:" .. SCRIPT_NAME .. " END\\n?','')\n" ..
    "    local fw=io.open(p,'w'); if fw then fw:write(c); fw:close() end end\n" ..
    "  reaper.SetExtState('" .. SCRIPT_NAME .. "','" .. SCRIPT_NAME .. "_registered_v3','',true)\n" ..
    "end end\n" ..
    marker .. " END\n"

  -- Flag as registered only once the block is really on disk; a failed write
  -- leaves the ExtState clear so the next run simply retries.
  if eon_write_startup(startup_path, existing .. block) then
    reaper.SetExtState(SCRIPT_NAME, key, "1", true)
    reaper.ShowConsoleMsg("[EON] " .. SCRIPT_NAME .. " registered as startup action (auto-cleans on uninstall).\n")
  end
end
self_register()

-- One-shot: register the full EON action catalog into the Action List. Runs
-- once per catalog version (ExtState-guarded), silently. EON_Register_Actions
-- is idempotent so this never duplicates; users can also run it by hand.
-- Scoped in a do-block (locals freed) to spare this chunk's ~200-local budget;
-- pcall-guarded so a registrar error can never break bridge startup.
do
  -- ⚠️ BUMP THIS whenever an EON_*.lua action is ADDED, or nobody gets it: the
  -- ExtState guard below makes the bridge believe registration is already done,
  -- so the new script never reaches the Action List — not on this machine and
  -- not on any customer's after an update. Adding the file is only half the job.
  -- 4 = the 3.0 additions: song starter (3), toolbar installer, big-view
  --     actions (11).
  -- 5 = registrar now accepts lowercase eon_* (skipping @noindex libraries),
  --     which picks up eon_drum_matrix.lua — the Drum Matrix entry point, which
  --     the old "^EON_" filter could never register.
  -- 6 = registrar path normalisation completed. 5 collapsed separator RUNS but
  --     left base_dir's trailing one, so the join re-doubled it and every
  --     script got a fresh non-canonical twin. Now proven to converge.
  -- 7 = the dock rig ships (EON_Swing_Dock / EON_Steppa_Dock / EON_Dock_Layout /
  --     EON_Swing_Dock_View / EON_Chain_Dock / EON_Dock_Debug), 2026-09-04.
  local ACTIONS_VER = "7"
  if reaper.GetExtState("EON_Actions", "registered_ver") ~= ACTIONS_VER then
    local _, bp = reaper.get_action_context()
    local bdir = bp and bp:match("^(.*)[/\\]")
    local rp = bdir and (bdir .. "/EON_Register_Actions.lua")
    local f = rp and io.open(rp, "r")
    if f then
      f:close()
      reaper.SetExtState("EON_Actions", "silent", "1", false)
      local ok = pcall(dofile, rp)
      reaper.SetExtState("EON_Actions", "silent", "", false)
      if ok then reaper.SetExtState("EON_Actions", "registered_ver", ACTIONS_VER, true) end
    end
  end
end

reaper.gmem_attach(core.GMEM_NAME)
reaper.gmem_write(G.BRIDGE_ALIVE, os.time())
-- ③ ADAPT seq: continue from the band's live value instead of restarting at 0.
-- A bridge restart otherwise resets the counter, and if the first publish lands
-- on the exact value a StepSeq last consumed, its edge-detect sees "no change"
-- and that load's adapt offer is silently swallowed. (Must sit AFTER the
-- attach — top-level reads before gmem_attach return nothing.)
eon_padcat_adapt_seq = math.floor(reaper.gmem_read(EON_PADCAT_ADAPT) or 0)

-- P5: age-sweep the unsaved sample store once at bridge start (the only
-- automatic deletion anywhere; saved projects untouched). pcall-guarded so a
-- filesystem hiccup can never break startup.
pcall(_eon_sweep_unsaved_store)

-- Ensure 32 channels on Swing track at bridge startup
local function ensure_32ch()
  local lock_id = math.floor(reaper.gmem_read(G.LOCK))
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        if reaper.GetMediaTrackInfo_Value(tr, "I_NCHAN") < 32 then
          reaper.SetMediaTrackInfo_Value(tr, "I_NCHAN", 32)
        end
      end
    end
  end
end

ensure_32ch()  -- run once at startup

-- ── Auto-detect factory kits alongside the script and move to Swing_Kits ──
local function auto_migrate_kits()
  -- Get this script's directory
  local info = debug.getinfo(1, "S")
  local script_path = info and info.source and info.source:match("^@?(.+)$") or ""
  local script_dir = script_path:match("(.*[/\\])") or ""
  if script_dir == "" then return end

  -- Scan for .swing files in the same directory
  local found = {}
  local i = 0
  while true do
    local fname = reaper.EnumerateFiles(script_dir, i)
    if not fname then break end
    if fname:match("%.swing$") then
      found[#found + 1] = fname
    end
    i = i + 1
  end
  if #found == 0 then return end

  -- Check which ones are NOT already in the kits directory
  local kits_dir = core.get_kits_dir()
  local to_move = {}
  for _, fname in ipairs(found) do
    local dest = kits_dir .. core.sep .. fname
    local f = io.open(dest, "rb")
    if f then
      f:close()  -- already exists in kits dir, skip
    else
      to_move[#to_move + 1] = fname
    end
  end
  if #to_move == 0 then return end

  -- Prompt user
  local names = table.concat(to_move, ", ")
  local msg = "Found " .. #to_move .. " kit file(s) alongside Swing:\n\n" ..
              names .. "\n\n" ..
              "Move them to your Swing_Kits folder?\n" ..
              kits_dir
  local ok = reaper.ShowMessageBox(msg, SCRIPT_NAME, 4)
  if ok ~= 6 then return end  -- user said No

  -- Move files
  local moved = 0
  for _, fname in ipairs(to_move) do
    local src = script_dir .. fname
    local dest = kits_dir .. core.sep .. fname
    -- Read source
    local f_in = io.open(src, "rb")
    if f_in then
      local data = f_in:read("*a")
      f_in:close()
      -- Write destination
      local f_out = io.open(dest, "wb")
      if f_out then
        f_out:write(data)
        f_out:close()
        -- Delete source
        os.remove(src)
        moved = moved + 1
      end
    end
  end

  if moved > 0 then
    eon_notice(
      "Moved " .. moved .. " kit(s) to:\n" .. kits_dir)
  end
end

auto_migrate_kits()  -- run once at startup

-- ═══════════════════════════════════════════════════════════════════════════════
-- EON LOADER PROTOCOL v1 — file-based external loader
-- ═══════════════════════════════════════════════════════════════════════════════
-- Lets any REAPER script load samples into Swing without gmem knowledge.
-- External script writes <reaper_resource>/Data/EON_Loader/pending_<unique>.txt
-- with key=value lines; bridge polls, validates, and delivers over the CMD 63
-- wire (the browser's single-pad load protocol: path staged in gmem, the
-- target JSFX reads the file from disk itself via load_from_path). See
-- EON_Loader_Protocol_v1.md for the public-facing spec.
--
-- Delivery rewrite 2026-07-16: the old route (load_audio_to_pad + CMD=3 +
-- PARAM1) had NO JSFX-side consumer — the kit-import state machine only
-- accepts CMD 3 after being armed by GS_KIT_LOAD_REQ=2, which the loader
-- never set. The sample never reached the pad, the CMD channel sat latched
-- at 3 until the stale-CMD watchdog aborted it (15s starvation per drop),
-- and load_audio_to_pad still clobbered the pad's META/PADNAME/pad_path
-- breadcrumbs + published the file as the pad's pitch SOURCE — so a later
-- kit save recorded a sample the pad never actually adopted. CMD 63 is the
-- proven consumer (undo bracket, crossfade, auto-name, auto-color, source
-- capture all included) and reads nothing from the blast-written AUDIOLEN
-- band.
--
-- Multi-instance note (v2.1.1): the loader routes to the browser-picked
-- instance (gmem INSTANCE) when that id is alive, else to whichever Swing
-- find_swing_track() returns (LOCK holder, or first found). External scripts
-- have no way to target a specific instance yet — that's planned for protocol
-- v2 with an optional instance_id field.

local LOADER_DIR = reaper.GetResourcePath() .. core.sep .. "Data" .. core.sep .. "EON_Loader"
reaper.RecursiveCreateDirectory(LOADER_DIR, 0)

-- Per-request retry counter prevents stale files from looping forever when
-- no Swing is connected (could happen if the user closes Swing right after
-- a third-party script wrote a request). Also counts busy-channel deferrals
-- (CMD/LOCK held by an in-flight command — e.g. a kit load), so the cap is
-- sized to outlast a worst-case monolithic kit import (~15s), not 1s.
local loader_retries = {}
local LOADER_MAX_RETRIES = 600  -- ~20s at typical defer rate

local function loader_parse_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  if not content then return nil end

  local req = {}
  for line in content:gmatch("[^\r\n]+") do
    local k, v = line:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
    if k and v then req[k:lower()] = v end
  end
  return req
end

-- Defer a request file to the next poll tick; give up (delete) once the retry
-- budget is spent. GLOBAL (main chunk is at Lua's 200-local ceiling).
function _eon_loader_defer(path)
  loader_retries[path] = (loader_retries[path] or 0) + 1
  if loader_retries[path] > LOADER_MAX_RETRIES then
    os.remove(path)
    loader_retries[path] = nil
  end
end

local function loader_process_one(path)
  local req = loader_parse_file(path)
  if not req then
    os.remove(path)
    return
  end

  -- Forward-compat: only target=swing handled in v2.1.1 (target field reserves
  -- coupe / sedan / press for future products). Unknown targets silently
  -- discarded so a future-targeted file doesn't pile up here.
  if (req.target or "swing"):lower() ~= "swing" then
    os.remove(path)
    return
  end

  -- Validate filepath exists and is readable
  if not req.filepath or req.filepath == "" then
    os.remove(path)
    return
  end
  local probe = io.open(req.filepath, "rb")
  if not probe then
    os.remove(path)
    return
  end
  probe:close()

  -- Validate pad index
  local pad = tonumber(req.pad) or 0
  if pad < 0 or pad > 15 then
    os.remove(path)
    return
  end

  -- Path must fit the CMD 63 staging band.
  if #req.filepath >= G.GS_BROWSER_PATH_MAX then
    os.remove(path)
    return
  end

  -- Need a Swing instance to route to. If none, defer; if persistently absent,
  -- give up to keep the request directory clean.
  local tr, fx = find_swing_track()
  if not tr then
    _eon_loader_defer(path)
    return
  end

  -- Shared command channel must be free before staging — the old code fired
  -- CMD=3 unconditionally, which could stomp an in-flight command (and a
  -- second pending file in the same poll would stomp the first). Busy ⇒
  -- leave the request file for the next poll tick.
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0
     or math.floor(reaper.gmem_read(G.LOCK) or 0) ~= 0 then
    _eon_loader_defer(path)
    return
  end

  -- Resolve a target the STRICT _is_browser_target() gate will accept (the
  -- CMD 63 consumer only fires on the instance whose id == gmem[INSTANCE]).
  -- Prefer the existing browser binding when that id is still alive — don't
  -- flip the browser's mirror source under the user — else bind the instance
  -- find_swing_track() picked (its id read live from FX param 3).
  local target_id = 0
  local cur_inst = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  if cur_inst > 0 then
    for t in core.iter_all_tracks() do
      for f = 0, reaper.TrackFX_GetCount(t) - 1 do
        if is_swing_fx(t, f)
           and math.floor(reaper.TrackFX_GetParam(t, f, 3) or 0) == cur_inst then
          target_id = cur_inst
          break
        end
      end
      if target_id > 0 then break end
    end
  end
  if target_id == 0 then
    target_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
  end
  if target_id <= 0 then
    -- Fresh insert still booting — param 3 lags registration. Retry.
    _eon_loader_defer(path)
    return
  end

  -- Stage path chars + pad + target, then fire CMD 63 (payload first, CMD
  -- last — same order as the browser's load_sample_to_pad).
  for i = 0, #req.filepath - 1 do
    reaper.gmem_write(G.GS_BROWSER_PATH + i, req.filepath:byte(i + 1))
  end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, #req.filepath)
  reaper.gmem_write(G.GS_BROWSE_PAD, pad)
  reaper.gmem_write(G.INSTANCE, target_id)
  -- This producer stages NO display name — defensively drop any armed
  -- name-adopt flag (a leaked fill flag here would make the handler keep
  -- the pad's OLD mirrored name instead of the new file's — REVIEW 2026-07-27).
  reaper.gmem_write(G.GS_BROWSE_NAME_ADOPT, 0)
  reaper.gmem_write(G.CMD, 63)

  os.remove(path)
  loader_retries[path] = nil
end

local function loader_poll()
  local i = 0
  repeat
    local fname = reaper.EnumerateFiles(LOADER_DIR, i)
    if fname and fname:match("^pending_") and fname:sub(-4) == ".txt" then
      loader_process_one(LOADER_DIR .. core.sep .. fname)
    end
    i = i + 1
  until not fname or i > 100  -- safety cap; 100 pending requests per poll is plenty
end

local heartbeat_counter = 0

-- ─── Lane color ownership ─────────────────────────────────────────────────
-- Per-instance policy stored in P_EXT:EON_LANE_COLOR_POLICY on the Swing ENGINE
-- track, decoded to two booleans. See .docs/specs/Spec_Lane_Color_Ownership.md.
--   "swing" (default / absent / unknown) -> write=true  read=true
--   "reaper"                             -> write=false read=true
--   "none"                               -> write=false read=false
-- Declared module-GLOBAL (no `local`): the main chunk is at Lua's 200-local
-- ceiling. No cache — one P_EXT read per Swing track per pass is noise next to
-- the per-pad gmem reads already in the loop, and a cache is one more thing to
-- invalidate.
function bridge_lane_policy(swing_track)   -- -> write_tracks, read_tracks
  if not swing_track then return true, true end
  local _, v = reaper.GetSetMediaTrackInfo_String(swing_track, "P_EXT:EON_LANE_COLOR_POLICY", "", false)
  if v == "reaper" then return false, true  end
  if v == "none"   then return false, false end
  return true, true
end

-- Last-seen policy per Swing track GUID, so the identity sync can detect a flip
-- BACK to "swing" and force a repaint — otherwise the band is stable and neither
-- the forward snap nor the gesture-gated reverse would reclaim the foreign color.
_lane_pol_last = {}

-- One-time notice if SWS Auto Color is active WITH rules: it also wants to own
-- lane-track colors. Swing's gesture gate keeps them from fighting, but the user
-- may prefer "REAPER owns" (SWS colors then flow into the pads). Suggest, never
-- auto-set. Prefer the live toggle state; the ini also gives the rule count,
-- which the toggle state can't. Runs once per session.
_sws_detect_done = false
_sws_next_try = 0
function bridge_detect_sws_autocolor()
  if _sws_detect_done then return end
  -- ⚠️ORDER IS THE OPTIMIZATION (regression fix 2026-08-06): the first cut
  -- parsed the SWS ini from disk BEFORE checking whether a Swing even exists,
  -- and the no-Swing re-arm made that a PER-POLL-TICK file read — measurable
  -- drag on the whole defer loop (user felt it at REAPER close). Now the only
  -- thing that runs while waiting is one throttled gmem scan; the file I/O
  -- happens exactly once, after a Swing is live.
  local now = reaper.time_precise()
  if now < _sws_next_try then return end
  _sws_next_try = now + 5
  local any_swing = false
  for slot = 0, (G.GS_INST_REG_MAX or 16) - 1 do
    if (reaper.gmem_read(G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE) or 0) > 0 then
      any_swing = true; break
    end
  end
  if not any_swing then return end
  _sws_detect_done = true
  local enabled, count = nil, 0
  local cmd = reaper.NamedCommandLookup("_SWSAUTOCOLOR_ENABLE")
  if cmd and cmd ~= 0 then enabled = reaper.GetToggleCommandState(cmd) == 1 end
  local sep2 = package.config:sub(1, 1)
  local f = io.open(reaper.GetResourcePath() .. sep2 .. "sws-autocoloricon.ini", "r")
  if f then
    for line in f:lines() do
      local e = line:match("^AutoColorEnable=(%d+)")
      if e and enabled == nil then enabled = (e == "1") end
      local c = line:match("^AutoColorCount=(%d+)")
      if c then count = tonumber(c) or 0 end
    end
    f:close()
  end
  if not (enabled and count > 0) then return end
  if reaper.GetExtState("EON_Swing", "sws_notice_count") == tostring(count) then return end
  local ti, chose = 0, false
  while ti < reaper.CountTracks(0) and not chose do
    local tr = reaper.GetTrack(0, ti)
    local _, pol = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_LANE_COLOR_POLICY", "", false)
    chose = pol ~= nil and pol ~= ""
    ti = ti + 1
  end
  reaper.SetExtState("EON_Swing", "sws_notice_count", tostring(count), true)
  if not chose then
  reaper.ShowConsoleMsg(
      "[EON Swing] SWS Auto Color is active with " .. count .. " rule(s). If it " ..
      "recolors Swing's pad/lane tracks, use the Kit > Lane Colors menu to choose " ..
      "who owns them (\"REAPER owns\" lets SWS colors drive the pads).\n")
  end
end

-- Project-wide quiet window after WE rename a lane track. SWS Auto Color re-runs
-- on SetTrackTitle and recolors EVERY matching track project-wide (not just the
-- renamed one), so a rename by any instance can provoke a recolor the reverse-
-- adopt leg would misread as a user's TCP gesture. One scalar, not per-lane:
-- instance A's rename must mute the gate for instance B too.
_lane_rename_quiet_until = 0
function _lane_rename_touch()
  _lane_rename_quiet_until = reaper.time_precise() + 0.75
end

-- ─── Real-time multi-out track color sync ────────────────────────────────
-- Watch the JSFX's pad-color slots in gmem and propagate any change to the
-- multi-out child tracks. Triggers naturally when the user loads a new kit
-- (kit load fires pad_colors), changes a pad's color manually via the
-- overlay color picker, or runs auto-color (CMD 23). Cost: 16 gmem_reads
-- per defer tick to compute a hash; the work loop only runs when the hash
-- actually changes AND multi-out tracks exist.
--
-- Bridge-side because the JSFX doesn't have track-state access — gmem is
-- the only path from JSFX to track metadata.
local last_pad_color_hash = -1

local function refresh_multiout_colors_if_changed()
  -- Hash the 16 hue floats + per-pad audio state + the broadcast effective
  -- saturation and lightness slots. Quantize to int*1000 so floating-point
  -- noise doesn't trigger a redundant refresh. Including S/L in the hash
  -- means changes to the intensity dial or theme picker also trigger an
  -- update, not just per-pad hue changes. Audio state is included so that
  -- pad load/clear transitions reset tracks to REAPER's default color.
  local hash = 1
  for i = 0, G.NUM_PADS - 1 do
    local hue_x1k = math.floor(reaper.gmem_read(G.META_BASE + i * G.META_PP + 12) * 1000 + 0.5)
    local has_audio = core.pad_has_audio(i) and 1 or 0
    hash = (hash * 31 + hue_x1k) % 0x7FFFFFFF
    hash = (hash * 31 + has_audio) % 0x7FFFFFFF
  end
  local eff_s = reaper.gmem_read(G.GS_COL_EFFECTIVE_S)
  local eff_l = reaper.gmem_read(G.GS_COL_EFFECTIVE_L)
  hash = (hash * 31 + math.floor(eff_s * 1000 + 0.5)) % 0x7FFFFFFF
  hash = (hash * 31 + math.floor(eff_l * 1000 + 0.5)) % 0x7FFFFFFF
  if hash == last_pad_color_hash then return end
  last_pad_color_hash = hash

  -- Find the active Swing track (LOCK-holder, or first found)
  local swing_track = find_swing_track()
  if not swing_track then return end

  -- Only update if multi-out tracks actually exist (i.e. user has run
  -- "Build Multi-Out Tracks" at least once).
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < G.NUM_PADS then return end

  -- Lane color ownership: under "reaper"/"none" Swing does not paint lanes.
  -- Early-out skips the whole send walk (legacy fallback path; the per-instance
  -- identity sync gates the same way inline).
  if not bridge_lane_policy(swing_track) then return end

  -- Saturation and lightness from gmem; fall back to legacy 0.75/0.55 if
  -- the JSFX hasn't populated the new slots yet (e.g. an older Swing
  -- instance running alongside a newer bridge). Use eff_l as the "slot
  -- initialized" sentinel since theme lightness is never 0 (themes range
  -- 0.35..0.72) — that lets eff_s legitimately be 0 when the user pulls
  -- the intensity dial all the way down (full desaturation, monochrome).
  if eff_l <= 0 then
    eff_s = 0.75
    eff_l = 0.55
  end

  -- Walk each send, map source channel pair → pad index, recolor dest track
  reaper.PreventUIRefresh(1)
  for s = 0, sends - 1 do
    local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if pad >= 0 then
      -- (nesting kept: core.srcchan_pad already rejects no-audio and odd channels)
      if pad >= 0 and pad < G.NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          if core.pad_has_audio(pad) then
            -- Pad has audio → apply pad color
            local hue = reaper.gmem_read(G.META_BASE + pad * G.META_PP + 12)
            local r, g, b = hsl_to_rgb(hue, eff_s, eff_l)
            local color = reaper.ColorToNative(r, g, b) | 0x1000000
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", color)
          else
            -- Empty pad → remove custom color (REAPER default)
            reaper.SetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR", 0)
          end
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
end

-- ─────────────────────────────────────────────────────────────────────────
-- SAFETY-NET FORWARD NAME SYNC (matches the color version's pattern)
-- ─────────────────────────────────────────────────────────────────────────
-- The forward name sync today fires via CMD=52 (event-driven, set by
-- JSFX sync_note_names after rename/load/drop). If any code path
-- bypasses CMD=52 (future code, edge cases, races), names go stale on
-- multi-out tracks silently. This hash-debounced poll catches every
-- pad-name change regardless of how it happened — same idea as
-- refresh_multiout_colors_if_changed (color version, line ~4609).
--
-- Cost: 16 pads × 16 chars = 256 gmem reads + 16 hash ops per ~33ms.
-- No-op early-out if hash matches last seen.

local last_pad_name_hash = 0

local function refresh_multiout_names_if_changed()
  local hash = 1
  -- Read all 16 pad-name strings from PADNAME_BASE and hash them
  for pad = 0, G.NUM_PADS - 1 do
    for j = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + pad * G.PADNAME_LEN + j) or 0)
      if c == 0 then break end
      hash = (hash * 31 + c) % 0x7FFFFFFF
    end
    hash = (hash * 31 + pad) % 0x7FFFFFFF  -- include pad index so reordered names trigger
  end
  if hash == last_pad_name_hash then return end
  last_pad_name_hash = hash

  -- Hash changed — walk multi-out tracks and rename to match.
  local swing_track = find_swing_track()
  if not swing_track then return end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < G.NUM_PADS then return end

  reaper.PreventUIRefresh(1)
  for s = 0, sends - 1 do
    local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if pad >= 0 then
      -- (nesting kept: core.srcchan_pad already rejects no-audio and odd channels)
      if pad >= 0 and pad < G.NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          -- Blank pads (no audio, per the one shared signal) → number only,
          -- never a stale gmem name. Loaded pads → the gmem name.
          local pname
          if not core.pad_has_audio(pad) then
            pname = string.format("%02d", pad + 1)
          else
            pname = ""
            for j = 0, G.PADNAME_LEN - 1 do
              local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + pad * G.PADNAME_LEN + j) or 0)
              if c == 0 then break end
              pname = pname .. string.char(c)
            end
            if pname == "" then pname = string.format("%02d", pad + 1) end
          end
          reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", pname, true)
          _lane_rename_touch()  -- mute color-adopt gate: SWS re-colors on our rename
          -- P2 — keep the multi-out track's P_ICON in lockstep with its
          -- name. Same resolver the MIDI lanes use, so pad/lane/multi-out
          -- icons match per pad and follow live kit changes. pname here
          -- is the formatted display name; pass the raw bare name (or "")
          -- so the categorizer matches against the pad name only, not the
          -- "NN " number prefix used for blank pads' display.
          local raw = pname
          if not core.pad_has_audio(pad) then raw = "" end
          bridge_apply_icon(dest_tr, pad, raw)
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
end

-- ─────────────────────────────────────────────────────────────────────────
-- PER-INSTANCE IDENTITY → multi-out tracks (P2)
-- ─────────────────────────────────────────────────────────────────────────
-- The shared-META refreshers above only service the ONE active (LOCK/browser-
-- target) instance. With the per-instance identity bands each Swing publishes
-- its OWN registry-slot band, so we can service EVERY live instance's multi-out
-- set independently — two kits in two tabs no longer cross-drive. Runs alongside
-- the legacy refreshers during migration; idempotent compare-before-write avoids
-- churn. Color + name here; icons follow in P5 (need per-instance blank state).

-- Resolve a Swing instance_id → its live registry slot (fresh wall-clock heartbeat).
-- NOTE: declared module-GLOBAL (no `local`) on purpose — this large bridge main
-- chunk is near Lua's 200-local limit; a global adds zero main-chunk local slots.
function ss_resolve_slot(inst_id)
  if inst_id <= 0 then return nil end
  local now = reaper.time_precise()
  local slot = 0
  while slot < G.GS_INST_REG_MAX do
    local base = G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE
    if math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID) or 0) == inst_id then
      if (now - (reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT) or 0)) <= G.GS_INST_REG_TIMEOUT then
        return slot
      end
    end
    slot = slot + 1
  end
  return nil
end

-- Positive death evidence for an instance id: it sits in the registry with a
-- heartbeat that STOPPED (stale beyond the live timeout). A BOOTING instance
-- was never registered (absent from the registry entirely) and a live one is
-- fresh — only a re-minted/dead incarnation matches. The distinction is what
-- lets the load queue re-bind a dead target without ever re-aiming a fresh
-- insert's auto-load at a bystander (ss_resolve_slot alone cannot tell the
-- two apart: it returns nil for both).
function eon_inst_is_corpse(inst_id)
  if not inst_id or inst_id <= 0 then return false end
  local now = reaper.time_precise()
  local slot = 0
  while slot < G.GS_INST_REG_MAX do
    local base = G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE
    if math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID) or 0) == inst_id then
      local hb = reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT) or 0
      if hb > 0 and (now - hb) > G.GS_INST_REG_TIMEOUT then return true end
    end
    slot = slot + 1
  end
  return false
end

-- P4-2: pad index for a multi-out child — the explicit P_EXT tag (stamped at
-- build), with an I_SRCCHAN/2 fallback + one-time retro-tag for pre-P4
-- projects. The fallback is valid exactly while routing is still default,
-- i.e. before any output mirroring has moved a send — after that, srcchan
-- encodes the pad's OUTPUT pair, not its identity. Module-GLOBAL (200-local
-- ceiling).
function eon_child_pad_idx(tr, s, dest)
  local _, ptag = reaper.GetSetMediaTrackInfo_String(dest, "P_EXT:EON_PAD_IDX", "", false)
  if ptag ~= "" then return math.floor(tonumber(ptag) or -1) end
  local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN"))
  if pad >= 0 and pad < G.NUM_PADS then
    reaper.GetSetMediaTrackInfo_String(dest, "P_EXT:EON_PAD_IDX", tostring(pad), true)
    return pad
  end
  return -1
end

-- Module-GLOBAL (see ss_resolve_slot note) to avoid adding main-chunk local slots.
function refresh_multiout_identity_per_instance()
  local IDENT_BASE   = G.INST_IDENT_BASE
  local IDENT_STRIDE = G.INST_IDENT_INST_STRIDE
  local PAD_FIELDS   = G.INST_IDENT_PAD_FIELDS
  local OFF_HUE      = G.IDENT_OFF_HUE
  local OFF_VER      = G.IDENT_OFF_VER
  local NAME_BASE    = G.INST_PADNAME_BASE
  local NAME_STRIDE  = G.INST_PADNAME_INST_STRIDE
  local NAME_LEN     = G.INST_PADNAME_PAD_LEN
  -- Defensive: if a stale rk_lua_core (no identity contract) is loaded, bail
  -- instead of throwing (which would kill the whole bridge defer loop).
  if not (IDENT_BASE and IDENT_STRIDE and NAME_BASE) then return 0 end
  -- IN direction (D-1): inbound color mailbox constants. nil on a stale core,
  -- which simply disables the reverse leg (forward keeps working).
  local INCMD_BASE   = G.INST_INCMD_BASE
  local INCMD_STRIDE = G.INST_INCMD_STRIDE
  local OFF_MUTE     = G.IDENT_OFF_MUTE
  local OFF_SOLO     = G.IDENT_OFF_SOLO
  local OFF_AUDIO    = G.IDENT_OFF_AUDIO or 7
  local OFF_OUTPUT   = G.IDENT_OFF_OUTPUT or 5
  -- Per-(slot,pad) two-way state: last forwarded hue + theme S/L, pending
  -- pushed hue + timestamp. Module-GLOBAL table (main chunk is at Lua's
  -- 200-local ceiling — do not make this a chunk local).
  if not _inc_col_st then _inc_col_st = {} end
  local now = reaper.time_precise()
  local serviced = 0
  -- Lens link upkeep rides a ~1 Hz sub-tick of this ~10 Hz sweep. Strays are
  -- rare and a second of latency is invisible, whereas an fx_ident read per FX
  -- on every pass would not be. _eon_lens_scan_t is a module GLOBAL (no `local`
  -- — this chunk is at Lua's 200-local limit).
  local lens_scan = (now - (_eon_lens_scan_t or 0)) >= 1.0
  local lens_parents = nil
  if lens_scan then _eon_lens_scan_t = now ; lens_parents = {} end
  local eff_s = reaper.gmem_read(G.GS_COL_EFFECTIVE_S)
  local eff_l = reaper.gmem_read(G.GS_COL_EFFECTIVE_L)
  if eff_l <= 0 then eff_s = 0.75; eff_l = 0.55 end
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        local slot = ss_resolve_slot(inst_id)
        local sends = slot and reaper.GetTrackNumSends(tr, 0) or 0
        if slot then
          -- Cover follows the instance across slot migrations (recompile,
          -- collision reclaim) — the one-shot publish does not do it itself.
          -- Before the sends gate: stereo instances' kit tiles need it too.
          eon_kitcover_follow_slot(inst_id, slot)
          -- P4-2: per-instance piano-roll note names on the HOST track —
          -- every slotted instance's track gets ITS pads' names at ITS
          -- trigger notes (the legacy CMD-48/52 writer only served the
          -- active instance; it is gated off while this runs). Runs for
          -- non-multi-out instances too. Edge-triggered off the band NOTE
          -- field + name VER; moving a note clears the old pitch first.
          local ib0 = IDENT_BASE + slot * IDENT_STRIDE
          local nb0 = NAME_BASE  + slot * NAME_STRIDE
          for pad = 0, G.NUM_PADS - 1 do
            local k = slot * 16 + pad
            local cst = _inc_col_st[k]
            if not cst then cst = {} ; _inc_col_st[k] = cst end
            local nver = reaper.gmem_read(ib0 + pad * PAD_FIELDS) or 0
            local note = math.floor(reaper.gmem_read(ib0 + pad * PAD_FIELDS + 4) or 0)
            if cst.pn_ver ~= nver or cst.pn_note ~= note then
              local af = reaper.gmem_read(ib0 + pad * PAD_FIELDS + OFF_AUDIO) or 0
              local hue = reaper.gmem_read(ib0 + pad * PAD_FIELDS + OFF_HUE) or -2
              local blank = (af >= 1) and false or ((af <= -1) and true or (hue <= -1.5))
              local pname = ""
              if not blank then
                local j = 0
                while j < NAME_LEN do
                  local c = math.floor(reaper.gmem_read(nb0 + pad * NAME_LEN + j) or 0)
                  if c == 0 then break end
                  pname = pname .. string.char(c)
                  j = j + 1
                end
              end
              if cst.pn_note and cst.pn_note ~= note
                 and cst.pn_note >= 0 and cst.pn_note <= 127 then
                reaper.SetTrackMIDINoteNameEx(0, tr, cst.pn_note, 0, "")
              end
              if note >= 0 and note <= 127 then
                reaper.SetTrackMIDINoteNameEx(0, tr, note, 0, pname)
              end
              cst.pn_ver = nver ; cst.pn_note = note
            end
          end
        end
        if slot and sends >= G.NUM_PADS then
          serviced = serviced + 1
          -- Lens link_slot upkeep (Spec_EON_Lens.md): serialized slots go
          -- stale across sessions (registration order), so re-assert from
          -- the live registry each pass. Query-only — never re-inserts a
          -- Lens the user deleted.
          eon_lens_sync(tr, slot, fx)
          -- ...and note this instrument's parent so the revocation pass below
          -- can tell a Lens that is merely somewhere else INSIDE the instrument
          -- from one that has left it entirely.
          if lens_scan then
            local lp = find_folder_track(tr)
            if lp then lens_parents[lp] = slot end
          end
          -- Lane color ownership: consume a pending set-request from the JSFX
          -- Colors panel FIRST (payload-first/flag-last mailbox; we zero the
          -- flag to consume), so this same pass already runs under the new
          -- policy. P_EXT stays the single source of truth — the panel is a
          -- view/controller, nothing serialized JSFX-side.
          if INCMD_BASE then
            local _rq = INCMD_BASE + slot * INCMD_STRIDE + (G.INCMD_LANEPOL_REQ or 994)
            if (reaper.gmem_read(_rq) or 0) >= 1 then
              local _rv = math.floor(reaper.gmem_read(_rq + 1) or 0)
              local _rm = (_rv == 2) and "reaper" or (_rv == 3) and "none" or ""
              reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_LANE_COLOR_POLICY", _rm, true)
              reaper.gmem_write(_rq, 0)  -- consume LAST
            end
          end
          -- Fetched once per instance, not per pad (tr = the engine track).
          local _lc_wt, _lc_rt = bridge_lane_policy(tr)
          -- Publish for the JSFX Colors panel (1=swing 2=reaper 3=none; cell
          -- reads 0 when no bridge has ever published = panel greys out).
          if INCMD_BASE then
            reaper.gmem_write(
              INCMD_BASE + slot * INCMD_STRIDE + (G.INCMD_LANEPOL_PUB or 992),
              _lc_wt and 1 or (_lc_rt and 2 or 3))
          end
          -- On a flip BACK to "swing", the lanes still wear foreign colors while
          -- the band is stable — wipe this slot's per-pad color memory so the
          -- forward snap re-triggers (band_moved via cst.hue == nil) next pass.
          do
            local _pg = reaper.GetTrackGUID(tr)
            local _pm = _lc_wt and "swing" or (_lc_rt and "reaper" or "none")
            if _lane_pol_last[_pg] and _lane_pol_last[_pg] ~= "swing" and _pm == "swing" then
              for _p = 0, G.NUM_PADS - 1 do
                local _e = _inc_col_st[slot * 16 + _p]
                if _e then _e.hue = nil ; _e.s = nil ; _e.l = nil end
              end
            end
            _lane_pol_last[_pg] = _pm
          end
          local ib = IDENT_BASE + slot * IDENT_STRIDE
          local nb = NAME_BASE  + slot * NAME_STRIDE
          -- E-2: the pad-M/S legs own the child-track mute/solo EVERYWHERE —
          -- paired StepSeq lanes are now views/controllers of the pad state
          -- (they post to the INCMD sequencer cells; they no longer publish
          -- the banded M/S region, so the banded mirror self-silences on its
          -- dead heartbeat and only services pre-E-2 StepSeq builds during
          -- the transition). The E-1 stand-down arbitration is retired.
          local seq_owns = false
          reaper.PreventUIRefresh(1)
          for s = 0, sends - 1 do
            -- P4-2: pad identity comes from the child's P_EXT tag (srcchan
            -- now encodes the pad's OUTPUT routing, which the mirror below
            -- retargets — it no longer identifies the pad).
            local dest = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
            if dest and reaper.ValidatePtr(dest, 'MediaTrack*') then
              local pad = eon_child_pad_idx(tr, s, dest)
              if pad >= 0 and pad < G.NUM_PADS then
                  local hue = reaper.gmem_read(ib + pad * PAD_FIELDS + OFF_HUE) or -2
                  -- Blank: prefer the explicit AUDIO flag (+7: 1 loaded / -1
                  -- blank) so a manually-BLACK pad (hue -2 — the same value
                  -- the blank sentinel uses) keeps its name/color/icon/MS.
                  -- 0 = pre-flag JSFX build -> legacy hue-sentinel fallback.
                  local af = reaper.gmem_read(ib + pad * PAD_FIELDS + OFF_AUDIO) or 0
                  local blank
                  if af >= 1 then blank = false
                  elseif af <= -1 then blank = true
                  else blank = hue <= -1.5 end
                  -- COLOR: edge-triggered TWO-WAY (IN direction, D-1).
                  -- Forward-write the child track ONLY when the published hue
                  -- (or theme S/L) moves; a stable band + diverged track means
                  -- the USER recolored the track in the TCP -> post the hue to
                  -- the instance's inbound mailbox (flag=1: the TCP edit owns
                  -- its own native undo point) instead of stomping it. Origin
                  -- suppression: remember the pushed hue and suppress further
                  -- posts until the band echoes it back; if it never does
                  -- (kit_busy held too long so the JSFX never consumed the
                  -- mailbox), the push expires and we snap the track back to
                  -- canonical. NOTE: on a loaded pad the JSFX ALWAYS adopts the
                  -- pushed hue (Swing_ReaKit.jsfx inbound COLOR mailbox ->
                  -- swing_color_manualize) — there is no "auto-color rejects it"
                  -- path; only a kit_busy stall triggers the snap-back.
                  local ck = slot * 16 + pad
                  local cst = _inc_col_st[ck]
                  if not cst then cst = {} ; _inc_col_st[ck] = cst end
                  local want_col
                  if blank then
                    want_col = 0
                  else
                    -- hsl_to_rgb handles BOTH B&W sentinels (black <= -1.5,
                    -- white < 0) at 0-255 scale. The old inline white branch
                    -- here fed 0..1 FLOATS to ColorToNative (truncated to
                    -- ~black) and never saw black at all (blank ate -2).
                    local r, g, b = hsl_to_rgb(hue, eff_s, eff_l)
                    want_col = reaper.ColorToNative(r, g, b) | 0x1000000
                  end
                  local cur_col = math.floor(reaper.GetMediaTrackInfo_Value(dest, "I_CUSTOMCOLOR") or 0)
                  local band_moved = blank or cst.hue == nil
                    or math.abs(hue - cst.hue) > 0.0025
                    or cst.s ~= eff_s or cst.l ~= eff_l
                  local rejected = cst.push and cst.push_t and (now - cst.push_t) > 3.0
                  if band_moved or rejected then
                    -- Forward snap: band is the source. Covers first sight,
                    -- blank enforce, theme S/L change, the echo of our own
                    -- push, and rejected-push snap-back. Gated on write_tracks:
                    -- under "reaper"/"none" Swing does not own the lane color.
                    if _lc_wt and cur_col ~= want_col then
                      reaper.SetMediaTrackInfo_Value(dest, "I_CUSTOMCOLOR", want_col)
                    end
                    if not blank then cst.hue = hue ; cst.s = eff_s ; cst.l = eff_l end
                    if cst.push and (rejected or math.abs(hue - cst.push) <= 0.0025) then
                      cst.push = nil ; cst.push_t = nil
                    end
                  elseif INCMD_BASE and (not cst.push) and core.rgb_to_hue
                    and (cur_col & 0x1000000) ~= 0 and cur_col ~= want_col
                    and _lc_rt
                    and ((not _lc_wt)  -- "reaper" mode: user/SWS owns color, always adopt
                         or (reaper.IsTrackSelected(dest)
                             and now >= _lane_rename_quiet_until)) then
                    -- Band stable, track diverged. Adopt ONLY as a human gesture:
                    -- the lane must be SELECTED (SWS Auto Color never selects) and
                    -- we must not have just renamed a lane (SWS re-colors on our
                    -- own SetTrackTitle). "reaper" mode bypasses the gate — there
                    -- every external write is meant to flow into the pad.
                    local r, g, b = reaper.ColorFromNative(cur_col & 0xFFFFFF)
                    -- Skip near-gray picks (saturation too low -> hue undefined).
                    if (math.max(r, g, b) - math.min(r, g, b)) >= 26 then
                      local new_hue = core.rgb_to_hue(r, g, b)
                      if math.abs(new_hue - hue) > 0.005 then
                        local cb = INCMD_BASE + slot * INCMD_STRIDE + pad * 2
                        reaper.gmem_write(cb + 1, new_hue)  -- payload FIRST
                        reaper.gmem_write(cb + 0, 1)        -- flag LAST
                        cst.push = new_hue ; cst.push_t = now
                      end
                    end
                  end
                  -- NAME: edge-triggered TWO-WAY (D-2), keyed off the per-pad
                  -- VER stamp (the publisher bumps it only when the name
                  -- changes; it's also the seqlock for this multi-word read —
                  -- re-check after building and skip the pass on a torn read).
                  -- VER stable + diverged track name = user TCP rename ->
                  -- post chars+gen+flag into the name mailbox. Same origin
                  -- suppression / expiry snap-back as the color leg.
                  local nver = reaper.gmem_read(ib + pad * PAD_FIELDS + OFF_VER) or 0
                  local pname
                  if blank then
                    pname = string.format("%02d", pad + 1)
                  else
                    pname = ""
                    local j = 0
                    while j < NAME_LEN do
                      local c = math.floor(reaper.gmem_read(nb + pad * NAME_LEN + j) or 0)
                      if c == 0 then break end
                      pname = pname .. string.char(c)
                      j = j + 1
                    end
                    if pname == "" then pname = string.format("%02d", pad + 1) end
                  end
                  if (reaper.gmem_read(ib + pad * PAD_FIELDS + OFF_VER) or 0) == nver then
                    local _, cur_name = reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", "", false)
                    local nm_moved = blank or cst.nver == nil or nver ~= cst.nver
                    local nm_rejected = cst.npush and cst.npush_t and (now - cst.npush_t) > 3.0
                    if nm_moved or nm_rejected then
                      if cur_name ~= pname then
                        reaper.GetSetMediaTrackInfo_String(dest, "P_NAME", pname, true)
                        _lane_rename_touch()  -- mute the color-adopt gate: SWS re-colors on our rename
                      end
                      if not blank then cst.nver = nver end
                      if cst.npush and (nm_rejected or pname == cst.npush) then
                        cst.npush = nil ; cst.npush_t = nil
                      end
                    elseif INCMD_BASE and (not cst.npush) and (not blank)
                      and cur_name ~= "" and cur_name ~= pname then
                      -- user TCP rename -> reverse post (truncated to 32)
                      local nm = cur_name:sub(1, NAME_LEN)
                      local nbx = INCMD_BASE + slot * INCMD_STRIDE
                        + (G.INCMD_NAME_OFF or 64) + pad * (G.INCMD_NAME_FIELDS or 34)
                      for j = 1, NAME_LEN do
                        reaper.gmem_write(nbx + 1 + j, j <= #nm and nm:byte(j) or 0)
                      end
                      cst.ngen = (cst.ngen or 0) + 1
                      reaper.gmem_write(nbx + 1, cst.ngen)  -- gen 2nd-to-last
                      reaper.gmem_write(nbx + 0, 1)         -- flag LAST
                      cst.npush = nm ; cst.npush_t = now
                      -- Rename → category: a TCP child-track rename is the
                      -- same fresh name authority as the rename dialog
                      -- (guards + rationale in eon_padcat_apply_rename).
                      -- npush latches above, so this fires once per rename.
                      eon_padcat_apply_rename(slot, pad, nm)
                    end
                  end
                  -- MUTE/SOLO: edge-triggered two-way (E-1), same skeleton as
                  -- the color leg with 0/1 SET payloads. Stands down while a
                  -- paired StepSeq's banded mirror owns this instance's track
                  -- M/S (seq_owns). Blank pads: fully hands-off (no enforce —
                  -- a blank pad's track mute is the user's business).
                  if (not seq_owns) and (not blank) and OFF_MUTE then
                    local bm = ((reaper.gmem_read(ib + pad * PAD_FIELDS + OFF_MUTE) or 0) > 0.5) and 1 or 0
                    local tm = ((reaper.GetMediaTrackInfo_Value(dest, "B_MUTE") or 0) > 0) and 1 or 0
                    local m_moved = cst.bm == nil or bm ~= cst.bm
                    local m_rej = cst.mpush and cst.mpush_t and (now - cst.mpush_t) > 3.0
                    if m_moved or m_rej then
                      if tm ~= bm then
                        if reaper.GetExtState("EON_Bridge","debug_ms")=="1" then reaper.ShowConsoleMsg(("[ms] E1 fwd mute pad %d -> %d\n"):format(pad, bm)) end
                        reaper.SetMediaTrackInfo_Value(dest, "B_MUTE", bm)
                      end
                      cst.bm = bm
                      if cst.mpush and (m_rej or bm == cst.mpush) then
                        cst.mpush = nil ; cst.mpush_t = nil
                      end
                    elseif INCMD_BASE and (not cst.mpush) and tm ~= bm then
                      local cbm = INCMD_BASE + slot * INCMD_STRIDE
                        + (G.INCMD_MUTE_OFF or 640) + pad * 2
                      reaper.gmem_write(cbm + 1, tm)  -- payload FIRST
                      reaper.gmem_write(cbm + 0, 1)   -- flag LAST
                      cst.mpush = tm ; cst.mpush_t = now
                    end
                    local bs = ((reaper.gmem_read(ib + pad * PAD_FIELDS + OFF_SOLO) or 0) > 0.5) and 1 or 0
                    local ts = ((reaper.GetMediaTrackInfo_Value(dest, "I_SOLO") or 0) > 0) and 1 or 0
                    local s_moved = cst.bs == nil or bs ~= cst.bs
                    local s_rej = cst.spush and cst.spush_t and (now - cst.spush_t) > 3.0
                    if s_moved or s_rej then
                      if ts ~= bs then reaper.SetMediaTrackInfo_Value(dest, "I_SOLO", bs) end
                      cst.bs = bs
                      if cst.spush and (s_rej or bs == cst.spush) then
                        cst.spush = nil ; cst.spush_t = nil
                      end
                    elseif INCMD_BASE and (not cst.spush) and ts ~= bs then
                      local cbs = INCMD_BASE + slot * INCMD_STRIDE
                        + (G.INCMD_SOLO_OFF or 672) + pad * 2
                      reaper.gmem_write(cbs + 1, ts)  -- payload FIRST
                      reaper.gmem_write(cbs + 0, 1)   -- flag LAST
                      cst.spush = ts ; cst.spush_t = now
                    end
                  end
                  -- ICON (idempotent, per-instance) — P5. This path is now the SOLE
                  -- forward writer (the legacy name+icon refresher is gated off while
                  -- we service >=1 instance), so it must own the multi-out icon too.
                  -- Blank pad -> "" (clear); loaded -> resolver by band name. Uses the
                  -- per-instance blank state (hue sentinel), NOT shared pad_has_audio.
                  -- Guarded write (rk_lua_icons.apply) — user-set icons win over ours.
                  local want_icon = ""
                  if not blank then
                    local tcol = reaper.GetMediaTrackInfo_Value(dest, "I_CUSTOMCOLOR")
                    want_icon = bridge_icon_for_name(pname, tcol) or ""
                  end
                  if _bridge_icons and _bridge_icons.apply then
                    _bridge_icons.apply(dest, want_icon)
                  else
                    local _, cur_icon = reaper.GetSetMediaTrackInfo_String(dest, "P_ICON", "", false)
                    if cur_icon ~= want_icon then
                      reaper.GetSetMediaTrackInfo_String(dest, "P_ICON", want_icon, true)
                    end
                  end
                  -- OUTPUT routing is HARDWARE-OUTS semantics (user decision
                  -- 2026-06-12): children are FIXED outputs (send i = pair i,
                  -- never retargeted); the pad's OUT chooses which output it
                  -- feeds, and pads sharing an out MIX on that child. The
                  -- earlier follow-the-pad retarget DOUBLED audio (the moved
                  -- send + the pair's native child both pulled the same
                  -- channels) and was removed. The P_EXT pad tag still keys
                  -- identity, so painting stays correct regardless of OUT.
              end
            end
          end
          reaper.PreventUIRefresh(-1)
        end
      end
    end
  end
  -- Lens link upkeep. Runs AFTER the main walk so lens_parents is complete, and
  -- only when at least one instance was serviced: with no live map to judge
  -- against (project still loading, registry not resolved yet) every card would
  -- look like a stray. That guard opens no hole — an orphaned Lens is only
  -- dangerous while a live Swing exists to own the slot, and then serviced > 0.
  -- Separate enumeration on purpose: at ~1 Hz it is cheap, and it keeps this out
  -- of the per-instance block above.
  if lens_scan and serviced > 0 then
    local lens_found = {}
    for tr in core.iter_all_tracks() do
      for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
        if is_lens_fx(tr, fx) then lens_found[#lens_found + 1] = { tr = tr, fx = fx } end
      end
    end
    eon_lens_revoke_strays(lens_found, lens_parents)
  end
  return serviced
end

-- ─────────────────────────────────────────────────────────────────────────
-- EON: same-track StepSeq <-> Swing auto-pairing (identity refactor, Increment A)
-- ─────────────────────────────────────────────────────────────────────────
-- For each track that has BOTH a StepSeq and a Swing in its FX chain, resolve the
-- Swing's registry slot (ss_resolve_slot of its instance_id from param3) and push
-- SLOT+1 into the StepSeq's pairing slider (slider48 = param 47); 0 = unpaired, so
-- an unpaired StepSeq falls back to the shared-META scan (back-compat). The StepSeq
-- then reads THAT instance's IDENT band for lane hue/name, so two StepSeq+Swing
-- pairs no longer cross-read the single shared blob. Idempotent: only writes the
-- param when it actually changes. Manual cross-track override (the picker) layers
-- on top next. Module-GLOBAL (200-local ceiling) like ss_resolve_slot.
function refresh_stepseq_pairing()
  -- Rebuild the "which registry slots have a StepSeq paired to them" set each
  -- pass (module-global, 200-local rule). The E-1 M/S stand-down keys off
  -- THIS — pairing existence, not banded-heartbeat liveness — because the
  -- heartbeat stalls every time the audio device closes (@block stops) and a
  -- liveness-keyed gate would flap: the pad-M/S leg would wake, first-sight
  -- snap the tracks to the pad state, and stomp lane-driven TCP mutes.
  local owned = {}
  local any_unpaired = false
  for tr in core.iter_all_tracks() do
    local ss_fx, sw_fx = nil, nil
    local nfx = reaper.TrackFX_GetCount(tr)
    local fx = 0
    while fx < nfx do
      if not ss_fx and is_stepseq_fx(tr, fx) then ss_fx = fx end
      if not sw_fx and is_swing_fx(tr, fx)   then sw_fx = fx end
      fx = fx + 1
    end
    if ss_fx then
      -- Resolve the pairing slider's PARAM INDEX by NAME. JSFX sparse-slider ->
      -- param-index mapping is NOT slider#-1 when slider numbers have gaps (StepSeq's
      -- do), so hardcoding 47 set the WRONG param and the pairing never landed. Match
      -- the "EON Pair Slot" param name instead — robust to the actual mapping.
      local pair_param = nil
      local np = reaper.TrackFX_GetNumParams(tr, ss_fx)
      local p = 0
      while p < np do
        local _, pn = reaper.TrackFX_GetParamName(tr, ss_fx, p, "")
        if pn and pn:find("Pair Slot") then pair_param = p; break end
        p = p + 1
      end
      if pair_param then
        -- want: nil = HOLD current value (resolution unavailable), 0 = explicit unpair,
        -- +N/-N = auto/manual slot+1. STICKY policy: a stale registry heartbeat does NOT
        -- end a pairing — Swing's @block (and so its heartbeat) stops whenever REAPER
        -- closes the audio device, and pushing 0 then re-pushing slot+1 on every device
        -- close/reopen made REAPER record an "Edit FX parameter" undo point per write
        -- (undo-history spam + mid-stack undo position resets). Only write 0 when the
        -- Swing is genuinely GONE (no FX to pair with), and never write while merely
        -- unresolvable. Every write here costs the user an undo point.
        local want = nil
        -- MANUAL OVERRIDE wins over same-track auto: a persisted P_EXT:EON_SS_PAIR
        -- ("guid|regid") on the StepSeq's track points at a specific Swing (possibly on
        -- another track). Re-resolve the GUID to a live FX each tick (GUID survives
        -- reorder/reload; fx-index does not). If the FX itself no longer exists, fall
        -- through to same-track auto (self-heals when the paired Swing is gone).
        local resolved = false
        local _, pair = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_SS_PAIR", "", false)
        local m_guid = pair and pair:match("^([^|]*)") or ""
        if m_guid ~= "" then
          local swtr, swfx = ss_resolve_swing_by_guid(m_guid)
          if swtr then
            resolved = true   -- FX alive: manual pairing stands even if hb is stale
            local inst_id = math.floor(reaper.TrackFX_GetParam(swtr, swfx, 3) or 0)
            local slot = ss_resolve_slot(inst_id)
            -- NEGATIVE = manual pairing (the StepSeq dropdown checkmarks "Auto" vs the
            -- manual row off the sign; eon_pair_slot = abs(slider48)-1 either way).
            if slot then want = -(slot + 1) end
          end
        end
        if not resolved then
          if sw_fx then
            local inst_id = math.floor(reaper.TrackFX_GetParam(tr, sw_fx, 3) or 0)
            local slot = ss_resolve_slot(inst_id)
            if slot then want = slot + 1 end
            -- slot==nil: Swing present but heartbeat stale/unregistered -> HOLD
          else
            want = 0   -- no manual target, no same-track Swing: genuine unpair
          end
        end
        local cur = math.floor(reaper.TrackFX_GetParam(tr, ss_fx, pair_param) or 0)
        if want and cur ~= want then
          reaper.TrackFX_SetParam(tr, ss_fx, pair_param, want)
          -- FIRST pairing of a fresh StepSeq (cur == 0 -> paired). Saved projects
          -- reload with a persisted nonzero pair slot, so they never pass
          -- through here — their own slider values stand.
          if cur == 0 and want ~= 0 then
            -- Fresh-instance default: land on Pattern 1. slider1 is the first
            -- slider so param 0 is gap-proof; still verify by name in case the
            -- layout ever changes. (The DM-current follow can push a brand-new
            -- instance to another pattern before the user ever sees it.)
            local _, p0n = reaper.TrackFX_GetParamName(tr, ss_fx, 0, "")
            if p0n and p0n:find("Pattern") then
              reaper.TrackFX_SetParam(tr, ss_fx, 0, 0)
            end
            -- Sync-on-open default: enforce the machine default (SETTINGS
            -- "Sync on by default" -> ExtState EON_StepSeq/sync_on_open,
            -- "0" = off, unset = on). slider49 now DEFAULTS ON in the JSFX
            -- (a Steppa inserted with no Swing still comes up armed), so this
            -- write's real job is making an explicit machine-wide Off stick.
            -- SYMMETRIC (writes 0 too), value-guarded (writes = undo points).
            -- Param resolved BY NAME like Pair Slot above (sparse sliders).
            local sync_param = nil
            local p2 = 0
            while p2 < np do
              local _, pn2 = reaper.TrackFX_GetParamName(tr, ss_fx, p2, "")
              if pn2 and pn2:find("Sync Mode") then sync_param = p2; break end
              p2 = p2 + 1
            end
            if sync_param then
              local sync_want = reaper.GetExtState("EON_StepSeq", "sync_on_open") ~= "0" and 1 or 0
              if math.floor(reaper.TrackFX_GetParam(tr, ss_fx, sync_param) or 0) ~= sync_want then
                reaper.TrackFX_SetParam(tr, ss_fx, sync_param, sync_want)
              end
            end
          end
          if reaper.GetExtState("EON_Bridge", "debug_pairing") == "1" then
            reaper.ShowConsoleMsg(string.format("[bridge] pair write tr=%s cur=%d want=%d\n",
              tostring(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER")), cur, want))
          end
        end
        -- Effective pairing after this pass: the value we just wrote, or the
        -- held current value. Nonzero -> that slot's track M/S is owned by
        -- this StepSeq's mirror (E-1 stand-down reads _seq_ms_owned).
        local eff = want or cur
        if eff ~= 0 then owned[math.abs(eff) - 1] = true else any_unpaired = true end
      end
    end
  end
  _seq_ms_owned = owned
  -- Gate for the LEGACY global M/S force-mirror: it must only run when an
  -- UNPAIRED StepSeq actually exists. A paired StepSeq still advances the
  -- legacy heartbeat (pre-E-2 JSFX), so heartbeat liveness is NOT a valid
  -- "legacy consumer present" signal — it kept the force-mirror alive and it
  -- stomped user TCP mutes on the active Swing's children every pass.
  _seq_any_unpaired = any_unpaired
end

-- Re-resolve a stored Swing FX GUID to its live (track, fx) by scanning all tracks/FX
-- (there is no TrackFX_GetByGUID; the GUID survives reorder/reload, the fx-index does not).
-- Returns track, fx or nil. Module-GLOBAL (200-local ceiling) like the other pairing fns.
function ss_resolve_swing_by_guid(guid)
  if not guid or guid == "" then return nil end
  for tr in core.iter_all_tracks() do
    local nfx = reaper.TrackFX_GetCount(tr)
    local fx = 0
    while fx < nfx do
      if is_swing_fx(tr, fx) and reaper.TrackFX_GetFXGUID(tr, fx) == guid then
        return tr, fx
      end
      fx = fx + 1
    end
  end
  return nil
end

-- (The right-click gfx.showmenu pairing picker was removed — the StepSeq no longer raises
-- GS_SS_PICKER_REQ. Pairing now goes through the in-window PAIR dropdown, whose selection
-- is consumed by handle_stepseq_picker_sel below.)

-- Publish the live Swing ROSTER to gmem so the StepSeq's custom PAIR dropdown can render
-- instance labels (a JSFX can't read track names). Per registry slot (16): [0]=live flag,
-- [1..14]=track-name chars (truncated, 0-padded). Region 2760..2999 — the last block ends
-- at 2999, just under KIT_GMEM_AUDIO at 3000. Module-global (200-local ceiling).
function publish_swing_roster()
  local BASE, STRIDE, MAXS, LBL = 2760, 15, 16, 14
  local seen = {}
  for tr in core.iter_all_tracks() do
    local nfx = reaper.TrackFX_GetCount(tr)
    local fx = 0
    while fx < nfx do
      if is_swing_fx(tr, fx) then
        local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        local slot = ss_resolve_slot(inst_id)
        if slot and slot >= 0 and slot < MAXS and not seen[slot] then
          seen[slot] = true
          local _, tn = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
          if not tn or tn == "" then
            tn = "Track " .. math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0)
          end
          local b = BASE + slot * STRIDE
          reaper.gmem_write(b, 1)
          for i = 1, LBL do
            reaper.gmem_write(b + i, (i <= #tn) and tn:byte(i) or 0)
          end
        end
      end
      fx = fx + 1
    end
  end
  for slot = 0, MAXS - 1 do
    if not seen[slot] then reaper.gmem_write(BASE + slot * STRIDE, 0) end
  end
end

-- Selection coming back from the StepSeq's custom PAIR dropdown: gmem[2751] = 1 (Auto)
-- or slot+2 (pair to that registry slot). Same identity trick as the native-menu picker:
-- the user just clicked the StepSeq's UI, so GetFocusedFX2 IS the requesting instance.
-- Persists/clears P_EXT:EON_SS_PAIR, then re-runs the pairing refresh immediately so the
-- StepSeq's button label updates on its next frame. Module-global (200-local ceiling).
function handle_stepseq_picker_sel()
  local SEL = 2751
  local v = math.floor(reaper.gmem_read(SEL) or 0)
  if v <= 0 then return end
  reaper.gmem_write(SEL, 0)   -- consume
  local rv, trnum, itnum, fxnum = reaper.GetFocusedFX2()
  if not rv or rv == 0 or (itnum and itnum >= 0) then return end
  local sstr = (trnum == 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, trnum - 1)
  if not sstr or not is_stepseq_fx(sstr, fxnum) then return end
  if v == 1 then
    reaper.GetSetMediaTrackInfo_String(sstr, "P_EXT:EON_SS_PAIR", "", true)
  else
    local want_slot = v - 2
    for tr in core.iter_all_tracks() do
      local nfx = reaper.TrackFX_GetCount(tr)
      local fx = 0
      while fx < nfx do
        if is_swing_fx(tr, fx) then
          local regid = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
          if ss_resolve_slot(regid) == want_slot then
            reaper.GetSetMediaTrackInfo_String(sstr, "P_EXT:EON_SS_PAIR",
              reaper.TrackFX_GetFXGUID(tr, fx) .. "|" .. regid, true)
            refresh_stepseq_pairing()
            return
          end
        end
        fx = fx + 1
      end
    end
  end
  refresh_stepseq_pairing()
end

-- EON: BANDED StepSeq->Swing mute/solo mirror (identity refactor, final brick).
-- A PAIRED StepSeq writes its lane M/S into its paired Swing's registry-slot band
-- (EON_StepSeq.jsfx eon_publish_ms): 26020000 + slot*40, [0]=heartbeat, [1]=anysolo,
-- [2..17]=per-pad mute, [18..33]=per-pad solo. Mirror each LIVE band onto that Swing's
-- own multi-out child tracks -- two StepSeq+Swing pairs no longer collide on the global
-- 2710-2745 region (which stays, with eon_mirror_stepseq_ms, as the UNPAIRED fallback;
-- once every StepSeq is paired its heartbeat stalls and that mirror goes quiet).
-- Hold/release semantics match the legacy mirror: heartbeat stall -> release ONLY the
-- mute/solo this mirror applied. Module-global + lazy global state (200-local ceiling).
function eon_mirror_stepseq_ms_banded()
  local BASE, STRIDE = 26020000, 80
  -- [slot] = { last_alive, stall, applied={pad->{m,s}}, last_m={pad->0/1}, last_s={pad->0/1} }
  _ss_msb_state = _ss_msb_state or {}
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local slot = ss_resolve_slot(math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0))
        if slot then
          local st = _ss_msb_state[slot]
          if not st then st = { applied = {}, last_m = {}, last_s = {} }; _ss_msb_state[slot] = st end
          local b = BASE + slot * STRIDE
          local alive = math.floor(reaper.gmem_read(b) or 0)
          local live
          if alive ~= st.last_alive then
            st.last_alive = alive; st.stall = 0; live = true
          else
            st.stall = (st.stall or 0) + 1
            live = st.stall < 20            -- tolerate a few stalled polls before "dead"
          end
          if live or next(st.applied) ~= nil then
            local sends = reaper.GetTrackNumSends(tr, 0)
            for s = 0, sends - 1 do
              local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN"))
              if pad >= 0 then
                -- (nesting kept: core.srcchan_pad already rejects no-audio/odd)
                if pad >= 0 and pad < G.NUM_PADS then
                  local dest = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
                  if dest and reaper.ValidatePtr(dest, 'MediaTrack*') then
                    if live then
                      -- TWO-WAY, edge-triggered. Forward (StepSeq -> track) fires only
                      -- when the BAND value changes; while the band is stable, a track
                      -- that diverges means the USER edited it in the TCP -> queue a
                      -- reverse-adopt command for the StepSeq instead of stomping them.
                      local band_m = (math.floor(reaper.gmem_read(b + 2 + pad) or 0) > 0) and 1 or 0
                      local band_s = (math.floor(reaper.gmem_read(b + 18 + pad) or 0) > 0) and 1 or 0
                      local fwd_m = band_m ~= st.last_m[pad]
                      local fwd_s = band_s ~= st.last_s[pad]
                      st.last_m[pad] = band_m
                      st.last_s[pad] = band_s
                      local track_m = ((reaper.GetMediaTrackInfo_Value(dest, "B_MUTE") or 0) > 0) and 1 or 0
                      local track_s = ((reaper.GetMediaTrackInfo_Value(dest, "I_SOLO") or 0) > 0) and 1 or 0
                      if track_m ~= band_m then
                        if fwd_m then
                          if reaper.GetExtState("EON_Bridge","debug_ms")=="1" then reaper.ShowConsoleMsg(("[ms] BANDED fwd mute pad %d -> %d\n"):format(pad, band_m)) end
                          reaper.SetMediaTrackInfo_Value(dest, "B_MUTE", band_m)
                        else
                          if reaper.GetExtState("EON_Bridge","debug_ms")=="1" then reaper.ShowConsoleMsg(("[ms] BANDED revcmd pad %d cmd=%d\n"):format(pad, track_m + 1)) end
                          reaper.gmem_write(b + 40 + pad, track_m + 1)   -- 1=set OFF, 2=set ON
                        end
                      end
                      if track_s ~= band_s then
                        if fwd_s then
                          reaper.SetMediaTrackInfo_Value(dest, "I_SOLO", band_s)
                        else
                          reaper.gmem_write(b + 56 + pad, track_s + 1)
                        end
                      end
                      if band_m == 1 or band_s == 1 then
                        st.applied[pad] = { m = band_m, s = band_s }
                      else
                        st.applied[pad] = nil
                      end
                    else
                      -- StepSeq gone -> release ONLY the mute/solo this mirror applied.
                      local prev = st.applied[pad]
                      if prev and prev.m == 1 then
                        if (reaper.GetMediaTrackInfo_Value(dest, "B_MUTE") or 0) ~= 0 then
                          if reaper.GetExtState("EON_Bridge","debug_ms")=="1" then reaper.ShowConsoleMsg(("[ms] BANDED release pad %d\n"):format(pad)) end
                          reaper.SetMediaTrackInfo_Value(dest, "B_MUTE", 0)
                        end
                      end
                      if prev and prev.s == 1 then
                        if ((reaper.GetMediaTrackInfo_Value(dest, "I_SOLO") or 0) > 0) then
                          reaper.SetMediaTrackInfo_Value(dest, "I_SOLO", 0)
                        end
                      end
                    end
                  end
                end
              end
            end
            if not live then st.applied = {}; st.last_m = {}; st.last_s = {} end
          end
        end
      end
    end
  end
end

-- ─────────────────────────────────────────────────────────────────────────
-- REVERSE-DIRECTION SYNC: TCP/MCP track edits → JSFX/Browser
-- ─────────────────────────────────────────────────────────────────────────
-- When the user renames or recolors a multi-out child track DIRECTLY in
-- REAPER's TCP, propagate that change back into the JSFX (and from there
-- to the browser). Forward direction (JSFX → tracks) lives in the two
-- existing refresh_multiout_*_if_changed functions; these are their
-- mirror images.
--
-- Hash-debounced like the forward versions, so when names/colors haven't
-- changed (or no multi-out tracks exist), these functions are nearly
-- free (~16 API calls per poll tick).

local last_tcp_name_hash  = 0
local last_tcp_color_hash = 0

local function refresh_pad_names_from_tracks_if_changed()
  -- Skip reverse sync while a command is pending — the JSFX may have
  -- written fresh pad names to gmem that CMD=52 hasn't pushed to
  -- tracks yet.  Without this guard, we'd read the stale TCP name and
  -- overwrite the fresh gmem name before the cmd dispatch runs.
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then return end
  local swing_track = find_swing_track()
  if not swing_track then return end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < G.NUM_PADS then return end

  -- Read each multi-out track's P_NAME and build a hash that includes
  -- both the names AND the pad indices (so swapping tracks for the same
  -- pad indices doesn't escape detection).
  local hash = 1
  local tcp_names = {}  -- [pad_idx] = name
  for s = 0, sends - 1 do
    local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if pad >= 0 then
      -- (nesting kept: core.srcchan_pad already rejects no-audio and odd channels)
      if pad >= 0 and pad < G.NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          local _, tname = reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", "", false)
          tcp_names[pad] = tname or ""
          hash = (hash * 31 + pad) % 0x7FFFFFFF
          for i = 1, #(tname or "") do
            hash = (hash * 31 + string.byte(tname, i)) % 0x7FFFFFFF
          end
        end
      end
    end
  end
  if hash == last_tcp_name_hash then return end
  last_tcp_name_hash = hash

  -- Compare each TCP name against gmem PADNAME. If different, write the
  -- TCP name into gmem so the JSFX gmem-watcher picks it up next @gfx.
  -- Note: we DON'T write all names every change — only the ones that
  -- actually differ, to avoid clobbering names the JSFX wrote (which
  -- would trigger an oscillation).
  for pad, tname in pairs(tcp_names) do
    if tname ~= "" then
      -- Read current gmem PADNAME for this pad
      local cur = ""
      for j = 0, G.PADNAME_LEN - 1 do
        local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + pad * G.PADNAME_LEN + j))
        if c > 0 then cur = cur .. string.char(c) else break end
      end
      -- Multi-out tracks default to "01", "02", ... when built by
      -- do_build_multiout. Skip those numeric defaults so we don't
      -- overwrite a real pad name with a placeholder track name.
      local is_default = tname:match("^%d%d$") or tname == ""
      if tname ~= cur and not is_default then
        local truncated = tname:sub(1, G.PADNAME_LEN)
        for j = 0, G.PADNAME_LEN - 1 do
          local c = j < #truncated and string.byte(truncated, j + 1) or 0
          reaper.gmem_write(G.PADNAME_BASE + pad * G.PADNAME_LEN + j, c)
        end
      end
    end
  end
end

local function refresh_pad_colors_from_tracks_if_changed()
  -- Same guard as name reverse sync — don't clobber gmem hues while a
  -- command is in flight (e.g. auto-color rebuild via CMD 63/64).
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 then return end
  local swing_track = find_swing_track()
  if not swing_track then return end
  local sends = reaper.GetTrackNumSends(swing_track, 0)
  if sends < G.NUM_PADS then return end

  -- Lane color ownership: "none" never reads track colors back into the pad.
  local _rwt, _rrt = bridge_lane_policy(swing_track)
  if not _rrt then return end

  -- Hash all 16 multi-out track colors. Quantize to int (they already are).
  local hash = 1
  local tcp_colors = {}  -- [pad_idx] = raw I_CUSTOMCOLOR with flag
  local tcp_dest = {}    -- [pad_idx] = dest track (for the selection gate)
  for s = 0, sends - 1 do
    local pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(swing_track, 0, s, "I_SRCCHAN"))
    if pad >= 0 then
      -- (nesting kept: core.srcchan_pad already rejects no-audio and odd channels)
      if pad >= 0 and pad < G.NUM_PADS then
        local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
        if dest_tr then
          local raw_color = math.floor(reaper.GetMediaTrackInfo_Value(dest_tr, "I_CUSTOMCOLOR") or 0)
          tcp_colors[pad] = raw_color
          tcp_dest[pad]   = dest_tr
          hash = (hash * 31 + pad) % 0x7FFFFFFF
          hash = (hash * 31 + raw_color) % 0x7FFFFFFF
        end
      end
    end
  end
  if hash == last_tcp_color_hash then return end
  last_tcp_color_hash = hash

  -- For each pad, if the TCP color is set (0x1000000 flag) AND the
  -- corresponding hue in gmem differs from what RGB→hue produces from
  -- the TCP color, write the new hue. The forward-sync function will
  -- next tick set the TCP color from hue+S/L and the hashes will
  -- converge — so a TCP rename + recolor stabilizes within one cycle.
  for pad, raw_color in pairs(tcp_colors) do
    -- 0x1000000 = "use custom color" flag. Without it, REAPER returns 0
    -- or uses default — skip those (no explicit color set by user).
    -- Gesture gate: adopt only as a HUMAN edit — the lane must be SELECTED
    -- (SWS Auto Color never selects) and we must not have just renamed a lane
    -- (SWS re-colors on our SetTrackTitle). "reaper" mode bypasses the gate.
    local dtr = tcp_dest[pad]
    local gesture = (not _rwt)
      or (dtr and reaper.IsTrackSelected(dtr)
          and reaper.time_precise() >= _lane_rename_quiet_until)
    if gesture and (raw_color & 0x1000000) ~= 0 then
      local color = raw_color & 0xFFFFFF
      local r, g, b = reaper.ColorFromNative(color)
      local new_hue = core.rgb_to_hue(r, g, b)
      local cur_hue = reaper.gmem_read(G.META_BASE + pad * G.META_PP + 12) or 0
      -- Tolerance: 0.005 hue ~ 1.8° — below visible difference
      if math.abs(new_hue - cur_hue) > 0.005 then
        reaper.gmem_write(G.META_BASE + pad * G.META_PP + 12, new_hue)
      end
    end
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- AUTO-KIT-SIDECAR — bypasses REAPER chunk-size truncation for big kits
-- ═════════════════════════════════════════════════════════════════════════════
-- On project save: write a `.swing` file per Swing instance into the project
-- folder. On project open / new instance detection: auto-load that sidecar
-- via existing kit-load infrastructure. The embedded chunk continues to be
-- written (small kit fallback for "user emails .rpp alone"), but sidecars
-- always win on load if present, so big kits round-trip reliably.

local prev_proj_dirty = -1                -- IsProjectDirty value last poll (-1 = first poll)
local prev_proj_filename = ""             -- detect project switches / reopens
local primed_instances = {}               -- inst_id → true once we've checked for sidecar
local pending_load_queue = {}             -- queue of {inst_id, tr, fx, path, guid, preserve, retries}
-- Phase 1 (2026-07-17): the old AUDIOLEN-based reload-completeness verify
-- (MAX_KIT_LOAD_RETRY / kit_load_retry / load_verify_queue) is RETIRED. It
-- counted "loaded pads" from the AUDIOLEN band, which is a @gfx blast-mirror
-- refreshed ONLY for the browser-target instance — for any other instance it
-- read zero and silently re-queued the same kit up to 3 times (a live
-- spurious-reload / "loads twice" vector). The GS_LOAD_ACK epoch echo +
-- ACK_FAILBITS now classify every dispatch definitively; failures retry once
-- through eon_load_report below.
local current_load = nil                  -- in-flight load: {inst_id, path, started_at, epoch, item} or nil
-- Failure reporter for the load pipeline: ONE formatting point so probes and
-- users can grep "[Swing] kit load" lines. GLOBAL — the bridge's main chunk
-- is at Lua's 200-local limit ("too many local variables" if this were local).
-- UNIFIED USER-LOAD ENTRY (2026-07-19). EVERY user-facing kit load goes through
-- the queue, so the in-plugin LOAD button gets the same protections the browser
-- path has had since Phase 1: the pump-drain gate (a draining v26 stream can't
-- stomp the next load's staged paths), epoch/ack completion tracking, the
-- retry-on-failed-pads backstop, and serialization against in-flight loads.
-- do_import / do_import_browse called load_swing_dispatch DIRECTLY — not by
-- choice, but because they are defined ABOVE the queue and never had it in
-- scope — so the button silently bypassed all of it. GLOBAL: Lua resolves
-- globals at CALL time, so those earlier-defined functions reach this fine.
-- Returns false when no live instance can receive the load (caller should
-- reset the JSFX with CMD 98 rather than leave it armed forever).
function eon_enqueue_kit_load(filepath, want_inst)
  if not filepath or filepath == "" then return false end
  local want = math.floor(want_inst or 0)
  if want <= 0 then want = math.floor(reaper.gmem_read(G.LOCK) or 0) end        -- LOAD button takes LOCK
  if want <= 0 then want = math.floor(reaper.gmem_read(G.INSTANCE) or 0) end    -- browser binding
  -- tr/fx/guid deliberately left nil: the POP resolves them (and re-resolves a
  -- stale/booting id, falling back to the first live instance, then retries
  -- once before reporting). Doing it here would need enumerate_all_swings,
  -- which is declared BELOW this point and is therefore not in scope — the
  -- exact nil-call that broke the LOAD button on first live use.
  pending_load_queue[#pending_load_queue + 1] = {
    path = filepath, preserve = false,
    inst_id = (want > 0) and want or nil,
  }
  return true
end

function eon_load_report(msg)
  -- Console line is GATED (same convention as repair_debug below):
  -- ShowConsoleMsg OPENS the console, so an ungated one pops a window at a
  -- customer on every kit load — including project open and a fresh insert.
  -- The :7456 route-report TODO ("gate on an ExtState debug flag before
  -- release") is this gate. Enable with:
  --   reaper.SetExtState("EON_Swing", "load_debug", "1", false)
  if reaper.GetExtState("EON_Swing", "load_debug") == "1" then
    reaper.ShowConsoleMsg("[Swing] kit load " .. msg .. "\n")
  end
  -- Always tee to the bounded session log — invisible, and it is what headless
  -- probes AND live post-mortems actually read (2026-07-19 silent-empty-pads
  -- hunt). Gating the console line costs no diagnostic capability.
  local dir = reaper.GetResourcePath() .. "/Data/EON_Swing"
  reaper.RecursiveCreateDirectory(dir, 0)
  local lp = dir .. "/load_log.txt"
  local sz = 0
  local fr = io.open(lp, "rb"); if fr then sz = fr:seek("end") or 0; fr:close() end
  local f = io.open(lp, sz > 262144 and "w" or "a")   -- reset past 256KB
  if f then f:write(os.date("%H:%M:%S") .. " " .. msg .. "\n"); f:close() end
end
-- kit_sources is declared at file top (before load_swing_dispatch) so the
-- recording hook inside that function can see it via lexical scope. See
-- "AUTO-KIT-SIDECAR — kit_sources" further up the file.

-- Sanitize a REAPER track GUID "{A0CD27B9-E1D5-...}" into a filename-safe token
-- (hex only, no braces/dashes). The GUID is project-unique and save-persistent,
-- so it can't collide across projects the way the session-counter instance_id can.
local function guid_token(guid)
  if not guid or guid == "" then return nil end
  return (guid:gsub("[^%w]", ""))  -- strip { } and - → 32 hex chars
end

-- Get the sidecar `.swing` path for a track GUID, or nil if project unsaved.
-- Format: <projectfolder>/Swing/swing_<guidtoken>.swing
-- Keyed by track GUID (not the colliding integer instance_id) so two projects'
-- tracks can never share a sidecar filename.
local function get_sidecar_path(guid)
  local tok = guid_token(guid)
  if not tok then return nil end
  local _, proj_filename = reaper.EnumProjects(-1)
  if not proj_filename or proj_filename == "" then return nil end
  local proj_dir = proj_filename:match("(.*[/\\])")
  if not proj_dir then return nil end
  -- Subfolder keeps multi-instance projects tidy; create on demand
  local sidecar_dir = proj_dir .. "Swing"
  reaper.RecursiveCreateDirectory(sidecar_dir, 0)
  return sidecar_dir .. core.sep .. "swing_" .. tok .. ".swing"
end

-- Legacy integer-id sidecar path (pre-GUID scheme). Used ONLY as a one-time
-- read fallback so projects saved before this change still auto-load their kit
-- until they're re-saved (which writes the GUID-named sidecar). Never written.
local function get_legacy_sidecar_path(inst_id)
  if not inst_id or inst_id <= 0 then return nil end
  local _, proj_filename = reaper.EnumProjects(-1)
  if not proj_filename or proj_filename == "" then return nil end
  local proj_dir = proj_filename:match("(.*[/\\])")
  if not proj_dir then return nil end
  return proj_dir .. "Swing" .. core.sep .. "swing_" .. math.floor(inst_id) .. ".swing"
end

-- Enumerate every Swing instance on the project (track + fx + instance_id).
-- Also rehydrate kit_sources from track ExtState (P_EXT:swing_kit_src) so
-- legacy projects opened in a fresh bridge session inherit their saved
-- kit-source paths without requiring a manual reload.
local function enumerate_all_swings()
  if _eon_perf then _eon_perf.walks = _eon_perf.walks + 1 end
  local list = {}
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        if inst_id > 0 then
          -- Track GUID: project-unique, save-persistent. This is the sidecar/
          -- kit_sources key (the integer inst_id stays for JSFX command routing).
          local guid = reaper.GetTrackGUID(tr)
          -- Pull persisted kit_source path from this track's own ExtState into
          -- the in-memory table, keyed by GUID, but only if not already set this
          -- session (we trust live loads over the persisted hint).
          if guid and guid ~= "" and not kit_sources[guid] then
            local _, src = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", "", false)
            if src and src ~= "" then
              kit_sources[guid] = src
            end
          end
          list[#list + 1] = { tr = tr, fx = fx, inst_id = inst_id, guid = guid }
        end
      end
    end
  end
  return list
end

-- ── Kit-categories ④ FILL-FROM-KIT (user decision 2026-07-24: OPTION B) ────
-- Spec_Swing_Kit_Categories rev 2026-07-23. FILL = explicit browser action
-- (GS_KIT_LOAD_MODE=1 riding the kit-load request): treat the kit as a
-- content SET — zip-match its samples onto THIS rack's pad categories, then
-- issue per-pad CMD 63/64 browse-loads for MATCHED pads only. Its OWN path,
-- deliberately NOT a remap inside load_kit_v4 (four route cascades in the
-- historical ship-blocker path stay untouched; B is additive and cannot
-- regress loading). Consequences that fall out for free:
--   - unmatched / uncategorised / locked rack pads are NEVER ADDRESSED
--     (audio untouched — no skip-hack needed, never blank);
--   - categories are NOT touched -> no ADAPT snapshot, no chip, no P_EXT
--     rewrite (that IS the semantic difference from LOAD);
--   - the pad keeps ITS knobs/note/choke — FILL changes content, not layout.
-- Matching (spec 8a): per category, kit srcs ascending zip rack dsts
-- ascending; rack pads > kit samples => CYCLE; surplus kit samples =>
-- reported, never dumped. Kits without category data (pre-v4 binary) =>
-- REFUSE with a message (user decision (a) — never silent positional).
-- Sample source per matched pad: the kit's ORIGINAL file when readable
-- (provenance kept, browse-load parity), else extracted store WAV via the
-- EXISTING px machinery (eon_stage_kit_store_paths — idempotent; its staged
-- path cells are inert while no import is armed, and we gate on an idle
-- pipeline). CMD is a single-slot mailbox -> defer state machine, one
-- CMD 63 (clean pad replace, layer 0) or CMD 64 (add layer N) per idle tick.
-- ⚠️ Multi-layer caveat: CMD 63 forces layer_mode; per-layer vel/RR windows
-- don't travel over the browse protocol — layered pads fill with their
-- layers but browse-load semantics. Single-layer pads (the norm) are exact.
-- GLOBALS (bridge main chunk is at Lua's 200-local ceiling — padcat
-- precedent); defined AFTER current_load/pending_load_queue so the idle
-- gate binds them as upvalues.

-- Parse-only twin of load_kit_v4's reader: kit table + captured audio blobs
-- + per-pad layer counts (binary truth). No gmem writes, no staging.
function eon_fill_parse_kit_v4(filepath)
  local f = io.open(filepath, "rb")
  if not f then return nil, "could not open kit file" end
  local content = f:read("*a")
  f:close()
  if #content < 16 or content:sub(1, 8) ~= "SWINGv04" then
    return nil, "this kit has no category data — use Load"
  end
  local lua_len = math.floor(string.unpack("<d", content, 9))
  -- Positive-form guard: NaN fails every comparison (see load_kit_v4).
  if not (lua_len > 0 and 16 + lua_len <= #content) then
    return nil, "corrupt v4 header"
  end
  local chunk = load(content:sub(17, 16 + lua_len), "swing_v4_fill", "t", {})
  if not chunk then return nil, "invalid v4 Lua section" end
  local ok, kit = pcall(chunk)
  if not ok or type(kit) ~= "table" then return nil, "invalid v4 kit data" end
  -- Binary walk (read-only): per pad [lc:8B] then ((lc==0) and 1 or lc)
  -- blobs of [len:8B][sr:8B][PCM len*2] — mirrors read_blob's truncation
  -- tolerance (short blob -> len 0, walk stays aligned).
  local pos, blobs, plc = 17 + lua_len, {}, {}
  for pad = 0, G.NUM_PADS - 1 do
    local lc = 0
    if pos + 7 <= #content then
      lc = math.floor(string.unpack("<d", content, pos)); pos = pos + 8
      if not (lc > 0) then lc = 0 end           -- NaN/negative land on 0 too
      if lc > G.MAX_LAYERS then lc = G.MAX_LAYERS end
    end
    plc[pad] = lc
    for layer = 0, (lc == 0) and 0 or lc - 1 do
      local alen, sr, bytes = 0, 0, ""
      if pos + 15 <= #content then
        alen = math.floor(string.unpack("<d", content, pos)); pos = pos + 8
        sr = string.unpack("<d", content, pos); pos = pos + 8
        if not (sr >= 0 and sr < 1e7) then sr = 0 end
        if alen > 0 then
          if pos + alen * 2 - 1 <= #content then
            bytes = content:sub(pos, pos + alen * 2 - 1)
          end
          pos = pos + alen * 2
          if #bytes == 0 then alen = 0 end
        else
          alen = 0   -- negative or NaN: treat as an empty blob
        end
      end
      blobs[#blobs + 1] = { pad = pad, layer = layer, len = alen, sr = sr,
                            bytes = bytes, first = (layer == 0) }
    end
  end
  return kit, blobs, plc
end

-- ── Embed-on-insert: FX-browser parity for the MCP house default ───────────
-- The song starter and the RS5k import embed Swing in the MCP because they DO
-- the insert; a Swing added from REAPER's own FX browser had no hook and
-- opened un-embedded (portable-install report 2026-08-19). The JSFX writes
-- itself into the gmem instance registry on its first @block, so a NEW id
-- appearing mid-session IS the fresh-insert event, whatever UI performed the
-- insert.
--
-- Same contract as strip_sync's ensure_strip: FRESH INSERTS ONLY. Instances
-- present when the bridge starts, or arriving with a project/tab switch, are
-- adopted untouched (a user who un-embedded keeps their choice). Keyed by FX
-- GUID so each instance is defaulted at most once per session -- registry ids
-- can re-mint on recompile without re-triggering (the GUID stays put).
--
-- ⚠️ fx_embed_mcp rewrites the track chunk, which reloads the FX chain -- NOT
-- safe mid-kit-load (it would cut the auto-load handshake). A registry change
-- therefore only ARMS the sweep; it runs once the change is ~1.5s old AND the
-- pipeline is idle (the same gate eon_fill_tick uses), then embeds unseen
-- GUIDs exactly once. False arms (id re-mint, instance removal) are free: the
-- sweep finds no unseen GUID and does nothing.
eon_embed_seen    = {}    -- fx GUID -> true (adopted or already defaulted)
eon_embed_pending = nil   -- time the registry last changed, while unswept
eon_embed_reg     = nil   -- last registry fingerprint ("id@slot;...")
eon_embed_proj    = nil   -- project at last adoption snapshot

function eon_embed_snapshot()
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local g = reaper.TrackFX_GetFXGUID(tr, fx)
        if g then eon_embed_seen[g] = true end
      end
    end
  end
end

function eon_embed_tick()
  local fp = {}
  for slot = 0, G.GS_INST_REG_MAX - 1 do
    local id = math.floor(reaper.gmem_read(
      G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
    if id ~= 0 then fp[#fp + 1] = id .. "@" .. slot end
  end
  fp = table.concat(fp, ";")

  local proj = reaper.EnumProjects(-1)
  if proj ~= eon_embed_proj then
    -- Bridge start or project/tab switch: adopt everything present, embed
    -- nothing -- what a project brings with it is the user's saved state.
    eon_embed_proj, eon_embed_reg, eon_embed_pending = proj, fp, nil
    eon_embed_seen = {}
    eon_embed_snapshot()
    return
  end

  if fp ~= eon_embed_reg then
    eon_embed_reg = fp
    eon_embed_pending = reaper.time_precise()
  end
  if not eon_embed_pending then return end
  if reaper.time_precise() - eon_embed_pending < 1.5 then return end
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0
     or math.floor(reaper.gmem_read(G.LOCK) or 0) ~= 0
     or math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 2
     or current_load ~= nil or #pending_load_queue > 0
     or eon_pp_stream ~= nil or eon_chop_state ~= nil then
    return   -- stay armed; embed on a later idle tick
  end
  eon_embed_pending = nil
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      if is_swing_fx(tr, fx) then
        local g = reaper.TrackFX_GetFXGUID(tr, fx)
        if g and not eon_embed_seen[g] then
          eon_embed_seen[g] = true
          -- One Swing per track in practice; the frag match flips the first.
          core.fx_embed_mcp(tr, "Swing_ReaKit")
        end
      end
    end
  end
end

-- Browser request entry (called from the kit_req==1 pickup). Stashes the
-- request; eon_fill_tick begins it on the first fully idle poll tick (a fill
-- clicked mid-load waits its turn instead of silently dropping).
eon_fill_pending = nil   -- { path, inst_id, give_up }
eon_fill_state   = nil   -- { jobs, ji, li, inst_id, surplus, deadline }
function eon_fill_request(path, inst_id)
  eon_fill_pending = { path = path, inst_id = math.floor(inst_id or 0),
                       give_up = reaper.time_precise() + 12 }
end

-- Change map for a positional kit LOAD. Called from the load-ACK path ONLY when
-- load_ok — i.e. the JSFX echoed this dispatch, so the audio is really there.
-- Deliberately an OBSERVATION, not a prediction: pad content is read back from
-- the AUDIOLEN band the JSFX publishes, not from the kit file we staged. A load
-- that stages fine but never lands must not draw a map claiming it worked.
-- ⚠️ LOAD skips locked and custom pads exactly as FILL does, so those report
-- their own reasons rather than "changed".
-- GLOBAL: the main chunk is at Lua's 200-local ceiling.
function eon_chgmap_publish_load(inst_id)
  local slot = math.floor(inst_id or 0) - 1
  if slot < 0 or slot > 15 then return end
  local codes = {}
  for p = 0, G.NUM_PADS - 1 do
    local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + p * 4
    local published = (reaper.gmem_read(b) or 0) > 0
    local locked    = published and (reaper.gmem_read(b + 3) or 0) >= 0.5
    local custom    = published
      and math.floor((reaper.gmem_read(b + 2) or 0) + 0.5) == 2
    if locked then codes[p] = 3
    elseif custom then codes[p] = 4
    else
      codes[p] = ((reaper.gmem_read(G.AUDIOLEN_BASE + p) or 0) > 0) and 1 or 0
    end
  end
  -- No "no match" and no surplus for a positional load: every pad the kit
  -- carried went to its authored place. That is the whole point of LOAD.
  eon_chgmap_publish(inst_id, CHGMAP_OP_LOAD, codes, eon_chgmap_counts(codes, 0))
end

-- Gate + parse + match + arm. Runs only from eon_fill_tick on an idle tick.
function eon_fill_begin(filepath, inst_id)
  local slot = inst_id - 1
  if slot < 0 or slot > 15 then
    eon_load_report("FILL refused: no target Swing instance")
    return
  end
  eon_padcat_index("kick")                          -- ensure name maps built
  -- Rack side: published categories + locks (band is bridge-owned; VER==0 =
  -- never published). SRC==2 (custom sample) is excluded per spec §4 —
  -- custom pads are never stomped by a category fill.
  -- ⚠️ Change-map: LOCK and SRC==2 both collapse to cat=-1 for the matcher, but
  -- the map has to tell them apart ("locked" vs "your own sample" vs "no match"
  -- are three different answers to the user). Record the reason HERE, while the
  -- band read is in hand — re-reading it after the fill would race a concurrent
  -- operation. Codes per spec §3.1; refined to 1/2/5 as jobs are assigned.
  local rack, any = {}, false
  local chg = {}
  for p = 0, G.NUM_PADS - 1 do
    local b = EON_PADCAT_BASE + slot * EON_PADCAT_STRIDE + p * 4
    local cat = -1
    local published = (reaper.gmem_read(b) or 0) > 0
    local locked    = (reaper.gmem_read(b + 3) or 0) >= 0.5
    local custom    = math.floor((reaper.gmem_read(b + 2) or 0) + 0.5) == 2
    if published and not locked and not custom then
      cat = math.floor((reaper.gmem_read(b + 1) or -1) + 0.5)
    end
    rack[p] = cat
    if cat >= 0 then any = true end
    -- Provisional: locked/custom are final; an eligible pad starts at "no match"
    -- (5) and is promoted to changed (1/2) below if it wins a job. A pad with no
    -- category at all never had a slot to fill, so it reads as empty (0).
    chg[p] = locked and 3 or custom and 4 or (cat >= 0 and 5 or 0)
  end
  if not any then
    eon_load_report("FILL refused: this rack has no pad categories yet — LOAD a kit once (or set categories), then Fill")
    return
  end
  local kit, blobs, plc = eon_fill_parse_kit_v4(filepath)
  if not kit then
    eon_load_report("FILL refused: " .. tostring(blobs))
    return
  end
  -- Kit side: audio-carrying pads only, category = explicit field or a
  -- CONFIDENT classify(name) (spec §1; never classify from path).
  local pads = kit.pads or {}
  local has_audio, blob_at = {}, {}
  for _, b in ipairs(blobs) do
    blob_at[b.pad * G.MAX_LAYERS + (b.layer or 0)] = b
    if (b.len or 0) > 0 then has_audio[b.pad] = true end
  end
  local srcs_by_cat, any_src = {}, false
  for k = 0, G.NUM_PADS - 1 do
    local p = pads[k + 1]
    if p and has_audio[k] then
      local cat = p.category
      if (not cat or cat == "") and _bridge_categorizer and p.name and p.name ~= "" then
        local c, conf = _bridge_categorizer.classify(p.name)
        cat = conf and c or nil
      end
      local ix = eon_padcat_index(cat)
      if ix >= 0 then
        srcs_by_cat[ix] = srcs_by_cat[ix] or {}
        srcs_by_cat[ix][#srcs_by_cat[ix] + 1] = k
        any_src = true
      end
    end
  end
  if not any_src then
    eon_load_report("FILL refused: this kit has no category data — use Load")
    return
  end
  -- Zip per category (8a): srcs ascending x dsts ascending; dsts > srcs =>
  -- CYCLE; srcs > dsts => surplus (reported, never dumped elsewhere).
  local jobs, surplus = {}, 0
  for cat = 0, 45 do
    local srcs = srcs_by_cat[cat]
    if srcs then
      local dsts = {}
      for r = 0, G.NUM_PADS - 1 do
        if rack[r] == cat then dsts[#dsts + 1] = r end
      end
      for i, r in ipairs(dsts) do
        jobs[#jobs + 1] = { pad = r, src = srcs[((i - 1) % #srcs) + 1] }
        chg[r] = 1                        -- wins a job => no longer "no match"
      end
      -- Change-map CYCLE marking (spec 8a): more pads than samples means the
      -- zip wrapped and some sample is on two or more pads. Mark EVERY pad in a
      -- sharing group, not just the wrapped copies — with 3 pads on 1 sample,
      -- singling one out is arbitrary and reads as noise. "Why do these sound
      -- identical?" is the most surprising legitimate outcome of a fill, so it
      -- has to be visible on all the pads it affects.
      if #dsts > #srcs then
        local users = {}
        for i, r in ipairs(dsts) do
          local s = srcs[((i - 1) % #srcs) + 1]
          users[s] = (users[s] or 0) + 1
        end
        for i, r in ipairs(dsts) do
          local s = srcs[((i - 1) % #srcs) + 1]
          if users[s] > 1 then chg[r] = 2 end
        end
      end
      if #srcs > #dsts then surplus = surplus + (#srcs - #dsts) end
    end
  end
  if #jobs == 0 then
    eon_load_report("FILL: no category overlap between kit and rack — nothing changed")
    return
  end
  -- Per-job sample paths: original file per layer when readable, else the
  -- store WAV (extract once, only if some original is missing/unreadable).
  local need_store = false
  for _, j in ipairs(jobs) do
    local p = pads[j.src + 1] or {}
    local lc = plc[j.src] or 0
    -- Coerce: a corrupt kit's non-string name field would error the tick
    -- mid-fill (pcall-swallowed → silently wedged fills; REVIEW 2026-07-27).
    j.name = type(p.name) == "string" and p.name or nil
    j.lay = {}
    for li = 0, (lc == 0) and 0 or lc - 1 do
      local b = blob_at[j.src * G.MAX_LAYERS + li]
      if b and (b.len or 0) > 0 then
        local orig
        if lc == 0 then orig = p.path
        else orig = ((p.layers or {})[li + 1] or {}).path end
        if not (orig and orig ~= "" and eon_file_readable(orig)) then
          orig, need_store = nil, true
        end
        j.lay[#j.lay + 1] = { src_layer = li, path = orig }
      end
    end
  end
  if need_store then
    if not eon_stage_kit_store_paths(filepath, plc, blobs) then
      eon_load_report("FILL refused: sample extraction failed (disk)")
      return
    end
    local dir = eon_kit_store_dir(filepath)
    for _, j in ipairs(jobs) do
      for _, L in ipairs(j.lay) do
        L.path = L.path
          or string.format("%s/pad%02d_lay%d.wav", dir, j.src, L.src_layer)
      end
    end
  end
  eon_fill_state = { jobs = jobs, ji = 1, li = 1, inst_id = inst_id,
                     surplus = surplus, chg = chg,
                     deadline = reaper.time_precise() + 10 }
  eon_load_report(("FILL: matching %d pad(s)%s"):format(#jobs,
    surplus > 0 and (", %d kit sample(s) unused"):format(surplus) or ""))
end

-- One browse-load CMD per idle poll tick (CMD is single-slot). Layer 1 of a
-- pad goes out as CMD 63 (JSFX load_from_path — CLEAN replace, wipes the
-- pad's old layers: replace-all is kit truth within a filled pad), further
-- layers as CMD 64 (load_layer_from_path, surgical). Pad name cells carry
-- the KIT pad's display name (browse protocol: name is staged by the
-- requester before the CMD), so a filled pad reads like the kit authored it.
function eon_fill_tick()
  local st = eon_fill_state
  if not st then
    local pd = eon_fill_pending
    if not pd then return end
    if reaper.time_precise() > pd.give_up then
      eon_fill_pending = nil
      reaper.gmem_write(G.GS_BROWSE_NAME_ADOPT, 0)  -- never leak the flag
      eon_load_report("FILL dropped: pipeline stayed busy — try again")
      return
    end
    if math.floor(reaper.gmem_read(G.CMD) or 0) == 0
       and math.floor(reaper.gmem_read(G.LOCK) or 0) == 0
       and math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) ~= 2
       and current_load == nil and #pending_load_queue == 0
       and eon_pp_stream == nil and eon_chop_state == nil then
      eon_fill_pending = nil
      eon_fill_begin(pd.path, pd.inst_id)
    end
    return
  end
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0
     or math.floor(reaper.gmem_read(G.LOCK) or 0) ~= 0 then
    if reaper.time_precise() > st.deadline then
      eon_fill_state = nil
      -- ⚠️ REVIEW 2026-07-27: an abort after staging leaves the consume-once
      -- adopt flag armed on the bus — the next name-blind CMD-63 producer
      -- (the external-loader path) would silently keep the pad's OLD name.
      reaper.gmem_write(G.GS_BROWSE_NAME_ADOPT, 0)
      eon_load_report("FILL aborted: pad-load pipeline stalled (target gone?)")
    end
    return
  end
  -- NAME-ADOPT READBACK (2026-07-27 diagnostic, keep until adopt verified):
  -- the CMD-63 handler pushes the pad's final cname into the PADNAME band,
  -- so one idle tick later the band holds what the pad actually shows.
  -- Compare against what we staged; a MISS line names the exact pad, the
  -- staged name, the shown name, and whether the flag survived unconsumed
  -- (flag_now=1 would mean the compiled JSFX has no adopt code).
  if st.chk then
    local got = {}
    for k = 0, G.PADNAME_LEN - 1 do
      local ch = math.floor((reaper.gmem_read(G.PADNAME_BASE
        + st.chk.pad * G.PADNAME_LEN + k) or 0) + 0.5)
      if ch <= 0 then break end
      got[#got + 1] = string.char(math.min(255, math.max(1, ch)))
    end
    got = table.concat(got)
    if st.chk.want ~= "" and got ~= st.chk.want then
      eon_load_report(("FILL name MISS pad %d: staged '%s' shows '%s' flag_now=%d")
        :format(st.chk.pad + 1, st.chk.want, got,
          math.floor(reaper.gmem_read(G.GS_BROWSE_NAME_ADOPT) or 0)))
    end
    st.chk = nil
  end
  -- CMD is idle again. A live target consumes 63/64 within one @block
  -- (~ms); the stale-CMD watchdog clears an UNCONSUMED one only after 10s.
  -- Threshold 9s (REVIEW 2026-07-27, was 4s): observing CMD==0 before the
  -- watchdog fuse CANNOT be a watchdog clear — it proves consumption, even
  -- if a main-thread stall delayed our observation. Only a first-look at
  -- >=9s is ambiguous enough to classify as watchdog → dead target.
  if st.issued_at and reaper.time_precise() - st.issued_at > 9.0 then
    eon_fill_state = nil
    reaper.gmem_write(G.GS_BROWSE_NAME_ADOPT, 0)  -- never leak the flag
    eon_load_report("FILL aborted: target instance is not consuming pad loads")
    return
  end
  local j = st.jobs[st.ji]
  if not j then
    -- Publish the change map BEFORE clearing state: this is the only moment we
    -- know both what was planned (st.chg) and that every job actually landed.
    -- Deliberately NOT published on the abort paths above — a half-applied fill
    -- would draw a map claiming pads changed that never got their CMD.
    eon_chgmap_publish(st.inst_id, CHGMAP_OP_FILL, st.chg,
                       eon_chgmap_counts(st.chg, st.surplus))
    eon_fill_state = nil
    eon_load_report(("FILL complete: %d pad(s) filled%s"):format(#st.jobs,
      st.surplus > 0
        and (", %d kit sample(s) unused"):format(st.surplus) or ""))
    return
  end
  local L = j.lay[st.li]
  if not L then    -- pad had no loadable layers (all-zero blobs) — skip it
    st.ji = st.ji + 1; st.li = 1
    return
  end
  local plen = math.min(#L.path, G.GS_BROWSER_PATH_MAX - 1)
  for i = 0, plen - 1 do
    reaper.gmem_write(G.GS_BROWSER_PATH + i, L.path:byte(i + 1))
  end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, plen)
  if st.li == 1 and j.name and j.name ~= "" then
    local nb = G.PADNAME_BASE + j.pad * G.PADNAME_LEN
    for i = 0, G.PADNAME_LEN - 1 do
      reaper.gmem_write(nb + i, i < #j.name and j.name:byte(i + 1) or 0)
    end
    -- Tell the CMD-63 handler to ADOPT this staged name as the pad name
    -- (consume-once flag) instead of auto-naming from the loaded file —
    -- store-extraction fills otherwise name every pad "padNN_layN".
    reaper.gmem_write(G.GS_BROWSE_NAME_ADOPT, 1)
    st.chk = { pad = j.pad, want = j.name }   -- readback verify next idle tick
  end
  reaper.gmem_write(G.INSTANCE, st.inst_id)
  reaper.gmem_write(G.GS_BROWSE_PAD, j.pad)
  if st.li == 1 then
    reaper.gmem_write(G.CMD, 63)
  else
    reaper.gmem_write(G.GS_BROWSE_LAYER, st.li - 1)
    reaper.gmem_write(G.CMD, 64)
  end
  st.issued_at = reaper.time_precise()
  st.deadline = st.issued_at + 10
  st.li = st.li + 1
  if not j.lay[st.li] then st.ji = st.ji + 1; st.li = 1 end
end

-- Save sidecars by COPYING the source kit file each instance was loaded
-- from. Synchronous (file copy is fast for typical kits, even 200MB).
-- Avoids the gmem multi-window race entirely — we never read kit data
-- from gmem on save. Each instance has a recorded source path tracked
-- by record_kit_source() (called whenever a kit-load happens through
-- the bridge). If no source is recorded for an instance (fresh insert
-- with no kit, or a path we lost track of), the save is skipped — the
-- chunk's truncated fallback covers small kits, and the user can re-
-- load the kit manually to capture it for the next save.
local function file_copy(src_path, dst_path)
  if src_path == dst_path then return true end  -- self-copy = no-op
  local src = io.open(src_path, "rb")
  if not src then return false end

  -- Magic check: refuse to copy anything that doesn't look like a .swing
  -- file. Catches accidental ExtState corruption pointing at the wrong
  -- file, or someone manually tampering with track ExtState. Both v1
  -- binary (8-byte double magic 0x40d4d5d2538000... ≈ specific dword)
  -- and v4 text ("SWINGv0") share enough structure that we accept either.
  local head = src:read(8) or ""
  if head:sub(1, 8) ~= "SWINGv04" and head:sub(1, 8) ~= "SWINGv03" then
    -- Fall back: v1/v2 binary format starts with a packed double. Hard
    -- to validate cheaply, so accept any 8 bytes that aren't all zero.
    if head:byte(1) == 0 and head:byte(2) == 0 and head:byte(3) == 0
       and head:byte(4) == 0 and head:byte(5) == 0 and head:byte(6) == 0
       and head:byte(7) == 0 and head:byte(8) == 0 then
      src:close()
      return false  -- looks like an empty/zeroed file, not a real kit
    end
  end
  src:seek("set", 0)

  local dst = io.open(dst_path, "wb")
  if not dst then src:close(); return false end

  -- Chunked copy (4MB blocks) so large kits (200MB+) don't pin the
  -- entire file into Lua string memory at once. Synchronous within the
  -- defer cycle, but doesn't balloon RAM use proportionally to kit size.
  local CHUNK = 4 * 1024 * 1024
  local ok = true
  while true do
    local chunk = src:read(CHUNK)
    if not chunk or #chunk == 0 then break end
    if not dst:write(chunk) then ok = false; break end
  end
  src:close()
  dst:close()
  return ok
end

eon_sidecar_skip_warned = {}   -- global: bridge chunk is at the 200-local ceiling
-- Skip-unchanged cache for the per-save sidecar copies (perf sweep 2026-08-06:
-- every project save re-copied EVERY instance's whole kit file — N × kit-size
-- of synchronous I/O on each Ctrl+S and on the closing save, the largest close
-- cost with a behavior-identical cut). Key = guid; value = src.."|"..src_size
-- at the last copy, valid only within the current _kit_write_epoch: ANY
-- bridge-side kit write bumps the epoch (register_kit_source_after_save is
-- the single funnel), so a re-saved kit always re-copies. Lua has no mtime
-- without the js extension, hence epoch+size rather than stat. Accepted
-- narrow window: a kit file hand-edited OUTSIDE the bridge mid-session
-- propagates on the next epoch bump or bridge restart instead of the next
-- project save — the bridge is the only writer of .swing kits in normal use.
local _sidecar_copied = {}
_kit_write_epoch = 0
local _sidecar_epoch_seen = -1
local function _file_size(p)
  local f = io.open(p, "rb"); if not f then return -1 end
  local sz = f:seek("end") or -1; f:close(); return sz
end
local function auto_save_all_sidecars()
  local _, proj_filename = reaper.EnumProjects(-1)
  if not proj_filename or proj_filename == "" then return end
  if _sidecar_epoch_seen ~= _kit_write_epoch then
    _sidecar_epoch_seen = _kit_write_epoch
    _sidecar_copied = {}
  end
  local swings = enumerate_all_swings()
  for _, swing in ipairs(swings) do
    local source_path = kit_sources[swing.guid]
    local dest_path = get_sidecar_path(swing.guid)
    local ok = false
    if source_path and dest_path then
      local sig = source_path .. "|" .. _file_size(source_path)
      if _sidecar_copied[swing.guid] == sig and _file_size(dest_path) >= 0 then
        ok = true   -- dest present, source unchanged since OUR last copy
      else
        ok = file_copy(source_path, dest_path)
        if ok then _sidecar_copied[swing.guid] = sig end
      end
    end
    -- A skipped/failed copy used to be silent ("the chunk's truncated
    -- fallback covers small kits") — no longer true with ser-51 marker
    -- saves. The health tick's sc_ok cell keeps such saves embedding, but
    -- say WHY once per instance so a sourceless kit isn't a mystery.
    if not ok and dest_path and not eon_sidecar_skip_warned[swing.guid or ""] then
      eon_sidecar_skip_warned[swing.guid or ""] = true
      reaper.ShowConsoleMsg(("[EON sidecar] no backstop written for Swing inst %d (%s) — chunk stays/embeds until a kit load records a source\n")
        :format(swing.inst_id, source_path and ("source unreadable: " .. source_path) or "no recorded kit source"))
    end
  end
end

-- Queue a sidecar load for a freshly-detected instance. Tries (in order):
--   1. Project-folder sidecar (<projectpath>/Swing/swing_<inst>.swing)
--   2. Track ExtState (P_EXT:swing_kit_src) — last-seen kit path
--   3. Default 808_v2.swing — for fresh insertions on tracks with no kit
-- Silently skips if all three miss (e.g., fresh insert when 808_v2.swing is
-- also missing — user should never see that, but bridge stays sane).
--
-- Bridge-side 808 fallback exists because the JSFX-side auto-load 808
-- gating (`gmem[LOCK] == 0 && gmem[CMD] == 0 && bridge alive`) can fail
-- silently — if any condition is briefly false during JSFX init, the
-- _auto_load_attempted flag flips to 1 and the JSFX never retries. The
-- bridge has no such gating: if it sees an instance with no kit, it
-- pushes 808 directly via the same kit-load pipeline.
local function queue_sidecar_load_if_present(swing)
  -- "Hit" requires both: file exists AND has at least minimal valid kit
  -- structure (>= 16 bytes — magic 8 + lua_len 8 for v4, or magic
  -- double + format ver double for v1). 0-byte and tiny corrupted
  -- sidecars would otherwise pass the existence probe and then crash
  -- load_kit_v* with a dialog. Rejecting them here lets us fall
  -- through to Path 2/3.
  local function probe(path)
    if not path or path == "" then return false end
    local f = io.open(path, "rb"); if not f then return false end
    local size = f:seek("end") or 0
    f:close()
    return size >= 16
  end
  -- Path 1: project-folder sidecar, GUID-named (current scheme)
  local p1 = get_sidecar_path(swing.guid)
  local p1_hit = probe(p1)
  -- Path 1-legacy: pre-GUID integer-named sidecar. Read-only fallback so a
  -- project saved before the GUID change still auto-loads its kit until the
  -- next save (which writes the GUID-named file). Only consulted if the GUID
  -- sidecar is absent.
  local p1L = get_legacy_sidecar_path(swing.inst_id)
  local p1L_hit = (not p1_hit) and probe(p1L)
  local _, p2 = reaper.GetSetMediaTrackInfo_String(swing.tr, "P_EXT:swing_kit_src", "", false)
  local p2_hit = probe(p2)

  -- Path 1: project-folder sidecar (GUID-named)
  if p1_hit then
    pending_load_queue[#pending_load_queue + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx, path = p1, guid = swing.guid }
    return
  end

  -- Path 1-legacy: integer-named sidecar from before the GUID change
  if p1L_hit then
    pending_load_queue[#pending_load_queue + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx, path = p1L, guid = swing.guid }
    return
  end

  -- Path 2: track ExtState (set by previous load_swing_dispatch)
  if p2_hit then
    pending_load_queue[#pending_load_queue + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx, path = p2, guid = swing.guid }
    return
  end

  -- Path 3: REMOVED — a bridge-side default-kit fallback here clobbers kits
  -- the JSFX already deserialized from the project chunk (e.g. Choppa-applied
  -- slices that bypass the bridge). The JSFX-side auto-load (_auto_load_attempted
  -- flag in @block) handles truly fresh instances via CMD=22, which loads the
  -- shipped default (Fischer 808). The dead p3 probe that lingered after the
  -- disable — one io.open per repair scan against a kit 3.0 no longer ships —
  -- is gone too.
end

-- Drive the load queue: pop one item at a time, wait for completion before
-- starting the next. Completion = CMD has changed away from 3 (the
-- "load in flight" sentinel load_kit_v* writes during the pop). Possible
-- post-load CMD values we treat as "done":
--   0  → JSFX state-machine completed successfully (rk_swing_ui_state
--        .jsfx-inc:604 sets CMD=0 at end of state 4)
--   52 → JSFX state 4's tail call to sync_note_names() ran in the same
--        @gfx tick — it grabs the lock and writes 52 to ask the bridge
--        to sync pad names to the piano roll. CMD goes 3→0→52 fast
--        enough that the bridge often catches it at 52. Either snapshot
--        means the kit is loaded.
--   98 → bridge wrote it on validation/format failure (load_kit_v*
--        error paths) — JSFX may clear it back to 0 on its side, either
--        observation means done
--   99 → legacy non-import completion ack (multi-out builder, etc.)
-- Plus a 30s timeout for genuinely stuck loads. Prevents multi-instance
-- gmem corruption from overlapping loads.
local function drive_load_queue()
  -- Orphan-98 flag lifecycle: it marks "the 98 currently on the bus is OUR
  -- no-consumer abort". The moment CMD is anything else (watchdog cleared it,
  -- a waker consumed it, our own dispatch overwrote it) the claim is stale —
  -- drop it here, every tick, so it can never bless a LATER, real 98.
  if eon_orphan_abort98 and math.floor(reaper.gmem_read(G.CMD) or 0) ~= 98 then
    eon_orphan_abort98 = false
  end
  if current_load then
    local cmd_val = math.floor(reaper.gmem_read(G.CMD))
    local done = false
    local timed_out = false
    local no_consumer = false
    -- Phase 1 (2026-07-17): classification order is ACK first, CMD second.
    -- The consuming instance captures GS_LOAD_EPOCH at arm and echoes
    -- +epoch on import completion / -epoch on a 98/99 abort, with
    -- ACK_FAILBITS = pad_fail_bits (payload written before the ack flag,
    -- and we read on a later poll tick — the later-frame-echo rule). The
    -- ack is written in the same @block that clears CMD, so whenever the
    -- legacy CMD~=3 observation is possible on a current JSFX, the ack is
    -- already readable; the bare-CMD branch only classifies stale-compiled
    -- JSFX builds (degrades to today's assume-success behavior).
    local load_ok, load_why = true, nil
    local ack_val = math.floor(reaper.gmem_read(G.GS_LOAD_ACK) or 0)
    if current_load.epoch and ack_val ~= 0
       and math.abs(ack_val) == current_load.epoch then
      done = true
      if ack_val < 0 then
        load_ok, load_why = false, "aborted by consumer (98/99 during arm)"
      else
        local fb = math.floor(reaper.gmem_read(G.GS_LOAD_ACK_FAILBITS) or 0)
        if fb ~= 0 then
          load_ok, load_why = false, ("landed with failed pads (bits 0x%x)"):format(fb)
        end
      end
    elseif cmd_val ~= 3 then
      done = true
    elseif math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 2
       and (reaper.time_precise() - current_load.started_at) > 2.5 then
      -- Fast no-consumer detection (Phase 1): an armed instance zeroes REQ
      -- within one @block of seeing REQ==2. REQ still 2 after 2.5s means NO
      -- instance passed the (exclusive) arm gate — dead/mistargeted id, or
      -- a target whose audio engine isn't running. Don't burn the full 30s:
      -- fail now; the retry path re-resolves the target (see the pop).
      -- 2.5s (was 5s of 1s-granular os.time, 2026-07-20): a live target arms
      -- within one @block, so the only thing a longer fuse buys is a wider
      -- stalled-@block grace window — and an early abort there is harmless
      -- (98 reset or the instant retry re-targets the SAME instance).
      done = true
      timed_out = true            -- reuse the timeout branch's staging cleanup
      no_consumer = true          -- retry class: re-resolve NOW, no AV backoff
      load_ok, load_why = false, "no consumer armed (2.5s, REQ unconsumed)"
    elseif (reaper.time_precise() - current_load.started_at) > 30 then
      -- Stuck — abandon and continue. JSFX state may be partial but we
      -- don't want to block the rest of the bridge forever. (Timeout stays
      -- 30s — the v26 large-kit blob stream emits no progress signal, so a
      -- shorter fuse could kill a live import; the ack path classifies
      -- healthy loads long before this.)
      done = true
      timed_out = true
      load_ok, load_why = false, "timeout (30s)"
    end
    if done then
      -- LOCK release strategy:
      --   - On success (cmd_val != 3 and not timed_out): JSFX state 4
      --     already cleared LOCK to 0, but immediately afterward
      --     sync_note_names() reacquired it (LOCK = instance_id) so
      --     it can write CMD=52 + the new pad names for the bridge's
      --     cmd 52 handler to push to the piano roll. If we cleared
      --     LOCK here, find_swing_track() inside the cmd 52 handler
      --     would see LOCK=0 and return the FIRST Swing track instead
      --     of ours — multi-instance reopens would write every
      --     instance's pad names onto the first instance's track.
      --     Leave LOCK alone; the idle stale-LOCK self-heal in
      --     poll_sidecar_events catches anything left over after
      --     CMD goes back to 0.
      --   - On timeout: state 4 never ran, so LOCK is still pinned
      --     to our inst_id from when we wrote it at pop time. Clear
      --     it defensively so a future fresh-insert auto-load (which
      --     gates on LOCK==0) isn't blocked by our orphan.
      if timed_out then
        local lock_now = math.floor(reaper.gmem_read(G.LOCK) or 0)
        if lock_now == current_load.inst_id then
          reaper.gmem_write(G.LOCK, 0)
        end
        -- Leak fix (2026-07-15 pitch-source starvation): this path cleared LOCK
        -- and current_load but left the CMD=3 staging latch in gmem. Nothing
        -- else ever clears an orphaned 3 — poll_autoexport, the pad-swap
        -- stager, and our own pop gate all bail on CMD~=0 — so one timed-out
        -- load starved the whole pitch pipeline until a REAPER restart.
        -- Write 98 (the documented abort code), not 0: if the target instance
        -- DID enter kit_import_state 1 and merely stalled (audio device
        -- closed), 98 is what its state-1 handler consumes on wake for a full
        -- clean reset (kit_busy/LOCK/CMD). If nothing consumes it, the
        -- stale-CMD watchdog in poll_sidecar_events clears 98→0 within ~5s.
        -- Also disarm the delivery gate so a late-waking instance can't start
        -- importing gmem bands that a NEWER load has since overwritten.
        -- eon_orphan_abort98 (2026-07-20, retrykill <5s): this 98 is BRIDGE-
        -- OWNED — nobody is in state 1 to consume it (that's what we just
        -- detected), so the pop gate may dispatch right past it instead of
        -- sitting out the watchdog's 5s fuse. The stalled-waker corner keeps
        -- its reset: an armed LIVE target always re-resolves to ITSELF on
        -- retry (valid tr → param-3 re-read; the button path's LOCK want is
        -- found by the exact scan), so the waker consumes the retry's full
        -- delivery — strictly better than a bare 98 reset. The first-live
        -- fallback only ever fires for targets no scan can see (deleted FX /
        -- bogus id), which cannot be armed. GLOBAL (main chunk is at Lua's
        -- 200-local ceiling); cleared by the pop whenever CMD leaves 98.
        if math.floor(reaper.gmem_read(G.CMD) or 0) == 3 then
          reaper.gmem_write(G.CMD, 98)
          eon_orphan_abort98 = true
          eon_load_report(("%s (inst=%d): released stale CMD=3 staging latch")
            :format(load_why or "timed out", current_load.inst_id))
        end
        if math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 2 then
          reaper.gmem_write(G.GS_KIT_LOAD_REQ, 0)
        end
        if math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0) == current_load.inst_id then
          reaper.gmem_write(G.GS_PENDING_LOAD_INST, 0)
        end
      end
      -- Audio-only reload (project-open / Undo repair) just overwrote each
      -- pad's buffer with the kit's ORIGINAL samples (import state 3). For
      -- pads currently in Tuned mode, the Extension's baked (pitched) WAV must
      -- be re-injected over that. The Extension's reconcile dedups on (tune,
      -- algo) — tune was preserved, so it won't re-bake — and
      -- poll_pitch_bake_results won't re-swap because baked_ver is unchanged.
      -- Reset the per-pad baked shadow so the next poll re-injects the
      -- current/next baked WAV. Gate on the live MODE band so a stale cross-
      -- session baked_ver can't re-pitch a pad that is no longer Tuned.
      if (not timed_out) and current_load.preserve then
        -- B1b: reset only THIS instance's per-slot shadows for its Tuned pads,
        -- read from its own registry-slot MODE band, so the next poll re-injects
        -- the baked WAV over the just-restored original samples.
        local slot = pitch_slot_for_inst(current_load.inst_id)
        if slot then
          for pad = 0, 15 do
            if pitch_slot_pad_mode(slot, pad) == STRETCH_MODE_TUNED then
              _eon_baked_ver_shadow[slot][pad] = ""
              _eon_last_swap_t[slot][pad] = 0
            end
          end
        end
      end
      -- Phase 1: failure → re-enqueue the SAME item once (front of queue),
      -- then report loudly. Replaces the retired AUDIOLEN settle-verify
      -- (which re-queued healthy loads on non-browser-target instances —
      -- the mirror reads zero there). The retry re-runs the full dispatch:
      -- gmem staging persists nothing we need, load_kit_v* re-stages.
      if not load_ok then
        local item = current_load.item
          or { inst_id = current_load.inst_id, tr = current_load.tr, fx = current_load.fx,
               path = current_load.path, guid = current_load.guid,
               preserve = current_load.preserve }
        local kit_base = (current_load.path or ""):match("([^/\\]+)$") or "?"
        if (item.retries or 0) < 2 then
          item.retries = (item.retries or 0) + 1
          -- BACKOFF (2026-07-18, live catch): per-pad failures are dominated
          -- by AV/indexer holds on FRESHLY-EXTRACTED store WAVs — an instant
          -- retry lands inside the same hold window and fails with the SAME
          -- fail bits (observed live: 0xff9b twice, while the user's manual
          -- reload seconds later was clean). 2s then 4s clears the window.
          -- EXCEPT the no-consumer class (2026-07-20, retrykill <5s): that
          -- failure is a dead/mistargeted ID, not a file hold — the remedy
          -- is the pop's re-resolution/fallback, and waiting only delays it.
          local backoff = no_consumer and 0 or (2.0 * item.retries)
          item.retry_at = (backoff > 0)
            and (reaper.time_precise() + backoff) or nil
          table.insert(pending_load_queue, 1, item)
          eon_load_report(("%s — retry %d/2 in %.0fs: %s (inst=%d)")
            :format(load_why or "failed", item.retries, backoff,
                    kit_base, current_load.inst_id or 0))
        else
          eon_load_report(("FAILED after 2 retries (%s): %s (inst=%d)")
            :format(load_why or "failed", kit_base, current_load.inst_id or 0))
        end
      end
      -- Phase 2 (vector K): stamp the folder-track title from the loaded
      -- file's canonical name at ACK time. The gmem name mirror only
      -- publishes for the browser-target instance — a load delivered
      -- elsewhere used to leave a stale title. Internal reloads (sidecar
      -- preserve / undo restore) skip it: their token filenames are not
      -- display names.
      -- Per-load COMPLETION line (2026-07-19). Only failures used to log, so a
      -- load that "succeeded" via the legacy CMD-left-3 fallback — i.e. one the
      -- consumer never actually acked — was indistinguishable from a real
      -- success in the log. ack=no now says exactly that: the JSFX never echoed
      -- this dispatch (stale build, or the kit was staged and never consumed —
      -- the "I clicked 707 and it still shows the previous kit" case).
      eon_load_report(("done: %s ack=%s epoch=%d failbits=0x%x inst=%d"):format(
        (current_load.path or ""):match("([^/\\]+)$") or "?",
        (ack_val ~= 0 and math.abs(ack_val) == current_load.epoch)
          and (ack_val > 0 and "yes" or "abort") or "no",
        current_load.epoch or -1,
        math.floor(reaper.gmem_read(G.GS_LOAD_ACK_FAILBITS) or 0),
        math.floor(reaper.gmem_read(G.GS_LOAD_ACK_INST) or 0)))
      if load_ok then
        -- Phase 3 (vector G): lineage is recorded only for loads that
        -- ACTUALLY LANDED. Dispatch-time attribution let a mistargeted or
        -- failed load become the sidecar that project reopen resurrects
        -- ("sounds switching after reopen"). Sidecar→sidecar stays a no-op;
        -- undo restores record the consumed snapshot (it IS the live kit).
        if kit_sources and current_load.guid and current_load.guid ~= "" then
          kit_sources[current_load.guid] = current_load.path
        end
        if current_load.tr and reaper.ValidatePtr2(0, current_load.tr, "MediaTrack*") then
          reaper.GetSetMediaTrackInfo_String(current_load.tr,
            "P_EXT:swing_kit_src", current_load.path, true)
          if not (current_load.preserve
                  or (current_load.item and current_load.item.no_undo)) then
            update_folder_track_name(current_load.tr,
              eon_kit_display_name(current_load.path, nil))
          end
        end
        -- Change map for the load that just landed. Only for real user kit
        -- switches: an internal reload (sidecar preserve / undo restore) is not
        -- an action the user took, so drawing "16 pads changed" would be a lie
        -- about something they never did.
        if not (current_load.preserve
                or (current_load.item and current_load.item.no_undo)) then
          eon_chgmap_publish_load(current_load.inst_id)
        end
      end
      current_load = nil
    else
      return  -- still in flight, wait
    end
  end
  if not current_load and #pending_load_queue > 0 then
    -- Gate the pop on CMD == 0 so any JSFX-initiated command in flight
    -- gets a chance to be processed by the main poll's cmd dispatch
    -- (which runs AFTER us this same tick). Concrete case: at the end
    -- of a successful kit-import, the JSFX writes CMD=0 then immediately
    -- CMD=52 (sync_note_names tail call in rk_swing_ui_state.jsfx-inc
    -- :609). Without this gate, drive_load_queue clears current_load
    -- on the CMD=52 snapshot, pops the next item, calls load_kit_v* which
    -- writes CMD=3 — overwriting the 52 before the bridge's cmd 52
    -- handler (piano-roll name sync) ever runs. Same risk for any other
    -- JSFX-driven command (CMD=22 auto-load, CMD=99 ack, etc.) that
    -- happens to land in the gap between our done-detection and pop.
    --
    -- Cost: at most one extra poll tick (~33ms) of latency between
    -- successive queued loads. Imperceptible to the user, and only
    -- relevant on bulk-reopen where loads pipeline back-to-back.
    --
    -- ORPHAN-98 BYPASS (2026-07-20, retrykill <5s): a 98 the bridge itself
    -- wrote for a no-consumer abort has, by construction, nobody armed to
    -- consume it — holding the pop for the stale-CMD watchdog's 5s fuse
    -- just delays the recovery retry. Dispatch past it (the dispatch chain
    -- overwrites CMD); the flag drops the moment CMD is anything else, so
    -- a REAL failure-98 (JSFX abort, validation error) still holds the pop
    -- exactly as before.
    local cmd_now = math.floor(reaper.gmem_read(G.CMD) or 0)
    if cmd_now ~= 0 and not (cmd_now == 98 and eon_orphan_abort98) then return end
    -- Retry BACKOFF: a re-enqueued failure may carry a not-before time (AV
    -- hold on fresh store WAVs). Head-of-queue serialization is deliberate —
    -- the retried load keeps its place; later requests wait behind it.
    if pending_load_queue[1].retry_at
       and reaper.time_precise() < pending_load_queue[1].retry_at then
      return
    end
    -- PUMP-DRAIN GATE (2026-07-19, library-sweep intermittent): a v26
    -- stream (px extraction fallback) pumps blob windows into KIT_GMEM_AUDIO
    -- — the SAME band the next load's VER-201 path staging uses. Dispatching
    -- while a prior stream is still draining let the pump stomp freshly
    -- staged path strings mid-import: pads silently loading OTHER kits'
    -- audio, nondeterministic per run (the scratch-bus disease, again).
    -- The stream is part of the load transaction: no next dispatch until
    -- the pump is done.
    if eon_pp_stream ~= nil then return end
    -- Kit-categories ④ (REVIEW 2026-07-27): a FILL in flight owns the CMD
    -- 63/64 lane — dispatching a kit load mid-fill would interleave CMD=3
    -- staging with the fill's pad loads (and the fill's remaining jobs
    -- would then stomp freshly loaded pads). Fills run seconds; queued
    -- loads simply wait their turn.
    if eon_fill_state ~= nil then return end
    -- Phase 1 CLOBBER GUARD (kitpipe_storm run-8 catch, 2026-07-17):
    -- GS_KIT_LOAD_REQ is a shared-VALUE mailbox — 1 = incoming request,
    -- 2 = data-ready dispatch signal. Popping while an unconsumed 1 sits in
    -- the cell overwrites it with 2: the user's newest click silently
    -- evaporates and the pipeline finishes on an OLDER kit ("final state ≠
    -- last request" — a root mechanism of the load-twice symptom). Hold the
    -- pop one tick; the kit_req handler (later this same poll) consumes the
    -- 1 into the queue, then we dispatch with the full picture.
    if math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 1 then return end
    local item = table.remove(pending_load_queue, 1)
    -- Identity rollout (2026-07-08): instance ids can be re-minted between
    -- enqueue and dispatch (duplicate duel in the JSFX reconciler). The
    -- track+fx refs are the durable key — re-read the CURRENT id (param 3)
    -- at dispatch so LOCK/PENDING never carry a stale id (a stale id makes
    -- the JSFX delivery gate never fire = the load silently times out).
    if item.tr and reaper.ValidatePtr2(0, item.tr, "MediaTrack*") then
      local live_id = math.floor(reaper.TrackFX_GetParam(item.tr, item.fx, 3) or 0)
      if live_id > 0 then item.inst_id = live_id end
    else
      -- Phase 1: items may arrive with no live track ref (deferred while the
      -- target was mid-boot / unresolvable, or CMD-82 without a track match).
      -- Resolve NOW. Trust policy: an explicit want is honored AS-IS on the
      -- FIRST attempt even when the scan can't see it (a freshly-inserted
      -- instance reads param 3 == 0 while booting) — but a RETRIED item's
      -- unmatched want is treated as dead and falls back to the first live
      -- instance. Without the fallback, a dead id retried itself forever:
      -- dispatch → no consumer → retry same id → ... while real loads
      -- queued behind it (kitpipe_retrykill caught exactly this).
      local exact, first_live, live_n = nil, nil, 0
      for _, swing in ipairs(enumerate_all_swings()) do
        if (swing.inst_id or 0) > 0 then
          live_n = live_n + 1
          if not first_live then first_live = swing end
          if swing.inst_id == item.inst_id then exact = swing; break end
        end
      end
      local pick = exact
      if not pick and (item.inst_id or 0) <= 0 then pick = first_live end
      -- Dead-target re-bind (2026-08-19, "808F art never published"): a want
      -- naming an id that is un-enumerated AND a registry corpse means the
      -- instance re-minted (identity duel / recompile fallout) while a stale
      -- binding — browser INSTANCE cell, requester WANT — kept the old id.
      -- Dispatching at it costs the 2.5s no-consumer abort, and the retry
      -- re-arm skips load_swing_dispatch, so the cover publish and the
      -- folder rename silently vanish with it. Re-bind on the FIRST attempt,
      -- but only on positive corpse evidence and only when exactly one live
      -- instance exists: a BOOTING id (param 3 lags registration) is absent
      -- from both surfaces and keeps the explicit-want AS-IS contract below,
      -- so a fresh insert's auto-load can never be re-aimed at a bystander.
      if not pick and (item.inst_id or 0) > 0 and live_n == 1
         and eon_inst_is_corpse(item.inst_id) then
        eon_load_report(("target inst=%d re-minted — re-bound to inst=%d")
          :format(item.inst_id, first_live.inst_id))
        pick = first_live
      end
      if not pick and (item.retries or 0) > 0 and first_live then
        eon_load_report(("target inst=%d not found — retry falls back to inst=%d")
          :format(item.inst_id or 0, first_live.inst_id))
        pick = first_live
      end
      if pick then
        item.inst_id, item.tr, item.fx, item.guid =
          pick.inst_id, pick.tr, pick.fx, pick.guid
      end
    end
    if (item.inst_id or 0) <= 0 then
      -- Still no consumer. Never stage consumer-less data (it would sit at
      -- CMD=3 until the stale watchdog aborts 98): give the target one more
      -- queue cycle to boot, then report instead of silently dropping.
      if (item.retries or 0) < 1 then
        item.retries = (item.retries or 0) + 1
        pending_load_queue[#pending_load_queue + 1] = item
      else
        eon_load_report("FAILED: no live Swing instance to receive "
          .. ((item.path or ""):match("([^/\\]+)$") or "?"))
      end
      return
    end
    -- Two item classes now flow through here (Phase 3): sidecar/audio-repair
    -- reloads (queue_sidecar_load_if_present; no preserve field = default
    -- TRUE — restore @serialize-restored live params over the re-staged
    -- audio) and deferred user kit SWITCHES (the kit_req==1 busy path;
    -- preserve = false — the incoming kit's params must win).
    -- Phase 1b: the epoch is stamped LAST (in the post_cmd==3 branch below,
    -- after staging + PENDING + legacy REQ=2) because it IS the arm signal —
    -- an epoch the consumer hasn't seen means "a complete delivery is
    -- staged for whoever PENDING names". Computed here so current_load
    -- carries it; the cell write waits until the delivery is real.
    -- current_load keeps the original item so a failed dispatch can
    -- re-enqueue it with its retry budget intact.
    local dispatch_epoch = math.floor(reaper.gmem_read(G.GS_LOAD_EPOCH) or 0) + 1
    current_load = { inst_id = item.inst_id, tr = item.tr, fx = item.fx, path = item.path, guid = item.guid, started_at = reaper.time_precise(), preserve = (item.preserve ~= false), epoch = dispatch_epoch, item = item }
    reaper.gmem_write(G.LOCK, item.inst_id)
    -- (Phase 3: kit_sources/P_EXT lineage moved to positive-ACK time —
    -- see the ack block in the done-detection above.)
    -- Pre-set the per-instance routing slot so load_swing_dispatch's
    -- source-tracking fallback (lock → pending → instance) and, more
    -- importantly, the JSFX-side @gfx delivery gate
    --   GS_KIT_LOAD_REQ == 2 && PENDING_LOAD_INST == instance_id
    -- can both target this instance specifically.
    reaper.gmem_write(G.GS_PENDING_LOAD_INST, item.inst_id)
    -- Same routing, for the cover tile. Only the CMD path used to set this, so
    -- every QUEUED load — above all the sidecar reload on project open — reached
    -- eon_kitcover_publish with a nil slot, which returns immediately. The kit's
    -- artwork was parsed and extracted and then announced to nobody, which is
    -- why reopening a project showed a blank tile while reloading the kit by
    -- hand showed the art. The queue knows the instance; hand it over.
    eon_kit_cover_load_slot = ss_resolve_slot(item.inst_id)
    -- STALE compat stamp scrub (2026-07-19, live "PAD 2 blank on 707"): a
    -- leftover REQ==2 from a PREVIOUS dispatch must not survive into this
    -- one. CMD=3 goes up BEFORE staging (mirror latch inside dispatch), and
    -- both arm paths — the state-0 exclusive gate AND a LOAD-button-armed
    -- state 1 — accept REQ==2 as "staging complete". Button loads never
    -- consumed the stamp (the button pre-arms state 1, so the exclusive
    -- gate that normally eats REQ==2 never ran), so the stale 2 let the
    -- armed JSFX spring the moment the latch landed and its 1-pad-per-block
    -- consume cursor RACED the stager: cells not yet written read empty →
    -- "staged-empty = kit truth" → clear_pad → blank pads with names and
    -- failbits 0x0. Fresh requests (1) are never touched (clobber guard).
    if math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 2 then
      reaper.gmem_write(G.GS_KIT_LOAD_REQ, 0)
    end
    -- Note: the kit-import gate + state machine now run in JSFX @block
    -- (see Swing_ReaKit.jsfx, just before @sample). No need to
    -- force-open the FX window for @gfx — @block runs whenever the FX
    -- is on a track, regardless of UI visibility.
    if current_load.preserve or item.no_undo then
      -- bridge-internal (sidecar/preserve) or CMD-82 kit-undo restore: no
      -- undo dump, no named undo entry (an undo-restore must not mint a
      -- fresh undo point of itself).
      load_swing_dispatch(item.path, true, true)
    else
      -- Deferred user kit switch: same undo-block naming + kit-undo dump the
      -- inline kit_req path gives an idle-pipeline load.
      local kit_name = item.path:match("([^/\\]+)%.swing$")
                    or item.path:match("([^/\\]+)$") or "kit"
      reaper.Undo_BeginBlock()
      load_swing_dispatch(item.path, nil, true)
      reaper.Undo_EndBlock("Swing: Load Kit " .. kit_name, -1)
    end
    -- Trigger the JSFX-side import gate. load_kit_v4 has just written
    -- CMD=3 + meta + audio; without GS_KIT_LOAD_REQ=2 the JSFX never
    -- enters kit_import_state=1, so the data sits in gmem unconsumed.
    -- This mirrors the JSFX-driven CMD 22 path (which sets KIT_LOAD_REQ
    -- =2 in the kit_req==1 poll branch) — without it, the bridge-side
    -- 808 fallback never actually delivers, and fresh-insert auto-load
    -- silently fails. Only signal "data ready" if load_kit_v* actually
    -- wrote CMD=3; on validation/format failure CMD is 98 and we leave
    -- it alone so the JSFX-side error path runs.
    local post_cmd = math.floor(reaper.gmem_read(G.CMD) or 0)
    if post_cmd == 3 then
      -- Preserve-live is per-CLASS: audio-only reloads re-assert 1 BEFORE
      -- signalling data-ready (JSFX reads it at state 2); user kit switches
      -- leave it 0 (load_swing_dispatch already cleared it) so the incoming
      -- kit's params win.
      if current_load.preserve then
        reaper.gmem_write(G.GS_KIT_PRESERVE_LIVE, 1)
      end
      reaper.gmem_write(G.GS_KIT_LOAD_REQ, 2)   -- stale-JSFX compat arm path
      -- EPOCH LAST (Phase 1b): everything the consumer needs is now in
      -- place; the epoch-change is what a current JSFX arms on, and being
      -- a monotonic dedicated cell it cannot be clobbered by request
      -- traffic the way the shared-value REQ cell can.
      reaper.gmem_write(G.GS_LOAD_EPOCH, dispatch_epoch)
      -- (Phase 1: the staged-pad count + tail verify pass are retired — the
      -- consumer's ACK_FAILBITS echo reports per-pad load failures exactly.)
    else
      -- Load failed before even reaching CMD=3 (load_kit_v* validation /
      -- format error — CMD is 98). Classify NOW instead of letting the
      -- next done-detection tick read 98≠3 as success: clear PENDING so a
      -- future load isn't mis-routed, then retry once / report.
      reaper.gmem_write(G.GS_PENDING_LOAD_INST, 0)
      local kit_base = (item.path or ""):match("([^/\\]+)$") or "?"
      if (item.retries or 0) < 1 then
        item.retries = (item.retries or 0) + 1
        table.insert(pending_load_queue, 1, item)
        eon_load_report(("staging failed (cmd=%d) — retrying once: %s"):format(post_cmd, kit_base))
      else
        eon_load_report(("FAILED after retry (staging, cmd=%d): %s"):format(post_cmd, kit_base))
      end
      current_load = nil
    end
  end

  -- (Phase 1: the AUDIOLEN reload-completeness verify that lived here is
  -- RETIRED — see the note at the pending_load_queue declaration. The
  -- AUDIOLEN band is a browser-target-only mirror; counting it re-queued
  -- healthy loads on every other instance. ACK_FAILBITS is the replacement.)
end

-- Set up a brand-new Swing's track as a ready-to-sequence STEREO instrument:
-- seed a 1-bar looped "Pattern 1" MIDI item, tag the track as a Drum Matrix
-- STEREO grid lane (one multi-pitch lane on the Swing track itself), and grow
-- the track so the grid rows have room. The DM overlay is NOT launched —
-- opening it stays the user's decision (DM GRID / MATRIX buttons).
-- One-shot FOREVER per track via P_EXT:EON_PATTERN_SEEDED — the flag is
-- written even when setup is skipped, which permanently grandfathers
-- pre-update projects on their first session. Setup is skipped entirely when
-- the track already carries items ("already got MIDI on it"), already has a
-- lane tag, or a classic DM lane build owns this instance.
-- Kill-switch: ExtState EON_Bridge/seed_pattern = "0".
-- Module-GLOBAL (main chunk is at Lua's 200-local ceiling — do not make this
-- a chunk local).
function _eon_stereo_setup_for_new_swing(swing)
  if reaper.GetExtState("EON_Bridge", "seed_pattern") == "0" then return end
  local tr = swing.tr
  local _, seeded = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_PATTERN_SEEDED", "", false)
  if seeded and seeded ~= "" then return end
  local want_setup = reaper.CountTrackMediaItems(tr) == 0
  -- Already lane-tagged (stereo set up manually / restored project)?
  if want_setup then
    local _, own_tag = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_DRUM_LANE", "", false)
    if own_tag and own_tag ~= "" then want_setup = false end
  end
  -- Classic DM lane build owns this instance? Raw substring match on the lane
  -- tag JSON — lanes embed the Swing track GUID as swing_instance_guid, so no
  -- JSON decode is needed here.
  if want_setup and swing.guid and swing.guid ~= "" then
    for lane_tr in core.iter_all_tracks() do
      local _, raw = reaper.GetSetMediaTrackInfo_String(lane_tr, "P_EXT:EON_DRUM_LANE", "", false)
      if raw and raw ~= "" and raw:find(swing.guid, 1, true) then
        want_setup = false
        break
      end
    end
  end
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_PATTERN_SEEDED", "1", true)
  if not want_setup then return end
  -- Row range: a fresh Swing hasn't remapped pad notes yet, so root_note
  -- (slider1 = param 0, default 36) + 15 is exact. Kits with custom note maps
  -- go through EON_DM_BuildStereo, which reads the live per-slot pad map.
  local root = math.floor(reaper.TrackFX_GetParam(tr, swing.fx, 0) or 36)
  if root < 0 or root > 112 then root = 36 end
  local lo, hi = root, root + 15
  -- Persistent defer scripts never get an automatic undo point — wrap the
  -- setup explicitly so Ctrl+Z removes exactly what was added.
  reaper.Undo_BeginBlock()
  -- Stereo grid lane tag: same shape EON_DM_BuildStereo writes. Hand-built
  -- JSON — the bridge carries no encoder and every field is a plain scalar.
  reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:EON_DRUM_LANE", string.format(
    '{"stereo":true,"swing_instance_guid":"%s","pad_index":1,"pad_pitch":%d,' ..
    '"pad_channel":1,"note_lo":%d,"note_hi":%d,"pad_name":"Drums","created_at":"%s"}',
    swing.guid or "", lo, lo, hi, os.date("!%Y-%m-%dT%H:%M:%SZ")), true)
  -- 1-bar starter item at bar 1 (time-sig aware end-of-bar-1); loop-source is
  -- on, so dragging the right edge repeats the pattern.
  local end_t = reaper.TimeMap2_beatsToTime(0, 0, 1)
  local item = reaper.CreateNewMIDIItemInProj(tr, 0, end_t, false)
  if item then
    reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 1)
    local take = reaper.GetActiveTake(item)
    if take then reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "Pattern 1", true) end
    reaper.UpdateItemInProject(item)
  end
  -- Room for 16 grid rows + the stereo header band. Never shrink.
  local want_h = 16 * 20 + 20
  if (reaper.GetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE") or 0) < want_h then
    reaper.SetMediaTrackInfo_Value(tr, "I_HEIGHTOVERRIDE", want_h)
    reaper.TrackList_AdjustWindows(false)
  end
  reaper.Undo_EndBlock("Swing: stereo grid setup (pattern item + grid tag)", -1)
end

-- Detect "project just saved" via IsProjectDirty 1→0 transition.
-- ── P3 store lifecycle: recursive sample-tree copy (Save As) ──────────────
-- Depth-capped; idempotent (skips same-size existing targets). Module-GLOBAL
-- (200-local ceiling). Uses the same EnumerateFiles/Subdirectories APIs the
-- sweep helpers already rely on.
function eon_copy_tree(src, dst, depth)
  depth = depth or 0
  if depth > 4 then return end
  if not reaper.EnumerateFiles(src, 0) and not reaper.EnumerateSubdirectories(src, 0) then
    return   -- source absent/empty: nothing to do
  end
  reaper.RecursiveCreateDirectory(dst, 0)
  local fi = 0
  while true do
    local f = reaper.EnumerateFiles(src, fi)
    if not f then break end
    local sp, dp = src .. "/" .. f, dst .. "/" .. f
    local sf = io.open(sp, "rb")
    if sf then
      local ssz = sf:seek("end"); sf:close()
      local df = io.open(dp, "rb")
      local dsz = df and df:seek("end") or -1
      if df then df:close() end
      if dsz ~= ssz then file_copy(sp, dp) end
    end
    fi = fi + 1
  end
  local di = 0
  while true do
    local d = reaper.EnumerateSubdirectories(src, di)
    if not d then break end
    eon_copy_tree(src .. "/" .. d, dst .. "/" .. d, depth + 1)
    di = di + 1
  end
end

-- ── P3 store lifecycle: migrate unsaved-store chops on first save ─────────
-- Armed by poll_sidecar_events when a save lands with unsaved-store chop dirs
-- present. One instance per tick: copy that guidtok's chop WAVs into
-- <proj>/Swing/samples/chops/<guidtok>/, then stage corrected paths (ONLY for
-- pads whose CURRENT staged pad cell points into that unsaved dir — the
-- prefix match keeps other instances' and superseded loads' cells untouched)
-- and post CMD 86 (JSFX adopts strings, no reload, acks CMD=0). Copies are
-- crash-nets even when no rewrite fires: old unsaved paths keep resolving.
eon_migr_state = nil

function eon_migrate_kick()
  local _, projfn = reaper.EnumProjects(-1)
  if not projfn or projfn == "" then return end       -- still unsaved
  local unsaved_chops = reaper.GetResourcePath() .. "/Data/EON_Swing/unsaved/chops"
  if not reaper.EnumerateSubdirectories(unsaved_chops, 0) then return end
  if eon_migr_state then return end                    -- already running
  local work = {}
  for _, swing in ipairs(enumerate_all_swings()) do
    local g = (swing.guid or ""):gsub("[^%w]", "")
    if g ~= "" then
      local srcdir = unsaved_chops .. "/" .. g
      if reaper.EnumerateFiles(srcdir, 0) then
        work[#work + 1] = { inst_id = swing.inst_id, tr = swing.tr, fx = swing.fx,
                            tok = g, src = srcdir }
      end
    end
  end
  if #work == 0 then return end
  -- Snapshot the current pad source paths ONCE. Source of truth = the
  -- per-pad ExtState breadcrumbs ("Swing"/"pad_path_N", written by every
  -- staging route incl. the chop dispatch): stable session state, unlike
  -- the gmem pad-path cells, which are the block_pitch PCM scratch bus and
  -- can be stomped by the time the save event fires (observed: a healthy
  -- session where the prefix match staged 0 because the snapshot read the
  -- stomped bus). gmem cell kept as fallback for anything that staged
  -- without writing the breadcrumb.
  local snap = {}
  for pad = 0, G.NUM_PADS - 1 do
    local bc = reaper.GetExtState("Swing", "pad_path_" .. pad)
    snap[pad] = (bc ~= "" and bc) or read_pad_path_from_gmem(pad)
  end
  eon_migr_state = { work = work, i = 1, phase = "copy", deadline = 0, snap = snap }
  reaper.ShowConsoleMsg(("[Swing] migrating %d instance(s) of unsaved chops to project store\n"):format(#work))
end

function eon_migrate_pump()
  local st = eon_migr_state
  if not st then return end
  local item = st.work[st.i]
  if not item then eon_migr_state = nil; return end
  local now = reaper.time_precise()

  if st.phase == "copy" then
    local projdir = select(2, reaper.EnumProjects(-1)):match("^(.*)[/\\]") or ""
    if projdir == "" then eon_migr_state = nil; return end
    local dstdir = projdir .. "/Swing/samples/chops/" .. item.tok
    eon_copy_tree(item.src, dstdir, 3)   -- flat dir; depth headroom harmless
    -- stage rewrites: pads whose staged cell path lives under item.src
    local staged = 0
    -- Dedicated staging band (MIGR_PAD_CELLS/MIGR_LAYER_CELLS) when the JSFX
    -- advertises cap >= 202. The legacy home — the KIT_GMEM_AUDIO 260-cell
    -- band — is a SCRATCH BUS (block_pitch streams pad PCM over it for
    -- Extension bake capture, running for seconds right after project open):
    -- payloads staged there were stomped before the CMD-86 consume read
    -- them, so the JSFX acked with zero adoptions and the rewrites never
    -- reached the chunk (chunk-decode proof 2026-07-12, 2/2 runs).
    local mig202 = math.floor(reaper.gmem_read(G.HS_CAP) or 0) >= 202
    local pad_cells = mig202 and G.MIGR_PAD_CELLS or G.AUDIO_BASE
    local layer_cells = mig202 and G.MIGR_LAYER_CELLS or (G.AUDIO_BASE + G.NUM_PADS * 260)
    -- zero every cell first: empty cell = "leave slot alone" on the JSFX side
    for pad = 0, G.NUM_PADS - 1 do
      eon_write_gmem_path(pad_cells + pad * 260, "")
      for L = 0, G.MAX_LAYERS - 1 do
        eon_write_gmem_path(layer_cells + (pad * G.MAX_LAYERS + L) * 260, "")
      end
    end
    -- st.snap = staged-cell contents captured at kick time (pre-zero); a pad
    -- is rewritten only when its snapshot path lives under THIS instance's
    -- unsaved chop dir.
    for pad = 0, G.NUM_PADS - 1 do
      local cur = st.snap and st.snap[pad]
      if cur and cur ~= "" and cur:find(item.src, 1, true) == 1 then
        local base = cur:match("([^/\\]+)$") or ""
        local dst = dstdir .. "/" .. base
        if #dst > 258 then
          -- 260-cell protocol ceiling. eon_write_gmem_path silently maps
          -- >258 to "" — which USED to count as staged and fail adoption
          -- with no trace (bit the acceptance harness: its scratchpad
          -- project dir pushed paths to 271 chars). Deep real-world dirs
          -- (OneDrive nesting) can hit this too: be loud, don't count it.
          reaper.ShowConsoleMsg(("[Swing] chop migration: pad %d path too long for rewrite (%d > 258 chars) — pad keeps its unsaved-store path\n")
            :format(pad, #dst))
        else
          eon_write_gmem_path(pad_cells + pad * 260, dst)
          staged = staged + 1
        end
      end
    end
    if staged > 0 then
      st.staged = staged
      st.mig202 = mig202
      reaper.gmem_write(G.MIGR_ADOPTED, -1)  -- JSFX echoes the real count before its ack
      -- re-resolve target id at dispatch (re-mint safety)
      local live_id = item.inst_id
      if item.tr and reaper.ValidatePtr2(0, item.tr, "MediaTrack*") then
        local v = math.floor(reaper.TrackFX_GetParam(item.tr, item.fx, 3) or 0)
        if v > 0 then live_id = v end
      end
      reaper.gmem_write(G.GS_PENDING_LOAD_INST, live_id)
      reaper.gmem_write(G.CMD, 86)
      st.phase = "wait"; st.deadline = now + 2.0
    else
      st.i = st.i + 1   -- copies done; nothing to rewrite for this instance
    end
  elseif st.phase == "wait" then
    local c = math.floor(reaper.gmem_read(G.CMD) or -1)
    if c == 0 then
      -- CMD back to 0. On cap>=202 builds the consume echoes how many cells
      -- it actually adopted BEFORE acking — trust that, not the bare CMD==0
      -- (CMD is a shared bus and the consume acks even on all-empty cells;
      -- the pre-band bug shipped exactly that false "ack" for a week).
      local adopted = math.floor(reaper.gmem_read(G.MIGR_ADOPTED) or -1)
      if st.mig202 and adopted < (st.staged or 1) then
        local item3 = st.work[st.i]
        item3.tries = (item3.tries or 0) + 1
        if item3.tries < 3 then
          reaper.SetExtState("EON_Bridge", "dbg_86_result",
            ("short%d/%d-retry%d@%d"):format(adopted, st.staged or 0, item3.tries, os.time()), false)
          st.phase = "copy"
        else
          reaper.SetExtState("EON_Bridge", "dbg_86_result",
            ("SHORT%d/%d@%d"):format(adopted, st.staged or 0, os.time()), false)
          reaper.ShowConsoleMsg(("[Swing] chop migration: CMD-86 adopted %d of %d staged paths after retries\n")
            :format(math.max(adopted, 0), st.staged or 0))
          st.i = st.i + 1; st.phase = "copy"
        end
      else
        -- Full adoption (or legacy build with no echo). The consume also set
        -- GS_PROJ_DIRTY=1; the poll loop forwards that to MarkProjectDirty,
        -- so the rewrites reach the next save.
        reaper.SetExtState("EON_Bridge", "dbg_86_result",
          ("ack%d/%d@%d"):format(math.max(adopted, 0), st.staged or 0, os.time()), false)
        st.i = st.i + 1; st.phase = "copy"
      end
    elseif now > st.deadline then
      -- CMD must be cleared or drive_load_queue's pop condition (cmd==0)
      -- wedges behind the orphaned 86.
      reaper.gmem_write(G.CMD, 0)
      -- Migration usually runs seconds after a project (re)open, and a
      -- reopened instance boots on a fresh counter id before re-identifying
      -- to its serialized id — during that window the JSFX gate
      -- (PENDING == instance_id) can never match and the dispatch times out
      -- (observed live: dbg_86_result=TIMEOUT with correct staging). Retry:
      -- the copy phase is idempotent, re-stages the cells (they're a scratch
      -- bus), and re-resolves the live id — by the 2nd try identity has
      -- settled.
      local item2 = st.work[st.i]
      item2.tries = (item2.tries or 0) + 1
      if item2.tries < 3 then
        reaper.SetExtState("EON_Bridge", "dbg_86_result",
          "retry" .. item2.tries .. "@" .. tostring(os.time()), false)
        st.phase = "copy"
      else
        reaper.SetExtState("EON_Bridge", "dbg_86_result", "TIMEOUT@" .. tostring(os.time()), false)
        reaper.ShowConsoleMsg("[Swing] chop migration: CMD-86 ack timeout for inst " ..
          tostring(item2.inst_id) .. " after retries (files copied; paths unchanged)\n")
        st.i = st.i + 1; st.phase = "copy"
      end
    end
  end
end

-- ── P4 step 3c: auto-rebase on project move ─────────────────────────────────
-- Chunk paths are ABSOLUTE (loaders strcpy verbatim; @serialize v11 writes
-- raw), so moving/renaming a project folder kills every ser-51 marker pad
-- even though <projdir>/Swing/samples/** traveled with it — and the failure
-- used to be silent (loaders zero s_len BEFORE file_open). On reopen of a
-- real project this audit asks each instance to publish its restored paths
-- (CMD 87 → REB band; the pad_path_N breadcrumbs are session-stale on a cold
-- reopen and the AUDIO cells are the block_pitch scratch bus), file-checks
-- them bridge-side, splices the CURRENT projdir onto dead paths that carry
-- the /Swing/samples/ marker, and dispatches CMD 88 (adopt strings + reload
-- blank audio, chunked 1 pad/@block JSFX-side). Silent when nothing is dead;
-- one console line per repaired instance; GS_PROJ_DIRTY (set by the CMD-88
-- consume) makes the next save persist the rewrites. Requires HS_CAP >= 203.
-- GLOBALS (bridge main chunk is at Lua's 200-local ceiling).
eon_rebase_state = nil

-- Read one len-prefixed 260-cell gmem path (generic base — read_pad_path_
-- from_gmem is hardwired to the AUDIO scratch bus).
function eon_read_gmem_path(pbase)
  local n = math.floor(reaper.gmem_read(pbase) or 0)
  if n <= 0 or n > 258 then return "" end
  local t = {}
  for i = 1, n do
    t[i] = string.char(math.floor(reaper.gmem_read(pbase + i) or 0) % 256)
  end
  return table.concat(t)
end

function eon_bits_count(bits)
  local n, b = 0, math.floor(bits or 0)
  while b > 0 do
    n = n + (b % 2)
    b = math.floor(b / 2)
  end
  return n
end

function eon_rebase_kick()
  local _, projfn = reaper.EnumProjects(-1)
  if not projfn or projfn == "" then return end   -- unsaved project: no store to rebase against
  if eon_rebase_state then return end
  eon_rebase_state = { phase = "arm", wait_until = reaper.time_precise() + 2.0,
                       projfn = projfn }
end

function eon_rebase_pump()
  local st = eon_rebase_state
  if not st then return end
  local now = reaper.time_precise()
  if st.wait_until and now < st.wait_until then return end
  -- Abort wholesale if the project changed under the audit.
  local _, projfn_now = reaper.EnumProjects(-1)
  if (projfn_now or "") ~= st.projfn then eon_rebase_state = nil; return end
  -- DISPATCH phases (arm/pub) require the shared CMD bus + load pipeline
  -- idle — the on-open sidecar reload runs first and may itself fix pads.
  -- WAIT phases must keep running while OUR OWN CMD is in flight, or the
  -- deadline handling below could never fire (producer supervises its own
  -- latch; the stale-CMD watchdog is only the backstop).
  if (st.phase == "arm" or st.phase == "pub")
     and (math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0
          or current_load ~= nil or #pending_load_queue > 0
          or eon_migr_state ~= nil or eon_pp_stream ~= nil) then
    return
  end

  if st.phase == "arm" then
    if math.floor(reaper.gmem_read(G.HS_CAP) or 0) < 203 then
      eon_rebase_state = nil; return   -- stale JSFX build: no protocol
    end
    st.work = enumerate_all_swings()
    if #st.work == 0 then eon_rebase_state = nil; return end
    st.i = 1; st.tries = 0; st.phase = "pub"; st.wait_until = nil
    return
  end

  local item = st.work[st.i]
  if not item then eon_rebase_state = nil; return end

  if st.phase == "pub" then
    -- Nonce discipline: several CMD-87 producers (this audit, the health
    -- tick, acceptance probes) share ONE ack cell — the JSFX echoes the
    -- request nonce, so a later publish stomping the ack is a detectable
    -- mismatch (retry) instead of a silent hang.
    eon_reb_nonce = (eon_reb_nonce or 0) + 1
    st.nonce = eon_reb_nonce
    reaper.gmem_write(G.REB_PUB_ACK, 0)
    reaper.gmem_write(G.REB_PUB_REQ, st.nonce)
    local live_id = item.inst_id
    if item.tr and reaper.ValidatePtr2(0, item.tr, "MediaTrack*") then
      local v = math.floor(reaper.TrackFX_GetParam(item.tr, item.fx, 3) or 0)
      if v > 0 then live_id = v end
    end
    st.live_id = live_id
    reaper.gmem_write(G.GS_PENDING_LOAD_INST, live_id)
    reaper.gmem_write(G.CMD, 87)
    st.deadline = now + 2.0
    st.phase = "pubwait"

  elseif st.phase == "pubwait" then
    -- Payload-complete = ACK echoes our nonce (written before the CMD ack);
    -- also wait for CMD==0 so the stage+dispatch below owns a free bus.
    if math.floor(reaper.gmem_read(G.REB_PUB_ACK) or 0) == st.nonce
       and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      if math.floor(reaper.gmem_read(G.REB_RESTORE_GEN) or 0) < 1 then
        -- Instance hasn't deserialized yet (fresh insert / identity still
        -- settling) — retry briefly, then skip: nothing restored = nothing
        -- to rebase.
        st.tries = st.tries + 1
        if st.tries < 3 then
          st.phase = "pub"; st.wait_until = now + 1.0
        else
          st.i = st.i + 1; st.tries = 0; st.phase = "pub"
        end
        return
      end
      local skipped = math.floor(reaper.gmem_read(G.REB_SKIPPED) or 0)
      if skipped > 0 then
        reaper.ShowConsoleMsg(("[Swing] rebase: inst %d — %d path(s) exceed the 258-char gmem protocol and were not auditable\n")
          :format(st.live_id, skipped))
      end
      st.failbits_before = math.floor(reaper.gmem_read(G.REB_FAIL_BITS) or 0)
      -- ── Scan + stage ──────────────────────────────────────────────────
      local curdir = st.projfn:match("^(.*)[/\\]") or ""
      local unsaved = (reaper.GetResourcePath() .. "/Data/EON_Swing/unsaved"):gsub("\\", "/"):lower()
      -- Zero every MIGR staging cell first (empty = leave slot alone).
      for pad = 0, G.NUM_PADS - 1 do
        eon_write_gmem_path(G.MIGR_PAD_CELLS + pad * 260, "")
        for L = 0, G.MAX_LAYERS - 1 do
          eon_write_gmem_path(G.MIGR_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260, "")
        end
      end
      local staged, unrecov = 0, 0
      -- 80 recorded paths: pad-main (slot L = -1) + 4 layers per pad.
      for pad = 0, G.NUM_PADS - 1 do
        for L = -1, G.MAX_LAYERS - 1 do
          local src = (L < 0) and (G.REB_PAD_CELLS + pad * 260)
                              or (G.REB_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260)
          local p = eon_read_gmem_path(src)
          if p ~= "" and not eon_file_exists(p) then
            local norm = p:gsub("\\", "/")
            local mpos = norm:lower():find("/swing/samples/", 1, true)
            if norm:lower():find(unsaved, 1, true) == 1 then
              -- Unsaved-store path: valid on this machine; the migrate-on-
              -- save pass owns rewriting it. Not a rebase candidate.
            elseif mpos then
              local cand = curdir .. "/Swing/samples/" .. norm:sub(mpos + 15)
              if eon_file_exists(cand) then
                if #cand > 258 then
                  reaper.ShowConsoleMsg(("[Swing] rebase: pad %d rebased path too long for the 260-cell protocol (%d > 258 chars) — left broken\n")
                    :format(pad, #cand))
                  unrecov = unrecov + 1
                else
                  local dst = (L < 0) and (G.MIGR_PAD_CELLS + pad * 260)
                                      or (G.MIGR_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260)
                  eon_write_gmem_path(dst, cand)
                  staged = staged + 1
                end
              else
                unrecov = unrecov + 1
              end
            else
              unrecov = unrecov + 1
            end
          end
        end
      end
      st.staged = staged
      st.unrecov = unrecov
      if staged > 0 then
        reaper.gmem_write(G.MIGR_ADOPTED, -1)
        reaper.gmem_write(G.GS_PENDING_LOAD_INST, st.live_id)
        reaper.gmem_write(G.CMD, 88)
        st.deadline = now + 5.0   -- CMD-88 reloads are chunked 1 pad/@block
        st.phase = "rebwait"
      else
        st.phase = "finalize"
      end
    elseif now > st.deadline then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 87 then
        reaper.gmem_write(G.CMD, 0)   -- release our latch (pop-gate wedge rule)
      end
      st.tries = st.tries + 1
      if st.tries < 3 then
        st.phase = "pub"; st.wait_until = now + 0.5
      else
        st.i = st.i + 1; st.tries = 0; st.phase = "pub"
      end
    end

  elseif st.phase == "rebwait" then
    -- Complete = adopted echo landed (preset -1) AND the JSFX acked CMD=0
    -- (echo is written just before the ack; require both — never read a
    -- mid-flight state).
    local adopted = math.floor(reaper.gmem_read(G.MIGR_ADOPTED) or -1)
    if adopted >= 0 and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      if adopted < st.staged and st.tries < 3 then
        st.tries = st.tries + 1
        st.phase = "pub"; st.wait_until = now + 0.5   -- fresh publish + restage
      else
        st.phase = "finalize"
      end
    elseif now > st.deadline then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 88 then
        reaper.gmem_write(G.CMD, 0)
      end
      st.tries = st.tries + 1
      if st.tries < 3 then
        st.phase = "pub"; st.wait_until = now + 0.5
      else
        st.phase = "finalize"
      end
    end

  elseif st.phase == "finalize" then
    local failbits = math.floor(reaper.gmem_read(G.REB_FAIL_BITS) or 0)
    local unfixed  = eon_bits_count(failbits)
    local reloaded = math.max(0, eon_bits_count(st.failbits_before or 0) - unfixed)
    -- Map instance → registry slot for the per-slot banner short-circuit.
    for slot = 0, 15 do
      if math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE) or 0) == st.live_id then
        reaper.gmem_write(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE + 4, unfixed)
        reaper.gmem_write(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE + 5, os.time())
      end
    end
    if (st.staged or 0) > 0 or unfixed > 0 then
      reaper.ShowConsoleMsg(("[Swing] rebase: inst %d — %d path(s) rebased, %d pad(s) reloaded, %d pad(s) still missing\n")
        :format(st.live_id, st.staged or 0, reloaded, unfixed))
    end
    reaper.SetExtState("EON_Bridge", "dbg_rebase_result",
      ("inst%d:staged%d,reloaded%d,unfixed%d@%d"):format(st.live_id, st.staged or 0,
        reloaded, unfixed, os.time()), false)
    st.i = st.i + 1; st.tries = 0; st.phase = "pub"
  end
end

-- ── P4 step 3d: per-pad disk-health publisher ───────────────────────────────
-- The @serialize recoverability floor only checks that a path STRING exists;
-- this verifies the FILES (exists + WAV self-consistency) and publishes a
-- per-pad unhealthy bitmap into each instance's registry-slot band
-- (REB_SLOT_BASE +1 bits / +2 stamp / +3 gen). The JSFX consults it at save
-- time and force-embeds instead of writing a marker that would strand audio
-- (spec §4 "verify the sidecar before a marker-only embed"). Round-robin one
-- instance per pass, ~1 Hz; a CMD-87 publish runs only when that instance's
-- PATHS_GEN moved (paths cached per slot otherwise); the disk re-verify runs
-- from the cache every pass so an externally deleted file flips the bit
-- within a couple seconds without CMD traffic. GLOBALS (200-local ceiling).
eon_health = { cache = {}, st = nil, next_t = 0, rr = 1 }

-- Unhealthy iff the file a marker reload would need is missing or its WAV
-- header claims more data than the file holds (mid-write / truncated).
function eon_health_file_bad(path)
  if not path or path == "" then return true end
  local f = io.open(path, "rb")
  if not f then return true end
  local size = f:seek("end") or 0
  local bad = size < 45
  if not bad then
    f:seek("set", 36)
    local tag = f:read(4)
    if tag == "data" then
      local d = f:read(4)
      if d and #d == 4 then
        local dlen = d:byte(1) + d:byte(2) * 256 + d:byte(3) * 65536 + d:byte(4) * 16777216
        if 44 + dlen > size then bad = true end
      end
    end
  end
  f:close()
  return bad
end

-- Compute the unhealthy bitmap from a cached CMD-87 publish. Mirrors the
-- @serialize reload rules: layered pads need each l_len>0 layer's LPATH;
-- promoted-single (no LPATHs) and legacy pads need the pad-main path. Pads
-- with NO audio never set a bit (nothing for a marker to strand).
function eon_health_bits(c)
  local bits = 0
  for pad = 0, G.NUM_PADS - 1 do
    local bad = false
    local lc = c.layercnt[pad] or 0
    if lc > 0 then
      local anylp = false
      for L = 0, G.MAX_LAYERS - 1 do
        local li = pad * G.MAX_LAYERS + L
        if (c.lpaths[li] or "") ~= "" then
          anylp = true
          if (c.llen[li] or 0) > 0 and eon_health_file_bad(c.lpaths[li]) then bad = true end
        end
        -- layer audio with no LPATH at all = promoted-single → pad-main
        -- path is the disk source; handled by the !anylp check below.
      end
      if not anylp then
        local anyl = false
        for L = 0, G.MAX_LAYERS - 1 do
          if (c.llen[pad * G.MAX_LAYERS + L] or 0) > 0 then anyl = true end
        end
        if anyl and (c.paths[pad] or "") ~= "" and eon_health_file_bad(c.paths[pad]) then bad = true end
      end
    elseif (c.slen[pad] or 0) > 0 then
      if (c.paths[pad] or "") ~= "" and eon_health_file_bad(c.paths[pad]) then bad = true end
    end
    if bad then bits = bits + 2 ^ pad end
  end
  return bits
end

-- P4 sidecar backstop (spec §4 verify-before-marker): a marker-only save is
-- only safe while a plausible project sidecar exists for the instance — the
-- JSFX refuses the marker (force-embeds) unless the tick has verified one
-- this minute (REB slot cell +6). Ensure it here: when the sidecar is
-- missing, (re)copy it from the recorded kit source; a stale kit_sources
-- entry (file moved/deleted since load) is re-read from the track's P_EXT
-- hint so a repaired source heals without a kit reload. Chunk-restored
-- instances with NO valid source anywhere stay sc_ok=0 → the JSFX keeps
-- embedding (data-safe); a live-state export fallback is a known follow-up.
function eon_sidecar_plausible(p)
  if not p or p == "" then return false end
  local f = io.open(p, "rb"); if not f then return false end
  local size = f:seek("end") or 0; f:close()
  return size >= 16
end

function eon_sidecar_ensure_ok(swing)
  if not swing.guid or swing.guid == "" then return false end
  local dest = get_sidecar_path(swing.guid)
  if not dest then return false end          -- unsaved project: no sidecar home
  if eon_sidecar_plausible(dest) then return true end
  local src = kit_sources[swing.guid]
  if not eon_sidecar_plausible(src) and swing.tr
     and reaper.ValidatePtr2(0, swing.tr, "MediaTrack*") then
    local _, p2 = reaper.GetSetMediaTrackInfo_String(swing.tr, "P_EXT:swing_kit_src", "", false)
    if eon_sidecar_plausible(p2) then kit_sources[swing.guid] = p2; src = p2 end
  end
  if eon_sidecar_plausible(src) and file_copy(src, dest)
     and eon_sidecar_plausible(dest) then
    reaper.ShowConsoleMsg(("[EON sidecar] restored %s\n  from %s\n"):format(dest, src))
    return true
  end
  return false
end

function eon_health_tick()
  -- Kill switch for acceptance probes that need exclusive use of the CMD-87
  -- channel (ExtState EON_Bridge/health_tick = "0").
  if reaper.GetExtState("EON_Bridge", "health_tick") == "0" then return end
  -- Phase 4: LOADS OUTRANK HEALTH TELEMETRY. The load queue's pop gate
  -- waits for CMD==0, so a burst of health 87 publishes can starve a
  -- pending load of the shared CMD cell (caught as a ~1% strict-seq flake:
  -- "never settled, cmd=87"). Yield while a load is queued/in flight —
  -- UNLESS a publish is already mid-flight (hs.st), which must finish its
  -- ack/deadline handling or it would strand its 87 on the bus.
  if (current_load ~= nil or #pending_load_queue > 0) and not eon_health.st then
    return
  end
  local now = reaper.time_precise()
  local hs = eon_health
  -- In-flight CMD-87 publish for a health refresh?
  if hs.st then
    local st = hs.st
    if math.floor(reaper.gmem_read(G.REB_PUB_ACK) or 0) == st.nonce
       and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      local c = { gen = st.gen, paths = {}, lpaths = {}, slen = {}, llen = {}, layercnt = {} }
      for pad = 0, G.NUM_PADS - 1 do
        c.paths[pad]    = eon_read_gmem_path(G.REB_PAD_CELLS + pad * 260)
        c.slen[pad]     = math.floor(reaper.gmem_read(G.REB_SLEN + pad) or 0)
        c.layercnt[pad] = math.floor(reaper.gmem_read(G.REB_LAYERCNT + pad) or 0)
        for L = 0, G.MAX_LAYERS - 1 do
          local li = pad * G.MAX_LAYERS + L
          c.lpaths[li] = eon_read_gmem_path(G.REB_LAYER_CELLS + li * 260)
          c.llen[li]   = math.floor(reaper.gmem_read(G.REB_LLEN + li) or 0)
        end
      end
      hs.cache[st.slot] = c
      hs.st = nil
      -- verdict written by the per-slot pass below on the next tick
    elseif now > st.deadline then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 87 then reaper.gmem_write(G.CMD, 0) end
      hs.st = nil   -- give up this round; round-robin retries later
    end
    return
  end
  if now < hs.next_t then return end
  hs.next_t = now + 1.0
  local swings = enumerate_all_swings()
  if #swings == 0 then return end
  if hs.rr > #swings then hs.rr = 1 end
  local swing = swings[hs.rr]
  hs.rr = hs.rr + 1
  -- resolve this instance's registry slot
  local live_id = swing.inst_id
  if swing.tr and reaper.ValidatePtr2(0, swing.tr, "MediaTrack*") then
    local v = math.floor(reaper.TrackFX_GetParam(swing.tr, swing.fx, 3) or 0)
    if v > 0 then live_id = v end
  end
  local slot
  for s = 0, 15 do
    if math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE) or 0) == live_id then
      slot = s; break
    end
  end
  if not slot then return end
  local gen = math.floor(reaper.gmem_read(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE) or 0)
  local c = hs.cache[slot]
  if c and c.gen == gen then
    -- Paths unchanged: re-verify the disk from the cache (catches external
    -- deletions) and refresh the verdict cells. Sidecar verdict (+6) rides
    -- the same stamp/gen freshness window — payload first, stamp/gen last.
    reaper.gmem_write(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE + 6,
                      eon_sidecar_ensure_ok(swing) and 1 or 0)
    reaper.gmem_write(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE + 1, eon_health_bits(c))
    reaper.gmem_write(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE + 2, os.time())
    reaper.gmem_write(G.REB_SLOT_BASE + slot * G.REB_SLOT_STRIDE + 3, gen)
    return
  end
  -- Paths changed since the cache: request a fresh publish — only when the
  -- whole pipeline is idle (never contend with loads/migrate/rebase).
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0
     or current_load ~= nil or #pending_load_queue > 0
     or eon_migr_state ~= nil or eon_rebase_state ~= nil or eon_pp_stream ~= nil
     or math.floor(reaper.gmem_read(G.HS_CAP) or 0) < 203 then
    return
  end
  eon_reb_nonce = (eon_reb_nonce or 0) + 1
  reaper.gmem_write(G.REB_PUB_ACK, 0)
  reaper.gmem_write(G.REB_PUB_REQ, eon_reb_nonce)
  reaper.gmem_write(G.GS_PENDING_LOAD_INST, live_id)
  reaper.gmem_write(G.CMD, 87)
  hs.st = { slot = slot, live_id = live_id, gen = gen, deadline = now + 2.0,
            nonce = eon_reb_nonce }
end

-- ── P4 step 3e: banner-driven relink ────────────────────────────────────────
-- The missing-samples banner's "Relink samples folder..." posts CMD 89; the
-- dispatcher picks a folder (JS_Dialog_BrowseForFolder) and arms this pumped
-- machine: CMD-87 publish → for every dead recorded path, depth-capped
-- basename search under the chosen folder → stage hits into the MIGR band →
-- CMD 88 (adopt + reload blank). Fail bits clear via the loaders on success,
-- which retires the banner by itself. GLOBALS (200-local ceiling).
eon_relink_state = nil

-- Depth-capped recursive case-insensitive basename search. Collects each
-- directory's listing BEFORE recursing (EnumerateFiles keeps one cache per
-- path — don't interleave parent/child enumeration).
function eon_relink_find(dir, base_lower, depth)
  if depth > 6 then return nil end
  reaper.EnumerateFiles(dir, -1)
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    if fn:lower() == base_lower then return dir .. "/" .. fn end
    i = i + 1
  end
  local subs = {}
  reaper.EnumerateSubdirectories(dir, -1)
  i = 0
  while true do
    local sub = reaper.EnumerateSubdirectories(dir, i)
    if not sub then break end
    subs[#subs + 1] = sub
    i = i + 1
  end
  for _, sub in ipairs(subs) do
    local hit = eon_relink_find(dir .. "/" .. sub, base_lower, depth + 1)
    if hit then return hit end
  end
  return nil
end

function eon_relink_kick(inst_id, folder)
  if eon_relink_state then return end
  for _, swing in ipairs(enumerate_all_swings()) do
    if swing.inst_id == inst_id then
      eon_relink_state = { inst = swing, folder = folder, phase = "pub", tries = 0 }
      reaper.ShowConsoleMsg(("[Swing] relink: searching %s for missing samples (inst %d)\n")
        :format(folder, inst_id))
      return
    end
  end
  reaper.ShowConsoleMsg("[Swing] relink: requesting instance not found\n")
end

-- ── P5: manual "Clean sample store" op ──────────────────────────────────────
-- Reclaims orphaned extraction dirs left in a SAVED project's store
-- (<projdir>/Swing/samples/{kits,chops}) — each kit re-save mints a fresh
-- content-keyed dir, orphaning the old one. Triggered by the
-- EON_Swing_Clean_Store action via ExtState clean_store_req=1.
-- SAFETY: keep-set = union of {live pad/layer dirs from EVERY registered
-- instance via CMD-87} ∪ {each project sidecar's would-reuse extraction dir}.
-- ABORTS (deletes nothing) if any Swing instance is unregistered/unresponsive
-- — better to reclaim nothing than a dir something still needs. Only ever
-- deletes dirs strictly under this project's store (belt-and-suspenders
-- prefix clamp). GLOBALS (bridge at the 200-local ceiling).
eon_clean_state = nil
function _eon_cln_norm(p) return (p or ""):gsub("\\", "/"):lower() end
function _eon_cln_parent(p) return (_eon_cln_norm(p):match("^(.*)/[^/]*$")) or "" end

function _eon_clean_finish(st, msg)
  reaper.SetExtState("EON_Bridge", "health_tick", "", false)   -- restore the tick
  reaper.SetExtState("EON_Bridge", "clean_store_result", msg, false)
  reaper.ShowConsoleMsg("[EON store] clean: " .. msg .. "\n")
  if not st.noui then eon_notice("Clean sample store:\n\n" .. msg, "EON Swing") end
  eon_clean_state = nil
end

-- Returns true when the request is settled (armed or terminally rejected) and
-- the caller should clear clean_store_req; false on a TRANSIENT-busy so the
-- flag stays set and the next poll retries (bounded by eon_clean_busy_since).
eon_clean_busy_since = nil
function eon_clean_store_kick()
  if eon_clean_state then return true end
  local noui = reaper.GetExtState("EON_Bridge", "clean_store_noui") == "1"
  local function reject(msg)   -- terminal: report + settle
    reaper.SetExtState("EON_Bridge", "clean_store_result", msg, false)
    reaper.ShowConsoleMsg("[EON store] clean: " .. msg .. "\n")
    if not noui then eon_notice("Clean sample store:\n\n" .. msg, "EON Swing") end
    eon_clean_busy_since = nil
    return true
  end
  local _, projfn = reaper.EnumProjects(-1)
  if not projfn or projfn == "" then
    return reject("needs a SAVED project — save first, then retry. Nothing deleted.")
  end
  if math.floor(reaper.gmem_read(G.HS_CAP) or 0) < 203 then
    return reject("the loaded Swing build is too old — reopen the project so the current Swing compiles.")
  end
  -- never contend with an in-flight pipeline op (they own CMD / the REB band).
  -- This is usually TRANSIENT (a load/rebase settling), so keep the request
  -- armed and retry next poll rather than dropping it — up to 10s.
  if math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0 or current_load ~= nil
     or #pending_load_queue > 0 or eon_migr_state ~= nil or eon_rebase_state ~= nil
     or eon_relink_state ~= nil or eon_pp_stream ~= nil then
    eon_clean_busy_since = eon_clean_busy_since or reaper.time_precise()
    if reaper.time_precise() - eon_clean_busy_since > 10.0 then
      return reject("Swing stayed busy (a kit load or repair kept running) — try again in a moment. Nothing deleted.")
    end
    return false   -- transient: leave clean_store_req set, retry next poll
  end
  eon_clean_busy_since = nil
  -- ⚠️ TWO forms of the same path, and they are NOT interchangeable.
  -- `store`      lowercased — ONLY ever a lookup key (st.keep) or the safety
  --              clamp prefix, where both sides go through _eon_cln_norm.
  -- `store_real` real case — EVERY filesystem call must use this one.
  -- They used to be the same lowercased string, which on a case-sensitive
  -- filesystem named a directory that does not exist (the real one is
  -- "Swing/samples", capital S — see eon_kit_store_dir's caller at :8250).
  -- The sweep then enumerated nothing, deleted nothing, and still reported
  -- "reclaimed 0 ... kept 0", so the store grew for ever on Linux with no
  -- symptom. It also fed the lowercased path to eon_kit_store_dir, which
  -- io.opens the file to build its content key — that open fails on Linux,
  -- yielding a degenerate key that could never match the keep-set.
  local store_real = (projfn:match("(.*[/\\])") .. "Swing/samples"):gsub("\\", "/")
  local store = _eon_cln_norm(store_real)
  reaper.SetExtState("EON_Bridge", "health_tick", "0", false)   -- own the CMD-87 channel
  eon_clean_state = { phase = "collect", noui = noui, store = store,
    store_real = store_real,
    swings = enumerate_all_swings(), si = 1, keep = {}, nonce = 0,
    deadline = 0, tries = 0, waiting = false }
  return true
end

function eon_clean_pump()
  local st = eon_clean_state
  if not st then return end
  local now = reaper.time_precise()

  if st.phase == "collect" then
    if st.si > #st.swings then st.phase = "sidecars"; return end
    local sw = st.swings[st.si]
    local live_id = sw.inst_id
    if sw.tr and reaper.ValidatePtr2(0, sw.tr, "MediaTrack*") then
      local v = math.floor(reaper.TrackFX_GetParam(sw.tr, sw.fx, 3) or 0)
      if v > 0 then live_id = v end
    end
    local slot
    for s = 0, 15 do
      if math.floor(reaper.gmem_read(
           G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE) or 0) == live_id then slot = s; break end
    end
    if not slot then
      return _eon_clean_finish(st, ("aborted: a Swing instance (id %d) isn't registered/responsive — nothing deleted. Reopen or wait, then retry."):format(live_id))
    end
    if not st.waiting then
      st.nonce = (eon_reb_nonce or 0) + 1; eon_reb_nonce = st.nonce
      reaper.gmem_write(G.REB_PUB_ACK, 0)
      reaper.gmem_write(G.REB_PUB_REQ, st.nonce)
      reaper.gmem_write(G.GS_PENDING_LOAD_INST, live_id)
      reaper.gmem_write(G.CMD, 87)
      st.waiting = true; st.deadline = now + 2.0
      return
    end
    if math.floor(reaper.gmem_read(G.REB_PUB_ACK) or 0) == st.nonce
       and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      for pad = 0, G.NUM_PADS - 1 do
        local pp = eon_read_gmem_path(G.REB_PAD_CELLS + pad * 260)
        if pp ~= "" then st.keep[_eon_cln_parent(pp)] = true end
        for L = 0, G.MAX_LAYERS - 1 do
          local lp = eon_read_gmem_path(G.REB_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260)
          if lp ~= "" then st.keep[_eon_cln_parent(lp)] = true end
        end
      end
      st.waiting = false; st.tries = 0; st.si = st.si + 1
      return
    end
    if now > st.deadline then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 87 then reaper.gmem_write(G.CMD, 0) end
      st.waiting = false; st.tries = st.tries + 1
      if st.tries >= 3 then
        return _eon_clean_finish(st, ("aborted: instance %d didn't answer CMD-87 — nothing deleted."):format(live_id))
      end
    end
    return

  elseif st.phase == "sidecars" then
    -- Real case: this is enumerated, and each hit is handed to
    -- eon_kit_store_dir, which io.opens it. Only the RESULT is normalised
    -- into a keep-set key.
    local sdir = st.store_real:gsub("/samples$", "")   -- <projdir>/Swing
    local i = 0
    while true do
      local fn = reaper.EnumerateFiles(sdir, i)
      if not fn or fn == "" then break end
      if fn:match("%.swing$") then
        st.keep[_eon_cln_norm(eon_kit_store_dir(sdir .. "/" .. fn))] = true
      end
      i = i + 1
    end
    st.phase = "sweep"; return

  elseif st.phase == "sweep" then
    local removed, kept = 0, 0
    for _, sub in ipairs({ "kits", "chops" }) do
      -- Real case for enumeration and removal; the clamp below still compares
      -- normalised key against normalised st.store, so both sides stay lowercase.
      local base = st.store_real .. "/" .. sub
      local dirs, i = {}, 0
      while true do
        local dn = reaper.EnumerateSubdirectories(base, i)
        if not dn or dn == "" then break end
        dirs[#dirs + 1] = dn; i = i + 1
      end
      for _, dn in ipairs(dirs) do
        local dir = base .. "/" .. dn
        local key = _eon_cln_norm(dir)
        -- SAFETY CLAMP: only ever touch dirs strictly under this project store
        if key:sub(1, #st.store + 1) == st.store .. "/" and not st.keep[key] then
          local files, k = {}, 0
          while true do
            local fn = reaper.EnumerateFiles(dir, k)
            if not fn or fn == "" then break end
            files[#files + 1] = fn; k = k + 1
          end
          for _, fn in ipairs(files) do os.remove(dir .. "/" .. fn) end
          removed = removed + 1
          reaper.ShowConsoleMsg("[EON store] clean: reclaimed " .. dir .. "\n")
        else
          kept = kept + 1
        end
      end
    end
    return _eon_clean_finish(st, ("reclaimed %d orphaned dir(s); kept %d in use."):format(removed, kept))
  end
end

function eon_relink_pump()
  local st = eon_relink_state
  if not st then return end
  local now = reaper.time_precise()
  if st.wait_until and now < st.wait_until then return end
  st.wait_until = nil
  if st.phase == "pub"
     and (math.floor(reaper.gmem_read(G.CMD) or 0) ~= 0
          or current_load ~= nil or #pending_load_queue > 0
          or eon_migr_state ~= nil or eon_rebase_state ~= nil or eon_pp_stream ~= nil) then
    return
  end

  if st.phase == "pub" then
    eon_reb_nonce = (eon_reb_nonce or 0) + 1
    st.nonce = eon_reb_nonce
    reaper.gmem_write(G.REB_PUB_ACK, 0)
    reaper.gmem_write(G.REB_PUB_REQ, st.nonce)
    local live_id = st.inst.inst_id
    if st.inst.tr and reaper.ValidatePtr2(0, st.inst.tr, "MediaTrack*") then
      local v = math.floor(reaper.TrackFX_GetParam(st.inst.tr, st.inst.fx, 3) or 0)
      if v > 0 then live_id = v end
    end
    st.live_id = live_id
    reaper.gmem_write(G.GS_PENDING_LOAD_INST, live_id)
    reaper.gmem_write(G.CMD, 87)
    st.deadline = now + 2.0
    st.phase = "pubwait"

  elseif st.phase == "pubwait" then
    if math.floor(reaper.gmem_read(G.REB_PUB_ACK) or 0) == st.nonce
       and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      for pad = 0, G.NUM_PADS - 1 do
        eon_write_gmem_path(G.MIGR_PAD_CELLS + pad * 260, "")
        for L = 0, G.MAX_LAYERS - 1 do
          eon_write_gmem_path(G.MIGR_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260, "")
        end
      end
      local staged, missing = 0, 0
      for pad = 0, G.NUM_PADS - 1 do
        for L = -1, G.MAX_LAYERS - 1 do
          local src = (L < 0) and (G.REB_PAD_CELLS + pad * 260)
                              or (G.REB_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260)
          local p = eon_read_gmem_path(src)
          if p ~= "" and not eon_file_exists(p) then
            local base = (p:match("([^/\\]+)$") or ""):lower()
            local hit = base ~= "" and eon_relink_find(st.folder, base, 0) or nil
            if hit and #hit <= 258 then
              local dst = (L < 0) and (G.MIGR_PAD_CELLS + pad * 260)
                                  or (G.MIGR_LAYER_CELLS + (pad * G.MAX_LAYERS + L) * 260)
              eon_write_gmem_path(dst, hit)
              staged = staged + 1
            else
              missing = missing + 1
              if hit then
                reaper.ShowConsoleMsg(("[Swing] relink: match for pad %d exceeds the 258-char path protocol — skipped\n"):format(pad))
              end
            end
          end
        end
      end
      st.staged = staged
      if staged > 0 then
        reaper.gmem_write(G.MIGR_ADOPTED, -1)
        reaper.gmem_write(G.GS_PENDING_LOAD_INST, st.live_id)
        reaper.gmem_write(G.CMD, 88)
        st.deadline = now + 5.0
        st.phase = "rebwait"
      else
        reaper.ShowConsoleMsg(("[Swing] relink: no matches under the chosen folder (%d path(s) still missing)\n")
          :format(missing))
        reaper.SetExtState("EON_Bridge", "dbg_relink_result",
          ("nomatch,missing%d@%d"):format(missing, os.time()), false)
        eon_relink_state = nil
      end
    elseif now > st.deadline then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 87 then reaper.gmem_write(G.CMD, 0) end
      st.tries = st.tries + 1
      if st.tries < 3 then
        st.phase = "pub"; st.wait_until = now + 0.5
      else
        reaper.ShowConsoleMsg("[Swing] relink: publish timeout — try again\n")
        eon_relink_state = nil
      end
    end

  elseif st.phase == "rebwait" then
    local adopted = math.floor(reaper.gmem_read(G.MIGR_ADOPTED) or -1)
    if adopted >= 0 and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
      local fb = math.floor(reaper.gmem_read(G.REB_FAIL_BITS) or 0)
      reaper.ShowConsoleMsg(("[Swing] relink: %d path(s) relinked, %d pad(s) still missing\n")
        :format(adopted, eon_bits_count(fb)))
      reaper.SetExtState("EON_Bridge", "dbg_relink_result",
        ("relinked%d,failbits%d@%d"):format(adopted, fb, os.time()), false)
      eon_relink_state = nil
    elseif now > st.deadline then
      if math.floor(reaper.gmem_read(G.CMD) or 0) == 88 then reaper.gmem_write(G.CMD, 0) end
      reaper.ShowConsoleMsg("[Swing] relink: CMD-88 timeout — try again\n")
      eon_relink_state = nil
    end
  end
end


-- Detect "new instance appeared this session" via primed_instances table.
-- Detect "project switched/reopened OR Save As" via filename change.
local function poll_sidecar_events()
  -- Project change detection — clear primed table on switch/reopen.
  -- Save As also lands here (filename changes from old to new). When
  -- the change is between two real projects (not blank → blank), treat
  -- it as an implicit save event so sidecars get written to the new
  -- path. Without this, Save As would never trigger sidecar write —
  -- the IsProjectDirty 1→0 transition gets consumed by the rename.
  local _, cur_proj_filename = reaper.EnumProjects(-1)
  cur_proj_filename = cur_proj_filename or ""
  if cur_proj_filename ~= prev_proj_filename then
    primed_instances = {}
    pending_load_queue = {}
    local was_save_as = (prev_proj_filename ~= "" and cur_proj_filename ~= "")
    -- P3: FIRST SAVE of an untitled project also lands here (blank → real
    -- filename) — and this branch resets prev_proj_dirty, so the dirty 1→0
    -- hook below never sees it. Handle it explicitly or unsaved-store chops
    -- are never migrated on the most common path.
    local was_first_save = (prev_proj_filename == "" and cur_proj_filename ~= "")
    -- Capture the PREVIOUS project dir before the pointer moves — Save As
    -- must carry the sample store (kits/ + chops/) to the new project folder.
    -- Sidecars were already copied by auto_save_all_sidecars; samples weren't.
    local prev_dir = prev_proj_filename:match("^(.*)[/\\]")
    prev_proj_filename = cur_proj_filename
    prev_proj_dirty = -1
    if was_save_as then
      auto_save_all_sidecars()
      local new_dir = cur_proj_filename:match("^(.*)[/\\]")
      if prev_dir and new_dir and prev_dir ~= new_dir then
        eon_copy_tree(prev_dir .. "/Swing/samples", new_dir .. "/Swing/samples")
      end
      eon_migrate_kick()   -- unsaved-store chops → the (new) project store
    elseif was_first_save then
      auto_save_all_sidecars()   -- sidecars for the first save too
      eon_migrate_kick()         -- unsaved-store chops → the new project store
    end
    -- P4 step 3c: ANY change onto a real project audits recorded disk paths
    -- and auto-rebases ones broken by a folder move/rename. This detector
    -- cannot distinguish Save As from a tab switch / reopen (both are
    -- saved→saved filename changes — the was_save_as branch fires for
    -- BOTH, acceptance probe run 1 proved the final-elseif placement never
    -- ran for real opens), so kick unconditionally: the audit is dead-
    -- paths-only and silent when everything resolves, so over-firing costs
    -- one CMD-87 publish per instance.
    if cur_proj_filename ~= "" then
      eon_rebase_kick()
    end
  end

  -- Save trigger — IsProjectDirty(0) returns >0=dirty, 0=clean
  local dirty = reaper.IsProjectDirty(0) or 0
  if prev_proj_dirty > 0 and dirty == 0 then
    auto_save_all_sidecars()
    eon_migrate_kick()     -- P3: first save of an unsaved project w/ chops
  end
  prev_proj_dirty = dirty

  -- Load trigger — mark every Swing instance primed once per session.
  -- ⚠️ The on-open sidecar RELOAD is ON by default — the block comment here
  -- claimed "DISABLED by default (2026-07-06)" for over a month while the
  -- inline check below shipped `~= "0"` = default-ON (perf sweep 2026-08-06
  -- caught the lie). ON is deliberate: large kits (909/808_v2) exceed the
  -- @serialize FX-chunk ceiling and truncate, and the sidecar reload is their
  -- ONLY recovery. Cost: every kit loads twice at project open (chunk restore
  -- + this reload, incl. temp-WAV extraction) — the main open-latency item.
  -- Post-3.0 design item: reload only when the chunk actually truncated.
  -- Opt out per machine with ExtState EON_Bridge/openload_reload = "0".
  local swings = enumerate_all_swings()
  for _, swing in ipairs(swings) do
    if not primed_instances[swing.inst_id] then
      primed_instances[swing.inst_id] = true
      if reaper.GetExtState("EON_Bridge", "openload_reload") ~= "0" then  -- reload ON: large kits (909/808_v2) exceed the @serialize FX-chunk ceiling & truncate; sidecar reload is their ONLY recovery. Disable with ExtState "0".
        queue_sidecar_load_if_present(swing)
      end
      _eon_stereo_setup_for_new_swing(swing)
    end
  end

  -- ── Audio-repair trigger ────────────────────────────────────────────
  -- JSFX writes GS_AUDIO_REPAIR_REQ = its instance_id when it detects
  -- chunk-truncated audio after a deserialize (Undo, Redo, project
  -- chunk restore). The detector is in @serialize is_read tail (see
  -- Swing_ReaKit.jsfx) — it probes 3 positions per pad and flags if
  -- the buffer reads as zeroed despite metadata claiming s_len > 100.
  --
  -- Repair = re-run Path B for that one instance only: find its
  -- tr/fx, queue queue_sidecar_load_if_present for it (which falls
  -- through project-sidecar → track-ExtState → 808 default if needed),
  -- and let drive_load_queue dispatch it the next tick.
  --
  -- LIMITATION: the sidecar reflects whatever was on disk at the LAST
  -- project save. If the user changed kits between saves and then
  -- triggered an Undo-style repair, the audio may not match the
  -- restored metadata. Acceptable trade-off vs. the alternative
  -- (silent blank pads). Documented in CLAUDE.md / project docs.
  local repair_inst = math.floor(reaper.gmem_read(G.GS_AUDIO_REPAIR_REQ) or 0)
  if repair_inst > 0 then
    -- Consume the request immediately so the JSFX doesn't keep re-
    -- writing it every poll (it's set by @serialize, not @block, so
    -- it only fires once per chunk restore — but defensive clear
    -- still right thing to do)
    reaper.gmem_write(G.GS_AUDIO_REPAIR_REQ, 0)
    -- Re-prime this instance so queue_sidecar_load_if_present is
    -- willing to fire for it (primed_instances guards re-load).
    primed_instances[repair_inst] = nil
    -- Locate the swing for this inst_id and queue it
    local repair_swing
    for _, swing in ipairs(swings) do
      if swing.inst_id == repair_inst then
        repair_swing = swing
        break
      end
    end
    if repair_swing then
      -- Diagnostic, not a user message — it names an instance id and an
      -- internal failure mode. Gated like the bridge's other debug output
      -- (ShowConsoleMsg OPENS the console, so an ungated one pops a window
      -- at a customer mid-session). Enable with:
      --   reaper.SetExtState("EON_Swing", "repair_debug", "1", false)
      if reaper.GetExtState("EON_Swing", "repair_debug") == "1" then
        reaper.ShowConsoleMsg(string.format(
          "[Swing] audio repair: chunk-truncated kit detected on inst=%d → reloading from sidecar/808\n",
          repair_inst
        ))
      end
      primed_instances[repair_inst] = true
      queue_sidecar_load_if_present(repair_swing)
    end
  end

  -- Process the load queue (one at a time, waiting for JSFX completion).
  -- Save is now synchronous (file copy in auto_save_all_sidecars), no
  -- queue needed.
  drive_load_queue()

  -- Stale LOCK detection. The bridge's general CMD-completion auto-
  -- release (in the main poll, after the cmd dispatch) only fires when
  -- CMD transitions to 0/98/99. If something orphans LOCK without
  -- changing CMD (e.g., a kit-import that errors silently in the
  -- middle, or a previous bridge session leaving stale state), LOCK
  -- stays pinned forever. The JSFX-side auto-load 808 gates on
  -- `gmem[LOCK] == 0`, so this stuck state means fresh Swing inserts
  -- never auto-load. When everything is genuinely idle (no in-flight
  -- load, no pending queue, no CMD), it's safe to clear LOCK.
  if not current_load and #pending_load_queue == 0 then
    local cmd_now  = math.floor(reaper.gmem_read(G.CMD) or 0)
    local lock_now = math.floor(reaper.gmem_read(G.LOCK) or 0)
    if cmd_now == 0 and lock_now ~= 0 then
      reaper.gmem_write(G.LOCK, 0)
    end
  end

  -- Lua-posted completion release (2026-08-19). Ops posted from plain Lua
  -- (eon_action_target bridge()/post_locked — the Song Starter, the EON menu
  -- wrappers) have no armed JSFX waiting on their completion code. Orphan 99s
  -- are eaten in ms by every idle instance's misc_cmds — and that consume
  -- doubles as the pad name/color refresh, so 99 must be LEFT ALONE — but
  -- nothing eats an orphan 98 (teaching bystander instances to eat 98 would
  -- let them steal an ARMED importer's abort): a cancelled FX-returns dialog
  -- parked a 98 on the bus for the watchdog's full 5s fuse, dropping every
  -- CMD==0-gated post in the window. The poster stamps GS_CMD_LUA_POST with
  -- the code; track the op and release its 98 the tick it lands. Guarded on
  -- the constant so a stale rk_lua_core degrades to the watchdog, not a crash.
  if G.GS_CMD_LUA_POST then
    local cmd_now = math.floor(reaper.gmem_read(G.CMD) or 0)
    local stamp   = math.floor(reaper.gmem_read(G.GS_CMD_LUA_POST) or 0)
    if stamp ~= 0 then
      if cmd_now == stamp then
        _eon_lua_op = stamp                          -- op observed on the bus
        reaper.gmem_write(G.GS_CMD_LUA_POST, 0)      -- stamp consumed
        _eon_lua_stale = nil
      elseif cmd_now == 0 then
        -- Two sightings before declaring the stamp stale: the poster writes
        -- the stamp a hair before CMD, so one idle-bus sighting can be a
        -- mid-post snapshot.
        if _eon_lua_stale then
          reaper.gmem_write(G.GS_CMD_LUA_POST, 0)
          _eon_lua_stale = nil
        else
          _eon_lua_stale = true
        end
      else
        _eon_lua_stale = nil   -- an older op still draining; keep the stamp
      end
    else
      _eon_lua_stale = nil
    end
    if _eon_lua_op then
      if cmd_now == 98 then
        reaper.gmem_write(G.CMD, 0)
        reaper.gmem_write(G.LOCK, 0)
        _eon_lua_op = nil
      elseif cmd_now == 0 then
        _eon_lua_op = nil     -- completed (self-cleared or misc_cmds ate a 99)
      end
      -- 97 (parked dialog) and mid-op codes: keep tracking
    end
  end

  do
    local cmd_now = math.floor(reaper.gmem_read(G.CMD) or 0)
    -- ── Stale-CMD watchdog (2026-07-15 pitch-source starvation) ──────────
    -- A bridge-staged CMD is only ever consumed by a JSFX instance in the
    -- matching state (3 needs kit_import_state==1; 65/66/67 need the routed
    -- instance alive; 98/99 need an importer/exporter to ack). If the
    -- consumer never shows up — instance deleted, stale inst_id, audio
    -- device closed, or a bridge restart orphaning a half-done handshake —
    -- the value latches forever: poll_autoexport, the bake-swap stagers and
    -- drive_load_queue's pop gate ALL bail on CMD~=0, so Stretch/Tuned pads
    -- starve until a full REAPER restart (observed live 2026-07-15, CMD=3
    -- for hours). Watch the channel whenever nothing OWNS it: no in-flight
    -- dispatched load (current_load), no VER-26 stream, no CMD-66 capture
    -- pending — and clear any bridge-owned value that sits unconsumed too
    -- long. A non-empty pending_load_queue must NOT disable the watchdog:
    -- queued items touch no gmem until pop (staging + current_load are set
    -- inside one drive_load_queue call), and on bridge boot the sidecar
    -- reload queues IMMEDIATELY with its pop blocked by the very stale CMD
    -- we're here to clear — gating on queue-empty deadlocks (acceptance
    -- probe run 1, 2026-07-15: CMD=3 held 45s+ across a bridge restart).
    -- Thresholds: 3 → 15s (a legit INLINE monolithic VER-24 import holds 3
    -- with current_load nil for its whole gmem copy — worst-case ~14s for a
    -- maxed 64M staging at 2048-sample blocks); 65/66/67 → 10s (consumed
    -- within ms when alive; 66's own pollers time out at 2s); 63/64 → 10s
    -- (browser/loader single-pad loads — latch forever if gmem[INSTANCE]
    -- binds a dead id; consumed within a block when the target is alive,
    -- and both producers gate on CMD==0 so a latched 63 is never a load
    -- that is merely waiting behind a kit import); 87/88 → 10s
    -- (P4 rebase/relink handshakes — their pumps supervise their own 2s/5s
    -- deadlines, this is the bridge-restart-orphan backstop; a legit 88
    -- holds ≤16 blocks); 98/99 → 5s
    -- (ack codes, also our own 3-abort's second stage). A stale 3 is
    -- aborted with 98, not 0, so an importer wedged in kit_import_state 1
    -- (device closed after the delivery gate fired) still gets its clean
    -- abort on wake; the 98 arm then finishes the job if nobody consumes.
    -- State lives in a GLOBAL (main chunk is at Lua's 200-local ceiling).
    if _eon_cmd_wd == nil then _eon_cmd_wd = { v = 0, t = 0 } end
    if current_load or eon_pp_stream or _eon_autoexport or _eon_layer.export then
      _eon_cmd_wd.v = -1     -- channel legitimately owned; re-latch when free
    elseif cmd_now ~= _eon_cmd_wd.v then
      _eon_cmd_wd.v = cmd_now
      _eon_cmd_wd.t = reaper.time_precise()
    elseif cmd_now == 3 or cmd_now == 65 or cmd_now == 66 or cmd_now == 67
        or cmd_now == 63 or cmd_now == 64
        or cmd_now == 87 or cmd_now == 88 or cmd_now == 89
        or cmd_now == 98 or cmd_now == 99 then
      local held = reaper.time_precise() - _eon_cmd_wd.t
      if cmd_now == 3 and held > 15.0 then
        reaper.gmem_write(G.CMD, 98)
        -- Disarm the delivery gate too: a late-waking instance firing on a
        -- stale REQ=2 would import gmem bands the next load has overwritten.
        if math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 2 then
          reaper.gmem_write(G.GS_KIT_LOAD_REQ, 0)
          reaper.gmem_write(G.GS_PENDING_LOAD_INST, 0)
        end
        reaper.ShowConsoleMsg(("[Swing] CMD watchdog: stale kit-staging latch CMD=3 sat %.1fs with no load in flight — aborted (98)\n")
          :format(held))
        _eon_cmd_wd.v = -1
      elseif cmd_now ~= 3 and held > ((cmd_now == 98 or cmd_now == 99) and 5.0 or 10.0) then
        reaper.gmem_write(G.CMD, 0)
        -- A stale 63/64 may carry an armed name-adopt flag (fill staged it,
        -- no consumer took it). Drop it with the command, or the NEXT
        -- name-blind CMD-63 producer silently keeps the old pad name
        -- (REVIEW 2026-07-27).
        if cmd_now == 63 or cmd_now == 64 then
          reaper.gmem_write(G.GS_BROWSE_NAME_ADOPT, 0)
        end
        reaper.ShowConsoleMsg(("[Swing] CMD watchdog: cleared stale CMD=%d (sat %.1fs, no consumer)\n")
          :format(cmd_now, held))
        _eon_cmd_wd.v = -1
      end
    end
  end
end

-- Toolbar lit-state for the EON toggle actions. REAPER only lights a toolbar
-- button when its action reports a toggle state, so the bridge (which knows the
-- live state) mirrors each toggle onto its command id via SetToggleCommandState
-- + RefreshToolbar2 — firing only on change, throttled to ~4 Hz. GLOBAL (this
-- chunk is at the 200-local cap; adds zero main-chunk locals). is_stepseq_fx /
-- eon_fx_float_visible are globals; GS_BROWSER_OPEN / core are upvalues.
_eon_tog   = nil
_eon_tog_t = 0
function eon_update_toggle_states()
  local now = reaper.time_precise()
  if now < _eon_tog_t then return end
  _eon_tog_t = now + 0.25

  if not _eon_tog then
    local sp = package.config:sub(1, 1)
    local d  = (debug.getinfo(1, "S").source:match("@?(.*)") or ""):match("^(.*)[/\\]")
    if not d then return end
    local function rid(f)
      local i = reaper.AddRemoveReaScript(true, 0, d .. sp .. f, false)
      return (i and i > 0) and i or nil
    end
    _eon_tog = {
      { id = rid("EON_Swing_ToggleGrid.lua"), last = -1, get = function()
          local t = tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9
          return (reaper.time_precise() - t) < 5 and 1 or 0 end },
      { id = rid("EON_Swing_TogglePaint.lua"), last = -1, get = function()
          return reaper.GetExtState("EON_DRUM_MATRIX", "paint_mode") == "1" and 1 or 0 end },
      { id = rid("EON_Swing_ToggleMediaExplorer.lua"), last = -1, get = function()
          return reaper.GetToggleCommandState(50124) == 1 and 1 or 0 end },
      { id = rid("EON_Toggle_Swing_Browser.lua"), last = -1, get = function()
          -- ExtState only: the browser re-attaches a different gmem segment
          -- mid-script, so its GS_BROWSER_OPEN write is unreliable to read here.
          -- browser_running is set on open / cleared on close (segment-free).
          return reaper.GetExtState("Swing", "browser_running") == "1" and 1 or 0 end },
      { id = rid("EON_Toggle_Swing_PadFX.lua"), last = -1, get = function()
          if reaper.GetExtState("Swing", "padfx_running") ~= "1" then return 0 end
          local hb = tonumber(reaper.GetExtState("Swing", "padfx_heartbeat")) or 0
          return (os.time() - hb) < 3 and 1 or 0 end },
      { id = rid("EON_Swing_ToggleStepSeq.lua"), last = -1, get = function()
          for tr in core.iter_all_tracks() do
            local nfx, fx = reaper.TrackFX_GetCount(tr), 0
            while fx < nfx do
              if is_stepseq_fx(tr, fx) and eon_fx_float_visible(tr, fx) then return 1 end
              fx = fx + 1
            end
          end
          return 0 end },
    }
  end

  local i = 1
  while i <= #_eon_tog do
    local e = _eon_tog[i]
    if e.id then
      local s = e.get() or 0
      if s ~= e.last then
        reaper.SetToggleCommandState(0, e.id, s)
        reaper.RefreshToolbar2(0, e.id)
        e.last = s
      end
    end
    i = i + 1
  end
end

-- ═════════════════════════════════════════════════════════════════════════════
-- PERF PROFILER (dev instrumentation, 2026-08-14 — "REAPER feels heavier" hunt)
-- Off by default. Arm/disarm at runtime (picked up within a second, no restart):
--   reaper.SetExtState("EON_Bridge", "perf", "1", false)   -- "0"/"" = off
-- While armed, poll() stamps ~13 section boundaries and every ~5s appends ONE
-- summary line to Data/EON_Swing/perf_log.txt (128KB cap, then restarts):
--   effective defer rate (a sag below ~30Hz = the UI thread is saturated —
--   possibly by @gfx, which this profiler deliberately does NOT see), avg/max
--   tick cost, the track-walk rate (enumerate_all_swings + find_swing_track
--   calls/s) and per-FX identity-probe rate (is_swing_fx calls/s) — the
--   numbers behind the post-3.0 "shared roster" queue item — then the top
--   sections by average cost, and the project track/FX census.
-- Cost when off: one nil-check per mark. When armed: ~15 time_precise calls
-- per tick + one small append per window — too small to perturb the measure.
-- All state GLOBAL (bridge main chunk sits at Lua's 200-local ceiling).
_eon_perf = nil
function eon_perf_mark(sec)
  local P = _eon_perf
  if not P then return end
  local now = reaper.time_precise()
  if P.cur then P.acc[P.cur] = (P.acc[P.cur] or 0) + (now - P.last) end
  P.cur, P.last = sec, now
end

function eon_perf_flush(now)
  local P = _eon_perf
  local win = now - P.w0
  if win <= 0 or P.ticks == 0 then P.w0 = now return end
  -- Census pass: one track×FX count per flush window (~5s), outside any tick.
  local nfx = 0
  for tr in core.iter_all_tracks() do nfx = nfx + reaper.TrackFX_GetCount(tr) end
  local secs = {}
  for k, v in pairs(P.acc) do secs[#secs + 1] = { k, v } end
  table.sort(secs, function(a, b) return a[2] > b[2] end)
  local top = {}
  for i = 1, math.min(6, #secs) do
    top[#top + 1] = ("%s %.2fms/%d%%"):format(secs[i][1],
      secs[i][2] / P.ticks * 1000,
      P.tsum > 0 and math.floor(secs[i][2] / P.tsum * 100 + 0.5) or 0)
  end
  local line = ("perf: %.1fHz | tick avg %.2fms max %.1fms | walks %.0f/s probes %.0f/s | %s | %dtr/%dfx\n")
    :format(P.ticks / win, P.tsum / P.ticks * 1000, P.tmax * 1000,
            P.walks / win, P.probes / win, table.concat(top, "  "),
            reaper.CountTracks(0), nfx)
  local dir = reaper.GetResourcePath() .. "/Data/EON_Swing"
  reaper.RecursiveCreateDirectory(dir, 0)
  local path = dir .. "/perf_log.txt"
  local ex = io.open(path, "rb")
  local sz = ex and ex:seek("end") or 0
  if ex then ex:close() end
  local f = io.open(path, sz > 131072 and "wb" or "ab")
  if f then f:write(os.date("%H:%M:%S "), line) f:close() end
  P.acc, P.ticks, P.tsum, P.tmax = {}, 0, 0, 0
  P.walks, P.probes, P.w0 = 0, 0, now
end

function eon_perf_tick_begin()
  local P = _eon_perf
  if not P then return end
  local now = reaper.time_precise()
  P.cur, P.last, P.t0 = nil, now, now
end

function eon_perf_tick_end()
  local P = _eon_perf
  if not P then return end
  -- Armed mid-tick (the heartbeat check sits inside poll): no tick_begin ran
  -- this pass, so there is nothing coherent to account — start clean next tick.
  -- Without this guard the nil t0 arithmetic would kill the whole defer loop.
  if not P.t0 then P.cur = nil return end
  eon_perf_mark(nil)
  local now = reaper.time_precise()
  local dt = now - P.t0
  P.ticks = P.ticks + 1
  P.tsum = P.tsum + dt
  if dt > P.tmax then P.tmax = dt end
  if now - P.w0 >= 5.0 then eon_perf_flush(now) end
end

local function poll()
  eon_perf_tick_begin()                 -- perf profiler (no-op unless armed)
  eon_perf_mark("loader")
  -- EON Loader protocol v1 — file-based external sample loader
  loader_poll()

  -- One-time SWS Auto Color coexistence notice (self-gated to run once).
  bridge_detect_sws_autocolor()

  -- Auto-kit-sidecar — save/load per-instance .swing files in project folder
  -- so big kits survive REAPER's chunk-size truncation.
  eon_perf_mark("sidecar")
  poll_sidecar_events()

  -- Kit cover dropped onto a JSFX tile — read it in so the next save bakes it.
  eon_perf_mark("cover")
  eon_kitcover_poll_pending()

  -- Drum Matrix MIDI-lane sync (name/color/blank → P_EXT:EON_DRUM_LANE
  -- tracks), run here so the lanes track the live kit even when the Drum
  -- Matrix overlay is closed. Same code the overlay ticks; digest-gated so
  -- it's a cheap no-op when nothing changed. pcall'd so a Drum-Matrix-side
  -- error can't take down the bridge.
  eon_perf_mark("dmsync")
  if dm_swing_sync then pcall(dm_swing_sync.Tick) end

  -- Root-note detection: drain one queued analysis per tick and service the
  -- JSFX re-analysis mailbox. pcall'd so a detector error can't take down the
  -- bridge (same discipline as dm_swing_sync above).
  eon_perf_mark("rootnote")
  pcall(eon_rootnote_tick)

  -- P2/P6: per-instance identity → multi-out tracks (color + name + icon).
  -- Services EVERY live Swing instance from its OWN registry-slot band. Not
  -- hash-debounced (it walks tracks) so throttle to ~10Hz; idempotent
  -- compare-before-write means no churn when unchanged. _ident_active is a
  -- module GLOBAL (no `local` — this chunk is at Lua's 200-local limit) and
  -- sticks across the 2 off-ticks so the legacy fallback writers below stay
  -- disabled while >=1 instance is serviced here.
  eon_perf_mark("ident")
  if (heartbeat_counter % 3) == 0 then
    _ident_active = (refresh_multiout_identity_per_instance() or 0) > 0
    -- STICKY identity flag (heartbeat disease #5, 2026-06-12): _ident_active
    -- drops to false whenever the audio device closes (heartbeats stall, the
    -- walker services nothing) -- e.g. on EVERY app-focus switch. Gating the
    -- legacy shared-META fallbacks on the LIVE flag let them un-gate during
    -- those windows and repaint the children from the stale shared blob
    -- ("colors change when I switch programs"). Once ANY instance has been
    -- identity-serviced this session, the legacy writers stay retired.
    if _ident_active then _ident_seen = true end
  end

  -- Legacy shared-META forward writers — now a FALLBACK only. They write the
  -- ACTIVE instance's child tracks from the single shared-META band. With 2+
  -- instances that band oscillates between instances' kits (whoever is the
  -- browser target that block), so these would rewrite the active instance's
  -- tracks with alternating colors every tick and FIGHT the per-instance
  -- writer above → continuous blink. Gate them off whenever the per-instance
  -- path is servicing a live instance (the normal case once a registry slot
  -- is claimed). They only fire when NO instance has a slot yet — e.g. a
  -- pre-identity Swing build, or the registry is exhausted.
  if not (_ident_active or _ident_seen) then
    -- Real-time pad-color → multi-out track sync (no-op when unchanged).
    refresh_multiout_colors_if_changed()
    -- Safety-net pad-name + icon sync (forward direction; hash-debounced).
    refresh_multiout_names_if_changed()
  end

  -- EON: handle a selection coming back from the StepSeq's custom PAIR dropdown. A cheap
  -- no-op when nothing is queued; run every tick so the UI feels responsive.
  eon_perf_mark("stepseq")
  handle_stepseq_picker_sel()

  -- EON: same-track StepSeq<->Swing auto-pairing (manual P_EXT pairing overrides). Push
  -- each paired Swing's registry slot into its StepSeq's pairing slider so the StepSeq's
  -- lane hue/name read the correct instance's IDENT band. Topology changes rarely, so
  -- throttle to ~5Hz; idempotent (writes the param only on change).
  if (heartbeat_counter % 6) == 0 then
    refresh_stepseq_pairing()
    -- Roster for the StepSeq PAIR dropdown (labels of live Swing instances).
    publish_swing_roster()
  end

  -- Reverse direction: TCP/MCP rename/recolor → JSFX/Browser.
  -- Both hash-debounced. The forward and reverse functions converge to
  -- a stable state within one or two poll ticks because both directions
  -- agree on the same representation (hue for color, char[] for name).
  -- Legacy shared-blob reverse paths (name via KIT_GMEM_PADNAMES, color via
  -- shared META hue): superseded by the per-instance INCMD mailboxes inside
  -- refresh_multiout_identity_per_instance (D-1/D-2). Fallback only when no
  -- instance is registry-slotted (mirrors the forward gating).
  if not (_ident_active or _ident_seen) then
    refresh_pad_names_from_tracks_if_changed()
    refresh_pad_colors_from_tracks_if_changed()
  end

  -- Pad-click → MCP/TCP track select (gated in JSFX by
  -- pad_click_selects_track preference). JSFX writes 1-indexed pad to
  -- GS_PAD_TRACK_SELECT; bridge resolves the multi-out child track via
  -- the existing send-walk pattern (same as CMD=50 rename auto-update)
  -- and exclusively-selects it. Slot reset to 0 to consume the request.
  eon_perf_mark("cmd")
  do
    local req = math.floor(reaper.gmem_read(G.GS_PAD_TRACK_SELECT) or 0)
    if req > 0 and req <= G.NUM_PADS then
      local pad_idx = req - 1
      local sw_tr = find_swing_track()
      if sw_tr then
        local num_sends = reaper.GetTrackNumSends(sw_tr, 0)
        local found = false
        for si = 0, num_sends - 1 do
          local send_pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(sw_tr, 0, si, "I_SRCCHAN"))
          if send_pad == pad_idx then
            local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(sw_tr, 0, si, 1)
            if dest_tr then
              reaper.SetOnlyTrackSelected(dest_tr)
              reaper.Main_OnCommand(40913, 0)  -- Track: Vertical scroll selected tracks into view
              found = true
            end
            break
          end
        end
        -- silent no-op if no multi-out track exists for this pad
      end
      reaper.gmem_write(G.GS_PAD_TRACK_SELECT, 0)  -- consume request
    end
  end


  -- Dev/probe hook: silent kit export to an explicit path, no dialogs.
  -- The kitpipe regression harness (.dev_tests/kitpipe_*) uses this to
  -- round-trip a live kit through the REAL dump machinery (CMD 83 → JSFX
  -- export staging → CMD 84 → silent v4 write, same path the kit-undo
  -- snapshot takes; no kit_sources/lineage registration). One-shot: the
  -- ExtState is consumed on pickup. Inert in normal sessions — nothing
  -- sets EON_Bridge/dev_export_path except probes.
  local dev_export = reaper.GetExtState("EON_Bridge", "dev_export_path")
  if dev_export ~= "" and not pending_export and not kit_undo_job
     and math.floor(reaper.gmem_read(G.CMD) or 0) == 0 then
    reaper.SetExtState("EON_Bridge", "dev_export_path", "", false)
    -- Optional companion ExtState: explicit kit name for the export manifest
    -- (fixture builders name their kits; absent → live gmem name backfill in
    -- the CMD-84 handler).
    local dev_name = reaper.GetExtState("EON_Bridge", "dev_export_name")
    reaper.SetExtState("EON_Bridge", "dev_export_name", "", false)
    pending_export = { filepath = dev_export, undo_dump = true,
                       kit_name = (dev_name ~= "" and dev_name or nil),
                       author = "", desc = "kitpipe probe export" }
    reaper.gmem_write(G.CMD, 83)
  end

  -- Browser-initiated kit load (dedicated flag, avoids CMD race with @gfx)
  local kit_req = math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ))
  if kit_req == 1 then
    reaper.gmem_write(G.GS_KIT_LOAD_REQ, 0)  -- clear request
    local direct_path = reaper.GetExtState("Swing", "kit_load_path")
    if direct_path and direct_path ~= "" then
      reaper.SetExtState("Swing", "kit_load_path", "", false)
      -- Phase 1 queue unification (2026-07-17): EVERY kit load flows through
      -- pending_load_queue → drive_load_queue. The old idle-path INLINE load
      -- was a second dispatch path with no current_load tracking, no epoch,
      -- no timeout, and no retry — a click that mis-targeted silently
      -- no-op'd until the 15s stale-CMD watchdog fired 98 ("load twice").
      -- The pop costs at most one poll tick (~33ms) over inline — the pop
      -- gate note in drive_load_queue has the arbitration rationale (this
      -- also serializes against in-flight imports, the Phase-3 2026-07-12
      -- back-to-back-stall fix).
      -- Explicit want (PENDING from the browser/auto-load, else the browser
      -- binding) is trusted AS-IS when the track-scan can't see it yet — a
      -- freshly-inserted instance reads param 3 == 0 while booting; the pop
      -- re-resolves and retries once before reporting.
      -- Want priority (Phase 1b): the dedicated request-want channel first
      -- (GS_LOAD_WANT — new browser/auto-load), then legacy PENDING (old
      -- requesters), then the live browser binding. WANT is consumed here;
      -- PENDING is deliberately NOT touched anymore — it is now exclusively
      -- the bridge→JSFX delivery binding, and clearing it here erased an
      -- in-flight dispatch's binding before the target armed (the storm
      -- run-8 30s orphan).
      local want_id = math.floor(reaper.gmem_read(G.GS_LOAD_WANT) or 0)
      if want_id > 0 then
        reaper.gmem_write(G.GS_LOAD_WANT, 0)
      else
        want_id = math.floor(reaper.gmem_read(G.GS_PENDING_LOAD_INST) or 0)
      end
      if want_id <= 0 then want_id = math.floor(reaper.gmem_read(G.INSTANCE) or 0) end
      -- Which registry slot this load is for, so the cover lands on the right
      -- instance's tile. Resolved from the id via the registry, never id-1.
      eon_kit_cover_load_slot = ss_resolve_slot(want_id)
      -- Kit-categories ④ (user decision 2026-07-24: OPTION B): FILL diverts
      -- HERE, before the load queue — it is its own additive path (zip-match
      -- the kit onto this rack's categories, then per-pad CMD 63/64 loads of
      -- MATCHED pads only; see eon_fill_request). It never becomes a
      -- load_kit_v4 dispatch, so the load-route cascades stay untouched and
      -- unmatched pads are simply never addressed.
      if math.floor(reaper.gmem_read(G.GS_KIT_LOAD_MODE) or 0) == 1 then
        eon_fill_request(direct_path, want_id)
      else
        local item = { path = direct_path, preserve = false }
        for _, swing in ipairs(enumerate_all_swings()) do
          if (swing.inst_id or 0) > 0
             and (want_id <= 0 or swing.inst_id == want_id) then
            item.inst_id, item.tr, item.fx, item.guid =
              swing.inst_id, swing.tr, swing.fx, swing.guid
            break
          end
        end
        if not item.inst_id and want_id > 0 then item.inst_id = want_id end
        pending_load_queue[#pending_load_queue + 1] = item
      end
    end
    -- One-shot: the mode is consumed WITH the request — a stale 1 can never
    -- turn a later JSFX-button / auto-sidecar load into a fill.
    reaper.gmem_write(G.GS_KIT_LOAD_MODE, 0)
  end

  local cmd = math.floor(reaper.gmem_read(G.CMD))

  -- 98/99 are COMPLETION codes (op cancelled/done), left on the bus for the
  -- armed JSFX that raised the op to consume (it clears kit_busy and writes
  -- CMD=0). Ops fired from plain Lua — the Song Starter checkboxes, the EON
  -- menu wrappers — have no armed instance: nothing consumes, the code sits
  -- there FOREVER, and every CMD==0 gate in the system (all action posts
  -- included) silently starves until REAPER restarts. Same class as the
  -- 2026-07-15 stale-CMD 66 audit. A live armed JSFX consumes within a couple
  -- of @block cycles (~ms); five seconds of lingering means nobody is coming —
  -- release the bus. (An armed instance with the audio device closed can't
  -- consume either, but its own kit-busy watchdog covers that recovery.)
  if cmd == 98 or cmd == 99 then
    local nowc = reaper.time_precise()
    if not eon_done_code_since then eon_done_code_since = nowc end
    if nowc - eon_done_code_since > 5.0 then
      reaper.gmem_write(G.CMD, 0)
      eon_done_code_since = nil
    end
  else
    eon_done_code_since = nil
  end

  -- Companion-bus twin of the watchdog above, needed BECAUSE of instance
  -- addressing: a broadcast companion cmd was always consumed by SOME
  -- instance, but a TARGETED one whose instance died mid-flight lingers
  -- forever -- and companion posts are only made on an idle bus, so it would
  -- block every later companion command. 15s is geological for a live @gfx
  -- (gfx_idle consumes in ms) while still clearing a genuinely long
  -- kit_busy pending-hold only well after the kit pipeline's own watchdogs.
  do
    local comp = math.floor(reaper.gmem_read(G.GS_COMPANION_CMD) or 0)
    if comp > 0 then
      local nowc = reaper.time_precise()
      if not eon_comp_since then eon_comp_since = nowc end
      if nowc - eon_comp_since > 15.0 then
        reaper.gmem_write(G.GS_COMPANION_CMD, 0)
        if G.GS_COMPANION_TARGET then reaper.gmem_write(G.GS_COMPANION_TARGET, 0) end
        eon_comp_since = nil
      end
    else
      eon_comp_since = nil
    end
  end

  -- Kit ops
  if cmd == 10 or cmd == 12 or cmd == 15 then
    -- Phase 3 save guard (bridge belt-and-suspenders): refuse while any load
    -- owns the pipeline. The JSFX button gates check the gmem cells, but only
    -- the bridge sees its own queue/current_load; a save racing a load can
    -- bake the in-flight kit's staging under the typed name (chimera-file
    -- vector). CMD 98 runs the JSFX export state's clean reset.
    -- CMD 12 (silent in-place save) sits INSIDE this guard deliberately: it is
    -- the same write pipeline, so it carries the identical race, and having no
    -- dialog makes it MORE dangerous — nothing would pause to let the load land.
    if current_load ~= nil or #pending_load_queue > 0
       or math.floor(reaper.gmem_read(G.GS_KIT_LOAD_REQ) or 0) == 2 then
      eon_load_report("save refused: a kit load is in flight — retry in a moment")
      reaper.gmem_write(G.CMD, 98)
    elseif cmd == 10 then
      do_export_name_prompt()
    elseif cmd == 12 then
      do_save_in_place()
    else
      do_export_browse()
    end
  elseif cmd == 1 then
    -- User-save complete (CMD 1 is now emitted ONLY for a user save — the silent
    -- undo dump emits its own CMD 84, see below). do_export_write_file guards on
    -- pending_export == nil, so a stray 1 is a harmless CMD-98 no-op.
    rk_export.do_export_write_file()
  elseif cmd == 84 then
    -- Silent kit-undo dump completed staging (distinct from the user-save CMD 1
    -- since 2026-07-09, so this can't be confused with a real export even after
    -- the phase-1 timeout niled kit_undo_job — the old ack hole). Self-sufficient:
    -- write the temp .swing ONLY if the job is still live (else the timeout gave
    -- up and there's nothing to arm undo with), but ALWAYS ack CMD 85 so the JSFX
    -- returns to idle (kit_busy restored) instead of stranding in export state 3.
    -- CMD 85 preserves LOCK, so a load the timeout already released is untouched.
    if pending_export and pending_export.undo_dump then
      -- PROVEN v4 writer (v5's JSFX-side audio dump is unlanded — metadata-only
      -- zips = names-but-silent pads on undo). v4 = per-pad source paths + full
      -- live metadata; reload re-reads the samples.
      -- Silent-dump exports (kit-undo, dev_export_path) build pending_export
      -- without kit_name; write_kit_v4 fed the nil to lua_quote, which errored
      -- inside this pcall → NO file written while CMD 85 still acked (the
      -- kit-undo snapshot silently never existed). Backfill from the live
      -- gmem name here — the one site both silent paths flow through.
      pending_export.kit_name = pending_export.kit_name or read_kit_name_from_gmem()
      local ok = pcall(write_kit_v4, pending_export.filepath, pending_export, true)
      if ok and kit_undo_job then kit_undo_avail[kit_undo_job.guid] = pending_export.filepath end
      pending_export = nil
      if kit_undo_job then
        kit_undo_job.phase = 2
        kit_undo_job.deadline = reaper.time_precise() + 1.5
      end
    end
    reaper.gmem_write(G.CMD, 85)
  elseif cmd == 2 then
    rk_ops.do_import()
  elseif cmd == 16 then
    rk_ops.do_import_browse()
  elseif cmd == 19 then
    rk_export.do_export_sfz_browse()
  elseif cmd == 21 then
    rk_export.do_export_rs5k_browse()

  -- SFZ kit import (LOAD right-click "Import SFZ Kit..." menu item).
  -- File dialog → ExtState → CMD 60 (open browser, which reads ExtState
  -- and runs import_start). Same pipeline as EON_SB_ImportKit.lua but
  -- triggered from inside the JSFX, so the user doesn't have to hunt
  -- for the standalone action.
  elseif cmd == 17 then
    local retval, filename = reaper.GetUserFileNameForRead(
      "", "Import SFZ Kit", "sfz"
    )
    if retval and filename ~= "" then
      reaper.SetExtState("Swing", "import_file", filename, false)
      reaper.gmem_write(G.CMD, 60)  -- delegate to "open browser" handler next tick
    else
      reaper.gmem_write(G.CMD, 0)   -- user cancelled
    end

  -- P4 step 3e: relink request from the missing-samples banner. LOCK carries
  -- the requesting instance id (CMD-82 pattern). Ack promptly, THEN show the
  -- folder picker (it blocks this dispatcher; an unacked 89 would trip the
  -- stale-CMD watchdog). ExtState EON_Bridge/relink_folder pre-seeds the
  -- folder for headless acceptance (consumed one-shot).
  -- CMD 90/91 — show this instance's embedded UI in the TCP (90) or MCP (91).
  -- There is NO API for embedding: the whole TrackFX named-config-parm list,
  -- read and write, has no key for it, and the only other route would be
  -- SetTrackStateChunk, which rebuilds the FX chain and would cold-start the
  -- sampler. Instead use the two pieces REAPER does expose: mark this FX
  -- "last focused" (a writable named-config parm), then fire its own
  -- "Show last focused FX embedded UI in TCP/MCP" action. Command ids are
  -- looked up BY NAME via SWS's CF_EnumerateActions rather than hardcoded,
  -- so they cannot drift between REAPER versions.
  elseif cmd == 90 or cmd == 91 then
    local want_tcp = (cmd == 90)
    reaper.gmem_write(G.CMD, 0)
    local tr, fx = find_swing_track()
    if tr and fx then
      reaper.TrackFX_SetNamedConfigParm(tr, fx, "focused", "1")
      -- Lookup + fire live in eon_embed_last_focused (shared with the Lens
      -- build path); false = SWS absent or the action name not found.
      if not eon_embed_last_focused(want_tcp) then
        reaper.ShowConsoleMsg("[EON Swing] could not find the \"Show last focused " ..
          "FX embedded UI " .. (want_tcp and "in TCP" or "in MCP") ..
          "\" action — embed it from the FX chain's right-click menu instead.\n")
      end
    end

  elseif cmd == 89 then
    local rl_inst = math.floor(reaper.gmem_read(G.LOCK) or 0)
    reaper.gmem_write(G.CMD, 0)
    local rl_folder = reaper.GetExtState("EON_Bridge", "relink_folder")
    if rl_folder ~= "" then
      reaper.SetExtState("EON_Bridge", "relink_folder", "", false)
    elseif reaper.JS_Dialog_BrowseForFolder then
      local ok, f2 = reaper.JS_Dialog_BrowseForFolder(
        "Relink missing samples: pick the folder that contains them", "")
      rl_folder = (ok == 1 and f2) or ""
    else
      local ok, f2 = reaper.GetUserInputs("Relink samples", 1,
        "Folder path:,extrawidth=260", "")
      rl_folder = (ok and f2) or ""
    end
    if rl_folder ~= "" and rl_inst > 0 then
      eon_relink_kick(rl_inst, rl_folder)
    end

  -- Auto-load default 808 kit on fresh JSFX instance creation.
  -- JSFX fires this once (tracked via _auto_load_attempted in @serialize)
  -- when the bridge first becomes available. Uses get_kits_dir() so the
  -- resolution matches every other kit-load code path (browser kit menu,
  -- file dialog, drag-drop): <resource>/Data/Swing_Kits on every platform,
  -- portable installs included. The factory kits live in SUBFOLDERS there
  -- ("Fischer 808", "Vintage Synth") — the 3.0 layout the installers and
  -- the Kits view use. The old flat "808_v2.swing"/"909.swing" targets
  -- stopped shipping in 3.0, and because the io.open gate below fails
  -- SILENTLY, a fresh customer install opened on 16 empty pads with no
  -- error anywhere (2026-08-03 release audit).
  -- get_kits_dir() also calls RecursiveCreateDirectory so a fresh install
  -- with no kit data yet still resolves cleanly (the open below just won't
  -- find the file and the auto-load no-ops without erroring).
  elseif cmd == 22 then
    -- PARAM1: 0 = 808 (default), 1 = 909-style synth kit
    local kit_sel = math.floor(reaper.gmem_read(G.PARAM1))
    local kit_file = kit_sel == 1
      and ("Vintage Synth" .. core.sep .. "9T9.swing")
      or  ("Fischer 808"   .. core.sep .. "808 F.swing")
    local kit_path = core.get_kits_dir() .. core.sep .. kit_file
    local f = io.open(kit_path, "rb")
    if f then
      f:close()
      reaper.SetExtState("Swing", "kit_load_path", kit_path, false)
      reaper.gmem_write(G.GS_KIT_LOAD_REQ, 1)
      local req_tr, req_fx = find_swing_track()
      if req_tr and req_fx then
        -- Only force the window open if it's currently closed. If the
        -- user already had Swing floating, TrackFX_SetOpen would yank
        -- it back into the FX chain window — don't touch it.
        if not reaper.TrackFX_GetOpen(req_tr, req_fx)
           and not eon_fx_float_visible(req_tr, req_fx) then
          reaper.TrackFX_Show(req_tr, req_fx, 3)  -- 3 = show in floating window
          -- Kit load is a user gesture and this branch only fires when the
          -- window was closed — Hub should capture AND front it.
          core.hub_notify("open", "swing", req_tr, req_fx)
        end
      end
    end
    reaper.gmem_write(G.CMD, 0)

  -- Kits-view pick (Spec_Swing_Kits_View.md §4): the JSFX staged the kit's
  -- full path in the GS_BROWSER_PATH band (CMD-serialized shared bus, CMD-18
  -- shape) and wrote GS_LOAD_WANT itself. Re-enter the standard browser-load
  -- funnel: CMD cleared FIRST (the kit_req==1 pickup needs the bus idle),
  -- then ExtState + MODE + REQ=1 exactly like load_kit_from_browser. From
  -- here the load flows through pending_load_queue / drive_load_queue /
  -- format-sniffed dispatch / epoch-ACK completion — all unchanged.
  elseif cmd == 24 then
    -- decode the payload BEFORE releasing the bus (audit: CMD=0 first left
    -- a window where another producer could restage the shared band)
    local path_len = math.floor(reaper.gmem_read(G.GS_BROWSER_PATH_LEN))
    local kv_path
    if path_len > 0 and path_len < G.GS_BROWSER_PATH_MAX then
      local chars = {}
      for i = 0, path_len - 1 do
        chars[i + 1] = string.char(math.floor(reaper.gmem_read(G.GS_BROWSER_PATH + i)))
      end
      kv_path = table.concat(chars)
    end
    reaper.gmem_write(G.CMD, 0)
    if kv_path then
      -- the view stages paths RELATIVE to Data/Swing_Kits (records carry
      -- folder + name, not absolute); normalize to native separators and
      -- prefix the kits dir. Absolute paths pass through untouched.
      if not (kv_path:match("^%a:") or kv_path:match("^[/\\]")) then
        kv_path = core.get_kits_dir() .. core.sep .. kv_path:gsub("[/\\]", core.sep)
      end
      -- stale-roster guard (audit): a pick of a renamed/deleted kit would
      -- otherwise ride the funnel into modals + a CMD-98 bus stall. Verify
      -- the file quietly; on miss, skip the load and republish the roster
      -- so the view self-heals on its next snapshot.
      local fh = io.open(kv_path, "rb")
      if fh then
        fh:close()
        reaper.SetExtState("Swing", "kit_load_path", kv_path, false)
        reaper.gmem_write(G.GS_KIT_LOAD_MODE, 0)
        reaper.gmem_write(G.GS_KIT_LOAD_REQ, 1)
      else
        pcall(G.KITLIST.publish)
      end
    end

  -- Drag-drop import (kit-format file dropped on the pad grid).
  -- JSFX wrote the path to GS_BROWSER_PATH chars + GS_BROWSER_PATH_LEN.
  -- Same downstream as CMD 17: ExtState + open browser.
  elseif cmd == 18 then
    local path_len = math.floor(reaper.gmem_read(G.GS_BROWSER_PATH_LEN))
    if path_len > 0 and path_len < G.GS_BROWSER_PATH_MAX then
      local chars = {}
      for i = 0, path_len - 1 do
        chars[i + 1] = string.char(math.floor(reaper.gmem_read(G.GS_BROWSER_PATH + i)))
      end
      local filename = table.concat(chars)
      reaper.SetExtState("Swing", "import_file", filename, false)
      reaper.gmem_write(G.CMD, 60)
    else
      reaper.gmem_write(G.CMD, 0)
    end

  -- Sample ops
  elseif cmd == 20 then
    rk_ops.do_batch_import()
  elseif cmd == 23 then
    rk_ops.do_auto_color()

  -- Arrangement ops
  elseif cmd == 30 then
    rk_ops.do_chop_to_pads()

  -- Routing ops
  elseif cmd == 40 then
    rk_ops.do_build_multiout()

  -- UI ops
  elseif cmd == 45 then
    reaper.Main_OnCommand(50124, 0)   -- toggle Media Explorer
    reaper.gmem_write(G.CMD, 0)

  -- EON tools (Swing left-panel launcher buttons)
  elseif cmd == 70 then
    -- STEP SEQ: open the Step Sequencer in THIS track's MAIN FX chain, just above
    -- the Swing FX. find_swing_track() resolves the locking instance's track (the
    -- JSFX wrote LOCK = instance_id). MAIN chain -- NOT input/rec FX -- so the
    -- StepSeq (a) AUTO-PAIRS (refresh_stepseq_pairing scans the main chain) and
    -- (b) plays during normal playback without the track being record-armed.
    -- StepSeq passes incoming MIDI through, so MIDI items / live notes still reach
    -- Swing below it. Toggles its floating window.
    local seq_tr = find_swing_track()
    -- ⚠️ This was the literal "JS:EON_StepSeq.jsfx" -- an Effects-ROOT path that is
    -- only true on a dev machine with the hand-maintained flat copy. The installer
    -- puts it in Effects/EON/Swing/ and ReaPack in Effects/<index name>/EON/Swing/,
    -- so for every customer AddByName returned -1 twice and the STEP SEQ button
    -- did nothing at all, with no message. Resolve it properly.
    local seq_name, _, seq_why = core.jsfx_addname("EON_StepSeq.jsfx")
    if seq_tr and not seq_name then
      reaper.ShowConsoleMsg("[EON] Could not locate EON_StepSeq.jsfx under the " ..
        "Effects folder -- Steppa cannot be opened.\n  " .. tostring(seq_why) .. "\n")
    end
    if seq_tr and seq_name then
      local seq_idx = reaper.TrackFX_AddByName(seq_tr, seq_name, false, 0)   -- query main chain
      if seq_idx < 0 then
        seq_idx = reaper.TrackFX_AddByName(seq_tr, seq_name, false, -1)       -- insert at end of main chain
        if seq_idx and seq_idx >= 0 then
          -- Move it just above the Swing FX so the generated MIDI feeds Swing.
          local sw_idx, nfx, fi = -1, reaper.TrackFX_GetCount(seq_tr), 0
          while fi < nfx do
            if is_swing_fx(seq_tr, fi) then sw_idx = fi; break end
            fi = fi + 1
          end
          if sw_idx >= 0 and seq_idx > sw_idx then
            reaper.TrackFX_CopyToTrack(seq_tr, seq_idx, seq_tr, sw_idx, true)   -- move (is_move = true)
            seq_idx = sw_idx
          end
          -- House default: fresh inserts open embedded in the MCP (action
          -- path — no chunk rewrite on a kit-loaded Swing track).
          reaper.TrackFX_SetNamedConfigParm(seq_tr, seq_idx, "focused", "1")
          eon_embed_last_focused(false)
        end
      end
      if seq_idx and seq_idx >= 0 then
        if eon_fx_float_visible(seq_tr, seq_idx) then
          reaper.TrackFX_Show(seq_tr, seq_idx, 2)   -- visible -> hide
          core.hub_notify("close", "stepseq", seq_tr, seq_idx)
        else
          reaper.TrackFX_Show(seq_tr, seq_idx, 3)   -- show floating
          core.hub_notify("open", "stepseq", seq_tr, seq_idx)
        end
      end
    end
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 71 then
    -- PAD FX: run the self-toggling launcher (open if closed, signal-close if
    -- open). Resolved from the bridge's own dir, like the browser (CMD 60).
    local padfx_dir = (debug.getinfo(1, "S").source:match("@?(.*)") or ""):match("^(.*)[/\\]") or ""
    local padfx_toggle = padfx_dir .. core.sep .. "EON_Toggle_Swing_PadFX.lua"
    local pf = io.open(padfx_toggle, "r")
    if pf then
      pf:close()
      local pf_id = reaper.AddRemoveReaScript(true, 0, padfx_toggle, true)
      if pf_id and pf_id > 0 then
        reaper.Main_OnCommand(pf_id, 0)
        -- Left registered: eon_toolbar.lua registers THIS path and bakes its
        -- _RS id into reaper-menu.ini -- the old unregister here killed the
        -- EON toolbar's Pad FX button on first use. See AP-4.
      end
    end
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 92 then
    -- MERGED (Swing's build menu and the EON Build menu): audio multi-outs FIRST,
    -- then tag each pad's audio track as a merged lane and seed it a pattern item
    -- of its own. Merged mode ADOPTS the multi-out tracks rather than creating
    -- any, so without them there is nothing to adopt and the audio build has to
    -- run first — which is why this chains the way CMD 74 ("Build Both") does.
    -- Nothing is MOVED: a classic lane's item stays where it is (the builder
    -- warns about the double-trigger instead), and a pad track that already
    -- holds MIDI keeps what it has.
    -- 92, and NOT the two nearer numbers it is natural to reach for. 83 is
    -- this bridge's own OUTBOUND silent-kit-dump code (start_kit_undo_dump
    -- writes it, rk_swing_ui_state answers it) and poll() reads the very cell it
    -- writes, so an inbound 83 branch would fire a full merged build on every
    -- kit load. 79 looks free in code but is design-claimed as RE-ROLL PAD by
    -- Spec_Swing_Change_Map_And_Reroll.md. Grep the code AND
    -- .refs/swing_gmem_bridge_protocol.md before claiming a CMD.
    -- Same async seam as 74: do NOT write CMD=0 here. The FX-returns prompt
    -- inside do_build_multiout is a house dialog on the defer loop, so the call
    -- can return with CMD parked at 97; the 98/99 the build eventually writes is
    -- the completion code the JSFX consumes to clear kit_busy.
    rk_ops.do_build_multiout({ on_done = function(ok)
      if ok then run_dm_script("EON_DM_BuildMerged.lua") end
    end })

  elseif cmd == 73 then
    -- MULTI (left-panel half-button / build menu): build the classic Drum
    -- Matrix MIDI lanes (EON_DM_Build's own dialogs handle rebuild/parallel
    -- and the stereo-tag handoff).
    run_dm_script("EON_DM_Build.lua")
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 74 then
    -- MATRIX "Build Both": audio multi-outs FIRST, then the Drum Matrix MIDI
    -- lanes. The DM step rides do_build_multiout's on_done callback — the
    -- FX-returns prompt inside it is an async house dialog, so "did it
    -- cancel?" can no longer be read off G.CMD the moment the call returns
    -- (it may return with the dialog still open and CMD parked at 97).
    -- Do NOT write CMD=0 here: the 98/99 the build leaves is the completion
    -- code the JSFX consumes to clear kit_busy.
    rk_ops.do_build_multiout({ on_done = function(ok)
      if ok then run_dm_script("EON_DM_Build.lua") end
    end })

  elseif cmd == 75 then
    -- PAINT (the single Drum Matrix grid control): if the overlay is already
    -- running (its singleton lock is fresh, refreshed each tick with a 5s TTL),
    -- just toggle paint mode. If it isn't running, switch paint ON and open the
    -- grid overlay — one click goes straight to painting. The overlay reads
    -- paint_mode from ExtState each frame; GS_DM_PAINT (published every tick)
    -- drives the button's lit colour. Close the grid from its own X.
    if (reaper.time_precise() - (tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9)) < 5 then
      reaper.SetExtState("EON_DRUM_MATRIX", "paint_mode",
        reaper.GetExtState("EON_DRUM_MATRIX", "paint_mode") == "1" and "0" or "1", true)
    else
      reaper.SetExtState("EON_DRUM_MATRIX", "paint_mode", "1", true)
      run_dm_script("eon_drum_matrix.lua")
    end
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 76 then
    -- GRID: toggle the Drum Matrix overlay on/off. If it's running (singleton
    -- lock fresh < 5s) raise the self-close flag the overlay consumes next frame;
    -- otherwise clear any stale flag and open it. GS_DM_OVERLAY (published each
    -- tick above) drives the button's lit state.
    if (reaper.time_precise() - (tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9)) < 5 then
      reaper.SetExtState("EON_DRUM_MATRIX", "overlay_close", "1", false)  -- session-only; do not persist (a saved '1' would auto-close on next launch)
    else
      reaper.SetExtState("EON_DRUM_MATRIX", "overlay_close", "", false)
      run_dm_script("eon_drum_matrix.lua")
    end
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 77 then
    -- STEREO (left-panel half-button / build menu): one click to the stereo
    -- grid. Track not lane-tagged yet -> run EON_DM_BuildStereo (tags the
    -- Swing track itself, no child tracks); already tagged -> open the DM
    -- overlay if it isn't running (same lock check as CMD 76; never force-
    -- close from here). find_swing_track() resolves the locking instance and
    -- bumps the track to 32 channels — an intentional Swing-track signature.
    local st_tr = find_swing_track()
    local st_tagged = false
    if st_tr then
      local _, st_raw = reaper.GetSetMediaTrackInfo_String(st_tr, "P_EXT:EON_DRUM_LANE", "", false)
      st_tagged = (st_raw ~= nil and st_raw ~= "")
    end
    if st_tagged then
      if (reaper.time_precise() - (tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9)) >= 5 then
        reaper.SetExtState("EON_DRUM_MATRIX", "overlay_close", "", false)
        run_dm_script("eon_drum_matrix.lua")
      end
    else
      run_dm_script("EON_DM_BuildStereo.lua")
    end
    reaper.gmem_write(G.CMD, 0)

  -- Open the EON toolbar (slot-agnostic). Find the [Floating toolbar N] section
  -- titled "EON" in reaper-menu.ini and toggle it via the native "Open/close
  -- toolbar N" action (41679 = toolbar 1, contiguous → 41678 + N). Never assumes
  -- a fixed slot, so it survives a user whose toolbar 2 is already taken.
  elseif cmd == 78 then
    local slot, cur = nil, nil
    local mf = io.open(reaper.GetResourcePath() .. core.sep .. "reaper-menu.ini", "r")
    if mf then
      for line in mf:lines() do
        local n = line:match("^%[Floating toolbar (%d+)%]")
        if n then cur = tonumber(n)
        elseif line:match("^%[") then cur = nil                 -- left the section
        elseif cur and line:match("^title=EON%s*$") then slot = cur; break end
      end
      mf:close()
    end
    if slot then
      reaper.Main_OnCommand(41678 + slot, 0)                     -- toolbar N open/close
    else
      -- No EON toolbar. This used to fall through silently, so the TOOLBAR
      -- button in the Swing panel did NOTHING for every user who had not built
      -- one by hand — which is every customer, since the installer has never
      -- shipped a toolbar. Offer to build it instead of pretending nothing
      -- happened. eon_toolbar resolves the command IDs on THIS machine; they
      -- cannot be precomputed (see that file's header).
      local ok_tb, TB = pcall(dofile, _SCRIPT_DIR .. core.sep .. "EON"
                                      .. core.sep .. "eon_toolbar.lua")
      if ok_tb and TB then
        TB.ensure(_SCRIPT_DIR)
      else
        eon_notice(
          "No EON toolbar found, and the toolbar builder is missing.\n\n" ..
          "Run \"EON: Install / Refresh Toolbar\" from the Action List.", "EON Toolbar")
      end
    end
    reaper.gmem_write(G.CMD, 0)

  -- Browser ops (v5)
  elseif cmd == 60 then
    -- Toggle Swing Browser — open if closed, close if open
    -- Note: only one browser can run at a time (shared gmem namespace)
    local browser_running = reaper.GetExtState("Swing", "browser_running")
    local browser_gmem = reaper.gmem_read(G.GS_BROWSER_OPEN)
    -- If ExtState says running but gmem says not, browser crashed — clear stale state
    if browser_running == "1" and browser_gmem == 0 then
      reaper.SetExtState("Swing", "browser_running", "0", false)
      browser_running = "0"
    end
    if browser_running == "1" and reaper.gmem_read(G.GS_BROWSER_VISIBLE) == 1 then
      -- Visible → close (toggle off)
      reaper.SetExtState("Swing", "browser_close", "1", false)
    else
      -- Not running, or running but hidden (docked) → close stale + (re)launch
      if browser_running == "1" then
        reaper.SetExtState("Swing", "browser_close", "1", false)
      end
      local info = debug.getinfo(1, "S")
      local script_path = info.source:match("@?(.*)")
      local script_dir = script_path:match("^(.*)[/\\]") or ""
      local browser_path = script_dir .. core.sep .. "Swing_Browser.lua"
      local f = io.open(browser_path, "r")
      if f then
        f:close()
        local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
        if cmd_id > 0 then
          reaper.Main_OnCommand(cmd_id, 0)
          -- Left registered: Swing_Browser.lua works standalone, so a direct
          -- user registration is plausible -- see AP-4.
        end
      end
    end
    reaper.gmem_write(G.CMD, 0)

  -- ─── Browser sample-assign via ExtState (CMD 61) — RETIRED 2026-07-16 ──
  -- No producer has written CMD 61 in any tracked revision (the browser fires
  -- CMD 63/64 directly to the JSFX; the "browser_sample_path" ExtState it read
  -- is never set). Its pipeline was also broken end-to-end: it staged audio
  -- via load_audio_to_pad (offsets summed from the blast-written AUDIOLEN
  -- band) and fired CMD=3 + PARAM1, which no JSFX state consumes without the
  -- GS_KIT_LOAD_REQ=2 arm. Kept as a no-op so any stale gmem value clears
  -- cleanly instead of wedging the poll (same idiom as CMD 80/81 below).
  elseif cmd == 61 then
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 62 then
    -- Close browser
    reaper.SetExtState("Swing", "browser_close", "1", false)
    reaper.gmem_write(G.CMD, 0)

  -- ─── Kit-macro external link (CMD 68) ──────────────────────────────────
  -- Editor "+ EXT": native-plink the user's LAST-TOUCHED parameter (of any
  -- OTHER FX on the requesting Swing's track) to the macro slider named in
  -- PARAM1. plink is created 1:1 (scale=1, offset=0 — the only verified-
  -- exact affine; macro_system research §2e); range shaping stays with the
  -- target param. Same-track only: links do not cross tracks and a cross-
  -- scope link fails SILENTLY, so validate instead of guessing. Removal =
  -- REAPER's native param-modulation dialog on the target param.
  elseif cmd == 68 then
    local mi = math.floor(reaper.gmem_read(G.CMD + 1) or 0)  -- PARAM1 (CMD+1) = macro 0..7
    local lock_id = math.floor(reaper.gmem_read(G.LOCK) or 0)
    local okt, tn, fxn, parm = reaper.GetLastTouchedFX()
    local msg = nil
    if not okt then msg = "no last-touched FX parameter — wiggle the target knob first" end
    local swtr, swfx = nil, nil
    if not msg then
      for tr in core.iter_all_tracks() do
        for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
          if not swtr and is_swing_fx(tr, fx)
             and math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0) == lock_id then
            swtr, swfx = tr, fx
          end
        end
      end
      if not swtr then msg = "requesting Swing instance not found" end
    end
    if not msg then
      -- GetLastTouchedFX: tracknumber is 1-based (0 = master)
      local ttr = (tn or 0) == 0 and reaper.GetMasterTrack(0)
                                 or  reaper.GetTrack(0, (tn or 1) - 1)
      if ttr ~= swtr then
        msg = "last-touched param is not on the Swing track — same-track links only"
      elseif (fxn or 0) >= 16777216 then
        -- 0x1000000 flag = record-input / monitoring FX chain; a plink from
        -- there to a main-chain Swing param is cross-chain — refuse rather
        -- than create a link that fails silently.
        msg = "input-FX chain params can't link to Swing macros"
      elseif fxn == swfx then
        msg = "that param is Swing itself — use the editor's + ADD instead"
      else
        local want = "Macro " .. (mi + 1)   -- resolve BY NAME (sparse-slider rule)
        local pidx = nil
        for p = 0, reaper.TrackFX_GetNumParams(swtr, swfx) - 1 do
          local _, nm = reaper.TrackFX_GetParamName(swtr, swfx, p, "")
          if nm == want then pidx = p break end
        end
        if not pidx then
          msg = "param '" .. want .. "' not found on Swing"
        else
          reaper.Undo_BeginBlock2(0)
          local pre = "param." .. math.floor(parm or 0) .. ".plink."
          reaper.TrackFX_SetNamedConfigParm(swtr, fxn, pre .. "active", "1")
          reaper.TrackFX_SetNamedConfigParm(swtr, fxn, pre .. "effect", tostring(swfx))
          reaper.TrackFX_SetNamedConfigParm(swtr, fxn, pre .. "param",  tostring(pidx))
          reaper.TrackFX_SetNamedConfigParm(swtr, fxn, pre .. "scale",  "1")
          reaper.TrackFX_SetNamedConfigParm(swtr, fxn, pre .. "offset", "0")
          reaper.Undo_EndBlock2(0, "Link Swing macro to FX param", -1)
        end
      end
    end
    if msg then reaper.ShowConsoleMsg("[Swing macros] ext-link: " .. msg .. "\n") end
    reaper.gmem_write(G.CMD, 0)

  -- ─── Header-bar UNDO / REDO buttons (CMD 80 / 81) — RETIRED (Phase 1B) ──
  -- The orange buttons now drive Swing's OWN internal param-undo engine in the
  -- JSFX; they no longer signal the bridge or call REAPER's global undo. Kept
  -- as no-ops so any stale gmem value clears cleanly instead of wedging the poll.
  elseif cmd == 80 or cmd == 81 then
    reaper.gmem_write(G.CMD, 0)

  -- ─── Kit-level UNDO reload (CMD 82) ─────────────────────────────────────
  -- JSFX fired this from the orange UNDO on a kit-type entry. Reload the temp
  -- undo sidecar dumped before the kit op. skip_undo_dump=true: the reload
  -- must not overwrite the file it's reloading (1-level undo, no redo loop).
  elseif cmd == 82 then
    -- Phase 1: kit-undo restore flows through the load QUEUE like every
    -- other load (epoch/ack tracked, retried once, reported on failure) —
    -- the old direct dispatch here staged CMD=3/REQ=2 with PENDING written
    -- only when the target resolved, one of the producers that could stage
    -- consumer-less data under the now-exclusive arm gate. no_undo: an
    -- undo-restore must not mint a fresh undo point or dump.
    local _u_inst, _u_guid = resolve_undo_target()
    local _u_path = _u_guid and kit_undo_avail[_u_guid]
    local _u_f = _u_path and io.open(_u_path, "rb")
    if _u_f then
      _u_f:close()
      kit_undo_avail[_u_guid] = nil                 -- consume (1-level)
      reaper.gmem_write(G.CMD, 0)
      pending_load_queue[#pending_load_queue + 1] = {
        inst_id = (_u_inst and _u_inst > 0) and _u_inst or nil,
        path = _u_path, preserve = false, no_undo = true,
      }
    else
      if _u_guid then kit_undo_avail[_u_guid] = nil end
      reaper.gmem_write(G.CMD, 0)                      -- nothing to undo to — no-op
    end

  -- Structural-op handshake (CMD 46/48). Phase 1B: NO REAPER undo block — Swing
  -- no longer mints global-undo points (the kit-wipe came from those; global
  -- Ctrl+Z can no longer restore a stale Swing chunk). CMD 46 just acks so the
  -- JSFX runs the clear/swap/new/clear-layer mutation in @block; CMD 48 closes
  -- the handshake and marks the project dirty so the change still saves.
  elseif cmd == 46 then
    -- (Kit-undo pre-wipe dump PARKED — see the load_swing_dispatch wrapper.)
    reaper.gmem_write(G.UNDO_ACK, 1)        -- tell JSFX: go ahead, run the op
    reaper.gmem_write(G.UNDO_DESC, 0)
    reaper.gmem_write(G.CMD, 0)

  elseif cmd == 48 then
    reaper.gmem_write(G.UNDO_ACK, 0)
    reaper.gmem_write(G.CMD, 0)
    reaper.MarkProjectDirty(0)
    sync_names_and_tracks(find_swing_track())

  -- Pad naming
  elseif cmd == 50 then
    -- Rename pad via REAPER's native text input dialog
    local pad_idx = math.floor(reaper.gmem_read(G.PARAM1))
    -- See cmd 61 note: `goto cmd_done` instead of bare `return` so a bad
    -- pad_idx doesn't kill the defer-driven poll loop.
    if pad_idx < 0 or pad_idx >= G.NUM_PADS then reaper.gmem_write(G.CMD, 0); goto cmd_done end
    -- Read current name from gmem PADNAME area
    local cur_name = ""
    for j = 0, G.PADNAME_LEN - 1 do
      local c = math.floor(reaper.gmem_read(G.PADNAME_BASE + pad_idx * G.PADNAME_LEN + j))
      if c > 0 then cur_name = cur_name .. string.char(c) end
    end
    local retval, new_name = reaper.GetUserInputs(
      string.format("Rename Pad %d", pad_idx + 1), 1,
      "Pad Name (max 16 chars):,extrawidth=160",
      cur_name
    )
    if retval and new_name ~= nil then
      -- Trim to PADNAME_LEN chars and write back to gmem PADNAME area
      new_name = new_name:sub(1, G.PADNAME_LEN)
      for j = 0, G.PADNAME_LEN - 1 do
        local c = j < #new_name and string.byte(new_name, j + 1) or 0
        reaper.gmem_write(G.PADNAME_BASE + pad_idx * G.PADNAME_LEN + j, c)
      end
      reaper.gmem_write(G.PARAM1, pad_idx)
      reaper.gmem_write(G.CMD, 51)  -- signal JSFX: name ready

      -- Rename → category: the badge follows the new name (guards + rationale
      -- in eon_padcat_from_rename; LOCKed pads and unclassifiable names keep
      -- their current badge).
      eon_padcat_from_rename(pad_idx, new_name)

      -- Auto-update multi-out track name if it exists
      local sw_tr = find_swing_track()
      if sw_tr then
        local num_sends = reaper.GetTrackNumSends(sw_tr, 0)
        for si = 0, num_sends - 1 do
          local send_pad = core.srcchan_pad(reaper.GetTrackSendInfo_Value(sw_tr, 0, si, "I_SRCCHAN"))
          if send_pad == pad_idx then
            local dest_tr = reaper.BR_GetMediaTrackSendInfo_Track(sw_tr, 0, si, 1)
            if dest_tr then
              local tname
              if new_name ~= "" then
                tname = new_name
              else
                tname = string.format("%02d", pad_idx + 1)
              end
              reaper.GetSetMediaTrackInfo_String(dest_tr, "P_NAME", tname, true)
              _lane_rename_touch()  -- mute color-adopt gate: SWS re-colors on our rename
            end
            break
          end
        end
      end
    else
      reaper.gmem_write(G.CMD, 0)   -- cancelled
    end

  -- Sync MIDI note names to REAPER piano roll + multi-out child track names
  elseif cmd == 52 then
    sync_names_and_tracks(find_swing_track())
    reaper.gmem_write(G.CMD, 0)

  end

  -- Skip target for `goto cmd_done` from inside cmd handlers that need to
  -- bail early without killing the defer poll loop. Falls through to the
  -- lock-release / undo-leak / heartbeat / defer tail below.
  ::cmd_done::

  -- Release instance lock for commands that fully complete in the bridge.
  -- Commands that write CMD=3 (data transfer) keep the lock held;
  -- the JSFX releases it once it finishes reading.
  if cmd > 0 then
    local final = math.floor(reaper.gmem_read(G.CMD))
    if final == 0 or final == 98 or final == 99 then
      reaper.gmem_write(G.LOCK, 0)
    end
  end

  -- Phase 1B: project-dirty signal. The JSFX sets GS_PROJ_DIRTY on any state
  -- change (replacing the old slider_automate undo-capture). Flag REAPER's
  -- project as dirty so edits prompt-to-save — WITHOUT minting a global-undo
  -- point. (The old undo-block leak protection is gone: no blocks to leak.)
  eon_perf_mark("misc")
  if reaper.gmem_read(GS_PROJ_DIRTY) ~= 0 then
    reaper.gmem_write(GS_PROJ_DIRTY, 0)
    reaper.MarkProjectDirty(0)
  end

  -- Drive any in-flight kit-undo dump (timeouts + post-ack continuation).
  kit_undo_job_tick()

  -- Heartbeat + periodic 32-channel check + track number
  heartbeat_counter = heartbeat_counter + 1
  if heartbeat_counter >= 30 then
    reaper.gmem_write(G.BRIDGE_ALIVE, os.time())
    -- Perf profiler arm/disarm (dev flag — block comment above poll). Checked
    -- here at ~1Hz so toggling needs no bridge restart.
    if reaper.GetExtState("EON_Bridge", "perf") == "1" then
      if not _eon_perf then
        _eon_perf = { acc = {}, ticks = 0, tsum = 0, tmax = 0,
                      walks = 0, probes = 0, w0 = reaper.time_precise() }
        reaper.ShowConsoleMsg("[Swing] perf profiler ON -> Data/EON_Swing/perf_log.txt (ExtState EON_Bridge/perf=0 stops it)\n")
      end
    elseif _eon_perf then
      _eon_perf = nil
    end
    -- Write track number for browser title
    local sw_tr = find_swing_track()
    if sw_tr then
      reaper.gmem_write(G.GS_TRACK_NUM, math.floor(reaper.GetMediaTrackInfo_Value(sw_tr, "IP_TRACKNUMBER")))
    end
    ensure_32ch()
    heartbeat_counter = 0
  end

  -- Publish Media Explorer toggle state every tick so the JSFX EXPLORE button
  -- recolors instantly when the user opens/closes it (action 50124).
  eon_perf_mark("publish")
  reaper.gmem_write(G.GS_MEDIA_EXPLORER_OPEN, reaper.GetToggleCommandState(50124) == 1 and 1 or 0)

  -- Publish Drum Matrix paint-mode state every tick so the Swing PAINT button
  -- reflects it instantly — including an external key-toggle via
  -- EON_DM_TogglePaint.lua. Gated on the overlay actually running (its singleton
  -- lock fresh within 5s) so the button only lights when painting is live, not
  -- when a stale paint_mode flag lingers after the grid was closed.
  reaper.gmem_write(G.GS_DM_PAINT,
    (reaper.GetExtState("EON_DRUM_MATRIX", "paint_mode") == "1"
     and (reaper.time_precise() - (tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9)) < 5)
    and 1 or 0)
  -- Overlay running state (singleton lock fresh < 5s) for the Swing GRID button.
  reaper.gmem_write(G.GS_DM_OVERLAY,
    (reaper.time_precise() - (tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9)) < 5
    and 1 or 0)

  -- EON toolbar open-state → header TOOLBAR chip lit colour. Find the
  -- [Floating toolbar N] titled EON once (cached in _eon_tb_slot; GLOBAL, no
  -- main-chunk local), then publish its native "Open/close toolbar N" toggle
  -- state each tick (41678 + N; 41680 = slot 2, user-verified).
  if _eon_tb_slot == nil then
    _eon_tb_slot = 0
    local mf = io.open(reaper.GetResourcePath() .. core.sep .. "reaper-menu.ini", "r")
    if mf then
      local cur = nil
      for line in mf:lines() do
        local n = line:match("^%[Floating toolbar (%d+)%]")
        if n then cur = tonumber(n)
        elseif line:match("^%[") then cur = nil
        elseif cur and line:match("^title=EON%s*$") then _eon_tb_slot = cur; break end
      end
      mf:close()
    end
  end
  if _eon_tb_slot > 0 then
    reaper.gmem_write(G.GS_TOOLBAR_OPEN,
      reaper.GetToggleCommandState(41678 + _eon_tb_slot) == 1 and 1 or 0)
  end

  -- STEP SEQ button lit state: per-instance "this track's StepSeq float window
  -- is open", published into the StepSeq courier band (26030000 + slot*64,
  -- field 52; 53 = OPT_AA "Auto-adapt patterns" settings mirror, 54..63 free)
  -- keyed by each Swing's registry slot; the Swing button reads its own slot's
  -- cell. Every other tick — the float-window visibility checks are cheap but
  -- not free.
  if (heartbeat_counter % 2) == 0 then
    for _, sw in ipairs(enumerate_all_swings()) do
      local sl = ss_resolve_slot(sw.inst_id)
      if sl then
        local seq_open = 0
        for fx = 0, reaper.TrackFX_GetCount(sw.tr) - 1 do
          if is_stepseq_fx(sw.tr, fx) then
            if eon_fx_float_visible(sw.tr, fx) then seq_open = 1 end
            break
          end
        end
        reaper.gmem_write(26030000 + sl * 64 + 52, seq_open)
      end
    end
  end

  -- (Phase 1B) Undo/redo availability is now owned by the JSFX internal engine
  -- — the header buttons read _udo_uc / _udo_rc directly — so the bridge no
  -- longer publishes REAPER's Undo_CanUndo2 state into GS_UNDO_*.

  -- ─── EON unified theme → JSFX gmem color band (~5 Hz) ────────────────────
  -- Republish the resolved palette ONLY when the selection changes (or, for the
  -- "reaper" theme, when the active .ReaperTheme file changes — REAPER fires no
  -- theme-changed event). gmem writes don't wake the JSFX, so publish_theme_band
  -- bumps GS_THEME_ID last as the generation handshake the JSFX poll each frame.
  eon_perf_mark("theme")
  if _theme.mod and (heartbeat_counter % 2) == 0 then
    -- Theme button on a JSFX (Swing / StepSeq) can't SetExtState, so it writes a
    -- 1..4 request to GS_THEME_REQ; pick it up, write the shared ExtState, clear
    -- the request. The change-detection below then republishes the band, and the
    -- Browser / Pad-FX read the same ExtState — every surface stays in sync.
    local req = math.floor(reaper.gmem_read(G.GS_THEME_REQ) or 0)
    if req >= 1 and req <= #_theme.names then
      local nm = _theme.names[req]
      if nm then reaper.SetExtState("Swing", "eon_theme", nm, true) end
      reaper.gmem_write(G.GS_THEME_REQ, 0)
    end
    -- EON FX rollout LISTEN-BACK: an in-FX theme picker (1175, EQs, ...) writes
    -- GS_THEME_REQ / GS_THEME_KNOB_REQ / GS_THEME_VU_REQ into its OWN gmem
    -- segment — the main drain above never sees those. Sweep the curated
    -- segments (~200ms), forward the first pending request into the shared
    -- ExtState (the name read + change-detect BELOW then republish everywhere
    -- in this same tick), and mirror GS_THEME_CUR into each segment so picker
    -- labels track the active theme. State on _theme fields, NOT locals (main
    -- chunk sits at the 200-local limit).
    if (heartbeat_counter % 6) == 0 and core.drain_theme_fx_segments then
      _theme.fx_treq, _theme.fx_kreq, _theme.fx_vreq =
        core.drain_theme_fx_segments(_theme.idx[_theme.last_name or ""] or 0)
      if _theme.fx_treq >= 1 and _theme.fx_treq <= #_theme.names
         and _theme.names[_theme.fx_treq] then
        reaper.SetExtState("Swing", "eon_theme", _theme.names[_theme.fx_treq], true)
      end
      if _theme.fx_kreq >= 1 then
        -- Same formula as the main GS_THEME_KNOB_REQ handler below: 1 = clear
        -- override, else style index + 1. Keyed to the (possibly just-updated)
        -- theme name; inlined reads — no new locals.
        reaper.SetExtState("Swing",
          "eon_knob_" .. (reaper.GetExtState("Swing", "eon_theme") ~= ""
                          and reaper.GetExtState("Swing", "eon_theme") or "eon"),
          _theme.fx_kreq == 1 and "" or tostring(_theme.fx_kreq - 1), true)
      end
      -- VU-face SYNC relay (appearance cluster ">ALL" latch): DIRECT republish
      -- into every curated FX segment — deliberately NO ExtState (see
      -- rk_lua_core GS_THEME_VU_* note: the broadcast is a follow-me event;
      -- per-instance persistence lives on each FX's own slider/chunk). The
      -- fx_vreq guard also covers an old core without the third return (nil).
      if _theme.fx_vreq and _theme.fx_vreq >= 1 and core.relay_vu_fx_segments then
        core.relay_vu_fx_segments(_theme.fx_vreq)
      end
    end
    local name = reaper.GetExtState("Swing", "eon_theme")
    if name == "" then name = "eon" end
    -- KNOB button (Swing left panel): a JSFX can't SetExtState, so it writes a
    -- style request to GS_THEME_KNOB_REQ = (style_index + 1); 1 = Default/clear.
    -- Set the per-theme ExtState here, BEFORE the kov read below, so the same
    -- poll's change-detection republishes GS_THEME_KNOB_P. No new locals — this
    -- scope sits near the 200-local limit (see notes below).
    if math.floor(reaper.gmem_read(G.GS_THEME_KNOB_REQ) or 0) >= 1 then
      reaper.SetExtState("Swing", "eon_knob_" .. name,
        math.floor(reaper.gmem_read(G.GS_THEME_KNOB_REQ)) == 1 and ""
        or tostring(math.floor(reaper.gmem_read(G.GS_THEME_KNOB_REQ)) - 1), true)
      reaper.gmem_write(G.GS_THEME_KNOB_REQ, 0)
    end
    -- VU-face SYNC raised by a cluster plugin that lives on the MAIN segment
    -- (ChannelTool). The FX-segment sweep cannot see this mailbox, so drain and
    -- relay it here; without this its ">ALL" click is a no-op and leaves the
    -- request latched non-zero forever. No new locals (200-local limit above).
    if math.floor(reaper.gmem_read(G.GS_THEME_VU_REQ) or 0) >= 1 then
      core.relay_vu_fx_segments(math.floor(reaper.gmem_read(G.GS_THEME_VU_REQ)))
      reaper.gmem_write(G.GS_THEME_VU_REQ, 0)
    end
    -- Publish the active theme index so JSFX selectors can highlight it.
    reaper.gmem_write(G.GS_THEME_CUR, _theme.idx[name] or 1)
    -- Any of the three REAPER entries re-derives when the active .ReaperTheme file
    -- changes (REAPER fires no theme-changed event). Inlined (no new local — the
    -- bridge main chunk sits at the 200-local limit).
    local rfile = ((name == "reaper" or name == "reaper_panel" or name == "reaper_color")
      and reaper.GetLastColorThemeFile) and (reaper.GetLastColorThemeFile() or "") or ""
    -- Per-theme KNOB-STYLE override (set by the Pad-FX "Knob" dropdown): "" = use the
    -- theme's built-in knob; else this style index supersedes both tiers. Stored on
    -- _theme (a field, NOT a new top-level local — main chunk is at the 200 limit) and
    -- tracked so changing the knob republishes even when the theme name is unchanged.
    _theme.kov = reaper.GetExtState("Swing", "eon_knob_" .. name)
    if name ~= _theme.last_name or rfile ~= _theme.last_file or _theme.kov ~= _theme.last_kov then
      _theme.last_name, _theme.last_file, _theme.last_kov = name, rfile, _theme.kov
      _theme.gen = _theme.gen + 1
      -- Console-theme knob identity FIRST (primary/secondary style + per-role
      -- hues), THEN the colour band (which writes GS_THEME_ID last as the ready
      -- handshake). Guarded so a bare install without the new helpers won't error.
      if _theme.mod.knob_styles and core.publish_theme_knobs then
        _theme.ks = _theme.mod.knob_styles(name)   -- field on _theme, NOT a new top-level local (main chunk sits at the 200-local limit)
        _theme.ki = (_theme.kov ~= "" and tonumber(_theme.kov)) or nil   -- override -> both tiers
        core.publish_theme_knobs(_theme.ki or _theme.ks[1], _theme.ki or _theme.ks[2], _theme.mod.role_band(name))
      end
      core.publish_theme_band(_theme.mod.to_band(_theme.mod.resolve(name)), _theme.gen)
      -- EON FX rollout: mirror the band + knob identity into each curated FX's
      -- OWN gmem segment so gmem-using FX (1175, EQs, Delay, ...) follow the theme
      -- without having to leave their segment. No new locals (main chunk sits at
      -- the 200-local limit); recomputes the palette (cheap — change only).
      if core.publish_theme_fx_segments then
        core.publish_theme_fx_segments(_theme.mod.to_band(_theme.mod.resolve(name)), _theme.gen,
          _theme.ki or (_theme.ks and _theme.ks[1]), _theme.ki or (_theme.ks and _theme.ks[2]),
          _theme.mod.role_band(name))
      end
    end
    -- EON: periodic FX-segment refresh so a gmem-using FX loaded AFTER the last
    -- theme change still picks up the current theme (the on-change publish above
    -- only fires when the selection changes). Throttled; only once a theme has
    -- been published. No new locals (main chunk sits at the 200-local limit).
    if (heartbeat_counter % 20) == 0 and core.publish_theme_fx_segments and _theme.mod
       and _theme.last_name and _theme.last_name ~= "" then
      core.publish_theme_fx_segments(_theme.mod.to_band(_theme.mod.resolve(name)), _theme.gen,
        _theme.ki or (_theme.ks and _theme.ks[1]), _theme.ki or (_theme.ks and _theme.ks[2]),
        _theme.mod.role_band(name))
    end
  end

  -- EON: mirror StepSeq lane mute/solo onto the multi-out child tracks (~10 Hz).
  -- Banded mirror services every PAIRED StepSeq+Swing pair independently; the legacy
  -- global mirror remains as the fallback for UNPAIRED StepSeqs (it self-silences when
  -- everything is paired, because nothing advances the legacy heartbeat anymore).
  eon_perf_mark("mirror")
  if (heartbeat_counter % 3) == 0 then
    -- Legacy global mirror ONLY when an unpaired StepSeq exists (pairing-keyed,
    -- see refresh_stepseq_pairing). nil = pairing pass hasn't run yet (~1s
    -- after bridge start): hold off — the force-mirror is the dangerous one.
    -- AND never let it touch the active Swing's children when that Swing's
    -- slot is owned by a PAIRED StepSeq -- the legacy region belongs to some
    -- OTHER (unpaired) StepSeq, and force-driving this instance's tracks from
    -- it stomped user TCP mutes (the single-instance legacy assumption).
    if _seq_any_unpaired == true then
      local _lt = find_swing_track()
      local _lown = false
      if _lt and _seq_ms_owned then
        for _lfx = 0, reaper.TrackFX_GetCount(_lt) - 1 do
          if is_swing_fx(_lt, _lfx) then
            local _ls = ss_resolve_slot(math.floor(reaper.TrackFX_GetParam(_lt, _lfx, 3) or 0))
            if _ls and _seq_ms_owned[_ls] then _lown = true end
            break
          end
        end
      end
      if not _lown then eon_mirror_stepseq_ms(_lt) end
    end
    eon_mirror_stepseq_ms_banded()
  end

  -- EON: keep the three session-track identities (engine / audio / MIDI icons +
  -- colors) populated and self-healing — covers sessions built before the
  -- bridge knew about them, and reasserts after a reload (~2 Hz, guarded +
  -- compare-before-write so idle frames are no-ops). Services the active
  -- instance; per-instance builds also paint via update_folder_track_name.
  if (heartbeat_counter % 15) == 0 then
    bridge_reflect_struct(find_swing_track())
  end

  -- VER-26 per-pad kit-load stream: publish/advance one blob per tick while a
  -- load is in flight (no-op otherwise). See Spec_Swing_PerPad_Sidecar_Load.
  eon_perf_mark("pumps")
  eon_pp_pump()

  -- P3 eager capture: deferred chop WAV writes (one slice per tick, then a
  -- VER-201 path dispatch; no-op when eon_chop_state is nil).
  eon_chop_pump()

  -- P3 store lifecycle: unsaved-chop migration after a save (no-op when idle).
  eon_migrate_pump()

  -- P4 step 3c: moved-project path audit + auto-rebase (no-op when idle).
  eon_rebase_pump()

  -- P4 step 3d: per-pad disk-health publisher (~1 Hz round-robin; the
  -- @serialize embed floor reads the verdict at save time).
  eon_health_tick()

  -- P4 step 3e: banner-driven relink (no-op when idle).
  eon_relink_pump()

  -- P5: manual "Clean sample store" — the EON_Swing_Clean_Store action sets
  -- clean_store_req. Clear it only once kick settles (armed or terminally
  -- rejected); a transient-busy returns false so the request survives to the
  -- next poll instead of being silently dropped.
  if reaper.GetExtState("EON_Bridge", "clean_store_req") == "1" then
    if eon_clean_store_kick() then
      reaper.SetExtState("EON_Bridge", "clean_store_req", "", false)
    end
  end
  eon_clean_pump()

  -- Phase 2b: pick up Extension bake results (pitched WAVs) and inject
  -- them into the active instance's pad audio.
  poll_pitch_bake_results()

  -- EON: StepSeq<->DM Import-on-engage courier (folded in; see loader near top).
  -- Cheap when idle (16 gmem reads/pass); pcall-guarded so a courier fault can
  -- never stall the bridge poll loop.
  eon_perf_mark("tail")
  if eon_courier then pcall(eon_courier_tick) end
  -- EON: merged-mode trigger mirror (folded in; see loader near the top). Same
  -- pcall guard — a mirror fault must never stall the bridge poll loop.
  if eon_merged_mirror then pcall(eon_merged_mirror_tick) end

  -- AP-2: StepSeq custom-preset apply menu (scroll-audition). Independent of the courier
  -- (works on bare Swing); pcall-guarded so a fault can't stall the poll loop.
  pcall(eon_preset_nav_tick)
  pcall(eon_padcat_req_tick)
  pcall(eon_padcat_queue_tick)
  pcall(eon_padcat_backfill_tick)
  pcall(G.KITLIST.tick)
  -- Kit-categories ④ FILL: one CMD 63/64 per idle tick while a fill is in
  -- flight (no-op when eon_fill_state/eon_fill_pending are nil).
  pcall(eon_fill_tick)
  -- Embed-on-insert: default a freshly-inserted Swing to MCP-embedded
  -- (FX-browser parity; no-op unless the gmem instance registry changed).
  pcall(eon_embed_tick)
  -- AP-4: open the browser panel when the JSFX Preset strip is right-clicked.
  pcall(eon_preset_browser_launch_tick)
  -- GROOVE S3: open the .rgt groove importer when the groove menu asks for it.
  pcall(eon_groove_browser_launch_tick)
  -- Mini file browser: enumerate + publish the current folder into EON_SWBROWSE.
  -- ⚠️ A bare pcall here HID a real bug for two rounds: eon_fb_peaks read the
  -- wrong constants table, threw on every call, and the waveform was simply flat
  -- with no trace anywhere. Report once per distinct message -- never per tick,
  -- which is the dialog-storm hazard this file's header warns about.
  -- ⛔⛔ DO NOT wrap this in an `(function() ... end)()`. The previous line ends
  -- in a call, so a statement STARTING with `(` is parsed as calling THAT line's
  -- return value: "attempt to call a boolean value" at the line ABOVE, which is
  -- the one place nobody looks. Module globals instead -- this file avoids new
  -- locals anyway (the ~200-local cap).
  eon_fb_ok, eon_fb_err = pcall(eon_fb_tick)
  if not eon_fb_ok then
    eon_fb_lasterr = eon_fb_lasterr or ""
    if tostring(eon_fb_err) ~= eon_fb_lasterr then
      eon_fb_lasterr = tostring(eon_fb_err)
      reaper.ShowConsoleMsg("[EON] mini browser tick error: " .. eon_fb_lasterr ..
                            string.char(10))
    end
  end
  -- Dock-rig layout pick from Swing's wordmark menu (GS_DOCK_LAYOUT_REQ relay).
  pcall(eon_dock_layout_tick)
  -- Wordmark dock toggle: floating instance asked to be re-docked.
  pcall(eon_redock_tick)
  -- Start the Drum Strip sync companion if no one else has (once per session).
  pcall(eon_strip_sync_ensure_tick)
  -- Start EON Floatter (window sizes) if no one else has (once per session).
  pcall(eon_floatter_ensure_tick)
  -- Start the FX picker bridge if no one else has (once per session).
  pcall(eon_fxpick_ensure_tick)
  -- StepSeq SETTINGS: Open Swing / Drum Matrix command buttons.
  pcall(eon_ss_commands_tick)
  -- Toolbar lit-state for the EON toggle buttons (Grid/Paint/StepSeq/PadFX/Media/Browser).
  pcall(eon_update_toggle_states)

  eon_perf_tick_end()                   -- perf profiler window close (no-op unless armed)
  -- Ops: graceful self-exit for headless bridge restarts (dev workflow — the
  -- Lua source has no hot-reload). Set ExtState EON_Bridge/exit_req=1: the
  -- loop ends WITHOUT re-arming, so the script terminates through atexit
  -- (BRIDGE_ALIVE -> 0, temp sweeps, courier cleanup) with no ReaScript
  -- task-control dialog. A restarter then just runs the bridge action again.
  if reaper.GetExtState("EON_Bridge", "exit_req") == "1" then
    reaper.SetExtState("EON_Bridge", "exit_req", "", false)
    reaper.ShowConsoleMsg("[Swing] bridge exit_req honored — exiting cleanly (restart via action)\n")
    return
  end
  reaper.defer(poll)
end

if reaper.GetExtState("EON_Bridge", "debug_startup") == "1" then
  reaper.ShowConsoleMsg(("[bridge] started: %s (sticky StepSeq pairing, 2026-06-10)\n")
    :format(({reaper.get_action_context()})[2] or "?"))
end
pcall(eon_padcat_pext_restore)   -- kit-categories: saved pad jobs -> PADCAT band before any kit load
pcall(G.KITLIST.publish)         -- kits view: startup roster publish (covers a REQ bump that
                                 -- happened while the bridge was down — tick baselines stale)

-- ── Extension preflight ──────────────────────────────────────────────────────
-- Swing leans on three free extensions, and a missing one used to fail
-- quietly, feature by feature: the browser never opened, multi-out grew no
-- strips, the dock toggle did nothing. This bridge is the one script every
-- install runs, so it is the place to say so -- ONCE per session, and only
-- when something is actually missing (a console line on every launch would
-- pop the console open for a background service with nothing to say).
-- Each line names the feature that stops working, so the user can decide
-- whether they care. Nothing is gated on it: everything that can run, runs.
pcall(function()
  local missing = {}
  if not reaper.ImGui_CreateContext then
    missing[#missing + 1] = "ReaImGui -- the sample browser, Pad FX and the dock layout picker"
  end
  if not reaper.JS_Window_Find then
    missing[#missing + 1] = "js_ReaScriptAPI -- the dock rig and window sizing"
  end
  if not reaper.BR_GetMediaTrackSendInfo_Track then
    missing[#missing + 1] = "SWS -- Drum Strip sync on multi-out tracks, clipboard actions"
  end
  if #missing > 0 then
    local msg = "[EON] Swing: " .. #missing .. " extension(s) not installed. " ..
                "Install from ReaPack (Extensions) and restart REAPER:\n"
    for _, m in ipairs(missing) do msg = msg .. "  - " .. m .. "\n" end
    reaper.ShowConsoleMsg(msg)
  end
end)

reaper.defer(poll)
reaper.atexit(function()
  reaper.gmem_write(G.BRIDGE_ALIVE, 0)
  -- Sync playback ownership (eon_sync_mute_pass): deliberately NOT released
  -- here. A synced StepSeq keeps playing after the bridge exits, so its project
  -- copy must stay muted; the P_EXT:EON_SYNC_MUTE marker makes the state
  -- re-derivable and the next bridge start's sweep releases exactly what is due.
  if _theme.mod then core.clear_theme_band(); if core.clear_theme_fx_segments then core.clear_theme_fx_segments() end end  -- EON: JSFX revert to default colors
  _eon_sweep_temp_audio()  -- Issue C: clear bake temp WAVs so they don't pile up
  -- P3b-4c: restore 'smoothseek' if the bridge dies mid-song (SongStop normally does)
  if eon_courier and eon_courier.pattern_song and eon_courier.pattern_song.Cleanup then
    pcall(eon_courier.pattern_song.Cleanup)
  end
end)
