# ReaKit UI — integration guide

A JSFX GUI toolkit: knobs, faders, buttons, selectors, XY pads, envelopes and
meters, all drawn from `gfx_*` primitives. No images, no sprites, no external
dependencies, one shared interaction model, and it scales to any window size on
every platform REAPER runs on.

This guide is for a developer dropping ReaKit into **their own** JSFX. If you
just want to see it work, open `Swing/ReaKit_Starter.jsfx` in REAPER — it is a
complete five-section interface with every widget family wired to a real
parameter, and it is meant to be copied.

---

## What's in the kit

| File | What it gives you |
|---|---|
| `Swing/libs/rk_ui_core.jsfx-inc` | The per-frame contract, palette, state allocator, panel chrome, tooltips |
| `Swing/libs/rk_ui_widgets.jsfx-inc` | Buttons, toggles, LED pills, segmented selectors, dropdowns, drag-fields, meters |
| `Swing/libs/rk_ui_motion.jsfx-inc` | XY pad, envelope editor, tempo-sync divisions (widget + maths) |
| `Swing/libs/knobs_kbsg.jsfx-inc` | 20 knob styles behind one call, one shared feel |
| `Swing/libs/sliders_kbsg.jsfx-inc` | 17 slider and fader types |
| `Swing/libs/rk_auto_contrast.jsfx-inc` | Text ink that stays readable on any surface colour |
| `Swing/libs/rk_theme.jsfx-inc` | The EON theme picker — needs EON's bridge, see [Theming](#theming) |
| `Swing/libs/vu_kbsg.jsfx-inc` | Hardware VU ports — **read [Gotchas](#gotchas) before importing this one** |

---

## Quick start

```eel
import libs/rk_ui_core.jsfx-inc
import libs/knobs_kbsg.jsfx-inc
import libs/rk_ui_widgets.jsfx-inc
import libs/rk_ui_motion.jsfx-inc

@init
freemem = 0;
freemem = rk_mem_init(freemem);   // the kit takes its block, hands back the top
m_size  = rk_widget_mem();        // 16 slots per control, allocated ONCE

@gfx 600 400
rk_frame_begin(600, 400);         // design size -> rk_sc
rk_backdrop();

nv = rk_knob_interact(1, m_size, 100, 100, 20, g_size, 1, 500, 40, 0);
nv != g_size ? ( g_size = nv; rk_automate(1); );
rk_knob_draw(1, 100, 100, 20, g_size, 1, 500, 0, m_size[0],
             0.31, 0.68, 0.90, 0, 0.13, 0.14, 0.16);

rk_frame_end();
```

Import order matters: `rk_ui_core` first, then anything else. EEL2 is
single-pass — a function must be defined before it is called.

---

## The frame contract

The widget libraries read their input from globals. `rk_frame_begin()` sets all
of them and `rk_frame_end()` closes the frame; between those two calls you can
mix ReaKit controls with your own `gfx_*` drawing freely.

| Global | What it is |
|---|---|
| `mx`, `my` | Mouse position, corrected on wheel frames when embedded |
| `LMB`, `RMB` | Button state |
| `lmb_down`, `rmb_down`, `lmb_up` | Edges — computed once per frame, never per widget |
| `CTRL`, `SHIFT`, `ALT` | Modifiers. CTRL = fine adjust, by convention everywhere |
| `dt` | Frame delta, clamped to 50 ms so a stalled UI can't jump |
| `hv_speed` | Hover animation rate (11) |
| `frame_wheel` | Wheel notches this frame; `rk_frame_end()` consumes `mouse_wheel` |
| `tau` | `2*pi` |
| `rk_W`, `rk_H`, `rk_sc`, `rk_ret`, `rk_micro` | Window size, scale factor, HiDPI factor, embedded flag |
| `rk_key` | This frame's `gfx_getchar()`, drained once for you |
| `rk_live` | 0 while an overlay owns the input — kit widgets honour it automatically |

`rk_frame_end()` also draws the tooltip layer, latches the edge-detect state,
and re-arms embed click-through. Anything you want painted above tooltips must
come after it.

Two things it folds in that are easy to get wrong on your own:

- **Embedded wheel events arrive with a stale mouse position**, so every hover
  test misses and the wheel does nothing. `rk_frame_begin()` remembers the
  pointer on ordinary frames and reuses it on wheel frames.
- **Embed click-through**: a UI in a track panel should pass clicks to REAPER
  when they don't land on a control. Widgets call `rk_claim()` when the pointer
  is over them; `rk_frame_end()` gives the click back if nothing claimed it.

---

## Widget state

Every interactive control needs a 16-slot block, allocated **once** in `@init`:

```eel
m_cutoff = rk_widget_mem();
```

Allocating in `@gfx` hands out fresh memory every frame, and the control forgets
it is being dragged the moment you move the mouse.

The layout is shared with `knobs_kbsg` and `sliders_kbsg`, so blocks are
interchangeable across the whole kit:

```
[0] hover_t    [1] dragging   [2] drag_ref   [3] drag_start_val
[4] last_click_time           [5] settled    [6] active
[7] aux        [8..15] widget-specific
```

`mem[0]` is the hover animation you hand to any `*_draw`; `mem[6]` is what you
pass to `rk_claim()`.

---

## Automation-safe writes

**This is the rule the whole kit is built on.** A widget never writes a
parameter. It returns a value; you compare, assign, and tell the host.

```eel
slider3:g_size=40<1,500,0.1>Grain Size (ms)

nv = rk_knob_interact(style, m_size, cx, cy, r, g_size, 1, 500, 40, 0);
nv != g_size ? ( g_size = nv; rk_automate(3); recalc(); );
```

`rk_automate(n)` is `slider_automate(2^(n-1))`. Named sliders make the variable
and the parameter the same thing, which is why the assignment is enough on the
audio side — but not on the host side:

- Assigning without `rk_automate()` leaves the automation lane, the host's
  parameter display and any control surface stale.
- Calling `rk_automate()` unconditionally every frame spams the undo history and
  writes automation while nobody is touching anything.

The comparison is the contract. For a control that moves two parameters at once
(an XY pad, a preset recall), write both and call `rk_automate_mask()` once:

```eel
rk_xy(m_xy, x, y, w, h, m_x, m_y, 0, 1, 0, 1, 0.5, 0.5) ? (
  m_x = rk_xy_vx; m_y = rk_xy_vy;
  rk_automate_mask(2 ^ (9 - 1) | 2 ^ (10 - 1));
);
```

---

## Catalog

### Knobs — `knobs_kbsg.jsfx-inc`

One interact, one draw, twenty looks. **Visual dispatch only**: every style
shares `ssl_knob_interact`, so the feel is identical and only the face changes.

```eel
nv = rk_knob_interact(style, mem, cx, cy, radius, cur, vmin, vmax, vdef, n_detents);
rk_knob_draw(style, cx, cy, radius, value, vmin, vmax, is_sym, hover_t,
             cr, cg, cb, n_detents, bg_r, bg_g, bg_b);
```

| ID | Style | ID | Style | ID | Style |
|---|---|---|---|---|---|
| 1 | SSL 4000E *(default)* | 8 | Jog wheel | 15 | Pro Tools |
| 2 | Vari-Mu | 10 | Spice Pro | 16 | FabFilter |
| 3 | API 550 | 11 | Encoder (LED ring) | 17 | Serum |
| 4 | Witti Sound | 12 | Pultec EQP-1A | 18 | Roland 808/909 |
| 5 | Neve 1073 | 13 | Ableton Live | 19 | Pultec cream |
| 6 | Joanny/McFizz | 14 | FL Studio | 20 | Neve alt |
| 7 | MPC rubber pad | | | | |

Style 9 (BirdBird) needs its own memory-based draw and is not in the dispatch;
unknown IDs fall back to SSL. IDs are persisted in ExtState by EON plugins —
**append only, never renumber.**

The shared gestures, which you get for free on every style:

| Gesture | Result |
|---|---|
| Drag | ~200 px for full range, regardless of knob size or parameter range |
| CTRL + drag | Fine (×0.1) |
| Wheel | 2% of range per notch; 0.5% with CTRL |
| Wheel with `n_detents > 1` | Snaps to discrete steps |
| Double-click | Back to `vdef` |

Pass `is_sym = 1` for bipolar parameters so the arc fills from the centre.

### Sliders and faders — `sliders_kbsg.jsfx-inc`

Values are **normalised 0..1** here (knobs work in real units — the one seam in
the kit). Draw and interact are separate calls; console-style vertical faders
are painters that pair with a shared interact:

| Type | Draw | Interact |
|---|---|---|
| Horizontal | `sld_horiz_draw` | `sld_horiz_interact` |
| Vertical fader | `sld_vert_draw` | `sld_vert_interact` |
| Fill bar | `sld_fillbar_draw` | `sld_fillbar_interact` |
| Stepped | `sld_stepped_draw` | `sld_stepped_interact` |
| Bipolar | `sld_bipolar_draw` | `sld_bipolar_interact` |
| Mini | `sld_mini_draw` | `sld_mini_interact` |
| Arc | `sld_arc_draw` | `sld_arc_interact` |
| Range (two thumbs) | `sld_range_draw` | `sld_range_interact` |
| Vertical LED strip | `sld_vled_draw` | `sld_vled_interact` |
| Vertical groove | `sld_vgroove_draw` | `sld_vgroove_interact` |
| SSL / Neve / API / Tube / MPC | `sld_vssl_draw`, `sld_vneve_draw`, `sld_vapi_draw`, `sld_vtube_draw`, `sld_vmpc_draw` | `sld_vbipolar_interact` |
| Pro Tools / Console 4K | `sld_vpt_draw`, `sld_vconsole_draw` | `sld_vert_interact` |

Colours: `sld_set_accent(r,g,b)`, `sld_set_accent2(r,g,b)`, `sld_set_track(r,g,b)`.

### Controls — `rk_ui_widgets.jsfx-inc`

| Call | Returns |
|---|---|
| `rk_button(mem, x, y, w, h, label)` | 1 on the frame it is pressed |
| `rk_toggle(mem, x, y, w, h, label, state)` | New state |
| `rk_toggle_led(mem, x, y, w, h, label, state)` | New state, with an LED |
| `rk_seg_begin(mem, x, y, w, h, n, cur)` + `rk_seg_item(i, label)` | New index / 1 when a cell is clicked |
| `rk_combo_begin(mem, x, y, w, h, cur, label)` + `rk_combo_item(i, label)` + `rk_combo_end()` | 1 while open / 1 when a row is picked |
| `rk_field(mem, x, y, w, h, cur, vmin, vmax, vdef, step, txt)` | New value (drag, wheel, double-click) |
| `rk_meter_v` / `rk_meter_h(mem, x, y, w, h, db, db_lo, db_hi)` | — (peak hold lives in the block) |
| `rk_led(cx, cy, rad, on_t, r, g, b)` | — |
| `rk_db(x)` | Linear amplitude to dB |

EEL2 has no string arrays, so multi-choice controls are opened, filled item by
item, and closed:

```eel
nv = rk_seg_begin(m_dir, x, y, w, h, 3, g_dir);
rk_seg_item(0, "FORWARD")   ? ( nv = 0; );
rk_seg_item(1, "REVERSE")   ? ( nv = 1; );
rk_seg_item(2, "ALTERNATE") ? ( nv = 2; );
nv != g_dir ? ( g_dir = nv; rk_automate(5); );
```

### Motion and timing — `rk_ui_motion.jsfx-inc`

| Call | Notes |
|---|---|
| `rk_xy(mem, x, y, w, h, cur_x, cur_y, xmin, xmax, ymin, ymax, xdef, ydef)` | Returns 1 when either axis moved; values in `rk_xy_vx` / `rk_xy_vy` |
| `rk_env(mem, x, y, w, h, a, d, s, r, a_max, d_max, s_max, r_max)` | Draggable ADSR contour; returns 1 on change, values in `rk_env_a/_d/_s/_r` |
| `rk_div_chip(mem, x, y, w, h, cur, vdef)` | Tempo-sync selector, 0..15 |
| `rk_div_beats(d)` / `rk_div_seconds(d)` / `rk_div_hz(d)` / `rk_div_name(d, dst)` | The maths behind it |

Division indices: `0` = free, then 1/4, 1/8, 1/16, 1/32, 1/64, each in
straight / triplet / dotted order. **This is byte-identical to the table in
`rk_delay.jsfx-inc`**, so a UI index can be handed straight to a delay engine.

Set `s_max` to 0 in `rk_env` and it reads as the AD contour a grain or a
percussive layer wants.

### Chrome — `rk_ui_core.jsfx-inc`

`rk_backdrop()`, `rk_panel()`, `rk_section()` (returns the first free y inside),
`rk_sep_h/v()`, `rk_readout()`, `rk_readout_a()`, `rk_fill_round()`,
`rk_font()`, `rk_text/_c/_r/_box()`, `rk_tip()`.

`rk_tip(x, y, w, h, text)` arms a tooltip against a rectangle; it appears after
a short dwell, follows nothing, and is clamped inside the window.

---

## Theming

The kit carries an 8-slot semantic palette: `0 BG · 1 PANEL · 2 TEXT ·
3 TEXT_DIM · 4 ACCENT · 5 ACCENT2 · 6 WARN · 7 BORDER`.

```eel
rk_pal_set(4, 0.9, 0.4, 0.2);      // your accent
rk_col(4, 1);                       // gfx_set from a slot
rk_pal_get(4);                      // -> rk_cr / rk_cg / rk_cb
rk_col_lift(1, 0.12, 1);            // slot, lightened (or darkened, if < 0)
```

Defaults are a neutral dark console, so a plugin that never touches a theme
still looks deliberate.

`rk_pal_adopt()` takes the live EON theme when its bridge is running and does
nothing when it isn't — safe to call unconditionally. The full theme picker
(`rk_theme.jsfx-inc`, `rkth_chip`, 14 themes) is a different proposition: it
reads and writes a `gmem` block that EON's Kit Bridge script publishes. Without
that script it falls back to dark defaults and the picker does nothing. If you
want your own themes, use the palette and skip `rk_theme.jsfx-inc`.

---

## Scaling

`rk_sc` is the one number you multiply by. Lay out in design pixels for the size
you passed to `rk_frame_begin()`, and wrap dimensions in `rk_px()`:

```eel
rk_font(10, 1);                     // 10 design px, bold
gfx_rect(rk_px(12), rk_px(8), rk_px(64), rk_px(20));
```

When embedded (`rk_micro`), `rk_sc` becomes the HiDPI factor instead of a
stretch factor, because a track-panel strip should render at native density
rather than scale a 600-px layout into 120 px of height. Check `rk_micro` and
lay out a denser variant — see `EON_76.jsfx` for a worked example of one plugin
carrying both a floating and an embedded layout.

---

## Gotchas

1. **`vu_kbsg.jsfx-inc` is not drop-in.** It hardcodes memory addresses 0–437,
   so it collides with any allocator that starts at 0, and it expects `zm_theme`
   plus `zm_frame_r/g/b` globals. It also contains an exact port of Liteon's
   GPL VU (`lit_*`, `mtr_vu_liteon_*`), which is incompatible with an MIT
   redistribution. Use `rk_meter_v` / `rk_meter_h` unless you specifically want
   a hardware VU face, and if you do, take only the sections you need.
2. **Dropdowns paint immediately.** An open list covers whatever is already on
   screen, so draw combos last in `@gfx`. The kit's own controls stand down
   while a list is open — they hit-test against `rk_live`, which
   `rk_frame_begin()` derives from the previous frame's overlay state — so a
   click on a row can't also reach the widget underneath. Controls from
   `knobs_kbsg` / `sliders_kbsg` don't know about this: gate those yourself
   with `!rk_modal ? ( ... );`, or place lists where they don't cover knobs.
3. **Allocate widget memory in `@init`, never in `@gfx`.** The symptom is a
   control that won't drag.
4. **`lmb_down` must be computed once per frame**, which `rk_frame_begin()`
   does. Recomputing it inside a widget makes every widget think it was clicked.
5. **Knobs work in real units, sliders in 0..1.** The two libraries grew apart
   before they were one kit. Convert with `rk_norm()` / `rk_denorm()`.
6. **Draw a knob from the value you passed in, not the value it returned.**
   The starter's `ui_knob` does this deliberately: drawing the arc from the
   fresh value while the caller's readout text still shows the old one lets the
   pointer and the number disagree mid-drag. Commit both on the next frame.
7. **`rk_frame_end()` consumes `mouse_wheel`.** If you read the wheel yourself,
   read `frame_wheel`, and read it before the frame ends.
8. **EEL2 is single-pass.** Import `rk_ui_core` first; define your own helper
   functions above their first call site.

---

## Files and licence

The UI kit files — `rk_ui_core.jsfx-inc`, `rk_ui_widgets.jsfx-inc`,
`rk_ui_motion.jsfx-inc` and `ReaKit_Starter.jsfx` — are MIT licensed; see
[LICENSE](LICENSE). Use them in your own plugins, commercial or not.

The knob, slider and meter libraries are part of the ReaKit bundle and ship
under its terms; `vu_kbsg.jsfx-inc` additionally carries third-party VU ports
with their own licences (see Gotchas). Everything else in this repository is
Swing, which is commercial software — see the repository's `LICENSE.md`.
