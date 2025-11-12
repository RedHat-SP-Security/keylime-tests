#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00001"

TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model"
DELAY=10

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
        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf agent attestation_interval_seconds 20"
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

        rlRun "limeStart${AGENT_SERVICE}"
        rlRun -s "limeWaitForAgentRegistration ${AGENT_ID}" 1
        rlAssertGrep "ERROR - Agent $AGENT_ID does not exist on Registrar" $rlRun_LOG -E
        rlRun "limeCreateTestPolicy"
        #check agent status in logs
        rlAssertGrep "Error.*Connection refused" $(limeAgentLogfile)
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Try register agent after startup registrar, without running verifier, should suceed"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        sleep 80
        rlRun -s "limeWaitForAgentRegistration ${AGENT_ID}" 0
        rlAssertGrep "SUCCESS: Agent $AGENT_ID registered" $(limeAgentLogfile)
        rlAssertGrep "SUCCESS: Agent $AGENT_ID activated" $(limeAgentLogfile)
    rlPhaseEnd

    rlPhaseStartTest "Stop verifier and check adding keylime agent"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add ${TENANT_ARGS}" 1
        rlAssertGrep "Failed to establish a new connection.*Connection refused" $rlRun_LOG -E
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Connection Refused'" 1
        rlAssertGrep "GET invoked from" $(limeAgentLogfile)
    rlPhaseEnd

    rlPhaseStartTest "Start again verifier and check adding keylime agent"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add ${TENANT_ARGS}"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
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