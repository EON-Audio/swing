-- ReaKit Lua Knobs — JSFX knob-skin parity for ImGui panels
-- (c) EON Studios — All Rights Reserved
--
-- 1:1 ports of the Swing JSFX knob styles (installer/src/Swing/libs/knobs_kbsg.jsfx-inc)
-- into ReaImGui DrawList, so the Pad FX / Browser panels render the SAME knobs as
-- the plugin. The JSFX is the SOURCE OF TRUTH: each K.<style> below is a near
-- line-for-line transcription of the matching <style>_knob_draw EEL2 function.
-- When a JSFX knob changes, mirror the change here (each style's header names its
-- EEL2 function).
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

function Pen:rect(x, y, w, h)
  ImGui.DrawList_AddRectFilled(self.dl, x, y, x + w, y + h, self.col)
end

-- Shared by ableton + fabfilter (knobs_kbsg rk_kn_ray / rk_kn_band / rk_kn_lens).
-- A band is one thick stroke here: the same square-ended annulus the stacked 1 px
-- gfx_arc passes build in EEL2. Quad corners in pointer_quad's order.
local function kn_ray(g, cx, cy, a, r0, r1, w)
  local ux, uy = sin(a), -cos(a)
  local px, py, h = -uy, ux, w * 0.5
  local x0, y0, x1, y1 = cx + ux * r0, cy + uy * r0, cx + ux * r1, cy + uy * r1
  g:quad(x0 + px * h, y0 + py * h, x0 - px * h, y0 - py * h,
         x1 - px * h, y1 - py * h, x1 + px * h, y1 + py * h)
end
local function kn_band(g, cx, cy, r_in, r_out, a1, a2)
  if a2 > a1 then g:arc(cx, cy, (r_in + r_out) * 0.5, a1, a2, r_out - r_in) end
end
-- disc(cx,cy,dd) ∩ disc(lcx,lcy,rho): a convex lens, one span per pixel row
local function kn_lens(g, cx, cy, dd, lcx, lcy, rho)
  local i = floor(math.max(cy - dd, lcy - rho))
  local last = math.min(cy + dd, lcy + rho)
  while i <= last do
    local y = i + 0.5
    local dy0, dy1 = y - cy, y - lcy
    if math.abs(dy0) < dd and math.abs(dy1) < rho then
      local hw, f = sqrt(dd * dd - dy0 * dy0), sqrt(rho * rho - dy1 * dy1)
      local x0, x1 = math.max(cx - hw, lcx - f), math.min(cx + hw, lcx + f)
      if x1 > x0 + 0.25 then
        local xs = floor(x0 + 0.5)
        g:rect(xs, i, math.max(1, floor(x1 + 0.5) - xs), 1)
      end
    end
    i = i + 1
  end
end
-- bipolar anchor, as the JSFX: 0 = from the start, 1 = centre, 0<x<1 = at x
local function kn_start(is_sym, SW)
  if is_sym == nil or is_sym == 0 or is_sym == false then return -SW end
  if is_sym == true or is_sym >= 1 then return 0 end
  return (is_sym * 2 - 1) * SW
end

-- knobs_kbsg rk_kn_vdisc: a disc filled row by row with a vertical gradient (its
-- edge is left to an AA circle drawn after; both row ends rounded from the circle).
local function kn_vdisc(g, cx, cy, r, tr, tg, tb, br, bg_, bb)
  local i = floor(cy - r)
  while i <= cy + r do
    local y = i + 0.5 - cy
    local hw = sqrt(math.max(r * r - y * y, 0)) - 0.5
    if hw > 0 then
      local x0, x1 = floor(cx - hw + 0.5), floor(cx + hw + 0.5)
      if x1 > x0 then
        local f = (y + r) / (2 * r)
        g:set(tr + (br - tr) * f, tg + (bg_ - tg) * f, tb + (bb - tb) * f, 1)
        g:rect(x0, i, x1 - x0, 1)
      end
    end
    i = i + 1
  end
end
-- knobs_kbsg rk_kn_pill: a radial rounded bar r0..r1 at clock angle a, width w.
local function kn_pill(g, cx, cy, a, r0, r1, w)
  local h = w * 0.5
  if r1 - r0 > w then kn_ray(g, cx, cy, a, r0 + h, r1 - h, w) end
  g:circle(cx + sin(a) * (r0 + h), cy - cos(a) * (r0 + h), h, 1)
  g:circle(cx + sin(a) * (r1 - h), cy - cos(a) * (r1 - h), h, 1)
end

-- ── Style ports ──────────────────────────────────────────────────────────────

-- SSL (style 1) — ssl_knob_draw. The SSL E-Series knob (2026-09-24): a big flat colour
-- cap, a light-grey rim lit from the top-left, a fluted grey skirt, a white bar
-- painted on the cap (dark on a light cap), a soft shadow below-right; detent dots at
-- 1.25r as before. is_sym is unused (parity).
function K.ssl(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, n_detents)
  n_detents = n_detents or 0
  local ht = hover_t * hover_t
  local val_rad = ((value - vmin) / math.max(0.0000001, vmax - vmin) * 260 - 130) * PI / 180
  local cap, rim = radius * (0.74 + 0.04 * ht), radius * 0.88
  -- soft shadow below-right
  g:set(0, 0, 0, 0.18); g:circle(cx + radius * 0.06, cy + radius * 0.10, radius * 1.02, 1)
  g:set(0, 0, 0, 0.22); g:circle(cx + radius * 0.04, cy + radius * 0.06, radius, 1)
  -- fluted skirt: lit top-left, shade bottom-right; 24 flutes
  kn_vdisc(g, cx, cy, radius, 0.66, 0.67, 0.68, 0.36, 0.36, 0.37)
  local w = math.max(1, radius * 0.035)
  for i = 0, 23 do
    local a = i * 2 * PI / 24
    local sh = 0.5 + 0.5 * cos(a + 0.785)
    g:set(0.26 + 0.20 * sh, 0.26 + 0.20 * sh, 0.27 + 0.20 * sh, 1)
    kn_ray(g, cx, cy, a, rim, radius - 0.5, w)
  end
  g:set(0.20, 0.20, 0.21, 0.9); g:circle(cx, cy, radius, 0)
  -- rim: a light-grey band round the cap, lit top-left
  for i = 0, 11 do
    local a = -PI + i * 2 * PI / 12
    local sh = 0.5 + 0.5 * cos(a + PI / 12 + 0.785)
    local f = 0.60 + 0.20 * sh
    g:set(f, f + 0.01, f + 0.01, 1)
    kn_band(g, cx, cy, cap, rim, a, a + 2 * PI / 12 + 0.02)
  end
  -- flat colour cap, a touch lighter at the top, a dark seam at its edge
  kn_vdisc(g, cx, cy, cap, math.min(cr + 0.05, 1), math.min(cg + 0.05, 1), math.min(cb + 0.05, 1), cr * 0.85, cg * 0.85, cb * 0.85)
  g:set(cr * 0.45, cg * 0.45, cb * 0.45, 1); g:circle(cx, cy, cap, 0)
  g:set(cr * 0.45, cg * 0.45, cb * 0.45, 0.6); g:circle(cx, cy, cap + 0.6, 0)
  -- painted pointer bar, centre -> cap edge; a light cap gets a dark bar
  if cr * 0.299 + cg * 0.587 + cb * 0.114 > 0.6 then g:set(0.12, 0.12, 0.14, 1) else g:set(0.95, 0.96, 0.96, 1) end
  kn_ray(g, cx, cy, val_rad, cap * 0.05, cap * 0.97, math.max(1.5, cap * 0.22))
  -- detent dots
  if n_detents > 0 then
    local det_step = (vmax - vmin) / math.max(1, n_detents - 1)
    local active_det = floor((value - vmin) / det_step + 0.5)
    for i = 0, n_detents - 1 do
      local da = (-130 + i * 260 / math.max(1, n_detents - 1)) * PI / 180
      local dx, dy = cx + sin(da) * radius * 1.25, cy - cos(da) * radius * 1.25
      if i == active_det then
        g:set(cr, cg, cb, 1); g:circle(dx, dy, radius * 0.08, 1)
      else
        g:set(0.4, 0.4, 0.4, 0.5 + 0.3 * ht); g:circle(dx, dy, radius * 0.05, 1)
      end
    end
  end
end

-- Vari-Mu (style 2) — varimu_knob_draw. The Manley Variable Mu knob (2026-09-25): a black
-- bar knob — lit shoulders and dark grooves either side of a raised bar, a white pointer
-- line at the bar's end — inside Manley's printed scale (a thin arc and 11 ticks) drawn in
-- the accent. The knob itself ignores the accent. 270° sweep. No detents/bg/is_sym.
function K.varimu(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb)
  local ht = hover_t * hover_t
  local lift = 0.03 * ht
  local SW = 135 * PI / 180
  local rng = vmax - vmin  -- a zero range reads as 0; an inverted one works
  local t = math.abs(rng) > 0.0000001 and clamp((value - vmin) / rng, 0, 1) or 0
  local a = -SW + t * 2 * SW
  -- Manley's printed scale: a thin arc at 0.86 R and 11 ticks out to R, in the accent
  local sr = radius * 0.86
  g:set(cr, cg, cb, 0.9)
  g:arc(cx, cy, sr, -SW, SW, 1)
  if radius >= 24 then g:arc(cx, cy, sr + 0.6, -SW, SW, 1) end
  for i = 0, 10 do
    kn_ray(g, cx, cy, -SW + i * 2 * SW / 10, sr, radius, math.max(1, radius * 0.035))
  end
  local rs = radius * 0.72
  -- soft shadow, then the black skirt: lit a touch at the top, near-black below
  g:set(0, 0, 0, 0.35); g:circle(cx + rs * 0.05, cy + rs * 0.09, rs, 1)
  kn_vdisc(g, cx, cy, rs, 0.22 + lift, 0.23 + lift, 0.27 + lift, 0.07, 0.075, 0.09)
  g:set(0.04, 0.04, 0.05, 1); g:circle(cx, cy, rs, 0)
  g:set(0.50, 0.52, 0.58, 0.45); g:arc(cx, cy, rs - 1, -2.0, -0.55, 1)  -- rim light, upper-left
  -- the skirt's shoulders: two soft lit bands parallel to the bar (each clipped to its
  -- chord), and a dark groove either side of the bar
  local ux, uy = sin(a), -cos(a)
  local px, py = -uy, ux
  for i = -1, 1, 2 do
    local off = i * rs * 0.66
    local q = math.abs(off) + rs * 0.14
    local L = sqrt(math.max(rs * rs - q * q, 0))
    g:set(0.30 + lift, 0.31 + lift, 0.36 + lift, 0.35); kn_ray(g, cx + px * off, cy + py * off, a, -L, L, rs * 0.28)
    g:set(0.34 + lift, 0.35 + lift, 0.40 + lift, 0.35); kn_ray(g, cx + px * off, cy + py * off, a, -L, L, rs * 0.14)
    off = i * rs * 0.37
    q = math.abs(off) + rs * 0.06
    L = sqrt(math.max(rs * rs - q * q, 0))
    g:set(0.02, 0.02, 0.03, 0.55); kn_ray(g, cx + px * off, cy + py * off, a, -L, L, rs * 0.12)
  end
  -- the bar: its dark walls, then the top face set a hair down-left, its long edges lit
  local bw, bl = rs * 0.48, rs * 0.90
  local ox, oy = -rs * 0.04, rs * 0.035
  g:set(0.03, 0.03, 0.035, 1); kn_ray(g, cx, cy, a, -bl, bl, bw + math.max(1, rs * 0.06))
  g:set(0.15 + lift, 0.155 + lift, 0.18 + lift, 1); kn_ray(g, cx + ox, cy + oy, a, -bl + 1, bl - 1, bw)
  g:set(0.36 + lift, 0.37 + lift, 0.42 + lift, 0.8)
  kn_ray(g, cx + ox + px * (bw * 0.5 - 0.8), cy + oy + py * (bw * 0.5 - 0.8), a, -bl + 1, bl - 1, 1)
  kn_ray(g, cx + ox - px * (bw * 0.5 - 0.8), cy + oy - py * (bw * 0.5 - 0.8), a, -bl + 1, bl - 1, 1)
  -- the white pointer line, inlaid at the pointer end of the bar
  g:set(0.93 + lift, 0.93 + lift, 0.92 + lift, 1)
  kn_ray(g, cx + ox, cy + oy, a, rs * 0.36, rs * 0.88, math.max(1.2, rs * 0.075))
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

-- MPC — mpc_knob_draw. Background track arc + accent value arc,
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

-- API (style 3) — api_knob_draw. The API 550A knob (2026-09-25): a warm-white fin knob (a
-- tapered pointer fin and three lobes, lit from above) that turns round a fixed blue collar
-- (the accent, dot_r/g/b) and a flat warm-grey cap. The fin tip sits at the radius, so the
-- body is R / 1.6. is_sym is unused (parity). Hover: the knob grows 4 %.
function K.api(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, dot_r, dot_g, dot_b)
  local ht = hover_t * hover_t
  local SW = 150 * PI / 180
  local rng = vmax - vmin  -- a zero range reads as 0; an inverted one works
  local t = math.abs(rng) > 0.0000001 and clamp((value - vmin) / rng, 0, 1) or 0
  local a = -SW + t * 2 * SW
  local rb = radius / 1.6 * (1 + 0.04 * ht)
  local tr, tg, tb = 0.98, 0.965, 0.95       -- lit white (top)
  local br, bg_, bb = 0.58, 0.50, 0.47       -- shaded white (bottom)
  -- (the shading below divides a height by rb: a knob of no size takes the middle shade)
  -- soft shadow below-right of the whole knob
  g:set(0, 0, 0, 0.28); g:circle(cx + rb * 0.06, cy + rb * 0.10, rb * 1.05, 1)
  -- the fin: a tapered quad and a rounded tip, coloured by the light at its middle
  local ux, uy = sin(a), -cos(a)
  local px, py = -uy, ux
  local r0, r1, w0, w1 = rb * 0.70, rb * 1.45, rb * 0.28, rb * 0.15
  local x0, y0, x1, y1 = cx + ux * r0, cy + uy * r0, cx + ux * r1, cy + uy * r1
  local fy = cy + uy * rb * 1.1
  local f = rb > 0 and clamp(0.5 + (fy - cy) / (2.4 * rb), 0, 1) or 0.5
  g:set(tr + (br - tr) * f, tg + (bg_ - tg) * f, tb + (bb - tb) * f, 1)
  g:quad(x0 + px * w0, y0 + py * w0, x1 + px * w1, y1 + py * w1,
         x1 - px * w1, y1 - py * w1, x0 - px * w0, y0 - py * w0)
  g:circle(x1, y1, w1, 1)
  -- three lobes, each coloured by the light at its centre
  for i = 1, 3 do
    local la = a + i * PI / 2
    local lx, ly = cx + sin(la) * rb * 0.85, cy - cos(la) * rb * 0.85
    f = rb > 0 and clamp(0.5 + (ly - cy) / (2.4 * rb), 0, 1) or 0.5
    g:set(tr + (br - tr) * f, tg + (bg_ - tg) * f, tb + (bb - tb) * f, 1)
    g:circle(lx, ly, rb * 0.30, 1)
  end
  -- the round body over the roots of the fin and lobes
  kn_vdisc(g, cx, cy, rb, tr + (br - tr) * 0.083, tg + (bg_ - tg) * 0.083, tb + (bb - tb) * 0.083,
           tr + (br - tr) * 0.917, tg + (bg_ - tg) * 0.917, tb + (bb - tb) * 0.917)
  g:set(tr + (br - tr) * 0.5, tg + (bg_ - tg) * 0.5, tb + (bb - tb) * 0.5, 0.6); g:circle(cx, cy, rb, 0)
  -- the inner knob: the collar with four small scallops (fixed), a dark seam, the grey cap
  g:set(0, 0, 0, 0.25); g:circle(cx, cy, rb * 0.83, 1)
  for i = 0, 3 do
    local la = PI / 4 + i * PI / 2
    local lx, ly = cx + sin(la) * rb * 0.78, cy - cos(la) * rb * 0.78
    f = rb > 0 and clamp(0.5 + (ly - cy) / (1.8 * rb), 0, 1) or 0.5
    g:set(dot_r * (1 - 0.28 * f), dot_g * (1 - 0.28 * f), dot_b * (1 - 0.28 * f), 1)
    g:circle(lx, ly, rb * 0.14, 1)
  end
  kn_vdisc(g, cx, cy, rb * 0.80, dot_r, dot_g, dot_b, dot_r * 0.72, dot_g * 0.72, dot_b * 0.72)
  g:set(dot_r * 0.5, dot_g * 0.5, dot_b * 0.5, 0.8); g:circle(cx, cy, rb * 0.80, 0)
  g:set(0.10, 0.10, 0.12, 1); g:circle(cx, cy, rb * 0.66, 1)
  kn_vdisc(g, cx, cy, rb * 0.60, 0.80, 0.76, 0.745, 0.73, 0.69, 0.68)
  g:set(0.55, 0.52, 0.51, 0.7); g:circle(cx, cy, rb * 0.60, 0)
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
  -- Charcoal top disc, light drifting top-left. The disc swells toward the side
  -- wall on hover; the wall and the panel ticks stay put (1.6.0 sync; SCR137).
  for i = 0, 8 do
    local t = i / 8
    local sh = lerp(0.065, 0.235, t * t)
    g:set(sh, sh, sh + 0.008, 1)
    g:circle(cx - radius * 0.08 * t, cy - radius * 0.10 * t, radius * lerp(0.84, 0.90, ht) * (1 - t * 0.55), 1)
  end
  g:set(1, 1, 1, lerp(0.10, 0.25, ht)); g:circle(cx, cy, radius * lerp(0.84, 0.90, ht), 0)
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
  radius = radius * (1 + 0.06 * ht)   -- body swells on hover; the panel ticks stay put (1.6.0 sync; SCR137)
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

-- Ableton (style 13) — ableton_knob_draw. The Live 12 dial (2026-09-24): no body,
-- one band 0.83R..R over ±150°, the value in the accent, a dark ink track + thick
-- needle, a short gap in the track past the needle. The ink sits darker than the
-- panel; below panel luminance 0.16 it flips light.
function K.ableton(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local SW = 150 * PI / 180
  local t = clamp((value - vmin) / (vmax - vmin), 0, 1)
  local val_a = -SW + 2 * SW * t
  local start_a = kn_start(is_sym, SW)
  local ht = hover_t * hover_t
  local band = math.max(1.5, radius * 0.17 * (1 + 0.22 * ht))
  local r_in, r_mid = radius - band, radius - band * 0.5
  local nw = math.max(1.5, radius * 0.14 * (1 + 0.15 * ht))
  local gap_a = (nw * 0.5 + math.max(1, radius * 0.12)) / r_mid
  local bl = (bgr + bgg + bgb) * 0.33333
  local ir, ig, ib
  if bl >= 0.16 then
    local k = bl > 0.45 and 0.22 or 0.45
    ir, ig, ib = bgr * k, bgg * k, bgb * k
  else
    ir, ig, ib = bgr + 0.30, bgg + 0.30, bgb + 0.30
  end
  -- Track: everything that is neither value nor the gap past the needle
  g:set(ir, ig, ib, 1)
  if val_a >= start_a then
    kn_band(g, cx, cy, r_in, radius, -SW, start_a)
    kn_band(g, cx, cy, r_in, radius, val_a + gap_a, SW)
  else
    kn_band(g, cx, cy, r_in, radius, -SW, val_a - gap_a)
    kn_band(g, cx, cy, r_in, radius, start_a, SW)
  end
  -- Value, in the accent
  g:set(cr, cg, cb, 1)
  kn_band(g, cx, cy, r_in, radius, math.min(start_a, val_a), math.max(start_a, val_a))
  -- Needle: centre -> through the band, round inner end
  g:set(ir, ig, ib, 1)
  kn_ray(g, cx, cy, val_a, 0, radius - 0.5, nw)
  g:circle(cx, cy, nw * 0.5, 1)
end

-- Pro Tools (style 15) — pt_knob_draw. The Avid EQ III knob (2026-09-25): a black track
-- channel ±130°, a bright green LED (bipolar fills from its anchor; unipolar lights a
-- short dot at the value), a silver skirt with a bevel lit top-left, a knurled ring, a
-- flat cap in the accent set down-right, a thick near-black pointer. bgr/bgg/bgb unused.
function K.pt(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t * hover_t
  local lift = 0.03 * ht
  local SW = 130 * PI / 180
  local rng = vmax - vmin  -- a zero range reads as 0; an inverted one works
  local t = math.abs(rng) > 0.0000001 and clamp((value - vmin) / rng, 0, 1) or 0
  local val = -SW + t * 2 * SW
  -- soft shadow below-right: five faint discs, the widest furthest down
  for i = 5, 1, -1 do
    g:set(0, 0, 0, 0.07)
    g:circle(cx + radius * 0.012 * i, cy + radius * 0.025 * i, radius * (0.815 + 0.012 * i), 1)
  end
  -- track: a black channel, ±130°, square ends
  local tw = math.max(2, radius * 0.125)
  local ri = radius - tw
  g:set(0, 0, 0, 1); kn_band(g, cx, cy, ri, radius, -SW, SW)
  -- the green LED
  local a1, a2
  local sym = is_sym == true and 1 or (type(is_sym) == "number" and is_sym or 0)  -- as EEL2: > 0 = bipolar
  if sym > 0 then
    local a0 = kn_start(sym, SW)
    a1, a2 = math.min(a0, val), math.max(a0, val)
  else
    local hw = math.max(tw * 0.6 / math.max(radius - tw * 0.5, 1), 3 * PI / 180)
    a1, a2 = math.max(-SW, val - hw), math.min(SW, val + hw)
  end
  if a2 > a1 then
    if tw >= 4 then
      g:set(0.01, 0.69, 0, 1); kn_band(g, cx, cy, ri, radius, a1, a2)
      g:set(0, 0.96, 0, 1); kn_band(g, cx, cy, ri + tw * 0.3, radius - tw * 0.3, a1, a2)
    else
      g:set(0, 0.86, 0, 1); kn_band(g, cx, cy, ri, radius, a1, a2)
    end
  end
  -- skirt: dark bevel disc, its lit part a lens toward the top-left, the bright face
  local sk, sf = radius * 0.81, radius * 0.73
  g:set(0.22, 0.22, 0.22, 1); g:circle(cx, cy, sk, 1)
  g:set(0.47 + lift, 0.465 + lift, 0.46 + lift, 1)
  kn_lens(g, cx, cy, sk, cx - radius * 0.035, cy - radius * 0.05, sk)
  local i = floor(cy - sf)
  while i <= cy + sf do
    local yy = i + 0.5 - cy
    local hwid = sqrt(math.max(sf * sf - yy * yy, 0)) - 0.5
    if hwid > 0 then
      local f = (yy + sf) / (2 * sf); f = f * f
      g:set(0.80 - 0.27 * f + lift, 0.81 - 0.27 * f + lift, 0.79 - 0.27 * f + lift, 1)
      local x0 = floor(cx - hwid + 0.5)
      g:rect(x0, i, math.max(1, floor(cx + hwid + 0.5) - x0), 1)
    end
    i = i + 1
  end
  g:set(0.62, 0.63, 0.61, 0.55); g:circle(cx, cy, sf, 0)
  g:set(0.13, 0.13, 0.13, 0.85); g:circle(cx, cy, sk, 0)
  -- knurled ring; its teeth catch the light toward the top-left, from radius 28 px
  local kr = radius * 0.56
  kn_vdisc(g, cx, cy, kr, 0.51 + lift, 0.52 + lift, 0.51 + lift, 0.36, 0.37, 0.36)
  g:set(0.30, 0.30, 0.30, 0.7); g:circle(cx, cy, kr, 0)
  local fade = clamp((radius - 28) / 12, 0, 1)
  if fade > 0 then
    for n = 0, 47 do
      local a = n * 2 * PI / 48
      local w = cos(a + 0.4)
      if w > 0.08 then
        g:set(0.24, 0.24, 0.24, 0.5 * fade * w)
        kn_ray(g, cx, cy, a, kr - radius * 0.03, kr + radius * 0.008, math.max(1, radius * 0.02))
      end
    end
  end
  -- cap: set down-right; light disc, the shaded lens, the middle lens in the cap colour
  local ccx, ccy = cx + radius * 0.03, cy + radius * 0.08
  local rb = radius * 0.50 * (1 + 0.04 * ht)
  local rf, dd = rb * 0.88, rb * 0.07
  g:set(0.15, 0.13, 0.13, 0.8); g:circle(ccx, ccy, rb + 0.8, 1)
  g:set(cr + (1 - cr) * 0.55, cg + (1 - cg) * 0.55, cb + (1 - cb) * 0.55, 1); g:circle(ccx, ccy, rb, 1)
  g:set(cr * 0.60, cg * 0.60, cb * 0.60, 1); kn_lens(g, ccx, ccy, rb, ccx + dd, ccy + dd, rb)
  g:set(cr, cg, cb, 1); kn_lens(g, ccx + dd, ccy + dd, rb, ccx - dd, ccy - dd, rb)
  kn_vdisc(g, ccx, ccy, rf, math.min(cr * 1.04, 1), math.min(cg * 1.04, 1), math.min(cb * 1.04, 1),
           cr * 0.94, cg * 0.94, cb * 0.94)
  g:set(cr * 0.85, cg * 0.85, cb * 0.85, 0.7); g:circle(ccx, ccy, rf, 0)
  -- pointer: thick, near-black (light on a very dark cap)
  if cr * 0.299 + cg * 0.587 + cb * 0.114 < 0.22 then g:set(0.92, 0.92, 0.92, 0.95) else g:set(0.07, 0.06, 0.06, 0.95) end
  kn_ray(g, ccx, ccy, val, radius * 0.10, radius * 0.56, math.max(1.5, radius * 0.09))
end

-- Serum (style 17) — serum_knob_draw. Large beveled dark body, faint track + glowing
-- accent value arc hugging the rim, thin pointer + tip dot, dark centre cap (no ticks).
function K.serum(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local RAD130 = 130 * PI / 180
  local scale = 260 / (vmax - vmin)
  local voffset = -vmin * 260 / (vmax - vmin) - 130
  local val_rad = (value * scale + voffset) * PI / 180
  local body_r = radius * lerp(0.80, 0.86, hover_t)   -- the body swells on hover (knobs_kbsg 1.6.0 sync; SCR137)
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

-- FabFilter (style 16) — fabfilter_knob_draw. The Pro-G knob (2026-09-24): a dome
-- that follows the panel, a white lens scoop with a grey line, a dark tick channel
-- 1.02D..1.155D filled with the accent up to the value, and on big knobs (D 36->48
-- px) a grip of 12 dimples. Light panels: mid-tone dome, the channel sinks.
function K.fabfilter(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local SW, TH = 150 * PI / 180, 27 * PI / 180
  local t = clamp((value - vmin) / (vmax - vmin), 0, 1)
  local val_a = -SW + 2 * SW * t
  local start_a = kn_start(is_sym, SW)
  local ht = hover_t * hover_t
  local dd = radius / 1.155
  local ch_in, ch_out = dd * 1.02, radius - math.max(1, radius * 0.015)
  local gg = clamp((dd - 36) / 12, 0, 1)
  local bl = (bgr + bgg + bgb) * 0.33333
  local sc = bl <= 0.25 and 0.33 or 0.58 - bl
  local lp = bl > 0.5
  -- Channel: panel +0.03 across the sweep, the accent up to the value, a dark line
  -- just outside, ticks every 30° (faint over the accent)
  local f = lp and -0.05 or 0.03
  g:set(bgr + f, bgg + f, bgb + f, 1)
  kn_band(g, cx, cy, ch_in, ch_out, -SW, SW)
  local lo, hi = math.min(start_a, val_a), math.max(start_a, val_a)
  g:set(cr, cg, cb, 1)
  kn_band(g, cx, cy, ch_in, ch_out, lo, hi)
  f = lp and 0.12 or 0.05
  g:set(bgr - f, bgg - f, bgb - f, 1)
  g:arc(cx, cy, ch_out + 0.5, -SW, SW, 1)
  local tw = math.max(1, dd * 0.02)
  f = lp and -0.20 or 0.15
  for i = 0, 10 do
    local a = -SW + i * (30 * PI / 180)
    g:set(bgr + f, bgg + f, bgb + f, (a >= lo and a <= hi) and 0.45 or 1)
    kn_ray(g, cx, cy, a, ch_in, ch_out, tw)
  end
  -- Dome: vertical gradient row by row; hover swells it 3% and lifts it
  dd = dd * (1 + 0.03 * ht)
  local lift = 0.05 * ht
  local i = floor(cy - dd)
  while i <= cy + dd do
    local y = i + 0.5 - cy
    local hw = sqrt(math.max(dd * dd - y * y, 0)) - 0.6
    if hw > 0 then
      local s = sc + 0.16 - 0.32 * ((y + dd) / (2 * dd)) + lift
      g:set(bgr + s - 0.044, bgg + s, bgb + s + 0.042, 1)
      g:rect(floor(cx - hw + 0.5), i, math.max(1, floor(2 * hw + 0.5)), 1)
    end
    i = i + 1
  end
  -- Grip: 12 dimples, a shade darker than the dome where they sit, darker inner edge
  if gg > 0 then
    local dc, drho = 1.039 * dd, 0.269 * dd
    local dph = math.acos((drho * drho + dc * dc - dd * dd) / (2 * drho * dc))
    for k = 0, 11 do
      local a = val_a + (15 + 30 * k) * PI / 180
      local lcx, lcy = cx + sin(a) * dc, cy - cos(a) * dc
      local s = sc + 0.16 - 0.32 * (0.5 - cos(a) * 0.45) + lift - 0.07 * gg
      g:set(bgr + s - 0.044, bgg + s, bgb + s + 0.042, 1)
      kn_lens(g, cx, cy, dd - 0.6, lcx, lcy, drho)
      g:set(bgr + s - 0.144, bgg + s - 0.10, bgb + s - 0.058, gg)
      g:arc(lcx, lcy, drho, a + PI - dph, a + PI + dph, 1)
    end
  end
  -- Scoop: the same lens, bigger, on the pointer (#e2e2e2, a #f2f2f2 core), AA edge
  local tip = 0.30 + 0.12 * gg
  local c = dd * (1 - tip * tip) / (2 * (cos(TH) - tip))
  local rho = c - tip * dd
  local ph = math.acos((rho * rho + c * c - dd * dd) / (2 * rho * c))
  local lcx, lcy = cx + sin(val_a) * c, cy - cos(val_a) * c
  g:set(0.885, 0.885, 0.885, 1)
  kn_lens(g, cx, cy, dd - 0.6, lcx, lcy, rho)
  g:set(0.95, 0.95, 0.95, 1)
  kn_lens(g, cx, cy, dd - 0.10 * rho, lcx, lcy, rho * 0.86)
  g:set(0.885, 0.885, 0.885, 1)
  g:arc(lcx, lcy, rho - 0.6, val_a + PI - ph, val_a + PI + ph, 1)
  g:set(0.10, 0.10, 0.10, 0.55)
  g:arc(lcx, lcy, rho, val_a + PI - ph, val_a + PI + ph, 1)
  g:set(0.44, 0.44, 0.44, 1)
  kn_ray(g, cx, cy, val_a, dd * (0.56 + 0.06 * gg), dd * (0.81 + 0.04 * gg), math.max(1.2, dd * 0.026))
  -- Outline, near-black, over the dome's, the dimples' and the scoop's edges
  local olr = math.min(bgr * 0.45, 0.08)
  g:set(olr, olr, math.min(bgb * 0.45, 0.08), 1)
  local w, rr = math.max(1, dd * 0.035), dd - 0.3
  while rr <= dd + w - 0.3 do g:circle(cx, cy, rr, 0); rr = rr + 0.6 end
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

-- Spice/sp (style 10) — sp_knob_draw (the 2026-09-20 redesign):
-- real units; the role hue scaled by value heat and lifted toward white on hover; a
-- dim track over the full travel; the value arc from the left (bipolar: from its
-- anchor); a glow halo outside the ring; a panel-contrast inner ring with a hover
-- pulse; the perpendicular sweep needle. Re-ported whole: the panel still drew the
-- pre-redesign fixed-blue knob with no track, no halo, no role hue (sweep SCR138).
function K.sp(g, cx, cy, r, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t
  local vn = (value - vmin) / math.max(vmax - vmin, 0.0001)
  -- Bipolar anchor: is_sym 1 = range midpoint; fractional 0<x<1 = normalized
  -- anchor position (value-anchored sym, e.g. 12/18 for a -12..+6 dB knob)
  local sym = (is_sym or 0) ~= 0
  local anc = sym and ((is_sym < 1) and is_sym or 0.5) or 0
  -- Value heat: how hot the knob runs (bipolar = distance off the anchor)
  local heat = sym and math.min(1, math.abs(vn - anc) / math.max(math.max(anc, 1 - anc), 0.0001)) or vn
  -- Role hue scaled by heat, then lifted toward white on hover
  local kr, kg, kb = cr * lerp(0.55, 1.0, heat), cg * lerp(0.55, 1.0, heat), cb * lerp(0.55, 1.0, heat)
  kr = kr + (1 - kr) * 0.25 * ht
  kg = kg + (1 - kg) * 0.25 * ht
  kb = kb + (1 - kb) * 0.25 * ht
  -- Proportions from v6: margin=12, w=18, arc_fill=3, rad=0.6 (scaled to radius)
  local margin = r * 12 / 55
  local w = r * 18 / 55
  local arc_fill = 3
  local knob_rad = 0.6
  local kas = -TAU * (1 + knob_rad / 2)
  local inner = r - w - margin
  local inner_pulse = lerp(0, 2, ht)
  -- Arc span: unipolar fills from the left; bipolar from the anchor
  local a_val = vn * TAU * knob_rad + kas
  local a_ctr = anc * TAU * knob_rad + kas
  local a_lo, a_hi
  if sym then a_lo, a_hi = math.min(a_ctr, a_val), math.max(a_ctr, a_val)
  else a_lo, a_hi = kas, a_val end
  -- Background track (dim role hue) — full travel range, jog-style
  local arc_steps = floor(w * arc_fill)
  local rw_ = r - w
  local a_full = TAU * knob_rad + kas
  g:set(cr * 0.15, cg * 0.15, cb * 0.15, 0.8)
  for i = 0, arc_steps - 1 do g:arc(cx, cy, rw_ + i / arc_fill, kas, a_full) end
  -- Active arc ring
  g:set(kr, kg, kb, 1)
  for i = 0, arc_steps - 1 do g:arc(cx, cy, rw_ + i / arc_fill, a_lo, a_hi) end
  -- Glow halo outside the ring — blooms with value heat and hover
  local glow_a = lerp(0.05, 0.22, math.max(heat * 0.8, ht))
  for j = 1, 4 do
    g:set(kr, kg, kb, glow_a * (1 - j * 0.22))
    g:arc(cx, cy, r + j, a_lo, a_hi, 1)
  end
  -- Inner circle (3-pass outline + hover pulse), panel-contrast ink
  local bg_luma = 0.299 * bgr + 0.587 * bgg + 0.114 * bgb
  local ring = (bg_luma > 0.5) and 0.22 or 0.8
  local ir = inner + inner_pulse
  g:set(ring, ring, ring, 1)
  g:circle(cx, cy, ir, 0); g:circle(cx, cy, ir - 0.5, 0); g:circle(cx, cy, ir - 1, 0)
  -- Needle (perpendicular sweep; the pass count follows the needle width)
  local polar = (vn * 1.01) * TAU * knob_rad + kas
  local xo_ = sin(polar + TAU / 2) * -1
  local yo_ = cos(polar + TAU / 2)
  g:set(kr, kg, kb, 1)
  local nthick = r * 0.15
  local steps = math.max(6, 2 * math.ceil(nthick * 1.5))
  local ex_, ey_ = xo_ * (ir - 1), yo_ * (ir - 1)
  local s = -steps / 2
  while s <= steps / 2 do
    local off_x = s / steps * yo_ * nthick
    local off_y = -s / steps * xo_ * nthick
    g:line(cx + off_x, cy + off_y, cx + off_x + ex_, cy + off_y + ey_)
    s = s + 1
  end
end

-- Encoder (style 11) — encoder_draw. The X-Touch Mini encoder (2026-09-24): no
-- pointer; 13 pill LED bars from -140 to +140 degrees filling to the value in a dark
-- well (the old LED ring's footprint, 1.38r); a small black knob with a grey top and
-- a chamfer lit from the top.
function K.encoder(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb)
  local ht = hover_t * hover_t
  local t = clamp((value - vmin) / (vmax - vmin), 0, 1)
  local SW = 140 * PI / 180
  local wr = radius * 1.38
  local r0, r1, w = radius * 1.02, radius * 1.31, math.max(1.2, radius * 0.11)
  local pos = t * 12
  -- recessed well: darker than any panel, dark edge
  g:set(0, 0, 0, 0.38); g:circle(cx, cy, wr, 1)
  g:set(0, 0, 0, 0.55); g:circle(cx, cy, wr, 0)
  -- 13 LED bars filling to the value; a lit bar blooms softly
  for i = 0, 12 do
    local a = -SW + i * (2 * SW / 12)
    local b = clamp(pos - i + 1, 0, 1)
    g:set(cr * 0.20, cg * 0.20, cb * 0.20, 1)
    kn_pill(g, cx, cy, a, r0, r1, w)
    if b > 0.02 then
      local mx, my = cx + sin(a) * (r0 + r1) * 0.5, cy - cos(a) * (r0 + r1) * 0.5
      g:set(cr, cg, cb, 0.10 * b); g:circle(mx, my, (r1 - r0) * 0.80, 1)
      g:set(cr, cg, cb, 0.14 * b); g:circle(mx, my, (r1 - r0) * 0.55, 1)
      g:set(cr * 0.20 + (math.min(cr * 0.45 + 0.55, 1) - cr * 0.20) * b,
            cg * 0.20 + (math.min(cg * 0.45 + 0.55, 1) - cg * 0.20) * b,
            cb * 0.20 + (math.min(cb * 0.45 + 0.55, 1) - cb * 0.20) * b, 1)
      kn_pill(g, cx, cy, a, r0, r1, w)
    end
  end
  -- knob: black body, chamfer lit from the top, flat grey top face, no pointer
  local k = radius * 0.73 * (1 + 0.06 * ht)
  local tl = 0.29 + 0.04 * ht
  g:set(0, 0, 0, 0.35); g:circle(cx + k * 0.05, cy + k * 0.09, k, 1)
  g:set(0.08, 0.08, 0.08, 1); g:circle(cx, cy, k, 1)
  kn_vdisc(g, cx, cy, k * 0.85, 0.52, 0.52, 0.52, 0.10, 0.10, 0.10)
  g:set(tl, tl, tl, 1); g:circle(cx, cy, k * 0.55, 1)
  g:set(0.05, 0.05, 0.05, 1); g:circle(cx, cy, k, 0)
end

-- Jog (style 8) — jog_knob_draw. Spice-style outer arc ring + metallic jog body with
-- 12 grip notches + position dot. cr/cg/cb = arc colour. (Pixel-constant layout.)
function K.jog(g, cx, cy, radius, value, vmin, vmax, hover_t, arc_r, arc_g, arc_b)
  local ht = hover_t ^ 2
  local or_ = radius
  -- Inner disc: the fixed inset (radius - 10) is the original look down to the
  -- r=25 design size; below about r=18 it collapses and the dot's orbit
  -- (ir_ - 8) goes NEGATIVE, so the dot sat on the wrong side at Pad FX sizes
  -- (radius 14..24). Whichever is larger keeps the original geometry where the
  -- knob is actually drawn and switches to the scale-safe form only where the
  -- old maths breaks down; each derived term below is clamped the same way
  -- (knobs_kbsg jog_knob_draw, 2026-08-02; mirrored SCR139).
  local ir_ = math.max(radius * 0.60, radius - 10)
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
  g:set(0.32 + base_b, 0.32 + base_b, 0.34 + base_b, 1); g:circle(cx, cy, math.max(ir_ * 0.87, ir_ - 2), 1)
  g:set(0.30 + base_b, 0.30 + base_b, 0.32 + base_b, 1); g:circle(cx, cy, math.max(ir_ * 0.67, ir_ - 5), 1)
  g:set(0.28 + base_b, 0.28 + base_b, 0.30 + base_b, 1); g:circle(cx, cy, math.max(ir_ * 0.47, ir_ - 8), 1)
  g:set(0.42 + base_b, 0.42 + base_b, 0.44 + base_b, 0.3)
  g:circle(cx - math.min(radius * 0.08, 2), cy - math.min(radius * 0.12, 3), math.max(ir_ * 0.73, ir_ - 4), 0)
  -- Center dot: fixed 4px originally; the fraction takes over once 4px would dominate the face.
  g:set(0.50 + base_b, 0.50 + base_b, 0.52 + base_b, 1); g:circle(cx, cy, math.min(radius * 0.16, 4), 1)
  for jt = 0, 11 do
    local ja = jt / 12.0 * 2.0 * PI
    local tx1, ty1 = cx + cos(ja) * math.max(or_ * 0.80, or_ - 5), cy + sin(ja) * math.max(or_ * 0.80, or_ - 5)
    local tx2, ty2 = cx + cos(ja) * math.max(or_ * 0.96, or_ - 1), cy + sin(ja) * math.max(or_ * 0.96, or_ - 1)
    g:set(0.15, 0.15, 0.17, 0.6); g:line(tx1 + 0.5, ty1 + 0.5, tx2 + 0.5, ty2 + 0.5)
    g:set(0.55 + base_b, 0.53 + base_b, 0.50 + base_b, 0.8)
    g:line(tx1, ty1, tx2, ty2); g:line(tx1 + 1, ty1, tx2 + 1, ty2)
  end
  val_rad = (-130 + val_norm * 260) * PI / 180
  -- ir_ - 8 is the original orbit and the term that went negative at small radii; the fraction floors it
  local orbit = math.max(ir_ * 0.47, ir_ - 8)
  local ix, iy = cx + sin(val_rad) * orbit, cy - cos(val_rad) * orbit
  g:set(0.90 + ht * 0.1, 0.88 + ht * 0.1, 0.85 + ht * 0.1, 0.9)
  g:circle(ix, iy, math.min(math.max(1.5, radius * 0.12), 3), 1)
  if ht > 0.01 then
    g:set(arc_r, arc_g, arc_b, 0.2 * ht)
    g:circle(cx, cy, or_ + arc_w + 4, 0); g:circle(cx, cy, or_ + arc_w + 5, 0)
  end
end

-- FL (style 14) — fl_knob_draw. The FL Studio knob (2026-09-25): a full turn from the
-- bottom (bipolar from the top), the ring in a dark socket (a groove in the panel colour,
-- lit = the accent), FL's blue-grey dome with a light rim along the top, a dot pointer.
function K.fl(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb)
  local ht = hover_t * hover_t
  local lift = 0.04 * ht
  local rng = vmax - vmin  -- a zero range reads as 0; an inverted one works
  local t = math.abs(rng) > 0.0000001 and clamp((value - vmin) / rng, 0, 1) or 0
  local val = -PI + t * 2 * PI
  local bw = math.max(2, radius * 0.15)
  local ri, rb = radius - bw, radius * 0.79
  local io, ii = math.min(0.8, bw * 0.2), math.min(0.3, bw * 0.1)
  -- socket: dark disc, the groove ring in the panel colour, the dark gap inside it
  g:set(bgr * 0.72, bgg * 0.72, bgb * 0.72, 1); g:circle(cx, cy, radius + 0.5, 1)
  g:set(math.min(bgr + 0.015, 1), math.min(bgg + 0.015, 1), math.min(bgb + 0.015, 1), 1); g:circle(cx, cy, radius - io, 1)
  g:set(bgr * 0.72, bgg * 0.72, bgb * 0.72, 1); g:circle(cx, cy, ri + ii, 1)
  -- the value ring: from the bottom, or from the anchor when bipolar
  local a1, a2
  local sym = is_sym == true and 1 or (type(is_sym) == "number" and is_sym or 0)  -- as EEL2: > 0 = bipolar
  if sym > 0 then
    local a0 = sym >= 1 and 0 or (-PI + sym * 2 * PI)
    a1, a2 = math.min(a0, val), math.max(a0, val)
  else
    a1, a2 = -PI, val
  end
  if a2 > a1 then g:set(cr, cg, cb, 1); kn_band(g, cx, cy, ri + ii, radius - io, a1, a2) end
  -- body: the dome, two soft rings into the gap colour, the rim light along the top
  kn_vdisc(g, cx, cy, rb, 0.40 + lift, 0.427 + lift, 0.451 + lift, 0.204 + lift, 0.231 + lift, 0.247 + lift)
  g:set(bgr * 0.72, bgg * 0.72, bgb * 0.72, 1); g:circle(cx, cy, rb, 0)
  g:set(bgr * 0.72, bgg * 0.72, bgb * 0.72, 0.5); g:circle(cx, cy, rb - 0.8, 0)
  local d = math.max(1.5, radius * 0.09)
  local tt = rb + d - sqrt((rb + d) * (rb + d) - 2 * rb * d * 0.658)
  g:set(0.52 + lift, 0.54 + lift, 0.56 + lift, 1)
  local dp = 0.5
  while dp < tt + 0.3 and dp < rb do
    local ca = (2 * rb * dp - dp * dp + 2 * rb * d * 0.342) / (2 * d * (rb - dp))
    if ca > -1 and ca < 1 then local th = math.acos(ca); g:arc(cx, cy, rb - dp, -th, th, 1) end
    dp = dp + 0.6
  end
  -- the dot
  local dr = rb * 0.74
  local dotr = math.max(1.2, rb * 0.075) * (1 + 0.15 * ht)
  g:set(cr, cg, cb, 1); g:circle(cx + sin(val) * dr, cy - cos(val) * dr, dotr, 1)
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

-- Rainbow Arc (style 9) — rainbow_knob_draw. EON's own knob: a 270-degree arc
-- whose colour cross-fades through EON's six band colours (Tone's six), a dark
-- body with a thin coloured rim, a pointer ending in a dot. Stateless: the colour
-- follows the clock while the knob is up and rests on red at zero.
K.RAINBOW_SIX = { {0.92, 0.30, 0.30}, {0.96, 0.60, 0.18}, {0.38, 0.86, 0.36},
                  {0.22, 0.82, 0.70}, {0.30, 0.66, 0.96}, {0.68, 0.44, 0.96} }
function K.rainbow(g, cx, cy, radius, value, vmin, vmax, hover_t)
  local six = K.RAINBOW_SIX
  local v = clamp((value - vmin) / math.max(1e-7, vmax - vmin), 0, 1)
  local cr, cg, cb = six[1][1], six[1][2], six[1][3]
  if v > 0 then
    local p = (reaper.time_precise() / 0.6) % 6
    local i = floor(p)
    local f = p - i
    f = f * f * (3 - 2 * f)
    local a, b = six[i + 1], six[(i + 1) % 6 + 1]
    cr, cg, cb = lerp(a[1], b[1], f), lerp(a[2], b[2], f), lerp(a[3], b[3], f)
  end
  local hov = hover_t or 0
  local sweep, a0 = PI * 1.5, -PI * 0.75
  local av = a0 + v * sweep
  local ring_w = radius * (0.16 + 0.04 * hov)
  local ring_mid = radius - ring_w * 0.5
  g:set(0.06 + cr * 0.2, 0.06 + cg * 0.2, 0.07 + cb * 0.2, 1)
  g:arc(cx, cy, ring_mid, a0, a0 + sweep, ring_w)
  if v > 0 then
    g:set(cr, cg, cb, 1)
    g:arc(cx, cy, ring_mid, a0, av, ring_w)
  end
  local body_r = radius - ring_w - math.max(2, radius * 0.08)
  g:set(0.10, 0.10, 0.12, 1); g:circle(cx, cy, body_r, 1)
  g:set(cr, cg, cb, 0.55 + 0.35 * hov); g:circle(cx, cy, body_r, 0)
  local s, c = sin(av), -cos(av)
  g:set(cr, cg, cb, 1)
  g:line(cx + s * body_r * 0.35, cy + c * body_r * 0.35, cx + s * body_r * 0.85, cy + c * body_r * 0.85, 1.5)
  g:circle(cx + s * body_r * 0.85, cy + c * body_r * 0.85, math.max(1.5, radius * 0.05), 1)
end

-- ── Dispatcher ───────────────────────────────────────────────────────────────
-- Style ids match knobs_kbsg.jsfx-inc rk_knob_draw (1 ssl · 2 varimu · 3 api ·
-- 4 ws · 5 neve · 6 jo · 7 mpc · 8 jog · 9 rainbow · 10 sp · 11 encoder · 12 pultec ·
-- 13 ableton · 14 fl · 15 pt · 16 fabfilter · 17 serum · 18 roland).
-- PORTED: ssl(1) varimu(2) api(3) ws(4) neve(5) jo(6) mpc(7) jog(8) rainbow(9)
-- sp(10) encoder(11) pultec(12) ableton(13) fl(14) pt(15) fabfilter(16) serum(17)
-- roland(18) pultec_cream(19) neve_alt(20). (0/unknown → ssl.)
function K.draw(style, g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t,
                cr, cg, cb, n_det, bgr, bgg, bgb)
  if style == 2  then return K.varimu(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb) end
  if style == 3  then return K.api(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb) end
  if style == 4  then return K.ws(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 5  then return K.neve(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb, n_det) end
  if style == 6  then return K.jo(g, cx, cy, radius, (value - vmin) / math.max(1e-7, vmax - vmin), hover_t, cr, cg, cb) end
  if style == 7  then return K.mpc(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 8  then return K.jog(g, cx, cy, radius, value, vmin, vmax, hover_t, cr, cg, cb) end
  if style == 9  then return K.rainbow(g, cx, cy, radius, value, vmin, vmax, hover_t) end
  if style == 10 then return K.sp(g, cx, cy, radius, value, vmin, vmax, is_sym, hover_t, cr, cg, cb, bgr, bgg, bgb) end
  if style == 11 then return K.encoder(g, cx, cy, radius / 1.38, value, vmin, vmax, hover_t, cr, cg, cb) end  -- collar reaches 1.38 R: fit the others' footprint
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
