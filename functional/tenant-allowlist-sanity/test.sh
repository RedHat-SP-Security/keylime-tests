#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        rlRun "TmpDir=\$(mktemp -d)"
        rlRun "pushd ${TmpDir}"
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant ima_allowlist nosuchfile.txt"  # to avoid conflicts, we will be specifying it on cmdline
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
        rlRun "limeCreateTestLists /etc/hostname"
        CHECKSUM=$( sha256sum allowlist.txt | cut -d ' ' -f 1 )
        # start simple http server to serve files
        rlRun "python3 -m http.server 8000 &"
        HTTP_PID=$!
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
        rlRun "gpg --batch --pinentry-mode=loopback --passphrase '' --generate-key gpg.script"
        rlRun "gpg --list-secret-keys"
        rlRun "gpg --armor -o gpg-key.pub --export joe@foo.bar"
        # sign our allowlist.txt
        rlRun "gpg --detach-sign -o allowlist-gpg.sig allowlist.txt"
	# generate ECDSA key and sign our allowlist
	rlRun "openssl ecparam -genkey -name secp384r1 -noout -out ecdsa-priv.pem"
	rlRun "openssl ec -in ecdsa-priv.pem -pubout -out ecdsa-pub.pem"
	rlRun "openssl dgst -sha256 -binary allowlist.txt > allowlist.hash256"
	rlRun "openssl pkeyutl -sign -inkey ecdsa-priv.pem -in allowlist.hash256 -out allowlist-hash256.sig"
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist allowlist.txt --allowlist-name list1"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist providing --allowlist-checksum"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist allowlist.txt --allowlist-name list2 --allowlist-checksum ${CHECKSUM}"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist providing --allowlist-url and --allowlist-checksum"
        rlRun "curl 'http://localhost:8000/allowlist.txt'"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list3 --allowlist-url 'http://localhost:8000/allowlist.txt' --allowlist-checksum ${CHECKSUM}"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist providing --allowlist-url and --allowlist-sig and --allowlist-sig-key with GPG key"
        rlRun "gpg --verify allowlist-gpg.sig allowlist.txt"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list4 --allowlist-url 'http://localhost:8000/allowlist.txt' --allowlist-sig allowlist-gpg.sig --allowlist-sig-key gpg-key.pub"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist providing --allowlist-url and --allowlist-sig and --allowlist-sig-key with ECDSA key"
        rlRun "openssl pkeyutl -in allowlist.hash256 -inkey ecdsa-pub.pem -pubin -verify -sigfile allowlist-hash256.sig"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list7 --allowlist-url 'http://localhost:8000/allowlist.txt' --allowlist-sig allowlist-hash256.sig --allowlist-sig-key ecdsa-pub.pem"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist providing --allowlist-url and --allowlist-sig-url and --allowlist-sig-key"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list5 --allowlist-url 'http://localhost:8000/allowlist.txt' --allowlist-sig-url 'http://localhost:8000/allowlist-gpg.sig' --allowlist-sig-key gpg-key.pub"
    rlPhaseEnd

    rlPhaseStartTest "Test showallowlist"
        rlRun -s "lime_keylime_tenant -c showallowlist --allowlist-name list1"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'list1'" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test deleteallowlist"
        rlRun -s "lime_keylime_tenant -c deleteallowlist --allowlist-name list1"
        #rlAssertGrep "{'code': 200, 'status': 'Deleted'" $rlRun_LOG
        rlRun -s "lime_keylime_tenant -c showallowlist --allowlist-name list1"
        rlAssertGrep "{'code': 404, 'status': 'Allowlist list1 not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent using the named allowlist"
        rlRun "lime_keylime_tenant -t 127.0.0.1 -u $AGENT_ID --allowlist-name list2 --exclude excludelist.txt -f allowlist.txt -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "lime_keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Try to add allowlist without specifying --allowlist-name"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist allowlist.txt" 1
        rlAssertGrep "allowlist_name is required to add an allowlist" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to add allowlist without specifying --allowlist"
        # this would succeed, not sure if this is OK
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list6 --tpm_policy '{}'"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
        rlRun -s "lime_keylime_tenant -c showallowlist --allowlist-name list6"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'list6'.*'ima_policy': None}}" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Try to add --allowlist-name that already exists"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist allowlist.txt --allowlist-name list2"
        rlAssertGrep "{'code': 409, 'status': 'Allowlist with name list2 already exists', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to show allowlist without specifying --allowlist-name"
        rlRun -s "lime_keylime_tenant -c showallowlist"
        rlAssertGrep "{'code': 404, 'status': 'Allowlist None not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to delete allowlist without specifying --allowlist-name"
        rlRun -s "lime_keylime_tenant -c deleteallowlist"
        rlAssertGrep "{'code': 404, 'status': 'Allowlist None not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to delete --allowlist-name that does not exist"
        rlRun -s "lime_keylime_tenant -c deleteallowlist --allowlist-name nosuchlist"
        rlAssertGrep "{'code': 404, 'status': 'Allowlist nosuchlist not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist not matching --allowlist-checksum"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist allowlist.txt --allowlist-name list10 --allowlist-checksum f00" 1
        rlAssertGrep "Checksum of allowlist does not match!" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist from --allowlist-url not matching --allowlist-checksum"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-url 'http://localhost:8000/allowlist.txt' --allowlist-name list11 --allowlist-checksum f00" 1
        rlAssertGrep "Checksum of allowlist does not match!" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist not matching --allowlist-sig with GPG key"
        rlRun "sed 's/^000/111/' allowlist.txt > allowlist2.txt"
        rlRun "gpg --verify allowlist-gpg.sig allowlist2.txt" 1
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list20 --allowlist allowlist2.txt --allowlist-sig allowlist-gpg.sig --allowlist-sig-key gpg-key.pub" 1
        rlAssertGrep "signature verification failed" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist not matching --allowlist-sig with ECDSA key"
        rlRun "openssl dgst -sha256 -binary allowlist2.txt > allowlist2.hash256"
        rlRun "openssl pkeyutl -in allowlist2.hash256 -inkey ecdsa-pub.pem -pubin -verify -sigfile allowlist-hash256.sig" 1
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list23 --allowlist allowlist2.txt --allowlist-sig allowlist-hash256.sig --allowlist-sig-key ecdsa-pub.pem" 1
        rlAssertGrep "signature verification failed" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist from --allowlist-url not matching --allowlist-sig"
        rlRun "curl 'http://localhost:8000/allowlist2.txt'"
        rlRun "gpg --verify allowlist-gpg.sig allowlist2.txt" 1
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list21 --allowlist-url 'http://localhost:8000/allowlist2.txt' --allowlist-sig allowlist-gpg.sig --allowlist-sig-key gpg-key.pub" 1
        rlAssertGrep "signature verification failed" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist from --allowlist-url not matching --allowlist-sig-url"
        rlRun -s "lime_keylime_tenant -c addallowlist --allowlist-name list22 --allowlist-url 'http://localhost:8000/allowlist2.txt' --allowlist-sig-url 'http://localhost:8000/allowlist-gpg.sig' --allowlist-sig-key gpg-key.pub" 1
        rlAssertGrep "signature verification failed" $rlRun_LOG
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
        fi
        limeClearData
        limeRestoreConfig
        rlServiceRestore tpm2-abrmd
        rlRun "popd"
        rlRun "rm -rf ${TmpDir}"
        rlRun "gpgconf --kill gpg-agent"
    rlPhaseEnd

rlJournalEnd
