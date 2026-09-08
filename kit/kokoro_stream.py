#!/usr/bin/env python3
"""Speak text with Kokoro as ONE CONTINUOUS stream (no inter-sentence gaps).

Producer thread generates sentence chunks ahead; the main thread feeds a single
always-open audio stream, so playback never stops between chunks. Generation is
~4x faster than realtime, so after the ~1s first chunk the producer stays ahead.

Usage: kokoro_stream.py <cache_wav_path> <voice> <text...>
Writes the full concatenated wav to cache_wav_path afterwards (replay cache).
SIGTERM/SIGINT stop playback immediately (instant mute)."""
import queue
import signal
import sys
import threading

import numpy as np
import sounddevice as sd
import soundfile as sf
from scipy.signal import resample_poly

from kokoro_onnx import Kokoro

HOME = __file__.rsplit("/", 1)[0]
SR = 24000

# Play at the device's OWN rate (Lee 2026-08-17: audible hiss on the Pebble V3).
# Kokoro emits 24 kHz; the speaker runs at 44.1 kHz, so an unmatched stream made
# CoreAudio resample by 1.8375 in real time — that ratio is what produced the
# noise. Proof it was playback and not the model: the identical cached wav plays
# clean through afplay (offline conversion), and the file measures 72 dB SNR.
# resample_poly does the same conversion as an exact rational ratio (147/80).
try:
    OUT_SR = int(sd.query_devices(kind="output")["default_samplerate"]) or SR
except Exception:
    OUT_SR = SR


def to_device_rate(samples: np.ndarray) -> np.ndarray:
    if OUT_SR == SR:
        return samples
    g = np.gcd(OUT_SR, SR)
    return resample_poly(samples, OUT_SR // g, SR // g).astype(np.float32)

stop = threading.Event()


def die(*_):
    stop.set()
    sd.stop()
    sys.exit(0)


signal.signal(signal.SIGTERM, die)
signal.signal(signal.SIGINT, die)

cache_out, VOICE, text = sys.argv[1], sys.argv[2], " ".join(sys.argv[3:])

# Chunking shared with the daemon: small first clause for fast start, big
# later chunks against audible gaps (tuning history in tts_text.py).
from tts_text import chunk_text

chunks = chunk_text(text)

k = Kokoro(f"{HOME}/kokoro-v1.0.onnx", f"{HOME}/voices-v1.0.bin")
q: "queue.Queue[np.ndarray | None]" = queue.Queue(maxsize=4)


def produce():
    for chunk in chunks:
        if stop.is_set():
            break
        samples, _ = k.create(chunk, voice=VOICE, speed=1.0, lang="en-gb")
        q.put(np.asarray(samples, dtype=np.float32))
    q.put(None)


threading.Thread(target=produce, daemon=True).start()

played = []
# One always-open output stream: chunks are written back-to-back with zero gap.
# blocksize/latency are explicit: the defaults gave buffers small enough to
# underrun between chunks, which is heard as noise rather than a gap.
with sd.OutputStream(
    samplerate=OUT_SR, channels=1, dtype="float32", blocksize=2048, latency="high"
) as out:
    while not stop.is_set():
        samples = q.get()
        if samples is None:
            break
        played.append(samples)  # cache keeps the original 24 kHz audio
        out.write(to_device_rate(samples).reshape(-1, 1))

if played and not stop.is_set():
    sf.write(cache_out, np.concatenate(played), SR, format="WAV", subtype="PCM_16")
