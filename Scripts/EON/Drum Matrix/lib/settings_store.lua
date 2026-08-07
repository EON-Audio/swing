-- settings_store.lua -- EON Drum Matrix central settings registry.
--
-- Pattern ported from TK_Trackname_in_Arrange.lua (lines 879-899):
--   * Settings stored as a Lua table, persisted to ExtState as JSON.
--   * Save-on-change: every Set() writes ExtState immediately, so changes
--     survive REAPER crashes without an Apply button.
--   * Per-key reset (M.Reset) for surgical undo of a single field, plus
--     ResetAll() that nukes everything back to defaults.
--   * GetDoc(key) returns the tooltip string the settings window shows.

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.encode then json = mod end
end

-- Lazy-load safety.lua so we can ConsoleWarn on encode failures. We can't
-- require it at top because settings_store is itself required by safety's
-- consumers, and a circular load order would deadlock. So we resolve it on
-- first use via dofile + cache. If safety.lua is missing, we still work —
-- just without console warnings.
local _safety
local function safety()
  if _safety ~= nil then return _safety end
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'safety.lua')
  _safety = (ok and type(mod) == 'table') and mod or false
  return _safety
end
local function warn(msg)
  local s = safety()
  if s then s.ConsoleWarn(msg) else reaper.ShowConsoleMsg('[EON DM] ' .. msg .. '\n') end
end

local EXT_SECTION = 'EON_DRUM_MATRIX'
local EXT_KEY     = 'settings'

-- =============================================================================
-- DEFAULTS + DOCS
-- =============================================================================

local DEFAULTS = {
  -- Display tab
  lane_bg_brightness   = 18,    -- 0..96 grey level of the opaque grid background (18 = original 0x12)
  lane_tint_alpha      = 0,     -- 0..255, lane background fill alpha
  grid_bar_alpha       = 255,   -- 0..255
  grid_bar_thickness   = 2,     -- 1..4 px
  grid_beat_alpha      = 170,   -- 0..255
  grid_subbeat_alpha   = 80,    -- 0..255
  lane_border_alpha    = 200,   -- 0..255, horizontal lane separator lines (top/bottom of each lane)
  bar_line_accent      = true,  -- tint bar (tier-1) grid lines a distinct color vs beat/sub-beat
  bar_numbers_enabled  = true,  -- float dim bar numbers at the top of the grid (no ruler band)
  show_labels          = true,
  show_pitch_in_label  = true,
  show_lane_icons      = true,   -- category glyph before lane labels + stereo pad-row names
  item_dim_factor      = 0.18,  -- 0.0..1.0, how much darker items are vs pad color
  piano_keyboard       = 'keys',-- 'keys' | 'labels' | 'off' — piano-lane pitch guide
  -- Clutter controls
  minimal_mode         = false, -- master "clean" switch: hide pattern bar + grid cog + labels/badges
  show_pattern_bar     = true,  -- show the pattern-selector bar (top, left of the cog)
  lane_controls_on_hover = false, -- draw the per-lane cog/M/S only for the lane under the cursor

  -- Paint tab
  default_velocity     = 100,   -- 1..127
  live_trigger         = false,
  right_click_action   = 'delete',  -- 'delete' | 'toggle' | 'off'
  snap_mode            = 'floor',   -- 'floor' | 'nearest' | 'off'
  grid_widget_enabled  = true,      -- show the floating grid cog (hover+wheel = change grid)
  grid_scroll_in_paint = false,     -- wheel over EMPTY grid cycles grid in paint mode (else nothing)
  paint_fx_cutout      = true,      -- paint mode: punch holes in the lanes around floating FX windows

  -- Pattern tab
  new_item_bars        = 4,     -- 1, 2, 4, 8
  pattern_default_bars = 1,     -- 1, 2, 4, 8 — length of a new pattern region
  pattern_new_at_selection = false,  -- New pattern uses the time selection (if any); else always append after the last
  auto_extend          = true,
  apply_sets_tempo     = false, -- match project tempo to chosen pattern BPM on apply
  apply_quantize       = false, -- snap raw-note (format 2) presets to the step grid on apply

  -- Presets / Genre (Phase E)
  genre                  = 'hip-hop',  -- current preset library genre filter
  ghost_velocity_factor  = 0.4,        -- Shift+click velocity multiplier (0..1)
  humanize_time_ms       = 5,          -- ± time jitter for HumanizeLane
  humanize_vel_amount    = 10,         -- ± velocity jitter for HumanizeLane
  randomize_density_pct  = 25,         -- default fill density for RandomizeLane

  -- Graph editor strip (Phase F)
  graph_editor_enabled   = true,       -- master toggle for the velocity strip
  graph_strip_height     = 14,         -- pixel height of the strip per lane
  graph_strip_scope      = 'selected', -- 'all' | 'selected' | 'off'

  -- Overlay keymap (Feature A2). Map of action_id -> ImGui key-chord int
  -- (mods | key, e.g. Mod_Ctrl | Key_C). Empty = every action uses its
  -- registry default (see lib/keymap.lua). A table default round-trips through
  -- the JSON store and the type-gate (type(v) == type(dv)) below.
  keymap                 = {},

}

local DOCS = {
  lane_bg_brightness   = 'Grey level of the opaque grid background. 0 = black, 96 = light grey; 18 = default.',
  lane_tint_alpha      = 'Translucent fill behind each lane. 0 = off (clean cells); higher = more visible band.',
  grid_bar_alpha       = 'Bar-line opacity. Brightest tier — measure starts.',
  grid_bar_thickness   = 'Bar-line width in pixels. Use 2 for clear measure markers.',
  grid_beat_alpha      = 'Beat-line opacity (every quarter note).',
  grid_subbeat_alpha   = 'Sub-beat opacity (1/16, 1/8 etc. depending on current grid). Lower = subtler.',
  lane_border_alpha    = 'Horizontal lane separator lines (top + bottom of each lane row). 0 = no separators (lanes blend together); 255 = solid borders.',
  bar_line_accent      = 'Tint bar (measure-start) grid lines a distinct warm color so bars stand out from beat/sub-beat lines.',
  bar_numbers_enabled  = 'Show dim bar numbers floating at the top of the grid (aligned to bar lines). No reserved ruler band.',
  show_labels          = 'Show pad name + pitch label at the left edge of each lane.',
  show_lane_icons      = 'Draw the pad\'s category glyph (kick, snare, hi-hat...) before its lane label and before stereo pad-row names. The Pads tab always shows them.',
  show_pitch_in_label  = 'Append the MIDI pitch number in parens: "Kick (36)" vs just "Kick".',
  item_dim_factor      = 'How dim the lane MIDI items appear vs the bright cells. 0.0 = black, 1.0 = full pad color.',
  piano_keyboard       = 'Piano-lane pitch guide on the left of each clip: "keys" = mini keyboard, "labels" = note names only, "off" = none. Notes always draw on top, so this never hides a clip start.',
  minimal_mode         = 'Clean view: hides the pattern bar, the grid cog, and lane labels/badges, leaving just the step cells and the top-right menu. Master switch — overrides the individual show toggles while ON.',
  show_pattern_bar     = 'Show the pattern-selector bar at the top (just left of the menu cog). Turn off to reclaim that strip if you drive patterns from the keyboard or Pattern Manager.',
  lane_controls_on_hover = 'Only show each lane\'s cog / Mute / Solo buttons when the mouse is over that lane (declutters the left edge). Off = always show them (original behaviour).',
  default_velocity     = 'Velocity for newly painted notes.',
  live_trigger         = 'Send a MIDI Note On to the virtual keyboard when you paint a cell. Requires kit tracks armed + monitor + input = Virtual MIDI keyboard.',
  right_click_action   = 'What right-click on a cell does.',
  snap_mode            = 'How paint clicks snap to the grid. Floor = land in the cell you clicked.',
  grid_widget_enabled  = 'Show the small floating "grid cog" (top-right) with the current grid division. Hover it + scroll the wheel to change the grid — works whether or not paint mode is on. Click = next, right-click = previous.',
  grid_scroll_in_paint = 'In paint mode, let the mouse wheel over an EMPTY cell cycle the project grid. Default OFF: the wheel over a note adjusts its velocity, and the grid cog is the dedicated grid control. Turn ON to also cycle the grid by scrolling blank space.',
  paint_fx_cutout      = 'While painting, keep floating FX windows (Swing, Pad FX, any plugin) visible: the lanes are not drawn where those windows sit, and clicks there go to the FX window instead of painting hidden notes. Turn OFF to always paint the full lane area.',
  new_item_bars        = 'Length of MIDI items auto-created at the edit cursor.',
  pattern_default_bars = 'Length in bars of a new pattern region created by "+" when there is no time selection. Patterns tile left-to-right at this length.',
  pattern_new_at_selection = 'When ON, "New pattern" uses your current time selection/loop as the new pattern range (place it where you want). When OFF (default), New pattern ALWAYS appends right after the last pattern and ignores the loop — so your audition loops never decide where patterns land.',
  auto_extend          = 'When a click lands past a lane item, extend the item to cover it instead of creating a new one.',
  apply_sets_tempo      = 'When ON, applying a preset sets the project tempo to the chosen pattern BPM (per-pattern bpm field, else a genre default). Default OFF so applying a pattern never retempos your session unexpectedly.',
  apply_quantize        = 'When ON, imported raw-timing patterns snap to the step grid on apply. Default OFF to preserve the human feel (swing, ghosts, off-grid hits) of the source loop. Has no effect on classic grid (format 1) presets.',
  genre                 = 'Active genre filter for the preset library. Drives which patterns appear in lane cog menus.',
  ghost_velocity_factor = 'Velocity scale for Shift+click ghost notes. 0.4 = 40% of default.',
  humanize_time_ms      = 'Maximum ± timing jitter (milliseconds) applied by Humanize lane.',
  humanize_vel_amount   = 'Maximum ± velocity jitter (0-127) applied by Humanize lane.',
  randomize_density_pct = 'Default % of grid steps filled by Randomize lane.',
  graph_editor_enabled  = 'Master toggle for the velocity-bar strip below drum lanes. Drag in the strip to adjust velocity.',
  graph_strip_height    = 'Pixel height of the graph editor strip below each lane (typical: 10-20).',
  graph_strip_scope     = 'Which lanes show the strip. "selected" = only the currently-selected REAPER track; "all" = every lane; "off" = none.',
}

-- =============================================================================
-- in-memory cache, synced to ExtState. CRITICAL: every Get/Set goes through a
-- cache that re-reads the ExtState JSON STRING and only re-decodes when it
-- actually changes. This is what makes settings updates real-time across
-- multiple `dofile` copies of this module (each lib file that requires
-- settings has its own Lua table, but they ALL sync via the shared ExtState).
-- =============================================================================

local cached_raw   = nil
local cached_table = nil

local function defaults_table()
  local t = {}
  for k, v in pairs(DEFAULTS) do t[k] = v end
  return t
end

local function refresh_cache()
  local raw = reaper.GetExtState(EXT_SECTION, EXT_KEY)
  if cached_table and raw == cached_raw then return end   -- no change since last read
  cached_raw   = raw
  cached_table = defaults_table()
  if json and raw ~= '' then
    local ok, decoded = pcall(json.decode, raw)
    if ok and type(decoded) == 'table' then
      for k, dv in pairs(DEFAULTS) do
        local v = decoded[k]
        -- Type-gate against the default: a corrupt or hand-edited ExtState
        -- value of the wrong type (e.g. a string where a number is expected)
        -- would otherwise reach a ReaImGui SliderInt and raise. Numbers are
        -- also floored at 0 — every numeric setting here is an alpha / pixel /
        -- factor / count where a negative value is invalid.
        if v ~= nil and type(v) == type(dv) then
          if type(dv) == 'number' and v < 0 then v = 0 end
          cached_table[k] = v
        end
      end
    end
  end
end

local function save_cache()
  if not json then
    warn('settings save: json.lua missing — settings will not persist')
    return false
  end
  if not cached_table then return false end
  local ok, encoded = pcall(json.encode, cached_table)
  if not ok or not encoded then
    warn('settings save: json.encode failed (' .. tostring(encoded) .. ')')
    return false
  end
  reaper.SetExtState(EXT_SECTION, EXT_KEY, encoded, true)
  cached_raw = encoded   -- prime the cache-equality check on next Get
  return true
end

-- =============================================================================
-- public API
-- =============================================================================

function M.Load()  refresh_cache() end
function M.Save()  save_cache()    end

function M.Get(key)
  refresh_cache()
  if cached_table[key] == nil then return DEFAULTS[key] end
  return cached_table[key]
end

-- Compare-and-swap Set. The cache is re-read from ExtState BEFORE the write
-- so any concurrent updates from another dofile-copy of this module get
-- merged in rather than clobbered. Returns true on success, false if the
-- encode/persist failed (caller can choose to surface or ignore).
function M.Set(key, value)
  if DEFAULTS[key] == nil then return false end   -- guard against typos
  refresh_cache()                                  -- pull in concurrent edits
  cached_table[key] = value
  return save_cache()
end

function M.GetDoc(key)
  return DOCS[key] or ''
end

function M.GetDefault(key)
  return DEFAULTS[key]
end

function M.Reset(key)
  if DEFAULTS[key] == nil then return false end
  refresh_cache()
  cached_table[key] = DEFAULTS[key]
  return save_cache()
end

function M.ResetAll()
  cached_table = defaults_table()
  return save_cache()
end

-- =============================================================================
-- settings-window-open flag (separate ExtState key for cross-script toggle)
-- =============================================================================

local OPEN_KEY = 'settings_open'

function M.IsWindowOpen()
  return reaper.GetExtState(EXT_SECTION, OPEN_KEY) == '1'
end

function M.SetWindowOpen(on)
  reaper.SetExtState(EXT_SECTION, OPEN_KEY, on and '1' or '0', false)
end

function M.ToggleWindow()
  M.SetWindowOpen(not M.IsWindowOpen())
end

return M
