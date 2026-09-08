#!/bin/bash
# "Heard you" chirp — plays the INSTANT Lee presses enter (UserPromptSubmit hook).
#
# Why it exists (2026-09-04): measured from this session's transcript, a reply's
# first spoken word lands 10-20s after enter, and essentially ALL of that is the
# model reading a large conversation and thinking — the voice stack contributes
# well under a second. This does not make anything faster. It removes the silence,
# so the wait stops reading as "something is broken".
#
# Rules that matter more than the sound:
#   - PRE-RENDERED audio only (~/.claude/tts/ack/{voice}-{n}.wav). Generating
#     speech here would cost 0.3-3s and defeat the entire point.
#   - fire-and-forget: afplay is backgrounded and this script exits at once. A
#     hook that blocks would ADD delay to the thing it is hiding.
#   - silent when muted (no ENABLED), paused (PAUSE), dictating (HOLD), or when
#     something is already speaking — talking over a report is worse than silence.
#   - COOLOFF seconds between chirps, so three quick prompts is one chirp.
#
# Usage: ack.sh [team]   (team defaults to the statusline registration for $PPID)

TTS_HOME="$HOME/.claude/tts"
ACK="$TTS_HOME/ack"
STAMP="$TTS_HOME/ack.last"
COOLOFF=8

[ -f "$TTS_HOME/ENABLED" ] || exit 0
[ -f "$TTS_HOME/PAUSE" ] && exit 0
[ -f "$TTS_HOME/HOLD" ] && exit 0
[ -f "$TTS_HOME/speaking" ] && exit 0      # someone is mid-sentence
[ -f "$TTS_HOME/ACK_OFF" ] && exit 0       # per-machine off switch, no code change

# Cool-off, done with one find and no arithmetic — `bc` in the hot path cost more
# than the check was worth (measured 0.42s vs 0.28s per call).
[ -n "$(find "$STAMP" -newermt "-${COOLOFF} seconds" 2>/dev/null)" ] && exit 0

# Team → voice, same resolution as speak.sh (exact, then prefix*, then default).
#
# 🔴 2026-09-05: reading ONLY $PPID silently picked the default voice whenever a
# session had not registered itself (teamE ran a whole session as Emma while its
# own queued replies were Bella — the mismatch is what surfaced it). $PPID is the
# session process for a hook, but not for every launch path, so climb the process
# tree the way cal.py does and take the NEAREST registered ancestor. Same fix,
# same reason: `~/.claude/history/*/…claude-code-session-identity` §5.
TEAM="${1:-}"
SESSIONS="$HOME/.claude/team-sessions"
if [ -z "$TEAM" ]; then
  TEAM=$(cat "$SESSIONS/$PPID" 2>/dev/null)
  # Fast path missed — walk up. Only here, so the hot path still costs one `cat`.
  if [ -z "$TEAM" ]; then
    pid=$(ps -o ppid= -p "$PPID" 2>/dev/null | tr -d ' ')
    for _ in 1 2 3 4 5; do
      { [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ]; } && break
      TEAM=$(cat "$SESSIONS/$pid" 2>/dev/null)
      [ -n "$TEAM" ] && break
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
    # Still nothing: say so. Falling back to the default voice is fine; doing it
    # SILENTLY is what hid a wrong-voice session for hours.
    if [ -z "$TEAM" ]; then
      printf '%s\tno team registered for pid %s or its ancestors — using default voice\n' \
        "$(date +%Y-%m-%dT%H:%M:%S)" "$PPID" >>"$TTS_HOME/ack.log"
    fi
    # macOS recycles pids and nothing prunes this directory, so a stale file can
    # land on a live ancestor and answer with the wrong team. Cheap to bound it
    # here, on the rare path only: drop registrations whose process is gone.
    for f in "$SESSIONS"/[0-9]*; do
      [ -e "$f" ] || continue
      kill -0 "${f##*/}" 2>/dev/null || rm -f "$f"
    done
  fi
fi
voice_for_team() {
  local conf="$TTS_HOME/voices.conf" t="$1" k v
  [ -f "$conf" ] || { echo "bf_emma"; return; }
  v=$(grep -E "^${t}=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2)
  [ -n "$v" ] && { echo "$v"; return; }
  while IFS='=' read -r k v; do
    case "$k" in \#*|"") continue ;; esac
    case "$k" in *\*) [ "${t#"${k%\*}"}" != "$t" ] && { echo "$v"; return; } ;; esac
  done <"$conf"
  v=$(grep -E "^default=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2)
  echo "${v:-bf_emma}"
}
VOICE=$(voice_for_team "$TEAM")

# Rotate so it never sounds like one recording on a loop. $RANDOM is fine here —
# nothing depends on the choice.
shopt -s nullglob
CLIPS=("$ACK/$VOICE"-*.wav)
[ ${#CLIPS[@]} -eq 0 ] && CLIPS=("$ACK"/bf_emma-*.wav)   # voice not rendered yet
[ ${#CLIPS[@]} -eq 0 ] && exit 0                          # nothing rendered at all
CLIP="${CLIPS[$((RANDOM % ${#CLIPS[@]}))]}"

# Longer, human phrases (2026-09-04, Lee: "I don't like any of it… make it
# natural") are seconds long, so a queued report could start on top of one. The
# marker makes the watcher wait; it is removed when playback ends, and it carries
# a mtime so a crashed afplay cannot block the queue for more than ACK_MAX.
touch "$STAMP" "$TTS_HOME/ack.playing"
(
  afplay "$CLIP" >/dev/null 2>&1
  rm -f "$TTS_HOME/ack.playing"
) >/dev/null 2>&1 &
exit 0
