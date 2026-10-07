#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# shellcheck disable=SC2154
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Fuzzer test for keylime TPM quote & TPM2B structure parsing (keylime#1139).
#
# The parsers in keylime/tpm/tpm2_objects.py and tpm_main._get_quote_parameters
# are hand-written binary offset walkers operating on data that originates from
# a potentially compromised agent. This test fuzzes them for crashes, hangs and
# resource exhaustion (the input-controlled-loop-count DoS and decompression
# bomb classes called out in the issue).
#
# Two layers, so the test does useful work everywhere:
#   * replay.py  - deterministic regression over a generated known-bad corpus,
#                  needs only keylime + python3 stdlib. Always runs.
#   * atheris    - coverage-guided campaign. Runs only when atheris can be
#                  imported/installed (it needs clang and a matching Python).
#
# Budgets are overridable via environment for longer local campaigns:
FUZZ_MAX_TOTAL_TIME="${FUZZ_MAX_TOTAL_TIME:-30}"   # atheris seconds per target
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-10}"                 # per-input hang timeout (s)
FUZZ_RSS_MB="${FUZZ_RSS_MB:-2048}"                 # per-input RSS limit (MiB)

TARGETS="tpms_attest tpm2b_public quote_params"

rlJournalStart

    rlPhaseStartSetup "Set up the fuzzing environment"
        # Scripts live in the test directory; remember it before we move away.
        TEST_DIR=$(pwd)
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        SEED_DIR="${TmpDir}/seeds"
        ART_DIR="${TmpDir}/artifacts"
        rlRun "mkdir -p '${SEED_DIR}' '${ART_DIR}'"

        # The parsers under test ship in the keylime python package.
        rlAssertRpm keylime
        rlRun "python3 -c 'import keylime.tpm.tpm2_objects'" 0 "keylime python package must be importable" || rlDie "keylime python package not importable, cannot fuzz its parsers"

        # Generate the seed corpus (valid + known-adversarial blobs).
        rlRun "python3 '${TEST_DIR}/generate_seeds.py' '${SEED_DIR}'" 0 "Generate seed corpus"

        # The quote_params target drives tpm_main.Tpm, whose import chain needs
        # keylime's own deps (python3-gpg, python3-lark, ...). Warn loudly if it
        # is not importable so that target does not silently become a no-op.
        if python3 -c "import sys; sys.path.insert(0, '${TEST_DIR}'); import fuzz_targets as f; sys.exit(0 if f._HAVE_TPM else 1)" 2>/dev/null; then
            rlLogInfo "tpm_main.Tpm importable: the quote_params target is active"
        else
            rlLogWarning "tpm_main.Tpm NOT importable (missing keylime deps?): the quote_params target will be a no-op"
        fi

        # Best-effort atheris: use it if present, otherwise try to install it,
        # otherwise fall back to the deterministic replayer only.
        ATHERIS=0
        if python3 -c 'import atheris' 2>/dev/null; then
            ATHERIS=1
        else
            rlLogInfo "atheris not installed, attempting best-effort pip install"
            rlRun "pip3 install --quiet atheris" 0,1 "Try to install atheris"
            if python3 -c 'import atheris' 2>/dev/null; then
                ATHERIS=1
            fi
        fi
        if [ "${ATHERIS}" -eq 1 ]; then
            rlLogInfo "atheris available: coverage-guided fuzzing enabled"
        else
            rlLogWarning "atheris unavailable: running deterministic replay only"
        fi
    rlPhaseEnd

    for TARGET in ${TARGETS}; do

        rlPhaseStartTest "Deterministic regression replay: ${TARGET}"
            # Every seed must be handled gracefully and within the hang timeout.
            rlRun "python3 '${TEST_DIR}/replay.py' '${TARGET}' '${SEED_DIR}/${TARGET}' --timeout ${FUZZ_TIMEOUT}" 0 "No crash/hang replaying the ${TARGET} seed corpus"
        rlPhaseEnd

        if [ "${ATHERIS}" -eq 1 ]; then
            rlPhaseStartTest "Coverage-guided fuzzing: ${TARGET}"
                PREFIX="${ART_DIR}/${TARGET}-"
                # atheris exits non-zero and drops a crash-/timeout-/oom- file
                # under PREFIX if it finds a problem. Build the command on one
                # line to avoid fragile backslash line-continuations.
                FUZZ_CMD="FUZZ_TARGET='${TARGET}' python3 '${TEST_DIR}/fuzz_harness.py' -max_total_time=${FUZZ_MAX_TOTAL_TIME} -timeout=${FUZZ_TIMEOUT} -rss_limit_mb=${FUZZ_RSS_MB} -artifact_prefix='${PREFIX}' '${SEED_DIR}/${TARGET}'"
                rlRun "${FUZZ_CMD}" 0 "Fuzz ${TARGET} for ${FUZZ_MAX_TOTAL_TIME}s without crashes"

                # Collect and re-verify any reproducer atheris saved.
                REPROS=$(find "${ART_DIR}" -maxdepth 1 -type f -name "${TARGET}-*" 2>/dev/null)
                if [ -n "${REPROS}" ]; then
                    rlFail "atheris found crashing input(s) for ${TARGET}"
                    for R in ${REPROS}; do
                        rlFileSubmit "${R}"
                        rlRun "python3 '${TEST_DIR}/replay.py' '${TARGET}' '${R}' --timeout ${FUZZ_TIMEOUT}" 1 "Reproducer confirmed: ${R}"
                    done
                fi
            rlPhaseEnd
        fi

    done

    rlPhaseStartCleanup "Cleanup"
        rlRun "rm -r '${TmpDir}'" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalPrintText
rlJournalEnd
