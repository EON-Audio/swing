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
-- PL H14: one word per entry, the card hash of the 40-character name, in the
-- 32 words the chain records leave free (3264 + 32*25 = 4064 .. 4095).
local CHAIN_HASH = CHAIN + CHAIN_MAX * CREC
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
-- The shared core (Pad Banks Outputs step 3): which of Swing's sends are its own output tracks
-- (core.swing_send_pair -- a channel alone is no owner: a user's own send from Swing's channels 1-2 read as pad 1),
-- and the strip band, where Swing says which pair each slot plays on.
local okc, core = pcall(require, "rk_lua_core")
if not okc then
  reaper.ShowConsoleMsg("FX picker bridge: could not load rk_lua_core\n" .. tostring(core) .. "\n")
  return
end

-- Styled dialog module (ReaImGui), the Kit Bridge's contract: pcall'd, gated on
-- available(), and every call site keeps its native GetUserInputs /
-- ShowMessageBox fallback. ⚠️ its prompts are ASYNC -- the work goes INSIDE
-- on_ok, never after the call.
local eon_dlg
do
  local okd, m = pcall(dofile, dir .. "/EON/eon_imgui_dialog.lua")
  if okd and type(m) == "table" then eon_dlg = m end
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

-- ⚠️ ONE fallback chain for every site that turns a category word into a pip
-- index: the rail, the rows, a chain file's peek and the console inserts.
-- BUCKET_IX holds the 22 effect buckets only, so an instrument bucket ("drums",
-- "keys") fell to 0 = comp at the console site and to the empty ring at the peek
-- -- four sites, four fallbacks, one wrong (sweep BRW20, 2026-10-26).
local function bucket_ix(c)
  return BUCKET_IX[c] or IBUCKET_GLYPH[c] or (#fx.BUCKETS - 1)
end

local rows, banks = {}, {}          -- registry + the rail built from it
local view, view_q = {}, nil        -- the filtered result set
-- PL H4/H7 (2026-10-26): WHOSE query `view` was built from. It is one list for
-- all sixteen slots and a pick names a ROW of it (R_RIDX), so an action is
-- resolved only against the acting slot's own list -- re-built first when
-- another Swing's ask (its FX tab re-asks twice a second) rebuilt it since.
local view_slot = nil
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
  view, view_q, view_bank, view_kf, view_slot = rows, nil, -1, 2, nil
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
  for _, c in ipairs(order) do
    banks[#banks + 1] = { name = c, kind = 3, cat = c,
                          bucket = bucket_ix(c), n = seen[c] }
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

-- ⚠️ This string comes out of SHARED gmem, so it is untrusted. The engine
-- refuses anything that leaves FXChains (fx.chain_rel, called by every chain_*
-- function), which is where the check has to live: that is what opens files.
--
-- ⚠️ PL H2 (2026-10-26): the face builds the path from the names it was SENT,
-- and publish() sends ascii_fold(name) cut to NAME_MAX -- "Réverbs" arrives as
-- "R??verbs", "Drums – Parallel" as "Drums - Parallel". Sent back verbatim that
-- named no folder and the view came up empty with no error. Each part is
-- matched back to the real folder, the same fold and cut applied to the real
-- names; a path that matches nothing is used as sent, as before.
local rel_fold = {}        -- the path as the face sent it -> the real one
local function read_rel(b)
  local n = math.floor(reaper.gmem_read(b + CHREL_LEN) or 0)
  n = math.max(0, math.min(CHREL_MAX, n))
  if n == 0 then return "" end
  local t = {}
  for i = 0, n - 1 do
    t[#t + 1] = string.char(math.floor(reaper.gmem_read(b + CHREL + i) or 32) % 256)
  end
  local s = table.concat(t)
  if rel_fold[s] then return rel_fold[s] end
  local cur = ""
  for part in s:gmatch("[^/]+") do
    local hit, fold
    for _, d in ipairs(fx.chain_list(cur).dirs or {}) do
      if d.name == part then hit = d.rel break end
      if not fold and ascii_fold(d.name):sub(1, NAME_MAX) == part then fold = d.rel end
    end
    cur = hit or fold
    if not cur then break end
  end
  if cur then rel_fold[s] = cur return cur end
  -- ⚠️ The face sends "/" always; translate to this platform's separator.
  -- The engine joins with package.config's, so a raw "/" would break the
  -- lookup on any host where that is not the separator -- and it would fail
  -- as an EMPTY folder rather than as an error.
  local sep = package.config and package.config:sub(1, 1) or "/"
  return (s:gsub("/", sep))
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
        -- A VST / VST3 / CLAP entry is the DECORATED chunk name, "VST3: ReaEQ
        -- (Cockos)": the recipe lookup is an exact key match, so the format
        -- prefix and the vendor group have to come off first, as category_fx
        -- strips them for a live slot (sweep BRW18, 2026-10-26).
        nm = (fx.parse_name(nm))
        out.n = out.n + 1
        if #out.cats < 4 then
          out.cats[#out.cats + 1] = bucket_ix(fx.category(nm))
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
  -- Set first: every return below leaves `view` as THIS slot's query's list
  -- (rebuilt, or the cache hit of an identical query).
  view_slot = slot
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
    reaper.gmem_write(p + R_BUCKET, bucket_ix(r.cat))
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

-- ── WIRED PAIRS (Pad Banks Outputs step 5) ───────────────────────────────────
-- A pad's Wired container is keyed by the PAIR its audio rides (rk_lua_fxpicker
-- PAD VIEWS): bank A's 0..15, a bank's 19..21 (shared by its pads), a split pad's
-- 22..31. Swing publishes each slot's (the strip band's OUT_WPAIR) and the names
-- the captions need. One table, not five locals: this chunk is near Lua's
-- 200-local ceiling. Declared here, above publish_chain, for the same compile-time
-- reason as ci_tgt.
-- ciw.pn[slot] = { id = instance id, bank = the bank seen last pass, [abs slot
-- 0..63] = name }; ciw.bank_seen[slot] = the bank on screen at the last tick.
local ciw = { pn = {}, bank_seen = {} }

-- Every bank's pad names, as far as each bank has been on screen. Swing publishes
-- only the bank ON SCREEN's sixteen (INST_PADNAME, slot*512 + pad*32 chars, beside
-- GS_INST_BANK_CUR, which leads its names by up to a block), so a bank is copied
-- in once it has stayed on screen from one pass to the next and still is after
-- the read -- the kit bridge's eon_out_names_tick, the same rule. (The old reader
-- took the band as bank A's whatever bank was on screen: with bank B shown, bank
-- A's pad containers were renamed after bank B's pads.)
function ciw.names_tick(slot)
  local G = core.GMEM
  local id = math.floor(reaper.gmem_read(G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE + G.GS_INST_REG_OFF_ID) or 0)
  local c = ciw.pn[slot]
  if not c or c.id ~= id then c = { id = id }; ciw.pn[slot] = c end
  local b = math.floor(reaper.gmem_read(G.GS_INST_BANK_CUR + slot) or 0)
  if b == c.bank and b >= 0 and b <= 3 then
    local got = {}
    for pad = 0, G.NUM_PADS - 1 do
      local base, t = G.INST_PADNAME_BASE + slot * G.INST_PADNAME_INST_STRIDE + pad * G.INST_PADNAME_PAD_LEN, {}
      for i = 0, G.INST_PADNAME_PAD_LEN - 1 do
        local ch = math.floor(reaper.gmem_read(base + i) or 0)
        if ch <= 0 then break end
        t[#t + 1] = (ch >= 32 and ch <= 126) and string.char(ch) or "?"
      end
      got[b * G.NUM_PADS + pad] = table.concat(t)
    end
    if math.floor(reaper.gmem_read(G.GS_INST_BANK_CUR + slot) or 0) == b then
      for k, v in pairs(got) do c[k] = v end
    end
  end
  c.bank = b
end

-- A slot's (0..63) name -- "" for a pad with none -- or nil while its bank has not been on screen since the
-- bridge started: not known, which is not the same as empty (a caption built from it is not one to rename to).
function ciw.name(slot, o)
  local c = ciw.pn[slot]
  return c and c[o]
end

-- The pair slot `o` rides under Wired (OUT_WPAIR, published as pair + 1), or nil
-- from a Swing that does not publish it (OUT_GEN 0, or a build before step 5's
-- picker): the caller falls back to bank A's pad = its pair, what every older
-- Swing routed.
function ciw.wpair(slot, o)
  local G = core.GMEM
  local band = G.GS_STRIP_BASE + slot * G.GS_STRIP_STRIDE
  if math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_GEN) or 0) == 0 then return nil end
  local w = math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_WPAIR + o) or 0)
  return (w > 0) and (w - 1) or nil
end

-- Swing's whole output block for one instance, or nil (an older Swing, or every try
-- met a block being written): OUT_GEN is odd while Swing writes, even once whole,
-- and a read is kept only on the same even value before and after (the kit
-- bridge's eon_out_use). { pair[o], wpair[o] (nil unpublished), own[p] = the
-- owner slot of split pair p, bank[b] = bank b's name (1..3 = B..D) }.
function ciw.read_out(slot)
  local G = core.GMEM
  local band = G.GS_STRIP_BASE + slot * G.GS_STRIP_STRIDE
  for _ = 1, 5 do
    local g0 = math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_GEN) or 0)
    if g0 == 0 then return nil end
    if g0 % 2 == 0 then
      local u = { pair = {}, wpair = {}, own = {}, bank = {} }
      for o = 0, 63 do
        u.pair[o] = math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_PAIR + o) or 0)
        local w = math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_WPAIR + o) or 0)
        u.wpair[o] = (w > 0) and (w - 1) or nil
      end
      for p = 22, 31 do
        local w = math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_OWN + p - 22) or 0)
        u.own[p] = (w > 0) and (w - 1) or nil
      end
      for bk = 1, 3 do
        local t, base = {}, band + G.GS_STRIP_OFF_BKNAME + (bk - 1) * G.GS_STRIP_BKNAME_LEN
        for j = 0, G.GS_STRIP_BKNAME_LEN - 1 do
          local ch = math.floor(reaper.gmem_read(base + j) or 0)
          if ch <= 0 or ch > 255 then break end
          t[#t + 1] = string.char(ch)
        end
        u.bank[bk] = table.concat(t)
      end
      if math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_GEN) or 0) == g0 then return u end
    end
  end
  return nil
end

-- Pair p's caption for instance `slot` -- what its container is called (rk_lua_
-- fxpicker's pair_caption: "Kick (pad 1)", "Bank B: Toms", "C3: Snare") -- and the
-- `name` the library's container calls take for it: bank A's pad name (the library
-- adds " (pad N)"), a bank or split pair's whole caption. `u` = ciw.read_out's
-- block when the caller has one. Third value: whether everything the caption
-- is built from is KNOWN -- the pad's name cached, the block read, a split pair's
-- owner and its name -- so a container is renamed only to a real caption. On a
-- bridge start no name is cached yet, and "C3: Snare" was renamed to the bare
-- "C3" (review 2026-10-12; the kit bridge's eon_out_follow has the same rule).
function ciw.caption(slot, p, u)
  if p < 16 then
    local nm = ciw.name(slot, p)
    return fx.pair_caption(p, nm or ""), nm or "", nm ~= nil
  end
  u = u or ciw.read_out(slot)
  if p < 22 then
    local cap = fx.pair_caption(p, u and u.bank[p - 18] or "")
    return cap, cap, u ~= nil
  end
  local o = u and u.own[p]
  local nm = o and ciw.name(slot, o)
  local cap = fx.pair_caption(p, nm or "", o)
  return cap, cap, o ~= nil and nm ~= nil
end

-- A pad AIM -> the target it means on THIS tick. The console's insert slots and
-- Swing's FX tab (which follows the selected pad) name a PAD; which track holds
-- that pad is ci_pads' answer, and the answer can change while the aim is still
-- held: stereo <-> multi-out, a rebuilt pad track, another Swing taking over
-- the registry slot. nil = not resolvable this tick. Declared here, above
-- resolve_target, for the same compile-time reason as ci_tgt.
-- -1 = the master/bus strip. A pad with NO track (stereo) is a VIEW of Swing's
-- own track: its Wired slice, pinned to the pad's pair (fx.view) -- the
-- publisher stashes that track as pads.swing_tr.
-- The pair a slot plays on, from Swing's strip band (OUT_PAIR, Pad Banks Outputs step 3); nil from a Swing that
-- does not publish it (OUT_GEN 0).
local function ci_slot_pair(slot, s)
  local G = core.GMEM
  local band = G.GS_STRIP_BASE + slot * G.GS_STRIP_STRIDE
  if math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_GEN) or 0) == 0 then return nil end
  return math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_PAIR + s) or 0)
end
-- kind (TGT_KIND, written with the aim): 0 = `pad` is one of bank A's sixteen output tracks (what older faces' console
-- strips send); 1 = a SLOT 0..63 (Swing's FX tab following the selected pad, and since step 5 a console strip, as
-- its slot on the bank on screen): the track it plays through now -- its pad track, a bank's track or its own split
-- track (step 3) -- or in stereo the Wired container of the pair it rides (step 5: a bank B-D pad's bank pair, a
-- split pad's own pair). The target's `pad` is then that PAIR, the view's key; `aim` stays the slot.
local function pad_target(slot, pad, kind)
  local pads = ci_pads[slot]
  if not pads then return nil end
  if pad < 0 then
    return pads.master and { tr = pads.master, pad = pads.master_pad, aim = pad } or nil
  end
  if kind == 1 then
    -- The order the console publisher draws a strip in -- ONE resolver: the slot's own output track first (multi-
    -- out, or a multi-out kit with tracks deleted, which counts as stereo with some tracks left), else the Wired
    -- container of the pair it rides. Wired first drew one chain and acted on another there (review 2026-10-12).
    local p = ci_slot_pair(slot, pad)
    if p == nil and pad < 16 then p = pad end
    local tr = p and (p < 16 and pads[p] or pads.pair[p])
    if tr then return { tr = tr, aim = pad, kind = 1 } end
    if pads.swing_tr then
      local wp = ciw.wpair(slot, pad)
      if wp == nil and pad < 16 then wp = pad end   -- an older Swing: bank A's pad on its own pair
      return wp and { tr = pads.swing_tr, pad = wp, aim = pad, kind = 1 } or nil
    end
    return nil
  end
  if pads[pad] then return { tr = pads[pad], aim = pad } end
  if pads.swing_tr then return { tr = pads.swing_tr, pad = pad, aim = pad } end
  return nil
end

-- ⭐ ONE resolver, so drawing and acting can never aim at different tracks.
-- ci_tgt still wins: an aim is a choice -- the console's is a click the user just
-- made, and Swing's FX tab stops aiming while PIN is on -- so a pin must not
-- out-rank it. The pin only displaces the last-touched fallback, which is the
-- drift it exists to stop.
local function resolve_target(slot)
  -- A target is { tr = MediaTrack, pad = nil | a pair | -1 }: nil = the whole
  -- track; a pair (0..15, 19..31) = its Wired slice of Swing's own track (fx.view);
  -- -1 = the master slice of it. The last-touched fallback is a whole track.
  -- An AIMED target also carries aim = the pad it names and is re-resolved
  -- here on every call, so it follows that pad to whatever track holds it
  -- now. When this tick cannot resolve it, the last answer stands.
  local a = ci_tgt[slot]
  if a and a.aim ~= nil then ci_tgt[slot] = pad_target(slot, a.aim, a.kind) or a end
  local t = ci_tgt[slot] or ci_pin[slot]
  local tr, pad
  if t then tr, pad = t.tr, t.pad else tr = reaper.GetLastTouchedTrack() end
  if tr and not reaper.ValidatePtr2(0, tr, "MediaTrack*") then return nil end
  return tr, pad
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

-- ── SAVE CHAIN: ask for a name ──────────────────────────────────────────────
-- ⚠️ This used to pass the BROWSED FOLDER as the chain's name. At the root that
-- is "" -- the engine refused it ("no name given") and the result was dropped,
-- so the button did nothing at all -- and inside "Drums" it wrote
-- FXChains/Drums.RfxChain BESIDE the folder and silently overwrote it on every
-- save. Found by the 2026-09-22 safety-audit follow-up. Now: a name prompt,
-- written into the folder you are looking at, and an overwrite is confirmed.

-- What a chain file may be called. Strips the characters Windows forbids (the
-- separators among them, so a name can never reach out of the folder), the
-- trailing dots and spaces Win32 trims off by itself, and a typed .RfxChain so
-- the extension is added exactly once. '?' goes too: pad names arrive from gmem
-- with every non-ASCII byte already folded to '?', which is not a legal
-- filename character.
local function chain_name_clean(s)
  s = tostring(s or "")
  s = s:gsub("%.[rR][fF][xX][cC][hH][aA][iI][nN]$", "")
  s = s:gsub('[<>:"/\\|%?%*%c]', " ")
  s = s:gsub("%s+", " "):gsub("^[%s%.]+", ""):gsub("[%s%.]+$", "")
  if #s > 64 then s = s:sub(1, 64):gsub("[%s%.]+$", "") end
  -- ⚠️ Windows DEVICE NAMES are not filenames, and an extension does not rescue
  -- them: CON, NUL, PRN, AUX, COM1..9, LPT1..9 -- and CON.anything too. Every
  -- character in them is legal, so the cleaner above passes them through and the
  -- save then fails with no useful message. Rejecting returns "" , which the
  -- caller already treats as "nothing usable typed".
  local stem = s:match("^([^%.]*)") or s
  if stem:upper():match("^CON$") or stem:upper():match("^PRN$") or stem:upper():match("^AUX$")
     or stem:upper():match("^NUL$") or stem:upper():match("^COM[1-9]$")
     or stem:upper():match("^LPT[1-9]$") then
    return ""
  end
  return s
end

-- ⚠️⚠️ `folder` IS AN ARGUMENT, NOT RE-READ FROM ch_rel. The overwrite prompt is
-- asynchronous: the user can browse to another folder while it is up. Reading
-- ch_rel[slot] again here meant the path we CHECKED and the path we WROTE could
-- differ -- confirm "replace" for Drums/Kick, land on Bass/Kick, and overwrite a
-- chain that was never mentioned. Reproduced by the 2026-09-22 Codex audit with
-- mocked callbacks. Whatever the destination was when we asked is what we write.
local function chain_save_write(tr, pad, v, slot, name, folder)
  -- The answer arrives a dialog later, so the track is re-checked here.
  if not (tr and reaper.ValidatePtr2(0, tr, "MediaTrack*")) then return end
  folder = folder or ch_rel[slot] or ""
  local rel = (folder == "" and name or (folder .. "/" .. name)) .. ".RfxChain"
  local okw, err
  if v then okw, err = fx.view_chain_save(tr, pad, rel)
  else okw, err = fx.chain_save(tr, rel) end
  if not okw then
    reaper.ShowConsoleMsg("[EON] " .. tostring(err or "chain save failed") .. NL)
    return
  end
  -- The listing is now stale -- the new chain would not appear until the folder
  -- changed. Dropping the cache key rebuilds it on the next query.
  view_q = nil
  -- And the PEEKS: a chain saved over an existing name kept the old file's
  -- preview (its pips and count) until the bridge restarted. The key is built
  -- with the platform separator and the save path with "/", so the whole table
  -- goes rather than one entry (sweep BRW19, 2026-10-26).
  ch_peek_cache = {}
end

local function chain_save_named(tr, pad, v, slot, name)
  name = chain_name_clean(name)
  if name == "" then return end          -- cancelled, or nothing usable typed
  local folder = ch_rel[slot] or ""
  local path = fx.chain_dir() .. "/" .. (folder == "" and name or (folder .. "/" .. name))
             .. ".RfxChain"
  local f = io.open(path, "r")
  -- `folder` is captured ABOVE and threaded through every branch: the one we
  -- tested for existence is the one we write, even if the browser moved while
  -- the prompt was up.
  if not f then return chain_save_write(tr, pad, v, slot, name, folder) end
  f:close()
  local msg = '"' .. name .. '" already exists. Replace it?'
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.confirm and eon_dlg.confirm({
    title = "Save FX chain", message = msg, ok_label = "Replace",
    on_ok = function() chain_save_write(tr, pad, v, slot, name, folder) end,
  })
  if not shown then
    -- MB type 4 is Yes/No, and its answers are 6 = Yes, 7 = No.
    if reaper.ShowMessageBox(msg, "Save FX chain", 4) == 6 then
      chain_save_write(tr, pad, v, slot, name, folder)
    end
  end
end

local function chain_save_prompt(tr, pad, v, slot)
  if eon_dlg and eon_dlg.busy and eon_dlg.busy() then return end
  local folder = ch_rel[slot] or ""
  -- A default worth keeping: the pad's own name in a pad view (a bank's or a split
  -- pad's caption in theirs), else the track's.
  local def = ""
  if pad ~= nil and pad >= 0 then
    local cap, nm = ciw.caption(slot, pad)
    def = (pad < 16) and nm or cap
  end
  if def == "" and reaper.GetTrackName then
    local _, tn = reaper.GetTrackName(tr)
    def = tn or ""
  end
  def = chain_name_clean(def)
  if def == "" then def = "My Chain" end
  local where = (folder == "") and "saved in FXChains" or ("saved in FXChains/" .. folder)
  local shown = eon_dlg and eon_dlg.available() and eon_dlg.open({
    title = "Save FX chain", ok_label = "Save",
    fields = { { key = "name", label = "Name", value = def, sub = where } },
    on_ok = function(vals) chain_save_named(tr, pad, v, slot, vals.name) end,
  })
  if not shown then
    local okd, nm = reaper.GetUserInputs("Save FX chain", 1,
                                         "Name:,extrawidth=220", def)
    if okd then chain_save_named(tr, pad, v, slot, nm) end
  end
end

local function do_action(slot, verb, a, bnum)
  -- ⚠️ THE SAME RESOLVER THE PUBLISH USES. Acting on a different track than
  -- the one on screen is not a wrong result, it is an invisible one.
  local tr, pad = resolve_target(slot)
  if not tr then return end
  -- A PAD VIEW (Wired, stereo): the target is one pair's slice of Swing's own
  -- track (a pad's, a bank's, a split pad's) and every index the face sends is
  -- a slot IN THAT SLICE. Map it to
  -- the chain index here, once, so no verb below can reach the wrong plugin.
  -- (pad == -1 is the master slice; nil is a whole track, unmapped.)
  local v = (pad ~= nil) and fx.view(tr, pad) or nil
  local ai = a
  if v and a >= 0 then ai = v.idx[a + 1] or -1 end
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
    if ai < 0 then return end
    -- ⭐ TOGGLE, not just open. Clicking the same plugin again closes its
    -- window, which is what a click on an already-open thing means -- and
    -- without it there is no way to dismiss the float from the face at all.
    -- GetFloatingWindow is the precise question ("is it floating RIGHT NOW");
    -- TrackFX_GetOpen also answers true for an FX merely selected in the
    -- chain window.
    local open = false
    if reaper.TrackFX_GetFloatingWindow then
      open = reaper.TrackFX_GetFloatingWindow(tr, ai) ~= nil
    elseif reaper.TrackFX_GetOpen then
      open = reaper.TrackFX_GetOpen(tr, ai)
    end
    reaper.TrackFX_Show(tr, ai, open and 2 or 3)   -- 2 = hide float, 3 = show
    return
  elseif verb == A_EMBED_TCP or verb == A_EMBED_MCP then
    if ai < 0 then return end
    embed_fx(tr, ai, verb == A_EMBED_TCP)
    return
  elseif verb == A_CHAIN_APPLY or verb == A_CHAIN_SAVE then
    if view_slot ~= slot then apply_query(BASE + slot * STRIDE, slot) end   -- PL H4: this slot's rows
    local row = view[a + 1]
    if verb == A_CHAIN_APPLY then
      -- Folders are navigated, not applied. The face already refuses to
      -- send this for a folder row; refusing again here means a stray
      -- action from anywhere cannot wipe a chain with a directory name.
      if row and row.kindix == K_CHAIN then
        if v then fx.view_chain_apply(tr, pad, row.rel, "replace", pad >= 0 and select(2, ciw.caption(slot, pad)) or nil)
        else fx.chain_apply(tr, row.rel, "replace") end
        ch_fp[slot] = nil          -- the chain definitely moved
      end
    else
      -- SAVE asks for a name and writes the target's CURRENT chain into the
      -- folder being browsed, so "save here" means the folder you are looking
      -- at. A pad view saves just that pad's slice, with the pad pins stripped.
      chain_save_prompt(tr, pad, v, slot)
    end
    return
  elseif verb == A_OFFLINE then
    if ai < 0 then return end
    -- The picker engine reads offline but has never written it; one call
    -- rather than a new engine function, since nothing else needs it yet.
    -- The state of the INDEX itself: a Wired insert is a child of its pair's
    -- container (an encoded index), and fx.chain lists the top level only --
    -- looked up there, Offline toggled nothing on any of them (2026-10-12).
    if reaper.TrackFX_GetOffline and reaper.TrackFX_SetOffline then
      reaper.TrackFX_SetOffline(tr, ai, not reaper.TrackFX_GetOffline(tr, ai))
    end
    return
  end
  if verb == A_ENABLE then
    if ai < 0 then return end
    -- The index itself, as for Offline above (a container child is not in fx.chain).
    fx.set_enabled(tr, ai, not reaper.TrackFX_GetEnabled(tr, ai))
  elseif verb == A_REMOVE then
    if ai < 0 then return end
    fx.remove(tr, ai)
  elseif verb == A_MOVE then
    -- M.move is the best-evidenced call in the engine: the REAPER harness
    -- covers down-by-one, 0->3, 3->0 and the duplicate-safe case.
    if bnum >= 0 then
      if v then fx.view_move(tr, pad, a, bnum) else fx.move(tr, a, bnum) end
    end
  elseif verb == A_SWAP or verb == A_INSERT then
    if view_slot ~= slot then apply_query(BASE + slot * STRIDE, slot) end   -- PL H4: this slot's rows
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
      if v then fx.view_swap(tr, pad, a, add) else fx.swap(tr, a, add) end
    else
      -- The name goes along: on REAPER 7 the first insert on a pair makes its
      -- container, "KICK (pad 1)", "Bank B: Toms" or "C3: Snare" (ciw.caption).
      if v then fx.view_insert(tr, pad, add, (a >= 0) and a or nil, pad >= 0 and select(2, ciw.caption(slot, pad)) or nil)
      else fx.insert(tr, add, a >= 0 and a + 1 or nil) end
    end
  end
end

-- Console targeting. The face writes "pad P, slot S" and bumps TGT_SEQ when
-- you click an insert slot on a strip, and Swing's FX tab does the same
-- whenever the selected pad changes; until one of them has, the picker's
-- target is whatever REAPER last touched, which is right for "open the picker
-- on the thing I just clicked" and useless for "this pad, that slot".
--
-- ci_tgt[slot] holds the resolved target AND the pad it aims at. resolve_target
-- re-resolves it from the latest console publish on every tick rather than
-- trusting the track it found first: a pad's track can be deleted or rebuilt
-- underneath us, and a stale pointer would have the picker quietly editing a
-- track that no longer exists.
local TGT_SEQ, TGT_PAD, TGT_SLOT = 142, 143, 144
local TGT_KIND = 57   -- what TGT_PAD names: 0 a console strip, 1 a slot (Swing's FXP_TGT_KIND, Outputs step 3)
-- ⚠️ TGT_PIN and ci_pin USED TO BE DECLARED HERE. Re-declaring them below
-- do_action did not just hide them from it -- a second `local` of the same
-- name is a DIFFERENT table, so even after do_action was taught to read the
-- pin it would have read the empty first one forever while this half wrote
-- the second. They now live once, up beside ci_tgt.

-- A trace of what an aim resolved to, GATED (ExtState EON_FXPICK/trace = "1": the rigs set it; a customer never
-- sees it): slot, the aim's words, the strip band's output block for the aimed slot and the target it became.
-- Appended to <resource>/Data/EON_Swing/fxpick_trace.txt (2026-10-22, EON_Probe_PadPick: an aim at pad 3 named pad 1).
local function tgt_trace(slot, pad, kind, t)
  if reaper.GetExtState("EON_FXPICK", "trace") ~= "1" then return end
  local G = core.GMEM
  local band = G.GS_STRIP_BASE + slot * G.GS_STRIP_STRIDE
  local gen = math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_GEN) or 0)
  local op = pad >= 0 and math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_PAIR + pad) or 0) or -1
  local ow = pad >= 0 and math.floor(reaper.gmem_read(band + G.GS_STRIP_OFF_OUT_WPAIR + pad) or 0) or -1
  local pads = ci_pads[slot]
  local dir = reaper.GetResourcePath() .. "/Data/EON_Swing"
  reaper.RecursiveCreateDirectory(dir, 0)
  local f = io.open(dir .. "/fxpick_trace.txt", "a")
  if not f then return end
  f:write(("%s slot=%d aim pad=%d kind=%d | gen=%d out_pair=%d out_wpair=%d | pads=%s swing_tr=%s pads[0]=%s pair0=%s | -> pad=%s aim=%s kind=%s tr=%s\n"):format(
    os.date("%H:%M:%S"), slot, pad, kind, gen, op, ow, tostring(pads ~= nil), tostring(pads and pads.swing_tr ~= nil),
    tostring(pads and pads[0] ~= nil), tostring(pads and pads.pair and pads.pair[0] ~= nil),
    tostring(t and t.pad), tostring(t and t.aim), tostring(t and t.kind), tostring(t and t.tr ~= nil)))
  f:close()
end

local function consume_target(slot)
  local b = BASE + slot * STRIDE
  local seq = math.floor(reaper.gmem_read(b + TGT_SEQ) or 0)
  if seq == 0 or seq == ci_tgt_seq[slot] then return end
  ci_tgt_seq[slot] = seq
  local pad = math.floor(reaper.gmem_read(b + TGT_PAD) or -1)
  -- pad_target indexes the pad tracks the console publisher resolved, so the
  -- two sides cannot disagree about which track a pad means. ⚠️ An aim that
  -- cannot resolve yet is KEPT, not dropped -- a Swing that registered a moment
  -- ago is not in ci_pads until the next publish (<= 0.5 s). Dropping it left
  -- REAPER's last-touched track on screen until something aimed again, and the
  -- FX tab never re-aims at a pad it already asked for. resolve_target retries.
  local kind = math.floor(reaper.gmem_read(b + TGT_KIND) or 0)
  ci_tgt[slot] = pad_target(slot, pad, kind) or { aim = pad, kind = kind }
  tgt_trace(slot, pad, kind, ci_tgt[slot])
  local sel = math.floor(reaper.gmem_read(b + TGT_SLOT) or -1)
  reaper.gmem_write(b + CH_SEL, sel)
  ch_fp[slot] = nil            -- force a republish for the new target
end

-- ⚠️ ABOVE publish_chain, which calls it (PL H14): a local function is an
-- upvalue only for code compiled after it.
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

local function publish_chain(slot)
  -- ⚠️ Resolve the pin BEFORE the fingerprint gate below, which returns early:
  -- latching has to happen on every tick, not only on ticks that republish.
  -- The pin latches the whole target, view included, so a pinned pad stays
  -- that pad's slice and not the Swing track it lives on.
  local pin = math.floor(reaper.gmem_read(BASE + slot * STRIDE + TGT_PIN) or 0)
  if pin == 1 then
    if not ci_pin[slot] then
      local t = ci_tgt[slot]
      if t then ci_pin[slot] = { tr = t.tr, pad = t.pad }
      else ci_pin[slot] = { tr = reaper.GetLastTouchedTrack() } end
    end
  else
    ci_pin[slot] = nil
  end
  if ci_pin[slot] and not (ci_pin[slot].tr
     and reaper.ValidatePtr2(0, ci_pin[slot].tr, "MediaTrack*")) then
    ci_pin[slot] = nil
  end
  -- ⭐ THE SHARED RESOLVER — the one do_action fires at. What is drawn and
  -- what is acted on are now the same track (and the same slice) by construction.
  local tr, pad = resolve_target(slot)
  -- A target that has since been deleted must not be handed to the API.
  if not tr then
    pad = nil
    if not (ci_tgt[slot] and ci_tgt[slot].aim ~= nil) then
      tr = reaper.GetLastTouchedTrack()
      ci_tgt[slot] = nil
      if tr and not reaper.ValidatePtr2(0, tr, "MediaTrack*") then tr = nil end
    end
    -- An AIMED pad that cannot resolve right now shows NO track, not whatever
    -- REAPER touched last: do_action refuses every verb while resolve_target
    -- returns nil, so a stranger's chain on screen would only invite clicks
    -- that do nothing. The aim stays; resolve_target keeps retrying it.
  end
  local tname, tnum, tcol = "", 0, -1
  if tr then
    tnum = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER") or 0)
    -- I_CUSTOMCOLOR carries a flag bit above the colour; 0 means "no custom
    -- colour", which must stay distinguishable from black. ColorFromNative
    -- because the packing is OS-dependent -- reading the bytes directly works
    -- on Windows and gives blue-for-red on Mac.
    local c = math.floor(reaper.GetMediaTrackInfo_Value(tr, "I_CUSTOMCOLOR") or 0)
    if c ~= 0 then
      local cr, cg, cb = reaper.ColorFromNative(c % 0x1000000)
      tcol = cr * 65536 + cg * 256 + cb
    end
    local ok, nm = reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    tname = ascii_fold((ok and nm ~= "" and nm) or ("Track " .. tnum))
  end
  tgt_none[slot]   = (tr == nil)
  local ch, v = {}, nil
  if tr then
    if pad ~= nil then ch, v = fx.chain_view(tr, pad) else ch = fx.chain(tr) end
  end
  -- A view is named for what it is, so the chain column says WHOSE inserts
  -- these are: "KICK (pad 1)", "Bank B: Toms" (every bank B pad on its bank's
  -- pair), "C3: Snare" -- not the name of the track they all share.
  if v then
    if pad >= 0 then
      tname = ascii_fold((ciw.caption(slot, pad)))
    else
      tname = ascii_fold(tname .. " (master)")
    end
  end
  -- ⚠️ tnum IS IN THE FINGERPRINT. Reordering tracks changes the number while
  -- the name stays put; without it here the republish never fires and the face
  -- shows a number that moved. The view's absolute indices are in it too: a
  -- re-pin moves a plugin between slices without changing any name.
  local parts = { tname, tnum, tcol, #ch, tostring(pad) }
  for _, e in ipairs(ch) do
    -- Offline belongs in the fingerprint too: without it, toggling offline
    -- changes nothing the bridge can see and the republish never happens.
    parts[#parts + 1] = e.name .. (e.enabled and "1" or "0")
                                .. (e.offline and "F" or "-")
                                .. ":" .. tostring(e.idx)
  end
  local fp = table.concat(parts, string.char(31))
  if fp == ch_fp[slot] then return end
  ch_fp[slot] = fp
  -- Frozen is read HERE, below the fingerprint gate -- not per tick. The chunk
  -- of a loaded track is not small, and this sat ABOVE the gate while its
  -- comment said otherwise: a full GetTrackStateChunk per tick for every slot
  -- that ever asked, ~30x/s (sweep BRW2, 2026-10-26). A freeze empties the live
  -- chain, so the fingerprint moves and the flag is re-read; publish() sends
  -- it with the next page.
  tgt_frozen[slot] = track_frozen(tr)

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
    -- PL H14: the card hash of the FORTY-character name, one word per entry
    -- after the records (CHAIN_HASH). An entry carries only CNAME_MAX characters
    -- and the deck is keyed on forty, so the face could not find 177 cards by
    -- itself -- the console inserts' CI_HASH, for the same reason.
    reaper.gmem_write(b + CHAIN_HASH + i - 1, card_hash(nm:sub(1, NAME_MAX)))
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
local CI_FMT, CI_FMT_VER = 3, 3
-- CI_BANK (header word 4, step 5): the bank on screen the sixteen strip records
-- were built for -- record i is strip i of that bank (its slot's track, or its
-- slot's Wired container). Version 3 = records keyed by the bank on screen.
local CI_BANK = 4
-- 17 records: the sixteen STRIPS, then the MASTER as record 16. It used to ride in the
-- header's spare words; with names the records are big enough that it is
-- simpler, and one less special case, for the master to just BE a record --
-- the same publish loop and the same draw call handle it.
local CI_RECS = 17
-- Instance registry: iid -> slot. Same table eon_action_target.lua reads.
local REG_BASE, REG_STRIDE, REG_MAX, REG_TIMEOUT = 2556, 4, 16, 3.0
local ci_fp = {}

local function ci_is_swing(tr, fx)
  return core.is_swing_fx(tr, fx)   -- the plugin's file, never its shown name (the bridge's rule)
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
local function ci_words(tr, ch)
  local out, nm, hs = {}, {}, {}
  for i = 1, math.min(CI_NSLOT, #ch) do
    local e = ch[i]
    -- e.cat is the bucket the engine resolved for this slot when it read the
    -- chain (category_fx on e.idx, the ABSOLUTE chain index -- a view's entries
    -- are a subset of the track's chain). It was resolved a second time here,
    -- another two recipe scans per slot every half second (sweep BRW31).
    local cat = bucket_ix(e.cat)
    out[i] = cat + (e.enabled and 0 or 64) + (e.offline and 128 or 0)
    -- e.name is ALREADY the shortened display name the picker list uses
    -- (fx.parse_name strips vendor and format). Truncating that beats
    -- inventing a second way to abbreviate, which would eventually disagree
    -- with the picker about what a plugin is called.
    nm[i] = (e.name or ""):sub(1, CI_NCHAR)
    -- ⚠️⚠️ FORTY CHARACTERS, not the whole string. The card table is keyed on
    -- `hkey(name[:40])` and the face hashes `min(40, len)` -- both because the
    -- published name field is 40 wide -- so hashing the FULL name here missed
    -- every plugin with a longer name than that.
    -- ⚠️ FOLDED FIRST, as publish() and publish_chain() hash it: the card table
    -- is keyed on forty CHARACTERS and :sub counts BYTES, so a name with an
    -- em dash (three bytes) was cut two characters short of its key and never
    -- found its card in a mixer insert slot (sweep BRW21, 2026-10-26).
    hs[i] = card_hash(ascii_fold(e.name or ""):sub(1, NAME_MAX))
  end
  return out, #ch, nm, hs
end
local function ci_pad_words(tr) return ci_words(tr, fx.chain(tr)) end

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
            -- pad index. Same mapping the kit bridge colours lanes by -- and
            -- since Outputs step 3 the same OWNER test (core.swing_send_pair):
            -- a send whose destination is not one of Swing's own output tracks
            -- is no pad's (a user's bus fed from channels 1-2 took pad 1's
            -- console strip, the LAST send winning). pads.pair[p] = the bank
            -- and split-pad tracks (pairs 19..31), for the FX tab's slot aims.
            local pads, nsend = { pair = {} }, reaper.GetTrackNumSends(tr, 0)
            local no_sws = false
            for s = 0, nsend - 1 do
              -- ⚠️ BR_GetMediaTrackSendInfo_Track is SWS. Without it this
              -- resolved NOTHING and every pad published as "owns no
              -- track" -- indistinguishable from a project that simply is
              -- not in multi-out, with no error anywhere.
              if reaper.BR_GetMediaTrackSendInfo_Track then
                local p, dest = core.swing_send_pair(tr, s)
                if p >= 0 and p < 16 then pads[p] = pads[p] or dest
                elseif p >= 16 then pads.pair[p] = pads.pair[p] or dest end
              else
                local c = core.srcchan_pad(reaper.GetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN"))
                if c >= 0 and c < 16 then no_sws = true end
              end
            end

            -- STEREO: no pad tracks at all. A pad's inserts are then its
            -- WIRED slice of Swing's OWN track -- the plugins between Swing
            -- and the Patchbay pinned to the pad's channel pair (fx.view) --
            -- so that is what the strips show, and what a click on one will
            -- target (consume_target reads pads.swing_tr). Whether Wired is
            -- actually ON goes out as a flag: the slots are live either way,
            -- but inserts under a switched-off Wired are silent and the face
            -- has to say so.
            local stereo = nsend < 16
            local wired = false
            if stereo then
              pads.swing_tr = tr
              for i = 0, reaper.TrackFX_GetNumParams(tr, fxi) - 1 do
                local ok, nm = reaper.TrackFX_GetParamName(tr, fxi, i, "")
                if ok and nm:find("Wired (", 1, true) then
                  wired = (reaper.TrackFX_GetParam(tr, fxi, i) or 0) >= 0.5
                  break
                end
              end
            end

            -- Build the whole payload first, fingerprint it, and only touch
            -- gmem when something actually changed. Sixteen chains re-read per
            -- tick is fine; sixteen chains re-WRITTEN per tick would make the
            -- face's seq-gate fire every frame for no reason.
            -- Step 5: record i is STRIP i of the bank on screen (CI_BANK), i.e.
            -- slot bank*16 + i: the track its pair plays on in multi-out (bank
            -- A's pad, its bank's, its split track), the Wired container of the
            -- pair it rides in stereo. Bank A's strips by position, as before.
            ciw.names_tick(slot)
            local u = ciw.read_out(slot)
            local bank = math.floor(reaper.gmem_read(core.GMEM.GS_INST_BANK_CUR + slot) or 0)
            if bank < 0 or bank > 3 then bank = 0 end
            local rec, fpp = {}, { "B:" .. bank }
            for pad = 0, 15 do
              local o = bank * 16 + pad
              local p = u and u.pair[o]
              if p == nil and o < 16 then p = o end      -- an older Swing: bank A by position
              local ptr = p and ((p < 16) and pads[p] or pads.pair[p])
              local wp = u and u.wpair[o]
              if wp == nil and o < 16 then wp = o end
              if ptr then
                local w, n, nm, hs = ci_pad_words(ptr)
                rec[pad] = { n = n, w = w, nm = nm, hs = hs }
                fpp[#fpp + 1] = pad .. ">" .. p .. ":" .. n .. ":" .. table.concat(w, ",")
                                    .. ":" .. table.concat(nm, ",")
              elseif stereo and wp then
                local w, n, nm, hs = ci_words(tr, (fx.chain_view(tr, wp)))
                rec[pad] = { n = n, w = w, nm = nm, hs = hs }
                fpp[#fpp + 1] = pad .. "=" .. wp .. ":" .. n .. ":" .. table.concat(w, ",")
                                    .. ":" .. table.concat(nm, ",")
              else
                rec[pad] = { n = -1, w = {}, nm = {}, hs = {} }
                fpp[#fpp + 1] = pad .. ":-1"
              end
            end
            -- Every pair container on Swing's track follows its name -- a pad's,
            -- a bank's, a split pad's owner (renamed pads, kit loads, a new owner);
            -- one pass finds them all, whichever bank is on screen. A split pair
            -- with no known owner keeps the name it has.
            if stereo then
              for p, c in pairs(fx.pair_containers(tr)) do
                local _, nm, known = ciw.caption(slot, p, u)
                if known then fx.name_pad_container(tr, p, nm, c) end
              end
            end

            -- MASTER: whatever Swing's summed output actually passes through,
            -- which depends on the ROUTING and not on a preference.
            --   multi-out — the pads left as 16 separate outputs and sum on
            --     their PARENT track. That folder is the desk's master.
            --   stereo    — they summed inside Swing, so the master is the
            --     rest of Swing's own chain: minus Swing itself, minus the
            --     Patchbay, minus every pad-pinned plugin (those are the pad
            --     slices above). A view too, so a click targets the same slice.
            local mtr, mrec
            for pad = 0, 15 do
              if pads[pad] then mtr = reaper.GetParentTrack(pads[pad]) break end
            end
            -- Since Outputs step 2 bank A's pads sit in a "Bank A" folder; the
            -- desk's master is the folder over every bank (Audio), as before.
            if mtr then
              local _, bf = reaper.GetSetMediaTrackInfo_String(mtr, "P_EXT:EON_BANK_FOLDER", "", false)
              if bf == "A" then mtr = reaper.GetParentTrack(mtr) or mtr end
            end
            if mtr then
              pads.master, pads.master_pad = mtr, nil
              local mw, mn, mnm, mhs = ci_pad_words(mtr)
              mrec = { n = mn, w = mw, nm = mnm, hs = mhs }
            elseif stereo then
              pads.master, pads.master_pad = tr, -1
              local mw, mn, mnm, mhs = ci_words(tr, (fx.chain_view(tr, -1)))
              mrec = { n = mn, w = mw, nm = mnm, hs = mhs }
            else
              pads.master, pads.master_pad = tr, nil
              local mw, mn, mnm, mhs = ci_pad_words(tr)
              mrec = { n = mn, w = mw, nm = mnm, hs = mhs }
            end
            -- Hand the resolved tracks to the targeting path so a console
            -- click and this publish cannot disagree about which track a pad
            -- means. Re-stashed every publish, never cached across one: a pad
            -- track can be deleted or rebuilt underneath us.
            ci_pads[slot] = pads
            rec[16] = mrec   -- master = rec 16
            fpp[#fpp + 1] = "M:" .. mrec.n .. ":" .. table.concat(mrec.w, ",")
                                .. ":" .. table.concat(mrec.nm, ",")
            -- bit0: pads can take inserts (multi-out tracks, or the Wired
            --       slices of Swing's own track in stereo).
            -- bit1: could not look the pad tracks up at all (no SWS).
            -- bit2: stereo -- the inserts live on Swing's own track.
            -- bit3: ...and Wired is OFF, so they are silent right now.
            -- The face needs to tell these apart -- "you are not in
            -- multi-out" and "I cannot see" are different sentences.
            local flags = ((nsend >= 16 or stereo) and 1 or 0) + (no_sws and 2 or 0)
                        + (stereo and 4 or 0) + ((stereo and not wired) and 8 or 0)
            fpp[#fpp + 1] = "F:" .. flags

            -- ⚠️ HEARTBEAT IS UNCONDITIONAL, outside the change gate below.
            -- A heartbeat says "I am here", never "something happened".
            -- A COUNTER, not a clock: the face has no wall clock to compare
            -- against; all it needs is whether the number moved.
            ci_beat = (ci_beat or 0) + 1
            reaper.gmem_write(CI_BASE + slot * CI_STRIDE + CI_HB, ci_beat)

            local fp = table.concat(fpp, "|")
            if ci_fp[slot] ~= fp then
              ci_fp[slot] = fp
              local b = CI_BASE + slot * CI_STRIDE
              local seq = math.floor((reaper.gmem_read(b + CI_SEQ) or 0) / 2) * 2 + 2
              reaper.gmem_write(b + CI_SEQ, seq - 1)     -- ODD: mid-write
              reaper.gmem_write(b + CI_FMT, CI_FMT_VER)
              reaper.gmem_write(b + CI_FLAGS, flags)
              reaper.gmem_write(b + CI_BANK, bank)
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
  -- A bank switch re-keys that console's strips (CI_BANK): publish now, not
  -- within the half second -- the face draws no inserts until the records match.
  for s in pairs(ci_pads) do
    local bk = math.floor(reaper.gmem_read(core.GMEM.GS_INST_BANK_CUR + s) or 0)
    if bk ~= ciw.bank_seen[s] then ciw.bank_seen[s] = bk; ci_last = 0 end
  end
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

local function fxpick_self_register()
  -- Probe/host opt-out. Registration records get_action_context()'s path — the
  -- HOSTING script, not this file — so a harness that dofile'd us would install
  -- ITSELF as a startup action. The kit bridge learned this the hard way.
  if reaper.GetExtState("EON_Bridge", "no_self_register") == "1" then return end
  local _, script_path = reaper.get_action_context()
  local NAME = "EON_FXPicker_Bridge"
  local key = NAME .. "_registered_v5"   -- v5 (2026-10-14): the block checks the script file (every install re-registers once)
  local marker = "-- EON:" .. NAME
  -- A rewrite that failed half-way may have left the file stepped aside as
  -- .eon-prev; put it back before anything below reads it. If it cannot be put
  -- back, do NOTHING this run: registering anyway would read an empty file
  -- and, once the hold lifts, the writer's own recovery would restore the
  -- original only for the write to replace it with a file holding just our
  -- block (Codex 2026-09-23). The next run retries.
  if not eon_recover_startup(reaper.GetResourcePath() .. "/Scripts/__startup.lua") then return end

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
  local had_block
  existing, had_block = eon_strip_startup_block(existing, NAME)

  -- Named command ids ("_RSxxxxx") survive action-list rebuilds; the raw int
  -- does not, so prefer the token.
  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  -- Self-cleaning: when the action is gone (a ReaPack uninstall: the lookup
  -- returns 0) or the script file is gone while the action stays (a folder
  -- deleted by hand, 2026-10-14), the block removes itself and clears the
  -- ExtState so a reinstall registers fresh. Runs at most once. %q: a ]] in
  -- the path would end a long bracket.
  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    string.format("local sf=io.open(%q,'r'); if sf then sf:close() end\n", script_path) ..
    "if id~=0 and sf then reaper.Main_OnCommand(id,0) else\n" ..
    eon_startup_selfclean_src(NAME, NAME, key) ..
    "end end\n" ..
    marker .. " END\n"

  -- Flag registered only once the block is really on disk; a failed write
  -- leaves the ExtState clear so the next run simply retries.
  if eon_write_startup(startup_path, existing .. block) then
    reaper.SetExtState(NAME, key, "1", true)
    -- Only a genuine first registration speaks: replacing an existing block (every
    -- updated install after a key bump) must not pop the console open for users.
    if not had_block then
      reaper.ShowConsoleMsg("[EON] " .. NAME ..
        " registered as startup action (auto-cleans on uninstall).\n")
    end
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
