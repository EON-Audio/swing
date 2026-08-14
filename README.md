# Swing 3.0 — Beta

**A drum workstation that lives inside REAPER.**

The Swing sampler, the Steppa step sequencer, the Drum Matrix, a channel
strip per drum — one instrument, no external app, everything saved in your
project like it belongs there. Because it does.

> **You're on the beta.** Thanks for being here. Install it the way a buyer
> would, make some drums, and try to break it. Everything you notice is a
> report we want.

## 📖 The Manual

**[Swing 3.0 Manual — PDF, 48 pages](Swing_3.0_Manual.pdf)** — quickstart to
recipes, every view illustrated. GitHub renders it right in your browser.

## What's in the box

One install, five plugins, one ecosystem:

- **Swing** — 16-pad drum sampler. Four layers per pad (velocity splits,
  round-robin, sum), per-pad FX chains, ADSR, choke groups, key ranges,
  16 stereo outputs.
- **The Drum Synth** *(new in 3.0)* — nine engine families, thirty voices,
  ports of hardware-measured references. No samples required: eleven of the
  thirteen factory kits are pure synth and load instantly.
- **Steppa** — the step sequencer. Groove import/export (`.rgt` and straight
  from MIDI files), 824 factory patterns browsable by role and genre, song
  mode.
- **Drum Matrix** — your patterns as real REAPER MIDI items in the arrange
  window. Edit either end; the other follows, ratchets included.
- **Drum Strip + FX Return View** — a mixer channel per drum with SSL-style
  controls, plus delay/reverb return metering.
- **EON Lens** — a kit-artwork card for the track panel. Your kit's cover,
  living on the track, pulsing with the audio.

Plus: 14 console themes, 18 knob styles, kit cover art, multiple instances
per project with zero cross-talk, and Swing's own undo engine — Ctrl+Z can't
wipe a kit anymore.

## Install (ReaPack, all platforms)

1. Install [ReaPack](https://reapack.com) if you don't have it.
2. In REAPER: **Extensions → ReaPack → Import repositories…** and paste:

   ```
   https://raw.githubusercontent.com/EON-Audio/swing/main/index.xml
   ```

3. **Synchronize packages**, install **EON Swing 3**, and **restart REAPER**.

Also via ReaPack, free and required: **SWS**, **ReaImGui**, and
**js_ReaScriptAPI**.

## First run

1. Insert **Swing_ReaKit** on a track (search "Swing" in the FX browser).
   A kit loads on its own and the pads make sound immediately.
2. Run **Swing_Kit_Bridge** once from the Action List (Actions → Show action
   list). It registers itself and auto-starts from then on — one-time step.
3. That's it. The browser, sequencer and strips are all reachable from
   Swing's own UI.

## What to hammer on

- **The first ten minutes.** Fresh install, fresh project — does everything
  come up on its own?
- **Multi-out.** Hit MULTI. Sixteen named, colored tracks should appear, each
  with its own Drum Strip, without you doing anything.
- **Save / close / reopen.** Is everything exactly as you left it?
- **Kits and samples.** Factory kits, your own samples, your own kits,
  reloaded in a new project.
- **Feel.** Anything that lags, flickers, or makes you go "huh?" — that's a
  report.

## Reporting

Reply to your beta invite email with whatever you have — rough notes are
fine. Ideal: OS + REAPER version, what you did, what you expected, what
happened instead. Screenshots welcome. For kit-loading problems, attach
`<REAPER resource folder>/Data/EON_Swing/load_log.txt`.

## Updating mid-beta

**Extensions → ReaPack → Synchronize packages**, then restart REAPER —
always restart. A running Swing keeps old code in memory and will happily
confuse you otherwise.

## Good to know

- **Update notifications are Windows-only** for now; ReaPack Synchronize is
  the update path everywhere.
- **Chromatic key ranges play in Repitch mode** (the range editor says so);
  Tuned/Stretch ranges are on the roadmap. Ranged pads are monophonic.
- **Projects saved with 3.0 won't open in Swing 2.1.x** — the upgrade is
  one-way.
- **Audio cutting out when REAPER loses focus is a REAPER preference**, not
  Swing: Preferences → Audio → Device → *Close audio device when stopped and
  application is inactive*. Uncheck it.

---

*EON Studios · Swing 3.0 beta*
