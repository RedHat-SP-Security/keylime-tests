#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

HTTP_SERVER_PORT=8080
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "limeUpdateConf logger_keylime level DEBUG"
        rlRun "limeUpdateConf handler_consoleHandler level DEBUG"
        # tenant, set to true to verify ek on TPM
        rlRun "limeUpdateConf tenant require_ek_cert false"
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

        rlRun 'cat > /var/lib/keylime/check_ek_script.sh <<_EOF
#!/bin/sh
echo AGENT_UUID=\${AGENT_UUID}
echo EK=\${EK}
echo EK_CERT=\${EK_CERT}
echo EK_TPM=\${EK_TPM}
echo PROVKEYS=\${PROVKEYS}
_EOF'
        rlRun "chown keylime:keylime /var/lib/keylime/check_ek_script.sh"
        rlRun "chmod 500 /var/lib/keylime/check_ek_script.sh"
        #veryfing of ek cert via own custom script, verifying pass
        rlRun "limeUpdateConf tenant ek_check_script /var/lib/keylime/check_ek_script.sh"
        rlRun "cat > /var/lib/keylime/check_ek_script_fail.sh <<_EOF
#!/bin/sh
exit 1
_EOF"
        rlRun "chown keylime:keylime /var/lib/keylime/check_ek_script_fail.sh"
        rlRun "chmod 500 /var/lib/keylime/check_ek_script_fail.sh"
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent and check genuine of TPM via ek_check_script option"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c update"
        rlAssertGrep "AGENT_UUID=$AGENT_ID" $rlRun_LOG -E
        rlAssertGrep "EK=-----BEGIN PUBLIC KEY-----" $rlRun_LOG -E
        rlAssertGrep "EK_CERT=[^ ]+" $rlRun_LOG -E
        rlAssertGrep "EK_TPM=[^ ]+" $rlRun_LOG -E
        rlAssertGrep "PROVKEYS={}" $rlRun_LOG
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Expected fail of adding keylime agent due verifying of script via ek_ceck_script option, which doesn't have a zero exit code."
        #veryfing of ek cert via own custom script, verifying fail
        rlRun "limeUpdateConf tenant ek_check_script /var/lib/keylime/check_ek_script_fail.sh"
        #expected to fail
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c update" 1
        rlAssertGrep "ERROR - External check script failed to validate EK" $rlRun_LOG
    rlPhaseEnd
    
    rlPhaseStartCleanup "Do the keylime cleanup"
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
        limeClearData
        rlRun "rm -rf /var/lib/keylime/check_ek_*.sh"
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd

