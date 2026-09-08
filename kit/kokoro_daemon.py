#!/usr/bin/env python3
"""Persistent Kokoro TTS daemon — keeps the model warm so each message skips
the ~1.2s Python-import + model-load cost that kokoro_stream.py pays.

Protocol (unix socket ~/.claude/tts/daemon.sock, one JSON line per request):
  {"cmd": "speak", "cache": "/path/out.wav", "voice": "bf_emma", "text": "..."}
Daemon replies "done\n" when playback finishes. If the CLIENT DISCONNECTS
mid-playback (watcher's mute path kills the client), playback stops instantly —
that preserves the instant-mute semantics without touching watcher.sh.

  start:  nohup ~/.claude/tts/kokoro-venv/bin/python ~/.claude/tts/kokoro_daemon.py &
  stop:   pkill -f kokoro_daemon.py
"""
import ctypes
import ctypes.util
import json
import os
import socket
import sys
import threading
import time

import numpy as np
import sounddevice as sd
import soundfile as sf
from scipy.signal import resample_poly

from kokoro_onnx import Kokoro
from tts_text import chunk_text

HOME = os.path.dirname(os.path.abspath(__file__))
SOCK_PATH = os.path.join(HOME, "daemon.sock")
SR = 24000
PLAY_SLICE = 4096  # frames per write, so a disconnect check runs ~5x/second


def device_rate() -> int:
    # Re-queried per message: Lee switches between speakers and an unmatched
    # rate is the Pebble-V3 hiss bug (see kokoro_stream.py history).
    try:
        return int(sd.query_devices(kind="output")["default_samplerate"]) or SR
    except Exception:
        return SR


def reset_portaudio(why: str) -> None:
    """Drop PortAudio's cached device state. Same recovery the August -9986 fix
    used; here it also runs after abandoning a wedged message, because the
    device the stuck stream was writing to is the prime suspect."""
    print(f"[daemon] resetting PortAudio ({why})", flush=True)
    try:
        sd._terminate()
        sd._initialize()
    except Exception as e:
        print(f"[daemon] PortAudio reset failed: {e}", flush=True)


_last_device = None


def coreaudio_default_output() -> int:
    """The system default output device ID, read straight from CoreAudio.

    🔴 It must NOT come from sounddevice: measured 2026-09-02 in a long-lived
    process, `sd.query_devices(kind="output")` kept returning the SAME name
    across two real device switches (UGREEN → MacBook → UGREEN) while CoreAudio
    reported 120 → 74 → 120. PortAudio's cache is the thing we are detecting, so
    asking PortAudio whether it is stale is circular — that was the first
    version of this check and it never fired once.
    """
    try:
        ca = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))

        class Addr(ctypes.Structure):
            _fields_ = [("mSelector", ctypes.c_uint32),
                        ("mScope", ctypes.c_uint32),
                        ("mElement", ctypes.c_uint32)]

        def fourcc(s):
            return int.from_bytes(s.encode("ascii"), "big")

        dev = ctypes.c_uint32(0)
        size = ctypes.c_uint32(4)
        addr = Addr(fourcc("dOut"), fourcc("glob"), 0)   # kAudioHardwarePropertyDefaultOutputDevice
        if ca.AudioObjectGetPropertyData(ctypes.c_uint32(1), ctypes.byref(addr),
                                         0, None, ctypes.byref(size),
                                         ctypes.byref(dev)) != 0:
            return 0
        return dev.value
    except Exception:
        return 0


def open_stream():
    """Open the output stream, re-initialising PortAudio if its state went stale.

    A long-lived process caches the device list at import; after the default
    output changes (sleep/wake, headphones, a speaker connecting) every open
    fails with PaErrorCode -9986 forever. That silently cost 294 of 314
    messages between 2026-08-19 and 08-22 — the process stayed alive, so it
    looked healthy while every message took the slow fallback path.

    🔴 2026-09-02: recovering only when the open RAISES is not enough. Lee
    docked at a different desk and EVERY device changed under a 12h-old daemon;
    the open kept succeeding against a stale index, so audio went nowhere with
    a clean heartbeat and no error — silence that no signal could show. So the
    device is now compared BY NAME every message and a change forces the
    re-init before opening, instead of waiting for a failure that never comes.
    """
    global _last_device
    dev = coreaudio_default_output()
    if _last_device and dev and dev != _last_device:
        print(f"[daemon] default output changed: {_last_device} -> {dev}",
              flush=True)
        reset_portaudio("output device changed")
    _last_device = dev or _last_device

    try:
        rate = device_rate()
        return sd.OutputStream(samplerate=rate, channels=1, dtype="float32",
                               blocksize=2048, latency="high"), rate
    except Exception as e:
        print(f"[daemon] stream open failed ({e}) — reinitialising PortAudio", flush=True)
        sd._terminate()
        sd._initialize()
        rate = device_rate()
        return sd.OutputStream(samplerate=rate, channels=1, dtype="float32",
                               blocksize=2048, latency="high"), rate


STATUS_PATH = os.path.join(HOME, "daemon.status")
HEARTBEAT_SEC = 10

# Phase, not a verdict. The old write_status() was called only at the END of a
# request and inside handle()'s except, so it was a receipt for the last
# completed message: a daemon quiet all night and a daemon wedged since
# yesterday wrote a byte-identical `{"ok": true}`, and a wedge (which neither
# returns nor raises) reached neither call site. 2026-09-02 went mute for 10h
# behind that green. This is a pulse instead — a clock-driven thread reports
# where the daemon IS, and the reader decides.
STATE = {"phase": "idle", "since": time.time(), "progress": time.time(),
         "last_error": "", "last_error_at": 0.0}
STATE_LOCK = threading.Lock()


def set_phase(phase: str, error: str = None) -> None:
    """Records the transition AND flushes it. Without the flush the file lagged
    up to HEARTBEAT_SEC behind reality — measured: it still read `playing` after
    a message had already been abandoned, which is a smaller version of exactly
    the lie this whole change removes."""
    with STATE_LOCK:
        STATE["phase"] = phase
        STATE["since"] = time.time()
        STATE["progress"] = time.time()
        if error is not None:
            # kept after recovery on purpose — it is the only record of what
            # happened overnight — but stamped, so a reader can tell a live
            # fault from a scar
            STATE["last_error"] = error
            STATE["last_error_at"] = time.time()
    write_status()          # outside the lock: write_status takes it too


def mark_progress() -> None:
    """Called after every completed audio write — the anti-wedge evidence."""
    with STATE_LOCK:
        STATE["progress"] = time.time()


def write_status() -> None:
    """Atomic: temp file + os.replace, so a reader never parses half a file and
    never restarts a healthy daemon because JSON was truncated mid-write."""
    with STATE_LOCK:
        payload = {"at": time.time(), "phase": STATE["phase"],
                   "busy_for": round(time.time() - STATE["since"], 1),
                   "stalled_for": round(time.time() - STATE["progress"], 1),
                   "pid": os.getpid(), "last_error": STATE["last_error"],
                   "last_error_at": STATE["last_error_at"]}
    tmp = f"{STATUS_PATH}.tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, STATUS_PATH)
    except OSError:
        pass


def heartbeat() -> None:
    """Ticks regardless of what the daemon is doing. A stale `at` therefore
    means the process is gone or frozen — the one thing nothing could see."""
    while True:
        write_status()
        time.sleep(HEARTBEAT_SEC)


def to_rate(samples: np.ndarray, out_sr: int) -> np.ndarray:
    if out_sr == SR:
        return samples
    g = np.gcd(out_sr, SR)
    return resample_poly(samples, out_sr // g, SR // g).astype(np.float32)


def client_gone(conn: socket.socket) -> bool:
    try:
        conn.setblocking(False)
        return conn.recv(1) == b""
    except BlockingIOError:
        return False
    except OSError:
        return True
    finally:
        try:
            conn.setblocking(True)
        except OSError:
            pass


SPEED_CONF = f"{HOME}/speed.conf"


def speech_speed() -> float:
    """Playback rate, re-read per message so the Monitor's dropdown takes effect
    without a daemon restart. File wins, then TTS_SPEED, then 1.25."""
    try:
        with open(SPEED_CONF) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    return min(2.5, max(0.5, float(line)))
    except (OSError, ValueError):
        pass
    try:
        return min(2.5, max(0.5, float(os.environ.get("TTS_SPEED", "1.25"))))
    except ValueError:
        return 1.25


k = Kokoro(f"{HOME}/kokoro-v1.0.onnx", f"{HOME}/voices-v1.0.bin")
k.create("Warm up.", voice="bf_emma", speed=speech_speed(), lang="en-gb")
speak_lock = threading.Lock()  # watcher serializes anyway; belt and braces

# Sized from daemon.err, not taste. Longest real message so far: 4,122 chars /
# 23 chunks ≈ 4.4 min of speech; worst first-audio 3.6s; a PLAY_SLICE write is
# 0.17s of audio.
LOCK_WAIT = 30      # the watcher sends one at a time, so waiting means trouble
MSG_DEADLINE = 600  # 2.3x the longest legitimate message
STALL_LIMIT = 45    # no completed write for this long = wedged (260x a slice)
GEN_LIMIT = 120     # no chunk out of the generator for this long = wedged


def play(conn: socket.socket, req: dict, chunks, stop: threading.Event,
         box: dict) -> None:
    """Generate + play. Runs in its own thread so the caller can give up on it:
    out.write() cannot be interrupted, so the only way a wedged write costs one
    message instead of the daemon is to stop WAITING for it."""
    import queue as q_mod

    t0 = time.time()
    q: "q_mod.Queue[np.ndarray | None]" = q_mod.Queue(maxsize=4)

    def produce():
        try:
            for chunk in chunks:
                if stop.is_set():
                    break
                samples, _ = k.create(chunk, voice=req["voice"],
                                      speed=speech_speed(), lang="en-gb")
                q.put(np.asarray(samples, dtype=np.float32))
        except Exception as e:
            print(f"[daemon] generate failed: {e}", flush=True)
            set_phase("generating", f"generate: {e}")
        q.put(None)

    threading.Thread(target=produce, daemon=True).start()

    set_phase("generating")
    stream, out_sr = open_stream()
    box["stream"] = stream
    played = []
    first_logged = False
    with stream as out:
        while not stop.is_set():
            try:
                samples = q.get(timeout=GEN_LIMIT)
            except Exception:
                set_phase("generating", f"no chunk within {GEN_LIMIT}s")
                break
            if samples is None:
                break
            if not first_logged:
                print(f"[daemon] first-audio {time.time() - t0:.2f}s "
                      f"chunks={len(chunks)} chars={len(req['text'])}", flush=True)
                first_logged = True
                set_phase("playing")
            played.append(samples)  # cache keeps original 24 kHz audio
            buf = to_rate(samples, out_sr).reshape(-1, 1)
            for i in range(0, len(buf), PLAY_SLICE):
                if client_gone(conn):  # mute: watcher killed the client
                    stop.set()
                    break
                out.write(buf[i : i + PLAY_SLICE])
                mark_progress()

    if played and not stop.is_set():
        sf.write(req["cache"], np.concatenate(played), SR,
                 format="WAV", subtype="PCM_16")
    box["done"] = True


def speak(conn: socket.socket, req: dict) -> None:
    chunks = chunk_text(req["text"])
    if not chunks:
        conn.sendall(b"done\n")
        return

    stop = threading.Event()
    box: dict = {"done": False, "stream": None}
    worker = threading.Thread(target=play, args=(conn, req, chunks, stop, box),
                              daemon=True)
    worker.start()

    # Wait in short hops so a stall is caught by lack of PROGRESS, not only by
    # the total deadline: a message that legitimately plays for four minutes and
    # one frozen on its first write both exceed a naive timer, only one of them
    # keeps completing writes.
    started = time.time()
    while worker.is_alive():
        worker.join(1)
        with STATE_LOCK:
            stalled = time.time() - STATE["progress"]
        over = time.time() - started > MSG_DEADLINE
        if stalled > STALL_LIMIT or over:
            why = (f"deadline {MSG_DEADLINE}s exceeded" if over
                   else f"no audio progress for {int(stalled)}s")
            print(f"[daemon] abandoning message — {why}", flush=True)
            stop.set()
            try:                       # may unblock the stuck write, may raise
                if box["stream"] is not None:
                    box["stream"].abort(ignore_errors=True)
                    box["stream"].close(ignore_errors=True)
            except Exception as e:
                print(f"[daemon] stream close failed: {e}", flush=True)
            reset_portaudio(why)
            set_phase("idle", why)
            try:
                conn.sendall(b"dropped\n")
            except OSError:
                pass
            return                     # one message lost; daemon stays usable

    set_phase("idle")
    try:
        conn.sendall(b"done\n")
    except OSError:
        pass


def handle(conn: socket.socket) -> None:
    try:
        line = conn.makefile("rb").readline()
        req = json.loads(line)
        cmd = req.get("cmd")
        if cmd == "testhold":
            # Test hook: hold the lock so the refusal path can be PROVEN rather
            # than reasoned about. Not reachable from speak.sh.
            secs = min(120, max(1, int(req.get("secs", 10))))
            print(f"[daemon] testhold {secs}s", flush=True)
            with speak_lock:
                conn.sendall(b"holding\n")
                time.sleep(secs)
            return
        if cmd != "speak":
            return
        # Bounded, so a wedged predecessor costs this message a refusal instead
        # of hanging its client forever (2026-09-02: a client waited with no
        # reply, no error and no log line).
        if not speak_lock.acquire(timeout=LOCK_WAIT):
            print(f"[daemon] refused: busy > {LOCK_WAIT}s", flush=True)
            set_phase(STATE["phase"], f"refused a request after {LOCK_WAIT}s busy")
            try:
                conn.sendall(b"busy\n")
            except OSError:
                pass
            return
        try:
            speak(conn, req)
        finally:
            speak_lock.release()
    except Exception as e:  # one bad request must not kill the daemon
        print(f"[daemon] request failed: {e}", flush=True)
        set_phase("idle", str(e))
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> None:
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        server.bind(SOCK_PATH)
    except OSError:
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            probe.connect(SOCK_PATH)
            probe.close()
            sys.exit(0)  # live daemon already owns the socket
        except OSError:
            os.unlink(SOCK_PATH)  # stale socket from a killed daemon
            server.bind(SOCK_PATH)
    server.listen(4)
    threading.Thread(target=heartbeat, daemon=True).start()
    print("[daemon] ready", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
