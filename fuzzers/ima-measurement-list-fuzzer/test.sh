#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# shellcheck disable=SC2154
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Fuzzer test for keylime's IMA measurement-list line parser (keylime#1139).
#
# keylime/ima/ast.py Entry(data: str) parses individual measurement lines
# supplied by a potentially compromised agent. The verifier drives it in
# keylime/ima/ima.py _process_measurement_list wrapped in "except ParserError",
# so the parser's contract is to reject any malformed line with a ParserError
# and nothing else. Any OTHER exception (ValueError, struct.error,
# UnicodeEncodeError, ...) escaping Entry() is not caught by the verifier loop
# and crashes the whole quote-verification pipeline -> remote DoS. This test
# fuzzes the line parser and its component parsers for exactly that class of
# non-ParserError escape, plus hangs and resource exhaustion.
#
# Two layers, so the test does useful work everywhere:
#   * replay.py  - deterministic regression over a generated known-bad corpus,
#                  needs only keylime + python3 stdlib. Always runs.
#   * atheris    - coverage-guided campaign in SURVEY mode: it keeps fuzzing for
#                  the full budget and enumerates every DISTINCT finding
#                  (deduplicated by exception type + keylime file:line) instead
#                  of stopping at the first. Runs only when atheris can be
#                  imported/installed (it needs clang and a matching Python).
#
# Budgets are overridable via environment for longer local campaigns:
FUZZ_MAX_TOTAL_TIME="${FUZZ_MAX_TOTAL_TIME:-30}"   # atheris seconds per target
FUZZ_TIMEOUT="${FUZZ_TIMEOUT:-10}"                 # per-input hang timeout (s)
FUZZ_RSS_MB="${FUZZ_RSS_MB:-2048}"                 # per-input RSS limit (MiB)

TARGETS="entry digest name signature"

rlJournalStart

    rlPhaseStartSetup "Set up the fuzzing environment"
        # Scripts live in the test directory; remember it before we move away.
        TEST_DIR=$(pwd)
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        SEED_DIR="${TmpDir}/seeds"
        ART_DIR="${TmpDir}/artifacts"
        rlRun "mkdir -p '${SEED_DIR}' '${ART_DIR}'"

        # The parser under test ships in the keylime python package.
        rlAssertRpm keylime
        rlRun "python3 -c 'import keylime.ima.ast'" 0 \
            "keylime.ima.ast must be importable" \
            || rlDie "keylime.ima.ast not importable, cannot fuzz the IMA parser"

        # Generate the seed corpus (valid + known-adversarial lines/fields).
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
            # Every seed must be parsed or rejected with ParserError, within
            # the hang timeout. A non-ParserError escape is a finding. -s
            # captures the output (crashing seed paths + full tracebacks) so it
            # can be attached on failure.
            rlRun -s "python3 '${TEST_DIR}/replay.py' '${TARGET}' '${SEED_DIR}/${TARGET}' --timeout ${FUZZ_TIMEOUT}" 0 \
                "No non-ParserError escape/hang replaying the ${TARGET} seed corpus"
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
                # findings rather than stopping at the first. It therefore exits 0
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
