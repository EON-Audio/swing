-- EON_DM_ResyncFromSwing.lua -- One-shot. Pull the live Swing kit/pad state
-- (names + MIDI notes) into every unlocked drum lane right now. Useful when
-- you changed the kit or renamed pads in Swing and want to snap the matrix to
-- match without waiting for the overlay's automatic sync (or when the overlay
-- isn't running at all). Bind to a key if you do this often.
--
-- Defers a few frames so a Swing that just changed has published its pad
-- bands, then resyncs. It no longer stamps the bridge-alive cell (99): Swing
-- publishes whatever that cell holds, and the stamp impersonated a bridge for
-- 5 s (DM213, 2026-10-26: a real one refused to start, a fresh Swing posted
-- its auto-load into silence).

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local swing_sync = dofile(SCRIPT_DIR .. 'lib/swing_sync.lua')

local MAX_FRAMES = 8

r.gmem_attach('Swing_Media_Transfer')

local frames = 0
local function wait_then_sync()
  frames = frames + 1
  -- Give Swing a few frames to write fresh pad data.
  if frames < MAX_FRAMES then
    r.defer(wait_then_sync)
    return
  end
  local n = swing_sync.ForceResync()
  if n == -1 then
    r.Help_Set('EON DM Resync: Swing not detected.', false)
  else
    r.Help_Set(string.format('EON DM Resync: %d lane%s updated from Swing.',
      n, n == 1 and '' or 's'), false)
  end
end

r.defer(wait_then_sync)
