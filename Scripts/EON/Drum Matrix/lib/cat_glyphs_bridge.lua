-- cat_glyphs_bridge.lua — EON Drum Matrix glue for the shared 46-category
-- vector glyphs (rk_lua_cat_glyphs.lua, the ReaImGui DrawList transcription of
-- rk_cat_glyphs.jsfx-inc). Pairs each pad NAME with a glyph id via the shared
-- eon_filename_categorizer (46 categories — NOT DM's internal 11-cat
-- category.lua, which keeps driving preset matching untouched).
--
-- Both dependencies are pcall-loaded from Scripts root (swing_sync.lua
-- precedent): if either file is missing the feature vanishes gracefully —
-- callers must gate on M.Available() or the nil from IdForName().
--
-- classify() is scoring-based (not cheap per frame) -> name→id memoized.

local M = {}
local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

local _glyphs, _categorizer
do
  local scripts_root = _SCRIPT_DIR .. '../../../'   -- lib/ -> DM -> EON -> Scripts root
  local ok, mod = pcall(dofile, scripts_root .. 'rk_lua_cat_glyphs.lua')
  if ok and type(mod) == 'table' and mod.draw then _glyphs = mod end
  local ok2, m2 = pcall(dofile, scripts_root .. 'eon_filename_categorizer.lua')
  if ok2 and type(m2) == 'table' and m2.classify then _categorizer = m2 end
end

function M.Available() return _glyphs ~= nil and _categorizer ~= nil end

local _cache = {}   -- name -> glyph id (pad names: bounded in practice)
function M.IdForName(name)
  if not (_glyphs and _categorizer) or not name or name == '' then return nil end
  local id = _cache[name]
  if id == nil then
    local cat = _categorizer.classify(name)
    id = _glyphs.ID[cat] or _glyphs.ID.other
    _cache[name] = id
  end
  return id
end

-- col = 0xRRGGBBAA, th = stroke px. No-op when the module is absent or id nil.
function M.Draw(dl, id, cx, cy, s, col, th)
  if _glyphs and id then _glyphs.draw(dl, id, cx, cy, s, col, th) end
end

return M
