-- EON_DM_SeedLane.lua -- DEV-ONLY P_EXT:EON_DRUM_LANE seeder. Phase 8's Build
-- action will subsume the create-from-scratch path; this script is the
-- "adapt selected tracks" workflow.
--
-- One-shot REAPER action: for each selected track (in selection order):
--   1. Writes a P_EXT:EON_DRUM_LANE JSON record with the pad pitch + name
--      read live from the Swing JSFX gmem (falls back to GM defaults if
--      Swing isn't loaded or hasn't published yet).
--   2. Sets the track color to a position-based rainbow hue.
--   3. Creates a 4-bar MIDI item at the edit cursor (only if the track has
--      no existing items).
--
-- gmem timing fix (Phase 4 polish):
-- Swing JSFX only publishes pad metadata when gmem[99] (KIT_GMEM_BRIDGE_ALIVE)
-- is recent. If Swing_Kit_Bridge.lua isn't running, the data is stale or zero.
-- We bump that slot ourselves, defer one frame so JSFX has a chance to publish,
-- then read pad data. Works even without the bridge running.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local json = dofile(SCRIPT_DIR .. 'lib/json.lua')
if not (json and json.encode) then
  r.ShowMessageBox('lib/json.lua missing or invalid.', 'EON DM Seed', 0)
  return
end
local category = dofile(SCRIPT_DIR .. 'lib/category.lua')

-- Default GM-style fallback used when Swing isn't running / heartbeat dead.
local DEFAULT_PADS = {
  {pitch=36, name='Kick'},      {pitch=37, name='Side Stick'},
  {pitch=38, name='Snare'},     {pitch=39, name='Clap'},
  {pitch=40, name='Snare 2'},   {pitch=41, name='Low Tom'},
  {pitch=42, name='Closed HH'}, {pitch=43, name='High Tom'},
  {pitch=44, name='Pedal HH'},  {pitch=45, name='Mid Tom'},
  {pitch=46, name='Open HH'},   {pitch=47, name='Low Tom 2'},
  {pitch=48, name='Hi Tom'},    {pitch=49, name='Crash'},
  {pitch=50, name='Hi Tom 2'},  {pitch=51, name='Ride'},
}

-- Read live pad pitches+names from the Swing JSFX gmem AFTER the bridge-alive
-- bump has had a frame to take effect.
local function read_live_pads()
  if (r.gmem_read(1711) or 0) == 0 then return nil end   -- no Swing alive
  local pads = {}
  for i = 1, 16 do
    local pitch_raw = r.gmem_read(100 + (i - 1) * 80 + 10) or 0
    local pitch = math.floor(pitch_raw + 0.5)
    if pitch < 0 or pitch > 127 then pitch = DEFAULT_PADS[i].pitch end

    local name_base = 1720 + (i - 1) * 32
    local bytes = {}
    for j = 0, 31 do
      local c = r.gmem_read(name_base + j) or 0
      if c == 0 then break end
      bytes[#bytes + 1] = string.char(math.floor(c) & 0xFF)
    end
    local name = table.concat(bytes)
    if name == '' then name = DEFAULT_PADS[i].name end

    pads[i] = { pitch = pitch, name = name }
  end
  -- Sanity: if EVERY read pitch matched defaults exactly, JSFX likely hasn't
  -- published (we're seeing zeros that happened to fall through fallbacks).
  -- Caller will treat nil here as "use defaults" too.
  local any_nontrivial = false
  for i = 1, 16 do
    if pads[i].name ~= DEFAULT_PADS[i].name then any_nontrivial = true; break end
  end
  if not any_nontrivial then return nil end
  return pads
end

-- HSV -> RGB (S=0.7, V=0.85, H in [0,1)). Returns 0..255 ints.
local function hsv_to_rgb(h, s, v)
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  local rr, gg, bb = 0, 0, 0
  local seg = i % 6
  if     seg == 0 then rr, gg, bb = v, t, p
  elseif seg == 1 then rr, gg, bb = q, v, p
  elseif seg == 2 then rr, gg, bb = p, v, t
  elseif seg == 3 then rr, gg, bb = p, q, v
  elseif seg == 4 then rr, gg, bb = t, p, v
  else                 rr, gg, bb = v, p, q end
  return math.floor(rr * 255 + 0.5),
         math.floor(gg * 255 + 0.5),
         math.floor(bb * 255 + 0.5)
end

local function rainbow_color(pad_index)
  local h = ((pad_index - 1) % 16) / 16
  local R, G, B = hsv_to_rgb(h, 0.7, 0.85)
  return r.ColorToNative(R, G, B) | 0x1000000
end

-- ---------------------------------------------------------------------------
-- Up-front: count selection, attach gmem, bump bridge alive.
-- ---------------------------------------------------------------------------

local n = r.CountSelectedTracks(0)
if n <= 0 then
  r.ShowMessageBox('No tracks selected. Select one or more tracks first.', 'EON DM Seed', 0)
  return
end

-- Snapshot the selection now; the deferred phase will iterate it again.
local selected_tracks = {}
for i = 0, n - 1 do selected_tracks[#selected_tracks + 1] = r.GetSelectedTrack(0, i) end

r.gmem_attach('Swing_Media_Transfer')
r.gmem_write(99, os.time())   -- bump KIT_GMEM_BRIDGE_ALIVE so JSFX publishes

-- ---------------------------------------------------------------------------
-- Deferred phase: after JSFX has had a frame to publish pad metadata, read
-- and apply. Loop up to ~10 frames waiting for the heartbeat to confirm
-- publish happened.
-- ---------------------------------------------------------------------------

local frames_waited = 0
local MAX_FRAMES    = 10

local function dim_color_for_pad(pad_index)
  -- HSL -> RGB with position-based hue, dimmed by 0.18 (matches item_style.lua)
  local h = ((pad_index - 1) % 16) / 16
  local s, l = 0.7, 0.55
  local q = l < 0.5 and (l * (1 + s)) or (l + s - l * s)
  local p = 2 * l - q
  local function hue2rgb(t)
    if t < 0 then t = t + 1 end
    if t > 1 then t = t - 1 end
    if t < 1/6 then return p + (q - p) * 6 * t end
    if t < 1/2 then return q end
    if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
    return p
  end
  local rr = hue2rgb(h + 1/3)
  local gg = hue2rgb(h)
  local bb = hue2rgb(h - 1/3)
  local R = math.floor(rr * 255 * 0.18 + 0.5)
  local G = math.floor(gg * 255 * 0.18 + 0.5)
  local B = math.floor(bb * 255 * 0.18 + 0.5)
  return r.ColorToNative(R, G, B) | 0x1000000
end

local function do_seed()
  local PADS = read_live_pads() or DEFAULT_PADS
  local using_live = (PADS ~= DEFAULT_PADS)
  local created_at = os.date('!%Y-%m-%dT%H:%M:%SZ')
  local cursor_time = r.GetCursorPosition()
  if cursor_time < 0 then cursor_time = 0 end
  local cursor_qn  = r.TimeMap_timeToQN(cursor_time)
  local item_end_t = r.TimeMap_QNToTime(cursor_qn + 16)   -- 4 bars

  r.Undo_BeginBlock()
  local items_made = 0
  for i, track in ipairs(selected_tracks) do
    if track then
      local pad_index = ((i - 1) % 16) + 1
      local pad = PADS[pad_index]
      local payload = {
        swing_instance_guid = '{DEV-SEED-PLACEHOLDER}',
        pad_index = pad_index,
        pad_pitch = pad.pitch,
        pad_channel = 1,
        pad_name = pad.name,
        category = category.InferFromName(pad.name),
        created_at = created_at,
      }
      local encoded = json.encode(payload)
      r.GetSetMediaTrackInfo_String(track, 'P_EXT:EON_DRUM_LANE', encoded, true)
      r.SetTrackColor(track, rainbow_color(pad_index))

      -- Pre-create a 4-bar MIDI item at the edit cursor if this track has
      -- no items yet. Apply dim style + cleared take name.
      if r.CountTrackMediaItems(track) == 0 then
        local new_item = r.CreateNewMIDIItemInProj(track, cursor_time, item_end_t, false)
        if new_item then
          r.SetMediaItemInfo_Value(new_item, 'I_CUSTOMCOLOR', dim_color_for_pad(pad_index))
          local new_take = r.GetActiveTake(new_item)
          if new_take then
            r.GetSetMediaItemTakeInfo_String(new_take, 'P_NAME', '', true)
          end
          items_made = items_made + 1
        end
      end
    end
  end
  r.Undo_EndBlock('EON DM: seed drum lane markers', -1)
  r.UpdateArrange()

  local source_label = using_live and 'live Swing kit' or 'GM defaults (no Swing detected)'
  r.ShowMessageBox(
    string.format(
      'Seeded %d track(s) from %s.\nPre-created %d MIDI item(s) at cursor.\nReload EON Drum Matrix to see stripes.',
      #selected_tracks, source_label, items_made),
    'EON DM Seed', 0)
end

local function wait_then_seed()
  frames_waited = frames_waited + 1
  -- Either we've waited long enough OR the heartbeat ticked since we bumped it.
  local alive = r.gmem_read(1711) or 0
  if alive > 0 or frames_waited >= MAX_FRAMES then
    do_seed()
    return
  end
  r.defer(wait_then_seed)
end

r.defer(wait_then_seed)
