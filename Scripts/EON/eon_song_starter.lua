-- @noindex
-- eon_song_starter.lua
-- Shared builder behind the EON: New Song actions (loaded via dofile, not an
-- action itself — same arrangement as eon_action_target.lua).
--
-- Lays out a song skeleton in one undo point: tempo, four named regions, a
-- Swing track, an empty MIDI item per region, and the Drum Matrix lanes.
--
-- ORDERING MATTERS. Everything this script does directly is synchronous, but
-- the lane build is a BRIDGE command (code 73) that the bridge picks up on its
-- own defer tick — we cannot see it finish from here. So lanes are fired LAST
-- and nothing afterwards depends on them. Do not reorder this to build lanes
-- before the MIDI items: the items would race a track layout that does not
-- exist yet.
-- (c) EON Studios

local M = {}

-- Region tints, roughly matching the Swing pad hue vocabulary so a starter
-- project reads as EON-branded rather than REAPER-default grey.
local REGION_COLORS = {
  { 92, 124, 176 },   -- Intro   — blue
  { 96, 156, 108 },   -- Verse   — green
  { 196, 132,  72 },  -- Chorus  — amber
  { 132, 100, 160 },  -- Outro   — violet
}

M.DEFAULT_SECTIONS = { "Intro", "Verse", "Chorus", "Outro" }
M.DEFAULT_BARS = 8
M.DEFAULT_BPM = 120

-- Time (seconds) at the start of measure `bar`, 0-based. TimeMap2_beatsToTime
-- with a measure argument treats the beat operand as an offset INSIDE that
-- measure, so passing 0 lands exactly on the barline whatever the signature.
local function bar_time(bar)
  return reaper.TimeMap2_beatsToTime(0, 0, bar)
end

-- Insert a track at the end and return it. wantDefaults=false so the user's
-- default-track template (which may carry FX we would be rude to duplicate)
-- is not applied.
local function add_track(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, false)
  local tr = reaper.GetTrack(0, idx)
  if tr and name then
    reaper.GetSetMediaTrackInfo_String(tr, "P_NAME", name, true)
  end
  return tr
end

-- Resolve Swing's JSFX by the same identity the bridge and the action wrappers
-- use, rather than a display name that changes with the desc: line.
local function add_swing(tr)
  if not tr then return nil end
  -- -1 = instantiate if not already present. AddByName reports success even
  -- when the JSFX failed to COMPILE, so a non-negative return here means "the
  -- file was found", not "the plugin is healthy".
  local fx = reaper.TrackFX_AddByName(tr, "Swing_ReaKit", false, -1)
  if fx < 0 then
    fx = reaper.TrackFX_AddByName(tr, "EON/Swing/Swing_ReaKit", false, -1)
  end
  return fx >= 0 and fx or nil
end

-- opts:
--   bpm          number  | nil  — project tempo; nil leaves the tempo alone
--   bars         number        — bars per section (default 8)
--   sections     table         — section names, in order (default 4-part)
--   start_bar    number        — first bar, 0-based (default: current cursor bar)
--   insert_swing boolean       — add a track with Swing on it
--   midi_items   boolean       — one empty MIDI item per region on that track
--   build_lanes  boolean       — fire the Drum Matrix lane build (async)
--   target       table  | nil  — eon_action_target module, required for lanes
--
-- Returns ok, message.
function M.build(opts)
  opts = opts or {}
  local sections = opts.sections or M.DEFAULT_SECTIONS
  local bars = tonumber(opts.bars) or M.DEFAULT_BARS
  if bars < 1 then bars = 1 end
  if #sections == 0 then return false, "no sections to build" end

  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)

  -- Tempo first: every bar->time conversion below depends on it, so setting it
  -- afterwards would place the regions against the OLD grid.
  if opts.bpm then reaper.SetCurrentBPM(0, opts.bpm, false) end

  -- Default to the bar under the edit cursor so running this in a project that
  -- already has material appends rather than overlaying bar 1.
  local start_bar = opts.start_bar
  if not start_bar then
    local cur = reaper.GetCursorPosition()
    local _, measures = reaper.TimeMap2_timeToBeats(0, cur)
    start_bar = measures or 0
  end

  local tr, fx
  if opts.insert_swing then
    tr = add_track("Swing")
    fx = add_swing(tr)
  end

  for i, name in ipairs(sections) do
    local b0 = start_bar + (i - 1) * bars
    local t0, t1 = bar_time(b0), bar_time(b0 + bars)

    local c = REGION_COLORS[((i - 1) % #REGION_COLORS) + 1]
    -- |0x1000000 flags the colour as "set by the user"; without it REAPER
    -- treats the value as unset and paints the default.
    local col = reaper.ColorToNative(c[1], c[2], c[3]) | 0x1000000
    reaper.AddProjectMarker2(0, true, t0, t1, name, -1, col)

    if opts.midi_items and tr then
      -- Items land on the Swing track itself: that is the writing surface.
      -- The Drum Matrix lane children are for routing and display, and they
      -- do not exist yet at this point anyway (see the ordering note above).
      local item = reaper.CreateNewMIDIItemInProj(tr, t0, t1, false)
      if item then
        local take = reaper.GetActiveTake(item)
        if take then
          reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", name, true)
        end
      end
    end
  end

  -- Frame the new song so the user sees what just happened.
  reaper.GetSet_LoopTimeRange(true, false,
    bar_time(start_bar), bar_time(start_bar + #sections * bars), false)

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  reaper.Undo_EndBlock2(0, "EON: New Song", -1)

  -- LAST, and deliberately outside the undo block: this posts a command the
  -- bridge executes on a later tick, so it makes its own undo point. Firing it
  -- inside our block would leave the block open across an async boundary.
  if opts.build_lanes and opts.target and fx then
    opts.target.focus_lock()
    opts.target.fire(73)   -- Build MIDI Lanes (Drum Matrix)
  end

  local what = #sections .. " regions"
  if opts.insert_swing then
    what = what .. (fx and " + Swing" or " + Swing (FX ADD FAILED)")
  end
  if opts.midi_items then what = what .. " + MIDI items" end
  if opts.build_lanes and fx then what = what .. " + lanes" end
  return true, what
end

-- Shared prompt for the configurable entry point. Returns an opts fragment or
-- nil if the user cancelled.
function M.prompt()
  local ok, csv = reaper.GetUserInputs(
    "EON: New Song", 3,
    "Tempo (BPM),Bars per section,Sections (comma separated),extrawidth=180",
    M.DEFAULT_BPM .. "," .. M.DEFAULT_BARS .. ","
      .. table.concat(M.DEFAULT_SECTIONS, " ")
  )
  if not ok then return nil end

  -- GetUserInputs is itself comma-separated, so the section list cannot use
  -- commas as its own separator — it is space-separated in the field and the
  -- field is the LAST one, so anything after the second comma belongs to it.
  local bpm, bars, names = csv:match("^([^,]*),([^,]*),(.*)$")
  local sections = {}
  for word in tostring(names):gmatch("%S+") do sections[#sections + 1] = word end
  if #sections == 0 then sections = M.DEFAULT_SECTIONS end

  return {
    bpm = tonumber(bpm) or M.DEFAULT_BPM,
    bars = tonumber(bars) or M.DEFAULT_BARS,
    sections = sections,
  }
end

return M
