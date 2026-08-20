# What's new in Swing 3.0

*For everyone running 2.1.6 · EON Studios*

Your last update was 2.1.6, back in May. This one is bigger than everything
since launch put together — every pad can be a synth now, and you get four more
plugins besides Swing itself.

Here's what actually changes when you open it.

---

## Every pad can now be a synth

Alongside its sample layers — or instead of them — each pad carries a
synthesised drum voice. Nine families, thirty voice types: kicks, snares, hats,
claps, toms, rides, rims, cowbells, shakers.

These are ported from hardware-measured references, not approximated, so the
classic voices behave the way the machines they came from actually behaved.

A synth pad is a full pad. It plays from MIDI and the sequencer, takes the
per-pad EQ, FX, chokes and sends, saves into kits, and undoes normally.

There's a dedicated editor for it, with a 3D drum above the controls that moves
as you tune it and responds to how hard you hit it.

## Your pad grid became a workspace

The grid now doubles as a full-window canvas. Mapping (a piano-roll note map
with a proper choke lane), Colors, Outputs, Kits and the Synth editor — plus the
mixer console and full-size EQ, delay, reverb and compressor pages.

All ten views bind to keys and toolbar buttons — plus an action that closes
whichever is open.

## Play a pad across the keyboard

Give a pad a key range and it plays melodically across the keys instead of on
one note. The range is stored relative to the pad's own note, so it survives a
kit change — load a new kit and your playable pad is still playable.

Tempo-repeat follows the key you're actually holding, so held-note rolls track
the melody instead of hammering the pad's root.

Key ranges work in Repitch today. Tuned and Stretch are still to come, and Swing
says so in the range editor rather than leaving you guessing.

## Run as many Swings as you like

Each instance keeps its own pitch state, mute/solo, colours and note names, and
stays in sync with the Drum Matrix both ways. No cross-talk.

## Ctrl+Z can't wipe a kit any more

Swing has its own undo engine now — parameter, structural and full-kit — pulled
out of REAPER's global undo.

---

## Four plugins you didn't have

2.1.6 installed one thing: Swing. This release installs five.

### Step Sequencer

A full step sequencer built for Swing, not bolted on.

- **Groove system** — swing and groove engine with `.rgt` import *and* export,
  plus groove import straight from a MIDI file
- **824 factory patterns in a browser organised by role** — main, fill, build,
  break, perc — with genre chips and live counts
- **Song mode** — named arrangements that switch at the play-next boundary

### Drum Matrix

Your patterns as a grid in the arrange window, working directly on REAPER MIDI
items rather than a private format.

- **Live two-way sync with the sequencer** — a region is a pattern, edit either
  end and the other follows, ratchets included
- Lanes carry your pad names, colours and icons straight through from Swing
- Role-based remapping, so a pattern aimed at one kit lands sensibly on another

### EON Drum Strip

A standalone channel strip — the per-pad chain as its own plugin, and a full
embedded track/mixer view. SSL-style knobs, EQ graph, gain-reduction meter,
HPF/LPF nodes and VU-face selectors. One strip can broadcast its layout to the
others so a whole kit's strips match in one move.

There's an **FX Return View** too — hardware-faceplate return monitors, the
EON 480 reverb and EON H9 delay decks, with every contributing pad's send on
a fader.

### EON Lens

A kit-artwork card for the track panel. Your kit's cover, living on the track,
pulsing with the audio. A kit without a cover gets a generated monogram, so
the card never sits blank.

### Per-pad FX and multi-out returns

Inside Swing: a dedicated FX panel per pad with an interactive EQ graph, plus
opt-in delay and reverb **return outputs** for multi-out rigs, and per-pad send
knobs on the Drum Strip.

New alongside them: **EON 76**, a bus compressor with a real gain-reduction
needle. Multi-out can drop one on your drum bus for glue, and one always
drives the new **Smash** return — parallel compression on a fader, fed by a
per-pad SMASH send sitting next to DLY and RVB.

---

## Kits, look and feel

### Kit artwork

Kits now carry a cover image inside the `.swing` file itself, so it travels with
the kit wherever the kit goes. Drag an image onto the KIT tab tile to attach
one. All thirteen factory kits ship with machine-portrait covers, and a kit
without one draws a matching vector portrait instead of sitting blank.

### Kit categories, with LOCK and ADAPT

Each pad carries a category glyph in place of its number, picked from a grid of
46. **LOCK** keeps a pad exactly as it is through kit loads. **ADAPT** re-aims
your existing patterns at the new kit rather than leaving them pointing at the
old one, and a change map shows you what moved.

### Themes, knobs and icons

14 console themes and 18 knob styles, and the Lua panels now draw the
same knobs as the plugin so nothing looks bolted on. The icon system was reworked
to 46 solid-silhouette categories with hue-tinted variants that follow your pad
colour out to track colours and sequencer lanes.

### SFZ and RS5k

Self-contained **SFZ export** — the WAVs travel with the kit — with import
fidelity for tune, volume, pan and note. Plus a two-way **RS5k converter** that
handles velocity, round-robin and containers.

---

## Everyday things that got better

- **Sweeping the EQ is silent.** The whole EQ path moved to state-variable
  filters, with a new Hi-Mid band and a Q wheel per bell.
- **The tune knob responds immediately**, and velocity-layered pads now pitch
  every layer correctly.
- **Drag samples straight onto pads** — including onto a Swing embedded in the
  track panel or mixer. Multi-file drags fill consecutive pads.
- **When samples go missing, Swing helps.** You get a banner offering to relink
  the folder, instead of silent pads.
- **Pads no longer come back blank** when you reopen a project.
- **A save-corruption bug when cloning a pad or track is fixed.** If you have
  ever cloned a Swing track, this one matters.
- **Controller note-map presets** — 16 of them, covering MPC, Maschine,
  Launchpad and Push — plus a MIDI-learn mode that steps through the pads so you
  can map a controller in one pass.
- **Chop a selection straight onto pads**, from the action list or the LOAD
  right-click menu.
- **Embed audio: Auto, Always or Never.** Decide whether pad audio is written
  into the project file — small projects, or self-contained ones.
- **New Song** lays out tempo, four named regions, a Swing track, a MIDI item
  per region and the drum lanes, in one action. There's an **Install / Refresh
  Toolbar** action too.

The full list is in the release notes.

---

## Things that moved — read this bit

These are the changes most likely to have you hunting for something.

- **The four vintage-machine sample kits from 2.1.x are gone.** They're replaced
  by eleven Vintage Synth kits and two sampled 808 kits. The synth kits cover
  the same ground with fully editable voices. **Your own kits are untouched** —
  the installer never removes your content.
- **"Load Kit (.swing)" is no longer in the LOAD right-click menu.** Left-click
  LOAD now opens the Kits view, and loading a kit file lives there.
- **Swing deletes its own unsaved scratch audio after 30 days.** Pad audio that
  was never saved into a kit or project, and hasn't been touched in a month, is
  removed so the store doesn't grow forever. It never touches kits, projects or
  your own sample files — but it does delete from your disk, so it's worth
  knowing.
- **Tuned and Stretch need the EON engine.** Repitch is pure JSFX and needs
  nothing extra. Without the engine, both play back as Repitch — and Swing
  tells you so rather than quietly sounding wrong.

---

## Before you upgrade

**Keep a copy of any project you might need to open in 2.1.x again.**

The project format moves from `ser_ver` 44 to 54. Your 2.1.x projects and kits
load into 3.0 cleanly — older fields fill in with sensible defaults. But 3.0
writes per-pad data that 2.1.x has no reader for: synth voices, the new EQ
bands, key ranges, pitch state. We haven't tested going backwards and we don't
promise it works. Treat the upgrade as one-way.

## After you install

1. Restart REAPER.
2. The Kit Bridge registers the action catalogue on first run. You can re-run
   **EON: Install / Refresh Actions** any time.

You'll want these from ReaPack, same as before:

- **ReaImGui** — the sample browser
- **SWS** — a few sync actions
- **js_ReaScriptAPI** — the Drum Matrix

Swing's JSFX itself needs none of them.
