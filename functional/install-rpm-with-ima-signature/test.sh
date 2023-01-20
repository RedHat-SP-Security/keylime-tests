#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# This test requires HW TMP

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
AGENT_USER=kagent
AGENT_GROUP=tss
AGENT_WORKDIR=/var/lib/keylime-agent

TEST_SRC_DIR=$PWD

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertExists ${limeIMAPublicKey} || rlDie "This test requires ${imeIMAPublicKey} to be present on a system"
        rlAssertRpm keylime
        limeBackupConfig

        # update keylime conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf verifier quote_interval 2"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"

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

        # create TMPDIR
        rlRun "TMPDIR=\$( mktemp -d )"
        rlRun "pushd ${TMPDIR}"

        # create allowlist and excludelist
        limeCreateTestPolicy

        # start rngd to provide more random data
        pidof rngd && ENTROPY=false || ENTROPY=true
        $ENTROPY && rlRun "rngd -r /dev/urandom -o /dev/random" 0 "Start rngd to generate random numbers"
        [ -d /root/.gnupg ] && rlFileBackup --clean /root/.gnupg /etc/hosts

        # create gpg key for rpm signing
        cat >gpg.conf <<EOF
%echo Generating a basic OpenPGP key
Key-Type: RSA
Key-Length: 2048
Name-Real: Lime Tester
Name-Comment: with simple passphrase
Name-Email: lime@foo.bar
Expire-Date: 0
Passphrase: abc
# Do a commit here, so that we can later print "done" :-)
%commit
%echo done
EOF
        rlRun "gpg --batch --gen-key gpg.conf" 0 "Create gpg key"
        rlRun "gpg --export --armor lime@foo.bar > pub.key" 0 "Create gpg public key"
        rlRun "rpm --import pub.key" 0 "Import the key"
    rlPhaseEnd

    rlPhaseStartTest "Prepare test RPM file"
        TESTDIR=`limeCreateTestDir`
        rlRun "chmod a+rx ${TESTDIR}"
        # build test rpm
        rlRun -s "rpmbuild -bb -D 'destdir ${TESTDIR}' ${TEST_SRC_DIR}/rpm-ima-sign-test.spec"
        RPM_PATH=$( awk '/Wrote:/ { print $2 }' $rlRun_LOG )
        # generage GPG key for RPM signing
        # create expect script for signing packages
        cat > sign.exp <<EOF
#!/usr/bin/expect -f
spawn rpmsign --addsign --signfiles --fskpath=${limeIMAPrivateKey} ${RPM_PATH}
expect {
    "Enter pass phrase: " {
        send -- "abc\r"
    }
    "Passphrase: " {
        send -- "abc\r"
    }
}
expect eof
EOF
        # add gpg key to rpm macros
        [ -f ~/.rpmmacros ] && rlFileBackup ~/.rpmmacros
        echo "%_gpg_name Lime Tester (with simple passphrase) <lime@foo.bar>" > ~/.rpmmacros
        rlRun "expect sign.exp"
        # we are installing rpm plugin here so it won't be applied when installing ordinary RHEL packages (with signatures)
        rlRun "yum -y install rpm-plugin-ima"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "keylime_tenant -u ${AGENT_ID} --runtime-policy policy.json -f /etc/hostname --sign_verification_key ${limeIMAPublicKey} -c add"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Install RPM file"
        rlRun "rpm -ivh ${RPM_PATH}"
        SCRIPT=$( rpm -qlp ${RPM_PATH} )
        ls -l ${SCRIPT}
        rlRun -s "getfattr -m ^security.ima --dump ${SCRIPT}"
        rlRun "evmctl ima_verify -a sha256 ${SCRIPT}"
        rlRun -s "${SCRIPT} boom"
        rlRun -s "grep '${SCRIPT}' /sys/kernel/security/ima/ascii_runtime_measurements"
    rlPhaseEnd

    rlPhaseStartTest "Confirm the system is still compliant"
        # verifier request new quote every 2 seconds so 10 seconds should be enough
        rlRun "sleep 10" 0 "Wait 10 seconds to give verifier some time to do a new attestation"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rpm -e rpm-plugin-ima"
        rlRun "popd"
        rlRun "rpm -e rpm-ima-sign-test"
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
        rlFileRestore
        limeExtendNextExcludelist ${TESTDIR}
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
