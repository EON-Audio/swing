-- Swing Browser settings — the CANONICAL FRESH-INSTALL DEFAULTS.
--
-- Two roles, one file:
--   1. Shipped seed. Live prefs get written to
--      <resource>/Data/EON_Swing/Swing_Browser_Settings.lua; the browser
--      reads this shipped copy only while that file doesn't exist yet
--      (first launch, or the user's file was deleted).
--   2. In-code defaults. Swing_Browser.lua dofile()s this table at startup
--      as its DEFAULTS, then shallow-clones it into the working `settings`
--      table. Any field a user's saved prefs are missing (older schema)
--      falls back to the value here.
--
-- Consequences: add a new setting HERE first, not just in the browser code
-- — otherwise fresh installs and older user files silently miss it. The
-- `version` field is code-owned (Swing_Browser.lua's SETTINGS_VERSION) and
-- overrides whatever this file says, so schema bumps don't require touching
-- this file.
--
-- The Shortcuts panel (Desktop / Downloads / REAPER Resources / Project Dir)
-- is built dynamically from $USERPROFILE / $HOME at draw time
-- (Swing_Browser.lua → draw_shortcuts_panel), so those entries are portable
-- across users and don't need to live here.
return {
  version = 1,
  last_folder = "",
  window_w = 773,
  window_h = 928,
  volume = 1.000,
  auto_play = true,
  sort_column = 1,
  sort_ascending = true,
  loop_preview = false,
  theme = "eon",
  show_shortcuts = true,
  show_favorites = true,
  show_recent = true,
  show_kits = true,
  show_categories = true,
  -- Sidebar collapsible-section open state. ImGui's CollapsingHeader uses
  -- DefaultOpen on every script launch, which would reset the user's
  -- collapse choices; we mirror the state into settings each frame and
  -- feed it back via SetNextItemOpen(Cond_Once) on init so the layout
  -- survives a browser close → reopen cycle.
  categories_open = true,
  kits_open       = true,
  shortcuts_open  = true,
  favorites_open  = true,
  recent_open     = true,
  -- Left-pane 4x4 pad grid. Optional since samples can be dragged straight
  -- onto the plugin's own pads (EON_DRAG); collapsing it hands the vertical
  -- space to the favorites/kits sidebar below. Default open — the grid is
  -- still how you see loaded/muted pads and pick a target pad.
  pads_open = true,
  -- Whole left pane (pads + pad controls + kits/favorites sidebar). Hiding
  -- it is the one that widens the FILE TABLE, since that lives in the right
  -- pane — collapsing the pad grid alone only frees vertical space within
  -- the left.
  left_pane_open = true,
  spectral_view = false,      -- TK-style spectral coloring of waveform preview (FFT per pixel)
  grid_overlay = false,       -- TK-style time grid overlay on waveform preview
  recurse_subfolders = false, -- Subfolders mode: flatten all audio in subdirs into one list
  kit_fill_mode = false,      -- Kit categories: OFF = LOAD author's layout, ON = FILL onto MY layout
  -- Docking: 0 = floating (default). Negative IDs (-1..-16) target REAPER's
  -- native dockers; positive IDs are ImGui internal docks (rare). Updated
  -- from the live ImGui_GetWindowDockID() each frame so user-initiated
  -- drags persist across sessions.
  dock_id = 0,
  favorites = {
  },
  recent_folders = {
  },
}
