#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#Machine should have /dev/tpm0 or /dev/tpmrm0 device
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

# variable REGISTRY defines whether we will pull upstream images or use local dockerfiles
#REGISTRY=quay.io

[ -n "${COMP_TEST_KEYLIME_VERSIONS}" ] || COMP_TEST_KEYLIME_VERSIONS="v7.3.0 v7.8.0 v7.9.0 v7.10.0 v7.11.0 v7.12.0"
[ -n "${COMP_TEST_AGENT_VERSION}" ] || COMP_TEST_AGENT_VERSION="v0.2.4"


[ -n "${OLD_KEYLIME_DOCKERFILES}" ] || OLD_KEYLIME_DOCKERFILES=$PWD/Dockerfile.keylime.c10s
NEW_KEYLIME_DOCKERFILE=$PWD/Dockerfile.upstream.c10s
[ -n "$OLD_AGENT_DOCKERFILE" ] || OLD_AGENT_DOCKERFILE=$PWD/Dockerfile.keylime.c10s

rlJournalStart

    rlPhaseStartSetup "Do the global keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        # update /etc/keylime.conf
        limeBackupConfig
        CONT_NETWORK_NAME="container_network"
        IP_VERIFIER="172.18.0.4"
        IP_REGISTRAR="172.18.0.8"
        IP_AGENT="172.18.0.12"
        IP_TENANT="172.18.0.16"
        #create network for containers
        rlRun "limeconCreateNetwork ${CONT_NETWORK_NAME} 172.18.0.0/16"

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

        #prepare verifier container
        rlRun "limeUpdateConf verifier ip $IP_VERIFIER"
        #for log purposes, when agent fail, we need see verifier log, that attestation failed
        rlRun "limeUpdateConf verifier log_destination stream"

        # prepare registrar container
        rlRun "limeUpdateConf registrar ip $IP_REGISTRAR"

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $IP_VERIFIER"
        rlRun "limeUpdateConf tenant registrar_ip $IP_REGISTRAR"

    rlPhaseEnd

function test_iteration() {

    rlPhaseStartSetup "Do the setup for iteration $ITERATION"
        # Pull or build keylime containers
        TAG_OLD_VERIFIER="old_verifier_image"
	if [ -n "$OLD_VERIFIER_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $OLD_VERIFIER_IMAGE $TAG_OLD_VERIFIER"
        else
            rlRun "limeconPrepareImage ${OLD_KEYLIME_DOCKERFILE} ${TAG_OLD_VERIFIER}"
	fi
        TAG_OLD_REGISTRAR="old_registrar_image"
	if [ -n "$REGISTRY" ]; then
            rlRun "limeconPullImage $REGISTRY $OLD_REGISTRAR_IMAGE $TAG_OLD_REGISTRAR"
        else
            rlRun "limeconPrepareImage ${OLD_KEYLIME_DOCKERFILE} ${TAG_OLD_REGISTRAR}"
	fi
        TAG_AGENT="old_agent_image"
	if [ -n "$REGISTRY" ]; then
            rlRun "limeconPullImage $REGISTRY $OLD_AGENT_IMAGE $TAG_AGENT"
        else
            rlRun "limeconPrepareImage ${OLD_AGENT_DOCKERFILE} ${TAG_AGENT}"
	fi

        #run verifier container
        CONT_VERIFIER="verifier_container"
        rlRun "limeconRunVerifier $CONT_VERIFIER $TAG_OLD_VERIFIER $IP_VERIFIER $CONT_NETWORK_NAME keylime_verifier /etc/keylime"
        rlRun "limeWaitForVerifier 8881 $IP_VERIFIER"
        #wait for generating of certs
        sleep 5
        rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_ca/ ."
        #run registrar container
        CONT_REGISTRAR="registrar_container"
        rlRun "limeconRunRegistrar $CONT_REGISTRAR $TAG_OLD_REGISTRAR $IP_REGISTRAR $CONT_NETWORK_NAME keylime_registrar /etc/keylime $(realpath ./cv_ca)"
        rlRun "limeWaitForRegistrar 8891 $IP_REGISTRAR"

        CONT_TENANT="tenant_container"
        # define limeconKeylimeTenantCmd so that the keylime container can be used by limeWaitForAgentStatus etc.
        limeconKeylimeTenantCmd="limeconRunTenant $CONT_TENANT localhost/$TAG_OLD_VERIFIER $IP_TENANT $CONT_NETWORK_NAME"
        limeconTenantVolume="$PWD/:/workdir/:z"

        # create allowlist and excludelist and generate policy.json using tenant container
        TESTDIR=$(limeCreateTestDir)
        #rlRun "limeCreateTestPolicy"
        #rlRun "podman run --rm --attach stdout -v $PWD:/root:z tenant_image /bin/bash -c 'cd /root && keylime_create_policy -a allowlist.txt -e excludelist.txt 2> /dev/null' > policy.json"

        #setup of agent
        CONT_AGENT="old_agent_container"
        rlRun "limeUpdateConf agent registrar_ip '\"$IP_REGISTRAR\"'"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID $IP_AGENT confdir_$CONT_AGENT"
        rlRun "limeconRunAgent $CONT_AGENT $TAG_AGENT $IP_AGENT $CONT_NETWORK_NAME $TESTDIR keylime_agent $PWD/confdir_$CONT_AGENT $(realpath ./cv_ca)"
        rlRun -s "limeWaitForAgentRegistration $AGENT_ID"
    rlPhaseEnd

    rlPhaseStartTest "Update keylime version in iteration $ITERATION"
        # copy regdb
        rlRun "podman cp $CONT_REGISTRAR:/var/lib/keylime/reg_data.sqlite ."
        rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_data.sqlite ."
        rlRun "limeconStop $CONT_REGISTRAR $CONT_VERIFIER"
        #run verifier container
        TAG_NEW_KEYLIME="new_keylime_image"
        rlRun "limeconPrepareImage ${NEW_KEYLIME_DOCKERFILE} ${TAG_NEW_KEYLIME}"
        CONT_VERIFIER="verifier_new_container"
        rlRun "limeconRunVerifier $CONT_VERIFIER $TAG_NEW_KEYLIME $IP_VERIFIER $CONT_NETWORK_NAME keylime_verifier /etc/keylime"
        rlRun "limeWaitForVerifier 8881 $IP_VERIFIER"
        #rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_ca/ ."
        #run registrar container
        CONT_REGISTRAR="registrar_new_container"
        rlRun "limeconRunRegistrar $CONT_REGISTRAR $TAG_NEW_KEYLIME $IP_REGISTRAR $CONT_NETWORK_NAME keylime_registrar /etc/keylime $(realpath ./cv_ca)"
        rlRun "limeWaitForRegistrar 8891 $IP_REGISTRAR"

        CONT_TENANT="tenant_new_container"
        # define limeconKeylimeTenantCmd so that the keylime container can be used by limeWaitForAgentStatus etc.
        limeconKeylimeTenantCmd="limeconRunTenant $CONT_TENANT localhost/$TAG_NEW_KEYLIME $IP_TENANT $CONT_NETWORK_NAME"
        rlRun -s "limeKeylimeTenant -c regstatus -u $AGENT_ID"
        rlAssertNotGrep ERROR "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the iteration $ITERATION cleanup"
        limeconSubmitLogs
        rlRun "limeconStop $CONT_REGISTRAR $CONT_VERIFIER $CONT_AGENT"
	rlRun "podman rmi $TAG_AGENT $TAG_OLD_VERIFIER $TAG_OLD_REGISTRAR"
        limeExtendNextExcludelist "$TESTDIR"
    rlPhaseEnd

}

    if [ -n "$REGISTRY" ]; then
        # do multiple iterations with upstream images
        OLD_AGENT_IMAGE=keylime/keylime_agent:${COMP_TEST_AGENT_VERSION}
        for ITERATION in ${COMP_TEST_KEYLIME_VERSIONS}; do
            OLD_VERIFIER_IMAGE=keylime/keylime_verifier:$ITERATION
            OLD_REGISTRAR_IMAGE=keylime/keylime_registrar:$ITERATION
            test_iteration
        done
    else
        # do just one iteration with dockefiles
        for ITERATION in ${OLD_KEYLIME_DOCKERFILES}; do
            OLD_KEYLIME_DOCKERFILE=$ITERATION
            test_iteration
        done
    fi

    rlPhaseStartCleanup "Do the global cleanup"
	rlRun "podman rmi $TAG_NEW_KEYLIME"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
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
