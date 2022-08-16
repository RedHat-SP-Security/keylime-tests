#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
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
        #when policy will be not on machine
        rlRun "semodule -l | grep 'keylime' &> /dev/null" 0,1
        if [ $? != 0 ]; then
            #local selinux policy aplying
            rlRun "pushd keylime-selinux-policy/"
            rlRun "make -f /usr/share/selinux/devel/Makefile keylime.pp"
            rlRun "semodule -i keylime.pp"
	    #for testing purpose, delete later
            rlRun "setenforce 0"
	    rlRun "popd"
            #changing SELinux context of files
            rlRun "restorecon -R /"
        fi
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
    rlPhaseEnd

    rlPhaseStartTest "Check if keylime SELinux policy is active and rule are applied"
        rlRun "sesearch -A -s keylime_domain -t cert_t -c file -p read"
        rlRun "sesearch -A -s keylime_agent_t -t sssd_t -c unix_stream_socket -p connectto"
        rlRun "sesearch -A -s keylime_server_t -t sssd_t -c unix_stream_socket -p connectto"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c update"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rm -f /var/tmp/test_payload_file"
        rlRun "rm -rf keylime-selinux-policy/keylime.pp"
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
        limeExtendNextExcludelist $TESTDIR
        rlRun "ausearch -m AVC -ts recent | grep keylime" 1
    rlPhaseEnd

rlJournalEnd
