-- @description EON: FX Picker bridge
-- @version 0.2
-- @author EON Studios
-- @about
--   Serves the FX picker's plugin list to whichever Swing instances have the
--   view open. Runs as a defer loop; toggle it off by running it again.
--
--   ITS OWN SCRIPT, not part of Swing_Kit_Bridge.lua. The bridge is the only
--   thing already ticking at the right rate, but it is ~17k lines carrying 156
--   of Lua's 200 top-level locals and is contended across concurrent sessions.
--   A picker fault should not be able to take the kit bridge down with it.
--
--   ⚠️ S2 SCOPE: publishes a window of the unfiltered registry. No query, no
--   filters, no chain, no actions — those are S3 onward. What this proves is
--   the protocol: that a Lua defer loop can fill a gmem band a JSFX @gfx can
--   read without tearing.

local NL = string.char(10)
local SEG = "Swing_Media_Transfer"

-- Must match the constants in Swing_ReaKit.jsfx. Declared in
-- .refs/gmem_regions_supplement.tsv before either side touched the band.
local BASE, STRIDE, SLOTS = 26345472, 4096, 16

local PUB_SEQ, GEN, ANS_REQ = 0, 1, 2
local TOTAL, WIN_OFF, WIN_N = 5, 6, 7
local FLAGS, HB, FMT_VER    = 15, 16, 17
local REQ_SEQ, REQ_OFF, REQ_N = 64, 69, 70

-- ⚠️ 192 + 48*64 = 3264 = CHAIN, exactly as 192 + 64*48 did. Vendor needed 16
-- more words per row and the record was full, so the width came out of the row
-- COUNT rather than by growing the band. Keep this arithmetic true.
local ROWS, REC, REC_MAX = 192, 64, 48
local R_VLEN, R_VEND, VEND_MAX = 48, 49, 15
local CH_SEQ, CH_N, CH_SEL = 3, 18, 19
local TGT_LEN, TGT_NAME, TGT_NUM, TGT_COL = 20, 21, 53, 56
-- CREC is 25: word 23 carries offline, word 24 is the FACE's locally
-- resolved card and must not be published over. See FXP_CREC in the .jsfx.
local CHAIN, CREC, CHAIN_MAX = 3264, 25, 32
local C_LEN, C_NAME, C_ON, C_FMT = 0, 1, 21, 22
-- Word 23 of the 24-word record was spare. Offline was being READ from
-- REAPER and then thrown away, so the face drew offline and bypassed
-- identically -- two different states, one appearance.
local C_OFF = 23
local CNAME_MAX = 20
local ACT_ACK, ACT_SEQ, ACT_VERB, ACT_A, ACT_B = 4, 72, 73, 74, 75
local A_SWAP, A_INSERT, A_ENABLE, A_REMOVE, A_MOVE = 1, 2, 3, 4, 5
local A_EMBED_TCP, A_EMBED_MCP, A_OFFLINE = 6, 7, 8
local A_CHAIN_APPLY, A_CHAIN_SAVE, A_FLOAT = 9, 10, 11
local Q_LEN, Q, Q_MAX = 76, 77, 63
local BANK = 141
-- Kind filter: 0 = FX (everything that is NOT an instrument) · 1 = instruments
-- only · 2 = both. FX deliberately keeps midi/other/util plugins -- "not an
-- instrument" is the useful split; "exactly kind==fx" would quietly drop the
-- video processor, ReaControlMIDI and friends out of a list that had them.
-- ⚠️⚠️ DECLARED HERE, WITH THE OTHER BAND OFFSETS, because apply_query reads
-- it and apply_query is ~300 lines ABOVE where this first lived. Lua binds an
-- upvalue only if the local exists at COMPILE time; below its reader it
-- compiles to a global, and a global that is never assigned is nil -- so the
-- read became arithmetic on nil the moment anyone opened the picker. The file
-- warns about exactly this for ci_tgt, tgt_frozen and view_kf, and it caught
-- me anyway: getting view_kf right is no help if the CONSTANT is misplaced.
local KINDF = 55
local TBL, TBL_N = 26411008, 8192
local TB_N, TB_SEQ, TB, TREC, TB_MAX = 0, 1, 16, 40, 48
local TB_LEN, TB_NAME, TB_KIND, TB_BUCK, TB_COUNT = 0, 1, 25, 26, 27
local TBNAME_MAX = 24
local R_LEN, R_NAME, R_FMT, R_BUCKET, R_KIND, R_RIDX = 0, 1, 42, 43, 44, 45
local R_CHSTK = 47   -- CHAINS: packed preview of what is inside the file
local NAME_MAX = 40

local FMT_CODE = { VST = 1, VST3 = 2, JS = 3, CLAP = 4, AU = 5, LV2 = 6, DX = 7,
                   VSTi = 1, VST3i = 2, CLAPi = 4, AUi = 5, LV2i = 6, DXi = 7 }

-- ⚠️⚠️ EVERY NAME GOES THROUGH THIS BEFORE THE WIRE. The band carries one BYTE
-- per cell and the face draws one CHARACTER per cell, so anything outside plain
-- ASCII -- an em dash, a curly quote, an accent -- is 2 or 3 bytes on the way in
-- and 2 or 3 pieces of garbage on the way out. "EON Lens — artwork" arrived as
-- "EON Lens à artwork", which is what the user saw. Truncation made it worse:
-- #name counts bytes, so a 32-byte cut can land INSIDE a character.
--
-- Transliterated rather than decoded: teaching the face UTF-8 would mean
-- variable-width cells in a fixed-width record, and the face draws these one
-- glyph at a time in a dozen places. Folding to ASCII at the single point where
-- names enter the protocol fixes every one of them at once.
--
-- ⭐ SAFE FOR CARD MATCHING: the card hash already lower-cases and drops
-- non-alphanumerics, so a dash becoming a hyphen cannot change which card a
-- plugin resolves to.
local UTF8_FOLD = {
  ["\226\128\148"] = "-",  ["\226\128\147"] = "-",   -- em dash, en dash
  ["\226\128\152"] = "'",  ["\226\128\153"] = "'",   -- curly single quotes
  ["\226\128\156"] = '"',  ["\226\128\157"] = '"',   -- curly double quotes
  ["\226\128\166"] = "...",                          -- ellipsis
  ["\194\174"]     = "",   ["\226\132\162"] = "",    -- (R), (TM)
  ["\194\176"]     = "deg",["\195\151"]     = "x",   -- degree, multiply
}

local function ascii_fold(s)
  if not s or s == "" then return "" end
  for seq, rep in pairs(UTF8_FOLD) do s = s:gsub(seq, rep) end
  -- Anything still non-ASCII becomes '?', so a name can never carry a byte the
  -- face would draw as noise. A visible '?' says "a character did not survive";
  -- silent mojibake says nothing and looks like corruption.
  return (s:gsub("[\128-\255]", "?"))
end

local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
package.path = dir .. "/?.lua;" .. package.path
local ok, fx = pcall(require, "rk_lua_fxpicker")
if not ok then
  reaper.ShowConsoleMsg("FX picker bridge: could not load rk_lua_fxpicker\n"
                        .. tostring(fx) .. "\n")
  return
end

-- Toggle: a second run stops the first.
local _, _, secId, cmdId = reaper.get_action_context()
if reaper.GetExtState("EON_FXPICK", "running") == "1" then
  reaper.SetExtState("EON_FXPICK", "running", "0", false)
  return
end
reaper.SetExtState("EON_FXPICK", "running", "1", false)
reaper.gmem_attach(SEG)

local BUCKET_IX = {}
for i, b in ipairs(fx.BUCKETS) do BUCKET_IX[b] = i - 1 end
local KIND_IX = { fx = 0, instrument = 1, midi = 2, other = 3 }

-- REAPER category name -> glyph id, sent in TB_BUCK for kind-4 rows.
-- ⭐ WHERE THE MEANING GENUINELY MATCHES, IT REUSES OUR SHAPE. Dynamics IS a
-- knee, EQ IS a bell -- redrawing those as separate marks would be two glyphs
-- for one idea. Where REAPER has a concept we have no word for, 22..27 are new
-- shapes. The face draws them in a NEUTRAL ink either way, so a shared shape
-- never implies a shared vocabulary.
-- ⚠️ Lower-cased keys: the ini's capitalisation is REAPER's business.
local RCAT_GLYPH = {
  ["dynamics"] = 0,  ["eq"] = 1,        ["distortion"] = 2,  ["reverb"] = 3,
  ["delay"] = 4,     ["gate"] = 10,     ["modulation"] = 11, ["filter"] = 12,
  ["analyzer"] = 13, ["tools"] = 9,     ["utility"] = 9,     ["dither"] = 17,
  ["pitch correction"] = 7,             ["pitch shift"] = 7,
  ["synth"] = 22,    ["instrument"] = 22,
  ["sampler"] = 23,  ["external"] = 24, ["midi"] = 25,
  ["surround"] = 26, ["tuner"] = 27,
}

-- ⚠️⚠️ OUR OWN INSTRUMENT BUCKETS HAD NO GLYPH INDEX AT ALL. The rail's
-- bucket for kind 3 came from `bix`, which is built ONLY from fx.BUCKETS --
-- the 22 effect buckets. Everything in fx.INSTRUMENT_BUCKETS therefore fell to
-- the no-guess ring, so drums, keys, sfx and sampler all drew as empty circles
-- while the categories beside them had marks.
--
-- ⭐ synth, sampler and midi have had FINISHED ART since the 22..27 block was
-- drawn -- it was simply never reached, because nothing mapped a bucket NAME
-- to those numbers. Three of these five lines cost no new glyph at all.
--
-- ⚠️ 31/32 continue past 30, which is the last rail-structure mark. 22..27 are
-- REAPER's set (see RCAT_GLYPH) and 28..30 are ALL / RECENT / folder, so the
-- next free number is genuinely 31 -- reusing one would give two different
-- categories the same face.
local IBUCKET_GLYPH = {
  ["synth"] = 22, ["sampler"] = 23, ["midi"] = 25, ["drums"] = 31, ["keys"] = 32,
  -- The last four now have shapes of their own (33..36 in the .jsfx). The
  -- ring they used to borrow is the mark for UNCLASSIFIED, so "orchestral"
  -- was wearing the badge for "we could not tell" -- and drawing grey next
  -- to a rail of coloured rows, which read as disabled.
  ["orchestral"] = 33, ["world"] = 34, ["sfx"] = 35, ["other"] = 36,
}

local rows, banks = {}, {}          -- registry + the rail built from it
local view, view_q = {}, nil        -- the filtered result set
local view_bank = -1                -- selected rail row
-- ⚠️ DECLARED HERE, above apply_query which assigns it. Lua binds an upvalue
-- only if the local exists at compile time; written without this it would
-- compile to a global -- which works, right up until something else in the
-- session uses the same name. Same rule as ci_tgt and tgt_frozen below.
local view_kf = 2                   -- kind filter in force for `view`
local recent = {}                   -- MRU of inserted plugins, session-only
                                    -- (NOT rebuilt below: a retry must not
                                    --  wipe what the user already inserted)

-- ⚠️ Built in a FUNCTION rather than at load, because this script now runs as
-- a STARTUP action. When __startup.lua fires it, there is no guarantee REAPER
-- has finished enumerating plugins — and the old load-time build would have
-- cached that empty answer for the entire session, leaving every picker in
-- every Swing instance permanently blank with no error anywhere. Called once
-- immediately (so a manual run behaves exactly as it did) and retried from the
-- tick for as long as it keeps coming back with nothing.
--
-- Rail contents: ALL, RECENT, the user's FX folders, then the categories that
-- actually have members.
local function fxpick_build_registry()
  -- ⚠️⚠️ INSTRUMENTS MUST BE IN THE LIST FOR THE INST FILTER TO FILTER THEM.
  -- This was fx.registry(true), which means kinds = { fx = true } -- so the
  -- registry held NO instruments at all and the INST toggle filtered a set
  -- that could never contain one. The button looked live and did nothing.
  -- ⛔ NOT kinds = "all". The `other` kind exists to hold what is not a plugin
  -- -- documentation files, bad extensions, REAPER's own path fallbacks -- and
  -- "all" would put every one of them in the browser. fx + instrument is the
  -- set the filter actually offers.
  rows = fx.registry({ force = true,      -- force: a retry must not be served
                       kinds = { fx = true, instrument = true } })
  view, view_q, view_bank, view_kf = rows, nil, -1, 2
  banks = { { name = "ALL PLUGINS", kind = 0 },
            { name = "RECENT",      kind = 1 } }
  for _, b in ipairs(fx.banks()) do
    -- Count the folder's members now: the rail shows a count for every other
    -- kind and a blank one reads as "empty", not as "not counted".
    local n = 0
    for _, r0 in ipairs(rows) do
      if fx.in_bank(r0, b.set) then n = n + 1 end
    end
    banks[#banks + 1] = { name = b.name, kind = 2, set = b.set, n = n }
  end
  -- ⭐ REAPER'S OWN CATEGORIES, from the same file its native FX browser uses.
  -- Read ONCE per registry build, not per row: it is a file, and the registry
  -- is rebuilt rarely. Stamped onto the row so the filter below is a field
  -- compare rather than a lookup per plug-in per keystroke.
  -- The developer half also lands here, because REAPER knowing the vendor
  -- beats guessing it out of the display name -- which is what turned
  -- "ReaStream (8ch)" into a company called 8ch.
  local rcat, rdev = fx.fxtags()
  for _, r0 in ipairs(rows) do
    r0.rcat = fx.tag_lookup(rcat, r0)
    r0.rdev = fx.tag_lookup(rdev, r0)
  end
  local seen, order = {}, {}
  for _, r0 in ipairs(rows) do
    if r0.cat and r0.cat ~= "" then
      if not seen[r0.cat] then seen[r0.cat] = 0; order[#order + 1] = r0.cat end
      seen[r0.cat] = seen[r0.cat] + 1
    end
  end
  table.sort(order, function(a, b) return seen[a] > seen[b] end)
  local bix = {}
  for i, n in ipairs(fx.BUCKETS) do bix[n] = i - 1 end
  for _, c in ipairs(order) do
    banks[#banks + 1] = { name = c, kind = 3, cat = c,
                          bucket = bix[c] or IBUCKET_GLYPH[c]
                                   or (#fx.BUCKETS - 1), n = seen[c] }
  end
  -- ⛔ KIND 4, NOT MERGED INTO KIND 3. REAPER's set is coarser and differently
  -- drawn (Dynamics, Tools, External); ours says what a plug-in does at the
  -- granularity this instrument cares about. Merging would lose the
  -- distinction both ways, so they sit side by side and the user picks the
  -- vocabulary they think in.
  local rseen, rorder = {}, {}
  for _, r0 in ipairs(rows) do
    if r0.rcat and r0.rcat ~= "" then
      if not rseen[r0.rcat] then rseen[r0.rcat] = 0; rorder[#rorder + 1] = r0.rcat end
      rseen[r0.rcat] = rseen[r0.rcat] + 1
    end
  end
  table.sort(rorder, function(a, b) return rseen[a] > rseen[b] end)
  for _, c in ipairs(rorder) do
    -- 21 (the empty ring) for anything unmapped: a category we have no
    -- shape for should say so, not borrow one that means something else.
    banks[#banks + 1] = { name = c, kind = 4, rcat = c,
                          bucket = RCAT_GLYPH[c:lower()] or 21, n = rseen[c] }
  end
  return #rows > 0
end
local registry_ok = fxpick_build_registry()

-- Once per BRIDGE RUN, not once per gmem lifetime. gmem survives the script,
-- so gating on the published seq would mean a user who edits their REAPER FX
-- folders never sees the change without restarting REAPER itself -- restarting
-- the bridge would look like it did nothing.
local banks_pub = false

local function publish_banks()
  if banks_pub then return end
  banks_pub = true
  -- Continue the counter rather than restarting it: the face holds the last
  -- seq it consumed across a bridge restart, exactly as the row page does.
  local seq = math.floor((reaper.gmem_read(TBL + TB_SEQ) or 0) / 2) * 2 + 2
  reaper.gmem_write(TBL + TB_SEQ, seq - 1)                       -- ODD
  local n = math.min(TB_MAX, #banks)
  for i = 1, n do
    local b, p = banks[i], TBL + TB + (i - 1) * TREC
    local nm = ascii_fold(b.name)
    local len = math.min(TBNAME_MAX, #nm)
    reaper.gmem_write(p + TB_LEN, len)
    for c = 1, len do reaper.gmem_write(p + TB_NAME + c - 1, nm:byte(c)) end
    reaper.gmem_write(p + TB_KIND, b.kind)
    reaper.gmem_write(p + TB_BUCK, b.bucket or -1)
    reaper.gmem_write(p + TB_COUNT, b.n or 0)
  end
  reaper.gmem_write(TBL + TB_N, n)
  reaper.gmem_write(TBL + TB_SEQ, seq)                           -- SEQ LAST
end
local last_req = {}                 -- per slot, the REQ_SEQ we last answered
local pub_seq  = {}

-- Re-run the search only when the query text actually changed. The face
-- debounces to one post per 4 frames, but it re-posts on every scroll too, and
-- filtering 882 rows per tick for an unchanged query would be pure waste.
-- ⭐ CHAINS mode fills the SAME `view` the plugin list uses. A chain file is
-- just a row that happens to be a file, so publish(), paging, scrolling and the
-- face's row renderer all work unchanged. A parallel channel would have been a
-- second copy of every one of those, kept in step by hand.
--
-- One folder level plus a breadcrumb, never a recursive walk: the spec's rail
-- is "top-level + breadcrumb; no expand-triangle tree widget", and a recursive
-- listing of someone's FXChains folder is unbounded work for a view that only
-- ever shows one level.
local CHMODE, CHREL_LEN, CHREL, CHREL_MAX = 145, 146, 147, 40
local K_CHAIN, K_FOLDER = 4, 5
local ch_rel = {}          -- per slot, the folder currently being listed

local function read_rel(b)
  local n = math.floor(reaper.gmem_read(b + CHREL_LEN) or 0)
  n = math.max(0, math.min(CHREL_MAX, n))
  if n == 0 then return "" end
  local t = {}
  for i = 0, n - 1 do
    t[#t + 1] = string.char(math.floor(reaper.gmem_read(b + CHREL + i) or 32) % 256)
  end
  -- ⚠️ The face sends "/" always; translate to this platform's separator.
  -- The engine joins with package.config's, so a raw "/" would break the
  -- lookup on any host where that is not the separator -- and it would fail
  -- as an EMPTY folder rather than as an error.
  local sep = package.config and package.config:sub(1, 1) or "/"
  return (table.concat(t):gsub("/", sep))
end

-- Look INSIDE a .RfxChain and report what it holds: up to four category
-- indices plus a total. REPLACE WHOLE CHAIN overwrites what you have, and
-- without this you are choosing blind from a list of filenames.
--
-- ⚠️ <JS_SER is a SERIALISATION block, not a plugin. A naive "<TAG" match
-- counts it and every chain reads two or three plugins heavier than it is.
-- The `%u[%u%d]*` then `%s+` pattern excludes it: after JS the next character
-- is an underscore, which is neither, so the whole match fails.
--
-- Two spellings for the name, both real, from an actual chain file:
--   <JS "zenomod_VU Meter (ZenoMOD).jsfx" ""      -- quoted
--   <JS EON_ReaKit_Bundle/EON/Eon_JSFX/Spice.jsfx ""  -- bare path
local CH_TAGS = { VST = 1, VST3 = 1, AU = 1, AUi = 1, CLAP = 1, LV2 = 1,
                  DX = 1, JS = 1 }
local ch_peek_cache = {}

local function chain_peek(rel)
  if ch_peek_cache[rel] then return ch_peek_cache[rel] end
  local sep = package.config and package.config:sub(1, 1) or "/"
  local out = { cats = {}, n = 0 }
  local f = io.open(fx.chain_dir() .. sep .. rel, "r")
  if not f then ch_peek_cache[rel] = out; return out end
  for line in f:lines() do
    local tag, rest = line:match("^%s*<(%u[%u%d]*)%s+(.*)$")
    if tag and CH_TAGS[tag] then
      local nm = rest:match('^"([^"]*)"') or rest:match("^(%S+)")
      if nm and nm ~= "" then
        -- A JS entry is a PATH; the basename is the only recognisable part.
        nm = nm:match("([^/\\]+)$") or nm
        nm = nm:gsub("%.jsfx$", ""):gsub("%.dll$", ""):gsub("%.vst3$", "")
        out.n = out.n + 1
        if #out.cats < 4 then
          out.cats[#out.cats + 1] = BUCKET_IX[fx.category(nm)] or 21
        end
      end
    end
  end
  f:close()
  ch_peek_cache[rel] = out
  return out
end

local function build_chain_view(rel)
  local L = fx.chain_list(rel)
  local out = {}
  -- Folders first, then chains. A listing that interleaves them makes you read
  -- every row to find out which is which.
  for _, d in ipairs(L.dirs or {}) do
    out[#out + 1] = { name = d.name, disp = d.name, vendor = "", fmt = "",
                      kind = "folder", kindix = K_FOLDER, rel = d.rel, cat = "" }
  end
  for _, f in ipairs(L.files or {}) do
    local pk = chain_peek(f.rel)
    -- Packed by MULTIPLICATION; the face unpacks by division. EEL2 shifts
    -- are 32-bit with the count masked mod 32 and this reaches ~32.5M.
    local stk = (pk.cats[1] or 31)
             + (pk.cats[2] or 31) * 32
             + (pk.cats[3] or 31) * 1024
             + (pk.cats[4] or 31) * 32768
             + math.min(31, pk.n) * 1048576
    out[#out + 1] = { name = f.name, disp = f.name, vendor = "", fmt = "",
                      kind = "chain", kindix = K_CHAIN, rel = f.rel, cat = "",
                      chstk = stk }
  end
  return out
end

local function apply_query(b, slot)
  local ql = math.floor(reaper.gmem_read(b + Q_LEN) or 0)
  ql = math.max(0, math.min(Q_MAX, ql))
  local t = {}
  for i = 0, ql - 1 do
    t[#t + 1] = string.char(math.floor(reaper.gmem_read(b + Q + i) or 32) % 256)
  end
  local q = table.concat(t)
  local bk = math.floor(reaper.gmem_read(b + BANK) or -1)

  -- CHAINS mode short-circuits the whole plugin path. The cache key has to
  -- include the FOLDER as well as the query, or navigating into a subfolder
  -- with the search box untouched would look like nothing happened.
  local chm = math.floor(reaper.gmem_read(b + CHMODE) or 0)
  if chm == 1 then
    local rel = read_rel(b)
    -- Remember the folder: SAVE writes into whatever you are browsing, so
    -- "save here" has to mean the folder actually on screen.
    ch_rel[slot] = rel
    local key = "CH" .. rel .. "" .. q
    if key == view_q then return end
    view_q, view_bank = key, -1
    view = build_chain_view(rel)
    if q ~= "" then
      local keep, lq = {}, q:lower()
      for _, r0 in ipairs(view) do
        if r0.name:lower():find(lq, 1, true) then keep[#keep + 1] = r0 end
      end
      view = keep
    end
    return
  end

  -- ⚠️ THE KIND FILTER IS PART OF THE CACHE KEY. Without it, flipping FX or
  -- INST with the query and bank untouched hits this early return and the list
  -- never changes -- the toggle would look dead. Same lesson the CHAINS folder
  -- taught a few lines up.
  local kf = math.floor(reaper.gmem_read(b + KINDF) or 2)
  if q == view_q and bk == view_bank and kf == view_kf then return end
  view_q, view_bank, view_kf = q, bk, kf

  local sel = banks[bk + 1]
  if sel and sel.kind == 1 then
    -- RECENT is a list the bridge keeps, not a filter over the registry.
    view = {}
    for _, nm in ipairs(recent) do
      for _, r0 in ipairs(rows) do
        if r0.disp == nm then view[#view + 1] = r0 break end
      end
    end
    if q ~= "" then
      local keep = {}
      for _, r0 in ipairs(view) do
        if r0.key:find(q:lower(), 1, true) then keep[#keep + 1] = r0 end
      end
      view = keep
    end
  elseif sel and sel.kind == 2 then
    view = fx.search(q, { bank = sel.set })
  elseif sel and sel.kind == 3 then
    view = fx.search(q, { cat = sel.cat })
  elseif sel and sel.kind == 4 then
    -- REAPER's own category. Filtered HERE rather than through fx.search,
    -- which knows our vocabulary and nothing about REAPER's.
    local base = (q == "") and rows or fx.search(q)
    view = {}
    for _, r0 in ipairs(base) do
      if r0.rcat == sel.rcat then view[#view + 1] = r0 end
    end
  else
    view = (q == "") and rows or fx.search(q)
  end

  -- Kind filter, applied LAST so it narrows whatever the bank and the query
  -- already produced -- every branch above feeds through it, including RECENT.
  if kf ~= 2 then
    local keep = {}
    for _, r0 in ipairs(view) do
      local isinst = (r0.kind == "instrument")
      if (kf == 1) == isinst then keep[#keep + 1] = r0 end
    end
    view = keep
  end
end

-- ⚠️ DECLARED ABOVE publish(), which READS them. Lua binds an upvalue only
-- if the local exists at compile time; below it, these compile to global
-- lookups and nil at runtime. Same trap as ci_tgt earlier this session --
-- caught here by sweeping for it rather than by a user hitting it.
-- Both are stashed by publish_chain, never read live from publish().
local tgt_frozen = {}   -- per slot: is the target track frozen
local tgt_none   = {}   -- per slot: there is no target track at all

local function publish(slot, off, n, answering)
  local b = BASE + slot * STRIDE
  local total = #view
  off = math.max(0, math.min(math.max(0, total - 1), math.floor(off or 0)))
  n   = math.max(0, math.min(REC_MAX, math.floor(n or 0)))
  if off + n > total then n = math.max(0, total - off) end

  -- Seed from the BAND, not from zero. Stopping and restarting this script is
  -- the documented way to toggle it, and a restart makes fresh locals -- so
  -- counting from 1 republishes with a seq the face has ALREADY consumed. The
  -- face sees s1 == _fxv_seen, skips the snapshot, and sits on pre-restart rows
  -- for good, while the heartbeat cheerfully says "bridge live". A seqlock only
  -- works if its counter never goes backwards; gmem is where that memory lives.
  pub_seq[slot] = pub_seq[slot]
                  or math.floor((reaper.gmem_read(b + PUB_SEQ) or 0) / 2)

  -- ODD first: the seqlock's "I am mid-write" state. The face reads the seq,
  -- the body, then the seq again -- an odd or changed value means discard.
  pub_seq[slot] = pub_seq[slot] + 1
  local seq = pub_seq[slot] * 2          -- keep it even at rest
  reaper.gmem_write(b + PUB_SEQ, seq - 1)

  for i = 0, n - 1 do
    local r = view[off + i + 1]
    local p = b + ROWS + i * REC
    local name = ascii_fold(r.name)
    local len = math.min(NAME_MAX, #name)
    reaper.gmem_write(p + R_LEN, len)
    for c = 1, len do
      reaper.gmem_write(p + R_NAME + c - 1, name:byte(c))
    end
    -- Vendor. Parsed by the registry since P1 and discarded at the wire until
    -- now; the face draws it only when the user asks for it.
    local vend = ascii_fold(r.rdev or r.vendor)
    local vlen = math.min(VEND_MAX, #vend)
    reaper.gmem_write(p + R_VLEN, vlen)
    for c = 1, vlen do
      reaper.gmem_write(p + R_VEND + c - 1, vend:byte(c))
    end
    reaper.gmem_write(p + R_FMT,    FMT_CODE[r.fmt] or 0)
    -- ⚠️⚠️ SAME FALLBACK CHAIN AS THE RAIL. BUCKET_IX is built from
    -- fx.BUCKETS alone, so every instrument row -- synth, drums, keys,
    -- sampler -- resolved to 21 here: a grey pip and, because the face's
    -- bucket_name also stopped at 20, no word beside it. The rail had
    -- already been taught IBUCKET_GLYPH; the LIST never was.
    reaper.gmem_write(p + R_BUCKET, BUCKET_IX[r.cat] or IBUCKET_GLYPH[r.cat]
                                    or (#fx.BUCKETS - 1))
    -- r.kindix is set only by the chain builder. Chains continue the same
    -- 0..3 kind space (4 = chain file, 5 = folder) rather than overloading
    -- one of the plugin kinds, so the face can tell them apart by kind alone.
    reaper.gmem_write(p + R_KIND,   r.kindix or KIND_IX[r.kind] or 0)
    reaper.gmem_write(p + R_RIDX,   off + i)
    -- CHAINS only. 31 in a slot means "no plugin here", which is outside
    -- the 0..21 bucket range and so cannot be mistaken for a category.
    reaper.gmem_write(p + R_CHSTK,  r.chstk or 0)
  end
  -- Blank the tail so a shorter page cannot leave the previous one's rows
  -- showing underneath it.
  for i = n, REC_MAX - 1 do
    reaper.gmem_write(b + ROWS + i * REC + R_LEN, 0)
  end

  reaper.gmem_write(b + TOTAL,   total)
  reaper.gmem_write(b + WIN_OFF, off)
  reaper.gmem_write(b + WIN_N,   n)
  reaper.gmem_write(b + ANS_REQ, answering or 0)
  -- bit0 frozen, bit1 no EnumInstalledFX, bit2 no target. bit0 was declared
  -- in the .jsfx from the start and never written -- the face has been
  -- reading a flag nobody set.
  reaper.gmem_write(b + FLAGS,
    (tgt_frozen[slot] and 1 or 0)
    + (reaper.EnumInstalledFX and 0 or 2)
    + (tgt_none[slot] and 4 or 0))
  reaper.gmem_write(b + FMT_VER, 1)
  reaper.gmem_write(b + GEN,     (pub_seq[slot]))
  -- PAYLOAD FIRST, SEQ LAST. Even = stable.
  reaper.gmem_write(b + PUB_SEQ, seq)
end

-- The chain publishes on its OWN seqlock and only when it actually changed:
-- the target track can change, or FX can be added in REAPER\'s own window,
-- neither of which bumps REQ_SEQ. A fingerprint keeps that to one string
-- compare per tick instead of 768 gmem writes.
local ch_fp = {}

local last_act = {}

-- Run one mutation. Every verb goes through the engine, which already wraps a
-- single Undo_BeginBlock/EndBlock per gesture -- so a swap is ONE ctrl-Z that
-- restores the previous plugin at the same position with its settings.
-- ⛔ Nothing here may touch Swing's own dirty counters: this belongs in
-- REAPER's undo stack, not Swing's.
-- Fire REAPER's "Show last focused FX embedded UI in TCP/MCP" action on one
-- FX. Ported from Swing_Kit_Bridge.lua's CMD 90/91, which proved the technique
-- on Swing's own instance; it never depended on the FX being Swing, so pointing
-- it at a pad's insert is the same two steps.
--
-- ⚠️ There is NO API for embedding. The whole TrackFX named-config-parm list
-- has no key for it in either direction, which is also why the menu draws this
-- as an action rather than a checkbox. SetTrackStateChunk would reach the flag
-- but rebuilds the FX chain, and on a pad track that means a cold-start.
--
-- ⚠️ The action is a TOGGLE and there is no readback, so firing it on an FX
-- that is already embedded un-embeds it. That is REAPER's behaviour, not a bug
-- we can paper over from here.
local function embed_fx(tr, fxi, want_tcp)
  if not reaper.CF_EnumerateActions then
    reaper.ShowConsoleMsg("[EON] Embed needs SWS (CF_EnumerateActions). "
      .. "Embed it from the FX chain's right-click menu instead." .. NL)
    return
  end
  reaper.TrackFX_SetNamedConfigParm(tr, fxi, "focused", "1")
  local want = want_tcp and "in TCP" or "in MCP"
  local i = 0
  -- Bounded: the enumeration ends on a 0 id, but never trust an external API
  -- to terminate a while-true.
  while i < 30000 do
    local cid, nm = reaper.CF_EnumerateActions(0, i, "")
    if not cid or cid == 0 then break end
    -- Both halves matter: "Show next single FX embedded UI in TCP" also
    -- contains "in TCP" and is a different action entirely.
    if nm and nm:find("Show last focused FX embedded UI ", 1, true)
          and nm:find(want, 1, true) then
      reaper.Main_OnCommand(cid, 0)
      return
    end
    i = i + 1
  end
end

-- ⚠️ TAKES THE SLOT. This used to resolve its own track with
-- GetLastTouchedTrack(), which was fine while every action came from the
-- picker looking at that same track -- and became a live hazard the moment a
-- console strip could fire Delete at a pad's chain. It would have deleted from
-- whatever REAPER happened to touch last.
-- ⚠️ DECLARED HERE, above do_action, not beside consume_target where it is
-- used next. Lua binds an upvalue only if the local exists at COMPILE time:
-- declared later, do_action's reference compiled to a GLOBAL lookup and
-- blew up at runtime with "attempt to index a nil value (global 'ci_tgt')"
-- the first time anyone clicked a menu item. Nothing warns; it parses fine.
local ci_tgt, ci_tgt_seq, ci_pads = {}, {}, {}

-- PIN: the face asks the picker to HOLD its current target instead of drifting
-- with REAPER's last-touched track. ci_pin latches the track that was showing
-- when the pin went on, and is dropped the moment the pin clears -- or the
-- moment the pointer goes stale, because a pinned track can still be deleted.
--
-- ⚠️⚠️ THESE TWO LIVED AT THE OLD publish_chain, ~130 LINES BELOW do_action --
-- the exact trap the note above this block warns about, walked into a second
-- time. do_action could not see ci_pin at compile time, so it never consulted
-- it: the page DREW the pinned track's chain while every action fired at
-- GetLastTouchedTrack instead. With PIN on, clicking a card floated nothing,
-- or floated a stranger's plugin. Nothing errors -- the two paths just quietly
-- disagree about what "this track" means.
local TGT_PIN = 54
local ci_pin = {}

-- ⭐ ONE resolver, so drawing and acting can never aim at different tracks.
-- ci_tgt still wins: aiming at a console slot is an EXPLICIT choice and a pin
-- must not out-rank the thing the user just clicked. The pin only displaces
-- the last-touched fallback, which is the drift it exists to stop.
local function resolve_target(slot)
  local tr = ci_tgt[slot] or ci_pin[slot] or reaper.GetLastTouchedTrack()
  if tr and not reaper.ValidatePtr2(0, tr, "MediaTrack*") then return nil end
  return tr
end

-- ⚠️ A FROZEN track's FX chain is not editable in any meaningful sense --
-- REAPER has rendered it and taken the plugins offline. Swapping or
-- deleting there edits something the audio no longer comes from, so the
-- change appears to do nothing and is silently lost on unfreeze.
--
-- There is no I_FROZEN accessor; the track CHUNK is the only honest source,
-- and a frozen track carries a <FREEZE block. Read only on the paths that
-- already run at low frequency -- a republish or an action -- never per
-- tick, because the chunk of a loaded track is not small.
local function track_frozen(tr)
  if not tr or not reaper.GetTrackStateChunk then return false end
  local ok, chunk = reaper.GetTrackStateChunk(tr, '', false)
  return (ok and chunk and chunk:find('<FREEZE', 1, true)) and true or false
end

local function do_action(slot, verb, a, bnum)
  -- ⚠️ THE SAME RESOLVER THE PUBLISH USES. Acting on a different track than
  -- the one on screen is not a wrong result, it is an invisible one.
  local tr = resolve_target(slot)
  if not tr then return end
  -- FLOAT and EMBED only LOOK at a plugin, so they stay allowed on a frozen
  -- track. Everything else CHANGES the chain and is refused: the edit would
  -- not be what you hear, and would vanish on unfreeze.
  if verb ~= A_FLOAT and verb ~= A_EMBED_TCP and verb ~= A_EMBED_MCP
     and track_frozen(tr) then
    reaper.ShowConsoleMsg('[EON] That track is FROZEN -- its FX chain cannot '
      .. 'be edited until you unfreeze it.' .. NL)
    return
  end
  if verb == A_FLOAT then
    -- ⭐ TOGGLE, not just open. Clicking the same plugin again closes its
    -- window, which is what a click on an already-open thing means -- and
    -- without it there is no way to dismiss the float from the face at all.
    --
    -- GetFloatingWindow is the precise question ("is it floating RIGHT NOW"),
    -- and it is the one that matters: TrackFX_GetOpen also returns true for an
    -- FX merely selected in the chain window, so toggling on that would refuse
    -- to open a float for a plugin whose chain window happens to be up.
    local open = false
    if reaper.TrackFX_GetFloatingWindow then
      open = reaper.TrackFX_GetFloatingWindow(tr, a) ~= nil
    elseif reaper.TrackFX_GetOpen then
      open = reaper.TrackFX_GetOpen(tr, a)
    end
    reaper.TrackFX_Show(tr, a, open and 2 or 3)   -- 2 = hide float, 3 = show
    return
  elseif verb == A_EMBED_TCP or verb == A_EMBED_MCP then
    embed_fx(tr, a, verb == A_EMBED_TCP)
    return
  elseif verb == A_CHAIN_APPLY or verb == A_CHAIN_SAVE then
    local row = view[a + 1]
    if verb == A_CHAIN_APPLY then
      -- Folders are navigated, not applied. The face already refuses to
      -- send this for a folder row; refusing again here means a stray
      -- action from anywhere cannot wipe a chain with a directory name.
      if row and row.kindix == K_CHAIN then
        fx.chain_apply(tr, row.rel, "replace")
        ch_fp[slot] = nil          -- the chain definitely moved
      end
    else
      -- SAVE writes the target's CURRENT chain into the folder being
      -- browsed, so "save here" means the folder you are looking at.
      fx.chain_save(tr, ch_rel[slot] or "")
    end
    return
  elseif verb == A_OFFLINE then
    -- The picker engine reads offline but has never written it; one call
    -- rather than a new engine function, since nothing else needs it yet.
    local ch = fx.chain(tr)
    local e = ch[a + 1]
    if e and reaper.TrackFX_SetOffline then
      reaper.TrackFX_SetOffline(tr, a, not e.offline)
    end
    return
  end
  if verb == A_ENABLE then
    local ch = fx.chain(tr)
    local e = ch[a + 1]
    if e then fx.set_enabled(tr, a, not e.enabled) end
  elseif verb == A_REMOVE then
    fx.remove(tr, a)
  elseif verb == A_MOVE then
    -- M.move is the best-evidenced call in the engine: the REAPER harness
    -- covers down-by-one, 0->3, 3->0 and the duplicate-safe case.
    if bnum >= 0 then fx.move(tr, a, bnum) end
  elseif verb == A_SWAP or verb == A_INSERT then
    local row = view[bnum + 1]
    if not row then return end
    -- ⚠️ The engine takes the DISPLAY NAME, not the row. row.disp is what
    -- TrackFX_AddByName wants and what the REAPER harness passes; handing it
    -- the table crashes inside REAPER with "string expected, got table".
    local add = row.disp
    -- MRU, newest first, capped. Session-only: an FX list that reorders itself
    -- across restarts is more confusing than useful.
    if add and add ~= "" then
      for i = #recent, 1, -1 do
        if recent[i] == add then table.remove(recent, i) end
      end
      table.insert(recent, 1, add)
      while #recent > 24 do table.remove(recent) end
      view_q = nil                       -- RECENT changed; rebuild the view
    end
    if not add or add == "" then add = row.name end
    if verb == A_SWAP and a >= 0 then
      fx.swap(tr, a, add)
    else
      fx.insert(tr, add, a >= 0 and a + 1 or nil)
    end
  end
end

-- Console targeting. The face writes "pad P, slot S" and bumps TGT_SEQ when
-- you click an insert slot on a strip; until then the picker's target is
-- whatever REAPER last touched, which is right for "open the picker on the
-- thing I just clicked" and useless for "this pad, that slot".
--
-- ci_tgt[slot] holds the resolved MediaTrack. It is re-resolved on every
-- console publish rather than cached forever: a pad's track can be deleted or
-- rebuilt underneath us, and a stale pointer would have the picker quietly
-- editing a track that no longer exists.
local TGT_SEQ, TGT_PAD, TGT_SLOT = 142, 143, 144
-- ⚠️ TGT_PIN and ci_pin USED TO BE DECLARED HERE. Re-declaring them below
-- do_action did not just hide them from it -- a second `local` of the same
-- name is a DIFFERENT table, so even after do_action was taught to read the
-- pin it would have read the empty first one forever while this half wrote
-- the second. They now live once, up beside ci_tgt.

local function consume_target(slot)
  local b = BASE + slot * STRIDE
  local seq = math.floor(reaper.gmem_read(b + TGT_SEQ) or 0)
  if seq == 0 or seq == ci_tgt_seq[slot] then return end
  ci_tgt_seq[slot] = seq
  local pad = math.floor(reaper.gmem_read(b + TGT_PAD) or -1)
  local pads = ci_pads[slot]
  -- -1 = the master/bus strip. Anything else indexes the pad tracks the
  -- console publisher already resolved this tick, so the two sides cannot
  -- disagree about which track a pad means.
  ci_tgt[slot] = (pad >= 0 and pads) and pads[pad] or (pads and pads.master) or nil
  local sel = math.floor(reaper.gmem_read(b + TGT_SLOT) or -1)
  reaper.gmem_write(b + CH_SEL, sel)
  ch_fp[slot] = nil            -- force a republish for the new target
end

local function publish_chain(slot)
  -- ⚠️ Resolve the pin BEFORE the fingerprint gate below, which returns early:
  -- latching has to happen on every tick, not only on ticks that republish.
  local pin = math.floor(reaper.gmem_read(BASE + slot * STRIDE + TGT_PIN) or 0)
  if pin == 1 then
    ci_pin[slot] = ci_pin[slot] or ci_tgt[slot] or reaper.GetLastTouchedTrack()
  else
    ci_pin[slot] = nil
  end
  if ci_pin[slot] and not reaper.ValidatePtr2(0, ci_pin[slot], "MediaTrack*") then
    ci_pin[slot] = nil
  end
  -- ⭐ THE SHARED RESOLVER — the one do_action fires at. What is drawn and
  -- what is acted on are now the same track by construction.
  local tr = resolve_target(slot)
  -- A target that has since been deleted must not be handed to the API.
  if not tr then
    tr = reaper.GetLastTouchedTrack()
    ci_tgt[slot] = nil
    if tr and not reaper.ValidatePtr2(0, tr, "MediaTrack*") then tr = nil end
  end
  local tname, tnum, tcol = "", 0, -1
  if tr then
    tnum = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0)
    -- I_CUSTOMCOLOR carries a flag bit above the colour; 0 means "no custom
    -- colour", which must stay distinguishable from black. ColorFromNative
    -- because the packing is OS-dependent -- reading the bytes directly works
    -- on Windows and gives blue-for-red on Mac.
    -- ⚠️ A PLAIN `if`. This was written `c ~= 0 and (function() ... end)()`,
    -- which is EEL2's ternary habit in a language that does not have it: Lua
    -- statements are assignments, calls or control structures, and a bare
    -- expression is a syntax error. Half this session is spent in the other
    -- language and it shows.
    local c = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") or 0)
    if c ~= 0 then
      local cr, cg, cb = reaper.ColorFromNative(c % 0x1000000)
      tcol = cr * 65536 + cg * 256 + cb
    end
    local ok, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    tname = ascii_fold((ok and nm ~= "" and nm) or ("Track " .. tnum))
  end
  -- Frozen is read HERE, on the republish path, which the fingerprint
  -- already gates -- not per tick. The chunk of a loaded track is not small.
  tgt_frozen[slot] = track_frozen(tr)
  tgt_none[slot]   = (tr == nil)
  local ch = tr and fx.chain(tr) or {}
  -- ⚠️ tnum IS IN THE FINGERPRINT. Reordering tracks changes the number while
  -- the name stays put; without it here the republish never fires and the face
  -- shows a number that moved.
  local parts = { tname, tnum, tcol, #ch }
  for _, e in ipairs(ch) do
    -- Offline belongs in the fingerprint too: without it, toggling offline
    -- changes nothing the bridge can see and the republish never happens.
    parts[#parts + 1] = e.name .. (e.enabled and "1" or "0")
                                .. (e.offline and "F" or "-")
  end
  local fp = table.concat(parts, string.char(31))
  if fp == ch_fp[slot] then return end
  ch_fp[slot] = fp

  local b = BASE + slot * STRIDE
  local seq = (reaper.gmem_read(b + CH_SEQ) or 0)
  seq = math.floor(seq / 2) * 2 + 2
  reaper.gmem_write(b + CH_SEQ, seq - 1)          -- ODD: mid-write

  local tl = math.min(32, #tname)
  reaper.gmem_write(b + TGT_LEN, tl)
  for c = 1, tl do reaper.gmem_write(b + TGT_NAME + c - 1, tname:byte(c)) end
  reaper.gmem_write(b + TGT_NUM, tnum)
  reaper.gmem_write(b + TGT_COL, tcol)

  local n = math.min(CHAIN_MAX, #ch)
  for i = 1, n do
    local e, p = ch[i], b + CHAIN + (i - 1) * CREC
    local nm = ascii_fold(e.name)
    local len = math.min(CNAME_MAX, #nm)
    reaper.gmem_write(p + C_LEN, len)
    for c = 1, len do reaper.gmem_write(p + C_NAME + c - 1, nm:byte(c)) end
    reaper.gmem_write(p + C_ON, e.enabled and 1 or 0)
    reaper.gmem_write(p + C_OFF, e.offline and 1 or 0)
    reaper.gmem_write(p + C_FMT, FMT_CODE[e.fmt] or 0)
  end
  for i = n, CHAIN_MAX - 1 do
    reaper.gmem_write(b + CHAIN + i * CREC + C_LEN, 0)
  end
  reaper.gmem_write(b + CH_N, n)
  reaper.gmem_write(b + CH_SEL, -1)
  reaper.gmem_write(b + CH_SEQ, seq)              -- PAYLOAD FIRST, SEQ LAST
end

-- ═════════════════════════════════════════════════════════════════════════
-- CONSOLE INSERT SUMMARY — what is in each PAD's own track chain.
-- ═════════════════════════════════════════════════════════════════════════
-- The picker publishes ONE chain for ONE target. A console strip wants sixteen
-- at once, and only a summary of each: enough to draw a lit slot in the right
-- category colour. Names live in the hover popover, not on a 44 px strip.
--
-- ⚠️ A pad only owns a REAPER track in MULTI-OUT. Every other pad plays through
-- Swing's own chain and has nowhere to put a plugin, so its record is count=-1
-- and the face draws the slots DEAD rather than as empty add-boxes. An inviting
-- +box on a pad that cannot take one is a lie the interface would be telling.
local CI_BASE, CI_STRIDE = 26542080, 2048
local CI_SEQ, CI_HB, CI_FLAGS, CI_HDR, CI_PREC, CI_NSLOT = 0, 1, 2, 32, 118, 8
local CI_COUNT, CI_SLOT, CI_NAME, CI_NAMEW, CI_NCHAR = 0, 1, 9, 12, 11
local CI_HASH = 105   -- card-name hash per slot, over the FULL name
-- Bump BOTH this and CI_FMT_VER in the .jsfx whenever the record moves, so a
-- face talking to a not-yet-restarted bridge says so instead of drawing the
-- old shape read as the new one.
local CI_FMT, CI_FMT_VER = 3, 2
-- 17 records: pads 0..15, then the MASTER as record 16. It used to ride in the
-- header's spare words; with names the records are big enough that it is
-- simpler, and one less special case, for the master to just BE a record --
-- the same publish loop and the same draw call handle it.
local CI_RECS = 17
-- Instance registry: iid -> slot. Same table eon_action_target.lua reads.
local REG_BASE, REG_STRIDE, REG_MAX, REG_TIMEOUT = 2556, 4, 16, 3.0
local ci_fp = {}

local function ci_is_swing(tr, fx)
  local ok, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
  if ok and ident and ident:find("DrumKit_ReaKit") then return true end
  local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
  if fname and fname:find("DrumKit_ReaKit") then return true end
  return fname and (fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad")) and true or false
end

local function ci_slot_of(iid)
  local now = reaper.time_precise()
  for s = 0, REG_MAX - 1 do
    local b = REG_BASE + s * REG_STRIDE
    if math.floor(reaper.gmem_read(b) or 0) == iid
       and (now - (reaper.gmem_read(b + 1) or 0)) <= REG_TIMEOUT then return s end
  end
end

-- One pad's slot words. Category index drives the colour; enabled/offline are
-- read back rather than assumed, because REAPER's own FX window can change
-- them behind us at any moment.
-- Port of swing_fxcard_hash from rk_swing_fxcard_data.jsfx-inc, character for
-- character. The face cannot compute it itself: it only receives a TRUNCATED
-- name, and the card deck is keyed on the whole one -- so hashing 11 characters
-- of "EON Drum Strip" finds nothing at all.
--
-- ⚠️ IF THAT FUNCTION EVER CHANGES, THIS MUST CHANGE WITH IT. Two copies of one
-- hash is the cost of the split; they agree only because they were written to.
-- Lowercase alphanumerics only, parenthesised sections skipped entirely (that
-- is how "Pro-Q 3 (FabFilter)" and "Pro-Q 3" land on the same card).
local function card_hash(name)
  local h, depth = 0, 0
  for i = 1, #name do
    local c = name:byte(i)
    if c == 40 then                       -- '('
      depth = depth + 1
    elseif c == 41 then                   -- ')'
      if depth > 0 then depth = depth - 1 end
    elseif depth == 0 then
      if c >= 65 and c <= 90 then c = c + 32 end
      if (c >= 48 and c <= 57) or (c >= 97 and c <= 122) then
        h = (h * 131 + c) % 1000003
      end
    end
  end
  return h
end

local function ci_pad_words(tr)
  local out, nm, hs, ch = {}, {}, {}, fx.chain(tr)
  for i = 1, math.min(CI_NSLOT, #ch) do
    local e = ch[i]
    local cat = BUCKET_IX[fx.category_fx(tr, i - 1)] or 0
    out[i] = cat + (e.enabled and 0 or 64) + (e.offline and 128 or 0)
    -- e.name is ALREADY the shortened display name the picker list uses
    -- (fx.parse_name strips vendor and format). Truncating that beats
    -- inventing a second way to abbreviate, which would eventually disagree
    -- with the picker about what a plugin is called.
    nm[i] = (e.name or ""):sub(1, CI_NCHAR)
    -- Hash the FULL name, never the truncated one.
    hs[i] = card_hash(e.name or "")
  end
  return out, #ch, nm, hs
end

local function publish_console_inserts()
  -- Find every live Swing instance and the pad tracks it feeds.
  local seen = {}
  for ti = -1, reaper.CountTracks(0) - 1 do
    local tr = (ti < 0) and reaper.GetMasterTrack(0) or reaper.GetTrack(0, ti)
    if tr then
      for fxi = 0, reaper.TrackFX_GetCount(tr) - 1 do
        if ci_is_swing(tr, fxi) then
          local slot = ci_slot_of(math.floor(reaper.TrackFX_GetParam(tr, fxi, 3) or 0))
          if slot and not seen[slot] then
            seen[slot] = true
            -- Pad tracks are the Swing track's SENDS: source channel pair ->
            -- pad index. Same mapping the kit bridge colours lanes by.
            local pads, nsend = {}, reaper.GetTrackNumSends(tr, 0)
            local no_sws = false
            for s = 0, nsend - 1 do
              local sc = reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN")
              local pad = -1
              if sc then
                sc = math.floor(sc)
                local c = sc >= 0 and (sc % 1024) or -1
                if c >= 0 and c % 2 == 0 then pad = c / 2 end
              end
              -- ⚠️ BR_GetMediaTrackSendInfo_Track is SWS. Without it this
              -- resolved NOTHING and every pad published as "owns no
              -- track" -- indistinguishable from a project that simply is
              -- not in multi-out, with no error anywhere. The dependency
              -- is not new (the kit bridge walks sends the same way) but it
              -- was UNDECLARED, which is the part that made it a bug.
              if pad >= 0 and pad < 16 then
                if reaper.BR_GetMediaTrackSendInfo_Track then
                  pads[pad] = reaper.BR_GetMediaTrackSendInfo_Track(tr, 0, s, 1)
                else
                  no_sws = true
                end
              end
            end

            -- Build the whole payload first, fingerprint it, and only touch
            -- gmem when something actually changed. Sixteen chains re-read per
            -- tick is fine; sixteen chains re-WRITTEN per tick would make the
            -- face's seq-gate fire every frame for no reason.
            local rec, fpp = {}, {}
            for pad = 0, 15 do
              local ptr = pads[pad]
              if ptr then
                local w, n, nm, hs = ci_pad_words(ptr)
                rec[pad] = { n = n, w = w, nm = nm, hs = hs }
                fpp[#fpp + 1] = pad .. ":" .. n .. ":" .. table.concat(w, ",")
                                    .. ":" .. table.concat(nm, ",")
              else
                rec[pad] = { n = -1, w = {}, nm = {}, hs = {} }
                fpp[#fpp + 1] = pad .. ":-1"
              end
            end

            -- MASTER: whatever Swing's summed output actually passes through,
            -- which depends on the ROUTING and not on a preference.
            --   multi-out — the pads left as 16 separate outputs and sum on
            --     their PARENT track. That folder is the desk's master.
            --   stereo    — they summed inside Swing, so the master is the
            --     rest of the chain on Swing's own track.
            -- Same rule the insert slots follow: what a strip shows is decided
            -- by how the audio is routed, never by a setting.
            local mtr
            for pad = 0, 15 do
              if pads[pad] then mtr = reaper.GetParentTrack(pads[pad]) break end
            end
            mtr = mtr or tr
            -- Hand the resolved tracks to the targeting path so a console
            -- click and this publish cannot disagree about which track a pad
            -- means. Re-stashed every publish, never cached across one: a pad
            -- track can be deleted or rebuilt underneath us.
            pads.master = mtr
            ci_pads[slot] = pads
            local mw, mn, mnm, mhs = ci_pad_words(mtr)
            rec[16] = { n = mn, w = mw, nm = mnm, hs = mhs }  -- master = rec 16
            fpp[#fpp + 1] = "M:" .. mn .. ":" .. table.concat(mw, ",")
                                .. ":" .. table.concat(mnm, ",")

            -- ⚠️ HEARTBEAT IS UNCONDITIONAL, outside the change gate below.
            -- It used to live inside it, which meant a project where nothing
            -- changed froze the beat and the face would call a perfectly
            -- healthy bridge dead — a false alarm precisely when everything is
            -- fine. A heartbeat says "I am here", never "something happened".
            --
            -- A COUNTER, not a clock: the face has no wall clock to compare
            -- against, and os.time()'s one-second resolution made two publishes
            -- in the same second indistinguishable. All the face needs is
            -- whether the number moved.
            ci_beat = (ci_beat or 0) + 1
            reaper.gmem_write(CI_BASE + slot * CI_STRIDE + CI_HB, ci_beat)

            local fp = table.concat(fpp, "|")
            if ci_fp[slot] ~= fp then
              ci_fp[slot] = fp
              local b = CI_BASE + slot * CI_STRIDE
              local seq = math.floor((reaper.gmem_read(b + CI_SEQ) or 0) / 2) * 2 + 2
              reaper.gmem_write(b + CI_SEQ, seq - 1)     -- ODD: mid-write
              -- bit0: this instance has multi-out tracks.
              -- bit1: we could not look them up at all (no SWS).
              -- The face needs to tell those apart -- "you are not in
              -- multi-out" and "I cannot see" are different sentences.
              reaper.gmem_write(b + CI_FMT, CI_FMT_VER)
              reaper.gmem_write(b + CI_FLAGS,
                (nsend >= 16 and 1 or 0) + (no_sws and 2 or 0))
              -- One loop for all 17. The master stopped being a special
              -- case the moment it became a record like any other.
              for ri = 0, CI_RECS - 1 do
                local p, r = b + CI_HDR + ri * CI_PREC, rec[ri]
                reaper.gmem_write(p + CI_COUNT, r.n)
                for k = 1, CI_NSLOT do
                  reaper.gmem_write(p + CI_SLOT + k - 1, r.w[k] or -1)
                  -- Name as length-then-characters, so the face never has
                  -- to hunt for a terminator it might not find.
                  local nm = ascii_fold(r.nm[k])
                  local np = p + CI_NAME + (k - 1) * CI_NAMEW
                  reaper.gmem_write(np, #nm)
                  for c = 1, CI_NCHAR do
                    reaper.gmem_write(np + c, c <= #nm and nm:byte(c) or 0)
                  end
                  -- Hash of the FULL name, so the face's card lookup is not
                  -- fed the truncation above.
                  reaper.gmem_write(p + CI_HASH + k - 1, r.hs[k] or 0)
                end
              end
              reaper.gmem_write(b + CI_SEQ, seq)         -- EVEN: readable, LAST
            end
          end
        end
      end
    end
  end
end

local function tick()
  if reaper.GetExtState("EON_FXPICK", "running") ~= "1" then
    reaper.SetToggleCommandState(secId, cmdId, 0)
    reaper.RefreshToolbar2(secId, cmdId)
    return
  end
  -- Startup-order retry (see fxpick_build_registry). Only ever runs while the
  -- registry is genuinely empty, so a user with no plugins installed costs one
  -- EnumInstalledFX call per tick and everyone else costs nothing at all. On a
  -- late success the rail has to be republished — banks_pub was latched true
  -- against the empty list.
  if not registry_ok then
    registry_ok = fxpick_build_registry()
    if registry_ok then banks_pub = false end
  end

  local now = os.time()

  -- Console insert summary. THROTTLED: it walks every track and reads every
  -- pad chain, which is far too much to do per defer tick. Twice a second is
  -- faster than anyone can insert a plugin and notice the lag.
  local tnow = reaper.time_precise()
  if tnow - (ci_last or 0) >= 0.5 then
    ci_last = tnow
    local cok, cerr = pcall(publish_console_inserts)
    -- A fault here must never take the picker down with it: the console's
    -- insert band going stale is a cosmetic failure, a dead bridge is not.
    if not cok and not ci_warned then
      ci_warned = true
      reaper.ShowConsoleMsg("[EON] console insert summary failed: "
                            .. tostring(cerr) .. NL)
    end
  end

  for slot = 0, SLOTS - 1 do
    local b = BASE + slot * STRIDE
    local req = reaper.gmem_read(b + REQ_SEQ) or 0
    publish_banks()
    if req ~= 0 and req ~= last_req[slot] then
      last_req[slot] = req
      -- ⚠️ Inside the branch, not outside. `view` is one shared list, so
      -- running this for all 16 slots meant the 15 untouched ones (whose
      -- query cells read 0) kept resetting the filter the live one had just
      -- set. Only the slot actually being answered gets to shape the view.
      apply_query(b, slot)
      publish(slot, reaper.gmem_read(b + REQ_OFF), reaper.gmem_read(b + REQ_N), req)
    end
    -- Heartbeat only for slots that have ever asked: an untouched slot stays
    -- silent, so a picker that was never opened does not look alive.
    -- ⚠️ Target BEFORE actions. An action posted in the same frame as a
    -- target change would otherwise run against the PREVIOUS target -- and
    -- the console posts exactly that pair when you pick Delete from a slot
    -- menu. Aim, then fire, in that order, on the same tick.
    consume_target(slot)
    -- Actions are edge-triggered and must NEVER be coalesced away.
    local aseq = reaper.gmem_read(b + ACT_SEQ) or 0
    if aseq ~= 0 and aseq ~= last_act[slot] then
      last_act[slot] = aseq
      local ok, err = pcall(do_action, slot,
                            reaper.gmem_read(b + ACT_VERB) or 0,
                            math.floor(reaper.gmem_read(b + ACT_A) or -1),
                            math.floor(reaper.gmem_read(b + ACT_B) or -1))
      if not ok then
        reaper.ShowConsoleMsg("FX picker action failed: " .. tostring(err) .. NL)
      end
      ch_fp[slot] = nil            -- the chain definitely moved; republish it
      reaper.gmem_write(b + ACT_ACK, aseq)
    end
    if last_req[slot] then
      reaper.gmem_write(b + HB, now)
      publish_chain(slot)
    end
  end
  reaper.defer(tick)
end

-- ═════════════════════════════════════════════════════════════════════════
-- Self-register as a startup action — same contract as Swing_Kit_Bridge.lua.
-- ═════════════════════════════════════════════════════════════════════════
-- This is a background defer() companion, and the house rule is that those
-- auto-start while one-shot toolbar scripts never do (.docs/wiki/11 §Auto-start
-- rules). Registration happens on the first MANUAL run and is idempotent.
--
-- Deliberately placed AFTER the toggle check above: a second run is the
-- documented way to STOP the bridge and returns early, so it must not also
-- re-register on the way out.
--
-- ⛔ RETIRING THIS SCRIPT LATER: unregister with AddRemoveReaScript(false,...)
-- BEFORE deleting the file, then strip the block from __startup.lua. Deleting
-- the .lua first leaves a block whose NamedCommandLookup still resolves out of
-- reaper-kb.ini, and REAPER throws "Can't load file" at every launch.

-- Atomic rewrite of the SHARED __startup.lua: tmp file + rename, never a
-- truncate in place, because other vendors' startup lines live in that file
-- and a crash mid-write must not be able to eat them. Global, not local —
-- the same helper rides in every EON self-registering script.
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

local function fxpick_self_register()
  -- Probe/host opt-out. Registration records get_action_context()'s path — the
  -- HOSTING script, not this file — so a harness that dofile'd us would install
  -- ITSELF as a startup action. The kit bridge learned this the hard way.
  if reaper.GetExtState("EON_Bridge", "no_self_register") == "1" then return end
  local _, script_path = reaper.get_action_context()
  local NAME = "EON_FXPicker_Bridge"
  local key = NAME .. "_registered_v3"
  local marker = "-- EON:" .. NAME

  -- Trust ExtState only when __startup.lua actually still contains our block:
  -- an uninstall step can delete that file without clearing the ExtState, and
  -- then we would believe we were registered forever.
  if reaper.GetExtState(NAME, key) == "1" then
    local fr = io.open(reaper.GetResourcePath() .. "/Scripts/__startup.lua", "r")
    if fr then
      local content = fr:read("*a"); fr:close()
      if content:find(marker .. " BEGIN", 1, true) then return end
    end
    reaper.SetExtState(NAME, key, "", true)
  end

  local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
  if not cmd_id or cmd_id <= 0 then return end

  local startup_path = reaper.GetResourcePath() .. "/Scripts/__startup.lua"
  local existing = ""
  local fr = io.open(startup_path, "r")
  if fr then existing = fr:read("*a"); fr:close() end

  -- Strip any prior copy of our block so re-registration is idempotent.
  local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
  existing = existing:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")

  -- Named command ids ("_RSxxxxx") survive action-list rebuilds; the raw int
  -- does not, so prefer the token.
  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  -- Self-cleaning: when the script file is gone the lookup returns 0, and the
  -- block removes itself and clears the ExtState so a reinstall registers
  -- fresh. Runs at most once per uninstall.
  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then reaper.Main_OnCommand(id,0) else\n" ..
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); if f then local c=f:read('*a'); f:close()\n" ..
    "    c=c:gsub('\\n?%-%- EON:" .. NAME .. " BEGIN.-%-%- EON:" .. NAME .. " END\\n?','')\n" ..
    "    local fw=io.open(p,'w'); if fw then fw:write(c); fw:close() end end\n" ..
    "  reaper.SetExtState('" .. NAME .. "','" .. NAME .. "_registered_v3','',true)\n" ..
    "end end\n" ..
    marker .. " END\n"

  -- Flag registered only once the block is really on disk; a failed write
  -- leaves the ExtState clear so the next run simply retries.
  if eon_write_startup(startup_path, existing .. block) then
    reaper.SetExtState(NAME, key, "1", true)
    reaper.ShowConsoleMsg("[EON] " .. NAME ..
      " registered as startup action (auto-cleans on uninstall).\n")
  end
end
fxpick_self_register()

reaper.SetToggleCommandState(secId, cmdId, 1)
reaper.RefreshToolbar2(secId, cmdId)
reaper.atexit(function()
  reaper.SetExtState("EON_FXPICK", "running", "0", false)
  reaper.SetToggleCommandState(secId, cmdId, 0)
  reaper.RefreshToolbar2(secId, cmdId)
end)
-- No start-up banner. This script self-registers as a startup action, so a
-- ShowConsoleMsg here POPS THE CONSOLE OPEN on every REAPER launch, for a
-- background service that has nothing to say. Running state is already
-- visible without it: the toolbar toggle is lit two lines above, and
-- EON_FXPICK/running is set. Faults still speak.
tick()
