-- rk_lua_cat_glyphs.lua — ReaKit 46-category instrument glyphs, ReaImGui
-- DrawList transcription of rk_cat_glyphs.jsfx-inc (installer/src/Swing/libs/,
-- THE source of truth — coordinates here are copied 1:1; change the JSFX first,
-- then mirror). Used by the Drum Matrix (stereo lane headers, piano row labels,
-- Pads tab). Sibling transcriptions: gen_icons.py (PNG track icons).
--
-- API:
--   M.draw(dl, cat, cx, cy, s, col, th)  -- col = 0xRRGGBBAA, th = stroke px
--                                           LOD like the JSFX: s < 11 -> small tier
--   M.ID[category_string] -> id            -- eon_filename_categorizer strings
--   M.NAMES[id] -> display name
--
-- Primitive mapping (JSFX -> DrawList):
--   gfx_line              -> AddLine
--   gfx_circle(..,1,1)    -> AddCircleFilled     gfx_circle(..,0,1) -> AddCircle
--   gfx_rect(x,y,w,h,0)   -> AddRect             gfx_rect(x,y,w,h)  -> AddRectFilled
--   eon_ell               -> 22-segment AddLine polyline (identical math)
-- (c) EON Studios — All Rights Reserved

local M = {}
local r = reaper
local cos, sin, max, pi = math.cos, math.sin, math.max, math.pi

-- category ids: FROZEN, append-only (persisted in StepSeq lane_icon_override)
M.NAMES = {
  [0]='Kick', 'Snare', 'Rimshot', 'Clap', 'Closed Hat', 'Open Hat', 'Hi-Hat',
  'Cymbal', 'Crash', 'Ride', 'Floor Tom', 'Rack Tom', 'Tom', 'Conga', 'Bongo',
  'Cowbell', 'Clave', 'Tambourine', 'Shaker', 'Maraca', 'Percussion', 'Bass',
  'Synth', 'Pad', 'Keys', 'Guitar', 'Strings', 'Brass', 'Vocal', 'FX', 'Loop',
  'Other', 'Snap', 'Splash', 'China', 'Sidestick', 'Triangle', 'Woodblock',
  'Cabasa', 'Guiro', 'Timbale', 'Agogo', 'Djembe', 'Cajon', 'Vibraslap', 'Whistle',
}
M.ID = {
  kick=0, snare=1, rimshot=2, clap=3, closed_hat=4, open_hat=5, hihat=6,
  cymbal=7, crash=8, ride=9, floor_tom=10, rack_tom=11, tom=12, conga=13,
  bongo=14, cowbell=15, clave=16, tambourine=17, shaker=18, maraca=19,
  percussion=20, bass=21, synth=22, pad=23, keys=24, guitar=25, strings=26,
  brass=27, vocal=28, fx=29, loop=30, other=31, snap=32, splash=33, china=34,
  sidestick=35, triangle=36, woodblock=37, cabasa=38, guiro=39, timbale=40,
  agogo=41, djembe=42, cajon=43, vibraslap=44, whistle=45,
}

-- primitive shims (module-locals rebound per draw call — single-threaded UI)
local _dl, _col, _th
local function L(x1, y1, x2, y2) r.ImGui_DrawList_AddLine(_dl, x1, y1, x2, y2, _col, _th) end
local function C(cx, cy, rad)    r.ImGui_DrawList_AddCircle(_dl, cx, cy, rad, _col, 0, _th) end
local function CF(cx, cy, rad)   r.ImGui_DrawList_AddCircleFilled(_dl, cx, cy, rad, _col, 0) end
local function R(x, y, w, h)     r.ImGui_DrawList_AddRect(_dl, x, y, x + w, y + h, _col, 0, 0, _th) end
local function RF(x, y, w, h)    r.ImGui_DrawList_AddRectFilled(_dl, x, y, x + w, y + h, _col) end
local function ELL(cx, cy, rx, ry, a0, a1)  -- eon_ell: 22-segment polyline
  local n, a = 22, a0
  local st = (a1 - a0) / n
  local px, py = cx + rx * cos(a), cy + ry * sin(a)
  for _ = 1, n do
    a = a + st
    local x, y = cx + rx * cos(a), cy + ry * sin(a)
    L(px, py, x, y)
    px, py = x, y
  end
end

-- SMALL tier (s < 11): <=6 strokes per glyph — 1:1 with eon_cat_glyph_sm
local function sm(cat, cx, cy, s)
  local s2 = s * 0.5
  if cat == 0 then CF(cx, cy, s)
  elseif cat == 1 then C(cx, cy, s) L(cx-s, cy-s2, cx+s, cy+s2) L(cx-s, cy, cx+s, cy+s)
  elseif cat == 2 then C(cx, cy, s) L(cx-0.6*s, cy-s, cx+s, cy-0.2*s)
  elseif cat == 3 then L(cx-s, cy+s, cx-s2, cy-s) L(cx+1, cy+s, cx+s2+1, cy-s)
  elseif cat == 4 then L(cx-s, cy-1, cx+s, cy-1) L(cx-s, cy+1, cx+s, cy+1)
  elseif cat == 5 then L(cx-s, cy-s2, cx+s, cy-s2) L(cx-s, cy+s2, cx+s, cy+s2)
  elseif cat == 6 then L(cx-s, cy-2, cx+s, cy-2) L(cx-s, cy+1, cx+s, cy+1) L(cx, cy+1, cx, cy+s)
  elseif cat == 7 then C(cx, cy, s) CF(cx, cy, 1.5)
  elseif cat == 8 then C(cx, cy, 0.65*s) L(cx, cy-0.65*s, cx, cy-s) L(cx-0.5*s, cy-0.45*s, cx-0.8*s, cy-0.75*s) L(cx+0.5*s, cy-0.45*s, cx+0.8*s, cy-0.75*s)
  elseif cat == 9 then C(cx, cy, s) CF(cx, cy, max(1.5, 0.35*s))
  elseif cat == 10 then C(cx, cy-0.1*s, 0.9*s) L(cx-0.5*s, cy+0.6*s, cx-0.7*s, cy+s) L(cx+0.5*s, cy+0.6*s, cx+0.7*s, cy+s)
  elseif cat == 11 then C(cx, cy+0.1*s, 0.85*s) L(cx-s2, cy-s, cx+s2, cy-s)
  elseif cat == 12 then C(cx, cy, 0.85*s)
  elseif cat == 13 then L(cx-s2, cy-s, cx+s2, cy-s) L(cx-s2, cy-s, cx-0.35*s, cy+s) L(cx+s2, cy-s, cx+0.35*s, cy+s) L(cx-0.35*s, cy+s, cx+0.35*s, cy+s)
  elseif cat == 14 then C(cx-s2, cy, s2) C(cx+0.55*s, cy+0.1*s, 0.4*s)
  elseif cat == 15 then L(cx-s2, cy-s, cx+s2, cy-s) L(cx-s2, cy-s, cx-s, cy+s) L(cx+s2, cy-s, cx+s, cy+s) L(cx-s, cy+s, cx+s, cy+s)
  elseif cat == 16 then L(cx-0.72*s, cy+0.52*s, cx+0.5*s, cy-0.6*s) L(cx-0.5*s, cy+0.66*s, cx+0.72*s, cy-0.46*s)
  elseif cat == 17 then C(cx, cy, s) CF(cx, cy-0.6*s, 1.2) CF(cx-0.55*s, cy+0.35*s, 1.2) CF(cx+0.55*s, cy+0.35*s, 1.2)
  elseif cat == 18 then ELL(cx, cy, 0.45*s, 0.75*s, 0, 2*pi)
  elseif cat == 19 then C(cx, cy-0.4*s, 0.55*s) L(cx, cy+0.15*s, cx, cy+s)
  elseif cat == 20 then L(cx-0.75*s, cy+0.8*s, cx+0.6*s, cy-0.75*s) L(cx+0.75*s, cy+0.8*s, cx-0.6*s, cy-0.75*s) CF(cx+0.6*s, cy-0.75*s, 1.5) CF(cx-0.6*s, cy-0.75*s, 1.5)
  elseif cat == 21 then R(cx-s, cy-s, 2*s, 2*s) CF(cx, cy, max(1.5, 0.3*s))
  elseif cat == 22 then L(cx-s, cy+s2, cx-0.33*s, cy-s2) L(cx-0.33*s, cy-s2, cx+0.33*s, cy+s2) L(cx+0.33*s, cy+s2, cx+s, cy-s2)
  elseif cat == 23 then L(cx-s, cy, cx-s2, cy-s2) L(cx-s2, cy-s2, cx, cy) L(cx, cy, cx+s2, cy+s2) L(cx+s2, cy+s2, cx+s, cy)
  elseif cat == 24 then R(cx-s, cy-0.6*s, 2*s, 1.2*s) L(cx-0.33*s, cy-0.6*s, cx-0.33*s, cy+0.6*s) L(cx+0.33*s, cy-0.6*s, cx+0.33*s, cy+0.6*s)
  elseif cat == 25 then C(cx, cy+0.3*s, 0.6*s) L(cx, cy-0.3*s, cx, cy-s)
  elseif cat == 26 then L(cx-s2, cy-s, cx-s2, cy+s) L(cx, cy-s, cx, cy+s) L(cx+s2, cy-s, cx+s2, cy+s) L(cx-s, cy+s2, cx+s, cy-s2)
  elseif cat == 27 then L(cx+s, cy-s2, cx+s, cy+s2) L(cx+s, cy-s2, cx-s, cy) L(cx+s, cy+s2, cx-s, cy)
  elseif cat == 28 then C(cx, cy-0.4*s, 0.45*s) L(cx, cy+0.05*s, cx, cy+s) L(cx-0.4*s, cy+s, cx+0.4*s, cy+s)
  elseif cat == 29 then L(cx-s, cy, cx+s, cy) L(cx, cy-s, cx, cy+s) L(cx-s2, cy-s2, cx+s2, cy+s2) L(cx-s2, cy+s2, cx+s2, cy-s2)
  elseif cat == 30 then ELL(cx, cy, 0.62*s, 0.62*s, 0.75, 2*pi) L(cx+0.45*s, cy+0.42*s, cx+0.23*s, cy+0.4*s) L(cx+0.45*s, cy+0.42*s, cx+0.41*s, cy+0.18*s)
  elseif cat == 32 then CF(cx, cy+0.35*s, max(1.5, 0.2*s)) L(cx, cy+0.1*s, cx, cy-0.6*s) L(cx-0.25*s, cy+0.15*s, cx-0.7*s, cy-0.4*s) L(cx+0.25*s, cy+0.15*s, cx+0.7*s, cy-0.4*s)
  elseif cat == 33 then L(cx-s, cy+0.1*s, cx+s, cy+0.1*s) L(cx, cy+0.1*s, cx, cy+0.7*s) CF(cx-0.4*s, cy-0.4*s, 1.2) CF(cx+0.35*s, cy-0.55*s, 1.2)
  elseif cat == 34 then L(cx-s, cy-0.4*s, cx-0.5*s, cy+0.1*s) L(cx-0.5*s, cy+0.1*s, cx+0.5*s, cy+0.1*s) L(cx+0.5*s, cy+0.1*s, cx+s, cy-0.4*s) L(cx, cy+0.1*s, cx, cy+0.7*s)
  elseif cat == 35 then C(cx, cy, 0.75*s) L(cx-s, cy, cx+s, cy)
  elseif cat == 36 then L(cx-0.8*s, cy+0.7*s, cx, cy-0.8*s) L(cx, cy-0.8*s, cx+0.8*s, cy+0.7*s) L(cx-0.8*s, cy+0.7*s, cx+0.8*s, cy+0.7*s)
  elseif cat == 37 then R(cx-0.8*s, cy-0.4*s, 1.6*s, 0.9*s) L(cx-0.5*s, cy-0.05*s, cx+0.5*s, cy-0.05*s)
  elseif cat == 38 then C(cx, cy-0.15*s, 0.6*s) L(cx-0.4*s, cy-0.55*s, cx+0.4*s, cy+0.25*s) L(cx+0.4*s, cy-0.55*s, cx-0.4*s, cy+0.25*s) L(cx, cy+0.45*s, cx, cy+s)
  elseif cat == 39 then ELL(cx, cy, 0.85*s, 0.4*s, 0, 2*pi) L(cx-0.4*s, cy-0.35*s, cx-0.4*s, cy+0.35*s) L(cx, cy-0.4*s, cx, cy+0.4*s) L(cx+0.4*s, cy-0.35*s, cx+0.4*s, cy+0.35*s)
  elseif cat == 40 then L(cx-0.85*s, cy-0.3*s, cx+0.85*s, cy-0.3*s) L(cx-0.85*s, cy-0.3*s, cx-0.85*s, cy+0.15*s) L(cx+0.85*s, cy-0.3*s, cx+0.85*s, cy+0.15*s) L(cx-0.85*s, cy+0.15*s, cx+0.85*s, cy+0.15*s) L(cx, cy+0.15*s, cx, cy+0.9*s)
  elseif cat == 41 then L(cx-0.7*s, cy-0.4*s, cx-0.35*s, cy+0.4*s) L(cx-0.05*s, cy-0.4*s, cx-0.35*s, cy+0.4*s) L(cx+0.15*s, cy-0.3*s, cx+0.5*s, cy+0.55*s) L(cx+0.85*s, cy-0.3*s, cx+0.5*s, cy+0.55*s)
  elseif cat == 42 then L(cx-0.7*s, cy-0.6*s, cx+0.7*s, cy-0.6*s) L(cx-0.7*s, cy-0.6*s, cx-0.2*s, cy+0.2*s) L(cx+0.7*s, cy-0.6*s, cx+0.2*s, cy+0.2*s) L(cx-0.2*s, cy+0.2*s, cx-0.5*s, cy+0.9*s) L(cx+0.2*s, cy+0.2*s, cx+0.5*s, cy+0.9*s)
  elseif cat == 43 then R(cx-0.65*s, cy-0.8*s, 1.3*s, 1.6*s) C(cx, cy-0.35*s, max(2, 0.22*s))
  elseif cat == 44 then L(cx-0.7*s, cy+0.6*s, cx+0.4*s, cy-0.5*s) CF(cx-0.75*s, cy+0.68*s, max(1.5, 0.18*s)) L(cx+0.4*s, cy-0.5*s, cx+0.85*s, cy-0.25*s) L(cx+0.4*s, cy-0.5*s, cx+0.6*s, cy-0.85*s)
  elseif cat == 45 then C(cx-0.15*s, cy+0.1*s, 0.55*s) L(cx+0.3*s, cy-0.3*s, cx+0.9*s, cy-0.3*s) L(cx+0.3*s, cy-0.05*s, cx+0.9*s, cy-0.05*s) L(cx+0.9*s, cy-0.3*s, cx+0.9*s, cy-0.05*s)
  else -- 31 other: waveform bars
    L(cx-0.6*s, cy-0.3*s, cx-0.6*s, cy+0.3*s) L(cx-0.3*s, cy-0.6*s, cx-0.3*s, cy+0.6*s) L(cx, cy-0.42*s, cx, cy+0.42*s) L(cx+0.3*s, cy-0.68*s, cx+0.3*s, cy+0.68*s) L(cx+0.6*s, cy-0.25*s, cx+0.6*s, cy+0.25*s)
  end
end

-- DETAILED tier (s >= 11) — 1:1 with eon_cat_glyph_lg (crash pre-scaled 0.85)
local function lg(cat, cx, cy, s)
  if cat == 0 then C(cx, cy-0.08*s, 0.82*s) C(cx, cy-0.08*s, 0.4*s) CF(cx+0.16*s, cy+0.02*s, 0.15*s) L(cx+0.16*s, cy+0.02*s, cx+0.66*s, cy+0.42*s) L(cx-0.48*s, cy+0.56*s, cx-0.66*s, cy+0.98*s) L(cx+0.48*s, cy+0.56*s, cx+0.66*s, cy+0.98*s)
  elseif cat == 1 then ELL(cx, cy-0.4*s, 0.85*s, 0.24*s, 0, 2*pi) L(cx-0.85*s, cy-0.4*s, cx-0.85*s, cy+0.42*s) L(cx+0.85*s, cy-0.4*s, cx+0.85*s, cy+0.42*s) ELL(cx, cy+0.42*s, 0.85*s, 0.24*s, 0, pi) L(cx-0.45*s, cy-0.06*s, cx-0.45*s, cy+0.2*s) L(cx, cy-0.06*s, cx, cy+0.2*s) L(cx+0.45*s, cy-0.06*s, cx+0.45*s, cy+0.2*s)
  elseif cat == 2 then ELL(cx, cy-0.35*s, 0.8*s, 0.22*s, 0, 2*pi) L(cx-0.8*s, cy-0.35*s, cx-0.8*s, cy+0.42*s) L(cx+0.8*s, cy-0.35*s, cx+0.8*s, cy+0.42*s) ELL(cx, cy+0.42*s, 0.8*s, 0.22*s, 0, pi) L(cx-0.4*s, cy-0.05*s, cx-0.4*s, cy+0.18*s) L(cx+0.4*s, cy-0.05*s, cx+0.4*s, cy+0.18*s) L(cx-0.55*s, cy-0.68*s, cx+0.72*s, cy-0.12*s) L(cx+0.22*s, cy-0.86*s, cx+0.5*s, cy-0.5*s)
  elseif cat == 3 then
    local p = { {-0.4,0.72},{-0.46,0.1},{-0.5,-0.48},{-0.4,-0.56},{-0.33,-0.4},{-0.3,-0.2},{-0.24,-0.6},{-0.14,-0.7},{-0.05,-0.58},{-0.02,-0.24},{0.04,-0.62},{0.14,-0.7},{0.22,-0.54},{0.26,-0.2},{0.32,-0.5},{0.42,-0.56},{0.47,-0.36},{0.45,0.02},{0.74,-0.02},{0.52,0.2},{0.36,0.52},{0.26,0.72},{-0.4,0.72} }
    for i = 1, #p - 1 do L(cx + p[i][1]*s, cy + p[i][2]*s, cx + p[i+1][1]*s, cy + p[i+1][2]*s) end
  elseif cat == 4 then L(cx-0.9*s, cy-0.12*s, cx+0.9*s, cy-0.12*s) L(cx-0.9*s, cy+0.12*s, cx+0.9*s, cy+0.12*s) L(cx, cy+0.12*s, cx, cy+0.72*s) L(cx, cy-0.12*s, cx, cy-0.48*s)
  elseif cat == 5 then L(cx-0.9*s, cy-0.45*s, cx+0.9*s, cy-0.45*s) L(cx-0.9*s, cy+0.15*s, cx+0.9*s, cy+0.15*s) L(cx, cy+0.15*s, cx, cy+0.78*s) L(cx, cy-0.45*s, cx, cy-0.72*s)
  elseif cat == 6 then L(cx-0.75*s, cy-0.15*s, cx+0.75*s, cy-0.15*s) L(cx-0.75*s, cy+0.05*s, cx+0.75*s, cy+0.05*s) CF(cx, cy-0.72*s, 0.08*s) L(cx, cy-0.15*s, cx, cy-0.68*s) L(cx, cy+0.05*s, cx, cy+0.62*s) L(cx, cy+0.62*s, cx-0.3*s, cy+0.95*s) L(cx, cy+0.62*s, cx+0.3*s, cy+0.95*s)
  elseif cat == 7 then C(cx, cy, 0.86*s) C(cx, cy, 0.34*s) CF(cx, cy, 0.12*s)
  elseif cat == 8 then
    local sc = s * 0.85
    C(cx, cy, 0.72*sc) CF(cx, cy, 0.1*sc) L(cx+0.74*sc, cy+0.43*sc, cx+0.97*sc, cy+0.56*sc) L(cx, cy+0.85*sc, cx, cy+1.12*sc) L(cx-0.74*sc, cy+0.43*sc, cx-0.97*sc, cy+0.56*sc) L(cx-0.74*sc, cy-0.43*sc, cx-0.97*sc, cy-0.56*sc) L(cx, cy-0.85*sc, cx, cy-1.12*sc) L(cx+0.74*sc, cy-0.43*sc, cx+0.97*sc, cy-0.56*sc)
  elseif cat == 9 then C(cx, cy, 0.82*s) CF(cx, cy, 0.24*s)
  elseif cat == 10 then ELL(cx, cy-0.42*s, 0.8*s, 0.26*s, 0, 2*pi) L(cx-0.8*s, cy-0.42*s, cx-0.8*s, cy+0.34*s) L(cx+0.8*s, cy-0.42*s, cx+0.8*s, cy+0.34*s) ELL(cx, cy+0.34*s, 0.8*s, 0.26*s, 0, pi) L(cx-0.34*s, cy-0.14*s, cx-0.34*s, cy+0.12*s) L(cx+0.34*s, cy-0.14*s, cx+0.34*s, cy+0.12*s) L(cx-0.44*s, cy+0.42*s, cx-0.6*s, cy+0.92*s) L(cx+0.44*s, cy+0.42*s, cx+0.6*s, cy+0.92*s)
  elseif cat == 11 then ELL(cx, cy-0.38*s, 0.72*s, 0.22*s, 0, 2*pi) L(cx-0.72*s, cy-0.38*s, cx-0.72*s, cy+0.36*s) L(cx+0.72*s, cy-0.38*s, cx+0.72*s, cy+0.36*s) ELL(cx, cy+0.36*s, 0.72*s, 0.22*s, 0, pi) L(cx-0.28*s, cy-0.08*s, cx-0.28*s, cy+0.16*s) L(cx+0.28*s, cy-0.08*s, cx+0.28*s, cy+0.16*s) L(cx, cy-0.58*s, cx, cy-0.92*s) L(cx-0.12*s, cy-0.92*s, cx+0.12*s, cy-0.92*s)
  elseif cat == 12 then ELL(cx, cy-0.5*s, 0.82*s, 0.26*s, 0, 2*pi) L(cx-0.82*s, cy-0.5*s, cx-0.82*s, cy+0.5*s) L(cx+0.82*s, cy-0.5*s, cx+0.82*s, cy+0.5*s) ELL(cx, cy+0.5*s, 0.82*s, 0.26*s, 0, pi) L(cx-0.32*s, cy-0.12*s, cx-0.32*s, cy+0.2*s) L(cx+0.32*s, cy-0.12*s, cx+0.32*s, cy+0.2*s)
  elseif cat == 13 then ELL(cx, cy-0.78*s, 0.55*s, 0.19*s, 0, 2*pi) L(cx-0.55*s, cy-0.78*s, cx-0.46*s, cy+0.82*s) L(cx+0.55*s, cy-0.78*s, cx+0.46*s, cy+0.82*s) ELL(cx, cy+0.82*s, 0.46*s, 0.16*s, 0, pi) L(cx-0.2*s, cy-0.35*s, cx-0.2*s, cy+0.02*s) L(cx+0.2*s, cy-0.35*s, cx+0.2*s, cy+0.02*s)
  elseif cat == 14 then ELL(cx-0.4*s, cy-0.3*s, 0.42*s, 0.16*s, 0, 2*pi) L(cx-0.82*s, cy-0.3*s, cx-0.82*s, cy+0.55*s) L(cx+0.02*s, cy-0.3*s, cx+0.02*s, cy+0.55*s) ELL(cx-0.4*s, cy+0.55*s, 0.42*s, 0.16*s, 0, pi) L(cx-0.4*s, cy-0.05*s, cx-0.4*s, cy+0.2*s) ELL(cx+0.46*s, cy-0.18*s, 0.34*s, 0.14*s, 0, 2*pi) L(cx+0.12*s, cy-0.18*s, cx+0.12*s, cy+0.5*s) L(cx+0.8*s, cy-0.18*s, cx+0.8*s, cy+0.5*s) ELL(cx+0.46*s, cy+0.5*s, 0.34*s, 0.14*s, 0, pi) L(cx+0.46*s, cy+0.02*s, cx+0.46*s, cy+0.22*s)
  elseif cat == 15 then L(cx-0.32*s, cy-0.85*s, cx+0.32*s, cy-0.85*s) L(cx-0.32*s, cy-0.85*s, cx-0.62*s, cy+0.72*s) L(cx+0.32*s, cy-0.85*s, cx+0.62*s, cy+0.72*s) L(cx-0.62*s, cy+0.72*s, cx+0.62*s, cy+0.72*s) L(cx-0.46*s, cy+0.32*s, cx+0.46*s, cy+0.32*s)
  elseif cat == 16 then L(cx-0.72*s, cy+0.52*s, cx+0.5*s, cy-0.6*s) L(cx-0.5*s, cy+0.66*s, cx+0.72*s, cy-0.46*s)
  elseif cat == 17 then C(cx, cy, 0.85*s) C(cx, cy, 0.52*s) CF(cx, cy-0.68*s, 0.1*s) CF(cx+0.59*s, cy-0.34*s, 0.1*s) CF(cx+0.59*s, cy+0.34*s, 0.1*s) CF(cx, cy+0.68*s, 0.1*s) CF(cx-0.59*s, cy+0.34*s, 0.1*s) CF(cx-0.59*s, cy-0.34*s, 0.1*s)
  elseif cat == 18 then ELL(cx, cy, 0.4*s, 0.62*s, 0, 2*pi) CF(cx-0.12*s, cy-0.12*s, 0.06*s) CF(cx+0.1*s, cy+0.16*s, 0.06*s) L(cx+0.56*s, cy-0.5*s, cx+0.76*s, cy-0.4*s) L(cx+0.6*s, cy-0.18*s, cx+0.8*s, cy-0.08*s)
  elseif cat == 19 then C(cx+0.02*s, cy-0.36*s, 0.42*s) L(cx-0.28*s, cy+0.08*s, cx+0.32*s, cy+0.08*s) L(cx-0.12*s, cy+0.08*s, cx-0.12*s, cy+0.86*s) L(cx+0.16*s, cy+0.08*s, cx+0.16*s, cy+0.86*s) L(cx-0.12*s, cy+0.86*s, cx+0.16*s, cy+0.86*s) L(cx+0.56*s, cy-0.66*s, cx+0.76*s, cy-0.54*s) L(cx+0.62*s, cy-0.34*s, cx+0.82*s, cy-0.24*s)
  elseif cat == 20 then L(cx-0.7*s, cy+0.85*s, cx+0.55*s, cy-0.75*s) CF(cx+0.6*s, cy-0.82*s, 0.09*s) L(cx+0.7*s, cy+0.85*s, cx-0.55*s, cy-0.75*s) CF(cx-0.6*s, cy-0.82*s, 0.09*s)
  elseif cat == 21 then L(cx-0.85*s, cy-0.85*s, cx+0.85*s, cy-0.85*s) L(cx+0.85*s, cy-0.85*s, cx+0.85*s, cy+0.85*s) L(cx+0.85*s, cy+0.85*s, cx-0.85*s, cy+0.85*s) L(cx-0.85*s, cy+0.85*s, cx-0.85*s, cy-0.85*s) C(cx, cy, 0.42*s) CF(cx, cy, 0.14*s)
  elseif cat == 22 then L(cx-0.85*s, cy+0.4*s, cx-0.35*s, cy-0.4*s) L(cx-0.35*s, cy-0.4*s, cx-0.35*s, cy+0.4*s) L(cx-0.35*s, cy+0.4*s, cx+0.15*s, cy-0.4*s) L(cx+0.15*s, cy-0.4*s, cx+0.15*s, cy+0.4*s) L(cx+0.15*s, cy+0.4*s, cx+0.65*s, cy-0.4*s) L(cx+0.65*s, cy-0.4*s, cx+0.65*s, cy+0.4*s)
  elseif cat == 23 then L(cx-0.85*s, cy, cx-0.42*s, cy-0.45*s) L(cx-0.42*s, cy-0.45*s, cx, cy) L(cx, cy, cx+0.42*s, cy+0.45*s) L(cx+0.42*s, cy+0.45*s, cx+0.85*s, cy)
  elseif cat == 24 then L(cx-0.85*s, cy-0.5*s, cx+0.85*s, cy-0.5*s) L(cx-0.85*s, cy+0.55*s, cx+0.85*s, cy+0.55*s) L(cx-0.85*s, cy-0.5*s, cx-0.85*s, cy+0.55*s) L(cx+0.85*s, cy-0.5*s, cx+0.85*s, cy+0.55*s) L(cx-0.3*s, cy-0.5*s, cx-0.3*s, cy+0.55*s) L(cx+0.28*s, cy-0.5*s, cx+0.28*s, cy+0.55*s) RF(cx-0.52*s, cy-0.5*s, 0.26*s, 0.62*s) RF(cx+0.02*s, cy-0.5*s, 0.26*s, 0.62*s)
  elseif cat == 25 then C(cx, cy+0.35*s, 0.5*s) C(cx, cy-0.15*s, 0.34*s) C(cx, cy+0.2*s, 0.12*s) L(cx, cy-0.45*s, cx, cy-0.95*s) L(cx-0.12*s, cy-0.95*s, cx+0.12*s, cy-0.95*s)
  elseif cat == 26 then L(cx-0.3*s, cy-0.72*s, cx-0.3*s, cy+0.72*s) L(cx-0.1*s, cy-0.72*s, cx-0.1*s, cy+0.72*s) L(cx+0.1*s, cy-0.72*s, cx+0.1*s, cy+0.72*s) L(cx+0.3*s, cy-0.72*s, cx+0.3*s, cy+0.72*s) L(cx-0.78*s, cy+0.4*s, cx+0.78*s, cy-0.4*s)
  elseif cat == 27 then L(cx+0.82*s, cy-0.5*s, cx+0.82*s, cy+0.5*s) L(cx+0.82*s, cy-0.5*s, cx+0.42*s, cy-0.2*s) L(cx+0.82*s, cy+0.5*s, cx+0.42*s, cy+0.2*s) L(cx+0.42*s, cy, cx-0.72*s, cy) C(cx-0.82*s, cy, 0.1*s) L(cx-0.05*s, cy-0.05*s, cx-0.05*s, cy-0.3*s) L(cx+0.12*s, cy-0.05*s, cx+0.12*s, cy-0.32*s) L(cx+0.29*s, cy-0.05*s, cx+0.29*s, cy-0.3*s)
  elseif cat == 28 then C(cx, cy-0.4*s, 0.35*s) L(cx-0.28*s, cy-0.5*s, cx+0.28*s, cy-0.5*s) L(cx-0.32*s, cy-0.32*s, cx+0.32*s, cy-0.32*s) L(cx-0.12*s, cy-0.08*s, cx-0.12*s, cy+0.72*s) L(cx+0.12*s, cy-0.08*s, cx+0.12*s, cy+0.72*s) L(cx-0.12*s, cy+0.72*s, cx+0.12*s, cy+0.72*s) L(cx-0.35*s, cy+0.92*s, cx+0.35*s, cy+0.92*s) L(cx, cy+0.72*s, cx, cy+0.92*s)
  elseif cat == 29 then L(cx-0.9*s, cy+0.7*s, cx-0.35*s, cy+0.35*s) L(cx-0.35*s, cy+0.35*s, cx+0.15*s, cy-0.15*s) L(cx+0.15*s, cy-0.15*s, cx+0.72*s, cy-0.62*s) L(cx+0.72*s, cy-0.62*s, cx+0.33*s, cy-0.55*s) L(cx+0.72*s, cy-0.62*s, cx+0.6*s, cy-0.22*s)
  elseif cat == 30 then ELL(cx, cy, 0.62*s, 0.62*s, 0.75, 2*pi) L(cx+0.45*s, cy+0.42*s, cx+0.23*s, cy+0.4*s) L(cx+0.45*s, cy+0.42*s, cx+0.41*s, cy+0.18*s)
  elseif cat == 32 then L(cx-0.1*s, cy+0.95*s, cx-0.1*s, cy+0.2*s) L(cx-0.1*s, cy+0.2*s, cx-0.3*s, cy-0.7*s) L(cx-0.1*s, cy+0.2*s, cx+0.55*s, cy-0.15*s) CF(cx+0.28*s, cy-0.45*s, 0.07*s) L(cx+0.45*s, cy-0.6*s, cx+0.65*s, cy-0.8*s) L(cx+0.55*s, cy-0.35*s, cx+0.82*s, cy-0.42*s) L(cx+0.18*s, cy-0.72*s, cx+0.22*s, cy-0.95*s)
  elseif cat == 33 then ELL(cx, cy-0.05*s, 0.78*s, 0.18*s, 0, 2*pi) CF(cx, cy-0.16*s, 0.09*s) L(cx, cy+0.13*s, cx, cy+0.72*s) L(cx-0.28*s, cy+0.72*s, cx+0.28*s, cy+0.72*s) CF(cx-0.45*s, cy-0.55*s, 0.06*s) CF(cx+0.05*s, cy-0.72*s, 0.06*s) CF(cx+0.5*s, cy-0.5*s, 0.06*s)
  elseif cat == 34 then L(cx-0.85*s, cy-0.42*s, cx-0.55*s, cy-0.05*s) L(cx-0.55*s, cy-0.05*s, cx, cy+0.12*s) L(cx, cy+0.12*s, cx+0.55*s, cy-0.05*s) L(cx+0.55*s, cy-0.05*s, cx+0.85*s, cy-0.42*s) CF(cx, cy-0.02*s, 0.09*s) L(cx, cy+0.12*s, cx, cy+0.72*s) L(cx-0.28*s, cy+0.72*s, cx+0.28*s, cy+0.72*s)
  elseif cat == 35 then ELL(cx, cy+0.3*s, 0.8*s, 0.28*s, 0, 2*pi) L(cx-0.9*s, cy-0.55*s, cx+0.6*s, cy+0.3*s) CF(cx+0.66*s, cy+0.33*s, 0.07*s) L(cx-0.9*s, cy-0.55*s, cx-0.78*s, cy-0.66*s)
  elseif cat == 36 then L(cx-0.55*s, cy+0.5*s, cx, cy-0.55*s) L(cx, cy-0.55*s, cx+0.55*s, cy+0.5*s) L(cx-0.55*s, cy+0.5*s, cx+0.28*s, cy+0.5*s) L(cx+0.16*s, cy-0.08*s, cx+0.7*s, cy-0.24*s)
  elseif cat == 37 then R(cx-0.75*s, cy-0.3*s, 1.5*s, 0.75*s) L(cx-0.55*s, cy-0.05*s, cx+0.55*s, cy-0.05*s) L(cx+0.3*s, cy-0.45*s, cx+0.75*s, cy-0.9*s) CF(cx+0.28*s, cy-0.42*s, 0.1*s)
  elseif cat == 38 then ELL(cx, cy-0.55*s, 0.5*s, 0.15*s, 0, 2*pi) L(cx-0.5*s, cy-0.55*s, cx-0.5*s, cy+0.15*s) L(cx+0.5*s, cy-0.55*s, cx+0.5*s, cy+0.15*s) ELL(cx, cy+0.15*s, 0.5*s, 0.15*s, 0, pi) L(cx-0.45*s, cy-0.45*s, cx+0.45*s, cy+0.1*s) L(cx+0.45*s, cy-0.45*s, cx-0.45*s, cy+0.1*s) L(cx, cy+0.3*s, cx, cy+0.9*s)
  elseif cat == 39 then ELL(cx-0.05*s, cy+0.05*s, 0.8*s, 0.38*s, 0, 2*pi) L(cx-0.5*s, cy-0.25*s, cx-0.5*s, cy+0.35*s) L(cx-0.25*s, cy-0.3*s, cx-0.25*s, cy+0.4*s) L(cx, cy-0.32*s, cx, cy+0.42*s) L(cx+0.25*s, cy-0.3*s, cx+0.25*s, cy+0.4*s) L(cx+0.45*s, cy-0.4*s, cx+0.9*s, cy-0.85*s)
  elseif cat == 40 then ELL(cx, cy-0.35*s, 0.8*s, 0.22*s, 0, 2*pi) L(cx-0.8*s, cy-0.35*s, cx-0.8*s, cy+0.1*s) L(cx+0.8*s, cy-0.35*s, cx+0.8*s, cy+0.1*s) ELL(cx, cy+0.1*s, 0.8*s, 0.22*s, 0, pi) L(cx, cy+0.32*s, cx, cy+0.9*s) L(cx-0.3*s, cy+0.9*s, cx+0.3*s, cy+0.9*s)
  elseif cat == 41 then L(cx-0.75*s, cy-0.35*s, cx-0.35*s, cy+0.55*s) L(cx+0.05*s, cy-0.35*s, cx-0.35*s, cy+0.55*s) L(cx-0.75*s, cy-0.35*s, cx+0.05*s, cy-0.35*s) L(cx+0.15*s, cy-0.2*s, cx+0.5*s, cy+0.75*s) L(cx+0.85*s, cy-0.2*s, cx+0.5*s, cy+0.75*s) L(cx+0.15*s, cy-0.2*s, cx+0.85*s, cy-0.2*s) L(cx-0.35*s, cy-0.35*s, cx+0.05*s, cy-0.75*s) L(cx+0.05*s, cy-0.75*s, cx+0.5*s, cy-0.2*s)
  elseif cat == 42 then ELL(cx, cy-0.6*s, 0.65*s, 0.2*s, 0, 2*pi) L(cx-0.65*s, cy-0.6*s, cx-0.2*s, cy+0.15*s) L(cx+0.65*s, cy-0.6*s, cx+0.2*s, cy+0.15*s) L(cx-0.2*s, cy+0.15*s, cx-0.5*s, cy+0.85*s) L(cx+0.2*s, cy+0.15*s, cx+0.5*s, cy+0.85*s) ELL(cx, cy+0.85*s, 0.5*s, 0.14*s, 0, pi)
  elseif cat == 43 then R(cx-0.6*s, cy-0.85*s, 1.2*s, 1.7*s) C(cx, cy-0.4*s, 0.22*s) L(cx-0.6*s, cy-0.62*s, cx+0.6*s, cy-0.62*s)
  elseif cat == 44 then C(cx-0.62*s, cy+0.62*s, 0.2*s) L(cx-0.48*s, cy+0.48*s, cx+0.35*s, cy-0.35*s) L(cx+0.35*s, cy-0.35*s, cx+0.85*s, cy-0.1*s) L(cx+0.35*s, cy-0.35*s, cx+0.6*s, cy-0.85*s) L(cx+0.6*s, cy-0.85*s, cx+0.85*s, cy-0.1*s)
  elseif cat == 45 then C(cx-0.2*s, cy+0.2*s, 0.5*s) L(cx+0.1*s, cy-0.2*s, cx+0.85*s, cy-0.2*s) L(cx+0.15*s, cy+0.05*s, cx+0.85*s, cy+0.05*s) L(cx+0.85*s, cy-0.2*s, cx+0.85*s, cy+0.05*s) CF(cx-0.2*s, cy+0.2*s, 0.1*s)
  else -- 31 other
    L(cx-0.6*s, cy-0.3*s, cx-0.6*s, cy+0.3*s) L(cx-0.3*s, cy-0.6*s, cx-0.3*s, cy+0.6*s) L(cx, cy-0.42*s, cx, cy+0.42*s) L(cx+0.3*s, cy-0.68*s, cx+0.3*s, cy+0.68*s) L(cx+0.6*s, cy-0.25*s, cx+0.6*s, cy+0.25*s)
  end
end

-- public entry. col = 0xRRGGBBAA packed, th = stroke thickness (default 1).
function M.draw(dl, cat, cx, cy, s, col, th)
  _dl, _col, _th = dl, col or 0xFFFFFFFF, th or 1
  if s < 11 then sm(cat, cx, cy, s) else lg(cat, cx, cy, s) end
end

return M
