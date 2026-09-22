"""Shared sentence chunking for the Kokoro speakers (daemon + fallback stream).

First chunk is deliberately small (first clause, <=10 words) so first sound
lands fast; later chunks are big (~25+ words) so each buys generation time
for its successor (gap rule from 2026-08-17 tuning).
"""
import re

FIRST_MAX_WORDS = 10
LATER_MIN_WORDS = 25

# Thai writes no full stops and no spaces inside a clause — the space IS the
# clause break, so the English splitter would return the whole message as one
# chunk and the first-sound-fast rule would be lost.
THAI = re.compile(r"[฀-๿]")

# Chunk sizes RAMP instead of jumping 1 -> 5 (fixed 2026-09-21).
#
# The rule that keeps speech continuous: generating the NEXT chunk must finish
# before the CURRENT one stops playing. Measured on this Mac, Thai generates at
# ~2x realtime — 0.62s of compute per 1.25s of speech — so a chunk can cover a
# successor at most ~2x its own size. The old 1 -> 5 jump asked one phrase to
# cover five, and the queue ran dry for ~1.9s right after the opening phrase:
#
#   speak c0 1.25s  vs  generate c1 3.17s   STARVED
#
# Each step below stays under that 2x limit, so every chunk pays for the next.
# The tail repeats the last value; 5 phrases is where speech is long enough
# that generation is never the bottleneck again.
THAI_CHUNK_RAMP = (1, 2, 3, 5)


def chunk_text_thai(text: str) -> list[str]:
    phrases = [p for p in text.split() if p]
    if not phrases:
        return []
    chunks, i, step = [], 0, 0
    while i < len(phrases):
        take = THAI_CHUNK_RAMP[min(step, len(THAI_CHUNK_RAMP) - 1)]
        chunks.append(" ".join(phrases[i : i + take]))
        i += take
        step += 1
    return chunks


def chunk_text(text: str) -> list[str]:
    if THAI.search(text):
        return chunk_text_thai(text)
    sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", text) if s.strip()]
    if not sentences:
        return []

    first = sentences.pop(0)
    while len(first.split()) < 2 and sentences:  # never a 1-word stub
        first += " " + sentences.pop(0)

    # Cut a long opening sentence at its first clause boundary (comma / dash).
    remainder = ""
    if len(first.split()) > FIRST_MAX_WORDS:
        m = re.search(r"[,;:]|\s[—–-]\s", first)
        if m:
            head = first[: m.end()].rstrip(" ,;:—–-")
            if 2 <= len(head.split()) <= FIRST_MAX_WORDS:
                remainder = first[m.end():].strip()
                first = head

    chunks = [first]
    cur = ""
    for sent in ([remainder] if remainder else []) + sentences:
        cur = (cur + " " + sent).strip()
        if len(cur.split()) >= LATER_MIN_WORDS:
            chunks.append(cur)
            cur = ""
    if cur:
        chunks.append(cur)
    return chunks
