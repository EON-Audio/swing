-- keymap.lua -- EON Drum Matrix overlay keymap registry.
--
-- Single source of truth for the overlay-focused keyboard shortcuts. Both the
-- dispatcher (eon_drum_matrix.lua MainLoopBody) and the rebind UI
-- (settings_window.lua "Keys" tab) drive off this table, so a shortcut is
-- defined exactly once.
--
-- A binding is a single ImGui "key chord" int: mods | key (e.g.
--   reaper.ImGui_Mod_Ctrl() | reaper.ImGui_Key_C()
-- ). ReaImGui v0.10.x exposes ImGui_IsKeyChordPressed(ctx, chord), which
-- compares the modifier set EXACTLY (so Ctrl+Z does not also fire on
-- Ctrl+Alt+Z) and fires once per key-down (no auto-repeat). That makes the
-- whole dispatch a one-liner per action and lets a user-rebound chord persist
-- as a plain integer in settings_store's `keymap` table.
--
-- This build has NO ImGui_GetKeyName, so we maintain a curated key table for
-- both pretty-printing (ChordName) and capture-scan (CAPTURE_KEYS).

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local settings
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'settings_store.lua')
  if ok and type(mod) == 'table' then settings = mod end
end

local r = reaper

-- =============================================================================
-- modifier flags
-- =============================================================================

-- Resolve a modifier flag defensively: a missing accessor degrades to 0
-- (that bit simply never participates) rather than crashing module load and
-- taking the whole overlay down at dofile time.
local function MK(name)
  local fn = r['ImGui_Mod_' .. name]
  if type(fn) ~= 'function' then return 0 end
  local ok, v = pcall(fn)
  return (ok and type(v) == 'number') and v or 0
end

local MOD_CTRL  = MK('Ctrl')
local MOD_SHIFT = MK('Shift')
local MOD_ALT   = MK('Alt')
local MOD_SUPER = MK('Super')
local MOD_MASK  = MOD_CTRL | MOD_SHIFT | MOD_ALT | MOD_SUPER

M.MOD_MASK = MOD_MASK

-- =============================================================================
-- curated key table: display name <-> ImGui key value. Built by calling the
-- ImGui_Key_* accessors once at load. Anything this build lacks is skipped.
-- =============================================================================

-- { display_name, ImGui_Key_* suffix }
local KEY_SPECS = {
  -- letters
  { 'A','A' },{ 'B','B' },{ 'C','C' },{ 'D','D' },{ 'E','E' },{ 'F','F' },
  { 'G','G' },{ 'H','H' },{ 'I','I' },{ 'J','J' },{ 'K','K' },{ 'L','L' },
  { 'M','M' },{ 'N','N' },{ 'O','O' },{ 'P','P' },{ 'Q','Q' },{ 'R','R' },
  { 'S','S' },{ 'T','T' },{ 'U','U' },{ 'V','V' },{ 'W','W' },{ 'X','X' },
  { 'Y','Y' },{ 'Z','Z' },
  -- digits (top row)
  { '0','0' },{ '1','1' },{ '2','2' },{ '3','3' },{ '4','4' },
  { '5','5' },{ '6','6' },{ '7','7' },{ '8','8' },{ '9','9' },
  -- function row
  { 'F1','F1' },{ 'F2','F2' },{ 'F3','F3' },{ 'F4','F4' },{ 'F5','F5' },
  { 'F6','F6' },{ 'F7','F7' },{ 'F8','F8' },{ 'F9','F9' },{ 'F10','F10' },
  { 'F11','F11' },{ 'F12','F12' },
  -- arrows + navigation
  { 'Left','LeftArrow' },{ 'Right','RightArrow' },
  { 'Up','UpArrow' },{ 'Down','DownArrow' },
  { 'Home','Home' },{ 'End','End' },
  { 'PageUp','PageUp' },{ 'PageDown','PageDown' },
  { 'Insert','Insert' },{ 'Delete','Delete' },{ 'Backspace','Backspace' },
  { 'Space','Space' },{ 'Enter','Enter' },{ 'Tab','Tab' },
  -- keypad
  { 'Num0','Keypad0' },{ 'Num1','Keypad1' },{ 'Num2','Keypad2' },
  { 'Num3','Keypad3' },{ 'Num4','Keypad4' },{ 'Num5','Keypad5' },
  { 'Num6','Keypad6' },{ 'Num7','Keypad7' },{ 'Num8','Keypad8' },
  { 'Num9','Keypad9' },{ 'Num.','KeypadDecimal' },{ 'NumEnter','KeypadEnter' },
  { 'Num+','KeypadAdd' },{ 'Num-','KeypadSubtract' },
  { 'Num*','KeypadMultiply' },{ 'Num/','KeypadDivide' },
  -- punctuation
  { '-','Minus' },{ '=','Equal' },{ '[','LeftBracket' },{ ']','RightBracket' },
  { '\\','Backslash' },{ ';','Semicolon' },{ "'",'Apostrophe' },
  { ',','Comma' },{ '.','Period' },{ '/','Slash' },{ '`','GraveAccent' },
}

local KEY_NAME    = {}   -- value -> display name
local CAPTURE_KEYS = {}  -- ordered list of capturable key values

for _, spec in ipairs(KEY_SPECS) do
  local disp, suffix = spec[1], spec[2]
  local fn = r['ImGui_Key_' .. suffix]
  if fn then
    local ok, val = pcall(fn)
    if ok and type(val) == 'number' then
      KEY_NAME[val] = disp
      CAPTURE_KEYS[#CAPTURE_KEYS + 1] = val
    end
  end
end

M.KEY_NAME     = KEY_NAME
M.CAPTURE_KEYS = CAPTURE_KEYS

-- Escape value (used by the rebind UI to cancel capture; never bindable).
M.KEY_ESCAPE = (function()
  local ok, v = pcall(r.ImGui_Key_Escape)
  return ok and v or nil
end)()

-- =============================================================================
-- chord helpers
-- =============================================================================

local function chord(mods, key) return (mods or 0) | key end
M.Chord = chord

-- Decompose a chord into its key value (mods stripped off).
function M.ChordKey(c)  return c & (~MOD_MASK) end
function M.ChordMods(c) return c & MOD_MASK end

-- Chord-pressed test. Prefers the native ImGui_IsKeyChordPressed (v0.9+) which
-- matches the modifier set EXACTLY and fires once per key-down. Falls back to
-- IsKeyPressed + a manual GetKeyMods equality check on older builds — the same
-- feature-detect-and-degrade shape TK_Notes uses. (House style EON ports from.)
local has_key_chord  = type(r.ImGui_IsKeyChordPressed) == 'function'
local has_key_pressd = type(r.ImGui_IsKeyPressed) == 'function'
function M.IsChordPressed(ctx, c)
  if not c or c == 0 then return false end
  if has_key_chord then return r.ImGui_IsKeyChordPressed(ctx, c) end
  if not has_key_pressd then return false end
  local want = c & MOD_MASK
  local now  = (r.ImGui_GetKeyMods(ctx) or 0) & MOD_MASK
  if now ~= want then return false end
  return r.ImGui_IsKeyPressed(ctx, c & (~MOD_MASK), false)
end

-- Human-readable "Ctrl+Shift+C". Returns 'Unbound' for 0/nil, '?' for an
-- unknown key value.
function M.ChordName(c)
  if not c or c == 0 then return 'Unbound' end
  local mods = c & MOD_MASK
  local key  = c & (~MOD_MASK)
  local parts = {}
  if (mods & MOD_CTRL)  ~= 0 then parts[#parts + 1] = 'Ctrl'  end
  if (mods & MOD_SHIFT) ~= 0 then parts[#parts + 1] = 'Shift' end
  if (mods & MOD_ALT)   ~= 0 then parts[#parts + 1] = 'Alt'   end
  if (mods & MOD_SUPER) ~= 0 then parts[#parts + 1] = 'Super' end
  parts[#parts + 1] = KEY_NAME[key] or '?'
  return table.concat(parts, '+')
end

-- =============================================================================
-- action registry (ordered). `chord` is the factory default; a user override
-- lives in settings_store's `keymap` table keyed by `id`. `group` drives the
-- section headers in the Keys tab. `sel` marks selection-gated actions (the
-- dispatcher still fires them but the rebind UI notes the requirement).
-- =============================================================================

local function K(suffix)
  local fn = r['ImGui_Key_' .. suffix]
  local ok, v = pcall(fn)
  return ok and v or 0
end

M.Registry = {
  -- Transport (no modifiers)
  { id = 'transport_play',   label = 'Play / Stop',        group = 'Transport', chord = K('Space') },
  { id = 'transport_record', label = 'Record',             group = 'Transport', chord = K('R') },
  { id = 'transport_play2',  label = 'Play (numpad)',      group = 'Transport', chord = K('Keypad0') },
  { id = 'transport_stop2',  label = 'Stop (numpad)',      group = 'Transport', chord = K('KeypadDecimal') },
  { id = 'cursor_start',     label = 'Cursor to start',    group = 'Transport', chord = K('Home') },
  { id = 'cursor_end',       label = 'Cursor to end',      group = 'Transport', chord = K('End') },
  { id = 'zoom_pattern',     label = 'Zoom to pattern',    group = 'Transport', chord = K('Z') },

  -- Edit (undo/redo + bar duplicate)
  { id = 'undo',          label = 'Undo',                  group = 'Edit', chord = chord(MOD_CTRL, K('Z')) },
  { id = 'redo',          label = 'Redo (Ctrl+Y)',         group = 'Edit', chord = chord(MOD_CTRL, K('Y')) },
  { id = 'redo_alt',      label = 'Redo (Ctrl+Shift+Z)',   group = 'Edit', chord = chord(MOD_CTRL | MOD_SHIFT, K('Z')) },
  { id = 'dup_bar_all',   label = 'Duplicate bar (all lanes)',  group = 'Edit', chord = chord(MOD_CTRL, K('B')) },
  { id = 'dup_bar_lane',  label = 'Duplicate bar (this lane)',  group = 'Edit', chord = chord(MOD_CTRL | MOD_SHIFT, K('B')) },

  -- Selection (mostly gated on a non-empty note selection)
  { id = 'nudge_left',  label = 'Nudge selection left',   group = 'Selection', chord = K('LeftArrow'),  sel = true },
  { id = 'nudge_right', label = 'Nudge selection right',  group = 'Selection', chord = K('RightArrow'), sel = true },
  { id = 'nudge_up',    label = 'Nudge selection up',     group = 'Selection', chord = K('UpArrow'),    sel = true },
  { id = 'nudge_down',  label = 'Nudge selection down',   group = 'Selection', chord = K('DownArrow'),  sel = true },
  { id = 'delete_sel',  label = 'Delete selection',       group = 'Selection', chord = K('Delete'),     sel = true },
  { id = 'delete_sel2', label = 'Delete selection (BkSp)',group = 'Selection', chord = K('Backspace'),  sel = true },
  { id = 'copy_sel',    label = 'Copy selection',         group = 'Selection', chord = chord(MOD_CTRL, K('C')), sel = true },
  { id = 'cut_sel',     label = 'Cut selection',          group = 'Selection', chord = chord(MOD_CTRL, K('X')), sel = true },
  { id = 'dup_sel',     label = 'Duplicate selection',    group = 'Selection', chord = chord(MOD_CTRL, K('D')), sel = true },
  { id = 'paste_sel',   label = 'Paste at playhead',      group = 'Selection', chord = chord(MOD_CTRL, K('V')) },
}

-- id -> default chord, for fast EffectiveChord lookup.
local DEFAULT_CHORD = {}
for _, e in ipairs(M.Registry) do DEFAULT_CHORD[e.id] = e.chord end
M.DefaultChord = function(id) return DEFAULT_CHORD[id] end

-- =============================================================================
-- override storage (settings_store `keymap` table)
-- =============================================================================

local function keymap_table()
  local km = settings and settings.Get('keymap')
  if type(km) ~= 'table' then return {} end
  return km
end

-- Effective chord for an action: user override if present (and a positive
-- int), else the registry default.
function M.EffectiveChord(id)
  local km = keymap_table()
  local v = km[id]
  if type(v) == 'number' and v > 0 then return v end
  return DEFAULT_CHORD[id]
end

-- Persist a rebind. Pass nil/0 to clear the override (revert to default).
function M.SetChord(id, c)
  if not settings or DEFAULT_CHORD[id] == nil then return false end
  local km = {}
  for k, v in pairs(keymap_table()) do km[k] = v end
  if not c or c == 0 then km[id] = nil else km[id] = c end
  return settings.Set('keymap', km)
end

function M.ResetChord(id) return M.SetChord(id, nil) end

function M.ResetAll()
  if not settings then return false end
  return settings.Set('keymap', {})
end

-- Returns the first OTHER action id currently bound to chord `c` (ignoring
-- `self_id`), or nil. Used by the Keys tab for a soft duplicate warning.
function M.FindConflict(c, self_id)
  if not c or c == 0 then return nil end
  for _, e in ipairs(M.Registry) do
    if e.id ~= self_id and M.EffectiveChord(e.id) == c then return e.id end
  end
  return nil
end

return M
