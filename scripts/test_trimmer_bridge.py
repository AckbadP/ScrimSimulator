"""Tests for scrim_trimmer_bridge.py against ScrimTrimmer's own test recordings.

    python3 -m unittest scripts/test_trimmer_bridge.py

Skipped when the submodule, tesseract or the Python deps are missing.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import unittest
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "scrim_trimmer_bridge.py")
RES = os.path.join(HERE, "..", "third_party", "ScrimTrimmer", "src", "tests", "resources")
# The cases' Local chat panel: pixels (0, 312)-(192, 738) of the 1280x800 frame.
CHAT_REGION = ["0", str(312 / 800), str(192 / 1280), str(738 / 800)]

sys.path.insert(0, HERE)
from scrim_trimmer_bridge import t0_datetime  # noqa: E402

HAVE_DEPS = (
    os.path.isdir(RES)
    and shutil.which("tesseract") is not None
    and shutil.which("ffprobe") is not None
    and all(importlib.util.find_spec(m) for m in ("cv2", "numpy", "pytesseract", "PIL"))
)


def run_bridge(case: int, *extra: str) -> dict:
    out = subprocess.run(
        [sys.executable, BRIDGE, os.path.join(RES, f"case{case}.mkv"),
         "--chat-log", os.path.join(RES, f"case{case}.txt"), *extra],
        check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    return json.loads(out.stdout)


class T0Date(unittest.TestCase):
    def utc(self, *a):
        return datetime(*a, tzinfo=timezone.utc)

    def test_same_day(self):
        self.assertEqual(t0_datetime(63835, self.utc(2026, 4, 4, 17, 42, 57)),
                         self.utc(2026, 4, 4, 17, 43, 55))

    def test_log_starts_after_midnight_recording_before(self):
        self.assertEqual(t0_datetime(86390, self.utc(2026, 4, 5, 0, 0, 5)),
                         self.utc(2026, 4, 4, 23, 59, 50))

    def test_log_starts_before_midnight_recording_after(self):
        self.assertEqual(t0_datetime(10, self.utc(2026, 4, 4, 23, 59, 30)),
                         self.utc(2026, 4, 5, 0, 0, 10))


@unittest.skipUnless(HAVE_DEPS, "needs the ScrimTrimmer submodule, tesseract, ffprobe and Python deps")
class Bridge(unittest.TestCase):
    def test_detects_t0_and_match(self):
        out = run_bridge(6, "--chat-region", *CHAT_REGION)
        self.assertEqual(out["t0_utc"], "2026-04-04T18:01:54Z")
        self.assertEqual(out["t0_source"], "auto")
        self.assertEqual(out["pairs"], [[73, 109]])

    def test_provided_t0_lists_every_match(self):
        out = run_bridge(3, "--t0", "17:52:22")
        self.assertEqual(out["t0_utc"], "2026-04-04T17:52:22Z")
        self.assertEqual(out["t0_source"], "provided")
        self.assertEqual(out["pairs"], [[8, 41], [59, 95]])


if __name__ == "__main__":
    unittest.main()
