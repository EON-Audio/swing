-- grid_widget.lua — EON Drum Matrix. A small floating "grid cog": shows the
-- current project grid division and lets you change it by HOVER + mouse wheel.
-- It works whether or not paint mode is on, because it is its OWN ImGui window
-- (NOT the NoMouseInputs overlay) — the same trick the settings cog and pattern
-- bar use. Left-click cycles forward, right-click cycles back.
--
-- Division list + cycle logic live in lib/grid.lua (single source of truth,
-- shared with the paint-mode wheel + the EON_DM_CycleGrid keybind).

local r = reaper
local M = {}

local _SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
local grid = dofile(_SCRIPT_DIR .. 'grid.lua')

-- Layout: a compact pill on the RIGHT edge, in the floating-controls column,
-- stacked below the settings cog (T+4, ~52px) and the tool-mode selector
-- (~T+60, ~34px). Single source of truth for Render AND the paint-suppression
-- hover check (so a wheel/click over the pill never bleeds into the grid).
local GW_W      = 86
local GW_H      = 26
local RIGHT_PAD = 4
local TOP_OFF   = 4 + 52 + 4 + 34 + 4   -- clears the cog + tool-mode column

function M.GetRect(R, T)
  if not R or not T then return nil end
  return R - GW_W - RIGHT_PAD, T + TOP_OFF, GW_W, GW_H
end

function M.IsHovered(ctx, R, T)
  local x, y, w, h = M.GetRect(R, T)
  if not x then return false end
  local mx, my = reaper.ImGui_GetMousePos(ctx)
  return mx ~= nil and mx >= x and mx <= x + w and my >= y and my <= y + h
end

function M.Render(ctx, L, T, R, B)
  local x, y, w, h = M.GetRect(R, T)
  if not x then return end
  reaper.ImGui_SetNextWindowPos(ctx, x, y)
  reaper.ImGui_SetNextWindowSize(ctx, w, h)
  local flags = reaper.ImGui_WindowFlags_NoTitleBar()
              | reaper.ImGui_WindowFlags_NoResize()
              | reaper.ImGui_WindowFlags_NoMove()
              | reaper.ImGui_WindowFlags_NoScrollbar()
              | reaper.ImGui_WindowFlags_NoSavedSettings()
              | reaper.ImGui_WindowFlags_NoFocusOnAppearing()
              | reaper.ImGui_WindowFlags_NoDocking()
              | reaper.ImGui_WindowFlags_NoBackground()
              | reaper.ImGui_WindowFlags_NoCollapse()
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 0, 0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 5)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        0x222222C0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x444444FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  0x666666FF)
  if reaper.ImGui_Begin(ctx, 'EON_DM_GridCog', false, flags) then
    if reaper.ImGui_Button(ctx, 'Grid ' .. grid.CurrentLabel(), w, h) then
      grid.Cycle(1)   -- left-click: forward
    end
    if reaper.ImGui_IsItemHovered(ctx) then
      local wheel = reaper.ImGui_GetMouseWheel(ctx) or 0
      if wheel ~= 0 then grid.Cycle(wheel > 0 and 1 or -1) end
      reaper.ImGui_SetTooltip(ctx,
        'Project grid: ' .. grid.CurrentLabel() ..
        '\nWheel: change    Click: next    Right-click: prev')
    end
    if reaper.ImGui_IsItemClicked(ctx, 1) then
      grid.Cycle(-1)  -- right-click: back
    end
    reaper.ImGui_End(ctx)
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

return M
