-- @description EON: Install / Refresh Actions
-- @version 1.0
-- @author EON Studios
-- @about
--   Registers the full EON action catalog into the REAPER Action List in one
--   pass (Swing panel ops, kit management, and the Drum Matrix scripts) so you
--   can keybind or toolbar any of them. Idempotent: re-running never creates
--   duplicates. The Swing bridge fires this once on first run after an update;
--   you can also run it by hand any time to pick up newly added scripts.
--
-- Enumerates EON_*.lua under this folder and under "EON/Drum Matrix/", skipping
-- background companions, internal sync bridges, and dev/test probes.
-- (c) EON Studios

local sep = package.config:sub(1, 1)

-- Resolve our own folder robustly whether run as an action or via dofile().
--
-- ⚠️ NORMALISE THE SEPARATORS. REAPER keys a registered script by its path
-- STRING, not by the file it resolves to, so "…\installer\src\…" and
-- "…\installer\\src\\…" register as two different actions pointing at one file.
-- That is exactly how this catalogue accumulated duplicates: the bridge invokes
-- us as bdir .. "/EON_Register_Actions.lua" while a manual run arrives with
-- whatever REAPER stored, and debug.getinfo faithfully reports each spelling.
-- Collapsing every run of separators to one canonical `sep` makes repeat runs
-- converge instead of forking. (gsub returns two values — the parens matter.)
-- ⚠️ TRAILING separator must go too. "^(.*)[/\\]" is greedy, so on a path that
-- already contains a doubled separator it captures one of the pair and leaves
-- base_dir ending in one — and then `dir .. sep .. fn` re-doubles it at the
-- join. Collapsing runs alone is not enough; that half-fix produced a fresh
-- crop of "…\.Scripts\\file.lua" rows.
local src = debug.getinfo(1, "S").source:match("^@?(.*)$") or ""
local base_dir = src:match("^(.*)[/\\]") or "."
base_dir = base_dir:gsub("[/\\]+", sep)
base_dir = base_dir:gsub("[/\\]+$", "")
local dm_dir   = base_dir .. sep .. "EON" .. sep .. "Drum Matrix"

-- Never expose these as user actions:
--   * background companions that self-register as startup actions
--   * internal StepSeq sync bridges
--   * this registrar itself (registered separately below, once)
local BLOCK = {
  ["EON_Register_Actions.lua"]     = true,
  ["EON_UpdateCheck.lua"]          = true,
  ["EON_Swing_Strip_Sync.lua"]     = true,
  ["EON_StepSeq_Sync_Courier.lua"] = true,
  ["EON_StepSeq_Sync_Probe.lua"]   = true,
}

local function excluded(name)
  if BLOCK[name] then return true end
  -- dev/test/diagnostic scripts
  if name:find("TEST") or name:find("Test") or name:find("Diag") then return true end
  return false
end

-- A @noindex header marks a dofile-only library, never a runnable action. This
-- is what lets the filter below accept lowercase names without dragging
-- eon_action_target / eon_menu_lib / eon_toolbar and friends into the Action
-- List: they all carry the marker, and the one lowercase file that is a real
-- entry point (eon_drum_matrix.lua) does not.
local function is_library(path)
  local f = io.open(path, "r")
  if not f then return false end
  local head = f:read(400) or ""
  f:close()
  return head:find("@noindex", 1, true) ~= nil
end

-- Collect candidate full paths from a directory.
-- ⚠️ The match is CASE-INSENSITIVE. It used to be "^EON_", which silently
-- excluded eon_drum_matrix.lua — the Drum Matrix's own entry point, and the
-- one script a user is most likely to want on a toolbar. It could never be
-- auto-registered, so any button pointing at it depended on a hand
-- registration and died the moment the file moved.
local function collect(dir, out)
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn or fn == "" then break end
    i = i + 1
    if fn:lower():match("^eon_") and fn:match("%.lua$") and not excluded(fn) then
      local full = dir .. sep .. fn
      if not is_library(full) then out[#out + 1] = full end
    end
  end
end

local paths = {}
collect(base_dir, paths)
collect(dm_dir, paths)

-- Register everything. AddRemoveReaScript(add=true) is idempotent — an already
-- registered script just returns its existing command id. Commit only on the
-- final call so the action list / reaper-kb.ini is rewritten once.
local n = #paths
local registered = 0
for idx = 1, n do
  local commit = (idx == n)
  local id = reaper.AddRemoveReaScript(true, 0, paths[idx], commit)
  if id and id > 0 then registered = registered + 1 end
end

-- Make sure this registrar itself is in the action list too, so users can find
-- "EON: Install / Refresh Actions".
reaper.AddRemoveReaScript(true, 0, base_dir .. sep .. "EON_Register_Actions.lua", true)

-- Stay silent when the bridge auto-fires us at startup; report on manual runs.
if reaper.GetExtState("EON_Actions", "silent") ~= "1" then
  reaper.ShowConsoleMsg(
    ("[EON] Registered %d/%d actions into the Action List (filter \"EON\" to see them).\n")
      :format(registered, n))
end
