#!/bin/bash
# Re-render the instant-ack clips from ack-phrases.conf, in every team voice.
#
# Run this after editing the phrases. It loads the Kokoro model ONCE for the
# whole batch — 8 voices x N phrases through kokoro_stream.py would pay the
# ~1.2s import + model load every single time, and that script also plays the
# audio while it writes it, which made a batch both slow and noisy.
#
#   regen-ack.sh          # only render what is missing
#   regen-ack.sh --force  # wipe and re-render everything (changed phrases)
#   ACK_SPEED=0.95 regen-ack.sh --force   # slower than normal speech
#
# Speed comes from speed.conf, the SAME value normal speech uses. It was
# hardcoded at 1.25 on the first pass and Lee heard it immediately: the clips
# were 25% faster than my own voice, which reads as rushed rather than natural.

set -uo pipefail
TTS_HOME="$HOME/.claude/tts"
[ "${1:-}" = "--force" ] && rm -f "$TTS_HOME/ack"/*.wav

"$TTS_HOME/kokoro-venv/bin/python" - "$TTS_HOME" <<'PY'
import hashlib
import os
import sys

import soundfile as sf
from kokoro_onnx import Kokoro

home = sys.argv[1]
ack = os.path.join(home, "ack")
os.makedirs(ack, exist_ok=True)

def normal_speed() -> float:
    """speed.conf, same source speak.sh reads, so an ack matches the voice
    around it. ACK_SPEED overrides for a deliberately slower greeting."""
    env = os.environ.get("ACK_SPEED")
    if env:
        try:
            return min(2.5, max(0.5, float(env)))
        except ValueError:
            pass
    try:
        for line in open(os.path.join(home, "speed.conf")):
            line = line.strip()
            if line and not line.startswith("#"):
                return min(2.5, max(0.5, float(line)))
    except (OSError, ValueError):
        pass
    return 1.0


speed = normal_speed()
print(f"speed {speed}")

phrases = [l.strip() for l in open(os.path.join(home, "ack-phrases.conf"))
           if l.strip() and not l.startswith("#")]
voices = sorted({l.strip().split("=", 1)[1] for l in open(os.path.join(home, "voices.conf"))
                 if l.strip() and not l.startswith("#") and "=" in l})
if not phrases:
    sys.exit("ack-phrases.conf has no phrases")

# Name each clip after a hash of its text, so editing one line re-renders only
# that line and stale clips are obvious rather than silently kept.
wanted = set()
k = Kokoro(os.path.join(home, "kokoro-v1.0.onnx"), os.path.join(home, "voices-v1.0.bin"))
for v in voices:
    for p in phrases:
        tag = hashlib.sha256(p.encode()).hexdigest()[:8]
        out = os.path.join(ack, f"{v}-{tag}.wav")
        wanted.add(os.path.basename(out))
        if os.path.exists(out) and os.path.getsize(out) > 0:
            continue
        samples, sr = k.create(p, voice=v, speed=speed, lang="en-gb")
        sf.write(out, samples, sr, format="WAV", subtype="PCM_16")
        print("rendered", os.path.basename(out), "—", p)

for name in os.listdir(ack):
    if name.endswith(".wav") and name not in wanted:
        os.unlink(os.path.join(ack, name))
        print("removed stale", name)
print(f"{len(voices)} voices x {len(phrases)} phrases = {len(wanted)} clips")
PY
