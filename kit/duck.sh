#!/bin/bash
# Audio ducking for the TTS watcher (from the live-dj pattern, built 2026-09-01).
#
# While Emma speaks, music players drop to DUCK_PCT so the voice cuts through
# without the music stopping; when the queue goes quiet the saved volume comes
# back. Per-APP volume, never the Mac's master volume — Emma plays through the
# same output and a master duck would duck her too.
#
#   duck.sh down   save each running player's volume, set it to DUCK_PCT
#   duck.sh up     restore every saved volume, clear the state
#
# Controllable players: Spotify + Music (both speak AppleScript). Browser tabs
# (YouTube) have no per-app control — out of scope by design.
#
# Config: ~/.claude/tts/duck.conf — a number (duck percentage, default 20),
# or the word "off" to disable ducking entirely.
#
# Non-fatal by contract: every failure exits 0 so a TCC denial (launchd gets no
# Automation grants — AppleScript error -1743) can never block speech. A denial
# is logged to duck.err by the caller's redirect.
#
# Idempotent: `down` twice keeps the ORIGINAL saved volume (never saves the
# already-ducked 20). `up` with nothing saved is a no-op.

set -uo pipefail

TTS_HOME="$HOME/.claude/tts"
STATE="$TTS_HOME/duck-state"
CONF="$TTS_HOME/duck.conf"
APPS=(Spotify Music)

mkdir -p "$STATE"

DUCK_PCT=20
if [ -f "$CONF" ]; then
  c=$(tr -d '[:space:]' <"$CONF")
  case "$c" in
    off) exit 0 ;;
    ''|*[!0-9]*) : ;;          # not a number — keep default
    *) DUCK_PCT=$c ;;
  esac
fi

# stderr goes to the caller (watcher redirects it into duck.err) so a TCC
# denial (-1743) is visible there instead of vanishing.
get_vol() { osascript -e "tell application \"$1\" to sound volume"; }
set_vol() { osascript -e "tell application \"$1\" to set sound volume to $2"; }
log() { printf '%s\t%s\n' "$(date +%H:%M:%S)" "$*" >>"$TTS_HOME/duck.log"; }

case "${1:-}" in
  down)
    for app in "${APPS[@]}"; do
      pgrep -xq "$app" || { log "down $app: not running"; continue; }
      [ -f "$STATE/$app" ] && { log "down $app: already ducked"; continue; }
      vol=$(get_vol "$app") || { log "down $app: get_vol FAILED"; continue; }
      case "$vol" in ''|*[!0-9]*) log "down $app: bad vol [$vol]"; continue ;; esac
      [ "$vol" -le "$DUCK_PCT" ] && { log "down $app: already quiet ($vol)"; continue; }
      echo "$vol" >"$STATE/$app"
      if set_vol "$app" "$DUCK_PCT"; then log "down $app: $vol -> $DUCK_PCT"; else log "down $app: set_vol FAILED"; rm -f "$STATE/$app"; fi
    done
    ;;
  up)
    for f in "$STATE"/*; do
      [ -e "$f" ] || continue
      app=$(basename "$f")
      vol=$(cat "$f")
      pgrep -xq "$app" && set_vol "$app" "$vol" && log "up $app: restored $vol"
      rm -f "$f"
    done
    ;;
  *)
    echo "usage: duck.sh down|up" >&2
    ;;
esac
exit 0
