-- EON_FloatSize_Capture.lua
--
-- Remember the size of ONE plugin's floating window, per plugin.
--
-- Open a plugin floating, drag it to the shape you want, run this. From then
-- on EON_FloatSize_Watch.lua opens THAT plugin at THAT size, ahead of the size
-- EON ships for it. Repeat for each plugin you care about; anything you never
-- capture keeps opening at its shipped size, or at its own @gfx default if
-- EON ships none.
--
-- WHY THIS EXISTS:
-- `@gfx W H` sets a JSFX's floating-window size AND fixes its TCP/MCP embed
-- aspect ratio at compile time -- one pair of numbers doing two jobs. 29 of
-- the 31 EON plugins have an embedded UI, so reshaping the floating window in
-- source would reshape the embed with it. A JSFX also cannot resize itself:
-- gfx_w/gfx_h are read-only (forum t=263900). This is a known, open limitation
-- -- see forum p=2866376, "JSFX: Custom aspect ratio for embedded TCP UI?",
-- which confirms the coupling and has no answer. Sizing the window from
-- ReaScript after REAPER opens it is the way to have both.
--
-- WHAT IT STORES:
-- The CANVAS size -- the plugin's gfx area, measured from its own child
-- window -- not the outer window. The outer window is canvas plus REAPER's
-- title bar and toolbar, which change with theme, OS and DPI; the canvas is
-- what you actually shaped. See EON/eon_floatsize_lib.lua for the model.

local r = reaper

if not r.JS_Window_GetRect then
  r.MB("This needs the js_ReaScriptAPI extension.\n\n" ..
       "Install it via ReaPack (Extensions > ReaPack > Browse packages > js_ReaScriptAPI).",
       "EON float size", 0)
  return
end

local dir = ({r.get_action_context()})[2]:match("^(.*)[/\\]")
local L = dofile(dir .. "/EON/eon_floatsize_lib.lua")

-- ── Find the plugin to capture ──────────────────────────────────────────────
-- Prefer whatever REAPER says is focused. If that does not resolve to a track
-- FX with an open floating window, fall back to "the only one open".
local function from_focus()
  if not r.GetFocusedFX then return nil end
  local retval, tracknumber, _, fxnumber = r.GetFocusedFX()
  if retval ~= 1 then return nil end                  -- 1 = track FX
  if fxnumber >= 0x1000000 then return nil end        -- input/monitoring chain
  local tr = (tracknumber == 0) and r.GetMasterTrack(0) or r.GetTrack(0, tracknumber - 1)
  if not tr then return nil end
  local hwnd = r.TrackFX_GetFloatingWindow(tr, fxnumber)
  if not hwnd then return nil end
  return tr, fxnumber, hwnd
end

local function all_floating()
  local found = {}
  local function scan(tr)
    if not tr then return end
    for fx = 0, r.TrackFX_GetCount(tr) - 1 do
      local hwnd = r.TrackFX_GetFloatingWindow(tr, fx)
      if hwnd then found[#found + 1] = { tr = tr, fx = fx, hwnd = hwnd } end
    end
  end
  scan(r.GetMasterTrack(0))
  for i = 0, r.CountTracks(0) - 1 do scan(r.GetTrack(0, i)) end
  return found
end

local tr, fx, hwnd = from_focus()

if not hwnd then
  local open = all_floating()
  if #open == 0 then
    r.MB("No floating plugin window found.\n\n" ..
         "Open a plugin in a floating window, drag it to the size you want, " ..
         "then run this again.", "EON float size", 0)
    return
  elseif #open > 1 then
    r.MB(("%d floating plugin windows are open and REAPER did not report which " ..
          "is focused.\n\nClick the one you want to capture (or close the others) " ..
          "and run this again."):format(#open), "EON float size", 0)
    return
  end
  tr, fx, hwnd = open[1].tr, open[1].fx, open[1].hwnd
end

-- ── Measure and store ───────────────────────────────────────────────────────
local _, nm = r.TrackFX_GetFXName(tr, fx, "")

local canvas = L.find_canvas(hwnd)
if not canvas then
  r.MB(("%s has no JSFX canvas to measure -- this only sizes JSFX plugins " ..
        "with a graphics area.\n\nNothing was saved."):format(nm or "That plugin"),
       "EON float size", 0)
  return
end

local c = L.rect(canvas)
if not c then
  r.MB("Could not read that window's canvas.", "EON float size", 0)
  return
end

if c.w < 40 or c.h < 40 then
  r.MB(("That canvas measured %dx%d, which looks wrong.\n\nNothing was saved.")
       :format(c.w, c.h), "EON float size", 0)
  return
end

local key = L.fx_key(tr, fx)
L.set_capture(key, c.w, c.h, L.fx_ident(tr, fx))

r.MB(("Saved %d x %d (canvas)\n\nfor:  %s\nkey:  %s\n\n" ..
      "Make sure EON_FloatSize_Watch.lua is running -- this plugin will open " ..
      "at that size from now on, ahead of the size EON ships for it.\n\n" ..
      "No embed was touched: this never changes @gfx.")
     :format(c.w, c.h, nm or "?", key), "EON float size", 0)
