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
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
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
        rlRun "evmctl ima_sign ${ALG_ARG} ${SCRIPT}"
        rlRun -s "getfattr -m ^security.ima --dump ${SCRIPT}"
        rlRun "evmctl ima_verify ${ALG_ARG} ${SCRIPT}"
        # if IMA is emulated, we would have good checksum for Agent but our running kernel would deny access anyway
        rlRun -s "${SCRIPT} boom"
        rlAssertGrep "boom" $rlRun_LOG
        rlRun -s "grep '${SCRIPT}' /sys/kernel/security/ima/ascii_runtime_measurements"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --runtime-policy policy.json -f /etc/hostname --sign_verification_key ${limeIMAPublicKey} -c add"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo >> ${SCRIPT}"
        rlRun "${SCRIPT}"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} '(Failed|Invalid Quote)'"
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
            rlServiceRestore tpm2-abrmd
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist ${TESTDIR}
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
