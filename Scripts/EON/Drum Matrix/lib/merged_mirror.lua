-- merged_mirror.lua — EON Drum Matrix. Engine for MERGED mode: one track per
-- drum carrying BOTH the pad's audio return and its pattern MIDI item.
--
-- WHY THIS MODULE EXISTS (the routing cycle)
-- ------------------------------------------
-- Classic Build gives every pad TWO tracks: a MIDI lane that sends notes INTO
-- Swing (EON_DM_Build.lua, I_SRCCHAN = -1) and an audio multi-out that receives
-- Swing's per-pad output (Swing_Kit_Bridge.lua, I_SRCCHAN = pad*2). Merging the
-- pair onto one track means that track must feed Swing AND be fed by Swing —
-- a cycle in REAPER's routing graph. REAPER culls the feedback edge, which is
-- why the old ADAPT attempt (noted at EON_DM_Build.lua:495) "didn't produce
-- sound". The only native escape is Preferences → 'allow feedback in routing',
-- which disables plugin delay compensation for the WHOLE PROJECT — unusable in
-- a product.
--
-- So merged mode breaks the cycle by moving the MIDI send off the merged track
-- entirely:
--
--   merged track 01..16   audio IN from Swing + Drum Strip + editable MIDI item
--                         (NO send to Swing — it is a leaf, never upstream)
--   hidden trigger track  one multi-pitch item, MIDI send INTO Swing
--
-- No track is both upstream and downstream of Swing, so there is no cycle and
-- PDC is untouched. This module keeps the hidden item equal to the union of
-- the merged lanes' items.
--
-- ONE-WAY BY DESIGN. The trigger track is a render target, not an editing
-- surface: it is hidden from the TCP and the MCP and is rebuilt wholesale from
-- the lanes whenever they change. Nothing is ever read back OUT of it, which is
-- what lets this skip the echo-suppression/origin-tag machinery that two-way
-- sync needs (cf. stepseq_sync.lua's dm_rev/origin store).
--
-- Pure helper module: no ImGui, no gfx, no globals beyond the module table.

local M = {}

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''

-- Guarded json load (same graceful-degrade pattern as the other DM modules).
local json
do
  local ok, mod = pcall(dofile, SCRIPT_DIR .. 'json.lua')
  if ok and type(mod) == 'table' and mod.encode then json = mod end
end

M.TRIGGER_EXT = 'EON_DM_TRIGGER'    -- P_EXT tag on the hidden trigger track
M.LANE_EXT    = 'EON_DRUM_LANE'     -- shared with the classic/stereo builds

-- Loop-expansion ceiling. A 1-bar item looped across a 20-minute arrangement is
-- legitimate; a pathological source length (0 QN slipping past the > 0 guard)
-- is not. Cap the repeat count so a bad take can never spin the defer loop.
local MAX_LOOP_REPEATS = 4096

-- ---------------------------------------------------------------------------
-- discovery
-- ---------------------------------------------------------------------------

local function decode_ext(tr, key)
  local ok, raw = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:' .. key, '', false)
  if not ok or raw == '' or not json then return nil end
  local dec_ok, dec = pcall(json.decode, raw)
  if not dec_ok or type(dec) ~= 'table' then return nil end
  return dec
end

-- The hidden trigger track for a Swing instance, or nil.
function M.FindTrigger(swing_guid)
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local t = decode_ext(tr, M.TRIGGER_EXT)
    if t and t.swing_guid == swing_guid then return tr end
  end
  return nil
end

-- Every merged lane belonging to a Swing instance, in REAPER track order.
-- Returns { { track = tr, lane_info = {...} }, ... }.
function M.MergedLanes(swing_guid)
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    local lane = decode_ext(tr, M.LANE_EXT)
    if lane and lane.merged == true and lane.swing_instance_guid == swing_guid then
      out[#out + 1] = { track = tr, lane_info = lane }
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- trigger track
-- ---------------------------------------------------------------------------

-- Create the hidden trigger track (idempotent — returns the existing one).
--
-- Placed at the END of the project, deliberately OUTSIDE Swing's parent folder.
-- Swing_Kit_Bridge.find_audio_subfolder identifies the Audio sub-folder as "the
-- track immediately after Swing with I_FOLDERDEPTH == 1"; parking a track in
-- that slot would make the next Multi-Out rebuild create a SECOND audio sub.
-- folder_layout's parent walk is depth-driven for the same reason. Outside the
-- folder, this track is invisible to both, and it is hidden so its position
-- costs the user nothing.
function M.EnsureTrigger(swing_track, swing_guid, kit_name)
  if not swing_track or not json then return nil end
  local existing = M.FindTrigger(swing_guid)
  if existing then return existing end

  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)     -- false = no default envelopes/FX
  local tr = reaper.GetTrack(0, idx)
  if not tr then return nil end

  reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME',
    'EON DM Trigger — ' .. (kit_name or 'Kit'), true)
  reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:' .. M.TRIGGER_EXT,
    json.encode({
      swing_guid = swing_guid,
      kit_name   = kit_name or 'Kit',
      created_at = os.date('!%Y-%m-%dT%H:%M:%SZ'),
    }), true)

  -- Hidden in both views. track_detection.IsVisible gates on B_SHOWINTCP, so
  -- hiding also keeps the DM renderer from ever classifying this track.
  reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINTCP', 0)
  reaper.SetMediaTrackInfo_Value(tr, 'B_SHOWINMIXER', 0)
  -- No audio ever originates here; don't add a silent bus to master.
  reaper.SetMediaTrackInfo_Value(tr, 'B_MAINSEND', 0)
  reaper.SetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH', 0)

  -- The one MIDI send into Swing — the same shape the classic lanes use.
  local si = reaper.CreateTrackSend(tr, swing_track)
  if si >= 0 then
    reaper.SetTrackSendInfo_Value(tr, 0, si, 'I_SRCCHAN', -1)  -- audio off
    reaper.SetTrackSendInfo_Value(tr, 0, si, 'I_MIDIFLAGS', 0) -- all channels
  end
  return tr
end

-- ---------------------------------------------------------------------------
-- change detection
-- ---------------------------------------------------------------------------

-- Cheap signature of everything the mirror output depends on: per MIDI item,
-- REAPER's own note hash plus the item geometry/flags that move notes in
-- project time. Rebuilds only happen when this string changes.
function M.Digest(lanes)
  local parts = {}
  for _, L in ipairs(lanes) do
    parts[#parts + 1] = string.format('%s#%.0f', reaper.GetTrackGUID(L.track) or '?',
                                      reaper.GetMediaTrackInfo_Value(L.track, 'B_MUTE'))
    for i = 0, reaper.CountTrackMediaItems(L.track) - 1 do
      local item = reaper.GetTrackMediaItem(L.track, i)
      local take = item and reaper.GetActiveTake(item)
      if take and reaper.TakeIsMIDI(take) then
        local hash
        if reaper.MIDI_GetHash then
          local ok, h = reaper.MIDI_GetHash(take, false, '')
          if ok then hash = h end
        end
        parts[#parts + 1] = string.format('%s|%.6f|%.6f|%.0f|%.0f|%.4f',
          hash or '?',
          reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
          reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
          reaper.GetMediaItemInfo_Value(item, 'B_MUTE'),
          reaper.GetMediaItemInfo_Value(item, 'B_LOOPSRC'),
          reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS'))
      end
    end
  end
  return table.concat(parts, ';')
end

-- ---------------------------------------------------------------------------
-- note collection
-- ---------------------------------------------------------------------------

-- Loop period of a MIDI take, expressed in the take's own PPQ. 0 when the item
-- doesn't loop or the source length can't be resolved. Derived through
-- MIDI_GetPPQPosFromProjQN rather than assuming 960 ticks/QN.
local function loop_period_ppq(take)
  if not reaper.GetMediaItemTake_Source then return 0 end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return 0 end
  local slen, is_qn = reaper.GetMediaSourceLength(src)
  if not slen or slen <= 0 or not is_qn then return 0 end
  local qn0 = reaper.MIDI_GetProjQNFromPPQPos(take, 0)
  local period = reaper.MIDI_GetPPQPosFromProjQN(take, qn0 + slen)
  if not period or period <= 0 then return 0 end
  return period
end

-- Append one item's playable notes to `out`, in absolute project time.
--
-- Notes are copied VERBATIM (pitch, channel, velocity). That is the faithful
-- translation of what merged mode replaces: the classic lane track sent its
-- whole MIDI stream to Swing unfiltered, so foreign pitches and per-note
-- channels behaved exactly this way. Forcing everything to lane.pad_pitch here
-- would silently break the DM's foreign-note support.
local function collect_item(item, out)
  if reaper.GetMediaItemInfo_Value(item, 'B_MUTE') == 1 then return end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then return end

  local pos  = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local iend = pos + reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local period = (reaper.GetMediaItemInfo_Value(item, 'B_LOOPSRC') == 1)
                 and loop_period_ppq(take) or 0

  local _, ncnt = reaper.MIDI_CountEvts(take)
  for i = 0, (ncnt or 0) - 1 do
    local ok, _, muted, sppq, eppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if ok and not muted then
      local rep = 0
      repeat
        local s = reaper.MIDI_GetProjTimeFromPPQPos(take, sppq + rep * period)
        local e = reaper.MIDI_GetProjTimeFromPPQPos(take, eppq + rep * period)
        if s >= iend then break end          -- past the item: later reps can't help
        -- REAPER only plays what falls inside the item bounds; clip to match.
        if s >= pos - 1e-9 then
          if e > iend then e = iend end
          if e > s then
            out[#out + 1] = { s = s, e = e, ch = chan, pitch = pitch, vel = vel }
          end
        end
        rep = rep + 1
      until period <= 0 or rep > MAX_LOOP_REPEATS
    end
  end
end

-- Every playable note across every merged lane, in absolute project time.
function M.Collect(lanes)
  local out = {}
  for _, L in ipairs(lanes) do
    -- A muted track contributes nothing. This matters: on a classic lane, mute
    -- stopped the track's MIDI send and the pad never fired at all. A merged
    -- lane is an AUDIO track, so REAPER's mute only silences the return — the
    -- pad would still trigger, still spend a voice and still choke its group.
    -- Dropping the lane here keeps mute meaning what it meant before.
    if reaper.GetMediaTrackInfo_Value(L.track, 'B_MUTE') ~= 1 then
      for i = 0, reaper.CountTrackMediaItems(L.track) - 1 do
        local item = reaper.GetTrackMediaItem(L.track, i)
        -- Merged tracks legitimately carry AUDIO items too (that is the whole
        -- point of the mode) — collect_item skips any take that isn't MIDI.
        if item then collect_item(item, out) end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- rebuild
-- ---------------------------------------------------------------------------

-- Replace the trigger track's contents with one item carrying `notes`.
function M.Rebuild(trigger, notes)
  if not trigger then return false end

  for i = reaper.CountTrackMediaItems(trigger) - 1, 0, -1 do
    local it = reaper.GetTrackMediaItem(trigger, i)
    if it then reaper.DeleteTrackMediaItem(trigger, it) end
  end
  if #notes == 0 then return true end

  local t0, t1 = math.huge, -math.huge
  for _, n in ipairs(notes) do
    if n.s < t0 then t0 = n.s end
    if n.e > t1 then t1 = n.e end
  end
  if t1 <= t0 then t1 = t0 + 0.001 end

  local item = reaper.CreateNewMIDIItemInProj(trigger, t0, t1, false)
  if not item then return false end
  local take = reaper.GetActiveTake(item)
  if not take then return false end

  for _, n in ipairs(notes) do
    local sp = reaper.MIDI_GetPPQPosFromProjTime(take, n.s)
    local ep = reaper.MIDI_GetPPQPosFromProjTime(take, n.e)
    if ep <= sp then ep = sp + 1 end
    -- noSort = true: one MIDI_Sort at the end instead of per-note resorting.
    reaper.MIDI_InsertNote(take, false, false, sp, ep, n.ch, n.pitch, n.vel, true)
  end
  reaper.MIDI_Sort(take)

  reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', true)
  reaper.SetMediaItemInfo_Value(item, 'B_UISEL', 0)
  return true
end

-- ---------------------------------------------------------------------------
-- sync
-- ---------------------------------------------------------------------------

-- Per-instance digest of the last successful rebuild.
local last_digest = {}

-- Forget the cached digest so the next Sync rebuilds unconditionally. Call
-- after anything that can change the trigger track behind our back (project
-- load, undo, a rebuilt kit).
function M.Reset(swing_guid)
  if swing_guid then last_digest[swing_guid] = nil else last_digest = {} end
end

-- Bring one instance's trigger track up to date. Returns true if it rebuilt.
--
-- Deliberately creates NO undo block. A deferred script that opens one per tick
-- floods the undo history and would tangle with Swing's own undo engine; the
-- edit the user just made to a lane is the undo point that matters, and this
-- output is regenerated from it anyway.
function M.Sync(swing_guid, force)
  local lanes = M.MergedLanes(swing_guid)
  if #lanes == 0 then return false end
  local trigger = M.FindTrigger(swing_guid)
  if not trigger then return false end

  local digest = M.Digest(lanes)
  if not force and last_digest[swing_guid] == digest then return false end

  reaper.PreventUIRefresh(1)
  local ok = M.Rebuild(trigger, M.Collect(lanes))
  reaper.PreventUIRefresh(-1)
  if ok then
    last_digest[swing_guid] = digest
    reaper.UpdateArrange()
  end
  return ok
end

-- Every Swing instance that currently has merged lanes built. Returns a list of
-- swing_guid strings (deduped, project order).
function M.MergedInstances()
  local seen, out = {}, {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local lane = decode_ext(reaper.GetTrack(0, i), M.LANE_EXT)
    if lane and lane.merged == true then
      local g = lane.swing_instance_guid
      if g and g ~= '' and not seen[g] then
        seen[g] = true
        out[#out + 1] = g
      end
    end
  end
  return out
end

return M
