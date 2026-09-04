-- rk_lua_theme.lua — EON unified theme: semantic palette + REAPER-theme
-- derivation. ONE source of truth for the whole suite (Browser, Pad FX = Lua;
-- Swing, Step Seq = JSFX via the gmem theme band).
-- (c) EON Studios.
--
-- The "REAPER" (match-DAW-theme) derivation is ported from TouristKiller's
-- TK Workbench (`TK Workbench/core/theme.lua`, MIT-style) — thanks/attribution
-- to TouristKiller. The per-slot ini-key priority lists + WCAG contrast guards
-- are his design.
--
-- Semantic palette keys (what every consumer maps from):
--   bg        window / housing background
--   panel     recessed panel / LCD / cell background
--   text      primary text
--   text_dim  secondary / dim text
--   accent    selection / active / primary accent
--   accent2   secondary accent / hover / hilite
--   grid      gridlines / dividers
--   border    frame border / outline
-- Colors are packed 0xRRGGBBAA ints (ImGui convention).

local r = reaper
local T = {}

local function pack(rr, gg, bb, aa) return (rr << 24) | (gg << 16) | (bb << 8) | (aa or 255) end
local function split(c) return (c >> 24) & 255, (c >> 16) & 255, (c >> 8) & 255, c & 255 end
local function clamp(v, a, b) return v < a and a or (v > b and b or v) end
T.pack, T.split = pack, split

-- Channel lerp a→b by t (0..1). Alpha forced opaque (theme surfaces are solid).
local function blend(a, b, t)
  local ar, ag, ab = split(a); local br, bg, bb = split(b)
  return pack(math.floor(ar + (br - ar) * t + 0.5),
              math.floor(ag + (bg - ag) * t + 0.5),
              math.floor(ab + (bb - ab) * t + 0.5), 255)
end

-- ── REAPER theme derivation (TK Workbench port) ───────────────────────────
local function theme_color(name, fallback)
  if not r.GetThemeColor or not r.ColorFromNative then return fallback end
  local ok, native = pcall(r.GetThemeColor, name, 0)
  if not ok or native == nil or native < 0 then return fallback end
  local ok2, rr, gg, bb = pcall(r.ColorFromNative, native)
  if not ok2 then return fallback end
  return pack(rr or 0, gg or 0, bb or 0, 255)
end

local function luminance(c) local rr, gg, bb = split(c); return (0.2126 * rr + 0.7152 * gg + 0.0722 * bb) / 255 end
local function channel_luminance(v)
  v = clamp(v / 255, 0, 1)
  if v <= 0.03928 then return v / 12.92 end
  return ((v + 0.055) / 1.055) ^ 2.4
end
local function contrast_luminance(c)
  local rr, gg, bb = split(c)
  return 0.2126 * channel_luminance(rr) + 0.7152 * channel_luminance(gg) + 0.0722 * channel_luminance(bb)
end
local function contrast_ratio(a, b)
  local la, lb = contrast_luminance(a), contrast_luminance(b)
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end
local function min_contrast(c, bgs)
  local v
  for _, b in ipairs(bgs) do local rr = contrast_ratio(c, b); v = v and math.min(v, rr) or rr end
  return v or 0
end
local function readable_text(bg) return luminance(bg) > 0.5 and 0x20242AFF or 0xF2F4F7FF end
local function best_text(bgs)
  local d, l = 0x20242AFF, 0xF2F4F7FF
  return min_contrast(d, bgs) >= min_contrast(l, bgs) and d or l
end
local function ensure_readable(c, bgs, fb, minr)
  minr = minr or 4.5
  if c and min_contrast(c, bgs) >= minr then return c end
  if fb and min_contrast(fb, bgs) >= minr then return fb end
  return best_text(bgs)
end
local function color_distance(a, b)
  local ar, ag, ab = split(a); local br, bg, bb = split(b)
  return (math.abs(ar - br) + math.abs(ag - bg) + math.abs(ab - bb)) / 765
end
local function color_chroma(c)
  local rr, gg, bb = split(c)
  return (math.max(rr, gg, bb) - math.min(rr, gg, bb)) / 255
end
local function has_visual_weight(c, bg, mind, minc)
  if not c then return false end
  mind = mind or 0.16
  if color_distance(c, bg) < mind then return false end
  if color_chroma(c) < (minc or 0) and color_distance(c, bg) < 0.34 then return false end
  return true
end
local function first_theme_color(names, fb)
  for _, n in ipairs(names) do local c = theme_color(n, nil); if c then return c end end
  return fb
end
local function first_weighted(names, bg, fb, mind, minc)
  for _, n in ipairs(names) do
    local c = theme_color(n, nil)
    if has_visual_weight(c, bg, mind, minc) then return c end
  end
  return (has_visual_weight(fb, bg, mind, 0) and fb) or readable_text(bg)
end
-- TK Workbench readable_theme_text: take the first theme text key, but if its
-- luminance sits within 0.38 of the background's, it'd read mushy → swap for the
-- guaranteed-readable ink instead. (Verbatim from TK make_reaper_colors.)
local function readable_theme_text(names, bg, fb)
  local c = first_theme_color(names, fb)
  if math.abs(luminance(c) - luminance(bg)) < 0.38 then return readable_text(bg) end
  return c
end
-- TK Workbench keep_apart: reject a colour that's too close to `other` (or lacks
-- visual weight vs the bg) and substitute the fallback. Used to keep warning vs
-- accent vs danger visually distinct. (Verbatim from TK make_reaper_colors.)
local function keep_apart(c, bg, other, fb)
  if color_distance(c, other) < 0.12 then return fb end
  if not has_visual_weight(c, bg, 0.14, 0.04) then return fb end
  return c
end

-- TK Workbench "Graphite" preset — the per-slot fallback source when the active
-- REAPER theme is missing an ini key. Verbatim values so a key-less slot lands on
-- exactly the colour TK would use.
local GRAPHITE = {
  window_bg = 0x111111FF, child_bg = 0x181818FF, popup_bg = 0x1B1B1BFF, frame_bg = 0x242424FF,
  frame_hover = 0x333333FF, header = 0x2C2C2CFF, header_hover = 0x383838FF, separator = 0x3A3A3AFF,
  border = 0x444444FF, text = 0xF0F0F0FF, text_dim = 0xA0A0A0FF, badge_text = 0x000000DD,
  accent = 0xD8DEE9FF, accent_soft = 0x4C566AFF, warning = 0xEBCB8BFF, danger = 0xBF616AFF,
}

-- Per-slot ini-key priority lists. Mode-aware, ported from TK Workbench
-- `make_reaper_colors(mode)` — three modes (balanced / panel / color) differ in
-- which surface + accent keys are pulled first (panel = docker/list chrome;
-- color = vivid marker/region/VU accent). Keys that vary by mode are tables of
-- { balanced, panel } (color reuses balanced surfaces); shared keys are flat.
local KEYS = {
  window_bg = {
    balanced = { "col_main_bg", "col_main_bg2", "docker_bg", "col_arrangebg" },
    panel    = { "col_main_bg", "docker_bg", "genlist_bg", "col_main_bg2", "col_arrangebg" },
  },
  panel_bg = {
    balanced = { "col_main_bg2", "docker_bg", "col_tracklistbg", "genlist_bg", "col_tr1_bg" },
    panel    = { "docker_bg", "genlist_bg", "col_main_bg2", "col_tracklistbg", "col_tr1_bg" },
  },
  popup_bg = {
    balanced = { "docker_bg", "windowtab_bg", "col_main_bg2", "genlist_bg" },
    panel    = { "windowtab_bg", "docker_bg", "genlist_bg", "col_main_bg2" },
  },
  frame_bg = {
    balanced = { "col_main_editbk", "col_transport_editbk", "genlist_bg", "col_buttonbg" },
    panel    = { "genlist_bg", "col_main_editbk", "col_transport_editbk", "col_buttonbg" },
  },
  text      = { "col_main_text", "genlist_fg", "col_tcp_text", "col_mixer_text" },
  text_dim  = { "col_main_text2", "genlist_seliafg", "col_tl_fg2", "col_toolbar_text" },
  highlight = { "col_main_3dhl", "tcp_list_scrollbar_mouseover", "mcp_list_scrollbar_mouseover" },
  shadow    = { "col_main_3dsh", "genlist_grid", "col_gridlines" },
  accent = {
    balanced = { "genlist_selbg", "docker_selface", "col_seltrack", "selcol_tr1_bg", "selcol_tr2_bg",
                 "col_transport_editbk", "marker", "region", "col_routingact", "col_vumid" },
    panel    = { "docker_selface", "genlist_selbg", "col_transport_editbk", "col_main_3dhl",
                 "col_seltrack", "marker", "region" },
    color    = { "marker", "region", "col_routingact", "col_vumid", "col_vuhot",
                 "genlist_selbg", "docker_selface", "col_seltrack", "selcol_tr1_bg", "selcol_tr2_bg" },
  },
  warning = {
    balanced = { "col_tl_bgsel", "col_tl_bgsel2", "playrate_edited", "marker", "region" },
    color    = { "region", "marker", "playrate_edited", "col_tl_bgsel", "col_tl_bgsel2" },
  },
  danger = { "col_vuclip", "midi_noteon_flash", "midi_notemute_sel", "mute_overlay_col", "midi_selbg" },
}

-- Derive a semantic palette from the active REAPER theme for the given mode
-- ("balanced" | "panel" | "color"). Full re-port of TK Workbench's
-- make_reaper_colors mapped onto our 8 semantic slots. text/text_dim keep the
-- WCAG readability guards; surfaces/accent are the theme's own colours. Snapshot
-- (caller decides when to re-derive — REAPER fires no theme-changed event).
function T.make_reaper(mode)
  -- 1:1 VERBATIM port of TK Workbench make_reaper_colors(mode). Every line below
  -- mirrors the original (key lists, blend weights, contrast guards, Graphite
  -- fallbacks). We compute the FULL 16-role TK table, then alias our 8 published
  -- slots from it (bg/panel/text/text_dim/accent/accent2/grid/border) — the extra
  -- TK roles (warning/danger/badge_text/hover/header surfaces) ride along on the
  -- returned table for any consumer that wants them. So for every role TK emits,
  -- ours is byte-identical.
  local fb = GRAPHITE
  mode = mode or "balanced"
  local panel_m = mode == "panel"
  local color_m = mode == "color"
  local window_bg = first_theme_color(panel_m and KEYS.window_bg.panel or KEYS.window_bg.balanced, fb.window_bg)
  local child_bg  = first_theme_color(panel_m and KEYS.panel_bg.panel  or KEYS.panel_bg.balanced,  fb.child_bg)
  local popup_bg  = first_theme_color(panel_m and KEYS.popup_bg.panel  or KEYS.popup_bg.balanced,  blend(child_bg, window_bg, 0.22))
  local frame_bg  = first_theme_color(panel_m and KEYS.frame_bg.panel  or KEYS.frame_bg.balanced,  blend(child_bg, readable_text(child_bg), 0.08))
  local text      = readable_theme_text(KEYS.text, window_bg, readable_text(window_bg))
  local text_dim  = first_theme_color(KEYS.text_dim, blend(text, window_bg, 0.42))
  local dark      = luminance(window_bg) < 0.5
  local highlight = first_theme_color(KEYS.highlight, text)
  local shadow    = first_theme_color(KEYS.shadow, fb.separator)
  local selection_keys = panel_m and KEYS.accent.panel or (color_m and KEYS.accent.color or KEYS.accent.balanced)
  local selection = first_weighted(selection_keys, window_bg, fb.accent, color_m and 0.18 or 0.13, color_m and 0.08 or 0.04)
  local frame_hover  = blend(frame_bg, highlight, dark and 0.18 or 0.12)
  local header       = blend(frame_bg, selection, panel_m and 0.14 or (color_m and 0.36 or (dark and 0.28 or 0.2)))
  local header_hover = blend(frame_hover, selection, panel_m and 0.2 or (color_m and 0.44 or (dark and 0.34 or 0.26)))
  local accent = selection
  local warning = first_weighted(color_m and KEYS.warning.color or KEYS.warning.balanced, window_bg, fb.warning, 0.14, 0.05)
  local danger  = first_weighted(KEYS.danger, window_bg, fb.danger, 0.16, 0.06)
  warning = keep_apart(warning, window_bg, accent, fb.warning)
  danger  = keep_apart(danger, window_bg, accent, fb.danger)
  danger  = keep_apart(danger, window_bg, warning, fb.danger)
  local text_backgrounds = { window_bg, child_bg, popup_bg, frame_bg, frame_hover, header, header_hover }
  text     = ensure_readable(text, text_backgrounds, readable_text(window_bg), 4.5)
  text_dim = ensure_readable(text_dim, { window_bg, child_bg, popup_bg, frame_bg }, blend(text, window_bg, dark and 0.28 or 0.42), 3.0)
  local separator   = shadow
  local border      = blend(highlight, shadow, 0.5)
  local badge_text  = ensure_readable(luminance(accent) > 0.55 and 0x000000DD or 0xFFFFFFFF, { accent }, nil, 4.5)
  local accent_soft = blend(accent, window_bg, panel_m and 0.82 or (color_m and 0.56 or (dark and 0.64 or 0.76)))
  return {
    -- our 8 published slots (read by T.to_band / consumers)
    bg = window_bg, panel = child_bg, text = text, text_dim = text_dim,
    accent = accent, accent2 = accent_soft, grid = separator, border = border,
    -- full TK role set (1:1) for any consumer that wants the rest
    window_bg = window_bg, child_bg = child_bg, popup_bg = popup_bg, frame_bg = frame_bg,
    frame_hover = frame_hover, header = header, header_hover = header_hover, separator = separator,
    badge_text = badge_text, accent_soft = accent_soft, warning = warning, danger = danger,
  }
end

-- Fixed semantic palettes (tuned to match rk_lua_widgets.push_theme look).
-- ⚠ These eleven are hand-tuned and are NOT put through clamp_for_swing — only the
-- three derived reaper* palettes are. They were, however, tuned by eye in SWING,
-- where `panel` is just the pad tray and a whisper of recess looks right. The
-- ReaImGui side spends the SAME value on every button, input field, popup and
-- table header, and `grid` on the scrollbar thumb — so several of them had
-- controls in the browser you could not actually see (FL's thumb sat 0.008 from
-- the panel it slides on; SSL's buttons had neither a distinct fill nor a visible
-- edge; EON, Light and Ableton put disabled text under 3:1).
--
-- Corrected 2026-08-30, lightness only, nothing that touches a theme's character:
-- a button must stand 0.06 off its window OR carry a 0.08 border, the scrollbar
-- thumb must stand 0.08 off the panel, and secondary text must clear 3:1 on both.
-- `dark` and `protools_light` already passed and are untouched.
-- ⛔ Do not "tidy" these back toward their neighbours — .dev_tests/theme_contrast_gate.py
-- checks them and will fail. Run it after any edit here.
T.FIXED = {
  eon   = { bg = 0xD6CFC2FF, panel = 0xC2BDB3FF, text = 0x2B2822FF, text_dim = 0x4F4B43FF,
            accent = 0xFF8C32FF, accent2 = 0x4D4D52FF, grid = 0x938A78FF, border = 0x938A78FF },
  dark  = { bg = 0x1E1E22FF, panel = 0x2A2A30FF, text = 0xDDDDE0FF, text_dim = 0x91919AFF,
            accent = 0xFF8C32FF, accent2 = 0x4A4A55FF, grid = 0x414148FF, border = 0x414148FF },
  light = { bg = 0xF0F0F2FF, panel = 0xE0E0E5FF, text = 0x222228FF, text_dim = 0x626268FF,
            accent = 0xFF8C32FF, accent2 = 0xC0C0CCFF, grid = 0xC0C0C8FF, border = 0xC0C0C8FF },
  -- ── EON console themes (palette here; knob style + per-role hues below) ──
  -- SSL: classic console-fader grey body, signature green accent
  ssl   = { bg = 0x44484CFF, panel = 0x575B5DFF, text = 0xE6E8E4FF, text_dim = 0xD0D3CFFF,
            accent = 0x2FB463FF, accent2 = 0xB0B6BEFF, grid = 0x6F7374FF, border = 0x6F7374FF },
  -- Neve: lighter blue-grey body (was too dark) + Neve red. The blue-grey is well
  -- founded — AMS Neve's own modules are described as "RAF blue-grey".
  neve  = { bg = 0x38414EFF, panel = 0x4A5463FF, text = 0xEDE7D8FF, text_dim = 0xC1C8D1FF,
            accent = 0xD8413AFF, accent2 = 0x6E8CB8FF, grid = 0x606977FF, border = 0x606977FF },
  -- makeover: indigo + chrome (off the SSL green; chrome suits the API look).
  -- ⚠ NOT authentic to a real API console, and has never claimed to be.
  api   = { bg = 0x1E1F22FF, panel = 0x2A2C30FF, text = 0xF0F2F5FF, text_dim = 0x91949CFF,
            accent = 0x3E5BC0FF, accent2 = 0xC8CDD2FF, grid = 0x414349FF, border = 0x3E4248FF },
  tube  = { bg = 0x211A14FF, panel = 0x2C2218FF, text = 0xF0E4D0FF, text_dim = 0x9C8A70FF,
            accent = 0xF0A83CFF, accent2 = 0xC2663AFF, grid = 0x44382BFF, border = 0x4A3A28FF },
  -- ── EON DAW themes (matched to the real DAW UIs) ──
  -- Ableton: Live light grey + salmon-orange selection accent. ⚠ The salmon is
  -- UNVERIFIED — Live's stock theme is not published and we have no install to sample.
  ableton  = { bg = 0xC8C8C8FF, panel = 0xBABABAFF, text = 0x2A2A2AFF, text_dim = 0x4A4A4AFF,
               accent = 0xFF764DFF, accent2 = 0x8A8E94FF, grid = 0xA5A5A5FF, border = 0x9E9E9EFF },
  -- ⚠ Diverges from the published FL palette (gold #FDB200, emerald #1EC173, near-black
  -- ground): ours is a redder orange, a yellower green, and a much lighter body. Open
  -- question, deliberately NOT changed here — moving it is a character decision.
  fl       = { bg = 0x262626FF, panel = 0x3A3A3AFF, text = 0xD8D8D8FF, text_dim = 0xA5A5A5FF,
               accent = 0xF89B30FF, accent2 = 0x6FBF4FFF, grid = 0x535353FF, border = 0x515151FF },
  -- Pro Tools: greyer graphite body (lifted off near-black) + edit-blue accent.
  -- ⚠ Both Pro Tools recreations on the dev machine use a LIGHT window over a dark
  -- panel, i.e. closer to protools_light below than to this. Open question.
  protools = { bg = 0x36393CFF, panel = 0x474B4FFF, text = 0xE2E6EAFF, text_dim = 0xB8BBC0FF,
               accent = 0x46A6D8FF, accent2 = 0x5A636EFF, grid = 0x5D6166FF, border = 0x5D6166FF },
  -- PT Light: Pro-Tools mid-grey chrome + white graph panel + dark legible text
  -- (distinct from `light` which is near-white). bg=window grey, panel=white EQ
  -- graph fill, grid/border stay grey (JSFX passes fixed alphas — band is RGB only).
  --
  -- ⚠ Its ink runs DARKER than the other light themes on purpose. Their windows are
  -- near-white (light 0xF0F0F2, ableton 0xC8C8C8) so a 0x22-0x2B ink is comfortable
  -- there; this one's window is a mid-grey 0xB0B3B5, which squeezes everything drawn
  -- on it. At the old 0x303236 / 0x5C5E62 the body ink managed 6.09:1 on that window
  -- and the secondary ink only 3.08:1 — over the 3.0 floor on paper, thin to actually
  -- read (user, 2026-08-30) — and 2.80:1 on the orange accent, which was under.
  -- Now 7.92:1 and 4.99:1. ⛔ Do not "align" these with the other light themes.
  protools_light = { bg = 0xB0B3B5FF, panel = 0xFAFAFAFF, text = 0x1C1E21FF, text_dim = 0x3E3F42FF,
                     accent = 0xFF8C32FF, accent2 = 0xA8AEB6FF, grid = 0xBFC2C6FF, border = 0xAEB2B6FF },
}

-- ── Per-theme knob identity (EON console themes) ──────────────────────────
-- Knob STYLE indices (match knobs_kbsg.jsfx-inc rk_knob_draw dispatch):
--   1 ssl · 2 varimu · 3 api · 4 ws · 5 neve · 6 jo · 7 mpc · 8 jog · 10 sp
--   · 11 encoder · 12 pultec · 13 ableton · 14 fl · 15 protools · 16 fabfilter
--   · 17 serum · 18 roland · 19 pultec_cream · 20 neve_alt.
--   Each theme = { primary, secondary }. IDs persist in ExtState — append only.
T.KNOBS = {
  eon = {1,1}, dark = {1,1}, light = {1,1},
  reaper = {1,1}, reaper_panel = {1,1}, reaper_color = {1,1},
  ssl = {1,1}, neve = {2,2}, api = {3,3}, tube = {12,12},
  ableton = {13,13}, fl = {14,14}, protools = {15,15}, protools_light = {1,1},
}

-- Per-theme KNOB ROLE hue table — 6 roles, fixed order:
--   1 drive/input · 2 gain/output · 3 freq · 4 shape/Q · 5 dynamics · 6 time/mix
-- A knob resolves its colour from the active theme's row by role; with no role
-- (or bridge idle) it falls back to its own hardcoded hue in the plugin.
T.NROLE = 6
local _roles_eon = { 0xFF8C32FF, 0xC8CED6FF, 0x4FA3D8FF, 0x8E7BD6FF, 0xE0606BFF, 0x4FC08AFF }
T.ROLES = {
  eon = _roles_eon, dark = _roles_eon, light = _roles_eon,
  reaper = _roles_eon, reaper_panel = _roles_eon, reaper_color = _roles_eon,
  ssl   = { 0xB0B6BEFF, 0xC8CED6FF, 0x2FB463FF, 0x3E7DC4FF, 0xD6463CFF, 0xE0A33CFF },
  neve  = { 0xC24A42FF, 0xD8413AFF, 0x5A7AAEFF, 0x6E86A8FF, 0xB0563EFF, 0xC9A24AFF },
  api   = { 0x3E5BC0FF, 0xC8CDD2FF, 0x4FB477FF, 0x4F8FD8FF, 0xD6553CFF, 0xE0C24FFF },
  tube  = { 0xF0A83CFF, 0xD8C49AFF, 0xE08A4AFF, 0xC2663AFF, 0xC24A3AFF, 0xB89A4AFF },
  ableton  = { 0xFF764DFF, 0x6A6E74FF, 0x3E8FD8FF, 0x8C7BC0FF, 0xC85A4AFF, 0x4FA080FF },
  fl       = { 0xF89B30FF, 0xD8CFC2FF, 0x5FB0E0FF, 0xC89BE0FF, 0xF26B5EFF, 0x6FBF4FFF },
  protools = { 0x46A6D8FF, 0xC2C8D0FF, 0x5FB0A0FF, 0x7E9AD8FF, 0xD86A5EFF, 0xD0A84FFF },
  protools_light = _roles_eon,
}

-- name → {primary, secondary} knob style indices (default ssl/ssl).
function T.knob_styles(name)
  return T.KNOBS[name] or T.KNOBS.eon
end

-- name → array of T.NROLE {r,g,b} (0..1) role hues, for core.publish_theme_knobs.
function T.role_band(name)
  local rows = T.ROLES[name] or T.ROLES.eon
  local b = {}
  for i = 1, T.NROLE do
    local rr, gg, bb = split(rows[i] or 0)
    b[i] = { rr / 255, gg / 255, bb / 255 }
  end
  return b
end

-- ── EON survivability clamp (NOT part of the TK port) ─────────────────────
-- TK's derivation is safe in TK's app because his UI never trusts the palette:
-- every label asks `text_for_background()` at draw time what ink clears 4.5:1
-- on the shade actually under it (~84 call sites across 20 files). ImGui gives
-- him the rest for free — one push of 14 style colours and every widget
-- inherits.
--
-- Swing has neither. It is JSFX: no style stack, nothing inherits, and ~2100
-- of its colours are literals baked for the cream iMPC housing. Only BG /
-- PANEL / ACCENT / ACCENT2 are themed at all. So a palette derived from an
-- arbitrary REAPER theme can land somewhere none of those literals survive —
-- which is the "everything goes dark, can't read it" report.
--
-- This pass runs ONLY on the three derived reaper* palettes. The 11 fixed
-- palettes are hand-tuned and ship untouched. It is deliberately kept OUT of
-- make_reaper(), so that function stays a byte-identical port and can still be
-- diffed against TK upstream (verified identical at TK v0.9.3, 2026-08-29).
--
-- It moves LIGHTNESS only, never hue, so the DAW's colour identity survives.
-- Escape hatch for A/B: ExtState Swing/eon_theme_clamp = "0".
local INK_DARK, INK_LIGHT = 0x20242AFF, 0xF2F4F7FF   -- TK's two guaranteed inks

-- Separation thresholds, in color_distance units (sum of |channel deltas| / 765).
-- For a grey pair that is exactly delta/255, so 0.08 == 20 grey levels.
--
-- Tuned against the 12 themes installed here. Set too high and the clamp starts
-- "fixing" surfaces that were already distinct: at 0.10, CLogic's tray (19 levels
-- off its body, plainly visible, text on it at 11.8:1) got dragged 52 levels away
-- and lost half its contrast for nothing. 0.08 still catches the genuinely flat
-- pairs -- Default 5 Dark ships a body and tray 7 levels apart, and every theme
-- whose col_main_bg2 simply repeats col_main_bg.
local SEP_PANEL = 0.08   -- tray vs body: a large area, needs only to read as recessed
local SEP_LINE  = 0.08   -- gridlines and borders: thin, so no lower than the above
local SEP_ACC   = 0.12   -- accent vs body: must read as a deliberate mark, not a shade

-- Can ANY ink clear `ratio` on this surface? A mid-luminance surface fails
-- against BOTH near-black and near-white — that is the band on which nothing
-- can legibly be drawn, and the band a baked literal cannot escape.
local function ink_survives(c, ratio)
  return math.max(contrast_ratio(c, INK_DARK), contrast_ratio(c, INK_LIGHT)) >= ratio
end

-- Walk a colour toward whichever pole it already leans to until an ink clears
-- `ratio`. 20 steps of 5% is finer than the eye resolves, so the result still
-- reads as the theme's own colour.
local function escape_midband(c, ratio)
  if ink_survives(c, ratio) then return c end
  local target = luminance(c) >= 0.5 and 0xFFFFFFFF or 0x000000FF
  for i = 1, 20 do
    local out = blend(c, target, i * 0.05)
    if ink_survives(out, ratio) then return out end
  end
  return target
end

-- Pull `c` onto the same side of the light/dark divide as `base`, so that ONE
-- ink is legible on both — without letting them get closer than `mind`.
--
-- This exists because the Lua consumer cannot do what Swing does. Swing resolves
-- ink per surface at draw time (rk_auto_ink), so its BG and PANEL are free to sit
-- on opposite sides. The Browser and Pad FX are ReaImGui: w._apply_semantic
-- pushes ONE Col_Text and ImGui paints it on the window, the popups, the frames,
-- the buttons and the table rows alike. A theme like Pro Tools 2020 (light window
-- 164,164,164 over a dark docker 51,51,51) leaves no single ink that clears 4.5:1
-- on both, so whichever way the guard resolves, half the Browser goes unreadable.
--
-- Walking the panel to BG's side costs a little DAW fidelity in that one case and
-- buys a window you can actually read. It is a no-op for every theme whose
-- surfaces already share a side, which is most of them.
local function share_ink(c, base, mind)
  local ink = readable_text(base)
  if contrast_ratio(ink, c) >= 4.5 then return c end
  local target = luminance(base) > 0.5 and 0xFFFFFFFF or 0x000000FF
  for i = 1, 20 do
    local out = blend(c, target, i * 0.05)
    if contrast_ratio(ink, out) >= 4.5 and color_distance(out, base) >= mind then return out end
  end
  return c   -- no point satisfies both; keep separation and let the guard compromise
end

-- Push `c` away from `from` until they differ by at least `mind`, moving to
-- whichever pole `from` is NOT near (so a dark surface gets a lighter panel).
local function separate(c, from, mind)
  if color_distance(c, from) >= mind then return c end
  local target = luminance(from) < 0.5 and 0xFFFFFFFF or 0x000000FF
  for i = 1, 20 do
    local out = blend(c, target, i * 0.05)
    if color_distance(out, from) >= mind then return out end
  end
  return target
end

function T.clamp_for_swing(pal)
  if reaper and reaper.GetExtState
     and reaper.GetExtState("Swing", "eon_theme_clamp") == "0" then return pal end

  -- 1. BG off the extremes. Swing's bezels and recesses are drawn as black and
  --    white ALPHA washes over the body; on pure black or pure white one side
  --    of every bevel disappears and the housing reads as a flat slab.
  local bg = pal.bg
  if luminance(bg) < 0.05 then bg = blend(bg, 0xFFFFFFFF, 0.10) end
  if luminance(bg) > 0.95 then bg = blend(bg, 0x000000FF, 0.10) end
  -- 2. BG out of the dead mid-band. Swing draws BOTH near-white and near-black
  --    literals on the body; a mid-grey body loses whichever it is nearer, and
  --    at the centre it loses both.
  bg = escape_midband(bg, 4.5)

  -- 3. PANEL stands off BG, and is itself drawable. Many REAPER themes give
  --    col_main_bg and col_main_bg2 the same or near-same value, which
  --    collapses Swing's tray into its body — the "everything goes flat" half
  --    of the report. Then onto BG's side of the light/dark divide, so a single
  --    ink serves both — see share_ink for why that is not optional. The final
  --    escape_midband is a no-op whenever share_ink succeeded (a colour that
  --    clears 4.5:1 against one ink clears it against the better of the two).
  local panel = separate(pal.panel, bg, SEP_PANEL)
  panel = escape_midband(share_ink(panel, bg, SEP_PANEL), 4.5)

  -- 4. Structure lines stand off the surface they are drawn on, or the panel
  --    edges and gridlines vanish into it.
  local grid   = separate(pal.grid,   panel, SEP_LINE)
  local border = separate(pal.border, panel, SEP_LINE)

  -- 5. ACCENT must be able to carry a label (Swing prints on top of it) and
  --    must still read as a distinct element against the moved BG.
  local accent = separate(escape_midband(pal.accent, 4.5), bg, SEP_ACC)
  -- 6. ACCENT2 becomes Swing's header strip; it needs to read as its own band.
  --    Its captions self-resolve via rk_auto_ink_dim, so only separation here.
  local accent2 = separate(pal.accent2, bg, SEP_PANEL)

  -- 7. Re-run the text guards against the surfaces as they NOW are — shipping a
  --    palette whose ink was proven against a BG no longer in it is how the
  --    guard becomes decoration.
  --
  --    Proven against BG **and** PANEL together. ensure_readable takes the
  --    MINIMUM contrast across the list, so this is only a promise worth making
  --    because step 3 already walked PANEL onto BG's side of the divide — ask
  --    for both across a straddling pair and you get a compromise that fails on
  --    each. The pair is the two surfaces ReaImGui paints its one Col_Text on;
  --    Swing's remaining surfaces (header strip, pads, LCDs) resolve their own
  --    ink at draw time via rk_auto_ink, the same answer TK reaches with
  --    text_for_background().
  local dark = luminance(bg) < 0.5
  local text = ensure_readable(pal.text, { bg, panel }, readable_text(bg), 4.5)
  local text_dim = ensure_readable(pal.text_dim, { bg, panel },
                                   blend(text, bg, dark and 0.28 or 0.42), 3.0)

  pal.bg, pal.panel, pal.grid, pal.border = bg, panel, grid, border
  pal.accent, pal.accent2, pal.text, pal.text_dim = accent, accent2, text, text_dim
  -- badge_text is the ink TK computes for drawing ON the accent. to_band drops
  -- it (the 8-slot band has no room), but keep it correct on the table for the
  -- Lua-side consumers that read the palette directly.
  pal.badge_text = ensure_readable(luminance(accent) > 0.55 and 0x000000DD or 0xFFFFFFFF,
                                   { accent }, nil, 4.5)
  return pal
end

-- Keep a colour's HUE and move only its lightness, until it clears `minr` on every
-- surface it will be drawn on. Returns it untouched when it already does.
--
-- This is the half of TK's text_for_background we could not use as-is. His falls
-- back to a guaranteed near-black or near-white ink, which is exactly right for
-- body text and exactly wrong for a colour that MEANS something — the browser's
-- folder gold, its error red, its stereo-file blue. Throwing the hue away there
-- throws the signal away with it. So this tries both directions and takes the
-- one that reaches the ratio with the SMALLER move, keeping as much of the
-- original colour as the contrast allows.
--
-- Only falls through to a flat ink when neither direction can get there at all.
function T.ink_on(c, surfaces, minr)
  minr = minr or 4.5
  if type(surfaces) ~= "table" then surfaces = { surfaces } end
  if #surfaces == 0 then return c end
  if min_contrast(c, surfaces) >= minr then return c end
  local best, best_ch, best_t
  for _, pole in ipairs({ 0x000000FF, 0xFFFFFFFF }) do
    for i = 1, 20 do
      local t = i * 0.05
      local out = blend(c, pole, t)
      if min_contrast(out, surfaces) >= minr then
        -- SATURATION first, distance second. On a MID-grey surface both directions
        -- reach the ratio, and picking purely by the smaller move takes the lighter
        -- one — which washes the colour out. SSL's category wheel lost 46% of its
        -- saturation that way and Neve 33%, and saturation is the entire point of
        -- those colours: it is what tells a ride from a clap at a glance.
        --
        -- ⚠ Must be HSV saturation (max-min)/max, NOT color_chroma (max-min)/255.
        -- Chroma falls by exactly (1-t) in BOTH directions, so comparing it here
        -- is a no-op — measured, after writing it that way first.
        local rr, gg, bb = split(out)
        local hi = math.max(rr, gg, bb)
        local sat = hi > 0 and (hi - math.min(rr, gg, bb)) / hi or 0
        if not best or sat > best_sat + 0.02
           or (math.abs(sat - best_sat) <= 0.02 and t < best_t) then
          best, best_sat, best_t = out, sat, t
        end
        break
      end
    end
  end
  return best or best_text(surfaces)
end

-- name → semantic palette (packed RGBA). The three REAPER entries map to the TK
-- derivation modes (matches TK Workbench's three separate preset entries):
--   reaper = balanced · reaper_panel = panel · reaper_color = color
-- Derived palettes go through the survivability clamp; fixed ones do not.
function T.resolve(name)
  if name == "reaper"       then return T.clamp_for_swing(T.make_reaper("balanced")) end
  if name == "reaper_panel" then return T.clamp_for_swing(T.make_reaper("panel")) end
  if name == "reaper_color" then return T.clamp_for_swing(T.make_reaper("color")) end
  return T.FIXED[name] or T.FIXED.eon
end

-- Semantic palette → array of 8 {r,g,b} (0..1) in core.GMEM THEME_* order,
-- for core.publish_theme_band (JSFX-native floats).
local ORDER = { "bg", "panel", "text", "text_dim", "accent", "accent2", "grid", "border" }
function T.to_band(pal)
  local b = {}
  for i, k in ipairs(ORDER) do
    local rr, gg, bb = split(pal[k] or 0)
    b[i] = { rr / 255, gg / 255, bb / 255 }
  end
  return b
end

return T
