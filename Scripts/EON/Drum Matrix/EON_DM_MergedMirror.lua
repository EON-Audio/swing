-- EON_DM_MergedMirror.lua -- Keeps merged mode's hidden trigger track in step
-- with the pattern items you edit. Toggle action: run once to start, again to
-- stop (the toolbar button lights while it runs).
--
-- Merged mode puts each pad's pattern item on the pad's own audio track. Those
-- tracks cannot send MIDI to Swing without creating a routing cycle (see
-- lib/merged_mirror.lua), so the notes reach Swing through one hidden trigger
-- track instead. This loop is what keeps that track equal to the lanes.
--
-- Cost is a string compare per tick, not a rebuild: merged_mirror.Digest folds
-- REAPER's own MIDI hash plus item geometry into one signature and the rebuild
-- only runs when it moves. Idle projects cost effectively nothing.
--
-- This mirror now lives INSIDE the always-on bridge (Swing_Kit_Bridge.lua,
-- eon_merged_mirror_tick), folded in the same way EON_StepSeq_Sync_Courier.lua
-- was. Running this standalone copy at the same time would rebuild the same
-- trigger track from the same lanes twice a pass, and the two would take turns
-- invalidating each other's digest cache — so if the bridge is alive, this
-- self-disables and lets the bridge own it. The standalone only matters now as
-- a bare-DM fallback for someone running the Drum Matrix without the bridge.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path

local safety = dofile(SCRIPT_DIR .. 'lib/safety.lua')
local mirror = dofile(SCRIPT_DIR .. 'lib/merged_mirror.lua')
if not (mirror and mirror.Sync) then
  r.ShowMessageBox('lib/merged_mirror.lua missing or invalid.', 'EON DM Merged Mirror', 0)
  return
end

-- Bridge ownership check — same test the StepSeq courier uses (the bridge
-- writes os.time() to gmem[99] = KIT_GMEM_BRIDGE_ALIVE while it runs, 0 on
-- exit). Done before anything else so the toggle state is never touched.
r.gmem_attach('Swing_Media_Transfer')
if (r.gmem_read(99) or 0) > 0 then
  r.ShowMessageBox(
    'The Swing Kit Bridge is running, and it already keeps merged mode\'s\n' ..
    'trigger track up to date. This standalone mirror is not needed.\n\n' ..
    'It only exists as a fallback for running the Drum Matrix without the bridge.',
    'EON DM Merged Mirror', 0)
  return
end

-- Toolbar toggle state. sec/cmd come from REAPER when the action runs.
local _, _, sec, cmd = r.get_action_context()
local function set_toggle(on)
  if sec and cmd then r.SetToggleCommandState(sec, cmd, on and 1 or 0) end
  r.RefreshToolbar2(sec or 0, cmd or 0)
end

-- ---------------------------------------------------------------------------
-- Cross-instance run state
-- ---------------------------------------------------------------------------
-- Deliberately NOT safety.AcquireScriptLock: that lock is a mutual-exclusion
-- guard with no way for the holder to notice it has been revoked, so a second
-- press clearing the key would just get overwritten by the live copy's next
-- refresh and the toggle would never turn off. A heartbeat plus an explicit
-- stop flag gives the running copy something it can actually observe.
--
--   run  = reaper.time_precise() heartbeat, rewritten every tick by the live
--          copy. Older than STALE_AFTER means the holder died (script error,
--          REAPER crash) and a fresh press should start rather than toggle off.
--   stop = set by the second press; the live copy sees it and exits.
local EXT         = 'EON_DM_MERGED_MIRROR'
local STALE_AFTER = 2.0

local function heartbeat_fresh()
  local v = tonumber(r.GetExtState(EXT, 'run') or '')
  return v ~= nil and (r.time_precise() - v) < STALE_AFTER
end

if heartbeat_fresh() then
  -- A mirror is live: this press is the "off" half of the toggle.
  r.SetExtState(EXT, 'stop', '1', false)
  set_toggle(false)
  return
end

r.DeleteExtState(EXT, 'stop', false)
set_toggle(true)

r.atexit(function()
  r.DeleteExtState(EXT, 'run', false)
  r.DeleteExtState(EXT, 'stop', false)
  set_toggle(false)
end)

-- ---------------------------------------------------------------------------
-- Loop
-- ---------------------------------------------------------------------------

-- ~4 Hz. Fast enough that a painted note is audible on the next loop pass,
-- slow enough that the digest scan never shows up in a CPU profile.
local TICK_FRAMES = 8
local frame = 0

-- Reset the digest cache whenever the active project changes: track pointers
-- and GUIDs are per-project, and a stale digest would make the mirror think a
-- freshly-opened project's trigger track is already up to date.
local last_proj = r.EnumProjects(-1)

local function tick()
  frame = frame + 1
  if frame % TICK_FRAMES ~= 0 then r.defer(tick) return end

  if r.GetExtState(EXT, 'stop') == '1' then return end   -- atexit does cleanup
  r.SetExtState(EXT, 'run', tostring(r.time_precise()), false)

  local proj = r.EnumProjects(-1)
  if proj ~= last_proj then
    last_proj = proj
    mirror.Reset()
  end

  for _, guid in ipairs(mirror.MergedInstances()) do
    safety.SafePcall('merged_mirror.Sync', mirror.Sync, guid)
  end

  r.defer(tick)
end

r.defer(tick)
