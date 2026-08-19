# Third-Party Notices

Swing includes or adapts the open-source work below, each piece used under
its own license, with thanks — this project genuinely stands on these
shoulders. Everything not listed here is (c) EON Studios and covered by
[LICENSE.md](LICENSE.md).

## Bundled / adapted code

- **DD-101 "Dum Drums"** by Joep Vanlier (Saike) — MIT
  ([github.com/JoepVanlier/JSFX](https://github.com/JoepVanlier/JSFX)).
  The drum-synth engine voicings in `Swing/libs/rk_synthdrums.jsfx-inc` are
  adapted from saikedrums v0.18.
- **SEQS (Sequenced FX)** by Joep Vanlier (Saike) — MIT.
  Steppa's UI widget layer and the shared button/hint styling in
  `Swing/libs/rk_widgets.jsfx-inc` are adapted from SEQS.
- **2-op phase-modulation drum voices** by TiaR / Thierry Rochebois — BSD
  (via ReaTeam). Synth-engine building blocks in
  `Swing/libs/rk_synthdrums.jsfx-inc`.
- **ReEQ** by Justin Johnson — MIT
  ([github.com/Justin-Johnson/ReJJ](https://github.com/Justin-Johnson/ReJJ)).
  Portions of the filter/EQ code in `Swing/libs/rk_svf.jsfx-inc`.
- **TK Kit Maker** and **TK Workbench** by TouristKiller — MIT, used under an
  explicit grant (2026-08-01). The sample-analysis engine
  (`Scripts/rk_lua_sample_analysis.lua`) and the match-DAW-theme derivation
  (`Scripts/rk_lua_theme.lua`).
- **json.lua** by rxi — MIT. Bundled verbatim at
  `Scripts/EON/Drum Matrix/lib/json.lua` (license text inside the file).
- **imgui.lua** by Christian Fillion — the ReaImGui API shim, from the
  [ReaImGui](https://github.com/cfillion/reaimgui) project (LGPL-3.0).
  Bundled so Swing's dialogs bind to the ReaImGui extension you install via
  ReaPack; the extension itself is a separate install, not part of this
  package.
- **REAPER Toolkit (rtk)** by Jason Tackaberry — MIT
  ([reapertoolkit.dev](https://reapertoolkit.dev)). No longer used by Swing;
  `Scripts/rtk.lua` stays fetchable for a while so older cached package
  indexes that still list it keep installing, and will be removed after the
  beta.

## Pattern and reference credits

- Steppa's factory pattern library credits its sources in
  `Scripts/EON/PatternLibrary/CREDITS.md`, which ships with the install.
- Mutable Instruments **Plaits** drum models by Emilie Gillet — MIT — served
  as quality references for voicing comparisons; no Plaits code ships in
  Swing.

## MIT License

The MIT-licensed items above are used under these terms (copyright holders
as named per item):

> Permission is hereby granted, free of charge, to any person obtaining a
> copy of this software and associated documentation files (the "Software"),
> to deal in the Software without restriction, including without limitation
> the rights to use, copy, modify, merge, publish, distribute, sublicense,
> and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
> THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
> FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
> DEALINGS IN THE SOFTWARE.
