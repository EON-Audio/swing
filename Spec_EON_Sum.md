# Spec — EON Sum (the summing box)

**Status:** design, no code written.
**Scope:** a summing stage in two circuits (**drum machine** and **console**)
and two hosts (a **Swing feature** and a **standalone box**), from one
plugin. EON's own DSP.
**Companion docs:** `Spec_EON_Lens.md`, `.refs/swing_gmem_bridge_protocol.md`
(neither is in the package checkout — this doc belongs beside them).

> **Rev 5** — ⚠️ **TAM's source read; it is proprietary (§3.6).** "All rights
> reserved… creating derivative works is prohibited." Implement from the
> physics, never from that file; the git history already proves independent
> derivation and must not be rewritten. Reading it also sharpened the
> competitive picture: **TAM's rail modulates only the slew-limiter
> threshold** — the headroom half of a sagging supply is unmodelled, which is
> the more audible half on drums (§3.2, point 2). That is now the strongest
> reason to build this, and the first one that is about the sound rather than
> the workflow.
>
> **Rev 4** — ⚠️ **prior art found (§3.1).** Punchipum's *The Analog Molecule*
> already ships the shared-power-rail mechanism, free, mature, eight months of
> development. The DSP idea is not novel and this spec no longer claims it is.
> What survives is integration, post-fader load, the drum-machine circuit and
> per-instance isolation (§3.2) — enough for a Swing feature, not enough for a
> standalone product, so the box is demoted from staged to unlikely (§3.3).
> TAM's bug history is taken wholesale as a test plan (§3.4).
>
> **Rev 3** — both circuits and both hosts are now in scope (§2). They are one
> codebase: the circuit switch changes which cross-channel mechanism is live,
> and the host difference is *only* the identity layer. One thing has to be
> decided now rather than later — generalizing that identity layer from the
> first commit (§2.3). Shipping order stays staged (§2.4): the switches exist
> from day one, the second voicing and second host ship when they earn it.
>
> **Rev 2** — the model was originally console summing, seeded by the forum
> thread. Changed to lead with the drum-machine circuit: Swing is a drum
> machine, and the two bus topologies are genuinely different. The
> architecture, the post-fader analysis (§4) and the rejection of an
> invertible pair (§5) were never console-specific and are unchanged.

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

## 2. Two circuits, two hosts, one codebase

Two independent axes, and it is worth keeping them apart:

| | | |
|---|---|---|
| **Circuit** | `MACHINE` — shared supply rail | `CONSOLE` — active virtual-earth summing |
| **Host** | Swing feature — built by the multi-out builder | Standalone box — works on any tracks |

Four combinations, one plugin, one band protocol. Both axes are worth having,
and they cost very different amounts (§2.4).

### 2.1 The circuits

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

#### Why MACHINE leads

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

`CONSOLE` is not a downgrade, it is a different mechanism — active summing,
almost no rail interaction, inter-strip crosstalk instead. Some users are
putting Swing's drums into a live-kit mix where that is exactly what they
want, and the standalone box (§2.2) is *mostly* going to be used on
non-drum material.

**How much of the plugin is shared?** Nearly all of it:

| Shared by both circuits | `MACHINE` only | `CONSOLE` only |
|---|---|---|
| Fader compensation (§4) | Rail sag engine | Virtual-earth bus loading |
| Voice/channel sag curve (§6.1) | Passive resistor-network loading | Inter-strip crosstalk (BLEED) |
| CAP, DRIFT, AMP, TRIM | | Wider DRIFT |
| Band protocol, identity, UI shell | | |

So the circuit switch changes *which cross-channel mechanism is live*. It is
an honest switch between two real topologies, not a flavour knob — and the
marginal DSP work for the second one is small.

### 2.2 The hosts

The standalone box is the same plugin with a different setup path. What
actually differs is **only the identity layer** — four bindings:

| | Swing feature | Standalone box |
|---|---|---|
| Group id | Swing's instance registry slot (`GS_INST_REG`, 16 slots, heartbeat-keyed) | allocated from a free pool at build, stamped on the tracks |
| Channel index | `P_EXT:EON_PAD_IDX` | assigned at build, stamped `P_EXT:EON_SUM_CH` |
| Fader / pan for §4 | pushed by `EON_Swing_Strip_Sync`'s existing tie tick — free | a small generic poller reading `D_VOL`/`D_PAN` per member track |
| Deck names + colours | pad names and colours from the strip band | track names and colours from the poller; falls back to numbers |

Everything below the identity layer — the DSP, the band protocol, the
faceplate, the theme, the metering — is identical.

#### The standalone box beats the thread's script, for free

studiokozak's builder has to create a SUMMING track per source group to get a
post-fader position. Ours does not: it reads the fader and compensates (§4).
So the standalone builder creates **no tracks at all** — select some tracks,
it inserts a channel instance on each and a bus instance on their destination,
stamps the group, done. No pin-mapping, no `I_NCHAN`, no track-count
explosion, and it works on a folder you have already built.

That is the product pitch, and it falls straight out of the work §4 already
requires.

### 2.3 The one decision that has to be made now

**Generalize the identity layer from day one**, even while only the Swing path
ships.

Group id, channel index, and the fader/pan source should be *inputs* to the
plugin from the first commit, with Swing's registry slot and `EON_PAD_IDX` as
one implementation of them. That costs almost nothing now — three sliders and
a lookup instead of two hard-coded reads.

Retrofitting it later is the expensive path: identity threads through the band
protocol, the deck's data source, the fader compensation, and every
`ensure_*` call site. Doing it Swing-specific and generalizing in a second
pass means touching all of that twice.

Everything else can be deferred safely. This cannot.

### 2.4 Shipping order

Both axes in the architecture from the start; **not both shipped at once.**

The bottleneck on a nonlinear model is not the code, it is the listening —
tuning until it sounds right is where the weeks go. Two circuits doubles that
work, and a half-tuned `CONSOLE` sitting next to a well-tuned `MACHINE` makes
the product look worse, not better. Same for the hosts: the Swing path already
has a builder to hang off, the standalone one needs a new script and a new
poller.

So:

1. `MACHINE` + Swing — the DSP proves itself where the plumbing already exists.
2. `CONSOLE` — ships when it is actually tuned, not when it compiles.
3. ~~Standalone box~~ — **demoted in rev 4 (§3.3).** TAM already occupies that
   market, free. Keep the identity layer generic anyway (§2.3), but do not
   plan a release around it.

The switches exist from commit one. Nothing gets retrofitted; the second
voicing ships when it earns it.

### 2.5 What we do *not* do

- **No named machine.** Model the class of circuit, not a specific product.
  Controls are named after what they physically are — RAIL, CAP, AMP — not
  after a machine. This is also the safe side of the licensing pass, and
  consistent with the decision to rename the brand-styled knob themes.
- **No converter or bit modelling.** The Drum Strip already owns crush and
  drive. Duplicating them here would be two stages fighting over the same
  sound.
- **No third "CLEAN" circuit.** `k = 0` with the rail off is already
  mathematically identity (§6.1) — it is a position on the existing controls,
  not a mode.

### 2.6 Packaging — your call, not mine

The ReaPack index currently ships **one package**, `Swing_ReaKit.jsfx`, with
every file as a `<source>` under one `EON/Swing` category. Two options:

- **Both in the Swing package** *(simplest)*. `EON_Sum.jsfx` plus both builder
  scripts ship together. The "summing box" is then a Swing-package feature
  that happens to work on any tracks. One file to maintain, no ReaPack
  collision, and every Swing owner gets it.
- **Split into the FX-suite index** *(if it needs to sell separately)*. Then
  the JSFX lives in one index and the other depends on it — two packages must
  never provide the same file path, or ReaPack conflicts. Swing must not be
  made to depend on the FX suite, so the JSFX would have to ship from Swing
  and the FX suite reference it, or ship twice under different filenames.

Technically the first is clearly better. Whether the box is a separate product
is a business question and yours.

---

## 3. Prior art

> ## ⚠️ Licence first — read §3.6 before writing a line of DSP
>
> TAM's source header reads *"All rights reserved. Modification, copying,
> redistribution, or creating derivative works is prohibited."* It is **not**
> open source. Its source has been read in this project's history; the posture
> that keeps us clean is in **§3.6**, and it is not optional.

### 3.1 The Analog Molecule — the rail idea is already shipping

**Read this before writing any code.** Punchipum's *The Analog Molecule*
(TAM), [thread 315xxx, Dec 2025 → v4.5](https://forums.cockos.com/showthread.php?t=310907),
free on ReaPack, twelve pages of thread, active development for eight months
— already implements the headline mechanism in §6.3:

> *"When a Kick drum hits hard on Channel 1, it draws current from the global
> rail. The instance on your Vocal track (Channel 20) 'feels' this energy
> demand. The voltage doesn't drop instantly; it 'sags' with a natural,
> organic inertia, just like a real capacitor discharging."*

It is a shared-gmem power rail across up to 180 instances, with per-instance
seed IDs for phase decorrelation (our DRIFT), a global crosstalk network (our
BLEED, but shared rather than local), Channel / Bus / Master topologies (our
MODE), and two engines. Users compare it favourably to Sonimus and N-Console.

**So the mechanism is not novel, and the spec should stop implying it is.**
If the pitch for EON Sum is "shared power rail glue", we are second to market
behind a free, mature, well-liked plugin.

### 3.2 What actually survives as differentiation

Ranked honestly, strongest first:

1. **It is already set up, and set up correctly.** TAM's quick-start asks the
   user to place an instance on every track, set the topology per track,
   guarantee exactly one Master, and press *Reshuffle All IDs* after any
   track duplication. Swing's builder does all of that from one checkbox, and
   channel identity comes from `P_EXT:EON_PAD_IDX` — a real, stable fact about
   the track — rather than a random seed that collides on copy. That is the
   difference between a checkbox and twenty minutes of admin, and it is
   something no general-purpose plugin can offer.
2. **TAM's rail moves slew rate, not headroom.** From the source: the network
   value is smoothed into `buffered_rail`, converted to `shared_sag =
   1/(1 + buffered_rail·0.04)`, and that term is used in exactly one place —
   scaling the Interstage slew-limiter threshold. Nothing else in the audio
   path reads it.

   That is a real and defensible model: an amplifier's slew rate is set by
   available current, so a sagging rail does slow it down. But a sagging rail
   *also* costs output swing, and **that half is unmodelled.** Our §6.3 —
   per-voice headroom loss at each voice's own level — is not a re-tread of
   TAM's rail; it is the component TAM leaves out, and on drums (huge
   transients, small supply) it is the more audible half.

   This is the sharpest differentiation on the list, and the only one that is
   about the *sound* rather than the workflow.

3. **Post-fader load.** TAM instructs first-insert placement, which is the
   most pre-fader position there is. That is defensible for the channel's
   *input* electronics, which genuinely sit before the fader and draw what
   they draw. But the *summing bus* is loaded by post-fader current, and in a
   drum machine the level pot sits between the voice and the mix bus — so
   post-pot is the physically correct place to measure draw. Pull a fader
   20 dB in TAM and that channel still loads the rail identically. §4's
   compensation is what fixes that, and it only works because
   `EON_Swing_Strip_Sync` already knows the fader value.
4. **A different circuit.** TAM is explicitly large-format console — 180
   channels, ribbon cables, transformer bus. Nobody is modelling a drum
   machine's mix bus: sixteen voices, one small supply, a passive resistor
   network. Real, but be honest that much of the difference is tuning —
   time constants and depth — not topology.
5. **Isolation that already works.** TAM's documented fix for REAPER sharing
   gmem across project tabs is *duplicate the .jsfx file and rename its gmem
   namespace by hand*. Swing already has a heartbeat-keyed instance registry
   and targeted (not broadcast) commands, so per-instance isolation is
   existing machinery rather than a user-facing wart.

### 3.3 What this kills

**The standalone box, mostly.** §2.2 pitched it as beating studiokozak's
script by creating no tracks. That is still true, but it would ship into a
market where TAM is free, mature, handles 180 channels, and has an audience.
Competing there on the same mechanism is a bad trade.

The Swing-integrated feature is barely affected: it competes on integration
and correctness, not on having the idea. **Revised recommendation — build the
Swing feature; treat the standalone box as unlikely, not staged.** Keep the
identity layer generic anyway (§2.3): it is still cheap, it still buys
per-instance isolation, and it keeps the door open.

Also worth checking before shipping: a user may run **both**. TAM on the drum
tracks plus EON Sum on the same tracks is two rail models stacking. Not our
bug, but worth one line in the manual. Namespaces do not collide —
TAM is `gmem=AnalogMoleculeHybrid`, Swing is `gmem=Swing_Media_Transfer`
(verified).

### 3.4 Eight months of TAM's bugs, for free

TAM's changelog and thread are a map of where this class of plugin breaks.
Taking all of it:

| TAM's problem | What we do |
|---|---|
| **gmem is shared across project tabs** — two open projects sum each other's crosstalk and rail. Fix is a manual file-duplicate-and-rename. | Key every band row on the instance registry slot, and scope the rail to the group, never the namespace. Cross-tab is a harder case than the multi-instance one already in §10 — two *projects*, not two Swings. Must be tested with two tabs open. |
| **Duplicate IDs on track copy** — needs a *Reshuffle All IDs* button. | `P_EXT:EON_PAD_IDX` copies with a duplicated track too, so we have the same bug in a different coat. The bus must detect two channels claiming one index and re-stamp or refuse, without a user-facing button. |
| **v3.4 shifted slider indexes**, silently changing old sessions. The author had to tell users not to update mid-project. | Already immune: the house resolves params by name (`EON_Drum_Strip.jsfx:23` — *"slider names are stable API — do not rename casually"*), and `EON_Swing_Strip_Sync` maps by label. Keep that discipline and never renumber. |
| **Global crosstalk is the CPU hog** — several users report spikes; one had it lock up. | Field evidence for the choice already in §6.4: keep BLEED *local* (per-channel L↔R) rather than a shared crosstalk bus. The expensive version is the one that bites. |
| **Three separate render bugs** (v2.9 stuttering, v3.3 offline full-speed phase error, v4.5 XT on render). | This is exactly where a gmem-coupled audio path fails, and it validates §6.5: sliders canonical, gmem a convenience, always a local fallback. Offline render must be tested first, not last. |
| **Auto-bypass on silence** materially helps CPU. | Worth doing for the sixteen channel instances — the idea, not the implementation (§3.6). |
| **Rail decay depends on one instance existing.** The accumulator is decayed only by the Master (`t_topo == 2`); channels only ever add to it. With no Master placed, nothing appears to decay — the UI warns, but the audio path still reads the value. | **Never make decay the property of one instance.** Our bus owns the rail, but the accumulator must self-decay (timestamped, or decayed by whoever reads it) so a missing, bypassed, muted or offline bus degrades to "no sag", never to a runaway. This belongs in the §6.5 fallback contract. |
| **Denormals** needed a dedicated pass (v2.5) to stop CPU spikes in silence. | Flush every filter and envelope state. Cheap to do from the start, tedious to retrofit. |

**One implementation note worth carrying over**, and it is a documented JSFX
primitive rather than anything of theirs: cross-instance accumulation must use
`atomic_add()`, not `gmem[x] += y`. Sixteen instances on different threads
summing current draw is exactly the race that needs it.

---

### 3.6 Licensing — the constraint on how we build

**TAM is proprietary.** Its header:

> `Copyright (c) 2025 DocShadrach — All rights reserved.`
> `Licensed for use inside REAPER for personal or professional projects only.`
> `Modification, copying, redistribution, or creating derivative works is prohibited.`

(It embeds Airwindows *Interstage* and *Console9* under MIT, credited to Chris
Johnson — so the MIT parts are MIT wherever you get them from Airwindows
directly. The wrapper, the network architecture and everything else in that
file are not.)

Its source has been read in the course of this design. That is not a problem
in itself — reading a competitor is normal — but it changes what "careful"
looks like from here.

**The posture:**

1. **Implement from the physics, not from that file.** Rail sag is how power
   supplies behave; it is not anyone's property. A specific implementation
   is. Do not open TAM's source while writing `EON_Sum.jsfx`, and do not
   transcribe its constants, its structure, its gmem layout or its
   variable-for-variable shape.
2. **The git history is the evidence, and it is good.** `a9dea44` — *"Spec
   rev 2: model a drum machine's mix bus, not a console's"* — designed the
   shared-rail model, the sag curve and the `Σ|I|` side-channel **before** TAM
   was known to this project. `1c0912c` records the moment it was found, and
   this section records the source being read. That ordering is worth
   preserving; do not rewrite it.
3. **Airwindows is a legitimate source, TAM is not.** If any Console-family
   maths is ever wanted, take it from Chris Johnson's MIT releases directly
   and credit it in `THIRD_PARTY_NOTICES.md` in the house style — never
   second-hand through TAM's file.
4. **What §3.4 takes is behaviour, not code.** "Denormals need flushing",
   "decay must not depend on one instance", "test offline render early",
   "crosstalk is the CPU hog" are observations about how this class of plugin
   fails. Facts about behaviour are not derivative works. Their solutions to
   those problems are theirs.
5. **`atomic_add`, double-buffering and false-sharing padding are standard
   technique**, documented in the JSFX reference and general concurrency
   practice. Using them is not copying; copying their specific cluster/bank
   arithmetic would be.

None of this is legal advice, and if EON Sum ever ships commercially it is
worth ten minutes of someone who does give legal advice.

---

### 3.7 Where the builder idea comes from

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

### 6.4 CONSOLE circuit

Same architecture, different cross-channel mechanism (§2.1): rail engine off,
summing switched from passive-resistive to active virtual-earth, plus
inter-strip crosstalk (BLEED) — a 6 dB/oct HF-tilted L↔R leak in the −60 dB
region, which is the dominant real crosstalk term and the cheapest to place
honestly. DRIFT runs wider, because a console's channels are further apart in
component tolerance than sixteen voices on one board.

Bus loading here replaces rail sag: a console's summing amp holds its node
near zero volts, so channels barely interact through it. What remains is the
node's finite transimpedance under load — much subtler than a rail sag, and
correctly so.

Ships second (§2.4), when it is tuned.

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
- **Deck data source** — pad names and colours come free from the strip band
  under Swing. Standalone, the poller pushes track names and colours; with
  neither, the deck falls back to channel numbers and still works. The
  faceplate never depends on identity being resolvable.
- One file, `Swing/EON_Sum.jsfx`, carrying both axes as sliders: `MODE`
  (CHANNEL/BUS) and `CIRCUIT` (MACHINE/CONSOLE). Two files could version-skew
  between deploys; the two halves of one machine must not. One entry in
  `index.xml`, one deploy.
- Naming: **EON Sum**, `desc:EON Sum — Summing Box`. Fits EON 76 / EON Lens /
  EON Smash, and stays accurate across both circuits — which a
  drum-machine-specific name would not. *(Alternative: EON Rail, which names
  the MACHINE mechanism but mis-sells CONSOLE.)*

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
| **Two project tabs open** | ⚠️ **The one TAM could not solve cleanly (§3.4).** REAPER shares gmem across the whole application, so two projects each holding a Swing will sum into each other's rail unless every band row is registry-slot-keyed and the rail is scoped to the group. TAM's answer is telling users to duplicate the plugin file by hand. Ours must not be. Test with two tabs before anything else. |
| **Duplicated pad track** | `P_EXT:EON_PAD_IDX` copies along with the track, so two channels claim one index — the same bug TAM needs its *Reshuffle All IDs* button for. The bus detects the collision and re-stamps or refuses; no user-facing button. |
| **Group id collision** | Only if the standalone host is ever built (§3.3). Two allocators must not hand out the same id, or one console's kick ducks another's hats. One allocator, one claim protocol, heartbeat-expired slots reclaimed. |
| **Tuning cost, not code cost** | The real budget for a second circuit is listening, not implementation (§2.4). Ship `CONSOLE` when it is tuned. A half-voiced second mode is worse than no second mode. |
| **Standalone poller cost** | The Swing path gets fader compensation free off an existing tick. The standalone one needs its own timer polling `D_VOL`/`D_PAN` per member track. Cheap per track, but it is a new always-running script — it needs the same heartbeat-and-die discipline as the strip sync. |

---

## 11. Suggested order of work

Both axes are in the architecture from step 1. Only one combination ships at
a time (§2.4).

1. **`EON_Sum.jsfx`, BUS mode, MACHINE circuit**, no side-channel — rail
   driven from `|Σ|` of the sum. Drop it on the Audio parent by hand.
   Auditionable in an afternoon, and it settles whether the pump is musical
   before any plumbing exists.
2. **CHANNEL mode**, inserted by hand: CAP, voice sag, current publish, and
   the per-channel half of the rail. A/B against step 1 — this is the
   experiment that proves per-channel application is worth sixteen instances.
   **If it is not audibly better than step 1, stop and ship step 1 alone.**
3. **Identity layer, generic** (§2.3) — group id, channel index and fader/pan
   as plugin inputs, with Swing's registry slot and `EON_PAD_IDX` as the first
   implementation. Do this before the band, not after: it is what the band
   keys on.
4. **Link band** — publish, rail state, deck metering. Sized for N groups × M
   channels from the start, not 1 × 19.
5. **Fader compensation** in the strip-sync companion. Verify against §4:
   sweep a pad fader and confirm both the harmonic signature and the pump
   depth hold still.
6. **Swing build integration** — the fourth checkbox, `ensure_sum`, preserve
   on rebuild. *Ship here: `MACHINE` + Swing is a complete product.*
7. **DRIFT and the passive bus network** — seasoning, easiest to overdo.
8. **`CONSOLE` circuit** — the second cross-channel mechanism. Ships when
   tuned, not when it compiles.
9. ~~Standalone box~~ — demoted (§3.3). Only if there is a reason to compete
   with TAM head-on, which there currently is not.

**Before step 1**, sit with TAM for an evening. It is free, it ships the
mechanism, and the honest question this spec now has to answer is not "does
rail sag work" — it does, TAM proves it — but **"is the built-in, correctly
levelled, drum-tuned version enough better than a free plugin the user could
just install?"** If the answer is no, that is worth finding out in an evening
rather than after step 6.

Steps 1–2 answer the only question that actually matters, and neither
requires touching `Swing_Kit_Bridge.lua`. Step 3 is the cheap-now,
expensive-later one.

---

*Figures in §4, §5 and §6.1 are measured, not estimated — 64 k FFT at
192 kHz, Hann window; 16-channel test at −20 dBFS uncorrelated noise per
channel. The rail model is not yet measured; it is designed, and step 1
exists to test it.*
