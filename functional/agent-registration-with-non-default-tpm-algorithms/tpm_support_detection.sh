#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
        fi
        sleep 5
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
    rlPhaseEnd

    rlPhaseStartTest "Survey TPM ECC and RSA curve/key support for EK creation"
        if limeTPMEmulated; then
            rlLogInfo "Querying TPM for advertised ECC curve support:"
            rlRun "tpm2_getcap ecc-curves | tee '${TmpDir}'/tpm_ecc_curves.txt"

            rlLogInfo "Querying TPM for advertised RSA key size support:"
            rlRun "tpm2_getcap algorithms | grep -i rsa | tee '${TmpDir}'/tpm_rsa_algs.txt"

            rlLogInfo "Testing which ECC curves actually work for EK creation:"
            SUPPORTED_ECC=""
            for curve in ecc192 ecc224 ecc256 ecc384 ecc521; do
                rlLog "Testing $curve..."
                if tpm2_createek -c "${TmpDir}"/test_${curve}.ctx \
                                 -G ${curve} -u "${TmpDir}"/test_${curve}.pub \
                                 >"${TmpDir}"/ek_test_${curve}.log 2>&1; then
                    rlLogInfo "EK creation with $curve: SUCCESS"
                    SUPPORTED_ECC="${SUPPORTED_ECC} ${curve}"
                    rm -f "${TmpDir}"/test_${curve}.ctx \
                          "${TmpDir}"/test_${curve}.pub
                else
                    rlLogInfo "EK creation with $curve: FAILED"
                    cat "${TmpDir}"/ek_test_${curve}.log
                fi
            done

            rlLogInfo "Testing which RSA key sizes actually work for EK creation:"
            SUPPORTED_RSA=""
            for rsa in rsa1024 rsa2048 rsa3072 rsa4096; do
                rlLog "Testing $rsa..."
                if tpm2_createek -c "${TmpDir}"/test_${rsa}.ctx \
                                 -G ${rsa} -u "${TmpDir}"/test_${rsa}.pub \
                                 >"${TmpDir}"/ek_test_${rsa}.log 2>&1; then
                    rlLogInfo "EK creation with $rsa: SUCCESS"
                    SUPPORTED_RSA="${SUPPORTED_RSA} ${rsa}"
                    rm -f "${TmpDir}"/test_${rsa}.ctx "${TmpDir}"/test_${rsa}.pub
                else
                    rlLogInfo "EK creation with $rsa: FAILED"
                    cat "${TmpDir}"/ek_test_${rsa}.log
                fi
            done

            rlLogInfo "========================================="
            rlLogInfo "Supported algorithms for EK creation:"
            rlLogInfo "  ECC curves:${SUPPORTED_ECC}"
            rlLogInfo "  RSA sizes:${SUPPORTED_RSA}"
            rlLogInfo "========================================="
            rlRun "limeSubmitCommonLogs" 0,1
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        if limeTPMEmulated; then
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalEnd
