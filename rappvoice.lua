-- rappvoice.lua — RAPP Voice: hold-to-talk dictation for macOS.
-- Recognition is on-device (whisper.cpp on 127.0.0.1). The OPTIONAL polish
-- hook, reached by saying the trigger word first, shells out to `claude -p`
-- and therefore sends that one transcript to Anthropic.
-- Hold the hotkey anywhere, speak, release → cleaned text appears at your cursor.
-- Pipeline: ffmpeg (avfoundation) → resident whisper-server (whisper.cpp) → post-process → paste.

local M = {}

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------

local HOME = os.getenv("HOME")

-- Homebrew is at /opt/homebrew on Apple Silicon and /usr/local on Intel. These
-- were hardcoded to the former, which made every path below simply absent on an
-- Intel Mac. Resolve once, preferring the Apple Silicon location so behaviour
-- there is unchanged.
local function brew(name)
  for _, p in ipairs({ "/opt/homebrew/bin/" .. name, "/usr/local/bin/" .. name,
                       "/usr/bin/" .. name }) do
    if hs.fs.attributes(p) then return p end
  end
  return "/opt/homebrew/bin/" .. name  -- report the canonical path in errors
end

local CONFIG = {
  -- Hotkey: which modifier to hold. Choose "rightCmd", "leftCmd", "rightOption", "fn".
  hotkey = "rightCmd",

  -- Speech engine
  whisperServer = brew("whisper-server"),
  whisperCli    = brew("whisper-cli"),       -- batch fallback
  model         = HOME .. "/.rappvoice/models/ggml-small.en.bin",
  fallbackModel = HOME .. "/.rappvoice/models/ggml-base.en.bin",
  port          = 8765,
  language      = "en",

  -- Audio capture
  ffmpeg            = brew("ffmpeg"),
  audioDevice       = ":default",   -- the leading colon is required (no video, default audio)
  maxRecordSeconds  = 600,
  minRecordSeconds  = 0.35,         -- shorter than this → treated as silence, nothing inserted

  -- Insertion: "paste" (clipboard + Cmd-V) or "type" (keystroke simulation, for
  -- clipboard-manager users who don't want their history polluted).
  insertMethod        = "paste",
  pasteDelay          = 0.05,       -- seconds between setting the clipboard and Cmd-V
  clipboardRestoreDelay = 0.25,     -- seconds after Cmd-V before the old clipboard is restored

  -- Post-processing.
  -- Only true disfluencies belong here. "i mean" and "like, like" were tried and
  -- removed: they are ordinary content, and stripping them silently destroys
  -- meaning ("you know what I mean" became "What.", "i mean it sincerely" became
  -- "It sincerely."). An entry must never be a phrase you might actually say.
  fillers = { "um", "uh", "uhm", "erm", "hmm", "mhm", "you know" },

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
  polishHook    = HOME .. "/.rappvoice/hooks/polish.sh",
  polishTimeout = 60,

  -- Double-tap the hotkey to latch into hands-free recording; tap again to finish.
  doubleTapSeconds = 0.35,   -- max gap between the two taps
  tapMaxSeconds    = 0.25,   -- a hold shorter than this is a "tap", never a dictation

  sounds = true,
  dictionary = HOME .. "/.rappvoice/dictionary.txt",
  logDir     = HOME .. "/.rappvoice/logs",
  workDir    = "/tmp/rappvoice",
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
local LOG        = CONFIG.logDir .. "/rappvoice.log"
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
  print("[rappvoice] " .. line)
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
      hs.alert.show("RAPP Voice: no whisper model found — run ~/.rappvoice/install.sh")
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
    hs.alert.show("RAPP Voice: speech server restarting")
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

-- Each term is emitted TWICE as its own sentence. Measured on ggml-small.en with
-- an invented word that is a homophone of a real one:
--   "OpenRappter, RappterStore, ..."              -> "OpenRaptor"   (wrong)
--   "OpenRappter. OpenRappter. RappterStore. ..." -> "OpenRappter"  (right)
-- Weighting this way costs nothing and does not bleed terms into unrelated audio
-- (verified against speech and silence fixtures that contain none of them).
local function dictionaryPrompt(dict)
  local seen, parts = {}, {}
  for _, t in ipairs(dict.terms or {}) do
    if not seen[t] then
      seen[t] = true
      parts[#parts + 1] = t .. ". " .. t .. "."
    end
  end
  if #parts == 0 then return nil end
  return table.concat(parts, " ")
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
    elseif ch:match("%d") then
      -- Digits must stay bare. "%4" in a Lua pattern is a back-reference to
      -- capture 4, not a literal 4, so escaping it throws "invalid capture
      -- index" on any term like GPT-4 or llama3.2.
      out[#out + 1] = ch
    else
      out[#out + 1] = "%" .. ch   -- escape magic punctuation
    end
  end
  return table.concat(out)
end

-- Lua has no \b, so word boundaries use frontier patterns. A frontier only
-- matches at a word/non-word transition, so it must be omitted on an edge that
-- is already non-word — otherwise terms like "C++" or "F#" never match.
local function boundedCi(term)
  local pat = ciPattern(term)
  if term:match("^%w") then pat = "%f[%w]" .. pat end
  if term:match("%w$") then pat = pat .. "%f[%W]" end
  return pat
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
    s = s:gsub(boundedCi(w), "")
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
    s = s:gsub(boundedCi(sub.from), function() return sub.to end)
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
    s = s:gsub(boundedCi(term), function() return term end)
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

--------------------------------------------------------------------------------
-- Insertion
--------------------------------------------------------------------------------

-- skipKeystroke is for tests only: it exercises the clipboard save/restore without
-- firing a real Cmd-V, which would otherwise paste into whatever app happens to be
-- frontmost when the suite runs.
local function insertText(text, skipKeystroke)
  local t0 = now()
  if CONFIG.insertMethod == "type" then
    if not skipKeystroke then hs.eventtap.keyStrokes(text) end
    return ms(t0)
  end
  -- readAllData, not getContents: getContents() returns nil for any non-text
  -- pasteboard, so restoring from it would silently destroy a copied image or
  -- file list. readAllData/writeAllData round-trip every UTI.
  local original = hs.pasteboard.readAllData()
  hs.pasteboard.setContents(text)
  after(CONFIG.pasteDelay, function()
    if not skipKeystroke then hs.eventtap.keyStroke({ "cmd" }, "v", 0) end
    after(CONFIG.clipboardRestoreDelay, function()
      if original and next(original) then
        hs.pasteboard.clearContents()
        hs.pasteboard.writeAllData(original)
      end
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
  -- The hook shells out to an LLM. If it never returns, state.mode would stay
  -- "working" forever and the hotkey would stop responding, so the callback is
  -- fired exactly once — by whichever of task-exit or timeout happens first.
  local done, task = false, nil
  local function settle(text, polished, logKind, extra)
    if done then return end
    done = true
    extra = extra or {}
    extra.polish_ms = ms(t0)
    logEvent(logKind, extra)
    cb(text, polished)
  end

  task = hs.task.new("/bin/sh", function(code, out, err)
    local polished = trim(out or "")
    if code == 0 and polished ~= "" then
      settle(polished, true, "polish_ok")
    else
      -- degrade to the unpolished text rather than lose the dictation
      settle(rest, false, "polish_failed", { code = code, err = (err or ""):sub(1, 400) })
    end
  end, { "-c", string.format("%q %q", CONFIG.polishHook, POLISH_IN) })
  task:start()

  after(CONFIG.polishTimeout, function()
    if done then return end
    if task then task:terminate() end
    settle(rest, false, "polish_timeout", { timeout_s = CONFIG.polishTimeout })
  end)
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
      -- Post-processing builds Lua patterns out of user-supplied dictionary
      -- entries. If one of them throws, the callback chain dies with state.mode
      -- still "working" and the hotkey stops responding until a reload, so a
      -- bad entry must cost one dictation, not the whole session.
      local ok, final = pcall(postProcess, text, raw_mode, ctx.dict)
      if not ok then
        logEvent("postprocess_error", { err = tostring(final), dry_run = ctx.dryRun })
        final = trim(text or "")
      end
      local postMs = ms(post0)

      if final == "" then
        logEvent("silence_skipped", {
          wav_seconds = dur, reason = "no_speech", raw = (rawText or ""):sub(1, 120),
          asr_ms = asrMs, engine = engine, dry_run = ctx.dryRun,
        })
        return finish("", { reason = "no_speech", raw = rawText })
      end

      local insertMs = nil
      if not ctx.dryRun then insertMs = insertText(final); playSound("Tink") end

      logEvent(ctx.dryRun and "dry_run" or "dictation", {
        app = ctx.app, bundle = ctx.bundle, raw_mode = raw_mode, engine = engine,
        polished = polished,
        hold_seconds = ctx.startedAt and tonumber(string.format("%.2f", ctx.releasedAt - ctx.startedAt)) or nil,
        wav_seconds = tonumber(string.format("%.2f", dur)),
        mic_open_ms = ctx.deviceReadyAt and ms(ctx.startedAt, ctx.deviceReadyAt) or nil,
        ffmpeg_exit_ms = ctx.exitMs,
        asr_ms = asrMs,
        post_ms = postMs,
        insert_ms = insertMs,
        -- key-release → clipboard set. The Cmd-V itself lands pasteDelay later.
        total_ms = ms(ctx.releasedAt),
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
  if pid then hs.execute("/bin/kill -INT " .. pid) end

  -- A discard throws the WAV away, so there is nothing to wait for. Returning to
  -- idle immediately matters: the first tap of a double-tap is a discard, and a
  -- human's second tap lands ~100-150ms later — well inside the time ffmpeg takes
  -- to exit. Waiting here made handleFlags drop that second tap, so
  -- double-tap-to-latch silently did nothing.
  if discard then
    state.mode = "idle"; setIcon("idle")
    return
  end

  local function afterExit()
    runPipeline({
      app = wasApp, bundle = wasBundle, dict = dict,
      releasedAt = releasedAt, startedAt = startedAt, deviceReadyAt = deviceReadyAt,
      exitMs = ms(releasedAt),
      dryRun = opts.dryRun, onDone = opts.onDone,
    })
  end

  if pid then
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
          hs.alert.show("RAPP Voice: hands-free — tap to finish", 1)
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
M._stateMode = function() return state.mode end

-- Clear the tap history so a test starts from a known state.
function M._resetState()
  state.mode = "idle"
  state.lastTapAt, state.downAt = 0, 0
  state.ignoreNextUp, state.latchArmed = false, false
  setIcon("idle")
end

-- Drive the press/release state machine with a synthetic flagsChanged event, so
-- the latch logic is testable without the Accessibility grant an eventtap needs.
function M._fakeKey(isDown)
  local key = KEYS[CONFIG.hotkey]
  handleFlags({
    getKeyCode = function() return key.keyCode end,
    getRawEventData = function()
      return { CGEventData = { flags = isDown and key.mask or 0 } }
    end,
  })
  return state.mode
end

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
      menubar:setTooltip("RAPP Voice — hold " .. CONFIG.hotkey .. " to dictate")
      menubar:setMenu(buildMenu)
    end
  end

  if not hs.accessibilityState() then
    hs.alert.show("RAPP Voice needs Accessibility: System Settings → Privacy & Security → Accessibility → Hammerspoon", 8)
    logEvent("accessibility_missing", {})
  end

  M.startServer()

  if tap then tap:stop() end
  tap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, handleFlags)
  tap:start()

  logEvent("started", { hotkey = CONFIG.hotkey, model = CONFIG.model, port = CONFIG.port })
  return M
end


M.start()

return M
