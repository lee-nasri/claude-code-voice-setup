#!/bin/bash
# Speak text aloud with Kokoro (bf_emma) — a fully LOCAL AI voice. Nothing ever
# leaves the Mac, so there is no sensitivity routing anymore: every line gets
# the same good voice. Lee's decision 2026-08-16 ("use emma, this model only").
#
#   speak.sh "text"      — speak
#   speak.sh --test      — speak a fixed line
#
# Engine : kokoro-onnx in ~/.claude/tts/kokoro-venv (model kokoro-v1.0.onnx)
# Fallback: macOS `say` — only if Kokoro itself fails (should never happen)
# Cache  : wavs keyed on sha256(voice+text); safe to cache since all-local.
# History: the old cloud(edge-tts)/offline(Kanya) router is gone — see git/notes.

set -uo pipefail
export LC_ALL=en_US.UTF-8

TTS_HOME="$HOME/.claude/tts"
CACHE="$TTS_HOME/cache"
PY="$TTS_HOME/kokoro-venv/bin/python"
LOG="$TTS_HOME/routing.log"

# --team X picks the voice from voices.conf (exact match, then prefix*, then default).
TEAM=""
if [ "${1:-}" = "--team" ]; then TEAM="${2:-}"; shift 2; fi
voice_for_team() {
  local conf="$TTS_HOME/voices.conf" t="$1" line k v
  [ -f "$conf" ] || { echo "bf_emma"; return; }
  # exact
  v=$(grep -E "^${t}=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2)
  [ -n "$v" ] && { echo "$v"; return; }
  # prefix rules like team*=am_michael
  while IFS='=' read -r k v; do
    case "$k" in \#*|"") continue ;; esac
    case "$k" in
      *\*) [ "${t#"${k%\*}"}" != "$t" ] && { echo "$v"; return; } ;;
    esac
  done <"$conf"
  v=$(grep -E "^default=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2)
  echo "${v:-bf_emma}"
}
VOICE=$(voice_for_team "$TEAM")

mkdir -p "$CACHE"

if [ "${1:-}" = "--test" ]; then set -- "Voice test complete. Emma speaking, fully local."; fi
# --why kept for compatibility with old callers: everything is local now.
if [ "${1:-}" = "--why" ]; then shift; echo "route=local reason=kokoro voice=$VOICE"; exit 0; fi

TEXT="${*:-}"
[ -z "$TEXT" ] && { echo "usage: speak.sh <text>" >&2; exit 2; }

printf '%s\troute=local\tvoice=%s\tteam=%s\tchars=%s\n' \
  "$(date +%Y-%m-%dT%H:%M:%S)" "$VOICE" "${TEAM:-none}" "${#TEXT}" >>"$LOG"

KEY=$(printf '%s\n%s' "$VOICE" "$TEXT" | shasum -a 256 | cut -c1-32)
WAV="$CACHE/$KEY.wav"

# Cached repeat: play instantly. Fresh text: STREAM sentence-by-sentence —
# full wav lands in cache afterwards.
if [ -s "$WAV" ]; then
  afplay "$WAV" && exit 0
fi

# Fast path (2026-08-19): persistent daemon keeps the model warm — first sound
# ~1.2s sooner than the cold fallback below. Client disconnect = instant mute.
SOCK="$TTS_HOME/daemon.sock"
if [ -x "$PY" ] && [ -S "$SOCK" ]; then
  printf '%s' "$TEXT" | "$PY" "$TTS_HOME/tts_client.py" "$SOCK" "$WAV" "$VOICE" && exit 0
fi

# Daemon down: start it for the NEXT message, speak this one the cold way.
# 2026-09-02: launchd (com.<you>.claude-tts-daemon, KeepAlive) now OWNS the daemon;
# this spawn is only a fallback for a session running with the job unloaded. The
# two cannot race — main() probes the socket and exits if one is already live.
# QoS is inherited, not fixed here: a `taskpolicy -B -p` call used to sit on the
# next line to lift the daemon off background QoS, and it DOES NOTHING — measured
# 2026-08-30, priority stayed 4 before and after. The real control is the watcher's
# launch agent, which no longer sets ProcessType Background.
if [ -x "$PY" ] && ! pgrep -f kokoro_daemon.py >/dev/null 2>&1; then
  nohup "$PY" "$TTS_HOME/kokoro_daemon.py" >>"$TTS_HOME/daemon.err" 2>&1 &
fi
if [ -x "$PY" ]; then
  "$PY" "$TTS_HOME/kokoro_stream.py" "$WAV" "$VOICE" "$TEXT" >>"$TTS_HOME/kokoro.err" 2>&1 && exit 0
  rm -f "$WAV"
fi

# Kokoro broke (venv deleted, model missing) — stay audible on the built-in voice.
say "$TEXT" 2>/dev/null
