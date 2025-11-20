#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# How to run it:
# tmt -c distro=rhel-9.1 -c agent=rust run plan --default discover -h fmf -t /setup/configure_kernel_ima_module/ima_policy_simple -t /functional/registrar_rejecting_duplicate_uuid -vv provision --how=connect --guest=TEST_VM --user root prepare execute --how tmt --interactive login finish
# Where TEST_VM should be configured with swtpm to emulate /dev/tpm0 and /dev/tpm1 devices.

# If AGENT_IMAGE is set, the agent image is pulled from REGISTRY (default quay.io),
# otherwise, the image is built from Dockerfile set in AGENT_DOCKERFILE.
[ -n "$AGENT_DOCKERFILE" ] || AGENT_DOCKERFILE=Dockerfile.upstream.c10s
[ -n "$REGISTRY" ] || REGISTRY=quay.io

TENANT_ARGS=""
AGENT_CMD="keylime_agent"
if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
    TENANT_ARGS="--push-model"
    AGENT_CMD="keylime_push_model_agent"
fi

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # Update /etc/keylime.conf
        limeBackupConfig
        # Getting host IP address
        SERVER_IP=$( hostname -I | awk '{ print $1 }' )

        # Tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $SERVER_IP"
        rlRun "limeUpdateConf tenant registrar_ip $SERVER_IP"

        # Registrar
        rlRun "limeUpdateConf registrar ip $SERVER_IP"

        # Verifier
        rlRun "limeUpdateConf verifier ip $SERVER_IP"

        # Configure verifier for push mode attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        fi

        # Start tpm emulator for first agent - /dev/tpm0
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        # Start ima emulator for first agent
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"
        
        # Start tpm emulator for second agent - /dev/tpm1
        rlRun "limeTPMDevNo=1 limeStartTPMEmulator"
        rlRun "limeTPMDevNo=1 limeWaitForTPMEmulator"
        # Start ima emulator for second agent
        rlRun "limeTPMDevNo=1 TCTI=device:/dev/tpmrm1 limeStartIMAEmulator"
 
        sleep 5

        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

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
        
        # Create test directories and scripts
        TESTDIR_FIRST=$(limeCreateTestDir)
        TESTDIR_SECOND=$(limeCreateTestDir)
        rlRun "echo -e '#!/bin/bash\necho ok' > $TESTDIR_FIRST/good-script.sh && chmod a+x $TESTDIR_FIRST/good-script.sh"
        rlRun "echo -e '#!/bin/bash\necho ok' > $TESTDIR_SECOND/good-script.sh && chmod a+x $TESTDIR_SECOND/good-script.sh"

        # Create allowlist and excludelist for agents
        rlRun "limeCreateTestPolicy -e ${TESTDIR_SECOND} ${TESTDIR_FIRST}/*"
        rlRun "mv policy.json policy1.json"
        rlRun "limeCreateTestPolicy -e ${TESTDIR_FIRST} ${TESTDIR_SECOND}/*"
        rlRun "mv policy.json policy2.json"

        # Setup and run first agent - baseline registration with new UUID
        IP_AGENT_FIRST="172.18.0.4"
        UUID_AGENT_FIRST="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        CONT_AGENT_FIRST="agent_container_first"
        rlRun "limeconPrepareAgentConfdir $UUID_AGENT_FIRST $IP_AGENT_FIRST confdir_$CONT_AGENT_FIRST"

        # Run first agent 
        rlRun "limeconRunAgent $CONT_AGENT_FIRST $TAG_AGENT $IP_AGENT_FIRST $CONT_NETWORK_NAME $TESTDIR_FIRST $AGENT_CMD $PWD/confdir_$CONT_AGENT_FIRST $PWD/cv_ca"
        rlRun "limeWaitForAgentRegistration ${UUID_AGENT_FIRST}"

        # Register first agent via tenant
        rlRun -s "keylime_tenant -v $SERVER_IP -t $IP_AGENT_FIRST -u $UUID_AGENT_FIRST --runtime-policy policy1.json -f /etc/hosts -c add ${TENANT_ARGS}"
        rlRun "limeWaitForAgentStatus $UUID_AGENT_FIRST 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$UUID_AGENT_FIRST'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Test registrar is rejecting duplicate UUID"
        # Setup second agent - registration attempt with duplicate UUID
        IP_AGENT_SECOND="172.18.0.8"
        UUID_AGENT_SECOND="$UUID_AGENT_FIRST"
        CONT_AGENT_SECOND="agent_container_second"
        rlRun "limeconPrepareAgentConfdir $UUID_AGENT_SECOND $IP_AGENT_SECOND confdir_$CONT_AGENT_SECOND"

        # Run second agent
        rlRun "limeTPMDevNo=1 limeconRunAgent $CONT_AGENT_SECOND $TAG_AGENT $IP_AGENT_SECOND $CONT_NETWORK_NAME $TESTDIR_SECOND $AGENT_CMD $PWD/confdir_$CONT_AGENT_SECOND $PWD/cv_ca"
        rlRun "limeWaitForAgentRegistration ${UUID_AGENT_SECOND} 5" 1 "Expect failed registration due to duplicate UUID"            # Nope - passing

        # Check for error messages in registrar logs
        REGISTRAR_LOG=$(limeRegistrarLogfile)
        rlAssertExists "$REGISTRAR_LOG"
        cat "$REGISTRAR_LOG"
        rlAssertGrep "duplicate\|already.*exist\|already.*register|reject.*uuid|uuid.*already|409|conflict" "$REGISTRAR_LOG" -E     # Nope - passing

        # Verify that the second agent is NOT registered
        rlRun -s "keylime_tenant -c regstatus -u $UUID_AGENT_SECOND" 1  # Nope - passing
        rlAssertNotGrep "Registered" "$rlRun_LOG"                       # Nope - passing
        rlRun -s "keylime_tenant -c cvlist"                             # Nope - not as expected, more those uuids are listed
        rlAssertEquals "$(grep -o "$UUID_AGENT_FIRST" "$rlRun_LOG" | wc -l)" "1" "Only one agent should be registered with this UUID" # Nope
        
        # Verify that attempting to add the second agent via tenant fails
        rlRun "keylime_tenant -v $SERVER_IP -t $IP_AGENT_SECOND -u $UUID_AGENT_SECOND --runtime-policy policy2.json -f /etc/hosts -c add ${TENANT_ARGS}" 1 # Yep, finally!

        # Verify the agents are in the expected state
        rlRun "limeWaitForAgentStatus $UUID_AGENT_FIRST 'Get Quote'" 0 "First agent should be registered and working"
        rlRun "limeWaitForAgentStatus $UUID_AGENT_SECOND 'Get Quote' 5" 1 "Second agent should not reach working state due to duplicate UUID" # Nope - passing
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconStop 'agent_container.*'"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        rlRun "limeStopTPMEmulator"
        rlRun "limeTPMDevNo=1 limeStopTPMEmulator"
        rlRun "limeStopIMAEmulator"
        limeExtendNextExcludelist "$TESTDIR_FIRST"
        limeExtendNextExcludelist "$TESTDIR_SECOND"
        rlRun "rm -f $TESTDIR_FIRST/*"
        rlRun "rm -f $TESTDIR_SECOND/*" 
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
