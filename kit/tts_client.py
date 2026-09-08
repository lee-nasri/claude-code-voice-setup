#!/usr/bin/env python3
"""Tiny stdlib-only client for kokoro_daemon.py (fast startup, no imports).

Usage: tts_client.py <socket> <cache_wav> <voice>   (text on stdin)
Blocks until the daemon says "done". Killing this process (watcher mute path)
drops the connection, which the daemon reads as stop-playback-now.
Exit 0 = spoken; nonzero = daemon unreachable/failed (caller falls back)."""
import json
import socket
import sys

try:
    sock_path, cache, voice = sys.argv[1], sys.argv[2], sys.argv[3]
    text = sys.stdin.read()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sock_path)
    s.sendall((json.dumps({"cmd": "speak", "cache": cache, "voice": voice,
                           "text": text}) + "\n").encode())
    # Playback takes as long as it takes, so there is no sane fixed timeout —
    # but waiting FOREVER is what froze the whole queue on 2026-09-02: a
    # SIGSTOPped daemon left this client blocked, so speak.sh never returned and
    # the watcher never started another message. Wait in hops and give up only
    # when the daemon's own heartbeat has gone stale (kokoro_daemon.py writes
    # daemon.status every ~10s), which a healthy daemon can never do however
    # long it is speaking. Exiting nonzero sends speak.sh to the cold path, so
    # the message is still spoken.
    import json as _json
    import os
    import time
    status = os.path.join(os.path.dirname(os.path.abspath(sock_path)),
                          "daemon.status")
    while True:
        s.settimeout(5)
        try:
            sys.exit(0 if s.recv(16).startswith(b"done") else 1)
        except socket.timeout:
            pass
        try:
            with open(status) as f:
                age = time.time() - float(_json.load(f).get("at", 0))
        except Exception:
            age = 0          # no heartbeat file: keep waiting, do not guess
        if age > 45:
            sys.exit(1)      # frozen or gone — free the queue
except Exception:
    sys.exit(1)
