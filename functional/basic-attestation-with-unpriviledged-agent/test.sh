#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
AGENT_USER=kagent
AGENT_GROUP=tss
AGENT_WORKDIR=/var/lib/keylime-agent

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        notifiers="$KEYLIME_TEST_REVOCATION_NOTIFIERS"
        if [ -z "$notifiers" ]; then
            notifiers=zeromq
        fi
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf cloud_verifier revocation_notifiers '$notifiers'"
        else
            rlRun "limeUpdateConf cloud_verifier revocation_notifiers ''"
            rlRun "limeUpdateConf cloud_agent listen_notifications False"
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
        # do special configuration for the agent
        rlRun "limeUpdateConf cloud_agent run_as ${AGENT_USER}:${AGENT_GROUP}"
        rlRun "useradd -s /sbin/nologin -g ${AGENT_GROUP} ${AGENT_USER}"
        rlRun "mkdir -p ${AGENT_WORKDIR}/cv_ca"
        #rlRun "mkdir -p ${AGENT_WORKDIR}/secure"
        rlRun "cp /var/lib/keylime/cv_ca/{cacert.crt,client*} ${AGENT_WORKDIR}/cv_ca"
        rlRun "chown -R ${AGENT_USER}:${AGENT_GROUP} ${AGENT_WORKDIR}"
        # when using unit files we need to adjust them
        if [ -f /usr/lib/systemd/system/keylime_agent.service -o -f /etc/systemd/system/keylime_agent.service ]; then
            rlRun "mkdir -p /etc/systemd/system/keylime_agent.service.d/"
            rlRun "cat > /etc/systemd/system/keylime_agent.service.d/20-keylime_dir.conf <<_EOF
[Service]
Environment=\"KEYLIME_DIR=${AGENT_WORKDIR}\"
_EOF"
            rlRun "systemctl daemon-reload"
            rlRun "limeStartAgent"
        else
            # otherwise exporting KEYLIME_DIR this way would be enough
            rlRun "KEYLIME_DIR=${AGENT_WORKDIR} limeStartAgent"
        fi
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        ps -ef | grep keylime_agent
        rlRun "pgrep -f keylime_agent -u root" 1 "keylime_agent should not be running as root"
        rlRun "pgrep -f keylime_agent -u kagent" 0 "keylime_agent shouldbe running as kagent"
        # create allowlist and excludelist
        limeCreateTestLists
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt --include payload --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
        rlAssertExists /var/tmp/test_payload_file
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/keylime-bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
        fi
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
        if [ -f /etc/systemd/system/keylime_agent.service.d/20-keylime_dir.conf ]; then
            rlRun "rm -f /etc/systemd/system/keylime_agent.service.d/20-keylime_dir.conf"
            rlRun "systemctl daemon-reload"
        fi
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
        rlRun "userdel -r ${AGENT_USER}"
        mount | grep -q "${AGENT_WORKDIR}/secure" && rlRun "umount ${AGENT_WORKDIR}/secure"
        rlRun "rm -rf ${AGENT_WORKDIR}"
    rlPhaseEnd

rlJournalEnd
