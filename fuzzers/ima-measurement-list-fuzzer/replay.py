#!/usr/bin/env python3
"""Atheris-independent corpus replayer for the keylime IMA line parser.

This is the always-available half of the fuzzer test. It feeds every file in a
corpus directory through the selected target using the same decoding and the
same crash policy as the atheris harness, but wraps each call in a SIGALRM
wall-clock timeout so a hang is turned into a reported failure even without
atheris.

It is used two ways by test.sh:
  * as a deterministic regression over the generated known-bad seed corpus
    (so the test does meaningful work on platforms where atheris cannot be
    built), and
  * to re-verify any crash reproducers atheris saved.

Exit status is 0 only if every input was handled gracefully (rejected with a
ParserError or parsed) and quickly.

Usage:
    python3 replay.py <target> <corpus_dir> [--timeout SECONDS]
"""

import argparse
import os
import signal
import sys
import traceback

import fuzz_targets


# Inherits BaseException (not Exception) on purpose: it is raised from the
# SIGALRM handler *inside* fuzz_targets.run_one, whose "except GRACEFUL"
# swallows declared parser rejections. A BaseException sails past that and is
# caught here, so a hang is never mistaken for graceful handling.
class Timeout(BaseException):
    pass


def _alarm(_signum, _frame):
    raise Timeout()


def replay_file(target, path, timeout):
    with open(path, "rb") as f:
        data = f.read()
    signal.signal(signal.SIGALRM, _alarm)
    signal.setitimer(signal.ITIMER_REAL, timeout)
    try:
        fuzz_targets.run_one(target, data)
        return None
    except Timeout:
        return ("HANG", f"HANG: input not processed within {timeout}s")
    except fuzz_targets.SERIOUS as e:
        return (fuzz_targets.classify_exception(e), f"RESOURCE/CRASH: {type(e).__name__}: {e}")
    except Exception as e:  # pylint: disable=broad-except
        return (
            fuzz_targets.classify_exception(e),
            "UNEXPECTED EXCEPTION (not ParserError):\n" + traceback.format_exc(),
        )
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("target", choices=fuzz_targets.TARGETS)
    ap.add_argument("corpus", help="a corpus directory or a single input file")
    ap.add_argument("--timeout", type=float, default=10.0)
    args = ap.parse_args()

    # Accept either a corpus directory or a single reproducer file.
    files = []
    if os.path.isdir(args.corpus):
        for root, _dirs, names in os.walk(args.corpus):
            for n in names:
                files.append(os.path.join(root, n))
    else:
        files.append(args.corpus)
    files.sort()

    failures = 0
    seen = {}  # signature -> count; the full traceback is printed only once each
    for path in files:
        result = replay_file(args.target, path, args.timeout)
        if result is None:
            continue
        failures += 1
        sig, detail = result
        if sig in seen:
            seen[sig] += 1
            print(f"[FAIL] {args.target} <- {path}\n       [{sig}] (duplicate finding; traceback suppressed)")
        else:
            seen[sig] = 1
            print(f"[FAIL] {args.target} <- {path}\n       [{sig}] {detail}")
    print(f"{args.target}: replayed {len(files)} inputs, {failures} failure(s), {len(seen)} distinct finding(s)")
    for sig, n in sorted(seen.items()):
        print(f"  {sig}  (x{n})")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
