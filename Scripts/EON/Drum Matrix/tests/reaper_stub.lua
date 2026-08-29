-- Minimal REAPER API stub: enough of the media-item/MIDI surface to exercise
-- merged_mirror.lua for real. Fixed 120 BPM (1 QN = 0.5 s), 960 ppq per QN,
-- take PPQ measured from the item's own start.
local QN_SEC, PPQ_QN = 0.5, 960

local P = { tracks = {} }          -- the fake project
local R = {}

local function newtrack(name)
  local t = { name = name or '', ext = {}, items = {}, vals = {}, sends = {},
              guid = '{GUID-' .. tostring(#P.tracks + 1) .. '}' }
  P.tracks[#P.tracks + 1] = t
  return t
end
P.newtrack = newtrack

-- item: {pos, len, mute, loop, startoffs, midi=true/false, notes={{s,e,ch,pitch,vel,mute}} in PPQ}
function P.additem(tr, o)
  o.vals = {}
  o.notes = o.notes or {}
  if o.midi == nil then o.midi = true end
  tr.items[#tr.items + 1] = o
  return o
end

-- ── tracks ────────────────────────────────────────────────────────────────
function R.CountTracks() return #P.tracks end
function R.GetTrack(_, i) return P.tracks[i + 1] end
function R.GetTrackGUID(tr) return tr.guid end
function R.InsertTrackAtIndex(i, _) table.insert(P.tracks, i + 1, {
  name='', ext={}, items={}, vals={}, sends={}, guid='{GUID-NEW-'..tostring(i)..'}' }) end
function R.SetMediaTrackInfo_Value(tr, k, v) tr.vals[k] = v end
function R.GetMediaTrackInfo_Value(tr, k) return tr.vals[k] or 0 end
function R.GetSetMediaTrackInfo_String(tr, k, v, setit)
  if k == 'P_NAME' then
    if setit then tr.name = v return true, v end
    return true, tr.name
  end
  local key = k:match('^P_EXT:(.+)$')
  if not key then return false, '' end
  if setit then tr.ext[key] = v return true, v end
  return (tr.ext[key] ~= nil), (tr.ext[key] or '')
end
function R.CreateTrackSend(src, dst) src.sends[#src.sends + 1] = { dst = dst }; return #src.sends - 1 end
function R.SetTrackSendInfo_Value(src, _, i, k, v) src.sends[i + 1][k] = v end
function R.GetTrackSendInfo_Value(src, _, i, k)
  local s = src.sends[i + 1]; if not s then return 0 end
  if k == 'P_DESTTRACK' then return s.dst end
  return s[k] or 0
end
function R.GetTrackNumSends(tr) return #tr.sends end

-- ── items / takes (take == item here) ─────────────────────────────────────
function R.CountTrackMediaItems(tr) return #tr.items end
function R.GetTrackMediaItem(tr, i) return tr.items[i + 1] end
function R.GetActiveTake(it) return it end
function R.TakeIsMIDI(it) return it.midi == true end
function R.GetMediaItemInfo_Value(it, k)
  if k == 'D_POSITION' then return it.pos end
  if k == 'D_LENGTH'   then return it.len end
  if k == 'B_MUTE'     then return it.mute and 1 or 0 end
  if k == 'B_LOOPSRC'  then return it.loop and 1 or 0 end
  return it.vals[k] or 0
end
function R.SetMediaItemInfo_Value(it, k, v) it.vals[k] = v end
function R.GetMediaItemTakeInfo_Value(it, k)
  if k == 'D_STARTOFFS' then return it.startoffs or 0 end
  return 0
end
function R.GetSetMediaItemTakeInfo_String(it, k, v, setit)
  if setit then it[k] = v return true, v end
  return true, it[k] or ''
end
function R.DeleteTrackMediaItem(tr, it)
  for i, x in ipairs(tr.items) do if x == it then table.remove(tr.items, i) return true end end
  return false
end
function R.CreateNewMIDIItemInProj(tr, t0, t1)
  return P.additem(tr, { pos = t0, len = t1 - t0, midi = true, notes = {} })
end

-- ── MIDI ──────────────────────────────────────────────────────────────────
function R.MIDI_CountEvts(it) return true, #it.notes, 0, 0 end
function R.MIDI_GetNote(it, i)
  local n = it.notes[i + 1]
  if not n then return false end
  return true, false, n.mute or false, n.s, n.e, n.ch, n.pitch, n.vel
end
function R.MIDI_InsertNote(it, _, mutd, s, e, ch, pitch, vel)
  it.notes[#it.notes + 1] = { s = s, e = e, ch = ch, pitch = pitch, vel = vel, mute = mutd }
  return true
end
function R.MIDI_Sort(it) table.sort(it.notes, function(a, b) return a.s < b.s end) end
function R.MIDI_GetHash(it)
  local parts = {}
  for _, n in ipairs(it.notes) do
    parts[#parts + 1] = string.format('%d/%d/%d/%d/%d', n.s, n.e, n.ch, n.pitch, n.vel)
  end
  return true, table.concat(parts, ',')
end
function R.MIDI_GetProjTimeFromPPQPos(it, ppq) return it.pos + (ppq / PPQ_QN) * QN_SEC end
function R.MIDI_GetPPQPosFromProjTime(it, t)   return ((t - it.pos) / QN_SEC) * PPQ_QN end
function R.MIDI_GetProjQNFromPPQPos(it, ppq)   return (it.pos / QN_SEC) + ppq / PPQ_QN end
function R.MIDI_GetPPQPosFromProjQN(it, qn)    return (qn - it.pos / QN_SEC) * PPQ_QN end
function R.GetMediaItemTake_Source(it) return it.src end
function R.GetMediaSourceLength(src) return src.qn, true end   -- MIDI => length in QN

-- ── misc no-ops ───────────────────────────────────────────────────────────
function R.PreventUIRefresh() end
function R.UpdateArrange() end
function R.ColorToNative(r_, g_, b_) return r_ + g_ * 256 + b_ * 65536 end
function R.ValidatePtr() return true end
function R.time_precise() return os.clock() end

P.R = R
return P
