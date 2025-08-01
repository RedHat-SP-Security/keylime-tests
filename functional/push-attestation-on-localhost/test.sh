#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart
    rlPhaseStartSetup "Setup push attestation environment"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Backup original configuration
        limeBackupConfig

        # Set the verifier to run in PUSH mode
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"

        # Set the configuration for the agent
        rlRun "limeUpdateConf agent measuredboot_ml_path '\"/var/tmp/binary_bios_measurements\"'"
        # TODO: this is not used anywhere
        #rlRun "limeUpdateConf agent uefi_logs_binary_path '\"/var/tmp/binary_bios_measurements\"'"

        # Copy the fake UEFI log
        rlRun "cp binary_bios_measurements /var/tmp"

        # Disable EK certificate verification on the tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Configure TPM emulator if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        sleep 5

        # Start keylime services with push support
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        # Start push-attestaton agent
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # create some scripts
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        rlRun "echo -e '#!/bin/bash\necho This is good-script2' > $TESTDIR/good-script2.sh && chmod a+x $TESTDIR/good-script2.sh"

        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add --push-model
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        # Check that agent appears in verifier's agent list
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "$AGENT_ID" "$rlRun_LOG"

        rlAssertGrep "PATCH Response Code.*202 Accepted" "$(limePushAgentLogfile)"

        rlAssertGrep "Attestation 0 for agent '${AGENT_ID}' verified successfully"

        #TODO Find out a reliable way to detect that the agent is passing attestation
        #rlRun -s "keylime_tenant -c cvlist"
        #rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Running allowed scripts should not affect attestation"
        rlRun "${TESTDIR}/good-script1.sh"
        rlRun "${TESTDIR}/good-script2.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script1.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script2.sh"
        rlRun "sleep 5"
        rlRun "expect script.expect"

        #TODO Find out a reliable way to detect that the agent is passing attestation
        rlAssertGrep "PATCH Response Code.*202 Accepted" "$(limePushAgentLogfile)"
        rlAssertGrep "Attestation 1 for agent '${AGENT_ID}' verified successfully" "$(limeVerifierLogfile)"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID failed\"' -m 10 -d 1 -t 10"

        rlAssertGrep "Attestation 2 for agent '${AGENT_ID}' verified successfully" "$(limeVerifierLogfile)"

        #TODO Find out reliable way to detect agent failing attestation
        #rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        #rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/bad-script.sh" $(limeVerifierLogfile)
        #rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup push attestation test"
        # Stop push agent
        rlRun "limeStopPushAgent"

        # Stop keylime services
        rlRun "limeStopVerifier"
        rlRun "limeStopRegistrar"

        # Stop TPM emulator if used
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi

        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
    rlPhaseEnd
rlJournalEnd
