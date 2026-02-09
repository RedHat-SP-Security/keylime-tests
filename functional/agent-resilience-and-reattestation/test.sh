#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00001"

TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model"
DELAY=10
ATTESTATION_INTERVAL=15

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
        # disable exponential_backoff to speed up verifier response
        rlRun "limeUpdateConf verifier exponential_backoff False"
        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier session_lifetime 180"
            rlRun "limeUpdateConf verifier quote_interval ${ATTESTATION_INTERVAL}"
            rlRun "limeUpdateConf agent attestation_interval_seconds ${ATTESTATION_INTERVAL}"
            #rlRun "limeUpdateConf agent tls_accept_invalid_certs true"
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
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStart${AGENT_SERVICE}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlRun "limeCreateTestPolicy"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add ${TENANT_ARGS}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PASS'"
        else
            rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'"
        fi
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Test agent restart - agent should re-establish attestation"
        rlLogInfo "Restarting agent service"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStart${AGENT_SERVICE}"
	sleep "${DELAY}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlRun "keylime_tenant -c reglist"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PASS'" 0 "Agent should re-establish attestation after restart"
        else
            rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'" 0 "Agent should re-establish attestation after restart"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Test verifier restart - agent should remain attested"
        rlLogInfo "Restarting verifier service"
        rlRun "limeStopVerifier"
	rlRun "sleep ${DELAY}"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        # give some time for verifier to reload agents from database
        rlRun "sleep ${DELAY}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PASS'" 0 "Agent should remain attested after verifier restart"
        else
            rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'" 0 "Agent should remain attested after verifier restart"
        fi
        rlRun -s "keylime_tenant -c cvlist"
    rlPhaseEnd

    rlPhaseStartTest "Delete agent from registrar and restart agent - should re-register and attest"
        rlLogInfo "Deleting agent from registrar"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID -c regdelete ${TENANT_ARGS}"
        # verify agent is deleted
        rlRun -s "keylime_tenant -c reglist"
        rlAssertNotGrep "$AGENT_ID" $rlRun_LOG
        # restart the agent
        rlLogInfo "Restarting agent service after deletion"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStart${AGENT_SERVICE}"
	rlRun "sleep ${DELAY}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
	rlRun "sleep ${DELAY}"
        # verify the agent is attested
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PASS'" 0 "Agent should re-register and attest after restart"
        else
            rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'" 0 "Agent should re-register and attest after restart"
        fi
        rlRun -s "keylime_tenant -c cvlist"
    rlPhaseEnd

function check_time_diffs() {
    # Convert the string of times into an array
    local timestamps=($1)
    local prev_epoch
    local lower_limit=$(( ${ATTESTATION_INTERVAL}-1 ))
    local upper_limit=$(( ${ATTESTATION_INTERVAL}+1 ))

    # Loop through the array using indices
    for i in "${!timestamps[@]}"; do
        # Convert HH:MM:SS to Unix Epoch seconds
        current_epoch=$(date -d "${timestamps[$i]}" +%s)

        if [[ $i -gt 0 ]]; then
            diff=$(( current_epoch - prev_epoch ))
	    rlRun "test $diff -ge ${lower_limit} && test $diff -le ${upper_limit}" 0 "Measured attestation interval should be between ${lower_limit} and ${upper_limit} seconds, measured $diff seconds"
        fi
        prev_epoch=$current_epoch
    done
}

    if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
        rlPhaseStartTest "Verify that push agent keeps attestation interval"
            rlRun "sleep $(( 3*${ATTESTATION_INTERVAL} ))"
	    rlLogInfo "Extracting recent attestation initiation times"
	    TIMES=$( grep 'Phase 1' /var/tmp/limeLib/agent.log | tail -n 4 | cut -d ' ' -f 3 | xargs )
	    rlLogInfo "TIMES=$TIMES"
	    check_time_diffs "$TIMES"
        rlPhaseEnd
    fi

    rlPhaseStartTest "Remove agent and re-add with updated policy"
        # create a script that will be allowed
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho This is new-script' > $TESTDIR/new-script.sh && chmod a+x $TESTDIR/new-script.sh"
        # create new policy including the new script
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"
        rlLogInfo "Removing agent"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID -c delete ${TENANT_ARGS}"
        rlRun -s "keylime_tenant -c cvlist"
        # run the new script
        rlRun "${TESTDIR}/new-script.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep new-script.sh"
        # re-add agent with updated policy
        rlLogInfo "Re-adding agent with updated policy"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add ${TENANT_ARGS}"
        rlRun "sleep ${DELAY}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PASS'" 0 "Agent should remain attested after running new allowed script"
        else
            rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'" 0 "Agent should remain attested after running new allowed script"
        fi
        rlRun -s "keylime_tenant -c cvlist"
    rlPhaseEnd

    rlPhaseStartTest "Stop agent so it stops sending quotes - should fail attestation"
        rlLogInfo "Stopping agent"
        rlRun "limeStop${AGENT_SERVICE}"
        # verify the agent is not attested
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeTIMEOUT=$(( ${ATTESTATION_INTERVAL}*6 )) limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'FAIL'" 0 "Agent should fail attestation"
        else
            rlRun "limeTIMEOUT=$(( ${ATTESTATION_INTERVAL}*6 )) limeWaitForAgentStatus '$AGENT_ID' '(Failed|Invalid Quote)'" 0 "Agent should fail attestation"
        fi
        rlRun -s "keylime_tenant -c cvlist"
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
