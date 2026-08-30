# Spec — EON Sum (the summing box)

**Status:** design, no code written.
**Scope:** a console-summing stage for Swing's multi-out drum bus, built on
EON's own DSP.
**Companion docs:** `Spec_EON_Lens.md`, `.refs/swing_gmem_bridge_protocol.md`
(neither is in the package checkout — this doc belongs beside them).

---

## 1. What it is

A two-part audio stage that turns Swing's multi-out folder into a summing
console:

- **EON Sum (CHANNEL)** — one instance per pad track. Models the channel
  strip's output amplifier: level-dependent saturation at *that pad's* level,
  plus per-channel component tolerance and crosstalk.
- **EON Sum (BUS)** — one instance on the `Audio` submix parent. Models the
  summing node: a sag whose depth follows how hard the sixteen channels are
  collectively driving it, plus the output amp's harmonics and trim.

Neither is a bus saturator you could get by dropping one plugin on the master.
The whole point is that half the processing happens at each channel's own
level, before the sum — which is the one thing a plugin on the bus can never
do.

---

## 2. Where the idea comes from

studiokozak's **SK AW Console Builder**
([thread 310907](https://forums.cockos.com/showthread.php?t=310907)) automates
building an Airwindows Console rig in REAPER: a SUMMING track, a channel pair
per source, a Console Channel per source pinned to its pair, one Console Buss
on the sum.

What we take from it: **the topology.** Encode per channel, decode once on the
bus, and the correctness requirement that makes it work — the encode must see
the level that actually reaches the bus.

What we do not take: the DSP, and the invertible-pair maths underneath it
(§4). Airwindows Console is Chris Johnson's; this is EON's own model, so
`THIRD_PARTY_NOTICES.md` gains nothing. The *idea* deserves a credit line in
the JSFX header and the manual, and it should name both Chris Johnson and the
thread.

What Swing does not need: the SUMMING track and the pin-mapping. That whole
apparatus exists because a stock REAPER track has one stereo path and no
post-fader insert. Swing's multi-out build already gives every pad its own
track feeding one parent (`Swing_Kit_Bridge.lua:9888-9925`). The channels are
already discrete. There is nothing to wire, no `I_NCHAN` to raise, no pin
matrix — and no doubling of the track count, which matters because
`folder_layout.EnsureSwingParentLayout` and the Drum Matrix both depend on the
folder shape.

---

## 3. The post-fader problem, and Swing's version of it

The thread's core complaint: Console only behaves if Channel and Buss sit on
the same gain stage, REAPER has no post-fader insert slot, so you need a
dedicated track whose fader sits between them.

**Swing has this problem in full**, and for a non-obvious reason. Under
multi-out with the strip-sync companion alive (`strip_takeover`), Swing hands
its per-pad level *out to REAPER*:

- `rk_swing_core.jsfx-inc:1129,1219` — `_tie_pg = strip_takeover ? 1.0 : p_gain[_lv_pad]`.
  The voice is rendered at **unity**; Swing does not apply the pad fader.
- `EON_Swing_Strip_Sync.lua:452` — `tie_channel(..., "D_VOL", ...)` mirrors the
  mixer fader onto the child track's `D_VOL`. Pan goes the same way to
  `D_PAN` (`:454`), which is why `process_pad_fx` emits centre under takeover
  (`rk_drumkit_fx.jsfx-inc:158-166`).

So the pad fader in Swing's new console *is* the REAPER track fader, by
design — the One-Mixer tie. And `D_VOL` is applied **after** the track's FX
chain. Any encode we insert is therefore pre-fader, and every fader move
detunes the model.

How much does that matter? Measured on the proposed curve (§5), driving a
1 kHz sine:

| input level | peak gain | h2 | h3 |
|---|---|---|---|
| −40 dB | −0.02 dB | −70.5 dB | −67.2 dB |
| −20 dB | −0.15 dB | −50.7 dB | −47.3 dB |
| −12 dB | −0.38 dB | −43.1 dB | −39.5 dB |
| −6 dB | −0.75 dB | −37.6 dB | −33.9 dB |
| 0 dB | −1.44 dB | −32.7 dB | −28.5 dB |

A 10 dB fader error moves h2 by **9.2 dB relative to the fundamental**. That
is not a rounding error; pull a fader 10 dB and the channel's character is
wrong by roughly the same 10 dB. The stage is level-dependent on purpose —
that is what makes it a console rather than a filter — which is exactly why
placement has to be right.

### Three ways out, and the one to take

1. **Own the level in the plugin.** Encode carries a LEVEL knob; build sets
   `D_VOL` to unity; tell users to mix on the strip. Exact, and hostile — it
   breaks the One-Mixer tie that Swing's console is built on, and REAPER users
   will reach for the track fader regardless.

2. **Build a summing track per pad, SK-style.** 16 tracks become 32. Rejected:
   it fights `folder_layout`, doubles the TCP, and buys nothing Swing does not
   already have.

3. **Compensate for the fader inside the encode.** ✅ **Recommended.**

   The encode computes

   ```
   out = E(x · g) / g          g = the track's fader gain (and pan, per side)
   ```

   The track fader then multiplies by `g` downstream, so what arrives at the
   bus is `E(x · g)` — precisely as if the encode were post-fader. The
   nonlinearity sees post-fader level; the signal level leaving the plugin is
   untouched, so nothing else in the chain shifts.

   **This is nearly free in Swing, and only in Swing.** `EON_Swing_Strip_Sync`
   already computes `bv` and writes it to `D_VOL` on every tie tick — it is
   the component that *creates* the problem, and it can push the same value
   into the encode in the same tick. No new polling, no new source of truth.

   Details that have to be right:
   - `g` is smoothed over ~30 ms in the JSFX. A raw jump is a zipper on the
     harmonic content, not the level.
   - Pan → per-side `gL`/`gR`, read from `D_PAN` the same way.
   - Floor `g` (≈ −60 dB) so `/g` cannot explode on a fader at −inf. Below
     the floor the channel is inaudible anyway; clamp and stop compensating.
   - **Graceful degradation:** no companion heartbeat → `g = 1` → the stage
     behaves as a plain pre-fader encode. Wrong-ish character, never a
     failure. Same posture as `strip_takeover` falling back when the script
     dies.

---

## 4. Why not an invertible encode/decode pair

Console's elegance is that encode and decode are exact inverses — `sin` and
`asin` — so a single channel through both is bit-transparent, and the entire
effect emerges from summing. It is a lovely trick. It does not survive sixteen
channels.

Measured, 16 uncorrelated channels at −20 dBFS each:

| | peak | rms | crest |
|---|---|---|---|
| linear sum (console off) | +4.42 dB | −7.97 dB | 12.39 dB |
| **EON two-stage** | +2.61 dB | −8.90 dB | **11.52 dB** |
| invertible `sin`/`asin` pair | +3.92 dB | −6.97 dB | 10.89 dB |

The encoded sum peaks at **1.65**, and `asin` is undefined above 1.0 — the
invertible pair leaves its own domain on **1.2 % of samples** and hard-clips
there. Any rational-form inverse (`x/(1+k|x|)` ↔ `y/(1−k|y|)`) is worse: it has
a pole rather than a clip, and for N identical channels the composite blows up
at `a = 1/((N−1)k)`. The failure is structural — the decode is calibrated to
undo *one* encode, and you are handing it sixteen.

The second problem is a correctness trap. With an invertible pair, **every**
signal reaching the bus must be encoded, or the decode expands something that
was never compressed. Swing's own Verb/Delay/Smash returns land on the same
`Audio` parent, and users add tracks to folders. Measured on the two-stage
model, one stray unencoded channel among sixteen shifts bus RMS by
**+0.020 dB** — inaudible. Under an invertible pair the same stray is a real,
audible error the user cannot see the cause of.

So: **two honest stages, not one invertible trick.** A channel amp and a
summing amp, each modelling something that physically exists. We give up
"transparent on a single channel" — which nobody's drum bus ever is — and buy
robustness, no singularities, and no hidden correctness rule.

---

## 5. The model

### 5.1 Channel stage — the strip's output amp

Signal order inside the CHANNEL instance:

1. **Fader/pan compensation** — `x · g`, per §3.
2. **Virtual-earth sag.** The output stage driving the bus, one divide:

   ```
   E(x) = x / (1 + k(x)·|x|)        k(x) = k⁺ for x ≥ 0, k⁻ for x < 0
   ```

   Cheap (no transcendentals — this runs ×16), monotonic, bounded, zero
   state, zero latency. `k⁺ = k⁻` gives a pure odd-harmonic curve; splitting
   them introduces the even order that real, asymmetrically-biased iron has.
   Measured at 0 dBFS:

   | | h2 | h3 | h4 | h5 |
   |---|---|---|---|---|
   | IRON off (`k±` = 0.30) | −162 dB *(numerical floor)* | −26.7 dB | −192 dB | −41.5 dB |
   | IRON on (`k⁺`=0.30, `k⁻`=0.18) | −32.7 dB | −28.5 dB | −56.9 dB | −43.6 dB |

   IRON off is *exactly* odd — the h2/h4 figures are the FFT floor, not a
   small residue. That makes IRON a genuine character switch rather than a
   tilt, and it makes "console off" (`k = 0`) mathematically identity.

3. **DRIFT** — per-channel component tolerance: a gain offset of a few
   hundredths of a dB and a one-pole HF phase tilt, seeded deterministically
   from `P_EXT:EON_PAD_IDX` so it is stable across sessions and renders. This
   is what stops sixteen channels sounding like one channel played sixteen
   times. Not modelled on the bus, because it does not exist there.

4. **BLEED** — L↔R crosstalk within the strip, 6 dB/oct HF-tilted, −60 dB
   region. The dominant real crosstalk term, and the cheapest to place
   honestly.

5. **Publish** — this channel's `|current|` (block RMS of the post-sag signal)
   and a heartbeat to the link band. Diagnostic and bus-load data only; see
   §5.3.

### 5.2 Bus stage — the summing node

1. **Read bus load** `L = Σ|Iᵢ|` from the link band across live channels.
2. **Load-modulated sag** — the same rational shape, coefficient `k_b`
   scaled by `L`. This is the part that cannot be computed from the summed
   audio, and the reason a side-channel exists at all: `Σ|Iᵢ|` is total
   current drawn from the node, which is *not* recoverable from `|Σ Iᵢ|`
   once channels partially cancel. Sixteen channels at −20 dB and one channel
   at −8 dB can hit the same bus meter and load the node differently.
3. **IRON / rail** — the output amp's own asymmetry and headroom.
4. **TRIM** — output level.

**Dynamics deliberately stay out.** EON 76 already sits on this bus and is the
compressor. EON Sum contributes harmonic and load behaviour; it does not grow
a second envelope follower. Chain order on the parent is therefore
`EON Sum (BUS) → EON 76` — close the console first, then glue it.

### 5.3 The side-channel contract

The link band is the *only* cross-instance dependency, and it is deliberately
weak:

- It carries a **coefficient**, never a sample. A stale or missing value
  produces a slightly different tone. It can never click, drop out, or
  diverge.
- It is one block late by construction (REAPER renders children before
  parent). Acceptable for a control-rate coefficient; it would not be for
  anything in the signal path.
- **Fallback:** band stale (no heartbeat within N blocks) → derive `L` from
  `|Σ|` of the received audio. Degrades to a good bus saturator.
- Offline render and freeze work because of that fallback, not in spite of it.

Precedent for all of this: `EON_FX_Return_View.jsfx` already reads the
per-instance strip band to show which pads feed a bus, with `link_slot` pushed
by the strip-sync companion, and `EON_76.jsfx` already runs a param-echo +
command band (`GS_BC_LINK`, 26170000–26171535) entirely in `@block`.

### 5.4 Who owns the coefficients

The bus is the console; the channels are its input strips. One set of
controls, sixteen satellites.

But **the serialized sliders are canonical, not gmem.** The bus writes a
character change to the band for live feedback *and* the sync companion pushes
it into all sixteen encodes' sliders by param name (exactly how
`set_fx_returns` and `EON_Swing_Strip_Sync`'s `pmap` already work). Rationale:
a render must be bit-reproducible from the project file alone, with no script
running and no gmem. gmem is the live-edit convenience path; the project is
the truth.

---

## 6. Placement

```
Swing — <kit>                        ← parent folder
├── Swing                            ← engine track
└── Audio                            ← submix parent
    ├── 01 Kick   [Drum Strip → EON Sum (CHANNEL)]   D_VOL = pad fader
    ├── … 16 pads                                     ⋮
    ├── EON Verb Return   [… → EON Sum (CHANNEL)]
    ├── EON Delay Return  [… → EON Sum (CHANNEL)]
    └── EON Smash Return  [EON 76 → EON Sum (CHANNEL)]
    ▲ parent FX chain: EON Sum (BUS) → EON 76
```

- **Encode last in the pad chain**, after `EON_Drum_Strip`. The strip's
  `slider20 strip_out_db` (Output Trim) is then pre-encode, which is correct:
  it is part of the channel's level, not a post-console fader.
- **Returns get an encode too.** Under the two-stage model this is a quality
  choice rather than a correctness rule (§4) — but the returns are console
  channels in every meaningful sense, and leaving them out means the wet path
  bypasses the console.
- **Decode before EON 76** on the parent (§5.2).

---

## 7. Build integration

All of this rides the existing path — `rk_ops.do_build_multiout`
(`Swing_Kit_Bridge.lua:9494`):

- **Dialog** — a fourth checkbox in "Drum Bus Options": *Console summing
  (EON Sum)*. `proceed_build(want_returns, want_buscomp, want_stepseq, want_sum)`.
  Ripples to three call sites: the `opts.fx_returns` programmatic path, the
  preserve path, and the no-ReaImGui `ShowMessageBox` fallback.
- **Preserve on rebuild** — `have_sum`, detected by scanning `audio_sub` for
  "EON Sum", mirroring `have_buscomp`. A Rebuild must not silently drop the
  user's console, and must not re-ask.
- **Insertion** — `ensure_sum(tr, mode, ch)` modelled on `ensure_eon76`:
  find-or-insert, set defaults by param name, leave an existing instance
  alone. Unlike `ensure_eon76`, **no `core.fx_embed_mcp` on the channel
  instances** — the pad track's MCP embed is already the Drum Strip
  (`EON_Swing_Strip_Sync.lua:327`), and pad tracks are 28 px. Only the BUS
  instance embeds.
- **Sync companion** — the fader/pan compensation and the coefficient push
  belong in `EON_Swing_Strip_Sync.lua`, in the tie tick that already writes
  `D_VOL`/`D_PAN`. New file only if that one is already at its local budget.

---

## 8. UI

- **BUS** — a faceplate deck in the `EON_FX_Return_View` idiom: sixteen
  channel-load bars showing who is driving the node (pad names and colours
  come free from the strip band), a bus-load needle on `vu_kbsg`, and the
  character controls — LOAD, IRON, DRIFT, BLEED, TRIM. `rk_theme` chip, so it
  follows the suite's fourteen themes like everything else.
- **CHANNEL** — effectively headless. A nameplate and a load LED for when
  someone does open it. No embed, minimal `@gfx`.
- One file, `Swing/EON_Sum.jsfx`, with a `MODE` slider (CHANNEL/BUS). Two
  files could version-skew between deploys; the two halves of a console must
  not. One entry in `index.xml`, one deploy.
- Naming: **EON Sum**, `desc:EON Sum — Console Summing`. Fits EON 76 / EON
  Lens / EON Smash. *(Alternatives if the FX suite wants a family name:
  EON Bus, EON Iron.)*

---

## 9. Risks and open questions

| | |
|---|---|
| **CPU ×16** | The curve is one divide, but sixteen JSFX instances are not free even hidden. Channel instances get `no_meter` and no `gfx_idle`; only the bus deck redraws. Needs measuring on a real kit before it ships. |
| **PDC** | Must be zero, hard constraint — same reason the Drum Strip documents it. No lookahead, no oversampling, no `pdc_delay`. Oversampling the sag would be nice and is not worth live-drum latency. |
| **gmem band** | Proposal: `26180000`, above `GS_BC_LINK`'s 26170000–26171535. **Must be verified against `.refs/swing_gmem_bridge_protocol.md`, `.refs/gmem_regions_supplement.tsv` and `EON/.Extension/src/gmem/*.h` before use** — none are in this checkout, and the house rule is a full-bundle sweep before claiming a range. |
| **Multi-instance** | Two Swings = two Audio buses = two independent consoles. Link rows must key on the registry slot, as EON 76 does; a broadcast cell would cross-wire them. |
| **`strip_takeover` off** | No companion → no `D_VOL` mirroring → the pad fader is back inside Swing → compensation should be *disabled*, not defaulted to 1. The encode needs to know which regime it is in, not just what `g` is. |
| **User adds a track to the folder** | Benign (§4), but the bus deck can spot it: compare `Σ` of published channel currents against received audio and light an advisory. Cheap, and it is the kind of thing that saves a support round. |
| **Frozen / rendered pad tracks** | A frozen track keeps its FX chain baked; the bus then sees an already-encoded signal with no live heartbeat. The load fallback covers it — worth an explicit test. |

---

## 10. Suggested order of work

1. **`EON_Sum.jsfx`, BUS mode only**, no side-channel — load derived from
   `|Σ|`. Drop it on the Audio parent by hand. This is auditionable in an
   afternoon and settles whether the curve is musically right before any
   plumbing exists.
2. **CHANNEL mode**, inserted by hand, with the sag + IRON. A/B sixteen
   channels against step 1's bus-only version — this is the experiment that
   proves the whole premise is worth the sixteen instances.
3. **Fader compensation** in the sync companion. Verify against the table in
   §3: sweep a pad fader and confirm the harmonic signature holds still.
4. **Link band** — publish, bus load, deck metering.
5. **Build integration** — the fourth checkbox, `ensure_sum`, preserve.
6. **DRIFT / BLEED**, last. They are the seasoning, and they are the easiest
   to overdo.

Steps 1–2 answer the only question that actually matters, and neither of them
requires touching `Swing_Kit_Bridge.lua`.

---

*Figures in §3, §4 and §5.1 are measured, not estimated — 64 k FFT at
192 kHz, Hann window; 16-channel test at −20 dBFS uncorrelated noise per
channel.*
