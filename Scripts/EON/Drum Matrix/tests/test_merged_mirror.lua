-- test_merged_mirror.lua -- Offline tests for lib/merged_mirror.lua.
--
-- Merged mode's note mirroring is pure project-state manipulation, so it can be
-- exercised without REAPER: reaper_stub.lua implements just enough of the
-- media-item/MIDI API (fixed 120 BPM, 960 ppq per QN) to run the real module.
-- These are NOT a substitute for trying merged mode in REAPER -- routing,
-- playback and the Drum Strip can only be verified there -- but they pin the
-- parts that are easy to get silently wrong: loop expansion, clipping to item
-- bounds, mute handling, audio items sharing a lane track, and digest churn.
--
-- Not shipped: deliberately absent from index.xml, so ReaPack never installs it.
--
-- Run:  lua5.4 test_merged_mirror.lua        (from this directory)

local HERE = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or './'
local LIB  = HERE .. '../lib/'
local P    = dofile(HERE .. 'reaper_stub.lua')
reaper = P.R
local json = dofile(LIB .. "json.lua")

local pass, fail = 0, 0
local function ok(cond, msg)
  if cond then pass = pass + 1 else fail = fail + 1; print("  FAIL: " .. msg) end
end
local function near(a, b, msg, tol)
  tol = tol or 1e-6
  if type(a) ~= "number" then fail = fail + 1; print("  FAIL: "..msg.." (got "..tostring(a)..")") return end
  ok(math.abs(a - b) < tol, msg .. string.format(" (got %.6f want %.6f)", a, b))
end

local GUID = "{SWING-1}"

-- Fresh project each test; merged_mirror is re-loaded so its digest cache resets.
local function fresh()
  P.tracks = {}
  local swing = P.newtrack("Swing")
  return swing, dofile(LIB .. "merged_mirror.lua")
end

local function add_lane(pad_idx, pitch)
  local tr = P.newtrack(string.format("%02d Pad", pad_idx))
  tr.ext["EON_DRUM_LANE"] = json.encode({
    merged = true, swing_instance_guid = GUID,
    pad_index = pad_idx, pad_pitch = pitch, pad_channel = 1, pad_name = "Pad",
  })
  return tr
end

local function trigger_notes(M)
  local t = M.FindTrigger(GUID)
  if not t or #t.items == 0 then return {}, t end
  return t.items[1].notes, t
end

-- T1 ── basic collect + rebuild ---------------------------------------------
print("T1 basic collect/rebuild")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  local b = add_lane(2, 38)
  P.additem(a, { pos = 0.0, len = 2.0, notes = { { s = 0,   e = 480,  ch = 0, pitch = 36, vel = 100 } } })
  P.additem(b, { pos = 0.0, len = 2.0, notes = { { s = 960, e = 1440, ch = 0, pitch = 38, vel = 90  } } })
  ok(M.EnsureTrigger(swing, GUID, "Kit") ~= nil, "trigger created")
  ok(M.Sync(GUID) == true, "first sync rebuilds")
  local n = trigger_notes(M)
  ok(#n == 2, "two notes mirrored (got " .. #n .. ")")
  if #n == 2 then
    near(n[1].s, 0,   "note1 at ppq 0")
    near(n[2].s, 960, "note2 at ppq 960 (0.5 s)")
    ok(n[1].pitch == 36 and n[2].pitch == 38, "pitches preserved verbatim")
    ok(n[1].vel == 100 and n[2].vel == 90, "velocities preserved")
  end
  ok(M.Sync(GUID) == false, "second sync is a no-op (digest unchanged)")
end

-- T2 ── loop expansion -------------------------------------------------------
print("T2 loop expansion")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  -- 1-bar source (4 QN = 2 s) looped across an 8 QN (4 s) item.
  local it = P.additem(a, { pos = 0.0, len = 4.0, loop = true,
                            notes = { { s = 0, e = 240, ch = 0, pitch = 36, vel = 100 } } })
  it.src = { qn = 4 }
  M.EnsureTrigger(swing, GUID, "Kit"); M.Sync(GUID)
  local n = trigger_notes(M)
  ok(#n == 2, "looped note repeats twice (got " .. #n .. ")")
  if #n == 2 then
    near(n[1].s, 0,    "rep 1 at ppq 0")
    near(n[2].s, 3840, "rep 2 at ppq 3840 (2.0 s)")
  end
end

-- T3 ── clipping to item bounds ---------------------------------------------
print("T3 clipping")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  P.additem(a, { pos = 0.0, len = 1.0, notes = {
    { s = 0,    e = 240,  ch = 0, pitch = 36, vel = 100 },  -- inside
    { s = 2880, e = 3120, ch = 0, pitch = 36, vel = 100 },  -- starts past item end
    { s = 1800, e = 3000, ch = 0, pitch = 36, vel = 100 },  -- starts inside, ends past
  } })
  M.EnsureTrigger(swing, GUID, "Kit"); M.Sync(GUID)
  local n = trigger_notes(M)
  ok(#n == 2, "note starting past item end dropped (got " .. #n .. ")")
  local last = n[#n]
  if last then near(last.e, 1920, "overhanging note clipped to item end (ppq 1920 = 1.0 s)") end
end

-- T4 ── mutes -----------------------------------------------------------------
print("T4 mutes")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  local b = add_lane(2, 38)
  P.additem(a, { pos = 0.0, len = 2.0, mute = true,
                 notes = { { s = 0, e = 240, ch = 0, pitch = 36, vel = 100 } } })
  P.additem(b, { pos = 0.0, len = 2.0, notes = {
    { s = 0,   e = 240, ch = 0, pitch = 38, vel = 100, mute = true },
    { s = 480, e = 720, ch = 0, pitch = 38, vel = 100 },
  } })
  M.EnsureTrigger(swing, GUID, "Kit"); M.Sync(GUID)
  local n = trigger_notes(M)
  ok(#n == 1, "muted item and muted note both excluded (got " .. #n .. ")")
  -- The trigger item is created spanning the notes, so its ppq 0 IS the
  -- first surviving note; check the absolute project time instead.
  local _, t = trigger_notes(M)
  if n[1] then near(n[1].s, 0, "surviving note at trigger ppq 0") end
  if t and t.items[1] then near(t.items[1].pos, 0.25, "trigger item starts at 0.25 s (ppq 480 of the lane)") end
end

-- T5 ── audio items on a merged track ----------------------------------------
print("T5 audio item on merged track")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  P.additem(a, { pos = 0.0, len = 3.0, midi = false })              -- an audio item
  P.additem(a, { pos = 0.0, len = 2.0,
                 notes = { { s = 0, e = 240, ch = 0, pitch = 36, vel = 100 } } })
  M.EnsureTrigger(swing, GUID, "Kit")
  local okc = pcall(M.Sync, GUID)
  ok(okc, "audio item does not crash the mirror")
  local n = trigger_notes(M)
  ok(#n == 1, "audio item ignored, MIDI item mirrored (got " .. #n .. ")")
end

-- T6 ── digest reacts to edits ------------------------------------------------
print("T6 digest")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  local it = P.additem(a, { pos = 0.0, len = 2.0,
                            notes = { { s = 0, e = 240, ch = 0, pitch = 36, vel = 100 } } })
  M.EnsureTrigger(swing, GUID, "Kit")
  M.Sync(GUID)
  ok(M.Sync(GUID) == false, "no rebuild when nothing changed")
  it.notes[1].s = 480                                    -- user moves the note
  ok(M.Sync(GUID) == true, "rebuild after a note moves")
  it.pos = 1.0                                           -- user drags the item
  ok(M.Sync(GUID) == true, "rebuild after the item moves")
  local n = trigger_notes(M)
  if n[1] then near(n[1].s, 0, "moved item: note lands at trigger-item ppq 0 (1.25 s abs)") end
end

-- T7 ── trigger track shape ---------------------------------------------------
print("T7 trigger track")
do
  local swing, M = fresh()
  add_lane(1, 36)
  local t1 = M.EnsureTrigger(swing, GUID, "Kit")
  local t2 = M.EnsureTrigger(swing, GUID, "Kit")
  ok(t1 == t2, "EnsureTrigger is idempotent")
  ok(t1.vals["B_SHOWINTCP"] == 0 and t1.vals["B_SHOWINMIXER"] == 0, "trigger hidden in TCP and MCP")
  ok(t1.vals["B_MAINSEND"] == 0, "trigger has no master send")
  ok(#t1.sends == 1, "trigger has exactly one send")
  ok(t1.sends[1].dst == swing, "trigger sends to the Swing track")
  ok(t1.sends[1]["I_SRCCHAN"] == -1, "send is MIDI-only (audio disabled)")
  ok(#swing.sends == 0, "Swing gains no send back to the trigger (no cycle)")
  ok(#M.MergedInstances() == 1, "MergedInstances finds the kit")
end

-- T8 ── empty lanes -----------------------------------------------------------
print("T8 empty / stale")
do
  local swing, M = fresh()
  local a = add_lane(1, 36)
  local it = P.additem(a, { pos = 0.0, len = 2.0,
                            notes = { { s = 0, e = 240, ch = 0, pitch = 36, vel = 100 } } })
  local t = M.EnsureTrigger(swing, GUID, "Kit")
  M.Sync(GUID)
  ok(#t.items == 1, "trigger item present")
  it.notes = {}                                          -- user deletes every note
  M.Sync(GUID)
  ok(#t.items == 0, "trigger emptied when all notes go away")
  ok(M.Sync("{NOT-A-KIT}") == false, "unknown guid is a safe no-op")
end

print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
