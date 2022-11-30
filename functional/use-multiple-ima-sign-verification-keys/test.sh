#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        # update keylime conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf verifier quote_interval 2"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
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
        TESTDIR=$(limeCreateTestDir)
        #move to testdir
        rlRun "pushd $TESTDIR"
        # create allowlist and excludelist
        limeCreateTestPolicy
        rlRun "limeInstallIMAKeys first_key $PWD"
        rlRun "limeInstallIMAKeys second_key $PWD"
        rlRun "cat > script_first.sh <<_EOF
#!/bin/bash
echo \"Hello one!\"
_EOF"

        rlRun "cat > script_second.sh <<_EOF
#!/bin/bash
echo \"Hello two!\"
_EOF"
        rlRun "chmod a+rx script_first.sh"
        rlRun "evmctl ima_sign -k privkey_first_key.pem script_first.sh"
        rlRun "getfattr -m ^security.ima --dump script_first.sh"
        rlRun "chmod a+rx script_second.sh"
        rlRun "evmctl ima_sign -k privkey_second_key.pem script_second.sh"
        rlRun "getfattr -m ^security.ima --dump script_second.sh"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent with keys"
        rlRun "keylime_tenant -u ${AGENT_ID} --allowlist policy.json -f /etc/hostname --sign_verification_key  x509_first_key.pem --sign_verification_key x509_second_key.pem  -c add"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Run script and check if scripts are in ascii_runtime_measurements"
        rlRun "./script_first.sh"
        rlRun "./script_second.sh"
        rlAssertGrep "script_first.sh" /sys/kernel/security/ima/ascii_runtime_measurements
        rlAssertGrep "script_second.sh" /sys/kernel/security/ima/ascii_runtime_measurements
    rlPhaseEnd

    rlPhaseStartTest "Confirm the system is still compliant"
        rlRun "sleep 10" 0 "Wait 10 seconds to give verifier some time to do a new attestation"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Confirm that system fail due to changing measured file"
        rlRun "echo 'echo \"boom\"' >> script_first.sh"
        rlRun "./script_first.sh"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Invalid Quote'"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        #return back from testdir to working dir
        rlRun "popd"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "rm -rf $TESTDIR/*"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist ${TESTDIR}
    rlPhaseEnd

rlJournalEnd
