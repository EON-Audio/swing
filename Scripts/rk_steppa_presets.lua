-- rk_steppa_presets.lua -- Steppa's preset bank, its apply path and its two browser launchers: ONE master.
--
-- Moved here from Swing_Kit_Bridge.lua on 2026-11-10 (Steppa-first plan, decision D3) so that two hosts run the SAME
-- code: Swing's Kit Bridge, and EON_Steppa_Helper.lua (Steppa installed without Swing). The logic is the bridge's,
-- line for line; .dev_tests/steppa_presets_same.py holds it to the bridge's last own copy (every gmem write equal).
--
--   local sp = dofile(dir .. "/rk_steppa_presets.lua").new{
--     script_dir    = dir,                 -- the folder this file and the two browser scripts live in
--     padcat_index  = function(name) ... end or nil,   -- Swing's glyph id for a category name (nil: no Swing)
--     padcat_base   = 26003000 or nil,     -- Swing's published pad-category band (nil: no Swing -> canonical rows)
--     padcat_stride = 64,
--     on_flat       = function(flat) ... end or nil,   -- called ONCE with the flat list (Swing publishes its own list)
--   }
--   sp.nav_tick(); sp.browser_launch_tick(); sp.groove_launch_tick()    -- once per host tick
--   sp.reset()    -- forget every baseline: the next tick re-reads the request counters and applies nothing stale
--
-- The protocol (unchanged; the cells are the bridge's, documented in .refs/swing_gmem_bridge_protocol.md):
--   APPLY band 26044000 (+8 data, +264 ratchet list, +990 hat mask), PCTRL band 26045000 + slot*64
--   ([0] nav seq, [1] nav dir, [2] idx out, [3] count out, [5] select seq, [6] select idx, [16..] name out),
--   preset browser 26046100 open req / 26046101 alive / 26046103 close req, groove browser 26140200 / 26140201.
-- The host must have attached the gmem segment "Swing_Media_Transfer" before the first tick.
local M = {}

-- The cells, by name (this file is their one Lua home; Steppa's names in EON_StepSeq.jsfx are in the comments).
local APPLY_BASE       = 26044000   -- EON_SS_APPLY_BASE: [0] slot, [1] seq (bumped LAST), [2] rows, [3] steps, [4] spb, [5] list stamp
local APPLY_SEQ        = APPLY_BASE + 1
local PCTRL_BASE       = 26045000   -- EON_SS_PCTRL_BASE (+ slot * 64)
local BROWSER_OPEN_REQ = 26046100   -- EON_SS_BROWSER_OPEN_REQ
local BROWSER_ALIVE    = 26046101   -- the preset browser's time_precise heartbeat
local BROWSER_CLOSE    = 26046103   -- bumped: the preset browser quits
local GRV_OPEN_REQ     = 26140200   -- EON_SS_GRV_OPEN_REQ
local GRV_ALIVE        = 26140201   -- the groove browser's heartbeat
local REDOCK_REQ       = 2631       -- EON_REDOCK_REQ (GS_REDOCK_REQ_STEPPA): Steppa's wordmark asks for the dock; consume-to-0
local HELPER_ALIVE     = 2637       -- EON_SH_ALIVE (GS_STEPPA_HELPER_ALIVE): EON_Steppa_Helper's time_precise heartbeat while it
                                    -- SERVES (the owner's yes, 2026-11-10: "yes i do want the dock button"); 0 = not serving

-- Preset row names -> the 46-glyph vocabulary ids Swing's pad-category band stores (aliases per gen_presets.py).
M.CAT_ALIAS = {
  ["808"] = "bass", sub = "bass", ohat = "open_hat", chat = "closed_hat",
  hat = "closed_hat",                 -- 2026-07-27 user rule: generic hat = closed
  bell = "cowbell", cymbal2 = "crash", cymbal = "ride",
  shaker = "shaker", maracas = "maraca", perc = "percussion",
  rim = "rimshot",
  -- the toms (the audit's factory rig, 2026-10-22): the presets' tom = low, tom1 = mid, tom2 = high
  -- (PatternLibrary/gen/content.py); every shipped kit names them TOM LO = floor_tom, TOM MID = tom, TOM HI = rack_tom.
  tom = "floor_tom", tom_lo = "floor_tom", tom1 = "tom", tom_mid = "tom", tom2 = "rack_tom", tom_hi = "rack_tom",
}
-- Second choices: the same drum under another name. A list is tried in order. (Cymbal family: a ride / crash row on a
-- generic CYMBAL pad beats the fixed-row fallback, the user's call 2026-08-04.)
M.CAT_FALLBACK = {
  ride = "cymbal", cymbal = "cymbal", crash = "cymbal", cymbal2 = "cymbal",
  maracas = { "shaker", "cabasa" }, shaker = { "maraca", "cabasa" },
  tom = { "tom", "rack_tom" }, tom_lo = { "tom", "rack_tom" },
  tom1 = { "rack_tom", "floor_tom" }, tom_mid = { "rack_tom", "floor_tom" },
  tom2 = { "tom", "floor_tom" }, tom_hi = { "tom", "floor_tom" },
  conga = { "bongo", "djembe", "timbale" }, clave = "woodblock", rim = "sidestick", clap = "snap",
  cowbell = "agogo", bell = "agogo",
  closed_hat = "hihat", chat = "hihat", hat = "hihat", open_hat = "hihat", ohat = "hihat",
}
-- The role vocabulary (the browser script's: PatternLibrary/FORMAT.md) as ids; an old cache without the role field
-- gets it from the label.
M.ROLE_ID = { main = 0, fill = 1, build = 2, ["break"] = 3, perc = 4 }
M.ROLE_FROM_LABEL = { ["Main A"] = "main", ["Main B"] = "main", ["Fill"] = "fill", ["Rolls"] = "build",
                      ["Breakdown"] = "break", ["Stripped"] = "break", ["Open Hats"] = "perc", ["Percussion"] = "perc" }

function M.new(ctx)
  local S = {}
  local base = tostring(ctx.script_dir or ""):gsub("[/\\]+", "/"):gsub("/+$", "")
  local b2 = base:gsub("/%.Scripts$", "/Scripts")
  local bases = (b2 ~= base) and { base, b2 } or { base }
  local PADCAT_BASE, PADCAT_STRIDE = ctx.padcat_base, ctx.padcat_stride or 64

  -- First base where the file exists (else the de-dotted path): the dev tree's .Scripts and an install's Scripts.
  local function find(rel)
    for i = 1, #bases do
      local p = bases[i] .. "/" .. rel
      local fh = io.open(p, "r")
      if fh then fh:close(); return p end
    end
    return bases[#bases] .. "/" .. rel
  end

  local flat_cache, catrow_cache            -- nil = not loaded yet, false = the cache or the json reader is missing
  local apply_seq = 0
  local pnav_last, psel_last, pidx = {}, {}, {}
  local flat_told = false
  local browser_req_last, browser_launch_t, grv_req_last
  local dock_baselined

  -- Load preset_cache.json ONCE and flatten to [{name, rows, ...}] over every (preset, variation) pair. Returns the
  -- flat list + the category_row map; nil if the cache or the json reader is missing (the strip just stays inert).
  function S.flat()
    if flat_cache ~= nil then return flat_cache or nil, catrow_cache end
    local okj, json = pcall(dofile, find("EON/Drum Matrix/lib/json.lua"))
    if not okj or not json or not json.decode then flat_cache = false; return nil end
    local f = io.open(find("EON/PatternLibrary/preset_cache.json"), "r")
    if not f then flat_cache = false; return nil end
    local txt = f:read("*a"); f:close()
    local okd, data = pcall(json.decode, txt)
    if not okd or type(data) ~= "table" or not data.presets then flat_cache = false; return nil end
    local flat = {}
    local flat_p = {}   -- one entry per preset (its ordinal: pidx)
    for _, p in ipairs(data.presets) do
      flat_p[#flat_p + 1] = p
      -- Every preset is listed, the non-16-step (triplet-grid) ones too: the flat list MUST stay index-aligned with
      -- the preset browser, which builds its own list from the same cache and sends ABSOLUTE indices. The grid
      -- geometry rides along per entry; Steppa adopts it on consume.
      for _, v in ipairs(p.variations or {}) do
        flat[#flat + 1] = { name = (p.name or "?") .. " - " .. (v.label or "?"), rows = v.rows or {},
                            ns = p.steps_per_bar or 16, spb = p.steps_per_beat or 4,
                            sw = p.swing or 0, hsw = p.hat_swing or 0,
                            genre = p.genre or "?", pidx = #flat_p,
                            feel = (((p.steps_per_beat or 4) % 3) == 0) and 2 or (((p.swing or 0) > 0 or (p.hat_swing or 0) > 0) and 1 or 0),
                            role = M.ROLE_ID[v.role or M.ROLE_FROM_LABEL[v.label or ""] or "main"] or 0 }
      end
    end
    flat_cache   = flat
    catrow_cache = data.category_row or {}
    return flat, catrow_cache
  end

  -- Resolve a preset row category to the LANE that plays that sound on THIS rack: the pad whose PUBLISHED category
  -- matches (lowest unclaimed pad wins); a row with no free pad of its drum is skipped on a kit with published
  -- categories (the user, 2026-10-22); a rack with no categories at all -- and Steppa without Swing -- keeps the
  -- canonical layout baked into preset_cache.json.
  function S.lane_for_cat(cat, slot, taken, catrow)
    local fallback = catrow[cat]
    local gr = reaper.gmem_read
    local names = { M.CAT_ALIAS[cat] or cat }
    local fb = M.CAT_FALLBACK[cat]
    if type(fb) == "table" then for i = 1, #fb do names[#names + 1] = fb[i] end elseif fb then names[2] = fb end
    for n = 1, #names do
      local id = ctx.padcat_index and ctx.padcat_index(names[n]) or -1
      if id and id >= 0 and PADCAT_BASE then
        for pad = 0, 15 do
          local b = PADCAT_BASE + slot * PADCAT_STRIDE + pad * 4
          if (gr(b) or 0) > 0 and math.floor((gr(b + 1) or -1) + 0.5) == id
             and not taken[pad] then
            taken[pad] = true
            return pad
          end
        end
      end
    end
    if PADCAT_BASE then
      for pad = 0, 15 do
        local b = PADCAT_BASE + slot * PADCAT_STRIDE + pad * 4
        if (gr(b) or 0) > 0 and math.floor((gr(b + 1) or -1) + 0.5) >= 0 then return nil end
      end
    end
    return fallback
  end

  -- Stage one flat entry's grid into the APPLY band (ROW-keyed), then bump applyreq so the targeted instance consumes
  -- it. Ratchet cells are staged TWICE: the max velocity into the plane, plus a sparse list after it
  -- ([count, then per ratchet: cell (row*NS+s), K, v0..v7]). Header [5] carries the same seq as [1]; Steppa parses
  -- the list only when [5] == [1]. Fits the band: 1 + 72*10 = 721 <= 736 free.
  function S.stage_apply(slot, entry, catrow)
    local gw = reaper.gmem_write
    local AB, AD = APPLY_BASE, APPLY_BASE + 8
    local SD = AD + 16 * 16                               -- 26044264: sparse ratchet list
    local AH = AB + 990                                   -- 26044990: the hat rows' bit mask (Swing's sequencer)
    local ns  = entry.ns or 16
    local spb = entry.spb or 4
    -- Never reuse the number an earlier host left in the cell: Steppa consumes on a CHANGE of [1], so a fresh host
    -- (the bridge started after the helper applied one preset, or a restarted bridge) whose own count came round to
    -- that same number would be ignored -- the name changed, the grid did not (self audit, 2026-11-10).
    local seq = math.max(apply_seq, math.floor((reaper.gmem_read(APPLY_SEQ) or 0) + 0.5)) + 1
    for i = 0, 16 * 16 - 1 do gw(AD + i, 0) end          -- zero the full vel plane
    local rats = {}
    local taken = {}
    local hatrows = {}
    -- Deterministic row order (pairs() order is arbitrary): the band scan claims pads identically on every apply.
    local cats = {}
    for cat in pairs(entry.rows) do cats[#cats + 1] = cat end
    table.sort(cats)
    for _, cat in ipairs(cats) do
      local steps = entry.rows[cat]
      local row = S.lane_for_cat(cat, slot, taken, catrow)
      if row and type(steps) == "table" then
        local alias = M.CAT_ALIAS[cat] or cat
        if alias == "open_hat" or alias == "closed_hat" then hatrows[row] = true end
        for s = 0, ns - 1 do
          local v = steps[s + 1]
          if type(v) == "table" then                      -- ratchet: flatten for the plane...
            local m = 0; for _, x in ipairs(v) do if (x or 0) > m then m = x end end
            if m > 0 and #v > 1 and #rats < 72 then       -- ...and record for the subdiv list
              rats[#rats + 1] = { cell = row * ns + s, vels = v }
            end
            v = m
          end
          v = math.floor(tonumber(v) or 0)
          if v > 0 then gw(AD + row * ns + s, v) end      -- plane addressed by ns (matches Steppa's r*buf_ns+s)
        end
      end
    end
    gw(SD, #rats)
    for i, rc in ipairs(rats) do
      local p = SD + 1 + (i - 1) * 10
      local K = math.min(#rc.vels, 8)
      gw(p, rc.cell); gw(p + 1, K)
      for k = 1, 8 do gw(p + 1 + k, math.floor(tonumber(rc.vels[k]) or 0)) end
    end
    -- The feel in header cells 6 / 7 and the hat rows as a bit mask, all inside the band's reserved span; Steppa
    -- reads none of them.
    gw(AB + 6, math.floor(tonumber(entry.sw) or 0)); gw(AB + 7, math.floor(tonumber(entry.hsw) or 0))
    local hatmask = 0
    for row16 = 0, 15 do if hatrows[row16] then hatmask = hatmask + 2 ^ row16 end end
    gw(AH, hatmask)
    gw(AB + 0, slot); gw(AB + 2, 16); gw(AB + 3, ns); gw(AB + 4, spb)
    gw(AB + 5, seq)                                       -- subdiv-list-valid stamp
    apply_seq = seq
    gw(AB + 1, seq)                                       -- bump LAST (after the grid is in place)
  end

  -- Write an ASCII name into a gmem char band (null-terminated).
  function S.write_name(nbase, name, maxc)
    local gw = reaper.gmem_write
    local n = math.min(#name, maxc)
    for i = 0, n - 1 do gw(nbase + i, string.byte(name, i + 1)) end
    gw(nbase + n, 0)
  end

  -- Per tick: scan each slot's PCTRL mailbox; on a new NAV request step that slot's flat index by NAV_DIR, on a new
  -- SELECT jump to its index; stage the grid and publish idx / count / name back for Steppa's strip.
  function S.nav_tick()
    local flat, catrow = S.flat()
    if not flat or #flat == 0 then return end
    if not flat_told then flat_told = true; if ctx.on_flat then pcall(ctx.on_flat, flat) end end
    local gr, gw = reaper.gmem_read, reaper.gmem_write
    local PB, PS = PCTRL_BASE, 64                           -- EON_SS_PCTRL_BASE / STRIDE
    local function apply_idx(slot, nb, idx)
      idx = idx % #flat
      pidx[slot] = idx
      S.stage_apply(slot, flat[idx + 1], catrow)
      gw(nb + 2, idx); gw(nb + 3, #flat)
      S.write_name(nb + 16, flat[idx + 1].name, 31)
    end
    for slot = 0, 15 do
      local nb = PB + slot * PS
      -- A fresh host (restarted inside one REAPER session, the cells still holding the last requests) baselines them
      -- and never applies them: the pattern on screen is the user's by now (the audit's factory rig, 2026-10-22).
      -- The index the last host published carries on.
      if pnav_last[slot] == nil then
        pnav_last[slot] = math.floor((gr(nb + 0) or 0) + 0.5)
        psel_last[slot] = math.floor((gr(nb + 5) or 0) + 0.5)
        if pnav_last[slot] > 0 or psel_last[slot] > 0 then pidx[slot] = math.floor((gr(nb + 2) or 0) + 0.5) end
      end
      -- Relative nav from the in-window strip (wheel / arrows): step by NAV_DIR.
      local navseq = math.floor((gr(nb + 0) or 0) + 0.5)
      if navseq ~= (pnav_last[slot] or 0) then
        pnav_last[slot] = navseq
        if navseq > 0 then                                 -- 0 = never navigated (open blank)
          local dir = (gr(nb + 1) or 0) >= 0 and 1 or -1
          apply_idx(slot, nb, (pidx[slot] or 0) + dir)
        end
      end
      -- Absolute select from the preset browser: jump straight to SELECT_IDX.
      local selseq = math.floor((gr(nb + 5) or 0) + 0.5)
      if selseq ~= (psel_last[slot] or 0) then
        psel_last[slot] = selseq
        if selseq > 0 then
          apply_idx(slot, nb, math.floor((gr(nb + 6) or 0) + 0.5))
        end
      end
    end
  end

  -- Steppa's Preset strip (right-click, or a click on the name) bumps BROWSER_OPEN_REQ; a JSFX cannot launch a
  -- ReaScript, so the host registers + runs the browser. ALIVE is a time_precise heartbeat the browser writes each
  -- frame: a bump while one is alive is a TOGGLE (CLOSE_REQ 26046103, the browser quits on it).
  -- ⚠️ The launched script is deliberately left REGISTERED: AddRemoveReaScript(false, path) removes the action for
  -- that PATH no matter who registered it, which strips the user's own shortcuts and toolbar buttons (2026-08-26).
  function S.browser_launch_tick()
    local gr = reaper.gmem_read
    local req = math.floor((gr(BROWSER_OPEN_REQ) or 0) + 0.5)        -- EON_SS_BROWSER_OPEN_REQ
    if browser_req_last == nil then browser_req_last = req; return end  -- baseline; ignore stale
    if req == browser_req_last then return end
    browser_req_last = req
    if req <= 0 then return end
    local now = reaper.time_precise()
    if (now - (gr(BROWSER_ALIVE) or 0)) < 0.6 then                -- alive -> this bump means CLOSE
      reaper.gmem_write(BROWSER_CLOSE, math.floor((gr(BROWSER_CLOSE) or 0) + 0.5) + 1)
      return
    end
    -- Launch-in-flight guard: the browser needs a frame or two before its ALIVE heartbeat starts, so a fast second
    -- bump would double-launch without this.
    if browser_launch_t and (now - browser_launch_t) < 1.5 then return end
    local browser_path = base .. "/EON_StepSeq_Preset_Browser.lua"
    local f = io.open(browser_path, "r")
    if not f then return end
    f:close()
    local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
    if cmd_id and cmd_id > 0 then
      reaper.Main_OnCommand(cmd_id, 0)
      browser_launch_t = now
    end
  end

  -- Steppa's groove menu ("Import grooves...", or an empty user slot) bumps GRV_OPEN_REQ (26140200); launch the
  -- groove browser the same way. ALIVE (26140201) is its heartbeat -> skip if one is already up.
  function S.groove_launch_tick()
    local gr = reaper.gmem_read
    local req = math.floor((gr(GRV_OPEN_REQ) or 0) + 0.5)        -- EON_SS_GRV_OPEN_REQ
    if grv_req_last == nil then grv_req_last = req; return end
    if req == grv_req_last then return end
    grv_req_last = req
    if req <= 0 then return end
    if (reaper.time_precise() - (gr(GRV_ALIVE) or 0)) < 0.6 then return end      -- already open
    local browser_path = base .. "/EON_StepSeq_Groove_Browser.lua"
    local f = io.open(browser_path, "r")
    if not f then return end
    f:close()
    local cmd_id = reaper.AddRemoveReaScript(true, 0, browser_path, true)
    if cmd_id and cmd_id > 0 then
      reaper.Main_OnCommand(cmd_id, 0)
    end
  end

  -- Steppa's wordmark ("dock me", and the re-dock hello of a reopened window) bumps REDOCK_REQ. Start the dock pane
  -- script unless its own heartbeat (ExtState EON_SteppaDock/alive, stamped every pane tick) says one is running: a
  -- second one would fight the first over the same window. ONE master for both hosts: the bridge calls this from its
  -- eon_redock_tick after it has pointed the selection at a paired Swing's track; the helper calls dock_tick below.
  function S.dock_launch()
    local hb = tonumber(reaper.GetExtState("EON_SteppaDock", "alive")) or 0
    if (reaper.time_precise() - hb) < 2 then return end
    local path = base .. "/EON_Steppa_Dock.lua"
    local f = io.open(path, "r")
    if not f then
      reaper.ShowConsoleMsg("[EON] EON_Steppa_Dock.lua not found (" .. path .. ")\n"
        .. "  The wordmark dock toggle needs it. Reinstall Steppa (or Swing).\n")
      return
    end
    f:close()
    local cmd_id = reaper.AddRemoveReaScript(true, 0, path, true)
    if cmd_id and cmd_id > 0 then reaper.Main_OnCommand(cmd_id, 0) end   -- left registered (see browser_launch_tick)
  end

  -- The no-Swing host's dock relay (the bridge has its own, for Swing's pane too). First sighting: clear without
  -- acting, so a click posted while nobody served cannot fire later. Unpaired there is no track to select: the pane
  -- follows the selected track, as it does under the bridge for an unpaired Steppa.
  function S.dock_tick()
    if not dock_baselined then dock_baselined = true; reaper.gmem_write(REDOCK_REQ, 0); return end
    if math.floor((reaper.gmem_read(REDOCK_REQ) or 0) + 0.5) <= 0 then return end
    reaper.gmem_write(REDOCK_REQ, 0)
    S.dock_launch()
  end

  -- The no-Swing host says "I am serving" (on = true, every tick) or "I stopped" (false). Steppa offers the dock
  -- click only while the bridge's heartbeat or this stamp is fresh.
  function S.stamp_alive(on)
    reaper.gmem_write(HELPER_ALIVE, on and reaper.time_precise() or 0)
  end

  -- Forget every baseline (a host that stood aside for another host and takes over again): the next tick re-reads
  -- the request counters and applies nothing that was asked while it was away.
  function S.reset()
    pnav_last, psel_last, pidx = {}, {}, {}
    browser_req_last, browser_launch_t, grv_req_last = nil, nil, nil
    dock_baselined = nil
    apply_seq = math.floor((reaper.gmem_read(APPLY_SEQ) or 0) + 0.5)
  end

  return S
end

return M
