# tpm-quote-parsing-fuzzer

Fuzzer for keylime's TPM quote & TPM2B structure parsing, addressing
[keylime/keylime#1139](https://github.com/keylime/keylime/issues/1139).

## Why

The parsers exercised here consume data that originates from a **potentially
compromised agent** (TPM quotes, attestation blobs, public-key structures).
They are hand-written binary offset walkers with input-controlled lengths and
32-bit loop counts, which the issue flags as the highest-priority fuzzing
target in keylime. Concretely we hunt for:

* **CPU DoS** from input-controlled loop counts (`unmarshal_tpml_pcr_selection`),
* **memory exhaustion** from unchecked `TPM2B` length fields and zlib
  decompression bombs (`_get_quote_parameters`),
* **hangs**, **unbounded recursion**, and **hard interpreter crashes**
  (segfaults in C extensions).

## Targets

| target         | entry point                                       |
|----------------|---------------------------------------------------|
| `tpms_attest`  | `tpm2_objects.unmarshal_tpms_attest(bytes)`       |
| `tpm2b_public` | `tpm2_objects.pubkey_from_tpm2b_public(bytes)`    |
| `quote_params` | `tpm_main.Tpm._get_quote_parameters(str, bool)`   |

## How it works

The test runs in two complementary layers:

1. **Deterministic replay (`replay.py`)** — always runs. Feeds a generated
   corpus of valid *and* known-adversarial blobs through each parser under a
   per-input SIGALRM wall-clock timeout, requiring every input to be handled
   gracefully and quickly. Needs only the installed `keylime` package plus the
   Python standard library, so it works on every platform.

2. **Coverage-guided campaign (`fuzz_harness.py`)** — runs on top when
   [atheris](https://github.com/google/atheris) can be imported or
   pip-installed (it needs `clang` and a compatible Python). Seeded from the
   same corpus. Any reproducer atheris saves fails the test and is attached to
   the beakerlib results.

### Crash policy (shared by both layers, see `fuzz_targets.py`)

A binary parser fed hostile garbage is *expected* to reject it by raising an
ordinary exception, so **every `Exception` is swallowed as graceful rejection**
— including the bare `Exception` these hand-written parsers raise on bad magic
or a wrong token count.

Only genuinely dangerous outcomes are treated as findings:

* `MemoryError` / `RecursionError` / `SystemError` are re-raised;
* a **hang** is caught out-of-band (atheris/libFuzzer `-timeout`, or the
  replayer's SIGALRM — whose `Timeout` subclasses `BaseException` so it sails
  past the broad `except Exception`);
* a **segfault** terminates the process regardless.

## Files

| file                | role                                                        |
|---------------------|-------------------------------------------------------------|
| `main.fmf`          | test metadata (beakerlib)                                   |
| `test.sh`           | orchestrates both layers across all targets                 |
| `fuzz_targets.py`   | shared decoding, crash policy and seed-corpus generation    |
| `fuzz_harness.py`   | atheris entry point (`FUZZ_TARGET` env var selects target)  |
| `generate_seeds.py` | writes the seed corpus to disk                              |
| `replay.py`         | atheris-independent corpus replayer                         |

## Running

As part of the test suite (beakerlib):

```bash
cd fuzzers/tpm-quote-parsing-fuzzer
./test.sh
```

Standalone / during development (against an installed or checked-out keylime):

```bash
# optional: point at a keylime source tree instead of the installed package
export PYTHONPATH=/path/to/keylime

python3 generate_seeds.py /tmp/corpus
python3 replay.py tpms_attest /tmp/corpus/tpms_attest --timeout 10

# coverage-guided (requires atheris)
FUZZ_TARGET=tpms_attest python3 fuzz_harness.py \
    -max_total_time=60 -timeout=10 -rss_limit_mb=2048 \
    -artifact_prefix=/tmp/art- /tmp/corpus/tpms_attest
```

### Tuning the campaign

`test.sh` honours these environment variables (defaults in parentheses):

* `FUZZ_MAX_TOTAL_TIME` (30) — atheris seconds per target
* `FUZZ_TIMEOUT` (10) — per-input hang timeout, seconds
* `FUZZ_RSS_MB` (2048) — per-input RSS limit, MiB

## Extending

* **New target**: add a branch to `fuzz_targets._call()`, list it in `TARGETS`,
  and add seeds in `make_seeds()`. The harness, replayer and `test.sh` loop all
  pick it up automatically.
* **New seeds**: append to the relevant list in `make_seeds()`. Include both a
  valid blob (to seed coverage) and the adversarial shape you want covered.

## Notes

* `atheris` is not packaged as an RPM; `test.sh` installs it best-effort via
  `pip` and silently falls back to the deterministic replay layer if that is
  not possible (e.g. on a Python version with no atheris wheel).
* This test lives under `fuzzers/` rather than `functional/`, so it is **not**
  pulled in by the existing CI plans' `^/functional/.*` discovery. Add
  `^/fuzzers/.*` (or the specific test path) to a plan's `discover` section to
  run it in CI.
