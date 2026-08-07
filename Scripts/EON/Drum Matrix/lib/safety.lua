-- safety.lua -- EON Drum Matrix cross-cutting safety helpers.
--
-- Centralizes the guards that every other module needs:
--   * SafePcall  - pcall + console log so the defer loop never silently dies
--   * Validate*  - cheap ValidatePtr wrappers, return true/false
--   * ConsoleWarn - one-line "[EON DM] ..." log to REAPER console
--   * AcquireScriptLock / ReleaseScriptLock - ExtState-based singleton lock
--     with a TTL so stale locks self-expire after REAPER crashes
--
-- Used by all hardened modules. Tiny — no Lua-side state beyond the warn
-- dedup table to avoid spamming the console with the same message every frame.

local M = {}

local EXT_SECTION_LOCKS = 'EON_DRUM_MATRIX_LOCKS'

-- Console warn dedup: keys are arbitrary strings, values are last-emit time.
-- Same warn key won't emit more than once per WARN_DEDUP_SEC seconds.
local WARN_DEDUP_SEC = 5
local _warned_at = {}

-- =============================================================================
-- Console logging
-- =============================================================================

function M.ConsoleWarn(msg)
  if not msg or msg == '' then return end
  reaper.ShowConsoleMsg('[EON DM] ' .. tostring(msg) .. '\n')
end

-- Same as ConsoleWarn but rate-limited per `key`. Use when a warn might fire
-- every defer tick (e.g. malformed P_EXT on a track we keep re-classifying).
function M.ConsoleWarnOnce(key, msg)
  if not key or not msg then return end
  local now  = reaper.time_precise()
  local last = _warned_at[key]
  if last and (now - last) < WARN_DEDUP_SEC then return end
  _warned_at[key] = now
  M.ConsoleWarn(msg)
end

-- Reset the dedup table — call at script init so previous-session warnings
-- don't suppress fresh ones in a new run.
function M.ResetWarnDedup()
  _warned_at = {}
end

-- =============================================================================
-- Pointer validation
-- =============================================================================

function M.ValidateTrack(track)
  if not track then return false end
  if not reaper.ValidatePtr then return true end   -- old REAPER: best effort
  return reaper.ValidatePtr(track, 'MediaTrack*')
end

function M.ValidateTake(take)
  if not take then return false end
  if not reaper.ValidatePtr then return true end
  return reaper.ValidatePtr(take, 'MediaItem_Take*')
end

function M.ValidateItem(item)
  if not item then return false end
  if not reaper.ValidatePtr then return true end
  return reaper.ValidatePtr(item, 'MediaItem*')
end

-- =============================================================================
-- pcall wrapper
-- =============================================================================

-- Wrap a function call so the defer loop never dies on a single bad frame.
-- Returns (true, fn_return_values...) on success, (false, errmsg) on failure.
-- On failure, logs the error once via ConsoleWarnOnce keyed by error message,
-- so an error that fires every tick won't drown the console.
function M.SafePcall(label, fn, ...)
  local ok, err_or_val = pcall(fn, ...)
  if not ok then
    M.ConsoleWarnOnce('pcall:' .. tostring(label) .. ':' .. tostring(err_or_val),
                      tostring(label) .. ': ' .. tostring(err_or_val))
    return false, err_or_val
  end
  return true, err_or_val
end

-- =============================================================================
-- Singleton script lock (ExtState-based, TTL-protected)
-- =============================================================================
-- Pattern: a script wanting exclusive run writes a reaper.time_precise()
-- timestamp (seconds since an arbitrary per-session epoch — NOT unix time;
-- only meaningful for elapsed-time comparison) to ExtState when it starts,
-- and clears it when it exits. Other instances reading the key check: if the
-- timestamp is <ttl_sec old, lock is held; if older, the previous holder
-- crashed and we can take the lock.
-- This is best-effort, not a true mutex: there is no compare-and-swap between
-- the staleness check and the write below. In practice REAPER runs ReaScripts
-- cooperatively on a single main thread, so AcquireScriptLock always runs to
-- completion before any other script executes — adequate for de-duplicating
-- rapid toolbar-button presses without inter-process IPC.

function M.AcquireScriptLock(name, ttl_sec)
  if not name then return false end
  ttl_sec = ttl_sec or 5
  local now = reaper.time_precise()
  local cur = reaper.GetExtState(EXT_SECTION_LOCKS, name)
  if cur and cur ~= '' then
    local held_at = tonumber(cur)
    if held_at and (now - held_at) < ttl_sec then
      return false   -- another instance holds it, lock is fresh
    end
    -- stale lock, previous holder crashed - we may take it
  end
  reaper.SetExtState(EXT_SECTION_LOCKS, name, tostring(now), false)
  return true
end

-- Refresh the timestamp inside an already-held lock. Call once per defer
-- tick from long-running scripts (the main overlay) so the TTL never expires
-- while the script is alive.
function M.RefreshScriptLock(name)
  if not name then return end
  reaper.SetExtState(EXT_SECTION_LOCKS, name, tostring(reaper.time_precise()), false)
end

function M.ReleaseScriptLock(name)
  if not name then return end
  reaper.DeleteExtState(EXT_SECTION_LOCKS, name, false)
end

return M
