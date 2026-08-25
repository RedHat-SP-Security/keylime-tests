#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# This test requires HW TMP

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
AGENT_USER=kagent
AGENT_GROUP=tss
AGENT_WORKDIR=/var/lib/keylime-agent

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Add IMA signature to a test file"
        TESTDIR=`limeCreateTestDir`
        rlRun "chmod a+rx ${TESTDIR}"
        SCRIPT="${TESTDIR}/echo"
        rlRun "echo -e '#!/bin/bash\necho boom' > ${SCRIPT} && chmod a+x ${SCRIPT} && chown ${limeTestUser}:${limeTestUser} ${SCRIPT}"
        ls -l ${SCRIPT}
        ALG_ARG="-a sha256"
        rlRun "evmctl ima_sign ${ALG_ARG} --key ${limeIMAPrivateKey} ${SCRIPT}"
        rlRun -s "getfattr -m ^security.ima --dump ${SCRIPT}"
        rlRun "evmctl ima_verify ${ALG_ARG} --key ${limeIMACertificateDER} ${SCRIPT}"
        # if IMA is emulated, we would have good checksum for Agent but our running kernel would deny access anyway
        rlRun -s "${SCRIPT} boom"
        rlAssertGrep "boom" $rlRun_LOG
        rlRun -s "grep '${SCRIPT}' /sys/kernel/security/ima/ascii_runtime_measurements"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "limeCtl --verifier-ip 127.0.0.1 agent add ${AGENT_ID} --ip 127.0.0.1 --runtime-policy policy.json --ima-key ${limeIMAPublicKey}"
        rlRun "limeWaitForAgentStatus --field attestation_status ${AGENT_ID} 'PASS'"
        rlRun -s "limeCtl agent list"
        rlRun "limeAssertJsonField $rlRun_LOG code=200 status=Success uuids=${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo >> ${SCRIPT}"
        rlRun "${SCRIPT}"
        rlRun "limeWaitForAgentStatus --field attestation_status ${AGENT_ID} 'FAIL'"
        # the change in the Warning message has been introduced in https://github.com/keylime/keylime/pull/1322
        rlAssertGrep "WARNING - (File not found in allowlist: ${SCRIPT}|signature for file ${SCRIPT} is not valid)" $(limeVerifierLogfile) -E
        rlAssertGrep "ERROR - IMA ERRORS: Some entries couldn't be validated" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent ${AGENT_ID} failed, stopping polling" $(limeVerifierLogfile)
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist ${TESTDIR}
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
