-- ReaKit Root Note Detector — clean-room YIN
-- (c) EON Studios — All Rights Reserved
--
-- Estimates the ROOT NOTE (MIDI note + cents) of a one-shot sample.
-- Distinct from the browser's existing detect_key(), which returns a musical
-- KEY ("C" / "Am") from a chromagram and is not a per-sample fundamental.
--
-- Usage:
--   local rn = dofile(script_dir .. sep .. "rk_root_note.lua")
--   local r  = rn.detect_file(path)      -- needs REAPER (AudioAccessor)
--   local r  = rn.analyse(samples, sr)   -- pure Lua, REAPER-free, probeable
--   if r and r.show then ... r.name, r.octave, r.cents ... end
--
-- ALGORITHM — YIN (de Cheveigné & Kawahara 2002, JASA). Implemented from the
-- published paper: difference function -> cumulative mean normalised difference
-- -> absolute threshold -> parabolic interpolation. No third-party code.
--
-- ⚠️ SYNTH PADS DO NOT NEED THIS. rk_synthdrums.jsfx-inc knows its own settled
-- fundamental in closed form (kick :333, snare :395, tom :615), so a SYN pad's
-- root note is exact and free — call hz_to_note() on the synth value instead.
-- Hats/cymbals there expose only a filter cutoff (:509/:556), i.e. no
-- fundamental at all, and correctly display nothing.
--
-- ── Design decisions, each measured 2026-08-01 (see the calibration rig) ──
--
-- 1. DECIMATE THE SIGNAL, NEVER THE LAG AXIS. YIN's cumulative mean
--    normalisation d'(t) = d(t)*t / sum(d(1..t)) is SEQUENTIAL over t, so
--    skipping lags silently changes the normaliser. Decimating the signal x4
--    shrinks both the lag range and the window (an O(D^2) win) while still
--    visiting every lag. Cents are recovered by parabolic interpolation.
--
-- 2. SETTLE-AWARE WINDOW. Pitched percussion GLIDES. Measured on Swing's own
--    tom (pitch envelope tau ~61 ms): starting 10 ms past the peak reads +2.5
--    semitones sharp; 100 ms+ reads +0.06. Start ~35% into the decay, capped,
--    with fallbacks so short one-shots still get measured.
--
-- 3. SUBHARMONIC PROMOTE. YIN returns the period of the WAVEFORM, and drum
--    voices are INHARMONIC. Swing's snare runs shells at f0 and 1.63*f0 (~5/3)
--    whose sum repeats at f0/3 — raw YIN read exactly -18.8 semitones. Promote
--    to the LOWEST well-supported partial, not the loudest: picking the loudest
--    overshoots on missing-fundamental percussion (a real tabla measured
--    partials at 2f and 3f with nothing at f, where YIN's raw answer IS the
--    perceptual residue pitch you would tune to).
--
-- 4. CONFIDENCE GATE 0.90. Calibrated against 80 labelled renders from Swing's
--    own synth (which knows its true f0), then validated on TR-808 / TR-909 /
--    Hand Drums: zero false positives, 100% noise rejection. 0.85 was clean on
--    real kits but cost a false positive on the adversarial synth sweep.
--    A WRONG root note actively misleads someone tuning to it; a dash does not.
--
-- ⚠️ The gate rejects UNPITCHED sources. It does NOT protect against octave or
-- harmonic misassignment — a confidently periodic sample can still be promoted
-- to the wrong partial. Treat cents as advisory on gliding sources: two 808
-- kicks measured 17 cents apart straddled G/G# and displayed different names.

local M = {}

-- ═══════════════════════════════════════════════════════════════════════════
-- TUNABLES — every calibrated constant lives here (retune without re-reading)
-- ═══════════════════════════════════════════════════════════════════════════

M.CONST = {
  FMIN            = 25.0,   -- Hz, low enough for a sub-30 Hz 808
  FMAX            = 1000.0, -- Hz, above any sensible "root note"
  DECIM           = 4,      -- signal decimation factor (see design note 1)
  YIN_THRESHOLD   = 0.15,   -- paper's absolute threshold
  CONF_GATE       = 0.90,   -- calibrated; below this we show nothing

  SETTLE_FRAC     = 0.35,   -- start this far into the decay
  SETTLE_CAP      = 0.200,  -- but never later than this (s)
  DECAY_FLOOR     = 0.10,   -- window ends at -20 dB of post-attack level
  ENV_STEP        = 0.010,  -- envelope resolution (s)
  WIN_MAX         = 0.400,  -- cap analysis window length (s)
  -- ⚠️ DO NOT raise this to YIN's structural floor (2/FMIN = 80 ms at FMIN 25).
  -- It is tempting: a window under 2/FMIN trips `tau_max >= W` inside M.yin and
  -- returns nil however clean the signal, because W only exceeds tau_max once
  -- the window holds two periods of the LOWEST detectable frequency. But this
  -- value gates the window BEFORE the fallback ladder below has finished
  -- widening it, so raising it to 0.085 rejected windows that would otherwise
  -- have grown past the floor — measured 2026-08-01, it silently lost TR-808
  -- Tom 02 (conf 0.99) and Tom 03 (conf 1.00), both previously correct.
  -- Short-window failure is already the RIGHT answer (25 Hz is unresolvable in
  -- 60 ms); it just surfaces as "no periodicity" rather than "too short".
  WIN_MIN         = 0.040,  -- floor for "there is anything here at all" (s)
  WIN_COMFORT     = 0.080,  -- want at least this much after the settle start

  SILENCE_RMS     = 0.003,  -- whole-file silence gate
  BODY_RMS        = 0.002,  -- analysis-window silence gate

  SUBH_MULTIPLES  = { 2, 3, 4, 5 },
  SUBH_MARGIN     = 1.6,    -- f0 must be beaten by this before we promote
  SUBH_SUPPORT    = 0.30,   -- a partial counts as "supported" at 30% of peak

  READ_MAX_S      = 2.0,    -- never read more than this from a file (s)
}

M.NOTE_NAMES = { "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B" }

-- ═══════════════════════════════════════════════════════════════════════════
-- PURE DSP — no reaper.* below this line until the FILE I/O section.
-- Keeping the core REAPER-free makes it unit-probeable and reusable.
-- ═══════════════════════════════════════════════════════════════════════════

function M.hz_to_note(f)
  if not f or f <= 0 then return nil end
  local midi    = 69.0 + 12.0 * (math.log(f / 440.0) / math.log(2))
  local nearest = math.floor(midi + 0.5)
  return {
    midi   = midi,
    note   = nearest,
    name   = M.NOTE_NAMES[(nearest % 12) + 1],
    octave = math.floor(nearest / 12) - 1,
    cents  = (midi - nearest) * 100.0,
  }
end

function M.rms(x, a, b)
  a, b = a or 1, b or #x
  if b < a then return 0.0 end
  local s = 0.0
  for i = a, b do s = s + x[i] * x[i] end
  return math.sqrt(s / (b - a + 1))
end

-- Anti-aliased decimation: box average then pick every Nth. Crude, but its
-- nulls sit near the folding frequencies, which is enough below 1 kHz.
function M.decimate(x, factor)
  if factor <= 1 then return x end
  local out, n, i = {}, #x, 1
  while i + factor - 1 <= n do
    local acc = 0.0
    for j = 0, factor - 1 do acc = acc + x[i + j] end
    out[#out + 1] = acc / factor
    i = i + factor
  end
  return out
end

-- Single-frequency DFT magnitude. Used only for subharmonic arbitration, so a
-- handful of these is far cheaper than a full FFT.
function M.goertzel(x, sr, freq, a, b)
  a, b = a or 1, b or #x
  local n = b - a + 1
  if n < 8 or freq <= 0 or freq >= sr * 0.5 then return 0.0 end
  local coeff = 2.0 * math.cos(2.0 * math.pi * freq / sr)
  local s1, s2 = 0.0, 0.0
  for i = a, b do
    local s0 = x[i] + coeff * s1 - s2
    s2, s1 = s1, s0
  end
  local p = s1 * s1 + s2 * s2 - coeff * s1 * s2
  if p < 0 then p = 0 end
  return math.sqrt(p) / n
end

-- ── YIN core ───────────────────────────────────────────────────────────────
-- Returns f0_hz, confidence. confidence = 1 - d'(tau*) (aperiodicity
-- complement): 1.0 is perfectly periodic, ~0.5 is noise.
function M.yin(sig, sr, fmin, fmax, threshold)
  local C = M.CONST
  fmin, fmax = fmin or C.FMIN, fmax or C.FMAX
  threshold = threshold or C.YIN_THRESHOLD

  local n       = #sig
  local tau_min = math.max(2, math.floor(sr / fmax))
  local tau_max = math.floor(sr / fmin) + 1
  local W       = tau_max * 2                 -- integration window >= 2 periods

  if n < W + tau_max then
    W = n - tau_max
    if W < 64 then return nil, 0.0 end
  end
  if tau_max >= W then return nil, 0.0 end

  -- Step 1/2: difference function d(tau)  [paper eq. 6]
  local d = {}
  for tau = 1, tau_max do
    local s = 0.0
    for j = 1, W do
      local diff = sig[j] - sig[j + tau]
      s = s + diff * diff
    end
    d[tau] = s
  end

  -- Step 3: cumulative mean normalised difference  [paper eq. 8]
  -- SEQUENTIAL over tau — this is why the lag axis cannot be decimated.
  local dp, running = { [0] = 1.0 }, 0.0
  for tau = 1, tau_max do
    running = running + d[tau]
    dp[tau] = (running > 0) and (d[tau] * tau / running) or 1.0
  end

  -- Step 4: absolute threshold, then walk down into the local minimum
  local tau_star, tau = -1, tau_min
  while tau <= tau_max do
    if dp[tau] < threshold then
      while tau + 1 <= tau_max and dp[tau + 1] < dp[tau] do tau = tau + 1 end
      tau_star = tau
      break
    end
    tau = tau + 1
  end
  if tau_star < 0 then                        -- nothing cleared: take global min
    local best = nil
    for t = tau_min, tau_max do
      if best == nil or dp[t] < dp[best] then best = t end
    end
    if best == nil then return nil, 0.0 end
    tau_star = best
  end

  -- Step 5: parabolic interpolation for a sub-sample period
  local t = tau_star
  if t >= 2 and t < tau_max then
    local y0, y1, y2 = dp[t - 1], dp[t], dp[t + 1]
    local denom = 2.0 * (2.0 * y1 - y0 - y2)
    if math.abs(denom) > 1e-12 then t = t + (y2 - y0) / denom end
  end
  if t <= 0 then return nil, 0.0 end

  local f0 = sr / t
  if f0 < fmin or f0 > fmax then return nil, 0.0 end
  local conf = 1.0 - dp[tau_star]
  if conf < 0 then conf = 0 elseif conf > 1 then conf = 1 end
  return f0, conf
end

-- ── Subharmonic promote (design note 3) ────────────────────────────────────
-- Returns corrected_f0, multiplier.
function M.promote(sig, sr, f0, a, b, fmax)
  local C = M.CONST
  fmax = fmax or C.FMAX
  if not f0 or f0 <= 0 then return f0, 1 end

  local mags = { [1] = M.goertzel(sig, sr, f0, a, b) }
  local peak = mags[1]
  local ks   = { 1 }
  for _, k in ipairs(C.SUBH_MULTIPLES) do
    local fk = f0 * k
    if fk > fmax or fk >= sr * 0.45 then break end
    mags[k] = M.goertzel(sig, sr, fk, a, b)
    ks[#ks + 1] = k
    if mags[k] > peak then peak = mags[k] end
  end

  -- f0 itself well supported -> YIN was right, leave it alone.
  if peak <= 0 or mags[1] * C.SUBH_MARGIN >= peak then return f0, 1 end

  -- Otherwise take the LOWEST partial carrying real support (not the loudest).
  table.sort(ks)
  for _, k in ipairs(ks) do
    if mags[k] >= C.SUBH_SUPPORT * peak then return f0 * k, k end
  end
  return f0, 1
end

-- ── Settle-aware analysis window (design note 2) ───────────────────────────
-- Returns first, last (1-based, inclusive) or nil.
function M.window(sig, sr)
  local C, n = M.CONST, #sig
  local pk, pi = 0.0, 1
  for i = 1, n do
    local a = sig[i] >= 0 and sig[i] or -sig[i]
    if a > pk then pk, pi = a, i end
  end

  local step = math.max(1, math.floor(sr * C.ENV_STEP))
  local ref, cnt = 0.0, 0
  for i = pi, math.min(n - step, pi + step * 5), step do    -- post-attack level
    local v = M.rms(sig, i, i + step - 1)
    if v > ref then ref = v end
    cnt = cnt + 1
  end
  if ref <= 0 or cnt == 0 then return nil end

  -- Start the decay search one step past the attack so the transient itself
  -- can never terminate the window.
  local floor_v, last, decayed = ref * C.DECAY_FLOOR, n, false
  for i = pi + step * 2, n - step, step do
    if M.rms(sig, i, i + step - 1) < floor_v then
      last, decayed = i, true
      break
    end
  end

  -- SUSTAINED MATERIAL (a held bass/synth one-shot, a loop): there is no decay
  -- to anchor to, and the "peak" of a steady waveform is whichever sample lands
  -- nearest the crest — an essentially arbitrary index that can sit anywhere in
  -- the file. Anchoring the window to it is then unstable: measured 2026-08-01,
  -- the same 220 Hz sine put its peak at 57% of the file under one libm and near
  -- the end under another, which collapsed the window to nothing.
  -- Detect the sustained case by a tail that is still strong, and anchor at the
  -- START instead. A merely truncated decay tail fails this test, so percussive
  -- behaviour (and every calibrated result) is unchanged.
  if not decayed and M.rms(sig, n - step + 1, n) > ref * 0.5 then
    pi, last = 1, n
  end

  local span  = last - pi
  local first = pi + math.min(math.floor(sr * C.SETTLE_CAP),
                              math.floor(span * C.SETTLE_FRAC))
  if last - first < math.floor(sr * C.WIN_COMFORT) then      -- back off
    first = pi + math.min(math.floor(sr * 0.060), math.floor(span * 0.15))
  end
  if last - first < math.floor(sr * 0.060) then              -- back off further
    first = pi
    last  = math.min(n, pi + math.floor(sr * 0.250))
  end
  if last - first < math.floor(sr * C.WIN_MIN) then return nil end
  return first, math.min(last, first + math.floor(sr * C.WIN_MAX))
end

-- ── Top-level analysis (pure Lua) ──────────────────────────────────────────
-- samples: 1-based array of mono floats. Returns a result table, or nil.
--   { f0, f0_raw, mult, conf, show, note, name, octave, cents, midi,
--     win_start, win_end, why }
-- `show` is the UI gate: true only when conf >= CONF_GATE.
function M.analyse(samples, sr)
  local C = M.CONST
  if not samples or #samples < 64 or not sr or sr <= 0 then
    return nil
  end
  if M.rms(samples) < C.SILENCE_RMS then
    return { show = false, why = "silent" }
  end

  local a, b = M.window(samples, sr)
  if not a then return { show = false, why = "no usable body" } end
  if M.rms(samples, a, b) < C.BODY_RMS then
    return { show = false, why = "body too quiet" }
  end

  -- Slice, decimate, run YIN at the reduced rate.
  local seg = {}
  for i = a, b do seg[#seg + 1] = samples[i] end
  local ds  = M.decimate(seg, C.DECIM)
  local dsr = sr / C.DECIM
  if dsr * 0.5 <= C.FMAX then
    return { show = false, why = "decimation too aggressive" }
  end

  local f0_raw, conf = M.yin(ds, dsr)
  if not f0_raw then
    return { show = false, why = "no periodicity", conf = conf or 0 }
  end

  -- Promote against the FULL-RATE segment (partials above dsr/2 matter).
  local f0, mult = M.promote(samples, sr, f0_raw, a, b)

  local nt = M.hz_to_note(f0)
  if not nt then return { show = false, why = "bad frequency" } end

  return {
    f0 = f0, f0_raw = f0_raw, mult = mult, conf = conf,
    show = conf >= C.CONF_GATE,
    midi = nt.midi, note = nt.note, name = nt.name,
    octave = nt.octave, cents = nt.cents,
    win_start = a, win_end = b,
    why = (conf >= C.CONF_GATE) and "ok" or "below gate",
  }
end

-- Formats a result for the LCD / browser column. Returns "F#1" or "—".
function M.format(r, with_cents)
  if not r or not r.show then return "—" end
  local s = string.format("%s%d", r.name, r.octave)
  if with_cents then s = s .. string.format(" %+.0f", r.cents) end
  return s
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FILE I/O — needs REAPER. Reads REAL PCM via AudioAccessor, never GetPeaks:
-- peak data is a rectified envelope whose harmonic content is a distortion of
-- the signal, which is exactly what a pitch estimator must not be fed.
-- ═══════════════════════════════════════════════════════════════════════════

-- Scratch-track pattern mirrors Swing_Kit_Bridge.lua:3260 — AudioAccessor
-- needs an item, an item needs a track, and using the user's first track
-- pollutes it and leaves a stray undo step. Insert at the END, then delete.
local function acquire_scratch()
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  return reaper.GetTrack(0, idx)
end

local function release_scratch(tr)
  if tr then reaper.DeleteTrack(tr) end
  reaper.PreventUIRefresh(-1)
end

-- Reads up to READ_MAX_S of mono-summed PCM from a file.
-- Returns samples, samplerate — or nil, err.
function M.read_file(path, max_s)
  if not path then return nil, "no path" end
  local src = reaper.PCM_Source_CreateFromFileEx(path, true)
  if not src then return nil, "unreadable" end

  local sr     = reaper.GetMediaSourceSampleRate(src)
  local length = reaper.GetMediaSourceLength(src)
  local nch    = reaper.GetMediaSourceNumChannels(src)
  if nch < 1 then nch = 1 end
  if sr <= 0 or length <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil, "empty source"
  end

  local want = math.floor(math.min(length, max_s or M.CONST.READ_MAX_S) * sr)
  if want < 64 then
    reaper.PCM_Source_Destroy(src)
    return nil, "too short"
  end

  local tr = acquire_scratch()
  if not tr then
    reaper.PCM_Source_Destroy(src)
    release_scratch(nil)
    return nil, "no scratch track"
  end

  local item = reaper.AddMediaItemToTrack(tr)
  local take = item and reaper.AddTakeToMediaItem(item)
  if not take then
    reaper.PCM_Source_Destroy(src)
    release_scratch(tr)
    return nil, "no take"
  end
  reaper.SetMediaItemTake_Source(take, src)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", length)

  local acc = reaper.CreateTakeAudioAccessor(take)
  if not acc then
    release_scratch(tr)          -- DeleteTrack destroys item+take+source
    return nil, "no accessor"
  end

  local buf = reaper.new_array(want * nch)
  buf.clear()
  local ok = reaper.GetAudioAccessorSamples(acc, sr, nch, 0.0, want, buf)
  reaper.DestroyAudioAccessor(acc)
  release_scratch(tr)
  if ok ~= 1 then return nil, "read failed" end

  -- Mono-sum (interleaved -> 1-based mono array)
  local out = {}
  if nch == 1 then
    for i = 1, want do out[i] = buf[i] end
  else
    for i = 0, want - 1 do
      local acc_v = 0.0
      for c = 1, nch do acc_v = acc_v + buf[i * nch + c] end
      out[i + 1] = acc_v / nch
    end
  end
  return out, sr
end

-- Convenience: path -> analysis result (or nil, err).
function M.detect_file(path, max_s)
  local samples, sr = M.read_file(path, max_s)
  if not samples then return nil, sr end
  return M.analyse(samples, sr)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SYNTH PADS — exact, no detection. Mirrors rk_synthdrums.jsfx-inc.
-- Returns a result table shaped like analyse()'s, with conf = 1.
-- family: "kick" | "snare" | "tom".  Hats/cymbals have NO fundamental.
-- ═══════════════════════════════════════════════════════════════════════════

function M.synth_root(family, mac0, tune)
  mac0, tune = mac0 or 0.5, tune or 0.0
  local base
  if     family == "kick"  then base = 35.0  * 2 ^ ((mac0 - 0.5) * 1.5 + tune / 12)
  elseif family == "snare" then base = 165.0 * 2 ^ ((mac0 - 0.5) * 1.2 + tune / 12)
  elseif family == "tom"   then base = 95.0  * 2 ^ ((mac0 - 0.5) * 1.5 + tune / 12)
  else return { show = false, why = "no fundamental (noise-based family)" } end

  local nt = M.hz_to_note(base)
  return {
    f0 = base, conf = 1.0, show = true, mult = 1,
    midi = nt.midi, note = nt.note, name = nt.name,
    octave = nt.octave, cents = nt.cents, why = "synth (exact)",
  }
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GMEM BAND — publish per-pad results for the JSFX readout.
--
-- `G` is rk_lua_core's GMEM table. It is passed in rather than dofile'd so this
-- module stays standalone-probeable, AND so the band has exactly ONE definition
-- (rk_lua_core + Swing_ReaKit.jsfx) instead of a third copy here.
--
-- ⚠️ The band is PER-INSTANCE (slot-strided). The legacy GS_PAD_KEY_BASE
-- (1416-1431) is flat and collides across Swing instances — do not use it.
--
-- Publish discipline: VER is written LAST, so a JSFX reader that observes
-- VER > 0 is guaranteed every other field of that record is already committed.
-- ═══════════════════════════════════════════════════════════════════════════

function M.note_name(midi)
  if not midi or midi < 0 then return nil end
  local n = math.floor(midi)
  return M.NOTE_NAMES[(n % 12) + 1], math.floor(n / 12) - 1
end

local function rn_base(G, slot, pad)
  return G.ROOTNOTE_BASE + slot * G.ROOTNOTE_STRIDE + pad * G.ROOTNOTE_FIELDS
end

-- Publish one pad. `r` is an analyse() / synth_root() result, or nil to say
-- "no root note here". `src` defaults to RN_SRC_DETECTED; pass RN_SRC_SYNTH
-- for analytic synth values.
function M.publish(G, slot, pad, r, src)
  if not G or not slot or slot < 0 or not pad or pad < 0 then return false end
  local b    = rn_base(G, slot, pad)
  local show = (r ~= nil) and (r.show == true) and (r.note ~= nil)
  reaper.gmem_write(b + G.RN_OFF_NOTE,  show and r.note  or -1)
  reaper.gmem_write(b + G.RN_OFF_CENTS, show and r.cents or 0)
  reaper.gmem_write(b + G.RN_OFF_CONF,  (r and r.conf) or 0)
  reaper.gmem_write(b + G.RN_OFF_SRC,
                    show and (src or G.RN_SRC_DETECTED) or G.RN_SRC_NONE)
  -- VER LAST — everything above must be visible before the record goes live.
  local ver = (reaper.gmem_read(b + G.RN_OFF_VER) or 0) + 1
  reaper.gmem_write(b + G.RN_OFF_VER, ver)
  return true
end

-- Publish "nothing here" (pad cleared, or analysis declined).
function M.clear(G, slot, pad)
  return M.publish(G, slot, pad, nil)
end

-- Read a published record back (probes, and any Lua-side consumer).
function M.read(G, slot, pad)
  if not G or not slot or slot < 0 then return nil end
  local b = rn_base(G, slot, pad)
  if (reaper.gmem_read(b + G.RN_OFF_VER) or 0) <= 0 then return nil end
  local note = math.floor(reaper.gmem_read(b + G.RN_OFF_NOTE))
  local conf = reaper.gmem_read(b + G.RN_OFF_CONF)
  local src  = math.floor(reaper.gmem_read(b + G.RN_OFF_SRC))
  if note < 0 then
    return { show = false, conf = conf, src = src, why = "no root note" }
  end
  local name, octave = M.note_name(note)
  return { show = true, note = note, name = name, octave = octave,
           cents = reaper.gmem_read(b + G.RN_OFF_CENTS), conf = conf, src = src }
end

-- Consume the JSFX -> bridge re-analysis request. Edge-triggered on the seq
-- cell, so the caller keeps the last seq it saw:
--   local req; req, my_seq = rn.poll_request(G, my_seq)
-- Returns nil when nothing new. req.pad == -1 means "every pad on that slot".
function M.poll_request(G, last_seq)
  if not G then return nil, last_seq end
  local seq = reaper.gmem_read(G.ROOTNOTE_REQ) or 0
  if seq == (last_seq or 0) then return nil, last_seq or 0 end
  return {
    slot = math.floor(reaper.gmem_read(G.ROOTNOTE_REQ + 1) or -1),
    pad  = math.floor(reaper.gmem_read(G.ROOTNOTE_REQ + 2) or -1),
  }, seq
end

return M
