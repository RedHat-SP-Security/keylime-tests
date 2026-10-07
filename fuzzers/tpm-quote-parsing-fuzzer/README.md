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
   same corpus. Runs in **survey mode** (see below); every distinct finding it
   records fails the test and its reproducer + traceback are attached to the
   beakerlib results.

### Survey mode (finding *multiple* distinct bugs per run)

By default (`FUZZ_SURVEY=1`) the campaign does not stop at the first finding.
The harness *catches* each finding (an exception the crash policy flags, decided
by `fuzz_targets.is_finding()`), records a de-duplicated signature
(`ExcType@file.py:line`, located at the deepest keylime frame) plus a reproducer
input and traceback under `FUZZ_CRASH_DIR`, and **returns** so libFuzzer keeps
its coverage feedback and fuzzes for the full budget. One bounded run therefore
enumerates *all distinct* findings it can reach, not just the first. `test.sh`
then fails with the count, logs each signature, and submits one reproducer per
distinct bug. (atheris's `-fork` mode is not used: coverage does not survive the
fork, so forked jobs just re-crash on the corpus without progressing.)

Set `FUZZ_SURVEY=0` for the strict single-reproducer behaviour (first finding
propagates and libFuzzer minimizes/saves it) — handy when minimizing one crash.
A **hang** or **OOM** still ends the campaign and is reported via libFuzzer's own
timeout/oom artifact.

On a crash the test attaches: the replay report + each crashing seed
(deterministic phase), and the campaign log, signature summary, and per-finding
input+traceback reproducers (survey phase).

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

# coverage-guided survey (requires atheris): enumerate distinct findings
FUZZ_TARGET=tpms_attest FUZZ_SURVEY=1 FUZZ_CRASH_DIR=/tmp/survey \
    python3 fuzz_harness.py \
    -max_total_time=600 -timeout=10 -rss_limit_mb=2048 \
    -artifact_prefix=/tmp/art- /tmp/corpus/tpms_attest
sort -u /tmp/survey/tpms_attest.signatures   # the distinct findings, if any
```

### Tuning the campaign

`test.sh` honours these environment variables (defaults in parentheses):

* `FUZZ_MAX_TOTAL_TIME` (30) — atheris seconds per target
* `FUZZ_TIMEOUT` (10) — per-input hang timeout, seconds
* `FUZZ_RSS_MB` (2048) — per-input RSS limit, MiB
* `FUZZ_SURVEY` (1) — 1: enumerate all distinct findings over the full budget;
  0: stop at the first finding and save a single minimized reproducer

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
