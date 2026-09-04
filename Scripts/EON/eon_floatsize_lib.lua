-- @noindex
-- eon_floatsize_lib.lua
--
-- Shared measurement for the FloatSize scripts (EON_FloatSize_Capture, _Watch,
-- _Export). Loaded with dofile(); returns a table of functions.
--
-- THE MODEL: every size is a CANVAS size -- the JSFX gfx canvas, the thing the
-- eye actually sees -- never the outer window. The outer window is the canvas
-- plus REAPER's chrome (title bar + the preset/Param toolbar), and the chrome
-- moves with OS, DPI and REAPER version, so an outer size is only ever right
-- on the machine that stored it. A canvas size is right everywhere.
--
-- The canvas is its own child window of the floating FX window, class
-- "jsfx_gfx" (fbwin_probe 2026-08-29, floatsize_canvas_probe 2026-09-04).
-- Resizing the OUTER window by (target - current canvas) lands the canvas on
-- the target exactly, growing or shrinking below @gfx alike, and gfx_w/gfx_h
-- inside the plugin follow to the pixel.
--
-- DISPLAY SCALE: window rects are in the OS's window pixels. On Windows that
-- is physical pixels, so a canvas of N logical px measures N x scale. REAPER's
-- GetWindowDPIScalingForDialog is not a Lua function (probed 2026-09-04), so
-- the scale is read off a FRESH window instead: a float nobody has sized yet
-- opens at @gfx x scale, and @gfx is known. On macOS rects are points and the
-- ratio comes out 1, which is the right answer there.
--
-- Two kinds of stored size, deliberately different:
--   * a user CAPTURE is this machine's own window px, applied as-is, so it
--     round-trips exactly and needs no scale at all;
--   * the shipped TABLE (EON/eon_float_sizes.lua) is logical px, at 100%,
--     multiplied by the scale a fresh window reveals.

local r = reaper
local L = {}

L.EXT = "EON_FloatSize"

-- ── Identity ────────────────────────────────────────────────────────────────
-- fx_ident is the JSFX path: renaming an FX in the chain keeps its size, and
-- two different plugins with one display name stay apart. Display name only
-- where fx_ident is unavailable.
function L.fx_ident(tr, fx)
  if r.TrackFX_GetNamedConfigParm then
    local ok, val = r.TrackFX_GetNamedConfigParm(tr, fx, "fx_ident")
    if ok and val and val ~= "" then return val end
  end
  return nil
end

function L.fx_key(tr, fx)
  local ident = L.fx_ident(tr, fx)
  if not ident then
    local _, nm = r.TrackFX_GetFXName(tr, fx, "")
    ident = nm or ""
  end
  ident = ident:gsub("\\", "/")
  local base = ident:match("([^/]+)$") or ident
  base = base:gsub("%.[%w]+$", "")            -- drop .jsfx / .dll / .vst3
  base = base:gsub("[^%w%-_]", "_")
  return base
end

-- ── Windows ─────────────────────────────────────────────────────────────────
-- Magnitudes for w/h: on a flipped or secondary display the rect can come
-- back with bottom < top. `inv` remembers that so on-screen nudging skips an
-- axis it cannot reason about.
function L.rect(h)
  if not h then return nil end
  local ok, l, t, rt, b = r.JS_Window_GetRect(h)
  if not ok then return nil end
  return { x = l, y = t, w = math.abs(rt - l), h = math.abs(b - t), inv = (b < t) }
end

-- js_ReaScriptAPI has returned the class name in either slot across versions.
local function classname(h)
  local a, b = r.JS_Window_GetClassName(h, "")
  if type(a) == "string" and a ~= "" then return a end
  if type(b) == "string" and b ~= "" then return b end
  return ""
end

-- The jsfx_gfx child of a floating FX window, or nil for anything that is
-- not a JSFX with a canvas. A VST or CLAP float sizes itself and is not ours.
function L.find_canvas(hwnd)
  if not hwnd or not r.JS_Window_ArrayAllChild then return nil end
  local arr = r.new_array({}, 256)
  local n = r.JS_Window_ArrayAllChild(hwnd, arr)
  if not n or n <= 0 then return nil end
  local t = arr.table(1, n)
  for i = 1, n do
    local h = r.JS_Window_HandleFromAddress(t[i])
    if h and classname(h):lower():find("jsfx_gfx", 1, true) then return h end
  end
  return nil
end

-- Put the canvas at tw x th by resizing the OUTER window by the difference.
-- The top-left stays where REAPER put it unless the new size would hang off
-- the monitor, in which case the window slides back on.
function L.set_canvas(hwnd, canvas, tw, th)
  local o, c = L.rect(hwnd), L.rect(canvas)
  if not o or not c then return false end
  tw, th = math.floor(tw + 0.5), math.floor(th + 0.5)
  if tw < 40 or th < 40 then return false end         -- Capture's floor: anything smaller is garbage
  local nw, nh = o.w + (tw - c.w), o.h + (th - c.h)
  local nx, ny = o.x, o.y
  if r.JS_Window_GetViewportFromRect and not o.inv then
    local vl, vt, vr, vb = r.JS_Window_GetViewportFromRect(o.x, o.y, o.x + nw, o.y + nh, true)
    if vr and nx + nw > vr then nx = math.max(vl or nx, vr - nw) end
    if vb and ny + nh > vb then ny = math.max(vt or ny, vb - nh) end
  end
  r.JS_Window_SetPosition(hwnd, nx, ny, nw, nh)
  return true
end

-- ── Display scale from a fresh window ───────────────────────────────────────
-- The steps Windows offers; anything else (a custom percentage) simply never
-- reads as fresh, and the plugin opens at @gfx as it always did.
local STEPS = { 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3, 3.5, 4 }

function L.snap_scale(ratio)
  if not ratio or ratio ~= ratio then return nil end
  for _, s in ipairs(STEPS) do
    if math.abs(ratio - s) <= 0.02 then return s end
  end
  return nil
end

-- The scale a FRESH float reveals, or nil when the window is not fresh.
-- REAPER keeps a float's size in-session and in the project (FLOAT x y w h;
-- floatsize_restore_probe 2026-09-04), so a canvas that is not what REAPER
-- itself would have opened is a size somebody chose, and it is left alone.
--
-- What REAPER opens is @gfx x scale, bent two ways and only two
-- (floatsize_minsize_probe 2026-09-04):
--   * WIDER: the FX float has a minimum width (505 outer here) and a
--     narrow @gfx gets stretched, or centred inside, that minimum -- Drum
--     Strip at 300 opens 432 wide. Never narrower than @gfx, so
--     sw = c.w / gfx_w >= true scale.
--   * SHORTER: a tall @gfx times a laptop's scale can outgrow the screen,
--     and the window then ends at the monitor's edge. Never taller, so
--     sh = c.h / gfx_h <= true scale.
-- The true scale therefore sits between them: sh <= s_true <= sw. When both
-- snap to the same step, that IS the scale. When they snap to different
-- steps, one side was bent onto a step by coincidence -- the disambiguator
-- is whether the window's bottom is on the screen edge (height was bent
-- shorter, sw is the truth) or not (width was bent wider, sh is the truth).
local function bottom_on_edge(hwnd)
  if not r.JS_Window_GetViewportFromRect then return false end
  local o = L.rect(hwnd)
  if not o or o.inv then return false end
  local bottom = o.y + o.h
  local _, _, _, vb  = r.JS_Window_GetViewportFromRect(o.x, o.y, o.x + o.w, bottom, true)
  local _, _, _, vb2 = r.JS_Window_GetViewportFromRect(o.x, o.y, o.x + o.w, bottom, false)
  return (vb and math.abs(bottom - vb) <= 2) or (vb2 and math.abs(bottom - vb2) <= 2) or false
end

function L.fresh_scale(hwnd, c, gfx_w, gfx_h)
  if not c or not gfx_w or gfx_w <= 0 or not gfx_h or gfx_h <= 0 then return nil end
  local sw, sh  = L.snap_scale(c.w / gfx_w), L.snap_scale(c.h / gfx_h)
  local h_short = bottom_on_edge(hwnd)     -- height was bent SHORTER (screen edge)
  local s
  if sw and sh then
    if sw == sh then s = sw
    else s = h_short and sw or sh end      -- differ: bottom on edge -> sw is truth
  else
    s = sh or sw                            -- only one snapped
  end
  if not s then return nil end
  local h_ok = (sh == s) or h_short
  local w_ok = (sw == s) or (c.w >= gfx_w * s - 2)
  if h_ok and w_ok then return s end
  return nil
end

-- ── Stored captures (this machine's window px) ──────────────────────────────
-- <key>_cw / <key>_ch  canvas size, this machine's px  (what Capture writes)
-- <key>_ident          the fx_ident, so the export can read the plugin's @gfx
-- <key>_w / <key>_h    LEGACY: an OUTER size from the pair as it was before
--                      2026-09-04. Converted per plugin, once, by
--                      convert_legacy() the first time that plugin's float
--                      is seen; a customer never has one.
-- keys                 index of every key above, because ExtState cannot
--                      be enumerated
function L.get_capture(key)
  local w = tonumber(r.GetExtState(L.EXT, key .. "_cw"))
  local h = tonumber(r.GetExtState(L.EXT, key .. "_ch"))
  if w and h and w > 0 and h > 0 then return w, h end
  return nil
end

function L.get_legacy(key)
  local w = tonumber(r.GetExtState(L.EXT, key .. "_w"))
  local h = tonumber(r.GetExtState(L.EXT, key .. "_h"))
  if w and h and w > 0 and h > 0 then return w, h end
  return nil
end

local function index_add(key)
  local keys = r.GetExtState(L.EXT, "keys")
  for k in (keys .. ","):gmatch("([^,]*),") do
    if k == key then return end
  end
  r.SetExtState(L.EXT, "keys", keys == "" and key or (keys .. "," .. key), true)
end

function L.set_capture(key, w, h, ident)
  r.SetExtState(L.EXT, key .. "_cw", tostring(math.floor(w + 0.5)), true)
  r.SetExtState(L.EXT, key .. "_ch", tostring(math.floor(h + 0.5)), true)
  if ident and ident ~= "" then r.SetExtState(L.EXT, key .. "_ident", ident, true) end
  r.DeleteExtState(L.EXT, key .. "_w", true)     -- a legacy outer size is superseded
  r.DeleteExtState(L.EXT, key .. "_h", true)
  index_add(key)
end

-- The export reads @gfx from the plugin source, which it finds by ident. A
-- capture made without one picks it up the next time that plugin's float
-- is seen.
function L.note_ident(key, ident)
  if ident and ident ~= "" and r.GetExtState(L.EXT, key .. "_ident") == "" then
    r.SetExtState(L.EXT, key .. "_ident", ident, true)
  end
end

-- A legacy OUTER capture, met on its own plugin's live float. The canvas
-- tracks the outer window 1:1 (every probe), and each plugin keeps its own
-- distance between the two -- the Drum Strip's canvas sits 57 px narrower
-- than its client area, Swing's fills it -- so the conversion has to be
-- done against THIS plugin's window, not a chrome constant. Applies the old
-- size exactly as the old Watch did, stores the canvas that gives, and
-- drops the old keys. Returns the canvas size, or nil if not legacy.
function L.convert_legacy(hwnd, canvas, key)
  local w, h = L.get_legacy(key)
  if not w then return nil end
  local o, c = L.rect(hwnd), L.rect(canvas)
  if not o or not c then return nil end
  local cw, ch = w - (o.w - c.w), h - (o.h - c.h)
  if cw < 40 or ch < 40 then return nil end
  L.set_capture(key, cw, ch, nil)
  return cw, ch
end

-- Every key with a capture (canvas or legacy). The index covers everything
-- written since it existed; reaper-extstate.ini (written at exit) covers
-- captures from before it did.
function L.captured_keys()
  local set, list = {}, {}
  local function add(k)
    if k and k ~= "" and not set[k] and (L.get_capture(k) or L.get_legacy(k)) then
      set[k] = true
      list[#list + 1] = k
    end
  end
  for k in (r.GetExtState(L.EXT, "keys") .. ","):gmatch("([^,]*),") do add(k) end
  local f = io.open(r.GetResourcePath() .. "/reaper-extstate.ini", "r")
  if f then
    local insec = false
    for line in f:lines() do
      local sec = line:match("^%[(.-)%]%s*$")
      if sec then
        insec = (sec == L.EXT)
      elseif insec then
        add(line:match("^(.-)_cw=") or line:match("^(.-)_w="))
      end
    end
    f:close()
  end
  table.sort(list)
  return list
end

-- ── The shipped table ───────────────────────────────────────────────────────
-- { [key] = { w=, h=, gfx_w=, gfx_h= }, ... } in logical px. Absent or broken
-- reads as empty: nothing is sized that the author did not size.
function L.load_table(script_dir)
  local path = script_dir .. "/EON/eon_float_sizes.lua"
  local ok, t = pcall(dofile, path)
  if ok and type(t) == "table" then return t end
  return {}
end

return L
