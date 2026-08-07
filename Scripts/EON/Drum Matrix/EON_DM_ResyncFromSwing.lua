-- EON_DM_ResyncFromSwing.lua -- One-shot. Pull the live Swing kit/pad state
-- (names + MIDI notes) into every unlocked drum lane right now. Useful when
-- you changed the kit or renamed pads in Swing and want to snap the matrix to
-- match without waiting for the overlay's automatic sync (or when the overlay
-- isn't running at all). Bind to a key if you do this often.
--
-- Mirrors EON_DM_Build's bridge-handshake timing: bump gmem[99]
-- (KIT_GMEM_BRIDGE_ALIVE) so the Swing JSFX republishes its pad metadata,
-- defer a few frames to let that land, then resync.

local r = reaper

local SCRIPT_DIR = debug.getinfo(1, 'S').source:match('^@?(.*[\\/])') or ''
package.path = SCRIPT_DIR .. 'lib/?.lua;' .. package.path
local swing_sync = dofile(SCRIPT_DIR .. 'lib/swing_sync.lua')

local KIT_GMEM_BRIDGE_ALIVE = 99
local MAX_FRAMES = 8

r.gmem_attach('Swing_Media_Transfer')
r.gmem_write(KIT_GMEM_BRIDGE_ALIVE, os.time())   -- ask Swing to republish

local frames = 0
local function wait_then_sync()
  frames = frames + 1
  -- Give Swing a few frames to see the heartbeat and write fresh pad data.
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
