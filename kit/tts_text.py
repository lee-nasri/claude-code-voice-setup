"""Shared sentence chunking for the Kokoro speakers (daemon + fallback stream).

First chunk is deliberately small (first clause, <=10 words) so first sound
lands fast; later chunks are big (~25+ words) so each buys generation time
for its successor (gap rule from 2026-08-17 tuning).
"""
import re

FIRST_MAX_WORDS = 10
LATER_MIN_WORDS = 25


def chunk_text(text: str) -> list[str]:
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
