-- folder_layout.lua — EON ReaKit. Canonical layout enforcer for Swing's
-- parent folder. ONE source of truth so Multi-Out Build, EON_DM_Build, and
-- any future instrument build (Sedan, Coupe) don't have to reason about
-- each other's I_FOLDERDEPTH math.
--
-- Target layout (run after any build action):
--
--   [parent folder, unnamed]                I_FOLDERDEPTH = +1   ← opens parent
--   ├── Swing                                I_FOLDERDEPTH = 0
--   ├── <kit>                                I_FOLDERDEPTH = +1   ← audio sub
--   │   ├── multi-out 1..15                  I_FOLDERDEPTH = 0
--   │   └── multi-out 16                     I_FOLDERDEPTH = -1   ← closes audio sub
--   └── EON DM <kit>                         I_FOLDERDEPTH = +1   ← DM sub
--       ├── lane 1..15                       I_FOLDERDEPTH = 0
--       └── lane 16                          I_FOLDERDEPTH = -2   ← closes DM AND parent
--
-- Key invariant: the LAST child of the LAST sub-folder closes the parent
-- (depth -2). Every other sub-folder's last child closes only its own sub
-- (depth -1). Run-after-build means insertion order is irrelevant — build
-- whatever in whatever order, call EnsureSwingParentLayout, get the right
-- structure.
--
-- Tolerant of:
--   * No parent (returns false; caller decides whether to create one).
--   * Manually-inserted user tracks inside the parent (left at depth 0,
--     positionally where the user put them — only sub-folders and their
--     children get their depths normalized).
--   * Empty sub-folders (header track with no children → demoted to a
--     plain sibling at depth 0; doesn't pretend it's a folder).
--   * Idempotent — converges to the canonical pattern on every call.

local M = {}

-- ────────────────────────────────────────────────────────────────────────
-- Parent discovery (shared with Swing_Kit_Bridge.find_folder_track logic)
-- ────────────────────────────────────────────────────────────────────────

-- Return Swing's parent folder track (one above with I_FOLDERDEPTH == 1),
-- or nil if Swing isn't currently inside a folder.
function M.FindParent(swing_track)
  if not swing_track then return nil end
  local sw_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, 'IP_TRACKNUMBER') + 0.5) - 1
  if sw_idx < 1 then return nil end
  local above = reaper.GetTrack(0, sw_idx - 1)
  if not above then return nil end
  local depth = reaper.GetMediaTrackInfo_Value(above, 'I_FOLDERDEPTH')
  if depth == 1 then return above end
  return nil
end

-- Ensure Swing has a parent folder above it, creating one (unnamed) if
-- missing. Returns the parent track. Used by EON_DM_Build when the user
-- builds the Drum Matrix folder before ever clicking Multi-Out.
function M.EnsureParent(swing_track)
  if not swing_track then return nil end
  local existing = M.FindParent(swing_track)
  if existing then return existing end
  local sw_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, 'IP_TRACKNUMBER') + 0.5) - 1
  reaper.InsertTrackAtIndex(sw_idx, true)
  local parent = reaper.GetTrack(0, sw_idx)
  if parent then
    reaper.SetMediaTrackInfo_Value(parent, 'I_FOLDERDEPTH', 1)
    -- Leave the parent name BLANK so the kit-named sub-folders below
    -- (`<kit>` audio, `EON DM <kit>`) carry the labelling.
    reaper.GetSetMediaTrackInfo_String(parent, 'P_NAME', '', true)
  end
  return parent
end

-- Find the Drum Matrix sub-folder inside Swing's parent — i.e. the sub-folder
-- whose track has a non-empty P_EXT:EON_DRUM_KIT_FOLDER tag (written by
-- EON_DM_Build). Returns the track or nil. Used by the kit-rename path so
-- the bridge can update BOTH sub-folders' names ("<kit>" on audio, "EON DM
-- <kit>" on DM) when the live kit changes — without it the DM folder
-- froze on whatever kit was active when the user clicked Build.
function M.FindDMSubfolder(swing_track)
  local parent = M.FindParent(swing_track)
  if not parent then return nil end
  local p_idx = math.floor(reaper.GetMediaTrackInfo_Value(parent, 'IP_TRACKNUMBER') + 0.5) - 1
  local total = reaper.CountTracks(0)
  -- Walk parent contents (same stopping rule as _walk_parent_contents).
  local depth = 1
  local i = p_idx + 1
  while i < total and depth > 0 do
    local tr = reaper.GetTrack(0, i)
    if not tr then break end
    -- Only check tracks that ARE folder headers (depth >= 1 at parent level).
    if tr ~= swing_track then
      local d = reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
      if d >= 1 and depth == 1 then
        local _, raw = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_KIT_FOLDER', '', false)
        if raw and raw ~= '' then return tr end
      end
      depth = depth + d
    end
    i = i + 1
  end
  return nil
end

-- Return the 0-based track index of the LAST track currently sitting
-- inside Swing's parent (i.e. the track that today closes the parent via
-- its negative I_FOLDERDEPTH). Returns nil if no parent exists. Used by
-- builders to compute the "end-of-parent" insertion point — inserting
-- AT this index + 1 places the new content as the new last-inside.
function M.EndOfParentIndex(swing_track)
  local parent = M.FindParent(swing_track)
  if not parent then return nil end
  local p_idx = math.floor(reaper.GetMediaTrackInfo_Value(parent, 'IP_TRACKNUMBER') + 0.5) - 1
  local total = reaper.CountTracks(0)
  -- Walk forward from parent+1 tracking cumulative depth (starts at +1 from parent).
  local depth = 1
  local last_inside = p_idx
  local i = p_idx + 1
  while i < total and depth > 0 do
    local tr = reaper.GetTrack(0, i)
    if not tr then break end
    last_inside = i
    depth = depth + reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
    i = i + 1
  end
  return last_inside
end

-- ────────────────────────────────────────────────────────────────────────
-- Internal: walk + group the parent's contents
-- ────────────────────────────────────────────────────────────────────────

-- A track is a sub-folder header if it carries one of the kit-folder P_EXT
-- tags (audio multi-out sub or DM sub) OR currently opens a folder
-- (I_FOLDERDEPTH >= 1). The TAG check is what keeps two adjacent sub-folders
-- distinct: once a build leaves interior depths at 0 (or Pass-1 below zeroes a
-- header), depth alone can't tell a sub-folder header from a child — so the
-- audio sub and the DM sub would collapse into one. The tags survive that.
-- Tags-only header test (ignores I_FOLDERDEPTH). Used to re-absorb a sub-folder
-- that a prior layout pass stranded just PAST a premature parent-close — e.g.
-- Multi-Out closes the parent on the Audio sub's last child (-2), then the DM
-- "MIDI" folder is built right after it, landing outside the parent. The walk
-- would otherwise stop at the -2 and never normalise MIDI.
local function _is_tagged_sub_header(tr)
  local _, dm = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_KIT_FOLDER', '', false)
  if dm and dm ~= '' then return true end
  local _, au = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_AUDIO_KIT_FOLDER', '', false)
  if au and au ~= '' then return true end
  return false
end

local function _is_sub_header(tr, d)
  if d >= 1 then return true end
  return _is_tagged_sub_header(tr)
end

-- Returns parent + an ordered array of entries describing each track
-- inside Swing's parent. Each entry has role ∈ {swing, subfolder_header,
-- subfolder_child, other}. The walker stops the moment cumulative depth
-- returns to 0 (we've exited the parent).
local function _walk_parent_contents(swing_track)
  local parent = M.FindParent(swing_track)
  if not parent then return nil, nil end
  local p_idx = math.floor(reaper.GetMediaTrackInfo_Value(parent, 'IP_TRACKNUMBER') + 0.5) - 1
  local total = reaper.CountTracks(0)

  local entries = {}
  local cum_depth = 1                 -- inside parent
  local in_subfolder = false          -- are we currently descended into a sub?
  local i = p_idx + 1
  while i < total and cum_depth > 0 do
    local tr = reaper.GetTrack(0, i)
    if not tr then break end
    local d = reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')

    -- A header (by tag OR depth) ALWAYS starts a new sub-folder, even if we're
    -- already inside one — the previous sub implicitly ended at the track
    -- before it. This is what lets the audio sub and the DM sub stay distinct
    -- siblings when interior depths are 0 (the d417cfa regression). Depth-only
    -- detection mis-classified the second header as a child of the first.
    local role
    if tr == swing_track then
      role = 'swing'
    elseif _is_sub_header(tr, d) then
      role = 'subfolder_header'
      in_subfolder = true
    elseif in_subfolder then
      role = 'subfolder_child'
    else
      role = 'other'
    end
    entries[#entries + 1] = { track = tr, role = role, original_depth = d }

    -- After accounting for this track's depth contribution, did we exit
    -- the sub-folder we were in? cum_depth back to 1 = back at parent level.
    cum_depth = cum_depth + d
    if in_subfolder and cum_depth <= 1 then in_subfolder = false end
    i = i + 1
  end

  -- Re-absorb tagged sub-folders stranded just PAST a premature parent-close.
  -- The main walk stops at the track that returns cumulative depth to <= 0 (the
  -- parent's close). When Multi-Out runs first it closes the parent on the Audio
  -- sub's last child (-2); a DM "MIDI" folder built afterwards sits just outside
  -- that close, so the main walk never sees it (confirmed via logging 2026-06-04:
  -- end_of_parent=18, MIDI inserted at 19, entries showed only Swing+Audio).
  -- Pull any such tagged sub (+ its children) in as a sibling. Children are
  -- bounded by TAGS — DM lanes carry P_EXT:EON_DRUM_LANE — so this can never run
  -- away into unrelated tracks below the group (whose depths Pass-1 would zero).
  while i < total do
    local hdr = reaper.GetTrack(0, i)
    if not hdr or not _is_tagged_sub_header(hdr) then break end
    local _, dm_tag = reaper.GetSetMediaTrackInfo_String(hdr, 'P_EXT:EON_DRUM_KIT_FOLDER', '', false)
    local is_dm = dm_tag ~= nil and dm_tag ~= ''
    entries[#entries + 1] = {
      track = hdr, role = 'subfolder_header',
      original_depth = reaper.GetMediaTrackInfo_Value(hdr, 'I_FOLDERDEPTH'),
    }
    i = i + 1
    while i < total do
      local c = reaper.GetTrack(0, i)
      if not c or _is_tagged_sub_header(c) then break end
      local cd = reaper.GetMediaTrackInfo_Value(c, 'I_FOLDERDEPTH')
      if is_dm then
        -- DM lanes are tagged; the first non-lane bounds the group.
        local _, lane = reaper.GetSetMediaTrackInfo_String(c, 'P_EXT:EON_DRUM_LANE', '', false)
        if not lane or lane == '' then break end
      else
        -- Audio outs aren't individually tagged; accept depth-0 tracks, stop at
        -- anything opening a new folder (untagged d>=1) — outside our group.
        if cd >= 1 then break end
      end
      entries[#entries + 1] = { track = c, role = 'subfolder_child', original_depth = cd }
      i = i + 1
    end
  end

  return parent, entries
end

-- ────────────────────────────────────────────────────────────────────────
-- Main reorganizer
-- ────────────────────────────────────────────────────────────────────────

-- Walk Swing's parent, identify sub-folders + their children, and rewrite
-- every I_FOLDERDEPTH inside the parent to the canonical pattern. Returns
-- true if it applied a layout, false if Swing isn't in a parent (caller
-- should EnsureParent first or accept the no-op).
function M.EnsureSwingParentLayout(swing_track)
  if not swing_track then return false end
  local parent, entries = _walk_parent_contents(swing_track)
  if not parent or not entries then return false end

  -- Group consecutive subfolder_header + subfolder_child entries into
  -- one record each: { header_track, child_tracks = {...} }.
  local subfolders = {}
  local cur
  for _, e in ipairs(entries) do
    if e.role == 'subfolder_header' then
      cur = { header = e.track, children = {} }
      subfolders[#subfolders + 1] = cur
    elseif e.role == 'subfolder_child' and cur then
      cur.children[#cur.children + 1] = e.track
    end
  end

  -- Demote empty sub-folder headers (header but no children) to plain
  -- siblings — they're useless as folders and would leave the parent
  -- open with nothing closing them. Strip them out of the subfolders list
  -- but leave the track itself in place at depth 0 below.
  local real_subs = {}
  for _, s in ipairs(subfolders) do
    if #s.children > 0 then
      real_subs[#real_subs + 1] = s
    end
  end

  reaper.PreventUIRefresh(1)

  -- Parent: opens at +1 (idempotent; SetMediaTrackInfo only fires a UI
  -- update if the value actually changed, so this is cheap).
  reaper.SetMediaTrackInfo_Value(parent, 'I_FOLDERDEPTH', 1)

  -- Pass 1: zero out every track inside the parent (Swing + others +
  -- demoted-empty sub-folder headers + sub-folder children-not-last).
  -- We'll re-set the few that need a non-zero value next.
  for _, e in ipairs(entries) do
    reaper.SetMediaTrackInfo_Value(e.track, 'I_FOLDERDEPTH', 0)
  end

  -- Pass 2: for each real sub-folder, set header +1 and last child to
  -- -1 (or -2 if it's the FINAL sub-folder — closes parent too).
  for sub_idx, s in ipairs(real_subs) do
    reaper.SetMediaTrackInfo_Value(s.header, 'I_FOLDERDEPTH', 1)
    local last = s.children[#s.children]
    local is_final_sub = (sub_idx == #real_subs)
    reaper.SetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH', is_final_sub and -2 or -1)
  end

  -- Edge case: no real sub-folders. Parent contains only Swing (+ maybe
  -- manual "other" tracks). The LAST track in the parent must close it
  -- with -1, otherwise the parent never closes and any track inserted
  -- below the parent later gets sucked into it.
  if #real_subs == 0 and #entries > 0 then
    local last_entry = entries[#entries]
    reaper.SetMediaTrackInfo_Value(last_entry.track, 'I_FOLDERDEPTH', -1)
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  return true
end

return M
