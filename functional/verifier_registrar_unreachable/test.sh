#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00001"

TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model"
ATTESTATION_INTERVAL=10

# Use the correct log file function based on agent type
if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
    GET_AGENT_LOG='limePushAgentLogfile'
else
    GET_AGENT_LOG='limeAgentLogfile'
fi

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        [ "${AGENT_SERVICE}" != "Agent" ] && [ "${AGENT_SERVICE}" != "PushAgent" ] && rlDie "Error: AGENT_SERVICE variable is not set. Value 'Agent' or 'PushAgent' expected!"
        rlRun 'rlImport "./test-helpers"' || rlDie "Error: Cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        # disable revocation notifications on verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # disable revocation notifications on agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        rlRun "limeUpdateConf agent uuid \\\"${AGENT_ID}\\\""
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf verifier exponential_backoff False"
        rlRun "limeUpdateConf verifier quote_interval ${ATTESTATION_INTERVAL}"
        rlRun "limeUpdateConf verifier max_retries 5"
        rlRun "limeUpdateConf verifier request_timeout $((2*ATTESTATION_INTERVAL))"
        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier session_lifetime 180"
            rlRun "limeUpdateConf agent attestation_interval_seconds ${ATTESTATION_INTERVAL}"
            # Right now just for push agent
            rlRun "limeUpdateConf agent exponential_backoff_initial_delay 1000"
            # Allow hostname mismatch in test environment
            rlRun "limeUpdateConf agent tls_accept_invalid_hostnames true"
            rlRun "limeUpdateConf agent enable_authentication true"
            rlRun "limeUpdateConf agent tls_accept_invalid_certs true"
        fi
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
        # Need to start verifier for generating
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStopVerifier"
        # Ensure registrar is also stopped so it's not running when agent starts
        rlRun "limeStopRegistrar"
    rlPhaseEnd

    rlPhaseStartTest "Try to start just agent and check behavior when other services are down"
        rlRun "limeStart${AGENT_SERVICE}"
        rlRun -s "limeWaitForAgentRegistration ${AGENT_ID}" 1
        rlAssertGrep "ERROR - Agent $AGENT_ID does not exist on Registrar" $rlRun_LOG -E
        #check agent status in logs
        rlAssertGrep "Network error.*connection failed" $($GET_AGENT_LOG) -E
    rlPhaseEnd

    rlPhaseStartTest "Try register agent after startup registrar, without running verifier, should succeed"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun -s "limeTIMEOUT=80 limeWaitForAgentRegistration ${AGENT_ID}" 0
        rlAssertGrep "SUCCESS: Agent $AGENT_ID registered" $($GET_AGENT_LOG) -E
        rlAssertGrep "SUCCESS: Agent $AGENT_ID activated" $($GET_AGENT_LOG) -E
    rlPhaseEnd

    rlPhaseStartTest "Start verifier, establish attestation and then make verifier unreachable again"
        rlRun "limeCreateTestPolicy"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"     
        # Add the agent to the verifier database
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add ${TENANT_ARGS}"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        for i in {1..2}; do
            rlLogInfo "Iteration $i: Stopping and Restarting Verifier"
            rlRun "limeStopVerifier"
            rlRun "sleep ${ATTESTATION_INTERVAL}"
            rlRun "limeStartVerifier"
            rlRun "limeWaitForVerifier" 
            rlRun "sleep ${ATTESTATION_INTERVAL}"
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        done
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlAssertNotGrep "Traceback" "$(limeRegistrarLogfile)"
        rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
    rlPhaseEnd

rlJournalEnd
