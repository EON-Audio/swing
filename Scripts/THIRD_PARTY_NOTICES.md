EON Swing -- third-party notices
================================

Swing is (c) EON Studios and covered by Swing's own licence, the LICENSE file
that comes with it. A few parts of
it come from, or were adapted from, other people's work. Each of those parts
is listed below with its author, its licence and where it lives in your
install, so their notices travel with every copy as their licences ask.
Thank you to every one of them.

File names are given as installed: effect files under Swing's effect folder
(Swing/..., Swing/libs/...), scripts under Swing's script folder.


1. Code used under the MIT License
----------------------------------

The MIT License text is printed once, at the end of this section, and
applies to each item in it, with that item's copyright line.

- Dum Drums (DD-101) by Joep Vanlier (Saike), v0.18.
  Copyright (c) Joep Vanlier.
  The drum-synth voices are ported from it:
  Swing/libs/rk_synthdrums.jsfx-inc, rk_synthdrums_p2.jsfx-inc,
  rk_synthdrums_p3.jsfx-inc. The factory kit "DD-101" is named after it.

- SEQS (Sequenced FX) by Joep Vanlier (Saike).
  Copyright (c) Joep Vanlier.
  The step sequencer's button and hint widgets are adapted from it:
  Swing/libs/rk_widgets.jsfx-inc.

- ReEQ by Justin Johnson.
  Copyright (c) Justin Johnson.
  Portions of the per-pad EQ filter: Swing/libs/rk_svf.jsfx-inc.

- Spectrum analyser (S2GFX spectrum.jsfx-inc) by Justin Johnson.
  Copyright (c) Justin Johnson.
  EON Tone's analyser is a port of it: Swing/libs/rk_spectrum.jsfx-inc.

- TK Scripts by TouristKiller (Kurt Janssen), with thanks.
  Copyright (c) 2023-2026 Kurt Janssen (TK Scripts).
  https://github.com/TouristKiller/TK-Scripts
    - TK Kit Maker (credited to TouristKiller & Flurmechanik): the sample
      analysis, rk_lua_sample_analysis.lua and its use in Swing_Browser.lua.
    - TK Media Browser: the filename categoriser, eon_filename_categorizer.lua
      and its effect-side twin Swing/libs/rk_cat_glyphs.jsfx-inc; the
      browser's spectral colouring, waveform and time-grid drawing,
      Swing_Browser.lua and rk_lua_widgets.lua.
    - TK Workbench: the "match REAPER theme" colour derivation,
      rk_lua_theme.lua.
    - TK Trackname in Arrange: the Drum Matrix overlay positioning and
      settings window, EON/Drum Matrix/lib/overlay_window.lua,
      settings_store.lua, settings_window.lua, arrange_coords.lua and
      EON/Drum Matrix/EON_DM_Settings.lua. The overlay positioning credits
      Sexan's method.

- json.lua by rxi, v0.1.2.
  Copyright (c) 2020 rxi.
  Bundled unchanged: EON/Drum Matrix/lib/json.lua.

- Docking Tools by Ben 'Talagan' Babut (technique credited there to
  Edgemeal).
  Copyright (c) Ben 'Talagan' Babut.
  The docker resize: EON_Dock_Layout.lua.

The MIT License:

  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the
  "Software"), to deal in the Software without restriction, including
  without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to permit
  persons to whom the Software is furnished to do so, subject to the
  following conditions:

  The above copyright notice and this permission notice shall be included
  in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
  OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
  NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
  OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
  USE OR OTHER DEALINGS IN THE SOFTWARE.


2. Code used under the GNU Lesser General Public License, version 3
-------------------------------------------------------------------

- imgui.lua, the ReaImGui API file, by Christian Fillion (cfillion), part of
  the ReaImGui extension. Bundled unchanged, beside Swing's scripts, so
  Swing's windows bind to the ReaImGui extension you install from ReaPack.
  ReaImGui's source code is published under the LGPL v3 at
  https://codeberg.org/cfillion/reaimgui
  The full licence texts are installed beside it: imgui.LGPL-3.0.md (the
  GNU Lesser General Public License, version 3) and imgui.GPL-3.0.md (the GNU
  General Public License, version 3, which the LGPL v3 builds on). They
  cover imgui.lua only, not the rest of Swing.


3. Credited work whose authors state no licence
-----------------------------------------------

- megababy v3 by jnif, with the community modifications by NandyC ("nm"),
  ajaym (Akai/APC support) and prbmod (probability). Steppa, EON's step
  sequencer (Swing/EON_StepSeq.jsfx), is a fork of it, and its Quick Guide
  began as jnif's. Forked with thanks and credited here; this credit is not
  a licence claim. Steppa is free: it is installed with Swing at no charge
  and is not part of what you pay for when you buy Swing.

- "Joanny" knob style (style 6), credited to Joanny / McFizz:
  Swing/libs/knobs_kbsg.jsfx-inc and rk_lua_knobs.lua.


4. Sounds
---------

- The "808 F" factory kit uses the Roland TR-808 Rhythm Composer Sound
  Sample Set 1.0.0 (1994) by Michael Fischer / Technopolis, released by him
  as a free sample set. All credit for the recordings belongs to Michael
  Fischer. His original notes (TR808.TXT) and the kit credits (CREDITS.txt)
  are installed beside the kit, in the "Fischer 808" folder of Swing's kit
  library.

- The eleven "Vintage Synth" kits are EON's own synth settings and hold no
  recorded audio.

- The step sequencer's pattern library has its own credits file,
  EON/PatternLibrary/CREDITS.md.


5. With thanks for ideas, references and published techniques
--------------------------------------------------------------

Mutable Instruments Plaits by Emilie Gillet (a quality reference for the
drum voices); TiaR (T. Rochebois) and his 2op PM Synth (the two-operator
phase-modulation idea behind an earlier version of the drum-synth hat);
BirdBird (the look of the Rainbow Arc knob); Witti Sound (the look of the
Witti knob); Robert Bristow-Johnson's Audio EQ Cookbook; Andy Simper's
(Cytomic) state-variable filter paper; Edgemeal (the docker resize
technique); yimbot's "Docked Plugin Display" (the docked-plugin idea); MPL
(the waveform peaks approach); and the musicdsp.org archive (the published
halfband filter coefficients in Swing/libs/rk_anvil_p2.jsfx-inc).


6. Product names
----------------

Product and company names shown in Swing, such as the names of knob styles
and of the effects the FX picker recognises, belong to their owners. They
are used only to describe a look or to name what is installed on your
computer, and do not mean any affiliation with or endorsement by them.
