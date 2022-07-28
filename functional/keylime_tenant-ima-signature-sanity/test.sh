#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# This test requires HW TMP

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        rlFileBackup --clean --missing-ok ~/.gnupg /etc/hosts
        rlRun "rm -rf /root/.gnupg/" 
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
        limeCreateTestLists
        # start simple http server to serve files
        rlRun "python3 -m http.server 8000 &"
        HTTP_PID=$!
        #copy IMA key to work dir for future work
        rlRun "cp ${limeIMAPublicKey} ."
        # generate GPG key
        rlRun "gpgconf --kill gpg-agent"
        rlRun "export GNUPGHOME=${TmpDir}"
        rlRun "cat >gpg.script <<EOF
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Joe Tester
Name-Comment: with no passphrase
Name-Email: joe@foo.bar
Expire-Date: 0
# Do a commit here, so that we can later print 'done' :-)
%commit
%echo done
EOF"    
        #generate gpg keys which will be genuine
        rlRun "gpg --batch --pinentry-mode=loopback --passphrase '' --generate-key gpg.script"
        rlRun "gpg --armor -o gpg-key.pub --export joe@foo.bar"
        # sign our IMA key file
        rlRun "gpg --detach-sign -o signature-gpg-genuine.sig ${limeIMAPublicKey}"
        # sign our allowlist.txt and get get invalid signature for our x509_evm.pem
        rlRun "gpg --detach-sign -o signature-gpg-fake.sig allowlist.txt"
    rlPhaseEnd

    rlPhaseStartTest "Verify IMA key using a locally stored GPG signature"
        rlRun "gpg --verify signature-gpg-genuine.sig ${limeIMAPublicKey}"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt --sign_verification_key ${limeIMAPublicKey} --signature-verification-key-sig signature-gpg-genuine.sig --signature-verification-key-sig-key gpg-key.pub -c add"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Test that IMA key verification using GPG signature fails for an invalid signature of key"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt --sign_verification_key ${limeIMAPublicKey} --signature-verification-key-sig signature-gpg-fake.sig --signature-verification-key-sig-key gpg-key.pub -c update" 1
        rlAssertGrep "WARNING - Unable to verify signature" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Verify IMA key using a downloaded GPG signature and key"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt --signature-verification-key-url 'http://localhost:8000/x509_evm.pem' --signature-verification-key-sig-url 'http://localhost:8000/signature-gpg-genuine.sig' --signature-verification-key-sig-url-key gpg-key.pub -c update"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Test that IMA key verification using downloaded GPG signature fails for an invalid signature of key"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt --signature-verification-key-url 'http://localhost:8000/x509_evm.pem' --signature-verification-key-sig-url 'http://localhost:8000/signature-gpg-fake.sig' --signature-verification-key-sig-url-key gpg-key.pub -c update" 1
        rlAssertGrep "WARNING - Unable to verify signature" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "kill $HTTP_PID"
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
        limeRestoreConfig
        limeExtendNextExcludelist ${TESTDIR}
        rlRun "rm -rf ${TmpDir}"
        rlRun "gpgconf --kill gpg-agent"
        rlFileRestore
    rlPhaseEnd

rlJournalEnd
