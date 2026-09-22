"""Thai speech for the Kokoro stack — a SECOND model, held warm beside the English one.

Thai is not in `kokoro-v1.0.onnx` (54 voices, none Thai) and espeak-ng in this venv has no
Thai G2P, so this loads `kokoro-thai/` (kunato/wayu-kokoro-thai-v1, Apache-2.0) through
onnxruntime and phonemises with tltk. Same 24 kHz output as the English path, so callers
concatenate and play the two identically.

Imported by kokoro_daemon.py (warm, resident) and kokoro_stream.py (cold fallback + the
Monitor's preview). A failed load must never take the English voice down with it: every
entry point degrades to "not available" rather than raising at import time.
"""
from __future__ import annotations

import os
import threading

import numpy as np

HOME = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HOME, "kokoro-thai")
ONNX_DIR = os.path.join(MODEL_DIR, "onnx")
SR = 24000

# name -> (speaker id in styles.npz, the rate the voice was designed at).
# The base rate comes from the model's own roster.json, so `speed` from the
# caller scales a voice that already sounds like itself.
VOICES: dict[str, tuple[int, float]] = {
    "th_fah":     (3,  0.95),   # f_young_warm    — female, young, low, read
    "th_jane":    (4,  1.00),   # f_mid_clear     — female, mid, moderate, neutral
    "th_ton":     (8,  1.10),   # m_teen_bright   — male, teen, high, engaging
    "th_krit":    (9,  1.05),   # m_young_clear   — male, young, moderate, neutral
    "th_bank":    (11, 0.90),   # m_elderly_deep  — male, elderly, very low, read
}

_lock = threading.Lock()
_student = None
_styles: dict[int, np.ndarray] = {}
_error = ""


def is_thai_voice(voice: str) -> bool:
    return voice in VOICES


def available() -> bool:
    """True when the bundle is on disk. Does not load it."""
    return os.path.isfile(os.path.join(ONNX_DIR, "decoder_fp32.onnx"))


def load_error() -> str:
    return _error


def warm() -> bool:
    """Load the graphs and the G2P. Idempotent; returns False if unavailable."""
    global _student, _styles, _error
    if _student is not None:
        return True
    with _lock:
        if _student is not None:
            return True
        if not available():
            _error = f"no Thai bundle at {ONNX_DIR}"
            return False
        try:
            import sys
            if MODEL_DIR not in sys.path:
                sys.path.insert(0, MODEL_DIR)
            from kokoro_thai.onnx_infer import load_onnx, load_styles
            student = load_onnx(ONNX_DIR, precision="fp32")
            styles = load_styles(ONNX_DIR)
            # First call builds tltk's tables and — because of the Latin word —
            # loads misaki + spacy for the English half. Both cost seconds once.
            from kokoro_thai.onnx_infer import synth
            synth(student, "อุ่นเครื่อง warm up", styles[4], speed=1.0)
            _student, _styles, _error = student, styles, ""
            return True
        except Exception as e:                      # never take the English voice down
            _error = f"{type(e).__name__}: {e}"
            return False


def create(text: str, voice: str, speed: float = 1.0) -> np.ndarray:
    """Thai text -> float32 samples at 24 kHz. Raises if the model is unavailable."""
    if voice not in VOICES:
        raise ValueError(f"not a Thai voice: {voice}")
    if not warm():
        raise RuntimeError(f"Thai engine unavailable — {_error}")
    from kokoro_thai.onnx_infer import synth
    spk, base = VOICES[voice]
    rate = min(2.5, max(0.5, base * (speed if speed > 0 else 1.0)))
    return np.asarray(synth(_student, text, _styles[spk], speed=rate), dtype=np.float32)
