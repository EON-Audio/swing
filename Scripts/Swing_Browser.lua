-- Swing Sample Browser v5 — ImGui GUI
-- (c) EON Studios — All Rights Reserved
--
-- Companion to Swing_Kit_Bridge.lua. Provides a sample browser
-- for navigating folders, previewing audio, and assigning samples to pads.
--
-- ARCHITECTURE:
--   Uses ReaImGui for UI (requires ReaImGui extension via ReaPack).
--   Runs its own defer loop (independent from the bridge).
--   Communicates with Swing JSFX via gmem for pad assignment.
--   Reads active instance from ExtState to find the right gmem namespace.
--   Never acquires the instance lock — writes to gmem, bridge picks up CMD 61.
--
-- TYPE:   system
-- SCOPE:  project_tracks
-- POLICY: preserve_selection
-- TIER:   T1                    -- T2 for JS_Dialog_BrowseForFolder, T3 PLANNED for analysis
--
-- INSTALLATION:
--   Actions → Show action list → ReaScript: Load → select this file.
--   Launch manually or via CMD 60 from Swing JSFX.

-- ═══════════════════════════════════════════════════════════════════════════════
-- DEPENDENCY CHECK
-- ═══════════════════════════════════════════════════════════════════════════════
if not reaper.ImGui_GetBuiltinPath then
  -- Signal back to JSFX so a "ReaImGui not installed" banner appears in
  -- the LCD area (rk_swing_ui_state.jsfx-inc — same pattern as the
  -- bridge-not-running warning). GS_REAIMGUI_MISSING = 2368.
  -- We attach to gmem here even though we're early-returning; the cost
  -- is negligible and signaling the JSFX is the whole point.
  reaper.gmem_attach("Swing_Media_Transfer")
  reaper.gmem_write(2368, 1)
  reaper.MB(
    "Swing Browser requires the ReaImGui extension.\n\n"..
    "Install it from ReaPack:\n"..
    "  Extensions → ReaPack → Browse packages → search 'ReaImGui'\n\n"..
    "Then restart REAPER and try again.",
    "Swing Browser — Missing Dependency", 0)
  return
end

-- ReaImGui is present this session. Clear the flag if it was set by a
-- previous failed launch (e.g., user installed ReaImGui via ReaPack
-- without restarting REAPER, then re-clicked BROWSE).
reaper.gmem_attach("Swing_Media_Transfer")
reaper.gmem_write(2368, 0)

local function _get_script_dir()
  local info = debug.getinfo(1, "S")
  local path = info.source:match("@?(.*)")
  return path:match("^(.*)[/\\]") or ""
end
local _SCRIPT_DIR = _get_script_dir()
local _sep = package.config:sub(1,1)

package.path = _SCRIPT_DIR .. _sep .. "?.lua;" ..
               reaper.ImGui_GetBuiltinPath() .. "/?.lua;" ..
               (package.path or "")
local ImGui = require 'imgui' '0.9.3.2'

-- ═══════════════════════════════════════════════════════════════════════════════
-- SHARED MODULES (ReaKit Lua library)
-- ═══════════════════════════════════════════════════════════════════════════════
local core    = require("rk_lua_core")
local categorizer = require("eon_filename_categorizer")
local widgets = require("rk_lua_widgets")
local rootnote = require("rk_root_note")
-- Measured sample analysis (attack / decay / band / tonality / space).
-- Ported from TK Kit Maker under the 2026-08-01 MIT grant — see the module
-- header and .docs/refs/TK_Permission_DM_2026-08-01.md.
local measure = require("rk_lua_sample_analysis")
widgets.init(ImGui, core)

-- ═══════════════════════════════════════════════════════════════════════════════
-- CONSTANTS
-- ═══════════════════════════════════════════════════════════════════════════════
local SCRIPT_NAME = "EON Sample Browser — Swing"
local VERSION     = "5.0"

-- gmem address table. Referenced as G.NAME at every call site on purpose:
-- the main chunk is capped at 200 top-level locals by Lua and a block of
-- one-alias-per-address locals used to eat ~34 of them (and once pushed the
-- file past the limit outright). Do NOT reintroduce `local FOO = G.FOO`.
local G = core.GMEM

-- OS shortcuts from core
local sep = core.sep
local is_windows = core.is_windows

-- Shell-safe quoting for os.execute / ExecProcess arguments
local function shell_quote(s)
  if not s then return '""' end
  if is_windows then
    return '"' .. s:gsub('"', '') .. '"'
  else
    return "'" .. s:gsub("'", "'\\''") .. "'"
  end
end

-- Resolve a user-profile dir (Desktop / Downloads / Documents) with OneDrive
-- folder-redirection awareness on Windows. When OneDrive is set up to manage
-- a user's Desktop, %USERPROFILE%\Desktop is empty and the real folder lives
-- under %OneDrive%\Desktop. Probe the OneDrive variant first; only fall back
-- to the literal %USERPROFILE%\<name> if no OneDrive copy exists.
local function dir_exists(p)
  if not p or p == "" then return false end
  return reaper.EnumerateSubdirectories(p, 0) ~= nil
      or reaper.EnumerateFiles(p, 0) ~= nil
end

local function resolve_user_dir(name)
  if is_windows then
    local profile = os.getenv("USERPROFILE") or ""
    -- Try the OneDrive env vars Windows sets when redirection is active.
    local od = os.getenv("OneDrive")
            or os.getenv("OneDriveConsumer")
            or os.getenv("OneDriveCommercial")
    if od and od ~= "" then
      local p = od .. "\\" .. name
      if dir_exists(p) then return p end
    end
    -- Fallback probe: %USERPROFILE%\OneDrive\<name> in case env wasn't set.
    if profile ~= "" then
      local p = profile .. "\\OneDrive\\" .. name
      if dir_exists(p) then return p end
    end
    return profile .. "\\" .. name
  else
    return (os.getenv("HOME") or "") .. "/" .. name
  end
end

-- Function aliases from core
local get_extension   = core.get_extension
local is_audio_file   = core.is_audio_file
local is_native_audio = core.is_native_audio
local format_size     = core.format_size
local format_duration = core.format_duration
local get_parent_dir  = core.get_parent_dir
local get_folder_name = core.get_folder_name
local get_pad_color_from_gmem = core.get_pad_color
local get_pad_layer_count = core.get_pad_layer_count
local NATIVE_EXT    = core.NATIVE_EXT

-- ═══════════════════════════════════════════════════════════════════════════════
-- STATE TABLES
-- ═══════════════════════════════════════════════════════════════════════════════

local playback = {
  preview       = nil,      -- CF_Preview handle
  is_playing    = false,
  is_paused     = false,
  volume        = 0.8,      -- 0-1
  pitch         = 0,        -- semitones (-12 to +12)
  loop          = false,
  position      = 0,        -- seconds
  length        = 0,        -- seconds
  current_file  = "",       -- path of previewing file
  auto_play     = true,     -- preview on select
}

local file_mgr = {
  current_path    = "",
  entries         = {},     -- {name, path, is_dir, size, ext, duration}
  filtered        = nil,    -- nil = no filter active, else filtered list
  history         = {},     -- back stack of paths
  sort_column     = 1,      -- 1=name, 2=category, 3=type, 4=channels, 5=size, 6=duration, 7=bpm, 8=key
  sort_ascending  = true,
  selected_index  = 0,      -- 0 = none (drives preview/waveform)
  selected_set    = {},     -- { [index] = true } for multi-select
  range_anchor    = 0,      -- Shift+click range start
  focused_index   = 0,      -- last-clicked item (brighter highlight)
  pending_deselect = 0,     -- deferred deselect: index to reduce to on mouse-up
  pending_deselect_time = 0,  -- timestamp when pending was set (debounce for double-click)
  favorites       = {},     -- list of {path=, name=}
  recent_folders  = {},     -- list of paths (max 10)
  needs_rescan    = true,
  category_filter = nil,    -- nil = no category filter, else category string ("kick", "snare", etc.)
  recurse         = false,  -- Subfolders mode: BFS through subdirs, flatten all audio files into entries
}

local search = {
  query   = "",
  pending_time = 0,  -- debounce timer (§12.3)
}
local SEARCH_DEBOUNCE_MS = 80  -- ms before refiltering after keystroke

local waveform = {
  peaks       = {},     -- array of peak values
  peak_count  = 0,
  cached_file = "",     -- which file peaks belong to
  cached_width = 0,     -- display width used for peak generation
  src_length  = 0,      -- source length in seconds
  -- Spectral analysis (TK-style optional spectral coloring). FFT is
  -- expensive — cache per-file with width invalidation. spectral_data
  -- is num_slices floats 0..1 mapping bass→treble for the file's
  -- timeline. Computed only when settings.spectral_view is true.
  spectral_data        = {},
  spectral_cached_file = "",
  spectral_cached_w    = 0,
}

local ui = {
  ctx           = nil,   -- ImGui context
  is_open       = true,
  target_pad    = 0,     -- 0-15
  prev_target_pad = -1,  -- track pad changes from JSFX
  first_frame   = true,
  was_docked    = nil,    -- dock transition detection (nil = first frame, skip resolved)
  dock_skip     = 0,      -- frames remaining to skip after dock transition
  -- Dock toggle: when user clicks the Dock button or restores from settings
  -- on first frame, set pending_dock_id and want_dock_change so the next
  -- Begin call applies it via SetNextWindowDockID(Cond_Always).
  want_dock_change = false,
  pending_dock_id  = 0,
}

local SETTINGS_VERSION = 1  -- increment on breaking schema changes (see §11 migration)

local settings = {
  version        = SETTINGS_VERSION,
  last_folder    = "",
  window_w       = 900,
  window_h       = 550,
  volume         = 0.8,
  auto_play      = true,
  favorites      = {},
  recent_folders = {},
  sort_column    = 1,
  sort_ascending = true,
  loop_preview   = false,
  theme          = "dark",   -- "dark" or "light"
  show_shortcuts = true,
  show_favorites = true,
  show_recent    = true,
  show_kits      = true,
  show_categories = true,
  categories_open = true,
  -- Sidebar collapsible-section open state. ImGui's CollapsingHeader uses
  -- DefaultOpen on every script launch, which resets the user's collapse
  -- choices. We mirror the state into settings each frame and feed it
  -- back via SetNextItemOpen(Cond_Once) on init so the layout survives
  -- a browser close → reopen cycle.
  kits_open      = true,
  shortcuts_open = true,
  favorites_open = true,
  recent_open    = true,
  -- Left-pane 4x4 pad grid. Optional since samples can be dragged straight
  -- onto the plugin's own pads (EON_DRAG); collapsing it hands the vertical
  -- space to the favorites/kits sidebar below. Default open — the grid is
  -- still how you see loaded/muted pads and pick a target pad.
  pads_open      = true,
  -- Whole left pane (pads + pad controls + kits/favorites sidebar). Hiding it
  -- is the one that widens the FILE TABLE, since that lives in the right pane
  -- — collapsing the pad grid alone only frees vertical space within the left.
  left_pane_open = true,
  dock_id        = 0,        -- 0 = floating, negative = REAPER docker, positive = ImGui dock
  spectral_view  = false,    -- TK-style spectral coloring of waveform preview (FFT per pixel)
  grid_overlay   = false,    -- TK-style time grid overlay on waveform preview
  recurse_subfolders = false,-- Subfolders mode: flatten all audio files from subdirectories into one list
  kit_fill_mode  = false,    -- Kit-categories ④: OFF = LOAD (author's layout), ON = FILL (category-match onto MY layout)
}

-- ═══════════════════════════════════════════════════════════════════════════════
-- KIT AWARENESS + DATABASE
-- ═══════════════════════════════════════════════════════════════════════════════

local kit_db = {
  kit_name    = "",        -- current kit name from gmem
  prev_name   = "",        -- previous kit name (for change detection)
  data        = nil,       -- loaded .swing Lua table (the database)
  filepath    = "",        -- path to current .swing file
  dirty       = false,     -- true if database needs saving
  cache       = {},        -- BPM/key analysis cache { [filepath] = {bpm=, key=, analyzed=} }
}

-- Window-title track-number cache. The full track+FX scan to resolve
-- the browser target's track index is O(tracks×fx) every frame; cache
-- the result and re-scan only when the target instance changes or 2s
-- have elapsed (catches track rearrangement without full freshness).
local title_track_cache_target = 0
local title_track_cache_value  = 0
local title_track_cache_at     = 0

local get_kits_dir = core.get_kits_dir

-- ═══════════════════════════════════════════════════════════════════════════════
-- KIT BROWSER (sidebar section with thumbnails)
-- ═══════════════════════════════════════════════════════════════════════════════

local kit_browser = {
  kits         = {},      -- { {name=, path=, image_path=, image=nil, image_failed=false} }
  needs_scan   = true,    -- scan on first open or after refresh
  selected_idx = 0,       -- 1-based index of selected kit (0 = none)
}

local IMG_EXT = {"png", "jpg", "jpeg"}

-- Compare two strings the way a person reads them: a run of digits counts as
-- one number rather than as characters. Plain string compare stops at the first
-- character that differs, so "Kick 10" < "Kick 2" ("1" beats "2" and the 0 is
-- never reached) and a drum folder lists 1, 10, 11, 2 -- which reads as the sort
-- having given up. Caller lowercases first if it wants case-insensitive.
local function natural_lt(a, b)
  local ia, ib = 1, 1
  local la, lb = #a, #b
  while ia <= la and ib <= lb do
    local ca, cb = a:byte(ia), b:byte(ib)
    if ca >= 48 and ca <= 57 and cb >= 48 and cb <= 57 then
      local sa, sb = ia, ib
      repeat ia = ia + 1 until ia > la or a:byte(ia) < 48 or a:byte(ia) > 57
      repeat ib = ib + 1 until ib > lb or b:byte(ib) < 48 or b:byte(ib) > 57
      -- Compared as text after stripping leading zeros, not via tonumber:
      -- a longer run of significant digits is the larger number, and equal
      -- lengths compare correctly character by character. tonumber would go
      -- through a double and stop being exact past ~16 digits, which a
      -- date-stamped filename reaches.
      local ra = a:sub(sa, ia - 1):gsub("^0+", "")
      local rb = b:sub(sb, ib - 1):gsub("^0+", "")
      if #ra ~= #rb then return #ra < #rb end
      if ra  ~= rb  then return ra  <  rb  end
      -- Same value, different padding ("02" vs "2"). Order them anyway, or
      -- table.sort has two items neither of which sorts before the other.
      if (ia - sa) ~= (ib - sb) then return (ia - sa) < (ib - sb) end
    else
      if ca ~= cb then return ca < cb end
      ia, ib = ia + 1, ib + 1
    end
  end
  return (la - ia) < (lb - ib)   -- whichever ran out first is the shorter string
end

local function scan_kits()
  local kits_dir = get_kits_dir()
  kit_browser.kits = {}
  local idx = 0
  while true do
    local fname = reaper.EnumerateFiles(kits_dir, idx)
    if not fname then break end
    if fname:match("%.swing$") then
      local kit_name = fname:gsub("%.swing$", "")
      local fpath = kits_dir .. sep .. fname
      -- Check for matching thumbnail image
      local img_path = nil
      for _, ext in ipairs(IMG_EXT) do
        local candidate = kits_dir .. sep .. kit_name .. "." .. ext
        local f = io.open(candidate, "rb")
        if f then f:close(); img_path = candidate; break end
      end
      kit_browser.kits[#kit_browser.kits + 1] = {
        name         = kit_name,
        path         = fpath,
        image_path   = img_path,
        image        = nil,     -- lazy-loaded ImGui image handle
        image_failed = false,   -- don't retry failed loads
      }
    end
    idx = idx + 1
  end
  -- Plain alphabetical on purpose -- NOT natural_lt like the file and folder
  -- lists. Kit names lead with a model number rather than a count, so reading
  -- it as a number puts 8T8 and 9T9 above 808 F (8 and 9 being less than 808),
  -- which is right arithmetic and the wrong list.
  table.sort(kit_browser.kits, function(a, b) return a.name:lower() < b.name:lower() end)
  kit_browser.selected_idx = 0
  kit_browser.needs_scan = false
end

local function get_kit_image(ctx, kit_entry)
  if kit_entry.image then return kit_entry.image end
  if kit_entry.image_failed or not kit_entry.image_path then return nil end
  -- Lazy-load: create image + attach to context for auto-cleanup
  local ok, img = pcall(ImGui.CreateImage, kit_entry.image_path)
  if ok and img then
    ImGui.Attach(ctx, img)
    kit_entry.image = img
    return img
  else
    kit_entry.image_failed = true
    return nil
  end
end

local function load_kit_from_browser(filepath)
  -- Signal bridge to load this kit via dedicated flag (not CMD — avoids defer/gfx race)
  reaper.SetExtState("Swing", "kit_load_path", filepath, false)
  -- Name the target explicitly on the dedicated request-want channel
  -- (Phase 1b, GS_LOAD_WANT): the bridge consumes it when it picks up this
  -- request. Deliberately NOT written to GS_PENDING_LOAD_INST anymore —
  -- that cell is now exclusively the bridge→JSFX delivery binding, and a
  -- rapid second click writing it mid-dispatch erased the in-flight load's
  -- binding before its target armed (30s orphan, kitpipe storm catch).
  -- An OLD bridge (no WANT reader) still resolves via the gmem[INSTANCE]
  -- browser binding, which this browser maintains continuously.
  if active_inst_id and active_inst_id > 0 then
    reaper.gmem_write(G.GS_LOAD_WANT, active_inst_id)
  end
  -- Kit-categories ④: declare LOAD vs FILL for THIS request. Written BEFORE
  -- REQ=1 (the bridge reads the mode when it consumes the request, then
  -- clears it — one-shot, never a sticky global mode on the bus).
  reaper.gmem_write(G.GS_KIT_LOAD_MODE, settings.kit_fill_mode and 1 or 0)
  reaper.gmem_write(G.GS_KIT_LOAD_REQ, 1)  -- 1 = request
end

-- Read kit name from gmem (16 chars max). Trim trailing whitespace because
-- the JSFX may pad short names with spaces — we don't want them surfacing
-- in the title bar.
local function read_kit_name_from_gmem()
  local chars = {}
  for i = 0, G.GS_KIT_NAME_LEN - 1 do
    local c = math.floor(reaper.gmem_read(G.GS_KIT_NAME_BASE + i))
    if c > 0 then chars[#chars + 1] = string.char(c) else break end
  end
  return (table.concat(chars):gsub("%s+$", ""))
end

-- Find .swing file by kit name.
-- Phase 2 (2026-07-17): the displayed name is now filename-canonical, so the
-- exact reconstruction below is normally right. The gmem name band is 32
-- chars though — a longer filename arrives TRUNCATED, so fall back to a
-- prefix match over the kits dir before giving up (first match wins; a
-- 32-char collision is on the user's naming).
local function find_swing_file(kit_name)
  if not kit_name or kit_name == "" then return nil end
  local safe_name = kit_name:gsub('[<>:"/\\|%?%*]', '_')
  local kits_dir = get_kits_dir()
  local path = kits_dir .. sep .. safe_name .. ".swing"
  local f = io.open(path, "r")
  if f then f:close(); return path end
  if #kit_name >= 32 then
    local i = 0
    while true do
      local fn = reaper.EnumerateFiles(kits_dir, i)
      if not fn or fn == "" then break end
      if fn:sub(-6):lower() == ".swing" and fn:sub(1, #kit_name) == kit_name then
        return kits_dir .. sep .. fn
      end
      i = i + 1
    end
  end
  return nil
end

-- Load .swing v2 database (Lua table)
local function load_kit_database(filepath)
  if not filepath then return nil end
  local chunk, err = loadfile(filepath, "t", {})
  if not chunk then return nil end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" then return nil end
  return data
end

-- Create a minimal .swing v2 file for a new kit
local function create_kit_database(kit_name)
  local safe_name = kit_name:gsub('[<>:"/\\|%?%*]', '_')
  local kits_dir = get_kits_dir()
  local filepath = kits_dir .. sep .. safe_name .. ".swing"
  -- Don't overwrite existing files
  local f = io.open(filepath, "r")
  if f then f:close(); return filepath end
  -- Create minimal v2 file
  f = io.open(filepath, "w")
  if not f then return nil end
  f:write("-- Swing Kit v2 — EON Studios — proprietary\n")
  f:write("return {\n")
  f:write('  version  = 2,\n')
  f:write('  kit_name = "' .. kit_name:gsub('"', '\\"') .. '",\n')
  f:write('  author   = "",\n')
  f:write('  created  = "' .. os.date("%Y-%m-%d") .. '",\n')
  f:write('  modified = "' .. os.date("%Y-%m-%d") .. '",\n')
  f:write('  globals  = {},\n')
  f:write('  pads     = {},\n')
  f:write('  cache    = {},\n')
  f:write('}\n')
  f:close()
  return filepath
end

-- Save database back to .swing file (preserves all existing data, updates modified date)
local function save_kit_database()
  if not kit_db.data or not kit_db.filepath or kit_db.filepath == "" then return end

  -- Magic check: never overwrite a v3/v4 binary kit (SWINGv03/SWINGv04) with
  -- the browser's v2 path-only text format. The browser only knows the BPM/Key
  -- analysis cache + whatever pads metadata happens to be in kit_db.data; the
  -- real audio + per-layer data lives in the binary file. Clobbering it with
  -- v2 text is what produced the "blank kit on reopen" bug. If a write would
  -- destroy a binary save, skip silently — the cache update for this frame is
  -- lost, but nothing breaks (re-analysis on next browse re-populates).
  local probe = io.open(kit_db.filepath, "rb")
  if probe then
    local magic = probe:read(7) or ""
    probe:close()
    if magic == "SWINGv0" then return end
  end

  local data = kit_db.data
  data.modified = os.date("%Y-%m-%d")
  -- Update cache from working state
  data.cache = kit_db.cache

  local f = io.open(kit_db.filepath, "w")
  if not f then
    reaper.ShowConsoleMsg("[EON] Warning: could not save kit database to " .. kit_db.filepath .. "\n")
    return
  end
  f:write("-- Swing Kit v2 — EON Studios — proprietary\n")
  f:write("return {\n")
  f:write('  version  = ' .. (data.version or 2) .. ',\n')
  f:write('  kit_name = "' .. (data.kit_name or ""):gsub('"', '\\"') .. '",\n')
  f:write('  author   = "' .. (data.author or ""):gsub('"', '\\"') .. '",\n')
  f:write('  created  = "' .. (data.created or os.date("%Y-%m-%d")) .. '",\n')
  f:write('  modified = "' .. data.modified .. '",\n')

  -- Write globals if present
  if data.globals and next(data.globals) then
    f:write('  globals = {\n')
    for k, v in pairs(data.globals) do
      f:write('    ' .. k .. ' = ' .. tostring(v) .. ',\n')
    end
    f:write('  },\n')
  else
    f:write('  globals = {},\n')
  end

  -- Write pads if present
  if data.pads and next(data.pads) then
    f:write('  pads = {\n')
    for i = 1, 16 do
      local p = data.pads[i]
      if p then
        f:write('    [' .. i .. '] = {\n')
        for k, v in pairs(p) do
          if type(v) == "string" then
            f:write('      ' .. k .. ' = "' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '",\n')
          elseif type(v) == "number" then
            f:write('      ' .. k .. ' = ' .. v .. ',\n')
          elseif type(v) == "boolean" then
            f:write('      ' .. k .. ' = ' .. tostring(v) .. ',\n')
          end
        end
        f:write('    },\n')
      end
    end
    f:write('  },\n')
  else
    f:write('  pads = {},\n')
  end

  -- Write cache (trim: only keep entries still referenced)
  if kit_db.cache and next(kit_db.cache) then
    -- Collect referenced paths
    local referenced = {}
    if data.pads then
      for _, p in pairs(data.pads) do
        if p.path and p.path ~= "" then referenced[p.path] = true end
      end
    end
    f:write('  cache = {\n')
    for path, info in pairs(kit_db.cache) do
      if referenced[path] then
        f:write('    ["' .. path:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"] = {\n')
        if info.bpm then f:write('      bpm = ' .. info.bpm .. ',\n') end
        if info.key then f:write('      key = "' .. info.key .. '",\n') end
        if info.analyzed then f:write('      analyzed = "' .. info.analyzed .. '",\n') end
        f:write('    },\n')
      end
    end
    f:write('  },\n')
  else
    f:write('  cache = {},\n')
  end

  f:write('}\n')
  f:close()
  kit_db.dirty = false
end

-- Handle kit name change: load or create database
local function on_kit_name_change(new_name)
  -- Save previous database if dirty
  if kit_db.dirty and kit_db.data then
    save_kit_database()
  end

  kit_db.kit_name = new_name
  kit_db.prev_name = new_name
  kit_db.cache = {}
  kit_db.data = nil
  kit_db.filepath = ""
  -- Persistent analysis cache (keyed by file path) survives kit changes —
  -- BPM/key for kick.wav doesn't change because you switched kit. Only
  -- discard the in-flight DSP queue.
  analysis_queue = {}  -- discard pending analysis work

  if new_name == "" then return end

  -- Try to find and load existing .swing file
  local path = find_swing_file(new_name)
  if path then
    kit_db.filepath = path
    kit_db.data = load_kit_database(path)
    if kit_db.data then
      -- Populate cache from loaded data
      if kit_db.data.cache then
        for k, v in pairs(kit_db.data.cache) do
          kit_db.cache[k] = v
        end
      end
    end
  else
    -- No .swing file found — DO NOT create a v2 placeholder here. The browser
    -- used to write a minimal `pads = {}` file just because the user typed a
    -- new kit name, which then shadowed the JSFX's later v3/v4 binary save
    -- (binary file got "blank kit" on reopen because this empty v2 was loaded
    -- instead). The first real save now happens via JSFX → Kit Bridge →
    -- write_kit_v4. Until that fires, kit_db.data stays nil and
    -- save_kit_database() bails (line 345), so nothing gets written prematurely.
    kit_db.filepath = ""
    kit_db.data = nil
  end
end

-- Update cache entry for a file
local function update_cache(filepath, bpm, key)
  kit_db.cache[filepath] = {
    bpm = bpm,
    key = key,
    analyzed = os.date("%Y-%m-%d"),
  }
  kit_db.dirty = true
end

-- Lookup cache entry
local function lookup_cache(filepath)
  return kit_db.cache[filepath]
end

-- SWS / extension checks
local has_sws = reaper.CF_CreatePreview ~= nil
local has_js  = reaper.JS_Dialog_BrowseForFolder ~= nil

-- ═══════════════════════════════════════════════════════════════════════════════
-- SETTINGS PERSISTENCE
-- ═══════════════════════════════════════════════════════════════════════════════

local SCRIPT_DIR = _SCRIPT_DIR
-- Per-user prefs live under REAPER's resource path (writable, persists across
-- plugin updates) — NOT next to the script. Keeping prefs in the source tree
-- meant a) personal paths leaked into the shipped installer, and b) plugin
-- updates would clobber user prefs.
local USER_DIR = (reaper.GetResourcePath() or "") .. sep .. "Data" .. sep .. "EON_Swing"
local SETTINGS_FILE = USER_DIR .. sep .. "Swing_Browser_Settings.lua"
-- One-time migration: if the legacy settings file exists next to the script,
-- read it (so we don't lose prefs) and delete it from the source tree.
local LEGACY_SETTINGS_FILE = SCRIPT_DIR .. sep .. "Swing_Browser_Settings.lua"

-- mkdir -p USER_DIR (REAPER doesn't expose this; use os.execute as a fallback)
local function ensure_user_dir()
  local probe = io.open(USER_DIR .. sep .. ".probe", "w")
  if probe then probe:close(); os.remove(USER_DIR .. sep .. ".probe"); return true end
  if is_windows then
    os.execute('mkdir "' .. USER_DIR .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. USER_DIR .. '"')
  end
  -- Re-probe
  local p2 = io.open(USER_DIR .. sep .. ".probe", "w")
  if p2 then p2:close(); os.remove(USER_DIR .. sep .. ".probe"); return true end
  return false
end

local function save_settings()
  settings.last_folder    = file_mgr.current_path
  settings.volume         = playback.volume
  settings.auto_play      = playback.auto_play
  settings.favorites      = file_mgr.favorites
  settings.recent_folders = file_mgr.recent_folders
  settings.sort_column    = file_mgr.sort_column
  settings.sort_ascending = file_mgr.sort_ascending
  settings.loop_preview   = playback.loop

  ensure_user_dir()
  local f = io.open(SETTINGS_FILE, "w")
  if not f then return end
  f:write("return {\n")
  -- version (required for future migration — see §11)
  f:write(string.format('  version = %d,\n', SETTINGS_VERSION))
  -- scalars
  f:write(string.format('  last_folder = %q,\n', settings.last_folder))
  f:write(string.format('  window_w = %d,\n', settings.window_w))
  f:write(string.format('  window_h = %d,\n', settings.window_h))
  f:write(string.format('  volume = %.3f,\n', settings.volume))
  f:write(string.format('  auto_play = %s,\n', tostring(settings.auto_play)))
  f:write(string.format('  sort_column = %d,\n', settings.sort_column))
  f:write(string.format('  sort_ascending = %s,\n', tostring(settings.sort_ascending)))
  f:write(string.format('  loop_preview = %s,\n', tostring(settings.loop_preview)))
  f:write(string.format('  theme = %q,\n', settings.theme or "dark"))
  f:write(string.format('  show_shortcuts = %s,\n', tostring(settings.show_shortcuts ~= false)))
  f:write(string.format('  show_favorites = %s,\n', tostring(settings.show_favorites ~= false)))
  f:write(string.format('  show_recent = %s,\n', tostring(settings.show_recent ~= false)))
  f:write(string.format('  show_kits = %s,\n', tostring(settings.show_kits ~= false)))
  f:write(string.format('  show_categories = %s,\n', tostring(settings.show_categories ~= false)))
  f:write(string.format('  categories_open = %s,\n', tostring(settings.categories_open ~= false)))
  f:write(string.format('  kits_open = %s,\n',      tostring(settings.kits_open ~= false)))
  f:write(string.format('  shortcuts_open = %s,\n', tostring(settings.shortcuts_open ~= false)))
  f:write(string.format('  pads_open = %s,\n',      tostring(settings.pads_open ~= false)))
  f:write(string.format('  left_pane_open = %s,\n', tostring(settings.left_pane_open ~= false)))
  f:write(string.format('  favorites_open = %s,\n', tostring(settings.favorites_open ~= false)))
  f:write(string.format('  recent_open = %s,\n',    tostring(settings.recent_open ~= false)))
  f:write(string.format('  dock_id = %d,\n', math.floor(settings.dock_id or 0)))
  f:write(string.format('  spectral_view = %s,\n', tostring(settings.spectral_view == true)))
  f:write(string.format('  grid_overlay = %s,\n',  tostring(settings.grid_overlay == true)))
  f:write(string.format('  recurse_subfolders = %s,\n', tostring(settings.recurse_subfolders == true)))
  f:write(string.format('  kit_fill_mode = %s,\n', tostring(settings.kit_fill_mode == true)))
  -- favorites
  f:write('  favorites = {\n')
  for _, fav in ipairs(settings.favorites) do
    f:write(string.format('    {path=%q, name=%q},\n', fav.path, fav.name))
  end
  f:write('  },\n')
  -- recent
  f:write('  recent_folders = {\n')
  for _, r in ipairs(settings.recent_folders) do
    f:write(string.format('    %q,\n', r))
  end
  f:write('  },\n')
  f:write("}\n")
  f:close()
end

-- Settings migration (§11.3): add future migrations here
local function migrate_settings(s)
  -- v1 is current — no migrations yet
  -- Example for future:
  -- if (s.version or 0) < 2 then
  --   s.new_field = s.old_field or default
  --   s.old_field = nil
  --   s.version = 2
  -- end
  s.version = SETTINGS_VERSION
  return s
end

local function load_settings()
  -- One-time migration from legacy in-source-tree location to user data dir.
  -- If the user's prefs file doesn't exist yet but the legacy one does, copy
  -- the legacy contents over (preserves favorites/recent), then leave the
  -- legacy file in place — but it will no longer be written to. (Don't
  -- delete it: that would break a downgrade-then-upgrade cycle.)
  local existing = io.open(SETTINGS_FILE, "r")
  if existing then
    existing:close()
  else
    local legacy = io.open(LEGACY_SETTINGS_FILE, "r")
    if legacy then
      local body = legacy:read("*a")
      legacy:close()
      ensure_user_dir()
      local out = io.open(SETTINGS_FILE, "w")
      if out then out:write(body); out:close() end
    end
  end

  local f = io.open(SETTINGS_FILE, "r")
  if not f then return end
  f:close()

  local chunk, err = loadfile(SETTINGS_FILE, "t", {})
  local ok, loaded = false, nil
  if chunk then ok, loaded = pcall(chunk) end
  if ok and type(loaded) == "table" then
    -- Merge missing keys from defaults (§11.2)
    for k, v in pairs(settings) do
      if loaded[k] == nil then loaded[k] = v end
    end
    loaded = migrate_settings(loaded)
    for k, v in pairs(loaded) do
      settings[k] = v
    end
    -- Apply to live state
    playback.volume    = settings.volume
    playback.auto_play = settings.auto_play
    playback.loop      = settings.loop_preview
    file_mgr.favorites     = settings.favorites or {}
    file_mgr.recent_folders = settings.recent_folders or {}
    file_mgr.sort_column    = settings.sort_column
    file_mgr.sort_ascending = settings.sort_ascending
    file_mgr.recurse        = settings.recurse_subfolders == true
    if settings.last_folder ~= "" then
      file_mgr.current_path = settings.last_folder
    end
    -- Clamp minimum window size (prevents squeezed layout from old saves)
    settings.window_w = math.max(settings.window_w, 700)
    settings.window_h = math.max(settings.window_h, 400)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- FORWARD DECLARATIONS
-- ═══════════════════════════════════════════════════════════════════════════════
local sort_entries
local add_recent
local analysis_cache             -- bound below from load_persistent_cache()
local analysis_queue = {}
local load_sample_to_pad
local load_layer_to_pad  -- fwd decl: process_import_queue (above its def) uses it

-- ═══════════════════════════════════════════════════════════════════════════════
-- PERSISTENT ANALYSIS CACHE (BPM/key short-circuit)
-- ═══════════════════════════════════════════════════════════════════════════════
-- Two layers in front of the DSP analyzer:
--   1) embedded-tag short-circuit (read_tags) — microseconds per file
--   2) on-disk cache with mtime invalidation — survives across sessions
-- The DSP path stays unchanged as the final fallback for un-tagged files.

local cache_dirty = false
local cache_last_save = 0

-- mtime via JS_ReaScriptAPI (soft dep). Returns nil if extension missing,
-- so cache lookup degrades to "trust until file is re-cached" gracefully.
local function get_file_mtime(filepath)
  if not reaper.JS_File_Stat then return nil end
  local rv, _, mtime = reaper.JS_File_Stat(filepath)
  if rv == 0 then return mtime end
  return nil
end

local function load_persistent_cache()
  local cache_path = core.get_cache_dir() .. sep .. "analysis.lua"
  local f = io.open(cache_path, "r")
  if not f then return {} end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return {} end
  -- Sandboxed env (defense in depth — never exec arbitrary code from disk)
  local chunk = (loadstring or load)(content, "analysis_cache", "t", {})
  if not chunk then return {} end
  local ok, data = pcall(chunk)
  if not ok or type(data) ~= "table" or data.version ~= 1 then return {} end
  local entries = data.entries or {}
  -- `m` is the packed measurement string (see rk_lua_sample_analysis.pack).
  -- Kept as an opaque string here and unpacked lazily by get_metrics(), so
  -- loading a 20k-file cache costs no parsing for samples never looked at.
  -- Caches written before measured analysis existed simply carry no `m`; those
  -- entries get queued for an in-place upgrade by analyze_file(). Version stays
  -- 1 on purpose — the field is additive, and an older build ignores it.
  for _, e in pairs(entries) do
    if type(e) == "table" and e.m then
      e.packed, e.m = e.m, nil
    end
  end
  return entries
end

local function save_persistent_cache(force)
  if not cache_dirty then return end
  -- Debounce 1s during normal operation. `force` overrides — used at
  -- shutdown so up to 1s of fresh BPM/key analysis isn't lost.
  -- `now` must be at function scope so the cache_last_save = now write
  -- at the bottom can see it on both branches (force and non-force).
  local now = reaper.time_precise()
  if not force and now - cache_last_save < 1.0 then return end

  local cache_path = core.get_cache_dir() .. sep .. "analysis.lua"
  local tmp_path = cache_path .. ".tmp"
  local f = io.open(tmp_path, "w")
  if not f then return end

  f:write("return {\n  version = 1,\n  entries = {\n")
  for path, entry in pairs(analysis_cache) do
    -- Re-pack live metrics; entries loaded from disk and never re-measured
    -- still hold their original packed string and are written straight back.
    local packed = entry.packed
    if not packed and entry.metrics then packed = measure.pack(entry.metrics) end
    -- Only persist entries we actually have data for (skip in-flight queue
    -- placeholders). Measurements count as data on their own: a drum one-shot
    -- routinely has neither BPM nor key, and gating on those would throw away
    -- every measurement for exactly the content this browser is built for.
    if entry.analyzed and (entry.bpm or entry.key or packed or entry.root) then
      f:write("    [" .. core.lua_quote(path) .. "] = { ")
      -- mtime is a string from JS_File_Stat (not epoch number) — quote it.
      f:write("mtime = ", core.lua_quote(tostring(entry.mtime or "")), ", ")
      if entry.bpm then f:write("bpm = ", tostring(entry.bpm), ", ") end
      if entry.key then f:write("key = ", core.lua_quote(entry.key), ", ") end
      if packed then f:write("m = ", core.lua_quote(packed), ", ") end
      -- Additive like `m`; version stays 1 and an older build just ignores it.
      if entry.root then f:write("root = ", tostring(entry.root), ", ") end
      f:write("source = ", core.lua_quote(entry.source or "dsp"), " },\n")
    end
  end
  f:write("  },\n}\n")
  f:close()

  -- Atomic rename. Windows os.rename fails if target exists, so remove first.
  -- Brief window between remove+rename where cache is missing — acceptable
  -- because load_persistent_cache treats missing as empty and we'll rebuild.
  os.remove(cache_path)
  os.rename(tmp_path, cache_path)
  cache_dirty = false
  cache_last_save = now
end

analysis_cache = load_persistent_cache()

-- ═══════════════════════════════════════════════════════════════════════════════
-- HELPERS (aliases defined above from core module)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════════════════════
-- BPM + KEY DETECTION
-- ═══════════════════════════════════════════════════════════════════════════════

-- Analysis cache: path → {bpm=number|nil, key=string|nil, analyzed=bool}
-- (forward-declared above so on_kit_name_change can clear it)

-- Note names for key display
local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

-- Krumhansl-Schmuckler key profiles
local MAJOR_PROFILE = {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88}
local MINOR_PROFILE = {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17}

local function correlate_profile(chroma, profile, shift)
  -- Pearson correlation between chroma (rotated by shift) and profile
  local n = 12
  local sum_x, sum_y, sum_xy, sum_x2, sum_y2 = 0, 0, 0, 0, 0
  for i = 0, n - 1 do
    local x = chroma[((i + shift) % n) + 1]
    local y = profile[i + 1]
    sum_x = sum_x + x
    sum_y = sum_y + y
    sum_xy = sum_xy + x * y
    sum_x2 = sum_x2 + x * x
    sum_y2 = sum_y2 + y * y
  end
  local num = n * sum_xy - sum_x * sum_y
  local den = math.sqrt((n * sum_x2 - sum_x * sum_x) * (n * sum_y2 - sum_y * sum_y))
  if den < 1e-10 then return 0 end
  return num / den
end

local function detect_key(filepath)
  -- Key detection using Goertzel on high-res peak data + Krumhansl-Schmuckler
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return nil end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  if sr <= 0 or length <= 0.1 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  -- Use high-res peaks as proxy for waveform (mono, up to 8kHz)
  local pps = math.min(sr, 8000)
  local read_len = math.min(length, 4.0)
  local num_peaks = math.floor(read_len * pps)
  if num_peaks < 512 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  local buf = reaper.new_array(num_peaks * 2) -- mono: min+max
  buf.clear()
  local got = reaper.PCM_Source_GetPeaks(src, pps, 0, 1, num_peaks, 0, buf)
  reaper.PCM_Source_Destroy(src)

  local peak_count = math.min(got & 0xFFFFF, num_peaks)
  if peak_count < 512 then return nil end

  -- Extract max peaks (layout: [max0..max_n, min0..min_n])
  local samples = {}
  for i = 0, peak_count - 1 do
    samples[#samples + 1] = buf[i + 1] -- max values in first half
  end

  -- Build chromagram using Goertzel
  local chroma = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
  local fft_size = math.min(4096, #samples)
  local hop = math.floor(fft_size / 2)

  local block_start = 0
  local num_blocks = 0
  while block_start + fft_size <= #samples do
    for note = 0, 11 do
      for oct = 2, 5 do
        local midi = note + (oct + 1) * 12
        local freq = 440.0 * 2 ^ ((midi - 69) / 12)
        if freq < pps / 2 then
          local k = freq / pps * fft_size
          local w = 2 * math.pi * k / fft_size
          local coeff = 2 * math.cos(w)
          local s0, s1, s2 = 0, 0, 0
          for i = 1, fft_size do
            s0 = (samples[block_start + i] or 0) + coeff * s1 - s2
            s2 = s1
            s1 = s0
          end
          local power = s1 * s1 + s2 * s2 - coeff * s1 * s2
          chroma[note + 1] = chroma[note + 1] + math.abs(power)
        end
      end
    end
    block_start = block_start + hop
    num_blocks = num_blocks + 1
  end

  if num_blocks == 0 then return nil end
  for i = 1, 12 do chroma[i] = chroma[i] / num_blocks end

  local best_r = -2
  local best_key = "C"
  for shift = 0, 11 do
    local r_maj = correlate_profile(chroma, MAJOR_PROFILE, shift)
    if r_maj > best_r then best_r = r_maj; best_key = NOTE_NAMES[shift + 1] end
    local r_min = correlate_profile(chroma, MINOR_PROFILE, shift)
    if r_min > best_r then best_r = r_min; best_key = NOTE_NAMES[shift + 1] .. "m" end
  end

  if best_r < 0.3 then return nil end
  return best_key
end

-- Read embedded BPM/key tags from a file. Returns {bpm=number|nil, key=string|nil}
-- or nil if the file can't be opened. ~1ms per call vs ~50ms for DSP analysis.
-- Tag-priority order covers XMP, ID3v2, Vorbis, RIFF/BWF, ACID, and bare keys —
-- every major sample-library export format (Splice, Loopcloud, DAW exports).
local function read_tags(filepath)
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return nil end

  local function first(keys)
    for _, k in ipairs(keys) do
      local rv, v = reaper.GetMediaFileMetadata(src, k)
      if rv and v and v ~= "" then return v end
    end
    return nil
  end

  local bpm_str = first{
    "XMP:dm/tempo", "ID3:TBPM", "VORBIS:BPM",
    "RIFF:ACID:tempo", "ACID:tempo", "tempo", "BPM"
  }
  local key_str = first{
    "XMP:dm/key", "ID3:TKEY", "VORBIS:KEY",
    "RIFF:IKEY", "RIFF:ACID:key", "key", "KEY"
  }

  reaper.PCM_Source_Destroy(src)

  local bpm = tonumber(bpm_str)
  -- Sanity-clamp BPM to musical range (rejects 0, negatives, and absurd values
  -- from corrupted or non-musical tags)
  if bpm and (bpm < 30 or bpm > 300) then bpm = nil end

  return { bpm = bpm, key = key_str }
end

local function detect_bpm(filepath)
  -- BPM detection using peak envelope autocorrelation
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return nil end

  local sr = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  if sr <= 0 or length < 0.5 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  -- Get 200 peaks/sec envelope
  local env_sr = 200
  local read_len = math.min(length, 8.0)
  local num_peaks = math.floor(read_len * env_sr)
  if num_peaks < 100 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  local buf = reaper.new_array(num_peaks * 2) -- mono min+max
  buf.clear()
  local got = reaper.PCM_Source_GetPeaks(src, env_sr, 0, 1, num_peaks, 0, buf)
  reaper.PCM_Source_Destroy(src)

  local peak_count = math.min(got & 0xFFFFF, num_peaks)
  if peak_count < 100 then return nil end

  -- Extract max peaks (layout: [max0..max_n, min0..min_n])
  local peaks = {}
  for i = 0, peak_count - 1 do
    peaks[#peaks + 1] = math.abs(buf[i + 1])
  end

  -- Onset detection: first difference, half-wave rectify
  local onset = {}
  for i = 2, #peaks do
    local d = peaks[i] - peaks[i - 1]
    onset[i - 1] = d > 0 and d or 0
  end

  if #onset < 100 then return nil end

  -- Autocorrelation for BPM range 60-200
  local min_lag = math.floor(env_sr * 60 / 200)
  local max_lag = math.floor(env_sr * 60 / 60)
  if max_lag > #onset - 1 then max_lag = #onset - 1 end

  local best_lag = min_lag
  local best_corr = -1
  for lag = min_lag, max_lag do
    local corr = 0
    local count = math.min(#onset - lag, 400)
    for i = 1, count do
      corr = corr + onset[i] * onset[i + lag]
    end
    if corr > best_corr then
      best_corr = corr
      best_lag = lag
    end
  end

  local bpm = env_sr * 60.0 / best_lag
  if bpm < 60 or bpm > 200 then return nil end

  -- Check half-time
  local half_lag = best_lag * 2
  if half_lag <= max_lag then
    local corr_half = 0
    local count = math.min(#onset - half_lag, 400)
    for i = 1, count do
      corr_half = corr_half + onset[i] * onset[i + half_lag]
    end
    if corr_half > best_corr * 0.9 then
      bpm = bpm / 2
    end
  end

  if bpm < 60 or bpm > 200 then return nil end
  return math.floor(bpm + 0.5)
end

-- Metadata queue for deferred file size + duration (keeps scan instant)
local metadata_queue = {}
local METADATA_PER_FRAME = 4  -- files to process per frame
local SCAN_FILES_PER_FRAME = 200  -- directory entries to enumerate per frame

local function process_metadata_queue()
  local count = 0
  while count < METADATA_PER_FRAME and #metadata_queue > 0 do
    local e = table.remove(metadata_queue, 1)
    -- File size
    if e.size == -1 then
      local fh = io.open(e.path, "rb")
      if fh then
        e.size = fh:seek("end") or -1
        fh:close()
      end
    end
    -- Duration + channel count for native audio (single source open covers
    -- both — channel count drives the M/S column and the stereo waveform
    -- preview).
    if e.duration == -1 and NATIVE_EXT[e.ext] then
      local src = reaper.PCM_Source_CreateFromFileEx(e.path, true)
      if src then
        e.duration = reaper.GetMediaSourceLength(src)
        e.nch      = reaper.GetMediaSourceNumChannels(src)
        reaper.PCM_Source_Destroy(src)
      end
    end
    count = count + 1
  end
end

-- Analysis queue for incremental per-frame processing
-- (forward-declared above so on_kit_name_change can clear it)
local ANALYSIS_BUDGET_S = 0.008  -- §12.1: 8ms max per frame for analysis work

-- Does this REAPER build have the API the measurement core needs
-- (PCM_Source_CreateFromFile / PCM_Source_GetPeaks / new_array)? Resolved once:
-- when false, the browser behaves exactly as it did before measured analysis
-- existed, and no entry is ever queued for a metrics upgrade.
local measure_ready = measure.available()

local function analyze_file(filepath)
  if not filepath then return end

  -- Layer 1: persistent cache hit (in-memory, populated from disk on launch).
  -- JS_File_Stat returns mtime as a date-formatted STRING (not epoch number),
  -- so compare with string equality. nil mtime (no js_ReaScriptAPI) → trust
  -- the cache and skip re-analysis.
  local cached = analysis_cache[filepath]
  if cached and cached.analyzed then
    local mtime = get_file_mtime(filepath)
    if not mtime or not cached.mtime or mtime == cached.mtime then
      -- Cache valid for BPM/key. But entries written before measured analysis
      -- existed — and every entry the tag/kit_db layers below produce, which
      -- cannot yield measurements — carry none. Queue those for an in-place
      -- upgrade instead of falling through: re-running the cheap layers would
      -- rewrite the same metric-less entry forever and never make progress.
      -- `== nil` deliberately, not `not`: a failed measurement is stored as
      -- `false` and must NOT be retried on every enumeration.
      if measure_ready and cached.metrics == nil and not cached.packed
        and not cached.queued then
        cached.queued = true
        analysis_queue[#analysis_queue + 1] = filepath
      end
      return
    end
    -- mtime drifted — file was modified, fall through and re-analyze
  end

  -- Layer 2: embedded-tag short-circuit (Splice/Loopcloud/DAW exports)
  local tags = read_tags(filepath)
  if tags and (tags.bpm or tags.key) then
    analysis_cache[filepath] = {
      mtime = get_file_mtime(filepath) or "",
      bpm = tags.bpm,
      key = tags.key,
      source = "tag",
      analyzed = true,
    }
    cache_dirty = true
    return
  end

  -- Layer 3: legacy per-kit cache (BPM/key data baked into .swing files)
  local kit_cached = lookup_cache(filepath)
  if kit_cached then
    analysis_cache[filepath] = {
      mtime = get_file_mtime(filepath) or "",
      bpm = kit_cached.bpm,
      key = kit_cached.key,
      source = "kit_db",
      analyzed = true,
    }
    cache_dirty = true
    return
  end

  -- Layer 4: queue for full DSP analysis
  analysis_cache[filepath] = { bpm = nil, key = nil, analyzed = false, status = "..." }
  table.insert(analysis_queue, filepath)
end

-- Root note for the Root column. Returns a MIDI note number, or `false` when
-- the file has none — `false` rather than nil so an unpitched or unreadable
-- file is not re-queued on every enumeration (same convention as `metrics`).
--
-- Only notes that clear the detector's own confidence gate come back: an
-- unpitched source (hat, clap, most snares) legitimately has no root note, and
-- a wrong one would mislead anyone tuning to it.
local function detect_root_note(filepath)
  local ok, r = pcall(rootnote.detect_file, filepath)
  if not ok or type(r) ~= "table" or not r.show or not r.note then return false end
  return r.note
end

local function run_analysis(filepath)
  local entry = analysis_cache[filepath]
  if not entry then return end
  entry.queued = nil
  if entry.analyzed then
    -- Upgrade pass: BPM/key already cached, only the measurements are missing.
    -- `false` (not nil) is stored on failure so an unreadable file is not
    -- re-queued on every enumeration.
    if entry.metrics == nil and not entry.packed then
      entry.metrics = measure.measure(filepath) or false
      cache_dirty = true
    end
    -- Same additive-upgrade treatment for the root note: caches written before
    -- it existed carry no `root`, and would otherwise never acquire one because
    -- `analyzed` short-circuits this whole function.
    if entry.root == nil then
      entry.root = detect_root_note(filepath)
      cache_dirty = true
    end
    return
  end
  entry.bpm = detect_bpm(filepath)
  entry.key = detect_key(filepath)
  entry.root = detect_root_note(filepath)
  -- Measured character (attack / decay / spectrum / width). Independent of
  -- BPM+key: a file can have one and not the other. Stored as `false` on
  -- failure rather than nil, so an unreadable file is not re-queued on every
  -- enumeration.
  entry.metrics = measure.measure(filepath) or false
  entry.analyzed = true
  entry.status = nil
  entry.mtime = get_file_mtime(filepath) or ""
  entry.source = "dsp"
  cache_dirty = true
  -- Write to kit_db cache for per-kit persistence too (legacy path).
  -- kit_db is the v2 .swing schema and stays BPM/key only — metrics live in
  -- the persistent analysis cache, which is not shipped inside kit files.
  update_cache(filepath, entry.bpm, entry.key)
end

-- Metrics for a path, unpacking the cached form on first access. Entries loaded
-- from disk carry `packed` (a flat string); live ones already hold `metrics`.
local function get_metrics(filepath)
  local entry = analysis_cache[filepath]
  if not entry then return nil end
  if entry.metrics == nil and entry.packed then
    entry.metrics = measure.unpack(entry.packed) or false
  end
  return entry.metrics or nil
end

-- Derived axes + labels for a path. Cheap and pure — safe to call per frame.
local function get_axes(filepath)
  local m = get_metrics(filepath)
  if not m then return nil end
  return measure.derive(m)
end

-- Process queued analysis (call once per frame)
local function process_analysis_queue()
  local budget_start = reaper.time_precise()
  while #analysis_queue > 0 do
    local path = table.remove(analysis_queue, 1)
    -- run_analysis self-guards: it handles both the full first pass and the
    -- metrics-only upgrade of an entry that is already marked analyzed.
    run_analysis(path)
    -- §12.1: respect frame budget — bail before we block the UI thread
    if reaper.time_precise() - budget_start > ANALYSIS_BUDGET_S then break end
  end
end

local function get_analysis(filepath)
  return analysis_cache[filepath]
end

-- Incremental file enumeration: process N entries per frame to avoid UI stalls
-- Subfolders-mode safety caps. 20000 files covers big commercial sample
-- libraries (Splice/Loopcloud/Kontakt exports); 8 levels prevents accidental
-- infinite recursion through symlinked folders. Memory cost ~6MB at the cap;
-- category-count tick stays well under 16ms per frame at this size.
local SUBFOLDERS_MAX_FILES = 20000
local SUBFOLDERS_MAX_DEPTH = 8

local function process_scan_queue()
  local st = file_mgr.scan_state
  if not st then return end
  local count = 0
  while count < SCAN_FILES_PER_FRAME do
    local fname = reaper.EnumerateFiles(st.path, st.file_idx)
    if not fname then
      -- Files in this directory exhausted. In subfolders mode, also
      -- enumerate subdirectories and queue them for BFS walking.
      if st.recurse and st.depth < SUBFOLDERS_MAX_DEPTH then
        local di = 0
        while true do
          local sub = reaper.EnumerateSubdirectories(st.path, di)
          if not sub then break end
          if sub:sub(1, 1) ~= "." then  -- skip hidden / dotfolders
            st.queue[#st.queue + 1] = {
              path  = st.path .. sep .. sub,
              depth = st.depth + 1,
            }
          end
          di = di + 1
        end
      end
      -- Pop next directory from BFS queue, or finish if empty
      local next_dir = table.remove(st.queue, 1)
      if not next_dir or st.total_files >= SUBFOLDERS_MAX_FILES then
        sort_entries()
        file_mgr.current_path = st.root  -- always the root, not the deepest scanned dir
        file_mgr.needs_rescan = false
        analysis_queue = {}
        for _, e in ipairs(file_mgr.entries) do
          if not e.is_dir and is_native_audio(e.name) then
            analyze_file(e.path)
          end
        end
        file_mgr.scan_state = nil
        return
      end
      st.path     = next_dir.path
      st.depth    = next_dir.depth
      st.file_idx = 0
      -- IMPORTANT: skip the file_idx + count increments at the bottom of
      -- this iteration. Otherwise we'd advance past index 0 of the new
      -- directory, missing its first audio file (the BFS off-by-one bug
      -- that previously dropped the first sample of every nested folder).
      goto continue_scan
    elseif is_audio_file(fname) then
      local full_path = st.path .. sep .. fname
      local ext = get_extension(fname)
      -- Relative subfolder path (for display in subfolders mode). Strips
      -- the root prefix and any leading separator. Empty when this file
      -- is at the scan root itself (immediate folder).
      local subfolder = ""
      if st.recurse and st.path ~= st.root then
        subfolder = st.path:sub(#st.root + 1)
        if subfolder:sub(1, 1) == sep then
          subfolder = subfolder:sub(2)
        end
      end
      -- Categorize from filename + the file's actual folder path. Pure
      -- string ops, fast.
      local entry = {
        name      = fname,
        path      = full_path,
        is_dir    = false,
        size      = -1,
        ext       = ext,
        duration  = -1,
        nch       = -1,
        subfolder = subfolder,  -- "" when not in recurse mode or at root
        category  = categorizer.classify(fname, st.path),
      }
      table.insert(file_mgr.entries, entry)
      st.total_files = st.total_files + 1
      table.insert(metadata_queue, entry)
    end
    st.file_idx = st.file_idx + 1
    count = count + 1
    ::continue_scan::
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- SFZ READER (Item 25)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Convert SFZ note name (e.g., "c#3", "D4") to MIDI number
local function note_name_to_midi(name)
  if not name or name == "" then return nil end
  local n = tonumber(name)
  if n then return n end -- already a number

  name = name:lower()
  local note_vals = {c=0, d=2, e=4, f=5, g=7, a=9, b=11}
  local note_char = name:sub(1, 1)
  local base = note_vals[note_char]
  if not base then return nil end

  local offset = 1
  local sharp = name:sub(2, 2)
  if sharp == "#" then base = base + 1; offset = 2
  elseif sharp == "b" then base = base - 1; offset = 2
  end

  local octave = tonumber(name:sub(offset + 1))
  if not octave then return nil end
  return (octave + 1) * 12 + base
end

-- Parse an SFZ file and return a list of regions with sample paths + metadata
local function parse_sfz(sfz_path)
  local f = io.open(sfz_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()

  local sfz_dir = sfz_path:match("^(.*)[/\\]") or ""
  local regions = {}
  local current_group = {}  -- inherited <group> opcodes
  local current_region = nil

  for line in content:gmatch("[^\r\n]+") do
    -- Strip comments
    line = line:gsub("//.*$", ""):match("^%s*(.-)%s*$")
    if line == "" then goto continue end

    -- Check for headers
    local header = line:match("^<(%w+)>")
    if header then
      -- Save previous region
      if current_region and current_region.sample then
        table.insert(regions, current_region)
      end

      if header == "group" then
        current_group = {}
        current_region = nil
      elseif header == "region" then
        -- New region inherits group opcodes
        current_region = {}
        for k, v in pairs(current_group) do
          current_region[k] = v
        end
      else
        current_region = nil
      end
      -- Parse remaining opcodes on the same line after header
      line = line:gsub("^<%w+>%s*", "")
    end

    -- Resolve the opcode target for this line.
    local target = current_region or (header == "group" and current_group or nil)

    -- sample= is special: SFZ sample paths routinely contain spaces, so per the
    -- SFZ spec its value runs to end-of-line (or until the next " opcode=" token).
    -- Handle it BEFORE the generic whitespace-split parser below, which would
    -- otherwise truncate the path at the first space (e.g. a path ending in
    -- "TR 808 Kick 03.wav" would be read as just "...\TR" and fail to load).
    if target then
      local sb = line:lower():find("sample%s*=")
      if sb then
        local veq = line:find("=", sb)
        local rest = line:sub(veq + 1)
        local nxt = rest:find("%s+%a[%w_]*%s*=")  -- start of the next opcode, if any
        local sval
        if nxt then
          sval = rest:sub(1, nxt - 1)
          line = line:sub(1, sb - 1) .. " " .. rest:sub(nxt)  -- keep trailing opcodes for the loop
        else
          sval = rest
          line = line:sub(1, sb - 1)
        end
        sval = sval:gsub("^%s*(.-)%s*$", "%1")  -- trim
        if sval ~= "" then
          sval = sval:gsub("\\", sep)
          if not sval:match("^[/\\]") and not sval:match("^%a:") then
            sval = sfz_dir .. sep .. sval
          end
          target.sample = sval
        end
      end
    end

    -- Parse the remaining (whitespace-delimited) key=value opcodes.
    for key, val in line:gmatch("(%w+)=([^%s]+)") do
      if target then
        key = key:lower()
        if key == "lokey" then
          target.lokey = tonumber(val) or note_name_to_midi(val)
        elseif key == "hikey" then
          target.hikey = tonumber(val) or note_name_to_midi(val)
        elseif key == "pitch_keycenter" or key == "key" then
          target.pitch_keycenter = tonumber(val) or note_name_to_midi(val)
        elseif key == "lovel" then
          target.lovel = tonumber(val) or 0
        elseif key == "hivel" then
          target.hivel = tonumber(val) or 127
        elseif key == "tune" then
          target.tune = tonumber(val) or 0
        elseif key == "volume" then
          target.volume = tonumber(val) or 0
        elseif key == "pan" then
          target.pan = tonumber(val) or 0
        end
      end
    end

    ::continue::
  end

  -- Don't forget last region
  if current_region and current_region.sample then
    table.insert(regions, current_region)
  end

  return regions
end

-- Map SFZ regions to 16 pads by pitch zone
local function sfz_regions_to_pads(regions)
  if not regions or #regions == 0 then return {} end

  -- Sort regions by pitch_keycenter (or lokey)
  table.sort(regions, function(a, b)
    local ka = a.pitch_keycenter or a.lokey or 60
    local kb = b.pitch_keycenter or b.lokey or 60
    return ka < kb
  end)

  -- Take up to 16 regions (one per pad), picking highest velocity layer
  local pads = {}
  if #regions <= 16 then
    -- Direct mapping
    for i, r in ipairs(regions) do
      pads[i] = {
        path = r.sample,
        note = r.pitch_keycenter or r.lokey or (35 + i),
        tune = (r.tune or 0) / 100, -- cents → semitones
        volume = r.volume or 0,
        pan = (r.pan or 0) / 100, -- -100..100 → -1..1
      }
    end
  else
    -- More than 16: spread evenly across regions
    local step = #regions / 16
    for p = 1, 16 do
      local idx = math.floor((p - 0.5) * step) + 1
      idx = math.min(idx, #regions)
      local r = regions[idx]
      pads[p] = {
        path = r.sample,
        note = r.pitch_keycenter or r.lokey or (35 + p),
        tune = (r.tune or 0) / 100,
        volume = r.volume or 0,
        pan = (r.pan or 0) / 100,
      }
    end
  end

  return pads
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- IMPORT SYSTEM
-- ═══════════════════════════════════════════════════════════════════════════════

-- Auto-map drum type assignment (spec section 7.10)
local AUTO_MAP_TYPES = {
  "kick", "808", "snare", "clap",
  "open hh", "closed hh", "ride",
  "rim", "tom 1", "tom 2", "tom 3",
  "perc 1", "perc 2", "perc 3", "perc 4", "fx"
}

local import_state = {
  active    = false,   -- is import dialog open
  mode      = 1,       -- 1=auto-map, 2=sequential, 3=pad picker
  source    = "",      -- source file path
  pads      = {},      -- parsed pad assignments from SFZ/conversion (raw regions)
  mapping   = {},      -- [pad_1indexed] = index into pads (current assignment)
  error     = nil,     -- error message string
}

-- Auto-map keyword patterns: match filename → drum type → pad index
local AUTO_MAP_KEYWORDS = {
  { pad = 1,  keywords = {"kick", "bd", "bass_drum", "bassdrum", "bass drum"} },
  { pad = 2,  keywords = {"808", "sub"} },
  { pad = 3,  keywords = {"snare", "sn", "sd"} },
  { pad = 4,  keywords = {"clap", "cp", "handclap"} },
  -- Hat rows mirror the 2026-07-27 canonical rule (eon_filename_categorizer):
  -- ROW ORDER is the guarantee — pad 5 scans before pad 6, so every open name
  -- wins regardless of keyword position within a row (keyword order inside a
  -- row is cosmetic). Generic hi-hat names (hihat/hh/hi hat/high hat) -> pad 6
  -- CLOSED; bare "hat" on pad 6 so Hat/Hats stop sequential-filling onto
  -- arbitrary pads (never the open pad — row 5 already consumed open names).
  { pad = 5,  keywords = {"open_hh", "open hh", "openhh", "oh", "open_hat", "open hat", "ohat", "open"} },
  { pad = 6,  keywords = {"closed_hh", "closed hh", "closedhh", "ch", "closed_hat", "closed hat", "chat", "hihat", "hh", "hi_hat", "hi hat", "high_hat", "high hat", "highhat", "hat"} },
  { pad = 7,  keywords = {"ride", "crash", "cymbal", "cy"} },
  { pad = 8,  keywords = {"rim", "rimshot", "rs", "stick"} },
  { pad = 9,  keywords = {"tom1", "tom_1", "tom 1", "hi_tom", "hitom", "high_tom"} },
  { pad = 10, keywords = {"tom2", "tom_2", "tom 2", "mid_tom", "midtom"} },
  { pad = 11, keywords = {"tom3", "tom_3", "tom 3", "lo_tom", "lotom", "low_tom", "floor_tom"} },
  { pad = 12, keywords = {"perc1", "perc_1", "perc 1", "shaker", "tambourine", "tamb"} },
  { pad = 13, keywords = {"perc2", "perc_2", "perc 2", "conga", "bongo"} },
  { pad = 14, keywords = {"perc3", "perc_3", "perc 3", "cowbell", "bell", "triangle"} },
  { pad = 15, keywords = {"perc4", "perc_4", "perc 4", "woodblock", "clave", "block"} },
  { pad = 16, keywords = {"fx", "effect", "noise", "sweep", "riser", "impact"} },
}

-- Try to auto-detect drum type from sample filename
local function auto_map_detect(filepath)
  local fname = (filepath:match("[/\\]([^/\\]+)$") or filepath):lower()
  fname = fname:match("(.*)%.[^%.]+$") or fname  -- strip extension

  for _, map in ipairs(AUTO_MAP_KEYWORDS) do
    for _, kw in ipairs(map.keywords) do
      if fname:find(kw, 1, true) then
        return map.pad
      end
    end
  end
  return nil
end

-- Build mapping table based on current mode
local function build_import_mapping()
  import_state.mapping = {}
  local pads = import_state.pads
  if #pads == 0 then return end

  if import_state.mode == 1 then
    -- Auto-map: match filenames to drum types
    local used = {}
    local unmapped = {}

    for i, pad in ipairs(pads) do
      local target = auto_map_detect(pad.path)
      if target and not used[target] then
        import_state.mapping[target] = i
        used[target] = true
      else
        table.insert(unmapped, i)
      end
    end

    -- Fill remaining unmapped regions into empty pad slots
    local ui_idx = 1
    for p = 1, 16 do
      if not import_state.mapping[p] and ui_idx <= #unmapped then
        import_state.mapping[p] = unmapped[ui_idx]
        ui_idx = ui_idx + 1
      end
    end

  elseif import_state.mode == 2 then
    -- Sequential: fill pads 1-16 in source order
    for i = 1, math.min(#pads, 16) do
      import_state.mapping[i] = i
    end

  elseif import_state.mode == 3 then
    -- Pad picker: start with sequential, user can reassign
    for i = 1, math.min(#pads, 16) do
      import_state.mapping[i] = i
    end
  end
end

local function import_start(filepath)
  local ext = get_extension(filepath)

  local pads = {}
  local err = nil

  if ext == "sfz" then
    local regions = parse_sfz(filepath)
    if regions and #regions > 0 then
      pads = sfz_regions_to_pads(regions)
    else
      err = "No regions found in SFZ file"
    end
  else
    err = "Unsupported format: ." .. ext .. " (Swing imports .sfz only)"
  end

  if #pads == 0 and not err then err = "No samples found" end

  import_state.active = true
  import_state.source = filepath
  import_state.pads = pads
  import_state.error = err
  import_state.mode = 1
  build_import_mapping()
  return #pads > 0
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- RS5k → KIT IMPORT
-- ═══════════════════════════════════════════════════════════════════════════════
-- Read every ReaSamplOmatic5000 instance reachable from a track (its own FX
-- chain, plus child tracks if it's a folder parent — the common multi-out
-- drum-rack layout) and turn each into a Swing pad descriptor with the SAME
-- shape sfz_regions_to_pads emits, so it flows through the identical import
-- dialog + load queue. Triggered by the EON_SB_ImportRS5k companion action,
-- which writes the source track number to ExtState for frame() to pick up.

-- These helpers live on ONE table, not separate top-level locals — Swing_Browser
-- also runs close to Lua's 200-local main-chunk ceiling, so each bare
-- `local function` is a scarce slot. (MAX_IMPORT_LAYERS stays a plain local; the
-- table methods capture it as an upvalue.)
local rk_rs5k = {}

-- RS5k exposes no "is this me?" API, so fingerprint param 3's NAME (the rs5k_io
-- convention — cheap and reliable).
function rk_rs5k.is_rs5k_fx(track, fx)
  local ok, pname = reaper.TrackFX_GetParamName(track, fx, 3)
  return ok and pname == "Note range start"
end

-- One RS5k instance → a "voice" (nil if it has no sample loaded). A voice reads
-- ALL its files (FILE0..n — RS5k spreads multiple files across velocity, or
-- round-robins them when param 20 is on) plus its velocity zone (17/18), so the
-- grouping pass below can turn them into Swing pad LAYERS instead of dropping
-- everything but FILE0.
local MAX_IMPORT_LAYERS = 4  -- mirrors Swing's MAX_LAYERS

function rk_rs5k.rs5k_fx_to_voice(track, fx)
  local files = {}
  local i = 0
  while true do
    local ok, p = reaper.TrackFX_GetNamedConfigParm(track, fx, "FILE" .. i)
    if not ok or p == "" then break end
    files[#files + 1] = p
    i = i + 1
    if i > 64 then break end  -- sanity guard
  end
  if #files == 0 then return nil end  -- empty instance, skip

  -- note: param 3 (note range start) normalizes a MIDI note over 0..127.
  local note = math.floor(reaper.TrackFX_GetParam(track, fx, 3) * 127 + 0.5)
  -- tune: param 15 "Pitch adjust" is RS5k's actual semitone tune (default 0).
  -- Read the FORMATTED value so we get exact semitones without modeling the
  -- curve. ⚠️do NOT use param 5 "Pitch for start note" — that's keyboard-
  -- tracking pitch and DEFAULTS to -24, which pitched every import down 2 oct.
  local tune = 0
  local okt, dispt = reaper.TrackFX_GetFormattedParamValue(track, fx, 15)
  if okt then
    local n = tonumber(dispt:match("[%-%+]?%d+%.?%d*"))
    if n then tune = n end
  end
  -- pan: param 1 normalizes 0..1 (full-left..full-right) → Swing's -1..1.
  local pan  = reaper.TrackFX_GetParam(track, fx, 1) * 2 - 1
  -- round-robin: param 20 (round-robin mode) > 0 means the files cycle; else
  -- RS5k spreads them across velocity.
  local rr = (reaper.TrackFX_GetParam(track, fx, 20) or 0) > 0.5
  -- velocity zone: params 17/18 normalize 0..127 (used to detect same-note
  -- instances that form a velocity stack vs. unrelated drums on a shared note).
  local lovel = math.floor((reaper.TrackFX_GetParam(track, fx, 17) or 0) * 127 + 0.5)
  local hivel = math.floor((reaper.TrackFX_GetParam(track, fx, 18) or 1) * 127 + 0.5)
  -- volume: read the FORMATTED display ("+0.0 dB") so we don't have to model
  -- RS5k's norm→dB curve. The import queue re-applies it as 10^(dB/20), so we
  -- hand back dB exactly like the SFZ path does (-inf / unparsable → 0 dB).
  local volume = 0
  local okf, disp = reaper.TrackFX_GetFormattedParamValue(track, fx, 0)
  if okf then
    local n = tonumber(disp:match("[%-%+]?%d+%.?%d*"))
    if n then volume = n end
  end

  return { files = files, note = note, tune = tune, volume = volume,
           pan = pan, rr = rr, lovel = lovel, hivel = hivel }
end

-- A voice (1+ files) → one pad descriptor; layers beyond the first ride in via
-- the import queue's CMD-64 path. A SINGLE instance with multiple files always
-- velocity-splits them (RS5k has no single-instance round-robin — verified), so
-- multi-file → mode 1 (vel-split) regardless of the instance's RR toggle. RR is
-- only inferred across same-note instance GROUPS (the grouping pass below).
function rk_rs5k.rs5k_voice_to_pad(v)
  local layers = {}
  for _, f in ipairs(v.files) do
    if #layers < MAX_IMPORT_LAYERS then layers[#layers + 1] = f end
  end
  return {
    path = layers[1], note = v.note, tune = v.tune,
    volume = v.volume, pan = v.pan,
    layers = layers,
    layer_mode = (#layers > 1) and 1 or 0,
  }
end

-- If the FX at `cidx` is an FX Container, return the packed sub-FX indices of
-- its direct children, else nil. REAPER addresses a container's Nth child
-- (1-based) as 0x2000000 + N*(topcount+1) + (cidx+1), where topcount is the
-- track's top-level FX count. Computed addresses are VALIDATED downstream by
-- is_rs5k_fx (param-3 name), so a wrong index simply skips — never imports
-- garbage. One nesting level only (containers-in-containers aren't recursed).
function rk_rs5k.rs5k_container_children(tr, cidx, topcount)
  local ok, cnt = reaper.TrackFX_GetNamedConfigParm(tr, cidx, "container_count")
  if not ok then return nil end
  local n = tonumber(cnt)
  if not n or n <= 0 then return nil end
  local out = {}
  for child = 1, n do
    out[#out + 1] = 0x2000000 + child * (topcount + 1) + (cidx + 1)
  end
  return out
end

function rk_rs5k.read_rs5k_track(track)
  if not track then return {} end
  local voices = {}

  local function scan(tr)
    local fxn = reaper.TrackFX_GetCount(tr)
    for fx = 0, fxn - 1 do
      if rk_rs5k.is_rs5k_fx(tr, fx) then
        local v = rk_rs5k.rs5k_fx_to_voice(tr, fx)
        if v then voices[#voices + 1] = v end
      else
        -- Not RS5k itself — if it's a container, look inside for RS5k children.
        local kids = rk_rs5k.rs5k_container_children(tr, fx, fxn)
        if kids then
          for _, sub in ipairs(kids) do
            if rk_rs5k.is_rs5k_fx(tr, sub) then
              local v = rk_rs5k.rs5k_fx_to_voice(tr, sub)
              if v then voices[#voices + 1] = v end
            end
          end
        end
      end
    end
  end

  scan(track)

  -- Folder parent → also pull RS5k from the tracks it encloses (walk forward
  -- until the folder depth returns to 0). Covers the one-RS5k-per-child rack.
  if reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") == 1 then
    local total = reaper.CountTracks(0)
    -- IP_TRACKNUMBER is 1-based; the first child sits at 0-based index == it.
    local t = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
    local level = 1
    while t < total and level > 0 do
      local child = reaper.GetTrack(0, t)
      if not child then break end
      scan(child)
      level = level + reaper.GetMediaTrackInfo_Value(child, "I_FOLDERDEPTH")
      t = t + 1
    end
  end

  -- Turn voices into pads, merging velocity/RR layers:
  --   A) a voice with >1 file is already a (velocity) layer stack → its own pad.
  --   B) single-file voices that SHARE a note merge into one layered pad when
  --      they show velocity partitioning (restricted 17/18 → vel-split) OR are
  --      a round-robin group (any instance's RR toggle on → RR). RR is a
  --      MULTI-instance construct in RS5k, so this is where we detect it.
  --   C) anything else → one pad per voice (preserves 16-instances→16-pads;
  --      same-note full-range non-RR voices are separate drums, not layers).
  local pads = {}
  local singles_by_note, note_order = {}, {}
  for _, v in ipairs(voices) do
    if #v.files > 1 then
      pads[#pads + 1] = rk_rs5k.rs5k_voice_to_pad(v)   -- A
    else
      local k = v.note
      if not singles_by_note[k] then singles_by_note[k] = {}; note_order[#note_order + 1] = k end
      table.insert(singles_by_note[k], v)
    end
  end

  for _, k in ipairs(note_order) do
    local g = singles_by_note[k]
    local merge, any_rr = false, false
    if #g > 1 then
      local vel_part = false
      for _, v in ipairs(g) do
        if v.lovel > 0 or v.hivel < 127 then vel_part = true end
        if v.rr then any_rr = true end
      end
      merge = vel_part or any_rr
    end

    if merge then                                       -- B
      table.sort(g, function(a, b) return a.lovel < b.lovel end)
      local layers = {}
      for _, v in ipairs(g) do
        if #layers < MAX_IMPORT_LAYERS then layers[#layers + 1] = v.files[1] end
      end
      local base = g[1]
      pads[#pads + 1] = {
        path = layers[1], note = base.note, tune = base.tune,
        volume = base.volume, pan = base.pan, layers = layers,
        layer_mode = (#layers > 1) and (any_rr and 2 or 1) or 0,
      }
    else                                                -- C
      for _, v in ipairs(g) do pads[#pads + 1] = rk_rs5k.rs5k_voice_to_pad(v) end
    end
  end

  return pads
end

-- Open the import dialog populated from a track's RS5k rack (mirrors
-- import_start, but the source is a project track rather than an .sfz file).
function rk_rs5k.import_start_rs5k(track)
  local pads = rk_rs5k.read_rs5k_track(track)
  local err = nil
  if #pads == 0 then
    err = "No ReaSamplOmatic5000 instances found on the selected track"
  end

  local tname = "RS5k Track"
  if track then
    local _, nm = reaper.GetTrackName(track)
    if nm and nm ~= "" then tname = nm end
  end

  import_state.active = true
  import_state.source = tname
  import_state.pads   = pads
  import_state.error  = err
  import_state.mode   = 1
  build_import_mapping()
  return #pads > 0
end

-- Import load queue: loads one pad per frame to avoid CMD collision
local import_load_queue = {}

local function import_execute()
  -- Build a deferred load queue (one pad per frame to avoid CMD 63 collisions)
  import_load_queue = {}
  for pad_idx = 1, 16 do
    local src_idx = import_state.mapping[pad_idx]
    if src_idx then
      local pad = import_state.pads[src_idx]
      if pad then
        local target = pad_idx - 1 -- 0-indexed
        -- Carry the parsed metadata so process_import_queue can re-apply it
        -- after the audio loads (the CMD-63/64 load only transfers samples).
        -- `layers` (RS5k velocity/RR import) is nil for SFZ → single-sample path.
        table.insert(import_load_queue, {
          path = pad.path, pad = target,
          note = pad.note, tune = pad.tune,
          volume = pad.volume, pan = pad.pan,
          layers = pad.layers, layer_mode = pad.layer_mode,
        })
      end
    end
  end

  -- Keep temp_dir alive until queue is drained
  import_state.active = false
  import_state.error = nil
end

-- Process import load queue (call once per frame). Two phases per item: load
-- the audio, then — once CMD goes idle again — re-apply the parsed
-- tune/gain/pan/note (+ layer mode) via the target instance's INCMD mailbox.
-- Splitting the phases guarantees the metadata lands AFTER any param reset the
-- load does. Single-sample pads load via CMD 63; multi-LAYER pads (RS5k
-- velocity/RR import) load every layer via CMD 64 so all audio lives in the
-- l_len[] layer buffers consistently (one layer per idle frame, paced by CMD).
local function process_import_queue()
  if #import_load_queue == 0 then return end
  -- Only act when CMD is idle (load consumed, no in-flight command)
  if math.floor(reaper.gmem_read(G.CMD)) ~= 0 then return end

  local item = import_load_queue[1]
  if not item.loaded then
    if item.layers and #item.layers > 1 then
      local lc = item.lcur or 0
      if load_layer_to_pad(item.layers[lc + 1], item.pad, lc) then
        lc = lc + 1
        item.lcur = lc
        if lc >= #item.layers then item.loaded = true end
      end
    else
      if load_sample_to_pad(item.path, item.pad) then item.loaded = true end
    end
    return
  end

  -- Re-apply metadata. NOTE reuses its existing INCMD code (and locks the pad
  -- note); tune/gain/pan use the import-fidelity codes. 0 is a valid value for
  -- all three, so they post unconditionally. volume (dB) → linear gain. For
  -- layered pads, layer_mode sets vel-split / RR (auto even-split JSFX-side).
  local slot = core.resolve_inst_slot(active_inst_id)
  if slot then
    if item.note then
      core.post_pad_incmd(slot, G.INCMD_NOTE_OFF, item.pad, item.note, 2)
    end
    core.post_pad_incmd(slot, G.INCMD_TUNE_OFF, item.pad, item.tune or 0, 2)
    core.post_pad_incmd(slot, G.INCMD_GAIN_OFF, item.pad, 10 ^ ((item.volume or 0) / 20), 2)
    core.post_pad_incmd(slot, G.INCMD_PAN_OFF,  item.pad, item.pan or 0, 2)
    if item.layer_mode and item.layer_mode > 0 then
      core.post_pad_incmd(slot, G.INCMD_LMODE_OFF, item.pad, item.layer_mode, 2)
    end
  end
  table.remove(import_load_queue, 1)

  -- Cleanup when queue is done. temp_dir is always nil since the
  -- ConvertWithMoss removal (SFZ-only imports never extract anywhere) —
  -- the rmdir paths used to be a security concern (mixed quoting style)
  -- and dead-code maintenance burden, so they're gone.
  if #import_load_queue == 0 then
    import_state.pads = {}
    import_state.mapping = {}
  end
end

local function import_cancel()
  import_state.active = false
  import_state.pads = {}
  import_state.mapping = {}
  import_state.error = nil
  import_load_queue = {}
end

local function draw_import_dialog(ctx)
  if not import_state.active then return end

  local center_x, center_y = ImGui.GetWindowSize(ctx)
  ImGui.SetNextWindowPos(ctx, center_x * 0.15, center_y * 0.1, ImGui.Cond_Appearing)
  ImGui.SetNextWindowSize(ctx, 460, 420, ImGui.Cond_Appearing)

  local visible, open = ImGui.Begin(ctx, "Import Kit###import_dlg", true,
    ImGui.WindowFlags_NoCollapse)

  if not open then import_cancel() end

  if visible then
  if open then
    local fname = import_state.source:match("[/\\]([^/\\]+)$") or import_state.source
    local mode_changed = false

    -- Error state (parse failure, unsupported format, etc.)
    if import_state.error then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF6644FF)
      ImGui.TextWrapped(ctx, import_state.error)
      ImGui.PopStyleColor(ctx)
      ImGui.Spacing(ctx)
      if ImGui.Button(ctx, "Close", 80, 28) then
        import_cancel()
      end
    else
      -- Header
      ImGui.Text(ctx, "Source: " .. fname)
      ImGui.Text(ctx, "Samples found: " .. #import_state.pads)
      ImGui.Separator(ctx)

      -- Mode selector
      ImGui.Text(ctx, "Import Mode:")
      if ImGui.RadioButton(ctx, "Auto-Map (drum type)", import_state.mode == 1) then
        if import_state.mode ~= 1 then import_state.mode = 1; mode_changed = true end
      end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Match sample names to drum types\n(kick, snare, hat, etc.)")
      end
      ImGui.SameLine(ctx)
      if ImGui.RadioButton(ctx, "Sequential", import_state.mode == 2) then
        if import_state.mode ~= 2 then import_state.mode = 2; mode_changed = true end
      end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Fill pads 1-16 in source order")
      end
      ImGui.SameLine(ctx)
      if ImGui.RadioButton(ctx, "Pad Picker", import_state.mode == 3) then
        if import_state.mode ~= 3 then import_state.mode = 3; mode_changed = true end
      end
      if ImGui.IsItemHovered(ctx) then
        ImGui.SetTooltip(ctx, "Manually assign each source to a pad")
      end

      if mode_changed then build_import_mapping() end

      ImGui.Spacing(ctx)

      -- Preview: show mapping
      if import_state.mode == 3 then
        -- Pad picker: two-column layout (sources | pads)
        ImGui.Text(ctx, "Drag source # to reassign pads:")
        local picker_vis = ImGui.BeginChild(ctx, "##import_picker", 0, 220, ImGui.ChildFlags_Border)
        if picker_vis then
          for pad_idx = 1, 16 do
            local src_idx = import_state.mapping[pad_idx]
            local sample_name = ""
            if src_idx and import_state.pads[src_idx] then
              sample_name = import_state.pads[src_idx].path:match("[/\\]([^/\\]+)$") or "?"
            end

            local type_label = AUTO_MAP_TYPES[pad_idx] or ""

            -- Pad label + combo for source selection
            ImGui.Text(ctx, string.format("Pad %2d %-9s", pad_idx, type_label))
            ImGui.SameLine(ctx, 160)
            ImGui.SetNextItemWidth(ctx, 250)
            local preview = src_idx and (tostring(src_idx) .. ": " .. sample_name) or "(none)"
            if ImGui.BeginCombo(ctx, "##pick" .. pad_idx, preview) then
              -- Option: none
                if ImGui.Selectable(ctx, "(none)", src_idx == nil) then
                  import_state.mapping[pad_idx] = nil
                end
                -- Options: all source samples
                for si = 1, #import_state.pads do
                  local sname = import_state.pads[si].path:match("[/\\]([^/\\]+)$") or "?"
                  local label = string.format("%d: %s", si, sname)
                  if ImGui.Selectable(ctx, label .. "##src" .. si, src_idx == si) then
                    import_state.mapping[pad_idx] = si
                  end
                end
                ImGui.EndCombo(ctx)
              end
          end
        end
        ImGui.EndChild(ctx)
      else
        -- Auto-map / Sequential: simple preview list
        ImGui.Text(ctx, "Preview:")
        local preview_vis = ImGui.BeginChild(ctx, "##import_preview", 0, 220, ImGui.ChildFlags_Border)
        if preview_vis then
          for pad_idx = 1, 16 do
            local src_idx = import_state.mapping[pad_idx]

            if src_idx and import_state.pads[src_idx] then
              local pad = import_state.pads[src_idx]
              local sample_name = pad.path:match("[/\\]([^/\\]+)$") or pad.path
              local type_label = import_state.mode == 1 and (" [" .. (AUTO_MAP_TYPES[pad_idx] or "?") .. "]") or ""
              local label = string.format("Pad %2d: %s%s", pad_idx, sample_name, type_label)
              ImGui.Text(ctx, label)
            else
              ImGui.TextDisabled(ctx, string.format("Pad %2d: —", pad_idx))
            end
          end
        end
        ImGui.EndChild(ctx)
      end

      ImGui.Spacing(ctx)

      -- Count how many pads will be loaded
      local load_count = 0
      for p = 1, 16 do
        if import_state.mapping[p] then
          load_count = load_count + 1
        end
      end

      -- Action buttons
      local can_import = load_count > 0
      if not can_import then ImGui.BeginDisabled(ctx) end
      if ImGui.Button(ctx, "IMPORT (" .. load_count .. " pads)", 140, 28) then
        import_execute()
      end
      if not can_import then ImGui.EndDisabled(ctx) end

      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, "Cancel", 80, 28) then
        import_cancel()
      end
    end -- if error else content
  end -- if open
    ImGui.End(ctx)
  end -- if visible
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- FILE SYSTEM
-- ═══════════════════════════════════════════════════════════════════════════════

local function scan_directory(path)
  if not path or path == "" then return end

  file_mgr.entries = {}
  file_mgr.filtered = nil
  file_mgr.selected_index = 0
  file_mgr.selected_set = {}
  file_mgr.range_anchor = 0
  file_mgr.focused_index = 0
  file_mgr.category_filter = nil  -- reset on navigation: counts change per folder
  search.query = ""
  metadata_queue = {}  -- clear stale entries from previous folder
  analysis_queue = {}

  -- Subdirectories: in normal (Tree) mode, enumerate immediately so the
  -- user can navigate into them. In Subfolders mode, skip — the scan
  -- queue walks them automatically and we present a flat file list.
  if not file_mgr.recurse then
    local idx = 0
    while true do
      local subdir = reaper.EnumerateSubdirectories(path, idx)
      if not subdir then break end
      if subdir:sub(1,1) ~= "." then -- skip hidden
        table.insert(file_mgr.entries, {
          name   = subdir,
          path   = path .. sep .. subdir,
          is_dir = true,
          size   = -1,
          ext    = "",
          duration = -1,
          nch    = -1,
          subfolder = "",
        })
      end
      idx = idx + 1
    end
  end

  -- Files: defer to incremental scan (process_scan_queue handles N per
  -- frame). In Subfolders mode, the scan state carries a BFS queue of
  -- directories to visit and a depth counter; the processor walks the
  -- tree until queue empty or SUBFOLDERS_MAX_FILES reached.
  file_mgr.scan_state = {
    path        = path,
    root        = path,
    file_idx    = 0,
    recurse     = file_mgr.recurse == true,
    depth       = 0,
    queue       = {},
    total_files = 0,
  }
  file_mgr.current_path = path
  file_mgr.needs_rescan = false
end

sort_entries = function()
  -- Folders always first, then sort files
  local dirs = {}
  local files = {}
  for _, e in ipairs(file_mgr.entries) do
    if e.is_dir then
      table.insert(dirs, e)
    else
      table.insert(files, e)
    end
  end

  -- Sort dirs alphabetically
  table.sort(dirs, function(a, b) return natural_lt(a.name:lower(), b.name:lower()) end)

  -- Sort files by selected column (1-based indices match column order:
  -- 1=name, 2=category, 3=type, 4=channels, 5=size, 6=duration, 7=BPM, 8=key)
  local col = file_mgr.sort_column
  local asc = file_mgr.sort_ascending
  table.sort(files, function(a, b)
    local va, vb
    local str = false  -- string column -> natural_lt, so digits count as numbers
    if col == 1 then     -- name
      va, vb, str = a.name:lower(), b.name:lower(), true
    elseif col == 2 then -- category
      va, vb, str = a.category or "other", b.category or "other", true
    elseif col == 3 then -- type
      va, vb, str = a.ext, b.ext, true
    elseif col == 4 then -- channels (treat -1 unknown as high so it sorts last asc)
      va = a.nch == -1 and 99 or (a.nch or 99)
      vb = b.nch == -1 and 99 or (b.nch or 99)
    elseif col == 5 then -- size
      va, vb = a.size, b.size
    elseif col == 6 then -- duration
      va, vb = a.duration, b.duration
    elseif col == 7 then -- BPM
      local aa = get_analysis(a.path)
      local ab = get_analysis(b.path)
      va = aa and aa.bpm or 0
      vb = ab and ab.bpm or 0
    elseif col == 8 then -- Key
      local aa = get_analysis(a.path)
      local ab = get_analysis(b.path)
      va, vb, str = (aa and aa.key or ""), (ab and ab.key or ""), true
    else
      va, vb, str = a.name:lower(), b.name:lower(), true
    end
    if va ~= vb then
      if str then
        if asc then return natural_lt(va, vb) else return natural_lt(vb, va) end
      end
      if asc then return va < vb else return va > vb end
    end
    -- Tied on the sort key -> fall back to the name, always ascending. table.sort
    -- is not stable, so without this the files inside one category (or sharing a
    -- BPM, or all still unanalysed) come out in a different order every rebuild.
    return natural_lt(a.name:lower(), b.name:lower())
  end)

  file_mgr.entries = {}
  for _, d in ipairs(dirs)  do table.insert(file_mgr.entries, d) end
  for _, f in ipairs(files) do table.insert(file_mgr.entries, f) end
end

local function apply_filter()
  -- Clear multi-select when filter changes (indices shift)
  file_mgr.selected_set = {}
  file_mgr.range_anchor = 0
  file_mgr.focused_index = 0
  local q   = search.query ~= "" and search.query:lower() or nil
  local cat = file_mgr.category_filter  -- nil or category name
  if not q and not cat then
    file_mgr.filtered = nil
    return
  end
  -- Query syntax: space-separated terms all have to match (AND), and a term
  -- prefixed with "-" must NOT match. Nested locals on purpose — top-level
  -- ones are a scarce resource in this chunk (see project_lua_200_local_limit).
  local inc, exc
  if q then
    inc, exc = {}, {}
    for tok in q:gmatch("%S+") do
      if tok:sub(1, 1) == "-" and #tok > 1 then
        exc[#exc + 1] = tok:sub(2)
      else
        inc[#inc + 1] = tok
      end
    end
  end

  -- Match against the folder and derived category as well as the filename.
  -- Sample libraries encode the role in the PATH far more often than in the
  -- name — "808/Kicks/Long/01.wav" is not findable by typing "kick" unless
  -- the subfolder is searched too.
  local function hay(e)
    if e.is_dir then return e.name:lower() end
    return (e.name .. " " .. (e.subfolder or "") .. " " .. (e.category or "")):lower()
  end
  local function term_match(e)
    if not q then return true end
    local h = hay(e)
    for _, t in ipairs(exc) do if h:find(t, 1, true) then return false end end
    for _, t in ipairs(inc) do if not h:find(t, 1, true) then return false end end
    return true
  end

  file_mgr.filtered = {}
  for _, e in ipairs(file_mgr.entries) do
    local pass
    if e.is_dir then
      -- Always offer directories so folders stay navigable under a category
      -- filter; they only have to satisfy the text query.
      pass = term_match(e)
    else
      pass = term_match(e) and not (cat and (e.category or "other") ~= cat)
    end
    if pass then table.insert(file_mgr.filtered, e) end
  end
end

local function get_display_entries()
  return file_mgr.filtered or file_mgr.entries
end

local function navigate_to(path)
  if not path or path == "" then return end
  -- Push current to history
  if file_mgr.current_path ~= "" then
    table.insert(file_mgr.history, file_mgr.current_path)
    if #file_mgr.history > 50 then table.remove(file_mgr.history, 1) end
  end
  scan_directory(path)
  -- Add to recent
  add_recent(path)
end

local function navigate_back()
  if #file_mgr.history == 0 then return end
  local prev = table.remove(file_mgr.history)
  scan_directory(prev)
end

local function navigate_up()
  local parent = get_parent_dir(file_mgr.current_path)
  if parent and parent ~= file_mgr.current_path then
    navigate_to(parent)
  end
end

add_recent = function(path)
  -- Remove if already in list
  for i = #file_mgr.recent_folders, 1, -1 do
    if file_mgr.recent_folders[i] == path then
      table.remove(file_mgr.recent_folders, i)
    end
  end
  table.insert(file_mgr.recent_folders, 1, path)
  -- Cap at 10
  while #file_mgr.recent_folders > 10 do
    table.remove(file_mgr.recent_folders)
  end
end

local function add_favorite(path, name)
  -- Check if already favorited
  for _, fav in ipairs(file_mgr.favorites) do
    if fav.path == path then return end
  end
  table.insert(file_mgr.favorites, {path = path, name = name or get_folder_name(path)})
end

local function remove_favorite(path)
  for i = #file_mgr.favorites, 1, -1 do
    if file_mgr.favorites[i].path == path then
      table.remove(file_mgr.favorites, i)
    end
  end
end

local function browse_for_folder()
  local retval, folder
  if has_js then
    retval, folder = reaper.JS_Dialog_BrowseForFolder("Select sample folder", file_mgr.current_path)
    if retval == 1 and folder and folder ~= "" then
      navigate_to(folder)
    end
  else
    -- Fallback: use GetUserFileNameForRead hack for folder
    retval, folder = reaper.GetUserFileNameForRead("", "Select any file in the target folder", "")
    if retval then
      local dir = folder:match("^(.*)[/\\]")
      if dir then navigate_to(dir) end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- AUDIO PREVIEW (CF_Preview)
-- ═══════════════════════════════════════════════════════════════════════════════

local function preview_stop()
  if playback.preview then
    reaper.CF_Preview_Stop(playback.preview)
    playback.preview = nil
  end
  playback.is_playing = false
  playback.is_paused  = false
  playback.position   = 0
  playback.current_file = ""
end

local function preview_play(filepath)
  if not has_sws then return end
  if not filepath or filepath == "" then return end
  if not is_native_audio(filepath) then return end

  -- Stop current
  preview_stop()

  -- Create source and preview
  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return end

  playback.preview = reaper.CF_CreatePreview(src)
  if not playback.preview then
    reaper.PCM_Source_Destroy(src)
    return
  end

  -- Configure (set volume/fade BEFORE Play to avoid pop/click)
  reaper.CF_Preview_SetValue(playback.preview, "D_VOLUME", playback.volume)
  reaper.CF_Preview_SetValue(playback.preview, "D_PITCH", playback.pitch)
  reaper.CF_Preview_SetValue(playback.preview, "B_LOOP", playback.loop and 1 or 0)
  reaper.CF_Preview_SetValue(playback.preview, "D_FADEINLEN", 0.005)   -- 5ms anti-click
  reaper.CF_Preview_SetValue(playback.preview, "D_FADEOUTLEN", 0.020)  -- 20ms anti-click

  -- Get length
  playback.length = reaper.GetMediaSourceLength(src)
  -- Source is owned by the preview now — do NOT destroy it

  reaper.CF_Preview_Play(playback.preview)
  playback.is_playing = true
  playback.is_paused  = false
  playback.current_file = filepath
end

local function preview_toggle_pause()
  if not playback.preview then return end
  if playback.is_paused then
    -- Resume: set pause off
    reaper.CF_Preview_SetValue(playback.preview, "B_PPPAUSED", 0)
    playback.is_paused = false
    playback.is_playing = true
  else
    -- Pause: keeps position
    reaper.CF_Preview_SetValue(playback.preview, "B_PPPAUSED", 1)
    playback.is_paused = true
    playback.is_playing = false
  end
end

local function preview_update()
  -- Call each frame to track position and detect end
  if not playback.preview then return end
  local retval, pos = reaper.CF_Preview_GetValue(playback.preview, "D_POSITION")
  if retval then playback.position = pos end

  -- Check if still playing (position advancing and not paused)
  if playback.is_playing and not playback.is_paused then
    if playback.length > 0 and pos >= playback.length - 0.01 and not playback.loop then
      playback.is_playing = false
      playback.position = 0
    end
  end
end

local function preview_seek(ratio)
  if not playback.preview or playback.length <= 0 then return end
  local pos = ratio * playback.length
  reaper.CF_Preview_SetValue(playback.preview, "D_POSITION", pos)
end

local function preview_set_volume(vol)
  playback.volume = math.max(0, math.min(1, vol))
  if playback.preview then
    reaper.CF_Preview_SetValue(playback.preview, "D_VOLUME", playback.volume)
  end
end

-- Preview pitch in semitones. playback.pitch has been pushed to the preview
-- since forever (D_PITCH at preview_play) but nothing ever wrote it, so it sat
-- at 0 — auditioning a kick a couple of semitones down is exactly how you tell
-- whether it will sit in a track, so it is worth having on the transport.
-- Applies live to a playing preview; no restart, no click.
local function preview_set_pitch(semitones)
  playback.pitch = math.max(-24, math.min(24, semitones))
  if playback.preview then
    reaper.CF_Preview_SetValue(playback.preview, "D_PITCH", playback.pitch)
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- WAVEFORM PEAKS (MPL-style PCM_Source_GetPeaks)
-- ═══════════════════════════════════════════════════════════════════════════════

-- ─── Spectral analysis (TK Media Browser port) ─────────────────────────────
-- FFT-based per-pixel spectral_value 0..1 used to color the waveform when
-- settings.spectral_view is on. Bass-heavy slices → low values (orange/red),
-- treble-heavy slices → high values (cyan/blue). Mirrors TK exactly:
-- 1024-point FFT per slice across 6 frequency bands with the same gain
-- profile (0.15, 0.20, 0.35, 0.70, 1.30, 2.20), squared and renormalized,
-- weighted-sum centroid, gamma 0.7. See TK_MEDIA_BROWSER(SA).lua:2777.
local function calculate_spectral_data(file_path, num_slices)
  local out = {}
  local proj = 0
  local src = reaper.PCM_Source_CreateFromFileEx(file_path, true)
  if not src then return out end

  local length = reaper.GetMediaSourceLength(src)
  if not length or length <= 0 then
    reaper.PCM_Source_Destroy(src)
    return out
  end

  -- The scratch track must NOT show up in the user's project — neither
  -- visually (track flash on screen during a tutorial recording) nor in
  -- the undo history (every file selection would otherwise leave a
  -- "Delete track" undo entry). Wrap the entire add/use/remove sequence
  -- in PreventUIRefresh so REAPER skips the per-step UI redraw, and put
  -- it inside an undo block whose "title" we'll never end (Undo_EndBlock2
  -- with flags=-1 to discard the changes — they're transient analysis
  -- scaffolding, not user-facing state).
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock2(0)

  reaper.InsertTrackAtIndex(reaper.CountTracks(proj), false)
  local scratch_tr = reaper.GetTrack(proj, reaper.CountTracks(proj) - 1)
  reaper.SetMediaTrackInfo_Value(scratch_tr, "B_SHOWINMIXER", 0)
  reaper.SetMediaTrackInfo_Value(scratch_tr, "B_SHOWINTCP",   0)
  local item = reaper.AddMediaItemToTrack(scratch_tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)
  local accessor = reaper.CreateTakeAudioAccessor(take)

  if accessor then
    local samplerate = reaper.GetMediaSourceSampleRate(src) or 44100
    local fft_size = 1024
    local samplebuf = reaper.new_array(fft_size * 2)

    -- Frequency band split points (fraction of Nyquist) — TK values
    local SPLIT1, SPLIT2, SPLIT3 = 0.16, 0.32, 0.50
    local SPLIT4, SPLIT5         = 0.70, 0.85
    -- Per-band linear gains (TK profile — emphasises treble for hi-hat
    -- vs bass for kick differentiation)
    local G1, G2, G3, G4, G5, G6 = 0.15, 0.20, 0.35, 0.70, 1.30, 2.20

    for slice = 0, num_slices - 1 do
      local start_time = (slice / num_slices) * length
      samplebuf.clear()
      local got = reaper.GetAudioAccessorSamples(accessor, samplerate, 1, start_time, fft_size, samplebuf)
      local sval = 0.5  -- default mid-band on read failure

      if got > 0 then
        samplebuf.fft_real(fft_size, true)

        local b1, b2, b3, b4, b5, b6 = 0, 0, 0, 0, 0, 0
        local c1, c2, c3, c4, c5, c6 = 0, 0, 0, 0, 0, 0

        for bin = 1, fft_size / 2 - 1 do
          local Re = samplebuf[bin * 2]
          local Im = samplebuf[bin * 2 + 1]
          local mag = math.sqrt(Re * Re + Im * Im)
          local ratio = bin / (fft_size / 2)
          if ratio < SPLIT1 then
            b1 = b1 + mag; c1 = c1 + 1
          elseif ratio < SPLIT2 then
            b2 = b2 + mag; c2 = c2 + 1
          elseif ratio < SPLIT3 then
            b3 = b3 + mag; c3 = c3 + 1
          elseif ratio < SPLIT4 then
            b4 = b4 + mag; c4 = c4 + 1
          elseif ratio < SPLIT5 then
            b5 = b5 + mag; c5 = c5 + 1
          else
            b6 = b6 + mag; c6 = c6 + 1
          end
        end

        if c1 > 0 then b1 = b1 / c1 end
        if c2 > 0 then b2 = b2 / c2 end
        if c3 > 0 then b3 = b3 / c3 end
        if c4 > 0 then b4 = b4 / c4 end
        if c5 > 0 then b5 = b5 / c5 end
        if c6 > 0 then b6 = b6 / c6 end

        -- Apply per-band gain
        b1 = b1 * G1; b2 = b2 * G2; b3 = b3 * G3
        b4 = b4 * G4; b5 = b5 * G5; b6 = b6 * G6

        -- Normalize to fractions
        local total = b1 + b2 + b3 + b4 + b5 + b6
        if total > 0 then
          b1 = b1 / total; b2 = b2 / total; b3 = b3 / total
          b4 = b4 / total; b5 = b5 / total; b6 = b6 / total
        end

        -- Square and re-normalize (sharpens distinction)
        b1 = b1 * b1; b2 = b2 * b2; b3 = b3 * b3
        b4 = b4 * b4; b5 = b5 * b5; b6 = b6 * b6
        total = b1 + b2 + b3 + b4 + b5 + b6
        if total > 0 then
          b1 = b1 / total; b2 = b2 / total; b3 = b3 / total
          b4 = b4 / total; b5 = b5 / total; b6 = b6 / total
        end

        -- Weighted centroid (band index 0..5 → 0..1 after / 5)
        local weighted = b1 * 0 + b2 * 1 + b3 * 2 + b4 * 3 + b5 * 4 + b6 * 5
        sval = (weighted / 5.0) ^ 0.7
      end

      out[slice + 1] = sval
    end

    reaper.DestroyAudioAccessor(accessor)
  end

  -- Tear down scratch track (DeleteTrack also tears down item, take, and
  -- the take's source reference — do NOT call PCM_Source_Destroy after)
  reaper.DeleteTrack(scratch_tr)

  -- Close the undo block and discard the recorded changes (-1 flag) —
  -- the scratch track is transient analysis scaffolding, the user
  -- shouldn't see "Delete track" cluttering their undo history. Then
  -- release the UI-refresh suppression.
  reaper.Undo_EndBlock2(0, "Spectral analysis (transient)", -1)
  reaper.PreventUIRefresh(-1)
  return out
end

local function generate_peaks(filepath, display_width)
  if not filepath or filepath == "" then return end
  local dw = display_width or 400
  -- Cache valid if same file AND width hasn't changed significantly (>20% drift)
  if waveform.cached_file == filepath and waveform.peak_count > 0
     and math.abs(waveform.cached_width - dw) < dw * 0.2 then
    return
  end

  waveform.peaks = {}
  waveform.peak_count = 0
  waveform.cached_file = ""
  waveform.cached_width = 0
  waveform.src_length = 0

  local src = reaper.PCM_Source_CreateFromFileEx(filepath, true)
  if not src then return end

  local src_len = reaper.GetMediaSourceLength(src)
  if src_len < 0.001 then
    reaper.PCM_Source_Destroy(src)
    return
  end

  local sr = reaper.GetMediaSourceSampleRate(src) or 44100
  local nch = reaper.GetMediaSourceNumChannels(src) or 1
  local peak_width = math.max(display_width or 400, 100)
  -- One peak per pixel. REAPER's PCM_Source_GetPeaks computes min/max
  -- over each peak's window internally, so each peak naturally spans
  -- the bipolar signal extremes — drawing y_top=mid-mx, y_bot=mid-mn
  -- fills both halves around the centerline. (An earlier attempt to
  -- ask peakrate=samplerate gave 1-sample peaks where mn==mx, which
  -- caused pixels to render only one half when high-frequency content
  -- happened to align positive- or negative-only within the small
  -- aggregation window.)
  local peakrate = math.max(peak_width / src_len, 200)
  local n_spls = math.floor(src_len * peakrate)
  if n_spls < 10 then
    reaper.PCM_Source_Destroy(src)
    return
  end

  -- Stereo peaks via PCM_Source_GetPeaks(nchans=2). Buffer layout for
  -- nchans=2 is channel-grouped per block, mirroring the mono layout
  -- [max_*, min_*]:
  --   [max_L_0..max_L_{n-1}, max_R_0..max_R_{n-1},
  --    min_L_0..min_L_{n-1}, min_R_0..min_R_{n-1}]
  -- Total size = 4 * n_spls.
  --
  -- Mono path (nch < 2) keeps the original 1-channel call.
  -- Content-detect: if every L pair equals every R pair within a small
  -- threshold, the file is effectively mono (synth recordings with L=R,
  -- joint-stereo MP3s, etc.) — fold to a single mono peak set so the
  -- preview shows one classic waveform instead of two identical-looking
  -- ones stacked. Only true L≠R content gets the Tukan-style split.
  waveform.peaks = {}

  local actual
  local is_stereo_format = nch >= 2

  -- IMPORTANT: PCM_Source_GetPeaks output buffer is sized for n_spls (the
  -- requested count), not `actual` (what REAPER returned). The min block
  -- always starts at offset n_spls regardless of how many peaks were
  -- actually generated. Indexing the min block at `actual` instead of
  -- `n_spls` reads garbage from the max-block tail when REAPER returns
  -- fewer peaks than requested (some MP3 / odd-format files), which made
  -- the renderer draw top-half-only waveforms.
  if is_stereo_format then
    local buf = reaper.new_array(n_spls * 4)
    buf.clear()
    local retval = reaper.PCM_Source_GetPeaks(src, peakrate, 0, 2, n_spls, 0, buf)
    reaper.PCM_Source_Destroy(src)
    actual = math.min(retval & 0xFFFFF, n_spls)
    if actual < 2 then return end

    -- Per-channel block offsets (each block is n_spls long, regardless
    -- of `actual`). Layout: [maxL, maxR, minL, minR] each n_spls long.
    local mxL_ofs = 0
    local mxR_ofs = n_spls
    local mnL_ofs = n_spls * 2
    local mnR_ofs = n_spls * 3

    -- Single pass: compute per-channel peak amplitudes, per-channel
    -- cumulative ENERGY (sum of abs amplitudes — proxy for RMS/area
    -- under the curve), and cumulative L/R difference.
    local max_amp_L = 0
    local max_amp_R = 0
    local energy_L  = 0  -- per-channel cumulative |amp| (≈ area)
    local energy_R  = 0
    local cum_diff   = 0  -- sum of |L-R| across max + min per pixel
    local cum_signal = 0  -- sum of louder-channel abs per pixel
    for i = 0, actual - 1 do
      local mxL = buf[mxL_ofs + i + 1]
      local mxR = buf[mxR_ofs + i + 1]
      local mnL = buf[mnL_ofs + i + 1]
      local mnR = buf[mnR_ofs + i + 1]
      local axL = math.abs(mxL); local axR = math.abs(mxR)
      local anL = math.abs(mnL); local anR = math.abs(mnR)
      if axL > max_amp_L then max_amp_L = axL end
      if anL > max_amp_L then max_amp_L = anL end
      if axR > max_amp_R then max_amp_R = axR end
      if anR > max_amp_R then max_amp_R = anR end
      energy_L = energy_L + axL + anL
      energy_R = energy_R + axR + anR
      cum_diff   = cum_diff + math.abs(mxL - mxR) + math.abs(mnL - mnR)
      cum_signal = cum_signal + math.max(axL, axR) + math.max(anL, anR)
    end
    local max_amp = math.max(max_amp_L, max_amp_R)
    local norm = max_amp > 0.001 and (1.0 / max_amp) or 1.0

    -- Stereo-ness gate: kick / drum samples are commonly stored as
    -- stereo with L≈R (mono content in a stereo container). The old
    -- per-sample EPS=0.001 check fired on any noise-floor difference,
    -- so kicks rendered as two near-identical halves that visually
    -- merge into "one waveform wrapping around" — the user calls this
    -- a display bug. Use a RELATIVE difference test instead: only
    -- treat as stereo if total |L-R| > 10% of total louder-channel
    -- signal. Real stereo content (panned hats, reverb tails, M/S
    -- processed sounds) easily clears this; mono-as-stereo files
    -- correctly fold to one waveform.
    local stereo_content = cum_signal > 0.001 and (cum_diff / cum_signal) >= 0.10

    -- Channel-balance gate: drum/bass samples are often stored as
    -- "stereo" with the second channel quiet (mono content laid into
    -- L, M/S processed, or low-level dither/ambient on R). Even if
    -- stereo_content is true (channels differ in shape), if the
    -- quieter channel carries far less ENERGY than the louder one
    -- the stereo render shows one fat waveform up top and a thin
    -- line on the bottom — the user sees this as broken.
    --
    -- Use cumulative-energy ratio instead of peak ratio. Peak ratio
    -- failed on kicks where the R channel had occasional loud spikes
    -- (passes a 30% peak check) but was mostly silent (RMS-wise far
    -- quieter than L). Energy = cumulative |amp| ≈ area under the
    -- curve, which mirrors what the user perceives as "is this
    -- channel actually carrying content?". 30% energy threshold:
    -- real stereo (panned content, reverbs) keeps energy within
    -- ±10 dB; mono-as-stereo collapses to single waveform.
    local louder_e  = math.max(energy_L, energy_R)
    local quieter_e = math.min(energy_L, energy_R)
    -- 30% (≈ -10.5 dB) — calibrated value. Catches the bulk of
    -- mono-as-stereo files (kick samples with quiet R, bass with
    -- silent R) while leaving subtle-stereo recordings intact.
    -- Tried 40% which folded too much real stereo, then 35% as a
    -- compromise — settled back on 30% because it was already
    -- correct for everything except a single edge-case kick. True
    -- stereo content (panned hats, M/S synth, recorded room) keeps
    -- both channel energies within ~10 dB so still passes.
    local channel_balanced = louder_e < 0.001 or (quieter_e / louder_e) >= 0.30
    local render_as_stereo = stereo_content and channel_balanced

    -- Pick which channel to fold to when imbalanced (quieter is
    -- silent or near-silent). Use the energy-louder channel.
    local louder_is_L = energy_L >= energy_R

    waveform.is_stereo = render_as_stereo

    if render_as_stereo then
      for i = 0, actual - 1 do
        local mxL = buf[mxL_ofs + i + 1] * norm
        local mxR = buf[mxR_ofs + i + 1] * norm
        local mnL = buf[mnL_ofs + i + 1] * norm
        local mnR = buf[mnR_ofs + i + 1] * norm
        waveform.peaks[i + 1] = {mnL, mxL, mnR, mxR}
      end
    else
      -- Fold to mono. Two routes depending on why we landed here:
      --   1. Balanced channels with content == (L≈R or no stereo info)
      --      → average L+R so the rendered line sits in the middle.
      --   2. Imbalanced channels (one silent / much quieter)
      --      → use the louder channel directly. Averaging would half-
      --      amplitude the visible signal, making bass files look
      --      tiny when they're actually full-scale on one side.
      if channel_balanced then
        for i = 0, actual - 1 do
          local mx = (buf[mxL_ofs + i + 1] + buf[mxR_ofs + i + 1]) * 0.5 * norm
          local mn = (buf[mnL_ofs + i + 1] + buf[mnR_ofs + i + 1]) * 0.5 * norm
          waveform.peaks[i + 1] = {mn, mx}
        end
      else
        local mx_ofs = louder_is_L and mxL_ofs or mxR_ofs
        local mn_ofs = louder_is_L and mnL_ofs or mnR_ofs
        for i = 0, actual - 1 do
          waveform.peaks[i + 1] = {
            buf[mn_ofs + i + 1] * norm,
            buf[mx_ofs + i + 1] * norm,
          }
        end
      end
    end
  else
    -- True mono source: single-channel call, layout [max_*, min_*] each
    -- of length n_spls. min block starts at offset n_spls (not `actual`).
    local buf = reaper.new_array(n_spls * 2)
    buf.clear()
    local retval = reaper.PCM_Source_GetPeaks(src, peakrate, 0, 1, n_spls, 0, buf)
    reaper.PCM_Source_Destroy(src)
    actual = math.min(retval & 0xFFFFF, n_spls)
    if actual < 2 then return end
    local mn_ofs = n_spls
    local max_amp = 0
    for i = 0, actual - 1 do
      local mx = buf[i + 1]
      local mn = buf[mn_ofs + i + 1]
      if math.abs(mn) > max_amp then max_amp = math.abs(mn) end
      if math.abs(mx) > max_amp then max_amp = math.abs(mx) end
    end
    local norm = max_amp > 0.001 and (1.0 / max_amp) or 1.0
    waveform.is_stereo = false
    for i = 0, actual - 1 do
      local mn = buf[mn_ofs + i + 1] * norm
      local mx = buf[i + 1] * norm
      waveform.peaks[i + 1] = {mn, mx}
    end
  end

  waveform.peak_count = actual
  waveform.cached_file = filepath
  waveform.cached_width = dw
  waveform.src_length = src_len
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- GMEM / PAD COMMUNICATION
-- ═══════════════════════════════════════════════════════════════════════════════

local function gmem_init()
  reaper.gmem_attach(core.GMEM_NAME)
end

local function bridge_is_alive()
  local t = reaper.gmem_read(G.BRIDGE_ALIVE)
  if t == 0 then return false end
  return (os.time() - t) < 5
end

-- Active Swing instance the browser is currently bound to. Set when the
-- browser opens (from gmem[INSTANCE] which the JSFX wrote before CMD 60),
-- updated when the user picks a different instance from the popup, cleared
-- on close. The corresponding gmem slot is what the JSFX side reads to
-- decide whether to act on browser CMDs (see _is_browser_target).
active_inst_id = 0  -- module-scope (Lua "local" omitted intentionally so init/cleanup share it)

-- Scan all tracks for Swing FX instances (called on-demand when popup opens)
local swing_instances = {}
local function enumerate_swing_instances()
  swing_instances = {}
  active_inst_id = math.floor(reaper.gmem_read(G.INSTANCE))
  local now = reaper.time_precise()

  -- Step 1: collect alive inst_ids from the registry (JSFX writes every block).
  -- Map inst_id → display-only fields (pad_count, kit_hash).
  local alive = {}
  for s = 0, G.GS_INST_REG_MAX - 1 do
    local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
    local id        = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID))
    local heartbeat =            reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT)
    if id > 0 and heartbeat > 0 and (now - heartbeat) < G.GS_INST_REG_TIMEOUT then
      alive[id] = {
        pad_count = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_PAD_COUNT)),
        kit_hash  = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_KIT_HASH)),
      }
    end
  end

  -- Step 2: one-shot track scan to map alive inst_ids to their (track, fx).
  -- Done browser-side because JSFX has no API to know its own track/fx.
  -- We only fetch what we need; entries without a matching alive registry
  -- slot are dropped (instance was deleted but bridge hasn't noticed).
  local per_track = {}
  for tr in core.iter_all_tracks() do
    for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
      local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
      local is_swing = (retval and ident:find("DrumKit_ReaKit"))
                    or fname:find("DrumKit_ReaKit")
                    or fname:match("^JS: Swing")
                    or fname:match("Swing %— 16%-Pad")
      if is_swing then
        local inst_id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
        local meta = alive[inst_id]
        if meta then
          local track_num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
          local _, track_name = reaper.GetTrackName(tr)
          swing_instances[#swing_instances + 1] = {
            track      = tr,
            fx_index   = fx,
            inst_id    = inst_id,
            track_num  = track_num,
            track_name = track_name,
            pad_count  = meta.pad_count,
            kit_hash   = meta.kit_hash,
            is_active  = (inst_id == active_inst_id and active_inst_id > 0),
          }
          per_track[track_num] = (per_track[track_num] or 0) + 1
        end
      end
    end
  end

  -- Mark stacked entries so the picker can suffix "(FX #N)".
  for _, inst in ipairs(swing_instances) do
    inst.is_stacked = (per_track[inst.track_num] or 0) > 1
  end
end

local read_pad_name = core.read_pad_name
local pad_has_audio = core.pad_has_audio

-- Display/trigger truth: sample OR enabled synth (IDENT playable flag).
-- pad_has_audio stays for sample-specific paths (layer targeting, save).
local function pad_playable(pad)
  local inst = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  return core.pad_is_playable(pad, core.resolve_inst_slot(inst))
end

local write_pad_name_to_gmem = core.write_pad_name

-- Categories: the browser is the only place that sees a sample's FULL filename
-- AND the folder it came from, so it is the only place that can classify one
-- properly. Nothing on the load path published a category at all before this, so
-- a pad kept whatever category the previous kit gave it — drop a crash on a pad
-- that used to be a kick and it stayed a kick. The two fallbacks are both worse:
-- the pad glyph's own classifier is substring-based (reads "Custom" as a tom),
-- and right-click Auto re-infers from the 32-char gmem name, which truncates
-- long pack names past the word that identifies them.
--
-- Handed to the bridge over ExtState, not gmem. The category mailbox at 26004500
-- is single-slot and ALREADY has two writers (Swing's JSFX and EON_StepSeq); a
-- third racing its payload-then-seq post could land the wrong category on the
-- wrong pad, and a burst of pad loads would drop all but the last. A string
-- queue cannot tear and cannot drop. Both ends are Lua, and this is a UI-rate
-- event, so there is nothing gmem would buy.
local function queue_pad_category(pad_idx, filepath)
  if not filepath or not pad_idx then return end
  local slot = core.resolve_inst_slot and core.resolve_inst_slot(active_inst_id)
  if not slot then return end
  local fname  = filepath:match("[/\\]([^/\\]+)$") or filepath
  local folder = filepath:sub(1, #filepath - #fname)
  local cat, matched = categorizer.classify(fname, folder)
  -- An unconfident guess is worse than leaving the pad uncategorised: the glyph
  -- falls back to name inference on its own, and FILL treats -1 as eligible.
  if not matched or cat == "other" then return end
  local q = reaper.GetExtState("EON_Swing", "padcat_queue")
  -- If the bridge is not running, nothing drains this. Cap it rather than grow
  -- an unbounded ExtState string across a session.
  if #q > 4000 then return end
  q = (q ~= "" and (q .. ";") or "") .. slot .. ":" .. pad_idx .. ":" .. cat
  reaper.SetExtState("EON_Swing", "padcat_queue", q, false)
end

load_sample_to_pad = function(filepath, pad_idx)
  if not filepath or not pad_idx then return false end
  if pad_idx < 0 or pad_idx >= G.NUM_PADS then return false end
  if math.floor(reaper.gmem_read(G.CMD)) ~= 0 then return false end -- busy
  if math.floor(reaper.gmem_read(G.LOCK)) ~= 0 then return false end -- bridge busy

  -- Write file path as character codes directly to gmem
  local path_len = math.min(#filepath, G.GS_BROWSER_PATH_MAX - 1)
  for i = 0, path_len - 1 do
    reaper.gmem_write(G.GS_BROWSER_PATH + i, filepath:byte(i + 1))
  end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, path_len)

  -- Write pad name to gmem PADNAME area
  local fname = filepath:match("[/\\]([^/\\]+)$") or filepath
  local short_name = fname:match("(.*)%.[^%.]+$") or fname
  write_pad_name_to_gmem(pad_idx, short_name:sub(1, 32))

  -- Set target pad and send CMD 63 (JSFX handles directly via load_from_path).
  -- Re-assert INSTANCE so the active instance is the one that loads (other
  -- Swing instances ignore CMD 63 when their instance_id doesn't match).
  reaper.gmem_write(G.INSTANCE, active_inst_id)
  reaper.gmem_write(G.GS_BROWSE_PAD, pad_idx)
  reaper.gmem_write(G.CMD, 63)

  -- Write BPM/Key analysis to gmem for LCD display
  local a = get_analysis(filepath)
  if not a then
    -- Run analysis inline for the loaded sample
    analyze_file(filepath)
    run_analysis(filepath)
    a = analysis_cache[filepath]
  end
  if a and a.analyzed then
    reaper.gmem_write(G.GS_PAD_BPM_BASE + pad_idx, a.bpm or 0)
    -- Key: encode as note index (1-12) + minor flag (0 or 100)
    local key_val = 0
    if a.key then
      for i, name in ipairs(NOTE_NAMES) do
        if a.key == name then key_val = i; break end
        if a.key == name .. "m" then key_val = i + 100; break end
      end
    end
    reaper.gmem_write(G.GS_PAD_KEY_BASE + pad_idx, key_val)
  end
  queue_pad_category(pad_idx, filepath)
  return true
end

load_layer_to_pad = function(filepath, pad_idx, layer_idx)
  if not filepath or not pad_idx then return false end
  if pad_idx < 0 or pad_idx >= G.NUM_PADS then return false end
  if math.floor(reaper.gmem_read(G.CMD)) ~= 0 then return false end -- busy
  if math.floor(reaper.gmem_read(G.LOCK)) ~= 0 then return false end -- bridge busy

  -- Write file path as character codes directly to gmem
  local path_len = math.min(#filepath, G.GS_BROWSER_PATH_MAX - 1)
  for i = 0, path_len - 1 do
    reaper.gmem_write(G.GS_BROWSER_PATH + i, filepath:byte(i + 1))
  end
  reaper.gmem_write(G.GS_BROWSER_PATH_LEN, path_len)

  -- Write pad name to gmem PADNAME area (only for layer 0)
  if layer_idx == 0 then
    local fname = filepath:match("[/\\]([^/\\]+)$") or filepath
    local short_name = fname:match("(.*)%.[^%.]+$") or fname
    write_pad_name_to_gmem(pad_idx, short_name:sub(1, 32))
    -- Layer 0 names the pad, so it also decides the pad's category. Layers
    -- 1..n are velocity/RR variants of the SAME drum and must not re-post.
    queue_pad_category(pad_idx, filepath)
  end

  -- Set target pad, layer index, and send CMD 64.
  -- Re-assert INSTANCE so only the active instance handles the load.
  reaper.gmem_write(G.INSTANCE, active_inst_id)
  reaper.gmem_write(G.GS_BROWSE_PAD, pad_idx)
  reaper.gmem_write(G.GS_BROWSE_LAYER, layer_idx)
  reaper.gmem_write(G.CMD, 64)
  return true
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MULTI-SELECT HELPERS
-- ═════════════════════════════════════════════════════════════════���═════════════

local function clear_selection()
  file_mgr.selected_set = {}
  file_mgr.focused_index = 0
end

local function get_selected_count()
  local n = 0
  for _ in pairs(file_mgr.selected_set) do n = n + 1 end
  return n
end

local function get_selected_files_ordered()
  -- Returns sorted list of {index, entry} for all selected audio files
  local out = {}
  local entries = get_display_entries()
  local indices = {}
  for idx in pairs(file_mgr.selected_set) do indices[#indices + 1] = idx end
  table.sort(indices)
  for _, idx in ipairs(indices) do
    local e = entries[idx]
    if e and not e.is_dir and is_audio_file(e.name) then
      out[#out + 1] = {index = idx, entry = e}
    end
  end
  return out
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MULTI-LOAD QUEUE (processes one item per frame to avoid gmem CMD collisions)
-- ═══════════════════════════════════════════════════════════════════════════════

local multi_load_queue  = {}   -- { {filepath, pad_idx, is_layer, layer} }
local multi_load_status = ""   -- "X of Y loaded · not enough pads"

local function load_selected_to_pads(as_layers)
  local files = get_selected_files_ordered()
  if #files == 0 then return end
  multi_load_queue = {}
  multi_load_status = ""

  if as_layers then
    -- Layer mode: stack selected files as layers on active pad
    -- Start from layer 0 (replaces all layers with the selection)
    local max_layers = 4
    for i, f in ipairs(files) do
      local layer = i - 1
      if layer >= max_layers then break end
      multi_load_queue[#multi_load_queue + 1] = {
        filepath = f.entry.path, pad_idx = ui.target_pad, is_layer = true, layer = layer
      }
    end
    if #files > max_layers then
      multi_load_status = max_layers .. " of " .. #files .. " layered \xC2\xB7 max 4 layers"
    end
  else
    -- Default: sequential fill from active pad
    local pad = ui.target_pad
    local loaded, total = 0, #files
    for _, f in ipairs(files) do
      if pad >= G.NUM_PADS then break end
      multi_load_queue[#multi_load_queue + 1] = {
        filepath = f.entry.path, pad_idx = pad, is_layer = false
      }
      loaded = loaded + 1
      pad = pad + 1
    end
    if loaded < total then
      multi_load_status = loaded .. " of " .. total .. " loaded \xC2\xB7 not enough pads"
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- DRAG-OUT TO THE JSFX PAD GRID  (EON_DRAG mailbox)
-- ═══════════════════════════════════════════════════════════════════════════════
-- An ImGui drag payload never becomes a Win32 OLE drop, so the JSFX pad grid's
-- gfx_getdropfile can never see a drag that starts in this browser — dragging
-- onto the plugin's pads has never worked. Rather than start a real OLE drag
-- (which needs the extension), we own the gesture ourselves: while the button
-- is held we ask the OS which window is under the cursor, and if it is a Swing
-- @gfx surface we BROADCAST the cursor's position in that surface's client
-- pixels. Every live instance then answers "is that me?" by comparing its own
-- mouse_x/mouse_y; the one that matches does the hit-test (it knows its own
-- grid), lights the pad, and claims — so what you see lit is what loads.
--
-- Broadcasting is what makes DOCKED and FX-CHAIN instances work. Identifying
-- the window's owner from Lua is only possible via TrackFX_GetFloatingWindow,
-- so v1 could only ever drop onto a FLOATING window — not onto the chain view
-- you get the moment you insert Swing. Nothing here is per-window now.
--
-- Probe-verified 2026-07-31: (a) the cursor-to-window hit-test keeps resolving
-- even while ImGui holds the mouse capture, which is what makes a synthetic
-- drag possible without an OLE drag at all (dragdrop_wintree_probe.lua);
-- (b) a JSFX's mouse_x/mouse_y keep tracking the cursor OUTSIDE its own window
-- (measured mouse_y = -56) and @gfx runs for a chain-hosted FX, so non-hovered
-- instances reliably stay silent (mousebounds_probe.jsfx).
--
-- js_ReaScriptAPI is a SOFT dependency everywhere else in this file, so every
-- entry point nil-guards and the feature simply stays dormant without it.
local xdrag = {
  active   = false,  -- a drag that started in this browser is in flight
  paths    = nil,    -- ordered file paths snapshotted at drag start
  stamp    = 0,      -- last stamp we published
  inst     = nil,    -- instance that claimed the broadcast
  pad      = -1,     -- pad that instance reports the cursor is over
  pad_t    = 0,      -- when that claim arrived
  at       = nil,    -- "mode:x:y" the claim was given for; a still cursor
                     -- keeps the claim alive, a moved one invalidates it
}

-- No AddressFromHandle any more: nothing here maps a window to an instance —
-- instances identify themselves. GetParent is back only to answer "is the
-- cursor over REAPER at all", which gates the blind broadcast.
function xdrag.available()
  return reaper.JS_Window_FromPoint ~= nil
     and reaper.JS_Window_GetClassName ~= nil
     and reaper.JS_Window_ScreenToClient ~= nil
     and reaper.JS_Window_GetClientSize ~= nil
     and reaper.JS_Window_GetParent ~= nil
     and reaper.JS_Mouse_GetState ~= nil
end

-- Disarm the broadcast so no instance keeps a highlight lit (stamp 0 = idle).
function xdrag.clear()
  reaper.gmem_write(G.EON_DRAG_BASE + G.EON_DRAG_OFF_STAMP, 0)
end

-- Tear the gesture down and leave nothing armed. Also called from cleanup():
-- if the browser dies mid-drag (error, close, REAPER exit) a non-zero stamp
-- would otherwise sit in gmem for the rest of the session, and gmem outlives
-- a JSFX recompile — a re-instantiated Swing would read that leftover as a
-- live gesture and flash a phantom highlight.
function xdrag.abort()
  xdrag.clear()
  xdrag.active, xdrag.paths = false, nil
  xdrag.inst, xdrag.pad, xdrag.pad_t, xdrag.at = nil, -1, 0, nil
end

-- The cursor's position in CLIENT pixels of the topmost jsfx_gfx surface,
-- plus that surface's size, or nil if the cursor is not over one.
--
-- Note what this deliberately does NOT do: work out WHICH instance owns the
-- window. That question is only answerable via TrackFX_GetFloatingWindow,
-- which is exactly why v1 could not drop onto an instance sitting in the FX
-- chain. Here we only need the coordinates — the instances identify
-- themselves by matching their own mouse_x/mouse_y against them.
--
-- Requiring class jsfx_gfx keeps FX-window chrome (title bars, preset combos)
-- from reading as pad hits, and guarantees the client rect is the one the
-- JSFX actually draws into, so its mouse_x/mouse_y share this origin.
-- Returns mode, cx, cy, cw, ch — or nil when the cursor is somewhere no Swing
-- could possibly be.
--
-- PRECISE: over a real jsfx_gfx surface. Coordinates are usable and only the
-- instance whose own mouse_x/y match them claims. Floating and FX-chain.
--
-- BLIND: over REAPER, but not over any jsfx_gfx window. An EMBEDDED instance
-- (TCP/MCP) is painted into REAPER's own panel and owns no window, so there is
-- nothing here to measure and no coordinates worth sending — it decides for
-- itself whether its pointer is in bounds. Two guards make that safe:
--   * it must be REAPER under the cursor. An embedded instance's mouse_x/y
--     track the screen even when something is drawn OVER it, so broadcasting
--     blind while hovering another application would let an occluded instance
--     claim a drop the user never aimed at it.
--   * never our own ImGui window, so a release over the browser cannot fall
--     through onto an embedded pad sitting underneath it.
function xdrag.hit()
  local mx, my = reaper.GetMousePosition()
  local h = reaper.JS_Window_FromPoint(mx, my)
  if not h then return nil end

  local cls = reaper.JS_Window_GetClassName(h) or ""
  if cls == "jsfx_gfx" then
    local _, cw, ch = reaper.JS_Window_GetClientSize(h)
    if not cw or cw <= 0 or ch <= 0 then return nil end
    local cx, cy = reaper.JS_Window_ScreenToClient(h, mx, my)
    if not cx then return nil end
    return G.EON_DRAG_MODE_PRECISE, cx, cy, cw, ch
  end
  if cls == "reaper_imgui_context" then return nil end

  -- Walk to the top level: REAPER's own views (arrange, TCP, mixer) are child
  -- windows of the main window, and a floating mixer/docker reports a REAPER*
  -- class of its own. Coarse on purpose — being over REAPER at all is enough,
  -- because the in-bounds test on the JSFX side is the real filter.
  local main, node = reaper.GetMainHwnd(), h
  for _ = 1, 8 do
    if node == main then return G.EON_DRAG_MODE_BLIND, 0, 0, 0, 0 end
    local parent = reaper.JS_Window_GetParent(node)
    if not parent then break end
    node = parent
  end
  if cls:match("^REAPER") then return G.EON_DRAG_MODE_BLIND, 0, 0, 0, 0 end
  return nil
end

-- Called at BeginDragDropSource: remember what is being dragged. That returns
-- true on EVERY frame of the drag, not just the first, so this must be
-- idempotent.
function xdrag.begin_drag(single_path, multi)
  if xdrag.active or not xdrag.available() then return end
  local paths = {}
  if multi then
    for _, f in ipairs(get_selected_files_ordered()) do paths[#paths + 1] = f.entry.path end
  end
  if #paths == 0 then paths = {single_path} end
  xdrag.active, xdrag.paths = true, paths
  xdrag.inst, xdrag.pad, xdrag.pad_t = nil, -1, 0
end

-- Read whichever instance claimed the current broadcast. Exactly one should:
-- only the window actually under the cursor sees its own mouse_x/mouse_y
-- equal to the broadcast coordinates. Returns inst_id, pad or nil.
function xdrag.read_claim()
  local now = reaper.time_precise()
  for slot = 0, G.GS_INST_REG_MAX - 1 do
    local cb = G.EON_DRAG_CLAIM_BASE + slot * G.EON_DRAG_CLAIM_STRIDE
    -- The echo is a stamp WE generated, so its own age is the freshness test.
    local echo = reaper.gmem_read(cb + G.EON_DRAG_CLAIM_ECHO) or 0
    if echo > 0 and (now - echo) < 0.25 then
      local pad  = math.floor(reaper.gmem_read(cb + G.EON_DRAG_CLAIM_PAD) or -1)
      local inst = math.floor(reaper.gmem_read(cb + G.EON_DRAG_CLAIM_INST) or 0)
      if pad >= 0 and inst > 0 then return inst, pad end
    end
  end
  return nil
end

-- Queue the drop through the SAME retry-safe path the multi-select load uses
-- (load_sample_to_pad fails fast while a CMD/LOCK is in flight, so a direct
-- call here could silently drop the file).
function xdrag.commit(inst, pad)
  if not xdrag.paths or not pad or pad < 0 then return end
  multi_load_status = ""
  -- Stamp the target instance on every queue ITEM. The queue drains over
  -- several frames and load_sample_to_pad routes by whatever gmem[INSTANCE]
  -- says at drain time, so binding globally here would misroute anything
  -- already queued for a different instance.
  local n = 0
  for i, p in ipairs(xdrag.paths) do
    local target = pad + i - 1
    if target >= G.NUM_PADS then break end
    multi_load_queue[#multi_load_queue + 1] =
      {filepath = p, pad_idx = target, is_layer = false, inst_id = inst}
    n = n + 1
  end
  if n < #xdrag.paths then
    multi_load_status = n .. " of " .. #xdrag.paths .. " loaded Â· not enough pads"
  end
  -- Retarget the browser too, so the title bar and pad tiles follow the drop.
  if n > 0 and inst and inst > 0 and inst ~= active_inst_id then
    active_inst_id = inst
    reaper.gmem_write(G.INSTANCE, active_inst_id)
  end
  -- Two-sided guard against a double load: the release path already re-tests
  -- the cursor, but if ImGui also resolves its own drop target this tick
  -- (overlapping windows) on_pad_drop checks this and bails.
  xdrag.consumed_at = reaper.time_precise()
end

-- Per-frame watcher. Runs OUTSIDE the ImGui window so it keeps working once
-- the cursor has left the browser, which is the whole point.
function xdrag.update()
  if not xdrag.active then return end

  if (reaper.JS_Mouse_GetState(1) & 1) == 0 then
    -- Released. Prefer a claim answered RIGHT NOW — the JSFX repaints on its
    -- own clock, so the freshest answer is the pad actually still lit.
    local inst, pad = xdrag.read_claim()
    if not (inst and pad) then
      -- Nothing fresh. Fall back to the held claim, but ONLY if the cursor is
      -- still exactly where that claim was given: an instance that repaints
      -- on events alone stops answering the moment you hold still, and
      -- refusing the drop then would be the one case this whole mechanism has
      -- to get right.
      local m, cx, cy = xdrag.hit()
      if m and xdrag.at == (m .. ":" .. cx .. ":" .. cy) then
        inst, pad = xdrag.inst, xdrag.pad
      end
    end
    -- A release that ends over the browser's own window resolves to nothing
    -- here (xdrag.hit rejects our ImGui class), so ImGui's mini pad grid keeps
    -- sole ownership of that drop and nothing loads twice.
    if inst and pad and pad >= 0 then
      xdrag.commit(inst, pad)
    end
    xdrag.abort()
    return
  end

  local mode, cx, cy, cw, ch = xdrag.hit()
  if not mode then
    -- Nowhere a Swing could be: stop broadcasting so every instance drops its
    -- highlight, and forget any claim from a moment ago.
    xdrag.clear()
    xdrag.inst, xdrag.pad, xdrag.at = nil, -1, nil
    return
  end

  -- Read the claim BEFORE publishing this frame's coords, so the pad we hold
  -- always corresponds to a broadcast the instances have already answered.
  local here = mode .. ":" .. cx .. ":" .. cy
  local inst, pad = xdrag.read_claim()
  if inst and pad then
    xdrag.inst, xdrag.pad, xdrag.pad_t = inst, pad, reaper.time_precise()
    xdrag.at = here    -- remember WHERE this answer was given
  elseif xdrag.at and xdrag.at ~= here then
    -- The cursor has moved and nobody has answered for the new position yet.
    -- Drop the old answer rather than let it stand for somewhere it was never
    -- given. While the cursor is STILL, an unanswered frame changes nothing
    -- and the previous claim rides — which is what makes this indifferent to
    -- how often an instance repaints (embedded views may only redraw on
    -- events; unresolved, and this makes it moot).
    xdrag.inst, xdrag.pad, xdrag.at = nil, -1, nil
  end

  -- Payload first, stamp LAST — the stamp is the memory barrier stand-in
  -- (Lua has no gmem atomics; ordering is the only synchronisation we get).
  local B = G.EON_DRAG_BASE
  reaper.gmem_write(B + G.EON_DRAG_OFF_X, cx)
  reaper.gmem_write(B + G.EON_DRAG_OFF_Y, cy)
  reaper.gmem_write(B + G.EON_DRAG_OFF_W, cw)
  reaper.gmem_write(B + G.EON_DRAG_OFF_H, ch)
  reaper.gmem_write(B + G.EON_DRAG_OFF_COUNT, #xdrag.paths)
  reaper.gmem_write(B + G.EON_DRAG_OFF_MODE, mode)
  xdrag.stamp = reaper.time_precise()
  reaper.gmem_write(B + G.EON_DRAG_OFF_STAMP, xdrag.stamp)
end

-- Theme: local wrappers around widgets module
local function push_theme(ctx)
  -- Follow the shared EON theme each frame so changing it in any EON tool re-skins here too.
  local _sh = reaper.GetExtState("Swing", "eon_theme")
  if _sh ~= "" and _sh ~= settings.theme then settings.theme = _sh end
  widgets.push_theme(ctx, settings.theme)
end
local function pop_theme(ctx)
  widgets.pop_theme(ctx)
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- UI DRAWING
-- ═══════════════════════════════════════════════════════════════════════════════

local function draw_nav_bar(ctx)
  -- Navigation buttons (compact, REAPER-style)
  local can_back = #file_mgr.history > 0
  local can_up   = file_mgr.current_path ~= "" and get_parent_dir(file_mgr.current_path) ~= file_mgr.current_path

  if not can_back then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, "\xE2\x97\x80##back", 24, 20) then navigate_back() end
  if not can_back then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx, nil, 2)

  if not can_up then ImGui.BeginDisabled(ctx) end
  if ImGui.Button(ctx, "\xE2\x96\xB2##up", 24, 20) then navigate_up() end
  if not can_up then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx, nil, 2)

  if ImGui.Button(ctx, "\xF0\x9F\x93\x82##folder", 24, 20) then browse_for_folder() end
  if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, "Browse for folder") end

  ImGui.SameLine(ctx, nil, 4)

  -- Address bar (interactive frame, like REAPER's path bar)
  local avail = ImGui.GetContentRegionAvail(ctx)
  local fav_btn_w = 20
  local path_w = avail - fav_btn_w - 6

  -- Address bar uses a fixed dark background regardless of theme (matches the
  -- search bar below). Force Col_Text white so the path stays legible in
  -- light mode — without this, the theme's dark text renders invisible on
  -- the dark frame bg.
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x14141AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  ImGui.PushItemWidth(ctx, path_w)
  local path_display = file_mgr.current_path ~= "" and file_mgr.current_path or "(no folder selected)"
  -- Read-only input field looks like an address bar
  ImGui.InputText(ctx, "##path_display", path_display, ImGui.InputTextFlags_ReadOnly)
  ImGui.PopItemWidth(ctx)
  ImGui.PopStyleColor(ctx, 2)  -- Col_FrameBg + Col_Text

  ImGui.SameLine(ctx, nil, 2)

  -- Favorite toggle
  local is_fav = false
  for _, f in ipairs(file_mgr.favorites) do
    if f.path == file_mgr.current_path then is_fav = true; break end
  end
  local fav_label = is_fav and "\xE2\xAD\x90##fav" or "\xE2\x98\x86##fav"
  if ImGui.Button(ctx, fav_label, fav_btn_w, 20) then
    if is_fav then
      remove_favorite(file_mgr.current_path)
    else
      add_favorite(file_mgr.current_path)
    end
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, is_fav and "Remove from favorites" or "Add to favorites")
  end

  -- Search bar — full width, integrated below path (like Media Explorer filter)
  ImGui.PushStyleColor(ctx, ImGui.Col_FrameBg, 0x14141AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFFFFFFF)
  ImGui.PushItemWidth(ctx, -1)
  -- Ctrl+F sets ui.focus_search; SetKeyboardFocusHere(0) targets the
  -- next widget drawn (the search InputText below) for one frame
  if ui.focus_search then
    ImGui.SetKeyboardFocusHere(ctx, 0)
    ui.focus_search = false
  end
  local changed, new_val
  if ImGui.InputTextWithHint then
    changed, new_val = ImGui.InputTextWithHint(ctx, "##search", "Search...", search.query)
  else
    changed, new_val = ImGui.InputText(ctx, "##search", search.query)
  end
  if changed then
    search.query = new_val
    search.pending_time = reaper.time_precise() + SEARCH_DEBOUNCE_MS / 1000
  end
  -- Debounced filter (§12.3): only refilter after typing pause
  if search.pending_time > 0 and reaper.time_precise() >= search.pending_time then
    apply_filter()
    search.pending_time = 0
  end
  ImGui.PopItemWidth(ctx)
  ImGui.PopStyleColor(ctx, 2)  -- Col_FrameBg + Col_Text

  -- File count status line (like Media Explorer bottom status), with
  -- the Subfolders toggle inline on the right. Subfolders flattens the
  -- current folder + all subfolders into one list (BFS, capped at
  -- SUBFOLDERS_MAX_FILES / SUBFOLDERS_MAX_DEPTH for safety). Toggling
  -- triggers a rescan and resets nav state.
  local entries = get_display_entries()
  local count_str = #entries .. " items"
  if file_mgr.filtered then
    count_str = #file_mgr.filtered .. " / " .. #file_mgr.entries .. " items"
  end
  if file_mgr.recurse and file_mgr.scan_state then
    count_str = count_str .. " \xC2\xB7 scanning..."
  end
  -- Multi-select is Explorer-standard (Ctrl adds, Shift ranges) but nothing on
  -- screen said so, and plain-clicking rows looks like it "can't select more
  -- than one". Show the count of what IS selected, and how to select more.
  local sel_n = get_selected_count()
  if sel_n > 1 then
    count_str = count_str .. " \xC2\xB7 " .. sel_n .. " selected"
  else
    count_str = count_str .. " \xC2\xB7 Ctrl+click / Shift+click to select more"
  end
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x8C8C96FF)
  ImGui.Text(ctx, count_str)
  ImGui.PopStyleColor(ctx)
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx,
      "Ctrl+click     add/remove one file\n" ..
      "Shift+click    select a range\n" ..
      "Shift+Up/Down  extend with the keyboard\n\n" ..
      "Drag a multi-selection onto the plugin's pads to fill\n" ..
      "consecutive pads from wherever you drop.")
  end

  ImGui.SameLine(ctx)
  -- Right-align the Subfolders checkbox (rough — leaves room for ~120px)
  local row_w = ImGui.GetContentRegionAvail(ctx)
  if row_w > 100 then
    ImGui.SameLine(ctx, 0, row_w - 100)
  end
  local rec_changed, rec_new = ImGui.Checkbox(ctx, "Subfolders##recurse", file_mgr.recurse == true)
  if rec_changed then
    file_mgr.recurse = rec_new
    settings.recurse_subfolders = rec_new
    save_settings()
    -- Rescan from current root with the new mode
    if file_mgr.current_path ~= "" then
      scan_directory(file_mgr.current_path)
    end
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Flatten this folder + all subfolders into one list.\nCategories sidebar counts samples across the whole tree.\nSafety caps: " .. SUBFOLDERS_MAX_FILES .. " files / " .. SUBFOLDERS_MAX_DEPTH .. " levels deep.")
  end
end

local function draw_shortcuts_panel(ctx)
  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  if avail_h < 1 then return end
  local visible = ImGui.BeginChild(ctx, "##shortcuts_panel", -1, avail_h, ImGui.ChildFlags_Border)
  if visible then

    -- KITS section (top of sidebar, with thumbnails)
    if settings.show_kits then
      if kit_browser.needs_scan then scan_kits() end
      ImGui.SetNextItemOpen(ctx, settings.kits_open ~= false, ImGui.Cond_Once)
      local kits_open = ImGui.CollapsingHeader(ctx, "Kits")
      if kits_open ~= (settings.kits_open ~= false) then
        settings.kits_open = kits_open
        save_settings()
      end
      -- Right-click header context menu
      if ImGui.BeginPopupContextItem(ctx, "##kits_hdr_ctx") then
        if ImGui.MenuItem(ctx, "Refresh Kits") then kit_browser.needs_scan = true end
        if ImGui.MenuItem(ctx, "Open Kits Folder") then
          reaper.CF_ShellExecute(get_kits_dir())
        end
        if ImGui.MenuItem(ctx, "Hide Kits") then settings.show_kits = false; save_settings() end
        ImGui.EndPopup(ctx)
      end
      if kits_open then
        -- Kit-categories ④ LOAD/FILL toggle — at the TOP of the section (user
        -- request 2026-07-27: no scrolling past the kit list to reach it).
        -- OFF = the kit lands exactly as its author laid it out (the default
        -- forever); ON = FILL — category-match the kit's samples onto THIS
        -- rack's pad layout. Applies to the LOAD/FILL button AND double-click
        -- loads (both route through load_kit_from_browser).
        local fill_rv, fill_now = ImGui.Checkbox(ctx, "Fill my layout",
          settings.kit_fill_mode == true)
        if fill_rv then settings.kit_fill_mode = fill_now; save_settings() end
        if ImGui.IsItemHovered(ctx) then
          ImGui.SetTooltip(ctx,
            "OFF — LOAD: the kit lands exactly as its author laid it out.\n" ..
            "ON  — FILL: each of YOUR pads pulls the kit sample matching its\n" ..
            "category; your layout, categories and notes stay put.")
        end
        if #kit_browser.kits == 0 then
          ImGui.TextDisabled(ctx, "No kits found")
          ImGui.TextDisabled(ctx, "Save a kit first")
        else
          -- Clamp selected_idx if list changed
          if kit_browser.selected_idx > #kit_browser.kits then
            kit_browser.selected_idx = 0
          end
          for i, kit in ipairs(kit_browser.kits) do
            -- Thumbnail (32x32) or placeholder
            local img = get_kit_image(ctx, kit)
            if img then
              ImGui.Image(ctx, img, 32, 32)
            else
              -- Colored placeholder: hash name to hue, draw via DrawList
              local dl = ImGui.GetWindowDrawList(ctx)
              local cx, cy = ImGui.GetCursorScreenPos(ctx)
              local hue = 0
              for ci = 1, #kit.name do hue = hue + kit.name:byte(ci) end
              hue = (hue % 360) / 360.0
              local r, g, b = core.hsl_to_rgb(hue, 0.5, 0.4)
              local col = ImGui.ColorConvertDouble4ToU32(r, g, b, 1.0)
              ImGui.DrawList_AddRectFilled(dl, cx, cy, cx + 32, cy + 32, col, 4)
              -- Center first letter
              local letter = kit.name:sub(1, 1):upper()
              local tw = ImGui.CalcTextSize(ctx, letter)
              ImGui.DrawList_AddText(dl, cx + (32 - tw) * 0.5, cy + 8, 0xFFFFFFFF, letter)
              ImGui.Dummy(ctx, 32, 32)
            end
            ImGui.SameLine(ctx)
            -- Kit name: click to select (preview), not load
            local is_selected = (i == kit_browser.selected_idx)
            local is_loaded   = (kit.name == kit_db.kit_name)
            if is_loaded then
              ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x80C0FFFF)
            end
            if ImGui.Selectable(ctx, kit.name .. "##kit" .. i, is_selected, 0, 0, 20) then
              kit_browser.selected_idx = i
            end
            if is_loaded then
              ImGui.PopStyleColor(ctx)
            end
            -- Double-click to load immediately
            if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
              load_kit_from_browser(kit.path)
            end
            if ImGui.IsItemHovered(ctx) then
              local tip = kit.path
              if is_loaded then tip = tip .. "  [LOADED]" end
              ImGui.SetTooltip(ctx, tip)
            end
          end
          -- LOAD KIT button (below list; the Fill toggle lives at the TOP of
          -- the section — see above the kit-count check)
          ImGui.Spacing(ctx)
          local sel_kit = kit_browser.kits[kit_browser.selected_idx]
          if sel_kit then
            local is_already_loaded = (sel_kit.name == kit_db.kit_name)
            local btn_verb = settings.kit_fill_mode and "FILL"
              or (is_already_loaded and "RELOAD" or "LOAD KIT")
            local btn_label = btn_verb .. " \xE2\x86\x92 " .. sel_kit.name
            if ImGui.Button(ctx, btn_label, -1, 24) then
              load_kit_from_browser(sel_kit.path)
            end
          else
            ImGui.BeginDisabled(ctx)
            ImGui.Button(ctx, "Select a kit above", -1, 24)
            ImGui.EndDisabled(ctx)
          end
        end
      end
    end

    -- CATEGORIES section — TK Media Browser style. Counts samples in the
    -- current folder by drum-type heuristic (categorizer). Click a row to
    -- filter the file list to just that category; click again to clear.
    if settings.show_categories then
      ImGui.SetNextItemOpen(ctx, settings.categories_open ~= false, ImGui.Cond_Once)
      local categories_open = ImGui.CollapsingHeader(ctx, "Categories")
      if categories_open ~= (settings.categories_open ~= false) then
        settings.categories_open = categories_open
        save_settings()
      end
      if ImGui.BeginPopupContextItem(ctx, "##cat_hdr_ctx") then
        if ImGui.MenuItem(ctx, "Clear filter") then
          file_mgr.category_filter = nil
          apply_filter()
        end
        if ImGui.MenuItem(ctx, "Hide Categories") then
          settings.show_categories = false; save_settings()
        end
        ImGui.EndPopup(ctx)
      end
      if categories_open then
        -- Compute counts from current folder entries (cheap — runs once
        -- per frame, only iterates entries already loaded into memory)
        local cat_counts = {}
        local total_files = 0
        for _, e in ipairs(file_mgr.entries) do
          if not e.is_dir then
            local c = e.category or "other"
            cat_counts[c] = (cat_counts[c] or 0) + 1
            total_files = total_files + 1
          end
        end
        -- "All" row clears filter
        local all_label = string.format("All (%d)##cat_all", total_files)
        if ImGui.Selectable(ctx, all_label, file_mgr.category_filter == nil) then
          file_mgr.category_filter = nil
          apply_filter()
        end
        -- One row per category in the canonical order, with count + dot
        for _, cat in ipairs(categorizer.get_category_order()) do
          local count = cat_counts[cat] or 0
          if count > 0 then
            local color = categorizer.get_category_color(cat)
            -- Colored dot (small filled circle) + label + count
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, color)
            ImGui.Text(ctx, "\xE2\x97\x8F")  -- ●
            ImGui.PopStyleColor(ctx)
            ImGui.SameLine(ctx, nil, 6)
            local label = string.format("%s (%d)##cat_%s",
              cat:sub(1,1):upper() .. cat:sub(2), count, cat)
            local is_active = file_mgr.category_filter == cat
            if ImGui.Selectable(ctx, label, is_active) then
              file_mgr.category_filter = is_active and nil or cat
              apply_filter()
            end
          end
        end
        if cat_counts["other"] and cat_counts["other"] > 0 then
          -- "other" rendered last (already gets its turn in the order
          -- iteration; this comment just documents the ordering choice)
        end
      end
    end

    -- SHORTCUTS section (REAPER Media Explorer style)
    if settings.show_shortcuts then
      ImGui.SetNextItemOpen(ctx, settings.shortcuts_open ~= false, ImGui.Cond_Once)
      local shortcuts_open = ImGui.CollapsingHeader(ctx, "Shortcuts")
      if shortcuts_open ~= (settings.shortcuts_open ~= false) then
        settings.shortcuts_open = shortcuts_open
        save_settings()
      end
      -- Right-click header to hide (must be outside the open-check so it works when collapsed too)
      if ImGui.BeginPopupContextItem(ctx, "##shortcuts_hdr_ctx") then
        if ImGui.MenuItem(ctx, "Hide Shortcuts") then settings.show_shortcuts = false; save_settings() end
        ImGui.EndPopup(ctx)
      end
      if shortcuts_open then
        -- Desktop (OneDrive-redirection aware on Windows)
        local desktop = resolve_user_dir("Desktop")
        if ImGui.Selectable(ctx, "\xF0\x9F\x93\x81 Desktop##sc_desktop") then
          navigate_to(desktop)
        end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, desktop) end

        -- Downloads (Downloads is rarely OneDrive-redirected, but use the
        -- same resolver so the behavior is consistent if a user has set it up)
        local downloads = resolve_user_dir("Downloads")
        if ImGui.Selectable(ctx, "\xF0\x9F\x93\x81 Downloads##sc_downloads") then
          navigate_to(downloads)
        end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, downloads) end

        -- Project Directory
        local proj_path = reaper.GetProjectPath()
        if proj_path and proj_path ~= "" then
          if ImGui.Selectable(ctx, "\xF0\x9F\x93\x81 Project Directory##sc_proj") then
            navigate_to(proj_path)
          end
          if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, proj_path) end
        end

        -- REAPER Resource Path
        local res_path = reaper.GetResourcePath()
        if ImGui.Selectable(ctx, "\xF0\x9F\x93\x81 REAPER Resources##sc_res") then
          navigate_to(res_path)
        end
        if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, res_path) end

        -- Drives (Windows) or root (Mac/Linux)
        if is_windows then
          for _, letter in ipairs({"C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z"}) do
            local drive = letter .. ":\\"
            -- Check if drive exists
            if reaper.EnumerateSubdirectories(drive, 0) ~= nil or reaper.EnumerateFiles(drive, 0) ~= nil then
              if ImGui.Selectable(ctx, "\xF0\x9F\x92\xBF " .. letter .. ":\\##drv_" .. letter) then
                navigate_to(drive)
              end
            end
          end
        else
          if ImGui.Selectable(ctx, "\xF0\x9F\x93\x81 /##sc_root") then
            navigate_to("/")
          end
        end
      end
    end

    -- FAVORITES section
    if settings.show_favorites then
      ImGui.SetNextItemOpen(ctx, settings.favorites_open ~= false, ImGui.Cond_Once)
      local favorites_open = ImGui.CollapsingHeader(ctx, "Favorites")
      if favorites_open ~= (settings.favorites_open ~= false) then
        settings.favorites_open = favorites_open
        save_settings()
      end
      if ImGui.BeginPopupContextItem(ctx, "##favorites_hdr_ctx") then
        if ImGui.MenuItem(ctx, "Hide Favorites") then settings.show_favorites = false; save_settings() end
        ImGui.EndPopup(ctx)
      end
      if favorites_open then
        for i, fav in ipairs(file_mgr.favorites) do
          if ImGui.Selectable(ctx, fav.name .. "##fav" .. i) then
            navigate_to(fav.path)
          end
          if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, fav.path)
          end
        end
        if #file_mgr.favorites == 0 then
          ImGui.TextDisabled(ctx, "Right-click folder > Add to Favorites")
        end
      end
    end

    -- RECENT section
    if settings.show_recent then
      ImGui.SetNextItemOpen(ctx, settings.recent_open ~= false, ImGui.Cond_Once)
      local recent_open = ImGui.CollapsingHeader(ctx, "Recent")
      if recent_open ~= (settings.recent_open ~= false) then
        settings.recent_open = recent_open
        save_settings()
      end
      if ImGui.BeginPopupContextItem(ctx, "##recent_hdr_ctx") then
        if ImGui.MenuItem(ctx, "Clear Recent") then file_mgr.recent_folders = {}; save_settings() end
        if ImGui.MenuItem(ctx, "Hide Recent") then settings.show_recent = false; save_settings() end
        ImGui.EndPopup(ctx)
      end
      if recent_open then
        for i, r in ipairs(file_mgr.recent_folders) do
          local rname = get_folder_name(r)
          if ImGui.Selectable(ctx, rname .. "##recent" .. i) then
            navigate_to(r)
          end
          if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, r)
          end
        end
        if #file_mgr.recent_folders == 0 then
          ImGui.TextDisabled(ctx, "No recent folders")
        end
      end
    end

    -- Show hidden sections (only appears when something is hidden)
    local any_hidden = not settings.show_kits or not settings.show_categories or not settings.show_shortcuts or not settings.show_favorites or not settings.show_recent
    if any_hidden then
      ImGui.Separator(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x8888AAFF)
      ImGui.Text(ctx, "Show:")
      ImGui.PopStyleColor(ctx)
      ImGui.SameLine(ctx)
      if not settings.show_kits then
        if ImGui.SmallButton(ctx, "Kits##show") then settings.show_kits = true; save_settings() end
        ImGui.SameLine(ctx)
      end
      if not settings.show_categories then
        if ImGui.SmallButton(ctx, "Categories##show") then settings.show_categories = true; save_settings() end
        ImGui.SameLine(ctx)
      end
      if not settings.show_shortcuts then
        if ImGui.SmallButton(ctx, "Shortcuts##show") then settings.show_shortcuts = true; save_settings() end
        ImGui.SameLine(ctx)
      end
      if not settings.show_favorites then
        if ImGui.SmallButton(ctx, "Favorites##show") then settings.show_favorites = true; save_settings() end
        ImGui.SameLine(ctx)
      end
      if not settings.show_recent then
        if ImGui.SmallButton(ctx, "Recent##show") then settings.show_recent = true; save_settings() end
        ImGui.SameLine(ctx)
      end
      ImGui.NewLine(ctx)
    end

  end -- if visible
  ImGui.EndChild(ctx)  -- §3.1: EndChild ALWAYS called, outside visible block
end

local function draw_file_table(ctx)
  local entries = get_display_entries()
  local flags = ImGui.TableFlags_Resizable
              | ImGui.TableFlags_RowBg
              | ImGui.TableFlags_ScrollY
              | ImGui.TableFlags_BordersInnerV
              | ImGui.TableFlags_SizingStretchProp
              | ImGui.TableFlags_Sortable
              | ImGui.TableFlags_SortTristate
              | ImGui.TableFlags_Hideable      -- right-click headers → show/hide column checklist
              | ImGui.TableFlags_Reorderable   -- drag headers to reorder columns

  local _, avail_h = ImGui.GetContentRegionAvail(ctx)
  -- Reserve space for preview panel below (info + waveform + transport)
  -- Clamp to 40px min — negative height + ScrollY corrupts ImGui child-window stack
  local table_h = math.max(40, avail_h - 160)

  -- Selected rows are coloured per-row via TableSetBgColor (RowBg0). A
  -- Selectable ALSO fills with Col_Header when selected, and the theme sets
  -- that to the opaque panel colour — which painted straight over the row
  -- colour and made a multi-selection nearly invisible. Transparent here lets
  -- the row colours read; hover/active still give their normal feedback.
  ImGui.PushStyleColor(ctx, ImGui.Col_Header, 0x00000000)

  if ImGui.BeginTable(ctx, "##files", 9, flags, 0, table_h) then
    ImGui.TableSetupColumn(ctx, "Name",     ImGui.TableColumnFlags_WidthStretch | ImGui.TableColumnFlags_DefaultSort, 0.50)
    ImGui.TableSetupColumn(ctx, "Cat",      ImGui.TableColumnFlags_WidthFixed, 70)
    ImGui.TableSetupColumn(ctx, "Type",     ImGui.TableColumnFlags_WidthFixed, 42)
    ImGui.TableSetupColumn(ctx, "Ch",       ImGui.TableColumnFlags_WidthFixed, 30)
    ImGui.TableSetupColumn(ctx, "Size",     ImGui.TableColumnFlags_WidthFixed, 62)
    ImGui.TableSetupColumn(ctx, "Duration", ImGui.TableColumnFlags_WidthFixed, 58)
    ImGui.TableSetupColumn(ctx, "BPM",      ImGui.TableColumnFlags_WidthFixed, 40)
    ImGui.TableSetupColumn(ctx, "Key",      ImGui.TableColumnFlags_WidthFixed, 40)
    -- Root = detected fundamental of the sample itself, distinct from Key (a
    -- chromagram estimate of musical key). Blank whenever the detector's
    -- confidence gate declines — most drum hits genuinely have no root note.
    ImGui.TableSetupColumn(ctx, "Root",     ImGui.TableColumnFlags_WidthFixed, 44)
    ImGui.TableSetupScrollFreeze(ctx, 0, 1)
    ImGui.TableHeadersRow(ctx)

    -- Handle sort spec changes (header clicks)
    if ImGui.TableNeedSort(ctx) then
      local ok, col_idx, _, sort_dir = ImGui.TableGetColumnSortSpecs(ctx, 0)
      if ok then
        file_mgr.sort_column = col_idx + 1 -- ImGui is 0-based, ours is 1-based
        file_mgr.sort_ascending = (sort_dir == ImGui.SortDirection_Ascending)
        sort_entries()
        apply_filter()
      end
    end

    -- Arrow-key scroll: bring selected row into view before clipper starts
    if file_mgr.scroll_to_idx then
      local row_h = ImGui.GetTextLineHeightWithSpacing(ctx)
      local target_y = (file_mgr.scroll_to_idx - 1) * row_h
      local scroll_y = ImGui.GetScrollY(ctx)
      local visible_h = ImGui.GetWindowHeight(ctx) - row_h  -- minus header
      if target_y < scroll_y then
        ImGui.SetScrollY(ctx, target_y)
      elseif target_y + row_h > scroll_y + visible_h then
        ImGui.SetScrollY(ctx, target_y + row_h - visible_h)
      end
      file_mgr.scroll_to_idx = nil
    end

    -- Render rows (ListClipper for performance — §5.3: reuse long-lived clipper)
    ImGui.ListClipper_Begin(ui.clipper, #entries)
    while ImGui.ListClipper_Step(ui.clipper) do
      local clip_start, clip_end = ImGui.ListClipper_GetDisplayRange(ui.clipper)
    for row = clip_start, clip_end - 1 do
        local e = entries[row + 1]
        if e then
          ImGui.TableNextRow(ctx)

          -- Multi-select visual states: default / hover (built-in) / selected / selected+focused
          local clicked_idx = row + 1
          local is_in_set  = file_mgr.selected_set[clicked_idx] == true
          local is_focused = file_mgr.focused_index == clicked_idx and is_in_set
          -- Strong, opaque-ish fills: selection has to be obvious at a glance
          -- across a long list. (These only actually show because Col_Header
          -- is pushed transparent for this table — see draw_file_table; the
          -- Selectable's own opaque fill used to paint straight over them.)
          if is_focused then
            ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, 0x4A90E2F0)  -- anchor: bright azure
          elseif is_in_set then
            ImGui.TableSetBgColor(ctx, ImGui.TableBgTarget_RowBg0, 0x3C7AC0D8)  -- selected: deep blue
          end

          -- Name column
          ImGui.TableSetColumnIndex(ctx, 0)
          -- Folder/file icon + color differentiation
          local icon
          if e.is_dir then
            local folder_color = (settings.theme == "light" or settings.theme == "eon") and 0xB08020FF or 0xE8B84DFF
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, folder_color)
            icon = "\xF0\x9F\x93\x81 "  -- 📁
          else
            icon = "\xF0\x9F\x8E\xB5 "  -- 🎵
          end
          -- In Subfolders mode, append the relative subdirectory path after
          -- the filename so duplicate names from different subfolders are
          -- distinguishable at a glance ("Kick.wav  ·  808/Kicks").
          local display_name = icon .. e.name
          if e.subfolder and e.subfolder ~= "" then
            display_name = display_name .. "   \xC2\xB7   " .. e.subfolder
          end
          local label = display_name .. "##row" .. row
          if ImGui.Selectable(ctx, label, is_in_set, ImGui.SelectableFlags_SpanAllColumns | ImGui.SelectableFlags_AllowDoubleClick) then
            -- Modifier-aware selection
            local mods = ImGui.GetKeyMods(ctx)
            if (mods & ImGui.Mod_Ctrl) ~= 0 then
              -- Ctrl+click: toggle individual item
              file_mgr.pending_deselect = 0
              if file_mgr.selected_set[clicked_idx] then
                file_mgr.selected_set[clicked_idx] = nil
              else
                file_mgr.selected_set[clicked_idx] = true
              end
            elseif (mods & ImGui.Mod_Shift) ~= 0 and file_mgr.range_anchor > 0 then
              -- Shift+click: range select from anchor to clicked
              file_mgr.pending_deselect = 0
              file_mgr.selected_set = {}
              local lo = math.min(file_mgr.range_anchor, clicked_idx)
              local hi = math.max(file_mgr.range_anchor, clicked_idx)
              for si = lo, hi do file_mgr.selected_set[si] = true end
            else
              -- Plain click (Windows Explorer behavior):
              -- Click on already-selected item: keep set on mouse-down (allows drag of group).
              -- Set pending_deselect — resolved on mouse-up (see below EndTable).
              -- Click on unselected item: immediately clear set.
              if file_mgr.selected_set[clicked_idx] and get_selected_count() > 1 then
                file_mgr.pending_deselect = clicked_idx
                file_mgr.pending_deselect_time = reaper.time_precise()
              else
                file_mgr.selected_set = {}
                file_mgr.selected_set[clicked_idx] = true
                file_mgr.pending_deselect = 0
              end
              file_mgr.range_anchor = clicked_idx
            end
            file_mgr.selected_index = clicked_idx   -- drives preview/waveform
            file_mgr.focused_index  = clicked_idx   -- brighter highlight

            -- Single click on file: generate waveform, auto-preview + analyze
            if not e.is_dir and is_native_audio(e.name) then
              generate_peaks(e.path, 800)
              if playback.auto_play then
                preview_play(e.path)
              end
              analyze_file(e.path)
            end

            -- Double click
            if ImGui.IsMouseDoubleClicked(ctx, 0) then
              file_mgr.pending_deselect = 0  -- cancel deferred deselect
              if e.is_dir then
                navigate_to(e.path)
              else
                local sel_count = get_selected_count()
                if sel_count > 1 then
                  load_selected_to_pads(false)  -- sequential fill (layer via button/menu)
                else
                  load_sample_to_pad(e.path, ui.target_pad)
                end
              end
            end
          end

          -- Drag source for audio files. The ImGui payload only reaches ImGui
          -- targets (the mini pad grid below); xdrag.begin_drag additionally arms
          -- the OS-level watcher so the same gesture can land on the JSFX
          -- pad grid, which ImGui payloads can never reach.
          if not e.is_dir and ImGui.BeginDragDropSource(ctx) then
            local drag_count = is_in_set and get_selected_count() or 1
            if drag_count > 1 then
              ImGui.SetDragDropPayload(ctx, "SWING_MULTI", e.path)
              ImGui.Text(ctx, drag_count .. " files")
            else
              ImGui.SetDragDropPayload(ctx, "SWING_FILE", e.path)
              ImGui.Text(ctx, e.name)
            end
            xdrag.begin_drag(e.path, drag_count > 1)
            ImGui.EndDragDropSource(ctx)
          end

          -- Right-click context menu (Media Explorer style)
          if ImGui.BeginPopupContextItem(ctx, "##ctx" .. row) then
            if not e.is_dir then
              local ctx_sel_count = get_selected_count()
              if ctx_sel_count > 1 then
                -- Multi-select context menu
                if ImGui.MenuItem(ctx, "Load " .. ctx_sel_count .. " to Pads " .. (ui.target_pad + 1) .. "+") then
                  load_selected_to_pads(false)
                end
                if ImGui.MenuItem(ctx, "Layer " .. ctx_sel_count .. " on Pad " .. (ui.target_pad + 1)) then
                  load_selected_to_pads(true)
                end
              else
                -- Single-file context menu
                local load_label = "Load to Pad " .. (ui.target_pad + 1)
                if ImGui.MenuItem(ctx, load_label) then
                  load_sample_to_pad(e.path, ui.target_pad)
                end

                -- Load to specific pad submenu
                if ImGui.BeginMenu(ctx, "Load to Pad...") then
                  for pi = 0, G.NUM_PADS - 1 do
                    local pi_name = read_pad_name(pi)
                    local pi_label = tostring(pi + 1)
                    if pi_name ~= "" then pi_label = pi_label .. " — " .. pi_name end
                    if ImGui.MenuItem(ctx, pi_label) then
                      load_sample_to_pad(e.path, pi)
                    end
                  end
                  ImGui.EndMenu(ctx)
                end
              end

              ImGui.Separator(ctx)

              -- Preview controls
              if ImGui.MenuItem(ctx, "Preview") then
                preview_play(e.path)
                generate_peaks(e.path, 800)
              end
              if playback.is_playing and playback.current_file == e.path then
                if ImGui.MenuItem(ctx, "Stop Preview") then
                  preview_stop()
                end
              end

              ImGui.Separator(ctx)

              -- Insert into project
              if ImGui.MenuItem(ctx, "Insert into Project") then
                reaper.InsertMedia(e.path, 0)
              end
              if ImGui.MenuItem(ctx, "Insert on New Track") then
                reaper.InsertMedia(e.path, 1)
              end

              ImGui.Separator(ctx)

              -- Import option for .sfz files (only kit format Swing supports)
              if e.ext:lower() == "sfz" then
                if ImGui.MenuItem(ctx, "Import as Kit...") then
                  import_start(e.path)
                end
                ImGui.Separator(ctx)
              end
            end

            -- Folder-specific options
            if e.is_dir then
              if ImGui.MenuItem(ctx, "Open") then navigate_to(e.path) end
              if ImGui.MenuItem(ctx, "Add to Favorites") then add_favorite(e.path) end
              ImGui.Separator(ctx)
            end

            -- Common options (files and folders)
            if reaper.CF_LocateInExplorer then
              if ImGui.MenuItem(ctx, "Show in Explorer") then
                reaper.CF_LocateInExplorer(e.path)
              end
            end

            -- Copy path
            if ImGui.MenuItem(ctx, "Copy Path") then
              ImGui.SetClipboardText(ctx, e.path)
            end

            ImGui.EndPopup(ctx)
          end

          -- Cat column — colored category text per file (TK Media Browser style).
          -- Folder rows show a dash. Audio files show their classified
          -- category (kick/snare/hihat/...) tinted by the category color
          -- so the column itself is the visual identity, not the filename.
          ImGui.TableSetColumnIndex(ctx, 1)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          else
            local cat = e.category or "other"
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, categorizer.get_category_color(cat))
            ImGui.Text(ctx, cat)
            ImGui.PopStyleColor(ctx)
          end

          -- Type column
          ImGui.TableSetColumnIndex(ctx, 2)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "DIR")
          else
            ImGui.Text(ctx, e.ext:upper())
          end

          -- Channel column (M / S / multi).  -1 = not analyzed yet.
          ImGui.TableSetColumnIndex(ctx, 3)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          elseif e.nch == 1 then
            ImGui.TextDisabled(ctx, "M")
          elseif e.nch == 2 then
            ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x66CCFFFF)  -- soft blue accent for stereo
            ImGui.Text(ctx, "S")
            ImGui.PopStyleColor(ctx)
          elseif e.nch and e.nch > 2 then
            ImGui.Text(ctx, tostring(e.nch))  -- e.g. 6 = 5.1, 8 = 7.1
          else
            ImGui.TextDisabled(ctx, "")  -- not analyzed yet
          end

          -- Size column
          ImGui.TableSetColumnIndex(ctx, 4)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          else
            ImGui.Text(ctx, format_size(e.size))
          end

          -- Duration column
          ImGui.TableSetColumnIndex(ctx, 5)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          else
            ImGui.Text(ctx, format_duration(e.duration))
          end

          -- BPM column
          ImGui.TableSetColumnIndex(ctx, 6)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          else
            local a = get_analysis(e.path)
            if a and a.analyzed then
              if a.bpm then
                ImGui.Text(ctx, tostring(a.bpm))
              else
                ImGui.TextDisabled(ctx, "—")
              end
            elseif a then
              ImGui.TextDisabled(ctx, "...")
            else
              ImGui.TextDisabled(ctx, "")
            end
          end

          -- Key column
          ImGui.TableSetColumnIndex(ctx, 7)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          else
            local a = get_analysis(e.path)
            if a and a.analyzed then
              if a.key then
                ImGui.Text(ctx, a.key)
              else
                ImGui.TextDisabled(ctx, "—")
              end
            elseif a then
              ImGui.TextDisabled(ctx, "...")
            else
              ImGui.TextDisabled(ctx, "")
            end
          end

          -- Root column (detected fundamental, e.g. "G#1")
          ImGui.TableSetColumnIndex(ctx, 8)
          if e.is_dir then
            ImGui.TextDisabled(ctx, "—")
          else
            local a = get_analysis(e.path)
            if a and a.analyzed then
              -- `false` means measured and genuinely unpitched; nil means the
              -- upgrade pass has not reached this entry yet.
              if a.root then
                local nm, oc = rootnote.note_name(a.root)
                ImGui.Text(ctx, string.format("%s%d", nm or "?", oc or 0))
              elseif a.root == false then
                ImGui.TextDisabled(ctx, "—")
              else
                ImGui.TextDisabled(ctx, "...")
              end
            elseif a then
              ImGui.TextDisabled(ctx, "...")
            else
              ImGui.TextDisabled(ctx, "")
            end
          end
          -- Pop folder color
          if e.is_dir then
            ImGui.PopStyleColor(ctx)
          end
        end -- if e
    end -- for row
    end -- while ListClipper_Step
    ImGui.ListClipper_End(ui.clipper)

    ImGui.EndTable(ctx)

    -- Deferred deselect (Windows Explorer behavior):
    -- On mouse-down on a selected item in multi-select, we kept the set.
    -- On mouse-up without dragging, reduce to just that item.
    -- Wait 300ms to avoid firing between the two clicks of a double-click.
    if file_mgr.pending_deselect > 0 then
      local elapsed = reaper.time_precise() - file_mgr.pending_deselect_time
      if ImGui.IsMouseDragging(ctx, 0) then
        -- Drag started: cancel deselect (user is dragging the multi-select)
        file_mgr.pending_deselect = 0
      elseif elapsed > 0.3 then
        -- Enough time passed without double-click or drag: deselect to single item
        local pd = file_mgr.pending_deselect
        file_mgr.selected_set = {}
        file_mgr.selected_set[pd] = true
        file_mgr.pending_deselect = 0
      end
    end

    -- Click empty space = deselect all
    if ImGui.IsWindowHovered(ctx) and ImGui.IsMouseClicked(ctx, 0)
       and not ImGui.IsAnyItemHovered(ctx) then
      clear_selection()
    end
  end

  ImGui.PopStyleColor(ctx)  -- Col_Header (pushed before BeginTable, always popped)
end

local function draw_waveform(ctx, x, y, w, h)
  local pb_ratio = nil
  if playback.is_playing and playback.length > 0 then
    pb_ratio = playback.position / playback.length
  end

  -- Spectral cache: rebuild lazily when the toggle is on AND the file or
  -- width changed. FFT is expensive — never compute every frame; cached
  -- result reused until next file selection or toggle invalidation.
  local spectral = nil
  if settings.spectral_view and waveform.cached_file ~= "" then
    if waveform.spectral_cached_file ~= waveform.cached_file
       or math.abs(waveform.spectral_cached_w - w) > w * 0.2 then
      waveform.spectral_data = calculate_spectral_data(waveform.cached_file, math.max(64, math.floor(w)))
      waveform.spectral_cached_file = waveform.cached_file
      waveform.spectral_cached_w    = w
    end
    spectral = waveform.spectral_data
  end

  widgets.draw_waveform(ctx, x, y, w, h, waveform.peaks, pb_ratio, {
    spectral     = spectral,
    grid_overlay = settings.grid_overlay,
    src_length   = waveform.src_length,
  })
end

local function draw_playback_bar(ctx)
  -- ── Preview panel (REAPER Media Explorer style) ──
  ImGui.Separator(ctx)

  -- Selected file info line
  local entries = get_display_entries()
  local sel = entries[file_mgr.selected_index]
  if sel and not sel.is_dir then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xBBBBC0FF)
    local info = sel.name
    if sel.duration and sel.duration > 0 then
      info = info .. "  |  " .. format_duration(sel.duration)
    end
    if sel.size and sel.size > 0 then
      info = info .. "  |  " .. format_size(sel.size)
    end
    local analysis = get_analysis(sel.path)
    if analysis and analysis.analyzed then
      if analysis.bpm then info = info .. "  |  " .. analysis.bpm .. " BPM" end
      if analysis.key then info = info .. "  |  " .. analysis.key end
    end
    ImGui.Text(ctx, info)
    ImGui.PopStyleColor(ctx)

    -- Measured character. Separate line and dimmer than the name row: these are
    -- derived labels, not file facts. SPACE is omitted on mono material rather
    -- than guessed — the axis needs stereo decorrelation to mean anything.
    local axes = get_axes(sel.path)
    if axes then
      local lbl = measure.derive_labels(axes)
      local parts = { lbl.band, lbl.transient, lbl.decay, lbl.tonality }
      if lbl.space then parts[#parts + 1] = lbl.space end
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x8A8A93FF)
      ImGui.Text(ctx, table.concat(parts, "  ·  "))
      ImGui.PopStyleColor(ctx)
    end
    -- Multi-load truncation warning
    if multi_load_status ~= "" then
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFAA44FF)  -- orange warning
      ImGui.Text(ctx, "  |  " .. multi_load_status)
      ImGui.PopStyleColor(ctx)
    end
  else
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x6C6C76FF)
    ImGui.Text(ctx, "No file selected")
    ImGui.PopStyleColor(ctx)
  end

  -- Waveform area (tall preview like REAPER Media Explorer)
  local avail_w = ImGui.GetContentRegionAvail(ctx)
  local wave_h = 80
  -- Generate peaks at actual render width (lazy — only if file changed or width drifted)
  if sel and not sel.is_dir and is_native_audio(sel.name) then
    generate_peaks(sel.path, math.floor(avail_w))
  end
  local cx, cy = ImGui.GetCursorScreenPos(ctx)
  draw_waveform(ctx, cx, cy, avail_w, wave_h)

  -- Invisible button over waveform for click-to-seek
  if ImGui.InvisibleButton(ctx, "##waveform_seek", avail_w, wave_h) then
    local mouse_x = ImGui.GetMousePos(ctx)
    local ratio = (mouse_x - cx) / avail_w
    ratio = math.max(0, math.min(1, ratio))
    preview_seek(ratio)
  end

  -- Transport controls — colored DAW-style buttons. Each push/pop is a
  -- 4-color block (Button + Hovered + Active + Text) to give clear
  -- visual identity:
  --   Rewind / Forward : neutral grey (no destructive/state action)
  --   Play             : green   (start playback)
  --   Pause            : amber   (hold state)
  --   Stop             : red     (stop / reset)

  -- Rewind |<
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x55555AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x6E6E76FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x40404AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,          0xFFFFFFFF)
  if ImGui.Button(ctx, "|<##rew", 28, 22) then
    preview_seek(0)
  end
  ImGui.PopStyleColor(ctx, 4)
  ImGui.SameLine(ctx, nil, 3)

  -- Play (green) — always starts playback. If already playing, restarts
  -- from the current position; if paused, resumes.
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x33A85AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x44C26EFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x278A48FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,          0xFFFFFFFF)
  if ImGui.Button(ctx, "Play##play", 38, 22) then
    if playback.is_paused then
      preview_toggle_pause()  -- resume from pause
    elseif sel and not sel.is_dir and is_native_audio(sel.name) then
      preview_play(sel.path)
      generate_peaks(sel.path, 400)
    end
  end
  ImGui.PopStyleColor(ctx, 4)
  ImGui.SameLine(ctx, nil, 3)

  -- Pause (amber) — separate button, only acts while playing.
  local can_pause = playback.is_playing and not playback.is_paused
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        can_pause and 0xE0A030FF or 0x55555AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, can_pause and 0xF2B546FF or 0x6E6E76FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  can_pause and 0xC08820FF or 0x40404AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,          0xFFFFFFFF)
  if ImGui.Button(ctx, "Pause##pause", 44, 22) then
    if playback.is_playing then preview_toggle_pause() end
  end
  ImGui.PopStyleColor(ctx, 4)
  ImGui.SameLine(ctx, nil, 3)

  -- Stop (red) — same swing-red as the Close button + JSFX CLEAR.
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0xCC2222FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xE63333FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0xAA1111FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,          0xFFFFFFFF)
  if ImGui.Button(ctx, "Stop##stop", 38, 22) then
    preview_stop()
  end
  ImGui.PopStyleColor(ctx, 4)
  ImGui.SameLine(ctx, nil, 3)

  -- Forward >|
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x55555AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x6E6E76FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x40404AFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text,          0xFFFFFFFF)
  if ImGui.Button(ctx, ">|##fwd", 28, 22) then
    if playback.length > 0 then
      preview_seek(1)
    end
  end
  ImGui.PopStyleColor(ctx, 4)

  ImGui.SameLine(ctx, nil, 6)

  -- Position display
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xAAAAAAFF)
  local pos_str = format_duration(playback.position) .. " / " .. format_duration(playback.length)
  ImGui.Text(ctx, pos_str)
  ImGui.PopStyleColor(ctx)

  ImGui.SameLine(ctx, nil, 12)

  -- Volume slider (wider, REAPER-style) — scale to 0-100 for display
  ImGui.PushItemWidth(ctx, 100)
  local vol_changed, new_pct = ImGui.SliderDouble(ctx, "##vol", playback.volume * 100, 0, 100, "Vol %.0f%%")
  if vol_changed then preview_set_volume(new_pct / 100) end
  -- Mouse-wheel adjustment when hovering the slider — 2% per detent,
  -- shift+wheel for fine 1%. Mirrors how knobs in the JSFX behave.
  if ImGui.IsItemHovered(ctx) then
    local wheel = ImGui.GetMouseWheel(ctx) or 0
    if wheel ~= 0 then
      local fine = (ImGui.GetKeyMods(ctx) or 0) & ImGui.Mod_Shift ~= 0
      local step = fine and 0.01 or 0.02
      preview_set_volume(playback.volume + (wheel > 0 and step or -step))
    end
  end
  -- Double-click resets to 80%
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
    preview_set_volume(0.8)
  end
  ImGui.PopItemWidth(ctx)

  ImGui.SameLine(ctx, nil, 8)

  -- Pitch slider — same interaction grammar as Vol (wheel to nudge, shift for
  -- fine, double-click to reset). Semitones, because that is how you think
  -- about whether a kick will sit; applies live to whatever is playing.
  ImGui.PushItemWidth(ctx, 92)
  local pit_changed, new_semi = ImGui.SliderDouble(ctx, "##pitch", playback.pitch, -24, 24, "Pitch %+.1f st")
  if pit_changed then preview_set_pitch(new_semi) end
  if ImGui.IsItemHovered(ctx) then
    local pwheel = ImGui.GetMouseWheel(ctx) or 0
    if pwheel ~= 0 then
      local pfine = (ImGui.GetKeyMods(ctx) or 0) & ImGui.Mod_Shift ~= 0
      local pstep = pfine and 0.1 or 1.0
      preview_set_pitch(playback.pitch + (pwheel > 0 and pstep or -pstep))
    end
    ImGui.SetTooltip(ctx, "Preview pitch in semitones.\n" ..
      "Wheel to nudge, Shift+wheel fine, double-click to reset.")
  end
  if ImGui.IsItemHovered(ctx) and ImGui.IsMouseDoubleClicked(ctx, 0) then
    preview_set_pitch(0)
  end
  ImGui.PopItemWidth(ctx)

  ImGui.SameLine(ctx, nil, 8)

  -- Loop toggle
  local loop_changed, new_loop = ImGui.Checkbox(ctx, "Loop", playback.loop)
  if loop_changed then
    playback.loop = new_loop
    if playback.preview then
      reaper.CF_Preview_SetValue(playback.preview, "B_LOOP", new_loop and 1 or 0)
    end
  end

  ImGui.SameLine(ctx, nil, 8)

  -- Auto-play toggle
  local ap_changed, new_ap = ImGui.Checkbox(ctx, "Auto", playback.auto_play)
  if ap_changed then playback.auto_play = new_ap end

  -- TK-style waveform display toggles. SPECTRAL = FFT-based per-pixel
  -- frequency-content coloring (warm = bass, cool = treble, exact TK
  -- gradient). GRID = proportional time-grid overlay (~80px main ticks
  -- + 4 sub-ticks per interval, like TK). Both off by default to keep
  -- the preview minimal; user opts in.
  ImGui.SameLine(ctx, nil, 12)
  local sp_changed, sp_on = ImGui.Checkbox(ctx, "Spectral##spectral_view", settings.spectral_view == true)
  if sp_changed then
    settings.spectral_view = sp_on
    -- Invalidate cached spectral so the next draw regenerates with
    -- whatever file is currently selected
    waveform.spectral_data = {}
    waveform.spectral_cached_file = ""
    save_settings()
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Color the waveform by frequency content\n(warm = bass, cool = treble — TK Media Browser style)")
  end
  ImGui.SameLine(ctx, nil, 8)
  local gr_changed, gr_on = ImGui.Checkbox(ctx, "Grid##grid_overlay", settings.grid_overlay == true)
  if gr_changed then
    settings.grid_overlay = gr_on
    save_settings()
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Show time-grid overlay on the waveform")
  end
end

-- ─── Pad-info strip ─────────────────────────────────────────────────────
-- Sits below the pad grid. Shows the targeted pad's MIDI trigger note
-- and lets the user change it via a popup picker. Picker writes a
-- per-pad action (set-note) which the browser-target Swing applies in
-- @block. Stays in sync because JSFX writes p_note back to gmem META.
local NOTE_PICKER_NAMES = { "C","C#","D","D#","E","F","F#","G","G#","A","A#","B" }

-- P4: pad actions post to the browser-target instance's INCMD mailbox
-- (replaces the retired GS_PAD_ACTION shared channel — per-instance and
-- undo-correct: the Swing adopt fires mark_dirty_pad). Resolves the
-- target's registry slot per call; silently no-ops when the instance has
-- no live slot (a dead/frozen target — the old channel went nowhere then
-- too). flag=2 = adopt + undo.
local function post_pad_action(region_off, pad, value)
  local inst = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  local slot = core.resolve_inst_slot(inst)
  if not slot then return end
  core.post_pad_incmd(slot, region_off, pad, value, 2)
end

-- Mute/Solo menu items keep TOGGLE feel: read the pad's current band state
-- and post the inverted SET (idempotent under echo/retry, unlike a toggle).
local function toggle_pad_ms(pad, ident_off, region_off)
  local inst = math.floor(reaper.gmem_read(G.INSTANCE) or 0)
  local slot = core.resolve_inst_slot(inst)
  if not slot then return end
  local cur = (reaper.gmem_read(G.INST_IDENT_BASE + slot * G.INST_IDENT_INST_STRIDE
    + pad * G.INST_IDENT_PAD_FIELDS + ident_off) or 0) > 0.5
  core.post_pad_incmd(slot, region_off, pad, cur and 0 or 1, 2)
end
local function draw_pad_info_strip(ctx)
  local pad = ui.target_pad or 0
  local cur_note = core.read_pad_note(pad)
  local note_label = core.midi_to_note_name(cur_note)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, string.format("Pad %d  ", pad + 1))
  if pad_playable(pad) then
    local name = read_pad_name(pad)
    if name and name ~= "" then
      ImGui.SameLine(ctx)
      ImGui.TextColored(ctx, widgets.colors.text_dim, name)
    end
  end
  ImGui.SameLine(ctx)
  ImGui.Text(ctx, "  Note:")
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, note_label .. " \xE2\x96\xBE##pad_note_btn", 80) then
    ImGui.OpenPopup(ctx, "##pad_note_picker")
  end
  if ImGui.IsItemHovered(ctx) then
    ImGui.SetTooltip(ctx, "Set MIDI trigger note for pad " .. (pad + 1))
  end
  if ImGui.BeginPopup(ctx, "##pad_note_picker") then
    -- 11 octaves × 12 notes; render in a 12-column grid for compactness.
    -- Default kit layout uses C1 as pad 1 (note 36), so center the picker
    -- there: show the C-1 .. C9 range with the current note highlighted.
    for octave = -1, 9 do
      for pitch = 0, 11 do
        local n = (octave + 1) * 12 + pitch
        if n >= 0 and n <= 127 then
          if pitch > 0 then ImGui.SameLine(ctx, nil, 2) end
          local label = NOTE_PICKER_NAMES[pitch + 1] .. octave .. "##nt" .. n
          local sel = (n == cur_note)
          if ImGui.Selectable(ctx, label, sel, 0, 32, 0) then
            post_pad_action(core.GMEM.INCMD_NOTE_OFF, pad, n)
            ImGui.CloseCurrentPopup(ctx)
          end
        end
      end
    end
    ImGui.EndPopup(ctx)
  end
end

local function draw_pad_grid(ctx)
  widgets.draw_pad_grid(ctx, {
    target_pad      = ui.target_pad,
    read_pad_name   = read_pad_name,
    pad_has_audio   = pad_playable,   -- tile "loaded" state: synth pads count
    get_pad_color   = get_pad_color_from_gmem,
    get_folder_name = get_folder_name,
    -- Live mute mirroring: JSFX writes effective-mute (mute || muted-by-solo)
    -- per pad to GS_PAD_MUTED_BASE every @gfx tick. Browser reads here so
    -- muted pads dim to match the JSFX UI.
    is_pad_muted    = function(p) return reaper.gmem_read(G.GS_PAD_MUTED_BASE + p) > 0 end,
    on_pad_click = function(p)
      ui.target_pad = p
      reaper.gmem_write(G.GS_PAD_SELECT_REQ, p)
      -- Trigger pad playback if it's playable (sample OR synth — the JSFX
      -- handler gates on pad_is_playable too)
      if pad_playable(p) then
        reaper.gmem_write(G.GS_PAD_TRIGGER, p)
      end
    end,
    on_pad_drop = function(p, payload, payload_type)
      -- The same gesture can only land once. The drag-out watcher re-tests the
      -- cursor at release so it normally declines a drop that ended in here,
      -- but with overlapping windows ImGui's hover and the OS hit-test can
      -- disagree — if the watcher already committed this tick, stand down.
      if xdrag.consumed_at and (reaper.time_precise() - xdrag.consumed_at) < 0.10 then
        return
      end
      if payload_type == "SWING_MULTI" then
        local is_alt = (ImGui.GetKeyMods(ctx) & ImGui.Mod_Alt) ~= 0
        local prev_target = ui.target_pad
        ui.target_pad = p
        reaper.gmem_write(G.GS_PAD_SELECT_REQ, p)
        if is_alt then
          load_selected_to_pads(true)   -- Alt+drop: layer on this pad
        else
          load_selected_to_pads(false)  -- Normal drop: sequential fill from this pad
        end
        ui.target_pad = prev_target
      else
        load_sample_to_pad(payload, p)
      end
    end,
    -- Right-click menu: per-pad mute / solo / reverse / set-note / open-FX.
    -- Pad actions post to the target instance's INCMD mailbox (P4); "Open
    -- in JSFX" runs Lua-side (TrackFX_Show on the targeted instance).
    on_pad_right_click = function(ctx_, p)
      ImGui.Text(ctx_, string.format("Pad %d", p + 1))
      ImGui.Separator(ctx_)
      if ImGui.MenuItem(ctx_, "Toggle Mute") then
        toggle_pad_ms(p, core.GMEM.IDENT_OFF_MUTE, core.GMEM.INCMD_MUTE_OFF)
      end
      if ImGui.MenuItem(ctx_, "Toggle Solo") then
        toggle_pad_ms(p, core.GMEM.IDENT_OFF_SOLO, core.GMEM.INCMD_SOLO_OFF)
      end
      if ImGui.MenuItem(ctx_, "Toggle Reverse") then
        post_pad_action(core.GMEM.INCMD_REV_OFF, p, 0)
      end
      ImGui.Separator(ctx_)
      if ImGui.BeginMenu(ctx_, "Set Trigger Note") then
        local cur = core.read_pad_note(p)
        for octave = -1, 9 do
          if ImGui.BeginMenu(ctx_, "Octave " .. octave) then
            for pitch = 0, 11 do
              local n = (octave + 1) * 12 + pitch
              if n >= 0 and n <= 127 then
                local label = NOTE_PICKER_NAMES[pitch + 1] .. octave
                if ImGui.MenuItem(ctx_, label, nil, n == cur) then
                  post_pad_action(core.GMEM.INCMD_NOTE_OFF, p, n)
                end
              end
            end
            ImGui.EndMenu(ctx_)
          end
        end
        ImGui.EndMenu(ctx_)
      end
      ImGui.Separator(ctx_)
      if ImGui.MenuItem(ctx_, "Open Targeted FX in REAPER") then
        -- If a browser-target is set (INSTANCE > 0), open that exact one.
        -- Else fall back to the first Swing found in the project, so the
        -- menu still does something useful on a fresh project where the
        -- user hasn't picked an instance yet.
        local target_id = math.floor(reaper.gmem_read(G.INSTANCE))
        local opened = false
        for tr in core.iter_all_tracks() do
          for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
            local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
            local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
            local is_swing = (retval and ident:find("DrumKit_ReaKit"))
                          or fname:find("DrumKit_ReaKit")
                          or fname:match("^JS: Swing")
                          or fname:match("Swing %— 16%-Pad")
            if is_swing then
              local id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
              local pick = (target_id > 0 and id == target_id) or (target_id <= 0 and not opened)
              if pick then
                reaper.TrackFX_Show(tr, fx, 3)  -- 3 = floating window (always shows, even if hidden)
                opened = true
                if target_id > 0 then break end
              end
            end
          end
          if opened and target_id > 0 then break end
        end
      end
    end,
  })

end

local function draw_pad_controls(ctx)
  -- Load button (multi-select aware)
  local entries = get_display_entries()
  local sel = entries[file_mgr.selected_index]
  local sel_count = get_selected_count()
  local layer_cnt = get_pad_layer_count(ui.target_pad)
  local has_audio = pad_has_audio(ui.target_pad)

  if sel_count > 1 then
    -- Multi-select: two buttons — LOAD (sequential) and LAYER (stack)
    local end_pad = math.min(ui.target_pad + sel_count, G.NUM_PADS)
    local load_label = "LOAD " .. sel_count .. " \xE2\x86\x92 PADS " .. (ui.target_pad + 1) .. "-" .. end_pad
    if ImGui.Button(ctx, load_label, -1, 26) then
      load_selected_to_pads(false)
    end
    -- Layer button: stack all on one pad (replaces from layer 0)
    local max_layers = 4
    if sel_count > max_layers then
      ImGui.BeginDisabled(ctx)
      local layer_label = "LAYER " .. sel_count .. " \xE2\x86\x92 PAD " .. (ui.target_pad + 1) .. " (MAX " .. max_layers .. ")"
      ImGui.Button(ctx, layer_label, -1, 26)
      ImGui.EndDisabled(ctx)
    else
      local layer_label = "LAYER " .. sel_count .. " \xE2\x86\x92 PAD " .. (ui.target_pad + 1)
      if ImGui.Button(ctx, layer_label, -1, 26) then
        load_selected_to_pads(true)
      end
    end
  else
    -- Single-file: primary LOAD button
    local can_load = sel and not sel.is_dir
    if not can_load then ImGui.BeginDisabled(ctx) end
    local load_label = "LOAD \xE2\x86\x92 PAD " .. (ui.target_pad + 1)
    if ImGui.Button(ctx, load_label, -1, 28) then
      if sel then load_sample_to_pad(sel.path, ui.target_pad) end
    end
    if not can_load then ImGui.EndDisabled(ctx) end

    -- Single-file: "+ LAYER" button (only when pad already has audio and not full)
    if has_audio and sel and not sel.is_dir then
      local max_layers = 4
      local next_layer = math.max(layer_cnt, 1)
      if next_layer < max_layers then
        local layer_label = "+ LAYER \xE2\x86\x92 PAD " .. (ui.target_pad + 1) .. " [" .. next_layer .. "/" .. max_layers .. "]"
        if ImGui.Button(ctx, layer_label, -1, 24) then
          load_layer_to_pad(sel.path, ui.target_pad, next_layer)
        end
      else
        ImGui.BeginDisabled(ctx)
        ImGui.Button(ctx, "LAYERS FULL (4/4)", -1, 24)
        ImGui.EndDisabled(ctx)
      end
    end
  end
end

-- ─── Keyboard shortcuts help dialog ────────────────────────────────────────
-- Modal opens on `?` / F1 or by clicking the title-row `?` button. The
-- shortcut list is split into four columns by category. None of the
-- single-letter shortcuts conflict with REAPER's defaults (S/Z/X/D/E/G/
-- U/L/N/Y/T/V/P/R/W/F/M are all REAPER actions in arrange-view focus —
-- avoided here by using B/C/H/I/O which are free).
local SHORTCUTS = {
  {section = "Playback", items = {
    {"Space",        "Play / Pause preview"},
    {"I",            "Toggle loop preview"},
  }},
  {section = "Navigation", items = {
    {"Up / Down",    "Navigate file list"},
    {"PgUp / PgDn",  "Page up / down (10 entries)"},
    {"Home / End",   "Jump to first / last"},
    {"Backspace",    "Up one folder"},
  }},
  {section = "Selection & Loading", items = {
    {"Enter",        "Load selected → active pad"},
    {"Shift+Enter",  "Layer selected on active pad"},
    {"Ctrl+A",       "Select all visible files"},
    {"Ctrl+F",       "Focus search box"},
  }},
  {section = "Filtering & Display", items = {
    {"1 – 9",        "Filter by category 1–9"},
    {"0",            "Clear category filter"},
    {"B",            "Toggle Subfolders mode"},
    {"C",            "Toggle Spectral coloring"},
    {"H",            "Toggle Grid overlay"},
    {"O",            "Dock / Undock browser"},
  }},
  {section = "Misc", items = {
    {"Esc",          "Clear search → clear filter → stop preview"},
    {"? or F1",      "Show this dialog"},
  }},
}

local function draw_shortcuts_dialog(ctx)
  if not ui.show_shortcuts_modal then return end
  ImGui.OpenPopup(ctx, "Keyboard Shortcuts##shortcuts_modal")
  ui.show_shortcuts_modal = false
end

local function draw_shortcuts_modal_body(ctx)
  -- Always-call BeginPopupModal even when not open — it manages its own
  -- visible/closed state via the popup ID. Triggered by OpenPopup above.
  local center_x, center_y = ImGui.Viewport_GetCenter(ImGui.GetMainViewport(ctx))
  ImGui.SetNextWindowPos(ctx, center_x, center_y, ImGui.Cond_Appearing, 0.5, 0.5)
  ImGui.SetNextWindowSize(ctx, 520, 480, ImGui.Cond_Appearing)
  local visible, _ = ImGui.BeginPopupModal(ctx, "Keyboard Shortcuts##shortcuts_modal",
                                           true, ImGui.WindowFlags_NoCollapse)
  if visible then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, widgets.colors.text_gold)
    ImGui.Text(ctx, "Swing Browser — Keyboard Shortcuts")
    ImGui.PopStyleColor(ctx)
    ImGui.Spacing(ctx); ImGui.Separator(ctx); ImGui.Spacing(ctx)

    for _, group in ipairs(SHORTCUTS) do
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFCC44FF)
      ImGui.Text(ctx, group.section)
      ImGui.PopStyleColor(ctx)
      if ImGui.BeginTable(ctx, "##sc_" .. group.section, 2,
                          ImGui.TableFlags_SizingFixedFit) then
        ImGui.TableSetupColumn(ctx, "key", ImGui.TableColumnFlags_WidthFixed, 120)
        ImGui.TableSetupColumn(ctx, "desc", ImGui.TableColumnFlags_WidthStretch)
        for _, sc in ipairs(group.items) do
          ImGui.TableNextRow(ctx)
          ImGui.TableSetColumnIndex(ctx, 0)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x66CCFFFF)
          ImGui.Text(ctx, sc[1])
          ImGui.PopStyleColor(ctx)
          ImGui.TableSetColumnIndex(ctx, 1)
          ImGui.Text(ctx, sc[2])
        end
        ImGui.EndTable(ctx)
      end
      ImGui.Spacing(ctx)
    end

    ImGui.Separator(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0x8888AAFF)
    ImGui.TextWrapped(ctx, "All single-letter shortcuts are chosen to NOT conflict with REAPER's main-section defaults (S/Z/X/D/E/G/U/L/N/Y/T/V/P/R/W/F/M).")
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, "Close (Esc)", 100, 24) or ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
      ImGui.CloseCurrentPopup(ctx)
    end

    ImGui.EndPopup(ctx)
  end
end

local function draw_empty_state(ctx)
  local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)

  ImGui.Dummy(ctx, 0, avail_h * 0.2)

  -- Center text
  local text = "No folder selected"
  local text_w = ImGui.CalcTextSize(ctx, text)
  ImGui.SetCursorPosX(ctx, (avail_w - text_w) * 0.5)
  ImGui.TextDisabled(ctx, text)

  ImGui.Spacing(ctx)
  local btn_text = "Browse for Folder"
  local btn_w = ImGui.CalcTextSize(ctx, btn_text) + 20
  ImGui.SetCursorPosX(ctx, (avail_w - btn_w) * 0.5)
  if ImGui.Button(ctx, btn_text, btn_w, 28) then
    browse_for_folder()
  end

  -- Show favorites / recent if any
  if #file_mgr.favorites > 0 or #file_mgr.recent_folders > 0 then
    ImGui.Spacing(ctx)
    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    if #file_mgr.favorites > 0 then
      local fav_label = "FAVORITES"
      ImGui.SetCursorPosX(ctx, (avail_w - ImGui.CalcTextSize(ctx, fav_label)) * 0.5)
      ImGui.TextDisabled(ctx, fav_label)
      for i, fav in ipairs(file_mgr.favorites) do
        local fw = ImGui.CalcTextSize(ctx, fav.name)
        ImGui.SetCursorPosX(ctx, (avail_w - fw) * 0.5)
        if ImGui.Selectable(ctx, fav.name .. "##emptyfav" .. i) then
          navigate_to(fav.path)
        end
      end
    end

    if #file_mgr.recent_folders > 0 then
      ImGui.Spacing(ctx)
      local rec_label = "RECENT"
      ImGui.SetCursorPosX(ctx, (avail_w - ImGui.CalcTextSize(ctx, rec_label)) * 0.5)
      ImGui.TextDisabled(ctx, rec_label)
      for i, r in ipairs(file_mgr.recent_folders) do
        local rn = get_folder_name(r)
        local rw = ImGui.CalcTextSize(ctx, rn)
        ImGui.SetCursorPosX(ctx, (avail_w - rw) * 0.5)
        if ImGui.Selectable(ctx, rn .. "##emptyrec" .. i) then
          navigate_to(r)
        end
      end
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- KEYBOARD SHORTCUTS
-- ═══════════════════════════════════════════════════════════════════════════════

local function handle_keys(ctx)
  -- When the shortcuts help modal is open, all browser shortcuts are
  -- suppressed. Otherwise Esc would close the modal AND clear the
  -- search box on the same press, and letter keys (B/C/H/I/O) would
  -- toggle browser settings invisibly behind the modal. ImGui's
  -- BeginPopupModal blocks mouse/focus, but our shortcut handler runs
  -- unconditionally — this gate matches the modal semantics for
  -- keyboard input. ImGui itself still handles Esc-to-close-modal
  -- because that runs in BeginPopupModal, not here.
  --
  -- Note: ui.show_shortcuts_modal is only TRUE for the single frame
  -- between request and OpenPopup (see draw_shortcuts_dialog). Once
  -- the popup is open, that flag is false but ImGui.IsPopupOpen
  -- returns true with the popup's ID.
  if ImGui.IsPopupOpen(ctx, "Keyboard Shortcuts##shortcuts_modal") then
    return
  end

  -- Most shortcuts skip when an input field has focus (search box, etc.)
  -- so the user can type letters into the search field without firing
  -- their toggle bindings. Letter shortcuts also require no modifier
  -- so Shift+letter / Ctrl+letter combos route through their own checks.
  local input_active = ImGui.IsAnyItemActive(ctx)
  local mods = ImGui.GetKeyMods(ctx)
  local plain = mods == 0

  -- Space = play/pause
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space) and not input_active then
    if playback.is_playing or playback.is_paused then
      preview_toggle_pause()
    else
      local entries = get_display_entries()
      local sel = entries[file_mgr.selected_index]
      if sel and not sel.is_dir and is_native_audio(sel.name) then
        preview_play(sel.path)
        generate_peaks(sel.path, 400)
      end
    end
  end

  -- Escape: clear search if focused, else clear category filter, else
  -- stop preview. Layered behavior — first Esc gets you out of search,
  -- second clears any active category filter, third stops audio.
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then
    if input_active then
      -- ImGui handles input deactivation; nothing to do
    elseif file_mgr.category_filter then
      file_mgr.category_filter = nil
      apply_filter()
    else
      preview_stop()
    end
  end

  -- Backspace = navigate back
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Backspace) and not input_active then
    navigate_back()
  end

  -- Ctrl+A = select all visible items
  if not input_active and (mods & ImGui.Mod_Ctrl) ~= 0 and ImGui.IsKeyPressed(ctx, ImGui.Key_A) then
    local entries = get_display_entries()
    file_mgr.selected_set = {}
    for i = 1, #entries do file_mgr.selected_set[i] = true end
  end

  -- Ctrl+F = focus search box. SetKeyboardFocusHere(0) targets the next
  -- widget drawn — we just request focus via a one-frame flag and the
  -- search input picks it up.
  if not input_active and (mods & ImGui.Mod_Ctrl) ~= 0 and ImGui.IsKeyPressed(ctx, ImGui.Key_F) then
    ui.focus_search = true
  end

  -- Up/Down = change selection (only when search isn't focused)
  if not ImGui.IsAnyItemActive(ctx) then
    local entries = get_display_entries()
    -- mods already captured at line 4102 (enclosing scope)
    if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow) then
      local new_idx = math.max(1, file_mgr.selected_index - 1)
      file_mgr.selected_index = new_idx
      if (mods & ImGui.Mod_Shift) ~= 0 then
        -- Shift+arrow: extend selection
        file_mgr.selected_set[new_idx] = true
      else
        -- Plain arrow: single-select
        file_mgr.selected_set = {}
        file_mgr.selected_set[new_idx] = true
        file_mgr.range_anchor = new_idx
      end
      file_mgr.focused_index = new_idx
      file_mgr.scroll_to_idx = new_idx
      local sel = entries[new_idx]
      if sel and not sel.is_dir and is_native_audio(sel.name) then
        generate_peaks(sel.path, 400)
        if playback.auto_play then preview_play(sel.path) end
      end
    end
    if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow) then
      local new_idx = math.min(#entries, file_mgr.selected_index + 1)
      file_mgr.selected_index = new_idx
      if (mods & ImGui.Mod_Shift) ~= 0 then
        file_mgr.selected_set[new_idx] = true
      else
        file_mgr.selected_set = {}
        file_mgr.selected_set[new_idx] = true
        file_mgr.range_anchor = new_idx
      end
      file_mgr.focused_index = new_idx
      file_mgr.scroll_to_idx = new_idx
      local sel = entries[new_idx]
      if sel and not sel.is_dir and is_native_audio(sel.name) then
        generate_peaks(sel.path, 400)
        if playback.auto_play then preview_play(sel.path) end
      end
    end

    -- Enter = open folder or load sample(s). Shift+Enter on multi-select
    -- stacks the selection as layers on the active pad (max 4).
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) then
      local sel_count = get_selected_count()
      local as_layers = (mods & ImGui.Mod_Shift) ~= 0
      if sel_count > 1 then
        load_selected_to_pads(as_layers)
      else
        local sel = entries[file_mgr.selected_index]
        if sel then
          if sel.is_dir then
            navigate_to(sel.path)
          else
            load_sample_to_pad(sel.path, ui.target_pad)
          end
        end
      end
    end

    -- Page Up / Page Down: jump 10 entries
    local page_step = 10
    if ImGui.IsKeyPressed(ctx, ImGui.Key_PageUp) then
      local new_idx = math.max(1, file_mgr.selected_index - page_step)
      file_mgr.selected_index = new_idx
      file_mgr.selected_set = {[new_idx] = true}
      file_mgr.range_anchor = new_idx
      file_mgr.focused_index = new_idx
      file_mgr.scroll_to_idx = new_idx
    end
    if ImGui.IsKeyPressed(ctx, ImGui.Key_PageDown) then
      local new_idx = math.min(#entries, file_mgr.selected_index + page_step)
      file_mgr.selected_index = new_idx
      file_mgr.selected_set = {[new_idx] = true}
      file_mgr.range_anchor = new_idx
      file_mgr.focused_index = new_idx
      file_mgr.scroll_to_idx = new_idx
    end

    -- Home / End: jump to first / last entry
    if ImGui.IsKeyPressed(ctx, ImGui.Key_Home) and #entries > 0 then
      file_mgr.selected_index = 1
      file_mgr.selected_set = {[1] = true}
      file_mgr.range_anchor = 1
      file_mgr.focused_index = 1
      file_mgr.scroll_to_idx = 1
    end
    if ImGui.IsKeyPressed(ctx, ImGui.Key_End) and #entries > 0 then
      local last = #entries
      file_mgr.selected_index = last
      file_mgr.selected_set = {[last] = true}
      file_mgr.range_anchor = last
      file_mgr.focused_index = last
      file_mgr.scroll_to_idx = last
    end
  end

  -- Plain-letter toggles. All gated by `plain` (no modifiers) and
  -- `not input_active` so typing in the search box doesn't fire them.
  if plain and not input_active then
    -- B = Subfolders mode
    if ImGui.IsKeyPressed(ctx, ImGui.Key_B) then
      file_mgr.recurse = not (file_mgr.recurse == true)
      settings.recurse_subfolders = file_mgr.recurse
      save_settings()
      if file_mgr.current_path ~= "" then scan_directory(file_mgr.current_path) end
    end
    -- C = Spectral coloring
    if ImGui.IsKeyPressed(ctx, ImGui.Key_C) then
      settings.spectral_view = not (settings.spectral_view == true)
      waveform.spectral_data = {}
      waveform.spectral_cached_file = ""
      save_settings()
    end
    -- H = Grid overlay
    if ImGui.IsKeyPressed(ctx, ImGui.Key_H) then
      settings.grid_overlay = not (settings.grid_overlay == true)
      save_settings()
    end
    -- I = Loop preview
    if ImGui.IsKeyPressed(ctx, ImGui.Key_I) then
      playback.loop = not playback.loop
      if playback.preview then
        reaper.CF_Preview_SetValue(playback.preview, "B_LOOP", playback.loop and 1 or 0)
      end
    end
    -- O = Dock toggle
    if ImGui.IsKeyPressed(ctx, ImGui.Key_O) then
      ui.pending_dock_id  = (settings.dock_id or 0) ~= 0 and 0 or -1
      ui.want_dock_change = true
    end
    -- 1..9 = category filter (uses categorizer.get_category_order())
    local cat_order = categorizer.get_category_order()
    for digit = 1, 9 do
      if ImGui.IsKeyPressed(ctx, ImGui["Key_" .. digit]) then
        local cat = cat_order[digit]
        if cat then
          file_mgr.category_filter = (file_mgr.category_filter == cat) and nil or cat
          apply_filter()
        end
      end
    end
    -- 0 = clear category filter
    if ImGui.IsKeyPressed(ctx, ImGui.Key_0) then
      file_mgr.category_filter = nil
      apply_filter()
    end
  end

  -- ? or F1 = shortcuts help dialog. Lives OUTSIDE the `plain` gate above
  -- because `?` on US layout is Shift+/, and `plain` requires zero
  -- modifiers — so the previous placement made `?` unreachable. F1 fires
  -- on plain F1 (no Ctrl/Alt); `?` fires when Shift+/ is pressed with no
  -- Ctrl/Alt. Both still respect `not input_active` so typing `?` into
  -- the search box doesn't pop the dialog.
  if not input_active then
    local ctrl_alt_mask = ImGui.Mod_Ctrl | ImGui.Mod_Alt
    local f1_ok = ImGui.IsKeyPressed(ctx, ImGui.Key_F1)
                  and (mods & ctrl_alt_mask) == 0
    local q_ok  = ImGui.IsKeyPressed(ctx, ImGui.Key_Slash)
                  and (mods & ImGui.Mod_Shift) ~= 0
                  and (mods & ctrl_alt_mask) == 0
    if f1_ok or q_ok then
      ui.show_shortcuts_modal = true
    end
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MAIN LOOP
-- ═══════════════════════════════════════════════════════════════════════════════

local function init()
  gmem_init()
  load_settings()

  -- Create ImGui context
  ui.ctx = ImGui.CreateContext(SCRIPT_NAME)

  -- Initial scan — default to a useful starting folder if no saved path
  if file_mgr.current_path == "" then
    -- Try common sample locations, fall back to user home
    local rp = reaper.GetResourcePath()
    local try_paths = {}
    if is_windows then
      local user = os.getenv("USERPROFILE") or ""
      table.insert(try_paths, resolve_user_dir("Desktop"))
      table.insert(try_paths, resolve_user_dir("Music"))
      table.insert(try_paths, resolve_user_dir("Documents"))
      table.insert(try_paths, user)
    else
      local home = os.getenv("HOME") or ""
      table.insert(try_paths, home .. "/Music")
      table.insert(try_paths, home .. "/Desktop")
      table.insert(try_paths, home)
    end
    table.insert(try_paths, rp)
    for _, p in ipairs(try_paths) do
      if p ~= "" and (reaper.EnumerateSubdirectories(p, 0) ~= nil or reaper.EnumerateFiles(p, 0) ~= nil) then
        file_mgr.current_path = p
        break
      end
    end
  end
  if file_mgr.current_path ~= "" then
    scan_directory(file_mgr.current_path)
  end

  -- Create long-lived ListClipper (§5.3 — one per context, not per frame)
  ui.clipper = ImGui.CreateListClipper(ui.ctx)
  ImGui.Attach(ui.ctx, ui.clipper)

  -- Signal browser running
  reaper.SetExtState("Swing", "browser_running", "1", false)
  reaper.gmem_write(G.GS_BROWSER_OPEN, 1)
  -- Initialize active instance routing — JSFX writes its instance_id to
  -- INSTANCE before issuing CMD 60. The browser keeps this pinned so the
  -- right Swing instance receives sample loads + pad-select events. If
  -- the user opened the browser via a path that didn't set INSTANCE
  -- (e.g. a hotkey action), auto-pick the first alive instance from the
  -- registry so the browser has SOMETHING to talk to. JSFX-side gate is
  -- now strict (INSTANCE == instance_id), so without this we'd show an
  -- empty browser until the user explicitly picked.
  active_inst_id = math.floor(reaper.gmem_read(G.INSTANCE))
  if active_inst_id == 0 then
    local now = reaper.time_precise()
    for s = 0, G.GS_INST_REG_MAX - 1 do
      local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
      local id        = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID))
      local heartbeat =            reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT)
      if id > 0 and heartbeat > 0 and (now - heartbeat) < G.GS_INST_REG_TIMEOUT then
        active_inst_id = id
        reaper.gmem_write(G.INSTANCE, id)
        break
      end
    end
  end
end

local function cleanup()
  xdrag.abort()   -- never leave an armed drag mailbox behind (gmem outlives us)
  preview_stop()
  save_settings()
  -- Save database if dirty
  if kit_db.dirty and kit_db.data then
    save_kit_database()
  end
  -- Flush BPM/key analysis cache (force-override the 1s debounce so
  -- recent analysis work isn't lost when user closes browser quickly).
  save_persistent_cache(true)
  reaper.SetExtState("Swing", "browser_running", "0", false)
  reaper.gmem_write(G.GS_BROWSER_VISIBLE, 0)
  reaper.gmem_write(G.GS_BROWSER_OPEN, 0)
  -- Release instance routing so any Swing instance can act on shared gmem
  -- once the browser is gone.
  reaper.gmem_write(G.INSTANCE, 0)
  active_inst_id = 0
  if core.hub_notify then core.hub_notify("close", "browser") end
end

local loop

local function frame()
  -- Check for close request from bridge or toggle script. We must run
  -- cleanup() before returning — otherwise browser_running ExtState
  -- stays "1" forever, gmem[GS_BROWSER_OPEN] stays 1, settings/cache
  -- aren't flushed, and the toggle script gets stuck thinking the
  -- browser is still running. Bare `return` here was a ship-blocker.
  if reaper.GetExtState("Swing", "browser_close") == "1" then
    reaper.SetExtState("Swing", "browser_close", "0", false)
    ui.is_open = false
    cleanup()
    return
  end

  -- Check for pending import file (from companion script or bridge)
  local pending_import = reaper.GetExtState("Swing", "import_file")
  if pending_import and pending_import ~= "" then
    reaper.SetExtState("Swing", "import_file", "", false)
    import_start(pending_import)
  end

  -- Check for pending RS5k rack import (from EON_SB_ImportRS5k companion). It
  -- writes the source track's 1-based number; we resolve + scan here so the
  -- whole import pipeline (dialog, load queue) stays inside the browser.
  local pending_rs5k = reaper.GetExtState("Swing", "import_rs5k_track")
  if pending_rs5k and pending_rs5k ~= "" then
    reaper.SetExtState("Swing", "import_rs5k_track", "", false)
    local tnum = tonumber(pending_rs5k)
    local track = tnum and reaper.GetTrack(0, tnum - 1) or nil
    rk_rs5k.import_start_rs5k(track)
  end

  -- Update preview position
  preview_update()

  -- Swing-presence gate (~1 Hz rescan): every Swing-coupled pane reads the
  -- shared gmem blob, which OUTLIVES the FX — after deleting the last Swing
  -- (or in a fresh project) the browser kept painting the previous
  -- instance's kit. Keyed on actual FX EXISTENCE in the active project, not
  -- on heartbeats (heartbeats stall whenever the audio device closes).
  -- Stored on `ui` (no new chunk locals). Detection matches the FX-window
  -- toggle's is_swing test below.
  do
    local now_t = reaper.time_precise()
    if (ui.swing_check_t or 0) + 1.0 < now_t then
      ui.swing_check_t = now_t
      ui.swing_present = false
      for ti = 0, reaper.CountTracks(0) - 1 do
        local tr = reaper.GetTrack(0, ti)
        for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
          local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
          local rv, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
          if (rv and ident:find("DrumKit_ReaKit")) or fname:find("DrumKit_ReaKit")
             or fname:match("^JS: Swing") or fname:match("Swing %— 16%-Pad") then
            ui.swing_present = true
            break
          end
        end
        if ui.swing_present then break end
      end
      -- Identity rollout (2026-07-08): revalidate the routing target. An
      -- instance id can be re-minted mid-session (duplicate duel in the JSFX
      -- reconciler) — a cached id then mistargets every sample load/pad
      -- action forever. Key on ID PRESENCE in the registry, NOT heartbeat
      -- freshness (heartbeats freeze whenever the audio device closes — the
      -- app-focus disease). Absent id → re-pick first alive instance.
      if active_inst_id > 0 and ui.swing_present then
        local id_present = false
        for s = 0, G.GS_INST_REG_MAX - 1 do
          local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
          if math.floor(reaper.gmem_read(base) or 0) == active_inst_id then
            id_present = true
            break
          end
        end
        if not id_present then
          local stale_id = active_inst_id
          active_inst_id = 0
          -- Only release the shared routing cell if it still carries OUR
          -- stale id (another surface may have already re-pointed it).
          if math.floor(reaper.gmem_read(G.INSTANCE) or 0) == stale_id then
            reaper.gmem_write(G.INSTANCE, 0)
          end
          for s = 0, G.GS_INST_REG_MAX - 1 do
            local base = G.GS_INST_REG_BASE + s * G.GS_INST_REG_STRIDE
            local id        = math.floor(reaper.gmem_read(base + G.GS_INST_REG_OFF_ID) or 0)
            local heartbeat =            reaper.gmem_read(base + G.GS_INST_REG_OFF_HEARTBEAT) or 0
            if id > 0 and heartbeat > 0 and (now_t - heartbeat) < G.GS_INST_REG_TIMEOUT then
              active_inst_id = id
              reaper.gmem_write(G.INSTANCE, id)
              break
            end
          end
        end
      end
    end
  end

  local ctx = ui.ctx
  push_theme(ctx)

  local window_flags = ImGui.WindowFlags_NoCollapse

  -- Read target pad from gmem each frame
  ui.target_pad = math.floor(reaper.gmem_read(G.GS_BROWSE_PAD))
  if ui.target_pad < 0 then ui.target_pad = 0 end
  if ui.target_pad > 15 then ui.target_pad = 15 end

  if ui.target_pad ~= ui.prev_target_pad then
    ui.prev_target_pad = ui.target_pad
  end

  -- Process queued BPM/Key analysis (incremental, 2 files per frame)
  process_analysis_queue()

  -- Persist analysis cache to disk (self-debounces to ~1Hz)
  save_persistent_cache()

  -- Process incremental directory scan (200 entries per frame)
  if file_mgr.scan_state then process_scan_queue() end

  -- Process deferred file metadata (size + duration, 4 per frame)
  process_metadata_queue()

  -- Process import load queue (one pad per frame)
  process_import_queue()

  -- Track a drag that has left the browser window (EON_DRAG). Must run here,
  -- outside the ImGui Begin/End, so it keeps ticking while the cursor is over
  -- the plugin instead of over us.
  xdrag.update()

  -- Process multi-load queue (one item per frame, wait for CMD to clear).
  -- Only remove the item after the load function confirms success —
  -- prevents dropped pads if a CMD/LOCK race causes an early return.
  if #multi_load_queue > 0 and math.floor(reaper.gmem_read(G.CMD)) == 0
     and math.floor(reaper.gmem_read(G.LOCK)) == 0 then
    local item = multi_load_queue[1]
    -- Items carrying an explicit target (drag-drop onto a specific instance)
    -- re-assert it here: the load routes by gmem[INSTANCE] at THIS moment,
    -- which may be several frames after the item was queued. Items without
    -- one keep the historical behaviour of following the current binding.
    if item.inst_id and item.inst_id > 0 and item.inst_id ~= active_inst_id then
      active_inst_id = item.inst_id
      reaper.gmem_write(G.INSTANCE, active_inst_id)
    end
    local ok
    if item.is_layer then
      ok = load_layer_to_pad(item.filepath, item.pad_idx, item.layer)
    else
      ok = load_sample_to_pad(item.filepath, item.pad_idx)
    end
    if ok then
      table.remove(multi_load_queue, 1)
    end
  end

  -- Auto-refresh kit list after bridge saves a kit
  if reaper.GetExtState("Swing", "kit_saved") == "1" then
    reaper.SetExtState("Swing", "kit_saved", "", false)
    kit_browser.needs_scan = true
  end

  -- Read kit name from gmem each frame
  kit_db.kit_name = read_kit_name_from_gmem()

  -- Detect kit name change → reload database
  if kit_db.kit_name ~= kit_db.prev_name then
    on_kit_name_change(kit_db.kit_name)
  end

  -- Set initial size on first frame
  if ui.first_frame then
    ImGui.SetNextWindowSize(ctx, settings.window_w, settings.window_h, ImGui.Cond_Appearing)
    -- Restore dock state from settings on first frame. Cond_Always so the
    -- saved dock takes effect even if ImGui has its own remembered layout.
    if ImGui.SetNextWindowDockID and (settings.dock_id or 0) ~= 0 then
      ImGui.SetNextWindowDockID(ctx, settings.dock_id, ImGui.Cond_Always)
    end
    ui.first_frame = false
  elseif ui.want_dock_change and ImGui.SetNextWindowDockID then
    -- User clicked the Dock toggle — apply the pending dock change.
    ImGui.SetNextWindowDockID(ctx, ui.pending_dock_id, ImGui.Cond_Always)
    settings.dock_id     = ui.pending_dock_id
    ui.want_dock_change  = false
  end

  -- Window title includes kit name + track number so user knows which instance this controls.
  -- Track number derives from the user's browser-target pick (KIT_GMEM_INSTANCE),
  -- not the bridge's find_swing_track guess (which doesn't honor the picker
  -- and would always show the first Swing). Falls back to the bridge value
  -- if no instance is targeted yet (e.g. fresh project before any pick).
  --
  -- Cache the track-scan result keyed by current_target. The full enumeration
  -- across all tracks + their FX is expensive (O(tracks×fx) every frame at
  -- 60Hz on large projects) and the result rarely changes — only when user
  -- picks a different instance or rearranges tracks. Invalidate every 2s
  -- as a safety net in case track number changed.
  local title_kit = kit_db.kit_name ~= "" and (" — " .. kit_db.kit_name) or ""
  local current_target = math.floor(reaper.gmem_read(G.INSTANCE))
  local track_num = 0
  local now_ts = reaper.time_precise()
  if current_target > 0 then
    if title_track_cache_target == current_target and (now_ts - title_track_cache_at < 2.0) then
      track_num = title_track_cache_value
    else
      for tr in core.iter_all_tracks() do
        local found = false
        for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
          local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
          local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
          local is_swing = (retval and ident:find("DrumKit_ReaKit"))
                        or fname:find("DrumKit_ReaKit")
                        or fname:match("^JS: Swing")
                        or fname:match("Swing %— 16%-Pad")
          if is_swing then
            local id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
            if id == current_target then
              track_num = math.floor(reaper.GetMediaTrackInfo_Value(tr, "IP_TRACKNUMBER"))
              found = true
              break
            end
          end
        end
        if found then break end
      end
      title_track_cache_target = current_target
      title_track_cache_value  = track_num
      title_track_cache_at     = now_ts
    end
  end
  if track_num == 0 then track_num = math.floor(reaper.gmem_read(G.GS_TRACK_NUM)) end
  local title_track = track_num > 0 and (" [Track " .. track_num .. "]") or ""
  ImGui.SetNextWindowSizeConstraints(ctx, 500, 350, 99999, 99999)
  local visible, open = ImGui.Begin(ctx, SCRIPT_NAME .. " v" .. VERSION .. title_kit .. title_track .. "###swing_browser", true, window_flags)
  ui.is_open = open
  reaper.gmem_write(G.GS_BROWSER_VISIBLE, visible and 1 or 0)

  if visible then
    -- Store window size for settings
    settings.window_w, settings.window_h = ImGui.GetWindowSize(ctx)

    -- Red left border (3px, Swing signature red)
    local wx, wy = ImGui.GetWindowPos(ctx)
    local wh = settings.window_h
    local draw_list = ImGui.GetWindowDrawList(ctx)
    ImGui.DrawList_AddRectFilled(draw_list, wx, wy, wx + 3, wy + wh, widgets.colors.swing_red)

    -- Theme dropdown (Dark / Light / EON cream)
    local THEME_OPTS = { {"eon", "EON"}, {"dark", "Dark"}, {"light", "Light"},
                         {"reaper", "REAPER"}, {"reaper_panel", "REAPER Panel"}, {"reaper_color", "REAPER Color"},
                         {"ssl", "SSL"}, {"neve", "Neve"}, {"api", "API"}, {"tube", "Tube"},
                         {"ableton", "Ableton"}, {"fl", "FL Studio"}, {"protools", "Pro Tools"},
                         {"protools_light", "PT Light"} }
    local theme_label = "Dark"
    for _, o in ipairs(THEME_OPTS) do
      if settings.theme == o[1] then theme_label = o[2] end
    end
    if ImGui.Button(ctx, theme_label .. "##theme", 54, 22) then
      ImGui.OpenPopup(ctx, "theme_menu")
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Theme")
      local _wv = ImGui.GetMouseWheel(ctx)   -- hover + mouse-wheel cycles through themes
      if _wv ~= 0 then
        local _i = 1; for k, o in ipairs(THEME_OPTS) do if settings.theme == o[1] then _i = k end end
        _i = ((_i - 1 + (_wv > 0 and 1 or -1)) % #THEME_OPTS) + 1
        settings.theme = THEME_OPTS[_i][1]
        reaper.SetExtState("Swing", "eon_theme", settings.theme, true)
        save_settings()
      end
    end
    if ImGui.BeginPopup(ctx, "theme_menu") then
      for _, o in ipairs(THEME_OPTS) do
        if ImGui.Selectable(ctx, o[2], settings.theme == o[1]) then
          settings.theme = o[1]
          reaper.SetExtState("Swing", "eon_theme", settings.theme, true)  -- shared across EON tools
          save_settings()
        end
      end
      ImGui.EndPopup(ctx)
    end
    ImGui.SameLine(ctx)

    -- Kit name + slot display (em dash when no Swing exists — kit_db is
    -- read from gmem, which holds the LAST instance's kit after deletion)
    local kit_display = (ui.swing_present == false) and "\xE2\x80\x94"
      or (kit_db.kit_name ~= "" and kit_db.kit_name or "(no kit)")
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, widgets.colors.text_gold)
    ImGui.Text(ctx, kit_display)
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)

    -- Bridge status dot (compact circle indicator)
    local alive = bridge_is_alive()
    local dot_col = alive and widgets.colors.status_ok or widgets.colors.status_err
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, dot_col)
    ImGui.Text(ctx, "\xE2\x97\x8F")
    ImGui.PopStyleColor(ctx)
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, alive and "Bridge: Connected" or "Bridge: Not Running")
    end

    -- Instance selector — left-click ALWAYS opens the picker (so the user
    -- can see all instances + switch routing without surprise), even when
    -- there's only one instance. Selecting an entry switches routing only;
    -- the FX window doesn't auto-open. Right-click on an entry opens the
    -- FX window for that instance (escape hatch when you want to deep-edit).
    ImGui.SameLine(ctx)
    local inst_label = (track_num > 0 and ui.swing_present ~= false)
      and ("[Track " .. track_num .. "]##inst_btn")
      or  ("[No Instance]##inst_btn")
    if track_num == 0 or ui.swing_present == false then ImGui.BeginDisabled(ctx) end
    if ImGui.Button(ctx, inst_label) then
      enumerate_swing_instances()
      ImGui.OpenPopup(ctx, "##swing_instance_picker")
    end
    if track_num == 0 or ui.swing_present == false then ImGui.EndDisabled(ctx) end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Switch browser target instance\n(right-click an entry to open its FX window)")
    end
    if ImGui.BeginPopup(ctx, "##swing_instance_picker") then
      if #swing_instances == 0 then
        ImGui.TextDisabled(ctx, "No Swing instances found")
      else
        for idx, inst in ipairs(swing_instances) do
          -- Disambiguate stacked Swings on the same track with "(FX #N)".
          local label
          if inst.is_stacked then
            label = string.format("Track %d: %s (FX #%d)", inst.track_num, inst.track_name, inst.fx_index)
          else
            label = string.format("Track %d: %s", inst.track_num, inst.track_name)
          end
          if inst.is_active then label = label .. "  \xE2\x97\x8F" end
          -- Left-click: switch routing target only (no FX window pop).
          -- Always write on click — even on the "currently active" entry —
          -- so a stale active_inst_id (or a collision where both entries
          -- read as active) doesn't trap the user. Re-asserting INSTANCE
          -- is idempotent and self-corrects any drift.
          if ImGui.Selectable(ctx, label .. "##inst" .. idx, inst.is_active) then
            active_inst_id = inst.inst_id
            reaper.gmem_write(G.INSTANCE, active_inst_id)
          end
          -- Right-click: open the FX window for this instance — escape
          -- hatch for deep-editing without separately fishing for the FX.
          if ImGui.IsItemClicked(ctx, ImGui.MouseButton_Right) then
            reaper.TrackFX_Show(inst.track, inst.fx_index, 3)
            ImGui.CloseCurrentPopup(ctx)
          end
        end
      end
      ImGui.EndPopup(ctx)
    end

    -- Window-float toggle for the targeted Swing instance's FX window.
    -- Reads INSTANCE from gmem and scans tracks to find the matching FX —
    -- doesn't rely on enumerate_swing_instances' is_active flag (which can
    -- go stale between picker opens). This way Win always operates on the
    -- exact instance the user has currently picked.
    ImGui.SameLine(ctx)
    if track_num == 0 then ImGui.BeginDisabled(ctx) end
    if ImGui.Button(ctx, "Win##float_active") then
      local target_id = math.floor(reaper.gmem_read(G.INSTANCE))
      if target_id > 0 then
        local found = false
        for tr in core.iter_all_tracks() do
          for fx = 0, reaper.TrackFX_GetCount(tr) - 1 do
            local _, fname = reaper.TrackFX_GetFXName(tr, fx, "")
            local retval, ident = reaper.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
            local is_swing = (retval and ident:find("DrumKit_ReaKit"))
                          or fname:find("DrumKit_ReaKit")
                          or fname:match("^JS: Swing")
                          or fname:match("Swing %— 16%-Pad")
            if is_swing then
              local id = math.floor(reaper.TrackFX_GetParam(tr, fx, 3) or 0)
              if id == target_id then
                local floating = reaper.TrackFX_GetFloatingWindow(tr, fx) ~= nil
                reaper.TrackFX_Show(tr, fx, floating and 2 or 3)
                found = true
                break
              end
            end
          end
          if found then break end
        end
      end
    end
    if track_num == 0 then ImGui.EndDisabled(ctx) end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Toggle floating window for the targeted Swing instance")
    end

    -- Sidebar toggle — collapsing the left pane is what actually widens the
    -- file table (up to left_w extra), since the table lives in the right
    -- pane. Verb-style ASCII label to match Dock/Undock; no Unicode glyphs
    -- here for the same font-reliability reason noted below.
    ImGui.SameLine(ctx)
    local left_open = settings.left_pane_open ~= false
    if ImGui.Button(ctx, left_open and "Hide Sidebar##leftpane" or "Show Sidebar##leftpane") then
      settings.left_pane_open = not left_open
      save_settings()
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, left_open
        and "Hide the pads/kits sidebar and give the file list the full width"
        or  "Show the pads/kits sidebar")
    end

    -- Dock + Close buttons on the same title row. Placed inline with
    -- normal spacing (the prior right-align math + Unicode glyphs were
    -- fragile across fonts and could push the buttons off the visible
    -- row). Plain ASCII labels render reliably regardless of font setup.
    ImGui.SameLine(ctx)
    local is_docked   = (settings.dock_id or 0) ~= 0
    local dock_label  = is_docked and "Undock##dock" or "Dock##dock"
    if ImGui.Button(ctx, dock_label) then
      ui.pending_dock_id   = is_docked and 0 or -1
      ui.want_dock_change  = true
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, is_docked
        and "Undock (float the browser window)"
        or  "Dock to REAPER docker\n(right-click the docked tab to pick top/bottom/left/right)")
    end

    -- Help button (?) — opens the keyboard shortcuts modal. Lives next to
    -- Dock so users can discover the cheat sheet without knowing to press
    -- ? or F1.
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "?##help") then
      ui.show_shortcuts_modal = true
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Keyboard shortcuts (? or F1)")
    end

    ImGui.SameLine(ctx)
    -- Close button — red so it reads as "destructive" at a glance
    -- (matches the swing-red accent the JSFX uses for CLEAR/NEW etc.)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0xCC2222FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0xE63333FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0xAA1111FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text,          0xFFFFFFFF)
    if ImGui.Button(ctx, "X##close_browser") then
      ui.is_open = false
    end
    ImGui.PopStyleColor(ctx, 4)
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Close browser")
    end

    ImGui.Separator(ctx)

    local total_w, total_h = ImGui.GetContentRegionAvail(ctx)
    local left_w = math.max(160, math.min(300, total_w * 0.30))

    -- Track dock state transitions — BeginChild asserts during the frame(s)
    -- a window transitions between floating/docked (ReaImGui edge case).
    -- Skip pane layout for a few frames after the transition so the window
    -- geometry can stabilise; it recovers automatically.
    local is_docked = ImGui.IsWindowDocked(ctx)
    if ui.was_docked == nil then
      -- First frame: seed state, no transition
      ui.was_docked = is_docked
    elseif is_docked ~= ui.was_docked then
      -- Dock state just changed — skip the next 3 frames
      ui.was_docked = is_docked
      ui.dock_skip  = 3
    end
    if ui.dock_skip > 0 then
      ui.dock_skip = ui.dock_skip - 1
    end

    -- Persist user-initiated dock changes (drag-to-dock or unpin).
    -- ImGui_GetWindowDockID returns the current dock target; 0 means floating.
    if ImGui.GetWindowDockID then
      local cur_dock = ImGui.GetWindowDockID(ctx)
      if cur_dock ~= settings.dock_id then
        settings.dock_id = cur_dock
        save_settings()
      end
    end

    if ui.swing_present == false then
      -- No Swing in the project: blank content instead of stale-gmem panes.
      local aw, ah = ImGui.GetContentRegionAvail(ctx)
      ImGui.Dummy(ctx, 0, math.max(0, ah * 0.35))
      local t1 = "No Swing instance in this project"
      ImGui.SetCursorPosX(ctx, math.max(0, (aw - ImGui.CalcTextSize(ctx, t1)) * 0.5))
      ImGui.TextDisabled(ctx, t1)
      ImGui.Spacing(ctx)
      local t2 = "Add Swing to a track and the browser will wake up."
      ImGui.SetCursorPosX(ctx, math.max(0, (aw - ImGui.CalcTextSize(ctx, t2)) * 0.5))
      ImGui.TextDisabled(ctx, t2)
    elseif ui.dock_skip == 0 and total_w > 200 and total_h > 50 then
      -- LEFT PANE: 4x4 pad grid + controls + favorites. Skippable entirely
      -- (Hide Sidebar) — the right pane then claims the full width, which is
      -- the only way the file table actually gets bigger.
      if settings.left_pane_open ~= false then
        local left_visible = ImGui.BeginChild(ctx, "##left_pane", left_w, total_h, ImGui.ChildFlags_Border)
        if left_visible then
          -- Pads are collapsible: with drag-to-plugin working, this grid is no
          -- longer the only way to get a sample onto a pad. Collapsed, its
          -- square footprint (up to 300px tall) goes to the sidebar below.
          ImGui.SetNextItemOpen(ctx, settings.pads_open ~= false, ImGui.Cond_Once)
          local pads_open = ImGui.CollapsingHeader(ctx, "Pads")
          if pads_open ~= (settings.pads_open ~= false) then
            settings.pads_open = pads_open
            save_settings()
          end
          if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, "Show/hide the pad grid.\n" ..
              "Samples can also be dragged straight onto the plugin's pads.")
          end
          if pads_open then
            draw_pad_grid(ctx)
          end
          -- Info strip stays even when collapsed: it names the pad the controls
          -- below act on, and with the grid hidden it is the only thing that
          -- does (selection then follows the plugin's own pad selection).
          draw_pad_info_strip(ctx)
          ImGui.Separator(ctx)
          draw_pad_controls(ctx)
          ImGui.Separator(ctx)
          draw_shortcuts_panel(ctx)
        end
        ImGui.EndChild(ctx)

        ImGui.SameLine(ctx, nil, 6)
      end

      -- §4.2: query remaining width AFTER SameLine — the true available space
      -- (with the sidebar hidden there is no SameLine, so this is everything)
      local right_w = math.max(220, (select(1, ImGui.GetContentRegionAvail(ctx))))

      -- RIGHT PANE: nav bar, file table, preview
      local right_visible = ImGui.BeginChild(ctx, "##right_pane", right_w, total_h, ImGui.ChildFlags_None)
      if right_visible then
        if file_mgr.current_path == "" then
          draw_empty_state(ctx)
        else
          draw_nav_bar(ctx)
          draw_file_table(ctx)
          draw_playback_bar(ctx)
        end
      end
      ImGui.EndChild(ctx)
    end

    -- Import dialog overlay
    draw_import_dialog(ctx)
    draw_shortcuts_dialog(ctx)
    draw_shortcuts_modal_body(ctx)

    -- Keyboard shortcuts
    handle_keys(ctx)

    ImGui.End(ctx)
  end -- if visible

  pop_theme(ctx)

  -- Continue loop or shutdown
  if ui.is_open then
    reaper.defer(loop)
  else
    cleanup()
  end
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- MAIN ENTRY POINT (§8.5 xpcall + §9 lifecycle)
-- ═══════════════════════════════════════════════════════════════════════════════

loop = function()
  local ok, err = xpcall(frame, debug.traceback)
  if not ok then
    reaper.ShowConsoleMsg('\n[EON BROWSER ERROR]\n' .. tostring(err) .. '\n')
    cleanup()
    -- do not re-defer — stop the loop on error
  end
end

local function main()
  -- Single-instance guard: if another browser is already running (toggle
  -- script normally protects against this, but direct invocation via
  -- Action List does not), don't spawn a duplicate ImGui context that
  -- would race with the existing one over gmem and ExtState. Cross-check
  -- both ExtState (cheap) and gmem[GS_BROWSER_OPEN] (truth) so a stale
  -- ExtState from a crashed previous session doesn't permanently lock
  -- us out — fall through to launch if gmem says nobody is running.
  -- History: this attach once said "DrumKit_ReaKit" — a pre-rename segment
  -- name nothing writes to any more — so the read was always 0, the guard
  -- always looked "stale", and it fell through and launched a duplicate:
  -- exactly what it exists to prevent. Same bug, same fix as
  -- EON_Toggle_Swing_Browser.lua (2026-07-29).
  if reaper.GetExtState("Swing", "browser_running") == "1" then
    reaper.gmem_attach(core.GMEM_NAME)
    if reaper.gmem_read(G.GS_BROWSER_OPEN) ~= 0 then
      return  -- genuinely running; let user use the existing window
    end
    -- ExtState stale (last session crashed). Clear and proceed.
    reaper.SetExtState("Swing", "browser_running", "0", false)
  end
  init()
  reaper.atexit(cleanup)  -- §9.3 / §17.3: register BEFORE first defer
  -- EON Hub push IPC: window materializes on the first defer frame; the
  -- Hub's capture burst absorbs the gap (spec §3).
  if core.hub_notify then core.hub_notify("open", "browser") end
  reaper.defer(loop)
end

-- Launch with top-level xpcall (§8.5)
local ok, err = xpcall(main, debug.traceback)
if not ok then
  reaper.ShowConsoleMsg('\n[EON BROWSER INIT ERROR]\n' .. tostring(err) .. '\n')
end
