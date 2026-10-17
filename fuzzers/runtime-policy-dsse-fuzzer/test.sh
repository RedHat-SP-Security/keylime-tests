#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# shellcheck disable=SC2154
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Fuzzer test for keylime runtime-policy & DSSE envelope parsing (keylime#1139).
#
# The parsers in keylime/ima/ima.py (verify_runtime_policy,
# deserialize_runtime_policy) and keylime/signing.py (verify_dsse_envelope) are
# the REST-facing, network-reachable runtime-policy layer. They assume a
# dict-typed top-level JSON object and index/.get() into it without guarding the
# shape, so a hostile scalar/list request body escapes as an unhandled
# AttributeError/KeyError/TypeError (a verifier 500 / DoS) instead of the
# controlled validation error. This test fuzzes them for that shape-confusion
# class, plus hangs (ReDoS from the attacker-controlled exclude list) and
# resource exhaustion.
#
# STRICT crash policy (see fuzz_targets.py): only each function's documented
# controlled exception (ImaValidationError) or a normal return is graceful;
# every other escaping exception is a finding. Against a keylime that still
# carries the open #1139 bugs this test is therefore EXPECTED to report findings
# - that is the point, it documents them as reproducers. It turns green once
# keylime guards these parsers.
#
# Two layers, so the test does useful work everywhere:
#   * replay.py  - deterministic regression over a generated corpus, needs only
#                  keylime + python3 stdlib. Always runs.
#   * atheris    - coverage-guided campaign in SURVEY mode: it keeps fuzzing for
#                  the full budget and enumerates every DISTINCT finding
#                  (deduplicated by exception type + keylime file:line) instead
#                  of stopping at the first crash. Runs only when atheris can be
#                  imported/installed (it needs clang and a matching Python).
#
# Budgets are overridable via environment for longer local campaigns:
FUZZ_MAX_TOTAL_TIME="${FUZZ_MAX_TOTAL_TIME:-30}"   # atheris seconds per target
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-10}"                 # per-input hang timeout (s)
FUZZ_RSS_MB="${FUZZ_RSS_MB:-2048}"                 # per-input RSS limit (MiB)

TARGETS="runtime_policy deserialize_policy dsse_envelope"

rlJournalStart

    rlPhaseStartSetup "Set up the fuzzing environment"
        # Scripts live in the test directory; remember it before we move away.
        TEST_DIR=$(pwd)
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        SEED_DIR="${TmpDir}/seeds"
        ART_DIR="${TmpDir}/artifacts"
        rlRun "mkdir -p '${SEED_DIR}' '${ART_DIR}'"

        # The parsers under test ship in the keylime python package, and the
        # import pulls in keylime's deps (gpg, lark, jsonschema, ...).
        rlAssertRpm keylime
        rlRun "python3 -c 'import sys; sys.path.insert(0, \"${TEST_DIR}\"); import fuzz_targets'" 0 \
            "keylime runtime-policy/DSSE parsers must be importable" \
            || rlDie "cannot import the parsers under test, aborting"

        # Generate the seed corpus (valid + known-adversarial inputs).
        rlRun "python3 '${TEST_DIR}/generate_seeds.py' '${SEED_DIR}'" 0 \
            "Generate seed corpus"

        # Best-effort atheris: use it if present, otherwise try to install it,
        # otherwise fall back to the deterministic replayer only.
        ATHERIS=0
        if python3 -c 'import atheris' 2>/dev/null; then
            ATHERIS=1
        else
            rlLogInfo "atheris not installed, attempting best-effort pip install"
            if rlRun "pip3 install --quiet atheris" 0,1 "Try to install atheris" \
               && python3 -c 'import atheris' 2>/dev/null; then
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
            # A non-zero exit means a #1139 finding (unhandled exception / hang).
            # -s captures the output (crashing seed paths + full tracebacks) so
            # it can be attached on failure.
            rlRun -s "python3 '${TEST_DIR}/replay.py' '${TARGET}' '${SEED_DIR}/${TARGET}' --timeout ${FUZZ_TIMEOUT}" 0 \
                "No crash/hang replaying the ${TARGET} seed corpus"
            if grep -q '^\[FAIL\]' "${rlRun_LOG}"; then
                # Attach the replay report and each crashing seed input.
                rlFileSubmit "${rlRun_LOG}" "replay-${TARGET}.log"
                grep '^\[FAIL\]' "${rlRun_LOG}" | sed 's/.*<- //' | while read -r SEED; do
                    [ -e "${SEED}" ] && rlFileSubmit "${SEED}" "seed-${TARGET}-$(basename "${SEED}")"
                done
            fi
            rm -f "${rlRun_LOG}"
        rlPhaseEnd

        if [ "${ATHERIS}" -eq 1 ]; then
            rlPhaseStartTest "Coverage-guided fuzzing: ${TARGET}"
                PREFIX="${ART_DIR}/${TARGET}-"
                CRASH_DIR="${ART_DIR}/survey"
                # SURVEY mode: the harness catches each finding, records a
                # de-duplicated signature + reproducer under CRASH_DIR, and keeps
                # fuzzing for the full budget so one run enumerates ALL distinct
                # bugs rather than stopping at the first. It therefore exits 0
                # even when findings exist; a non-zero exit means a hang/OOM that
                # killed the campaign (libFuzzer drops a timeout-/oom- artifact
                # under PREFIX). atheris -fork is deliberately NOT used: coverage
                # does not survive the fork, so the campaign would not progress.
                # -s captures the campaign output (per-finding "[survey] new
                # finding" lines + libFuzzer stats) for attachment.
                rlRun -s "FUZZ_TARGET='${TARGET}' FUZZ_SURVEY=1 FUZZ_CRASH_DIR='${CRASH_DIR}' \
                        python3 '${TEST_DIR}/fuzz_harness.py' \
                        -max_total_time=${FUZZ_MAX_TOTAL_TIME} \
                        -timeout=${FUZZ_TIMEOUT} \
                        -rss_limit_mb=${FUZZ_RSS_MB} \
                        -artifact_prefix='${PREFIX}' \
                        '${SEED_DIR}/${TARGET}'" 0 \
                    "Survey ${TARGET} for ${FUZZ_MAX_TOTAL_TIME}s (continue past findings)"
                CAMPAIGN_LOG="${rlRun_LOG}"

                # Report every distinct finding the survey recorded.
                SIGFILE="${CRASH_DIR}/${TARGET}.signatures"
                if [ -s "${SIGFILE}" ]; then
                    COUNT=$(sort -u "${SIGFILE}" | wc -l)
                    rlFail "survey found ${COUNT} distinct finding(s) for ${TARGET}"
                    sort -u "${SIGFILE}" | while read -r SIG; do
                        rlLogWarning "  #1139 finding: ${SIG}"
                    done
                    # Attach the campaign log and the distinct-signature summary.
                    rlFileSubmit "${CAMPAIGN_LOG}" "survey-${TARGET}.log"
                    rlFileSubmit "${SIGFILE}" "signatures-${TARGET}.txt"
                    # Submit and re-verify one reproducer (input + traceback) per
                    # distinct finding.
                    for INP in "${CRASH_DIR}/${TARGET}__"*.input; do
                        [ -e "${INP}" ] || continue
                        rlFileSubmit "${INP}"
                        TRACE="${INP%.input}.trace"
                        [ -e "${TRACE}" ] && rlFileSubmit "${TRACE}"
                        rlRun "python3 '${TEST_DIR}/replay.py' '${TARGET}' '${INP}' --timeout ${FUZZ_TIMEOUT}" 1 \
                            "Reproducer confirmed: $(basename "${INP}")"
                    done
                fi
                rm -f "${CAMPAIGN_LOG}"

                # A hang/OOM ends the campaign early and leaves a libFuzzer
                # artifact under PREFIX; treat each as a finding too.
                REPROS=$(find "${ART_DIR}" -maxdepth 1 -type f -name "${TARGET}-*" 2>/dev/null)
                for R in ${REPROS}; do
                    rlFail "atheris saved a hang/OOM artifact for ${TARGET}"
                    rlFileSubmit "${R}"
                    rlRun "python3 '${TEST_DIR}/replay.py' '${TARGET}' '${R}' --timeout ${FUZZ_TIMEOUT}" 1 \
                        "Reproducer confirmed: ${R}"
                done
            rlPhaseEnd
        fi

    done

    rlPhaseStartCleanup "Cleanup"
        rlRun "rm -r '${TmpDir}'" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalPrintText
rlJournalEnd
