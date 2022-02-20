#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

SSL_SERVER_PORT=8980
CERT_DIR="/var/lib/keylime/ca"
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf cloud_verifier revocation_notifier_webhook yes"
        rlRun "limeUpdateConf cloud_verifier webhook_url https://localhost:${SSL_SERVER_PORT}"
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
            # start ima emulator
            export TPM2TOOLS_TCTI=tabrmd:bus_name=com.intel.tss2.Tabrmd
            export TCTI=tabrmd:
            # workaround for https://github.com/keylime/rust-keylime/pull/286
            export PATH=/usr/bin:$PATH
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        else
            rlServiceStart tpm2-abrmd
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
        limeCreateTestLists
        # generate certificate for the SSL SERVER
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_ca -c init -d /var/lib/keylime/ca
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlAssertExists ${CERT_DIR}/cacert.crt
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_ca -c create -n localhost -d /var/lib/keylime/ca
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlAssertExists ${CERT_DIR}/localhost-cert.crt
        # add cacert.crt to system-wide trust store
        rlRun "cp $CERT_DIR/cacert.crt /etc/pki/ca-trust/source/anchors/keylime-ca.crt"
        rlRun "update-ca-trust"
        SSL_SERVER_LOG=$( mktemp )
        # start revocation notifier webhook server using openssl s_server
        # alternatively, we can start ncat --ssl as server, though it didn't work reliably
        # we also need to feed it with sleep so that stdin won't be closed for s_server
        rlRun "sleep 500 | openssl s_server -cert ${CERT_DIR}/localhost-cert.crt -key ${CERT_DIR}/localhost-private.pem -port ${SSL_SERVER_PORT} &> ${SSL_SERVER_LOG} &"
        #rlRun "ncat --ssl --ssl-cert ${CERT_DIR}/localhost-cert.crt --ssl-key ${CERT_DIR}/localhost-private.pem --no-shutdown -k -l ${SSL_SERVER_PORT} -e 'sleep 3 && echo HTTP/1.1 200 OK' -o ${SSL_SERVER_LOG} &"
        SSL_SERVER_PID=$!
    rlPhaseEnd

    rlPhaseStartTest "Add keylime tenant"
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn lime_keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt --include payload --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "lime_keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
        rlAssertExists /var/tmp/test_payload_file
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime tenant"
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/keylime-bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
        rlRun "rlWaitForCmd 'tail $(limeAgentLogfile) | grep -q \"Executing revocation action\"' -m 10 -d 1 -t 10"
        rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
        rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
        rlAssertNotExists /var/tmp/test_payload_file
        cat ${SSL_SERVER_LOG}
        rlAssertGrep '\\"type\\": \\"revocation\\", \\"ip\\": \\"127.0.0.1\\", \\"agent_id\\": \\"d432fbb3-d2f1-4a97-9ef7-75bd81c00000\\"' ${SSL_SERVER_LOG} -i
        rlAssertNotGrep ERROR ${SSL_SERVER_LOG} -i
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "kill ${SSL_SERVER_PID}"
        rlRun "pkill -f 'sleep 500'"
        rlRun "rm ${SSL_SERVER_LOG}"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlFileSubmit $(limeVerifierLogfile)
        rlFileSubmit $(limeRegistrarLogfile)
        rlFileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlFileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
        fi
        rlRun "rm /etc/pki/ca-trust/source/anchors/keylime-ca.crt"
        rlRun "update-ca-trust"
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
        rlServiceRestore tpm2-abrmd
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
