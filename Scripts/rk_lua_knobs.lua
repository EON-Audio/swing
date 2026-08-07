-- ReaKit Lua Knobs — JSFX knob-skin parity for ImGui panels
-- (c) EON Studios — All Rights Reserved
--
-- 1:1 ports of the Swing JSFX knob styles (installer/src/Swing/libs/knobs_kbsg.jsfx-inc)
-- into ReaImGui DrawList, so the Pad FX / Browser panels render the SAME knobs as
-- the plugin. The JSFX is the SOURCE OF TRUTH: each K.<style> below is a near
-- line-for-line transcription of the matching <style>_knob_draw EEL2 function.
-- When a JSFX knob changes, mirror the change here (line ranges noted per style).
--
-- Only the VISUAL is ported. Interaction is uniform in the JSFX (ssl_knob_interact)
-- and already handled by rk_lua_widgets w.knob, so it is NOT duplicated here.
--
-- Usage:
--   local knobs = require("rk_lua_knobs"); knobs.init(ImGui)
--   local g = knobs.pen(draw_list)
--   knobs.draw(style, g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t,
--              cr, cg, cb, n_detents, bgr, bgg, bgb)

local K = {}
local ImGui

function K.init(_ImGui) ImGui = _ImGui end

-- ── EEL2 gfx shim ───────────────────────────────────────────────────────────
-- A "pen" wraps one DrawList + a current color, mirroring gfx_set/gfx_circle/
-- gfx_line so the ported bodies read like the EEL2 source. Floats are 0..1.

local PI = math.pi
local TAU = PI * 2
local floor, sin, cos, sqrt = math.floor, math.sin, math.cos, math.sqrt
local function lerp(a, b, t) return a + (b - a) * t end
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function rgba(r, g, b, a)
  r = r < 0 and 0 or (r > 1 and 1 or r)
  g = g < 0 and 0 or (g > 1 and 1 or g)
  b = b < 0 and 0 or (b > 1 and 1 or b)
  a = a < 0 and 0 or (a > 1 and 1 or a)
  return (floor(r * 255 + 0.5) << 24) | (floor(g * 255 + 0.5) << 16)
       | (floor(b * 255 + 0.5) << 8) | floor(a * 255 + 0.5)
end

-- Circle segment count scaled by radius (small knobs must not look polygonal,
-- large ones don't need 200 segs). gfx_circle is smoothly AA'd; this approximates.
local function seg_for(r)
  local n = floor(r * 1.4)
  return n < 14 and 14 or (n > 64 and 64 or n)
end

local Pen = {}
Pen.__index = Pen
function K.pen(dl) return setmetatable({ dl = dl, col = 0xFFFFFFFF }, Pen) end
function Pen:set(r, g, b, a) self.col = rgba(r, g, b, a or 1) end
function Pen:circle(cx, cy, r, fill)
  if r <= 0 then return end
  if fill == 1 then
    ImGui.DrawList_AddCircleFilled(self.dl, cx, cy, r, self.col, seg_for(r))
  else
    ImGui.DrawList_AddCircle(self.dl, cx, cy, r, self.col, seg_for(r), 1.0)
  end
end
function Pen:line(x1, y1, x2, y2, thick)
  ImGui.DrawList_AddLine(self.dl, x1, y1, x2, y2, self.col, thick or 1.0)
end
function Pen:triangle(x1, y1, x2, y2, x3, y3)
  ImGui.DrawList_AddTriangleFilled(self.dl, x1, y1, x2, y2, x3, y3, self.col)
end
function Pen:quad(x1, y1, x2, y2, x3, y3, x4, y4)
  ImGui.DrawList_AddQuadFilled(self.dl, x1, y1, x2, y2, x3, y3, x4, y4, self.col)
end
-- Open arc stroke. EEL2 gfx_arc angles: 0 = up (12 o'clock), +CW. ImGui PathArcTo
-- uses 0 = +x; convert with −pi/2. Strokes are direction-agnostic, so order the
-- endpoints (a reversed bipolar span draws the same line either way).
local HALFPI = PI * 0.5
function Pen:arc(cx, cy, r, a1, a2, thick)
  if r <= 0 then return end
  local s1, s2 = a1 - HALFPI, a2 - HALFPI
  if s2 < s1 then s1, s2 = s2, s1 end
  ImGui.DrawList_PathArcTo(self.dl, cx, cy, r, s1, s2)
  ImGui.DrawList_PathStroke(self.dl, self.col, 0, thick or 1.0)
end

-- ── Style ports ──────────────────────────────────────────────────────────────

-- SSL — knobs_kbsg.jsfx-inc ssl_knob_draw (lines 525–576). Knurled body, colored
-- cap, white 3-line pointer, detent dots at 1.25r. is_sym is unused (parity).
function K.ssl(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, n_detents)
  n_detents = n_detents or 0
  local ht = hover_t ^ 2
  local cap_a = lerp(0.7, 1.0, ht)
  local ring_bright = lerp(0.45, 0.70, ht)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_deg = value * scale + voffset
  local val_rad = val_deg * PI / 180
  -- Knurled body
  g:set(0.12, 0.12, 0.14, 1)
  g:circle(cx, cy, radius, 1)
  g:set(ring_bright, ring_bright, ring_bright + 0.02, 1)
  g:circle(cx, cy, radius * 0.92, 0)
  g:circle(cx, cy, radius * 0.85, 0)
  g:circle(cx, cy, radius * 0.78, 0)
  -- Colored cap
  g:set(cr, cg, cb, cap_a)
  g:circle(cx, cy, radius * 0.55, 1)
  g:set(cr * 0.6, cg * 0.6, cb * 0.6, cap_a)
  g:circle(cx, cy, radius * 0.55, 0)
  -- White pointer (3 lines for thickness)
  g:set(0.95, 0.95, 0.95, 1)
  local ptr_len = radius * 0.82
  local px = sin(val_rad) * ptr_len
  local py = -cos(val_rad) * ptr_len
  g:line(cx, cy, cx + px, cy + py)
  g:line(cx + cos(val_rad), cy + sin(val_rad),
         cx + px + cos(val_rad), cy + py + sin(val_rad))
  g:line(cx - cos(val_rad), cy - sin(val_rad),
         cx + px - cos(val_rad), cy + py - sin(val_rad))
  -- Detent dots
  if n_detents > 0 then
    local det_step = (vmax - vmin) / math.max(1, n_detents - 1)
    local active_det = floor((value - vmin) / det_step + 0.5)
    for i = 0, n_detents - 1 do
      local da = (-130 + i * 260 / math.max(1, n_detents - 1)) * PI / 180
      local dx = cx + sin(da) * radius * 1.25
      local dy = cy - cos(da) * radius * 1.25
      if i == active_det then
        g:set(cr, cg, cb, cap_a)
        g:circle(dx, dy, radius * 0.08, 1)
      else
        g:set(0.4, 0.4, 0.4, lerp(0.5, 0.8, ht))
        g:circle(dx, dy, radius * 0.05, 1)
      end
    end
  end
end

-- Vari-Mu — varimu_knob_draw (lines 1308–1377). Anodised brushed-silver body
-- (accent chroma pushed into the silver), concentric rings, recessed hub, thin
-- white pointer. 270° sweep. No detents/bg/is_sym.
function K.varimu(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb)
  local ht = hover_t ^ 2
  local ba = lerp(0.85, 1.0, ht)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  -- Anodised tint: push accent chroma into the silver
  local lum = (cr + cg + cb) * 0.33333
  local atr = (cr - lum) * 0.5
  local atg = (cg - lum) * 0.5
  local atb = (cb - lum) * 0.5
  -- Outer rim
  g:set(0.22, 0.22, 0.24, 1)
  g:circle(cx, cy, radius, 1)
  -- Silver body (anodised toward accent)
  local base_g = 0.62 + 0.06 * ht
  g:set(base_g + atr, base_g + atg, base_g + 0.01 + atb, ba)
  g:circle(cx, cy, radius * 0.92, 1)
  -- Brushed-metal concentric rings
  local hi_g = base_g + 0.06
  local lo_g = base_g - 0.05
  for i = 0, 5 do
    local ring_r = radius * (0.85 - i * 0.09)
    if ring_r > radius * 0.35 then
      local ring_a = (i % 2 == 0) and hi_g or lo_g
      g:set(ring_a + atr, ring_a + atg, ring_a + 0.01 + atb, 0.45)
      g:circle(cx, cy, ring_r, 0)
    end
  end
  -- Recessed center hub
  g:set(0.15, 0.15, 0.17, 1); g:circle(cx, cy, radius * 0.22, 1)
  g:set(0.10, 0.10, 0.12, 1); g:circle(cx, cy, radius * 0.16, 1)
  -- Pointer line (thin white, thickened by 1px offset)
  local ptr_in  = radius * 0.28
  local ptr_out = radius * 0.88
  g:set(0.95, 0.95, 0.97, 1)
  g:line(cx + sin(val_rad) * ptr_in,  cy - cos(val_rad) * ptr_in,
         cx + sin(val_rad) * ptr_out, cy - cos(val_rad) * ptr_out)
  g:line(cx + sin(val_rad) * ptr_in  + cos(val_rad),
         cy - cos(val_rad) * ptr_in  + sin(val_rad),
         cx + sin(val_rad) * ptr_out + cos(val_rad),
         cy - cos(val_rad) * ptr_out + sin(val_rad))
  -- Hover glow
  if hover_t > 0.01 then
    g:set(cr * 0.6 + 0.4, cg * 0.6 + 0.4, cb * 0.6 + 0.4, 0.25 * ht)
    g:circle(cx, cy, radius + 2, 0)
    g:circle(cx, cy, radius + 3, 0)
  end
end

-- Neve 1073 — neve_knob_draw. Fluted satin cap (24 scallops), satin dome,
-- cream pointer line, panel tick scale. 1:1 with knobs_kbsg 2026-07 redesign.
local function neve_detents(g, cx, cy, radius, value, vmin, vmax, ht, ba, n_det)
  local ds = (vmax - vmin) / math.max(1, n_det - 1)
  local ad = floor((value - vmin) / ds + 0.5)
  for i = 0, n_det - 1 do
    local da = (-130 + i * 260 / math.max(1, n_det - 1)) * PI / 180
    local dx = cx + sin(da) * radius * 1.25
    local dy = cy - cos(da) * radius * 1.25
    if i == ad then
      g:set(1, 1, 1, ba); g:circle(dx, dy, radius * 0.06, 1)
    else
      g:set(0.4, 0.4, 0.4, lerp(0.4, 0.7, ht)); g:circle(dx, dy, radius * 0.04, 1)
    end
  end
end

-- Wide pointer line as a quad (r0→r1 at val_rad, halfwidth hw)
local function pointer_quad(g, cx, cy, val_rad, r0, r1, hw)
  local pxp, pyp = cos(val_rad), sin(val_rad)
  local sxp, cyp = sin(val_rad), cos(val_rad)
  g:quad(cx + sxp * r0 + pxp * hw, cy - cyp * r0 + pyp * hw,
         cx + sxp * r0 - pxp * hw, cy - cyp * r0 - pyp * hw,
         cx + sxp * r1 - pxp * hw, cy - cyp * r1 - pyp * hw,
         cx + sxp * r1 + pxp * hw, cy - cyp * r1 + pyp * hw)
end

function K.neve(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb, n_det)
  n_det = n_det or 0
  local ht = hover_t ^ 2
  local ba = lerp(0.85, 1.0, ht)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  -- Panel tick scale (skipped when detent dots are shown)
  if n_det == 0 then
    for i = 0, 10 do
      local ta = (-130 + i * 26) * PI / 180
      g:set(0.63, 0.65, 0.70, lerp(0.30, 0.50, ht))
      g:line(cx + sin(ta) * radius * 0.99, cy - cos(ta) * radius * 0.99,
             cx + sin(ta) * radius * 1.12, cy - cos(ta) * radius * 1.12)
    end
  end
  -- Drop shadow + fluted cap base
  g:set(0, 0, 0, 0.35); g:circle(cx + 1, cy + 2, radius, 1)
  g:set(cr * 0.62, cg * 0.62, cb * 0.62, ba); g:circle(cx, cy, radius, 1)
  -- 24 flutes: light crest / dark trough quads on the rim band
  local fw = radius * 0.055
  for i = 0, 23 do
    local ca = i / 24 * TAU
    g:set(math.min(cr * 1.10 + 0.10, 1), math.min(cg * 1.10 + 0.10, 1), math.min(cb * 1.10 + 0.10, 1), 0.45 * ba)
    pointer_quad(g, cx, cy, ca, radius * 0.80, radius * 0.985, fw)
    local ta = (i + 0.5) / 24 * TAU
    g:set(cr * 0.28, cg * 0.28, cb * 0.28, 0.60)
    pointer_quad(g, cx, cy, ta, radius * 0.80, radius * 0.965, fw)
  end
  g:set(cr * 0.30, cg * 0.30, cb * 0.30, 1)
  g:circle(cx, cy, radius, 0)
  g:circle(cx, cy, radius - 0.5, 0)
  -- Satin dome, light drifting top-left
  for i = 0, 8 do
    local t = i / 8
    g:set(lerp(cr * 0.62, math.min(cr * 1.20 + 0.10, 1), t * t),
          lerp(cg * 0.62, math.min(cg * 1.20 + 0.10, 1), t * t),
          lerp(cb * 0.62, math.min(cb * 1.20 + 0.10, 1), t * t), 1)
    g:circle(cx - radius * 0.09 * t, cy - radius * 0.12 * t, radius * 0.78 * (1 - t * 0.55), 1)
  end
  g:set(cr * 0.32, cg * 0.32, cb * 0.32, 0.9); g:circle(cx, cy, radius * 0.78, 0)
  -- Cream pointer line w/ dark edging
  g:set(0.05, 0.04, 0.03, 0.45)
  pointer_quad(g, cx, cy, val_rad, radius * 0.10, radius * 0.93, radius * 0.062)
  g:set(0.93, 0.90, 0.82, 1)
  pointer_quad(g, cx, cy, val_rad, radius * 0.10, radius * 0.91, radius * 0.0425)
  -- Hover glow
  if hover_t > 0.01 then
    g:set(cr * 1.2, cg * 1.2, cb * 1.2, 0.3 * ht)
    g:circle(cx, cy, radius + 2, 0)
    g:circle(cx, cy, radius + 3, 0)
  end
  if n_det > 0 then neve_detents(g, cx, cy, radius, value, vmin, vmax, ht, ba, n_det) end
end

-- Neve Alt (style 20) — neve_alt_knob_draw. Heritage i73 concentric: chunky
-- scalloped ring (14 flutes), dark groove, satin dome, cream pointer across both.
function K.neve_alt(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb, n_det)
  n_det = n_det or 0
  local ht = hover_t ^ 2
  local ba = lerp(0.85, 1.0, ht)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  if n_det == 0 then
    for i = 0, 10 do
      local ta = (-130 + i * 26) * PI / 180
      g:set(0.65, 0.67, 0.72, lerp(0.30, 0.50, ht))
      g:line(cx + sin(ta) * radius * 1.02, cy - cos(ta) * radius * 1.02,
             cx + sin(ta) * radius * 1.15, cy - cos(ta) * radius * 1.15)
    end
  end
  -- Drop shadow + ring base
  g:set(0, 0, 0, 0.42); g:circle(cx + 1, cy + 2.5, radius, 1)
  g:set(cr * 0.58, cg * 0.58, cb * 0.58, ba); g:circle(cx, cy, radius, 1)
  -- 14 chunky scallops
  local fw = radius * 0.11
  for i = 0, 13 do
    local ca = i / 14 * TAU
    g:set(math.min(cr * 1.15 + 0.10, 1), math.min(cg * 1.15 + 0.10, 1), math.min(cb * 1.15 + 0.10, 1), 0.40 * ba)
    pointer_quad(g, cx, cy, ca, radius * 0.66, radius * 0.975, fw)
    local ta = (i + 0.5) / 14 * TAU
    g:set(cr * 0.22, cg * 0.22, cb * 0.22, 0.60)
    pointer_quad(g, cx, cy, ta, radius * 0.66, radius * 0.94, fw * 0.9)
  end
  -- Top-light / bottom-shade on the ring
  g:set(1, 1, 1, 0.10)
  g:arc(cx, cy, radius - 1, -1.5, 1.5)
  g:arc(cx, cy, radius - 2, -1.4, 1.4)
  g:set(0, 0, 0, 0.16)
  g:arc(cx, cy, radius - 1, 1.9, 2.9)
  g:arc(cx, cy, radius - 1, -2.9, -1.9)
  g:set(cr * 0.28, cg * 0.28, cb * 0.28, 1)
  g:circle(cx, cy, radius, 0)
  g:circle(cx, cy, radius - 0.5, 0)
  -- Dark groove between ring and dome
  g:set(0, 0, 0, 0.55)
  g:circle(cx, cy, radius * 0.64, 0)
  g:circle(cx, cy, radius * 0.63, 0)
  g:circle(cx, cy, radius * 0.62, 0)
  -- Inner satin dome
  for i = 0, 8 do
    local t = i / 8
    g:set(lerp(cr * 0.55, math.min(cr * 1.25 + 0.10, 1), t * t),
          lerp(cg * 0.55, math.min(cg * 1.25 + 0.10, 1), t * t),
          lerp(cb * 0.55, math.min(cb * 1.25 + 0.10, 1), t * t), 1)
    g:circle(cx - radius * 0.08 * t, cy - radius * 0.11 * t, radius * 0.58 * (1 - t * 0.55), 1)
  end
  g:set(1, 1, 1, 0.08); g:circle(cx, cy, radius * 0.58, 0)
  -- Cream pointer crossing dome and ring
  g:set(0.05, 0.04, 0.03, 0.45)
  pointer_quad(g, cx, cy, val_rad, radius * 0.06, radius * 0.96, radius * 0.062)
  g:set(0.93, 0.90, 0.82, 1)
  pointer_quad(g, cx, cy, val_rad, radius * 0.06, radius * 0.95, radius * 0.0425)
  -- Hover glow
  if hover_t > 0.01 then
    g:set(cr * 1.2, cg * 1.2, cb * 1.2, 0.3 * ht)
    g:circle(cx, cy, radius + 2, 0)
    g:circle(cx, cy, radius + 3, 0)
  end
  if n_det > 0 then neve_detents(g, cx, cy, radius, value, vmin, vmax, ht, ba, n_det) end
end

-- MPC — mpc_knob_draw (lines 1109–1181). Background track arc + accent value arc,
-- dark bevel shell, colour-tinted rubber dome cap, thick white indicator.
function K.mpc(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t ^ 2
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  -- Track arc (background)
  local n_passes = math.max(2, floor(radius / 6))
  g:set(bgr, bgg, bgb, 1)
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.6, -RAD130, RAD130, 1) end
  -- Active arc (accent)
  g:set(cr, cg, cb, lerp(0.75, 1.0, ht))
  local start_rad = (is_sym == 1) and 0 or -RAD130
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.6, start_rad, val_rad, 1) end
  -- Outer bevel rim
  local bevel_r = radius * 0.80
  g:set(0.10, 0.10, 0.11, 1); g:circle(cx, cy, bevel_r, 1)
  local hl = lerp(0.28, 0.38, ht)
  g:set(hl, hl, lerp(0.30, 0.40, ht), 1)
  g:circle(cx, cy, bevel_r, 0)
  g:circle(cx, cy, bevel_r - 0.5, 0)
  -- Rubber dome cap (tinted)
  local cap_r  = bevel_r * 0.82
  local dome_r = cap_r * 0.60
  g:set(lerp(cr * 0.35, cr * 0.50, ht), lerp(cg * 0.35, cg * 0.50, ht), lerp(cb * 0.35, cb * 0.50, ht), 1)
  g:circle(cx, cy, cap_r, 1)
  g:set(lerp(cr * 0.65, cr * 0.85, ht), lerp(cg * 0.65, cg * 0.85, ht), lerp(cb * 0.65, cb * 0.85, ht), 1)
  g:circle(cx - cap_r * 0.18, cy - cap_r * 0.18, dome_r, 1)
  g:set(cr * 0.12, cg * 0.12, cb * 0.12, 1)
  g:circle(cx + cap_r * 0.08, cy + cap_r * 0.08, dome_r * 0.55, 1)
  -- Indicator line (thick white, 3 passes)
  local ix1 = cx + sin(val_rad) * cap_r * 0.30
  local iy1 = cy - cos(val_rad) * cap_r * 0.30
  local ix2 = cx + sin(val_rad) * cap_r * 0.88
  local iy2 = cy - cos(val_rad) * cap_r * 0.88
  g:set(0.92, 0.92, 0.92, lerp(0.80, 1.0, ht))
  g:line(ix1, iy1, ix2, iy2, 1)
  g:line(ix1 + cos(val_rad) * 0.5, iy1 + sin(val_rad) * 0.5,
         ix2 + cos(val_rad) * 0.5, iy2 + sin(val_rad) * 0.5, 1)
  g:line(ix1 - cos(val_rad) * 0.5, iy1 - sin(val_rad) * 0.5,
         ix2 - cos(val_rad) * 0.5, iy2 - sin(val_rad) * 0.5, 1)
  -- Hover glow ring
  local glow_a = 0.25 * ht
  if glow_a > 0.01 then
    g:set(cr, cg, cb, glow_a)
    g:circle(cx, cy, bevel_r + 1.5, 0)
    g:circle(cx, cy, bevel_r + 2.5, 0)
  end
end

-- API 550 — api_knob_draw (lines 761–808), inner knob only. Chrome rim with bevel
-- arc, dark stepped body, thick white 4-line pointer, accent-coloured dot (cr/cg/cb).
function K.api(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, dot_r, dot_g, dot_b)
  local ht = hover_t ^ 2
  local chrome_bright = lerp(0.72, 0.88, ht)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  -- Chrome rim
  g:set(chrome_bright, chrome_bright, chrome_bright + 0.02, 1)
  g:circle(cx, cy, radius, 1)
  local cbri = math.min(chrome_bright + 0.1, 1)
  g:set(cbri, cbri, math.min(chrome_bright + 0.12, 1), 0.6)
  g:arc(cx, cy, radius - 1,   -0.8 * PI, -0.2 * PI, 1)
  g:arc(cx, cy, radius - 1.5, -0.8 * PI, -0.2 * PI, 1)
  g:set(0.45, 0.45, 0.48, 1); g:circle(cx, cy, radius, 0)
  -- Dark body
  g:set(0.10, 0.10, 0.12, 1); g:circle(cx, cy, radius * 0.82, 1)
  g:set(0.16, 0.16, 0.18, 1); g:circle(cx, cy, radius * 0.55, 1)
  g:set(0.13, 0.13, 0.15, 1); g:circle(cx, cy, radius * 0.35, 1)
  -- Thick white pointer (4 lines)
  g:set(0.95, 0.95, 0.95, 1)
  local px = sin(val_rad) * radius * 0.75
  local py = -cos(val_rad) * radius * 0.75
  local perp_x = cos(val_rad)
  local perp_y = sin(val_rad)
  g:line(cx - perp_x * 1.5, cy - perp_y * 1.5, cx + px - perp_x * 1.5, cy + py - perp_y * 1.5)
  g:line(cx - perp_x * 0.5, cy - perp_y * 0.5, cx + px - perp_x * 0.5, cy + py - perp_y * 0.5)
  g:line(cx + perp_x * 0.5, cy + perp_y * 0.5, cx + px + perp_x * 0.5, cy + py + perp_y * 0.5)
  g:line(cx + perp_x * 1.5, cy + perp_y * 1.5, cx + px + perp_x * 1.5, cy + py + perp_y * 1.5)
  -- Colored dot
  local dot_d = radius * 0.62
  local dot_radius = radius * lerp(0.10, 0.14, ht)
  g:set(dot_r, dot_g, dot_b, 1)
  g:circle(cx + sin(val_rad) * dot_d, cy - cos(val_rad) * dot_d, dot_radius, 1)
end

-- Pultec EQP-1A — pultec_knob_draw. Authentic: black bakelite, ridged side wall,
-- silver-white pointer, warm-grey panel ticks. Fixed colour (cr/cg/cb unused).
function K.pultec(g, cx, cy, radius, value, vmin, vmax, hover_t)
  local ht = hover_t ^ 2
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  -- Warm-grey panel tick scale
  for i = 0, 10 do
    local ta = (-130 + i * 26) * PI / 180
    g:set(0.55, 0.53, 0.47, lerp(0.40, 0.62, ht))
    g:line(cx + sin(ta) * radius * 0.99, cy - cos(ta) * radius * 0.99,
           cx + sin(ta) * radius * 1.12, cy - cos(ta) * radius * 1.12)
  end
  -- Drop shadow + black side wall
  g:set(0, 0, 0, 0.50); g:circle(cx + 1, cy + 2, radius, 1)
  g:set(0.05, 0.05, 0.055, 1); g:circle(cx, cy, radius, 1)
  -- Fine side-wall ridges
  for i = 0, 35 do
    local ra = i / 36 * TAU
    g:set(1, 1, 1, 0.06)
    g:line(cx + sin(ra) * radius * 0.86, cy - cos(ra) * radius * 0.86,
           cx + sin(ra) * radius * 0.99, cy - cos(ra) * radius * 0.99)
  end
  -- Charcoal top disc, light drifting top-left
  for i = 0, 8 do
    local t = i / 8
    local sh = lerp(0.065, 0.235, t * t)
    g:set(sh, sh, sh + 0.008, 1)
    g:circle(cx - radius * 0.08 * t, cy - radius * 0.10 * t, radius * 0.84 * (1 - t * 0.55), 1)
  end
  g:set(1, 1, 1, 0.10); g:circle(cx, cy, radius * 0.84, 0)
  -- Silver-white pointer w/ dark edging
  g:set(0, 0, 0, 0.45)
  pointer_quad(g, cx, cy, val_rad, radius * 0.14, radius * 0.82, radius * 0.055)
  g:set(0.85, 0.86, 0.89, 1)
  pointer_quad(g, cx, cy, val_rad, radius * 0.14, radius * 0.80, radius * 0.0375)
  -- Hover glow (cool silver)
  if hover_t > 0.01 then
    g:set(0.70, 0.72, 0.78, 0.14 * ht)
    g:circle(cx, cy, radius + 2, 0)
    g:circle(cx, cy, radius + 3, 0)
    g:circle(cx, cy, radius + 4, 0)
  end
end

-- Pultec Cream (style 19) — pultec_cream_knob_draw. Tube-Tech PE 1C: cream body,
-- painted black pointer. Fixed colour (cr/cg/cb unused).
function K.pultec_cream(g, cx, cy, radius, value, vmin, vmax, hover_t)
  local ht = hover_t ^ 2
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  -- Warm panel tick scale
  for i = 0, 10 do
    local ta = (-130 + i * 26) * PI / 180
    g:set(0.62, 0.60, 0.52, lerp(0.45, 0.68, ht))
    g:line(cx + sin(ta) * radius * 0.99, cy - cos(ta) * radius * 0.99,
           cx + sin(ta) * radius * 1.12, cy - cos(ta) * radius * 1.12)
  end
  -- Drop shadow + cream body (light drifting up)
  g:set(0, 0, 0, 0.35); g:circle(cx + 1.5, cy + 2.5, radius * 0.92, 1)
  for i = 0, 6 do
    local t = i / 6
    g:set(lerp(0.80, 0.94, t), lerp(0.75, 0.91, t), lerp(0.60, 0.81, t), 1)
    g:circle(cx, cy - radius * 0.09 * t, radius * 0.92 * (1 - t * 0.50), 1)
  end
  g:set(0.20, 0.18, 0.13, 0.8)
  g:circle(cx, cy, radius * 0.92, 0)
  g:circle(cx, cy, radius * 0.92 - 0.5, 0)
  -- Painted black pointer w/ soft edging
  g:set(0.35, 0.32, 0.24, 0.5)
  pointer_quad(g, cx, cy, val_rad, radius * 0.06, radius * 0.86, radius * 0.058)
  g:set(0.08, 0.075, 0.055, 1)
  pointer_quad(g, cx, cy, val_rad, radius * 0.06, radius * 0.84, radius * 0.0425)
  -- Hover glow (warm)
  if hover_t > 0.01 then
    g:set(0.6, 0.5, 0.25, 0.12 * ht)
    g:circle(cx, cy, radius + 2, 0)
    g:circle(cx, cy, radius + 3, 0)
    g:circle(cx, cy, radius + 4, 0)
  end
end

-- Ableton (style 13) — ableton_knob_draw. 1:1 Live glyph: flat low-contrast body,
-- thin rim track, thick value arc hugging the rim, needle joined to the arc in
-- the same color/weight (one glyph).
function K.ableton(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t ^ 2
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local _bl = (bgr + bgg + bgb) * 0.33333
  local ink = _bl > 0.5 and 0.0 or 1.0
  local lift = _bl > 0.5 and -0.07 or 0.075
  local body_r = radius * 0.86
  -- Flat body disc + hairline outline
  g:set(clamp(bgr + lift, 0, 1), clamp(bgg + lift, 0, 1), clamp(bgb + lift, 0, 1), 1)
  g:circle(cx, cy, body_r, 1)
  g:set(ink, ink, ink, 0.10); g:circle(cx, cy, body_r, 0)
  -- Faint rim track (unswept portion)
  g:set(ink, ink, ink, lerp(0.11, 0.17, ht))
  g:arc(cx, cy, radius, -RAD130, RAD130, 1)
  g:arc(cx, cy, radius - 0.7, -RAD130, RAD130, 1)
  -- Value arc hugging the rim; bipolar (center start) when is_sym
  local n_passes = math.max(3, floor(radius / 9))
  g:set(cr, cg, cb, lerp(0.92, 1.0, ht))
  local start_rad = (is_sym == 1) and 0 or -RAD130
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, start_rad, val_rad, 1) end
  -- Needle center→rim, same color/weight as the arc (one glyph)
  local nh = math.max(1.0, n_passes * 0.35)
  pointer_quad(g, cx, cy, val_rad, 0, body_r, nh)
end

-- Pro Tools (style 15) — pt_knob_draw. Old Digidesign/DigiRack: glossy colour-tinted
-- glass dome (grey accent → silver), strong specular, metallic rim, dark pointer, green arc.
function K.pt(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t ^ 2
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local body_r = radius * 0.72
  local n_passes = math.max(2, floor(radius / 8))
  local start_rad = (is_sym == 1) and 0 or -RAD130
  -- Green LED arc above the cap
  g:set(bgr, bgg, bgb, 0.35)
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.6, -RAD130, RAD130, 1) end
  g:set(0.40, 0.90, 0.42, lerp(0.8, 1.0, ht))
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.6, start_rad, val_rad, 1) end
  -- Shadow + grey metallic housing ring
  g:set(0, 0, 0, 0.32); g:circle(cx, cy + 2, body_r, 1)
  g:set(0.42, 0.43, 0.46, 1); g:circle(cx, cy, body_r, 1)
  -- Glossy colour dome: DARK TOP -> BRIGHT LOWER reflection (DigiRack lighting)
  local cap_r = body_r * 0.86
  g:set(cr * 0.30, cg * 0.30, cb * 0.32, 1); g:circle(cx, cy, cap_r, 1)
  for i = 0, 8 do
    local frac = i / 8
    local rr = cap_r * (1 - frac * 0.40)
    local yo = cap_r * 0.30 * frac
    g:set(lerp(cr * 0.30, math.min(cr * 1.25 + 0.20, 1), frac),
          lerp(cg * 0.30, math.min(cg * 1.25 + 0.20, 1), frac),
          lerp(cb * 0.32, math.min(cb * 1.25 + 0.20, 1), frac), 1)
    g:circle(cx, cy + yo, rr, 1)
  end
  -- Bright glossy reflection crescent in the lower-middle
  g:set(math.min(cr * 1.5 + 0.30, 1), math.min(cg * 1.5 + 0.30, 1), math.min(cb * 1.5 + 0.30, 1), 0.32)
  g:circle(cx, cy + cap_r * 0.30, cap_r * 0.34, 1)
  -- Dark separator between cap and housing
  g:set(0.16, 0.17, 0.20, 1); g:circle(cx, cy, cap_r, 0)
  -- Dark pointer (3 passes)
  local pin, pout = cap_r * 0.12, cap_r * 0.86
  g:set(0.08, 0.08, 0.09, 1)
  g:line(cx + sin(val_rad) * pin, cy - cos(val_rad) * pin, cx + sin(val_rad) * pout, cy - cos(val_rad) * pout)
  g:line(cx + sin(val_rad) * pin + cos(val_rad), cy - cos(val_rad) * pin + sin(val_rad),
         cx + sin(val_rad) * pout + cos(val_rad), cy - cos(val_rad) * pout + sin(val_rad))
  g:line(cx + sin(val_rad) * pin - cos(val_rad), cy - cos(val_rad) * pin - sin(val_rad),
         cx + sin(val_rad) * pout - cos(val_rad), cy - cos(val_rad) * pout - sin(val_rad))
end

-- Serum (style 17) — serum_knob_draw. Large beveled dark body, faint track + glowing
-- accent value arc hugging the rim, thin pointer + tip dot, dark centre cap (no ticks).
function K.serum(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local body_r = radius * 0.80
  local glow_a = lerp(0.75, 1.0, hover_t)
  for i = 0, 5 do
    local frac = i / 5
    g:set(lerp(0.09, 0.20, frac), lerp(0.09, 0.20, frac), lerp(0.11, 0.23, frac), 1)
    g:circle(cx, cy, body_r * (1 - frac * 0.32), 1)
  end
  g:set(0.30, 0.32, 0.36, 0.6); g:circle(cx, cy, body_r, 0)
  local n_passes = math.max(2, floor(radius / 6))
  local start_rad = (is_sym == 1) and 0 or -RAD130
  g:set(bgr, bgg, bgb, 0.22)
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, -RAD130, RAD130, 1) end
  g:set(cr, cg, cb, 0.22 * glow_a)
  for i = 0, math.max(3, n_passes + 1) - 1 do g:arc(cx, cy, radius - i * 0.9, start_rad, val_rad, 1) end
  g:set(cr, cg, cb, glow_a)
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, start_rad, val_rad, 1) end
  local px = cx + sin(val_rad) * body_r * 0.86
  local py = cy - cos(val_rad) * body_r * 0.86
  local pr = math.max(1.3, radius * 0.06)
  g:set(cr, cg, cb, glow_a)
  g:line(cx + sin(val_rad) * body_r * 0.18, cy - cos(val_rad) * body_r * 0.18, px, py)
  g:circle(px, py, pr, 1)
  g:set(0.05, 0.05, 0.07, 1); g:circle(cx, cy, body_r * 0.22, 1)
end

-- FabFilter (style 16) — fabfilter_knob_draw. Pro-G look: KNURLED grip edge (fan of
-- alternating radial ridges) + domed top-lit cap + specular gloss + halo ring + short notch.
function K.fabfilter(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local n_passes = math.max(3, floor(radius / 4))   -- bold halo
  local body_r = radius * 0.76
  local cap_r = body_r * 0.80
  g:set(0, 0, 0, 0.30); g:circle(cx, cy + 2, body_r, 1)
  -- Knurled grip ring (accent-tinted)
  g:set(cr * 0.18 + 0.10, cg * 0.18 + 0.10, cb * 0.18 + 0.12, 1); g:circle(cx, cy, body_r, 1)
  local kn_in = body_r * 0.78
  local n_teeth = math.max(20, floor(radius * 1.6))
  for i = 0, n_teeth - 1 do
    local ta = (i / n_teeth) * 2 * PI
    if i % 2 == 0 then g:set(cr * 0.35 + 0.34, cg * 0.35 + 0.34, cb * 0.35 + 0.36, 1)
    else g:set(cr * 0.28 + 0.14, cg * 0.28 + 0.14, cb * 0.28 + 0.16, 1) end
    g:line(cx + sin(ta) * kn_in, cy - cos(ta) * kn_in, cx + sin(ta) * body_r, cy - cos(ta) * body_r)
  end
  -- 2-tone domed cap (accent-tinted): dark bottom -> light top
  g:set(cr * 0.38 + 0.10, cg * 0.38 + 0.10, cb * 0.38 + 0.10, 1); g:circle(cx, cy, cap_r, 1)
  for i = 0, 7 do
    local frac = i / 7
    local rr = cap_r * (1 - frac * 0.58)
    local yo = -cap_r * 0.30 * frac
    g:set(lerp(cr * 0.38 + 0.12, cr * 0.45 + 0.52, frac),
          lerp(cg * 0.38 + 0.12, cg * 0.45 + 0.52, frac),
          lerp(cb * 0.38 + 0.12, cb * 0.45 + 0.52, frac), 1)
    g:circle(cx, cy + yo, rr, 1)
  end
  g:set(math.min(cr * 0.5 + 0.55, 1), math.min(cg * 0.5 + 0.55, 1), math.min(cb * 0.5 + 0.58, 1), 0.45)
  g:circle(cx, cy - cap_r * 0.42, cap_r * 0.26, 1)
  g:set(0.10, 0.12, 0.16, 0.8); g:circle(cx, cy, cap_r, 0); g:circle(cx, cy, body_r, 0)
  -- Halo: always-visible neutral track groove + BOLD value ring on top
  g:set(0.32, 0.34, 0.39, lerp(0.55, 0.80, hover_t))
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, -RAD130, RAD130, 1) end
  g:set(cr, cg, cb, lerp(0.9, 1.0, hover_t))
  local start_rad = (is_sym == 1) and 0 or -RAD130
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, start_rad, val_rad, 1) end
  -- Indicator: thick WHITE ARC band centred on the pointer, hugging the cap's curve
  -- (a true arc, not a pointy wedge). Filled by stacked arc passes. Recessed line.
  local fa = 0.42
  local ar_lo, ar_hi = cap_r * 0.50, cap_r * 0.96
  local n_band = math.max(8, floor((ar_hi - ar_lo) / 0.6))
  g:set(0.90, 0.93, 0.97, lerp(0.72, 0.92, hover_t))
  for i = 0, n_band do
    local rr = ar_lo + (ar_hi - ar_lo) * (i / n_band)
    g:arc(cx, cy, rr, val_rad - fa, val_rad + fa, 1)
  end
  g:set(0.20, 0.22, 0.28, lerp(0.6, 0.85, hover_t))
  g:line(cx + sin(val_rad) * cap_r * 0.30, cy - cos(val_rad) * cap_r * 0.30,
         cx + sin(val_rad) * cap_r * 0.96, cy - cos(val_rad) * cap_r * 0.96)
end

-- Witti/ws (style 4) — ws_knob_draw. Bg track arc + dark inner circle + accent value
-- arc + orbiting dot + hover ring.
function K.ws(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local RAD130 = 130 * PI / 180
  local n_passes = math.max(2, floor(radius / 5))
  local pass_gap = 0.5
  local inner_r = radius * 0.75
  local dot_orbit = radius * 0.5
  local dot_r = radius * 0.15
  local arc_alpha = lerp(0.6, 1.0, hover_t ^ 2)
  local dot_r_h = dot_r * lerp(1.0, 1.3, hover_t ^ 2)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  g:set(bgr, bgg, bgb, 1)
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * pass_gap, -RAD130, RAD130, 1) end
  g:set(0.08, 0.08, 0.10, 1); g:circle(cx, cy, inner_r, 1)
  g:set(cr, cg, cb, arc_alpha)
  local start_rad = (is_sym == 1) and 0 or -RAD130
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * pass_gap, start_rad, val_rad, 1) end
  g:set(cr, cg, cb, arc_alpha)
  g:circle(cx + sin(val_rad) * dot_orbit, cy - cos(val_rad) * dot_orbit, dot_r_h, 1)
  if hover_t > 0.01 then g:set(cr, cg, cb, 0.3 * arc_alpha); g:circle(cx, cy, inner_r, 0) end
end

-- Joanny/jo (style 6) — jo_knob_draw. Takes a normalised value (0..1). Soft 2-tone
-- coloured body + black outline + single full-length pointer (blur shadow omitted).
function K.jo(g, cx, cy, r, value, hover_t, cr, cg, cb)
  local ht = hover_t
  local lift = lerp(0, -2, ht)
  local shad_off = lerp(3, 1, ht)
  g:set(0, 0, 0, 0.20); g:circle(cx + shad_off,     cy + 2 + lift, r,     1)
  g:set(0, 0, 0, 0.15); g:circle(cx + shad_off + 1, cy + 3 + lift, r + 1, 1)
  g:set(0, 0, 0, 0.10); g:circle(cx + shad_off + 2, cy + 4 + lift, r + 2, 1)
  g:set(0, 0, 0, 0.05); g:circle(cx + shad_off + 3, cy + 5 + lift, r + 3, 1)
  local dy = cy + lift
  g:set(cr * 0.7, cg * 0.7, cb * 0.7, 0.8); g:circle(cx, dy, r, 1)
  g:set(cr, cg, cb, 1); g:circle(cx, dy, r * 0.73, 1)
  g:set(0, 0, 0, 1); g:circle(cx, dy, r + 0.6, 0)
  local vr = clamp(value, 0, 1)
  local angle = -2.3 + 4.6 * (vr * 0.98 + 0.02)
  if (cr + cg + cb >= 2.3) then g:set(0, 0, 0, 1) else g:set(1, 1, 1, 1) end
  g:line(cx, dy, cx + sin(angle) * r, dy - cos(angle) * r, 1)
end

-- Spice/sp (style 10) — sp_knob_draw. Takes a normalised value. Blue arc-fill ring +
-- 3-pass inner circle + perpendicular 60-line sweep needle.
function K.sp(g, cx, cy, r, value, hover_t)
  local ht = hover_t
  local kr, kg, kb = lerp(0, 0.15, ht), lerp(0.5, 0.65, ht), 1.0
  local margin = r * 12 / 55
  local w = r * 18 / 55
  local arc_fill = 5
  local knob_rad = 0.6
  local kas = -TAU * (1 + knob_rad / 2)
  local inner = r - w - margin
  local inner_pulse = lerp(0, 2, ht)
  local arc_steps = floor(w * arc_fill)
  g:set(kr, kg, kb, 1)
  for i = 0, arc_steps - 1 do
    g:arc(cx, cy, r - w + (i / arc_fill), kas, value * TAU * knob_rad + kas)
  end
  local ir = inner + inner_pulse
  g:set(0.8, 0.8, 0.8, 1)
  g:circle(cx, cy, ir, 0); g:circle(cx, cy, ir - 0.5, 0); g:circle(cx, cy, ir - 1, 0)
  local polar = (value * 1.01) * TAU * knob_rad + kas
  local xo_ = sin(polar + TAU / 2) * -1
  local yo_ = cos(polar + TAU / 2)
  g:set(kr, kg, kb, 1)
  local nthick = r * 0.15
  local steps = 60
  local s = -steps / 2
  while s <= steps / 2 do
    local off_x = s / steps * yo_ * nthick
    local off_y = -s / steps * xo_ * nthick
    g:line(cx + off_x, cy + off_y, cx + off_x + xo_ * (ir - 1), cy + off_y + yo_ * (ir - 1))
    s = s + 1
  end
end

-- Encoder (style 11) — encoder_draw. 16-LED ring (lit to value) + brushed metal body
-- + 24 edge notches + white pointer.
function K.encoder(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb)
  local ht = hover_t ^ 2
  local _vn = clamp((value - vmin) / (vmax - vmin), 0, 1)
  local led_orbit = radius * 1.3
  local led_r = radius * 0.08
  local led_pos = _vn * 15
  for i = 0, 15 do
    local a = (-130 + i * 260 / 15) * PI / 180
    local led_bright = math.max(0, 1 - math.abs(i - led_pos) * 0.4) * lerp(0.7, 1.0, ht)
    local lx = cx + sin(a) * led_orbit
    local ly = cy - cos(a) * led_orbit
    g:set(0.12, 0.12, 0.13, 0.6); g:circle(lx, ly, led_r * 1.2, 1)
    if led_bright > 0.05 then
      g:set(cr * led_bright, cg * led_bright, cb * led_bright, 1)
      g:circle(lx, ly, led_r * (0.8 + led_bright * 0.5), 1)
      if led_bright > 0.5 then
        g:set(cr * led_bright, cg * led_bright, cb * led_bright, 0.2 * led_bright)
        g:circle(lx, ly, led_r * 2, 1)
      end
    end
  end
  g:set(0.42 + 0.05 * ht, 0.42 + 0.05 * ht, 0.44 + 0.05 * ht, 1); g:circle(cx, cy, radius, 1)
  g:set(0.52 + 0.05 * ht, 0.52 + 0.05 * ht, 0.54 + 0.05 * ht, 1); g:circle(cx, cy, radius * 0.75, 1)
  g:set(0.46, 0.46, 0.48, 1); g:circle(cx, cy, radius * 0.5, 1)
  local notch_in, notch_out = radius * 0.88, radius
  g:set(0.30, 0.30, 0.32, 1)
  for i = 0, 23 do
    local a = i * TAU / 24
    g:line(cx + sin(a) * notch_in, cy - cos(a) * notch_in, cx + sin(a) * notch_out, cy - cos(a) * notch_out)
  end
  g:set(0.30, 0.30, 0.32, 1); g:circle(cx, cy, radius, 0)
  g:set(0.2, 0.2, 0.22, 1); g:circle(cx, cy, radius * 0.12, 1)
  local val_rad = (_vn * 260 - 130) * PI / 180
  g:set(0.85, 0.85, 0.85, 1)
  g:line(cx + sin(val_rad) * radius * 0.3, cy - cos(val_rad) * radius * 0.3,
         cx + sin(val_rad) * radius * 0.8, cy - cos(val_rad) * radius * 0.8)
  g:line(cx + sin(val_rad) * radius * 0.3 + cos(val_rad), cy - cos(val_rad) * radius * 0.3 + sin(val_rad),
         cx + sin(val_rad) * radius * 0.8 + cos(val_rad), cy - cos(val_rad) * radius * 0.8 + sin(val_rad))
end

-- Jog (style 8) — jog_knob_draw. Spice-style outer arc ring + metallic jog body with
-- 12 grip notches + position dot. cr/cg/cb = arc colour. (Pixel-constant layout.)
function K.jog(g, cx, cy, radius, value, vmin, vmax, hover_t, arc_r, arc_g, arc_b)
  local ht = hover_t ^ 2
  local or_ = radius
  local ir_ = radius - 10
  local base_b = lerp(0.0, 0.04, ht)
  local RAD130 = 130 * PI / 180
  local arc_w = math.max(3, radius * 0.14)
  local n_arc = floor(arc_w * 4)
  local val_norm = (value - vmin) / (vmax - vmin)
  local val_rad = val_norm * 260 * PI / 180 - RAD130
  g:set(arc_r * 0.15, arc_g * 0.15, arc_b * 0.15, 0.8)
  for i = 0, n_arc - 1 do g:arc(cx, cy, or_ + 3 + (i / 4), -RAD130, RAD130, 1) end
  g:set(arc_r, arc_g, arc_b, lerp(0.75, 1.0, ht))
  for i = 0, n_arc - 1 do g:arc(cx, cy, or_ + 3 + (i / 4), -RAD130, val_rad, 1) end
  g:set(0.08 + base_b, 0.08 + base_b, 0.10 + base_b, 0.9); g:circle(cx, cy, or_ + 2, 1)
  g:set(0.30 + base_b, 0.30 + base_b, 0.32 + base_b, 1); g:circle(cx, cy, or_, 1)
  g:set(0.18 + base_b, 0.18 + base_b, 0.20 + base_b, 1); g:circle(cx, cy, or_ - 3, 1)
  g:set(0.32 + base_b, 0.32 + base_b, 0.34 + base_b, 1); g:circle(cx, cy, ir_ - 2, 1)
  g:set(0.30 + base_b, 0.30 + base_b, 0.32 + base_b, 1); g:circle(cx, cy, ir_ - 5, 1)
  g:set(0.28 + base_b, 0.28 + base_b, 0.30 + base_b, 1); g:circle(cx, cy, ir_ - 8, 1)
  g:set(0.42 + base_b, 0.42 + base_b, 0.44 + base_b, 0.3); g:circle(cx - 2, cy - 3, ir_ - 4, 0)
  g:set(0.50 + base_b, 0.50 + base_b, 0.52 + base_b, 1); g:circle(cx, cy, 4, 1)
  for jt = 0, 11 do
    local ja = jt / 12.0 * 2.0 * PI
    local tx1, ty1 = cx + cos(ja) * (or_ - 5), cy + sin(ja) * (or_ - 5)
    local tx2, ty2 = cx + cos(ja) * (or_ - 1), cy + sin(ja) * (or_ - 1)
    g:set(0.15, 0.15, 0.17, 0.6); g:line(tx1 + 0.5, ty1 + 0.5, tx2 + 0.5, ty2 + 0.5)
    g:set(0.55 + base_b, 0.53 + base_b, 0.50 + base_b, 0.8)
    g:line(tx1, ty1, tx2, ty2); g:line(tx1 + 1, ty1, tx2 + 1, ty2)
  end
  val_rad = (-130 + val_norm * 260) * PI / 180
  local ix, iy = cx + sin(val_rad) * (ir_ - 8), cy - cos(val_rad) * (ir_ - 8)
  g:set(0.90 + ht * 0.1, 0.88 + ht * 0.1, 0.85 + ht * 0.1, 0.9); g:circle(ix, iy, 3, 1)
  if ht > 0.01 then
    g:set(arc_r, arc_g, arc_b, 0.2 * ht)
    g:circle(cx, cy, or_ + arc_w + 4, 0); g:circle(cx, cy, or_ + arc_w + 5, 0)
  end
end

-- FL (style 14) — fl_knob_draw. Bg track + dark domed body + accent value arc + light notch.
function K.fl(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t ^ 2
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local body_r = radius * 0.70
  local n_passes = math.max(2, floor(radius / 6))
  g:set(bgr, bgg, bgb, lerp(0.18, 0.30, ht))
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, -RAD130, RAD130, 1) end
  g:set(0, 0, 0, 0.30); g:circle(cx, cy + 1, body_r, 1)
  g:set(0.13, 0.13, 0.15, 1); g:circle(cx, cy, body_r, 1)
  g:set(0.22 + 0.06 * ht, 0.22 + 0.06 * ht, 0.24 + 0.06 * ht, 1); g:circle(cx, cy, body_r * 0.66, 1)
  g:set(0.30, 0.30, 0.33, lerp(0.4, 0.8, ht)); g:circle(cx, cy, body_r, 0)
  local arc_a = lerp(0.85, 1.0, ht)
  g:set(cr, cg, cb, arc_a)
  local start_rad = (is_sym == 1) and 0 or -RAD130
  for i = 0, n_passes - 1 do g:arc(cx, cy, radius - i * 0.7, start_rad, val_rad, 1) end
  local notch_in, notch_out = body_r * 0.30, body_r * 0.92
  g:set(0.92, 0.92, 0.95, arc_a)
  g:line(cx + sin(val_rad) * notch_in, cy - cos(val_rad) * notch_in, cx + sin(val_rad) * notch_out, cy - cos(val_rad) * notch_out)
  g:line(cx + sin(val_rad) * notch_in + 1, cy - cos(val_rad) * notch_in, cx + sin(val_rad) * notch_out + 1, cy - cos(val_rad) * notch_out)
end

-- Roland (style 18) — roland_knob_draw. Knurled dark edge + coloured cap + top-left
-- highlight + white pointer.
function K.roland(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local body_r = radius * 0.92
  g:set(0, 0, 0, 0.35); g:circle(cx + 1, cy + 2, body_r, 1)
  g:set(cr * 0.40, cg * 0.40, cb * 0.40, 1); g:circle(cx, cy, body_r, 1)
  for i = 0, 23 do
    local ang = (i / 24) * TAU
    g:set(cr * 0.25, cg * 0.25, cb * 0.25, 1)
    g:line(cx + sin(ang) * body_r * 0.88, cy - cos(ang) * body_r * 0.88, cx + sin(ang) * body_r, cy - cos(ang) * body_r)
  end
  g:set(cr, cg, cb, 1); g:circle(cx, cy, body_r * 0.80, 1)
  local hl = lerp(0.15, 0.30, hover_t)
  g:set(1, 1, 1, hl); g:circle(cx - body_r * 0.18, cy - body_r * 0.22, body_r * 0.42, 1)
  local ptr_in, ptr_out = body_r * 0.10, body_r * 0.74
  g:set(0.97, 0.97, 0.97, 1)
  g:line(cx + sin(val_rad) * ptr_in, cy - cos(val_rad) * ptr_in, cx + sin(val_rad) * ptr_out, cy - cos(val_rad) * ptr_out)
  g:line(cx + sin(val_rad) * ptr_in + 1, cy - cos(val_rad) * ptr_in, cx + sin(val_rad) * ptr_out + 1, cy - cos(val_rad) * ptr_out)
  if hover_t > 0.01 then g:set(1, 1, 1, 0.20 * hover_t); g:circle(cx, cy, body_r + 1, 0) end
end

-- ── Dispatcher ───────────────────────────────────────────────────────────────
-- Style ids match knobs_kbsg.jsfx-inc rk_knob_draw (1 ssl · 2 varimu · 3 api ·
-- 4 ws · 5 neve · 6 jo · 7 mpc · 8 jog · 10 sp · 11 encoder · 12 pultec ·
-- 13 ableton · 14 fl · 15 pt · 16 fabfilter · 17 serum · 18 roland).
-- PORTED: all 18 — ssl(1) varimu(2) api(3) ws(4) neve(5) jo(6) mpc(7) jog(8)
-- sp(10) encoder(11) pultec(12) ableton(13) fl(14) pt(15) fabfilter(16) serum(17)
-- roland(18). (style 9 = bb, needs interaction memory — not used here; 0/unknown → ssl.)
function K.draw(style, g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t,
                cr, cg, cb, n_det, bgr, bgg, bgb)
  if style == 2  then return K.varimu(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb) end
  if style == 3  then return K.api(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb) end
  if style == 4  then return K.ws(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 5  then return K.neve(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb, n_det) end
  if style == 6  then return K.jo(g, cx, cy, radius, (value - vmin) / math.max(1e-7, vmax - vmin), hover_t, cr, cg, cb) end
  if style == 7  then return K.mpc(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 8  then return K.jog(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb) end
  if style == 10 then return K.sp(g, cx, cy, radius, (value - vmin) / math.max(1e-7, vmax - vmin), hover_t) end
  if style == 11 then return K.encoder(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb) end
  if style == 12 then return K.pultec(g, cx, cy, radius, value, vmin, vmax, hover_t) end
  if style == 13 then return K.ableton(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 14 then return K.fl(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 15 then return K.pt(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 16 then return K.fabfilter(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 17 then return K.serum(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 18 then return K.roland(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 19 then return K.pultec_cream(g, cx, cy, radius, value, vmin, vmax, hover_t) end
  if style == 20 then return K.neve_alt(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb, n_det) end
  return K.ssl(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, n_det)
end

return K
