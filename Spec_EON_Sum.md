# Spec — EON Sum (the summing box)

**Status:** design, no code written.
**Scope:** a summing stage for Swing's multi-out drum bus, modelling a **drum
machine's mix bus** rather than a mixing console's. EON's own DSP.
**Companion docs:** `Spec_EON_Lens.md`, `.refs/swing_gmem_bridge_protocol.md`
(neither is in the package checkout — this doc belongs beside them).

> **Rev 2** — the model was originally console summing, seeded by the forum
> thread. Changed to drum-machine circuit after review: Swing is a drum
> machine, and the two bus topologies are genuinely different (§2). Console
> behaviour survives as a secondary mode. The architecture, the post-fader
> analysis (§4) and the rejection of an invertible pair (§5) are unchanged —
> they were never console-specific.

---

## 1. What it is

A two-part audio stage that turns Swing's multi-out folder into a drum
machine's output section:

- **EON Sum (CHANNEL)** — one instance per pad track. The voice's output
  stage: its coupling cap, its own amp, and the current it draws.
- **EON Sum (BUS)** — one instance on the `Audio` submix parent. The shared
  supply rail, the passive mix network, and the single output amp that every
  voice runs through.

The headline behaviour is **rail sag**: all sixteen voices draw from one power
supply, so a loud kick drops the rail and every other voice loses a little
headroom for a few tens of milliseconds. That is the drum-machine pump. It is
a *cross-channel* effect, which is the entire reason this needs a per-channel
stage and a bus stage rather than one plugin on the master.

---

## 2. Drum machine, not console

Both are "summing", and they are not the same circuit.

| | Mixing console | Drum machine |
|---|---|---|
| Channels | 24–72, each on its own strip PCB | 8–16 voices on one board |
| Summing | Active virtual-earth amp, long bus wire | Passive resistor network into one op-amp |
| Power | Beefy, per-rail regulation, often per-section | One modest supply shared by every voice |
| Character comes from | Channel line amps, bus impedance, crosstalk between adjacent strips | **Rail sag**, the single output amp, per-voice output stages |

The differences that matter for us:

- **Shared supply.** A console's channel strips do not meaningfully duck each
  other through the power rail. A drum machine's voices absolutely do — it is
  one small supply and the transients are enormous relative to it. This is the
  effect people are actually chasing when they talk about a drum machine's
  "mix bus", and no single-channel plugin can produce it.
- **Passive vs active summing.** A console's summing amp holds its node near
  zero volts, so channels barely load each other. A passive resistor network
  does not, so voices interact directly — small, resistive, level-dependent.
- **One output amp.** Sixteen voices through a single op-amp on a modest rail.
  Its clipping *is* the "loud" sound of the machine.

### Why this is the right call for Swing

1. **Swing is a drum machine.** Sixteen pads, one bus, per-pad voices. The
   drum-machine topology is a literal description of what already exists in
   the project; the console topology is an analogy.
2. **It is more audible on drums.** Rail sag on a kick is a groove effect.
   Console glue across sixteen drum channels is subtle to the point of being
   hard to A/B.
3. **It is differentiated.** Console summing is a crowded shelf — Airwindows
   Console, VCC, Console 1, and the forum thread's script. A drum machine's
   mix bus is close to empty.
4. **It justifies the plugin's existence.** The EON FX suite already has
   saturation and colour tools (Dirt Squeeze, Spice, Reelism) and the Drum
   Strip already has crush and drive (`slider16–18`). A summing box that is
   just another saturator adds nothing. The cross-channel behaviour is the
   only thing here that cannot be got any other way.

### What we do *not* do

- **No named machine.** Model the class of circuit, not a specific product.
  Controls are named after what they physically are — RAIL, CAP, AMP — not
  after a machine. This is also the safe side of the licensing pass, and
  consistent with the decision to rename the brand-styled knob themes.
- **No converter or bit modelling.** The Drum Strip already owns crush and
  drive. Duplicating them here would be two stages fighting over the same
  sound.
- **Console mode is secondary**, not the headline (§6.4).

---

## 3. Where the idea comes from

studiokozak's **SK AW Console Builder**
([thread 310907](https://forums.cockos.com/showthread.php?t=310907)) automates
building an Airwindows Console rig in REAPER: a SUMMING track, a channel pair
per source, a Console Channel per source pinned to its pair, one Console Buss
on the sum.

**What we take: the topology.** A stage per channel, a stage on the bus, and
the correctness requirement that makes it work — the per-channel stage must
see the level that actually reaches the bus. That requirement is identical
whether the thing being modelled is a console or a drum machine, and §4 is
where all the difficulty lives.

**What we don't: the DSP**, and the invertible-pair maths underneath it (§5).
Airwindows Console is Chris Johnson's; this is EON's own model, so
`THIRD_PARTY_NOTICES.md` gains nothing. The *idea* deserves a credit line in
the JSFX header and the manual, naming both Chris Johnson and the thread.

**What Swing does not need: the SUMMING track and the pin-mapping.** That
apparatus exists because a stock REAPER track has one stereo path and no
post-fader insert. Swing's multi-out build already gives every pad its own
track feeding one parent (`Swing_Kit_Bridge.lua:9888-9925`). The channels are
already discrete. Nothing to wire, no `I_NCHAN` to raise, no pin matrix — and
no doubling of the track count, which matters because
`folder_layout.EnsureSwingParentLayout` and the Drum Matrix both depend on the
folder shape.

---

## 4. The post-fader problem, and Swing's version of it

*(Unchanged by the drum-machine decision — the per-channel stage is
level-dependent either way, so it has the same requirement.)*

The thread's core complaint: the two halves only behave if they sit on the
same gain stage, REAPER has no post-fader insert slot, so you need a dedicated
track whose fader sits between them.

**Swing has this problem in full**, for a non-obvious reason. Under multi-out
with the strip-sync companion alive (`strip_takeover`), Swing hands its per-pad
level *out to REAPER*:

- `rk_swing_core.jsfx-inc:1129,1219` — `_tie_pg = strip_takeover ? 1.0 : p_gain[_lv_pad]`.
  The voice is rendered at **unity**; Swing does not apply the pad fader.
- `EON_Swing_Strip_Sync.lua:452` — `tie_channel(..., "D_VOL", ...)` mirrors the
  mixer fader onto the child track's `D_VOL`. Pan goes the same way to
  `D_PAN` (`:454`), which is why `process_pad_fx` emits centre under takeover
  (`rk_drumkit_fx.jsfx-inc:158-166`).

So the pad fader in Swing's console *is* the REAPER track fader, by design —
the One-Mixer tie. And `D_VOL` is applied **after** the track's FX chain. Any
per-channel stage we insert is therefore pre-fader, and every fader move
detunes the model.

Measured on the proposed curve (§6.1), 1 kHz sine:

| input level | peak gain | h2 | h3 |
|---|---|---|---|
| −40 dB | −0.02 dB | −70.5 dB | −67.2 dB |
| −20 dB | −0.15 dB | −50.7 dB | −47.3 dB |
| −12 dB | −0.38 dB | −43.1 dB | −39.5 dB |
| −6 dB | −0.75 dB | −37.6 dB | −33.9 dB |
| 0 dB | −1.44 dB | −32.7 dB | −28.5 dB |

A 10 dB fader error moves h2 by **9.2 dB relative to the fundamental**. Under
the drum-machine model it is worse than a tone error: the fader also sets how
much current the voice draws, so a mis-levelled channel sags the rail by the
wrong amount and the *pump* is wrong too.

### Three ways out, and the one to take

1. **Own the level in the plugin.** Channel stage carries a LEVEL knob; build
   sets `D_VOL` to unity; users mix on the strip. Exact, and hostile — it
   breaks the One-Mixer tie that Swing's console is built on, and REAPER users
   will reach for the track fader regardless.

2. **Build a summing track per pad, SK-style.** 16 tracks become 32. Rejected:
   it fights `folder_layout`, doubles the TCP, and buys nothing Swing does not
   already have.

3. **Compensate for the fader inside the channel stage.** ✅ **Recommended.**

   ```
   out = E(x · g) / g          g = the track's fader gain (and pan, per side)
   ```

   The track fader then multiplies by `g` downstream, so what arrives at the
   bus is `E(x · g)` — precisely as if the stage were post-fader. The
   nonlinearity and the current draw both see post-fader level; the signal
   level leaving the plugin is untouched, so nothing else in the chain shifts.

   **This is nearly free in Swing, and only in Swing.** `EON_Swing_Strip_Sync`
   already computes `bv` and writes it to `D_VOL` on every tie tick — it is
   the component that *creates* the problem, and it can push the same value
   into the plugin in the same tick. No new polling, no new source of truth.

   Details that have to be right:
   - `g` is smoothed over ~30 ms in the JSFX. A raw jump is a zipper on the
     harmonic content, not the level.
   - Pan → per-side `gL`/`gR`, read from `D_PAN` the same way.
   - Floor `g` (≈ −60 dB) so `/g` cannot explode on a fader at −inf. Below
     the floor the channel is inaudible anyway; clamp and stop compensating.
   - **Graceful degradation:** no companion heartbeat → `g = 1` → the stage
     behaves as a plain pre-fader one. Wrong-ish character, never a failure.
     Same posture as `strip_takeover` falling back when the script dies.

---

## 5. Why not an invertible encode/decode pair

*(Also unchanged — this was never console-specific, and it matters more now:
rail sag is not invertible even in principle.)*

Console's elegance is that its two halves are exact inverses — `sin` and
`asin` — so a single channel through both is bit-transparent, and the entire
effect emerges from summing. It is a lovely trick. It does not survive sixteen
channels.

Measured, 16 uncorrelated channels at −20 dBFS each:

| | peak | rms | crest |
|---|---|---|---|
| linear sum (bus off) | +4.42 dB | −7.97 dB | 12.39 dB |
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

So: **two real stages, not one invertible trick.** Which is also the only
option available once the model is a drum machine, because a shared power rail
has no inverse — the sag genuinely happened.

---

## 6. The model

### 6.1 Channel stage — the voice's output

Signal order inside the CHANNEL instance:

1. **Fader/pan compensation** — `x · g`, per §4.
2. **CAP** — the voice's series coupling capacitor: a first-order highpass,
   default around 10–20 Hz, exposed because on real machines it is often
   higher than you would expect and the resulting low-end phase shift is part
   of the sound. Cheap, one-pole, zero latency.
3. **Voice amp sag** — the output stage, one divide:

   ```
   E(x) = x / (1 + k(x)·|x|)        k(x) = k⁺ for x ≥ 0, k⁻ for x < 0
   ```

   No transcendentals — this runs ×16 — monotonic, bounded, zero state, zero
   latency. `k⁺ = k⁻` gives a pure odd-harmonic curve; splitting them
   introduces the even order that a single-supply stage has. Measured at
   0 dBFS:

   | | h2 | h3 | h4 | h5 |
   |---|---|---|---|---|
   | symmetric (`k±` = 0.30) | −162 dB *(numerical floor)* | −26.7 dB | −192 dB | −41.5 dB |
   | asymmetric (`k⁺`=0.30, `k⁻`=0.18) | −32.7 dB | −28.5 dB | −56.9 dB | −43.6 dB |

   Symmetric is *exactly* odd — the h2/h4 figures are the FFT floor, not a
   small residue. So the asymmetry control is a genuine character switch
   rather than a tilt, and `k = 0` is mathematically identity.

4. **Rail modulation** — apply the current rail droop published by the bus
   (§6.3). This is where the pump lands on *this* voice.
5. **DRIFT** — per-voice component tolerance: a gain offset of a few
   hundredths of a dB and a one-pole HF phase tilt, seeded deterministically
   from `P_EXT:EON_PAD_IDX` so it is stable across sessions and renders. Stops
   sixteen channels sounding like one channel played sixteen times.
6. **Publish** — this voice's current draw (block RMS of `|x|` post-sag) and a
   heartbeat to the link band.

### 6.2 Bus stage — the supply, the network, the output amp

1. **Read total current draw** `L = Σ|Iᵢ|` from the link band.
2. **RAIL** — the sag engine (§6.3). The headline control.
3. **BUS** — passive resistor-network loading: a small, resistive,
   level-dependent interaction between voices. Subtle by nature; it is a level
   effect, not a tone one.
4. **AMP** — the single output op-amp, with its own asymmetry and headroom.
   Sixteen voices through one stage on a modest rail; its clipping is the
   machine's "loud" sound.
5. **TRIM** — output level.

### 6.3 Rail sag — the part that needs both halves

The physical model: one supply feeding every voice, with a reservoir cap.
Total current draw pulls the rail down; the cap recovers it.

- **Depth** ∝ `L = Σ|Iᵢ|` — *total current drawn*, which is deliberately not
  `|Σ Iᵢ|`. Sixteen voices at −20 dB and one voice at −8 dB can hit the same
  bus meter and load the supply completely differently. This is the whole
  reason a side-channel exists.
- **Attack**: effectively instant. It is a rail, not a detector.
- **Recovery**: RC, ~10–80 ms, user-set. This is the pump's length.
- **Applied per channel**, not to the sum. A sagging rail costs each voice
  headroom at *its own* level, so a loud kick pushes the hats into the sag
  differently than it pushes itself. That asymmetry is the sound, and it is
  the reason this cannot be a single gain on the bus.

**This is not EON 76 with extra steps.** They stack, and they do different
jobs:

| | EON 76 | Rail sag |
|---|---|---|
| Detects | level of the sum, `\|Σ\|` | total current draw, `Σ\|I\|` |
| Threshold | yes (−40…0 dB) | none — always proportional |
| Applies | one gain to the summed signal | per-voice headroom loss |
| Recovery | release curve, 10–1000 ms | capacitor RC |

EON 76 can reach a 0.1 ms attack (`slider3`), so this is not purely a speed
argument. The real difference is *what is measured* and *where it is applied*.

**The latency problem, stated honestly.** The rail state is computed at the
bus (it needs the total) but applied at the channel (it needs per-voice
level). That is a loop across plugin instances, and gmem gives us one block of
latency. At 128 samples that is 2.7 ms — fine against a 30 ms recovery. At
1024 it is 21 ms, and the sag would arrive after the transient it belongs to.

Resolution: **split the model by time constant.**
- The instantaneous droop is applied **at the bus**, on the sum, where it costs
  no latency.
- The recovery tail is applied **per channel** via the band, where being one
  block late against a 30 ms envelope is inaudible.

Block-size sensitivity still needs measuring across 64–1024 (§9).

### 6.4 Console mode

The console topology is one slider away, and worth keeping: it is the same
architecture with the rail engine off, the summing behaviour switched from
passive-resistive to active virtual-earth, and the per-channel stage retuned.
Some users will be putting Swing's drums into a live-kit mix where console
glue is what they want.

Secondary, though. It is the alternate voicing, not the product.

### 6.5 The side-channel contract

The link band is the only cross-instance dependency, and it is deliberately
weak:

- It carries a **coefficient**, never a sample. A stale or missing value
  produces a slightly different tone or a slightly different pump. It can
  never click, drop out, or diverge.
- **Fallback:** band stale (no heartbeat within N blocks) → derive `L` from
  `|Σ|` of the received audio and apply the whole rail model at the bus.
  Degrades to a good, if less characterful, drum bus.
- Offline render and freeze work because of that fallback, not in spite of it.

Precedent already ships: `EON_FX_Return_View.jsfx` reads the per-instance
strip band to show which pads feed a bus, with `link_slot` pushed by the
strip-sync companion, and `EON_76.jsfx` runs a param-echo + command band
(`GS_BC_LINK`, 26170000–26171535) entirely in `@block`.

### 6.6 Who owns the parameters

The bus is the machine; the channels are its voices. One set of controls,
sixteen satellites.

But **the serialized sliders are canonical, not gmem.** The bus writes a
change to the band for live feedback *and* the sync companion pushes it into
all sixteen channel instances' sliders by param name (exactly how
`set_fx_returns` and `EON_Swing_Strip_Sync`'s `pmap` already work). A render
must be bit-reproducible from the project file alone, with no script running
and no gmem. gmem is the live-edit convenience path; the project is the truth.

---

## 7. Placement

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

- **Channel stage last in the pad chain**, after `EON_Drum_Strip`. The strip's
  `slider20 strip_out_db` (Output Trim) is then upstream, which is correct: it
  is part of the voice's level, and it should therefore affect current draw.
- **Returns get a channel stage too.** They are voices on the same bus in
  every meaningful sense, and they draw current like everything else.
- **Bus stage before EON 76** on the parent — finish the machine, then glue it.

---

## 8. Build integration

All of this rides the existing path — `rk_ops.do_build_multiout`
(`Swing_Kit_Bridge.lua:9494`):

- **Dialog** — a fourth checkbox in "Drum Bus Options": *Drum machine bus
  (EON Sum)*. `proceed_build(want_returns, want_buscomp, want_stepseq, want_sum)`.
  Ripples to three call sites: the `opts.fx_returns` programmatic path, the
  preserve path, and the no-ReaImGui `ShowMessageBox` fallback.
- **Preserve on rebuild** — `have_sum`, detected by scanning `audio_sub` for
  "EON Sum", mirroring `have_buscomp`. A Rebuild must not silently drop the
  user's bus, and must not re-ask.
- **Insertion** — `ensure_sum(tr, mode, ch)` modelled on `ensure_eon76`:
  find-or-insert, set defaults by param name, leave an existing instance
  alone. Unlike `ensure_eon76`, **no `core.fx_embed_mcp` on the channel
  instances** — the pad track's MCP embed is already the Drum Strip
  (`EON_Swing_Strip_Sync.lua:327`), and pad tracks are 28 px. Only the BUS
  instance embeds.
- **Sync companion** — the fader/pan compensation and the parameter push
  belong in `EON_Swing_Strip_Sync.lua`, in the tie tick that already writes
  `D_VOL`/`D_PAN`. New file only if that one is already at its local budget.

---

## 9. UI

- **BUS** — a faceplate deck in the `EON_FX_Return_View` idiom: sixteen
  current-draw bars showing which voices are pulling the rail down (pad names
  and colours come free from the strip band), a rail-droop needle on
  `vu_kbsg` — a *falling* needle, which is the right visual for a supply
  sagging — and the controls: RAIL depth, RECOVERY, BUS, AMP, CAP, DRIFT,
  TRIM. `rk_theme` chip, so it follows the suite's fourteen themes.
- **CHANNEL** — effectively headless. A nameplate and a draw LED. No embed,
  minimal `@gfx`.
- One file, `Swing/EON_Sum.jsfx`, with a `MODE` slider (CHANNEL/BUS). Two
  files could version-skew between deploys; the two halves of one machine must
  not. One entry in `index.xml`, one deploy.
- Naming: **EON Sum**, `desc:EON Sum — Drum Machine Bus`. Fits EON 76 / EON
  Lens / EON Smash. *(Alternatives: EON Rail — which names the actual
  mechanism — or EON Bus.)*

---

## 10. Risks and open questions

| | |
|---|---|
| **Block-size sensitivity** | New with the rail model. The per-channel half of the sag is one block late; at 1024 samples that is 21 ms against a 30 ms recovery. The §6.3 time-constant split should cover it — must be measured at 64 / 128 / 256 / 512 / 1024 before this ships. |
| **Pump can be cheesy** | Rail sag overdone is just a badly-set compressor. Defaults must be subtle, and the honest test is whether anyone can hear it at sane settings — which is exactly what build steps 1–2 exist to answer. |
| **CPU ×16** | The curve is one divide, but sixteen JSFX instances are not free even hidden. Channel instances get `no_meter` and no `gfx_idle`; only the bus deck redraws. Needs measuring on a real kit. |
| **PDC** | Must be zero, hard constraint — same reason the Drum Strip documents it. No lookahead, no oversampling, no `pdc_delay`. |
| **gmem band** | Proposal: `26180000`, above `GS_BC_LINK`'s 26170000–26171535. **Must be verified against `.refs/swing_gmem_bridge_protocol.md`, `.refs/gmem_regions_supplement.tsv` and `EON/.Extension/src/gmem/*.h` before use** — none are in this checkout, and the house rule is a full-bundle sweep before claiming a range. The band is now bidirectional (draw up, rail down), so it needs more room than the original estimate. |
| **Multi-instance** | Two Swings = two Audio buses = two independent machines with independent rails. Link rows must key on the registry slot, as EON 76 does; a broadcast cell would cross-wire them — and with a rail model that means one kit's kick ducking another kit's hats. |
| **`strip_takeover` off** | No companion → no `D_VOL` mirroring → the pad fader is back inside Swing → compensation should be *disabled*, not defaulted to 1. The channel stage needs to know which regime it is in, not just what `g` is. |
| **Stray track in the folder** | Benign, but the bus deck can spot it: compare Σ of published draw against received audio and light an advisory. |
| **Frozen pad tracks** | A frozen track keeps its FX chain baked; the bus then sees an already-processed signal with no live heartbeat, and that voice's current draw vanishes from the rail. The fallback covers it — worth an explicit test. |

---

## 11. Suggested order of work

1. **`EON_Sum.jsfx`, BUS mode only**, no side-channel — rail driven from
   `|Σ|` of the sum. Drop it on the Audio parent by hand. Auditionable in an
   afternoon, and it settles whether the pump is musical before any plumbing
   exists.
2. **CHANNEL mode**, inserted by hand: CAP, voice sag, current publish, and
   the per-channel half of the rail. A/B against step 1 — this is the
   experiment that proves per-channel application is worth sixteen instances.
   **If it is not audibly better than step 1, stop and ship step 1 alone.**
3. **Fader compensation** in the sync companion. Verify against §4: sweep a
   pad fader and confirm both the harmonic signature and the pump depth hold
   still.
4. **Link band** — publish, rail state, deck metering.
5. **Build integration** — the fourth checkbox, `ensure_sum`, preserve.
6. **DRIFT, BUS network, console mode**, last. Seasoning, and the easiest to
   overdo.

Steps 1–2 answer the only question that actually matters, and neither
requires touching `Swing_Kit_Bridge.lua`.

---

*Figures in §4, §5 and §6.1 are measured, not estimated — 64 k FFT at
192 kHz, Hann window; 16-channel test at −20 dBFS uncorrelated noise per
channel. The rail model is not yet measured; it is designed, and step 1
exists to test it.*
