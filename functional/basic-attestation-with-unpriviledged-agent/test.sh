#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
AGENT_USER=kagent
AGENT_GROUP=tss
AGENT_WORKDIR=/var/lib/keylime-agent

TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model" && BINARY_INFIX="push_model_"
echo "AGENT_SERVICE=${AGENT_SERVICE}"
echo "TENANT_ARGS=${TENANT_ARGS}"
echo "BINARY_INFIX=${BINARY_INFIX}"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        # update keylime conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\"]'"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
            rlRun "limeUpdateConf agent enable_revocation_notifications false"
        fi
        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier session_lifetime 180"
            rlRun "limeUpdateConf verifier quote_interval 10"
            rlRun "limeUpdateConf agent attestation_interval_seconds 10"
            rlRun "limeUpdateConf agent enable_authentication true"
        fi
        # change /etc/keylime.conf permissions so that agent running as ${AGENT_USER} can access it
        rlRun "find /etc/keylime -type f -exec chmod 444 {} \;"
        rlRun "find /etc/keylime -type d -exec chmod 555 {} \;"
        [ -f /etc/keylime-agent.conf ] && rlRun "chmod 444 /etc/keylime-agent.conf"
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
        sleep 5
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        # do special configuration for the agent
        rlRun "limeUpdateConf agent run_as '\"${AGENT_USER}:${AGENT_GROUP}\"'"
        rlRun "useradd -s /sbin/nologin -g ${AGENT_GROUP} ${AGENT_USER}"
        rlRun "mkdir -p ${AGENT_WORKDIR}/cv_ca"
        #rlRun "mkdir -p ${AGENT_WORKDIR}/secure"
        rlRun "cp /var/lib/keylime/cv_ca/{cacert.crt,client*} ${AGENT_WORKDIR}/cv_ca"
        rlRun "chown -R ${AGENT_USER}:${AGENT_GROUP} ${AGENT_WORKDIR}"
        rlRun "limeUpdateConf agent trusted_client_ca '\"default\"'"
        # when using unit files we need to adjust them
        if [ -f "/usr/lib/systemd/system/keylime_${BINARY_INFIX}agent.service" ] || [ -f "/etc/systemd/system/keylime_${BINARY_INFIX}agent.service" ]; then
            rlRun "mkdir -p '/etc/systemd/system/keylime_${BINARY_INFIX}agent.service.d/'"
            rlRun "cat > '/etc/systemd/system/keylime_${BINARY_INFIX}agent.service.d/20-keylime_dir.conf' <<_EOF
[Service]
Environment=\"KEYLIME_DIR=${AGENT_WORKDIR}\"
_EOF"
            rlRun "systemctl daemon-reload"
            rlRun "limeStart${AGENT_SERVICE}"
        else
            # otherwise exporting KEYLIME_DIR this way would be enough
            rlRun "KEYLIME_DIR=${AGENT_WORKDIR} limeStart${AGENT_SERVICE}"
        fi
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        ps -eo "%p %U %G %x %c" | grep keylime_
        rlRun "pgrep -f keylime_${BINARY_INFIX}agent -u root" 1 "keylime_agent should not be running as root"
        rlRun "pgrep -f keylime_${BINARY_INFIX}agent -u kagent" 0 "keylime_agent shouldbe running as kagent"
        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add ${TENANT_ARGS}
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
            rlRun "expect script.expect"
        else
            rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add ${TENANT_ARGS}"
        fi
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
            ls -l /var/tmp/test_payload_file
            rlAssertExists /var/tmp/test_payload_file
        fi
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho boom' > '$TESTDIR/keylime-bad-script.sh' && chmod a+x '$TESTDIR/keylime-bad-script.sh'"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'FAIL'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/keylime-bad-script.sh" $(limeVerifierLogfile)
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rm -f /var/tmp/test_payload_file"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        if [ -f "/etc/systemd/system/keylime_${BINARY_INFIX}agent.service.d/20-keylime_dir.conf" ]; then
            rlRun "rm -f '/etc/systemd/system/keylime_${BINARY_INFIX}agent.service.d/20-keylime_dir.conf'"
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
