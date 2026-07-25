#!/bin/bash
# FlowLocal polish hook.
#   $1 = path to a file containing the dictated text (trigger word already stripped)
#   stdout = the cleaned text, nothing else
#
# Swap the body to point at Ollama instead, e.g.:
#   ollama run llama3.2 "Clean up this dictated text ... : $text"
set -euo pipefail
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

text="$(cat "$1")"
[ -n "$text" ] || exit 1

claude -p "Clean up this dictated text: fix grammar, remove self-corrections and false starts, keep meaning and my voice. Output ONLY the cleaned text: $text"
