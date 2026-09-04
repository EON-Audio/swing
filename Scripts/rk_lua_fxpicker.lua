-- rk_lua_fxpicker.lua -- EON FX Picker, P1 engine (headless; no UI, no gmem).
--
-- Spec: .docs/specs/Spec_FX_Picker.md ("P1 -- engine (Lua, no UI)").
-- Everything the picker needs to know or change about an FX chain lives here,
-- so P2's big view and P4's LCD page are pure front ends over this API.
--
-- WHY ITS OWN MODULE (spec lists Swing_Kit_Bridge.lua): the bridge is ~17k lines
-- and carries 156 of Lua's 200 top-level locals, and it is contended across
-- concurrent sessions. Same folder, same `require` path, none of that risk.
--
-- API
--   -- registry (rung 1+3 of the category ladder)
--   M.registry(opts)             -> rows { name, vendor, fmt, path, ident, cat,
--                                          key, kind }
--                                   AUDIO EFFECTS ONLY by default; opts =
--                                   true (rebuild) | { force, kinds = {...} }
--                                   | { kinds = "all" }
--   M.registry_kinds(force)      -> { fx, instrument, midi, other, total }
--   M.search(q, opts)            -> filtered rows (opts.cat/.fmt/.limit/.kinds)
--   M.kind(name, ident, fmt, path) -> "fx" | "instrument" | "midi" | "other"
--   M.parse_name(disp, ident)    -> name, vendor, fmt, path
--   M.category(name, ident)      -> bucket        (uninserted plugin)
--   M.subcategory(name, ident)   -> free-text sub, or "" (curated list only)
--   M.category_fx(tr, idx)       -> bucket        (live slot; adds rung 2)
--   -- chain
--   M.chain(tr)                  -> slots { idx, name, vendor, fmt, ident, cat,
--                                           enabled, offline }
--   M.insert(tr, add, pos)       -> idx | nil, err
--   M.remove(tr, idx)            -> true | nil, err
--   M.move(tr, from, to)         -> true | nil, err
--   M.swap(tr, idx, add)         -> idx | nil, err
--   M.set_enabled(tr, idx, on)   -> true | nil, err
--   -- .RfxChain
--   M.chain_dir()                -> absolute FXChains path
--   M.chain_list(rel)            -> { dirs = {...}, files = {...} }
--   M.chain_apply(tr, rel, mode) -> true | nil, err   mode "append" | "replace"
--   M.chain_save(tr, rel)        -> true | nil, err
--
-- Indices are 0-based throughout, matching the ReaScript FX API. Lua arrays
-- returned by chain()/registry() are 1-based; each row carries its own `.idx`.
--
-- UNDO (spec hard rule): every mutation is wrapped in exactly ONE
-- Undo_BeginBlock/EndBlock pair -- one undo point per user gesture, never per
-- API call, so a swap (insert + move + delete) undoes as a single step. This
-- module NEVER touches Swing's own undo stack: REAPER's undo owns FX chains,
-- Swing's UNDO button owns kit/pad state, and the two never merge.
--
-- (c) EON Studios -- All Rights Reserved

local M = {}
local r = reaper

local recipes = nil
do local ok, m = pcall(require, "rk_lua_fx_recipes"); if ok then recipes = m end end

M.BUCKETS = recipes and recipes.BUCKETS or {
  "comp", "eq", "sat", "verb", "delay", "limit", "strip", "pitch", "amp",
  "util", "gate", "mod", "filter", "meter", "width", "tape", "time", "clip",
  "bass", "de-ess", "summing", "no-guess",
}
M.NO_GUESS = "no-guess"

-- Diagnostics the P1 test asserts on. move_retry > 0 means REAPER's
-- TrackFX_CopyToTrack destination convention is not what we computed -- see
-- M.move. Surfaced rather than swallowed: it is the one API semantic in this
-- module that could not be verified without REAPER.
M.stats = { move_retry = 0, move_fail = 0 }

-- ── helpers ────────────────────────────────────────────────────────────────

-- Match key: lowercase, punctuation collapsed to single spaces. MUST stay
-- identical to norm() in .dev_fxpicker/gen_recipe_table.py or the baked keys
-- stop matching.
local function norm(s)
  s = (s or ""):lower()
  s = s:gsub("[^a-z0-9]+", " ")
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- True when `pat` appears in `hay` at a TOKEN START, as a prefix of that token.
-- Token-start anchoring is what keeps "preamp" out of the amp bucket and
-- "frequency" out of eq; prefix-within-the-token is what lets one pattern cover
-- saturate/saturator/saturation.
--
-- ⚠️ Both halves must use the SAME rule. An earlier version anchored the first
-- token exactly (`pat .. " "`) while allowing later tokens to prefix-match, so
-- "Vintage Compressor" classified and a plugin named plain "Compressor" did
-- not -- along with "Limiter", "Saturator", "Reverb" and every other
-- single-word name in the library. Measured on a real 1120-plugin install
-- (.dev_fxpicker/score_classifier.py), that inconsistency alone was most of the
-- unresolved pile.
local function tok(hay, pat)
  if hay:sub(1, #pat) == pat then return true end        -- first token
  return hay:find(" " .. pat, 1, true) ~= nil            -- any later token
end

-- ── format + name parsing ──────────────────────────────────────────────────
-- EnumInstalledFX hands back a decorated display name ("VST3: Pro-Q 3
-- (FabFilter)") and an ident (a path, or a JS relative path). Split it into the
-- three things every surface wants: bare name, vendor, format.

local PREFIX = { "VST3i", "VST3", "VSTi", "VST", "CLAPi", "CLAP", "AUi", "AU",
                 "LV2i", "LV2", "DXi", "DX", "JS" }

function M.parse_name(disp, ident)
  disp = disp or ""
  local fmt, name = nil, disp
  for _, p in ipairs(PREFIX) do
    if disp:sub(1, #p + 1):upper() == p:upper() .. ":" then
      fmt = p
      name = disp:sub(#p + 2):gsub("^%s+", "")
      break
    end
  end
  if not fmt then
    local e = (ident or ""):lower()
    fmt = e:find("%.vst3") and "VST3" or e:find("%.clap") and "CLAP"
       or e:find("%.dll") and "VST"  or e:find("%.jsfx?$") and "JS" or "?"
  end

  -- JSFX display as `Description [relative/path.jsfx]`, sometimes with an
  -- author group too: `Thing  [author] [path]`. Peel the trailing bracket
  -- groups off and keep the LAST one as the path.
  --
  -- ⚠️ This is not cosmetic. Leaving the path in the name feeds FOLDER NAMES
  -- into every name test downstream: "ReaRack2 - Filter [ReaTeam JSFX/Synth/
  -- ReaRack Modular Synth/...]" reads as an instrument because its folder is
  -- called Synth, and "TK Scale Filter [TK Scripts/Midi/...]" reads as a MIDI
  -- tool for the same reason. The name is what the user sees and what should
  -- decide; the path is metadata, kept separately for a last-resort fallback.
  local path = nil
  local trimmed = name:gsub("%s+$", "")
  while true do
    local head, group = trimmed:match("^(.-)%s*%[([^%[%]]*)%]$")
    if not head or head == "" then break end
    path = path or group          -- first peeled = rightmost = the file path
    trimmed = head:gsub("%s+$", "")
  end
  if path then name = trimmed end

  -- trailing "(Vendor)" -- REAPER appends one for VST/VST3.
  local vendor = nil
  local base, v = name:match("^(.-)%s*%(([^()]+)%)%s*$")
  if base and base ~= "" then name, vendor = base, v end
  return name, vendor, fmt, path
end

-- ── category: rung 1 (recipe DB) ───────────────────────────────────────────
-- ROWS arrive pre-sorted longest-key-first, so the first token hit is also the
-- most specific one ("pro c 2" before "pro c"). No runtime sort.

-- Exact hash on the ident. JSFX rows in the hand-edited list are keyed on their
-- PATH rather than their name, because a display name changes the moment its
-- author edits the desc: line and the path does not. Lowercased, forward
-- slashes, both sides.
local function path_row(ident)
  if not recipes or not recipes.PATHS or not ident or ident == "" then return nil end
  return recipes.PATHS[(ident:gsub("\\", "/")):lower()]
end

-- Token-prefix scan over the name-keyed rows: the card recipes plus every
-- commercial plugin in the list. Pre-sorted longest-first, so the first hit is
-- also the most specific.
--   returns bucket, subcategory, kind
-- ⚠️ A SINGLE-WORD curated key must match EXACTLY, never as a prefix. The list
-- holds real product names, and some are one short common word: a row for the
-- plugin called "Tape" was swallowing "Tape Echo", which is a delay. Multi-word
-- keys keep prefix matching, which is what lets the card row "pro c" cover
-- "Pro-C 2". 316 of the keys are single-token, so this is not a corner case.
-- ⚠️ CURATED NAME ROWS MATCH EXACTLY. Nothing else is safe: a row is a claim
-- about ONE product, and every looser rule leaked in measurement --
--   prefix-anywhere : "Manipulator" (a real Polyverse pitch plugin) captured
--                     "Stereo Field Manipulator", which is a width tool
--   prefix-from-start: "Tape" captured "Tape Echo", which is a delay
-- Exact matching cost exactly one row on the real 1120 (ReaSurroundPan, which
-- simply wants its own entry) and fixed two wrong ones. When a variant needs
-- covering, ADD A ROW -- that is what the list is for.
local function row_hit(key, rk)
  return key == rk
end

local function recipe_row(key, alt)
  if not recipes then return nil end
  for i = 1, #recipes.ROWS do
    local rk = recipes.ROWS[i][1]
    if row_hit(key, rk) or (alt and alt ~= key and row_hit(alt, rk)) then
      local r = recipes.ROWS[i]
      return r[2], r[3], r[4]
    end
  end
  return nil
end

-- REAPER can hand back a name carrying TWO parenthetical groups -- the real
-- one is "ReaFir (FFT EQ+Dynamics Processor) (Cockos)", where the last is the
-- vendor and the middle is a description, not part of the product name. So
-- alongside the full key we try the name cut at its first "(".
local function core_key(name)
  local head = (name or ""):match("^([^(]+)")
  return head and norm(head) or nil
end

local function recipe_cat(key, alt)
  local cat = recipe_row(key, alt)
  return cat
end

-- ── category: rung 3 (name classifier) ─────────────────────────────────────
-- ORDER IS THE ALGORITHM. Specific before general: "limiter" must lose to
-- limit, not win comp; "tape echo" is a delay before it is a tape. Patterns are
-- token-prefix matched (see tok), so "saturat" catches saturation/saturator
-- while "amp" cannot catch "preamp".

-- Every edit below was MEASURED against a real 1120-plugin install with
-- .dev_fxpicker/score_classifier.py, not reasoned about. Where a pattern is
-- narrowed (e.g. "dynamic" -> "dynamics") it is because the broad form was
-- provably stealing rows; where one is deleted it is because it had no
-- dependents worth its false positives.
local CLASSIFY = {
  { "de-ess",  { "deess", "de ess", "esser", "sibil" } },
  -- "loud" caught anything loudness-ish including meters; the three real stems
  -- keep LoudMax / Louderizer / Loudener without the collateral.
  { "limit",   { "limit", "maximi", "brickwall", "brick wall", "ceiling",
                 "loudmax", "louder", "louden" } },
  { "gate",    { "gate", "expander", "noisegate", "downward" } },
  -- no "convolution"/"convolver": every real convolution reverb in the corpus
  -- also says "reverb" or "verb", so the pair only added amp-IR false hits.
  { "verb",    { "reverb", "verb", "hall", "plate", "chamber",
                 "room", "ambience", "space" } },
  { "delay",   { "delay", "echo", "slapback", "slap" } },
  { "tape",    { "tape", "reel", "cassette", "vinyl", "wow", "flutter", "varispeed" } },
  { "clip",    { "clip", "clipper", "bitcrush", "bit crush", "decimat", "redux",
                 "lofi", "lo fi", "crusher" } },
  -- "harmoni" never matched "Harmony" (token-prefix, not substring), so the
  -- Waves/Antares harmony boxes fell through. Both stems, explicitly.
  { "pitch",   { "pitch", "tune", "tuner", "harmoniz", "harmony", "octav",
                 "formant", "shifter", "autotune", "vocode" } },
  -- comp and mod BOTH move above amp: "Vulf Compressor" and "Ring Modulator"
  -- were losing to amp's "amp"/"cab" stems. comp stays above mod.
  { "comp",    { "comp", "compress", "1176", "la 2a", "la2a", "opto", "vca",
                 "fet", "vari mu", "varimu", "dynamics", "glue", "leveler",
                 "levelling" } },
  { "mod",     { "chorus", "flang", "phaser", "tremolo", "vibrato", "ensemble",
                 "rotary", "leslie", "modulat", "lfo", "wobble", "auto pan",
                 "autopan", "panner" } },
  { "amp",     { "amp", "amplifier", "cabinet", "cab", "stomp", "pedal",
                 "guitar", "bassman", "combo" } },
  -- Summing / console emulation is its own thing: a channel+bus pair that
  -- colours the sum. It is NOT a channel strip (no EQ, no dynamics) and not
  -- plain saturation (it works as a matched pair across the whole mix).
  -- Sits ABOVE strip so "Console Bus" does not read as a desk channel.
  -- ⚠️ Most of these cannot be caught by name at all -- Airwindows calls them
  -- Cora, Elsa, GenesisBus -- so the curated list carries the real weight here.
  { "summing", { "summing", "sum bus", "sumbus", "mixbus", "mix bus",
                 "console bus", "console channel", "console color",
                 "console colour" } },
  -- bare "channel" outranked comp and eq on 16 rows that were not strips at
  -- all ("SUM CHANNEL", "Channel Twister"). "console" still covers the desks.
  { "strip",   { "strip", "console", "channel strip" } },
  { "eq",      { "eq", "equali", "tilt", "shelf", "bell", "parametric",
                 "passive" } },   -- no "graphic": it ate "Graphical Waveshaper",
                                  -- and "equali" already covers Graphic Equalizer
  { "sat",     { "saturat", "distort", "drive", "overdrive", "tube", "valve",
                 "exciter", "fuzz", "warm", "colour", "color", "preamp",
                 "harmonic", "grit", "dirt", "waveshap", "wave shap" } },
  { "filter",  { "filter", "lowpass", "highpass", "low pass", "high pass",
                 "resonat", "wah", "allpass", "comb", "formant" } },
  { "width",   { "width", "widen", "stereo", "imag", "mid side", "midside",
                 "spread", "haas", "mono maker" } },
  { "bass",    { "bass", "sub", "low end", "subharmonic" } },
  { "meter",   { "meter", "analy", "spectrum", "scope", "lufs", "loudness",
                 "correlat", "phase scope", "goniometer", "vu" } },
  -- util is TERMINAL, so additions here can only pull rows out of no-guess --
  -- they cannot steal from any bucket above. That is why the long tail of
  -- housekeeping words lives here rather than being spread upward.
  { "util",    { "util", "gain", "trim", "volume", "phase", "invert", "mono",
                 "stream", "insert", "router", "routing", "send", "mixer",
                 "transient", "rider", "dither", "splitter", "joiner",
                 "crossover", "noise generat", "tone generat", "denois",
                 "noise reduc", "polarity", "switcher", "downmix", "upmix" } },
}

local function classify(key)
  for i = 1, #CLASSIFY do
    local bucket, pats = CLASSIFY[i][1], CLASSIFY[i][2]
    for j = 1, #pats do
      if tok(key, pats[j]) then return bucket end
    end
  end
  return nil
end

-- ── category: rung 2 (plugin-declared) ─────────────────────────────────────
-- ⛔ VERIFIED EMPTY on REAPER 7.x (2026-08-27, .dev_fxpicker/test_p1_reaper.lua).
-- A live VST3 and a live VST were asked for fx_category, vst_category, category
-- and fx_subcategory: every one returned nothing. The only keys that answer are
-- fx_type (a FORMAT -- "VST3" -- not a category), fx_ident and fx_name, all of
-- which EnumInstalledFX already gives us. So this rung contributes NOTHING
-- today and the name classifier below carries the whole long tail.
--
-- It is kept, unchanged and guarded, for exactly two reasons: a future REAPER
-- may start answering, and the call costs one guarded pcall on a path that only
-- runs for chain slots. If it ever does answer, DECLARED below is the mapping.
--
-- This rung also needs an INSTANTIATED FX -- EnumInstalledFX yields only name +
-- ident -- which is why there are two entry points: category() for registry
-- rows, category_fx() for live slots.

local DECLARED = {
  reverb = "verb", delay = "delay", dynamics = "comp", distortion = "sat",
  eq = "eq", equalizer = "eq", filter = "filter", pitch = "pitch",
  mastering = "limit", analyzer = "meter", spatial = "width",
  modulation = "mod", generator = "util", restoration = "util",
  tools = "util", surround = "util", network = "util",
}

local function declared_cat(tr, idx)
  if not r.TrackFX_GetNamedConfigParm then return nil end
  local ok, got, val = pcall(r.TrackFX_GetNamedConfigParm, tr, idx, "fx_category")
  if not ok or not got or not val or val == "" then return nil end
  for raw in tostring(val):lower():gmatch("[^|/,]+") do
    local piece = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if DECLARED[piece] then return DECLARED[piece] end
  end
  return nil
end

--- Resolve a bucket for a plugin that is not (necessarily) inserted.
--   the list, by path  ->  the list/cards, by name  ->  name classifier  ->  ?
-- Rung 2 (plugin-declared) is unreachable here by construction; see category_fx.
function M.category(name, ident)
  local p = path_row(ident)
  if p then return p[1] end
  local key = norm(name)
  return recipe_cat(key, core_key(name)) or classify(key)
      or (ident and ident ~= "" and classify(norm(ident:match("([^/\\]+)$") or "")))
      or M.NO_GUESS
end

--- The optional free-text subcategory, or "" when the row has none (the common
--- case). Only ever comes from the curated list -- never guessed, because a
--- guessed subcategory is worse than a blank one.
function M.subcategory(name, ident)
  local p = path_row(ident)
  if p then return p[2] or "" end
  local _, sub = recipe_row(norm(name), core_key(name))
  return sub or ""
end

--- Resolve a bucket for a slot that IS in a chain -- the full four-rung ladder.
function M.category_fx(tr, idx)
  local disp = select(2, r.TrackFX_GetFXName(tr, idx, ""))
  local name = M.parse_name(disp)
  local key = norm(name)
  return recipe_cat(key, core_key(name)) or declared_cat(tr, idx)
      or classify(key) or M.NO_GUESS
end

-- ── what KIND of thing is this? ────────────────────────────────────────────
-- EnumInstalledFX does not only return audio effects. On a real install
-- (1120 entries, 2026-08-27) it also returned 150 MIDI-only tools, 53
-- instruments, and 30 things that are not plugins at all -- REAPER's JSFX
-- scanner walks the Effects folder, so a repo living there gets its .sh, .lua,
-- .rtf and .swing files enumerated as if they were plugins. An FX picker
-- offering the user `deploy.sh` is a bug no amount of categorising fixes.
--
-- TAG, DO NOT DELETE. Every row keeps its kind and the caller filters, so a
-- mis-tag costs a toggle rather than making a real plugin vanish. Rules read
-- the NAME ONLY (parse_name has already stripped the bracketed path) -- see the
-- ReaRack2 note there for why the path must not participate.

local BAD_EXT = { ".sh", ".lua", ".rtf", ".swing", ".md", ".rpp", ".wav", ".png",
                  ".json", ".py", ".rfxchain", ".bat", ".ini", ".pdf", ".zip",
                  ".cfg", ".html", ".docx", ".csv" }
local DOC_WORD = { "readme", "license", "changelog", "instruction", "instructions",
                   "notes", "note", "todo", "manual" }

local INSTRUMENT_WORD = { "synth", "sampler", "drum machine", "drumkit", "rompler" }

local function any_tok(hay, list)
  for i = 1, #list do if tok(hay, list[i]) then return true end end
  return false
end

--- "fx" | "instrument" | "midi" | "other"
--- `path` is parse_name's 4th return (the bracketed JSFX file path), optional.
function M.kind(name, ident, fmt, path)
  -- The curated list wins outright. It sees what no heuristic can: "EON Steppa"
  -- is a MIDI sequencer whose name contains nothing MIDI-ish, and "Swing" is a
  -- drum instrument whose name says nothing at all.
  local p = path_row(ident)
  if p and p[3] and p[3] ~= "" then return p[3] end
  local _, _, lk = recipe_row(norm(name), core_key(name))
  if lk and lk ~= "" then return lk end

  local id = (ident or ""):lower()
  for i = 1, #BAD_EXT do
    if id:sub(-#BAD_EXT[i]) == BAD_EXT[i] then return "other" end
  end
  -- REAPER fell back to the path because it parsed no desc: line. Combined with
  -- a documentation-sounding basename, that is not a plugin.
  if name == ident then
    local base = norm(name:match("([^/\\]+)$") or name)
    for i = 1, #DOC_WORD do
      if tok(base, DOC_WORD[i]) then return "other" end
    end
  end
  -- Instruments: REAPER's own marker, authoritative (the "!!!VSTi" flag it
  -- writes into reaper-vstplugins64.ini surfaces as the trailing i).
  if fmt and fmt:sub(-1) == "i" then return "instrument" end

  local k = norm(name)
  if any_tok(k, INSTRUMENT_WORD) then return "instrument" end
  if tok(k, "midi") then return "midi" end

  -- ⚠️ ORDER MATTERS BELOW. The folder a JSFX lives in is weak evidence and
  -- frequently wrong: the ReaRack modular set ships under a folder called
  -- "Synth", so "ReaRack2 - Filter" would read as an instrument on its path
  -- alone. So NAME-BASED EFFECT EVIDENCE WINS FIRST -- if the name classifies
  -- to a real bucket, it is an effect and the folder does not get a vote.
  if classify(k) then return "fx" end

  -- Only now, with a name that said nothing at all, is the folder worth asking.
  -- This is what recovers a synth called "Yutani" that lives in .../Synth/.
  local p = norm(path or "")
  if p ~= "" then
    if any_tok(p, INSTRUMENT_WORD) then return "instrument" end
    if tok(p, "midi") then return "midi" end
  end
  return "fx"
end

-- ── registry ───────────────────────────────────────────────────────────────
-- Reuses the EnumInstalledFX walk the bridge already relies on
-- (Swing_Kit_Bridge.lua rack_fx_resolve) rather than standing up a second one.
-- Guarded for pre-6.37 REAPER, where the API simply does not exist.

local _all = nil     -- every enumerated entry, whatever its kind
local _view = {}     -- cache of filtered views, keyed by the kind set

local function build()
  _all = {}
  if not r.EnumInstalledFX then return end        -- < 6.37: empty, never nil
  local i = 0
  while true do
    local ok, disp, ident = r.EnumInstalledFX(i)
    if not ok then break end
    local name, vendor, fmt, path = M.parse_name(disp, ident)
    _all[#_all + 1] = {
      name   = name,
      vendor = vendor,
      fmt    = fmt,
      path   = path,
      ident  = ident or "",
      disp   = disp or "",
      key    = norm(name),
      kind   = M.kind(name, ident, fmt, path),
      cat    = M.category(name, ident),
      sub    = M.subcategory(name, ident),
    }
    i = i + 1
  end
end

--- The installed-FX registry.
---   M.registry()                       -- audio effects only (the default)
---   M.registry(true)                   -- ...rebuilt from REAPER
---   M.registry{ kinds = { fx = true, midi = true } }
---   M.registry{ kinds = "all" }        -- everything, unfiltered
--
-- Audio-effects-only is the default because that is what a picker is FOR; the
-- other kinds stay one argument away rather than being thrown out (M.kind).
function M.registry(opts)
  local force = (opts == true) or (type(opts) == "table" and opts.force)
  if not _all or force then build(); _view = {} end
  local kinds = (type(opts) == "table") and opts.kinds or nil
  if kinds == "all" then return _all end
  kinds = kinds or { fx = true }
  local ck = (kinds.fx and "f" or "") .. (kinds.instrument and "i" or "")
          .. (kinds.midi and "m" or "") .. (kinds.other and "o" or "")
  if _view[ck] then return _view[ck] end
  local out = {}
  for i = 1, #_all do
    if kinds[_all[i].kind] then out[#out + 1] = _all[i] end
  end
  _view[ck] = out
  return out
end

--- How many of each kind REAPER handed us. For a UI that wants to offer
--- "also show 150 MIDI tools" honestly.
function M.registry_kinds(force)
  M.registry(force and { force = true, kinds = "all" } or { kinds = "all" })
  local n = { fx = 0, instrument = 0, midi = 0, other = 0, total = #_all }
  for i = 1, #_all do n[_all[i].kind] = (n[_all[i].kind] or 0) + 1 end
  return n
end

--- Substring search over name/vendor. opts.cat filters to one bucket, opts.fmt
--- to one format, opts.limit caps the result, opts.kinds widens past audio FX
--- (same shape as M.registry).
function M.search(q, opts)
  opts = opts or {}
  local reg = M.registry(opts.kinds and { kinds = opts.kinds } or nil)
  local needle = norm(q or "")
  -- ⚠️ SPACE-OPTIONAL. With the per-instance "send all keyboard input to
  -- plug-in" toggle off, REAPER never delivers space to the plugin -- it
  -- starts transport -- so a user cannot type "tape echo" at all, and the
  -- failure is silent and looks like a broken search box. Matching the
  -- space-stripped forms too makes the space optional rather than required:
  -- "tapeecho" finds "Tape Echo". (Hyphen and dot already normalise to spaces
  -- via norm() and are always delivered, so "tape-echo" works as well.)
  local tight = needle:gsub(" ", "")
  local out = {}
  for i = 1, #reg do
    local row = reg[i]
    local hit = needle == ""
    if not hit then
      hit = row.key:find(needle, 1, true) ~= nil
         or (tight ~= "" and row.key:gsub(" ", ""):find(tight, 1, true) ~= nil)
         or (row.vendor and norm(row.vendor):find(needle, 1, true) ~= nil)
    end
    if hit and opts.bank and not M.in_bank(row, opts.bank) then hit = false end
    if hit and opts.cat and row.cat ~= opts.cat then hit = false end
    if hit and opts.fmt and row.fmt ~= opts.fmt then hit = false end
    if hit then
      out[#out + 1] = row
      if opts.limit and #out >= opts.limit then break end
    end
  end
  return out
end

-- ── chain read ─────────────────────────────────────────────────────────────

local function fx_ident(tr, idx)
  if not r.TrackFX_GetNamedConfigParm then return "" end
  local ok, got, val = pcall(r.TrackFX_GetNamedConfigParm, tr, idx, "fx_ident")
  if ok and got and val then return val end
  return ""
end

--- Read a track's FX chain as picker slots.
function M.chain(tr)
  local out = {}
  if not tr then return out end
  local n = r.TrackFX_GetCount(tr)
  for i = 0, n - 1 do
    local _, disp = r.TrackFX_GetFXName(tr, i, "")
    local name, vendor, fmt = M.parse_name(disp, fx_ident(tr, i))
    out[#out + 1] = {
      idx = i, name = name, vendor = vendor, fmt = fmt,
      ident = fx_ident(tr, i), disp = disp or "",
      cat = M.category_fx(tr, i),
      sub = M.subcategory(name, fx_ident(tr, i)),
      enabled = r.TrackFX_GetEnabled(tr, i),
      offline = r.TrackFX_GetOffline and r.TrackFX_GetOffline(tr, i) or false,
    }
  end
  return out
end

-- Bare display-name sequence -- the identity used to VERIFY a reorder. Names
-- can repeat (two ReaComps), so we compare the whole SEQUENCE rather than
-- trying to track one element; a duplicate cannot fool a sequence compare.
local function name_seq(tr)
  local t = {}
  for i = 0, r.TrackFX_GetCount(tr) - 1 do
    t[#t + 1] = select(2, r.TrackFX_GetFXName(tr, i, ""))
  end
  return t
end

local function seq_eq(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

-- What the sequence SHOULD look like after moving element `from` to `to`.
local function permuted(seq, from, to)
  local t = {}
  for i = 1, #seq do t[i] = seq[i] end
  local v = table.remove(t, from + 1)
  table.insert(t, to + 1, v)
  return t
end

-- Where did the element that started at `from` actually land? A single-element
-- move can only produce permuted(before, from, d) for some d, so we solve for d
-- by comparison. Duplicate names cannot fool this: two d values that produce
-- identical sequences are behaviourally identical, so either answer is right.
local function land_index(before, after, from)
  for d = 0, #before - 1 do
    if seq_eq(permuted(before, from, d), after) then return d end
  end
  return nil
end

-- ── chain mutation ─────────────────────────────────────────────────────────

local function undo_begin() r.Undo_BeginBlock() end
local function undo_end(what) r.Undo_EndBlock("EON FX: " .. what, -1) end

--- Move the FX at `from` so it ends up AT index `to`.
--
-- TrackFX_CopyToTrack(tr, src, tr, dest, true) is documented as "insert BEFORE
-- dest". Moving UP that means dest == the final index (the house call sites at
-- Swing_Kit_Bridge.lua:9849/16470 both move up and rely on exactly that).
-- Moving DOWN, removing the source first shifts everything above it down one,
-- so landing AT `to` needs dest = to + 1.
--
-- ⚠️ Which of those two readings REAPER actually implements could not be
-- verified without REAPER, and the house call sites do not settle it -- both
-- move UP, where the readings agree. So this does not guess. It moves, reads
-- the chain back, and if the slot did not land where asked, works out where it
-- DID land and moves it again from there. Converges in at most two attempts and
-- is duplicate-name-safe (everything is a whole-sequence comparison).
--
-- Both attempts sit inside the caller's undo block, so a corrected move is
-- still one undo step. M.stats.move_retry counts second attempts: if the P1
-- test reports any, "insert before dest" is the live convention.
local function move_raw(tr, from, to)
  if from == to then return true end
  local origin = name_seq(tr)
  local want = permuted(origin, from, to)
  local at = from
  for attempt = 1, 2 do
    local base = name_seq(tr)
    -- 1st: assume dest IS the final index. 2nd: assume it names the slot to
    -- insert before, which costs +1 when travelling down the chain.
    local dest = (attempt == 1) and to or ((to > at) and (to + 1) or to)
    r.TrackFX_CopyToTrack(tr, at, tr, dest, true)
    local after = name_seq(tr)
    if seq_eq(after, want) then
      if attempt > 1 then M.stats.move_retry = M.stats.move_retry + 1 end
      return true
    end
    local landed = land_index(base, after, at)
    if not landed then break end                   -- not a single-element move
    -- landed == at is NOT a dead end: under "insert before dest", moving down
    -- by one is a no-op (the slot is removed and re-inserted in front of the
    -- very neighbour it was meant to pass). That no-op is the tell, so retry
    -- from the same place with the other destination rather than giving up.
    at = landed
  end
  M.stats.move_fail = M.stats.move_fail + 1
  return nil, "move: could not place slot " .. from .. " at index " .. to
end

function M.move(tr, from, to)
  if not tr then return nil, "move: no track" end
  local n = r.TrackFX_GetCount(tr)
  if from < 0 or from >= n then return nil, "move: source index out of range" end
  if to < 0 or to >= n then return nil, "move: target index out of range" end
  if from == to then return true end
  undo_begin()
  local ok, err = move_raw(tr, from, to)
  undo_end("move slot")
  return ok, err
end

--- Insert `add` (a plugin name or ident) at chain position `pos`.
--- pos = nil or >= count appends. Returns the resulting index.
--
-- Mechanism is the house-proven one (spec): append with TrackFX_AddByName, then
-- move into place. The `-1000-pos` AddByName trick is explicitly NOT used --
-- unproven in-house.
--
-- ⚠️ instantiate = -1 (ALWAYS create), not the 1 the bridge uses. A positive
-- value means "add only if not already present, else return the existing one",
-- which is right for ensure_rack_comp (make sure ONE comp exists) and wrong
-- here: a picker asked for a second ReaComp must get a second ReaComp, not a
-- silent no-op handing back the first.
local function insert_raw(tr, add, pos)
  local before = r.TrackFX_GetCount(tr)
  local at = r.TrackFX_AddByName(tr, add, false, -1)
  if at < 0 or r.TrackFX_GetCount(tr) <= before then
    return nil, "insert: '" .. tostring(add) .. "' not found or refused"
  end
  at = r.TrackFX_GetCount(tr) - 1                 -- appended, so it is last
  if pos and pos >= 0 and pos < at then
    local ok, err = move_raw(tr, at, pos)
    if not ok then return nil, err end
    at = pos
  end
  return at
end

function M.insert(tr, add, pos)
  if not tr then return nil, "insert: no track" end
  if not add or add == "" then return nil, "insert: no plugin given" end
  -- Fail HERE with a readable message rather than deep inside
  -- TrackFX_AddByName, which reports "string expected, got table" with no
  -- hint that a caller passed a whole registry row instead of row.disp.
  if type(add) ~= "string" then
    return nil, "insert: expected a plugin name string, got " .. type(add)
  end
  undo_begin()
  local at, err = insert_raw(tr, add, pos)
  undo_end("insert " .. tostring(add))
  return at, err
end

function M.remove(tr, idx)
  if not tr then return nil, "remove: no track" end
  if idx < 0 or idx >= r.TrackFX_GetCount(tr) then
    return nil, "remove: index out of range"
  end
  undo_begin()
  local ok = r.TrackFX_Delete(tr, idx)
  undo_end("remove slot")
  if not ok then return nil, "remove: TrackFX_Delete refused" end
  return true
end

--- Replace the plugin at `idx` with `add`, in place.
--
-- Add BEFORE remove (spec): the new plugin is inserted and moved into position
-- while the old one is still running, so the chain never momentarily loses a
-- link. This is also the audition path.
function M.swap(tr, idx, add)
  if not tr then return nil, "swap: no track" end
  if not add or add == "" then return nil, "swap: no plugin given" end
  -- Fail HERE with a readable message rather than deep inside
  -- TrackFX_AddByName, which reports "string expected, got table" with no
  -- hint that a caller passed a whole registry row instead of row.disp.
  if type(add) ~= "string" then
    return nil, "swap: expected a plugin name string, got " .. type(add)
  end
  local n = r.TrackFX_GetCount(tr)
  if idx < 0 or idx >= n then return nil, "swap: index out of range" end
  undo_begin()
  -- Land the newcomer directly after the outgoing slot, then drop the old one:
  -- deleting idx pulls the newcomer down into exactly idx.
  local at, err = insert_raw(tr, add, idx + 1)
  if not at then undo_end("swap slot"); return nil, err end
  local ok = r.TrackFX_Delete(tr, idx)
  undo_end("swap slot")
  if not ok then return nil, "swap: could not delete the outgoing plugin" end
  return idx
end

function M.set_enabled(tr, idx, on)
  if not tr then return nil, "bypass: no track" end
  if idx < 0 or idx >= r.TrackFX_GetCount(tr) then
    return nil, "bypass: index out of range"
  end
  undo_begin()
  r.TrackFX_SetEnabled(tr, idx, on and true or false)
  undo_end(on and "enable slot" or "bypass slot")
  return true
end

-- ── .RfxChain ──────────────────────────────────────────────────────────────

local SEP = package.config and package.config:sub(1, 1) or "/"

-- ── FX folders (the "banks" rail) ───────────────────────────────────────────
-- reaper-fxfolders.ini: [FolderN] holds ItemK=<path or ident> and Nb=<count>;
-- [Folders] holds NameN=<display name>. The two are joined BY INDEX -- that is
-- the only link between a folder's contents and its name.
local function bank_key(s)
  s = tostring(s or ""):lower():gsub("\\", "/")
  s = s:match("([^/]+)$") or s                 -- basename
  s = s:gsub("%.[a-z0-9]+$", "")               -- drop the extension
  return (s:gsub("[^a-z0-9]+", ""))
end

-- ── REAPER's OWN tags ──────────────────────────────────────────────────────
-- reaper-fxtags.ini is what the native FX browser's Developers and Categories
-- nodes are built from. Two sections, both keyed by plug-in file:
--   [developer]  reacomp.dll=Cockos
--   [category]   reacomp.dll=Dynamics
--
-- ⭐ THESE ARE NOT OUR CATEGORIES AND MUST NOT BE MERGED WITH THEM. Ours come
-- from the recipe DB and describe what a plug-in DOES at the granularity a
-- drummer cares about (comp, sat, tape, de-ess, summing). REAPER's are the
-- coarser set its browser ships with (Dynamics, Tools, External). Folding one
-- into the other would lose the distinction in both directions -- so they live
-- side by side and the user picks whichever they think in.
--
-- ⭐ The developer half is REAPER'S OWN vendor data, which beats parsing a
-- vendor out of the display name: that guess reads "ReaStream (Cockos)"
-- correctly but turns "ReaStream (8ch)" into a company called 8ch.
--
-- ⚠️ KEYS COME IN TWO SHAPES. Mostly a file name (reacomp.dll, reVUe.vst3) but
-- sometimes a bundle ident (com.blenheimsound.reVUe). Callers match on both --
-- see tag_lookup below -- because neither alone covers the file.
function M.fxtags()
  local path = r.GetResourcePath() .. SEP .. "reaper-fxtags.ini"
  local f = io.open(path, "r")
  if not f then return {}, {} end
  local dev, cat, cur = {}, {}, nil
  for line in f:lines() do
    local sec = line:match("^%[(.-)%]%s*$")
    if sec then
      cur = sec:lower()
    else
      local k, v = line:match("^(.-)=(.*)$")
      if k and v and v ~= "" then
        k = k:lower()
        if cur == "developer" then dev[k] = v
        elseif cur == "category" then cat[k] = v end
      end
    end
  end
  f:close()
  return cat, dev
end

-- One row's tag, tried as ident then as the ident's BASENAME -- the file holds
-- both shapes and a row only ever carries the ident.
function M.tag_lookup(tbl, row)
  if not tbl or not row then return nil end
  local id = (row.ident or ""):lower()
  if id == "" then return nil end
  return tbl[id] or tbl[id:match("([^/\\]+)$") or id]
end

-- ── OUR OWN banks ──────────────────────────────────────────────────────────
-- Banks Swing owns, kept separate from REAPER's FX folders on purpose.
--
-- ⭐ WHY NOT WRITE reaper-fxfolders.ini. There is no ReaScript API for FX
-- folders, so adding one means hand-editing a file REAPER holds in memory and
-- writes back out on its own schedule -- our write and its write race, and the
-- loser is silently discarded. Our own file cannot lose that race, and it can
-- hold things REAPER's folders cannot.
--
-- ⚠️ THE SHAPE IS DELIBERATELY IDENTICAL to what M.banks() returns: a name and
-- a `set` of bank_keys. M.in_bank() then works on ours unchanged, and so does
-- every counter, filter and publish downstream. A parallel membership test
-- would have been a second copy of all of it, kept in step by hand.
--
-- The file is plain text and meant to survive being opened by a human:
--   [My Reverbs]
--   reaverb.dll
--   com.valhalladsp.room
-- Idents are stored RAW and folded to keys on load, exactly as REAPER's own
-- folder items are -- so a line someone typed by hand matches the same way one
-- we wrote does.
local MYBANK_DIR  = nil
local MYBANK_FILE = nil

local function mybank_path()
  if not MYBANK_FILE then
    MYBANK_DIR  = r.GetResourcePath() .. SEP .. "Data" .. SEP .. "EON_Swing"
    MYBANK_FILE = MYBANK_DIR .. SEP .. "FX_Banks.ini"
  end
  return MYBANK_FILE
end

-- Read straight off disk every time it is asked for. The registry is rebuilt
-- rarely and a bank edit has to show up on the NEXT publish, not the next
-- REAPER restart -- and this file is a few hundred bytes.
function M.mybanks()
  local f = io.open(mybank_path(), "r")
  if not f then return {} end
  local out, cur = {}, nil
  for line in f:lines() do
    local nm = line:match("^%[(.-)%]%s*$")
    if nm then
      -- ⭐ ONE RESERVED SECTION NAME. [hidden] is not a bank -- it is the list
      -- of bank names, of ANY kind, that the rail must not show. It lives in
      -- this file rather than in the project because hiding a bank is a
      -- preference about your rail, not a property of the song: hide it once
      -- and every project you open agrees, exactly as the browser's hidden
      -- sections do.
      -- ⚠️ A bank someone genuinely wants to CALL "hidden" would collide. The
      -- name is cleaned to "hidden " on the way in rather than refused, so the
      -- collision is impossible instead of merely unlikely.
      if nm:lower() == "hidden" then
        cur = nil
      elseif nm ~= "" then
        cur = { name = nm, idents = {}, set = {} }
        out[#out + 1] = cur
      else
        cur = nil
      end
    elseif cur then
      local v = line:match("^%s*(.-)%s*$")
      -- ⚠️ Blank lines and # comments skipped, not stored: a human editing
      -- this file will leave both behind, and a bank whose membership set
      -- contains "" matches every row with an empty name.
      if v ~= "" and v:sub(1, 1) ~= "#" then
        cur.idents[#cur.idents + 1] = v
        cur.set[bank_key(v)] = true
      end
    end
  end
  f:close()
  return out
end

-- The hidden set, keyed by LOWERCASED bank name. Names, not indices: REAPER's
-- folders and our categories are rebuilt from scratch on every registry build
-- and their order is not stable, so an index would hide a different bank the
-- moment you installed a plug-in.
function M.mybanks_hidden()
  local f = io.open(mybank_path(), "r")
  if not f then return {} end
  local out, inh = {}, false
  for line in f:lines() do
    local nm = line:match("^%[(.-)%]%s*$")
    if nm then
      inh = (nm:lower() == "hidden")
    elseif inh then
      local v = line:match("^%s*(.-)%s*$")
      if v ~= "" and v:sub(1, 1) ~= "#" then out[v:lower()] = true end
    end
  end
  f:close()
  return out
end

-- ⚠️ WHOLE FILE, ATOMIC. Written to a temp beside the target and renamed over
-- it, so a crash mid-write leaves the previous banks intact rather than half a
-- file. Rewriting in place is how a power cut costs someone every bank.
local function mybank_write(list, hid)
  local path = mybank_path()
  r.RecursiveCreateDirectory(MYBANK_DIR, 0)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return nil, "cannot write " .. tmp end
  f:write("# EON Swing FX banks. One [Bank Name] per bank, one plug-in per\n")
  f:write("# line, written as REAPER names it. Safe to edit by hand.\n")
  for _, b in ipairs(list) do
    f:write("[", b.name, "]\n")
    for _, id in ipairs(b.idents or {}) do f:write(id, "\n") end
  end
  -- ⚠️⚠️ THE HIDDEN LIST IS REWRITTEN TOO, ALWAYS. This function writes the
  -- WHOLE file, so a caller that only meant to add a plug-in to a bank would
  -- otherwise drop every hidden name on the floor. `hid` defaults to what is
  -- currently on disk precisely so that the common caller cannot forget.
  hid = hid or M.mybanks_hidden()
  local hn = {}
  for k in pairs(hid) do hn[#hn + 1] = k end
  table.sort(hn)                      -- a stable file diffs and reads sanely
  if #hn > 0 then
    f:write("[hidden]\n")
    for _, k in ipairs(hn) do f:write(k, "\n") end
  end
  f:close()
  os.remove(path)
  local ok = os.rename(tmp, path)
  if not ok then return nil, "cannot replace " .. path end
  return true
end

local function mybank_find(list, name)
  for i, b in ipairs(list) do
    if b.name:lower() == tostring(name or ""):lower() then return i, b end
  end
end

-- A name is a FILE SECTION HEADER, so ] and newlines cannot be in it, and a
-- name that is only spaces would give you a bank you cannot see or select.
local function mybank_clean(name)
  name = tostring(name or ""):gsub("[%[%]\r\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  -- See the reader: [hidden] is reserved. Nudged, not refused -- "you cannot
  -- call it that" is a worse answer than quietly making it work.
  if name:lower() == "hidden" then name = name .. " " end
  return name:sub(1, 24)          -- the rail publishes 24 chars; longer is a lie
end

function M.mybank_new(name)
  name = mybank_clean(name)
  if name == "" then return nil, "a bank needs a name" end
  local list = M.mybanks()
  if mybank_find(list, name) then return nil, "there is already a bank called " .. name end
  list[#list + 1] = { name = name, idents = {}, set = {} }
  return mybank_write(list)
end

function M.mybank_delete(name)
  local list = M.mybanks()
  local i = mybank_find(list, name)
  if not i then return nil, "no bank called " .. tostring(name) end
  table.remove(list, i)
  return mybank_write(list)
end

-- Membership is by bank_key, but what gets STORED is the raw ident: the key is
-- lossy (basename, no extension, alphanumerics only) and writing it back would
-- turn "ReaVerb.dll" into "reaverb" in a file people are invited to read.
-- Hiding works on ANY bank -- your REAPER folders and both sets of categories
-- as well as ours. That is the point: the rail is yours, and a group you never
-- think in should be able to leave whatever made it.
function M.mybank_hide(name, on)
  name = tostring(name or ""):lower()
  if name == "" then return nil, "no bank named" end
  local hid = M.mybanks_hidden()
  if on then hid[name] = true else hid[name] = nil end
  return mybank_write(M.mybanks(), hid)
end

function M.mybank_show_all()
  return mybank_write(M.mybanks(), {})
end

function M.mybank_add(name, ident)
  if not ident or ident == "" then return nil, "nothing to add" end
  local list = M.mybanks()
  local _, b = mybank_find(list, name)
  if not b then return nil, "no bank called " .. tostring(name) end
  if b.set[bank_key(ident)] then return true end     -- already in: not an error
  b.idents[#b.idents + 1] = ident
  b.set[bank_key(ident)] = true
  return mybank_write(list)
end

function M.mybank_remove(name, ident)
  local list = M.mybanks()
  local _, b = mybank_find(list, name)
  if not b then return nil, "no bank called " .. tostring(name) end
  local k = bank_key(ident or "")
  for i = #b.idents, 1, -1 do
    if bank_key(b.idents[i]) == k then table.remove(b.idents, i) end
  end
  b.set[k] = nil
  return mybank_write(list)
end

function M.banks()
  local path = r.GetResourcePath() .. SEP .. "reaper-fxfolders.ini"
  local f = io.open(path, "r")
  if not f then return {} end
  local items, names, cur = {}, {}, nil
  for line in f:lines() do
    local sec = line:match("^%[(.-)%]%s*$")
    if sec then
      cur = sec
    elseif cur == "Folders" then
      local i, nm = line:match("^Name(%d+)=(.*)$")
      if i then names[tonumber(i)] = nm end
    elseif cur and cur:match("^Folder%d+$") then
      local idx = tonumber(cur:match("(%d+)"))
      local _, val = line:match("^Item(%d+)=(.*)$")
      if val then
        items[idx] = items[idx] or {}
        items[idx][bank_key(val)] = true
      end
    end
  end
  f:close()
  local out = {}
  for i = 0, 63 do
    -- ⚠️ NAMED IS ENOUGH -- an EMPTY folder is still a folder. The item table
    -- is created lazily on the first Item line, so a folder you made and have
    -- not filled had no table and was dropped entirely: REAPER listed it and
    -- we did not, which reads as a failure to see it rather than as "it is
    -- empty". An empty bank filters to nothing, which is the truth.
    if names[i] then
      out[#out + 1] = { name = names[i], set = items[i] or {} }
    end
  end
  return out
end

-- True when a registry row belongs to a bank set. Tries the parsed name and
-- the path, because the ini stores whichever the user's folder was built from.
function M.in_bank(row, set)
  if not set then return true end
  return set[bank_key(row.name)] == true
      or set[bank_key(row.path)] == true
      or set[bank_key(row.ident)] == true
end

function M.chain_dir()
  return r.GetResourcePath() .. SEP .. "FXChains"
end

--- One folder level of FXChains/. `rel` is "" for the root. Deliberately not a
--- recursive walk: the spec's CHAINS rail is "top-level + breadcrumb; no
--- expand-triangle tree widget", so one level is all a frontend ever needs.
function M.chain_list(rel)
  rel = rel or ""
  local dir = M.chain_dir()
  if rel ~= "" then dir = dir .. SEP .. rel end
  local out = { dirs = {}, files = {} }
  if not r.EnumerateSubdirectories or not r.EnumerateFiles then return out end
  local i = 0
  while true do
    local d = r.EnumerateSubdirectories(dir, i)
    if not d then break end
    out.dirs[#out.dirs + 1] = { name = d, rel = (rel == "") and d or (rel .. SEP .. d) }
    i = i + 1
  end
  i = 0
  while true do
    local f = r.EnumerateFiles(dir, i)
    if not f then break end
    if f:lower():find("%.rfxchain$") then
      out.files[#out.files + 1] = {
        name = f:gsub("%.[rR][fF][xX][cC][hH][aA][iI][nN]$", ""),
        file = f,
        rel  = (rel == "") and f or (rel .. SEP .. f),
      }
    end
    i = i + 1
  end
  table.sort(out.dirs,  function(a, b) return a.name:lower() < b.name:lower() end)
  table.sort(out.files, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

--- Apply an .RfxChain. mode "append" adds it after the existing chain,
--- "replace" clears the chain first. Both are ONE undo step.
--
-- AddByName with the absolute path, falling back to the relative one -- the
-- retry the bridge already needs (rack_chain_insert, Swing_Kit_Bridge.lua).
function M.chain_apply(tr, rel, mode)
  if not tr then return nil, "chain: no track" end
  if not rel or rel == "" then return nil, "chain: no chain given" end
  local abs = M.chain_dir() .. SEP .. rel
  undo_begin()
  if mode == "replace" then
    for i = r.TrackFX_GetCount(tr) - 1, 0, -1 do r.TrackFX_Delete(tr, i) end
  end
  local before = r.TrackFX_GetCount(tr)
  r.TrackFX_AddByName(tr, abs, false, -1)
  if r.TrackFX_GetCount(tr) <= before then
    r.TrackFX_AddByName(tr, rel, false, -1)
  end
  local added = r.TrackFX_GetCount(tr) > before
  undo_end(mode == "replace" and "replace chain" or "add chain")
  if not added then return nil, "chain: '" .. rel .. "' could not be inserted" end
  return true
end

--- Write the track's chain out as a normal .RfxChain, so it stays visible to
--- REAPER's own FX browser (spec). Reads the track chunk's <FXCHAIN> block.
function M.chain_save(tr, rel)
  if not tr then return nil, "chain save: no track" end
  if not rel or rel == "" then return nil, "chain save: no name given" end
  if not rel:lower():find("%.rfxchain$") then rel = rel .. ".RfxChain" end
  local ok, chunk = r.GetTrackStateChunk(tr, "", false)
  if not ok or not chunk then return nil, "chain save: could not read the track chunk" end
  local body = chunk:match("<FXCHAIN\n(.-)\n>%s*\n") or chunk:match("<FXCHAIN\r?\n(.-)\r?\n>")
  if not body then return nil, "chain save: this track has no FX chain" end
  -- Drop the window-state preamble: a saved chain should not carry one track's
  -- window position into every project that loads it.
  body = body:gsub("^WNDRECT[^\n]*\n", ""):gsub("^SHOW[^\n]*\n", "")
             :gsub("^LASTSEL[^\n]*\n", ""):gsub("^DOCKED[^\n]*\n", "")
  local path = M.chain_dir() .. SEP .. rel
  local f = io.open(path, "wb")
  if not f then return nil, "chain save: could not write " .. path end
  f:write(body, "\n")
  f:close()
  return true
end

return M
