-- rk_lua_icons.lua — EON ReaKit P2. Resolve a drum category to a REAPER
-- P_ICON absolute path. ONE source of truth for which icon represents
-- which drum type, shared by Drum Matrix lane tracks, audio multi-out
-- tracks, the Swing Browser, and any future instrument (Coupe / Sedan).
--
-- Why this lives at Scripts/ root (next to rk_lua_core)
-- ─────────────────────────────────────────────────────
-- The bridge needs icon resolution for audio multi-out tracks even when
-- the Drum Matrix isn't installed. Putting it in DM/lib/ would couple
-- bridge functionality to DM. Sibling to rk_lua_core lets both reach it
-- via the same package.path the bridge already sets up.
--
-- Resolution order (first hit wins)
-- ─────────────────────────────────
--   1. <resource>/Effects/EON_ReaKit_Bundle/installer/src/Swing/icons/
--        <category>.png — your branded art. Drop a PNG named after the
--        category and it overrides REAPER's built-in for that one type.
--   2. <reaper-install>/Data/track_icons/<reaper-name>.png — the icons
--        REAPER ships. Mapped to our category names via BUILTIN_FILE.
--   3. nil — track_reflect leaves P_ICON unchanged.
--
-- Result is cached per category (and the cache is module-local — once a
-- category's lookup has hit/missed, the file_exists check doesn't run
-- again that REAPER session). Drop a new icon while REAPER is running →
-- restart REAPER (or call M.ClearCache from the console).

local M = {}

-- Category → REAPER built-in track-icon filename. Mapping curated against
-- the actual files that ship in REAPER's track_icons folders. If REAPER
-- renames or removes one of these in a future release, the entry just
-- stops resolving and we fall through to nil (no icon, no crash).
--
-- Categories where REAPER ships NO sensible built-in are deliberately
-- absent from this table so they fall through to nil and the track keeps
-- REAPER's default — better than painting a wrong-looking drum on a clap
-- or tambourine track. Drop a custom <category>.png into the bundle's
-- Swing/icons/ folder to give those categories their own art.
local BUILTIN_FILE = {
  kick          = "kick.png",
  snare         = "snare_top.png",
  rimshot       = "snare_top.png",        -- closest stand-in (snare technique)
  rim           = "snare_top.png",        -- alias — DM lib/category.lua taxonomy
  -- clap       = no REAPER built-in — bundle ships its own clap.png
  closed_hat    = "hihat.png",
  open_hat      = "hihat.png",
  hihat         = "hihat.png",
  ride          = "ride_bell.png",
  crash         = "cymbal_small.png",
  cymbal        = "cymbal_large.png",
  splash        = "cymbal_small.png",     -- closest built-in (small cymbal)
  china         = "cymbal_large.png",     -- closest built-in (large cymbal)
  sidestick     = "snare_top.png",        -- same stand-in as rimshot
  -- snap       = no REAPER built-in — bundle art can ship snap.png later
  tom           = "tom.png",
  rack_tom      = "tom.png",              -- REAPER has no rack/floor split
  floor_tom     = "tom.png",              -- bundle art provides the variants
  bongo         = "bongos.png",
  conga         = "congas.png",
  cowbell       = "cowbell.png",
  maraca        = "maracas.png",
  shaker        = "cabasa.png",           -- cabasa is the closest shaker family
  tambourine    = "tamborine.png",        -- REAPER ships it (misspelled) — verified 2026-06-11
  -- clave      = no REAPER built-in (no claves.png) — bundle ships its own clave.png
  percussion    = "drumbox.png",          -- generic drum-machine icon
                                          -- (categorizer emits 'percussion')
  perc          = "drumbox.png",          -- alias — DM lib/category.lua taxonomy
  -- Promoted world-perc categories. Closest REAPER built-ins where one
  -- exists; the rest (triangle/woodblock/guiro/agogo/vibraslap/whistle)
  -- deliberately absent → nil until bundle art ships.
  cabasa        = "cabasa.png",
  djembe        = "congas.png",           -- closest hand-drum stand-in
  timbale       = "tom.png",
  cajon         = "drumbox.png",          -- literal box
  -- Melodic categories (categorizer emits these for non-drum lanes) — all
  -- verified present in REAPER's track_icons 2026-06-11. Bundle art may
  -- override any of them later; today only `bass` ships bundle art.
  bass          = "bass.png",
  synth         = "synth.png",
  pad           = "pads.png",
  keys          = "piano.png",
  guitar        = "guitar.png",
  strings       = "violin.png",
  brass         = "trumpet.png",
  -- 'other' deliberately omitted → no icon for the catch-all bucket
}

-- Resource roots (resolved once at module load). Both calls return paths
-- specific to THIS user / THIS REAPER install — never hardcode either of
-- them. A user with REAPER on D:\Audio\REAPER\ gets that; a user with
-- portable REAPER gets the portable path; macOS / Linux likewise.
--   GetResourcePath() → per-user REAPER data dir
--                       (e.g. C:\Users\<u>\AppData\Roaming\REAPER)
--   GetExePath()       → REAPER install dir (location varies, can change)
local _resource = (reaper and reaper.GetResourcePath and reaper.GetResourcePath()) or ""
local _install  = (reaper and reaper.GetExePath      and reaper.GetExePath())      or ""

-- Bundle icon override paths — resolved RELATIVE to this script file, NEVER
-- hardcoded against any user/installer path. Survives every install layout
-- we ship (repo dev, .Scripts launch path, flat installer drop, future
-- alternative packagings) because the resolution chases this file rather
-- than assuming the bundle root is in any particular place. First match
-- wins; missing candidates are silently skipped.
local _SCRIPT_DIR_ICONS = (debug.getinfo(1, 'S').source:match('^@?(.*[\\/])')) or ''
local _bundle_icon_dirs = {
  _SCRIPT_DIR_ICONS .. "../Swing/icons",   -- repo + .Scripts layout (Scripts ↔ Swing siblings)
  _SCRIPT_DIR_ICONS .. "icons",            -- flat ship (icons co-located with Lua)
  _SCRIPT_DIR_ICONS .. "../icons",         -- one-level-up ship variant
}
-- REAPER ships track icons at <install>/InstallData/Data/track_icons and
-- (on first launch) mirrors them to <resource>/Data/track_icons where the
-- user can add or override their own. Check both — resource first because
-- that's where any user-added/replaced icons land.
local _builtin_dirs = {
  _resource .. "/Data/track_icons",
  _install  .. "/InstallData/Data/track_icons",
}

-- Per-category cache. `false` = looked up, no icon found (so we don't
-- redo file_exists every frame). `nil` = not looked up yet.
local _cache = {}

local function _file_exists(path)
  if reaper and reaper.file_exists then return reaper.file_exists(path) end
  local f = io.open(path, "r")
  if f then f:close(); return true end
  return false
end

-- Public: category string → absolute icon path, or nil.
function M.resolve(category)
  if not category or category == "" then return nil end
  local cached = _cache[category]
  if cached == false then return nil end
  if cached then return cached end

  -- 1. Bundle-shipped art (your branding wins over REAPER's built-ins).
  -- Walk all candidate paths — the first one that has this file wins.
  for _, dir in ipairs(_bundle_icon_dirs) do
    local custom = dir .. "/" .. category .. ".png"
    if _file_exists(custom) then
      _cache[category] = custom
      return custom
    end
  end

  -- 2. REAPER built-in. Try the user resource path first (user could have
  -- swapped or added their own there) then the install bundle.
  local builtin_name = BUILTIN_FILE[category]
  if builtin_name then
    for _, dir in ipairs(_builtin_dirs) do
      local builtin = dir .. "/" .. builtin_name
      if _file_exists(builtin) then
        _cache[category] = builtin
        return builtin
      end
    end
  end

  -- 3. No icon available.
  _cache[category] = false
  return nil
end

-- Manual cache reset (call from console after dropping new icons in).
function M.ClearCache() _cache = {} end

-- Public: like resolve(), but picks a hue-tinted variant matching the
-- track's custom color so the icon follows the lane/kit hue. Tints are
-- pre-generated by Swing/icons/gen_icons.py into tints/<bucket>/<cat>.png
-- (12 buckets, 30° hue steps). Falls back to the plain white glyph when:
-- no custom color (flag bit absent / 0), color is grey-ish (no stable
-- hue), or no tinted file exists for the category.
local TINT_BUCKETS = 12
function M.resolve_tinted(category, native_color)
  if not category or category == "" then return nil end
  local col = math.floor(tonumber(native_color) or 0)
  if col == 0 or (col & 0x1000000) == 0 then return M.resolve(category) end
  local r, g, b = reaper.ColorFromNative(col & 0xFFFFFF)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  if (mx - mn) < 24 then return M.resolve(category) end  -- grey: hue unstable
  local d = mx - mn
  local h
  if mx == r then h = ((g - b) / d) % 6
  elseif mx == g then h = (b - r) / d + 2
  else h = (r - g) / d + 4 end
  local bucket = math.floor(h / 6 * TINT_BUCKETS + 0.5) % TINT_BUCKETS
  local key = category .. "|" .. bucket
  local cached = _cache[key]
  if cached == false then return M.resolve(category) end
  if cached then return cached end
  for _, dir in ipairs(_bundle_icon_dirs) do
    local p = dir .. "/tints/" .. bucket .. "/" .. category .. ".png"
    if _file_exists(p) then
      _cache[key] = p
      return p
    end
  end
  _cache[key] = false
  return M.resolve(category)
end

-- Public: guarded P_ICON write that RESPECTS user-set icons.
--
-- Every auto-writer (bridge multi-out refresh, DM lane reflect) used to
-- enforce the resolver's icon each tick, silently stomping any icon the
-- user picked by hand in REAPER's track-icon dialog. The guard remembers
-- the last value WE wrote in P_EXT:EON_ICON_AUTO (persists in the project)
-- and only writes when the track's current icon is still ours:
--   cur == auto  → still our icon (or both empty) → enforce `want`
--   cur == want  → matches what we'd set anyway   → claim it (migrates
--                  tracks iconed by pre-guard builds)
--   otherwise    → the user customised (set OR cleared) → hands off
--
-- `want` semantics match track_reflect: "" clears, "/abs/path.png" sets.
-- Returns true if P_ICON actually changed. track_reflect.lua duplicates
-- this guard inline (it is a dependency-free sink by design) — keep the
-- two in lockstep if the P_EXT key or rules ever change.
function M.apply(track, want)
  if not track or want == nil then return false end
  local _, cur  = reaper.GetSetMediaTrackInfo_String(track, "P_ICON", "", false)
  local _, auto = reaper.GetSetMediaTrackInfo_String(track, "P_EXT:EON_ICON_AUTO", "", false)
  if cur ~= auto and cur ~= want then return false end  -- user-customised
  if auto ~= want then
    reaper.GetSetMediaTrackInfo_String(track, "P_EXT:EON_ICON_AUTO", want, true)
  end
  if cur ~= want then
    reaper.GetSetMediaTrackInfo_String(track, "P_ICON", want, true)
    return true
  end
  return false
end

return M
