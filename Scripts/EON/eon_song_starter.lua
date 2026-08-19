-- @noindex
-- eon_song_starter.lua
-- Shared builder behind the EON: New Song actions (loaded via dofile, not an
-- action itself — same arrangement as eon_action_target.lua).
--
-- Lays out a song skeleton in one undo point: tempo, four named regions, a
-- Swing track, an empty MIDI item per region, and the Drum Matrix lanes.
--
-- ORDERING MATTERS. Everything this script does directly is synchronous, but
-- the lane build is a BRIDGE command (code 73) that the bridge picks up on its
-- own defer tick — we cannot see it finish from here. So lanes are fired LAST
-- and nothing afterwards depends on them. Do not reorder this to build lanes
-- before the MIDI items: the items would race a track layout that does not
-- exist yet.
-- (c) EON Studios

local M = {}

-- rk_lua_core lives one level up in EVERY layout (dev .Scripts/, installer and
-- ReaPack Scripts/<...>/), so resolve it from this file's own directory rather
-- than package.path -- this module is dofile'd, so it cannot rely on the
-- caller's search path being set.
local _ss_dir = (debug.getinfo(1, "S").source:match("@?(.*)") or ""):match("^(.*)[/\\]") or ""
local _ss_sep = package.config:sub(1, 1)
local core = dofile(_ss_dir .. _ss_sep .. ".." .. _ss_sep .. "rk_lua_core.lua")

-- pattern_regions (Drum Matrix lib): the regions this builder lays out must be
-- ADOPTED into the DM pattern membership set, or the pattern system never sees
-- them — pattern_regions.List() deliberately returns members only (it must not
-- hijack regions the user made for other purposes), so an unadopted
-- Intro/Verse gets no DM chip, no bridge-published name/colour, and no synced
-- StepSeq region binding ("sync does nothing"). Guarded like the dialog below:
-- a partial install without the DM lib skips adoption instead of killing the
-- action.
local _pat_regions
do
  local ok, m = pcall(dofile, _ss_dir .. _ss_sep .. "Drum Matrix" .. _ss_sep
                              .. "lib" .. _ss_sep .. "pattern_regions.lua")
  _pat_regions = (ok and type(m) == "table" and m.Adopt) and m or nil
end

-- The EON form dialog sits beside this file. Loaded lazily and pcall'd: a
-- partial install that is missing it must drop to the GetUserInputs fallback in
-- M.prompt, not throw out of the middle of an action.
local _dlg_mod, _dlg_tried
local function load_dialog()
  if not _dlg_tried then
    _dlg_tried = true
    local ok, m = pcall(dofile, _ss_dir .. _ss_sep .. "eon_imgui_dialog.lua")
    _dlg_mod = (ok and type(m) == "table") and m or nil
  end
  return _dlg_mod
end

-- Region tints, roughly matching the Swing pad hue vocabulary so a starter
-- project reads as EON-branded rather than REAPER-default grey.
-- ⚠️ These paint the REAL timeline regions as well as the dialog's arrangement
-- strip — that shared source is the whole reason the strip is a preview rather
-- than a decoration. Making them bolder here makes the project bolder too,
-- which is the intent; do not "fix" one end without the other.
local REGION_COLORS = {
  {  62, 130, 224 },  -- Intro   — blue
  {  58, 182,  96 },  -- Verse   — green
  { 235, 142,  38 },  -- Chorus  — amber
  { 152,  82, 216 },  -- Outro   — violet
}

M.DEFAULT_SECTIONS = { "Intro", "Verse", "Chorus", "Outro" }
M.DEFAULT_BARS = 8
M.DEFAULT_BPM = 120

-- Song templates for the New Song dialog. `sections` is the LITERAL TEXT that
-- lands in the Sections field, not a parsed structure — so what the picker
-- fills in is exactly what the user can then edit, and the "Name:bars" suffix
-- they see is the same syntax they can type by hand. Anything without a suffix
-- inherits "Bars per section", which is why each template also carries a bars
-- value that suits its genre (16 for four-on-the-floor, 8 for song forms).
M.TEMPLATES = {
  { name = "Basic 4-part",   bpm = 120, bars = 8,
    sections = "Intro:4, Verse, Chorus, Outro:4" },
  { name = "Pop (verse-chorus)", bpm = 120, bars = 8,
    sections = "Intro:4, Verse, Pre:4, Chorus, Verse, Pre:4, Chorus, Bridge, Chorus, Outro:4" },
  { name = "Hip-Hop",        bpm = 90,  bars = 8,
    sections = "Intro:4, Verse:16, Hook, Verse:16, Hook, Verse:16, Hook, Outro:4" },
  { name = "Boom Bap",       bpm = 92,  bars = 8,
    sections = "Intro:4, Verse:16, Hook, Verse:16, Hook, Outro:4" },
  { name = "Trap",           bpm = 140, bars = 8,
    sections = "Intro:4, Verse:16, Hook, Verse:16, Hook, Bridge, Hook, Outro:4" },
  { name = "Lo-fi beat tape", bpm = 82, bars = 8,
    sections = "Intro:4, Loop A, Loop B, Loop A, Outro:4" },
  { name = "House",          bpm = 124, bars = 16,
    sections = "Intro, Build:8, Drop, Break:8, Build:8, Drop, Outro" },
  { name = "Techno",         bpm = 132, bars = 16,
    sections = "Intro, Groove, Build:8, Peak, Break:8, Peak, Outro" },
  { name = "Drum & Bass",    bpm = 174, bars = 16,
    sections = "Intro, Build:8, Drop, Break, Build:8, Drop, Outro" },
  { name = "12-bar Blues",   bpm = 100, bars = 12,
    sections = "Head, Solo, Solo, Head, Outro" },
  { name = "AABA (32-bar)",  bpm = 120, bars = 8,
    sections = "A1, A2, B, A3" },
  { name = "Loop sketch",    bpm = 120, bars = 8,
    sections = "Loop" },
}

-- Time (seconds) at the start of measure `bar`, 0-based. TimeMap2_beatsToTime
-- with a measure argument treats the beat operand as an offset INSIDE that
-- measure, so passing 0 lands exactly on the barline whatever the signature.
local function bar_time(bar)
  return reaper.TimeMap2_beatsToTime(0, 0, bar)
end

-- Insert a track at the end and return it. wantDefaults=false so the user's
-- default-track template (which may carry FX we would be rude to duplicate)
-- is not applied.
local function add_track(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  if tr and name then
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  end
  return tr
end

-- Resolve Swing's JSFX by the same identity the bridge and the action wrappers
-- use, rather than a display name that changes with the desc: line.
local function add_swing(tr)
  if not tr then return nil end
  -- -1 = instantiate if not already present. AddByName reports success even
  -- when the JSFX failed to COMPILE, so a non-negative return here means "the
  -- file was found", not "the plugin is healthy".
  -- ⚠️ This used to guess two literals: "Swing_ReaKit" (matches no registered
  -- ident in any layout) and "EON/Swing/Swing_ReaKit" (written for the installer
  -- layout but missing the ".jsfx" that is part of the ident). Neither could ever
  -- match under ReaPack, where the path carries the index-name segment. Result:
  -- New Song produced a track named "Swing" with no Swing on it and no Drum
  -- Matrix lanes, since the lane build is gated on this returning non-nil.
  local name, _, why = core.jsfx_addname("Swing_ReaKit.jsfx")
  if not name then
    reaper.ShowConsoleMsg("[EON] New Song could not locate Swing_ReaKit.jsfx " ..
      "under the Effects folder.\n  " .. tostring(why) .. "\n")
    return nil
  end
  local fx = reaper.TrackFX_AddByName(tr, name, false, -1)
  return fx >= 0 and fx or nil
end

-- opts:
--   bpm          number  | nil  — project tempo; nil leaves the tempo alone
--   bars         number        — bars per section (default 8)
--   sections     table         — in order; each entry is either a name string
--                                or { name = ..., bars = ... } for a section
--                                with its own length (default 4-part)
--   start_bar    number        — first bar, 0-based (default: current cursor bar)
--   insert_swing boolean       — add a track with Swing on it
--   midi_items   boolean       — one empty MIDI item per region on that track
--   build_lanes  boolean       — fire the Drum Matrix lane build (async)
--   step_seq     boolean       — insert EON StepSeq above Swing, embedded in the MCP
--   float_swing  boolean|nil   — open Swing's floating window after the kit
--                                request (nil = true, the historic behavior)
--   target       table  | nil  — eon_action_target module, required for lanes
--
-- Returns ok, message.
function M.build(opts)
  opts = opts or {}
  local sections = opts.sections or M.DEFAULT_SECTIONS
  local bars = tonumber(opts.bars) or M.DEFAULT_BARS
  if bars < 1 then bars = 1 end
  if #sections == 0 then return false, "no sections to build" end

  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)

  -- Tempo first: every bar->time conversion below depends on it, so setting it
  -- afterwards would place the regions against the OLD grid.
  if opts.bpm then reaper.SetCurrentBPM(0, opts.bpm, false) end

  -- Default to the bar under the edit cursor so running this in a project that
  -- already has material appends rather than overlaying bar 1.
  local start_bar = opts.start_bar
  if not start_bar then
    local cur = reaper.GetCursorPosition()
    local _, measures = reaper.TimeMap2_timeToBeats(0, cur)
    start_bar = measures or 0
  end

  local tr, fx
  if opts.insert_swing then
    tr = add_track("Swing")
    fx = add_swing(tr)
    -- Select ONLY the new track: the lane build (EON_DM_Build via bridge cmd
    -- 73/74) resolves a multi-Swing project through the single SELECTED track
    -- carrying a Swing — without this it pops its picker menu (or, worse,
    -- builds the other instance). Also simply the right place to leave the
    -- user after "New Song".
    if tr then reaper.SetOnlyTrackSelected(tr) end
  end

  -- Bars advance through a RUNNING CURSOR, not i * bars: a section may carry
  -- its own length (see M.parse_sections), which is what makes a 4-bar intro
  -- in front of 8-bar verses possible. Entries are either a plain name string
  -- (what the Quick and Regions actions pass) or { name, bars }.
  local cursor = start_bar
  for i, sec in ipairs(sections) do
    local name = (type(sec) == "table") and tostring(sec.name or "") or tostring(sec)
    local len  = ((type(sec) == "table") and tonumber(sec.bars)) or bars
    if len < 1 then len = 1 end
    local t0, t1 = bar_time(cursor), bar_time(cursor + len)

    local c = REGION_COLORS[((i - 1) % #REGION_COLORS) + 1]
    -- |0x1000000 flags the colour as "set by the user"; without it REAPER
    -- treats the value as unset and paints the default.
    local col = reaper.ColorToNative(c[1], c[2], c[3]) | 0x1000000
    local ridx = reaper.AddProjectMarker2(0, true, t0, t1, name, -1, col)
    -- Register the section as a Drum Matrix pattern (see the loader note: the
    -- membership set is what makes it exist to the DM bar, the bridge's
    -- name/colour publish, and a synced StepSeq).
    if _pat_regions and ridx and ridx >= 0 then _pat_regions.Adopt(ridx) end

    -- ONE writing surface (user 2026-08-11): when the Drum Matrix lanes are
    -- being built, notes live on the LANE tracks — Steppa and the DM read and
    -- write there — and empty per-region items on the Swing track are dead
    -- weight that LOOKS editable ("am I in drum matrix mode or not?"). Items
    -- here are the piano-roll writing surface for the NO-lanes workflow only.
    -- (If the lanes build later fails — bridge dead — the deferred arm's
    -- console warning explains the half-built state.)
    if opts.midi_items and tr and not opts.build_lanes then
      local item = reaper.CreateNewMIDIItemInProj(tr, t0, t1, false)
      if item then
        local take = reaper.GetActiveTake(item)
        if take then
          reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
        end
      end
    end

    cursor = cursor + len
  end

  -- Frame the new song so the user sees what just happened.
  reaper.GetSet_LoopTimeRange(true, false,
    bar_time(start_bar), bar_time(cursor), false)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock2(0, "EON: New Song", -1)

  -- LAST, and deliberately outside the undo block: this posts a command the
  -- bridge executes on a later tick, so it makes its own undo point. Firing it
  -- inside our block would leave the block open across an async boundary.
  -- One command, not two: 74 is the bridge's own build-both, so asking for
  -- lanes AND multi-out never races two structural rebuilds against each other.
  local build_code
  if opts.build_lanes and opts.multi_out then build_code = 74
  elseif opts.build_lanes                 then build_code = 73
  elseif opts.multi_out                   then build_code = 40 end

  if fx then
    -- Route the follow-up work at the Swing WE created, on the defer loop.
    -- Three reasons this cannot be a plain focus_lock()+fire():
    --   * our windowless AddByName is never the focused FX, so focus_lock()
    --     leaves a stale LOCK and the bridge builds the FIRST Swing it finds —
    --     in a project that already has one, that's the WRONG instance;
    --   * the new instance only claims its instance_id (slider4) once @block
    --     runs, which is AFTER this action returns — it cannot be read here;
    --   * fire() drops the command silently when the bus is busy (a lingering
    --     completion code takes ~5s to clear via the bridge watchdog).
    --
    -- SEQUENCE: kit FIRST, build second (the dead-window fix, 2026-08-19).
    -- The build used to be posted the moment the id existed, which held the
    -- CMD bus through the whole build + FX-returns dialog; the JSFX-side
    -- default-kit auto-load gates on an IDLE bus, so the kit (and with it the
    -- Lens artwork and the pad names/colors the build reads from gmem) only
    -- arrived seconds after everything else. The kit-load REQUEST channel is
    -- independent of the CMD bus, so we queue the default kit directly, wait
    -- for it to land, then post the build — children are created with real
    -- names/colors and the Lens is born with its artwork. The JSFX auto-load
    -- stays as the fallback and self-disarms when it sees loaded pads.
    local target = opts.target
    -- Default kit — mirrors the bridge's CMD-22 auto-load resolution
    -- (Swing_Kit_Bridge.lua, cmd == 22 — that copy is canonical; keep in
    -- sync). Missing file = skip the request silently, same as CMD 22.
    local kit_path = core.get_kits_dir() .. _ss_sep .. "Fischer 808"
                     .. _ss_sep .. "808 F.swing"
    do
      local kf = io.open(kit_path, "rb")
      if kf then kf:close() else kit_path = nil end
    end
    -- gmem cells, mirrored from rk_lua_core GMEM (inlined, the
    -- eon_action_target posture — this module must not depend on the bridge).
    local GS_KIT_LOAD_REQ, GS_LOAD_WANT = 1444, 26090340
    -- `fx` is an INDEX and the retry window is seconds long — re-resolve
    -- through the FX GUID each tick so an FX inserted above it mid-arm can't
    -- make us read a stranger's param 3 (garbage iid -> LOCK misroute).
    local fx_guid = reaper.TrackFX_GetFXGUID(tr, fx)
    local phase = kit_path and "kit_post" or "build"
    local deadline = reaper.time_precise() + 12.0
    local function arm()
      if not reaper.ValidatePtr2(0, tr, "MediaTrack*") then return end
      local rfx = fx
      if fx_guid then
        rfx = -1
        for i = 0, reaper.TrackFX_GetCount(tr) - 1 do
          if reaper.TrackFX_GetFXGUID(tr, i) == fx_guid then rfx = i break end
        end
        if rfx < 0 then return end   -- our Swing was deleted: stand down
      end
      local iid = math.floor(reaper.TrackFX_GetParam(tr, rfx, 3) or 0)  -- slider4 = instance_id

      if phase == "kit_post" then
        if reaper.time_precise() > deadline then
          -- Could not even request the kit (id never claimed / REQ never
          -- freed) — fall through to the build; the JSFX auto-load remains.
          phase = "kit_wait"; deadline = 0
        elseif iid > 0 then
          reaper.gmem_attach("Swing_Media_Transfer")
          if math.floor(reaper.gmem_read(GS_KIT_LOAD_REQ) or 0) == 0 then
            reaper.SetExtState("Swing", "kit_load_path", kit_path, false)
            reaper.gmem_write(GS_LOAD_WANT, iid)  -- WANT only; PENDING is the
            -- bridge→JSFX delivery binding and must never be stomped from here
            reaper.gmem_write(GS_KIT_LOAD_REQ, 1)
            -- CMD-22 parity: the auto-load pops Swing open on a fresh insert;
            -- a windowless AddByName is closed by definition. Float Swing is
            -- now an option (nil = the historic float).
            if opts.float_swing ~= false then
              reaper.TrackFX_Show(tr, rfx, 3)
              if core.hub_notify then core.hub_notify("open", "swing", tr, rfx) end
            end
            -- Step sequencer (opt-in): find-or-insert above Swing so its MIDI
            -- feeds the sampler, embedded-first in the MCP — never floated.
            if opts.step_seq then
              local sq = core.jsfx_addname("EON_StepSeq.jsfx")
              if sq then
                local si = reaper.TrackFX_AddByName(tr, sq, false, 0)
                if si < 0 then
                  si = reaper.TrackFX_AddByName(tr, sq, false, -1)
                  if si and si >= 0 then
                    if si > rfx then
                      reaper.TrackFX_CopyToTrack(tr, si, tr, rfx, true)
                      rfx = rfx + 1   -- Swing shifted down one slot
                    end
                    core.fx_embed_mcp(tr, "EON_StepSeq")
                  end
                end
              end
            end
            phase = "kit_wait"; deadline = reaper.time_precise() + 8.0
          end
        end
      elseif phase == "kit_wait" then
        -- The bridge stamps the track's kit-source breadcrumb on positive load
        -- ack — that is the "kit really landed" edge (pads, colors, artwork
        -- all staged before it). Deadline just means "build anyway".
        local _, src = reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:swing_kit_src", "", false)
        if src == kit_path then
          phase = "build"; deadline = reaper.time_precise() + 12.0
        elseif reaper.time_precise() > deadline then
          reaper.ShowConsoleMsg("[EON] New Song: default kit did not confirm in time -- building anyway\n")
          phase = "build"; deadline = reaper.time_precise() + 12.0
        end
      elseif phase == "build" then
        if not (build_code and target) then return end   -- kit-only run: done
        if reaper.time_precise() > deadline then
          reaper.ShowConsoleMsg("[EON] New Song: bridge build (cmd " .. build_code ..
            ") was never posted -- is the Swing Kit Bridge running?\n")
          return
        end
        if iid > 0 and target.post_locked and target.post_locked(iid, build_code) then
          return
        end
      end
      reaper.defer(arm)
    end
    arm()
  end

  local what = #sections .. " regions"
  if opts.insert_swing then
    what = what .. (fx and " + Swing" or " + Swing (FX ADD FAILED)")
  end
  if opts.midi_items and not opts.build_lanes then what = what .. " + MIDI items" end
  if fx and opts.build_lanes then what = what .. " + lanes" end
  if fx and opts.multi_out   then what = what .. " + multi-out" end
  return true, what
end

-- Split a section list into names. A comma-separated list wins whenever the
-- string contains a comma, so "Verse 2, Big Chorus" keeps its spaces; otherwise
-- fall back to whitespace, which is all the GetUserInputs field below can offer
-- (its DEFAULTS are themselves parsed as CSV, so a comma there splits the
-- field). Both entry points route through here, so both accept both shapes.
-- Returns a list of { name, bars } — bars nil meaning "use the default".
function M.parse_sections(s)
  local parts, out = {}, {}
  s = tostring(s or "")
  if s:find(",", 1, true) then
    for part in s:gmatch("[^,]+") do parts[#parts + 1] = part end
  else
    for word in s:gmatch("%S+") do parts[#parts + 1] = word end
  end

  for _, part in ipairs(parts) do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then
      -- "Verse:16" gives that one section its own length; a bare name inherits
      -- "Bars per section". Anchored at the end, so only a TRAILING ":number"
      -- is a length: "Verse 2" keeps its digit, "Verse 2:16" splits correctly.
      local nm, n = part:match("^(.-)%s*:%s*(%d+)$")
      if nm and nm ~= "" then
        out[#out + 1] = { name = nm, bars = tonumber(n) }
      else
        out[#out + 1] = { name = part }
      end
    end
  end

  if #out == 0 then
    for _, nm in ipairs(M.DEFAULT_SECTIONS) do out[#out + 1] = { name = nm } end
  end
  return out
end

-- ── User templates ─────────────────────────────────────────────────────────
-- A plain tab-separated file beside the kits, NOT ExtState: an ExtState value
-- is an ini value, and a section list is exactly the free-form string an ini
-- round-trip mangles. One record per line, hand-editable, and deleting the file
-- is a clean reset.
local function user_templates_path()
  local dir = reaper.GetResourcePath() .. _ss_sep .. "Data"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. _ss_sep .. "EON_Song_Templates.txt"
end

function M.user_templates()
  local out = {}
  local f = io.open(user_templates_path(), "r")
  if not f then return out end
  for line in f:lines() do
    -- sections captured with (.*) and taken LAST, so it is the only field
    -- allowed to be empty or to contain anything at all.
    local name, bpm, bars, secs = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if name and name ~= "" then
      out[#out + 1] = {
        name     = name,
        bpm      = tonumber(bpm)  or M.DEFAULT_BPM,
        bars     = tonumber(bars) or M.DEFAULT_BARS,
        sections = secs,
        user     = true,
      }
    end
  end
  f:close()
  return out
end

-- Saving under a name that already exists REPLACES it, so re-saving a tweak
-- does not litter the list with near-duplicates. Returns ok, err.
function M.save_template(t)
  local name = tostring((t and t.name) or ""):match("^%s*(.-)%s*$")
  if name == "" then return false, "no name" end
  -- The record separator is the line and the field separator is the tab, so
  -- neither may survive inside a value.
  local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]", " ")) end
  name = clean(name)

  local row = { name = name,
                bpm  = tonumber(t.bpm)  or M.DEFAULT_BPM,
                bars = tonumber(t.bars) or M.DEFAULT_BARS,
                sections = clean(t.sections) }

  local list, replaced = M.user_templates(), false
  for i, e in ipairs(list) do
    if e.name:lower() == name:lower() then list[i] = row; replaced = true; break end
  end
  if not replaced then list[#list + 1] = row end

  local f, err = io.open(user_templates_path(), "w")
  if not f then return false, tostring(err) end
  for _, e in ipairs(list) do
    -- %.10g so a whole-number tempo writes "120", not "120.0".
    f:write(string.format("%s\t%.10g\t%.10g\t%s\n",
                          e.name, e.bpm, e.bars, e.sections))
  end
  f:close()
  return true
end

-- ── Arrangement strip ──────────────────────────────────────────────────────
-- The section map drawn to scale, in the SAME colours build() paints the
-- regions with — so it previews the actual timeline rather than decorating the
-- dialog. Rebuilt from the LIVE field values every frame, which makes it a
-- typo check ("why is Chrous grey?") as much as a picture.
--
-- Deliberately not per-genre artwork: twelve drawings would be assets to make,
-- ship and keep in sync, and they would say less than this does.
-- Quarter notes per bar from the project signature. BPM in REAPER counts
-- QUARTER NOTES, so 6/8 is 3 QN to the bar, not 6.
local function qn_per_bar()
  local num, den = reaper.TimeMap_GetTimeSigAtTime(0, 0)
  return (tonumber(num) or 4) * 4 / (tonumber(den) or 4)
end

local function total_bars(secs, bars_def)
  local n = 0
  for _, s in ipairs(secs) do n = n + math.max(1, s.bars or bars_def) end
  return n
end

-- Paint a section map into an arbitrary rect. Shared by the big strip and the
-- template picker's rows, so a row thumbnail can never drift from the preview.
local function paint_sections(ctx, dl, x, y, w, h, secs, bars_def, show_bars)
  local total = total_bars(secs, bars_def)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y, x + w, y + h, 0x00000040, 3)
  if total < 1 or w <= 2 then return end

  local fh, cx = reaper.ImGui_GetFontSize(ctx), x
  for i, s in ipairs(secs) do
    local len = math.max(1, s.bars or bars_def)
    -- Last block runs to the right edge so rounding cannot leave a sliver.
    local x1  = (i == #secs) and (x + w) or (cx + w * len / total)
    local c   = REGION_COLORS[((i - 1) % #REGION_COLORS) + 1]
    local col = (c[1] << 24) | (c[2] << 16) | (c[3] << 8) | 0xFF
    local rx  = math.max(cx + 1, x1 - 2)          -- 2px gutter between blocks
    reaper.ImGui_DrawList_AddRectFilled(dl, cx, y, rx, y + h, col, 2)

    -- A name is drawn only when the WHOLE word fits. Clipping to the block was
    -- not enough: at thumbnail width it produced "horu" and "ridg", which reads
    -- as corruption. Too narrow now means no label, and the colour carries it.
    local tw = reaper.ImGui_CalcTextSize(ctx, s.name)
    if tw + 6 <= (rx - cx) and h >= fh + 2 then
      reaper.ImGui_DrawList_PushClipRect(dl, cx + 2, y, rx - 1, y + h, true)
      local two = show_bars and h >= (fh * 2 + 4)
      reaper.ImGui_DrawList_AddText(dl, cx + ((rx - cx) - tw) / 2,
        two and (y + h / 2 - fh - 1) or (y + (h - fh) / 2), 0xFFFFFFEE, s.name)
      if two then
        -- Bar count in the block's own shadow rather than another bright
        -- colour: it is a detail, and the name has to stay the loud thing.
        local bs = tostring(math.floor(len))
        local bw = reaper.ImGui_CalcTextSize(ctx, bs)
        reaper.ImGui_DrawList_AddText(dl, cx + ((rx - cx) - bw) / 2,
                                      y + h / 2 + 1, 0x00000099, bs)
      end
      reaper.ImGui_DrawList_PopClipRect(dl)
    end
    cx = x1
  end
end

local function draw_arrangement(ctx, x, y, w, h, by_key)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local function fval(k, dflt)
    local f = by_key[k]
    if f == nil or f.value == nil then return dflt end
    return f.value
  end

  local bars_def = math.floor(tonumber(fval("bars", M.DEFAULT_BARS)) or M.DEFAULT_BARS)
  if bars_def < 1 then bars_def = 1 end
  local bpm  = tonumber(fval("bpm", M.DEFAULT_BPM)) or M.DEFAULT_BPM
  local secs = M.parse_sections(tostring(fval("sections", "")))

  local strip_h = h - 16          -- bottom line is the summary
  paint_sections(ctx, dl, x, y, w, strip_h, secs, bars_def, true)

  local total = total_bars(secs, bars_def)
  local dur   = math.floor(total) * qn_per_bar() * 60 / math.max(1, bpm)
  reaper.ImGui_DrawList_AddText(dl, x, y + strip_h + 3, 0x8A8F98FF,
    string.format("%d sections  ·  %d bars  ·  %d:%02d",
                  #secs, math.floor(total),
                  math.floor(dur / 60), math.floor(dur % 60)))
end

-- ── Template grid ──────────────────────────────────────────────────────────
-- Genre art comes from the glyphs we already ship (Swing/icons), resolved
-- through rk_lua_icons so it survives every install layout. No new drawings to
-- make, and the art re-themes with the rest of the kit iconography.
-- { glyph, tint }. The shipped icons are pure GREYSCALE line art (measured: 0%
-- saturated pixels, mean luminance ~190), so DrawList_AddImage's col_rgba —
-- which MULTIPLIES the texture — colours them cleanly. Tints are kept near full
-- brightness in their dominant channel because that 0.75 base darkens whatever
-- it is multiplied by.
local GENRE_ART = {
  ["Basic 4-part"]       = { "pad",        0x7CC0FFFF },
  ["Pop (verse-chorus)"] = { "vocal",      0xFF7CC0FF },
  ["Hip-Hop"]            = { "groovebox",  0xFFC94AFF },
  ["Boom Bap"]           = { "kick",       0xFF9A4AFF },
  ["Trap"]               = { "closed_hat", 0xC08CFFFF },
  ["Lo-fi beat tape"]    = { "loop",       0x6FE0D4FF },
  ["House"]              = { "clap",       0x5FD0FFFF },
  ["Techno"]             = { "engine",     0xFF7A7AFF },
  ["Drum & Bass"]        = { "snare",      0xA8F05AFF },
  ["12-bar Blues"]       = { "guitar",     0x8FA8FFFF },
  ["AABA (32-bar)"]      = { "keys",       0xFFD06AFF },
  ["Loop sketch"]        = { "percussion", 0xB8C6D6FF },
}
local USER_ART = { "synth", 0x5AA8FFFF }   -- anything the user saved themselves

local function art_for(t)
  if t.user then return USER_ART[1], USER_ART[2] end
  local a = GENRE_ART[t.name]
  if a then return a[1], a[2] end
  return "pad", 0xB8C6D6FF
end

local _icons_mod, _icons_tried
local function icons_lib()
  if not _icons_tried then
    _icons_tried = true
    local ok, m = pcall(dofile, _ss_dir .. _ss_sep .. ".." .. _ss_sep .. "rk_lua_icons.lua")
    _icons_mod = (ok and type(m) == "table") and m or nil
  end
  return _icons_mod
end

local CARD_H, CARD_COLS, CARD_GAP = 58, 3, 6

-- ⚠️ The image cache MUST live per dialog, not module-wide: an ImGui image is
-- attached to a context, and every open() builds a fresh one. A cached handle
-- from a previous dialog would be attached to a dead context.
local function make_template_grid(list)
  local imgs = {}

  local function image_for(ctx, key)
    local hit = imgs[key]
    if hit ~= nil then return hit or nil end
    local lib  = icons_lib()
    local path = lib and lib.resolve and lib.resolve(key)
    if not path then imgs[key] = false; return nil end
    -- pcall throughout: a missing or unreadable PNG must cost the card its
    -- picture, never the dialog.
    local ok, img = pcall(reaper.ImGui_CreateImage, path)
    if not ok or not img then imgs[key] = false; return nil end
    pcall(reaper.ImGui_Attach, ctx, img)
    imgs[key] = img
    return img
  end

  return function(ctx, by_key, set)
    local self = by_key.template
    local cur  = math.floor(tonumber(self and self.value) or 1)

    reaper.ImGui_Dummy(ctx, 1, 2)
    reaper.ImGui_TextColored(ctx, 0x8A8F98FF, "Start from a template")

    -- Three rows visible; anything beyond that scrolls, so a long saved list
    -- can never push the Create button off the bottom of the dialog.
    local rows = math.min(3, math.ceil(#list / CARD_COLS))
    reaper.ImGui_BeginChild(ctx, "##tplgrid", -1, rows * (CARD_H + CARD_GAP) + 4)

    local cw = (reaper.ImGui_GetContentRegionAvail(ctx)
                - CARD_GAP * (CARD_COLS - 1)) / CARD_COLS
    for i, t in ipairs(list) do
      if (i - 1) % CARD_COLS ~= 0 then reaper.ImGui_SameLine(ctx, 0, CARD_GAP) end
      -- Rect captured BEFORE the Selectable: it has moved the cursor on by the
      -- time it returns, and the card is painted over its highlight.
      local x, y = reaper.ImGui_GetCursorScreenPos(ctx)
      local sel  = (i == cur)
      if reaper.ImGui_Selectable(ctx, "##tpl" .. i, sel, 0, cw, CARD_H) then
        self.value = i
        set("bpm", t.bpm)
        set("bars", t.bars)
        set("sections", t.sections)
      end

      local dl    = reaper.ImGui_GetWindowDrawList(ctx)
      local secs  = M.parse_sections(t.sections)
      local total = total_bars(secs, t.bars)
      local dur   = total * qn_per_bar() * 60 / math.max(1, t.bpm)

      local glyph, tint = art_for(t)
      local img = image_for(ctx, glyph)
      if img then
        -- uv defaults spelled out because col_rgba is the 11th argument.
        reaper.ImGui_DrawList_AddImage(dl, img, x + 5, y + 5, x + 33, y + 33,
                                       0, 0, 1, 1, tint)
      end
      local tx = x + (img and 38 or 6)
      reaper.ImGui_DrawList_AddText(dl, tx, y + 5, 0xF0F2F5FF, t.name)
      reaper.ImGui_DrawList_AddText(dl, tx, y + 21, 0x8A8F98FF,
        string.format("%d bars  ·  %d:%02d  ·  %g BPM",
                      math.floor(total), math.floor(dur / 60),
                      math.floor(dur % 60), t.bpm))

      -- Shape strip along the card's foot. No labels at this width — that is
      -- what produced the clipped word fragments.
      paint_sections(ctx, dl, x + 5, y + CARD_H - 18, cw - 10, 14,
                     secs, t.bars, false)

      if sel then
        reaper.ImGui_DrawList_AddRect(dl, x, y, x + cw, y + CARD_H, 0x3A86D0FF, 3)
      end
    end

    reaper.ImGui_EndChild(ctx)
  end
end

-- Shared prompt for the configurable entry point.
--
-- ⚠️ ASYNC — it hands the answer to on_accept(opts) instead of returning it.
-- The ReaImGui form runs on the defer loop, so the caller's main chunk has
-- already finished by the time the user clicks Create. The GetUserInputs
-- fallback calls on_accept synchronously before returning; callers must not
-- depend on which of the two they got. Cancel calls nothing at all.
function M.prompt(on_accept)
  if not on_accept then return end

  local dlg = load_dialog()
  if dlg and dlg.available and dlg.available() then
    -- Built-ins first, then whatever the user has saved. Saved ones are told
    -- apart in the grid by their own glyph (synth, in EON blue) rather than a
    -- name prefix — the ImGui default font is not guaranteed to carry a star
    -- or bullet, and the art does the job better anyway.
    local all = {}
    for _, t in ipairs(M.TEMPLATES)      do all[#all + 1] = t end
    for _, t in ipairs(M.user_templates()) do all[#all + 1] = t end

    local first_tpl = all[1]

    dlg.open({
      title    = "EON: New Song",
      width    = 640,
      ok_label = "Create",
      fields   = {
        { key = "bpm",  label = "Tempo (BPM)",      kind = "number",
          value = first_tpl.bpm,  min = 20, max = 960 },
        { key = "bars", label = "Bars per section", kind = "int",
          value = first_tpl.bars, min = 1,  max = 256 },
        { key = "sections", label = "Sections",     kind = "text",
          value = first_tpl.sections,
          hint  = "Intro, Verse, Chorus, Outro",
          sub   = "comma separated — add :bars for a section's own length" },
        { key = "arrangement", label = "Arrangement", kind = "custom",
          height = 58, draw = draw_arrangement },
        -- Multi-out and lanes are BRIDGE builds fired after the song is laid
        -- out, so they are opt-in rather than assumed.
        { key = "extras", label = "Also build", kind = "checks",
          sub = "bridge builds run after the song; with lanes on, notes live on the lanes (MIDI items skipped)",
          items = {
            { key = "midi_items",  label = "MIDI items",     value = true },
            { key = "build_lanes", label = "MIDI lanes",     value = true },
            { key = "multi_out",   label = "Multi-out audio", value = true },
            { key = "step_seq",    label = "Step sequencer",  value = true },
            { key = "float_swing", label = "Float Swing",     value = true },
          } },
        -- Saving rides along with Create rather than opening a second modal:
        -- one text box, no nesting, and the common case (leave it blank) costs
        -- nothing. Re-using an existing name overwrites that template.
        { key = "save_as", label = "Save as", kind = "text", value = "",
          hint = "optional",
          sub  = "name these settings to keep them in the grid below" },
        -- The picker sits at the BOTTOM and is a LOADER, not a mode: clicking a
        -- card stamps the fields above and gets out of the way, so editing them
        -- afterwards needs no "Custom" state to fall back to.
        { key = "template", kind = "block", value = 1,
          draw = make_template_grid(all) },
      },
      on_ok = function(v)
        local nm = tostring(v.save_as or ""):match("^%s*(.-)%s*$")
        if nm ~= "" then
          -- Saved BEFORE the build: if build() throws on a malformed section
          -- list, the user still keeps the recipe they just named.
          local ok, err = M.save_template({
            name = nm, bpm = v.bpm, bars = v.bars, sections = v.sections,
          })
          if not ok then
            reaper.ShowConsoleMsg("[EON] Could not save song template: " ..
                                  tostring(err) .. "\n")
          end
        end
        local ex = v.extras or {}
        on_accept({
          bpm      = tonumber(v.bpm)  or M.DEFAULT_BPM,
          bars     = tonumber(v.bars) or M.DEFAULT_BARS,
          sections = M.parse_sections(v.sections),
          midi_items  = ex.midi_items,
          build_lanes = ex.build_lanes,
          multi_out   = ex.multi_out,
          step_seq    = ex.step_seq,
          float_swing = ex.float_swing,
        })
      end,
    })
    return
  end

  -- Fallback: no ReaImGui installed. Same three questions, REAPER's own dialog.
  local ok, csv = reaper.GetUserInputs(
    "EON: New Song", 3,
    "Tempo (BPM),Bars per section,Sections (comma separated),extrawidth=180",
    M.DEFAULT_BPM .. "," .. M.DEFAULT_BARS .. ","
      .. table.concat(M.DEFAULT_SECTIONS, " ")
  )
  if not ok then return end

  -- The section field is the LAST one, so anything after the second comma
  -- belongs to it — commas included, which parse_sections then honours.
  local bpm, bars, names = csv:match("^([^,]*),([^,]*),(.*)$")
  on_accept({
    bpm      = tonumber(bpm)  or M.DEFAULT_BPM,
    bars     = tonumber(bars) or M.DEFAULT_BARS,
    sections = M.parse_sections(names),
  })
end

return M
