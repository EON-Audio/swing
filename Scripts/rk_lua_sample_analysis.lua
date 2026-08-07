-- rk_lua_sample_analysis.lua — measured sample analysis for EON Swing.
--
-- Raw audio measurement (amplitude envelope + spectrum) plus the tag vocabulary
-- that turns those measurements into labels. Consumed by Swing_Browser.lua's
-- analysis ladder; see Spec_Swing_Sample_Analysis.md.
--
-- ─────────────────────────────────────────────────────────────────────────────
-- PORTED FROM TK KIT MAKER — used under an explicit MIT grant.
--
--   Source: TK Kit Maker v0.2.35, `core/analyzer.lua` and `core/tags.lua`
--           https://github.com/TouristKiller/TK-Scripts
--   Author: TouristKiller (Kurt) & Flurmechanik
--
--   Copyright (c) TouristKiller
--
--   Permission is hereby granted, free of charge, to any person obtaining a
--   copy of this software and associated documentation files (the "Software"),
--   to deal in the Software without restriction, including without limitation
--   the rights to use, copy, modify, merge, publish, distribute, sublicense,
--   and/or sell copies of the Software, and to permit persons to whom the
--   Software is furnished to do so, subject to the following conditions:
--
--   The above copyright notice and this permission notice shall be included in
--   all copies or substantial portions of the Software.
--
--   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
--   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
--   DEALINGS IN THE SOFTWARE.
--
--   Not ported: TK's TSV tag cache, job scheduler and frame budget. Swing
--   already has a persistent cache and a budgeted defer queue
--   (Swing_Browser.lua) — this module is measurement + vocabulary only.
-- ─────────────────────────────────────────────────────────────────────────────
--
-- (c) EON Studios for the Swing-side glue (serialisation, module shape).

local r = reaper
local M = {}

-- ═══════════════════════════════════════════════════════════════════════════════
-- MEASUREMENT CORE  (TK Kit Maker core/analyzer.lua)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- Audio is read straight from the file through PCM_Source_GetPeaks — no item,
-- take or track needed — and the FFT is REAPER's native fft_real.
--
-- A one-shot is read ONCE, at its own samplerate, and the 1 ms envelope is
-- folded out of those samples here. The obvious split — a cheap coarse pass for
-- the envelope plus a sample block at the onset — decodes a short file very
-- nearly twice, because the second read still has to work its way from the start
-- of the file to the onset. Longer material keeps the two-pass route, where
-- holding every sample in memory would cost more than the extra decode:
--   1. coarse envelope, 1 ms grid over the whole file -> peak, decay, tail
--   2. sample block at the onset, ~8k @ samplerate    -> attack, spectrum, width
--
-- Only RAW measurements are returned (and cached); every threshold that turns
-- them into a label lives in the vocabulary section below, so the vocabulary can
-- be retuned without re-analysing a library.
--
-- All buffers are module-level and reused: analysing 10k files must not
-- allocate 10k arrays.

local ENV_RATE     = 1000   -- coarse envelope resolution (Hz) = 1 ms per point
local ENV_MAX_SEC  = 12     -- cap for very long files; longer tails read as "legato"
local FFT_SIZE     = 4096   -- 10.8 Hz per bin @ 44.1k — enough to split SUB from LOW
local FFT_FRAMES   = 3
local FFT_HOP      = 2048
local PRE_ROLL_S   = 0.005  -- read a little before the onset so the attack is complete
-- Up to this length a file is read in one go. 5 s at 48 kHz stereo is about
-- 960k array entries — fine to hold, and it covers nearly every one-shot.
local SINGLE_READ_MAX_SEC = 5

-- Band edges follow the 9-axes tag system (SUB .. AIR).
M.BANDS = {
  { id = "sub",  label = "SUB",  lo = 20,    hi = 60 },
  { id = "low",  label = "LOW",  lo = 60,    hi = 120 },
  { id = "lmid", label = "LMID", lo = 120,   hi = 400 },
  { id = "mid",  label = "MID",  lo = 400,   hi = 2000 },
  { id = "hmid", label = "HMID", lo = 2000,  hi = 6000 },
  { id = "high", label = "HIGH", lo = 6000,  hi = 12000 },
  { id = "air",  label = "AIR",  lo = 12000, hi = 20000 },
}
M.BAND_COUNT = #M.BANDS

local ONSET_FLOOR  = 0.08   -- fraction of peak that counts as "the hit started"
local DECAY_FLOOR  = 0.01   -- -40 dB below peak
local EARLY_FLOOR  = 0.3162 -- -10 dB below peak
local DIRECT_MS    = 50     -- window that counts as the direct hit, not the room

-- Attack is measured on a high-passed copy of the onset. A 50 Hz sine cannot
-- physically reach its first peak in under 4 ms, so measuring the raw waveform
-- would call every sub-heavy kick "slow"; what we hear as the transient sits
-- well above that. Two cascaded one-poles (12 dB/oct) keep a pure sub out of the
-- measurement while a broadband click passes untouched — sources with nothing up
-- there fall back to the full-band envelope, which is right: they have no
-- transient to measure.
local ATTACK_HP_HZ     = 400
local ATTACK_WINDOW_MS = 90
local ATTACK_HOLD_S    = 0.002
local ATTACK_MIN_HP    = 0.05 -- HP peak below this fraction of the full peak = fall back
-- Rise measured between these two fractions of the peak, then scaled back up to
-- a full 0..100% attack. Using the FIRST crossing of each makes it robust on
-- noisy sources, where the single loudest sample lands at a random spot.
local ATTACK_LO_FRAC   = 0.10
local ATTACK_HI_FRAC   = 0.80
local ATTACK_SCALE     = 1 / (ATTACK_HI_FRAC - ATTACK_LO_FRAC)
-- Floor for the fallback. A source with nothing above 400 Hz cannot sound spiky,
-- so its quarter-period (4-5 ms for a 55 Hz kick) must not masquerade as a hard
-- transient — without this every clickless sub kick reads as HARD.
local ATTACK_BANDLIMIT_MS = 6

-- Reused buffers ------------------------------------------------------------

local arrays = {}
local function scratch_array(name, need)
  local slot = arrays[name]
  if not slot or slot.cap < need then
    if not r.new_array then return nil end
    slot = { buf = r.new_array(need), cap = need }
    arrays[name] = slot
  end
  return slot.buf
end

local env_amp, hull, mag, mono, hp_env = {}, {}, {}, {}, {}

local hann = {}
for i = 1, FFT_SIZE do
  hann[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (FFT_SIZE - 1))
end

local function clamp01(v)
  if not v or v ~= v then return 0 end -- nil / NaN
  if v < 0 then return 0 end
  if v > 1 then return 1 end
  return v
end

-- Reading -------------------------------------------------------------------

-- Fills `out` with `count` mono peak-amplitude values (max of |max| and |min|
-- across channels). Returns the number of points, or nil when the block is
-- unreadable or digital silence.
local function read_envelope(src, rate, start_time, nch, count, out, name)
  local buf = scratch_array(name, count * nch * 2)
  if not buf then return nil end
  buf.clear()
  if not r.PCM_Source_GetPeaks(src, rate, start_time, nch, count, 0, buf) then return nil end

  local base = count * nch
  local any = false
  for i = 1, count do
    local hi = 0
    for ch = 1, nch do
      local idx = (i - 1) * nch + ch
      local a = math.abs(buf[idx] or 0)
      local b = math.abs(buf[base + idx] or 0)
      if b > a then a = b end
      if a > hi then hi = a end
    end
    out[i] = hi
    if hi > 0 then any = true end
  end
  if not any then return nil end
  return count
end

-- Reads `count` real samples at the source's own rate (peakrate == samplerate
-- makes GetPeaks hand back the samples themselves). Fills `mono` and returns the
-- mid/side energy split, which is our stereo-width measure.
--
-- Pass `env_out` to have the 1 ms envelope built in the same sweep. Doing it
-- afterwards meant walking every sample of the file a second time, and once the
-- double decode was gone that second walk was a good share of what was left.
--
-- Mono and stereo are handled without the per-channel loop for the same reason:
-- between them they are practically every sample anyone owns.
local function read_samples(src, sr, start_time, nch, count, env_out)
  local buf = scratch_array("blk", count * nch * 2)
  if not buf then return nil end
  buf.clear()
  if not r.PCM_Source_GetPeaks(src, sr, start_time, nch, count, 0, buf) then return nil end

  local mid_e, side_e = 0, 0
  local env_step = env_out and (sr / ENV_RATE) or 0
  local env_n, env_hi, env_edge, env_any = 0, 0, env_step, false

  for i = 1, count do
    local v
    if nch == 1 then
      v = buf[i] or 0
    elseif nch == 2 then
      local j = (i - 1) * 2
      local l = buf[j + 1] or 0
      local rt = buf[j + 2] or 0
      local m = (l + rt) * 0.5
      local s = (l - rt) * 0.5
      mid_e = mid_e + m * m
      side_e = side_e + s * s
      v = m
    else
      local j = (i - 1) * nch
      local sum = 0
      for ch = 1, nch do sum = sum + (buf[j + ch] or 0) end
      v = sum / nch
      local l = buf[j + 1] or 0
      local rt = buf[j + 2] or 0
      local m = (l + rt) * 0.5
      local s = (l - rt) * 0.5
      mid_e = mid_e + m * m
      side_e = side_e + s * s
    end
    mono[i] = v

    if env_out then
      local a = v < 0 and -v or v
      if a > env_hi then env_hi = a end
      if i >= env_edge then
        env_n = env_n + 1
        env_out[env_n] = env_hi
        if env_hi > 0 then env_any = true end
        env_hi = 0
        env_edge = env_edge + env_step
      end
    end
  end

  if env_out and not env_any then return nil end
  return count, mid_e, side_e, env_n
end

-- Measuring -----------------------------------------------------------------

-- Attack time in milliseconds from the high-passed onset, plus the level that
-- measurement was taken at (so the caller can reject it as too quiet).
-- `from` is where in `mono` to start, 1-based.
local function attack_from_block(from, n, sr)
  local win = math.min(n - from + 1, math.floor(ATTACK_WINDOW_MS * sr / 1000))
  if win < 64 then return nil, 0 end

  local coef = 1 / (1 + 2 * math.pi * ATTACK_HP_HZ / sr)
  local hold = math.exp(-1 / (sr * ATTACK_HOLD_S))
  local in1, out1, in2, out2, level = 0, 0, 0, 0, 0
  local peak = 0

  for i = 1, win do
    local x = mono[from + i - 1] or 0
    local y1 = coef * (out1 + x - in1)
    in1, out1 = x, y1
    local y2 = coef * (out2 + y1 - in2)
    in2, out2 = y1, y2
    local m = y2 < 0 and -y2 or y2
    level = m > level and m or level * hold
    hp_env[i] = level
    if level > peak then peak = level end
  end
  if peak <= 0 then return nil, 0 end

  local lo, hi = peak * ATTACK_LO_FRAC, peak * ATTACK_HI_FRAC
  local lo_i, hi_i
  for i = 1, win do
    if not lo_i and hp_env[i] >= lo then lo_i = i end
    if hp_env[i] >= hi then hi_i = i break end
  end
  if not lo_i or not hi_i then return nil, peak end
  return (hi_i - lo_i) * ATTACK_SCALE * 1000 / sr, peak
end

local function analyze_source(src)
  local sr = r.GetMediaSourceSampleRate(src) or 0
  if sr <= 0 then sr = 44100 end
  local nch = r.GetMediaSourceNumChannels(src) or 1
  if nch < 1 then nch = 1 end
  local len, is_qn = r.GetMediaSourceLength(src)
  if is_qn or not len or len <= 0 then return nil end

  -- 1. The envelope. Short files hand over every sample in one read and the
  --    envelope is folded out of them; long ones get the cheap coarse pass.
  local single = len <= SINGLE_READ_MAX_SEC
  local total_samples = math.floor(len * sr)
  if total_samples < 256 then single = false end

  local env_n, mid_e, side_e
  if single then
    local got, me, se, en = read_samples(src, sr, 0, nch, total_samples, env_amp)
    if got and en and en >= 4 then
      mid_e, side_e, env_n = me, se, en
    else
      -- Unreadable, silent, or too short to make an envelope worth the name.
      single = false
    end
  end

  if not single then
    env_n = math.floor(math.min(len, ENV_MAX_SEC) * ENV_RATE)
    if env_n < 8 then env_n = 8 end
    if not read_envelope(src, ENV_RATE, 0, nch, env_n, env_amp, "env") then return nil end
  end

  local peak, peak_i = 0, 1
  for i = 1, env_n do
    if env_amp[i] > peak then peak, peak_i = env_amp[i], i end
  end
  if peak <= 1e-6 then return nil end

  local onset_i = peak_i
  for i = 1, peak_i do
    if env_amp[i] >= peak * ONSET_FLOOR then onset_i = i break end
  end
  local onset_t = (onset_i - 1) / ENV_RATE

  -- Decay measured on a monotone hull, so a dip inside a still-ringing tail
  -- (tremolo, a modulated 808) does not end the decay early.
  hull[env_n] = env_amp[env_n]
  for i = env_n - 1, 1, -1 do
    local a, b = env_amp[i], hull[i + 1]
    hull[i] = a > b and a or b
  end

  local decay_i, early_i = env_n, env_n
  local floor_level, early_level = peak * DECAY_FLOOR, peak * EARLY_FLOOR
  local got_early = false
  for i = peak_i, env_n do
    if not got_early and hull[i] < early_level then
      early_i = i
      got_early = true
    end
    if hull[i] < floor_level then decay_i = i break end
  end
  local decay_ms = (decay_i - peak_i) * 1000 / ENV_RATE
  -- Time to -10 dB. Against the -40 dB decay this gives the SHAPE of the tail:
  -- a plain exponential always lands on 0.25, while a reverberant sample drops
  -- fast and then lingers, pushing the ratio down. That is the one dry/wet cue
  -- that also works on mono material.
  local decay10_ms = (early_i - peak_i) * 1000 / ENV_RATE

  -- Crest factor over the first 200 ms: distorted/limited material sits low.
  local rms_end = math.min(env_n, onset_i + 200)
  local acc, n_acc = 0, 0
  for i = onset_i, rms_end do
    acc = acc + env_amp[i] * env_amp[i]
    n_acc = n_acc + 1
  end
  local rms = n_acc > 0 and math.sqrt(acc / n_acc) or 0
  local crest_db = rms > 1e-9 and (20 * math.log(peak / rms) / math.log(10)) or 24

  -- Energy arriving after the direct hit, relative to the hit itself.
  local direct_end = math.min(env_n, peak_i + math.floor(DIRECT_MS * ENV_RATE / 1000))
  local direct, tail = 0, 0
  for i = peak_i, direct_end do direct = direct + env_amp[i] * env_amp[i] end
  for i = direct_end + 1, math.min(env_n, decay_i) do tail = tail + env_amp[i] * env_amp[i] end
  local tail_ratio = direct > 1e-12 and (tail / direct) or 0

  -- 2. Samples around the onset, for attack, spectrum and width. Already in
  --    hand on the single-read path; otherwise one more read.
  local base, avail
  if single then
    base = math.floor(onset_t * sr)
    avail = total_samples
  else
    local block_t = math.max(0, onset_t - PRE_ROLL_S)
    base = math.floor((onset_t - block_t) * sr)
    avail = base + FFT_SIZE + FFT_HOP * (FFT_FRAMES - 1)
    local got, me, se = read_samples(src, sr, block_t, nch, avail)
    if not got then return nil end
    mid_e, side_e = me, se
  end

  local attack_from = math.max(1, base + 1 - math.floor(PRE_ROLL_S * sr))
  local attack_ms, hp_peak = attack_from_block(attack_from, avail, sr)
  if not attack_ms or hp_peak < peak * ATTACK_MIN_HP then
    -- Nothing meaningful above 400 Hz: fall back to the full-band envelope,
    -- floored, because what it measures there is bandwidth, not attack.
    attack_ms = math.max(peak_i - onset_i, ATTACK_BANDLIMIT_MS)
  end

  local half = math.floor(FFT_SIZE / 2)
  for b = 1, half do mag[b] = 0 end
  local fft = scratch_array("fft", FFT_SIZE)
  if not fft then return nil end

  local frames = 0
  for f = 0, FFT_FRAMES - 1 do
    local off = base + f * FFT_HOP
    local energy = 0
    for i = 1, FFT_SIZE do
      local v = (mono[off + i] or 0) * hann[i]
      fft[i] = v
      energy = energy + v * v
    end
    if energy > 1e-10 then
      fft.fft_real(FFT_SIZE, true)
      for b = 1, half - 1 do
        local re = fft[b * 2] or 0
        local im = fft[b * 2 + 1] or 0
        mag[b] = mag[b] + math.sqrt(re * re + im * im)
      end
      frames = frames + 1
    end
  end
  if frames == 0 then return nil end

  local bin_hz = sr / FFT_SIZE
  local bands = {}
  for i = 1, M.BAND_COUNT do bands[i] = 0 end

  local total, log_sum, log_w = 0, 0, 0
  local geo_sum, arith_sum, flat_n = 0, 0, 0
  local pitch_mag, pitch_hz = 0, 0
  local hf = 0

  for b = 1, half - 1 do
    local freq = b * bin_hz
    local m = mag[b]
    total = total + m

    for i = 1, M.BAND_COUNT do
      local band = M.BANDS[i]
      if freq >= band.lo and freq < band.hi then
        bands[i] = bands[i] + m
        break
      end
    end

    -- Centroid in log-frequency: an octave counts the same everywhere, which is
    -- what makes it usable as an evenly spread SUB..AIR axis.
    if freq >= 30 and freq <= 18000 then
      log_sum = log_sum + m * math.log(freq)
      log_w = log_w + m
    end
    if freq >= 50 and freq <= 16000 then
      geo_sum = geo_sum + math.log(m + 1e-9)
      arith_sum = arith_sum + m
      flat_n = flat_n + 1
    end
    if freq >= 40 and freq <= 2000 and m > pitch_mag then
      pitch_mag, pitch_hz = m, freq
    end
    if freq >= 4000 then hf = hf + m end
  end

  if total <= 0 or log_w <= 0 then return nil end

  local centroid = math.exp(log_sum / log_w)
  local flatness = 0
  if flat_n > 0 and arith_sum > 0 then
    flatness = clamp01(math.exp(geo_sum / flat_n) / (arith_sum / flat_n))
  end

  local band_max = 0
  for i = 1, M.BAND_COUNT do
    bands[i] = bands[i] / total
    if bands[i] > band_max then band_max = bands[i] end
  end
  if band_max > 0 then
    for i = 1, M.BAND_COUNT do bands[i] = bands[i] / band_max end
  end

  local width = 0
  if nch >= 2 and (mid_e + side_e) > 1e-12 then
    width = clamp01(side_e / (mid_e + side_e) * 2)
  end

  return {
    dur        = len,
    nch        = nch,
    attack_ms  = attack_ms,
    decay_ms   = decay_ms,
    decay10_ms = decay10_ms,
    crest_db   = crest_db,
    centroid   = centroid,
    flat       = flatness,
    pitch      = pitch_hz,
    tail_ratio = tail_ratio,
    hf_ratio   = hf / total,
    width      = width,
    bands      = bands,
  }
end

-- Measures one file. Returns a metrics table, or nil when the file cannot be
-- read or holds no signal. Never raises: one broken file must not stop a
-- 10,000 file batch.
function M.measure(path)
  if not r.PCM_Source_CreateFromFile or not r.PCM_Source_GetPeaks or not r.new_array then
    return nil
  end
  local src = r.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local ok, res = pcall(analyze_source, src)
  r.PCM_Source_Destroy(src)
  if not ok then return nil end
  return res
end

-- True when the running REAPER build has everything the analyser needs.
function M.available()
  return r.PCM_Source_CreateFromFile ~= nil
    and r.PCM_Source_GetPeaks ~= nil
    and r.new_array ~= nil
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- TAG VOCABULARY  (TK Kit Maker core/tags.lua)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- The measurement core above produces raw numbers only; every threshold that
-- turns a measurement into a label lives here, and the cache stores the raw
-- numbers — so the vocabulary can be retuned without re-analysing a library.
--
-- Axes and how they are derived:
--   FREQUENCY   dominant band + log-frequency centroid   — measured, reliable
--   TRANSIENT   attack time                              — measured, reliable
--   DECAY       peak to -40 dB                           — measured, reliable
--   TONALITY    spectral flatness (+ centroid, decay)    — measured, fair
--   SPATIALITY  post-direct energy + stereo width        — measured, rough
--   TEXTURE     HF content + crest factor                — measured, rough
--   FUNCTION    filename — Swing uses eon_filename_categorizer, not ported here
--
-- Confidence is carried per axis so the UI can be honest about which labels are
-- a measurement and which are an educated guess.

M.TRANSIENTS = { "SOFT", "MEDIUM", "HARD", "IMPACT" }
M.DECAYS     = { "SHORT", "MEDIUM", "LONG", "LEGATO" }
M.TONALITIES = { "NOISE", "PITCHED", "DEFINED", "CHROMATIC" }
M.SPACES     = { "DRY", "ROOM", "HALL", "WET" }

-- Vocabulary for the TEXTURE axis. NOT derived automatically: every cheap
-- measure of "processing" (HF content, crest factor) turns out to track
-- brightness rather than distortion, so a clean hi-hat reads as FILTHY. The raw
-- numbers it would need (hf_ratio, crest_db) are cached anyway, so a better
-- mapping — or manual tagging — can be added without re-analysing anything.
M.TEXTURES = { "CLEAN", "WARM", "CRUNCHY", "FILTHY" }

-- The continuous axes, in the order the UI shows them.
M.AXES = {
  { id = "transient", label = "Transient", key = "att01",   lo = "soft",  hi = "impact", conf = "high" },
  { id = "decay",     label = "Decay",     key = "dec01",   lo = "short", hi = "legato", conf = "high" },
  { id = "tone",      label = "Frequency", key = "tone01",  lo = "sub",   hi = "air",    conf = "high" },
  { id = "space",     label = "Space",     key = "space01", lo = "dry",   hi = "wet",    conf = "low"  },
}

M.CONFIDENCE = {
  band = "high", transient = "high", decay = "high",
  tonality = "fair", space = "low",
}

-- Tonality boundaries on spectral flatness. Above NOISE_FLATNESS there is no
-- pitch left (hats, snares); below PURE_FLATNESS the spectrum is essentially a
-- single partial (808, synth bass); in between sits a clear pitch carried by a
-- lot of overtone and skin content.
--
-- The lower line is deliberately low. At 0.12 — checked against a real library —
-- bongos, congas and deep toms all read as DEFINED, because acoustically they
-- sit close to a tuned sine; the tag system puts every hand drum under PITCHED
-- and reserves DEFINED for synthetic material. The upper line is left where it
-- is on purpose: dropping it would drag metallic and high-tuned toms into NOISE,
-- and those are already landing correctly.
local NOISE_FLATNESS = 0.30
local PURE_FLATNESS  = 0.05

local axis_by_id = {}
for _, a in ipairs(M.AXES) do axis_by_id[a.id] = a end

function M.axis(id)
  return axis_by_id[id]
end

-- Normalised position of `v` between `lo` and `hi` on a log scale, so that
-- doubling counts the same everywhere — how we hear time and pitch.
local function log_norm(v, lo, hi)
  v = math.max(lo, math.min(hi, tonumber(v) or lo))
  return clamp01((math.log(v) - math.log(lo)) / (math.log(hi) - math.log(lo)))
end

local function bucket(v, edges)
  for i = 1, #edges do
    if v < edges[i] then return i end
  end
  return #edges + 1
end

-- Position of a frequency on the SUB..AIR axis: spread evenly across the seven
-- bands, not evenly across log frequency.
--
-- A plain log scale from 30 Hz to 18 kHz spends its bottom third on 20-400 Hz,
-- where only kicks and toms live, and crams every clap, snare and hat into the
-- top quarter — measured on a real library, hats all pile up against the end of
-- the axis. Stretching each band to an equal slice puts the material where the
-- vocabulary says it is, and leaves the axis usable as a coordinate rather than
-- a heap.
local function band_position(hz)
  local n = M.BAND_COUNT
  if not hz or hz <= M.BANDS[1].lo then return 0 end
  if hz >= M.BANDS[n].hi then return 1 end
  for i = 1, n do
    local b = M.BANDS[i]
    if hz < b.hi then
      local frac = (math.log(hz) - math.log(b.lo)) / (math.log(b.hi) - math.log(b.lo))
      return (i - 1 + clamp01(frac)) / n
    end
  end
  return 1
end

-- Turns raw metrics into the labelled axes. Pure and cheap: the UI may call this
-- every frame for the selected sample.
function M.derive(m)
  if not m then return nil end

  local att01 = 1 - log_norm(m.attack_ms, 0.2, 60)
  local dec01 = log_norm(m.decay_ms, 5, 4000)
  local tone01 = band_position(m.centroid)

  -- Dry/wet needs stereo. The decay SHAPE alone (a plain exponential spends a
  -- quarter of its -40 dB time reaching -10 dB; a reverberant tail drops fast
  -- then lingers, pushing that fraction down) cannot tell a room apart from a
  -- kick whose click decays faster than its body — both are two-stage decays.
  -- Stereo decorrelation is the cue that actually separates them, so on mono
  -- material this axis reports nothing rather than guessing.
  local space01, space_known = nil, false
  if (m.nch or 1) >= 2 then
    local shape = m.decay_ms > 0 and (m.decay10_ms / m.decay_ms) or 0.25
    local diffuse = clamp01((0.25 - shape) / 0.15)
    space01 = clamp01(0.55 * clamp01(m.width) + 0.45 * diffuse)
    space_known = true
  end

  -- Dominant band, not the centroid: a kick's centroid is dragged upward by its
  -- click, but its energy — and what we call it — sits in SUB/LOW.
  local band, band_max = 1, -1
  for i = 1, M.BAND_COUNT do
    local e = (m.bands and m.bands[i]) or 0
    if e > band_max then band_max, band = e, i end
  end

  local tonality
  if m.flat > NOISE_FLATNESS then
    tonality = 1 -- NOISE
  elseif m.flat > PURE_FLATNESS then
    tonality = 2 -- PITCHED
  elseif m.centroid > 800 and m.decay_ms > 300 then
    tonality = 4 -- CHROMATIC
  else
    tonality = 3 -- DEFINED
  end

  return {
    att01 = att01, dec01 = dec01, tone01 = tone01, space01 = space01,
    space_known = space_known,

    band = band,
    band_label = M.BANDS[band].label,
    -- Attack buckets are read off the high-passed onset; SOFT..IMPACT runs the
    -- opposite way to the millisecond scale, hence the flip. Decay buckets use
    -- the -40 dB time, which runs longer than the "perceived" length in the tag
    -- system table — a closed hat lands near 60 ms, not under 50.
    transient = 5 - bucket(m.attack_ms, { 1.5, 5, 15 }),
    decay = bucket(m.decay_ms, { 120, 450, 1500 }),
    tonality = tonality,
    space = space01 and bucket(space01, { 0.18, 0.38, 0.62 }) or nil,
  }
end

function M.derive_labels(d)
  if not d then return nil end
  return {
    band = d.band_label,
    transient = M.TRANSIENTS[d.transient],
    decay = M.DECAYS[d.decay],
    tonality = M.TONALITIES[d.tonality],
    space = d.space and M.SPACES[d.space] or nil,
  }
end

-- ═══════════════════════════════════════════════════════════════════════════════
-- SWING GLUE — cache serialisation  (EON Studios; not from TK)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- ⭐ We persist the RAW MEASUREMENTS, never the labels. That is the one
-- architectural decision worth taking from TK wholesale: thresholds live in the
-- vocabulary above, so retuning them relabels an existing library instantly.
-- Caching labels instead would bake today's thresholds into every entry and make
-- every future tweak a full re-analysis — a one-way door.

-- Metric fields persisted to the browser's analysis cache, in a fixed order.
-- Bands ride separately (see pack/unpack) because they are a 7-element array.
M.METRIC_KEYS = {
  "dur", "nch", "attack_ms", "decay_ms", "decay10_ms", "crest_db",
  "centroid", "flat", "pitch", "tail_ratio", "hf_ratio", "width",
}

-- Rounding for the cache file. Full float precision costs bytes for digits no
-- threshold in the vocabulary can see.
local ROUND = {
  dur = 4, nch = 0, attack_ms = 3, decay_ms = 1, decay10_ms = 1, crest_db = 2,
  centroid = 1, flat = 4, pitch = 1, tail_ratio = 4, hf_ratio = 4, width = 4,
}

local function round_to(v, places)
  local mul = 10 ^ (places or 4)
  return math.floor((tonumber(v) or 0) * mul + 0.5) / mul
end

-- metrics table → flat comma-separated string for the cache file.
-- Layout: 12 scalars, then BAND_COUNT band energies.
function M.pack(m)
  if not m then return nil end
  local out = {}
  for i = 1, #M.METRIC_KEYS do
    local k = M.METRIC_KEYS[i]
    out[i] = tostring(round_to(m[k], ROUND[k]))
  end
  local n = #out
  for i = 1, M.BAND_COUNT do
    out[n + i] = tostring(round_to((m.bands and m.bands[i]) or 0, 4))
  end
  return table.concat(out, ",")
end

-- Inverse of pack(). Returns nil on any shape mismatch, so a cache written by a
-- different band count or field list is simply re-analysed rather than trusted.
function M.unpack(s)
  if type(s) ~= "string" or s == "" then return nil end
  local vals = {}
  for tok in s:gmatch("[^,]+") do vals[#vals + 1] = tonumber(tok) end
  local want = #M.METRIC_KEYS + M.BAND_COUNT
  if #vals ~= want then return nil end

  local m = {}
  for i = 1, #M.METRIC_KEYS do m[M.METRIC_KEYS[i]] = vals[i] end
  local bands = {}
  for i = 1, M.BAND_COUNT do bands[i] = vals[#M.METRIC_KEYS + i] end
  m.bands = bands
  return m
end

return M
