#!/usr/bin/env python3
"""Barge-in detector for the TTS watcher (designed with Lee 2026-09-01).

    HOLD present → the watcher kills current playback (barge-in) and starts
                   nothing new; queued messages from other teams SURVIVE.
    HOLD gone    → the queue resumes in arrival order.

ONLY option+space barges in (Lee's rule, 2026-09-03). Handy is the only app
that opens the mic on that key, so the queue is held while — and only while —
Handy is capturing. Any other app on the mic (Discord, Zoom, Meet, a browser
tab) is ignored completely; for a real meeting the 🔊 mute button is one click
and is the deliberate control.

🔴 Why this was rewritten: the first version read one device-level flag
(kAudioDevicePropertyDeviceIsRunningSomewhere on the default input), which
cannot tell a 300 ms push-to-talk from a voice channel left open. On 2026-09-03
Discord connected at 14:17:03, the flag pinned true, and the voice system went
silent with six messages queued and NOTHING anywhere saying why — every other
signal (daemon pulse, mute files, volume) was green.

Attribution comes from CoreAudio's process objects (macOS 14.2+):
kAudioHardwarePropertyProcessObjectList + kAudioProcessPropertyIsRunningInput
give the exact capturing pid, so "who" is a fact and not a guess. Without them
(an older macOS) the holder cannot be identified, so nothing holds the queue —
option+space is the only rule, and a rule that cannot be checked is not applied.

Reading either signal needs NO microphone permission — it is status, not
capture, so it works under launchd (TCC grants never attach there).

Single instance via pidfile. Spawned by watcher.sh; safe to run standalone.
"""

import ctypes
import ctypes.util
import json
import os
import signal
import struct
import subprocess
import sys
import time

TTS_HOME = os.path.expanduser("~/.claude/tts")
HOLD = os.path.join(TTS_HOME, "HOLD")
PIDFILE = os.path.join(TTS_HOME, "mic_hold.pid")
STATE = os.path.join(TTS_HOME, "mic_hold.state")
LOG = os.path.join(TTS_HOME, "mic_hold.log")
POLL_SEC = 0.1
# Handy needs a beat to transcribe + insert after key release; resuming the
# instant the mic closes had Emma talking over the inserted text being read.
RELEASE_GRACE_SEC = 1.0
# The only capture that may hold the queue: Handy, which owns option+space.
# Matched case-insensitively as a substring of the executable path.
DICTATION_APPS = ("handy",)

ca = ctypes.CDLL(ctypes.util.find_library("CoreAudio"))


class PropertyAddress(ctypes.Structure):
    _fields_ = [
        ("mSelector", ctypes.c_uint32),
        ("mScope", ctypes.c_uint32),
        ("mElement", ctypes.c_uint32),
    ]


def fourcc(code: str) -> int:
    return int.from_bytes(code.encode("ascii"), "big")


SYSTEM_OBJECT = 1  # kAudioObjectSystemObject
GLOBAL = fourcc("glob")
ADDR_DEFAULT_INPUT = PropertyAddress(fourcc("dIn "), GLOBAL, 0)
ADDR_RUNNING_SOMEWHERE = PropertyAddress(fourcc("gone"), GLOBAL, 0)
ADDR_PROCESS_LIST = PropertyAddress(fourcc("prs#"), GLOBAL, 0)
ADDR_PROCESS_PID = PropertyAddress(fourcc("ppid"), GLOBAL, 0)
ADDR_RUNNING_INPUT = PropertyAddress(fourcc("piri"), GLOBAL, 0)


def log(msg: str) -> None:
    try:
        with open(LOG, "a") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    except OSError:
        pass


def get_bytes(object_id, addr, size):  # -> bytes or None
    buf = ctypes.create_string_buffer(size)
    got = ctypes.c_uint32(size)
    status = ca.AudioObjectGetPropertyData(
        ctypes.c_uint32(object_id), ctypes.byref(addr), 0, None,
        ctypes.byref(got), buf)
    return buf.raw[:got.value] if status == 0 else None


def get_u32(object_id, addr):  # -> int or None (system python is 3.9)
    raw = get_bytes(object_id, addr, 4)
    return struct.unpack("<I", raw)[0] if raw and len(raw) == 4 else None


def proc_name(pid):
    try:
        out = subprocess.run(["ps", "-o", "command=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=2).stdout
    except Exception:
        return ""
    return out.strip()


def capturing_pid():
    """(pid, command) of a process capturing input, or (None, None).

    None also means "process objects unavailable" — the caller then falls back
    to the device flag, so an older macOS keeps the old behaviour instead of
    losing barge-in entirely.
    """
    raw = get_bytes(SYSTEM_OBJECT, ADDR_PROCESS_LIST, 8192)
    if not raw:
        return None, None
    for obj in struct.unpack("<%dI" % (len(raw) // 4), raw):
        if not get_u32(obj, ADDR_RUNNING_INPUT):
            continue
        pid_raw = get_bytes(obj, ADDR_PROCESS_PID, 4)
        pid = struct.unpack("<i", pid_raw)[0] if pid_raw and len(pid_raw) == 4 else -1
        return pid, proc_name(pid)
    return 0, ""            # process objects work, nobody is capturing


def device_mic_in_use() -> bool:
    """Fallback signal: the default input device is running for someone."""
    device = get_u32(SYSTEM_OBJECT, ADDR_DEFAULT_INPUT)
    if not device:  # no input device / query failed → never hold the queue
        return False
    return bool(get_u32(device, ADDR_RUNNING_SOMEWHERE))


def is_dictation(command: str) -> bool:
    low = (command or "").lower()
    return any(app in low for app in DICTATION_APPS)


def write_state(holding, holder, since, reason):
    """Why the queue is (not) held, for the Monitor — the 09-03 outage was
    invisible precisely because nothing published this."""
    payload = {"at": time.time(), "holding": holding, "holder": holder,
               "since": since, "reason": reason}
    tmp = STATE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, STATE)
    except OSError:
        pass


def main() -> None:
    # Single instance.
    if os.path.exists(PIDFILE):
        try:
            os.kill(int(open(PIDFILE).read().strip()), 0)
            sys.exit(0)  # already running
        except (OSError, ValueError):
            pass
    with open(PIDFILE, "w") as f:
        f.write(str(os.getpid()))

    def cleanup(*_):
        for p in (HOLD, PIDFILE):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass
        write_state(False, "", 0.0, "detector stopped")
        sys.exit(0)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    holding = False
    released_at = 0.0
    capture_pid = 0          # pid of the capture we are currently tracking
    capture_started = 0.0
    logged_ignore = False    # log an ignored capture once, not 10x a second
    log("started (option+space only: holds for Handy, ignores every other capture)")

    while True:
        pid, command = capturing_pid()
        if pid is None:                      # no process objects on this OS
            in_use = device_mic_in_use()
            pid, command = (-1, "unknown (device flag)") if in_use else (0, "")
        else:
            in_use = bool(pid)

        if pid != capture_pid:               # a different capture began/ended
            capture_pid = pid
            capture_started = time.monotonic() if pid else 0.0
            logged_ignore = False
            if pid:
                log("capture by pid %s: %s" % (pid, (command or "?")[:120]))

        # Lee's rule, 2026-09-03: barge in ONLY for option+space. Handy is the
        # only thing that opens the mic on that key, so "the capturing process is
        # Handy" IS the key press — nothing else may touch the queue.
        want_hold = in_use and is_dictation(command)
        if not in_use:
            reason = ""
        elif want_hold:
            reason = "dictation (option+space)"
        else:
            who = os.path.basename((command or "?").split(" ")[0])[:40]
            reason = "%s is using the mic — ignored, only option+space barges in" % who
            if not logged_ignore:
                logged_ignore = True
                log("ignoring capture by pid %s (%s): not dictation" % (pid, who))

        if want_hold and not holding:
            open(HOLD, "w").close()
            holding = True
            released_at = 0.0
        elif not want_hold and holding:
            if not released_at:
                released_at = time.monotonic()
            elif time.monotonic() - released_at >= RELEASE_GRACE_SEC:
                try:
                    os.unlink(HOLD)
                except FileNotFoundError:
                    pass
                holding = False
                released_at = 0.0
        if want_hold:
            released_at = 0.0

        # wall-clock start of this capture, derived from the monotonic mark so a
        # clock change cannot make it read as the future
        since = (time.time() - (time.monotonic() - capture_started)) if capture_started else 0.0
        write_state(holding, (command or "")[:200], since,
                    reason or ("idle" if not in_use else ""))
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()
