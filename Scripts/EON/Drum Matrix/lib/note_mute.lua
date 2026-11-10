-- note_mute.lua -- EON. Notes muted BY A TOOL inside REAPER MIDI items, told apart from the user's own mutes.
--
-- The one master (rules page, rule 8) for every "this tool greys its own notes" (2026-10-30, the printed-mute job):
--   * Swing's printed notes follow its sequencer's lanes (the Kit Bridge's eon_plm_*, record P_EXT:EON_SEQ_LANES);
--   * the Drum Matrix's lane mute / solo (stereo kit and its pads, merged lanes) grey the notes of the Drum Matrix's
--     clips (dm_*, below);
--   * a paired Steppa's lane mute / solo grey its pads' notes in those same clips (ss_*, below; the Kit Bridge runs it).
-- After launch the timeline sync reuses it.
--
-- REAPER's note mute flag cannot say who muted a note; a RECORD on the item can: P_EXT:<key> =
-- "1|<owner>|" then one "ppq,pitch,lane,m" entry per note, ";"-separated -- the note's start in the take's PPQ, its pitch,
-- a lane (-1 = none), m = who holds it muted (Swing's prints: 1 = the sequencer; the Drum Matrix's clips: a bit per
-- tool, below). A note is held only while its start and pitch still match an entry (in order, for two at one place): a
-- note the user moved, transposed or added is never touched, and one the user muted by hand is never unmuted. The record
-- rides in the item's chunk, so a moved, copied or split item keeps it, an undo puts it back with the notes, and a glued
-- item (a new take) loses it and becomes a plain item.
--
-- Pure helper: no ImGui, no globals beyond the module table; the callers hold the undo blocks.

local M = {}

-- The record on an item: { owner, e = { { ppq, pitch, lane, m }, ... } } or nil.
function M.read(it, key)
  local ok, s = reaper.GetSetMediaItemInfo_String(it, key, "", false)
  if not ok or not s or s == "" then return nil end
  local ver, owner, body = s:match("^(%d+)|([^|]*)|(.*)$")
  if ver ~= "1" or not owner or owner == "" then return nil end
  local e = {}
  for p, k, l, m in body:gmatch("(%-?%d+),(%d+),(%-?%d+),(%d+)") do
    e[#e + 1] = { tonumber(p), tonumber(k), tonumber(l), tonumber(m) }
  end
  return { owner = owner, e = e }
end

local function encode(rec)
  if not rec or not rec.e or #rec.e == 0 then return "" end
  local parts = {}
  for i, x in ipairs(rec.e) do parts[i] = ("%d,%d,%d,%d"):format(x[1], x[2], x[3], x[4]) end
  return "1|" .. rec.owner .. "|" .. table.concat(parts, ";")
end

-- Writes the record; an empty one clears the field.
function M.write(it, key, rec)
  local s = encode(rec)
  if s == "" then
    local _, cur = reaper.GetSetMediaItemInfo_String(it, key, "", false)
    if cur and cur ~= "" then reaper.GetSetMediaItemInfo_String(it, key, "", true) end
    return
  end
  reaper.GetSetMediaItemInfo_String(it, key, s, true)
end

-- The item's notes, each paired with its record entry (start + pitch, in order) or nil.
local function pair(take, rec)
  local by = {}
  for _, x in ipairs(rec and rec.e or {}) do
    local k = x[1] .. ":" .. x[2]
    local q = by[k]
    if not q then q = { n = 0 }; by[k] = q end
    q[#q + 1] = x
  end
  local out = {}
  local _, nn = reaper.MIDI_CountEvts(take)
  for i = 0, (nn or 0) - 1 do
    local ok, _, muted, sppq, _, _, pitch = reaper.MIDI_GetNote(take, i)
    if ok then
      local p0 = math.floor(sppq + 0.5)
      local q = by[p0 .. ":" .. pitch]
      local x = nil
      if q and q.n < #q then q.n = q.n + 1; x = q[q.n] end
      out[#out + 1] = { i = i, muted = muted, ppq = p0, pitch = pitch, x = x }
    end
  end
  return out
end

local function midi_take(it)
  local take = reaper.GetActiveTake(it)
  if take and reaper.TakeIsMIDI(take) then return take end
  return nil
end

local function set_mute(take, i, on) reaper.MIDI_SetNote(take, i, nil, on, nil, nil, nil, nil, nil, true) end

-- Entry by entry: want(entry) -> true (should be muted) / false (should sound) / nil (leave). A note that should be muted
-- and sounds is muted and marked ours; one that should sound sounds again only if it is ours. Returns the notes changed.
-- dry = count only.
function M.apply(it, key, want, dry)
  local rec = M.read(it, key)
  local take = rec and midi_take(it)
  if not take then return 0 end
  local changed, recdirty = 0, false
  for _, n in ipairs(pair(take, rec)) do
    local x = n.x
    local w = x and want(x)
    if w == true and not n.muted then
      changed = changed + 1
      if not dry then set_mute(take, n.i, true); x[4] = 1; recdirty = true end
    elseif w == false and x[4] == 1 then
      if n.muted then
        changed = changed + 1
        if not dry then set_mute(take, n.i, false) end
      end
      if not dry then x[4] = 0; recdirty = true end
    end
  end
  if not dry then
    if changed > 0 then reaper.MIDI_Sort(take); reaper.UpdateItemInProject(it) end
    if recdirty then M.write(it, key, rec) end
  end
  return changed
end

-- SEVERAL TOOLS on one item (the Drum Matrix's clips: the Drum Matrix and a paired Steppa, 2026-10-30, the
-- coordinator's rule). An entry's m is a bit per tool holding the note muted. want(note) -> true (this tool greys
-- it) / false (this tool lets it sound) / nil (not this tool's note); note = { ppq, pitch }.
--   * a sounding note this tool greys is muted and gets the tool's bit;
--   * a muted note another tool holds gets the bit too (so it stays muted while EITHER holds it);
--   * a muted note nobody holds is the user's own and is never taken;
--   * a tool letting go clears only its bit; the note sounds again only when no bit is left.
-- Returns the notes changed. dry = count only.
function M.hold(it, key, owner, bit, want, dry)
  local take = midi_take(it)
  if not take then return 0 end
  local rec = M.read(it, key)
  if rec and rec.owner ~= owner then return 0 end   -- another family's record under this key: not ours to touch
  local changed, keep = 0, {}
  for _, n in ipairs(pair(take, rec)) do
    local held = n.x and n.x[4] or 0
    local w = want(n)
    if w == true then
      if not n.muted then
        changed = changed + 1
        if not dry then set_mute(take, n.i, true) end
        held = held | bit
      elseif held ~= 0 then
        held = held | bit
      end
    elseif w == false and held & bit ~= 0 then
      held = held & ~bit
      if held == 0 and n.muted then
        changed = changed + 1
        if not dry then set_mute(take, n.i, false) end
      end
    end
    if held ~= 0 then keep[#keep + 1] = { n.ppq, n.pitch, -1, held } end
  end
  if not dry then
    if changed > 0 then reaper.MIDI_Sort(take); reaper.UpdateItemInProject(it) end
    local new = { owner = owner, e = keep }
    local _, cur = reaper.GetSetMediaItemInfo_String(it, key, "", false)
    if (cur or "") ~= encode(new) then M.write(it, key, new) end   -- a pass that changes nothing writes nothing
  end
  return changed
end

-- The items in the project whose record under `key` names `owner` (one pass, one string read an item).
function M.items(key, owner)
  local out = {}
  local pre = "1|" .. owner .. "|"
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local it = reaper.GetTrackMediaItem(tr, i)
      local _, s = reaper.GetSetMediaItemInfo_String(it, key, "", false)
      if s and s:sub(1, #pre) == pre then out[#out + 1] = it end
    end
  end
  return out
end

-- ── The Drum Matrix's clips (2026-10-30, the owner's "each greys its own", "only grey the notes", "add them now") ────
-- One record per item, P_EXT:EON_DM_MUTED, owner "dm"; bit 1 = the Drum Matrix's buttons, bit 2 = a paired Steppa's.
--
-- The Drum Matrix greys on its STEREO and MERGED lanes (classic lanes keep REAPER's track mute / solo, which already
-- silences exactly the lane's own clips):
--   * a stereo lane IS Swing's own track: its kit-wide M / S live on the track (P_EXT:EON_DM_MS = "<mute>,<solo>") and
--     its per-pad M / S beside each pad row (P_EXT:EON_DM_PADMS = "<mute mask>,<solo mask>", bit pad-1); every MIDI
--     item on the track is the Drum Matrix's except Swing's own prints (Swing's sequencer greys those);
--   * a merged lane is the pad's audio track: its M / S live on that track (EON_DM_MS) and grey the lane's items;
--     REAPER's own mute on that track stays the user's mixer mute (tied to Swing's pad mute by the bridge).
-- The Drum Matrix's solo is one scope across those lanes: while any of them (a kit, a pad, a merged lane) is soloed,
-- every note not soloed is greyed.
M.DM_KEY = "P_EXT:EON_DM_MUTED"
M.DM_STATE = "P_EXT:EON_DM_MS"
M.DM_PADS = "P_EXT:EON_DM_PADMS"
M.DM_OWNER = "dm"
M.DM_BIT = 1
M.SS_BIT = 2

function M.dm_state(track)
  local _, s = reaper.GetSetMediaTrackInfo_String(track, M.DM_STATE, "", false)
  local m, so = (s or ""):match("^(%d),(%d)$")
  return m == "1", so == "1"
end

function M.dm_set(track, kind, on)
  local m, s = M.dm_state(track)
  if kind == "mute" then m = on else s = on end
  reaper.GetSetMediaTrackInfo_String(track, M.DM_STATE, (m and "1" or "0") .. "," .. (s and "1" or "0"), true)
end

-- The stereo kit's per-pad masks: mute, solo (bit pad-1, pads 1..16).
function M.dm_pads(track)
  local _, s = reaper.GetSetMediaTrackInfo_String(track, M.DM_PADS, "", false)
  local mm, sm = (s or ""):match("^(%d+),(%d+)$")
  return math.floor(tonumber(mm) or 0), math.floor(tonumber(sm) or 0)
end

function M.dm_pad_state(track, pad)
  local mm, sm = M.dm_pads(track)
  local b = 1 << (pad - 1)
  return mm & b ~= 0, sm & b ~= 0
end

function M.dm_pad_set(track, pad, kind, on)
  local mm, sm = M.dm_pads(track)
  local b = 1 << (pad - 1)
  if kind == "mute" then mm = on and (mm | b) or (mm & ~b) else sm = on and (sm | b) or (sm & ~b) end
  reaper.GetSetMediaTrackInfo_String(track, M.DM_PADS, mm .. "," .. sm, true)
end

-- Which lanes the Drum Matrix greys on: 'stereo', 'merged' or nil (classic).
function M.dm_kind(lane_info)
  if type(lane_info) ~= "table" then return nil end
  if lane_info.stereo == true then return "stereo" end
  if lane_info.merged == true then return "merged" end
  return nil
end

-- Swing's own printed items: Swing's sequencer greys those (eon_plm_*), neither the Drum Matrix nor Steppa touches them.
function M.dm_skip_item(it)
  local _, a = reaper.GetSetMediaItemInfo_String(it, "P_EXT:EON_SEQ_LANES", "", false)
  if a and a ~= "" then return true end
  local _, b = reaper.GetSetMediaItemInfo_String(it, "P_EXT:EON_SEQ_PRINT", "", false)
  return b ~= nil and b ~= ""
end

-- The stereo lanes' pad rows, attached for dm_apply: rows_of(lane_info) -> { { pad = 1..16, pitch = n }, ... }
-- (lane_tools.StereoRows). Returns `lanes`.
function M.dm_with_rows(lanes, rows_of)
  for _, ln in ipairs(lanes or {}) do
    if M.dm_kind(ln.lane_info) == "stereo" and rows_of then
      local ok, rows = pcall(rows_of, ln.lane_info)
      ln.rows = ok and rows or {}
    end
  end
  return lanes
end

-- True while any Drum Matrix grey state is on (the watcher's cheap test).
function M.dm_any(lanes)
  for _, ln in ipairs(lanes or {}) do
    local k = ln.track and M.dm_kind(ln.lane_info)
    if k then
      local m, s = M.dm_state(ln.track)
      if m or s then return true end
      if k == "stereo" then
        local mm, sm = M.dm_pads(ln.track)
        if mm ~= 0 or sm ~= 0 then return true end
      end
    end
  end
  return false
end

-- Every stereo / merged lane in `lanes` ({ track, lane_info, rows } as dm_with_rows leaves them) greyed or not by the
-- Drum Matrix's state; returns the notes changed. dry = count only.
function M.dm_apply(lanes, dry)
  local st, anysolo = {}, false
  for _, ln in ipairs(lanes or {}) do
    local k = ln.track and M.dm_kind(ln.lane_info)
    if k then
      local m, s = M.dm_state(ln.track)
      local x = { tr = ln.track, kind = k, m = m, s = s, mm = 0, sm = 0, pad_of = {} }
      if k == "stereo" then
        x.mm, x.sm = M.dm_pads(ln.track)
        for _, row in ipairs(ln.rows or {}) do x.pad_of[row.pitch] = row.pad end
      end
      st[#st + 1] = x
      if s or x.sm ~= 0 then anysolo = true end
    end
  end
  local n = 0
  for _, x in ipairs(st) do
    local want
    if x.kind == "merged" then
      local grey = x.m or (anysolo and not x.s)
      want = function() return grey end
    else
      want = function(note)
        local pad = x.pad_of[note.pitch]
        local b = pad and (1 << (pad - 1)) or 0
        local pm, ps = x.mm & b ~= 0, x.sm & b ~= 0
        return x.m or pm or (anysolo and not (x.s or ps))
      end
    end
    for i = 0, reaper.CountTrackMediaItems(x.tr) - 1 do
      local it = reaper.GetTrackMediaItem(x.tr, i)
      if not M.dm_skip_item(it) then n = n + M.hold(it, M.DM_KEY, M.DM_OWNER, M.DM_BIT, want, dry) end
    end
  end
  return n
end

-- ── A paired Steppa (2026-10-30, the owner's "only grey the notes") ──────────────────────────────────────────────────
-- Its lane mute / solo grey ITS kit's pads' notes in the Drum Matrix clips of the Swing it is paired with: the lanes
-- whose tag names that Swing's track GUID (classic, merged, stereo), Swing's prints skipped. grey_by_pitch[pitch] =
-- true / false per pad note (pitches of no pad: nil, left alone). Returns the notes changed. dry = count only.
function M.ss_apply(lanes, swing_guid, grey_by_pitch, dry)
  local n = 0
  local want = function(note) return grey_by_pitch[note.pitch] end
  local seen = {}
  for _, ln in ipairs(lanes or {}) do
    local li = ln.lane_info
    if ln.track and type(li) == "table" and li.swing_instance_guid == swing_guid and not seen[ln.track] then
      seen[ln.track] = true
      for i = 0, reaper.CountTrackMediaItems(ln.track) - 1 do
        local it = reaper.GetTrackMediaItem(ln.track, i)
        if not M.dm_skip_item(it) then n = n + M.hold(it, M.DM_KEY, M.DM_OWNER, M.SS_BIT, want, dry) end
      end
    end
  end
  return n
end

return M
