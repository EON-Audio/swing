-- EON_StepSeq_Groove_Browser.lua -- GROOVE S3: .rgt groove-template importer.
--
-- Lists every REAPER Groove Template (<resource>/Data/Grooves/*.rgt -- the SWS/Fingers
-- groove library), parses it, reduces it to a <=64-step per-16th tick-offset template,
-- and stages it into the EON_SS_GROOVE gmem mailbox (26140000). The targeted StepSeq
-- adopts it into a USER groove slot (1..7) and PERSISTS it via @serialize -- after the
-- import neither this panel nor the bridge is needed for the groove to survive.
--
-- .rgt format (verified against SWS GrooveTemplates.cpp, 2026-07-03):
--   Version: 0|1
--   Number of beats in groove: N
--   Groove: M positions
--   <position-in-beats> [amplitude 0..1]     (one line per hit; v0 has no amplitude)
--
-- Reduction: each position snaps to its nearest 16th; the delta becomes the step's
-- tick offset (128 ticks/step). The template is normalized so its EARLIEST hit sits on
-- the grid (the engine is delay-only); undefined steps take the normalization baseline.
-- At strength 100 the imported groove plays verbatim; the wheel scales it down.
--
-- Launched by the Swing_Kit_Bridge when the JSFX groove menu's "Import grooves..." row
-- bumps GRV_OPEN_REQ; also runnable directly from the Action list.

local r = reaper

if not r.ImGui_CreateContext then
  r.ShowMessageBox('EON Groove Browser requires ReaImGui (install via ReaPack).',
                   'EON Groove Browser', 0)
  return
end

r.gmem_attach('Swing_Media_Transfer')

local GRV_BASE  = 26140000            -- EON_SS_GROOVE_BASE (must match the JSFX)
local GRV_ALIVE = GRV_BASE + 201      -- our time_precise heartbeat (bridge won't double-launch)
local GRV_SLOT  = GRV_BASE + 202      -- JSFX-written: which StepSeq instance to target
local GRV_PUB_BASE, GRV_PUB_STRIDE = 26141000, 1200   -- JSFX-published raw user slots (read-only here)

-- ── scan Data/Grooves ────────────────────────────────────────────────────────
local sep = package.config:sub(1, 1)
local GROOVES_DIR = r.GetResourcePath() .. sep .. 'Data' .. sep .. 'Grooves'

local files = {}
do
  local i = 0
  while true do
    local fn = r.EnumerateFiles(GROOVES_DIR, i)
    if not fn then break end
    if fn:lower():match('%.rgt$') then files[#files + 1] = fn end
    i = i + 1
  end
  table.sort(files, function(a, b) return a:lower() < b:lower() end)
end

-- ── shared per-16th reduction ────────────────────────────────────────────────
-- hits = { {pos = beats, amp = 0..1 or nil}, ... }. Returns the staged template
-- { name=, n_steps=, offs={0..63 ticks}, amps={0..63 0..1}, has_vel= }.
local function reduce_hits(hits, beats, display_name)
  local n_steps = math.min(64, math.max(1, math.floor(beats * 4 + 0.5)))  -- per-16th grid, cap 64

  -- snap each hit to its nearest 16th; collect tick deltas + amplitudes per step
  local sum_t, cnt_t, sum_a, cnt_a = {}, {}, {}, {}
  for _, h in ipairs(hits) do
    local step_f  = h.pos * 4                       -- position in 16th steps
    local idx     = math.floor(step_f + 0.5)        -- nearest grid step
    local ticks   = (step_f - idx) * 128            -- delta in engine ticks (can be negative)
    local i2      = idx % n_steps                   -- wrap into the template
    sum_t[i2] = (sum_t[i2] or 0) + ticks
    cnt_t[i2] = (cnt_t[i2] or 0) + 1
    if h.amp and h.amp >= 0 then
      sum_a[i2] = (sum_a[i2] or 0) + h.amp
      cnt_a[i2] = (cnt_a[i2] or 0) + 1
    end
  end

  -- average per step, then normalize so the earliest hit sits ON the grid (delay-only
  -- engine); steps the template never touches take the baseline so relative feel holds.
  local minoff = 0
  local offs = {}
  for i = 0, n_steps - 1 do
    if cnt_t[i] then
      offs[i] = sum_t[i] / cnt_t[i]
      if offs[i] < minoff then minoff = offs[i] end
    end
  end
  local base = -minoff                              -- 0 when nothing plays early
  local out_offs, out_amps, has_vel = {}, {}, false
  for i = 0, 63 do
    local v = (i < n_steps) and ((offs[i] or 0) + base) or 0
    out_offs[i] = math.max(0, math.min(127, math.floor(v + 0.5)))
    if cnt_a[i] then
      out_amps[i] = math.max(0, math.min(1, sum_a[i] / cnt_a[i]))
      has_vel = true
    else
      out_amps[i] = 1
    end
  end

  return {
    name    = display_name:sub(1, 15),
    n_steps = n_steps,
    offs    = out_offs,
    amps    = out_amps,
    has_vel = has_vel,
  }
end

-- ── .rgt parse ───────────────────────────────────────────────────────────────
local function parse_rgt(path, display_name)
  local f = io.open(path, 'r')
  if not f then return nil, 'cannot open' end
  local txt = f:read('*a'); f:close()

  local beats = tonumber(txt:match('Number of beats in groove:%s*(%d+)'))
  if not beats or beats < 1 then return nil, 'no beat count' end

  -- hit lines: position [amplitude] -- numbers only after the "Groove:" header line.
  local body = txt:match('Groove:[^\n]*\n(.*)') or ''
  local hits = {}
  for line in body:gmatch('[^\r\n]+') do
    local pos, amp = line:match('^%s*([%d%.eE%-+]+)%s*([%d%.eE%-+]*)')
    local np = tonumber(pos)
    if np then hits[#hits + 1] = { pos = np, amp = tonumber(amp) } end
  end
  if #hits == 0 then return nil, 'no positions' end

  return reduce_hits(hits, beats, display_name)
end

-- ── .mid parse: extract the feel of any MIDI performance ────────────────────
-- DM pattern_import.lua technique: InsertMedia on a temp track (REAPER parses the
-- SMF -- no hand-rolled parser), read note starts in MUSICAL QN, delete the track.
-- Velocities become accent amps normalized so the loudest hit = 1.0.
local function parse_mid(path, display_name)
  if not r.InsertMedia then return nil, 'no InsertMedia API' end
  local cur = r.GetCursorPosition()
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local idx = r.CountTracks(0)
  r.InsertTrackAtIndex(idx, false)
  local temp = r.GetTrack(0, idx)
  local function cleanup()
    for i = r.CountTracks(0) - 1, idx, -1 do
      local tr = r.GetTrack(0, i)
      if tr then r.DeleteTrack(tr) end
    end
    r.SetEditCurPos(cur, false, false)
    r.PreventUIRefresh(-1)
    r.Undo_EndBlock('EON Groove Import: read MIDI feel', -1)
  end
  if not temp then cleanup(); return nil, 'temp track failed' end

  r.SetOnlyTrackSelected(temp)
  r.SetEditCurPos(0, false, false)
  r.InsertMedia(path, 0)

  -- InsertMedia may use `temp` or spin up its own track; scan ours for the MIDI take
  local item, take
  for ti = idx, r.CountTracks(0) - 1 do
    local tr = r.GetTrack(0, ti)
    for ii = 0, (tr and r.CountTrackMediaItems(tr) or 0) - 1 do
      local it = tr and r.GetTrackMediaItem(tr, ii)
      local tk = it and r.GetActiveTake(it)
      if tk and r.TakeIsMIDI(tk) then item, take = it, tk; break end
    end
    if take then break end
  end
  if not take then cleanup(); return nil, 'not a MIDI file' end

  local item_start    = r.GetMediaItemInfo_Value(item, 'D_POSITION')
  local item_len      = r.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local item_start_qn = r.TimeMap_timeToQN(item_start)
  local len_qn        = r.TimeMap_timeToQN(item_start + item_len) - item_start_qn

  local hits, maxvel = {}, 0
  local _, ncount = r.MIDI_CountEvts(take)
  for i = 0, ncount - 1 do
    local ok, _, _, ppq_s, _, _, _, vel = r.MIDI_GetNote(take, i)
    if ok then
      local pos = r.MIDI_GetProjQNFromPPQPos(take, ppq_s) - item_start_qn  -- QN == beats
      if pos < 0 then pos = 0 end
      hits[#hits + 1] = { pos = pos, vel = vel }
      if vel > maxvel then maxvel = vel end
    end
  end
  cleanup()
  if #hits == 0 then return nil, 'no notes' end

  for _, h in ipairs(hits) do
    h.amp = maxvel > 0 and (h.vel / maxvel) or nil    -- loudest hit = 1.0 (relative accents)
  end
  return reduce_hits(hits, math.max(1, len_qn), display_name)
end

-- ── staging into the gmem mailbox ────────────────────────────────────────────
-- Seed the seq from gmem so a fresh launch can't collide with a stale request.
local grvseq      = math.floor((r.gmem_read(GRV_BASE + 1) or 0) + 0.5)
local target_slot = math.max(0, math.min(15, math.floor((r.gmem_read(GRV_SLOT) or 0) + 0.5)))

local auto_assign = (r.GetExtState('EON_StepSeq', 'groove_autoassign') == '1')

local function stage(tpl, user_slot)                -- user_slot 1..7 -> mailbox 0..6
  r.gmem_write(GRV_BASE + 0, target_slot)
  r.gmem_write(GRV_BASE + 2, user_slot - 1)
  r.gmem_write(GRV_BASE + 3, tpl.n_steps)
  r.gmem_write(GRV_BASE + 4, auto_assign and 2 or 0)  -- bit1 = assign to MASTER on adopt (bit0=loaded is JSFX-side)
  for i = 0, 15 do
    local c = (i < #tpl.name) and tpl.name:byte(i + 1) or 0
    r.gmem_write(GRV_BASE + 5 + i, c)
  end
  for i = 0, 63 do
    r.gmem_write(GRV_BASE + 64 + i,  tpl.offs[i])
    r.gmem_write(GRV_BASE + 128 + i, tpl.amps[i])
  end
  grvseq = grvseq + 1
  r.gmem_write(GRV_BASE + 1, grvseq)                -- bump LAST -> the JSFX edge-detects
end

-- ── published-slot readback + .rgt export ───────────────────────────────────
-- The JSFX republishes its raw user slots (9..15 -> browser slots 1..7) on every
-- groove recompute, so this works for slots restored from a saved project too.
local function read_pub_slot(s)                     -- s = 1..7; nil when empty
  local b = GRV_PUB_BASE + target_slot * GRV_PUB_STRIDE + 1 + (s - 1) * 160
  local gr = r.gmem_read
  if (math.floor((gr(b + 145) or 0) + 0.5) & 1) == 0 then return nil end
  local name = {}
  for i = 0, 15 do
    local c = math.floor((gr(b + 128 + i) or 0) + 0.5)
    if c <= 0 or c > 255 then break end
    name[#name + 1] = string.char(c)
  end
  local n_steps = math.max(1, math.min(64, math.floor((gr(b + 144) or 16) + 0.5)))
  local offs, amps = {}, {}
  for i = 0, n_steps - 1 do
    offs[i] = math.max(0, math.min(127, gr(b + i) or 0))
    amps[i] = math.max(0, math.min(1, gr(b + 64 + i) or 1))
  end
  return { name = table.concat(name), n_steps = n_steps, offs = offs, amps = amps }
end

local function export_slot(s)                       -- writes Data/Grooves/<name>.rgt (v1)
  local tpl = read_pub_slot(s)
  if not tpl then return nil, 'slot ' .. s .. ' is empty (or the StepSeq needs a reload)' end
  local safe = tpl.name:gsub('[<>:"/\\|%?%*]', '_'):gsub('^%s+', ''):gsub('%s+$', '')
  if safe == '' then safe = 'EON groove ' .. s end
  local function exists(p)
    local f = io.open(p, 'r')
    if f then f:close(); return true end
    return false
  end
  local path = GROOVES_DIR .. sep .. safe .. '.rgt'
  local n = 1
  while exists(path) do                             -- never overwrite an existing groove
    n = n + 1
    path = GROOVES_DIR .. sep .. safe .. ' (EON ' .. n .. ').rgt'
  end
  local lines = {
    'Version: 1',
    'Number of beats in groove: ' .. math.ceil(tpl.n_steps / 4),
    'Groove: ' .. tpl.n_steps .. ' positions',
  }
  for i = 0, tpl.n_steps - 1 do
    lines[#lines + 1] = string.format('%.6f %.4f', (i + tpl.offs[i] / 128) / 4, tpl.amps[i])
  end
  local f = io.open(path, 'w')
  if not f then return nil, 'cannot write ' .. path end
  f:write(table.concat(lines, '\n') .. '\n'); f:close()
  return path:match('[^\\/]+$')
end

local function rescan_files()
  files = {}
  local i = 0
  while true do
    local fn = r.EnumerateFiles(GROOVES_DIR, i)
    if not fn then break end
    if fn:lower():match('%.rgt$') then files[#files + 1] = fn end
    i = i + 1
  end
  table.sort(files, function(a, b) return a:lower() < b:lower() end)
end

-- ── UI ───────────────────────────────────────────────────────────────────────
local ctx       = r.ImGui_CreateContext('EON Groove Import')
local filter    = ''
-- default destination = the user slot the JSFX suggested (clicking an "empty slot N" menu
-- row passes N-1 via GRV_BASE+203); 0/unset lands on slot 1.
local user_slot = math.max(1, math.min(7, math.floor((r.gmem_read(GRV_BASE + 203) or 0) + 0.5) + 1))
local last_msg  = ''
local slot_used = {}                                -- session memory of what we loaded where

local function frame()
  r.gmem_write(GRV_ALIVE, r.time_precise())
  r.ImGui_SetNextWindowSize(ctx, 400, 540, r.ImGui_Cond_FirstUseEver())
  local visible, open = r.ImGui_Begin(ctx, 'EON Groove Import', true)
  if visible then
    r.ImGui_Text(ctx, ('Data/Grooves: %d templates'):format(#files))
    r.ImGui_Separator(ctx)

    -- destination user-slot picker (1..7)
    r.ImGui_Text(ctx, 'Load into slot:')
    for s = 1, 7 do
      r.ImGui_SameLine(ctx)
      if r.ImGui_RadioButton(ctx, tostring(s) .. '##slot', user_slot == s) then user_slot = s end
    end
    -- live slot contents from the JSFX-published readback (works for project-restored
    -- slots too; falls back to session memory if the instance hasn't republished yet)
    local pub = read_pub_slot(user_slot)
    local slot_name = (pub and pub.name ~= '' and pub.name) or slot_used[user_slot]
    if slot_name then
      r.ImGui_TextColored(ctx, 0xE6B84FFF, 'slot ' .. user_slot .. ' = ' .. slot_name)
      r.ImGui_SameLine(ctx)
      if r.ImGui_SmallButton(ctx, 'Export -> .rgt') then
        local fname, err = export_slot(user_slot)
        if fname then
          last_msg = 'exported ' .. fname .. ' to Data/Grooves (permanent library)'
          rescan_files()
        else
          last_msg = 'EXPORT FAILED: ' .. (err or '?')
        end
      end
    else
      r.ImGui_TextColored(ctx, 0x8A8F98FF, 'slot ' .. user_slot .. ' = empty')
    end
    local achg, aval = r.ImGui_Checkbox(ctx, 'Assign to master after load', auto_assign)
    if achg then
      auto_assign = aval
      r.SetExtState('EON_StepSeq', 'groove_autoassign', aval and '1' or '0', true)
    end
    r.ImGui_SameLine(ctx)
    if r.ImGui_Button(ctx, 'Import MIDI file…') then
      local ok, fn = r.GetUserFileNameForRead('', 'Extract groove from MIDI file', '.mid')
      if ok and fn and fn ~= '' then
        local disp = (fn:match('[^\\/]+$') or fn):gsub('%.[Mm][Ii][Dd][Ii]?$', '')
        local tpl, err = parse_mid(fn, disp)
        if tpl then
          stage(tpl, user_slot)
          slot_used[user_slot] = tpl.name
          last_msg = ('loaded MIDI feel "%s" -> slot %d (%d steps%s)')
            :format(tpl.name, user_slot, tpl.n_steps, tpl.has_vel and ' +vel' or '')
          user_slot = (user_slot % 7) + 1
        else
          last_msg = 'FAILED ' .. disp .. ': ' .. (err or '?')
        end
      end
    end
    r.ImGui_Separator(ctx)

    r.ImGui_SetNextItemWidth(ctx, -1)
    local chg, txt = r.ImGui_InputTextWithHint(ctx, '##filter', 'search grooves…', filter)
    if chg then filter = txt end
    r.ImGui_Separator(ctx)

    if #files == 0 then
      r.ImGui_TextWrapped(ctx, 'No .rgt files in ' .. GROOVES_DIR .. '. Grooves come from the '
        .. 'SWS groove tool ("Get groove from selected item" saves one), or use Import MIDI file above.')
    end
    local lf = filter:lower()
    for _, fn in ipairs(files) do
      local disp = fn:gsub('%.rgt$', '')
      if lf == '' or disp:lower():find(lf, 1, true) then
        if r.ImGui_Selectable(ctx, disp .. '##' .. fn, false) then
          local tpl, err = parse_rgt(GROOVES_DIR .. sep .. fn, disp)
          if tpl then
            stage(tpl, user_slot)
            slot_used[user_slot] = tpl.name
            last_msg = ('loaded "%s" -> slot %d (%d steps%s)')
              :format(tpl.name, user_slot, tpl.n_steps, tpl.has_vel and ' +vel' or '')
            user_slot = (user_slot % 7) + 1         -- auto-advance for the next load
          else
            last_msg = 'FAILED ' .. disp .. ': ' .. (err or '?')
          end
        end
      end
    end

    r.ImGui_Separator(ctx)
    if last_msg ~= '' then r.ImGui_TextWrapped(ctx, last_msg) end
    r.ImGui_TextWrapped(ctx,
      'Click a groove to load it into the selected user slot. It appears in the StepSeq '
      .. 'groove menu (left column) and saves with the project. Strength 100 = verbatim.')
    r.ImGui_End(ctx)
  end
  if open then r.defer(frame) end
end

-- An empty Data/Grooves is fine -- the "Import MIDI file…" button still works;
-- the file list area just explains where .rgt grooves come from.
r.defer(frame)
