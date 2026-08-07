-- @noindex
-- eon_toolbar.lua
-- Finds, and if necessary BUILDS, the EON floating toolbar.
--
-- Why this cannot just ship a reaper-menu.ini section:
--
-- A toolbar button does not store "run EON_Menu_Build.lua". It stores a command
-- ID -- "_RS" + a 40-hex string -- that the user's own REAPER minted when that
-- script was first registered. The ID is NOT derivable from the script path
-- (checked: not sha1 of the path in any casing, separator or encoding), so it
-- cannot be precomputed for someone else's machine. A hardcoded toolbar would
-- install twelve buttons that press fine and do nothing.
--
-- So the IDs are resolved HERE, at runtime, by registering each script and
-- asking REAPER what it called the result.
--
-- ⚠️ reaper-menu.ini also holds every toolbar the USER has made. REAPER keeps
-- it in memory and rewrites it on exit, so we only ever APPEND a section in a
-- free slot, never rewrite existing ones, and we back the file up first. The
-- caller must tell the user to restart REAPER — an edit made while REAPER is
-- running is otherwise clobbered by its own save-on-exit.
-- (c) EON Studios

local M = {}

local sep = package.config:sub(1, 1)

-- Button layout, in order. `script` nil = a text LABEL (command -1), which is
-- how the existing EON toolbar separates its two groups.
-- Icons resolve from <resource>/Data/toolbar_icons — the ONLY place REAPER
-- looks for toolbar art. The installer puts them there; see gen_manifest.py.
M.BUTTONS = {
  { label = "PLAY",       icon = "eon_label_play_e.png"                                     },
  { label = "Grid",       icon = "eon_grid.png",        script = "EON_Swing_ToggleGrid.lua" },
  { label = "Paint",      icon = "eon_paint.png",       script = "EON_Swing_TogglePaint.lua" },
  { label = "Step Seq",   icon = "eon_stepseq.png",     script = "EON_Swing_ToggleStepSeq.lua" },
  { label = "Pad FX",     icon = "eon_padfx.png",       script = "EON_Toggle_Swing_PadFX.lua" },
  { label = "Media",      icon = "eon_media.png",       script = "EON_Swing_ToggleMediaExplorer.lua" },
  { label = "Browser",    icon = "eon_browser.png",     script = "EON_Toggle_Swing_Browser.lua" },
  { label = "New Song",   icon = "eon_song.png",        script = "EON_Song_Starter.lua"     },
  { label = "MENUS",      icon = "eon_label_menus_e.png"                                    },
  { label = "Build",      icon = "eon_build_cat.png",   script = "EON_Menu_Build.lua"       },
  { label = "Kit",        icon = "eon_kit_cat.png",     script = "EON_Menu_Kit.lua"         },
  { label = "Pattern",    icon = "eon_pattern_cat.png", script = "EON_Menu_Pattern.lua"     },
  { label = "Tools",      icon = "eon_tools_cat.png",   script = "EON_Menu_Tools.lua"       },
}

local function menu_path()
  return reaper.GetResourcePath() .. sep .. "reaper-menu.ini"
end

-- Scan reaper-menu.ini once. Returns:
--   slot   — the [Floating toolbar N] whose title is EON, or nil
--   maxn   — the highest N present, so a new toolbar can take maxn+1
-- Mirrors the scan already used by Swing_Kit_Bridge's CMD 78 so both agree on
-- what "the EON toolbar" means.
function M.scan()
  local slot, maxn, cur = nil, 0, nil
  local f = io.open(menu_path(), "r")
  if not f then return nil, 0 end
  for line in f:lines() do
    local n = line:match("^%[Floating toolbar (%d+)%]")
    if n then
      cur = tonumber(n)
      if cur > maxn then maxn = cur end
    elseif line:match("^%[") then
      cur = nil                                    -- left the section
    elseif cur and line:match("^title=EON%s*$") then
      slot = cur
    end
  end
  f:close()
  return slot, maxn
end

-- Register a script and hand back the "_RS..." string REAPER filed it under.
-- AddRemoveReaScript is idempotent — an already-registered script returns its
-- existing id rather than a duplicate — so this is safe to run repeatedly.
local function command_id(dir, script)
  local path = dir .. sep .. script
  local f = io.open(path, "r")
  if not f then return nil end                     -- not installed; skip it
  f:close()
  local num = reaper.AddRemoveReaScript(true, 0, path, false)
  if not num or num <= 0 then return nil end
  local str = reaper.ReverseNamedCommandLookup(num)
  return str and ("_" .. str) or nil
end

-- Build the toolbar. `dir` = the folder holding the EON_*.lua action scripts
-- (i.e. the parent of this file's own EON/ directory).
-- Returns ok, message.
function M.build(dir)
  local slot, maxn = M.scan()
  if slot then
    return false, "An EON toolbar already exists (Floating toolbar " .. slot .. ")."
  end

  local target = maxn + 1
  local lines, missing = {}, {}
  lines[#lines + 1] = ""
  lines[#lines + 1] = "[Floating toolbar " .. target .. "]"
  lines[#lines + 1] = "title=EON"

  local idx = 0
  for _, b in ipairs(M.BUTTONS) do
    local cmd
    if b.script then
      cmd = command_id(dir, b.script)
      if not cmd then missing[#missing + 1] = b.script end
    else
      cmd = "-1"                                   -- label: no action
    end
    if cmd then
      lines[#lines + 1] = "icon_" .. idx .. "=" .. b.icon
      lines[#lines + 1] = "item_" .. idx .. "=" .. cmd .. " " .. b.label
      idx = idx + 1
    end
  end
  -- Commit the registrations in one pass (each call above passed commit=false).
  reaper.AddRemoveReaScript(true, 0, dir .. sep .. "EON_Register_Actions.lua", true)

  if idx == 0 then
    return false, "No EON action scripts found in:\n" .. dir
  end

  -- Back up before touching a file that holds the user's own toolbars.
  local p = menu_path()
  local cur = ""
  local f = io.open(p, "r")
  if f then cur = f:read("*a"); f:close()
    local bak = io.open(p .. ".eon-backup", "w")
    if bak then bak:write(cur); bak:close() end
  end

  -- APPEND ONLY. Existing sections are never parsed, rewritten or reordered —
  -- a formatting quirk in someone's hand-edited file must not become our bug.
  if #cur > 0 and cur:sub(-1) ~= "\n" then cur = cur .. "\n" end
  local out = io.open(p, "w")
  if not out then return false, "Could not write:\n" .. p end
  out:write(cur .. table.concat(lines, "\n") .. "\n")
  out:close()

  local msg = "EON toolbar created (Floating toolbar " .. target .. ")"
    .. " with " .. idx .. " buttons.\n\n"
    .. "RESTART REAPER for it to appear — REAPER keeps toolbars in memory and\n"
    .. "would overwrite this file on exit otherwise.\n\n"
    .. "Then: View > Toolbars > Floating toolbar " .. target
    .. ", or the TOOLBAR button in Swing."
  if #missing > 0 then
    msg = msg .. "\n\nSkipped (not installed): " .. table.concat(missing, ", ")
  end
  return true, msg
end

-- Find it, or offer to make it. Returns the slot if one exists (caller opens
-- it), or nil after handling the build prompt itself.
function M.ensure(dir)
  local slot = M.scan()
  if slot then return slot end
  local yes = reaper.ShowMessageBox(
    "No EON toolbar found.\n\nCreate it now? This adds a new floating toolbar "
      .. "and leaves any toolbars you already have untouched.",
    "EON Toolbar", 4) == 6                          -- 4 = Yes/No, 6 = Yes
  if yes then
    local ok, msg = M.build(dir)
    reaper.ShowMessageBox(msg, ok and "EON Toolbar" or "EON Toolbar — not created", 0)
  end
  return nil
end

return M
