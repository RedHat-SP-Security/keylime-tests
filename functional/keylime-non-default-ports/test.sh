#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent
WEBHOOK_PORT=8080
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\",\"webhook\"]'"
        rlRun "limeUpdateConf revocations webhook_url https://localhost:${WEBHOOK_PORT}"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        fi
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf agent enable_revocation_notifications false"
        fi
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

        #seting keylime_port_t label for non default ports
        if rlIsRHEL '>=9.3' || rlIsFedora '>=38' || rlIsCentOS '>=9';then
            rlRun "semanage port -a -t keylime_port_t -p tcp 19002"
            rlRun "semanage port -a -t keylime_port_t -p tcp 18890"
            rlRun "semanage port -a -t keylime_port_t -p tcp 18992"
            rlRun "semanage port -a -t keylime_port_t -p tcp 18891"
            rlRun "semanage port -a -t keylime_port_t -p tcp 18881"
        fi

        sleep 5
        #set non default ports
        #default port 9002
        rlRun "limeUpdateConf agent port 19002"
        rlRun "limeUpdateConf agent contact_port 19002"
        # default port 8890
        rlRun "limeUpdateConf agent registrar_port 18890"
        rlRun "limeUpdateConf registrar port 18890"
        #default port 8992
        rlRun "limeUpdateConf agent receive_revocation_port 18992"
        rlRun "limeUpdateConf verifier zmq_port 18992"
        # default port 8891
        rlRun "limeUpdateConf tenant registrar_port 18891"
        rlRun "limeUpdateConf verifier registrar_port 18891"
        rlRun "limeUpdateConf registrar tls_port 18891"
        # default port 8881
        rlRun "limeUpdateConf verifier port 18881"
        rlRun "limeUpdateConf tenant verifier_port 18881"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier 18881"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar 18890"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            # start revocation notification webhook server
            WEBHOOK_LOG=$( mktemp )
            WEBHOOK_CERT="/var/lib/keylime/cv_ca/server-cert.crt"
            WEBHOOK_KEY="/var/lib/keylime/cv_ca/server-private.pem"
            rlRun "sleep 500 | openssl s_server -cert ${WEBHOOK_CERT} -key ${WEBHOOK_KEY} -port ${WEBHOOK_PORT} &> ${WEBHOOK_LOG} &"
            WEBHOOK_PID=$!
        fi
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
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
        ls -l /var/tmp/test_payload_file
        rlAssertExists /var/tmp/test_payload_file
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent - revocation actions"
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID failed\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail -20 $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rm -f /var/tmp/test_payload_file"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "kill ${WEBHOOK_PID}"
            rlRun "pkill -f 'sleep 500'"
            limeLogfileSubmit "${WEBHOOK_LOG}"
            rlRun "rm ${WEBHOOK_LOG}"
        fi
        #remove keylime_port_t label from non default ports
        if rlIsRHEL '>=9.3' || rlIsFedora '>=38' || rlIsCentOS '>=9';then
            rlRun "semanage port -d -t keylime_port_t -p tcp 19002"
            rlRun "semanage port -d -t keylime_port_t -p tcp 18890"
            rlRun "semanage port -d -t keylime_port_t -p tcp 18992"
            rlRun "semanage port -d -t keylime_port_t -p tcp 18891"
            rlRun "semanage port -d -t keylime_port_t -p tcp 18881"
        fi
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
