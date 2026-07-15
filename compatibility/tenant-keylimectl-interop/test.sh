#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Set AGENT_SERVICE=PushAgent to test push attestation mode (default: pull mode)
[ -n "${AGENT_SERVICE}" ] || AGENT_SERVICE="Agent"

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Setup keylime services (${AGENT_SERVICE} mode)"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier push_attestation_period 3"
            rlRun "limeUpdateConf verifier push_attestation_challenges_count 10"
            rlRun "limeUpdateConf agent registrar_tls_enabled true"
            rlRun "limeUpdateConf agent enable_authentication true"
        fi
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeCreateTestPolicy"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeStartPushAgent"
        else
            rlRun "limeStartAgent"
        fi
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Enroll with keylime_tenant, manage with keylimectl"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --runtime-policy policy.json -c add --push-model"
            rlRun "limeWaitForAgentStatus --field attestation_status ${AGENT_ID} 'PASS'"
        else
            rlRun "cat > /tmp/enroll.expect <<_EOF
set timeout 30
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --verify --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\\n\"
expect eof
_EOF"
            rlRun "expect /tmp/enroll.expect"
            rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        fi
        rlRun -s "keylimectl agent list"
        rlAssertGrep "${AGENT_ID}" "$rlRun_LOG"
        rlRun -s "keylimectl agent status ${AGENT_ID}"
        rlRun "keylimectl agent remove ${AGENT_ID}"
        rlRun -s "keylimectl agent list"
        rlAssertNotGrep "${AGENT_ID}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Enroll with keylimectl, manage with keylime_tenant"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "keylimectl agent add ${AGENT_ID} --runtime-policy policy.json --push-model"
            rlRun "limeWaitForAgentStatus --field attestation_status ${AGENT_ID} 'PASS'"
        else
            rlRun "keylimectl agent add ${AGENT_ID} --runtime-policy policy.json"
            rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        fi
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "${AGENT_ID}" "$rlRun_LOG"
        rlRun -s "keylime_tenant -c status -u ${AGENT_ID}"
        rlRun "keylime_tenant -c delete -u ${AGENT_ID}"
        rlRun "keylime_tenant -c regdelete -u ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup keylime services"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeStopPushAgent"
        else
            rlRun "limeStopAgent"
        fi
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
