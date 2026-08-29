-- @noindex
-- eon_menu_lib.lua — shared EON menu tree + gfx.showmenu launcher.
-- Loaded (not an action) by the category-button scripts (EON_Menu_Build.lua …)
-- and the all-in-one EON_Menu.lua. One source of truth for the whole catalog:
-- edit the tree here and every button updates.

local sep = package.config:sub(1, 1)
local DM  = "EON" .. sep .. "Drum Matrix" .. sep      -- Drum Matrix scripts subfolder
local M   = {}

-- .Scripts dir, captured at M.show time so checked closures can resolve sibling
-- libs (eon_lane_color). nil until the first M.show.
local _dir = nil
local _lanecolor = nil  -- cached eon_lane_color module
local function lanecolor()
  if _lanecolor == nil and _dir then
    local ok, m = pcall(dofile, _dir .. sep .. "EON" .. sep .. "eon_lane_color.lua")
    _lanecolor = ok and m or false
  end
  return _lanecolor or nil
end
-- Current lane-color mode for the focused Swing ("swing"/"reaper"/"none"), or
-- nil when the lib or a Swing instance is unavailable.
local function lc_mode()
  local L = lanecolor()
  return L and L.GetFocused() or nil
end

-- live toggle state -> ✓ checkmarks
local chk = {
  paint = function() return reaper.GetExtState("EON_DRUM_MATRIX", "paint_mode") == "1" end,
  grid  = function()
    local t = tonumber(reaper.GetExtState("EON_DRUM_MATRIX_LOCKS", "main_overlay")) or -1e9
    return (reaper.time_precise() - t) < 5
  end,
  media = function() return reaper.GetToggleCommandState(50124) == 1 end,  -- Media Explorer
  -- Lane-color radio: three sibling checkmarks (gfx.showmenu has no radio group,
  -- so exactly one returns true = conventional radio). Default "swing" shows
  -- lit when unset, so the current owner is always visible.
  lc_swing  = function() return lc_mode() == "swing"  end,
  lc_reaper = function() return lc_mode() == "reaper" end,
  lc_none   = function() return lc_mode() == "none"   end,
}

-- Leaf = { "Label", "relative/path.lua" [, checked = fn] }
-- Submenu = { "Label", { ...children... } }
M.CAT = {}

M.CAT.toggles = {
  { "Grid",           "EON_Swing_ToggleGrid.lua",          checked = chk.grid  },
  { "Paint",          "EON_Swing_TogglePaint.lua",         checked = chk.paint },
  { "Step Sequencer", "EON_Swing_ToggleStepSeq.lua" },
  { "Swing Window",   "EON_Toggle_Swing_Window.lua" },
  { "Pad FX",         "EON_Toggle_Swing_PadFX.lua" },
  { "Media Explorer", "EON_Swing_ToggleMediaExplorer.lua", checked = chk.media },
}

M.CAT.build = {
  { "Multi-Out",   "EON_Swing_BuildMultiOut.lua" },
  { "MIDI Lanes",  "EON_Swing_BuildMidiLanes.lua" },
  { "Both",        "EON_Swing_BuildBoth.lua" },
  { "Stereo Grid", "EON_Swing_BuildStereo.lua" },
  -- Merged folds the MIDI-lane half INTO the multi-out tracks (one track per
  -- drum carrying both), so it needs Multi-Out first and replaces MIDI Lanes,
  -- not Multi-Out. Listed last so the three classic layouts keep their order.
  { "Merged (1 track/drum)", "EON_Swing_BuildMerged.lua" },
}

M.CAT.kit = {
  { "New Kit",           "EON_SB_NewKit.lua" },
  { "Load Kit...",       "EON_SB_LoadAllPads.lua" },
  { "Load to Pad...",    "EON_SB_LoadSelectedPads.lua" },
  { sep = true },
  { "Import SFZ Kit...", "EON_SB_ImportKit.lua" },
  { "Import from RS5k",  "EON_SB_ImportRS5k.lua" },
  { "Batch Import...",   "EON_Swing_BatchImport.lua" },
  { sep = true },
  { "Auto-Color Pads",   "EON_Swing_AutoColorPads.lua" },
  { "Lane Colors", {
    { "Swing owns (default)", "EON_Swing_LaneColor_Swing.lua",  checked = chk.lc_swing  },
    { "REAPER owns (SWS)",    "EON_Swing_LaneColor_Reaper.lua", checked = chk.lc_reaper },
    { "Independent",          "EON_Swing_LaneColor_None.lua",   checked = chk.lc_none   },
  }},
  { "Sync Pad Names",    "EON_Swing_SyncPadNames.lua" },
  { "Chop to Pads",      "EON_Swing_ChopToPads.lua" },
}

M.CAT.pattern = {
  { "New Pattern",          DM .. "EON_DM_NewPattern.lua" },
  { "Next Pattern",         DM .. "EON_DM_NextPattern.lua" },
  { "Prev Pattern",         DM .. "EON_DM_PrevPattern.lua" },
  { sep = true },
  { "Copy",                 DM .. "EON_DM_Copy.lua" },
  { "Cut",                  DM .. "EON_DM_Cut.lua" },
  { "Paste",                DM .. "EON_DM_Paste.lua" },
  { "Duplicate Selection",  DM .. "EON_DM_DuplicateSelection.lua" },
  { "Duplicate Bar",        DM .. "EON_DM_DuplicateBar.lua" },
  { "Duplicate Bar (Lane)", DM .. "EON_DM_DuplicateBarLane.lua" },
  { sep = true },
  { "Roll x2",              DM .. "EON_DM_Roll2.lua" },
  { "Roll x3",              DM .. "EON_DM_Roll3.lua" },
  { "Roll x4",              DM .. "EON_DM_Roll4.lua" },
  { sep = true },
  { "Stamp Pattern",        DM .. "EON_DM_StampPattern.lua" },
  { "Commit to Item",       DM .. "EON_DM_CommitToItem.lua" },
  { "Seed Lane...",         DM .. "EON_DM_SeedLane.lua" },
  { sep = true },
  { "Song", {
    { "Play Song",       DM .. "EON_DM_PlaySong.lua" },
    { "Song Loop",       DM .. "EON_DM_SongLoop.lua" },
    { "Add Step",        DM .. "EON_DM_SongAddStep.lua" },
    { "Zoom Song",       DM .. "EON_DM_ZoomSong.lua" },
    { "Zoom to Pattern", DM .. "EON_DM_ZoomToPattern.lua" },
  }},
  { "Grid Tools", {
    { "Cycle Division",    DM .. "EON_DM_CycleGrid.lua" },
    { "Cycle Lane Tint",   DM .. "EON_DM_CycleLaneTint.lua" },
    { "Tidy Items",        DM .. "EON_DM_TidyItems.lua" },
    { "Resync from Swing", DM .. "EON_DM_ResyncFromSwing.lua" },
    { "Route to Swing",    DM .. "EON_DM_RouteToSwing.lua" },
  }},
}

M.CAT.tools = {
  { "StepSeq Preset Browser",    "EON_StepSeq_Preset_Browser.lua" },
  { "StepSeq Groove Browser",    "EON_StepSeq_Groove_Browser.lua" },
  { sep = true },
  { "Sample Browser",            "EON_Toggle_Swing_Browser.lua" },
  { "Choppa (Slicer)",           "EON_Choppa.lua" },
  { sep = true },
  { "Install / Refresh Actions", "EON_Register_Actions.lua" },
}

-- Full tree = toggles (checkmarked) then the four category submenus.
M.ALL = {}
for _, t in ipairs(M.CAT.toggles) do M.ALL[#M.ALL + 1] = t end
M.ALL[#M.ALL + 1] = { sep = true }
M.ALL[#M.ALL + 1] = { "Build",   M.CAT.build }
M.ALL[#M.ALL + 1] = { "Kit",     M.CAT.kit }
M.ALL[#M.ALL + 1] = { "Pattern", M.CAT.pattern }
M.ALL[#M.ALL + 1] = { "Tools",   M.CAT.tools }

-- ── build gfx.showmenu string + parallel leaf list ──────────────────────────
local function is_leaf(n) return type(n[2]) == "string" end

local function build(nodes, parts, leaves)
  for _, n in ipairs(nodes) do
    if n.sep then
      parts[#parts + 1] = ""            -- separator line: non-selectable, NOT added to leaves
    elseif is_leaf(n) then
      local lbl = n[1]
      if n.checked and n.checked() then lbl = "!" .. lbl end
      parts[#parts + 1] = lbl
      leaves[#leaves + 1] = n[2]
    else
      parts[#parts + 1] = ">" .. n[1]
      build(n[2], parts, leaves)
      parts[#parts] = "<" .. parts[#parts]   -- close submenu on its last item
    end
  end
end

-- Pop `nodes` as a menu at the mouse and run the picked action. `dir` is the
-- caller's .Scripts dir (native separators) used to resolve action files.
function M.show(nodes, dir)
  _dir = dir   -- let checked closures resolve sibling libs (eon_lane_color)
  local parts, leaves = {}, {}
  build(nodes, parts, leaves)
  local mx, my = reaper.GetMousePosition()
  gfx.init("", 0, 0, 0, mx, my)
  gfx.x, gfx.y = gfx.mouse_x, gfx.mouse_y
  local ok, sel = pcall(gfx.showmenu, table.concat(parts, "|"))
  gfx.quit()
  if ok and sel and sel > 0 and leaves[sel] then
    local id = reaper.AddRemoveReaScript(true, 0, dir .. sep .. leaves[sel], false)
    if id and id > 0 then reaper.Main_OnCommand(id, 0) end
  end
end

return M
