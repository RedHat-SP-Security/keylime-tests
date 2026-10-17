#!/usr/bin/env python3
"""Coverage-guided atheris harness for keylime runtime-policy/DSSE parsing (keylime#1139).

The parser to drive is selected with the FUZZ_TARGET environment variable
(one of: runtime_policy, deserialize_policy, dsse_envelope) because atheris
consumes sys.argv for its libFuzzer options.

Two modes (FUZZ_SURVEY, default "1"):

  * SURVEY mode (default) - the campaign must keep running for the full
    -max_total_time so one bounded run enumerates *all distinct* crash
    signatures, not just the first. A finding therefore must NOT crash the
    process (that would stop the campaign) and must NOT look "boring" to
    libFuzzer (or coverage-guided exploration past the crash would stall). So we
    catch the finding, record a de-duplicated signature + reproducer under
    FUZZ_CRASH_DIR, and return. libFuzzer keeps the input in its corpus if it hit
    new coverage, so it mutates onward toward the *next* distinct bug. atheris's
    own -fork mode is unusable here (coverage does not survive the fork), which
    is why we dedup in-process instead.

  * strict mode (FUZZ_SURVEY=0) - mirror replay.py exactly: the first finding
    propagates and libFuzzer records a classic crash reproducer and stops. Handy
    for minimizing a single reproducer.

All decoding and the accept policy (ALLOWED) still live in fuzz_targets so this
harness and replay.py stay in lockstep.

Usage (driven by test.sh):
    FUZZ_TARGET=runtime_policy FUZZ_CRASH_DIR=DIR python3 fuzz_harness.py \
        -max_total_time=600 -timeout=10 -rss_limit_mb=2048 \
        -artifact_prefix=ARTDIR/ SEED_CORPUS_DIR
"""

import os
import re
import sys
import traceback

import atheris

TARGET = os.environ.get("FUZZ_TARGET", "runtime_policy")
SURVEY = os.environ.get("FUZZ_SURVEY", "1") == "1"
CRASH_DIR = os.environ.get("FUZZ_CRASH_DIR", "")

# Instrument keylime (imported transitively by fuzz_targets) so atheris gets
# coverage feedback from the parsers under test.
with atheris.instrument_imports():
    import fuzz_targets

if TARGET not in fuzz_targets.TARGETS:
    sys.exit(f"unknown FUZZ_TARGET={TARGET!r}, expected one of {fuzz_targets.TARGETS}")

# Distinct findings already recorded this run (survey mode), so each bug is
# written once. In-process set, which is why we must not fork.
_seen = set()


def _record(sig, data, exc):
    """Persist a newly-seen finding: its signature, reproducer input and trace."""
    sys.stderr.write(f"[survey] new finding #{len(_seen)}: {sig}\n")
    if not CRASH_DIR:
        return
    try:
        os.makedirs(CRASH_DIR, exist_ok=True)
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", sig)
        base = os.path.join(CRASH_DIR, f"{TARGET}__{safe}")
        with open(base + ".input", "wb") as f:
            f.write(bytes(data))
        with open(base + ".trace", "w", encoding="utf-8") as f:
            f.write(sig + "\n\n")
            f.write("".join(traceback.format_exception(type(exc), exc, exc.__traceback__)))
        # One line per distinct signature; test.sh reads this to count findings.
        with open(os.path.join(CRASH_DIR, f"{TARGET}.signatures"), "a", encoding="utf-8") as f:
            f.write(sig + "\n")
    except Exception:  # pragma: no cover - best effort, never kill the campaign
        pass


def TestOneInput(data):
    if not SURVEY:
        # Strict: first finding propagates and stops the campaign (replay parity).
        fuzz_targets.run_one(TARGET, data)
        return

    # Survey: swallow findings after recording, so the campaign runs on.
    try:
        fuzz_targets._call(TARGET, bytes(data))
    except fuzz_targets.ALLOWED[TARGET]:
        # Controlled validation error - graceful, not a finding.
        return
    except Exception as exc:  # noqa: BLE001 - every escaping Exception is a finding
        sig = fuzz_targets.classify_exception(exc)
        if sig not in _seen:
            _seen.add(sig)
            _record(sig, data, exc)
        # Swallowed on purpose: keep exploring toward the next distinct bug. A
        # hang or segfault is still fatal and ends the campaign (handled by
        # test.sh via libFuzzer's -timeout / artifact files).


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
