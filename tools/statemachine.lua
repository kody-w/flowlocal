-- Press/release state machine test. Driven from inside Hammerspoon so the taps
-- can be paced against the REAL tapMaxSeconds / doubleTapSeconds windows, which
-- shell-paced calls are far too coarse to hit.
--
-- Records state transitions only — it deliberately does not shell out, because
-- hs.execute() from inside an ipc-driven call trips "hs.ipc: already recursing".
-- The caller checks for orphaned ffmpeg processes after DONE appears.
--
-- Run: hs -c 'dofile("<this file>")' and wait for DONE in /tmp/rappvoice/statemachine.txt
local fl = require("rappvoice")
local F = "/tmp/rappvoice/statemachine.txt"
os.remove(F)

local function log(s)
  local f = io.open(F, "a"); f:write(s .. "\n"); f:close()
end
local function check(label, got, want)
  log(string.format("%-40s %-9s %s", label, got, got == want and "PASS" or ("FAIL want " .. want)))
end

-- A chain of { delay, fn } steps, rooted in a global so GC cannot collect it.
local steps, i = {}, 0
local function run()
  i = i + 1
  local s = steps[i]
  if not s then log("DONE"); return end
  _G.__smTimer = hs.timer.doAfter(s[1], function()
    local ok, err = pcall(s[2])
    if not ok then log("ERROR at step " .. i .. ": " .. tostring(err)) end
    run()
  end)
end

local TAP = 0.10    -- a hold well under tapMaxSeconds (0.25)
local GAP = 0.15    -- a gap well under doubleTapSeconds (0.35)

steps = {
  -- A. one isolated short tap: discarded, nothing inserted, straight back to idle
  { 0.1, function() fl._resetState(); log("-- A. single short tap") end },
  { 0.1, function() check("A down starts recording", fl._fakeKey(true), "recording") end },
  { TAP, function() check("A up returns to idle at once", fl._fakeKey(false), "idle") end },
  { 1.0, function() check("A still idle", fl._stateMode(), "idle") end },

  -- B. two short taps inside doubleTapSeconds: latches hands-free.
  -- This is the case that used to fail: the first tap left mode "working" while
  -- ffmpeg was reaped, so the second tap was dropped.
  { 0.6, function() fl._resetState(); log("-- B. double tap latches") end },
  { 0.1, function() check("B tap1 down", fl._fakeKey(true), "recording") end },
  { TAP, function() check("B tap1 up -> idle immediately", fl._fakeKey(false), "idle") end },
  { GAP, function() check("B tap2 down is NOT dropped", fl._fakeKey(true), "recording") end },
  { TAP, function() fl._fakeKey(false) end },
  { 1.0, function() check("B latched", fl._stateMode(), "latched") end },

  -- C. a tap while latched finishes it, and the release must be ignored
  { 0.1, function() check("C down finishes the latch", fl._fakeKey(true), "working") end },
  { TAP, function() check("C up is ignored", fl._fakeKey(false), "working") end },
  { 4.0, function() check("C settles to idle", fl._stateMode(), "idle") end },

  -- D. a hold longer than tapMaxSeconds is a real dictation, not a discarded tap
  { 0.6, function() fl._resetState(); log("-- D. long hold dictates") end },
  { 0.1, function() check("D down", fl._fakeKey(true), "recording") end },
  { 1.2, function() check("D up goes to working", fl._fakeKey(false), "working") end },
  { 4.0, function() check("D settles to idle", fl._stateMode(), "idle") end },

  -- E. two taps OUTSIDE the double-tap window must NOT latch
  { 0.6, function() fl._resetState(); log("-- E. slow taps do not latch") end },
  { 0.1, function() fl._fakeKey(true) end },
  { TAP, function() fl._fakeKey(false) end },
  { 1.0, function() fl._fakeKey(true) end },   -- 1.0s gap > doubleTapSeconds
  { TAP, function() fl._fakeKey(false) end },
  { 1.5, function() check("E did not latch", fl._stateMode(), "idle") end },
}

run()
