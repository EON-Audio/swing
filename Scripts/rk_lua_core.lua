-- ReaKit Lua Core — Shared Utilities
-- (c) EON Studios — All Rights Reserved
--
-- Shared constants, path helpers, gmem I/O, color conversion, and file
-- utilities for all EON Lua scripts (Swing Browser, Kit Bridge, etc.).
--
-- Usage:
--   local core = dofile(script_dir .. sep .. "rk_lua_core.lua")

local core = {}

-- ═══════════════════════════════════════════════════════════════════════════════
-- OS / PATH
-- ═══════════════════════════════════════════════════════════════════════════════

core.sep = package.config:sub(1,1)
core.is_windows = core.sep == "\\"

function core.get_script_dir(stack_level)
  local info = debug.getinfo(stack_level or 2, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end

function core.get_extension(filename)
  return (filename:match("%.([^%.]+)$") or ""):lower()
end

function core.get_parent_dir(path)
  if not path or path == "" then return "" end
  path = path:gsub("[/\\]+$", "")
  -- Handle UNC paths (\\server\share)
  local unc = path:match("^(\\\\[^\\]+\\[^\\]+)$")
  if unc then return unc end
  local parent = path:match("^(.*)[/\\]")
  if not parent or parent == "" then
    return core.is_windows and path:match("^(%a:)") or "/"
  end
  return parent
end

function core.get_folder_name(path)
  if not path or path == "" then return "" end
  path = path:gsub("[/\\]+$", "")
  return path:match("[/\\]([^/\\]+)$") or path
end

function core.get_kits_dir()
  local resource = reaper.GetResourcePath()
  local dir = resource .. core.sep .. "Data" .. core.sep .. "Swing_Kits"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

-- ── Companion-script liveness ────────────────────────────────────────────────
-- EON_Swing_Strip_Sync stamps time_precise() here on every defer tick; the Kit
-- Bridge reads it to decide whether that script needs starting. Defined HERE,
-- once, because the writer and the reader are different files: the last time a
-- flag like this was spelled out separately at each end they drifted (the
-- browser wrote gmem 2368 while the JSFX read 2624, and nobody noticed).
-- Non-persistent on purpose -- REAPER clears it on restart, so a stale value
-- can never survive into a session where the script is not actually running.
core.ALIVE_STRIP_SYNC_SECTION = "EON_Swing_Strip_Sync"
core.ALIVE_STRIP_SYNC_KEY     = "alive_t"
-- Treat the script as dead once its stamp is this old. The stamp is written at
-- the top of every defer tick (~30 Hz, unconditional), so 2 s is ~60 missed
-- ticks of slack -- generous enough that a heavy project-load stall cannot be
-- mistaken for a dead script and get a second copy launched on top of it.
core.ALIVE_STALE_S            = 2.0

-- ── JSFX add-name resolution ─────────────────────────────────────────────────
-- TrackFX_AddByName wants "JS:<path relative to <resource>/Effects>", and that
-- path differs in EVERY layout we ship:
--   dev       Effects/EON_ReaKit_Bundle/installer/src/Swing/   (Scripts/ is a SIBLING)
--   installer Effects/EON/Swing/                               (Scripts/ is NOT)
--   ReaPack   Effects/<index name>/EON/Swing/                  (Scripts/ is NOT)
-- Deriving it from the calling SCRIPT's own directory only works in dev, which is
-- why the Drum Strip, the FX Return View, the Step Sequencer, the RS5k import and
-- New Song's Swing insert silently did nothing on every customer install, on every
-- platform, through every channel. Resolve against the Effects tree itself and
-- confirm the file exists BEFORE handing anything to AddByName.
--
-- Returns  addname, abspath   on success
--          nil, nil, reason   on failure -- callers MUST surface the reason.
-- basename MUST include the extension: it is part of the registered ident, and
-- omitting it is why eon_song_starter's "EON/Swing/Swing_ReaKit" never matched.
-- hint_tr/hint_fx: any already-loaded EON JSFX; they all share one directory, so
-- this is a zero-IO fast path.
core._jsfx_cache = {}

local function _jsfx_probe(p)
  if not p or p == "" then return nil end
  local f = io.open(p, "rb")
  if f then f:close(); return p end
  return nil
end

-- Depth-limited basename search. Subdirectories are COLLECTED BEFORE recursing:
-- REAPER keeps ONE EnumerateFiles/EnumerateSubdirectories cache per path, so
-- interleaving parent and child enumeration corrupts it. Same shape as
-- eon_relink_find in Swing_Kit_Bridge.lua.
local function _jsfx_scan(dir, want_lower, depth)
  if depth > 5 then return nil end
  reaper.EnumerateFiles(dir, -1)
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn or fn == "" then break end
    if fn:lower() == want_lower then return dir .. "/" .. fn end
    i = i + 1
  end
  local subs = {}
  reaper.EnumerateSubdirectories(dir, -1)
  i = 0
  while true do
    local sd = reaper.EnumerateSubdirectories(dir, i)
    if not sd or sd == "" then break end
    subs[#subs + 1] = sd
    i = i + 1
  end
  for _, sd in ipairs(subs) do
    local hit = _jsfx_scan(dir .. "/" .. sd, want_lower, depth + 1)
    if hit then return hit end
  end
  return nil
end

function core.jsfx_addname(basename, hint_tr, hint_fx)
  -- Only successes are cached. A miss must stay retryable so a mid-session
  -- ReaPack install heals without a REAPER restart.
  local hit = core._jsfx_cache[basename]
  if hit then return hit.addname, hit.abs end

  local eff = reaper.GetResourcePath() .. core.sep .. "Effects"
  local abs

  -- 1. Sibling of a live EON JSFX. Probe the ident BOTH as Effects-relative and
  --    as absolute: this codebase has only ever substring-tested fx_ident, so its
  --    exact shape is not established here and guessing would reintroduce the bug.
  if hint_tr and hint_fx and hint_fx >= 0 then
    local ok, ident = reaper.TrackFX_GetNamedConfigParm(hint_tr, hint_fx, "fx_ident")
    if ok and ident and ident ~= "" then
      local d = ident:gsub("\\", "/"):match("^(.*)/")
      if d and d ~= "" then
        abs = _jsfx_probe(eff .. "/" .. d .. "/" .. basename)
           or _jsfx_probe(d .. "/" .. basename)
      end
    end
  end

  -- 2. Known relative candidates, ordered by customer population.
  if not abs then
    for _, c in ipairs({ "EON/Swing/", "", "EON_ReaKit_Bundle/installer/src/Swing/" }) do
      abs = _jsfx_probe(eff .. core.sep .. c .. basename)
      if abs then break end
    end
  end

  -- 3. ReaPack: <resource>/Effects/<index name>/EON/Swing/<basename>. The index
  --    name is DISCOVERED, never typed -- it is remote metadata the user can
  --    rename in ReaPack. The only literal here is "EON/Swing", which is our own
  --    <category> in index.xml. Spaces and the em-dash come back verbatim.
  if not abs then
    reaper.EnumerateSubdirectories(eff, -1)
    local i = 0
    while true do
      local d = reaper.EnumerateSubdirectories(eff, i)
      if not d or d == "" then break end
      abs = _jsfx_probe(eff .. core.sep .. d .. core.sep .. "EON"
                            .. core.sep .. "Swing" .. core.sep .. basename)
      if abs then break end
      i = i + 1
    end
  end

  -- 4. Backstop: hand-moved install, or a ReaPack category rename.
  if not abs then abs = _jsfx_scan(eff, basename:lower(), 0) end

  if not abs then
    return nil, nil, basename .. " was not found anywhere under " .. eff
  end

  -- NEVER return "JS:" glued onto an absolute path -- that is the exact silent
  -- failure this function replaces.
  local root = (eff .. core.sep):gsub("\\", "/")
  local n = abs:gsub("\\", "/")
  if n:sub(1, #root):lower() ~= root:lower() then
    return nil, nil, basename .. " resolved outside the Effects tree: " .. abs
  end
  local addname = "JS:" .. n:sub(#root + 1)
  core._jsfx_cache[basename] = { addname = addname, abs = abs }
  return addname, abs
end

-- Persistent analysis cache (BPM/key short-circuit data, see Swing_Browser.lua).
-- Lives next to Swing_Kits so it ships+backs-up with the rest of Swing's data.
function core.get_cache_dir()
  local resource = reaper.GetResourcePath()
  local dir = resource .. core.sep .. "Data" .. core.sep .. "Swing_Cache"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

-- Windows-safe atomic file write. Writes to path.tmp, closes it, removes the
-- old path, then renames tmp -> path. Windows os.rename fails if the target
-- exists, so the remove is required — the brief window where the file is
-- missing is acceptable only if callers treat "missing" as "no data yet"
-- (defaults, rebuild from empty). A crash before rename leaves the previous
-- file intact and an orphaned .tmp; a crash after rename is the new file.
-- `writer` is either a body string or a function(f) that streams into f.
-- Returns true on success, false (+ message) on any failure — a writer that
-- throws is caught so the old file is not clobbered.
function core.atomic_write(path, writer)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return false, "open failed: " .. tmp end
  local ok, err = true, nil
  if type(writer) == "function" then
    ok, err = pcall(writer, f)
  else
    f:write(tostring(writer))
  end
  f:close()
  if not ok then
    os.remove(tmp)
    return false, err
  end
  os.remove(path)
  return os.rename(tmp, path)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- FORMAT HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════

function core.format_size(bytes)
  if not bytes or bytes < 0 then return "\xE2\x80\x94" end
  if bytes >= 1048576 then
    return string.format("%.1f MB", bytes / 1048576)
  elseif bytes >= 1024 then
    return string.format("%.0f KB", bytes / 1024)
  else
    return string.format("%d B", bytes)
  end
end

function core.format_duration(sec)
  if not sec or sec <= 0 then return "\xE2\x80\x94" end
  if sec < 60 then
    return string.format("0:%04.1f", sec)
  else
    local m = math.floor(sec / 60)
    local s = sec - m * 60
    return string.format("%d:%04.1f", m, s)
  end
end

function core.lua_quote(s)
  -- Escape backslash first (so it doesn't double up on subsequent escapes),
  -- then quote, newline, AND carriage return. CR appears in pasted Windows
  -- text and would otherwise terminate a "..." literal at load-time.
  return '"' .. s
    :gsub('\\', '\\\\')
    :gsub('"',  '\\"')
    :gsub('\n', '\\n')
    :gsub('\r', '\\r')
    .. '"'
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- AUDIO FILE EXTENSIONS
-- ═══════════════════════════════════════════════════════════════════════════════

core.NATIVE_EXT = {
  wav=true, aif=true, aiff=true, flac=true, mp3=true, ogg=true,
  bwf=true, w64=true, wv=true, caf=true
}

-- Kit formats Swing can import. SFZ only — multi-format support via
-- ConvertWithMoss was removed because it was unreliable and not part of
-- the v1 tutorial scope.
core.KIT_EXT = { sfz = true }

core.ALL_AUDIO_EXT = {}
for k in pairs(core.NATIVE_EXT) do core.ALL_AUDIO_EXT[k] = true end
for k in pairs(core.KIT_EXT)    do core.ALL_AUDIO_EXT[k] = true end

function core.is_audio_file(filename)
  return core.ALL_AUDIO_EXT[core.get_extension(filename)] or false
end

function core.is_native_audio(filename)
  return core.NATIVE_EXT[core.get_extension(filename)] or false
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- GMEM LAYOUT CONSTANTS (must match JSFX)
-- ═══════════════════════════════════════════════════════════════════════════════

core.GMEM = {
  -- ── v1 header/command rendezvous — RELOCATED 2026-07-09 from cells 0..35 ──
  -- A foreign in-process writer (control-surface extension family; per-boot
  -- segment-attach lottery) continuously tramples absolute cells 0/1/2 of
  -- whichever gmem segment it lands on ([0]=fader float, [1]=time_precise
  -- clock, [2]=const). On Swing_Media_Transfer that stomped CMD/VER/NPADS:
  -- kit loads jammed and garbage VER mid-import produced the phantom-pad-16
  -- pad-0 poison (see project_strip_sync_pad0_stomp, commit ab36056). The
  -- whole block now lives in the protected 2609xxxx band; cells 0..35 are
  -- DEAD — never claim them for anything.
  CMD           = 26090300,
  -- NOTE: the PARAM1/2/3 slots are OVERLOADED. The command bus uses them as
  -- transient args during a command; the kit header uses them as VER/NPADS/
  -- NAMELEN. Safe because they're never live at the same time (command args
  -- are written-then-consumed), but treat them as scratch — never assume a
  -- persistent value. KIT_GMEM_VER/NPADS aliases mirror the JSFX names.
  PARAM1        = 26090301,
  PARAM2        = 26090302,
  PARAM3        = 26090303,
  KIT_GMEM_VER  = 26090301,  -- alias of PARAM1 (kit header view)
  KIT_GMEM_NPADS = 26090302, -- alias of PARAM2 (kit header view)
  NAMELEN       = 26090303,
  NAME_BASE     = 26090304,  -- ..26090335 (32 chars)
  UNDO_ACK      = 95,
  UNDO_DESC     = 96,
  LOCK          = 97,
  INSTANCE      = 98,
  BRIDGE_ALIVE  = 99,
  META_BASE     = 100,
  META_PP       = 80,
  PADNAME_BASE  = 1720,
  PADNAME_LEN   = 32,
  AUDIOLEN_BASE = 2256,
  AUDIO_BASE    = 3000,

  NUM_PADS      = 16,
  MAX_LAYERS    = 4,
  SLOT_SIZE     = 4000000,
  LAYER_SIZE    = 1000000,

  -- Global state addresses
  GS_LOCK_BITMASK     = 1380,
  GS_BROWSER_VISIBLE  = 1381,
  GS_BROWSER_OPEN     = 1382,
  GS_KIT_NAME_BASE    = 1383,
  GS_KIT_NAME_LEN     = 16,
  GS_PAD_BPM_BASE     = 1400,
  GS_PAD_KEY_BASE     = 1416,
  GS_COL_EFFECTIVE_S  = 1432,   -- effective saturation = theme S × intensity
  GS_COL_EFFECTIVE_L  = 1433,   -- effective lightness  = theme L
  GS_WINDOW_W          = 1435,
  GS_WINDOW_H          = 1436,
  GS_BROWSE_PAD        = 1437,
  GS_BROWSER_PATH_LEN  = 1439,
  GS_PAD_SELECT_REQ    = 1440,
  GS_BROWSE_LAYER      = 1441,   -- layer index for CMD 64 (browser layer load)
  GS_TRACK_NUM         = 1442,
  GS_PAD_TRIGGER       = 1443,
  GS_KIT_LOAD_REQ      = 1444,   -- browser kit load: 0=idle, 1=request, 2=data ready
  -- Kit-categories ④ FILL mode: browser -> bridge, read at load-request time.
  -- 0/absent = LOAD (positional, as-authored — the default, unchanged);
  -- 1 = FILL (treat the kit as a content SET: match its samples onto THIS
  -- rack's pad categories, nothing moves, categories untouched, no ADAPT).
  -- Sits in the verified-free gap between PAD_OFFSET (2232..2247) and
  -- audiolen (2256+); confirmed unclaimed in every source + the canonical
  -- .refs/swing_gmem_bridge_protocol.md map 2026-07-24.
  GS_KIT_LOAD_MODE     = 2248,
  -- ④ FILL naming: requester staged a DISPLAY name (kit pad name) into the
  -- PADNAME band and wants the CMD-63 handler to ADOPT it as the pad name
  -- (consume-once flag) instead of auto-naming from the loaded file.
  -- Same verified-free 2248..2255 gap as GS_KIT_LOAD_MODE.
  GS_BROWSE_NAME_ADOPT = 2249,
  GS_AUDIO_REPAIR_REQ  = 1434,   -- JSFX → bridge: instance_id needs sidecar reload (audio truncated by chunk size limit on Undo/chunk restore); 0 = no request
  GS_BROWSER_PATH      = 1450,
  GS_BROWSER_PATH_MAX  = 260,
  GS_PAD_OFFSET_BASE   = 2232,   -- per-pad sample offset (16 floats)
  -- Per-pad chromatic key-range, packed lo*128+hi (16 floats). RELOCATED
  -- 2026-07-08 from 2620: that band overlapped FOUR owned GS cells —
  -- GS_PROJ_DIRTY (2620/pad0), GS_PAD_TRACK_SELECT (2623/pad3),
  -- GS_REAIMGUI_MISSING (2624/pad4), GS_FX_SEL_PAD (2625/pad5) — so dirty
  -- marks gave pad 0 a phantom range and range publishes ate the flags.
  -- New home = the verified-free gap after GS_FX_PUB (26090000-63) and
  -- GS_STRIP_REINIT_PULSE (26090100).
  GS_PAD_RANGE_BASE    = 26090200,  -- ..26090215
  GS_COMPANION_CMD     = 1710,
  GS_COMPANION_TARGET  = 2250,  -- instance_id the companion cmd is FOR (0 = broadcast).
                                -- Stamp BEFORE the cmd; the consumer clears both.
                                -- 2248..2255 gap (2248 LOAD_MODE, 2249 NAME_ADOPT).
  -- Heartbeat + update-channel slots (mirror Swing JSFX; previously absent
  -- here, which forced Lua tools to hardcode 1711). Monotonic GS_SWING_ALIVE
  -- is the canonical "is Swing running + ticking" signal.
  GS_SWING_ALIVE       = 1711,   -- monotonic heartbeat; nonzero + changing = alive
  GS_UPDATE_REQUEST    = 1712,
  GS_UPDATE_STATE      = 1713,
  GS_LATEST_VER_BASE   = 1714,
  GS_MEDIA_EXPLORER_OPEN = 1719, -- bridge → JSFX: 1 if REAPER Media Explorer is open
  -- Audio-only reload flag — bridge → JSFX. Set to 1 for a project-open
  -- sidecar auto-load or an Undo/chunk-restore audio-repair reload (both run
  -- after @serialize). The JSFX then preserves the @serialize-restored live
  -- per-pad params + globals instead of overwriting them from the kit file.
  -- Free slot in the gap between SP_PITCH_PDC_BUDGET (2273) and GS_UNDO_DESC (2276).
  -- RELOCATED 2026-07-08 from 2274: that cell doubles as the (supposedly
  -- removed) SP_PITCH_DIAG_TICK_COUNT, and the deployed Jul-5 extension
  -- build still increments it every audio block — so the preserve flag was
  -- PERMANENTLY nonzero and every kit load on a deserialized instance
  -- silently restored pre-load params over the fresh kit (bug-B stickiness,
  -- see project_strip_sync_pad0_stomp). 26090216 sits in the verified-free
  -- gap after GS_PAD_RANGE_BASE's new band (26090200-215).
  GS_KIT_PRESERVE_LIVE = 26090216,
  -- Header-bar UNDO/REDO buttons: bridge polls REAPER's undo stack
  -- and publishes next-action descriptions + availability flags here.
  GS_UNDO_DESC         = 2276,   -- 128-char string: next-undo description
  GS_UNDO_DESC_LEN     = 128,
  GS_REDO_DESC         = 2406,   -- 128-char string: next-redo description
  GS_REDO_DESC_LEN     = 128,
  GS_UNDO_AVAIL        = 2536,   -- 1 = undo available, 0 = stack empty
  GS_REDO_AVAIL        = 2537,   -- 1 = redo available, 0 = stack empty
  -- Live per-pad effective-mute state (mute OR muted-by-solo). JSFX writes
  -- every frame from the active browser-target instance; browser reads to
  -- dim muted pads to mirror the JSFX UI. 16 slots: 2282..2297.
  GS_PAD_MUTED_BASE    = 2538,
  -- Pending kit-load target — JSFX writes its instance_id when triggering
  -- a kit load (e.g. CMD 22 auto-load) so the receive handler routes the
  -- kit data only to that instance. Decoupled from INSTANCE (browser target)
  -- so an auto-load can't clobber the user's manual browser pick.
  GS_PENDING_LOAD_INST = 2554,
  -- B1b — per-instance Tuned injection selector. Before the bridge fires a
  -- pad-audio swap (CMD 65) for a baked WAV, it writes the TARGET registry
  -- slot here; the JSFX consumes the swap only when _reg_my_slot matches, so
  -- multiple live instances can run Tuned without grabbing each other's audio.
  -- Free slot between GS_PENDING_LOAD_INST (2554) and GS_INST_REG_BASE (2556).
  GS_PENDING_PITCH_INST = 2555,
  -- ─── Kit-load transaction band 26090336..26090341 (claimed 2026-07-17,
  -- grep-verified free incl. EON/.Extension/src/gmem/*.h; 340-341 reserved
  -- headroom for this band). Bridge stamps EPOCH before each dispatch; the
  -- consuming JSFX captures it at arm and echoes +epoch on import completion
  -- (state 4) or -epoch on a 98 abort, plus its instance_id and the post-
  -- import pad_fail_bits. Gives the bridge a real completion ack instead of
  -- inferring from the shared CMD cell. Readback is valid only on a LATER
  -- poll tick (same-frame cross-context gmem reads lie).
  GS_LOAD_EPOCH        = 26090336,  -- bridge → JSFX: monotonically increasing dispatch id.
                                    -- Phase 1b: ALSO the arm signal — stamped LAST at
                                    -- dispatch (after staging + PENDING); the consumer arms
                                    -- on epoch-change + PENDING match, immune to the REQ
                                    -- cell's 1-vs-2 value collisions (legacy REQ=2 still
                                    -- written for stale-JSFX compat).
  GS_LOAD_ACK          = 26090337,  -- JSFX → bridge: +epoch = landed, -epoch = aborted
  GS_LOAD_ACK_INST     = 26090338,  -- JSFX → bridge: instance_id that consumed the load
  GS_LOAD_ACK_FAILBITS = 26090339,  -- JSFX → bridge: pad_fail_bits after import (0 = clean)
  GS_LOAD_WANT         = 26090340,  -- requester → bridge: declared target instance for the
                                    -- NEXT kit_load_path request. Split off PENDING (Phase
                                    -- 1b): PENDING is now exclusively the bridge→JSFX
                                    -- delivery binding, so a new click can never stomp an
                                    -- in-flight dispatch's binding. Consumed by the
                                    -- kit_req handler.
  GS_DEV_BUTTON_LOAD   = 26090341,  -- RETIRED 2026-08-03: the JSFX consumer is gone (it
                                    -- replayed a write-set the LOAD button no longer
                                    -- uses). Cell stays reserved — never reuse a cell a
                                    -- shipped build has written. Headless LOAD coverage =
                                    -- the kitsview devpick mailbox (EON_KITLIST +7,
                                    -- KV_DEVPICK_MAGIC + index + 1).
  -- Bridge → browser: 0-based FX-chain index of the active target. Paired
  -- with GS_TRACK_NUM so the browser can disambiguate stacked Swings on
  -- the same track (track_num collides; fx_index doesn't).
  GS_TARGET_FX_IDX     = 1438,
  -- ─── Instance Registry (mirrors layout in Swing_ReaKit.jsfx) ────────
  -- Each Swing instance owns a slot, written EVERY @block. The browser
  -- reads this to know which Swings are alive, then does its own one-
  -- shot track scan to map inst_id → track/fx for picker display. No
  -- bridge involvement.
  GS_INST_REG_BASE     = 2556,
  GS_INST_REG_STRIDE   = 4,
  GS_INST_REG_MAX      = 16,
  GS_INST_REG_TIMEOUT  = 3.0,
  -- Per-slot field offsets (slot_base + offset)
  GS_INST_REG_OFF_ID         = 0,
  GS_INST_REG_OFF_HEARTBEAT  = 1,
  GS_INST_REG_OFF_PAD_COUNT  = 2,
  GS_INST_REG_OFF_KIT_HASH   = 3,
  -- ─── EON_DRAG: browser drag-over mailbox (base + slot*STRIDE) ───────
  -- A ReaImGui drag never becomes an OLE drop, so the JSFX pad grid's
  -- gfx_getdropfile can't see a browser drag. The browser tracks the
  -- gesture itself and mails cursor coords here; the JSFX owns the
  -- hit-test (it knows its own grid) and echoes the pad back, so the lit
  -- pad and the loaded pad are the same by construction.
  -- Mirrors Swing_ReaKit.jsfx EON_DRAG_BASE / EON_DRAG_CLAIM_BASE.
  -- v2: ONE broadcast, and every instance answers "is that me?" from its own
  -- mouse_x/mouse_y. v1 asked Lua to identify the window's owner, which only
  -- TrackFX_GetFloatingWindow can answer — so an instance in the FX chain
  -- could never be a drop target. Nothing here is per-window any more.
  EON_DRAG_BASE        = 26251264,  -- broadcast block (browser → all)
  EON_DRAG_OFF_STAMP   = 0,  -- written LAST (barrier)
  EON_DRAG_OFF_X       = 1,  -- cursor x in CLIENT px of the topmost jsfx_gfx
  EON_DRAG_OFF_Y       = 2,  -- cursor y in client px
  EON_DRAG_OFF_W       = 3,  -- that surface's client width  (fingerprint)
  EON_DRAG_OFF_H       = 4,  -- that surface's client height (fingerprint)
  EON_DRAG_OFF_COUNT   = 5,  -- files in flight (multi-drop highlight run)
  -- PRECISE = cursor is over a real jsfx_gfx surface, x/y/w/h are usable and
  -- only the instance they match may claim (floating / FX chain).
  -- BLIND   = cursor is over REAPER but not over any jsfx_gfx window, so x/y/
  -- w/h mean nothing: an EMBEDDED instance (TCP/MCP) claims on its own pointer
  -- being in bounds. Embedded UIs are painted into REAPER's panels and own no
  -- window, so their rect is not knowable from Lua — hence the second mode.
  EON_DRAG_OFF_MODE    = 6,
  EON_DRAG_MODE_PRECISE = 0,
  EON_DRAG_MODE_BLIND   = 1,
  EON_DRAG_CLAIM_BASE  = 26251520,  -- = BASE + 256; claim at + slot*STRIDE
  EON_DRAG_CLAIM_STRIDE = 4,
  EON_DRAG_CLAIM_PAD   = 0,  -- instance → browser: hovered pad (-1 = none)
  EON_DRAG_CLAIM_INST  = 1,  -- which instance is claiming
  EON_DRAG_CLAIM_ECHO  = 2,  -- echoes the broadcast stamp it answered, LAST
  -- ─── Per-pad action channel (browser → JSFX) ───────────────────────
  -- Used by the browser's note-per-pad selector and right-click menu to
  -- drive per-pad state changes. Only the browser-target Swing acts.
  -- target = -1 idle, 0..15 pad index. code: 1=mute, 2=solo, 3=reverse,
  -- 4=set note (value=MIDI note 0..127), 5=set output (value=output 0..15).
  -- GS_PAD_ACTION channel (2620-2622) RETIRED in P4 — pad actions post to
  -- the target instance's INCMD mailbox (see INCMD_* below + post_pad_incmd).
  -- Slots stay reserved (Swing Lite still compiles a dormant reader).
  -- Action codes (semantic names — keep in sync with JSFX)
  PAD_ACTION_MUTE      = 1,
  PAD_ACTION_SOLO      = 2,
  PAD_ACTION_REVERSE   = 3,
  PAD_ACTION_SET_NOTE  = 4,
  PAD_ACTION_SET_OUT   = 5,
  -- JSFX → bridge: pad-click → MCP/TCP track select. 1-indexed pad
  -- (1..16), 0 = no request (bridge writes 0 back after consuming).
  -- Gated on JSFX side by pad_click_selects_track preference (off
  -- by default; opt-in via Colors right-click menu).
  GS_PAD_TRACK_SELECT  = 2623,
  -- Swing_Browser.lua → JSFX: set to 1 when the user clicked BROWSE
  -- but ReaImGui isn't installed. JSFX shows a banner in the LCD area
  -- (rk_swing_ui_state.jsfx-inc, alongside the bridge-not-running
  -- overlay). Cleared on next successful browser launch.
  GS_REAIMGUI_MISSING  = 2624,

  -- ─── Pad FX panel channel (Swing JSFX ↔ ReaImGui "Pad FX" window) ─────────
  -- Browser-target Swing publishes the FX-focused pad + that pad's live FX
  -- params; the panel reads them and writes edits back (PAD written LAST,
  -- consumed by the JSFX). Slot numbers MUST match Swing_ReaKit.jsfx.
  GS_FX_SEL_PAD      = 2625,   -- JSFX→panel: FX-focused pad (overlay_pad/sel_pad), -1 = none
  -- Publish band relocated 2026-06-10 to the high range, then again 2026-07-02:
  -- 26040000 collided with EON_StepSeq's EON_SS_XFER pattern-transfer buffer
  -- (26040000..26041031). Now in the verified-free gap between the GS_STRIP band
  -- end (..26080719) and INST_INCMD_BASE (26100000): 64 slots reserved
  -- 26090000..26090063. The old 2626..2644 box had no room to grow.
  GS_FX_PUB_BASE     = 26090000, -- JSFX→panel: FX params for that pad (base + FX_PID_*)
  GS_FX_PUB_COUNT    = 23,       -- ids 0..22 used; band reserved through +62
  GS_FX_PUB_PAD      = 26090063, -- JSFX→panel: handshake, which pad the band describes
  GS_FX_ACTION_PAD   = 2646,   -- panel→JSFX: target pad, -1 = idle (write LAST)
  GS_FX_ACTION_PARAM = 2647,   -- panel→JSFX: param id (FX_PID_*)
  GS_FX_ACTION_VALUE = 2648,   -- panel→JSFX: new value (raw engineering units)
  -- Param ids — MUST match Swing_ReaKit.jsfx FX_PID_* and the publish-band order.
  -- Append-only.
  FX_PID_HPF_FREQ = 0,  FX_PID_LPF_FREQ = 1,  FX_PID_RESO = 2,
  FX_PID_EQ_LO = 3,     FX_PID_EQ_MID = 4,    FX_PID_EQ_HI = 5,
  FX_PID_EQ_LO_FREQ = 6, FX_PID_EQ_MID_FREQ = 7, FX_PID_EQ_HI_FREQ = 8,
  FX_PID_CMP_AMT = 9,   FX_PID_CMP_MODE = 10, FX_PID_BC_RATE = 11,
  FX_PID_BC_BITS = 12,  FX_PID_SAT_DRV = 13,  FX_PID_DRV_MODE = 14,
  FX_PID_SND_DLY = 15,  FX_PID_SND_RVB = 16,
  -- v46: 4th EQ band (second bell, "hi-mid") + per-bell Q (wheel over node)
  FX_PID_EQ_MID2 = 17, FX_PID_EQ_MID2_FREQ = 18,
  FX_PID_EQ_MID_Q = 19, FX_PID_EQ_MID2_Q = 20,
  -- v48: per-band shelf Q (0.7071 == the old fixed S=1.0)
  FX_PID_EQ_LO_Q = 21, FX_PID_EQ_HI_Q = 22,

  -- ─── Strip-sync band (Path B) — per-instance, registry-slot strided ──────
  -- Swing publishes its FULL per-pad FX state per registry slot; the
  -- EON_Swing_Strip_Sync.lua companion mirrors it onto the multi-out child
  -- tracks' "EON Drum Strip" JSFX and writes strip edits back via the command
  -- mailbox. MUST match Swing_ReaKit.jsfx GS_STRIP_*.
  --   band = GS_STRIP_BASE + slot * GS_STRIP_STRIDE
  --   pad param = band + GS_STRIP_PADS + pad * GS_STRIP_PAD_STRIDE + FX_PID_*
  -- GLOBAL (not per-slot) re-instantiation pulse, in the free gap between the
  -- GS_STRIP band end (26080719) and INST_INCMD_BASE (26100000), clear of
  -- GS_FX_PUB's relocated band (26090000..26090063). Was 26045000, which
  -- collided with StepSeq's EON_SS_PCTRL_BASE slot-0 NAV_SEQ bump-counter.
  -- The EON_Drum_Strip.jsfx bumps it in
  -- @init; the strip-sync uses it to restore a strip that came back at factory
  -- default after an audio-device-close re-instantiation (instead of letting that
  -- default propagate into Swing). MUST match EON_Drum_Strip.jsfx.
  GS_STRIP_REINIT_PULSE = 26090100,
  GS_STRIP_BASE         = 26050000,
  GS_STRIP_STRIDE       = 1024,
  GS_STRIP_OFF_SEQ      = 0,   -- JSFX→Lua: publish seq (bumped per rewrite)
  GS_STRIP_OFF_MULTIOUT = 1,   -- JSFX→Lua: multi_out flag
  GS_STRIP_OFF_LUA_HB   = 2,   -- Lua→JSFX: heartbeat (bump ~10Hz; stall = takeover off)
  GS_STRIP_OFF_VIEW_REQ = 3,   -- Swing→Lua: header STRIPS selector → (mode+1); sync_view pushes to strips
  GS_STRIP_OFF_CMD_SEQ  = 4,   -- Lua→JSFX: bump LAST, after PAD/PID/VAL
  GS_STRIP_OFF_CMD_PAD  = 5,
  GS_STRIP_OFF_CMD_PID  = 6,
  GS_STRIP_OFF_CMD_VAL  = 7,
  GS_STRIP_PADS         = 8,
  GS_STRIP_PAD_STRIDE   = 32,
  -- One-Mixer console tie: Swing publishes live p_gain/p_pan per pad at these
  -- per-pad-stride offsets (23/24 = FX-return viewer PEAK/HUE; 25/26 here;
  -- 27..31 free). The strip-sync companion two-way-mirrors them onto the child
  -- track's D_VOL/D_PAN; write-back to Swing rides the INCMD_GAIN/PAN
  -- mailboxes below. MUST match Swing_ReaKit.jsfx GS_STRIP_PAD_OFF_VOL/PAN.
  GS_STRIP_PAD_OFF_VOL  = 25,
  GS_STRIP_PAD_OFF_PAN  = 26,
  -- Band-level tie capability flag (601; band 0..7 taken, pad region 8..519,
  -- 600 = VU_REQ). Swing writes 1 per publish; 0 = old build → tie inert.
  GS_STRIP_OFF_TIE_VER  = 601,
  GS_STRIP_OFF_VU_REQ   = 600,  -- Swing→Lua: header VU selector → (style+2); past the pad region (8..519)

  -- ─── Unified theme bus (one selector → all four EON tools) ───────────────
  -- The Lua theme publisher resolves a palette (EON/Dark/Light/REAPER) and
  -- writes it here as normalized 0..1 RGB triples (JSFX-native; no /255). The
  -- JSFX tools (Swing, Step Seq) read the band each @gfx and re-skin from it.
  -- GS_THEME_ID is written LAST as the ready handshake: 0 = nothing published
  -- (JSFX keep their built-in defaults); >0 = a generation counter (bump on
  -- every republish so consumers can cheaply detect change). Free zone, post-
  -- M5 (after Pad FX's 2625-2648).
  GS_THEME_ID   = 2649,   -- 0 = none; else monotonic generation counter
  GS_THEME_BASE = 2650,   -- THEME_NCOL semantic colors × 3 floats (2650..2673)
  THEME_NCOL    = 8,
  -- Semantic slot indices (multiply by 3, add to GS_THEME_BASE):
  THEME_BG      = 0,   -- window / housing background
  THEME_PANEL   = 1,   -- recessed panel / LCD / cell background
  THEME_TEXT    = 2,   -- primary text
  THEME_TEXT_DIM= 3,   -- secondary / dim text
  THEME_ACCENT  = 4,   -- selection / active / primary accent
  THEME_ACCENT2 = 5,   -- secondary accent / hover / hilite
  THEME_GRID    = 6,   -- gridlines / dividers / borders
  THEME_BORDER  = 7,   -- frame border / outline
  -- Console-theme KNOB identity: primary/secondary knob STYLE index (see
  -- knobs_kbsg rk_knob_draw) + a per-ROLE hue table so each theme paints knobs
  -- by function. Below StepSeq M/S (2700): 2676/2677, role band 2678..2695.
  GS_THEME_KNOB_P    = 2676,  -- primary (hero) knob style index
  GS_THEME_KNOB_S    = 2677,  -- secondary (utility) knob style index
  GS_THEME_ROLE_BASE = 2678,  -- THEME_NROLE role hues x3 floats (2678..2695)
  THEME_NROLE        = 6,     -- 0 drive,1 gain,2 freq,3 shape,4 dynamics,5 time
  -- Theme SELECTOR plumbing (JSFX can't SetExtState, so a JSFX theme button
  -- requests a change here; the bridge writes the ExtState + republishes). In
  -- the free gap above the band (2674..2699; StepSeq M/S starts at 2700).
  GS_THEME_REQ  = 2674,   -- JSFX→bridge: 0 = none; 1..N theme index (REAPER modes are separate entries)
  GS_THEME_CUR  = 2675,   -- bridge→JSFX: active theme index for selector highlight
  -- JSFX→bridge knob-STYLE request (Swing's "KNOB" button). 0 = none; else
  -- (style_index + 1), so 1 = style 0 (Default/clear), 2 = style 1 (SSL) … 19 =
  -- style 18 (Roland). Bridge writes ExtState "eon_knob_<theme>" + clears it; the
  -- theme change-detection then republishes GS_THEME_KNOB_P. Sits in the free gap
  -- right above the role band (2678..2695), below StepSeq M/S (2700).
  GS_THEME_KNOB_REQ = 2696,
  -- bridge→JSFX: Drum Matrix paint-mode mirror (1 = on), sourced from ExtState
  -- "EON_DRUM_MATRIX"/"paint_mode". The Swing PAINT button reads it for its lit
  -- state; CMD 75 flips it. Last free slot before StepSeq M/S (2700).
  GS_DM_PAINT       = 2697,
  -- bridge→JSFX: Drum Matrix overlay running (1 = the eon_drum_matrix.lua
  -- singleton lock is fresh). The Swing GRID button reads it for its lit state;
  -- CMD 76 toggles the overlay. Last free slot before StepSeq M/S (2700).
  GS_DM_OVERLAY     = 2698,
  -- bridge→JSFX: EON toolbar open (1 = its "Open/close toolbar N" toggle state is
  -- on). The Swing header TOOLBAR chip reads it for its lit colour.
  GS_TOOLBAR_OPEN   = 2699,
  -- Appearance-cluster VU-face SYNC broadcast (rk_theme.jsfx-inc rkth_cluster's
  -- ">ALL" latch). REQ: JSFX→bridge, written into the FX's OWN gmem segment as
  -- (face index + 1); core.drain_theme_fx_segments collects + clears it, then
  -- core.relay_vu_fx_segments writes P = req and bumps GEN in EVERY curated FX
  -- segment (THEME_FX_SEGMENTS) so sibling rkth_vu_follow() polls adopt the
  -- face. Deliberately NO ExtState persistence (unlike eon_knob_*): the
  -- broadcast is a follow-me EVENT — each instance persists its own face on
  -- its slider (FX chunk), and the follower's GEN-seen-at-@init guard keeps a
  -- late-loading instance from adopting a stale broadcast.
  -- SLOTS 2752..2754 verified free 2026-08-11: the 2674..2699 gap above the
  -- theme band is FULL (see the four cells above); EON_StepSeq owns 2700+
  -- (ALIVE 2700, ANYSOLO 2702, MUTE 2710-2725, SOLO 2730-2745, PICKER_REQ/SEL
  -- 2750/2751, ROSTER 2760-2999 per EON_StepSeq.jsfx:1220-1227) and the
  -- KIT_GMEM_AUDIO scratch bus starts at 3000. The 2752..2759 hole between the
  -- picker mailbox and the roster is claimed by NOTHING: bundle-wide + EON-tree
  -- grep, swing_gmem_bridge_protocol.md §3 band map, gmem_regions_supplement
  -- .tsv (row added) and EON/.Extension/src/gmem/*.h all clean. Mirrors
  -- rk_theme.jsfx-inc GS_THEME_VU_*.
  GS_THEME_VU_REQ   = 2752,  -- JSFX→bridge: 0 = none; else picked face index + 1
  GS_THEME_VU_P     = 2753,  -- bridge→JSFX: broadcast face index + 1 (0 = never)
  GS_THEME_VU_GEN   = 2754,  -- bridge→JSFX: bump-on-publish generation counter

  -- ────────────────────────────────────────────────────────────────────────
  -- PER-INSTANCE IDENTITY BANDS (unified single-source-of-truth, P1)
  -- ────────────────────────────────────────────────────────────────────────
  -- Today the per-pad META(100)/PADNAME(1720) region is SINGLE-SHARED: only the
  -- active (LOCK/browser-target) instance owns it, so the canonical pad identity
  -- reflects one kit at a time. For full per-instance independence (N kits across
  -- M project tabs), each instance publishes its OWN identity to a region strided
  -- by its registry slot (same model as the Stretch control bands).
  --
  -- Placement: the verified-free high gap between STRETCH_AUDIO_END (25,165,823)
  -- and STRETCH_CONTROL_BASE (32,524,288). Above the kit-audio de-facto ceiling
  -- (~16.7M, where stretch audio begins) and the stretch audio band; below the
  -- stretch control band; far under the 33,554,432 named-segment cap. Identity is
  -- JSFX↔Lua only (no Extension), payload is tiny (~10k slots).
  --
  -- Ownership: each instance writes ONLY its own slot's band every @block, UNGATED
  -- (it owns its registry slot — no LOCK/browser-target needed), and live-READS it
  -- so an external edit is adopted + re-published. Consumers pair to a specific
  -- instance (registry slot) and read that slot's band.
  --
  -- Torn-read safety: the per-pad VER stamp (IDENT_OFF_VER) is written LAST by the
  -- owner; multi-word readers (name) do read-ver / read-fields / re-read-ver and
  -- retry on mismatch. Single-float fields (hue/mute/solo/note/output/icon) are
  -- word-atomic and need no retry.
  INST_IDENT_BASE         = 26000000,   -- slot*STRIDE + pad*FIELDS + field
  INST_IDENT_INST_STRIDE  = 128,        -- 16 pads * 8 fields
  INST_IDENT_PAD_FIELDS   = 8,
  IDENT_OFF_VER     = 0,   -- monotonic per-pad sequence stamp (written LAST)
  IDENT_OFF_HUE     = 1,   -- color hue 0..1 (or -1 white / -2 black sentinels)
  IDENT_OFF_MUTE    = 2,   -- 0/1
  IDENT_OFF_SOLO    = 3,   -- 0/1
  IDENT_OFF_NOTE    = 4,   -- MIDI note 0..127
  IDENT_OFF_OUTPUT  = 5,   -- output bus 0..15
  IDENT_OFF_ICON    = 6,   -- icon id: 0 = auto (name classifier), >0 = bundled icon
  IDENT_OFF_AUDIO   = 7,   -- explicit blank state: 1 = loaded, -1 = blank, 0 = old
                           -- build (fall back to the hue<=-1.5 sentinel). Needed
                           -- because hue -2 is ALSO the manual-BLACK color — hue
                           -- alone made consumers wipe a black pad's identity.
  INST_PADNAME_BASE        = 26010000,  -- slot*STRIDE + pad*32 chars (0-terminated)
  INST_PADNAME_INST_STRIDE = 512,       -- 16 pads * 32
  INST_PADNAME_PAD_LEN     = 32,
  -- Kit-categories band (Spec_Swing_Kit_Categories §7a): per-pad {category, source,
  -- lock} published by the BRIDGE (owner: Lua — unlike IDENT which the JSFX owns).
  -- Same torn-read discipline as IDENT: per-pad VER written LAST; readers treat
  -- VER==0 as "not published" and fall back to name inference. CATEGORY value =
  -- 0-based index into eon_filename_categorizer CATEGORY_ORDER (== rk_cat_glyphs
  -- ids); -1/absent = uncategorised. Range 26003000..26004023 verified free against
  -- every in-checkout gmem map + the canonical .refs doc 2026-07-24, and re-verified
  -- 2026-07-29 against EON/.Extension/src/gmem/*.h (now present in the checkout; no
  -- 26004xxx/26005xxx slot there) — the caveat this comment used to carry is closed.
  INST_PADCAT_BASE        = 26003000,   -- slot*STRIDE + pad*4 + field
  INST_PADCAT_INST_STRIDE = 64,         -- 16 pads * 4 fields
  PADCAT_OFF_VER  = 0,                  -- monotonic stamp, written LAST
  PADCAT_OFF_CAT  = 1,                  -- 46-vocab index, -1 = uncategorised
  PADCAT_OFF_SRC  = 2,                  -- 0 = kit/inferred, 1 = library, 2 = custom
  PADCAT_OFF_LOCK = 3,                  -- 1 = audio-locked (phase ② consumes)

  -- Change-map band (Spec_Swing_Change_Map_And_Reroll §3.2): what the LAST kit
  -- operation actually did to each pad, so the KIT-tab grid can report it. BRIDGE
  -- is the sole writer, JSFX reads only. Same seqlock discipline as PADCAT/ADAPT:
  -- SEQ written LAST. Sits after EON_PADCAT_ADAPT (26004600 + 0..17); range
  -- 26004700..26005211 verified free 2026-07-29 against every gmem map including
  -- EON/.Extension/src/gmem/*.h.
  --   Pad codes: 0 empty · 1 changed · 2 changed-shared(cycle) · 3 locked ·
  --              4 custom · 5 no-match · 6 synth
  -- ⚠️ 0 and 5 are DIFFERENT answers: 0 = nothing was here, 5 = we looked and found
  -- nothing. Only 5 means "go add sources". 6 keeps synth pads out of 5.
  INST_CHANGEMAP_BASE        = 26004700,  -- slot*STRIDE + offsets below
  INST_CHANGEMAP_INST_STRIDE = 32,
  CHGMAP_OFF_SEQ      = 0,   -- monotonic, written LAST
  CHGMAP_OFF_OP       = 1,   -- 0 none, 1 LOAD, 2 FILL, 3 REROLL_KIT, 4 REROLL_PAD
  CHGMAP_OFF_N_CHG    = 2,   -- changed count (includes shared/cycled)
  CHGMAP_OFF_N_LOCK   = 3,   -- skipped: locked
  CHGMAP_OFF_N_CUSTOM = 4,   -- skipped: user's own sample
  CHGMAP_OFF_N_NOMATCH= 5,   -- had a category, source had nothing for it
  CHGMAP_OFF_SURPLUS  = 6,   -- source samples that landed nowhere
  CHGMAP_OFF_STAMP    = 7,   -- time_precise() at publish; readers expire on age
  CHGMAP_OFF_PADS     = 8,   -- + pad (0..15) -> outcome code

  -- Root-note band (rk_root_note.lua publishes, JSFX reads). Per-pad detected
  -- fundamental for the PITCH readout. Same seqlock discipline: VER LAST.
  -- Claimed 26006000..26008063 in .refs/gmem_regions_supplement.tsv; the gap
  -- 26005212..26009999 was verified free against every map 2026-08-01.
  -- ⚠️ PER-INSTANCE ON PURPOSE. The legacy GS_PAD_KEY_BASE (1416-1431, above)
  -- is a FLAT 16-cell band with NO slot stride: two Swing instances silently
  -- overwrite each other's values. It also only ever had a writer — no JSFX
  -- has ever read it. Treat it as legacy; this band is what the UI consumes.
  -- SYN pads never need this: rk_synthdrums knows its settled fundamental in
  -- closed form, so the synth path computes the note exactly and locally.
  -- Kit cover artwork path exchange. Numbers must match the JSFX const block in
  -- Swing_ReaKit.jsfx (the names differ there, as with PADCAT/CHANGEMAP above).
  -- Both directions share this ONE per-instance band so no CMD number is spent
  -- and cover paths stay off GS_BROWSER_PATH, which is a CMD-serialised shared
  -- bus and would race sample loads. Paths use the length-prefixed form that
  -- eon_write_gmem_path / eon_read_gmem_path already speak.
  KITCOVER_BASE       = 26251792,  -- slot*STRIDE
  KITCOVER_STRIDE     = 544,
  KITCOVER_PUB_SEQ    = 0,    -- bridge -> JSFX. WRITTEN LAST, after the path.
  KITCOVER_PUB_PATH   = 1,    -- extracted temp-file path of the loaded cover
  KITCOVER_PUB_PREVIEW = 261, -- 1 = published path is an UNSAVED drop preview
  KITCOVER_PEND_SEQ   = 272,  -- JSFX -> bridge. WRITTEN LAST, after the path.
  KITCOVER_PEND_PATH  = 273,  -- a just-dropped image, awaiting the next save
  KITCOVER_PATH_MAX   = 258,

  ROOTNOTE_BASE       = 26006000,  -- slot*STRIDE + pad*FIELDS + field
  ROOTNOTE_STRIDE     = 128,       -- 16 pads * 8 fields
  ROOTNOTE_FIELDS     = 8,
  RN_OFF_VER          = 0,   -- monotonic; 0 = never published. WRITTEN LAST.
  RN_OFF_NOTE         = 1,   -- MIDI note 0..127; -1 = no root note
  RN_OFF_CENTS        = 2,   -- -50..+50
  RN_OFF_CONF         = 3,   -- 0..1
  RN_OFF_SRC          = 4,   -- 0 none, 1 detected (YIN), 2 synth (exact)
  RN_SRC_NONE         = 0,
  RN_SRC_DETECTED     = 1,
  RN_SRC_SYNTH        = 2,
  ROOTNOTE_REQ        = 26008048,  -- +0 seq LAST, +1 slot, +2 pad (-1=all), +3 rsvd

  -- Inbound per-instance command mailboxes (IN direction, Increment D).
  -- External writers (bridge TCP mirror, browser, Pad-FX) post pad color/name
  -- commands HERE, never into the owner-published bands above — commands in a
  -- writer-owned region can't be lost to the owner's per-block publish.
  -- Protocol: payload written FIRST, flag LAST; the owning Swing consumes in
  -- @block by zeroing the flag. Flag: 1 = adopt silently (writer already owns
  -- the undo point, e.g. a native TCP edit), 2 = adopt + mark_dirty_pad (the
  -- adopt IS the user action's undo record, e.g. browser/Pad-FX edits).
  INST_INCMD_BASE   = 26100000,  -- slot*STRIDE + region offsets below
  INST_INCMD_STRIDE = 1024,      -- 16 slots -> 26100000..26116383 (free gap)
  INCMD_COLOR_OFF   = 0,         -- + pad*2: [0]=flag, [1]=hue payload 0..1
  INCMD_NAME_OFF    = 64,        -- + pad*34: [0]=flag(LAST), [1]=gen, [2..33]=chars
  INCMD_NAME_FIELDS = 34,
  -- Mute/solo SET commands (Increment E): absolute 0/1 payloads (not toggles —
  -- idempotent under echo/retry). TWO writer-origin regions so the bridge (TCP
  -- edits) and the StepSeq JSFX (lane-pill clicks) never share cells.
  INCMD_MUTE_OFF     = 640,      -- bridge-origin:    + pad*2: [0]=flag, [1]=0/1
  INCMD_SOLO_OFF     = 672,      -- bridge-origin:    + pad*2
  INCMD_SEQ_MUTE_OFF = 704,      -- sequencer-origin: + pad*2
  INCMD_SEQ_SOLO_OFF = 736,      -- sequencer-origin: + pad*2
  -- P4: note/output/reverse (browser-origin; always flag=2 — every writer is
  -- a user action). REVERSE is the one TOGGLE-semantics cell (payload
  -- ignored): reverse has no published band field to diff a SET against.
  INCMD_NOTE_OFF     = 768,      -- + pad*2: [0]=flag, [1]=MIDI note 0..127
  INCMD_OUT_OFF      = 800,      -- + pad*2: [0]=flag, [1]=output pair 0..15
  INCMD_REV_OFF      = 832,      -- + pad*2: [0]=flag, [1]=unused (toggle)
  -- SFZ-import fidelity: re-apply per-pad playback params the CMD-63 audio
  -- load doesn't carry. SET semantics (0 is meaningful), flag 2 = adopt+undo.
  INCMD_TUNE_OFF     = 864,      -- + pad*2: [0]=flag, [1]=semitones -24..24
  INCMD_GAIN_OFF     = 896,      -- + pad*2: [0]=flag, [1]=linear gain 0..8
  INCMD_PAN_OFF      = 928,      -- + pad*2: [0]=flag, [1]=pan -1..1
  -- RS5k-import fidelity: set a pad's layer playback mode after stacking layers
  -- (vel-split auto-assigns even velocity ranges). + pad*2: [0]=flag, [1]=mode
  -- (0=single 1=vel-split 2=round-robin 3=sum). Region 960..991, under 1024.
  INCMD_LMODE_OFF    = 960,      -- + pad*2: [0]=flag, [1]=layer mode 0..3
  -- Lane color ownership view/controller (per-slot, NOT per-pad). The policy's
  -- source of truth is P_EXT:EON_LANE_COLOR_POLICY on the Swing track (bridge-
  -- owned); the JSFX Colors panel is a pure view over these cells — nothing here
  -- is serialized in the JSFX.
  --   PUB: bridge -> JSFX, republished every identity pass.
  --        0 = not published (no bridge / unslotted), 1 = swing, 2 = reaper,
  --        3 = none.
  --   REQ: JSFX -> bridge mailbox. [994]=flag (writer sets LAST, bridge zeroes
  --        to consume), [995]=requested mode 1/2/3 (payload FIRST).
  INCMD_LANEPOL_PUB  = 992,
  INCMD_LANEPOL_REQ  = 994,

  -- ────────────────────────────────────────────────────────────────────────
  -- Swing Pitch (SP_*) — three-mode pad pitch protocol (Part B)
  -- ────────────────────────────────────────────────────────────────────────
  -- Three modes per pad:
  --   SP_PITCH_MODE = 0 (Repitch) — local SincResampler (today's path); zero
  --                                  latency; duration shortens with pitch
  --   SP_PITCH_MODE = 1 (Tuned)   — Signalsmith pre-render on tune-change
  --                                  via BakeEngine; zero latency at trigger;
  --                                  duration preserved
  --   SP_PITCH_MODE = 2 (Stretch) — realtime ElastiqueVoice via audio_hook;
  --                                  ~30-100ms PDC-declared latency; duration
  --                                  preserved with live pitch modulation
  --
  -- Algorithm mapping (Extension CLAUDE.md canon, Tuned + Stretch only):
  --   SP_PITCH_ALGO = 0 (Drum)    — Elastique Pro + Monophonic
  --   SP_PITCH_ALGO = 1 (Tonal)   — Elastique Soloist + Monophonic
  --   SP_PITCH_ALGO = 2 (Texture) — Elastique Pro + Normal
  --   SP_PITCH_ALGO = 3 (Voice)   — Elastique Soloist + Speech
  --
  -- Single-pad-request channel — slot layout in Swing_Media_Transfer:
  --   1445  SP_PITCH_PROTOCOL_VER  JSFX republishes SP_PITCH_PROTOCOL_VER_VALUE
  --                                (4) EVERY tick, from @init/@slider/@block/@gfx —
  --                                deliberately NOT latched: an @init-only write to
  --                                the named pool can silently fail to land
  --   1446  SP_PITCH_HEARTBEAT     Extension writes counter; JSFX reads
  --   1447  SP_PITCH_REQ_PAD       JSFX writes 0..15 = request, -1 = idle
  --                                (Extension writes -1 to ack/clear)
  --   1448  SP_PITCH_REQ_SHIFT_ST  Semitones for the current request
  --   1449  SP_PITCH_REQ_ALGO      Algo enum for the current request
  --
  -- Placement history:
  --   * 70 M base failed: past the named-segment ceiling (32 M slots =
  --     NSEEL_RAM_BLOCKS_GMEM_NAMED × 65536). Writes silently dropped.
  --   * META embedding rejected: offsets 0..79 fully claimed by
  --     rk_swing_ui_state.jsfx-inc @serialize.
  --   * Final: single-pad-request protocol in 5 free slots at 1445..1449.
  --     JSFX writes ONE pending request at a time; Extension processes and
  --     acks. Real per-pad state stays in JSFX freemem (sp_pitch_mode[]
  --     etc.); gmem is just the wire. Single-instance (LOCK-gated) and
  --     single-bake-in-flight; latest-wins on multiple rapid changes.
  --
  -- Mode enum values (JSFX / Lua / C++ lockstep):
  SP_PITCH_MODE_REPITCH       = 0,
  SP_PITCH_MODE_TUNED         = 1,
  SP_PITCH_MODE_STRETCH       = 2,

  -- Algo enum values:
  SP_PITCH_ALGO_DRUM          = 0,
  SP_PITCH_ALGO_TONAL         = 1,
  SP_PITCH_ALGO_TEXTURE       = 2,
  SP_PITCH_ALGO_VOICE         = 3,

  -- Pitch protocol slots (in Swing_Media_Transfer):
  SP_PITCH_PROTOCOL_VER       = 1445,
  SP_PITCH_HEARTBEAT          = 1446,
  -- 1447-1449: RESERVED (legacy v2 single-pad-request channel). Unused in v3
  -- (stateless reconcile). Kept reserved so the slot map stays gap-correct.
  SP_PITCH_REQ_PAD            = 1447,
  SP_PITCH_REQ_SHIFT_ST       = 1448,
  SP_PITCH_REQ_ALGO           = 1449,

  -- Mode-flip-out-of-Tuned signal — in v3 the EXTENSION writes the pad index
  -- here when it observes a pad's published MODE band flip from Tuned to
  -- anything else, so this Lua bridge can restore the pad's ORIGINAL audio
  -- (otherwise the pad keeps playing the last pre-pitched bake, which under
  -- Repitch gets p_tune applied AGAIN — double-pitch). Bridge writes -1 to
  -- ack. (In v2 the JSFX wrote this; the stateless reconcile moved detection
  -- to the Extension.) Slot lives in the small free zone between AUDIOLEN end
  -- (2271) and GS_UNDO_DESC start (2276).
  SP_PITCH_MODE_REVERT_PAD    = 2272,

  -- Wire protocol version. Bumped on any incompatible layout change.
  -- v2 = single-pad-request channel; v3 = stateless reconcile (per-pad bands);
  -- v4 = B1 per-slot-strided control bands (each instance writes its own
  -- registry-slot region; Extension reconciles all live slots).
  SP_PITCH_PROTOCOL_VER_VALUE = 4,

  -- Sentinel meaning "no pending request" / "idle" (legacy v2 REQ_PAD; also
  -- the Extension's -1 ack on SP_PITCH_MODE_REVERT_PAD).
  SP_PITCH_REQ_PAD_IDLE       = -1,

  -- ────────────────────────────────────────────────────────────────────────
  -- Stretch-mode PDC budget (Part B step 1)
  -- ────────────────────────────────────────────────────────────────────────
  -- Extension writes the worst-case audio_hook latency in samples at
  -- project SR when at least one pad on this instance is in Mode=Stretch.
  -- JSFX reads in @slider/@block, assigns to pdc_delay (with pdc_bot_ch=0,
  -- pdc_top_ch=2, pdc_midi=1). When no pad is in Stretch mode, Extension
  -- writes 0 and the JSFX clears pdc_delay.
  --
  -- Binary policy (locked 2026-05-26): value changes only when the set of
  -- Stretch-mode pads transitions empty <-> non-empty. Mid-play p_tune
  -- changes never touch this slot. Per-pad opt-in to Stretch costs one
  -- PDC blip (REAPER flushes one buffer to recompensate) and is the
  -- documented UX — matches Battery/MPC behavior.
  --
  -- Lives in the small free zone between AUDIOLEN end (2271) and
  -- GS_UNDO_DESC start (2276), alongside SP_PITCH_MODE_REVERT_PAD (2272).
  SP_PITCH_PDC_BUDGET         = 2273,

  -- ────────────────────────────────────────────────────────────────────────
  -- Stretch audio band (Part B step 1) — per-pad SPSC ring buffers in
  -- the high end of Swing_Media_Transfer
  -- ────────────────────────────────────────────────────────────────────────
  -- Architectural constraint: JSFX gets exactly ONE `options:gmem=`
  -- segment per source file. Swing_ReaKit.jsfx is attached to
  -- Swing_Media_Transfer and cannot also reach a separate segment. So
  -- the Mode=Stretch audio band lives in the same segment, placed at
  -- the high end where realistic kit-load transfers don't reach.
  --
  -- Capacity reasoning:
  --   * Named-segment ceiling = NSEEL_RAM_BLOCKS_GMEM_NAMED × 65536
  --     = 512 × 65536 = 33,554,432 slots (verified: 70 M failed, 6 M works)
  --   * Kit-load transfer packs pads contiguously from slot 3000;
  --     GMEM_AUDIO_MAX is set to 64 M in the bridge but the cap silently
  --     truncates anything past 33.55 M. Realistic kits use 1-5 M slots.
  --   * Stretch band at 32,000,000 leaves 1 M slots of safety buffer to
  --     the cap, plus 27 M slots of headroom for kit-load growth before
  --     collision risk. Pathological collisions only when a kit's total
  --     packed audio exceeds 32 M slots — already broken by the segment
  --     cap, no regression from this placement.
  --
  -- Per-pad layout (stride 32768 slots = 16382 stereo frames):
  --   ring_base = STRETCH_AUDIO_BASE + pad_idx * STRETCH_PAD_STRIDE
  --   ring_base + 0  STRETCH_OFF_WRITE_POS   Extension writes (atomic_set)
  --   ring_base + 1  STRETCH_OFF_READ_POS    JSFX writes      (atomic_set)
  --   ring_base + 2  STRETCH_OFF_CAPACITY    constant = data frames
  --   ring_base + 3  STRETCH_OFF_RESERVED    reserved for fmt/flag
  --   ring_base + 4..ring_base + 32767       stereo interleaved L,R,...
  --
  -- SPSC ring invariants (lock-free):
  --   * Producer (Extension audio_hook) writes WRITE_POS only.
  --   * Consumer (JSFX @sample)         writes READ_POS  only.
  --   * Ring empty when WRITE_POS == READ_POS.
  --   * Ring full  when (WRITE_POS + 1) mod DATA_FRAMES == READ_POS.
  --
  -- Sample format: stereo interleaved at project sample rate. Mono
  -- sources are duplicated L=R during preload by the Extension (M3
  -- SampleData layer). Extension pre-resamples via WDL_Resampler on
  -- preload so élastique sees one canonical SR via set_srate.
  --
  -- B1c multi-instance footprint: 16 instances * 16 pads * 32768 =
  -- 8,388,608 slots from 16,777,216..25,165,823 (blocks 256..383).
  -- Per-instance stride = 16 pads * 32768 = 524288.
  STRETCH_AUDIO_BASE          = 16777216,
  STRETCH_AUDIO_END           = 25165823,  -- inclusive
  STRETCH_INST_AUDIO_STRIDE   = 524288,
  STRETCH_NUM_PADS            = 16,
  STRETCH_PAD_STRIDE          = 32768,
  STRETCH_HEADER_SLOTS        = 4,
  STRETCH_PAD_DATA_SLOTS      = 32764,
  STRETCH_PAD_DATA_FRAMES     = 16382,
  STRETCH_OFF_WRITE_POS       = 0,
  STRETCH_OFF_READ_POS        = 1,
  STRETCH_OFF_CAPACITY        = 2,
  STRETCH_OFF_RESERVED        = 3,
  STRETCH_PROTOCOL_VER        = 1,

  -- ────────────────────────────────────────────────────────────────────────
  -- Stretch per-pad control band (Part B step 3a)
  -- ────────────────────────────────────────────────────────────────────────
  -- Lives just past the audio band in the same segment. JSFX publishes
  -- per-pad MODE values here so the Extension audio_hook (no JSFX freemem
  -- access) can gate processing on "is this pad currently in Stretch mode."
  --
  -- Layout (16 slots, one per pad):
  --   STRETCH_PER_PAD_MODE_BASE + N  →  SP_PITCH_MODE for pad N
  --     0 = Repitch, 1 = Tuned, 2 = Stretch
  --     JSFX writes via atomic_set in @block when sp_pitch_mode[N] changes.
  --     Extension audio_hook reads in isPost callback.
  --
  -- Step 3b adds PITCH_ST and TRIGGER counter bands at higher offsets.
  STRETCH_CONTROL_BASE        = 32524288,
  STRETCH_PER_PAD_MODE_BASE   = 32524288,    -- 16 slots, N=0..15
  STRETCH_PER_PAD_TRIGGER_BASE= 32524304,    -- 16 slots, N=0..15 (monotonic)
  STRETCH_PER_PAD_PITCH_ST_BASE = 32524320,  -- 16 slots, N=0..15 (semitones)
  STRETCH_PER_PAD_ALGO_BASE   = 32524336,    -- 16 slots, N=0..15 (algo enum)
  -- B1b: per-registry-slot stride for the control bands above. Each live
  -- instance writes its own slot's region (slot*STRIDE). Mirrors the JSFX
  -- STRETCH_CONTROL_INSTANCE_STRIDE and the Extension kStretchControlInstanceStride.
  -- Lets the bridge read a specific instance's per-pad MODE band:
  --   gmem[STRETCH_PER_PAD_MODE_BASE + slot*STRETCH_CONTROL_INSTANCE_STRIDE + pad]
  STRETCH_CONTROL_INSTANCE_STRIDE = 80,
  -- Per-pad SOURCE GENERATION band (JSFX→Kit-Bridge only; the Extension never
  -- reads it). JSFX bumps a per-pad counter on any audio swap (drag-drop /
  -- browser / clear) and blasts it here every @block. The bridge diffs it to
  -- detect a changed pad and invalidate the Extension's cached Tuned-bake /
  -- Stretch-preload source (which is otherwise keyed on a stable temp path and
  -- would resurrect the OLD sample on a mode switch). Sits just above the
  -- 16-instance control region (top 32525567), same NSEEL block, same stride:
  --   gmem[STRETCH_PER_PAD_SRCGEN_BASE + slot*STRETCH_CONTROL_INSTANCE_STRIDE + pad]
  STRETCH_PER_PAD_SRCGEN_BASE = 32525568,

  -- ────────────────────────────────────────────────────────────────────────
  -- Per-pad kit-load handshake (VER-26 protocol)
  -- ────────────────────────────────────────────────────────────────────────
  -- Spec: .docs/specs/Spec_Swing_PerPad_Sidecar_Load.md. The bridge (producer)
  -- streams kit audio ONE blob (pad,layer) at a time through the fixed window
  -- at AUDIO_BASE — never the packed all-pads layout (32M segment ceiling +
  -- cumulative-offset drift). The targeted JSFX (consumer) copies the blob into
  -- its resident slot and echoes the generation when fully landed; the bridge
  -- only then advances. Exactly ONE consumer runs per load (the
  -- PENDING_LOAD_INST-gated instance), so these slots are GLOBAL; the
  -- 26500000-26509999 band is claimed (full-bundle sweep 2026-07-07) with
  -- per-instance stride 64 reserved should loads ever run concurrently.
  -- Publish order (x86 store-order dependent): GEN odd → payload + meta →
  -- GEN even (written LAST).
  HS_GEN   = 26500000,  -- bridge: monotonic generation; odd=writing, even=published
  HS_ECHO  = 26500001,  -- JSFX: last generation whose blob fully landed
  HS_PAD   = 26500002,  -- target pad 0..15
  HS_LAYER = 26500003,  -- layer index (0 = pad-main blob)
  HS_LEN   = 26500004,  -- samples staged in the window
  HS_FLAGS = 26500005,  -- bit0 = first blob of pad (memset that pad's slot), bit1 = kit done
  HS_CAP   = 26500006,  -- JSFX capability: a v26-aware build writes 26 here every @block;
                        -- the bridge falls back to the packed VER-24 path when absent

  -- ── CMD-86 dedicated staging band (P3 migration path rewrite) ─────────────
  -- 26300000..26320807, claimed 2026-07-12 (full-bundle sweep: 26200011..
  -- 26499999 verified empty; HS control band starts at 26500000). The old
  -- staging home — the KIT_GMEM_AUDIO 260-cell band — is a SCRATCH BUS
  -- (block_pitch streams pad PCM over it for Extension bake capture, which
  -- runs for seconds right after project open), so CMD-86 payloads staged
  -- there were stomped before the JSFX consume read them: ack fired with
  -- zero adoptions and the rewritten paths never reached the chunk. This
  -- band has exactly two writers (bridge stages, JSFX echoes adopted count)
  -- and no other traffic. Requires HS_CAP >= 202 (JSFX advertises); the
  -- bridge falls back to the legacy cells for older builds.
  -- Layout: +0 adopted-count echo (JSFX, written BEFORE the CMD ack;
  -- bridge presets -1), +1..7 reserved, then 80 length-prefixed 260-cell
  -- path slots: pad-main at +8+pad*260, layers at +8+16*260+(pad*4+L)*260.
  MIGR_STAGE_BASE   = 26300000,
  MIGR_ADOPTED      = 26300000,
  MIGR_PAD_CELLS    = 26300008,               -- + pad*260
  MIGR_LAYER_CELLS  = 26300008 + 16 * 260,    -- + (pad*4+layer)*260 (= 26304168)

  -- ── P4 step 3 REB bands (26320808..26342127, claimed 2026-07-15 from the
  -- same verified-free sweep, directly above the MIGR band).
  -- PUBLISH band = the CMD-87 response: the JSFX copies its LIVE pad/layer
  -- path strings + lengths + layer counts + pad_fail_bits here on request,
  -- because the bridge has NO other trustworthy path source on a cold
  -- reopen (pad_path_N ExtState breadcrumbs are staging-time-only and
  -- session-global; the KIT_GMEM_AUDIO path cells are the block_pitch
  -- scratch bus). Writers: JSFX fills payload then REB_PUB_ACK LAST;
  -- bridge presets the ACK to 0 per request. Requires HS_CAP >= 203.
  REB_PUB_ACK       = 26320808,  -- JSFX: echoes REB_PUB_REQ after payload complete
  REB_PUB_REQ       = 26320813,  -- producer: unique nonce (shared ACK cell across
                                 -- producers → stomps must be detectable, not hangs)
  REB_FAIL_BITS     = 26320809,  -- JSFX: pads whose disk source didn't load (also refreshed by CMD 88)
  REB_PUB_COUNT     = 26320810,  -- JSFX: non-empty path cells published
  REB_SKIPPED       = 26320811,  -- JSFX: >258-char paths dropped from publish
  REB_RESTORE_GEN   = 26320812,  -- JSFX: deserialize counter (0 = never restored)
  REB_PAD_CELLS     = 26320840,  -- + pad*260 (len-prefixed)
  REB_LAYER_CELLS   = 26325000,  -- + (pad*4+layer)*260
  REB_SLEN          = 26341640,  -- + pad
  REB_LLEN          = 26341656,  -- + pad*4+layer
  REB_LAYERCNT      = 26341720,  -- + pad
  -- PER-SLOT control band, stride 8 keyed by registry slot; one writer per
  -- cell: +0 PATHS_GEN (JSFX every @block), +1 HEALTH_BITS (bridge),
  -- +2 HEALTH_STAMP (bridge), +3 HEALTH_GEN (bridge), +4 REBASE_UNFIXED
  -- (bridge), +5 REBASE_DONE (bridge), +6..7 reserved.
  REB_SLOT_BASE     = 26342000,  -- ..26342127
  REB_SLOT_STRIDE   = 8,
}

core.GMEM_NAME = "Swing_Media_Transfer"

-- ═══════════════════════════════════════════════════════════════════════════════
-- GMEM STRING I/O
-- ═══════════════════════════════════════════════════════════════════════════════

function core.gmem_read_string(base, len_addr, max_len)
  local slen = math.min(math.floor(reaper.gmem_read(len_addr)), max_len)
  local chars = {}
  for i = 0, slen - 1 do
    local c = math.floor(reaper.gmem_read(base + i))
    if c > 0 then chars[#chars + 1] = string.char(c) end
  end
  return table.concat(chars)
end

function core.gmem_write_string(str, base, len_addr, max_len)
  local len = math.min(#str, max_len)
  reaper.gmem_write(len_addr, len)
  for i = 0, max_len - 1 do
    reaper.gmem_write(base + i, i < len and string.byte(str, i + 1) or 0)
  end
end

function core.read_pad_name(pad)
  local G = core.GMEM
  local base = G.PADNAME_BASE + pad * G.PADNAME_LEN
  local chars = {}
  for i = 0, G.PADNAME_LEN - 1 do
    local c = math.floor(reaper.gmem_read(base + i))
    if c <= 0 or c > 127 then break end  -- 0 = terminator, >127 = stale/misaligned gmem
    chars[#chars + 1] = string.char(c)
  end
  return table.concat(chars)
end

-- Read the MIDI trigger note for a given pad (0-15) from gmem.
-- The JSFX writes this to META_BASE + pad*META_PP + 10 via sync_note_names().
function core.read_pad_note(pad)
  local G = core.GMEM
  return math.floor(reaper.gmem_read(G.META_BASE + pad * G.META_PP + 10) or 0)
end

local NOTE_NAMES = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }
function core.midi_to_note_name(n)
  if not n or n < 0 or n > 127 then return "—" end
  return NOTE_NAMES[(n % 12) + 1] .. (math.floor(n / 12) - 1)
end

-- Resolve a Swing instance_id to its live registry SLOT (fresh heartbeat),
-- or nil. Lua twin of the bridge's ss_resolve_slot; used by surfaces that
-- post per-instance INCMD commands (browser pad actions, P4).
function core.resolve_inst_slot(inst_id)
  if not inst_id or inst_id <= 0 then return nil end
  local G = core.GMEM
  local now = reaper.time_precise()
  for slot = 0, G.GS_INST_REG_MAX - 1 do
    local base = G.GS_INST_REG_BASE + slot * G.GS_INST_REG_STRIDE
    if math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID) or 0) == inst_id then
      local hb = reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT) or 0
      if (now - hb) <= G.GS_INST_REG_TIMEOUT then return slot end
    end
  end
end

-- Post one per-pad command into a Swing instance's INCMD mailbox (payload
-- first, flag LAST — the instance consumes in @block by zeroing the flag).
-- region_off = G.INCMD_*_OFF; flag 2 = adopt + mark_dirty_pad (user action).
-- Replaces the retired send_pad_action / GS_PAD_ACTION shared channel (P4):
-- per-instance, race-free, undo-correct.
function core.post_pad_incmd(slot, region_off, pad, value, flag)
  local G = core.GMEM
  local cb = G.INST_INCMD_BASE + slot * G.INST_INCMD_STRIDE + region_off + pad * 2
  reaper.gmem_write(cb + 1, value or 0)
  reaper.gmem_write(cb, flag or 2)
end

-- ─── Pad FX panel helpers (Swing JSFX ↔ ReaImGui "Pad FX" window) ─────────
-- JSFX→panel: FX-focused pad the browser-target instance is publishing.
-- Returns -1 when nothing is focused / no instance picked.
function core.read_selected_pad()
  return math.floor(reaper.gmem_read(core.GMEM.GS_FX_SEL_PAD) or -1)
end

-- JSFX→panel: read the published FX band, but only if it currently describes
-- `expected_pad` (handshake guards the pad-switch race). Returns a table keyed
-- by FX_PID_* → value, or nil if the band is mid-switch (caller retries next frame).
function core.read_pad_fx(expected_pad)
  local G = core.GMEM
  if math.floor(reaper.gmem_read(G.GS_FX_PUB_PAD) or -1) ~= expected_pad then
    return nil
  end
  local t = {}
  for id = 0, G.GS_FX_PUB_COUNT - 1 do
    t[id] = reaper.gmem_read(G.GS_FX_PUB_BASE + id)
  end
  return t
end

-- panel→JSFX: set one FX param on a pad. Mirrors send_pad_action — VALUE/PARAM
-- first, PAD written LAST so the JSFX consumer (gated by _is_browser_target)
-- sees a complete record, applies it (recalc_fx + mark_dirty_pad), then clears.
function core.send_fx_action(pad, param_id, value)
  local G = core.GMEM
  reaper.gmem_write(G.GS_FX_ACTION_PARAM, param_id or 0)
  reaper.gmem_write(G.GS_FX_ACTION_VALUE, value or 0)
  reaper.gmem_write(G.GS_FX_ACTION_PAD,   pad)
end

-- ─── Unified theme bus helpers ────────────────────────────────────────────
-- Publisher → JSFX: write the resolved palette to the gmem band, GS_THEME_ID
-- LAST as the ready handshake. `palette` = array of THEME_NCOL {r,g,b} in 0..1;
-- `gen` = monotonic generation counter (bump every republish).
function core.publish_theme_band(palette, gen)
  local G = core.GMEM
  for i = 0, G.THEME_NCOL - 1 do
    local c = palette[i + 1]
    local base = G.GS_THEME_BASE + i * 3
    reaper.gmem_write(base,     (c and c[1]) or 0)
    reaper.gmem_write(base + 1, (c and c[2]) or 0)
    reaper.gmem_write(base + 2, (c and c[3]) or 0)
  end
  reaper.gmem_write(G.GS_THEME_ID, gen or 1)
end

-- Publisher → JSFX: console-theme KNOB identity. Call BEFORE publish_theme_band
-- so it is in place when GS_THEME_ID (the handshake) is written last. p_idx/
-- s_idx = primary/secondary knob style index; roles = array of THEME_NROLE
-- {r,g,b} (0..1) role hues.
function core.publish_theme_knobs(p_idx, s_idx, roles)
  local G = core.GMEM
  reaper.gmem_write(G.GS_THEME_KNOB_P, p_idx or 1)
  reaper.gmem_write(G.GS_THEME_KNOB_S, s_idx or (p_idx or 1))
  local n = G.THEME_NROLE or 6
  for i = 0, n - 1 do
    local c = roles and roles[i + 1]
    local base = G.GS_THEME_ROLE_BASE + i * 3
    reaper.gmem_write(base,     (c and c[1]) or 0)
    reaper.gmem_write(base + 1, (c and c[2]) or 0)
    reaper.gmem_write(base + 2, (c and c[3]) or 0)
  end
end

-- Clear the band (publisher on "no theme" / shutdown) so JSFX revert to defaults.
function core.clear_theme_band()
  reaper.gmem_write(core.GMEM.GS_THEME_ID, 0)
end

-- ─── Multi-namespace theme publish (FX rollout) ───────────────────────────
-- Curated FX that read the theme from their OWN gmem segment. A JSFX gets one
-- options:gmem= segment; these plugins already own theirs (rk_gmem_link uses the
-- low slots), so we mirror the theme band into each — it sits clear above at
-- GS_THEME_BASE..GS_THEME_KNOB_REQ. Character plugins are intentionally NOT
-- listed (they stay native; we never write into their segment).
core.THEME_FX_SEGMENTS = {
  "ReaKit1175", "ReaKit3BEQ", "ReaKit4BEQ", "ReaKitDeEsser", "ReaKitDelay",
  "ReaKitExpressBus", "ReaKitGate", "ReaKitLimiter", "ReaKitReverb",
  "ReaKitSaturation", "ReaKitStereoWidth", "FrostReaKitNetwork",
  -- Added with the appearance cluster (THEME/KNOB chips).
  -- (Prism Comp was briefly listed; it is a character plugin and no longer
  -- imports rk_theme, so it is off the list.)
  -- (ChannelTool reads the band from the main Swing_Media_Transfer segment,
  -- so it needs no mirror entry. Spice, DirtSqueeze and Reelism were listed
  -- briefly while the cluster was fleet-wide; they are character plugins and
  -- no longer import rk_theme, so they are back off the list per the rule
  -- above — we never write into a character plugin's segment.)
}

-- Mirror the band + knob identity into every FX segment, then RESTORE the main
-- segment. gmem_attach is last-wins / one-binding-per-Lua-state (see the attach
-- note near the top of the bridge), so this runs as ONE contiguous block and
-- MUST re-attach GMEM_NAME before returning. Call right after the main publish.
function core.publish_theme_fx_segments(palette, gen, p_idx, s_idx, roles)
  local segs = core.THEME_FX_SEGMENTS
  -- pcall so a mid-loop error can NEVER leave the bridge on an FX segment
  -- (that would send kit-data writes to the wrong place). Restore is below.
  pcall(function()
    local i = 1
    while i <= #segs do
      reaper.gmem_attach(segs[i])
      if p_idx and core.publish_theme_knobs then core.publish_theme_knobs(p_idx, s_idx, roles) end
      core.publish_theme_band(palette, gen)
      i = i + 1
    end
  end)
  reaper.gmem_attach(core.GMEM_NAME)   -- ALWAYS restore the main segment
end

-- Clear the band in every FX segment (no-theme / shutdown), then restore main.
function core.clear_theme_fx_segments()
  local segs = core.THEME_FX_SEGMENTS
  pcall(function()
    local i = 1
    while i <= #segs do
      reaper.gmem_attach(segs[i])
      reaper.gmem_write(core.GMEM.GS_THEME_ID, 0)
      i = i + 1
    end
  end)
  reaper.gmem_attach(core.GMEM_NAME)
end

-- Listen-back for the FX rollout: sweep every curated FX segment, collect any
-- pending theme / knob / VU-face REQUEST an in-plugin picker wrote there (the
-- bridge's main-segment drain never sees those), clear it, and mirror the
-- active theme index into GS_THEME_CUR so each picker's label highlights
-- correctly. cur_idx < 1 skips the CUR write (nothing published yet). Returns
-- theme_req, knob_req, vu_req (0 = none; last segment wins if several raced a
-- click). Same attach discipline as publish_theme_fx_segments: pcall-guarded
-- so an error can never leave the bridge attached to an FX segment.
function core.drain_theme_fx_segments(cur_idx)
  local segs = core.THEME_FX_SEGMENTS
  local G = core.GMEM
  local treq, kreq, vreq = 0, 0, 0
  pcall(function()
    local i = 1
    while i <= #segs do
      reaper.gmem_attach(segs[i])
      local r = math.floor(reaper.gmem_read(G.GS_THEME_REQ) or 0)
      if r >= 1 then treq = r; reaper.gmem_write(G.GS_THEME_REQ, 0) end
      r = math.floor(reaper.gmem_read(G.GS_THEME_KNOB_REQ) or 0)
      if r >= 1 then kreq = r; reaper.gmem_write(G.GS_THEME_KNOB_REQ, 0) end
      r = math.floor(reaper.gmem_read(G.GS_THEME_VU_REQ) or 0)
      if r >= 1 then vreq = r; reaper.gmem_write(G.GS_THEME_VU_REQ, 0) end
      if cur_idx and cur_idx >= 1 then reaper.gmem_write(G.GS_THEME_CUR, cur_idx) end
      i = i + 1
    end
  end)
  reaper.gmem_attach(core.GMEM_NAME)   -- ALWAYS restore the main segment
  return treq, kreq, vreq
end

-- VU-face SYNC relay (appearance-cluster ">ALL" latch — see GS_THEME_VU_* in
-- core.GMEM). vreq = the drained GS_THEME_VU_REQ (face index + 1). Writes
-- GS_THEME_VU_P = vreq then bumps GS_THEME_VU_GEN (payload first, generation
-- LAST) in EVERY curated FX segment so sibling instances' rkth_vu_follow()
-- polls adopt the face — including the broadcaster's own segment (its follow
-- is a no-op: the face already matches). DIRECT republish, deliberately NO
-- ExtState (unlike the knob relay): the broadcast is a follow-me EVENT, not
-- suite state — each instance persists its own face in its FX chunk. Same
-- attach discipline as publish_theme_fx_segments: pcall-guarded so an error
-- can never leave the bridge attached to an FX segment.
function core.relay_vu_fx_segments(vreq)
  local segs = core.THEME_FX_SEGMENTS
  local G = core.GMEM
  pcall(function()
    local i = 1
    while i <= #segs do
      reaper.gmem_attach(segs[i])
      reaper.gmem_write(G.GS_THEME_VU_P, vreq)
      reaper.gmem_write(G.GS_THEME_VU_GEN,
        math.floor(reaper.gmem_read(G.GS_THEME_VU_GEN) or 0) + 1)
      i = i + 1
    end
  end)
  reaper.gmem_attach(core.GMEM_NAME)   -- ALWAYS restore the main segment
  -- ChannelTool runs the appearance cluster but its options:gmem= IS the main
  -- segment, so it is deliberately absent from THEME_FX_SEGMENTS and the loop
  -- above never reaches it. Mirror the broadcast here too — payload before
  -- generation, same order as the loop — or ChannelTool never adopts a sync.
  pcall(function()
    reaper.gmem_write(G.GS_THEME_VU_P, vreq)
    reaper.gmem_write(G.GS_THEME_VU_GEN,
      math.floor(reaper.gmem_read(G.GS_THEME_VU_GEN) or 0) + 1)
  end)
end

-- Reader (Lua consumers): one semantic color → r,g,b (0..1), or nil if idle.
function core.read_theme_color(slot)
  local G = core.GMEM
  if (reaper.gmem_read(G.GS_THEME_ID) or 0) <= 0 then return nil end
  local base = G.GS_THEME_BASE + slot * 3
  return reaper.gmem_read(base), reaper.gmem_read(base + 1), reaper.gmem_read(base + 2)
end

function core.write_pad_name(pad, name)
  local G = core.GMEM
  local base = G.PADNAME_BASE + pad * G.PADNAME_LEN
  for i = 0, G.PADNAME_LEN - 1 do
    local c = 0
    if i < #name then c = name:byte(i + 1) end
    reaper.gmem_write(base + i, c)
  end
end

function core.pad_has_audio(pad)
  return reaper.gmem_read(core.GMEM.AUDIOLEN_BASE + pad) > 0
end

-- Playable = has audio OR an enabled SYN slot. AUDIOLEN stays a pure AUDIO
-- signal (save/stream paths depend on 0-for-synth-only), so synth playability
-- comes from the per-instance IDENT AUDIO flag (1 = playable, -1 = blank —
-- the JSFX publishes pad_is_playable there since 2026-07-29). slot = registry
-- slot 0-15 or nil (nil falls back to the audio-only answer).
function core.pad_is_playable(pad, slot)
  if reaper.gmem_read(core.GMEM.AUDIOLEN_BASE + pad) > 0 then return true end
  if slot == nil then return false end
  return (reaper.gmem_read(core.GMEM.INST_IDENT_BASE
    + slot * core.GMEM.INST_IDENT_INST_STRIDE
    + pad * core.GMEM.INST_IDENT_PAD_FIELDS
    + core.GMEM.IDENT_OFF_AUDIO) or 0) > 0.5
end

function core.get_pad_layer_count(pad)
  -- META offset +32 = p_layer_cnt (0=legacy/single, 1-4=loaded layers)
  return math.floor(reaper.gmem_read(core.GMEM.META_BASE + pad * core.GMEM.META_PP + 32))
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- COLOR UTILITIES
-- ═══════════════════════════════════════════════════════════════════════════════

core.PAD_COLOR_S = 0.75
core.PAD_COLOR_L = 0.55

function core.hsl_to_rgb(h, s, l)
  if s == 0 then return l, l, l end
  local function hue2rgb(p, q, t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end
  local q = l < 0.5 and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  return hue2rgb(p, q, h + 1/3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1/3)
end

-- RGB → hue (0..1). Inputs in 0..255. Used by the bridge's reverse-direction
-- sync to convert REAPER track colors (I_CUSTOMCOLOR) back into hue values
-- the JSFX understands. Saturation/lightness are intentionally discarded —
-- Swing's color system separates hue (per-pad) from S/L (theme-derived).
function core.rgb_to_hue(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  if mx == mn then return 0 end  -- grayscale → arbitrary hue, use 0
  local d = mx - mn
  local h
  if mx == r then
    h = ((g - b) / d) % 6
  elseif mx == g then
    h = (b - r) / d + 2
  else
    h = (r - g) / d + 4
  end
  return h / 6
end

function core.hsl_to_rgba(h, s, l, a)
  local r, g, b = core.hsl_to_rgb(h, s, l)
  return math.floor(r * 255 + 0.5) * 0x1000000
       + math.floor(g * 255 + 0.5) * 0x10000
       + math.floor(b * 255 + 0.5) * 0x100
       + (a or 0xFF)
end

function core.get_pad_color(pad)
  local G = core.GMEM
  local hue = reaper.gmem_read(G.META_BASE + pad * G.META_PP + 12)
  -- Read effective S/L from gmem so browser pads match the JSFX face's
  -- theme + intensity dial. JSFX writes these from swing_color_rebuild()
  -- whenever palette/intensity/theme changes.
  --
  -- Initialization probe: use eff_l (theme lightness) as the "JSFX has
  -- written" sentinel because every valid theme has L > 0 (smallest is
  -- 0.35 = Dark). eff_s CAN legitimately be 0 (intensity dial at 0% =
  -- full grayscale), so checking eff_s would clobber that valid case
  -- and snap pads back to default 0.75 saturation.
  local eff_s = reaper.gmem_read(G.GS_COL_EFFECTIVE_S)
  local eff_l = reaper.gmem_read(G.GS_COL_EFFECTIVE_L)
  if eff_l <= 0 or eff_l > 1 then
    eff_s = core.PAD_COLOR_S
    eff_l = core.PAD_COLOR_L
  else
    -- Clamp eff_s to [0,1] but DO honor 0 (grayscale via intensity=0)
    if eff_s < 0 then eff_s = 0 end
    if eff_s > 1 then eff_s = 1 end
  end
  -- B/W sentinel values from overlay color picker: -2 = black, -1 = white
  if hue <= -1.5 then
    return 0x333338FF  -- black (0.20, 0.20, 0.22)
  elseif hue < 0 then
    return 0xD1D1D9FF  -- white (0.82, 0.82, 0.85)
  end
  return core.hsl_to_rgba(hue, eff_s, eff_l)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- DRUM TYPE DETECTION
-- ═══════════════════════════════════════════════════════════════════════════════

core.DRUM_COLORS = {
  kick=0.00, kik=0.00, ["808"]=0.00, sub=0.76,
  snare=0.12, snr=0.12, rim=0.06, clap=0.30, clp=0.30,
  hat=0.49, hh=0.49, oh=0.72, ch=0.52, closed=0.52, hihat=0.49,
  tom=0.03, perc=0.40, shaker=0.35, tamb=0.33,
  cymbal=0.21, ride=0.17, crash=0.19,
  fx=0.82, vox=0.62, stab=0.66, pad=0.58, loop=0.86,
  cowbell=0.25, click=0.27, snap=0.40, stomp=0.03,
  conga=0.95, bongo=0.97, ["909"]=0.00
}

function core.guess_drum_type(filename)
  local name = filename:lower()
  -- Strip common audio extensions
  name = name:gsub("%.wav$",""):gsub("%.aif[f]?$",""):gsub("%.mp3$","")
             :gsub("%.flac$",""):gsub("%.ogg$","")
  -- Clean up for matching
  name = name:gsub("%d+",""):gsub("^%s+",""):gsub("%s+$",""):gsub("[_%-]"," ")
  for keyword, hue in pairs(core.DRUM_COLORS) do
    if name:find(keyword, 1, true) then return keyword, hue end
  end
  return nil, 0.5  -- no match → neutral hue
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- TRACK HELPERS
-- ═══════════════════════════════════════════════════════════════════════════════

-- Decode a send's I_SRCCHAN into the Swing pad index it feeds, or -1.
--
-- I_SRCCHAN is NOT a plain channel number. It packs a width code above the
-- channel: the low 10 bits are the first channel, the bits above are the width
-- (0=stereo, 1=mono, 2=quad, 3=6ch, 4=8ch), and -1 means the send carries no
-- audio at all. Stereo's code is 0, so for every send WE create the packed
-- value equals the bare channel and reading it raw appears to work.
--
-- It stops working the moment a user opens REAPER's routing dialog and sets one
-- pad's send to mono: the value gains 1024, which is still even, so a bare
-- `src_chan % 2 == 0` test passes and `src_chan / 2` lands past NUM_PADS. The
-- lane then silently stops being renamed, coloured and mute/solo-mirrored, with
-- no error anywhere. Masking the width off keeps that lane working as a lane —
-- which is right, since the user only changed how wide the send is, not what it
-- feeds.
function core.srcchan_pad(src_chan)
  if not src_chan then return -1 end
  src_chan = math.floor(src_chan)
  if src_chan < 0 then return -1 end   -- -1 = no audio on this send
  local ch = src_chan % 1024           -- strip the width code
  if ch % 2 ~= 0 then return -1 end    -- pads sit on even channel pairs
  return ch / 2
end

-- Iterate every track in the project — master FIRST, then regular tracks.
-- Use this anywhere you'd otherwise write
--     for i = 0, reaper.CountTracks(0) - 1 do
--       local tr = reaper.GetTrack(0, i)
-- because that pattern silently skips the master track. A Swing instance on
-- the master track is valid, and any code that searches for Swing must see
-- it (otherwise actions like multi-out build, kit dispatch, FX picker, and
-- ensure_32ch all fail with a confusing "Could not find Swing" message).
function core.iter_all_tracks()
  local i = -1  -- -1 = haven't yielded master yet; 0..n-1 = regular tracks
  return function()
    if i == -1 then
      i = 0
      return reaper.GetMasterTrack(0)
    end
    if i >= reaper.CountTracks(0) then return nil end
    local tr = reaper.GetTrack(0, i)
    i = i + 1
    return tr
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- EON HUB PUSH IPC (bundle .docs/specs/Spec_EON_Hub_Swing_Integration.md §3)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Tell EON Hub that a role window is opening/closing NOW, so its tab
-- captures/activates immediately instead of waiting for the 500 ms poll.
-- Call AFTER the window-state change (TrackFX_Show / script launch).
-- Degrades to a silent no-op when the Hub extension isn't installed.
--   event: "open" (user gesture → capture + activate) | "close" | "announce"
--          ("announce" = adopt without focus-steal, e.g. auto-opens)
--   role : "swing" | "stepseq" | "padfx" | "browser"
--          ⚠️ CONTRACT with the Hub's role registry (eon_integration.cpp
--          kRoles[].key) — never rename one side alone.
--   tr,fx: optional — the FX instance for fx-float roles (P3 uses the GUIDs).
local hub_nudge_cmd  -- nil = not looked up yet; 0 = Hub absent this session

function core.hub_notify(event, role, tr, fx)
  if hub_nudge_cmd == 0 then return end
  if hub_nudge_cmd == nil then
    hub_nudge_cmd = reaper.NamedCommandLookup("_EON_HUB_NUDGE") or 0
    if hub_nudge_cmd == 0 then return end
  end
  local seq = (tonumber(reaper.GetExtState("EON_HUB_IPC", "seq")) or 0) + 1
  local msg = string.format("v1|%s|t=%d|role=%s|inst=0", event, os.time(), role)
  if tr and fx and fx >= 0 then
    local _, tg = reaper.GetSetMediaTrackInfo_String(tr, "GUID", "", false)
    local fg = reaper.TrackFX_GetFXGUID(tr, fx)
    if tg and tg ~= "" and fg then msg = msg .. "|track=" .. tg .. "|fx=" .. fg end
  end
  -- 16-slot ring + monotonic seq, then the nudge command: the Hub drains
  -- synchronously but defers heavy work via PostMessage (never blocks us).
  reaper.SetExtState("EON_HUB_IPC", "msg_" .. (seq % 16), msg, false)
  reaper.SetExtState("EON_HUB_IPC", "seq", tostring(seq), false)
  reaper.Main_OnCommand(hub_nudge_cmd, 0)
end

return core
