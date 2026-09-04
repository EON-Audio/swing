-- EON_FloatSize_Watch.lua
--
-- Opens each plugin's floating window at the right size. Toggle action: run
-- once to start, run again to stop. Self-registers as a startup action on
-- first run.
--
-- WHERE A SIZE COMES FROM, in order:
--   1. A size YOU captured with EON_FloatSize_Capture.lua. Applied every time
--      that plugin's float appears.
--   2. The size EON ships for the plugin (EON/eon_float_sizes.lua). Applied
--      to a FRESH window -- one still at its @gfx default. REAPER keeps a
--      float's size in the session and in the project, so a window that
--      comes back at a size somebody chose is left exactly as it is.
--   3. Nothing: a plugin with neither is never touched and opens at its own
--      @gfx default, as it would with this script absent.
--
-- WHY THIS EXISTS RATHER THAN AN @gfx EDIT:
-- `@gfx W H` sets the floating size AND fixes the TCP/MCP embed aspect ratio
-- at compile time. 29 of the 31 EON plugins have an embedded UI, so reshaping
-- the float in source reshapes the embed too (the 600x320 change reverted in
-- e3a7023). A JSFX cannot resize itself either -- gfx_w/gfx_h are read-only,
-- forum t=263900. The coupling is a known open limitation with no answer:
-- forum p=2866376, "JSFX: Custom aspect ratio for embedded TCP UI?".
--
-- HOW: sizes are CANVAS sizes and the canvas is a child window of the float;
-- the outer window is resized by the difference and the canvas lands exactly.
-- The model, the display-scale reasoning and the probes behind both are in
-- EON/eon_floatsize_lib.lua.
--
-- SCOPE: track FX, master included. Take FX and input/monitoring FX are not
-- scanned -- polling every item x take x FX every tick is too costly for a
-- background loop. Short addition if you need it.
--
-- Each window is sized ONCE, when it first appears. Resize it by hand
-- afterwards and this leaves it alone until you close and reopen it.

local r = reaper

local EXT_SECTION = "EON_FloatSize"
local POLL_SEC    = 0.25       -- how often to look for newly-opened windows

if not r.JS_Window_SetPosition then
  r.MB("This needs the js_ReaScriptAPI extension.\n\n" ..
       "Install it via ReaPack (Extensions > ReaPack > Browse packages > js_ReaScriptAPI).",
       "EON float size", 0)
  return
end

-- ── Toggle state ────────────────────────────────────────────────────────────
local _, self_path, sec_id, cmd_id = r.get_action_context()
local SCRIPT_DIR = self_path:match("^(.*)[/\\]")

local function set_toggle(on)
  r.SetToggleCommandState(sec_id, cmd_id, on and 1 or 0)
  r.RefreshToolbar2(sec_id, cmd_id)
end

-- Running already? Second launch = stop. The flag is transient (not persisted)
-- so a crash or REAPER restart cannot leave it stuck "on".
if r.GetExtState(EXT_SECTION, "running") == "1" then
  r.SetExtState(EXT_SECTION, "running", "0", false)
  return
end
r.SetExtState(EXT_SECTION, "running", "1", false)

local L = dofile(SCRIPT_DIR .. "/EON/eon_floatsize_lib.lua")

-- Rewrite __startup.lua via tmp-file + rename instead of truncating in place.
-- The file is SHARED -- other vendors' startup lines live in it too -- so a
-- crash or full disk mid-write must never be able to eat it. Returns true
-- only once the new content is fully on disk under `path`. Global on purpose:
-- same helper as the other EON self-registering scripts.
function eon_write_startup(path, content)
  local tmp = path .. ".eon-tmp"
  local f = io.open(tmp, "w")
  if not f then return false end
  local wok = f:write(content)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return false end
  os.remove(path)                    -- Windows os.rename won't overwrite
  return os.rename(tmp, path) and true or false
end

-- ── One-time migration off the 1175-only predecessor ────────────────────────
-- That script covered a single plugin and is superseded by this one. Left in
-- place it would keep its own startup block and fight this script over 1175's
-- window. Unregisters it, strips its startup block, and carries its captured
-- size over. Harmless and silent if it was never installed.
local function migrate_old()
  local old_name = "EON_1175_FloatSize_Watch"
  local key = old_name .. "_migrated_v1"
  if r.GetExtState(EXT_SECTION, key) == "1" then return end

  local dir, sep = self_path:match("^(.*)([/\\])[^/\\]*$")
  if dir then
    local old_path = dir .. sep .. old_name .. ".lua"
    r.AddRemoveReaScript(false, 0, old_path, true)   -- no-op if not registered
  end

  local startup_path = r.GetResourcePath() .. "/Scripts/__startup.lua"
  local fr = io.open(startup_path, "r")
  if fr then
    local content = fr:read("*a"); fr:close()
    local marker = "-- EON:" .. old_name
    if content:find(marker .. " BEGIN", 1, true) then
      local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
      content = content:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")
      eon_write_startup(startup_path, content)
    end
  end

  -- Best-effort carry-over of the old global size onto 1175's per-plugin key.
  -- "1175_ReaKit" is the key fx_ident yields; if this host falls back to the
  -- display name instead, the value simply goes unused and 1175 needs one
  -- re-capture. Never overwrites a size already captured with the new script.
  local ow = r.GetExtState("EON_1175_FloatSize", "w")
  local oh = r.GetExtState("EON_1175_FloatSize", "h")
  if ow ~= "" and oh ~= "" and r.GetExtState(EXT_SECTION, "1175_ReaKit_w") == "" then
    r.SetExtState(EXT_SECTION, "1175_ReaKit_w", ow, true)
    r.SetExtState(EXT_SECTION, "1175_ReaKit_h", oh, true)
  end

  r.SetExtState(EXT_SECTION, key, "1", true)
end
migrate_old()

-- ── Self-register as a startup action (one-time, on first manual run) ───────
-- Same self-cleaning block the Kit Bridge and Strip Sync write into
-- Scripts/__startup.lua; REAPER runs that natively at launch, no SWS.
-- If NamedCommandLookup ever stops resolving, the block strips ITSELF out and
-- clears the flag, so a reinstall registers cleanly.
--
-- Only the START path reaches here: a second launch to toggle OFF returns
-- above and never touches registration.
local SCRIPT_NAME = "EON_FloatSize_Watch"
local function self_register()
  local key = SCRIPT_NAME .. "_registered_v1"
  local marker = "-- EON:" .. SCRIPT_NAME
  local startup_path = r.GetResourcePath() .. "/Scripts/__startup.lua"

  -- Flagged as registered? Trust it only if the block is really still there.
  if r.GetExtState(SCRIPT_NAME, key) == "1" then
    local fr = io.open(startup_path, "r")
    if fr then
      local content = fr:read("*a"); fr:close()
      if content:find(marker .. " BEGIN", 1, true) then return end
    end
    r.SetExtState(SCRIPT_NAME, key, "", true)
  end

  -- reg_cmd_id, not cmd_id: the outer cmd_id from get_action_context() is what
  -- set_toggle() closes over, and shadowing it here invites a bad edit.
  local reg_cmd_id = r.AddRemoveReaScript(true, 0, self_path, true)
  if not reg_cmd_id or reg_cmd_id <= 0 then return end

  local existing = ""
  local fr = io.open(startup_path, "r")
  if fr then existing = fr:read("*a"); fr:close() end

  local esc = marker:gsub("([%-%.%+%*%?%[%]%^%$%(%)%%])", "%%%1")
  existing = existing:gsub("\n?" .. esc .. " BEGIN.-" .. esc .. " END\n?", "")

  local named_id = r.ReverseNamedCommandLookup(reg_cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(reg_cmd_id)

  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then reaper.Main_OnCommand(id,0) else\n" ..
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); if f then local c=f:read('*a'); f:close()\n" ..
    "    c=c:gsub('\\n?%-%- EON:" .. SCRIPT_NAME .. " BEGIN.-%-%- EON:" .. SCRIPT_NAME .. " END\\n?','')\n" ..
    "    local fw=io.open(p,'w'); if fw then fw:write(c); fw:close() end end\n" ..
    "  reaper.SetExtState('" .. SCRIPT_NAME .. "','" .. key .. "','',true)\n" ..
    "end end\n" ..
    marker .. " END\n"

  -- Flag as registered only once the block is really on disk; a failed write
  -- leaves the ExtState clear so the next run simply retries.
  if eon_write_startup(startup_path, existing .. block) then
    r.SetExtState(SCRIPT_NAME, key, "1", true)
    r.ShowConsoleMsg("[EON float size] registered as startup action (auto-starts with REAPER).\n")
  end
end
self_register()

set_toggle(true)

r.atexit(function()
  r.SetExtState(EXT_SECTION, "running", "0", false)
  set_toggle(false)
end)

-- ── The shipped sizes ───────────────────────────────────────────────────────
-- Read once at start. Logical px at 100%; see the lib for how the display
-- scale is found. An install without the file sizes only what the user
-- captured.
local SHIPPED = L.load_table(SCRIPT_DIR)

-- ── Seen-window bookkeeping ─────────────────────────────────────────────────
-- Keyed by numeric HWND address, not the userdata handle: handle identity is
-- not guaranteed stable across calls, addresses are.
local sized   = {}      -- addr -> true once this window has had its one attempt
local pending = {}      -- addr -> tries while the canvas child is not there yet

local function addr(hwnd)
  return r.JS_Window_AddressFromHandle and r.JS_Window_AddressFromHandle(hwnd) or tostring(hwnd)
end

-- One window, first sight. Returns true when the window is settled (sized,
-- or found to be none of ours) and false when it should be looked at again.
local function first_sight(e)
  local canvas = L.find_canvas(e.hwnd)
  if not canvas then return false end             -- not a JSFX, or not built yet

  local key = L.fx_key(e.tr, e.fx)

  -- 1. The user's own capture: this machine's px, applied as-is. A capture
  --    from the pair as it was before 2026-09-04 is an OUTER size; it is
  --    converted here, against this very window, and applied the same.
  local w, h = L.get_capture(key)
  if not w then
    w, h = L.convert_legacy(e.hwnd, canvas, key)
    if w then
      r.ShowConsoleMsg(("[EON float size] %s: capture converted to canvas size %dx%d.\n"):format(key, w, h))
    end
  end
  if w and h then
    L.note_ident(key, L.fx_ident(e.tr, e.fx))
    L.set_canvas(e.hwnd, canvas, w, h)
    return true
  end

  -- 2. The shipped size, on a fresh window only.
  local ship = SHIPPED[key]
  if not ship or not ship.w or not ship.h then return true end
  local c = L.rect(canvas)
  local s = L.fresh_scale(e.hwnd, c, ship.gfx_w, ship.gfx_h)
  if not s then return true end                   -- somebody's size already; keep it
  r.SetExtState(EXT_SECTION, "scale", tostring(s), true)   -- for the export
  L.set_canvas(e.hwnd, canvas, ship.w * s, ship.h * s)
  return true
end

-- ── Poll ────────────────────────────────────────────────────────────────────
local next_poll = 0

local function collect(tr, out)
  if not tr then return end
  for fx = 0, r.TrackFX_GetCount(tr) - 1 do
    -- Cheap check first: only open windows are worth identifying.
    local hwnd = r.TrackFX_GetFloatingWindow(tr, fx)
    if hwnd then out[#out + 1] = { tr = tr, fx = fx, hwnd = hwnd } end
  end
end

local function tick()
  if r.GetExtState(EXT_SECTION, "running") ~= "1" then
    set_toggle(false)
    return                                  -- stopped by a second launch
  end

  local now = r.time_precise()
  if now >= next_poll then
    next_poll = now + POLL_SEC

    local open = {}
    collect(r.GetMasterTrack(0), open)
    for i = 0, r.CountTracks(0) - 1 do
      collect(r.GetTrack(0, i), open)
    end

    local live = {}
    for _, e in ipairs(open) do
      local a = addr(e.hwnd)
      live[a] = true
      if not sized[a] then
        if first_sight(e) then
          sized[a] = true
          pending[a] = nil
        else
          -- No canvas child yet. A JSFX gets more looks in case REAPER is
          -- still building the window; a VST never grows one and is let go.
          -- 20 polls at 0.25 s = 5 s, generous for a heavy @init (big sample
          -- banks, FFT plans) and cheap for VSTs (one array scan per poll).
          pending[a] = (pending[a] or 0) + 1
          if pending[a] >= 20 then sized[a] = true; pending[a] = nil end
        end
      end
    end

    -- Drop closed windows so reopening one sizes it again.
    for a in pairs(sized) do
      if not live[a] then sized[a] = nil end
    end
    for a in pairs(pending) do
      if not live[a] then pending[a] = nil end
    end
  end

  r.defer(tick)
end

tick()
