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

**Already on the beta?** The second beta adds Weld and Anvil, the Console
desk with its FX picker, docking for Swing and Steppa, the song strip, and
kit macros. The what's-new page has a **[section on the second beta](WHATS_NEW.md#the-second-beta)**.

## What's in the box

One install, one ecosystem:

- **Swing** — 16-pad drum sampler. Four layers per pad (velocity splits,
  round-robin, sum), per-pad FX chains, ADSR, choke groups, key ranges,
  16 stereo outputs.
- **The Drum Synth** *(new in 3.0)* — nine engine families, thirty voices,
  ports of hardware-measured references. Eleven of the thirteen factory kits
  are pure synth and load instantly.
- **Steppa** — the step sequencer. Groove import/export (`.rgt` and straight
  from MIDI files), 824 factory patterns browsable by role and genre, and a
  **song strip**: your sections drawn to length across the top, the playhead
  sweeping through them, one pattern per section.
- **Drum Matrix** — your patterns as real REAPER MIDI items in the arrange
  window. Edit either end; the other follows, ratchets included.
- **Drum Strip + FX Return View** — a mixer channel per drum with SSL-style
  controls, plus hardware-faceplate return monitors: the EON 480 reverb and
  EON H9 delay decks, every contributing pad's send on a fader.
- **EON Weld** *(new)* — a bus compressor built from the circuit of the
  console classic and fitted to measured hardware, with a real GR needle. The
  multi-out build puts one on your drum bus.
- **EON Anvil** *(new)* — a FET limiting amplifier solved from the schematic,
  in Blackface and Blue voices, with the all-buttons trick. It drives the
  **Smash** return: parallel compression on a fader, fed by a per-pad SMASH
  send next to DLY and RVB.
- **The Console** — Swing's mixer as a full desk: sixteen strips, an inserts
  band showing every pad's FX chain as cards, and an FX picker with the whole
  plugin catalogue sorted into categories.
- **Docking** — Swing and Steppa each fold into a slim dock face that lives
  under the arrange, and both come back docked when you reopen the project.
- **EON Lens** — a kit-artwork card for the track panel. Your kit's cover,
  living on the track, pulsing with the audio.

Plus: eight **kit macros** per kit with snapshots and morph, a file browser
inside Swing, 14 console themes, 18 knob styles, kit cover art, multiple
instances per project, and Swing's own undo engine — Ctrl+Z can't wipe a kit
anymore.

## In pictures

![The Swing workspace — 16 pads with synth voices, per-pad mixer, kit artwork](screenshots/01_pads.png)

*The workspace: 16 pads, synth or sample per pad, mixer meters, kit art,
master drive.*

| | |
|---|---|
| ![The Drum Synth editor — a 3D drum above the voice controls](screenshots/06_synth.png)<br>*The Drum Synth — nine families, thirty voices, and a 3D drum that moves as you tune it.* | ![The key-range editor — drag a pad across the keyboard](screenshots/13_range.png)<br>*Key ranges — drag a pad's edges and it plays melodically across the keys.* |
| ![Steppa — the song strip across the top, sections drawn to length, a beat in the grid](screenshots/steppa_song.png)<br>*Steppa — the song strip: Intro, Verse, Chorus, Outro drawn to length, the playhead moving through them, one pattern per section.* | ![The Drum Strip — EQ graph, VU, filters, FX, sends](screenshots/35_drumstrip.png)<br>*Drum Strip — a channel per drum: EQ graph, VU, filters, drive, comp, and the DLY / RVB / SMSH sends.* |

![Swing and Steppa docked under the arrange, the four song sections above them](screenshots/dock.png)

*Docked: Swing's rack face and Steppa's dock face side by side under the
arrange, the song's four sections above them. Both come back docked when the
project reopens.*

![The Drum Matrix — sixteen lanes in the arrange, one note block per hit](screenshots/dm_arrange.png)

*The Drum Matrix: your patterns as real REAPER MIDI items, one lane per drum,
named and coloured from the kit. Edit here or in Steppa; the other follows.*

![The Console — sixteen strips, the inserts band with FX cards, sends and faders](screenshots/console.png)

*The Console: sixteen strips on one desk, every pad's FX chain as cards in the
inserts band, sends and faders below.*

| | |
|---|---|
| ![The compact picker open over the desk — banks, categories and the plugin list](screenshots/console_picker.png)<br>*Click an empty slot and the picker opens right there on the desk: banks, category chips, the list with a card per plugin.* | ![The MACRO tab — eight macro knobs above the pad grid, with snapshots](screenshots/macro_tab.png)<br>*Kit macros — eight knobs above the grid, four snapshots and a morph slider.* |
| ![The macro editor — PUNCH mapped to four pads' comp](screenshots/macros_punch.png)<br>*The macro editor: PUNCH mapped to the comp on four pads, each with its own range.* | ![The macro editor — DECAY mapped across eight pads](screenshots/macros_decay.png)<br>*DECAY across eight pads, every mapping with a range of its own.* |

| | |
|---|---|
| ![EON Weld — bus compressor with a GR needle](screenshots/weld.png)<br>*EON Weld — the bus compressor, on your drum bus after MULTI.* | ![EON Anvil — FET limiting amplifier, Blackface voice](screenshots/anvil.png)<br>*EON Anvil — the FET limiter, driving the Smash return.* |
| ![Swing's COMP page — Weld's card in the big view](screenshots/comp_big.png)<br>*Swing's master compressor is Weld too, and its COMP page wears the same card: GR needle, six knobs, IN and AUTO.* | ![Swing's COMP page on the LCD — the card at strip size](screenshots/comp_lcd.png)<br>*The same card on the LCD, meter and buttons left, knobs right.* |

| | |
|---|---|
| ![Drum Bus Options — returns, and a card for each compressor on the bus and the Smash return](screenshots/rack_dialog.png)<br>*MULTI asks once: returns on or off, and which compressor goes on the bus and on the Smash return.* | ![EON: New Song — tempo, sections, an arrangement bar, and genre templates](screenshots/new_song.png)<br>*New Song: tempo, sections and bars, or a template — Pop, Hip-Hop, Trap, Techno, Drum & Bass and more.* |
| ![The dock layout picker — Full, Beatmaking, Sound design, Pads only, Ableton, Bitwig, Custom](screenshots/dock_layout.png)<br>*Dock layouts: seven arrangements of the EON panes around the arrange, one of them yours.* | ![The note picker — a pad's note chosen on a keyboard of pads](screenshots/note_picker.png)<br>*The note picker: every pad on a keyboard, a wheel to scroll octaves.* |

| | |
|---|---|
| ![The FX picker — banks and categories on the left, the plugin list with cards, the chain on the right](screenshots/fxpicker.png)<br>*The FX picker: every plugin you own, sorted into categories with a card each, and the pad's chain on the right.* | ![The FX picker's GRID view — a wall of plugin cards](screenshots/fxpicker_cards.png)<br>*GRID: the same catalogue as a wall of cards, each drawn to look like the plugin it stands for.* |

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

Also via ReaPack, free and required: **SWS** (Drum Strip sync on multi-out
tracks), **ReaImGui** (the sample browser, Pad FX, dock layouts) and
**js_ReaScriptAPI** (the dock rig). Install them first; the Kit Bridge names
any that are missing in the console.

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
  with REAPER. The bridge then starts its two companions itself, the Drum
  Strip sync helper and the FX picker bridge, and each registers itself the
  same way, so all three come up with REAPER from then on. The blocks are
  self-cleaning: uninstall the scripts and each block removes itself and its
  settings on the next launch. The file is rewritten through a temp file +
  rename, so other scripts' startup lines are never at risk.
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
