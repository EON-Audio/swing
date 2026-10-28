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
-- Pad Banks Outputs step 2: inside the audio sub, "Bank A" (P_EXT:EON_BANK_FOLDER) folds
-- the sixteen multi-outs, and each bank B-D track (P_EXT:EON_BANK_TRACK) folds the pads
-- split off from its bank; a bank group runs to the next bank header or the first Swing
-- return. Those headers never count as sub-folders of the parent. The sub's own close is
-- added to what its last child already closes (Bank D's last split: -1 + -2 = -3).
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

local function _pext(tr, key)
  local _, v = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:' .. key, '', false)
  return v or ''
end

-- Is `par` (the folder right above Swing) a parent Swing built? Ownership, not position (A3b, 2026-10-26): position
-- alone took a folder the user made ("Drums", Swing its first track) for Swing's parent -- the bridge renamed it
-- "Swing — <kit>" and recoloured it, and EnsureSwingParentLayout rewrote its tracks' depths. The same rule as the
-- bridge's eon_swing_parent_owned, cheapest proof first:
--   * P_EXT:EON_SWING_PARENT -- every parent made from now on (EnsureParent below, the bridge's Multi-Out build);
--     the bridge stamps it on an older parent that passes a test below;
--   * the name "Swing — ..." -- the label the bridge writes on every name sync to the parent it found;
--   * a track one of Swing's sends feeds, carrying P_EXT:EON_PAD_IDX (Swing's pad track), somewhere inside it;
--   * one of Swing's tagged sub-folders directly inside it (EON_AUDIO_KIT_FOLDER, EON_DRUM_KIT_FOLDER).
-- Each is something only Swing writes. Tracks compared by GUID.
function M.IsSwingParent(par, swing_track)
  if not par or not swing_track then return false end
  if _pext(par, 'EON_SWING_PARENT') ~= '' then return true end
  local _, nm = reaper.GetSetMediaTrackInfo_String(par, 'P_NAME', '', false)
  if nm and nm:sub(1, #'Swing — ') == 'Swing — ' then return true end
  local pg = reaper.GetTrackGUID(par)
  if not pg or pg == '' then return false end
  for s = 0, reaper.GetTrackNumSends(swing_track, 0) - 1 do
    local d = reaper.GetTrackSendInfo_Value(swing_track, 0, s, 'P_DESTTRACK')
    if not d and reaper.BR_GetMediaTrackSendInfo_Track then
      d = reaper.BR_GetMediaTrackSendInfo_Track(swing_track, 0, s, 1)
    end
    if d and _pext(d, 'EON_PAD_IDX') ~= '' then
      local p = reaper.GetParentTrack(d)
      while p do
        if reaper.GetTrackGUID(p) == pg then return true end
        p = reaper.GetParentTrack(p)
      end
    end
  end
  local i = math.floor(reaper.GetMediaTrackInfo_Value(par, 'IP_TRACKNUMBER') + 0.5)   -- 0-based: the track after it
  local depth, total = 1, reaper.CountTracks(0)
  while i < total and depth > 0 do
    local tr = reaper.GetTrack(0, i)
    if not tr then break end
    if _pext(tr, 'EON_AUDIO_KIT_FOLDER') ~= '' or _pext(tr, 'EON_DRUM_KIT_FOLDER') ~= '' then
      local p = reaper.GetParentTrack(tr)
      if p and reaper.GetTrackGUID(p) == pg then return true end
    end
    depth = depth + reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
    i = i + 1
  end
  return false
end

-- Return Swing's parent folder track: the folder Swing sits in (REAPER's own GetParentTrack) when Swing built it
-- (M.IsSwingParent), or nil if Swing isn't inside a folder of its own (a folder the user made is not one).
-- The folder it SITS IN, not the track directly above it (DM25, 2026-10-26): a user track dropped at the top of
-- Swing's folder hid the parent from the old rule, so EnsureParent nested a second parent right above Swing
-- inside the first; the old close then closed the new one and the old parent ran open over every track below.
-- The walkers below already treat tracks before Swing as 'other'.
function M.FindParent(swing_track)
  if not swing_track then return nil end
  local par = reaper.GetParentTrack(swing_track)
  if par and M.IsSwingParent(par, swing_track) then return par end
  return nil
end

-- Ensure Swing has a parent folder above it, creating one (unnamed) if
-- missing. Returns the parent track. Used by EON_DM_Build when the user
-- builds the Drum Matrix folder before ever clicking Multi-Out.
-- A3b: the new parent is tagged P_EXT:EON_SWING_PARENT and closes on Swing (Swing's close grows by one): a folder
-- of the user's that Swing sat in keeps its own end, and the parent no longer runs open to the project's end (the
-- build's EndOfParentIndex put the MIDI folder after every track below). The MIDI folder built right after Swing
-- is then pulled in by EnsureSwingParentLayout's re-absorb (its lanes are tagged).
function M.EnsureParent(swing_track)
  if not swing_track then return nil end
  local existing = M.FindParent(swing_track)
  if existing then
    if _pext(existing, 'EON_SWING_PARENT') == '' then   -- an older parent that passed on a proof
      reaper.GetSetMediaTrackInfo_String(existing, 'P_EXT:EON_SWING_PARENT', '1', true)
    end
    return existing
  end
  local sw_idx = math.floor(reaper.GetMediaTrackInfo_Value(swing_track, 'IP_TRACKNUMBER') + 0.5) - 1
  reaper.InsertTrackAtIndex(sw_idx, true)
  local parent = reaper.GetTrack(0, sw_idx)
  if parent then
    reaper.SetMediaTrackInfo_Value(parent, 'I_FOLDERDEPTH', 1)
    reaper.GetSetMediaTrackInfo_String(parent, 'P_EXT:EON_SWING_PARENT', '1', true)
    local sd = reaper.GetMediaTrackInfo_Value(swing_track, 'I_FOLDERDEPTH')
    if sd <= 0 then reaper.SetMediaTrackInfo_Value(swing_track, 'I_FOLDERDEPTH', sd - 1) end
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
  -- Walk parent contents (same stopping rule as _walk_parent_contents). Every track's depth counts, Swing's
  -- included (DM217, 2026-10-26: Swing as the parent's only child closes it with -1, and leaving that out ran
  -- the walk past the parent to the end of the project, where another group's stranded MIDI folder could be
  -- returned, renamed and repainted); only the header test skips Swing.
  local depth = 1
  local i = p_idx + 1
  while i < total and depth > 0 do
    local tr = reaper.GetTrack(0, i)
    if not tr then break end
    local d = reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
    -- Only check tracks that ARE folder headers (depth >= 1 at parent level).
    if tr ~= swing_track and d >= 1 and depth == 1 then
      local _, raw = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_DRUM_KIT_FOLDER', '', false)
      if raw and raw ~= '' then return tr end
    end
    depth = depth + d
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

-- Pad Banks Outputs step 2: the Audio sub holds folders of its own -- "Bank A" (P_EXT:EON_BANK_FOLDER, a bus over
-- the sixteen pad tracks) and the bank B, C, D tracks (P_EXT:EON_BANK_TRACK, each the folder of the pads split
-- off from its bank). They open a folder, but INSIDE the Audio sub: never a sub-folder of the parent.
local function _is_bank_header(tr)
  local _, a = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_BANK_FOLDER', '', false)
  if a and a ~= '' then return true end
  local _, b = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:EON_BANK_TRACK', '', false)
  return b ~= nil and b ~= ''
end
local function _is_swing_return(tr)
  for _, k in ipairs({ 'P_EXT:EON_VERB_RETURN', 'P_EXT:EON_DELAY_RETURN', 'P_EXT:EON_SMASH_RETURN' }) do
    local _, v = reaper.GetSetMediaTrackInfo_String(tr, k, '', false)
    if v and v ~= '' then return true end
  end
  return false
end

local function _is_sub_header(tr, d)
  if _is_bank_header(tr) then return false end
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
  -- Folders OUTSIDE the parent that the walked tracks also closed (A3b, 2026-10-26): Swing's parent inside a folder
  -- of the user's whose last track is Swing's (-3 = sub + parent + the user's). The rewrite below sets the canonical
  -- -2 and would drop that third close, leaving the user's folder open over every track below. The walk ending at
  -- <= 0 is the parent's close; anything below 0 belongs outside. A walk that ran off the end (never closed) has none.
  local outer = (cum_depth < 0) and cum_depth or 0

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
    local hd = reaper.GetMediaTrackInfo_Value(hdr, 'I_FOLDERDEPTH')
    entries[#entries + 1] = { track = hdr, role = 'subfolder_header', original_depth = hd }
    local net = hd   -- this sub's own net depth: 0 when it opens and closes itself, below 0 = outer closes too
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
        -- anything opening a new folder (untagged d>=1) — outside our group. A bank
        -- folder (Outputs step 2) opens one INSIDE the Audio sub: it belongs.
        if cd >= 1 and not _is_bank_header(c) then break end
      end
      entries[#entries + 1] = { track = c, role = 'subfolder_child', original_depth = cd }
      net = net + cd
      i = i + 1
    end
    if net < 0 then outer = outer + net end   -- a sub left open (net > 0, the DM build's lanes at 0) closes nothing
  end

  return parent, entries, outer
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
  local parent, entries, outer = _walk_parent_contents(swing_track)
  if not parent or not entries then return false end
  outer = outer or 0

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
  -- Bank folders inside it (Outputs step 2): a bank header opens a group that runs to the next bank header or the
  -- first Swing return; a group with members opens (+1) and its last member closes it (-1), a group without stays a
  -- plain track. The sub's own close is ADDED to whatever its last child already closes. A sub without bank headers
  -- (the DM sub, a pre-step-2 Audio sub) comes out exactly as before.
  -- The parent's close goes on the LAST track inside it (DM26, 2026-10-26): a user track placed after the final
  -- sub's last child (a "Drum Bus" dragged to the end of Swing's folder) was zeroed by Pass 1 while that child
  -- took -2, so the parent closed above the user's track and pushed it out to the top level. When the final sub's
  -- last child is not the group's last track, the sub closes with -1 only and entries[#entries] takes the -1 the
  -- no-sub branch below would give it.
  local last_in_parent = entries[#entries] and entries[#entries].track
  local parent_closed = false
  for sub_idx, s in ipairs(real_subs) do
    reaper.SetMediaTrackInfo_Value(s.header, 'I_FOLDERDEPTH', 1)
    local cur
    for _, c in ipairs(s.children) do
      if _is_bank_header(c) then
        if cur and cur.last then reaper.SetMediaTrackInfo_Value(cur.last, 'I_FOLDERDEPTH', -1) end
        cur = { header = c, last = nil }
        reaper.SetMediaTrackInfo_Value(c, 'I_FOLDERDEPTH', 0)
      elseif _is_swing_return(c) then
        if cur and cur.last then reaper.SetMediaTrackInfo_Value(cur.last, 'I_FOLDERDEPTH', -1) end
        cur = nil
      elseif cur then
        if not cur.last then reaper.SetMediaTrackInfo_Value(cur.header, 'I_FOLDERDEPTH', 1) end
        cur.last = c
      end
    end
    if cur and cur.last then reaper.SetMediaTrackInfo_Value(cur.last, 'I_FOLDERDEPTH', -1) end
    local last = s.children[#s.children]
    local closes_parent = (sub_idx == #real_subs) and (last == last_in_parent)
    local inner = reaper.GetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH')
    if inner > 0 then inner = 0 end   -- a member-less bank header at the very end
    reaper.SetMediaTrackInfo_Value(last, 'I_FOLDERDEPTH', inner + (closes_parent and -2 or -1))
    if closes_parent then parent_closed = true end
  end

  -- No real sub-folders (the parent holds only Swing, + maybe manual "other"
  -- tracks), or a user track sits after the final sub (DM26): the LAST track
  -- in the parent must close it with -1, otherwise the parent never closes
  -- and any track inserted below the parent later gets sucked into it.
  if not parent_closed and #entries > 0 then
    reaper.SetMediaTrackInfo_Value(last_in_parent, 'I_FOLDERDEPTH', -1)
  end

  -- The folders outside the parent that the walked tracks closed (A3b) close on the group's last track again.
  if outer < 0 and #entries > 0 then
    local lt = entries[#entries].track
    reaper.SetMediaTrackInfo_Value(lt, 'I_FOLDERDEPTH', reaper.GetMediaTrackInfo_Value(lt, 'I_FOLDERDEPTH') + outer)
  end

  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  return true
end

return M
