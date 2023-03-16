#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        rlFileBackup --clean --missing-ok ~/.gnupg /etc/hosts
        rlRun "rm -rf /root/.gnupg/"
        rlRun "TmpDir=\$(mktemp -d)"
        rlRun "pushd ${TmpDir}"
        limeBackupConfig
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
        rlRun "limeCreateTestPolicy /etc/hostname"
        CHECKSUM=$( sha256sum policy.json | cut -d ' ' -f 1 )
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
        # sign our policy.json
        rlRun "gpg --detach-sign -o allowlist-gpg.sig policy.json"
	# generate ECDSA key and sign our allowlist
	rlRun "openssl ecparam -genkey -name secp384r1 -noout -out ecdsa-priv.pem"
	rlRun "openssl ec -in ecdsa-priv.pem -pubout -out ecdsa-pub.pem"
	rlRun "openssl dgst -sha256 -binary policy.json > allowlist.hash256"
	rlRun "openssl pkeyutl -sign -inkey ecdsa-priv.pem -in allowlist.hash256 -out allowlist-hash256.sig"
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy policy.json --runtime-policy-name list1"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test updateruntimepolicy fails on malformed policy"
        rlRun -s "keylime_tenant -c updateruntimepolicy --runtime-policy <(echo '{}') --runtime-policy-name list1)" 2
        # rlAssertGrep "{'code': 400, 'status': \"Runtime policy is malformatted: 'meta' is a required property\", 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy providing --runtime-policy-checksum"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy policy.json  --runtime-policy-name list2 --runtime-policy-checksum ${CHECKSUM}"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy providing --runtime-policy-url and --runtime-policy-checksum"
        rlRun "curl 'http://localhost:8000/policy.json'"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list3 --runtime-policy-url 'http://localhost:8000/policy.json' --runtime-policy-checksum ${CHECKSUM}"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy providing --runtime-policy-url and --runtime-policy-sig and --runtime-policy-sig-key with GPG key"
        rlRun "gpg --verify allowlist-gpg.sig policy.json"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list4 --runtime-policy-url 'http://localhost:8000/policy.json' --runtime-policy-sig allowlist-gpg.sig --runtime-policy-sig-key gpg-key.pub"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy providing --runtime-policy-url and --runtime-policy-sig and --runtime-policy-sig-key with ECDSA key"
        rlRun "openssl pkeyutl -in allowlist.hash256 -inkey ecdsa-pub.pem -pubin -verify -sigfile allowlist-hash256.sig"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list7 --runtime-policy-url 'http://localhost:8000/policy.json' --runtime-policy-sig allowlist-hash256.sig --runtime-policy-sig-key ecdsa-pub.pem"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy providing --runtime-policy-url and --runtime-policy-sig-url and --runtime-policy-sig-key"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list5 --runtime-policy-url 'http://localhost:8000/policy.json' --runtime-policy-sig-url 'http://localhost:8000/allowlist-gpg.sig' --runtime-policy-sig-key gpg-key.pub"
    rlPhaseEnd

    rlPhaseStartTest "Test showruntimepolicy"
        rlRun -s "keylime_tenant -c showruntimepolicy --runtime-policy-name list1"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'list1'" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test deleteruntimepolicy"
        rlRun -s "keylime_tenant -c deleteruntimepolicy --runtime-policy-name list1"
        #rlAssertGrep "{'code': 200, 'status': 'Deleted'" $rlRun_LOG
        rlRun -s "keylime_tenant -c showruntimepolicy --runtime-policy-name list1"
        rlAssertGrep "{'code': 404, 'status': 'Runtime policy list1 not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent using the named allowlist"
        rlRun "keylime_tenant -t 127.0.0.1 -u $AGENT_ID --runtime-policy-name list2 -f policy.json -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Update keylime agent while adding new named allowlist"
        rlRun "keylime_tenant -t 127.0.0.1 -u $AGENT_ID --runtime-policy-name list8 --runtime-policy policy.json -f policy.json -c update"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlRun -s "keylime_tenant -c showruntimepolicy --runtime-policy-name list8"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'list8'" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to add runtime policy without specifying --runtime-policy-name"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy policy.json" 1
        rlAssertGrep "runtime_policy_name is required to add a runtime policy" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to add runtime policy without specifying --runtime-policy"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list6 --tpm_policy '{}'" 2
        rlAssertGrep "runtime_policy is required to add a runtime policy" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to add --runtime-policy-name that already exists"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy policy.json --runtime-policy-name list2"
        rlAssertGrep "{'code': 409, 'status': 'Runtime policy with name list2 already exists', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to show runtime policy without specifying --runtime-policy-name"
        rlRun -s "keylime_tenant -c showruntimepolicy" 1
        rlAssertGrep "runtime_policy_name is required to show a runtime policy" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to delete runtime policy without specifying --runtime-policy-name"
        rlRun -s "keylime_tenant -c deleteruntimepolicy" 1
        rlAssertGrep "runtime_policy_name is required to delete a runtime policy" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Try to delete --runtime-policy-name that does not exist"
        rlRun -s "keylime_tenant -c deleteruntimepolicy --runtime-policy-name nosuchlist"
        rlAssertGrep "{'code': 404, 'status': 'Runtime policy nosuchlist not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy not matching --runtime-policy-checksum"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy policy.json --runtime-policy-name list10 --runtime-policy-checksum f00" 1
        rlAssertGrep "Checksum of runtime policy does not match!" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy from --runtime-policy-url not matching --runtime-policy-checksum"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-url 'http://localhost:8000/policy.json' --runtime-policy-name list11 --runtime-policy-checksum f00" 1
        rlAssertGrep "Checksum of runtime policy does not match!" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy not matching --runtime-policy-sig with GPG key"
        rlRun "sed 's/0/1/' policy.json > policy2.json"
        rlRun "gpg --verify allowlist-gpg.sig policy2.json" 1
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list20 --runtime-policy policy2.json --runtime-policy-sig allowlist-gpg.sig --runtime-policy-sig-key gpg-key.pub" 1
        rlAssertGrep "failed detached signature verification" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy not matching --runtime-policy-sig with ECDSA key"
        rlRun "openssl dgst -sha256 -binary policy2.json > allowlist2.hash256"
        rlRun "openssl pkeyutl -in allowlist2.hash256 -inkey ecdsa-pub.pem -pubin -verify -sigfile allowlist-hash256.sig" 1
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list23 --runtime-policy policy2.json --runtime-policy-sig allowlist-hash256.sig --runtime-policy-sig-key ecdsa-pub.pem" 1
        rlAssertGrep "failed detached signature verification" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy from --runtime-policy-url not matching --runtime-policy-sig"
        rlRun "curl 'http://localhost:8000/policy2.json'"
        rlRun "gpg --verify allowlist-gpg.sig policy2.json" 1
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list21 --runtime-policy-url 'http://localhost:8000/policy2.json' --runtime-policy-sig allowlist-gpg.sig --runtime-policy-sig-key gpg-key.pub" 1
        rlAssertGrep "failed detached signature verification" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy from --runtime-policy-url not matching --runtime-policy-sig-url"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy-name list22 --runtime-policy-url 'http://localhost:8000/policy2.json' --runtime-policy-sig-url 'http://localhost:8000/allowlist-gpg.sig' --runtime-policy-sig-key gpg-key.pub" 1
        rlAssertGrep "failed detached signature verification" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addruntimepolicy fails on malformed policy"
        rlRun -s "keylime_tenant -c addruntimepolicy --runtime-policy <(echo '{}') --runtime-policy-name bad)" 2
        # rlAssertGrep "{'code': 400, 'status': \"Runtime policy is malformatted: 'meta' is a required property\", 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test addallowlist"
        rlRun -s "keylime_tenant -c addallowlist --allowlist allowlist.txt --exclude excludelist.txt --allowlist-name list23"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test showallowlist"
        rlRun -s "keylime_tenant -c showallowlist --allowlist-name list23"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'list23'" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test deleteallowlist"
        rlRun -s "keylime_tenant -c deleteallowlist --allowlist-name list23"
        #rlAssertGrep "{'code': 200, 'status': 'Deleted'" $rlRun_LOG
        rlRun -s "keylime_tenant -c showallowlist --allowlist-name list23"
        rlAssertGrep "{'code': 404, 'status': 'Runtime policy list23 not found', 'results': {}}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "kill $HTTP_PID"
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
        rlRun "popd"
        rlRun "rm -rf ${TmpDir}"
        rlRun "gpgconf --kill gpg-agent"
        rlFileRestore
    rlPhaseEnd

rlJournalEnd
