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
--   acks the CMD the job carries). A chunk not echoed by its deadline is republished (same
--   content, fresh GEN) up to 3x, then ABORTed; an ABORT the JSFX never echoes either is
--   cleared by the bridge so the browser queue cannot wedge.
--   The payload is ALWAYS interleaved stereo: the accessor is asked for 2 channels, so a
--   mono file arrives L==R (measured 2026-09-08: no Lua per-sample loop is needed; that loop
--   cost ~700 ms per 40 s file). PEAK = 0 -> the JSFX folds it while copying.
--   Route 1 = KIND 2 (CMD 69 preview). Routes 2/3 (drops, kit blobs) extend M.start.
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
local HDR, WIN, CHUNK = 30998528, 31064064, 65536
local O = { JOB = 0, GEN = 1, ECHO = 2, PAD = 3, LAYER = 4, KIND = 5, TOTAL = 6, SR = 7, NCH = 8,
            PEAK = 9, OFF = 10, LEN = 11, FLAGS = 12, INST = 13, DONE = 14, JSFX_LEVEL = 15,
            BRIDGE_LEVEL = 16, PATH = 64 }
local KIND = { DROP = 0, LAYER = 1, PREVIEW = 2, KIT = 3, REPAIR = 4 }
local F = { FIRST = 1, LAST = 2, FAILED = 4, ABORT = 8, KITDONE = 16 }
local FRAMES_PER_CHUNK = CHUNK // 2          -- interleaved stereo
M.LEVEL = 204                                 -- what this bridge speaks (== the JSFX's KIT_HS_CAP)
-- Dev gate (2026-09-10, plan Phase B): ExtState EON_Bridge/padpcm_level = "N" makes this
-- bridge PUBLISH level N and, when N is below M.LEVEL, stop consuming CMD 63/64/69 -- i.e.
-- behave exactly like a bridge that predates the stream, which is what every ReaPack sync
-- leaves running until REAPER restarts. The JSFX must then REFUSE the load and say restart
-- (EON_Probe_BridgeState_probe.lua drives all three states). Session-only, cleared by the
-- probe; a real old bridge has no such gate, it simply never wrote the cell.
local function level_pub()
  return tonumber(reaper.GetExtState("EON_Bridge", "padpcm_level")) or M.LEVEL
end
M.PREVIEW_MAX_CELLS = 1000000                 -- FB_PRV_MAX (rk_swing_ui_minibrowser.jsfx-inc)
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
  SLOT_SIZE, LAYER_SIZE = G.SLOT_SIZE or 4000000, G.LAYER_SIZE or 1000000
  -- The level is advertised from tick(), not here: at load time the bridge may not have
  -- attached the segment yet, and a gmem_write before gmem_attach lands in the default
  -- segment without a word (the first acceptance run read BRIDGE_LEVEL 0, 2026-09-08).
end

function M.shutdown()
  if job then M.abort("bridge exit") end
  gw(HDR + O.BRIDGE_LEVEL, 0)
end

function M.busy() return job ~= nil end
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
    gen = math.floor(gr(HDR + O.GEN))
    if gen % 2 == 1 then gen = gen + 1 end
  end
  return gen
end

-- Publish the chunk at job.pos (FIRST / LAST / FAILED / ABORT flags as the job says).
local function publish_next(j)
  gen = next_gen() + 1                                 -- odd: filling
  gw(HDR + O.GEN, gen)
  local n = 0
  local flags = 0
  if j.pos == 0 then flags = flags + F.FIRST end
  if j.failed then
    flags = flags + F.FAILED + F.LAST
  elseif j.aborting then
    flags = flags + F.ABORT + F.LAST
  else
    n = math.min(FRAMES_PER_CHUNK, j.frames - j.pos)
    if n > 0 then
      -- from the one-shot decode: cells pos*2 .. pos*2 + n*2 - 1 of the interleaved array
      local buf, base, o = j.pcm, WIN, j.pos * 2
      for i = 1, n * 2 do gw(base + i - 1, buf[o + i]) end
    end
    if j.pos + n >= j.frames then flags = flags + F.LAST end
  end
  gw(HDR + O.OFF, j.pos * 2)
  gw(HDR + O.LEN, n * 2)
  gw(HDR + O.FLAGS, flags)
  gen = gen + 1                                        -- even: published (LAST write)
  gw(HDR + O.GEN, gen)
  j.cur_gen = gen
  j.chunk_frames = n
  j.last = (flags % (F.LAST * 2)) >= F.LAST
  j.deadline = now() + 0.5 + (n * 2) / 1e6
  stats.chunks = stats.chunks + 1
end

-- Start a job. kind/pad/layer/max_cells/cmd describe the destination; path is the file.
-- Returns true when a job is now in flight (including a failed one that will ack the CMD).
function M.start(kind, path, inst, pad, layer, max_cells, cmd)
  if job then return false end
  job_id = (job_id or math.floor(gr(HDR + O.JOB))) + 1
  local j = { id = job_id, kind = kind, path = path or "", inst = inst or 0, pad = pad or -1,
              layer = layer or -1, cmd = cmd or 0, pos = 0, retries = 0, t0 = now(),
              frames = 0, total = 0, sr = 0, nch = 0 }
  local src = (path and path ~= "") and reaper.PCM_Source_CreateFromFileEx(path, true) or nil
  if not src then
    j.failed = true
    stats.failed = stats.failed + 1
  else
    local sr = reaper.GetMediaSourceSampleRate(src)
    local len = reaper.GetMediaSourceLength(src)
    local nch = reaper.GetMediaSourceNumChannels(src)
    local frames = math.floor(len * sr)
    if frames <= 0 or sr <= 0 then
      reaper.PCM_Source_Destroy(src)
      j.failed = true
      stats.failed = stats.failed + 1
    else
      frames = math.min(frames, math.floor((max_cells or M.PREVIEW_MAX_CELLS) / 2))
      j.tr, j.aa = scratch_open(src, len)
      if not j.aa then
        scratch_close(j)
        j.failed = true
        stats.failed = stats.failed + 1
      else
        -- ONE-SHOT decode of the whole (capped) file as interleaved stereo, then the
        -- scratch track goes away at once (see the header note on why not per tick).
        j.pcm = reaper.new_array(frames * 2)
        j.pcm.clear()
        local t0 = now()
        reaper.GetAudioAccessorSamples(j.aa, sr, 2, 0, frames, j.pcm)
        j.decode_ms = (now() - t0) * 1000
        scratch_close(j)
        j.sr, j.nch, j.frames, j.total = sr, nch, frames, frames * 2
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

-- Abort the in-flight job: publish an ABORT chunk so the JSFX fails it and acks the CMD.
function M.abort(why)
  local j = job
  if not j then return end
  if j.aborting then return end
  j.aborting = true
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
  if job or blocked then return false end
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
    j.deadline = now() + 0.5
    if j.abort_deadline then j.abort_deadline = now() + 1.0 end
    return
  end
  -- After the LAST chunk echoed, a pad job is still finishing on the JSFX side (zero tail,
  -- RMS/ADSR, the completion half) for up to a second or two, and the CMD stays on the bus
  -- until that completion half acks it. The job must stay "busy" until then: releasing it
  -- at the echo let the next tick re-consume the same CMD 63 and start a second job that
  -- aborted the first mid-finish (the kick drop landed EMPTY, first acceptance run).
  if j.awaiting_ack then
    local c = math.floor(gr(G_CMD))
    if c ~= j.cmd or j.cmd == 0 then
      finish_job(j)
    elseif now() > j.ack_deadline then
      reaper.ShowConsoleMsg(("[Swing] PADPCM: job %d (%s) streamed but CMD %d was never acked -- releasing the bus\n"):format(j.id, j.path, j.cmd))
      gw(G_CMD, 0)
      finish_job(j)
    end
    return
  end
  local echo = math.floor(gr(HDR + O.ECHO))
  if echo == j.cur_gen then
    if j.last then
      scratch_close(j)
      j.awaiting_ack = true                            -- released once the JSFX acks the CMD
      j.ack_deadline = now() + 10.0
    else
      j.pos = j.pos + j.chunk_frames
      j.retries = 0
      publish_next(j)
    end
    return
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
  if now() > j.deadline then
    j.retries = j.retries + 1
    -- The FIRST chunk may legitimately wait: the JSFX defers a drop while a kit import
    -- owns its pad bank (it leaves the chunk unlatched), so allow ~10 s there; a stall
    -- mid-stream means the consumer is gone.
    local limit = (j.pos == 0) and 20 or 3
    if j.retries > limit then
      M.abort(("chunk not echoed after %d republishes"):format(limit))
    else
      publish_next(j)                                  -- same chunk, fresh GEN (idempotent)
    end
  end
end

return M
