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
T.FIXED = {
  eon   = { bg = 0xD6CFC2FF, panel = 0xC2BDB3FF, text = 0x2B2822FF, text_dim = 0x7E776AFF,
            accent = 0xFF8C32FF, accent2 = 0x4D4D52FF, grid = 0x938A78FF, border = 0x938A78FF },
  dark  = { bg = 0x1E1E22FF, panel = 0x2A2A30FF, text = 0xDDDDE0FF, text_dim = 0x8C8C96FF,
            accent = 0xFF8C32FF, accent2 = 0x4A4A55FF, grid = 0x414148FF, border = 0x414148FF },
  light = { bg = 0xF0F0F2FF, panel = 0xE0E0E5FF, text = 0x222228FF, text_dim = 0x888890FF,
            accent = 0xFF8C32FF, accent2 = 0xC0C0CCFF, grid = 0xC0C0C8FF, border = 0xC0C0C8FF },
  -- ── EON console themes (palette here; knob style + per-role hues below) ──
  -- SSL: classic console-fader grey body, signature green accent
  ssl   = { bg = 0x44484CFF, panel = 0x4E5254FF, text = 0xE6E8E4FF, text_dim = 0xBCC0BAFF,
            accent = 0x2FB463FF, accent2 = 0xB0B6BEFF, grid = 0x5A5F60FF, border = 0x5A5F60FF },
  -- Neve: lighter blue-grey body (was too dark) + Neve red
  neve  = { bg = 0x38414EFF, panel = 0x45505FFF, text = 0xEDE7D8FF, text_dim = 0xAEB6C2FF,
            accent = 0xD8413AFF, accent2 = 0x6E8CB8FF, grid = 0x4E5868FF, border = 0x4E5868FF },
  -- makeover: indigo + chrome (off the SSL green; chrome suits the API look)
  api   = { bg = 0x1E1F22FF, panel = 0x2A2C30FF, text = 0xF0F2F5FF, text_dim = 0x8C9098FF,
            accent = 0x3E5BC0FF, accent2 = 0xC8CDD2FF, grid = 0x32343AFF, border = 0x3E4248FF },
  tube  = { bg = 0x211A14FF, panel = 0x2C2218FF, text = 0xF0E4D0FF, text_dim = 0x9C8A70FF,
            accent = 0xF0A83CFF, accent2 = 0xC2663AFF, grid = 0x3A2E20FF, border = 0x4A3A28FF },
  -- ── EON DAW themes (matched to the real DAW UIs) ──
  -- Ableton: Live light grey + authentic salmon-orange selection accent
  ableton  = { bg = 0xC8C8C8FF, panel = 0xBABABAFF, text = 0x2A2A2AFF, text_dim = 0x6C6C6CFF,
               accent = 0xFF764DFF, accent2 = 0x8A8E94FF, grid = 0xAEAEAEFF, border = 0x9E9E9EFF },
  fl       = { bg = 0x262626FF, panel = 0x303030FF, text = 0xD8D8D8FF, text_dim = 0x828282FF,
               accent = 0xF89B30FF, accent2 = 0x6FBF4FFF, grid = 0x2E2E2EFF, border = 0x383838FF },
  -- Pro Tools: greyer graphite body (lifted off near-black) + edit-blue accent
  protools = { bg = 0x36393CFF, panel = 0x42464AFF, text = 0xE2E6EAFF, text_dim = 0x9498A0FF,
               accent = 0x46A6D8FF, accent2 = 0x5A636EFF, grid = 0x50545AFF, border = 0x50545AFF },
  -- PT Light: Pro-Tools mid-grey chrome + white graph panel + dark legible text
  -- (distinct from `light` which is near-white). bg=window grey, panel=white EQ
  -- graph fill, grid/border stay grey (JSFX passes fixed alphas — band is RGB only).
  protools_light = { bg = 0xB0B3B5FF, panel = 0xFAFAFAFF, text = 0x303236FF, text_dim = 0x5C5E62FF,
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

-- name → semantic palette (packed RGBA). The three REAPER entries map to the TK
-- derivation modes (matches TK Workbench's three separate preset entries):
--   reaper = balanced · reaper_panel = panel · reaper_color = color
function T.resolve(name)
  if name == "reaper"       then return T.make_reaper("balanced") end
  if name == "reaper_panel" then return T.make_reaper("panel") end
  if name == "reaper_color" then return T.make_reaper("color") end
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
