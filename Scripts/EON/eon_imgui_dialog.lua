-- @noindex
-- eon_imgui_dialog.lua
-- A small modal form for the EON script family: a title, a handful of labelled
-- fields, Cancel / OK. It exists to replace reaper.GetUserInputs, whose Windows
-- chrome breaks the visual language of everything else EON ships — and whose
-- CSV-encoded field list means no field value can ever contain a comma.
--
-- ⚠️ ASYNC BY NATURE. GetUserInputs BLOCKS and returns the answer; ReaImGui runs
-- on the defer loop, so this hands the answer to a CALLBACK instead. A caller
-- that opens one of these must not do anything after the call that assumes the
-- answer is already in — move that work into on_ok.
--
-- Callers must keep their own GetUserInputs path and gate on M.available():
-- ReaImGui is a ReaPack extension the user may simply not have installed, and
-- an EON action that dies with "attempt to call a nil value" is worse than an
-- ugly dialog.
--
-- spec = {
--   title     string
--   width     number | nil     -- default 360
--   ok_label  string | nil     -- default "OK"
--   fields    { field, ... }
--   on_ok     function(values) -- values keyed by field.key
--   on_cancel function | nil
-- }
-- field = {
--   key    string              -- key in the values table handed to on_ok
--   label  string
--   kind   'text' | 'int' | 'number' | 'choice' | 'checks' | 'custom' | 'block'
--                              -- default 'text'
--   items  { {key,label,value}, ... }  -- 'checks' only: a row of toggles under
--                              --   one label. on_ok receives a table of
--                              --   key -> boolean under this field's key.
--   value  any                 -- initial value; carries the live edit.
--                              --   'choice' carries the 1-based index.
--   hint   string | nil        -- placeholder shown while a text field is empty
--   sub    string | nil        -- small grey note under the field
--   min    number | nil        -- clamped on accept, not while typing, so a
--   max    number | nil        --   half-typed "1" in a 20..400 field survives
--   choices    { string, ... } -- 'choice' only
--
-- A 'block' field is the odd one out: no label column, full width, and its
-- draw(ctx, by_key, set) does its OWN ImGui layout, so it can place real
-- widgets (a grid of clickable cards) rather than only painting. It gets `set`
-- because a block is usually a picker that writes the other fields.
--   on_change  function(index, set) -- 'choice' only; `set(key, value)` writes
--                              --   another field, which is how a template
--                              --   picker fills in the rest of the form
-- }
-- (c) EON Studios

local r = reaper
local M = {}

-- Every ReaImGui function this file actually calls, in surface order. Checked
-- up-front so a customer with an ancient ReaImGui that has CreateContext but is
-- missing something newer falls through to GetUserInputs -- vs. what used to
-- happen: dialog opens, then crashes mid-frame on the first missing call, and
-- the caller has already assumed "async, on_ok will fire" and moved on.
local REQUIRED = {
  'CreateContext', 'Begin', 'End', 'Text', 'TextColored', 'Button',
  'InputTextWithHint', 'InputInt', 'InputDouble', 'Checkbox',
  'BeginCombo', 'EndCombo', 'Selectable',
  'SetNextWindowSize', 'SetNextWindowPos', 'SetNextItemWidth',
  'SetKeyboardFocusHere', 'PushStyleVar', 'PopStyleVar',
  'PushStyleColor', 'PopStyleColor',
  'GetContentRegionAvail', 'GetWindowSize', 'GetCursorScreenPos',
  'AlignTextToFramePadding', 'SameLine', 'Separator', 'Dummy',
  'CalcTextSize', 'IsKeyPressed', 'TextWrapped',
  'Cond_FirstUseEver', 'Cond_Always', 'Cond_Appearing',
  'WindowFlags_NoCollapse', 'StyleVar_FrameRounding',
  'Col_Button', 'Col_ButtonHovered', 'Col_ButtonActive',
}
function M.available()
  for _, n in ipairs(REQUIRED) do
    if r['ImGui_' .. n] == nil then return false end
  end
  return true
end

-- EON palette. ReaImGui takes colours as 0xRRGGBBAA, NOT the 0xAARRGGBB that
-- the native REAPER colour APIs use.
local COL_OK       = 0x2A6FB0FF
local COL_OK_HOVER = 0x3A86D0FF
local COL_OK_ACTIVE= 0x1E5A94FF
local COL_SUB      = 0x8A8F98FF

-- The ImGui_Key_* enums are function calls that have moved between ReaImGui
-- versions. A missing one must degrade to "that shortcut is unavailable", never
-- to a nil-call that takes the whole dialog down — same guarded lookup the Drum
-- Matrix keymap uses.
local function key_of(name)
  local fn = r['ImGui_Key_' .. name]
  if not fn then return nil end
  local ok, v = pcall(fn)
  return ok and v or nil
end

local function clamp_field(f)
  if f.kind ~= 'int' and f.kind ~= 'number' then return end
  local v = tonumber(f.value) or 0
  if f.min and v < f.min then v = f.min end
  if f.max and v > f.max then v = f.max end
  if f.kind == 'int' then v = math.floor(v + 0.5) end
  f.value = v
end

-- Returns true if the dialog opened. False means no ReaImGui — the caller
-- should fall back, and on_cancel is NOT fired (nothing was ever shown).
function M.open(spec)
  if not M.available() then return false end

  local fields   = spec.fields or {}
  local ctx      = r.ImGui_CreateContext(spec.title or 'EON')
  local finished = false      -- fires the callback exactly once
  local first    = true
  -- Height is MEASURED, not guessed. The first frame uses a rough estimate, then
  -- we read back how much window was left unused and shrink to fit exactly once
  -- — a guessed row height is always wrong by a dozen pixels per field, which is
  -- what left a dead band under the buttons.
  local fit_h, measured = nil, false

  -- Cross-field writes, so a 'choice' field can fill in the rest of the form.
  local by_key = {}
  for _, f in ipairs(fields) do by_key[f.key] = f end
  local function set_field(k, v)
    local f = by_key[k]
    if f then f.value = v end
  end

  local K_ESC   = key_of('Escape')
  local K_ENTER = key_of('Enter')
  local K_KPENT = key_of('KeypadEnter')

  local function finish(accepted)
    if finished then return end
    finished = true
    if accepted then
      local out = {}
      for _, f in ipairs(fields) do
        clamp_field(f)
        out[f.key] = f.value
      end
      if spec.on_ok then spec.on_ok(out) end
    elseif spec.on_cancel then
      spec.on_cancel()
    end
  end

  local function frame()
    -- Not deferring again is how the window closes; the context is collected.
    if finished then return end

    -- ⚠️ Explicit size, NOT WindowFlags_AlwaysAutoResize. The fields ask for
    -- SetNextItemWidth(-1) = "fill the row", so auto-resize would be sizing the
    -- window to content that is itself sized to the window, and ImGui resolves
    -- that circle by collapsing to a sliver.
    if fit_h then
      r.ImGui_SetNextWindowSize(ctx, spec.width or 360, fit_h, r.ImGui_Cond_Always())
      fit_h = nil
    else
      -- Only the FIRST frame uses this; the measured fit below corrects it.
      local ch = 0
      for _, f in ipairs(fields) do
        ch = ch + (f.kind == 'custom' and ((f.height or 40) + 4)
                or f.kind == 'block'  and (f.height or 220)
                or 30)
                + (f.sub and 16 or 0)
      end
      r.ImGui_SetNextWindowSize(ctx, spec.width or 360,
                                spec.height or (56 + ch + 44),
                                r.ImGui_Cond_FirstUseEver())
    end
    -- Centre on the main window. Guarded: both calls are newer additions, and a
    -- dialog that lands in a default corner is a far smaller problem than one
    -- that does not open.
    if r.ImGui_GetMainViewport and r.ImGui_Viewport_GetCenter then
      local okv, cx, cy = pcall(function()
        return r.ImGui_Viewport_GetCenter(r.ImGui_GetMainViewport(ctx))
      end)
      if okv and cx then
        r.ImGui_SetNextWindowPos(ctx, cx, cy, r.ImGui_Cond_Appearing(), 0.5, 0.5)
      end
    end

    -- Softened frame corners; everything else stays REAPER's own dark theme so
    -- the dialog reads as part of the host rather than a visiting web page.
    r.ImGui_PushStyleVar(ctx, r.ImGui_StyleVar_FrameRounding(), 3)
    local visible, open = r.ImGui_Begin(ctx, spec.title or 'EON', true,
                                        r.ImGui_WindowFlags_NoCollapse())
    if visible then
      -- One label column, sized to the widest label, so the inputs line up
      -- instead of stair-stepping the way GetUserInputs does.
      local lblw = 0
      for _, f in ipairs(fields) do
        if f.kind ~= 'block' then
          local w = r.ImGui_CalcTextSize(ctx, f.label or '')
          if w > lblw then lblw = w end
        end
      end
      lblw = lblw + 14

      for i, f in ipairs(fields) do
       -- A 'block' owns the full width and its own layout, so it skips the
       -- label column entirely; everything else gets the aligned two-column row.
       if f.kind == 'block' then
        if f.draw then f.draw(ctx, by_key, set_field) end
       else
        r.ImGui_AlignTextToFramePadding(ctx)
        r.ImGui_Text(ctx, f.label or '')
        r.ImGui_SameLine(ctx, lblw)
        r.ImGui_SetNextItemWidth(ctx, -1)
        -- Land the caret in the first field so the dialog is typeable on open,
        -- the one genuinely good habit GetUserInputs had.
        if first and i == 1 then r.ImGui_SetKeyboardFocusHere(ctx) end

        local id = '##' .. tostring(f.key)
        if f.kind == 'custom' then
          -- Reserve a row and hand the caller the screen rect to paint into.
          -- Keeps this module free of any one dialog's bespoke graphics: the
          -- owner draws, we only do layout.
          local availw = r.ImGui_GetContentRegionAvail(ctx)
          local hh = f.height or 40
          local cx, cy = r.ImGui_GetCursorScreenPos(ctx)
          r.ImGui_Dummy(ctx, availw, hh)
          if f.draw then f.draw(ctx, cx, cy, availw, hh, by_key) end
        elseif f.kind == 'choice' then
          -- BeginCombo/Selectable rather than ImGui_Combo: the latter wants the
          -- items packed into one separator-delimited string, and getting that
          -- convention wrong fails at runtime instead of at read time.
          local items = f.choices or {}
          local cur = math.floor(tonumber(f.value) or 1)
          if cur < 1 then cur = 1 end
          if cur > #items then cur = #items end
          f.value = cur
          if r.ImGui_BeginCombo(ctx, id, items[cur] or '') then
            for ci, item in ipairs(items) do
              if r.ImGui_Selectable(ctx, item .. '##' .. ci, ci == cur) then
                f.value = ci
                if f.on_change then f.on_change(ci, set_field) end
              end
            end
            r.ImGui_EndCombo(ctx)
          end
        elseif f.kind == 'checks' then
          -- A ROW of toggles under one label, not one row each: three yes/no
          -- questions do not deserve three rows of a form this small. The
          -- value handed to on_ok is a table keyed by each item's key.
          local out = {}
          for ii, it in ipairs(f.items or {}) do
            if ii > 1 then r.ImGui_SameLine(ctx, 0, 12) end
            local chg, v = r.ImGui_Checkbox(ctx, (it.label or '') .. '##' ..
                                            tostring(f.key) .. ii, it.value and true or false)
            if chg then it.value = v end
            out[it.key] = it.value and true or false
          end
          f.value = out
        elseif f.kind == 'int' then
          -- step/step_fast 0 suppresses the +/- buttons: they eat width and
          -- this is a type-a-number field, not a nudge-it-live control.
          local chg, v = r.ImGui_InputInt(ctx, id, math.floor(tonumber(f.value) or 0), 0, 0)
          if chg then f.value = v end
        elseif f.kind == 'number' then
          local chg, v = r.ImGui_InputDouble(ctx, id, tonumber(f.value) or 0, 0, 0, '%g')
          if chg then f.value = v end
        else
          local chg, v = r.ImGui_InputTextWithHint(ctx, id, f.hint or '',
                                                   tostring(f.value or ''))
          if chg then f.value = v end
        end

        if f.sub then
          r.ImGui_Dummy(ctx, lblw - 8, 1)
          r.ImGui_SameLine(ctx)
          r.ImGui_TextColored(ctx, COL_SUB, f.sub)
        end
       end
      end

      r.ImGui_Dummy(ctx, 1, 4)
      r.ImGui_Separator(ctx)
      r.ImGui_Dummy(ctx, 1, 2)

      -- Buttons right-aligned, OK last: matches the platform order the rest of
      -- REAPER uses, so muscle memory still lands on the right one.
      -- cancel_label lets a confirm carry two REAL choices ("Keep on Main" vs
      -- "Add Returns") instead of forcing the second choice to read as an
      -- abort; no_cancel drops the left button entirely for pure notices
      -- (M.info) — an OK-only box with a Cancel button invents a choice that
      -- does not exist. Widths grow past the 92px floor to fit their label.
      local cl = spec.cancel_label or 'Cancel'
      local ol = spec.ok_label or 'OK'
      local function btn_w(lbl)
        local w = r.ImGui_CalcTextSize(ctx, lbl) + 26
        if w < 92 then w = 92 end
        return w
      end
      local cw = spec.no_cancel and 0 or btn_w(cl)
      local ow = btn_w(ol)
      local avail = r.ImGui_GetContentRegionAvail(ctx)
      local pad = avail - (cw + ow + (cw > 0 and 8 or 0))
      if pad > 0 then r.ImGui_Dummy(ctx, pad, 1); r.ImGui_SameLine(ctx) end
      if cw > 0 then
        if r.ImGui_Button(ctx, cl, cw, 0) then finish(false) end
        r.ImGui_SameLine(ctx)
      end
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_Button(),        COL_OK)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonHovered(), COL_OK_HOVER)
      r.ImGui_PushStyleColor(ctx, r.ImGui_Col_ButtonActive(),  COL_OK_ACTIVE)
      if r.ImGui_Button(ctx, ol, ow, 0) then finish(true) end
      r.ImGui_PopStyleColor(ctx, 3)

      -- Enter accepts from inside a field too — that is the whole point of a
      -- three-box form. Escape cancels.
      if K_ESC and r.ImGui_IsKeyPressed(ctx, K_ESC) then finish(false) end
      if (K_ENTER and r.ImGui_IsKeyPressed(ctx, K_ENTER))
        or (K_KPENT and r.ImGui_IsKeyPressed(ctx, K_KPENT)) then finish(true) end

      -- Fit once, now that everything is laid out: whatever vertical space is
      -- still unclaimed below the cursor is exactly the surplus to trim.
      if not measured then
        local _, availh = r.ImGui_GetContentRegionAvail(ctx)
        local _, winh   = r.ImGui_GetWindowSize(ctx)
        fit_h    = winh - availh + 10          -- +10 = bottom window padding
        measured = true
      end

      -- ⚠️ End ONLY when Begin returned true — the ReaImGui builds this bundle
      -- targets error on an unmatched End (same note as the StepSeq browsers).
      r.ImGui_End(ctx)
    end
    r.ImGui_PopStyleVar(ctx)   -- must pair with the push above on EVERY path

    if not open then finish(false) end   -- title-bar X
    first = false
    if not finished then r.defer(frame) end
  end

  r.defer(frame)
  return true
end

-- Confirmation dialog: a message + <cancel_label> / <ok_label>. Same contract
-- as M.open — returns false when ReaImGui is absent so the caller can fall
-- back to ShowMessageBox; on_ok fires only on the accept button (or Enter).
-- cancel_label relabels the left button for two-real-choices questions;
-- no_cancel drops it (used by M.info below). Height estimate follows the
-- message's line count — it only seeds the first frame, the measured fit
-- corrects it — so a multi-line question no longer clips at the fixed 44.
-- spec = { title, message, ok_label, cancel_label, no_cancel, width,
--          on_ok, on_cancel }
function M.confirm(spec)
  local _, nl = tostring(spec.message or ''):gsub('\n', '')
  return M.open({
    title    = spec.title or 'Confirm',
    width    = spec.width or 360,
    ok_label = spec.ok_label or 'OK',
    cancel_label = spec.cancel_label,
    no_cancel    = spec.no_cancel,
    on_ok    = spec.on_ok,
    on_cancel = spec.on_cancel,
    fields   = { {
      key  = '_msg',
      kind = 'block',
      height = 28 + nl * 17,
      draw = function(ctx)
        r.ImGui_TextWrapped(ctx, spec.message or '')
      end,
    } },
  })
end

-- Notice dialog: message + a single OK. Closing the window (X / Escape)
-- counts as acknowledged too — a notice has no choice to abandon — so both
-- paths land on on_ok (optional; omit it for fire-and-forget).
-- spec = { title, message, ok_label, width, on_ok }
function M.info(spec)
  return M.confirm({
    title     = spec.title or 'EON',
    message   = spec.message,
    ok_label  = spec.ok_label or 'OK',
    width     = spec.width,
    no_cancel = true,
    on_ok     = spec.on_ok,
    on_cancel = spec.on_ok,
  })
end

return M
