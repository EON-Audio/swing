# Swing 3.0 — Beta

**A drum workstation that lives inside REAPER.**

The Swing sampler, the Steppa step sequencer, the Drum Matrix, a channel
strip per drum — one instrument, no external app, everything saved in your
project like it belongs there. Because it does.

> **You're on the beta.** Thanks for being here. Install it the way a buyer
> would, make some drums, and try to break it. Everything you notice is a
> report we want.

## 📖 The Manual

**[Swing 3.0 Manual — PDF, 51 pages](Swing_3.0_Manual.pdf)** — quickstart to
recipes, every view illustrated. GitHub renders it right in your browser.

**Coming from Swing 2.1?** Read **[What's new in 3.0](WHATS_NEW.md)** — the
short tour of everything that changed, and the few things that moved.

## What's in the box

One install, one ecosystem:

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
  controls, plus hardware-faceplate return monitors: the EON 480 reverb and
  EON H9 delay decks, every contributing pad's send on a fader.
- **EON 76** *(new)* — a bus compressor with a real GR needle. The multi-out
  build can drop one on your drum bus for glue, and one always drives the new
  **Smash** return: parallel compression on a fader, fed by a per-pad SMASH
  send next to DLY and RVB.
- **EON Lens** — a kit-artwork card for the track panel. Your kit's cover,
  living on the track, pulsing with the audio.

Plus: 14 console themes, 18 knob styles, kit cover art, multiple instances
per project with zero cross-talk, and Swing's own undo engine — Ctrl+Z can't
wipe a kit anymore.

## In pictures

![The Swing workspace — 16 pads with synth voices, per-pad mixer, kit artwork](screenshots/01_pads.png)

*The workspace: 16 pads, synth or sample per pad, mixer meters, kit art,
master drive.*

| | |
|---|---|
| ![The Drum Synth editor — a 3D drum above the voice controls](screenshots/06_synth.png)<br>*The Drum Synth — nine families, thirty voices, and a 3D drum that moves as you tune it.* | ![The key-range editor — drag a pad across the keyboard](screenshots/13_range.png)<br>*Key ranges — drag a pad's edges and it plays melodically across the keys.* |
| ![Steppa — lanes with pad names, icons and colors](screenshots/34_stepseq.png)<br>*Steppa — your pads' names, icons and colors carried straight into the sequencer.* | ![The Drum Strip — VU meter, EQ nodes, SSL-style knobs](screenshots/35_drumstrip.png)<br>*Drum Strip — a channel per drum: VU, EQ nodes, drive, comp, sends.* |

![REAPER's mixer with sixteen drum channels, each carrying an embedded Drum Strip](screenshots/hand_mixer.png)

*Hit MULTI: sixteen named, colored channels in REAPER's own mixer, a Drum
Strip embedded on every one, returns included.*

## Install (ReaPack, all platforms)

1. Install [ReaPack](https://reapack.com) if you don't have it.
2. In REAPER: **Extensions → ReaPack → Import repositories…** and paste:

   ```
   https://raw.githubusercontent.com/EON-Audio/swing/main/index.xml
   ```

   > ⚠️ Paste that raw address **exactly** — this page's own URL
   > (`github.com/EON-Audio/swing`) is not a ReaPack index, and importing
   > it fails with an XML parse error.

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

## What Swing changes on your machine

Plain answers, because you shouldn't have to read source to know:

- **Startup action.** That one-time Swing_Kit_Bridge run adds a small block to
  `Scripts/__startup.lua` in your REAPER resource folder so the bridge starts
  with REAPER (the Drum Strip sync helper registers itself the same way). The
  blocks are self-cleaning: uninstall the scripts and each block removes
  itself and its settings on the next launch. The file is rewritten through a
  temp file + rename, so other scripts' startup lines are never at risk.
- **Network: none, by default.** A ReaPack install of Swing makes no network
  requests — updates come from ReaPack Synchronize, which only talks to this
  repository. (The Windows .exe channel ships an update checker that asks
  `api.github.com` for the latest release number when Swing loads; it sends
  nothing about you or your projects and stays silent offline. On a ReaPack
  install it only runs if you launch **EON_UpdateCheck** from the Action List
  yourself.)
- **Where your data lives.** Kits: `Data/Swing_Kits/`. Settings, caches and
  logs: `Data/EON_Swing/` and `Data/Swing_Cache/` — all inside your REAPER
  resource folder. The only thing written next to a project is that project's
  own kit audio.

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

## License

Swing is commercial software; this repository is its delivery channel, so the
source is visible but not open source. Install it, use it on your music
(commercial or not), share kits you make yourself — just don't redistribute
or resell the code or factory content. Full terms: [LICENSE.md](LICENSE.md).
The open-source work Swing builds on is credited in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

*EON Studios · Swing 3.0 beta*
