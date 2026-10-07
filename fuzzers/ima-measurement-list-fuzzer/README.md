# ima-measurement-list-fuzzer

Fuzzer for keylime's IMA measurement-list line parser, addressing
[keylime/keylime#1139](https://github.com/keylime/keylime/issues/1139).

## Why

`keylime/ima/ast.py` `Entry(data: str)` parses individual IMA measurement-list
lines supplied by a **potentially compromised agent**. The verifier drives it
in `keylime/ima/ima.py` `_process_measurement_list` inside a loop that catches
**only** `ast.ParserError`:

```python
try:
    entry = ast.Entry(line, ...)
    ...
except ast.ParserError:
    ...  # line rejected, keep going
```

So the parser's contract is: reject any malformed line by raising
`ParserError` and **nothing else**. Any other exception type escaping `Entry()`
(or the component parsers it drives) is *not* caught by the verifier loop and
propagates out, crashing the whole quote-verification pipeline — a remote DoS
of the verifier. That is exactly the class of finding the issue calls out for
this parser. Concretely we hunt for:

* **non-`ParserError` escapes**, e.g. the legacy `"n"` name path computing
  `TCG_EVENT_NAME_LEN_MAX - len(name_bytes)` on an over-long name (`ValueError:
  negative count`), or a lone surrogate in a path breaking the UTF-8 re-encode
  in `Name.struct` (`UnicodeEncodeError`),
* **memory exhaustion** / **unbounded recursion** (`MemoryError`,
  `RecursionError`),
* **hangs** and **hard interpreter crashes** (segfaults in C extensions).

## Targets

| target      | entry point                                   |
|-------------|-----------------------------------------------|
| `entry`     | `ast.Entry(line)` — the real trust boundary   |
| `digest`    | `ast.Digest(field, legacy).struct()`          |
| `name`      | `ast.Name(field, legacy).struct()`            |
| `signature` | `ast.Signature(hexdata).struct()`             |

`entry` alone reaches every component; the component targets let the
coverage-guided campaign drive each parser directly (faster to reach deep
states) and let a reproducer pin the blame on one component.

## How it works

The test runs in two complementary layers:

1. **Deterministic replay (`replay.py`)** — always runs. Feeds a generated
   corpus of valid *and* known-adversarial lines/fields through each parser
   under a per-input SIGALRM wall-clock timeout, requiring every input to be
   either parsed or rejected with `ParserError`. Needs only the installed
   `keylime` package plus the Python standard library, so it works everywhere.

2. **Coverage-guided campaign (`fuzz_harness.py`)** — runs on top when
   [atheris](https://github.com/google/atheris) can be imported or
   pip-installed (it needs `clang` and a compatible Python). Seeded from the
   same corpus. Runs in **survey mode** (see below); every distinct finding it
   records fails the test and its reproducer + traceback are attached to the
   beakerlib results.

### Survey mode (finding *multiple* distinct bugs per run)

By default (`FUZZ_SURVEY=1`) the campaign does not stop at the first finding.
The harness *catches* each finding (a non-ParserError escape, decided by
`fuzz_targets.is_finding()`), records a de-duplicated signature
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

This parser has a *declared* exception type for bad input, so the policy is the
inverse of a hand-written binary parser that may raise anything:

* `ast.ParserError` is **swallowed** as graceful rejection — it is the only
  type the verifier's own loop catches;
* **every other `Exception`** (`ValueError`, `struct.error`,
  `UnicodeEncodeError`, a bare `Exception`, …) is a **finding** and is
  re-raised;
* `MemoryError` / `RecursionError` / `SystemError` are re-raised too (named in
  `SERIOUS` so the replayer labels resource exhaustion distinctly);
* a **hang** is caught out-of-band (atheris/libFuzzer `-timeout`, or the
  replayer's SIGALRM — whose `Timeout` subclasses `BaseException` so it sails
  past the `except GRACEFUL`); a **segfault** terminates the process regardless.

Fuzz bytes are mapped to the parser's `str` input with
`decode("utf-8", "surrogateescape")` — total and reversible, and able to
produce the lone surrogates that reach the UTF-8 re-encode paths, matching how
untrusted agent-supplied bytes realistically arrive.

## Expected result against current keylime

> **This test reproduces real, currently-unfixed #1139 findings.** Against a
> keylime build where the parser still lets non-`ParserError` exceptions escape
> (over-long legacy name → `ValueError: negative count`; lone surrogate in a
> path → `UnicodeEncodeError`), the deterministic replay **fails** — as it
> should, that is the bug. It will pass once `Entry()` raises `ParserError`
> (or otherwise handles those inputs) instead.

## Files

| file                | role                                                        |
|---------------------|-------------------------------------------------------------|
| `main.fmf`          | test metadata (beakerlib)                                   |
| `test.sh`           | orchestrates both layers across all targets                 |
| `fuzz_targets.py`   | shared decoding, crash policy and seed-corpus generation    |
| `fuzz_harness.py`   | atheris entry point (`FUZZ_TARGET` env var selects target)  |
| `generate_seeds.py` | writes the seed corpus to disk                              |
| `replay.py`         | atheris-independent corpus/reproducer replayer              |

## Running

As part of the test suite (beakerlib):

```bash
cd fuzzers/ima-measurement-list-fuzzer
./test.sh
```

Standalone / during development (against an installed or checked-out keylime):

```bash
# optional: point at a keylime source tree instead of the installed package
export PYTHONPATH=/path/to/keylime

python3 generate_seeds.py /tmp/corpus
python3 replay.py entry /tmp/corpus/entry --timeout 10

# coverage-guided survey (requires atheris): enumerate distinct findings
FUZZ_TARGET=entry FUZZ_SURVEY=1 FUZZ_CRASH_DIR=/tmp/survey \
    python3 fuzz_harness.py \
    -max_total_time=600 -timeout=10 -rss_limit_mb=2048 \
    -artifact_prefix=/tmp/art- /tmp/corpus/entry
sort -u /tmp/survey/entry.signatures   # the distinct findings, if any
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
  valid field/line (to seed coverage) and the adversarial shape you want
  covered.

## Notes

* This fuzzer mirrors the structure of `fuzzers/tpm-quote-parsing-fuzzer`
  (same two-layer replay + atheris design, same harness/replayer scaffolding).
  The scaffolding is small and duplicated per fuzzer so each test directory
  stays self-contained and runnable in isolation by tmt/fmf; if the number of
  fuzzers grows, extracting the shared `generate_seeds.py` / `replay.py` /
  `fuzz_harness.py` into a common helper would become worthwhile. The
  per-fuzzer differences live in `fuzz_targets.py` (decoding, crash policy and
  seeds) and in `test.sh`'s target list.
* `atheris` is not packaged as an RPM; `test.sh` installs it best-effort via
  `pip` and silently falls back to the deterministic replay layer if that is
  not possible (e.g. on a Python version with no atheris wheel).
* This test lives under `fuzzers/` rather than `functional/`, so it is **not**
  pulled in by the existing CI plans' `^/functional/.*` discovery. Add
  `^/fuzzers/.*` (or the specific test path) to a plan's `discover` section to
  run it in CI.
