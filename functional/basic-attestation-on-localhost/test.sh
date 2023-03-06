#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent
HTTP_SERVER_PORT=8080
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "limeUpdateConf logger_root level DEBUG"
        rlRun "limeUpdateConf logger_keylime level DEBUG"
        rlRun "limeUpdateConf handler_consoleHandler level DEBUG"
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\",\"webhook\"]'"
        rlRun "limeUpdateConf revocations webhook_url http://localhost:${HTTP_SERVER_PORT}"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        fi
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf agent enable_revocation_notifications false"
        fi
        # if enviroment variable is set, the default algorithm in configuration file has changed
        if [ -n "$KEYLIME_TEST_USE_NON_DEFAULT_ALGORITHM" ]; then
            rlRun "limeUpdateConf agent tpm_encryption_alg ecc"
            rlRun "limeUpdateConf agent tpm_signing_alg ecschnorr"
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
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create some scripts
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        rlRun "echo -e '#!/bin/bash\necho This is good-script2' > $TESTDIR/good-script2.sh && chmod a+x $TESTDIR/good-script2.sh"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"
        HTTP_SERVER_LOG=$( mktemp )
        # start revocation notifier webhook server using ncat
        rlRun "ncat --no-shutdown -k -l ${HTTP_SERVER_PORT} -c '/usr/bin/sleep 3 && echo HTTP/1.1 200 OK' -o ${HTTP_SERVER_LOG} &"
        HTTP_SERVER_PID=$!
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
        ls -l /var/tmp/test_payload_file
        rlAssertExists /var/tmp/test_payload_file
    rlPhaseEnd

    rlPhaseStartTest "Running allowed scripts should not affect attestation"
        rlRun "${TESTDIR}/good-script1.sh"
        rlRun "${TESTDIR}/good-script2.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script1.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script2.sh"
	rlRun "sleep 5"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID failed\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail -20 $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
            cat ${HTTP_SERVER_LOG}
            rlAssertGrep '\\"type\\": \\"revocation\\", \\"ip\\": \\"127.0.0.1\\", \\"agent_id\\": \\"d432fbb3-d2f1-4a97-9ef7-75bd81c00000\\"' ${HTTP_SERVER_LOG} -i
            rlAssertNotGrep ERROR ${HTTP_SERVER_LOG} -i
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "kill ${HTTP_SERVER_PID}"
        rlRun "rm ${HTTP_SERVER_LOG}"
        rlRun "rm -f /var/tmp/test_payload_file"
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
        limeExtendNextExcludelist $TESTDIR
        # remove file with env variablo for future rerun of tests
        if [ -n "$KEYLIME_TEST_USE_NON_DEFAULT_ALGORITHM" ]; then
            rlRun "rm -rf /etc/profile.d/export_KEYLIME_TEST_USE_NON_DEFAULT_ALGORITHM.sh"
        fi
        #rlRun "rm -f $TESTDIR/*"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
