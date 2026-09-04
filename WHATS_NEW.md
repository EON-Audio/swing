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

These are ported from hardware-measured references, so the classic voices
behave the way the machines they came from actually behaved.

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

Key ranges work in Repitch today. Tuned and Stretch are still to come, and
Swing says so in the range editor.

## Run as many Swings as you like

Each instance keeps its own pitch state, mute/solo, colours and note names, and
stays in sync with the Drum Matrix both ways.

## Ctrl+Z can't wipe a kit any more

Swing has its own undo engine now — parameter, structural and full-kit — pulled
out of REAPER's global undo.

---

## Four plugins you didn't have

2.1.6 installed one thing: Swing. This release installs five.

### Step Sequencer

A full step sequencer built for Swing.

- **Groove system** — swing and groove engine with `.rgt` import *and* export,
  plus groove import straight from a MIDI file
- **824 factory patterns in a browser organised by role** — main, fill, build,
  break, perc — with genre chips and live counts
- **Song mode** — named arrangements that switch at the play-next boundary,
  with a song strip across the top of the sequencer (see the second beta)

### Drum Matrix

Your patterns as a grid in the arrange window, working directly on REAPER
MIDI items.

- **Live two-way sync with the sequencer** — a region is a pattern, edit either
  end and the other follows, ratchets included
- Lanes carry your pad names, colours and icons straight through from Swing
- Role-based remapping, so a pattern aimed at one kit lands sensibly on another

![The Drum Matrix in the arrange](screenshots/dm_arrange.png)

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
pulsing with the audio. A kit without a cover gets a generated monogram.

### Per-pad FX and multi-out returns

Inside Swing: a dedicated FX panel per pad with an interactive EQ graph, plus
opt-in delay and reverb **return outputs** for multi-out rigs, and per-pad send
knobs on the Drum Strip.

New alongside them: **EON Weld**, a bus compressor with a real gain-reduction
needle. Multi-out puts one on your drum bus for glue, and **EON Anvil** always
drives the new **Smash** return — parallel compression on a fader, fed by a
per-pad SMASH send sitting next to DLY and RVB. Both get a section of their
own under the second beta, below.

---

## Kits, look and feel

### Kit artwork

Kits now carry a cover image inside the `.swing` file itself, so it travels with
the kit wherever the kit goes. Drag an image onto the KIT tab tile to attach
one. All thirteen factory kits ship with machine-portrait covers, and a kit
without one draws a matching vector portrait.

### Kit categories, with LOCK and ADAPT

Each pad carries a category glyph in place of its number, picked from a grid of
46. **LOCK** keeps a pad exactly as it is through kit loads. **ADAPT** re-aims
your existing patterns at the new kit, and a change map shows you what moved.

### Themes, knobs and icons

14 console themes and 18 knob styles, and the Lua panels now draw the same
knobs as the plugin. The icon system was reworked to 46 solid-silhouette
categories with hue-tinted variants that follow your pad colour out to track
colours and sequencer lanes.

### The VU meters

Every needle in the suite runs on one new meter: the Drum Strip, Weld, Anvil,
1175, ExpressBus, DirtSqueeze, Reelism and ChannelTool. It's built to the VU
standard — a signal at reference takes 300 milliseconds to land and overshoots
by about one percent — so it moves the way a hardware VU does and agrees with
the stock meters on your other tracks. It's quicker than the needle you had.
Twenty faces, from cream and ivory through the console looks to a few loud
ones. Click the meter's cover to pick one; a face saved in an older project
comes back as the nearest of the twenty.

### SFZ and RS5k

Self-contained **SFZ export** — the WAVs travel with the kit — with import
fidelity for tune, volume, pan and note. Plus a two-way **RS5k converter** that
handles velocity, round-robin and containers.

---

## Everyday things that got better

- **Sweeping the EQ is silent.** The whole EQ path moved to state-variable
  filters, with a new Hi-Mid band and a Q wheel per bell.
- **The reverb and delay buses each have their own on/off.** Switching a bus
  off rings its tail out and keeps size, division, feedback and mix exactly
  where you left them.
- **The tune knob responds immediately**, and velocity-layered pads now pitch
  every layer correctly.
- **Drag samples straight onto pads** — including onto a Swing embedded in the
  track panel or mixer. Multi-file drags fill consecutive pads.
- **When samples go missing, Swing helps.** You get a banner offering to relink
  the folder.
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

## The second beta

Everything above was in the first beta. This is what the second one adds.

### EON Weld

The bus compressor, rebuilt as the circuit. The gain cell, its sidechain and
the timing network are the drawings of the console classic, and the whole
thing is fitted to measured hardware traces rather than to a description of
one. Threshold, ratio, attack, release, makeup and mix on a G-series face,
light or dark, with an AUTO release and the real GR needle. It sits on the
drum bus after MULTI, and works anywhere else you put it.

Swing's own master compressor has been this engine all along; its COMP page
now wears the same card, on the big view and on the LCD, with the GR needle
and an AUTO release of its own.

![EON Weld](screenshots/weld.png)

![Swing's COMP page, Weld's card in the big view](screenshots/comp_big.png)

![The same card on Swing's LCD](screenshots/comp_lcd.png)

### EON Anvil

A FET limiting amplifier solved from the schematic: the FET with its
subthreshold tail, the sidechain amplifier, the timing network as drawn. Two
voices — **Black**, calibrated on the original, and **Blue**, with its extra
gain inside the loop — plus 4, 8, 12, 20 and the all-buttons trick.
Input, output, attack, release, an XTRAS drawer, and its own GR needle. It
drives the Smash return, and the rack build offers it for the bus too.

![EON Anvil](screenshots/anvil.png)

MULTI asks once which compressor goes where — Weld, Anvil, one of the stock
JS comps, or one of your own FX chains — for the bus and for the Smash return:

![Drum Bus Options](screenshots/rack_dialog.png)

### The Console is a desk now

Open CONSOLE and you get a full window: sixteen strips, an inserts band that
shows every pad's FX chain as cards, sends, solo and mute, faders and a master
strip that follows your routing. Click an empty slot and a compact picker
opens over the desk; right-click a card to open, bypass, offline or embed the
plugin, drag cards to reorder. Sections you don't need switch off.

![The Console](screenshots/console.png)

![The compact picker over the desk](screenshots/console_picker.png)

### The FX picker

The whole plugin catalogue in one view: banks and folders on the left, your
plugins as a list or a wall of cards, categories with an icon each, REAPER's
own categories in the rail, vendor on every row, and the pad's chain on the
right. A CHAINS mode browses your FXChains and can replace a whole chain.
The EON line has a drawn card each; the stock REAPER plugins and a good
hundred others get one too.

![The FX picker](screenshots/fxpicker.png)

![The FX picker's card wall](screenshots/fxpicker_cards.png)

### Docking

Click the SWING wordmark and Swing moves into a docker pane, folding into a
**rack face**: a slim header and the full-size pad grid, built for a pane
under the arrange. Steppa's wordmark does the same with its own **dock face**,
one bar plus the lanes and grid. Both remember it — close the project, reopen
it, and they come back docked. The dock layout picker arranges the EON panes
around the arrange in a few layouts, or one of your own.

![Swing and Steppa docked](screenshots/dock.png)

![The dock layout picker](screenshots/dock_layout.png)

### The song strip

Song mode has a face. Your sections run across the top of the sequencer,
drawn to length, named, coloured, the playhead sweeping through them. Each
section is its own pattern, all of them stay loaded, and the grid shows the
one you picked while the engine plays the one under the playhead. Click a
block for its menu, hold one to listen. Zoom to a section or to the whole
song from the strip, and the arrange scrolls the kit tracks into view.

![Steppa with the song strip](screenshots/steppa_song.png)

A song starts from **New Song**: tempo, sections with their own bar counts,
or a genre template, and it lays out the regions, the Swing track and the
lanes in one go.

![EON: New Song](screenshots/new_song.png)

### Kit macros

Eight macro knobs per kit, each mapped to any number of pad and kit
parameters with its own range. An editor to assign them, DICE to try
something, snapshots you can morph between, and the mappings travel with the
kit. All thirteen factory kits carry a macro block.

![The MACRO tab](screenshots/macro_tab.png)

![The macro editor](screenshots/macros_decay.png)

### Smaller things

- A file browser inside Swing: folders in a rail, a splitter you can drag,
  drop a sound on a pad.
- The Drum Strip's floating window is a deck that reflows to its width, with
  a gear menu in the header.
- The Drum Matrix carries the feel both ways: swing, nudges, ties, accents,
  CC lanes and step probability all ride the item.
- The synth voice shows in the pad editor, and the 3D drum strikes on the hit.
- Swing's send delay runs on the EON Delay engine.
- Steppa's grid renders once and blits until something moves.

---

## After the second beta

Two small updates since, 3.0.1 and 3.0.2.

### EON Floatter

Every EON plugin's floating window now opens at the size it was designed
for. A JSFX has one size line, and it also shapes the panel embed, so the
float has to be sized from outside: Floatter watches for EON windows and
sets each one as it appears, on any screen, at any display scale. Resize a
window yourself and it stays that way; Capture keeps that size as yours for
that plugin, Reset goes back to EON's. One dial scales all of EON's sizes
for a small laptop or a big display, and "Apply EON sizes to this project"
sets every EON plugin already in the project, quietly. The Kit Bridge starts
it for you. Run **EON_Floatter** from the Action List for the panel. It
takes over from the EON_FloatSize scripts in the beta and keeps every size
you captured with them.

### The dock rig ships

EON Swing Dock, EON Steppa Dock, EON Dock Layout, EON Swing Dock View and
EON Chain Dock install with Swing and appear in the Action List, so the
wordmark's dock toggle and its DOCK LAYOUT menu work on a fresh install.

### The picker

It fills on a fresh install: the Kit Bridge starts the picker's bridge
itself. And EON's own plugins wear their own faces on their cards, drawn
from the shipping plugins, so Weld, Anvil, the Drum Strip and the rest are
telling apart at a glance.

### Small things

- The Drum Bus Options dialog shows its comp cards on installed copies.
- Snare A.DEC at full turn holds the longest decay.
- The Kit Bridge reports a missing extension in the console once, naming
  what it affects.
- Every ReaPack version is pinned to the commit that carries its files.

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
  tells you so.

---

## Before you upgrade

**Keep a copy of any project you might need to open in 2.1.x again.**

The project format moves from `ser_ver` 44 to 57. Your 2.1.x projects and kits
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
