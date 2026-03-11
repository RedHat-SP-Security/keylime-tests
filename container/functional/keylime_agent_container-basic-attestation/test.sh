#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#How to run it
#tmt -c distro=rhel-9.1 -c agent=rust run plan --default discover -h fmf -t /setup/configure_kernel_ima_module/ima_policy_simple -t /functional/keylime_agent_container-basic-attestation -vv provision --how=connect --guest=testvm --user root prepare execute --how tmt --interactive login finish
#Machine should be configured to emulated /dev/tpm0 and /dev/tpm1 devices with swtpm

# If AGENT_IMAGE env var is defined, the test will pull the image from the
# registry set in REGISTRY (default quay.io). Otherwise, the test builds the
# agent image from the Dockerfile set in AGENT_DOCKERFILE.

[ -n "$AGENT_DOCKERFILE" ] || AGENT_DOCKERFILE=Dockerfile.upstream.c10s

[ -n "$REGISTRY" ] || REGISTRY=quay.io

# Number of agents to test (default: 2)
[ -n "$AGENT_CONT_TEST_NUM_AGENTS" ] || AGENT_CONT_TEST_NUM_AGENTS=2

# attestation interval length
[ -n "$AGENT_CONT_TEST_ATTEST_INTERVAL" ] || AGENT_CONT_TEST_ATTEST_INTERVAL=10

# time/delay for which we will keep attestations running
[ -n "$AGENT_CONT_TEST_ATTEST_DURATION" ] || AGENT_CONT_TEST_ATTEST_DURATION=10

# Validate AGENT_CONT_TEST_NUM_AGENTS
if [ "$AGENT_CONT_TEST_NUM_AGENTS" -lt 1 ] || [ "$AGENT_CONT_TEST_NUM_AGENTS" -gt 250 ]; then
    echo "ERROR: AGENT_CONT_TEST_NUM_AGENTS must be between 1 and 250 (got: $AGENT_CONT_TEST_NUM_AGENTS)"
    exit 1
fi

# Memory monitoring interval in seconds (default: 5)
[ -n "$MEMORY_MONITOR_INTERVAL" ] || MEMORY_MONITOR_INTERVAL=5

TENANT_ARGS=""
AGENT_CMD="keylime_agent"
if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
    TENANT_ARGS="--push-model"
    AGENT_CMD="keylime_push_model_agent"
fi

# Helper functions to log events to memory log files
log_verifier_event() {
    local EVENT="$1"
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    [ -n "$VERIFIER_MEMORY_LOG" ] && echo "# [$TIMESTAMP] $EVENT" >> "$VERIFIER_MEMORY_LOG"
}

log_registrar_event() {
    local EVENT="$1"
    local TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    [ -n "$REGISTRAR_MEMORY_LOG" ] && echo "# [$TIMESTAMP] $EVENT" >> "$REGISTRAR_MEMORY_LOG"
}

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        limeTIMEOUT="$(( 3*$AGENT_CONT_TEST_ATTEST_INTERVAL ))"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        #getting ip of host
        SERVER_IP=$( hostname -I | awk '{ print $1 }' )

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $SERVER_IP"
        rlRun "limeUpdateConf tenant registrar_ip $SERVER_IP"

        #registrar
        rlRun "limeUpdateConf registrar ip $SERVER_IP"

        #verifier
        rlRun "limeUpdateConf verifier ip $SERVER_IP"
        rlRun "limeUpdateConf verifier quote_interval ${AGENT_CONT_TEST_ATTEST_INTERVAL}"

        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier session_lifetime 180"
            rlRun "limeUpdateConf agent attestation_interval_seconds ${AGENT_CONT_TEST_ATTEST_INTERVAL}"
            rlRun "limeUpdateConf agent verifier_url '\"https://$SERVER_IP:8881\"'"
            rlRun "limeUpdateConf agent enable_authentication true"
        fi

        # Validate that enough TPM devices will be available
        # After starting emulators, we'll have /dev/tpmrm0, /dev/tpmrm1, etc.
        # We need AGENT_CONT_TEST_NUM_AGENTS TPM devices
        rlLog "Checking if system can support $AGENT_CONT_TEST_NUM_AGENTS TPM devices"

        # Start TPM emulators for all agents
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            if [ $i -eq 0 ]; then
                rlRun "limeStartTPMEmulator"
                rlRun "limeWaitForTPMEmulator"
                rlRun "limeInstallIMAConfig"
                rlRun "limeStartIMAEmulator"
            else
                rlRun "limeTPMDevNo=$i limeStartTPMEmulator"
                rlRun "limeTPMDevNo=$i limeWaitForTPMEmulator"
                rlRun "limeTPMDevNo=$i TPM2TOOLS_TCTI=device:/dev/tpmrm$i limeStartIMAEmulator --no-stop"
            fi
        done

        sleep 5

        # Verify that all required TPM devices are available
        AVAILABLE_TPMS=$(ls -1 /dev/tpmrm* 2>/dev/null | wc -l)
        rlLog "Found $AVAILABLE_TPMS TPM devices, need $AGENT_CONT_TEST_NUM_AGENTS"
        if [ "$AVAILABLE_TPMS" -lt "$AGENT_CONT_TEST_NUM_AGENTS" ]; then
            rlDie "ERROR: Insufficient TPM devices available. Found $AVAILABLE_TPMS, but need $AGENT_CONT_TEST_NUM_AGENTS for the test."
        fi
        rlPass "TPM device check: $AVAILABLE_TPMS devices available for $AGENT_CONT_TEST_NUM_AGENTS agents"

        # remove old certificates to make sure they are regenerated
        rlRun "limeClearCertificates"

        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        log_verifier_event "Verifier started"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        log_registrar_event "Registrar started"

        # Start memory monitoring
        VERIFIER_MEMORY_LOG="verifier_memory.log"
        REGISTRAR_MEMORY_LOG="registrar_memory.log"
        export VERIFIER_MEMORY_LOG
        export REGISTRAR_MEMORY_LOG
        rlRun "bash $PWD/monitor_memory.sh $VERIFIER_MEMORY_LOG $REGISTRAR_MEMORY_LOG $MEMORY_MONITOR_INTERVAL &"
        MEMORY_MONITOR_PID=$!
        rlLog "Memory monitoring started with PID $MEMORY_MONITOR_PID"

        CONT_NETWORK_NAME="agent_network"
        rlRun "limeconCreateNetwork ${CONT_NETWORK_NAME} 172.18.0.0/16"
        rlRun "limeUpdateConf agent registrar_ip '\"$SERVER_IP\"'"

        rlRun "cp -r /var/lib/keylime/cv_ca ."
        rlAssertExists ./cv_ca/cacert.crt

        # Pull or build agent image
        TAG_AGENT="agent_image"
        if [ -n "$AGENT_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $AGENT_IMAGE $TAG_AGENT"
        else
            rlRun "limeconPrepareImage ${AGENT_DOCKERFILE} ${TAG_AGENT}"
        fi

        # Create top-level test directory
        TESTTOPDIR=$(limeCreateTestDir)

        # Initialize arrays to store agent data
        declare -a AGENT_IDS
        declare -a AGENT_IPS
        declare -a AGENT_CONTAINERS
        declare -a AGENT_TESTDIRS

        # Setup and run agents in a loop
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            # Create test subdirectory for this agent
            TESTDIR="$TESTTOPDIR/$i"
            rlRun "mkdir -p $TESTDIR"
            AGENT_TESTDIRS[$i]=$TESTDIR
            rlRun "echo -e '#!/bin/bash\necho ok' > $TESTDIR/good-script.sh && chmod a+x $TESTDIR/good-script.sh"

            # Generate agent configuration with fixed-length UUID
            AGENT_IP="172.18.0.$((4 + i))"
            AGENT_ID=$(printf "d432fbb3-d2f1-4a97-9ef7-75bd81c%05d" $i)
            CONT_NAME="agent_container_$i"

            AGENT_IDS[$i]=$AGENT_ID
            AGENT_IPS[$i]=$AGENT_IP
            AGENT_CONTAINERS[$i]=$CONT_NAME

            rlRun "limeconPrepareAgentConfdir $AGENT_ID $AGENT_IP confdir_$CONT_NAME"

            # Run agent with appropriate TPM device
            if [ $i -eq 0 ]; then
                rlRun "limeconRunAgent $CONT_NAME $TAG_AGENT $AGENT_IP $CONT_NETWORK_NAME $TESTDIR $AGENT_CMD $PWD/confdir_$CONT_NAME $PWD/cv_ca"
            else
                TPM_DEV_NO=$i
                rlRun "limeTPMDevNo=$TPM_DEV_NO limeconRunAgent $CONT_NAME $TAG_AGENT $AGENT_IP $CONT_NETWORK_NAME $TESTDIR $AGENT_CMD $PWD/confdir_$CONT_NAME $PWD/cv_ca"
            fi

            rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
            log_registrar_event "Agent $i registered (ID: $AGENT_ID, IP: $AGENT_IP)"
        done

        # Create allowlist and excludelist for each agent
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            # Build exclude list (all other agent testdirs)
            EXCLUDE_ARGS=""
            for j in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
                if [ $j -ne $i ]; then
                    EXCLUDE_ARGS="$EXCLUDE_ARGS -e ${AGENT_TESTDIRS[$j]}/"
                fi
            done

            rlRun "limeCreateTestPolicy $EXCLUDE_ARGS ${AGENT_TESTDIRS[$i]}/*"
            rlRun "mv policy.json policy$i.json"
        done
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agents"
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            AGENT_ID=${AGENT_IDS[$i]}
            AGENT_IP=${AGENT_IPS[$i]}

            rlRun -s "keylime_tenant -v $SERVER_IP -t $AGENT_IP -u $AGENT_ID --runtime-policy policy$i.json -f /etc/hosts -c add ${TENANT_ARGS}"
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"

            if [ $i -eq 0 ]; then
                rlRun -s "keylime_tenant -c cvlist"
                rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
            fi

            log_verifier_event "Agent $i activated (ID: $AGENT_ID)"
        done
    rlPhaseEnd

    rlPhaseStartTest "Execute good scripts"
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            TESTDIR=${AGENT_TESTDIRS[$i]}
            rlRun "$TESTDIR/good-script.sh"
        done
        sleep $limeTimeout
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            AGENT_ID=${AGENT_IDS[$i]}
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        done
        rlLogInfo "Wait ${AGENT_CONT_TEST_ATTEST_DURATION} seconds just to keep attestation running"
        rlRun "sleep ${AGENT_CONT_TEST_ATTEST_DURATION}"
    rlPhaseEnd

    rlPhaseStartTest "Fail each keylime agent"
        # Create and execute bad scripts on all agents
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            TESTDIR=${AGENT_TESTDIRS[$i]}
            rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
            rlRun "$TESTDIR/bad-script.sh"
        done

        # Check each agent for failure
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            TESTDIR=${AGENT_TESTDIRS[$i]}
            AGENT_ID=${AGENT_IDS[$i]}

            # Only check logs when using 2 or fewer agents
            # With many agents, log entries may get pushed out of tail window
            if [ "$AGENT_CONT_TEST_NUM_AGENTS" -le 2 ]; then
                rlRun "rlWaitForCmd 'tail -30 \$(limeVerifierLogfile) | grep -Eiq \"Agent.*$AGENT_ID.*failed\"' -m 30 -d 2 -t 60"
                rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/bad-script.sh" $(limeVerifierLogfile)
            fi
            log_verifier_event "Agent $i failed attestation (ID: $AGENT_ID)"

            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'FAIL'"
            rlAssertGrep "$TESTDIR/bad-script.sh" /sys/kernel/security/ima/ascii_runtime_measurements
        done
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # Stop memory monitoring
        if [ -n "$MEMORY_MONITOR_PID" ]; then
            rlLog "Stopping memory monitoring (PID $MEMORY_MONITOR_PID)"
            kill $MEMORY_MONITOR_PID 2>/dev/null || true
            wait $MEMORY_MONITOR_PID 2>/dev/null || true
        fi

        # Attach memory logs to test results
        if [ -f "$VERIFIER_MEMORY_LOG" ]; then
            rlFileSubmit "$VERIFIER_MEMORY_LOG"
        fi
        if [ -f "$REGISTRAR_MEMORY_LOG" ]; then
            rlFileSubmit "$REGISTRAR_MEMORY_LOG"
        fi

        limeconSubmitLogs
        rlRun "limeconStop 'agent_container.*'"
        rlRun "limeStopRegistrar"
        log_registrar_event "Registrar stopped"
        rlRun "limeStopVerifier"
        log_verifier_event "Verifier stopped"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"

        # Stop all TPM emulators
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            if [ $i -eq 0 ]; then
                rlRun "limeStopTPMEmulator"
            else
                rlRun "limeTPMDevNo=$i limeStopTPMEmulator"
            fi
        done
        rlRun "limeStopIMAEmulator"

        # Clean up test directories
        for i in $(seq 0 $((AGENT_CONT_TEST_NUM_AGENTS - 1))); do
            TESTDIR=${AGENT_TESTDIRS[$i]}
            rlRun "rm -f $TESTDIR/*"
        done
        limeExtendNextExcludelist $TESTTOPDIR
        rlRun "rm -rf $TESTTOPDIR" 
        limeSubmitCommonLogs
        limeClearData
        rlRun "limeClearCertificates"
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
