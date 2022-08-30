#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant agent_mtls_cert_enabled False"
        rlRun "limeUpdateConf cloud_agent mtls_cert_enabled False"
        rlRun "limeUpdateConf cloud_agent enable_insecure_payload False"
        rlRun "limeUpdateConf cloud_verifier agent_mtls_cert_enabled False"
        rlRun "limeUpdateConf cloud_verifier revocation_notifiers ${REVOCATION_NOTIFIER}"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf cloud_verifier revocation_notifiers ''"
            rlRun "limeUpdateConf cloud_agent listen_notifications False"
        fi
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
        # create allowlist and excludelist
        limeCreateTestLists
        # create expect script to add agent
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        rlRun "cat > add.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
    rlPhaseEnd

    rlPhaseStartTest "Check that agent cannot start without explicitly enabling insecure payload"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}" 1
        rlAssertGrep "enable_insecure_payload. has to be set to .True." $(limeAgentLogfile) -E
    rlPhaseEnd

    rlPhaseStartTest "Check that empty script_payload allows the agent to start"
        rlRun "limeUpdateConf cloud_agent payload_script ''"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlRun "expect add.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlAssertGrep "mTLS disabled" $(limeAgentLogfile)
        rlAssertGrep "payloads cannot be deployed" $(limeAgentLogfile)
    rlPhaseEnd

    rlPhaseStartTest "Enable insecure payload and set script_payload"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID -c delete"
        rlRun "keylime_tenant -r 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID -c regdelete"
        rlRun "limeStopAgent"
        rlRun "limeUpdateConf cloud_agent enable_insecure_payload True"
        rlRun "limeUpdateConf cloud_agent payload_script 'autorun.sh'"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent and check that payload was executed"
        rlRun "expect add.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
        ls -l /var/tmp/test_payload_file
        rlAssertExists /var/tmp/test_payload_file
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime tenant"
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/keylime-bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rm -f /var/tmp/test_payload_file"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        limeLogfileSubmit $(limeVerifierLogfile)
        limeLogfileSubmit $(limeRegistrarLogfile)
        limeLogfileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        if [ -f /etc/systemd/system/keylime_agent.service.d/20-keylime_dir.conf ]; then
            rlRun "rm -f /etc/systemd/system/keylime_agent.service.d/20-keylime_dir.conf"
            rlRun "systemctl daemon-reload"
        fi
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
