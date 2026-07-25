# FlowLocal

Hold a key anywhere on macOS, speak, release — cleaned-up text appears at your
cursor in whatever app is in front.

100% local. No cloud, no account, no API key, no telemetry. Your voice never
leaves the machine: speech recognition runs on your own GPU via
[whisper.cpp](https://github.com/ggerganov/whisper.cpp).

Measured on an Apple M4: **142–350 ms** from key-release to text ready.

```
key down ──► ffmpeg (avfoundation, 16 kHz mono)
key up   ──► whisper-server  (model stays resident in RAM)
         ──► filler stripping · sentence case · app-aware formatting · dictionary
         ──► clipboard + ⌘V at your cursor
```

---

## Install

```bash
git clone https://github.com/kody-w/flowlocal.git
cd flowlocal
./install.sh
```

The installer is idempotent — safe to re-run. It installs `ffmpeg`,
`whisper-cpp` and Hammerspoon via Homebrew, downloads the two speech models
(~630 MB total) into `~/.flowlocal/models/`, links the Lua files into
`~/.hammerspoon/`, and starts the speech server.

It will not overwrite a `dictionary.txt` or a `hooks/polish.sh` you have edited.

### Permissions — both are required

**1. Accessibility** — for the key tap and the ⌘V injection.

> System Settings → Privacy & Security → **Accessibility** → enable **Hammerspoon**

Without this the hotkey does nothing at all. FlowLocal shows an alert on load if
it is missing.

**2. Microphone** — for recording.

Your *first* recording triggers the microphone prompt for Hammerspoon. Approve
it. That first attempt inserts nothing; just hold the key again afterwards. If
the prompt never appears, add it by hand:

> System Settings → Privacy & Security → **Microphone** → enable **Hammerspoon**

**3. Reload after granting either permission** — Hammerspoon menubar → *Reload
Config*, or the FlowLocal `◌` menu → *Reload Hammerspoon config*.

---

## Use

| Action | Result |
|---|---|
| **Hold Right ⌘**, speak, release | Text inserted at your cursor |
| **Double-tap Right ⌘** | Hands-free recording; **tap again** to finish |
| Tap the key once | Nothing — taps are never dictations |
| Press/release with no speech | Nothing inserted, no error |

Menubar: `◌` idle · `🔴` recording · `⋯` transcribing. The menu has server
status, a server restart, and a config reload.

Say **"polish"** as the first word to route the rest through an LLM cleanup pass
(see below) — that costs seconds, so it is opt-in per dictation.

---

## What the post-processing does

Whisper gives you a raw sentence; FlowLocal makes it look like you typed it.

- **Trims** whitespace and drops whisper's non-speech annotations (`[BLANK_AUDIO]`,
  `*laughs*`).
- **Strips filler words** on word boundaries, then repairs the punctuation the
  removal leaves behind:
  `"Um, so this is, uh, basically the plan."` → `"So this is, basically the plan."`
- **Sentence-cases** and adds terminal punctuation.
- **App-aware:** in a terminal or a code editor it does the opposite — it
  *removes* the capital and the trailing period whisper added, because
  `"Git status."` is not what you wanted in a shell:

  | Frontmost app | `"git status"` becomes |
  |---|---|
  | TextEdit, Notes, Slack… | `Git status.` |
  | Terminal, VS Code, Cursor… | `git status` |

- **Applies your dictionary** (below).
- **Silence guard:** a recording shorter than `minRecordSeconds`, or a
  transcript with no words in it, inserts nothing and raises no dialog.

---

## Personal dictionary

`~/.flowlocal/dictionary.txt`, one entry per line. Edits apply on your next
dictation — no reload.

```
# A bare term biases the recogniser AND forces this exact spelling/casing.
Kubernetes
PostgreSQL
OpenRappter

# A rewrite, for invented words that are HOMOPHONES of real ones.
Open Raptor => OpenRappter
```

Two mechanisms, because one is not enough:

1. **Bias.** Every term is passed to whisper as its decoding prompt, which pulls
   ambiguous audio toward your vocabulary.
2. **Rewrite.** Biasing cannot fix a true homophone — "Rappter" and "Raptor" are
   acoustically identical, so no recogniser can choose between them from sound
   alone. `heard => meant` lines are a literal, case-insensitive replacement.

Keep the left side of a rewrite multi-word or clearly invented where you can: a
bare `Raptor => Rappter` would also corrupt genuine uses of the real word.

---

## Optional LLM polish

Say `"polish"` first and the rest of the transcript is piped through
`~/.flowlocal/hooks/polish.sh` before insertion. The shipped hook uses the
`claude` CLI:

```
"polish um I think we should uh maybe possibly consider shipping it"
                            ↓
"I think we should consider shipping it."
```

It is a plain shell script — `$1` is a file holding the text, stdout is the
cleaned result — so point it anywhere. For a fully offline polish, use Ollama:

```bash
#!/bin/bash
text="$(cat "$1")"
ollama run llama3.2 "Fix grammar and remove false starts. Output only the cleaned text: $text"
```

If the hook fails or times out, the un-polished transcript is inserted rather
than losing the dictation.

---

## Config reference

All of it is the `CONFIG` table at the top of `flowlocal.lua`.

| Key | Default | Meaning |
|---|---|---|
| `hotkey` | `"rightCmd"` | `rightCmd`, `leftCmd`, `rightOption`, `leftOption`, `rightShift`, `leftShift`, `fn` |
| `model` | `ggml-small.en.bin` | Primary model, kept resident |
| `fallbackModel` | `ggml-base.en.bin` | Used by the `whisper-cli` fallback |
| `port` | `8765` | whisper-server port |
| `language` | `"en"` | `"auto"` to detect (needs a multilingual model) |
| `audioDevice` | `":default"` | avfoundation device. **The leading colon is required.** |
| `minRecordSeconds` | `0.35` | Shorter recordings count as silence |
| `maxRecordSeconds` | `600` | Hard stop, so a stuck latch cannot run forever |
| `insertMethod` | `"paste"` | `"paste"` (clipboard + ⌘V) or `"type"` (simulated keystrokes) |
| `pasteDelay` | `0.05` | Seconds between setting the clipboard and ⌘V |
| `clipboardRestoreDelay` | `0.25` | Seconds after ⌘V before your clipboard is put back |
| `fillers` | `um, uh, uhm, erm, hmm, mhm, you know, i mean, like, like` | Removed on word boundaries |
| `rawApps` | Terminal, iTerm2, Ghostty, VS Code, Cursor, Alacritty, kitty, WezTerm, Warp | Apps that get unformatted text (name **or** bundle ID) |
| `polishTrigger` | `"polish"` | Spoken word that routes through the hook |
| `polishTimeout` | `60` | Seconds before a hung hook gives up and inserts the un-polished text |
| `doubleTapSeconds` | `0.35` | Max gap for a double-tap to latch |
| `tapMaxSeconds` | `0.25` | A hold shorter than this is a tap, not a dictation |
| `sounds` | `true` | Cue when the mic opens, and when text lands |

### Common changes

**Change the hotkey** — `CONFIG.hotkey = "fn"`, then reload.

**Swap the model** — download another `ggml-*.bin` into `~/.flowlocal/models/`,
point `CONFIG.model` at it, then use the menubar's *Restart speech server*.
`small.en` is the accuracy/latency sweet spot; `medium.en` is noticeably better
on hard audio and roughly 3× slower; `base.en` is fastest.

**Preserve your clipboard manager's history** — `insertMethod = "type"`. Slower
for long text, but it never touches the clipboard.

---

## Logs and profiling

`~/.flowlocal/logs/flowlocal.log` — one JSON object per event.

```json
{"event":"dictation","app":"TextEdit","raw_mode":false,"engine":"server",
 "mic_open_ms":312,"ffmpeg_exit_ms":41,"asr_ms":154,"post_ms":0,"total_ms":183,
 "raw":" Hello world, this is a test.\n","text":"Hello world, this is a test."}
```

`total_ms` is the number that matters: key-release → text inserted. `mic_open_ms`
is how long avfoundation took to open the device on key-*down* — that window is
before the start cue, which is why the cue plays only once capture is truly live.

Server output is in `whisper-server.log`.

---

## Tests

```bash
./tools/dryrun.sh
```

19 assertions, no microphone and no keyboard needed: speech is synthesised with
`say`, then pushed through the real pipeline via the Hammerspoon `hs` CLI. It
covers latency, filler stripping, app-aware raw mode, the dictionary, both
silence guards, the polish hook, and the whisper-cli fallback with the server
deliberately killed. It uses its own fixture dictionary, so your personal one
does not affect the results.

Four things only a human can check — the hotkey and ⌘V need real keys:

1. Hold Right ⌘ in TextEdit, say *"hello world this is a test"*, release.
2. Repeat in Notes, Safari's address bar, and VS Code.
3. Say *"um so this is uh basically the plan"* → `So this is basically the plan.`
4. Copy `SENTINEL`, dictate anything, then ⌘V — you should get `SENTINEL` back.

---

## Troubleshooting

**Nothing happens when I hold the key.** Accessibility is not granted, or the
config was not reloaded after granting it. Check:
`hs -c 'print(hs.accessibilityState())'`.

**Text appears in the wrong app.** The target is captured on key-*down*. Click
into the field you want before you start holding.

**The first word gets clipped.** avfoundation needs ~300 ms to open the mic. The
start cue plays when capture is actually live — wait for it.

**Nothing is inserted and the log says `silence_skipped`.** Either the recording
was under `minRecordSeconds`, or whisper heard no words. `raw` in the log entry
shows what it did hear.

**Latency got worse.** Check the server is still resident:
`pgrep -f whisper-server`. If it died, FlowLocal falls back to `whisper-cli`,
which reloads the model on every call — seconds instead of milliseconds. The
menubar menu shows server status and can restart it.

**A `⌘V` fires but the text is stale.** Raise `pasteDelay`; some Electron apps
read the pasteboard lazily.

---

## Uninstall

```bash
rm -rf ~/.flowlocal ~/.hammerspoon/flowlocal.lua
pkill -f whisper-server
# and remove the require("flowlocal") line from ~/.hammerspoon/init.lua
```

---

## Layout

```
~/.hammerspoon/init.lua        → require("flowlocal")
~/.hammerspoon/flowlocal.lua   → symlink to this repo's flowlocal.lua
~/.flowlocal/
  models/                      ggml-small.en.bin, ggml-base.en.bin
  dictionary.txt               your vocabulary
  hooks/polish.sh              the LLM polish hook
  logs/                        flowlocal.log, whisper-server.log
```

Built with [whisper.cpp](https://github.com/ggerganov/whisper.cpp),
[Hammerspoon](https://www.hammerspoon.org), and ffmpeg. MIT.
