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

# --team X picks the voice from voices.conf. X may be a bare team or a speaker
# key `{team}__{sid8}`; resolution lives in voice-lookup.sh, shared by all callers.
TEAM=""
if [ "${1:-}" = "--team" ]; then TEAM="${2:-}"; shift 2; fi
# --from N resumes a message cut by the continue-style pause (⌘⇧'), skipping the
# N sentences already spoken. Set by watcher.sh from the daemon's resume.json.
FROM=0
if [ "${1:-}" = "--from" ]; then FROM="${2:-0}"; shift 2; fi
. "$TTS_HOME/voice-lookup.sh"
VOICE=$(voice_for_team "$TEAM")

mkdir -p "$CACHE"

if [ "${1:-}" = "--test" ]; then set -- "Voice test complete. Emma speaking, fully local."; fi
# --why kept for compatibility with old callers: everything is local now.
if [ "${1:-}" = "--why" ]; then shift; echo "route=local reason=kokoro voice=$VOICE"; exit 0; fi

TEXT="${*:-}"
[ -z "$TEXT" ] && { echo "usage: speak.sh <text>" >&2; exit 2; }

printf '%s\troute=local\tvoice=%s\tteam=%s\tchars=%s\n' \
  "$(date +%Y-%m-%dT%H:%M:%S)" "$VOICE" "${TEAM:-none}" "${#TEXT}" >>"$LOG"

# 🔴 SPEED IS PART OF THE CACHE KEY (2026-09-14). It was not, and per-voice
# speed could not ship without this: the wav is rendered AT a rate, so keying on
# voice+text alone meant every line Emma had already said would replay at her
# old rate forever while new lines used the new one. Intermittent, and it would
# read as "the speed setting is ignored".
SPEED=$(speed_for_voice "$VOICE")
KEY=$(printf '%s\n%s\n%s' "$VOICE" "$SPEED" "$TEXT" | shasum -a 256 | cut -c1-32)
WAV="$CACHE/$KEY.wav"

# Cached repeat: play instantly. Fresh text: STREAM sentence-by-sentence —
# full wav lands in cache afterwards.
# A resumed message CANNOT use the cache: the wav is the whole message and
# afplay has no sentence offset. It goes through the live engine instead, which
# costs about a second more to first sound — the price of continuing.
if [ -s "$WAV" ] && [ "$FROM" -eq 0 ]; then
  afplay "$WAV" && exit 0
fi

# Fast path (2026-08-19): persistent daemon keeps the model warm — first sound
# ~1.2s sooner than the cold fallback below. Client disconnect = instant mute.
SOCK="$TTS_HOME/daemon.sock"
if [ -x "$PY" ] && [ -S "$SOCK" ]; then
  printf '%s' "$TEXT" | "$PY" "$TTS_HOME/tts_client.py" "$SOCK" "$WAV" "$VOICE" "$FROM" "$SPEED" && exit 0
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
  # SPEED goes BEFORE the text. kokoro_stream.py reads the text as `" ".join(argv[4:])`,
  # so a trailing speed was parsed as the message and the rate was lost: the fallback
  # spoke the number "0.95" out loud instead of the line (fixed 2026-09-22).
  "$PY" "$TTS_HOME/kokoro_stream.py" "$WAV" "$VOICE" "$SPEED" "$TEXT" >>"$TTS_HOME/kokoro.err" 2>&1 && exit 0
  rm -f "$WAV"
fi

# Kokoro broke (venv deleted, model missing) — stay audible on the built-in voice.
say "$TEXT" 2>/dev/null
