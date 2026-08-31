# ReaKit for DrumCloud — widget audit

Smaasten named five sections they'd hand to ReaKit — **grain, pitch, motion,
reverb, delay** — while keeping DrumCloud's waveform/grain visualisation
custom. This is what that needs, what the kit already had, and what was missing.

Audited against this tree (`Swing/libs/`). The ReaKit bundle ships a few
libraries Swing doesn't import (`btn_*` buttons, smooth, spectrum, oversample),
so treat "missing" below as "missing from the Swing tree" — everything new here
is namespaced `rk_ui_*` / `rk_*`, which won't collide with those.

---

## Section by section

### Grain — size, density, spray, position, direction

| Needs | Status |
|---|---|
| Four continuous knobs with fine adjust and reset | **Had it.** `rk_knob_interact` / `rk_knob_draw`, 20 styles |
| Direction mode switch (fwd / rev / alt) | **Was missing** → `rk_seg_begin` + `rk_seg_item` |
| Grain envelope shape | **Was missing** → `rk_env`, draggable contour |
| Density readout in Hz next to the control | **Had it** in fragments — `ebc_readout` was inlined in EON_76 → generalised as `rk_readout` / `rk_readout_a` |

### Pitch — semitones, cents, mode, scale

| Needs | Status |
|---|---|
| Detented semitone knob (49 stops over ±24) | **Had it.** `n_detents` on any knob style |
| Bipolar display for ± values | **Had it.** `is_sym = 1` |
| Mode switch | **Was missing** → segmented selector |
| Scale list (7+ entries, too many for a row) | **Was missing** → `rk_combo_begin/item/end` |

### Motion — path, rate, run

| Needs | Status |
|---|---|
| XY pad — two parameters under one finger | **Was missing entirely** → `rk_xy`, with a single paired automation write |
| Tempo-synced rate in musical divisions | **Was missing** as a widget → `rk_div_chip`; the maths (`rk_div_beats/seconds/hz/name`) matches `rk_delay.jsfx-inc`'s table exactly |
| Run / enable with a visible state | **Was missing** → `rk_toggle_led` |

### Reverb — size, damping, mix, freeze

| Needs | Status |
|---|---|
| Three knobs | **Had it** |
| Freeze toggle that reads as latched | **Was missing** → `rk_toggle_led` |
| Return level metering | **Had it, but not usably** — see the `vu_kbsg` note below → `rk_meter_v` / `rk_meter_h` |

### Delay — division, feedback, mix, ping-pong

| Needs | Status |
|---|---|
| Sync division + a milliseconds readout | **Was missing** → `rk_div_chip` + `rk_div_seconds` |
| Feedback / mix knobs | **Had it** |
| Ping-pong toggle | **Was missing** → `rk_toggle` |

### The custom visualisation

Nothing to add — and that's the point. `rk_frame_begin()` publishes the mouse
state and `rk_sc`; everything between it and `rk_frame_end()` is plain `gfx_*`.
DrumCloud's waveform/grain view draws straight into the same frame, reads the
same palette, and the kit neither knows nor cares. The starter's bottom panel is
exactly this: a hand-drawn peak envelope with grain markers driven by the same
parameters the knobs above it write.

---

## Cross-cutting gaps — the ones that mattered most

These weren't about any one section. They're what made the kit hard to adopt
from outside.

1. **The frame contract was undocumented tribal knowledge.** Ten globals had to
   be set at the top of every `@gfx` and two latched at the bottom; the only
   description lived in a lib header, and the only working example was inside a
   shipping plugin. Now: `rk_frame_begin()` / `rk_frame_end()`.
2. **Two non-obvious workarounds were copy-pasted per plugin** — the stale
   mouse position on embedded wheel events, and embed click-through re-arm.
   Both are folded into the frame calls now.
3. **The hint queue had no renderer.** `updateHintTime` in
   `rk_widgets.jsfx-inc` has always collected hint strings and dropped them on
   the floor — its own header says so. `rk_tip()` + the layer in
   `rk_frame_end()` is that renderer.
4. **Theming required EON's bridge.** `rk_theme.jsfx-inc` reads a `gmem` block
   published by a Lua script that ships with Swing; without it, a third-party
   plugin gets dark defaults and a dead picker. The palette in `rk_ui_core` is
   standalone, with `rk_pal_adopt()` as the optional bridge hookup.
5. **No allocator.** Every plugin invented its own `freemem` discipline.
   `rk_mem_init` / `rk_widget_mem` gives one convention, and it's the same
   16-slot block `knobs_kbsg` and `sliders_kbsg` already use.

---

## `vu_kbsg.jsfx-inc` — do not ship this one as MIT

Three findings, all verifiable in the file:

- **It owns memory addresses 0–437** (its own header says so) and expects
  `zm_theme` / `zm_frame_r/g/b` globals. Any plugin whose allocator starts at 0
  — which is the normal thing to do — silently corrupts it.
- **It contains an exact port of GPL code**: "SECTION 4: LITEON BALLISTICS" and
  "SECTION 6: LITEON DRAWING", from Liteon's `vumetergfx`, © 2008–2009 Lubomir
  I. Ivanov, marked GPL in the file (lines ~320–345 and ~497–668). GPL and an
  MIT redistribution don't mix, and GPL and a commercial licence mix worse.
- **That block is dead code.** `lit_vu_db_to_x`, `lit_arc_y` and
  `lit_draw_panel` are called only by `mtr_vu_liteon_stereo/summed/ms`, and
  those three are called by nothing in this repository. Deleting the two
  sections removes the problem without changing any rendered pixel.

Also worth a look while you're in there: `THIRD_PARTY_NOTICES.md` credits
DD-101, SEQS, TiaR, ReEQ, TK, json.lua, imgui.lua and rtk — but not the three
VU sources this file ports (Tukan, ZenoMOD, Liteon), and the Tukan physics and
ZenoMOD faces *are* live code.

`rk_meter_v` / `rk_meter_h` were written to be the answer for anyone who just
wants a level meter: no fixed memory, no theme bridge, no third-party lineage.

---

## Still missing

Honest list, in the order a granular sampler would feel them:

- **Typed numeric entry.** `rk_field` drags and wheels; it doesn't let you type
  "441". `gfx_getchar` makes this doable and `rk_key` already exposes the key.
- **Free-form breakpoint envelope.** `rk_env` is a fixed ADSR shape. A grain
  envelope with arbitrary points, or curved segments, is a bigger widget.
- **Modulation rings.** A knob showing how far an LFO is pushing it — an arc
  outside the value arc — is the natural next step for a motion section, and
  nothing in the kit draws one.
- **Scrolling dropdowns.** `rk_combo_*` draws every row. `rk_theme.jsfx-inc`
  has a scrolling implementation that could be generalised if you need lists
  longer than a panel.
- **Right-click context menus.** `gfx_showmenu` exists; nothing wraps it.
- **File drop.** `gfx_getdropfile` exists; nothing wraps it. A sampler wants it.
- **Keyboard focus and accessibility.** No focus ring, no tab order, no
  keyboard-only parameter editing.

---

## Try it

`Swing/ReaKit_Starter.jsfx` — five sections, every widget above wired to a real
parameter with automation-safe writes, a custom visualiser panel, and a knob
style stepper in the header so all 20 faces can be compared without editing
anything. The DSP is a deliberate passthrough: it's a GUI skeleton, meant to be
copied and gutted.
