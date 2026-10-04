#!/usr/bin/env python3
"""Find a recording's match windows and EVE time base with ScrimTrimmer.

Called by `scrim-positions --chat-log`. Uses the ScrimTrimmer submodule
(third_party/ScrimTrimmer) unchanged:

  - t0 (EVE time at video second 0) from `log_matcher.detect_t0`, which matches
    the Local chat log against OCR of the chat region, or from `--t0`;
  - CD / WF (GF) video seconds from `chat_log_parser.parse_chat_logs`, paired by
    `chat_analyzer.pair_cd_wf`.

Prints one JSON object on stdout; everything else goes to stderr:

  {"t0_utc": "2026-04-04T17:43:55Z", "t0_source": "auto", "duration_s": 41.0,
   "pairs": [[4, 38]]}

`t0_utc` is a full UTC date and time: ScrimTrimmer's t0 is seconds since
midnight, and the date comes from the chat log.
"""

import argparse
import contextlib
import json
import os
import sys
from datetime import datetime, timedelta, timezone

TRIMMER_SRC = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "third_party", "ScrimTrimmer", "src"
)


def _import_trimmer():
    if not os.path.isdir(TRIMMER_SRC):
        sys.exit(
            f"ScrimTrimmer not found at {os.path.normpath(TRIMMER_SRC)}; "
            "run `git submodule update --init`"
        )
    sys.path.insert(0, TRIMMER_SRC)
    try:
        import chat_analyzer
        import chat_log_parser
        import frame_extractor
        import log_matcher
    except ImportError as e:
        sys.exit(f"{e}; install the bridge's Python deps: pip install -r scripts/requirements-trimmer.txt")
    return chat_analyzer, chat_log_parser, frame_extractor, log_matcher


def t0_datetime(t0_sec: int, log_first: datetime) -> datetime:
    """The UTC datetime whose time of day is `t0_sec`, on whichever of the day before, of or
    after the log's first entry puts it nearest that entry (the log may cross midnight)."""
    midnight = log_first.replace(hour=0, minute=0, second=0, microsecond=0)
    candidates = [midnight + timedelta(days=d, seconds=t0_sec) for d in (-1, 0, 1)]
    return min(candidates, key=lambda c: abs((c - log_first).total_seconds()))


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("video")
    p.add_argument("--chat-log", action="append", required=True, dest="chat_logs")
    p.add_argument(
        "--chat-region", type=float, nargs=4, metavar=("X1", "Y1", "X2", "Y2"),
        help="chat window as fractions of the frame (left top right bottom); needed unless --t0",
    )
    p.add_argument("--t0", metavar="HH:MM:SS", help="EVE time at video second 0 (skips detection)")
    p.add_argument(
        "--sample-interval", type=int, default=2, metavar="S",
        help="OCR one chat frame every S seconds when detecting t0 (default 2). t0 is a lower "
        "bound found from when messages first appear, so sparser sampling makes it late-biased",
    )
    p.add_argument("--tournament", action="store_true", help="tournament start/end system messages")
    p.add_argument("--no-detect-countdown", action="store_false", dest="detect_countdown")
    p.add_argument("--verbose", "-v", action="store_true")
    args = p.parse_args()

    chat_analyzer, chat_log_parser, frame_extractor, log_matcher = _import_trimmer()

    entries = [e for path in args.chat_logs for e in chat_log_parser.read_chat_log(path)]
    if not entries:
        sys.exit("no chat lines found in " + ", ".join(args.chat_logs))
    log_first = min(ts for ts, _, _ in entries)

    duration = frame_extractor.probe_duration(args.video)
    if duration is None:
        duration = frame_extractor.get_video_duration(args.video)

    # ScrimTrimmer prints progress on stdout; keep stdout for the JSON.
    with contextlib.redirect_stdout(sys.stderr):
        if args.t0:
            t0_sec = chat_log_parser.game_time_to_seconds(args.t0)
            source = "provided"
        else:
            if args.chat_region is None:
                sys.exit("--chat-region is required to detect t0 (or pass --t0)")
            try:
                t0_sec = log_matcher.detect_t0(
                    args.chat_logs, args.video, chat_region=tuple(args.chat_region),
                    sample_interval=args.sample_interval, verbose=args.verbose,
                )
            except (RuntimeError, ValueError) as e:
                sys.exit(str(e))
            source = "auto"
        cd, wf = chat_log_parser.parse_chat_logs(
            args.chat_logs, t0_sec, duration,
            tournament_mode=args.tournament, detect_countdown=args.detect_countdown,
        )
        pairs = chat_analyzer.pair_cd_wf(cd, wf)
        print(f"  t0 {t0_sec} s ({source}); CDs {cd}; WFs {wf}; pairs {pairs}")

    t0 = t0_datetime(t0_sec, log_first).astimezone(timezone.utc)
    json.dump(
        {
            "t0_utc": t0.strftime("%Y-%m-%dT%H:%M:%SZ"),
            "t0_source": source,
            "duration_s": duration,
            "pairs": [[int(a), int(b)] for a, b in pairs],
        },
        sys.stdout,
    )
    print()


if __name__ == "__main__":
    main()
