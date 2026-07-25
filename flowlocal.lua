-- flowlocal.lua — FlowLocal: 100% local hold-to-talk dictation for macOS
-- Hold the hotkey anywhere, speak, release → cleaned text appears at your cursor.
-- Pipeline: ffmpeg (avfoundation) → resident whisper-server (whisper.cpp) → post-process → paste.

local M = {}

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local HOME = os.getenv("HOME")

local CONFIG = {
  -- Hotkey: which modifier to hold. Choose "rightCmd", "leftCmd", "rightOption", "fn".
  hotkey = "rightCmd",

  -- Speech engine
  whisperServer = "/opt/homebrew/bin/whisper-server",
  whisperCli    = "/opt/homebrew/bin/whisper-cli",       -- batch fallback
  model         = HOME .. "/.flowlocal/models/ggml-small.en.bin",
  fallbackModel = HOME .. "/.flowlocal/models/ggml-base.en.bin",
  port          = 8765,
  language      = "en",

  -- Audio capture
  ffmpeg            = "/opt/homebrew/bin/ffmpeg",
  audioDevice       = ":default",   -- the leading colon is required (no video, default audio)
  maxRecordSeconds  = 600,
  minRecordSeconds  = 0.35,         -- shorter than this → treated as silence, nothing inserted

  -- Insertion: "paste" (clipboard + Cmd-V) or "type" (keystroke simulation, for
  -- clipboard-manager users who don't want their history polluted).
  insertMethod        = "paste",
  pasteDelay          = 0.05,       -- seconds between setting the clipboard and Cmd-V
  clipboardRestoreDelay = 0.25,     -- seconds after Cmd-V before the old clipboard is restored

  -- Post-processing
  fillers = { "um", "uh", "uhm", "erm", "hmm", "mhm", "you know", "i mean", "like, like" },

  -- Frontmost apps that get RAW text: no sentence-casing, no terminal punctuation.
  -- Matched against the app name and the bundle ID.
  rawApps = {
    "Terminal", "iTerm2", "Ghostty", "Code", "Cursor", "Alacritty", "kitty", "WezTerm", "Warp",
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", -- Cursor
  },

  -- Optional LLM polish (opt-in, adds seconds). Say this word first to route the
  -- rest of the transcript through the hook script.
  polishTrigger = "polish",
  polishHook    = HOME .. "/.flowlocal/hooks/polish.sh",
  polishTimeout = 60,

  -- Double-tap the hotkey to latch into hands-free recording; tap again to finish.
  doubleTapSeconds = 0.35,   -- max gap between the two taps
  tapMaxSeconds    = 0.25,   -- a hold shorter than this is a "tap", never a dictation

  sounds = true,
  dictionary = HOME .. "/.flowlocal/dictionary.txt",
  logDir     = HOME .. "/.flowlocal/logs",
  workDir    = "/tmp/flowlocal",
}

M.CONFIG = CONFIG

--------------------------------------------------------------------------------
-- Modifier key table: keyCode + device-specific flag bit (so left/right differ)
--------------------------------------------------------------------------------

local KEYS = {
  leftCmd     = { keyCode = 55, mask = 0x00000008 },
  rightCmd    = { keyCode = 54, mask = 0x00000010 },
  leftOption  = { keyCode = 58, mask = 0x00000020 },
  rightOption = { keyCode = 61, mask = 0x00000040 },
  leftShift   = { keyCode = 56, mask = 0x00000002 },
  rightShift  = { keyCode = 60, mask = 0x00000004 },
  fn          = { keyCode = 63, mask = 0x00800000 },
}

--------------------------------------------------------------------------------
-- Paths / logging
--------------------------------------------------------------------------------

local WAV        = CONFIG.workDir .. "/rec.wav"
local POLISH_IN  = CONFIG.workDir .. "/polish_in.txt"
local LOG        = CONFIG.logDir .. "/flowlocal.log"
local SERVER_LOG = CONFIG.logDir .. "/whisper-server.log"

os.execute(string.format("/bin/mkdir -p %q %q", CONFIG.workDir, CONFIG.logDir))

local function now() return hs.timer.secondsSinceEpoch() end
local function ms(a, b) return math.floor(((b or now()) - a) * 1000 + 0.5) end

-- Hammerspoon timers are garbage-collected if nothing holds a reference — an
-- unreferenced hs.timer.doAfter silently never fires (verified: a forced
-- collectgarbage() between scheduling and firing kills it). Every deferred
-- action here goes through these helpers, which root the timer until it runs.
local liveTimers = {}

local function after(seconds, fn)
  local key = {}
  liveTimers[key] = hs.timer.doAfter(seconds, function()
    liveTimers[key] = nil
    fn()
  end)
  return liveTimers[key]
end

-- fn() returns true when it wants the repeat to stop.
local function every(seconds, fn)
  local key = {}
  liveTimers[key] = hs.timer.doEvery(seconds, function()
    if fn() then
      local t = liveTimers[key]
      if t then t:stop() end
      liveTimers[key] = nil
    end
  end)
  return liveTimers[key]
end

local function logEvent(kind, tbl)
  tbl = tbl or {}
  tbl.event = kind
  tbl.ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local ok, line = pcall(hs.json.encode, tbl)
  if not ok then line = string.format('{"event":%q,"encode_error":true}', kind) end
  local f = io.open(LOG, "a")
  if f then f:write(line, "\n"); f:close() end
  print("[flowlocal] " .. line)
end

--------------------------------------------------------------------------------
-- Menubar indicator
--------------------------------------------------------------------------------

local ICONS = { idle = "◌", recording = "🔴", latched = "🔴•", working = "⋯" }
local menubar = nil

local function serverRunning()
  local out = hs.execute(string.format("/usr/bin/pgrep -f 'whisper-server .*--port %d' | head -1", CONFIG.port))
  return (out or ""):match("%d+") ~= nil
end

local function buildMenu()
  return {
    { title = "whisper-server: " .. (serverRunning() and "running" or "stopped"), disabled = true },
    { title = "-" },
    { title = "Restart speech server", fn = function() M.restartServer() end },
    { title = "Open log", fn = function() hs.execute("/usr/bin/open -a Console " .. LOG) end },
    { title = "Reload Hammerspoon config", fn = function() hs.reload() end },
  }
end

local function setIcon(state)
  if not menubar then return end
  menubar:setTitle(ICONS[state] or ICONS.idle)
end

--------------------------------------------------------------------------------
-- Speech server management
--------------------------------------------------------------------------------

-- NB: probe with GET /. A POST to /inference without a file makes whisper-server
-- log an error and never reply, so it is useless as a health check.
local function serverHealthy()
  local out = hs.execute(string.format(
    "/usr/bin/curl -s -o /dev/null -m 2 -w '%%{http_code}' http://127.0.0.1:%d/", CONFIG.port))
  local code = tonumber((out or ""):match("%d+") or "0") or 0
  return code > 0   -- any HTTP response means it is past model load and serving
end
M._serverHealthy = serverHealthy

function M.startServer()
  if serverRunning() then
    logEvent("server_already_running", { port = CONFIG.port })
    return
  end
  local modelPath = CONFIG.model
  if not hs.fs.attributes(modelPath) then
    if hs.fs.attributes(CONFIG.fallbackModel) then
      modelPath = CONFIG.fallbackModel
    else
      logEvent("server_no_model", { model = CONFIG.model })
      hs.alert.show("FlowLocal: no whisper model found — run ~/.flowlocal/install.sh")
      return
    end
  end
  local cmd = string.format(
    "/usr/bin/nohup %q -m %q --host 127.0.0.1 --port %d -l %s -t 4 >> %q 2>&1 &",
    CONFIG.whisperServer, modelPath, CONFIG.port, CONFIG.language, SERVER_LOG)
  hs.execute(cmd)
  logEvent("server_starting", { model = modelPath, port = CONFIG.port })
end

function M.stopServer()
  hs.execute(string.format("/usr/bin/pkill -f 'whisper-server .*--port %d'", CONFIG.port))
  logEvent("server_stopped", { port = CONFIG.port })
end

function M.restartServer()
  M.stopServer()
  after(0.6, function()
    M.startServer()
    hs.alert.show("FlowLocal: speech server restarting")
  end)
end

--------------------------------------------------------------------------------
-- Personal dictionary
--------------------------------------------------------------------------------

-- dictionary.txt holds two kinds of line:
--   Term                     → biases decoding, and forces canonical casing
--   heard text => Term       → a literal rewrite, for homophones the acoustics
--                              cannot distinguish (e.g. "Raptor" vs "Rappter")
local function readDictionary()
  local dict = { terms = {}, subs = {} }
  local f = io.open(CONFIG.dictionary, "r")
  if not f then return dict end
  for line in f:lines() do
    local t = line:gsub("^%s+", ""):gsub("%s+$", "")
    if t ~= "" and not t:match("^#") then
      local from, to = t:match("^(.-)%s*=>%s*(.+)$")
      if from and from ~= "" then
        table.insert(dict.subs, { from = from, to = to })
        table.insert(dict.terms, to)
      else
        table.insert(dict.terms, t)
      end
    end
  end
  f:close()
  return dict
end

local function dictionaryPrompt(dict)
  local seen, uniq = {}, {}
  for _, t in ipairs(dict.terms or {}) do
    if not seen[t] then seen[t] = true; table.insert(uniq, t) end
  end
  if #uniq == 0 then return nil end
  return table.concat(uniq, ", ") .. "."
end

--------------------------------------------------------------------------------
-- Post-processing
--------------------------------------------------------------------------------

-- Build a case-insensitive Lua pattern for a literal phrase.
local function ciPattern(word)
  local out = {}
  for ch in word:gmatch(".") do
    if ch:match("%a") then
      out[#out + 1] = "[" .. ch:lower() .. ch:upper() .. "]"
    elseif ch == " " then
      out[#out + 1] = "%s+"
    else
      out[#out + 1] = "%" .. ch   -- escape everything non-alpha
    end
  end
  return table.concat(out)
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function isRawApp(appName, bundleID)
  for _, a in ipairs(CONFIG.rawApps) do
    if a == appName or a == bundleID then return true end
  end
  return false
end

-- Returns cleaned text, or "" if the transcript held no speech.
local function postProcess(raw, raw_mode, dict)
  dict = dict or {}
  local dictTerms, dictSubs = dict.terms or {}, dict.subs or {}
  local s = raw or ""

  -- whisper's non-speech annotations
  s = s:gsub("%[[^%]]*%]", " ")           -- [BLANK_AUDIO], [Music], [ Silence ]
  s = s:gsub("%*[^%*]*%*", " ")           -- *laughs*
  s = trim(s)
  if s:match("^%b()$") then s = "" end    -- the whole thing was "(buzzing)"

  -- fillers
  for _, w in ipairs(CONFIG.fillers) do
    s = s:gsub("%f[%w]" .. ciPattern(w) .. "%f[%W]", "")
  end

  -- tidy the wreckage the filler removal leaves behind
  s = s:gsub("%s+", " ")
  s = s:gsub("%s+([,%.!%?;:])", "%1")     -- " ," → ","
  for _ = 1, 3 do
    s = s:gsub("([,;:])%s*[,;:]", "%1")   -- ", ," → ","
  end
  s = s:gsub("^[%s,;:%.%-]+", "")         -- leading orphan punctuation
  s = trim(s)

  -- nothing but punctuation left → no speech
  if s == "" or not s:match("%w") then return "" end

  -- explicit homophone rewrites, most specific first
  table.sort(dictSubs, function(a, b) return #a.from > #b.from end)
  for _, sub in ipairs(dictSubs) do
    s = s:gsub("%f[%w]" .. ciPattern(sub.from) .. "%f[%W]", function() return sub.to end)
  end

  -- Raw mode must UNDO whisper's formatting, not merely decline to add to it:
  -- the model always sentence-cases and terminal-punctuates, which is wrong in a
  -- shell or an editor. Runs before the dictionary fixup so canonical casing wins.
  if raw_mode then
    s = s:gsub("[%.!%?]+$", "")
    -- lowercase the first letter only when the first word is plain Capitalised
    -- ("Get" → "get"); leave CamelCase and ACRONYMS alone.
    local first = s:match("^(%a+)")
    if first and first:sub(2) == first:sub(2):lower() then
      s = s:gsub("^%a", string.lower)
    end
  end

  -- personal dictionary: force canonical spelling/casing
  for _, term in ipairs(dictTerms) do
    s = s:gsub("%f[%w]" .. ciPattern(term) .. "%f[%W]", function() return term end)
  end

  if not raw_mode then
    -- sentence case
    s = s:gsub("^(%a)", function(c) return c:upper() end)
    s = s:gsub("([%.!%?]%s+)(%a)", function(p, c) return p .. c:upper() end)
    -- terminal punctuation
    if s:match("[%w%)%\"']$") then s = s .. "." end
  end

  return s
end

M._postProcess = postProcess   -- exposed for the test harness

--------------------------------------------------------------------------------
-- Insertion
--------------------------------------------------------------------------------

local function insertText(text)
  local t0 = now()
  if CONFIG.insertMethod == "type" then
    hs.eventtap.keyStrokes(text)
    return ms(t0)
  end
  local original = hs.pasteboard.getContents()
  hs.pasteboard.setContents(text)
  after(CONFIG.pasteDelay, function()
    hs.eventtap.keyStroke({ "cmd" }, "v", 0)
    after(CONFIG.clipboardRestoreDelay, function()
      if original ~= nil then hs.pasteboard.setContents(original) end
    end)
  end)
  return ms(t0)
end

--------------------------------------------------------------------------------
-- Transcription
--------------------------------------------------------------------------------

local function wavSeconds(path)
  local attr = hs.fs.attributes(path)
  if not attr then return 0 end
  return math.max(0, (attr.size - 44) / 32000)   -- 16kHz mono s16le
end

local function parseServerJSON(out)
  local ok, decoded = pcall(hs.json.decode, out or "")
  if ok and type(decoded) == "table" and type(decoded.text) == "string" then
    return decoded.text
  end
  return nil
end

-- Fallback: one-shot whisper-cli with the fast model.
local function transcribeCli(prompt, cb)
  local args = { "-m", CONFIG.fallbackModel, "-f", WAV, "-nt", "-np", "-l", CONFIG.language }
  if prompt then table.insert(args, "--prompt"); table.insert(args, prompt) end
  hs.task.new(CONFIG.whisperCli, function(code, out, err)
    if code ~= 0 then
      logEvent("cli_failed", { code = code, err = (err or ""):sub(1, 400) })
      cb(nil)
    else
      cb(out or "")
    end
  end, args):start()
end

local function transcribe(prompt, cb)
  local args = {
    "-s", "-m", "30",
    string.format("http://127.0.0.1:%d/inference", CONFIG.port),
    "-F", "file=@" .. WAV,
    "-F", "temperature=0",
    "-F", "response_format=json",
  }
  if prompt then
    table.insert(args, "--form-string"); table.insert(args, "prompt=" .. prompt)
  end
  hs.task.new("/usr/bin/curl", function(code, out, err)
    local text = (code == 0) and parseServerJSON(out) or nil
    if text then return cb(text, "server") end
    logEvent("server_transcribe_failed", {
      code = code, out = (out or ""):sub(1, 300), err = (err or ""):sub(1, 300),
    })
    M.startServer()   -- bring it back for next time
    transcribeCli(prompt, function(t) cb(t, "cli") end)
  end, args):start()
end

--------------------------------------------------------------------------------
-- Optional LLM polish
--------------------------------------------------------------------------------

local function maybePolish(text, cb)
  local trigger = CONFIG.polishTrigger
  local rest = text:match("^%s*" .. ciPattern(trigger) .. "%f[%W][%s,%.:;!%-]*(.*)$")
  if not rest or not hs.fs.attributes(CONFIG.polishHook) then return cb(text, false) end
  if trim(rest) == "" then return cb("", false) end

  local f = io.open(POLISH_IN, "w")
  if not f then return cb(rest, false) end
  f:write(rest); f:close()

  setIcon("working")
  local t0 = now()
  hs.task.new("/bin/sh", function(code, out, err)
    local polished = trim(out or "")
    if code == 0 and polished ~= "" then
      logEvent("polish_ok", { polish_ms = ms(t0) })
      cb(polished, true)
    else
      logEvent("polish_failed", { code = code, err = (err or ""):sub(1, 400), polish_ms = ms(t0) })
      cb(rest, false)   -- degrade to the unpolished text rather than lose the dictation
    end
  end, { "-c", string.format("%q %q", CONFIG.polishHook, POLISH_IN) }):start()
end

--------------------------------------------------------------------------------
-- Recording state machine
--------------------------------------------------------------------------------

local state = {
  mode = "idle",        -- idle | recording | latched | working
  task = nil,
  downAt = 0,
  startedAt = 0,
  deviceReadyAt = nil,
  lastTapAt = 0,
  ignoreNextUp = false,
  app = nil,
  bundle = nil,
  latchArmed = false,
}

local function playSound(name)
  if not CONFIG.sounds then return end
  local s = hs.sound.getByName(name)
  if s then s:volume(0.25); s:play() end
end

local function startRecording(latched)
  local app = hs.application.frontmostApplication()
  state.app = app and app:name() or ""
  state.bundle = app and app:bundleID() or ""
  state.startedAt = now()
  state.deviceReadyAt = nil
  state.dict = readDictionary()

  os.remove(WAV)

  local args = {
    "-hide_banner", "-loglevel", "info",
    "-f", "avfoundation", "-i", CONFIG.audioDevice,
    "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
    "-t", tostring(CONFIG.maxRecordSeconds),
    "-y", WAV,
  }

  -- ffmpeg MUST be launched from Hammerspoon: the child inherits Hammerspoon's
  -- TCC microphone grant, so the permission prompt attributes correctly.
  state.task = hs.task.new(CONFIG.ffmpeg, nil, function(_, _, stdErr)
    if not state.deviceReadyAt and stdErr and stdErr:match("Input #0") then
      state.deviceReadyAt = now()
      playSound("Pop")
      setIcon(latched and "latched" or "recording")
    end
    return true
  end, args)
  state.task:start()

  state.mode = latched and "latched" or "recording"
  setIcon(state.mode)
  logEvent("record_start", { app = state.app, latched = latched or false })
end

-- Everything that happens between "the WAV is on disk" and "text is inserted".
-- Shared by the live hotkey path and by M.dryRun(), so a dry run exercises the
-- real code rather than a copy of it.
-- ctx = { app, bundle, dict, releasedAt, startedAt, deviceReadyAt, exitMs, dryRun }
local function runPipeline(ctx)
  local finish = function(final, extra)
    state.mode = "idle"; setIcon("idle")
    if ctx.onDone then ctx.onDone(final, extra) end
  end

  local dur = wavSeconds(WAV)
  if dur < CONFIG.minRecordSeconds then
    logEvent("silence_skipped", { wav_seconds = dur, reason = "too_short", dry_run = ctx.dryRun })
    return finish("", { reason = "too_short" })
  end

  local asr0 = now()
  transcribe(dictionaryPrompt(ctx.dict), function(rawText, engine)
    local asrMs = ms(asr0)
    if not rawText then
      logEvent("transcribe_gave_up", { asr_ms = asrMs, dry_run = ctx.dryRun })
      return finish("", { reason = "asr_failed" })
    end

    maybePolish(rawText, function(text, polished)
      local post0 = now()
      local raw_mode = isRawApp(ctx.app, ctx.bundle)
      local final = postProcess(text, raw_mode, ctx.dict)
      local postMs = ms(post0)

      if final == "" then
        logEvent("silence_skipped", {
          wav_seconds = dur, reason = "no_speech", raw = (rawText or ""):sub(1, 120),
          asr_ms = asrMs, engine = engine, dry_run = ctx.dryRun,
        })
        return finish("", { reason = "no_speech", raw = rawText })
      end

      if not ctx.dryRun then insertText(final); playSound("Tink") end

      logEvent(ctx.dryRun and "dry_run" or "dictation", {
        app = ctx.app, bundle = ctx.bundle, raw_mode = raw_mode, engine = engine,
        polished = polished,
        hold_seconds = ctx.startedAt and tonumber(string.format("%.2f", ctx.releasedAt - ctx.startedAt)) or nil,
        wav_seconds = tonumber(string.format("%.2f", dur)),
        mic_open_ms = ctx.deviceReadyAt and ms(ctx.startedAt, ctx.deviceReadyAt) or nil,
        ffmpeg_exit_ms = ctx.exitMs,
        asr_ms = asrMs,
        post_ms = postMs,
        total_ms = ms(ctx.releasedAt),   -- key-release → text inserted
        chars = #final,
        raw = rawText,
        text = final,
      })
      finish(final, { engine = engine, polished = polished, asr_ms = asrMs, total_ms = ms(ctx.releasedAt) })
    end)
  end)
end

-- opts (optional, test-only): { dryRun = true, onDone = fn } suppresses insertion.
local function finishRecording(discard, opts)
  opts = opts or {}
  local task = state.task
  local releasedAt = now()
  local wasApp, wasBundle = state.app, state.bundle
  local dict = state.dict or {}
  local startedAt, deviceReadyAt = state.startedAt, state.deviceReadyAt

  state.task = nil
  state.mode = "working"
  setIcon(discard and "idle" or "working")

  if not task then state.mode = "idle"; setIcon("idle"); return end

  local pid = task:pid()
  local function afterExit()
    if discard then
      state.mode = "idle"; setIcon("idle")
      return
    end
    runPipeline({
      app = wasApp, bundle = wasBundle, dict = dict,
      releasedAt = releasedAt, startedAt = startedAt, deviceReadyAt = deviceReadyAt,
      exitMs = ms(releasedAt),
      dryRun = opts.dryRun, onDone = opts.onDone,
    })
  end

  if pid then
    hs.execute("/bin/kill -INT " .. pid)
    -- ffmpeg finalizes the WAV header on SIGINT; poll for the process to be gone.
    local waited = 0
    every(0.01, function()
      waited = waited + 0.01
      if not task:isRunning() or waited > 1.0 then
        afterExit()
        return true
      end
      return false
    end)
  else
    afterExit()
  end
end

--------------------------------------------------------------------------------
-- Hotkey eventtap
--------------------------------------------------------------------------------

local function flagBitSet(flags, mask)
  return (math.floor(flags) // mask) % 2 == 1
end

local tap = nil

local function handleFlags(e)
  local key = KEYS[CONFIG.hotkey]
  if not key then return false end
  if e:getKeyCode() ~= key.keyCode then return false end

  local raw = e:getRawEventData()
  local flags = (raw and raw.CGEventData and raw.CGEventData.flags) or 0
  local down = flagBitSet(flags, key.mask)
  local t = now()

  if down then
    state.downAt = t
    if state.mode == "latched" then
      -- a tap while latched ends the hands-free dictation
      state.ignoreNextUp = true
      finishRecording(false)
    elseif state.mode == "idle" then
      state.latchArmed = (t - state.lastTapAt) < CONFIG.doubleTapSeconds
      startRecording(false)
    end
  else
    if state.ignoreNextUp then
      state.ignoreNextUp = false
      state.lastTapAt = t
      return false
    end
    if state.mode ~= "recording" then return false end

    local held = t - state.downAt
    if held < CONFIG.tapMaxSeconds then
      -- a tap, not a dictation: throw the clip away
      if state.latchArmed then
        finishRecording(true)
        state.latchArmed = false
        after(0.05, function()
          startRecording(true)
          hs.alert.show("FlowLocal: hands-free — tap to finish", 1)
        end)
      else
        finishRecording(true)
      end
      state.lastTapAt = t
    else
      state.latchArmed = false
      finishRecording(false)
    end
  end
  return false
end

--------------------------------------------------------------------------------
-- Test hooks (used by tools/dryrun.sh via the `hs` CLI)
--------------------------------------------------------------------------------

M._insertForTest = insertText

-- Post-process a transcript exactly as it would be for a given frontmost app.
function M._processFor(text, appName)
  return postProcess(text, isRawApp(appName or "", appName or ""), readDictionary())
end

-- Exercise the REAL capture path — ffmpeg spawn, SIGINT, WAV finalisation — and
-- then the pipeline, without needing the hotkey. Nothing is inserted.
function M.micTest(seconds, appName, outFile)
  outFile = outFile or (CONFIG.workDir .. "/mictest_result.txt")
  os.remove(outFile)
  startRecording(false)
  if appName then state.app = appName; state.bundle = appName end
  after(seconds or 3, function()
    finishRecording(false, {
      dryRun = true,
      onDone = function(final, extra)
        local f = io.open(outFile, "w"); f:write(final or ""); f:close()
        local m = io.open(outFile .. ".meta", "w"); m:write(hs.json.encode(extra or {})); m:close()
      end,
    })
  end)
end

-- Push a pre-recorded WAV through the real ASR + polish + post-process chain.
-- Nothing is inserted; the result is written to outFile (default dryrun_result.txt).
function M.dryRun(wavPath, appName, outFile)
  outFile = outFile or (CONFIG.workDir .. "/dryrun_result.txt")
  os.remove(outFile)
  local rc = os.execute(string.format("/bin/cp %q %q", wavPath, WAV))
  if rc ~= true and rc ~= 0 then
    local f = io.open(outFile, "w"); f:write("ERROR: cannot read " .. wavPath); f:close()
    return
  end
  state.mode = "working"; setIcon("working")
  runPipeline({
    app = appName or "TextEdit", bundle = appName or "TextEdit",
    dict = readDictionary(), releasedAt = now(), dryRun = true,
    onDone = function(final, extra)
      local f = io.open(outFile, "w")
      f:write(final or "")
      f:close()
      local m = io.open(outFile .. ".meta", "w")
      m:write(hs.json.encode(extra or {}))
      m:close()
    end,
  })
end

--------------------------------------------------------------------------------
-- Start / stop
--------------------------------------------------------------------------------

function M.start()
  if not menubar then
    menubar = hs.menubar.new()
    if menubar then
      menubar:setTitle(ICONS.idle)
      menubar:setTooltip("FlowLocal — hold " .. CONFIG.hotkey .. " to dictate")
      menubar:setMenu(buildMenu)
    end
  end

  if not hs.accessibilityState() then
    hs.alert.show("FlowLocal needs Accessibility: System Settings → Privacy & Security → Accessibility → Hammerspoon", 8)
    logEvent("accessibility_missing", {})
  end

  M.startServer()

  if tap then tap:stop() end
  tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, handleFlags)
  tap:start()

  logEvent("started", { hotkey = CONFIG.hotkey, model = CONFIG.model, port = CONFIG.port })
  return M
end

function M.stop()
  if tap then tap:stop(); tap = nil end
  if menubar then menubar:delete(); menubar = nil end
end

M.start()

return M
