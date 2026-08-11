-- EON_StepSeq_Preset_Browser.lua  --  AP-3: searchable preset browser for the StepSeq.
--
-- Companion to the in-window scroll strip (AP-2). Lists the StepSeq preset bank
-- (preset_cache.json, the same grids that build the .ini) grouped by ROLE — the
-- eon-grid-1 function-first taxonomy (MAIN / FILL / BUILD / BREAK / PERC) — with
-- genre demoted to per-entry hue + the search box. Clicking an entry applies that
-- grid to the targeted StepSeq's ACTIVE pattern.
--
-- It does NOT touch gmem grids directly -- it raises an absolute "select index" request
-- over the PCTRL band; the always-on Swing_Kit_Bridge does the apply (so the strip and
-- this panel share ONE flat index + one apply path). The bridge must be running.
--
-- TARGET SLOT: defaults to 0 = an UNPAIRED StepSeq. Use the Slot stepper to target a
-- StepSeq paired to a Swing (its slot = pair number - 1).

local r = reaper

if not r.ImGui_CreateContext then
  r.ShowMessageBox('EON StepSeq Preset Browser requires ReaImGui (install via ReaPack).',
                   'EON Preset Browser', 0)
  return
end

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

-- Resolve a bundle-relative file, de-dotting a .Scripts/ runtime dir to its Scripts/ twin.
local function resolve(rel)
  local base = SCRIPT_DIR:gsub('[/\\]+', '/'):gsub('/+$', '')
  local bases = { base, base:gsub('/%.Scripts$', '/Scripts') }
  for _, b in ipairs(bases) do
    local p = b .. '/' .. rel
    local f = io.open(p, 'r')
    if f then f:close(); return p end
  end
  return base .. '/' .. rel
end

local json
do
  local ok, m = pcall(dofile, resolve('EON/Drum Matrix/lib/json.lua'))
  if ok then json = m end
end

-- Role taxonomy (eon-grid-1 `role`; see PatternLibrary/FORMAT.md). Groups render
-- in this fixed order. Caches built before the role field ship without it — the
-- LABEL fallback below re-derives it so old caches still group correctly.
local ROLE_ORDER = { 'main', 'fill', 'build', 'break', 'perc' }
local ROLE_LABEL = { ['main'] = 'MAIN', ['fill'] = 'FILL', ['build'] = 'BUILD',
                     ['break'] = 'BREAK', ['perc'] = 'PERC' }
local ROLE_COL   = { ['main'] = 0x7FD07FFF, ['fill'] = 0xF0C060FF, ['build'] = 0xF07A45FF,
                     ['break'] = 0x8FB8F0FF, ['perc'] = 0xB98BEAFF }
local ROLE_FROM_LABEL = {                          -- mirrors gen/content.py ROLE_BY_LABEL
  ['Main A'] = 'main', ['Main B'] = 'main', ['Fill'] = 'fill', ['Rolls'] = 'build',
  ['Breakdown'] = 'break', ['Stripped'] = 'break',
  ['Open Hats'] = 'perc', ['Percussion'] = 'perc',
}

-- Build the SAME flat list (preset x variation, in order) the bridge builds, so a row's
-- index here equals the bridge's flat index. Grouping is DISPLAY-ONLY on top of it.
local flat   = {}            -- idx-ordered (matches the bridge) for follow-current lookup
local groups = {}            -- ordered { {role=, entries={<flat refs>}} } per ROLE_ORDER
local gmap   = {}
for _, role in ipairs(ROLE_ORDER) do
  local grp = { role = role, entries = {} }
  gmap[role] = grp; groups[#groups + 1] = grp
end
if json and json.decode then
  local f = io.open(resolve('EON/PatternLibrary/preset_cache.json'), 'r')
  if f then
    local txt = f:read('*a'); f:close()
    local ok, data = pcall(json.decode, txt)
    if ok and type(data) == 'table' and data.presets then
      for _, p in ipairs(data.presets) do
        local g = p.genre or '?'
        -- FEEL facet (one vocabulary everywhere: Straight / Swung / Triplet).
        -- Grid trumps timing: a triplet GRID is Triplet; else swing>0 = Swung.
        local spb = p.steps_per_beat or 4
        local feel = (spb % 3 == 0) and 'Triplet'
          or (((p.swing or 0) > 0 or (p.hat_swing or 0) > 0) and 'Swung' or 'Straight')
        for _, v in ipairs(p.variations or {}) do
          local role = v.role or ROLE_FROM_LABEL[v.label or ''] or 'main'
          if not gmap[role] then role = 'main' end
          local e = {
            idx   = #flat,                          -- 0-based, matches the bridge
            genre = g,
            role  = role,
            feel  = feel,
            -- Triplet-grid rows carry the badge in the row text itself (also
            -- makes them findable by typing "triplet" in the search box).
            full  = (p.name or '?') .. ' - ' .. (v.label or '?')
                    .. (feel == 'Triplet' and spb ~= 4 and '  [Triplet]' or ''),
          }
          flat[#flat + 1] = e
          gmap[role].entries[#gmap[role].entries + 1] = e
        end
      end
    end
  end
end

if #flat == 0 then
  -- Customer-facing: the library file simply is not on disk (or is unreadable).
  -- The old text told customers to run gen_presets.py -- a dev tool that does
  -- not ship (and whose absence was itself the bug: preset_cache.json was in
  -- no manifest until 2026-08-11).
  r.ShowMessageBox('The preset library is missing or empty.\n\n'
    .. 'Reinstall Swing to restore it (ReaPack: Extensions > ReaPack >\n'
    .. 'Browse packages > right-click Swing > Reinstall), then restart REAPER.',
    'EON Preset Browser', 0)
  return
end

-- A hue per genre (0xRRGGBBAA) for the dropdown headers + the now-playing line.
local GENRE_COL = {
  ['Trap'] = 0xF07A45FF, ['Hip-Hop'] = 0x4FC9B0FF, ['RnB'] = 0xB98BEAFF,
  ['Boom-Bap'] = 0xE6B84FFF, ['House'] = 0x5BA8F0FF, ['Techno'] = 0xC0C6D0FF,
  ['Dnb'] = 0xF05B7AFF, ['Pop'] = 0xF0A0D8FF,
  -- feel-card genre expansion (2026-07): every shipping genre gets a hue —
  -- fallback gray reads as "broken", not "neutral".
  ['Drill'] = 0x8A93A6FF, ['Dubstep'] = 0x7A5BF0FF, ['Future Bass'] = 0x64D8F0FF,
  ['Disco'] = 0xF0C43FFF, ['Funk'] = 0xE8783CFF, ['Jazz'] = 0x4A7CF0FF,
  ['Reggaeton'] = 0xF05B45FF, ['Dancehall'] = 0x58C858FF, ['Latin'] = 0xE84C88FF,
  ['Amapiano'] = 0xE8D24AFF, ['Afrobeats'] = 0x48C89AFF, ['Reggae'] = 0xF0A43CFF,
  ['Trance'] = 0x5BE8D8FF, ['Jersey Club'] = 0xF078B8FF, ['Footwork'] = 0xB8E84CFF,
  ['Gospel'] = 0xC89AF0FF,
}
local function gcol(g) return GENRE_COL[g] or 0xAEB6C2FF end

r.gmem_attach('Swing_Media_Transfer')
local PB, PS = 26045000, 64        -- EON_SS_PCTRL_BASE / STRIDE (must match the JSFX/bridge)
local BROWSER_ALIVE, BROWSER_SLOT = 26046101, 26046102
local BROWSER_CLOSE = 26046103     -- bridge bumps this on a toggle-while-open -> we quit

local ctx      = r.ImGui_CreateContext('EON StepSeq Presets')
local filter   = ''
local close_seq = math.floor((r.gmem_read(BROWSER_CLOSE) or 0) + 0.5)  -- baseline stale close bumps
-- Genre filter chips: ordered list of genres as they appear in the cache; empty
-- selection = show all. Clicking a chip toggles it; ALL clears.
local genres, gseen, gsel, gsel_n = {}, {}, {}, 0
for _, e in ipairs(flat) do
  if not gseen[e.genre] then gseen[e.genre] = true; genres[#genres + 1] = e.genre end
end
-- Default the target slot to whatever the JSFX strip passed when it asked to open us
-- (so right-clicking a paired StepSeq opens us on its slot). Clamp 0..15.
local slot     = math.max(0, math.min(15, math.floor((r.gmem_read(BROWSER_SLOT) or 0) + 0.5)))
local sel_idx  = -1
local last_cur = -1     -- last CUR_IDX seen from the bridge (to follow the strip / scroll once)
-- Seed our select counter from the current gmem value so a fresh launch can't collide
-- with a stale request the bridge already consumed.
local selseq  = math.floor((r.gmem_read(PB + 0 * PS + 5) or 0) + 0.5)

local function select_entry(e)
  sel_idx = e.idx
  selseq  = selseq + 1
  local nb = PB + slot * PS
  r.gmem_write(nb + 6, e.idx)     -- SELECT_IDX
  r.gmem_write(nb + 5, selseq)    -- SELECT_SEQ (bump LAST -> bridge edge-detects)
end

-- FEEL filter chips (Straight / Swung / Triplet) — same toggle model as genres.
local FEELS = { 'Straight', 'Swung', 'Triplet' }
local FEEL_COL = { Straight = 0xAEB6C2FF, Swung = 0xE6B84FFF, Triplet = 0x64D8F0FF }
local fsel, fsel_n = {}, 0
-- SECTION filter chips (the role facet: MAIN/FILL/BUILD/BREAK/PERC) — same model.
local rsel, rsel_n = {}, 0

-- An entry passes when it survives the genre, section and feel chips AND the
-- text filter: OR within a facet, AND across facets (empty facet = pass-all).
local function entry_visible(e, lf)
  if gsel_n > 0 and not gsel[e.genre] then return false end
  if rsel_n > 0 and not rsel[e.role] then return false end
  if fsel_n > 0 and not fsel[e.feel] then return false end
  return lf == '' or e.full:lower():find(lf, 1, true) ~= nil
end

-- ── Wrapped chip-flow helpers ────────────────────────────────────────────────
-- Chips wrap to as many rows as the CURRENT panel width needs (the one-row
-- SameLine chain was why the panel only worked at full width). Width accounting
-- is manual — measure label + frame padding, track the row fill — so it uses
-- only ReaImGui calls this script's baseline already has (no GetItemRect*).
local chip_row_w, chip_x_used = 0, 0
local function chip_row_begin()
  chip_row_w  = select(1, r.ImGui_GetContentRegionAvail(ctx))
  chip_x_used = 0
end
local function chip_place(vis)   -- vis = VISIBLE label only (ids carry ##tags)
  local sp = select(1, r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_ItemSpacing()))
  local fp = select(1, r.ImGui_GetStyleVar(ctx, r.ImGui_StyleVar_FramePadding()))
  local w  = select(1, r.ImGui_CalcTextSize(ctx, vis)) + 2 * fp
  if chip_x_used > 0 and chip_x_used + sp + w <= chip_row_w then
    r.ImGui_SameLine(ctx)
    chip_x_used = chip_x_used + sp + w
  else
    chip_x_used = w                -- wrap: new line, this chip starts the row
  end
end
-- One filter pill. Lit = hue-tinted bg + white text (unambiguously CHECKED —
-- the old text-dim-only state read as decoration); off = dimmed hue text.
local function chip(vis, id, on, hue)
  chip_place(vis)
  r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(),
    on and 0xFFFFFFFF or ((hue & 0xFFFFFF00) | 0x66))
  if on then
    r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(), (hue & 0xFFFFFF00) | 0x50)
  end
  local clicked = r.ImGui_SmallButton(ctx, vis .. id)
  if on then r.ImGui_PopStyleColor(ctx) end
  r.ImGui_PopStyleColor(ctx)
  return clicked
end
local GENRE_COLLAPSE_W = 340   -- below this avail width, genre chips collapse
                               -- to a Genres ▾ button + stay-open checkbox popup


local function frame()
  -- Toggle-close: the bridge bumps CLOSE_REQ when the strip is clicked while
  -- we're alive. Stop deferring = close (context is garbage-collected).
  local creq = math.floor((r.gmem_read(BROWSER_CLOSE) or 0) + 0.5)
  if creq ~= close_seq then return end
  r.gmem_write(BROWSER_ALIVE, r.time_precise())   -- heartbeat: bridge won't double-launch us
  r.ImGui_SetNextWindowSize(ctx, 380, 520, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'EON StepSeq Presets', true)
  if visible then
    -- Search box (target instance is set automatically from however the browser was opened).
    r.ImGui_SetNextItemWidth(ctx, -1)
    local chg, txt = r.ImGui_InputTextWithHint(ctx, '##filter', 'search presets…', filter)
    if chg then filter = txt end
    -- ── Filter facets: Genres (wrapped / collapsed) · Sections · Feel ────────
    -- Every chip is a multi-select toggle: OR within a facet, AND across facets.
    chip_row_begin()
    if chip_row_w < GENRE_COLLAPSE_W then
      -- Narrow panel: 20+ genre chips can't earn their rows — collapse to one
      -- button + a stay-open checkbox popup (Checkbox never auto-closes it).
      local lbl = (gsel_n == 0) and 'Genres: ALL \u{25BE}'
                                or ('Genres: ' .. gsel_n .. ' \u{25BE}')
      chip_place(lbl)
      if r.ImGui_SmallButton(ctx, lbl .. '###genres_btn') then
        r.ImGui_OpenPopup(ctx, 'genres_pop')
      end
      if r.ImGui_BeginPopup(ctx, 'genres_pop') then
        local all_on = (gsel_n == 0)
        local ac, av = r.ImGui_Checkbox(ctx, 'ALL', all_on)
        if ac and av and not all_on then gsel = {}; gsel_n = 0 end
        r.ImGui_Separator(ctx)
        for _, g in ipairs(genres) do
          local on = gsel[g] and true or false
          r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), gcol(g))
          local cc, cv = r.ImGui_Checkbox(ctx, g, on)
          r.ImGui_PopStyleColor(ctx)
          if cc then
            if cv then gsel[g] = true; gsel_n = gsel_n + 1
            else gsel[g] = nil; gsel_n = gsel_n - 1 end
          end
        end
        r.ImGui_EndPopup(ctx)
      end
    else
      if chip('ALL', '##gall', gsel_n == 0, 0xAEB6C2FF) then gsel = {}; gsel_n = 0 end
      for _, g in ipairs(genres) do
        local on = gsel[g] and true or false
        if chip(g, '##chip', on, gcol(g)) then
          if on then gsel[g] = nil; gsel_n = gsel_n - 1
          else gsel[g] = true; gsel_n = gsel_n + 1 end
        end
      end
    end
    -- Sections + feel share one wrapped flow (5 + 3 chips, wraps only when tiny).
    chip_row_begin()
    for _, role in ipairs(ROLE_ORDER) do
      local on = rsel[role] and true or false
      if chip(ROLE_LABEL[role] or role, '##sec', on, ROLE_COL[role] or 0xAEB6C2FF) then
        if on then rsel[role] = nil; rsel_n = rsel_n - 1
        else rsel[role] = true; rsel_n = rsel_n + 1 end
      end
    end
    chip_place('·')
    r.ImGui_TextColored(ctx, 0x555F6AFF, '·')
    for _, f in ipairs(FEELS) do
      local on = fsel[f] and true or false
      if chip(f, '##feel', on, FEEL_COL[f]) then
        if on then fsel[f] = nil; fsel_n = fsel_n - 1
        else fsel[f] = true; fsel_n = fsel_n + 1 end
      end
    end
    r.ImGui_Separator(ctx)

    -- Follow the in-window strip: the bridge publishes the active flat index in PCTRL+2.
    -- When it changes (strip scroll or our own click), highlight + scroll to it once.
    local cur = math.floor((r.gmem_read(PB + slot * PS + 2) or -1) + 0.5)
    local do_scroll = false
    if cur ~= last_cur then last_cur = cur; sel_idx = cur; do_scroll = true end

    -- Now-playing line in the active genre's colour.
    local cure = (cur >= 0 and flat[cur + 1]) or nil
    r.ImGui_TextColored(ctx, cure and gcol(cure.genre) or 0xAEB6C2FF,
      'Now: ' .. (cure and cure.full or '(none)'))
    r.ImGui_Separator(ctx)

    local lf = filter:lower()
    for _, grp in ipairs(groups) do
      -- Count this role's matches under the chips + text filter — the header
      -- number is the LIVE visible count, and headers never force-open/close:
      -- collapse state is always the user's.
      local nvis = 0
      for _, e in ipairs(grp.entries) do
        if entry_visible(e, lf) then nvis = nvis + 1 end
      end
      if nvis > 0 then
        r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), ROLE_COL[grp.role] or 0xAEB6C2FF)
        local hdr = string.format('%s (%d)###role_%s', ROLE_LABEL[grp.role] or grp.role,
          nvis, grp.role)
        local hdr_open = r.ImGui_CollapsingHeader(ctx, hdr)
        r.ImGui_PopStyleColor(ctx)
        if hdr_open then
          for _, e in ipairs(grp.entries) do
            if entry_visible(e, lf) then
              r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Text(), gcol(e.genre))
              if r.ImGui_Selectable(ctx, e.full .. '##' .. e.idx, sel_idx == e.idx) then
                select_entry(e)
              end
              r.ImGui_PopStyleColor(ctx)
              if do_scroll and e.idx == cur and r.ImGui_SetScrollHereY then
                r.ImGui_SetScrollHereY(ctx, 0.5)
              end
            end
          end
        end
      end
    end
    r.ImGui_End(ctx)   -- this ReaImGui build: End ONLY when Begin returned true
  end
  -- Closing: just stop deferring; the context is garbage-collected (this ReaImGui build
  -- has no ImGui_DestroyContext). Matches the DM overlay's "don't re-arm" teardown.
  if open then r.defer(frame) end
end

r.defer(frame)
