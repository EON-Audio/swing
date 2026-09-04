-- @description EON: New Song (starter — regions + Swing + lanes)
-- @version 1.0
-- @author EON Studios
-- @about
--   Builds a song skeleton in one go: sets the tempo, drops the named regions
--   on the timeline, adds a Swing track, and builds the Drum Matrix lanes +
--   multi-out audio (the lanes are the writing surface; per-region MIDI items
--   on the Swing track are created only when lanes are OFF). Prompts for
--   tempo, section length and section names first.
local dir = ({reaper.get_action_context()})[2]:match("^(.*)[/\\]")
local S = dofile(dir .. "/EON/eon_song_starter.lua")
local T = dofile(dir .. "/EON/eon_action_target.lua")

-- Handoff from EON Swing Dock View's "No Swing in this project" menu: it stages
-- this flag right before launching us, so the rig opens once the song actually
-- exists. Read and CLEARED here at load, not in the callback — cancelling the
-- dialog never reaches the callback, and a flag left armed would make the next
-- plain "New Song" run pop the dock view open out of nowhere.
local open_view = reaper.GetExtState("EON_DockView", "after_song") == "1"
reaper.DeleteExtState("EON_DockView", "after_song", false)

-- ⚠️ S.prompt is ASYNC (the dialog runs on the defer loop) — the build has to
-- happen inside the callback. Nothing may follow this call that assumes the
-- song exists; the main chunk returns long before the user clicks Create.
S.prompt(function(opts)
  opts.insert_swing = true
  -- ⚠️ Default these only when ABSENT. The ReaImGui dialog supplies them from
  -- its "Also build" checkboxes; the GetUserInputs fallback cannot, and setting
  -- them unconditionally here would quietly ignore whatever the user ticked.
  if opts.midi_items  == nil then opts.midi_items  = true end
  if opts.build_lanes == nil then opts.build_lanes = true end
  opts.target = T
  S.build(opts)
  -- The song exists now, so the dock view has something to build around.
  -- Plain toggle, not apply mode: with the rig closed (which is why the user
  -- was asked in the first place) a toggle opens the active layout.
  if open_view then
    -- Ships next to this file (the dock rig is in .Scripts since 2026-09-04).
    local view = dir .. "/EON_Swing_Dock_View.lua"
    local vf = io.open(view, "r")
    if vf then
      vf:close()
      local cmd = reaper.AddRemoveReaScript(true, 0, view, true)
      if cmd and cmd > 0 then reaper.Main_OnCommand(cmd, 0) end
      -- Deliberately NOT unregistered: AddRemoveReaScript(false, path) strips
      -- the action for that PATH no matter who registered it, and the dock-rig
      -- docs tell users to install this very file as their own action — the
      -- same dance killed it on 2026-08-26. Registering is idempotent.
    end
  end
end)
