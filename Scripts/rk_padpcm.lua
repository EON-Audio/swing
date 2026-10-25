-- rk_padpcm.lua -- Kit Bridge companion: the EON_PADPCM decoded-PCM stream (bridge -> JSFX).
--
-- THE RULE this serves (go-live hardening plan, Phase 2, 2026-09-08): no sample file is ever
-- opened on Swing's audio thread. The first slice of a drop was a fixed ~30 ms stall
-- (file_open + the OS's first read inside @block -- five periods at 256 samples), so the
-- bridge now decodes on the UI thread through REAPER's own PCM_source / AudioAccessor (exact
-- parity with the JSFX's file_riff: WAV, AIFF, FLAC, OGG, MP3) and streams the PCM into a gmem
-- window; rk_swing_padpcm.jsfx-inc adopts it a bounded slice per block.
--
-- Loaded by Swing_Kit_Bridge.lua with dofile (the rk_root_note.lua precedent: one module-
-- global table, zero new bridge locals -- the bridge's main chunk sits at 177/200). The bridge
-- calls M.init(core.GMEM) once, M.consume_cmd(cmd, blocked) in its CMD dispatch, M.tick() in
-- its poll beside eon_pp_pump(), M.busy() in the stale-CMD watchdog, M.shutdown() at exit.
--
-- Protocol (.refs/gmem_regions_supplement.tsv EON_PADPCM; mirrors the KIT_HS handshake):
--   per chunk: GEN odd -> payload -> OFF/LEN/FLAGS -> GEN even (written LAST). The JSFX
--   echoes GEN once the chunk is fully copied; FIRST runs its setup, LAST its finish (which
--   acks the CMD the job carries). A chunk not echoed by its deadline waits on, under the same
--   GEN, up to 3 deadlines (20 for the first chunk), then the job is ABORTed; an ABORT the
--   JSFX never echoes either is cleared by the bridge so the browser queue cannot wedge.
--   (Until 2026-10-23 the chunk was republished under a fresh GEN, which the JSFX copied a
--   second time when it came mid-copy: audit H08.)
--   The payload is ALWAYS interleaved stereo: the accessor is asked for 2 channels, so a
--   mono file arrives L==R (measured 2026-09-08: no Lua per-sample loop is needed; that loop
--   cost ~700 ms per 40 s file). PEAK = 0 -> the JSFX folds it while copying.
--   Route 1 = KIND 2 (CMD 69 preview). Routes 2/3 (drops, kit blobs) extend M.start.
--   TWO WINDOWS (2026-10-15, LEVEL_DUAL 205): chunk k goes to window k % 2 (A = block 474, B = block
--   475, each with its own GEN / OFF / LEN / FLAGS / ECHO cells), up to two chunks outstanding, and every
--   tick refills each window the JSFX has echoed. The JSFX reads the windows in sequence (a fresh job
--   starts in A). Either side below 205 -> one window, the original cells, the original pace.
--
-- Measured on this machine (EON_Probe_PadPcmPre, 2026-09-08): gmem_write from a reaper.array
-- ~9 M cells/s -> one 65 536-cell chunk = ~7 ms of a tick; the scratch track leaves the
-- project clean (no dirty flag, no undo point, no state-change bump).
--
-- WHY THE DECODE IS ONE-SHOT (acceptance runs, 2026-09-08): reading the accessor once per
-- tick, 32 768 frames at a time, made audio-thread overruns scale with the decoder's work
-- per read (WAV 0.1 ms -> idle rate; FLAC 0.7 ms -> 6 in 4.5 s; MP3 1.7 ms -> 4) while the
-- kit stream's pure gmem_write bursts never moved the audio thread at all. REAPER's decoders
-- evidently share something with the engine. So: ONE accessor call for the whole (capped) file
-- at job start -- ~10-45 ms on the UI thread for the 1 M-cell preview cap, up to ~170 ms for a
-- 4 M-cell MP3 pad -- then release the scratch track and stream from the array with nothing
-- but gmem writes.

local M = {}
local reaper = reaper

-- band layout == rk_swing_padpcm.jsfx-inc == the TSV row
local HDR, WIN, WIN_B, CHUNK = 30998528, 31064064, 31129600, 65536
local O = { JOB = 0, GEN = 1, ECHO = 2, PAD = 3, LAYER = 4, KIND = 5, TOTAL = 6, SR = 7, NCH = 8,
            PEAK = 9, OFF = 10, LEN = 11, FLAGS = 12, INST = 13, DONE = 14, JSFX_LEVEL = 15,
            BRIDGE_LEVEL = 16, PRV_LOOP = 19, ACKED = 22, AUD_ID = 23, AUD_ISSUED = 24,
            PRV_RD = 25, PRV_RING = 26, PRV_JOB = 27,
            GEN_B = 29, OFF_B = 30, LEN_B = 31, FLAGS_B = 32, ECHO_B = 33, JOB_A = 34, JOB_B = 35, PATH = 64 }
-- The two windows and their descriptors (2026-10-15: window B, reserved since 2026-09-08, is in use).
-- Chunk k of a job goes to window k % nwin; nwin is 2 when BOTH sides speak LEVEL_DUAL, else 1 -- and
-- with 1 the protocol is byte for byte the single-window one (window A, the original cells).
-- JOB_A / JOB_B stamp each window with the job its chunk belongs to (the ring rig's first run on two
-- windows, 2026-10-15): a cancelled or aborted job can leave an unconsumed chunk in one window, and the
-- next job's first chunk lands in the other -- the JSFX, reading the windows in sequence, must know that
-- the leftover is not the new job's second chunk. The header's JOB alone cannot say (it names the new job).
local WDESC = { [0] = { win = WIN,   gen = O.GEN,   off = O.OFF,   len = O.LEN,   flags = O.FLAGS,   echo = O.ECHO,   jobc = O.JOB_A },
                [1] = { win = WIN_B, gen = O.GEN_B, off = O.OFF_B, len = O.LEN_B, flags = O.FLAGS_B, echo = O.ECHO_B, jobc = O.JOB_B } }
local KIND = { DROP = 0, LAYER = 1, PREVIEW = 2, KIT = 3, REPAIR = 4 }
local F = { FIRST = 1, LAST = 2, FAILED = 4, ABORT = 8, KITDONE = 16 }
local FRAMES_PER_CHUNK = CHUNK // 2          -- interleaved stereo
M.LEVEL = 204                                 -- the level at which a JSFX takes the stream at all (the gate below)
-- Two windows in flight (2026-10-15; the user: a sample takes too long to land). With one window the pace of a
-- load was one 65 536-cell chunk per bridge tick: the JSFX copied the chunk in ~35 ms and then sat idle until
-- the bridge's next defer noticed the echo and published the next (acceptance 2026-09-08: 4.0-5.6 s for a
-- 30-40 s file). With two, the JSFX copies window A while the bridge fills window B, and the bridge refills
-- every window that has been echoed each tick: the pace becomes the JSFX's own copy budget. A JSFX below this
-- level (or a bridge below it, the dev gate) keeps the single window.
M.LEVEL_DUAL = 205
-- Dev gate (2026-09-10, plan Phase B): ExtState EON_Bridge/padpcm_level = "N" makes this
-- bridge PUBLISH level N and, when N is below M.LEVEL, stop consuming CMD 63/64/69 -- i.e.
-- behave exactly like a bridge that predates the stream, which is what every ReaPack sync
-- leaves running until REAPER restarts. The JSFX must then REFUSE the load and say restart
-- (EON_Probe_BridgeState_probe.lua drives all three states). Session-only, cleared by the
-- probe; a real old bridge has no such gate, it simply never wrote the cell.
local function level_pub()
  -- what this bridge advertises: the two-window level (the first PadSpeed run, 2026-10-15, found it still
  -- advertising 204 -- the plugin then read "one window" and the second window never engaged)
  return tonumber(reaper.GetExtState("EON_Bridge", "padpcm_level")) or M.LEVEL_DUAL
end
M.PREVIEW_MAX_CELLS = 1000000                 -- FB_PRV_MAX (rk_swing_ui_minibrowser.jsfx-inc): the cap for a JSFX WITHOUT the ring
-- The preview RING (Spec_Swing_Preview_Ring, 2026-10-14). A JSFX that publishes its ring size (PRV_RING) plays a
-- stream longer than its buffer: the bridge decodes once (the array is Lua memory, not gmem) up to this many
-- seconds of the file, and publishes each chunk only when the player has made room for it (PRV_RD / PRV_JOB).
-- Such a JSFX acks CMD 69 at FIRST, so the bus is free while the stream runs; a new PCM command supersedes the
-- stream (M.consume_cmd), and DONE = -job from the JSFX means "cancelled: finish quietly".
M.PREVIEW_MAX_SECONDS = 120
M.KIND, M.F = KIND, F

local G_CMD, G_LOCK, G_INSTANCE, G_PATH, G_PATH_LEN, G_PATH_MAX
local G_BPAD, G_BLAYER, SLOT_SIZE, LAYER_SIZE
local job = nil          -- the in-flight job (one at a time: one window, one CMD bus)
local gen = nil          -- our GEN counter, re-seeded from gmem on first use
local job_id = nil       -- our JOB counter, re-seeded from gmem on first use
local stats = { jobs = 0, chunks = 0, failed = 0, aborted = 0 }
M.stats = stats

local function now() return reaper.time_precise() end
local function gr(i) return reaper.gmem_read(i) or 0 end
local function gw(i, v) reaper.gmem_write(i, v) end

function M.init(G)
  G_CMD, G_LOCK, G_INSTANCE = G.CMD, G.LOCK, G.INSTANCE
  G_PATH, G_PATH_LEN, G_PATH_MAX = G.GS_BROWSER_PATH, G.GS_BROWSER_PATH_LEN, G.GS_BROWSER_PATH_MAX or 259
  G_BPAD, G_BLAYER = G.GS_BROWSE_PAD, G.GS_BROWSE_LAYER
  SLOT_SIZE, LAYER_SIZE = G.SLOT_SIZE or 4000000, G.LAYER_SIZE or 4000000
  -- The level is advertised from tick(), not here: at load time the bridge may not have
  -- attached the segment yet, and a gmem_write before gmem_attach lands in the default
  -- segment without a word (the first acceptance run read BRIDGE_LEVEL 0, 2026-09-08).
end

-- Storage-rate ceiling (Spec_Swing_Pad_Banks §5.5): the bridge installs eon_store_rate
-- here after init; the default is identity, so the module stays usable on its own.
M.store_rate = function(sr) return sr end

function M.shutdown()
  if job then M.abort("bridge exit") end
  gw(HDR + O.BRIDGE_LEVEL, 0)
end

-- "Busy" = a job that holds the bus. A ring preview acked its CMD at FIRST and holds nothing: the fill
-- pipeline and the stale-CMD watchdog must not wait on it (M.consume_cmd supersedes it when needed).
function M.busy() return job ~= nil and not (job.kind == KIND.PREVIEW and (job.ring or 0) > 0) end

-- ── The audition identity (the queued audition, 2026-10-14; the user's design of 2026-09-18) ──────────────────
-- A preview request is identified by a number minted WHEN THE USER ASKED (the browser's click lands in the
-- bridge and the queue is built), not when CMD 69 is finally posted: a click with autoload AND audition on
-- queues the pad load first and the preview second, and a browser close in between posts a STOP. Swing clears
-- a STOP only for a request minted AFTER it: at the STOP it reads AUD_ISSUED (the latest minted) as the mark,
-- and at the rising edge of CMD 69 it compares AUD_ID (this job's) with that mark. A job minted before the
-- STOP stays cancelled; a new click after it plays. Monotonic, re-seeded from gmem like JOB (a bridge restart
-- continues the count); 0 = never minted, which Swing reads as "an old bridge: the old rule".
function M.mint_audition()
  local n = math.floor(gr(HDR + O.AUD_ISSUED) or 0) + 1
  gw(HDR + O.AUD_ISSUED, n)
  return n
end
function M.set_audition(id)      -- the job's identity, written BEFORE its CMD 69
  gw(HDR + O.AUD_ID, math.floor(id or 0))
end
function M.jsfx_level() return math.floor(gr(HDR + O.JSFX_LEVEL)) end

-- The browser path bus, exactly as the JSFX reads it (GS_BROWSER_PATH_LEN chars).
local function read_browser_path()
  local n = math.floor(gr(G_PATH_LEN))
  if n <= 0 or n >= G_PATH_MAX then return nil end
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = string.char(math.max(0, math.min(255, math.floor(gr(G_PATH + i))))) end
  return table.concat(t)
end

local function write_path_record(path)
  path = path or ""
  if #path > 258 then path = "" end
  gw(HDR + O.PATH, #path)
  for i = 0, #path - 1 do gw(HDR + O.PATH + 1 + i, path:byte(i + 1)) end
  gw(HDR + O.PATH + 1 + #path, 0)
end

-- Scratch track for the accessor: hidden, inserted and deleted inside PreventUIRefresh
-- brackets that never span a tick. Insert/delete leave the project clean (probe 0.8 b).
local function scratch_open(src, len)
  reaper.PreventUIRefresh(1)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINTCP", 0)
  reaper.SetMediaTrackInfo_Value(tr, "B_SHOWINMIXER", 0)
  local item = reaper.AddMediaItemToTrack(tr)
  local take = reaper.AddTakeToMediaItem(item)
  reaper.SetMediaItemTake_Source(take, src)          -- the take owns src from here on
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len)
  local aa = reaper.CreateTakeAudioAccessor(take)
  reaper.PreventUIRefresh(-1)
  return tr, aa
end

local function scratch_close(j)
  if j.aa then reaper.DestroyAudioAccessor(j.aa); j.aa = nil end
  if j.tr and reaper.ValidatePtr2(0, j.tr, "MediaTrack*") then
    reaper.PreventUIRefresh(1)
    reaper.DeleteTrack(j.tr)                           -- destroys the item, the take and its source
    reaper.PreventUIRefresh(-1)
  end
  j.tr = nil
end

local function next_gen()
  if not gen then
    -- seeded from the LIVE header, both windows: GEN is one monotonic count shared by the windows
    gen = math.max(math.floor(gr(HDR + O.GEN)), math.floor(gr(HDR + O.GEN_B)))
    if gen % 2 == 1 then gen = gen + 1 end
  end
  return gen
end

-- Write chunk c into its window under a fresh GEN: GEN odd -> payload -> OFF/LEN/FLAGS -> GEN even. Once
-- per chunk: a chunk whose deadline passes unechoed waits on under the same GEN (M.tick, audit H08).
local function publish_chunk(j, c)
  local d = WDESC[c.w]
  gen = next_gen() + 1                                 -- odd: filling
  gw(HDR + d.gen, gen)
  if c.n > 0 then
    -- from the one-shot decode: cells pos*2 .. pos*2 + n*2 - 1 of the interleaved array
    local buf, base, o = j.pcm, d.win, c.pos * 2
    for i = 1, c.n * 2 do gw(base + i - 1, buf[o + i]) end
  end
  gw(HDR + d.off, (c.pass * j.frames + c.pos) * 2)   -- absolute in the stream: passes included
  gw(HDR + d.len, c.n * 2)
  gw(HDR + d.flags, c.flags)
  gw(HDR + d.jobc, j.id)                               -- whose chunk this window holds
  gen = gen + 1                                        -- even: published (LAST write)
  gw(HDR + d.gen, gen)
  c.gen = gen
  j.cur_gen = gen                                      -- the last GEN published (the rigs' traces read it)
  c.deadline = now() + 0.5 + (c.n * 2) / 1e6
  stats.chunks = stats.chunks + 1
end

-- Describe the next chunk of the stream (FIRST / LAST / FAILED / ABORT flags as the job says), publish it
-- into the next window in sequence and queue it as outstanding. The caller checked a window is free
-- (#j.out < j.nwin) and, for a ring preview, that the ring has room for it (ring_fits).
local function publish_next(j)
  local c = { w = j.ck % j.nwin, pos = j.pub_pos, pass = j.pub_pass, n = 0, flags = 0, retries = 0 }
  -- FIRST = the stream's start: pass 0 only. The first chunk of a LOOP's second pass is NOT a start -- flagged as
  -- one it re-ran the JSFX's setup mid-stream (a new ring base, the voice faded; the ring rig's run 2, 2026-10-14).
  if c.pos == 0 and c.pass == 0 then c.flags = c.flags + F.FIRST end
  if j.failed then
    c.flags = c.flags + F.FAILED + F.LAST
  elseif j.aborting then
    c.flags = c.flags + F.ABORT + F.LAST
  else
    c.n = math.min(FRAMES_PER_CHUNK, j.frames - c.pos)
    if c.pos + c.n >= j.frames then
      -- A LONG file (one that does not fit the ring) with the browser's LOOP on repeats through the bridge:
      -- no LAST; the next chunk is frame 0 of the next pass with OFF still climbing. Capped at 2^30 cells
      -- so the JSFX's |0 casts stay exact (~3 h at 96 k). A file that fits loops in the JSFX itself.
      local long = j.ring > 0 and j.frames * 2 > j.ring
      local loop_on = math.floor(gr(HDR + O.PRV_LOOP)) > 0
      if long and loop_on and (c.pass + 2) * j.frames * 2 < 1073741824 then
        j.pub_pass = c.pass + 1; j.pub_pos = 0
      else
        c.flags = c.flags + F.LAST
        j.pub_pos = c.pos + c.n
      end
    else
      j.pub_pos = c.pos + c.n
    end
  end
  c.last = (c.flags % (F.LAST * 2)) >= F.LAST
  if c.last then j.published_last = true end
  j.ck = j.ck + 1
  j.out[#j.out + 1] = c
  publish_chunk(j, c)
end

-- Start a job. kind/pad/layer/max_cells/cmd describe the destination; path is the file.
-- Returns true when a job is now in flight (including a failed one that will ack the CMD).
function M.start(kind, path, inst, pad, layer, max_cells, cmd)
  if job then return false end
  job_id = (job_id or math.floor(gr(HDR + O.JOB))) + 1
  local j = { id = job_id, kind = kind, path = path or "", inst = inst or 0, pad = pad or -1,
              layer = layer or -1, cmd = cmd or 0, pos = 0, t0 = now(),
              frames = 0, total = 0, sr = 0, nch = 0,
              ring = 0, pass = 0,                 -- the preview ring: the stream position the JSFX has ECHOED
              -- the publish side (2026-10-15, two windows): chunks published so far, the next chunk's frame and
              -- pass, the outstanding chunks oldest first (at most nwin), and whether LAST has been published
              ck = 0, pub_pos = 0, pub_pass = 0, out = {}, published_last = false,
              nwin = (M.jsfx_level() >= M.LEVEL_DUAL and level_pub() >= M.LEVEL_DUAL) and 2 or 1,
              acked = false }   -- the JSFX has acked the CMD that started this job (a later CMD is a NEW request)
  local src = (path and path ~= "") and reaper.PCM_Source_CreateFromFileEx(path, true) or nil
  if not src then
    j.failed = true
    stats.failed = stats.failed + 1
  else
    local sr = M.store_rate(reaper.GetMediaSourceSampleRate(src))   -- the storage-rate ceiling (§5.5): frames, the decode and PP_SR all follow it
    local len = reaper.GetMediaSourceLength(src)
    local nch = reaper.GetMediaSourceNumChannels(src)
    local frames = math.floor(len * sr)
    if frames <= 0 or sr <= 0 then
      reaper.PCM_Source_Destroy(src)
      j.failed = true
      stats.failed = stats.failed + 1
    else
      -- The ring: a preview for a JSFX that publishes its ring size is capped in SECONDS of the file, not in
      -- cells of the buffer; an older JSFX (ring 0) keeps the 1 M-cell cap (and the ack at LAST).
      local ring = (kind == KIND.PREVIEW) and math.floor(gr(HDR + O.PRV_RING)) or 0
      if ring > 0 then
        j.ring = ring
        frames = math.min(frames, math.floor(M.PREVIEW_MAX_SECONDS * sr))
      else
        frames = math.min(frames, math.floor((max_cells or M.PREVIEW_MAX_CELLS) / 2))
      end
      -- The decode array FIRST, before any scratch track exists: reaper.new_array refuses a size
      -- above REAPER's own ceiling ("invalid size"), and the ring's 120 s cap (2026-10-14) asked for
      -- up to ~11 M cells. The QAudition rig's 60 s file (2026-10-15) threw here INSIDE the tick,
      -- after scratch_open: the job was never recorded, the hidden scratch track leaked into the
      -- project on every such click, the CMD sat on the bus until the plugin's 3 s guard cleared it,
      -- and no preview played. Now: ask once at ANY size (a hit is a few thousand frames -- the first
      -- form of this loop started at a 65 536-frame floor and failed every short file; the PadSpeed
      -- rig caught it the same hour), and on a refusal halve the frames while a retry is still worth
      -- a chunk, so REAPER grants the array (a 2-minute file plays its first ~45 s at 44.1 k instead
      -- of nothing); a file refused even at that size is failed cleanly (acked FAILED, nothing leaked).
      local ok_arr, arr = pcall(reaper.new_array, frames * 2)
      while not (ok_arr and arr) and frames >= 131072 do
        frames = math.floor(frames / 2)
        ok_arr, arr = pcall(reaper.new_array, frames * 2)
      end
      if not (ok_arr and arr) then
        reaper.PCM_Source_Destroy(src)
        j.failed = true
        stats.failed = stats.failed + 1
      else
        j.tr, j.aa = scratch_open(src, len)
        if not j.aa then
          scratch_close(j)
          j.failed = true
          stats.failed = stats.failed + 1
        else
          -- ONE-SHOT decode of the whole (capped) file as interleaved stereo, then the
          -- scratch track goes away at once (see the header note on why not per tick).
          j.pcm = arr
          j.pcm.clear()
          local t0 = now()
          reaper.GetAudioAccessorSamples(j.aa, sr, 2, 0, frames, j.pcm)
          j.decode_ms = (now() - t0) * 1000
          scratch_close(j)
          j.sr, j.nch, j.frames, j.total = sr, nch, frames, frames * 2
        end
      end
    end
  end
  -- header before the first GEN flip
  gw(HDR + O.JOB, j.id)
  gw(HDR + O.PAD, j.pad)
  gw(HDR + O.LAYER, j.layer)
  gw(HDR + O.KIND, kind)
  gw(HDR + O.TOTAL, j.total)
  gw(HDR + O.SR, j.sr)
  gw(HDR + O.NCH, j.nch)
  gw(HDR + O.PEAK, 0)
  gw(HDR + O.INST, j.inst)
  write_path_record(j.path)
  job = j
  stats.jobs = stats.jobs + 1
  publish_next(j)
  return true
end

-- The ring's flow control: the NEXT chunk to publish fits when its end is within the ring of the player's read
-- position. The position is trusted only when the JSFX says it belongs to THIS job (a stale one from the last
-- job would read as free space); otherwise the player has not started and the whole ring is free. With two
-- windows each chunk is checked at its own publish, so the second in flight fits too.
local function ring_fits(j)
  if (j.ring or 0) == 0 then return true end
  local n = math.min(FRAMES_PER_CHUNK, j.frames - j.pub_pos)
  local rd = (math.floor(gr(HDR + O.PRV_JOB)) == j.id) and math.floor(gr(HDR + O.PRV_RD)) or 0
  local off = (j.pub_pass * j.frames + j.pub_pos) * 2
  return off + n * 2 - rd <= j.ring
end

-- Abort the in-flight job: publish an ABORT chunk so the JSFX fails it and acks the CMD. The chunks still
-- outstanding are forgotten: the ABORT goes into the next window in sequence, and the JSFX, which consumes the
-- windows in sequence, reaches it after whatever it was copying (an ABORT carries no payload, so a window the
-- JSFX is reading is never overwritten under it).
function M.abort(why)
  local j = job
  if not j then return end
  if j.aborting then return end
  j.aborting = true
  j.out = {}
  j.why = why
  stats.aborted = stats.aborted + 1
  scratch_close(j)
  publish_next(j)
  j.abort_deadline = now() + 1.0
end

local function finish_job(j)
  scratch_close(j)
  job = nil
end

-- The bridge's CMD dispatch calls this every tick with the current CMD. Consumes CMD 69
-- (preview) when the JSFX speaks the protocol, nothing is blocking, and no job is in flight.
-- The CMD itself stays on the bus until the JSFX acks it at LAST (every producer already
-- gates on CMD == 0). Returns true when it started a job this tick.
function M.consume_cmd(cmd, blocked)
  if job then
    -- A ring preview (acked at FIRST, the bus free) is SUPERSEDED by any new PCM command -- the user's newer
    -- act: the JSFX fades the voice and fails the job, and the new one starts next tick. Not one already
    -- finishing (its ACKED match) or aborting: those end on their own. And ONLY once the JSFX has acked the
    -- CMD that started this job (job.acked, M.tick): until then the 69 on the bus IS this job's -- the first
    -- run of the ring rig (2026-10-14) aborted every long preview within 7 ms of its start for want of this.
    if job.kind == KIND.PREVIEW and (job.ring or 0) > 0 and job.acked and not job.aborting and not job.awaiting_ack then
      M.abort("superseded by a newer request")
    end
    return false
  end
  if blocked then return false end
  if cmd ~= 63 and cmd ~= 64 and cmd ~= 69 then return false end
  if M.jsfx_level() < M.LEVEL then return false end   -- old JSFX: it reads the file itself
  if level_pub() < M.LEVEL then return false end      -- dev gate: an "old" bridge does not stream
  local path = read_browser_path()
  local inst = math.floor(gr(G_INSTANCE))
  if cmd == 69 then
    return M.start(KIND.PREVIEW, path, inst, -1, -1, M.PREVIEW_MAX_CELLS, 69)
  elseif cmd == 63 then
    -- a drop: the pad's whole slot; the JSFX validates the pad and clears it at FIRST
    return M.start(KIND.DROP, path, inst, math.floor(gr(G_BPAD)), -1, SLOT_SIZE, 63)
  else
    -- a layer: one LAYER_SIZE region; layer 0 onto a plain pad replaces its sample,
    -- a layer >= 1 promotes the pad (swing_pad_promote, inside swing_ldr_begin_gmem)
    return M.start(KIND.LAYER, path, inst, math.floor(gr(G_BPAD)), math.floor(gr(G_BLAYER)), LAYER_SIZE, 64)
  end
end

-- Once per bridge tick.
function M.tick()
  -- Advertise every tick (one gmem write): self-healing after anything zeroes it, and the
  -- segment is certainly attached by the time the poll loop runs.
  gw(HDR + O.BRIDGE_LEVEL, level_pub())
  local j = job
  if not j then return end
  -- A stopped audio engine has no @block to consume with: park, never time out.
  if reaper.Audio_IsRunning and not reaper.Audio_IsRunning() then
    for _, c in ipairs(j.out) do c.deadline = now() + 0.5 end
    if j.abort_deadline then j.abort_deadline = now() + 1.0 end
    return
  end
  -- After the LAST chunk echoed, a pad job is still finishing on the JSFX side (zero tail,
  -- RMS/ADSR, the completion half) for up to a second or two, and the CMD stays on the bus
  -- until that completion half acks it. The job must stay "busy" until then: releasing it
  -- at the echo let the next tick re-consume the same CMD 63 and start a second job that
  -- aborted the first mid-finish (the kick drop landed EMPTY, first acceptance run).
  -- ACKED (2026-10-10): the JSFX names the job whose CMD it has just acked. "The CMD left" alone missed an ack
  -- whose next load was already posted -- a producer posts the moment the CMD reads 0, so before this tick: the
  -- same number back on the bus looked like this job still waiting, was never streamed, and was cleared after the
  -- deadline (FILL's N3 race, the Sample Browser's queues). A JSFX that predates the cell never matches.
  -- Has the JSFX acked the CMD that started this job? (A ring preview acks at FIRST; the cell names the job.)
  -- From then on a CMD on the bus is a NEW request, which may supersede a ring preview (M.consume_cmd).
  if not j.acked and (math.floor(gr(HDR + O.ACKED)) == j.id or math.floor(gr(G_CMD)) ~= j.cmd) then
    j.acked = true
  end
  -- The consumer CANCELLED (DONE = -job: a STOP on a long stream, a held request declined at FIRST, an ABORT
  -- it failed): finish quietly whatever state the job is in. Read first, so nothing below republishes.
  if math.floor(gr(HDR + O.DONE)) == -j.id then
    finish_job(j)
    return
  end
  if j.awaiting_ack then
    local c = math.floor(gr(G_CMD))
    if c ~= j.cmd or j.cmd == 0 or math.floor(gr(HDR + O.ACKED)) == j.id then
      finish_job(j)
    elseif now() > j.ack_deadline then
      reaper.ShowConsoleMsg(("[Swing] PADPCM: job %d (%s) streamed but CMD %d was never acked -- releasing the bus\n"):format(j.id, j.path, j.cmd))
      gw(G_CMD, 0)
      finish_job(j)
    end
    return
  end
  -- Echoes, oldest outstanding chunk first. The JSFX consumes the windows in sequence, so the oldest is
  -- always the one that can be echoed next; an echo of LAST ends the stream (the job then waits for the
  -- CMD's ack, or for the ring preview's ACKED match).
  while #j.out > 0 do
    local c = j.out[1]
    if math.floor(gr(HDR + WDESC[c.w].echo)) ~= c.gen then break end
    table.remove(j.out, 1)
    j.pos = c.pos + c.n; j.pass = c.pass
    -- The chunk that is now the oldest was published beside this one, so its deadline has been running
    -- while the JSFX was busy with this one: it counts from now, when the JSFX is due to take it (audit H08).
    local h = j.out[1]
    if h then h.deadline = now() + 0.5 + (h.n * 2) / 1e6 end
    if c.last then
      scratch_close(j)
      j.awaiting_ack = true                            -- released once the JSFX acks the CMD
      j.ack_deadline = now() + 10.0
      return
    end
  end
  if j.aborting then
    if now() > j.abort_deadline then
      -- nobody echoed even the ABORT: release the bus ourselves
      if math.floor(gr(G_CMD)) == j.cmd and j.cmd > 0 then gw(G_CMD, 0) end
      reaper.ShowConsoleMsg(("[Swing] PADPCM: job %d (%s) aborted -- %s, no consumer\n"):format(j.id, j.path, tostring(j.why)))
      finish_job(j)
    end
    return
  end
  -- Top up: every free window gets the next chunk, as long as the ring has room for it (a ring preview's
  -- flow control: a chunk held back until the player has made room is a wait, not a stall).
  while #j.out < j.nwin and not j.published_last and ring_fits(j) do
    publish_next(j)
  end
  -- The oldest outstanding chunk's deadline: the stall detector. It is re-armed a bounded number of times,
  -- then the job is ABORTed. The FIRST chunk may legitimately wait: the JSFX defers a drop while a kit import
  -- owns its pad bank (it leaves the chunk unlatched), so allow ~10 s there; a stall mid-stream means the
  -- consumer is gone.
  -- ⚠ Never REPUBLISHED (audit H08, 2026-10-23). A fresh GEN on a chunk the JSFX was still copying (a deferred
  -- first chunk, or the second of a pair at 4096-sample blocks) made it copy that chunk twice and take the
  -- windows one step off chunk k -> window k % 2 from then on: the last chunk landed before the one ahead of
  -- it (a hole in the pad), or sat in window B while the JSFX waited on A (the drop lost). The JSFX takes an
  -- unseen even GEN whenever it can, a deferring drop leaves it unseen on purpose, so the same GEN is still
  -- there to take; a fresh one never helped.
  local c = j.out[1]
  if c and now() > c.deadline then
    c.retries = c.retries + 1
    local limit = (c.pos == 0 and c.pass == 0) and 20 or 3
    if c.retries > limit then
      M.abort(("chunk not echoed after %d deadlines"):format(limit))
    else
      c.deadline = now() + 0.5 + (c.n * 2) / 1e6       -- wait again: the same chunk, the same GEN
    end
  end
end

return M
