# Shared voice resolution — sourced by speak.sh, watcher.sh, ack.sh and say.sh.
#
# A SPEAKER KEY is `{team}` or `{team}__{sid8}`, where sid8 is the first 8 chars
# of the session id that say.sh stamps into the queue filename. Keying the voice
# on the SESSION is what lets three forked windows of teamA hold three different
# voices while every other part of the system still calls all of them teamA.
#
# Lookup order: exact key → bare team → `prefix*` rules → default. So an
# old-style `{epoch}-teamA.txt` name resolves exactly as it did before this file
# existed, and a session with no voice of its own inherits its team's.
#
# Before this, the same lookup was copy-pasted in three scripts and had already
# drifted: watcher.sh's copy never implemented the `prefix*` rules at all.

: "${TTS_HOME:=$HOME/.claude/tts}"

# base_team <key> — the team half of a speaker key ("teamA__f11d852f" → "teamA").
base_team() { local t="${1:-}"; printf '%s' "${t%%__*}"; }

voice_for_team() {
  local conf="$TTS_HOME/voices.conf" t="${1:-}" base k v
  [ -f "$conf" ] || { echo "bf_emma"; return; }
  base=$(base_team "$t")
  # exact key first, so a per-session voice wins over its team's
  for k in "$t" "$base"; do
    [ -n "$k" ] || continue
    v=$(grep -E "^${k}=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2)
    [ -n "$v" ] && { echo "$v"; return; }
  done
  # prefix rules like team*=am_michael, matched on the team, never the session
  while IFS='=' read -r k v; do
    case "$k" in \#*|"") continue ;; esac
    case "$k" in
      *\*) [ -n "$base" ] && [ "${base#"${k%\*}"}" != "$base" ] && { echo "$v"; return; } ;;
    esac
  done <"$conf"
  v=$(grep -E "^default=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2)
  echo "${v:-bf_emma}"
}

# speed_for_voice <voice> — playback rate for THIS voice (2026-09-14).
#
# Keyed on the VOICE, deliberately, not on the team or the session: Lee's words
# were "if team A is Emma and I set one point five, every session that uses
# Emma gets it". Two forks can hold different voices, but one voice cannot
# sound like two different people.
#
# speeds.conf ({voice}={rate}) → 1.0. The old single global speed.conf is GONE
# (Lee, 2026-09-14: "remove the global speed we don't need it anymore") — one
# rate for everyone was the thing this replaces. Anything unparseable reads as
# "no opinion" and falls through to 1.0, so a corrupt line can never silence a
# voice or leave it at some wild rate.
speed_for_voice() {
  local conf="$TTS_HOME/speeds.conf" v="${1:-}" s
  if [ -n "$v" ] && [ -f "$conf" ]; then
    s=$(grep -E "^${v}=" "$conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -dc '0-9.')
    case "$s" in ''|.|*.*.*) ;; *) echo "$s"; return ;; esac
  fi
  echo "1.0"
}

# resolve_session [pid] — echoes "<team> <sid8>", either of which may be empty.
#
# $PPID is the session process for a hook but not for every launch path, so
# climb the tree and take the NEAREST registered ancestor — reading only $PPID
# once ran a whole session in the wrong voice (2026-09-05, see ack.sh).
resolve_session() {
  local sessions="$HOME/.claude/team-sessions" start="${1:-$PPID}" pid team sid n
  pid="$start"
  team=$(cat "$sessions/$pid" 2>/dev/null)
  if [ -z "$team" ]; then
    pid=$(ps -o ppid= -p "$start" 2>/dev/null | tr -d ' ')
    for n in 1 2 3 4 5; do
      { [ -z "$pid" ] || [ "$pid" = "0" ] || [ "$pid" = "1" ]; } && break
      team=$(cat "$sessions/$pid" 2>/dev/null)
      [ -n "$team" ] && break
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done
  fi
  # heartbeat.py writes {pid}.sid beside the registration on every hook event
  sid=$(cat "$sessions/$pid.sid" 2>/dev/null)
  printf '%s %s' "$team" "$(printf '%s' "$sid" | cut -c1-8)"
}

# speaker_key [pid] — "{team}__{sid8}", or "{team}" when the session is unknown.
speaker_key() {
  local team sid
  read -r team sid <<EOF
$(resolve_session "${1:-$PPID}")
EOF
  [ -n "$team" ] && [ -n "$sid" ] && { printf '%s__%s' "$team" "$sid"; return; }
  printf '%s' "$team"
}
