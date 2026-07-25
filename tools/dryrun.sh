#!/bin/bash
# FlowLocal dry-run acceptance tests.
# Everything here runs WITHOUT touching your microphone or your keyboard:
# speech is synthesised with `say`, then pushed through the real FlowLocal
# pipeline (whisper-server → filler stripping → app-aware formatting) via the
# Hammerspoon `hs` CLI. Tests that need real keys/mic are listed at the end.
set -uo pipefail

FL="$HOME/.flowlocal"
WORK=/tmp/flowlocal
FIX="$WORK/fixtures"
HSCLI="${HSCLI:-/opt/homebrew/bin/hs}"
PORT=8765
mkdir -p "$FIX"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
head_() { printf '\n\033[1;36m%s\033[0m\n' "$*"; }

command -v "$HSCLI" >/dev/null || { echo "fatal: hs CLI not found at $HSCLI (open Hammerspoon, then re-run install.sh)"; exit 1; }
"$HSCLI" -c 'print("ok")' >/dev/null 2>&1 || { echo "fatal: Hammerspoon is not answering on the ipc CLI"; exit 1; }

# ------------------------------------------------------------------ fixtures
# `say` emits AIFF; ffmpeg converts to the 16kHz mono s16le WAV whisper wants.
mkwav() { # mkwav <name> <spoken text> [say-rate]
  local name="$1" text="$2" rate="${3:-175}"
  [ -f "$FIX/$name.wav" ] && return 0
  say -r "$rate" -o "$FIX/$name.aiff" "$text" || return 1
  /opt/homebrew/bin/ffmpeg -hide_banner -loglevel error -i "$FIX/$name.aiff" \
    -ar 16000 -ac 1 -c:a pcm_s16le -y "$FIX/$name.wav" || return 1
}

head_ "Fixtures (synthesised speech)"
mkwav hello   "hello world this is a test"                     && echo "  hello.wav"
mkwav filler  "um so this is uh basically the plan"            && echo "  filler.wav"
mkwav gitcmd  "git status"                                     && echo "  gitcmd.wav"
mkwav dict    "I am shipping OpenRappter today"                && echo "  dict.wav"
mkwav polish  "polish um I think we should uh maybe possibly consider shipping it"  && echo "  polish.wav"
# 2 seconds of pure digital silence
[ -f "$FIX/silence.wav" ] || /opt/homebrew/bin/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i anullsrc=r=16000:cl=mono -t 2 -c:a pcm_s16le -y "$FIX/silence.wav"
echo "  silence.wav"
# a 0.1s clip, i.e. what a key tap produces
[ -f "$FIX/tap.wav" ] || /opt/homebrew/bin/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i anullsrc=r=16000:cl=mono -t 0.1 -c:a pcm_s16le -y "$FIX/tap.wav"
echo "  tap.wav"

# ---------------------------------------------------------- hermetic dictionary
# Point FlowLocal at a fixture dictionary for the duration of the run, so the
# assertions do not depend on whatever the user has edited into their own.
cat > "$FIX/dictionary.txt" <<'DICT'
OpenRappter
RappterStore
Rappter
Claude Code
Open Raptor => OpenRappter
OpenRaptor => OpenRappter
Raptor Store => RappterStore
RaptorStore => RappterStore
DICT
ORIG_DICT=$("$HSCLI" -c "print(require('flowlocal').CONFIG.dictionary)" 2>/dev/null | tail -1)
"$HSCLI" -c "require('flowlocal').CONFIG.dictionary = '$FIX/dictionary.txt'" >/dev/null 2>&1
restore_dict() { "$HSCLI" -c "require('flowlocal').CONFIG.dictionary = '$ORIG_DICT'" >/dev/null 2>&1; }
trap restore_dict EXIT

# ------------------------------------------------------------------ helpers
# Run a WAV through the real pipeline. Echoes the inserted text.
run_pipeline() { # run_pipeline <wav> <frontmost-app-name> [timeout-s]
  local wav="$1" app="$2" to="${3:-25}" out="$WORK/dryrun_result.txt"
  rm -f "$out" "$out.meta"
  "$HSCLI" -c "require('flowlocal').dryRun('$wav', '$app')" >/dev/null 2>&1
  local waited=0
  while [ ! -f "$out" ]; do
    sleep 0.1; waited=$((waited+1))
    [ "$waited" -gt $((to*10)) ] && { echo "__TIMEOUT__"; return 1; }
  done
  cat "$out"
}

meta() { cat "$WORK/dryrun_result.txt.meta" 2>/dev/null || echo '{}'; }

process_only() { # process_only <text> <app>   — post-processing path only
  "$HSCLI" -c "print(require('flowlocal')._processFor([==[$1]==], [==[$2]==]))" 2>/dev/null
}

# ------------------------------------------------------------------ tests
head_ "0. Speech server is resident"
code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT/")
[ "$code" != "000" ] && ok "whisper-server answering on :$PORT (HTTP $code)" || bad "whisper-server not answering on :$PORT"

head_ "1. Latency + punctuation  (\"hello world this is a test\")"
t0=$(python3 -c 'import time;print(time.time())')
got=$(run_pipeline "$FIX/hello.wav" TextEdit)
t1=$(python3 -c 'import time;print(time.time())')
wall=$(python3 -c "print(round(($t1-$t0)*1000))")
asr=$(meta | python3 -c 'import json,sys;print(json.load(sys.stdin).get("asr_ms","?"))')
echo "     text: \"$got\""
echo "     asr_ms=$asr   dry-run wall (incl. hs CLI spawn)=${wall}ms"
case "$got" in
  [A-Z]*[.!?]) ok "punctuated + sentence-cased" ;;
  *) bad "not punctuated/cased: \"$got\"" ;;
esac
if [ "$asr" != "?" ] && [ "$asr" -le 1500 ]; then ok "ASR ${asr}ms ≤ 1500ms budget"; else bad "ASR ${asr}ms over budget"; fi

head_ "2. Filler stripping"
got=$(run_pipeline "$FIX/filler.wav" TextEdit)
echo "     text: \"$got\""
if [ "$got" = "So this is basically the plan." ]; then ok "exact match"
else
  case "$got" in
    *[Uu]m*|*[Uu]h*) bad "fillers survived: \"$got\"" ;;
    *) ok "fillers stripped (ASR wording differs): \"$got\"" ;;
  esac
fi
# deterministic check of the same code path, independent of ASR wording
p=$(process_only "um so this is uh basically the plan" TextEdit)
[ "$p" = "So this is basically the plan." ] && ok "post-process exact: \"$p\"" || bad "post-process gave \"$p\""
p=$(process_only "Um, so this is, uh, basically the plan." TextEdit)
[ "$p" = "So this is, basically the plan." ] && ok "punctuated fillers: \"$p\"" || echo "     note: punctuated variant → \"$p\""

head_ "4. App-aware raw mode (Terminal)"
got=$(run_pipeline "$FIX/gitcmd.wav" Terminal)
echo "     text: \"$got\""
case "$got" in
  [A-Z]*) bad "capitalised in Terminal: \"$got\"" ;;
  *.) bad "trailing period in Terminal: \"$got\"" ;;
  *) ok "lowercase, no trailing period: \"$got\"" ;;
esac
p=$(process_only "git status" Terminal); [ "$p" = "git status" ] && ok "post-process raw: \"$p\"" || bad "post-process raw gave \"$p\""
p=$(process_only "git status" TextEdit); [ "$p" = "Git status." ] && ok "post-process formatted in TextEdit: \"$p\"" || bad "TextEdit gave \"$p\""
p=$(process_only "git status" Code); [ "$p" = "git status" ] && ok "VS Code is raw too" || bad "VS Code gave \"$p\""

head_ "5. Personal dictionary"
got=$(run_pipeline "$FIX/dict.wav" TextEdit)
echo "     text: \"$got\""
case "$got" in *OpenRappter*) ok "OpenRappter spelled correctly" ;; *) bad "dictionary term missed: \"$got\"" ;; esac
p=$(process_only "i am shipping openrappter and rappterstore today" TextEdit)
echo "     case fixup: \"$p\""
case "$p" in *OpenRappter*RappterStore*) ok "dictionary case normalisation" ;; *) bad "case fixup gave \"$p\"" ;; esac

head_ "5b. Dictionary edge cases (Lua patterns from user-supplied terms)"
cat > "$FIX/edgedict.txt" <<'DICT'
GPT-4
llama3.2
C++
F#
Node.js
DICT
"$HSCLI" -c "require('flowlocal').CONFIG.dictionary = '$FIX/edgedict.txt'" >/dev/null 2>&1
p=$(process_only "i use gpt-4 and llama3.2 daily" TextEdit)
[ "$p" = "I use GPT-4 and llama3.2 daily." ] && ok "digit terms: \"$p\"" || bad "digit terms gave \"$p\""
p=$(process_only "i write c++ and node.js and f# every day" TextEdit)
[ "$p" = "I write C++ and Node.js and F# every day." ] && ok "terms ending in punctuation: \"$p\"" || bad "punctuation terms gave \"$p\""
p=$(process_only "abc++ is not the language" Terminal)
[ "$p" = "abc++ is not the language" ] && ok "no match inside a larger token: \"$p\"" || bad "false positive: \"$p\""
"$HSCLI" -c "require('flowlocal').CONFIG.dictionary = '$FIX/dictionary.txt'" >/dev/null 2>&1
p=$(process_only "humming is not a filler and neither is uhoh" TextEdit)
[ "$p" = "Humming is not a filler and neither is uhoh." ] && ok "fillers respect word boundaries: \"$p\"" || bad "filler over-matched: \"$p\""

head_ "7. Silence guard"
got=$(run_pipeline "$FIX/silence.wav" TextEdit)
[ -z "$got" ] && ok "2s of silence → nothing inserted" || bad "silence produced: \"$got\""
got=$(run_pipeline "$FIX/tap.wav" TextEdit)
[ -z "$got" ] && ok "0.1s tap → nothing inserted (below minRecordSeconds)" || bad "tap produced: \"$got\""

head_ "8. Polish hook  (routes through claude -p — slow)"
if command -v claude >/dev/null || [ -x "$HOME/.local/bin/claude" ]; then
  got=$(run_pipeline "$FIX/polish.wav" TextEdit 180)
  pol=$(meta | python3 -c 'import json,sys;print(json.load(sys.stdin).get("polished"))')
  echo "     polished=$pol"
  echo "     text: \"$got\""
  [ "$pol" = "True" ] && ok "polish hook ran" || bad "polish hook did not run (polished=$pol)"
  case "$got" in *[Uu]h*|*[Uu]m*) bad "fillers survived polish" ;; *) ok "cleaned output" ;; esac
  case "$got" in *[Pp]olish*) bad "trigger word leaked into output" ;; *) ok "trigger word stripped" ;; esac
else
  echo "     SKIP: claude CLI not on PATH"
fi

head_ "Fallback engine (whisper-cli, server stopped)"
pkill -f "whisper-server .*--port $PORT" >/dev/null 2>&1
sleep 0.5
got=$(run_pipeline "$FIX/hello.wav" TextEdit 60)
eng=$(meta | python3 -c 'import json,sys;print(json.load(sys.stdin).get("engine"))')
echo "     engine=$eng  text=\"$got\""
[ "$eng" = "cli" ] && ok "fell back to whisper-cli when the server was down" || bad "engine was $eng"
sleep 1
"$HSCLI" -c "require('flowlocal').startServer()" >/dev/null 2>&1
for _ in $(seq 1 60); do
  sleep 0.5
  [ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:$PORT/)" != "000" ] && break
done
[ "$(curl -s -o /dev/null -m 2 -w '%{http_code}' http://127.0.0.1:$PORT/)" != "000" ] \
  && ok "server auto-restarted after the failure" || bad "server did not come back"

# ------------------------------------------------------------------ summary
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
cat <<'LIVE'

Still needs YOU (real mic + real keys):
  1. Latency in TextEdit  — hold Right Cmd, say "hello world this is a test", release.
  2. Cross-app           — repeat in Notes, Safari's address bar, VS Code.
  3. Filler stripping    — say "um so this is uh basically the plan".
  6. Clipboard restore   — copy "SENTINEL", dictate anything, then Cmd-V.
  Timings land in ~/.flowlocal/logs/flowlocal.log (total_ms = release → inserted).
LIVE
[ "$fail" -eq 0 ]
