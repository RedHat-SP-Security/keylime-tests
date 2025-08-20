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
        rlRun "limeUpdateConf tenant require_ek_cert false"
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
	rlRun "TMPDIR=\$( mktemp -d )"
        rlRun "chown keylime:keylime $TMPDIR"

        rlRun 'cat > /var/lib/keylime/check_ek_script.sh <<_EOF
#!/bin/sh
echo AGENT_UUID=\${AGENT_UUID}
echo EK=\${EK}
echo EK_CERT=\${EK_CERT}
echo EK_TPM=\${EK_TPM}
echo PROVKEYS=\${PROVKEYS}
# confirm EK cert
printf "%s" "\$EK" > $TMPDIR/pubkey.pem
printf "%s" "\${EK_CERT}" > $TMPDIR/ek_cert.der.b64
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
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent and check genuine of TPM via ek_check_script option"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -f /etc/hostname -c update"
        rlAssertGrep "AGENT_UUID=$AGENT_ID" $rlRun_LOG -E
        rlAssertGrep "EK=-----BEGIN PUBLIC KEY-----" $rlRun_LOG -E
        rlAssertGrep "EK_CERT=[^ ]+" $rlRun_LOG -E
        rlAssertGrep "EK_TPM=[^ ]+" $rlRun_LOG -E
        rlAssertGrep "PROVKEYS={}" $rlRun_LOG
        # verify EK cert for swtpm
        if limeTPMEmulated; then
            rlRun "openssl rsa -pubin -in $TMPDIR/pubkey.pem -text"
            rlRun "base64 -d $TMPDIR/ek_cert.der.b64 > $TMPDIR/ek_cert.der"
            rlRun "openssl x509 -inform der -in $TMPDIR/ek_cert.der > $TMPDIR/ek_cert.pem"
            rlRun "cat /var/lib/swtpm-localca/issuercert.pem /var/lib/swtpm-localca/swtpm-localca-rootca-cert.pem > $TMPDIR/ca_bundle.pem"
            rlRun "openssl verify  -CAfile $TMPDIR/ca_bundle.pem $TMPDIR/ek_cert.pem"
        fi
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Expected fail of adding keylime agent due verifying of script via ek_ceck_script option, which doesn't have a zero exit code."
        #veryfing of ek cert via own custom script, verifying fail
        rlRun "limeUpdateConf tenant ek_check_script /var/lib/keylime/check_ek_script_fail.sh"
        #expected to fail
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -f /etc/hostname -c update" 1
        rlAssertGrep "ERROR - External check script failed to validate EK" $rlRun_LOG
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
        rlRun "rm -rf /var/lib/keylime/check_ek_*.sh"
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
