-- EON_UpdateCheck.lua
-- Startup action — dormant until Swing heartbeat detected in gmem.
-- Handles update checks and "open URL" requests from Swing.
--
-- First manual run self-registers as a REAPER startup action.
-- After that, auto-runs every REAPER launch with no user intervention.
--
-- gmem layout (shared with Swing via "Swing_Media_Transfer"):
--   1711  GS_SWING_ALIVE       counter incremented every @block (0 = no Swing)
--   1712  GS_UPDATE_REQUEST    0=none, 1=check, 2=open URL
--   1713  GS_UPDATE_STATE      0=idle, 1=checking, 2=up-to-date, 3=available
--   1714–1718  GS_LATEST_VER   5-char version string (e.g. "2.1.1")

---------------------------------------------------------------------------
-- CONFIG
---------------------------------------------------------------------------
local SCRIPT_NAME       = "EON_UpdateCheck"
local GMEM_SECTION      = "Swing_Media_Transfer"
-- GitHub Releases API for the public distribution repo EON-Audio/swing --
-- the SAME repo the ReaPack index is served from, so one publish bumps both
-- the available-update notification and the ReaPack package.
-- Returns JSON with tag_name (e.g. "3.0") and html_url (release page).
-- ⚠️ Deliberately the DISTRIBUTION repo, never the development one. The dev
-- repo is private and must stay that way; making it public just to answer
-- this query would expose its entire history. Do not repoint this at it.
-- (This file ships to customers -- keep account/repo names other than the
-- public distribution repo out of it.)
local UPDATE_URL        = "https://api.github.com/repos/EON-Audio/swing/releases/latest"
-- Must match the latest released ReaPack index.xml <version> AND the
-- JSFX version (Swing_ReaKit.jsfx: version: 3.0). Compared against the
-- GitHub tag_name (stripped of leading "v" if present).
-- ⚠️ A GitHub release carrying this tag has to actually EXIST on the repo
-- above. With no releases published, /releases/latest answers 404, whose body
-- carries no tag_name -- so the parse below finds nothing and the state lands
-- on 0 (idle), NOT 2 (up to date). The user is told nothing at all, and the
-- failure is indistinguishable from "no network". Verified against the live
-- endpoint 2026-08-08.
-- ⚠⚠ BUMP THIS WITH index.xml, EVERY RELEASE. It is what the GitHub tag is
-- compared against, and it is read as a full semver: left at "3.0" while the
-- index published 3.0.9, parse_semver called the installed copy 3.0.0, so the
-- first release tagged 3.0.anything would have told EVERY user an update was
-- available -- permanently, with no way to make the notice go away. It has
-- never fired only because no GitHub release exists yet. deploy.sh now refuses
-- to publish when this does not match the version being released, so the drift
-- cannot come back silently.
local CURRENT_VERSION   = "3.0.15"
local POLL_INTERVAL     = 5.0        -- seconds between heartbeat polls
local HEARTBEAT_TIMEOUT = 2.0        -- seconds of stale counter = Swing gone

-- gmem slots
local GS_SWING_ALIVE       = 1711
local GS_UPDATE_REQUEST    = 1712
local GS_UPDATE_STATE      = 1713
local GS_LATEST_VER_BASE   = 1714  -- 5 slots: 1714–1718

---------------------------------------------------------------------------
-- SELF-REGISTER AS STARTUP ACTION (one-time).
--
-- The block written to __startup.lua is SELF-CLEANING: when the script
-- file is removed (e.g. via ReaPack uninstall), the block detects that
-- its registered command ID can no longer be resolved, strips itself
-- out of __startup.lua, and clears the registered_v3 ExtState so a
-- future reinstall registers fresh. No manual cleanup needed.
--
-- Bumped registered_v2 -> registered_v3 to force existing installs
-- (which have the old single-line format) to re-register and pick up
-- the new self-cleaning block on next script run.
---------------------------------------------------------------------------
-- Rewrite __startup.lua via tmp-file + rename instead of truncating in place.
-- The file is SHARED -- other vendors' startup lines live in it too -- so a
-- crash or full disk mid-write must never be able to eat it. Returns true
-- only once the new content is fully on disk under `path`. Global, not local:
-- the same helper rides in every EON self-registering script, and in the Kit
-- Bridge a top-level local would count against Lua's 200-local ceiling.
function eon_write_startup(path, content)
  local tmp, prev = path .. ".eon-tmp", path .. ".eon-prev"
  -- A read-only __startup.lua is the user's call. Windows would still let the
  -- renames below replace it -- and strand a read-only .eon-prev that blocks
  -- every later rewrite -- so refuse up front.
  local ro = io.open(path, "r")
  if ro then ro:close(); local ap = io.open(path, "a"); if not ap then return false end; ap:close() end
  local f = io.open(tmp, "w")
  if not f then return false end
  local wok = f:write(content)
  local cok = f:close()
  if not wok or not cok then os.remove(tmp) return false end
  -- Windows os.rename won't overwrite, so the old file steps aside first --
  -- and steps back if the new one cannot take its place. Nothing is ever
  -- deleted before the replacement is in (2026-09-07: the old remove-then-
  -- rename left the shared file GONE whenever the rename failed, e.g. an
  -- antivirus hold on the freshly written tmp file).
  os.remove(prev)
  local had_old = os.rename(path, prev)
  if os.rename(tmp, path) then
    os.remove(prev)
    return true
  end
  if had_old then os.rename(prev, path) end
  os.remove(tmp)
  return false
end

-- ⭐ Strip one script's block from __startup.lua text, in WHOLE LINES. The file is
-- shared with other vendors. The old gsub('\n?BEGIN.-END\n?') ate the newline on
-- BOTH sides, gluing a neighbour line that had no trailing newline onto the next
-- vendor's line (a comment then swallowed their command), and a stray BEGIN with
-- no END stretched the match over foreign lines down to our real END. Here a block
-- goes only when its BEGIN line is followed by its END line with no second BEGIN
-- in between -- anything unmatched stays verbatim -- together with the one blank
-- line we write above it, so re-registering never grows the file. The v1/v2 form
-- (a bare "-- EON:<name>" line plus the line after it) goes too. Returns the text
-- and whether anything was removed. Global, and identical in all five
-- self-registering EON scripts: .dev_tests/startup_file_test.py holds them to it.
function eon_strip_startup_block(text, name)
  local B, E, OLD = "-- EON:" .. name .. " BEGIN", "-- EON:" .. name .. " END", "-- EON:" .. name
  local out, pend, skip, hit = {}, nil, false, false
  local nl = text:sub(-1) == "\n"
  for l in (nl and text or text .. "\n"):gmatch("([^\n]*)\n") do
    local k = l:gsub("\r$", "")
    if skip then
      skip, hit = false, true
    elseif pend then
      if k == E then
        if out[#out] and out[#out]:gsub("\r$", "") == "" then out[#out] = nil end
        pend, hit = nil, true
      elseif k == B then
        for _, x in ipairs(pend) do out[#out + 1] = x end
        pend = { l }
      else
        pend[#pend + 1] = l
      end
    elseif k == B then
      pend = { l }
    elseif k == OLD then
      skip = true
    else
      out[#out + 1] = l
    end
  end
  if pend then for _, x in ipairs(pend) do out[#out + 1] = x end end
  local s = table.concat(out, "\n")
  if nl and #out > 0 then s = s .. "\n" end
  return s, hit
end

-- The uninstall half of the block written into __startup.lua (the `else` branch,
-- reached once the script's command no longer resolves). It removes the block by
-- the same whole-line rule as eon_strip_startup_block -- inlined, because nothing
-- of ours is left to call -- skips a read-only file, and clears the flag.
function eon_startup_selfclean_src(name, section, key)
  return
    "  local p=reaper.GetResourcePath()..\"/Scripts/__startup.lua\"\n" ..
    "  local f=io.open(p,'r'); local c=f and f:read('*a'); if f then f:close() end\n" ..
    "  local w=c and io.open(p,'a'); if w then w:close()\n" ..
    -- Markers assembled at run time: the literal "-- EON:<name> END" must never appear
    -- INSIDE the block, or an older copy's lazy BEGIN.-END match would stop there and
    -- leave half a block (broken Lua) behind.
    "    local N='-- EON:'..'" .. name .. "'; local B,E,o,q=N..' BEGIN',N..' END',{}\n" ..
    "    local nl=c:sub(-1)=='\\n'\n" ..
    "    for l in (nl and c or c..'\\n'):gmatch('([^\\n]*)\\n') do local k=l:gsub('\\r$','')\n" ..
    "      if q then\n" ..
    "        if k==E then if o[#o] and o[#o]:gsub('\\r$','')=='' then o[#o]=nil end q=nil\n" ..
    "        elseif k==B then for _,x in ipairs(q) do o[#o+1]=x end q={l}\n" ..
    "        else q[#q+1]=l end\n" ..
    "      elseif k==B then q={l} else o[#o+1]=l end\n" ..
    "    end\n" ..
    "    if q then for _,x in ipairs(q) do o[#o+1]=x end end\n" ..
    "    c=table.concat(o,'\\n')..((nl and #o>0) and '\\n' or '')\n" ..
    "    local t,b=p..'.eon-tmp',p..'.eon-prev'; local fw=io.open(t,'w'); local ok=false\n" ..
    "    if fw then ok=fw:write(c) and true or false; if not fw:close() then ok=false end end\n" ..
    "    if ok then os.remove(b); local h=os.rename(p,b); if os.rename(t,p) then os.remove(b) elseif h then os.rename(b,p) end end\n" ..
    "    os.remove(t) end\n" ..
    "  reaper.SetExtState('" .. section .. "','" .. key .. "','',true)\n"
end

local function self_register()
  local _, script_path = reaper.get_action_context()
  local key = SCRIPT_NAME .. "_registered_v4"
  local marker = "-- EON:" .. SCRIPT_NAME

  -- Check both ExtState AND __startup.lua. If the ExtState says registered
  -- but __startup.lua is missing or doesn't contain our block, re-register.
  -- This handles the case where the installer's uninstall step (or anything
  -- else) deletes/corrupts __startup.lua without clearing the ExtState.
  if reaper.GetExtState(SCRIPT_NAME, key) == "1" then
    local res_path = reaper.GetResourcePath()
    local startup_path = res_path .. "/Scripts/__startup.lua"
    local fr = io.open(startup_path, "r")
    if fr then
      local content = fr:read("*a"); fr:close()
      if content:find(marker .. " BEGIN", 1, true) then return end  -- genuinely registered
    end
    -- ExtState stale: __startup.lua missing or our block is gone. Clear and re-register.
    reaper.SetExtState(SCRIPT_NAME, key, "", true)
  end

  -- Register in action list (so manual invocation still works)
  local cmd_id = reaper.AddRemoveReaScript(true, 0, script_path, true)
  if not cmd_id or cmd_id <= 0 then return end

  local res_path = reaper.GetResourcePath()
  local startup_path = res_path .. "/Scripts/__startup.lua"

  local existing = ""
  local fr = io.open(startup_path, "r")
  if fr then existing = fr:read("*a"); fr:close() end

  -- Strip ALL prior versions of our block so re-registration is idempotent:
  --   v3+: BEGIN...END block (new self-cleaning format)
  --   v1/v2: single-line format ("-- EON:NAME" marker + next line)
  local marker = "-- EON:" .. SCRIPT_NAME
  local had_block
  existing, had_block = eon_strip_startup_block(existing, SCRIPT_NAME)

  -- Resolve a stable command token. Named command IDs ("_RSxxxxx") survive
  -- action-list rebuilds; the raw int can change.
  local named_id = reaper.ReverseNamedCommandLookup(cmd_id)
  local cmd_token = named_id
    and ('reaper.NamedCommandLookup("_' .. named_id .. '")')
    or tostring(cmd_id)

  -- Self-cleaning block. When `id` resolves (script file present), runs
  -- the script as usual. When `id == 0` (file removed via ReaPack uninstall),
  -- strips this block from __startup.lua and clears the registered_v3
  -- ExtState. The cleanup runs at most once per uninstall -- once the block
  -- is gone, this code never executes again.
  local block =
    "\n" .. marker .. " BEGIN\n" ..
    "do local id=" .. cmd_token .. "\n" ..
    "if id~=0 then reaper.Main_OnCommand(id,0) else\n" ..
    eon_startup_selfclean_src(SCRIPT_NAME, SCRIPT_NAME, key) ..
    "end end\n" ..
    marker .. " END\n"

  -- Flag as registered only once the block is really on disk; a failed write
  -- leaves the ExtState clear so the next run simply retries.
  if eon_write_startup(startup_path, existing .. block) then
    reaper.SetExtState(SCRIPT_NAME, key, "1", true)
    -- Only a genuine first registration speaks: replacing an existing block (every
    -- updated install after a key bump) must not pop the console open for users.
    if not had_block then
      reaper.ShowConsoleMsg("[EON] " .. SCRIPT_NAME .. " registered as startup action (auto-cleans on uninstall).\n")
    end
  end
end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local last_heartbeat   = 0     -- last seen counter value
local last_poll_time   = 0     -- time of last heartbeat read
local swing_alive      = false
-- The fetch in flight: { final, part, deadline }, nil when idle. Replaces the
-- old `checking_update` flag, which only ever guarded a call that had already
-- finished by the time it returned (see start_update_check).
local check_job        = nil

---------------------------------------------------------------------------
-- HELPERS
---------------------------------------------------------------------------
local function gmem_read(slot)
  return reaper.gmem_read(slot)
end

local function gmem_write(slot, val)
  reaper.gmem_write(slot, val)
end

-- ⚠ FIVE CELLS, AND THEY CANNOT GROW: 1719 is GS_MEDIA_EXPLORER_OPEN and 1720
-- starts the 512-cell pad-name block, so the band is boxed in on both sides and
-- widening it means relocating it. Nothing reads it today -- the JSFX declares
-- the constant and never touches it; the face shows an UPDATE button off
-- GS_UPDATE_STATE and never draws a number -- so this is write-only.
-- A version that does not fit is written as EMPTY rather than truncated: "3.0.10"
-- cut to five characters reads "3.0.1", which is not a shorter version, it is a
-- DIFFERENT and older one, and the first thing to ever draw this band would show
-- it as fact. Empty means "unknown", which any future reader can handle honestly.
-- ⛔ Relocate the band (gmem auditor) before drawing it anywhere.
local function write_version_string(str)
  local fits = #str <= 5
  for i = 0, 4 do
    local ch = (fits and i < #str) and string.byte(str, i + 1) or 0
    gmem_write(GS_LATEST_VER_BASE + i, ch)
  end
  return fits
end

-- Hand the URL to the OS opener WITHOUT building a shell command line.
-- CF_ShellExecute (SWS -- a required dependency) takes the string verbatim,
-- so there is nothing to quote or escape. The os.execute fallback exists only
-- for an install missing SWS, and only ever sees URLs that passed the
-- allowlist: https-only, characters restricted to the URL-safe set -- no
-- quotes, spaces, $, backticks or other shell metacharacters to break out
-- with. (The only caller feeds it html_url parsed from the GitHub API with a
-- quote-free capture, so the gate is belt-and-braces, not load-bearing.)
local function open_url(url)
  if type(url) ~= "string"
     or not url:match("^https://[%w%.%-_/#%%%?=&:+~@]+$") then
    return
  end
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(url)
    return
  end
  local os_name = reaper.GetOS()
  if os_name:match("Win") then
    os.execute('start "" "' .. url .. '"')
  elseif os_name:match("OSX") or os_name:match("macOS") then
    os.execute('open "' .. url .. '"')
  else
    os.execute('xdg-open "' .. url .. '"')
  end
end

---------------------------------------------------------------------------
-- UPDATE CHECK (curl detached, answer collected from the defer loop)
---------------------------------------------------------------------------
-- Failure diagnostics are console-GATED. Both check triggers are automatic
-- (Swing writes GS_UPDATE_REQUEST=1 on first load and again on project load;
-- there is no manual "check for updates" action anywhere in the UI), so an
-- ungated ShowConsoleMsg would pop the console unprompted for every customer
-- who is offline -- and, until the first GitHub Release exists, for everyone.
-- Same convention as EON_Swing/load_debug:
--   reaper.SetExtState("EON_Swing", "update_debug", "1", false)
local function update_dbg(line)
  if reaper.GetExtState("EON_Swing", "update_debug") == "1" then
    reaper.ShowConsoleMsg(line)
  end
end

-- ⚠⚠ THIS USED TO BLOCK REAPER. `ExecProcess(cmd, 6000)` does not return until
-- the process ends or the timeout expires -- a POSITIVE timeout is the waiting
-- form -- so the header above saying "non-blocking" described the intent and not
-- the call. Both triggers are automatic (Swing asks on first load and on every
-- project load), so an offline machine, or one waiting on a dead DNS server, ate
-- a multi-second freeze every time a project opened, with curl's own -m 5 as the
-- only bound. Nobody would connect that pause to an update check.
--
-- Now: launch curl detached and read the answer from the defer loop. curl writes
-- to a .part file and the shell renames it only on success, so the final file
-- EXISTING is the completion signal -- with a detached process there is nothing
-- else to wait on, and a half-written file would parse as garbage. Same
-- write-then-rename shape as the sidecar and the startup file.
local function update_tmp_path()
  local dir = reaper.GetResourcePath() .. "/Data/EON_Swing"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. "/update_check.json"
end

local function start_update_check()
  if check_job then return end

  local final = update_tmp_path()
  local part  = final .. ".part"
  -- Both paths go into a shell line. A quote in the resource path would break
  -- out of it, so refuse rather than build something unpredictable -- the check
  -- is a nicety, a mangled command line is not worth it.
  if final:find('"', 1, true) or final:find("'", 1, true) then
    update_dbg("[EON] Update check skipped: resource path contains a quote.\n")
    gmem_write(GS_UPDATE_STATE, 0)
    return
  end
  os.remove(final)
  os.remove(part)
  gmem_write(GS_UPDATE_STATE, 1) -- checking

  local cmd
  if reaper.GetOS():match("Win") then
    cmd = ('cmd /c curl -s -m 5 -o "%s" "%s" && move /Y "%s" "%s"')
      :format(part, UPDATE_URL, part, final)
  else
    cmd = ("/bin/sh -c 'curl -s -m 5 -o \"%s\" \"%s\" && mv -f \"%s\" \"%s\"'")
      :format(part, UPDATE_URL, part, final)
  end
  -- -2: start it and return immediately, no console window. Anything else here
  -- puts the wait back.
  reaper.ExecProcess(cmd, -2)
  check_job = { final = final, part = part,
                deadline = reaper.time_precise() + 12 }
end

-- The other half, called every defer tick. Every exit path clears check_job and
-- leaves a state behind, so a check can never wedge the script.
local function finish_update_check(retval)
  if retval and retval ~= "" then
    -- GitHub Releases API JSON structure (only the fields we care about):
    --   {"tag_name":"2.1.3","html_url":"https://github.com/.../releases/tag/2.1.3", ...}
    -- tag_name may start with "v" depending on how the release was tagged;
    -- strip it before comparison.
    local ver = retval:match('"tag_name"%s*:%s*"([^"]+)"')
    local dl  = retval:match('"html_url"%s*:%s*"([^"]+)"')
    if ver then
      ver = ver:gsub("^v", "")
    end

    if ver then
      -- Empty rather than truncated when it does not fit (see the function).
      if not write_version_string(ver) then
        update_dbg("[EON] Update check: '" .. ver ..
          "' does not fit the 5-char version band -- left empty.\n")
      end
      -- Compare with current version. Numeric semver compare so we don't
      -- false-fire "available" when the user is AHEAD of GitHub (e.g. a
      -- dev build with a higher version than the latest release).
      local function parse_semver(v)
        local a, b, c = v:match("^(%d+)%.(%d+)%.?(%d*)")
        return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
      end
      local ga, gb, gc = parse_semver(ver)
      local la, lb, lc = parse_semver(CURRENT_VERSION)
      local github_newer = (ga > la) or
                           (ga == la and gb > lb) or
                           (ga == la and gb == lb and gc > lc)
      if github_newer then
        gmem_write(GS_UPDATE_STATE, 3) -- available
        if dl then
          reaper.SetExtState(SCRIPT_NAME, "download_url", dl, false)
        end
      else
        gmem_write(GS_UPDATE_STATE, 2) -- up-to-date (or ahead)
      end
    else
      -- Common bodies at this point: (a) 404 with {"message":"Not Found"}
      -- when no releases have been published, (b) rate-limit responses,
      -- (c) captive-portal HTML on public wifi. A truncated snippet
      -- distinguishes all three at a glance -- vs. bare state 0, which is
      -- indistinguishable from a network error. Debug-gated (see update_dbg).
      local msg  = retval:match('"message"%s*:%s*"([^"]+)"')
      local snip = retval:sub(1, 160):gsub("[\r\n]+", " ")
      update_dbg("[EON] Update check: no tag_name in response " ..
        (msg and ("(" .. msg .. ") ") or "") ..
        "-- " .. snip .. (retval:len() > 160 and "..." or "") .. "\n")
      gmem_write(GS_UPDATE_STATE, 0) -- failed → idle
    end
  else
    -- Network offline, curl absent, or the 5s timeout expired. This is the
    -- NORMAL state on an offline studio machine, so it must stay silent for
    -- customers -- debug-gated trail only.
    update_dbg("[EON] Update check: no response from " .. UPDATE_URL ..
      " (network offline, curl missing, or timed out).\n")
    gmem_write(GS_UPDATE_STATE, 0) -- network error → idle
  end
end

-- Poll for the answer. Runs every tick whether or not Swing is alive: a check
-- that started while it was there should finish and clean up after itself.
local function poll_update_check()
  if not check_job then return end
  local f = io.open(check_job.final, "rb")
  if f then
    local body = f:read("a") or ""
    f:close()
    os.remove(check_job.final)
    check_job = nil
    finish_update_check(body)
    return
  end
  if reaper.time_precise() > check_job.deadline then
    -- curl never produced a complete file: offline, no curl, DNS hanging past
    -- its own -m 5, or the shell did not take the command line. All of them are
    -- silent-and-idle, which is also what happens if ExecProcess's detached form
    -- is unavailable -- so the worst case of this whole path is "no answer",
    -- never a freeze.
    os.remove(check_job.part)
    os.remove(check_job.final)
    check_job = nil
    update_dbg("[EON] Update check: nothing came back within 12s from " ..
      UPDATE_URL .. " (offline, curl missing, or the fetch never started).\n")
    gmem_write(GS_UPDATE_STATE, 0)
  end
end

---------------------------------------------------------------------------
-- HANDLE REQUESTS FROM SWING
---------------------------------------------------------------------------
local function handle_requests()
  local req = gmem_read(GS_UPDATE_REQUEST)

  if req == 1 then
    -- Check for updates
    gmem_write(GS_UPDATE_REQUEST, 0)
    start_update_check()

  elseif req == 2 then
    -- Open download URL
    gmem_write(GS_UPDATE_REQUEST, 0)
    local url = reaper.GetExtState(SCRIPT_NAME, "download_url")
    if url and url ~= "" then
      open_url(url)
    end
  end
end

---------------------------------------------------------------------------
-- HEARTBEAT DETECTION
---------------------------------------------------------------------------
local function check_heartbeat()
  local now = reaper.time_precise()
  if now - last_poll_time < POLL_INTERVAL then return end
  last_poll_time = now

  local beat = gmem_read(GS_SWING_ALIVE)

  if beat ~= last_heartbeat and beat > 0 then
    -- Counter changed → Swing is alive
    last_heartbeat = beat
    if not swing_alive then
      swing_alive = true
      -- Swing just appeared — reset update state
      gmem_write(GS_UPDATE_STATE, 0)
    end
  elseif beat == last_heartbeat then
    -- Counter stale → Swing removed or no Swing
    if swing_alive then
      swing_alive = false
    end
  end
end

---------------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------------
local function main()
  check_heartbeat()
  poll_update_check()

  if swing_alive then
    handle_requests()
  end

  reaper.defer(main)
end

---------------------------------------------------------------------------
-- INIT
---------------------------------------------------------------------------
self_register()
reaper.gmem_attach(GMEM_SECTION)
reaper.defer(main)
reaper.atexit(function()
  -- Clean exit — no persistent state to clear
end)
