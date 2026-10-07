# runtime-policy-dsse-fuzzer

Fuzzer for keylime's **REST-facing runtime-policy & DSSE envelope parsing**,
addressing [keylime/keylime#1139](https://github.com/keylime/keylime/issues/1139).

## Why

The parsers exercised here consume the **semi-trusted but network-reachable**
runtime-policy layer: request bodies supplied by tenants/operators over the
verifier/registrar REST API. The issue flags them because they assume a
**dict-typed top-level JSON object** and `.get(...)` / `[...]` into it without
guarding the shape. A hostile scalar or list body (`5`, `[]`, `"x"`, `null`)
therefore escapes as an unhandled `AttributeError` / `KeyError` / `TypeError`
instead of the controlled validation error — i.e. a verifier-side **500 / DoS**.

Concretely we hunt for:

* **shape-confusion** unhandled exceptions (scalar/list where a dict is assumed),
* **ReDoS / CPU DoS** from the attacker-controlled `exclude` list regex,
* **resource exhaustion** (oversized base64 payloads, pathological regexes),
* **hangs** and **hard interpreter crashes**.

## Targets

| target               | entry point                                                  |
|----------------------|-------------------------------------------------------------|
| `runtime_policy`     | `ima.verify_runtime_policy(data, None, verify_sig=False)`    |
| `deserialize_policy` | `ima.deserialize_runtime_policy(str)`                       |
| `dsse_envelope`      | `signing.verify_dsse_envelope(bytes)`                      |

`runtime_policy` is the "best single unit target" from the issue: with signature
verification off it reaches `json.loads`, the `.get("payload")` dict assumption,
DSSE payload `b64dec` and the exclude-list regex compilation in one call.

## Crash policy (STRICT — differs from the tpm-quote fuzzer)

Unlike the hand-written binary parsers in `tpm-quote-parsing-fuzzer` (where
raising *any* exception is acceptable rejection of garbage), these are REST
request handlers whose contract is to reject bad input with a **controlled**
error, never to leak an arbitrary exception. So the policy is inverted:

* **graceful** = the function's documented controlled exception
  (`ImaValidationError` for the `ima` functions) **or a normal return**;
* **finding** = *every other* escaping exception — this is the #1139
  shape-confusion class (a bad request that should be a 4xx but throws
  `AttributeError` / `KeyError` / `TypeError` / `JSONDecodeError`, i.e. a 500);
* `MemoryError` / `RecursionError` / `SystemError` are never graceful;
* a **hang** (e.g. a catastrophic-backtracking exclude regex) is caught
  out-of-band (atheris/libFuzzer `-timeout`, or the replayer's SIGALRM — whose
  `Timeout` subclasses `BaseException` so it sails past the accept handler);
* a **segfault** terminates the process regardless.

> **Expected to be RED on unfixed keylime.** The open #1139 bugs are still
> present, so this test *will* report findings against current keylime — that is
> its purpose: it documents them as reproducers. It turns **green** once keylime
> guards these parsers, at which point only the controlled `ImaValidationError`s
> survive.

## How it works

The test runs in two complementary layers:

1. **Deterministic replay (`replay.py`)** — always runs. Feeds a generated
   corpus of valid *and* known-adversarial inputs through each parser under a
   per-input SIGALRM wall-clock timeout. Needs only the installed `keylime`
   package plus the Python standard library, so it works on every platform.

2. **Coverage-guided campaign (`fuzz_harness.py`)** — runs on top when
   [atheris](https://github.com/google/atheris) can be imported or
   pip-installed (it needs `clang` and a compatible Python). Seeded from the
   same corpus. Runs in **survey mode** (see below); every distinct finding it
   records fails the test and its reproducer + traceback are attached to the
   beakerlib results.

### Survey mode (finding *multiple* distinct bugs per run)

Because the parsers currently crash on the very first bad seed, a plain
libFuzzer campaign would stop immediately and `FUZZ_MAX_TOTAL_TIME` would never
apply. atheris's `-fork` mode does not help here — coverage does not survive the
fork, so forked jobs just re-crash on the corpus without progressing.

So `fuzz_harness.py` defaults to **survey mode** (`FUZZ_SURVEY=1`): it *catches*
each finding, records a de-duplicated signature (`ExcType@file.py:line`, located
at the deepest keylime frame) plus a reproducer input and traceback under
`FUZZ_CRASH_DIR`, and **returns** so libFuzzer keeps its coverage feedback and
fuzzes for the full budget. One bounded run therefore enumerates *all distinct*
crash sites it can reach, not just the first. `test.sh` then fails with the
count, logs each signature, and submits one reproducer per distinct bug.

Set `FUZZ_SURVEY=0` to get the strict single-reproducer behaviour instead (first
finding propagates and libFuzzer minimizes/saves it, matching `replay.py`) —
handy when minimizing one specific crash. A **hang** (e.g. a ReDoS exclude
regex) or **OOM** still ends the campaign and is reported via libFuzzer's own
timeout/oom artifact.

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
cd fuzzers/runtime-policy-dsse-fuzzer
./test.sh
```

Standalone / during development (against an installed or checked-out keylime):

```bash
# optional: point at a keylime source tree instead of the installed package
export PYTHONPATH=/path/to/keylime

python3 generate_seeds.py /tmp/corpus
python3 replay.py runtime_policy /tmp/corpus/runtime_policy --timeout 10

# coverage-guided survey (requires atheris): enumerate distinct findings
FUZZ_TARGET=runtime_policy FUZZ_SURVEY=1 FUZZ_CRASH_DIR=/tmp/survey \
    python3 fuzz_harness.py \
    -max_total_time=600 -timeout=10 -rss_limit_mb=2048 \
    -artifact_prefix=/tmp/art- /tmp/corpus/runtime_policy
sort -u /tmp/survey/runtime_policy.signatures   # the distinct bugs found
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
  add its graceful-exception set to `ALLOWED`, and add seeds in `make_seeds()`.
  The harness, replayer and `test.sh` loop all pick it up automatically.
* **New seeds**: append to the relevant list in `make_seeds()`. Include both a
  valid object (to seed coverage) and the adversarial shape you want covered.

## Notes

* `atheris` is not packaged as an RPM; `test.sh` installs it best-effort via
  `pip` and silently falls back to the deterministic replay layer if that is
  not possible (e.g. on a Python version with no atheris wheel).
* This test lives under `fuzzers/` rather than `functional/`, so it is **not**
  pulled in by the existing CI plans' `^/functional/.*` discovery. Add
  `^/fuzzers/.*` (or the specific test path) to a plan's `discover` section to
  run it in CI.
