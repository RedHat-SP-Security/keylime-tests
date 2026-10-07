#!/usr/bin/env python3
"""Coverage-guided atheris harness for keylime TPM parsers (keylime#1139).

The parser to drive is selected with the FUZZ_TARGET environment variable
(one of: tpms_attest, tpm2b_public, quote_params) because atheris consumes
sys.argv for its libFuzzer options.

All crash/accept policy and input decoding lives in fuzz_targets so this
harness and the atheris-independent replay.py stay in lockstep.

Usage (driven by test.sh):
    FUZZ_TARGET=tpms_attest python3 fuzz_harness.py \
        -max_total_time=60 -timeout=10 -rss_limit_mb=2048 \
        -artifact_prefix=ARTDIR/ SEED_CORPUS_DIR
"""

import os
import sys

import atheris

TARGET = os.environ.get("FUZZ_TARGET", "tpms_attest")

# Instrument keylime (imported transitively by fuzz_targets) so atheris gets
# coverage feedback from the parsers under test.
with atheris.instrument_imports():
    import fuzz_targets

if TARGET not in fuzz_targets.TARGETS:
    sys.exit(f"unknown FUZZ_TARGET={TARGET!r}, expected one of {fuzz_targets.TARGETS}")


def TestOneInput(data):
    fuzz_targets.run_one(TARGET, data)


def main():
    atheris.Setup(sys.argv, TestOneInput)
    atheris.Fuzz()


if __name__ == "__main__":
    main()
