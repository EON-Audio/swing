-- EON Drum Matrix: transparent ReaImGui overlay over REAPER's arrange view.
-- Positioning logic adapted from Sexan/TK_Trackname_in_Arrange.lua.
-- All Drum Matrix decorations draw into the DrawList exposed by this module.

-- Dependency shim (ReaImGui 0.9.x + js_ReaScriptAPI 1.x)
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox('EON Drum Matrix requires ReaImGui (install via ReaPack).', 'EON Drum Matrix', 0)
  return {}
end
if not reaper.JS_Window_FindChildByID then
  reaper.ShowMessageBox('EON Drum Matrix requires js_ReaScriptAPI (install via ReaPack).', 'EON Drum Matrix', 0)
  return {}
end

local M = {}

-- Module-scoped state (Sexan's positioning system uses uppercase bounds)
local LEFT, TOP, RIGHT, BOT = 0, 0, 0, 0
local OLD_VAL               = 0   -- sum-of-coords cache; skips PointConvertNative when arrange hasn't moved
local scroll_size           = 17  -- Windows default; overwritten in Init for macOS
local scroll_size_effective = 17  -- what BeginFrame actually subtracted (may be 0 if ClientRect already excluded scrollbar)
local last_uiscale          = 1   -- last seen REAPER uiscale; recompute scroll_size when it changes
local ctx, main_hwnd, arrange_hwnd
local visible               = false
local window_focused        = false  -- does the overlay's ImGui window have OS focus?

local function recompute_scroll_size()
  local _, dpi_rpr_str = reaper.get_config_var_string('uiscale')
  local dpi = tonumber(dpi_rpr_str) or 1
  if dpi ~= last_uiscale then
    last_uiscale = dpi
    scroll_size = math.floor(15 * dpi + 0.5)
    OLD_VAL     = 0   -- force bounds re-cache so the new scrollbar width takes effect this frame
  end
end

-- Base flags, always-on. NoMouseInputs is OR'd in per-frame when paint_mode is false.
local function base_flags()
  local f = reaper.ImGui_WindowFlags_NoTitleBar()
          | reaper.ImGui_WindowFlags_NoResize()
          | reaper.ImGui_WindowFlags_NoDecoration()
          | reaper.ImGui_WindowFlags_NoBackground()
          | reaper.ImGui_WindowFlags_NoMove()
          | reaper.ImGui_WindowFlags_NoNav()
          | reaper.ImGui_WindowFlags_NoDocking()
          | reaper.ImGui_WindowFlags_NoSavedSettings()
          | reaper.ImGui_WindowFlags_NoFocusOnAppearing()
          | reaper.ImGui_WindowFlags_NoScrollbar()
  -- NoBringToFrontOnFocus: don't raise the overlay's OS window when it's clicked
  -- (paint mode). Without this, clicking a lane to paint pulls the overlay above
  -- Swing every time. The overlay still receives the click where it's already the
  -- topmost window (over the bare arrange), so painting is unaffected. Guarded in
  -- case an older ReaImGui lacks the flag.
  if reaper.ImGui_WindowFlags_NoBringToFrontOnFocus then
    f = f | reaper.ImGui_WindowFlags_NoBringToFrontOnFocus()
  end
  return f
end

local function ensure_arrange()
  if not arrange_hwnd or not reaper.ValidatePtr(arrange_hwnd, 'HWND') then
    main_hwnd    = reaper.GetMainHwnd()
    arrange_hwnd = reaper.JS_Window_FindChildByID(main_hwnd, 0x3E8)
    OLD_VAL      = 0  -- force re-convert next frame
  end
  return arrange_hwnd ~= nil
end

-- Keep every floating REAPER window (FX floats incl. Swing, the Mixer, the FX
-- browser, dialogs, and our own cog/pattern ImGui helper windows) stacked ABOVE
-- the transparent overlay, so the overlay never covers them. This mirrors
-- TK_Trackname_in_Arrange's PROVEN method:
--   (a) collect windows that must sit above the overlay — by class/title
--       (^REAPER, #32770 dialogs, Lua_LICE, ^WDL, Media Explorer / FX Browser,
--       plus reaper_imgui_context for our own helper windows), AND every
--       floating FX window via reaper.TrackFX_GetFloatingWindow (the reliable way
--       to get a floated JSFX GUI like Swing, which has no stable window class);
--   (b) SetZOrder each to 'TOP' (SWP_NOACTIVATE — no focus change);
--   (c) do it as a brief ONE-SHOT right after the overlay window exists — NOT on
--       a timer. Re-running on a heartbeat/focus was the cause of every glitch:
--       it flickered on each click and re-raised Swing above dialogs that popped
--       up later ("Save prompt stuck behind Swing"). One-shot avoids both.
--
-- DM adds one thing TK doesn't need: TK's overlay is display-only, so clicking it
-- passes through and never raises it. DM's overlay is CLICKABLE in paint mode, so
-- a paint click could raise it back on top. We set WS_EX_NOACTIVATE on the
-- overlay so clicking it never activates/raises it — making the one-shot stick.
-- (The overlay still receives mouse for painting; non-activating windows get
-- mouse messages, and keyboard already routes via the ExtState command queue.)
--
-- WRONG attempts, do NOT repeat: (1) push overlay BELOW each match with a 1024
-- array — ArrayAllTop returns a negative count when too small (~1300 windows
-- here) so it silently did nothing; (2) SetZOrder(overlay,'BOTTOM') — overlay is
-- OWNED by main and SetWindowPos lacks SWP_NOOWNERZORDER, so it dragged MAIN
-- REAPER to the global back; (3) sink overlay below the lowest float via
-- tostring(hwnd) — unreliable; (4) re-raise floats on a heartbeat — flicker +
-- dialogs trapped behind Swing.
local overlay_hwnd  = nil
local zo_tick       = 0       -- frames since the (re)start of the raise warmup
local zo_done       = false   -- one-shot raise complete?
local zo_last_paint = nil     -- last paint_mode seen (toggle → re-run the raise)

-- WS_EX_NOACTIVATE (0x08000000): once, so paint clicks never raise the overlay.
local function make_overlay_nonactivating()
  if not (reaper.JS_Window_GetLong and reaper.JS_Window_SetLong) then return end
  local ex = reaper.JS_Window_GetLong(overlay_hwnd, 'EXSTYLE')
  if not ex then return end
  ex = math.floor(ex)
  if (ex & 0x08000000) == 0 then
    reaper.JS_Window_SetLong(overlay_hwnd, 'EXSTYLE', ex | 0x08000000)
  end
end

-- Collect + raise (to TOP) every window that must sit above the overlay.
local function raise_windows_above_overlay()
  local to_raise = {}

  -- (a) REAPER windows / dialogs / other ImGui windows, by class + title.
  local arr = reaper.new_array({}, 8192)
  local n = reaper.JS_Window_ArrayAllTop(arr)
  if n and n < 0 then
    arr = reaper.new_array({}, (-n) + 64)
    n = reaper.JS_Window_ArrayAllTop(arr)
  end
  if n and n >= 1 then
    for _, addr in ipairs(arr.table()) do
      local h = reaper.JS_Window_HandleFromAddress(addr)
      if h and h ~= overlay_hwnd and h ~= main_hwnd and reaper.JS_Window_IsVisible(h) then
        local cn = reaper.JS_Window_GetClassName(h) or ''
        local ti = reaper.JS_Window_GetTitle(h) or ''
        if cn:match('^REAPER') or cn == '#32770' or cn:match('Lua_LICE')
           or cn:match('^WDL') or cn == 'reaper_imgui_context'
           or ti:match('Media Explorer') or ti:match('FX Browser') then
          to_raise[#to_raise + 1] = h
        end
      end
    end
  end

  -- (b) Every floating FX window (reliably catches Swing / any FX GUI).
  if reaper.TrackFX_GetFloatingWindow then
    local function collect(tr)
      if not tr then return end
      for fx = 0, (reaper.TrackFX_GetCount(tr) or 0) - 1 do
        local fh = reaper.TrackFX_GetFloatingWindow(tr, fx)
        if fh and reaper.JS_Window_IsVisible(fh) then to_raise[#to_raise + 1] = fh end
      end
    end
    for i = 0, reaper.CountTracks(0) - 1 do collect(reaper.GetTrack(0, i)) end
    collect(reaper.GetMasterTrack(0))
  end

  for _, h in ipairs(to_raise) do
    reaper.JS_Window_SetZOrder(h, 'TOP')
  end
end

local function ensure_overlay_z_order(paint_mode)
  if not (reaper.JS_Window_Find and reaper.JS_Window_SetZOrder
          and reaper.JS_Window_ArrayAllTop) then return end
  -- Wait until the overlay's OS window actually exists (ReaImGui creates it on
  -- the first frame); retry each frame until then.
  if not overlay_hwnd or not reaper.JS_Window_IsWindow(overlay_hwnd) then
    overlay_hwnd = reaper.JS_Window_Find('EON_DrumMatrix_Overlay', true)
  end
  if not overlay_hwnd then return end

  -- Re-assert NON-ACTIVATING every frame (ReaImGui rewrites the ex-style, which
  -- would otherwise clobber our one-time set and let a paint click raise the
  -- overlay over Swing). The GetLong is cheap; SetLong only fires when the bit
  -- was actually stripped.
  make_overlay_nonactivating()

  -- Re-run the one-shot raise whenever paint mode TOGGLES. If a paint interaction
  -- did manage to raise the overlay, toggling paint (esp. back OFF) re-lifts the
  -- floating windows above it. Event-driven — fires only on the transition, so it
  -- never becomes a per-frame timer (which is what caused the flicker before).
  if paint_mode ~= zo_last_paint then
    zo_last_paint = paint_mode
    zo_done, zo_tick = false, 0
  end

  if zo_done then return end

  -- Two shots: immediately (get Swing above the overlay with no visible lag) and
  -- again a few frames later (so the cog / grid / pattern helper windows, which
  -- ReaImGui creates over the following frames, also get raised). Then stop for
  -- good — no timer, so no flicker and no re-covering of later dialogs.
  zo_tick = zo_tick + 1
  if zo_tick == 1 or zo_tick == 8 then
    raise_windows_above_overlay()
  end
  if zo_tick >= 8 then zo_done = true end
end

-- Floating-FX exclusion rects (paint-mode cutout). While paint mode is on the
-- overlay's OS window sits ABOVE floating FX windows (ReaImGui raises it to
-- capture paint clicks — nothing we tried overrides that). So instead of
-- fighting the z-order, the renderer punches HOLES: it skips drawing inside
-- every visible floating FX window's rect, letting Swing (all instances — this
-- enumerates every track's floating FX, so N open Swings = N rects) show
-- through the transparent overlay. This returns those rects in ImGui coords
-- (same PointConvertNative space the overlay draws in), or nil when none.
function M.GetFXExclusionRects()
  if not (ctx and reaper.JS_Window_GetRect and reaper.TrackFX_GetFloatingWindow) then
    return nil
  end
  local rects
  local function add_fx_windows(tr)
    if not tr then return end
    for fx = 0, (reaper.TrackFX_GetCount(tr) or 0) - 1 do
      local fh = reaper.TrackFX_GetFloatingWindow(tr, fx)
      if fh and reaper.JS_Window_IsVisible(fh) then
        local ok, l, t, r_, b = reaper.JS_Window_GetRect(fh)
        if ok then
          local x1, y1 = reaper.ImGui_PointConvertNative(ctx, l, t)
          local x2, y2 = reaper.ImGui_PointConvertNative(ctx, r_, b)
          if x2 > x1 and y2 > y1 then
            rects = rects or {}
            rects[#rects + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
          end
        end
      end
    end
  end
  for i = 0, reaper.CountTracks(0) - 1 do add_fx_windows(reaper.GetTrack(0, i)) end
  add_fx_windows(reaper.GetMasterTrack(0))
  return rects
end

function M.Init(script_name)
  ctx = reaper.ImGui_CreateContext(script_name or 'EON Drum Matrix')
  -- Scrollbar width: TK uses 15 across platforms, DPI-scaled by REAPER's
  -- uiscale config var. Matches REAPER's actual scrollbar pixel width on
  -- Windows + macOS — using 17 produced a ~2px grid offset vs REAPER's lines.
  -- Re-checked each BeginFrame so DPI changes mid-session reflow correctly.
  recompute_scroll_size()
  ensure_arrange()
end

-- suppress_mouse: true while the cursor hovers a floating-FX cutout hole in
-- paint mode — the overlay goes NoMouseInputs for that frame so the click
-- passes THROUGH to the FX window the user can see (instead of painting an
-- invisible note into the lane hidden behind it).
function M.BeginFrame(paint_mode, suppress_mouse)
  visible = false
  if not ctx then return false end
  -- Detect REAPER DPI/uiscale changes mid-session and invalidate the bounds
  -- cache so the overlay reflows on the very next frame instead of waiting
  -- for the arrange-view rect to also change.
  recompute_scroll_size()
  if not ensure_arrange() then return false end

  -- Use the OUTER window rect (JS_Window_GetRect), exactly like the proven
  -- TK_Trackname_in_Arrange overlay. The arrange view's visible time range
  -- maps across the FULL outer width (LEFT..RIGHT); coords.TimeToPixel uses
  -- RIGHT-LEFT with no scrollbar subtraction. We only shrink the ImGui WINDOW
  -- by scroll_size so our painting doesn't sit on top of the vertical
  -- scrollbar — that's cosmetic and does NOT affect the time→pixel mapping.
  --
  -- (Earlier we preferred GetClientRect with conditional scroll subtraction;
  -- that shifted LEFT by the window border and compressed the axis, which is
  -- what forced the manual offset slider. Matching TK removes both.)
  local ok, l, t, r_, b = reaper.JS_Window_GetRect(arrange_hwnd)
  if not ok then return false end

  local sum = l + t + r_ + b
  if sum ~= OLD_VAL then
    OLD_VAL    = sum
    LEFT, TOP  = reaper.ImGui_PointConvertNative(ctx, l, t)
    RIGHT, BOT = reaper.ImGui_PointConvertNative(ctx, r_, b)
  end

  -- scroll_size is the scrollbar width we trim from the WINDOW only. coords
  -- maps time across the full RIGHT-LEFT, so GetScrollSize() is informational
  -- for any caller that wants to clamp draw endpoints away from the scrollbar.
  scroll_size_effective = scroll_size

  reaper.ImGui_SetNextWindowPos(ctx, LEFT, TOP)
  reaper.ImGui_SetNextWindowSize(ctx, (RIGHT - LEFT) - scroll_size, (BOT - TOP) - scroll_size)

  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x00000000)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 0)

  local flags = base_flags()
  if not paint_mode or suppress_mouse then
    flags = flags | reaper.ImGui_WindowFlags_NoMouseInputs()
  end

  visible = reaper.ImGui_Begin(ctx, 'EON_DrumMatrix_Overlay', false, flags)
  -- Capture focus while the overlay is the current ImGui window. Used by the
  -- command-queue dispatcher to avoid double-firing: when focused, ImGui keys
  -- handle the hotkeys; when unfocused, the bound REAPER actions do.
  window_focused = visible and reaper.ImGui_IsWindowFocused(ctx) or false
  -- Keep the floating windows above the overlay (TK one-shot at open; re-run on
  -- paint-mode toggle). Non-activating ex-style re-asserted here each frame.
  ensure_overlay_z_order(paint_mode)
  return visible
end

-- True when the overlay's ImGui window currently holds OS keyboard focus.
function M.IsFocused()
  return window_focused
end

function M.EndFrame()
  if not ctx then return end
  if visible then
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  visible = false
end

function M.GetDrawList()
  if not ctx then return nil end
  -- Guard against the BeginFrame having returned false (window not visible).
  -- ImGui_GetWindowDrawList may itself error if there's no current window;
  -- pcall it and return nil on failure so callers see the same null path
  -- they'd see if ctx was nil.
  local ok, dl = pcall(reaper.ImGui_GetWindowDrawList, ctx)
  if not ok then return nil end
  return dl
end

function M.GetBounds()
  return LEFT, TOP, RIGHT, BOT
end

function M.GetScrollSize()
  -- Returns the value BeginFrame actually subtracted this frame — 0 if the
  -- client rect already excluded the scrollbar, otherwise the platform default.
  return scroll_size_effective or scroll_size
end

function M.GetCtx()
  return ctx
end

function M.Shutdown()
  -- ReaImGui 0.9.x has no explicit DestroyContext — the context is reclaimed
  -- automatically when the script terminates. Just drop the reference.
  ctx = nil
end

return M
