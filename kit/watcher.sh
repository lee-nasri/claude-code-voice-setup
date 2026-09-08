#!/bin/bash
# Speaks anything dropped into ~/.claude/tts/queue/.
#
# Exists because hooks are loaded when a session starts — a session already
# running can never gain a new Stop hook. A daemon sidesteps that entirely:
# every session, old or new, speaks by writing a file.
#
# Write convention (2026-08-17): one file per message, named {epoch}-{team}.txt
#   echo "mfA here — done." > ~/.claude/tts/queue/$(date +%s)-mfA.txt
# Lexical sort of the names IS arrival order, so the oldest speaks first.
#
# Discard rules (designed with Lee 2026-08-17 — "late over lost"):
#   - SUPERSEDE: a newer file from the SAME team makes an older waiting one
#     obsolete — the old one is dropped. Nothing an agent does can drop
#     another agent's message, and there is NO age timer.
#   - SLEEP PURGE: if this loop itself stalled >5 min (laptop slept, watcher
#     frozen), queue content from before the gap is a ghost — purge it.
#   - MUTE: no ~/.claude/tts/ENABLED file → claimed messages are destroyed
#     instantly (never stockpiled), and current playback is killed mid-word.
#   - TEAM MUTE (2026-08-17): a team listed in muted.conf is dropped the same
#     way — its messages never queue, and if it is speaking when muted the
#     playback is cut mid-word. Global ENABLED overrides everything.
#   - SKIP (2026-08-20, Claude Monitor ⏭): a file at skip/{team} cuts that
#     team's current line and drops what it has waiting, then deletes itself —
#     one-shot, so the team's NEXT message speaks. Not a mute.
#     Caveat: while another team holds the speaker the outer loop is blocked,
#     so a skipped team's waiting files are discarded when that ends. They are
#     never spoken either way.
#   - HUSH (2026-08-22, ⌘⇧. global hotkey): skip/ALL is the same one-shot, but
#     for whoever is speaking plus every waiting message, any team.
#   - BARGE-IN (2026-09-01, designed with Lee): a HOLD file (written by
#     mic_hold.py while the mic is open — i.e. Lee is holding Handy's
#     push-to-talk) cuts CURRENT playback mid-word and freezes the queue.
#     Unlike skip/mute, waiting messages are NOT dropped: interrupting Emma
#     says nothing about Bella's or George's reports, so they play after
#     HOLD clears, in arrival order. The interrupted message's remainder is
#     gone by design — the screen keeps the full text.
#   - PAUSE (2026-09-03, ⌘⇧P or the ⏸ button): a deliberate, untimed stop for
#     when someone walks up to Lee's desk. Same freeze as HOLD, but the message
#     that was cut is written BACK into the queue under its own filename, so
#     resuming replays it FROM THE BEGINNING (Lee's choice over sentence-level
#     resume) and everything queued behind it keeps its arrival order.
#
# Single consumer by design: it claims each file with `mv` before speaking, so
# two files never overlap and nothing is spoken twice.
#
#   start:  nohup ~/.claude/tts/watcher.sh >/dev/null 2>&1 &
#   stop:   rm ~/.claude/tts/ENABLED   (goes quiet, keeps running)
#           pkill -f 'tts/watcher.sh'  (stops for good)

set -uo pipefail

TTS_HOME="$HOME/.claude/tts"
QUEUE="$TTS_HOME/queue"
CLAIMED="$TTS_HOME/queue/.claimed"
PIDFILE="$TTS_HOME/watcher.pid"
MUTED="$TTS_HOME/muted.conf"
SKIP="$TTS_HOME/skip"
# PAUSE (2026-09-03, Lee: "sometimes my teammate wants to ask me something").
# Deliberate, no timer: while it exists nothing speaks, and the message that was
# cut goes BACK in the queue under its own name, so resuming replays it from the
# beginning (his choice) and later messages keep their arrival order.
PAUSE="$TTS_HOME/PAUSE"

mkdir -p "$QUEUE" "$CLAIMED" "$SKIP"

# One watcher only — a second would double-speak.
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
  echo "watcher already running (pid $(cat "$PIDFILE"))" >&2
  exit 0
fi
echo $$ >"$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT

# Barge-in detector: mirrors mic-in-use into $TTS_HOME/HOLD. Self-healing —
# respawned here if it died (same pattern as speak.sh and the kokoro daemon).
spawn_mic_hold() {
  pgrep -f "tts/mic_hold.py" >/dev/null 2>&1 ||
    nohup /usr/bin/python3 "$TTS_HOME/mic_hold.py" >>"$TTS_HOME/mic_hold.err" 2>&1 &
}
spawn_mic_hold

# team_of <path> — the part after the last dash in the basename ("" if none).
team_of() {
  local b; b=$(basename "$1" .txt)
  case "$b" in
    *-*) echo "${b##*-}" ;;
    *)   echo "" ;;
  esac
}

# is_muted <team> — true when the team is listed in muted.conf (one per line).
is_muted() {
  [ -n "$1" ] && [ -f "$MUTED" ] && grep -qx "$1" "$MUTED"
}

# skip_pending <team> — a one-shot "shut up now" flag from Claude Monitor's ⏭.
# Unlike muted.conf this is consumed immediately: the team's next message speaks.
# ALL is kept as an escape hatch (`touch skip/ALL`) — nothing in the UI writes it.
skip_pending() {
  [ -f "$SKIP/ALL" ] || { [ -n "$1" ] && [ -f "$SKIP/$1" ]; }
}

LAST_TICK=$(date +%s)

TICK=0
while true; do
  NOW=$(date +%s)

  # Re-spawn the barge-in detector if it died (~every 15s, not every tick).
  TICK=$((TICK + 1))
  [ $((TICK % 60)) -eq 0 ] && spawn_mic_hold

  # Duck restore: saved volumes exist, nothing speaking, queue drained → bring
  # the music back. Covers every end path — natural finish, mute, skip, HOLD kill.
  # Paused counts as drained: the queue is deliberately full and the music
  # should not stay down while Lee is talking to someone.
  if [ -z "${SPEAK_PID:-}" ] && ls "$TTS_HOME/duck-state"/* >/dev/null 2>&1 &&
     { ! ls "$QUEUE"/*.txt >/dev/null 2>&1 || [ -f "$PAUSE" ]; }; then
    "$TTS_HOME/duck.sh" up 2>>"$TTS_HOME/duck.err" || true
  fi

  # Sleep purge: this loop normally ticks 4x/second. A >5 min gap means the
  # machine slept or the watcher hung — everything queued before is a ghost.
  if [ $((NOW - LAST_TICK)) -gt 300 ]; then
    rm -f "$QUEUE"/*.txt 2>/dev/null
  fi
  LAST_TICK=$NOW

  # Instant mute: if the flag vanished while something is playing, cut it off NOW.
  if [ ! -f "$TTS_HOME/ENABLED" ] && [ -n "${SPEAK_PID:-}" ] && kill -0 "$SPEAK_PID" 2>/dev/null; then
    pkill -P "$SPEAK_PID" 2>/dev/null
    kill "$SPEAK_PID" 2>/dev/null
    SPEAK_PID=""
  fi

  # Skip (⏭ in Claude Monitor): drop that team's WAITING messages. Cutting its
  # current playback is handled in the wait loop below, which owns SPEAK_PID.
  # The flag is consumed here so the team's next message speaks normally.
  for flag in "$SKIP"/*; do
    [ -e "$flag" ] || continue
    st=$(basename "$flag")
    if [ "$st" = "ALL" ]; then
      rm -f "$QUEUE"/*.txt "$CLAIMED"/*.txt.* 2>/dev/null
      [ -n "${SPEAK_PID:-}" ] || rm -f "$flag"
      continue
    fi
    rm -f "$QUEUE"/*-"$st".txt "$CLAIMED"/*-"$st".txt.* 2>/dev/null
    # leave the flag for the wait loop when that team is the one speaking
    [ "${SPEAKING_TEAM:-}" = "$st" ] && [ -n "${SPEAK_PID:-}" ] || rm -f "$flag"
  done

  for f in "$QUEUE"/*.txt; do
    [ -e "$f" ] || continue

    # Barge-in freeze (HOLD, option+space) or a deliberate pause (PAUSE) —
    # start nothing new. break, not continue: files stay in the queue for later.
    { [ -f "$TTS_HOME/HOLD" ] || [ -f "$PAUSE" ]; } && break

    # Claim first: the mv is the lock. A loser sees the file already gone.
    qname="$(basename "$f")"     # kept so a pause can put this message back
    claim="$CLAIMED/$qname.$$"
    mv "$f" "$claim" 2>/dev/null || continue

    if [ ! -f "$TTS_HOME/ENABLED" ]; then
      rm -f "$claim"          # muted: drop it, don't queue up a backlog to shout later
      continue
    fi

    team=$(team_of "$f")

    # Team mute: same no-backlog rule as the global mute — drop, never stockpile.
    if is_muted "$team"; then
      rm -f "$claim"
      continue
    fi

    # Supersede: if the same team has queued a NEWER message, this one is obsolete.
    if [ -n "$team" ] && ls "$QUEUE"/*-"$team".txt >/dev/null 2>&1; then
      rm -f "$claim"
      continue
    fi

    text=$(tr -d '\r' <"$claim")
    rm -f "$claim"
    [ -z "$text" ] && continue

    # Ducking (2026-09-01): pull music players down before speaking. Restore
    # happens in the outer loop once nothing is speaking AND the queue is empty,
    # so back-to-back messages don't bounce the volume. Never fatal.
    "$TTS_HOME/duck.sh" down 2>>"$TTS_HOME/duck.err" || true

    "$TTS_HOME/speak.sh" --team "$team" "$text" &   # background so the mute check stays live
    SPEAK_PID=$!
    SPEAKING_TEAM="$team"
    # Published for the ⌘⇧. hotkey: when the pointer is over no row it hushes
    # whoever is actually talking.
    printf '%s' "$team" >"$TTS_HOME/speaking"
    # The claim file is already consumed, so the /voice page reads the live
    # message text from here (token-gated in serve.py).
    printf '%s' "$text" >"$TTS_HOME/speaking-text"
    while kill -0 "$SPEAK_PID" 2>/dev/null; do
      # HOLD = barge-in: cut this utterance only; queued files are untouched.
      # PAUSE = deliberate: cut it AND put it back, so resume replays it whole.
      if [ ! -f "$TTS_HOME/ENABLED" ] || is_muted "$team" || skip_pending "$team" ||
         [ -f "$TTS_HOME/HOLD" ] || [ -f "$PAUSE" ]; then
        # TERM first (lets kokoro stop the audio stream cleanly), then KILL —
        # a TERM alone left the player draining its buffer for ~3s.
        pkill -P "$SPEAK_PID" 2>/dev/null
        kill "$SPEAK_PID" 2>/dev/null
        sleep 0.2
        pkill -KILL -P "$SPEAK_PID" 2>/dev/null
        kill -KILL "$SPEAK_PID" 2>/dev/null
        # Pause: requeue under the ORIGINAL name so it keeps its place in
        # arrival order and speaks from the top on resume. Mute and skip are
        # checked first — those mean "drop it", and they must still win.
        if [ -f "$PAUSE" ] && [ -f "$TTS_HOME/ENABLED" ] &&
           ! is_muted "$team" && ! skip_pending "$team" && [ ! -f "$SKIP/ALL" ]; then
          printf '%s' "$text" >"$QUEUE/$qname"
        fi
        # skip also drops whatever else is waiting, then clears itself
        if [ -f "$SKIP/ALL" ]; then
          rm -f "$QUEUE"/*.txt "$SKIP/ALL" 2>/dev/null
        elif skip_pending "$team"; then
          rm -f "$QUEUE"/*-"$team".txt "$SKIP/$team" 2>/dev/null
        fi
        break
      fi
      sleep 0.1
    done
    SPEAK_PID=""
    SPEAKING_TEAM=""
    rm -f "$TTS_HOME/speaking" "$TTS_HOME/speaking-text"
    LAST_TICK=$(date +%s)   # long playback is not a sleep gap
  done
  sleep 0.25
done
