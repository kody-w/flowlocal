#!/bin/bash
# FlowLocal installer — idempotent. Safe to re-run.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
FL="$HOME/.flowlocal"
HS="$HOME/.hammerspoon"
MODELS="$FL/models"
BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mfatal:\033[0m %s\n' "$*" >&2; exit 1; }

command -v brew >/dev/null || die "Homebrew is required: https://brew.sh"

# ------------------------------------------------------------------ dependencies
say "Dependencies"
for f in ffmpeg whisper-cpp; do
  if brew list --versions "$f" >/dev/null 2>&1; then
    ok "$f $(brew list --versions "$f" | awk '{print $2}')"
  else
    say "installing $f"
    brew install "$f" || die "brew install $f failed"
  fi
done

if [ -d /Applications/Hammerspoon.app ]; then
  ok "Hammerspoon"
else
  say "installing Hammerspoon"
  brew install --cask hammerspoon || die "brew install --cask hammerspoon failed"
fi

for b in /opt/homebrew/bin/whisper-server /opt/homebrew/bin/whisper-cli /opt/homebrew/bin/ffmpeg; do
  [ -x "$b" ] || die "missing $b"
done

# ------------------------------------------------------------------------- dirs
say "Directories"
mkdir -p "$MODELS" "$FL/hooks" "$FL/logs" "$HS"
ok "$FL/{models,hooks,logs}"

# ----------------------------------------------------------------------- models
say "Models"
fetch_model() {
  local name="$1" min_bytes="$2" dest="$MODELS/$1"
  if [ -f "$dest" ] && [ "$(stat -f%z "$dest")" -ge "$min_bytes" ]; then
    ok "$name ($(du -h "$dest" | cut -f1)) already present"
    return
  fi
  say "downloading $name"
  curl -L --fail -# -o "$dest.part" "$BASE_URL/$name" || { rm -f "$dest.part"; die "download of $name failed"; }
  mv "$dest.part" "$dest"
  ok "$name ($(du -h "$dest" | cut -f1))"
}
fetch_model ggml-small.en.bin 400000000   # primary
fetch_model ggml-base.en.bin  120000000   # fast fallback

# ------------------------------------------------------------------- dictionary
say "Personal dictionary"
if [ -f "$FL/dictionary.txt" ]; then
  ok "dictionary.txt kept ($(grep -cve '^\s*$' "$FL/dictionary.txt") terms)"
else
  cp "$SRC/dictionary.txt" "$FL/dictionary.txt"
  ok "dictionary.txt seeded"
fi

# ------------------------------------------------------------------ polish hook
say "Polish hook"
if [ -f "$FL/hooks/polish.sh" ] && ! [ -L "$FL/hooks/polish.sh" ]; then
  ok "hooks/polish.sh kept (yours)"
else
  cp "$SRC/polish.sh" "$FL/hooks/polish.sh"
  ok "hooks/polish.sh installed"
fi
chmod +x "$FL/hooks/polish.sh"

# --------------------------------------------------------------- hammerspoon
say "Hammerspoon config"
ln -sfn "$SRC/flowlocal.lua" "$HS/flowlocal.lua"
ok "$HS/flowlocal.lua -> $SRC/flowlocal.lua"

if [ -e "$HS/init.lua" ] && ! [ -L "$HS/init.lua" ]; then
  if grep -q 'require("flowlocal")' "$HS/init.lua"; then
    ok "init.lua already requires flowlocal"
  else
    cp "$HS/init.lua" "$HS/init.lua.pre-flowlocal.$(date +%s)"
    cat "$SRC/init.lua" >> "$HS/init.lua"
    ok "appended to your existing init.lua (backup written)"
  fi
else
  ln -sfn "$SRC/init.lua" "$HS/init.lua"
  ok "$HS/init.lua -> $SRC/init.lua"
fi

ln -sfn "$SRC/install.sh" "$FL/install.sh"
ln -sfn "$SRC/tools/dryrun.sh" "$FL/dryrun.sh" 2>/dev/null || true

# ------------------------------------------------------------------ launch + smoke
say "Speech server smoke test"
PORT=8765
if pgrep -f "whisper-server .*--port $PORT" >/dev/null; then
  ok "whisper-server already running on $PORT"
else
  nohup /opt/homebrew/bin/whisper-server -m "$MODELS/ggml-small.en.bin" \
    --host 127.0.0.1 --port "$PORT" -l en -t 4 >> "$FL/logs/whisper-server.log" 2>&1 &
  # probe with GET / — a POST to /inference without a file never gets a reply
  for _ in $(seq 1 60); do
    sleep 0.5
    code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)
    [ "${code:-000}" != "000" ] && break
  done
  if [ "${code:-000}" != "000" ]; then ok "whisper-server up on $PORT (HTTP $code)"
  else warn "whisper-server did not answer — see $FL/logs/whisper-server.log"; fi
fi

if pgrep -x Hammerspoon >/dev/null; then
  ok "Hammerspoon running — reload its config from the menubar (or run: hs -c 'hs.reload()')"
else
  say "launching Hammerspoon"
  open -a Hammerspoon
fi

cat <<'PERMS'

============================================================
 FlowLocal installed. TWO PERMISSIONS ARE REQUIRED.
============================================================

1) ACCESSIBILITY  (needed for the key tap and the Cmd-V injection)
   Open System Settings > Privacy & Security > Accessibility
   → enable Hammerspoon.
   Hammerspoon will also offer this prompt itself on first launch.

2) MICROPHONE  (needed to record)
   Your FIRST recording triggers the microphone prompt for
   Hammerspoon — approve it. Nothing is inserted on that first
   attempt; just hold the key again afterwards.
   If the prompt never appears, add it manually:
   System Settings > Privacy & Security > Microphone > Hammerspoon.

3) RELOAD after granting either permission:
   Hammerspoon menubar icon > Reload Config
   (or the FlowLocal ◌ menu > "Reload Hammerspoon config")

------------------------------------------------------------
 USE:  hold RIGHT COMMAND, speak, release.
       Double-tap RIGHT COMMAND for hands-free; tap to finish.
 Menubar: ◌ idle   🔴 recording   ⋯ transcribing
 Logs:   ~/.flowlocal/logs/flowlocal.log   (one JSON line per dictation)
 Docs:   README.md in this folder
------------------------------------------------------------
PERMS
