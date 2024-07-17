#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#Machine should have /dev/tpm0 or /dev/tpmrm0 device
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

[ -n "$VERIFIER_DOCKERFILE" ] || VERIFIER_DOCKERFILE=Dockerfile.upstream.c10s
[ -n "$REGISTRAR_DOCKERFILE" ] || REGISTRAR_DOCKERFILE=Dockerfile.upstream.c10s
[ -n "$AGENT_DOCKERFILE" ] || AGENT_DOCKERFILE=Dockerfile.upstream.c10s
[ -n "$TENANT_DOCKERFILE" ] || TENANT_DOCKERFILE=Dockerfile.upstream.c10s

[ -n "$REGISTRY" ] || REGISTRY=quay.io

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
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

        #need to setup configuration files

        # Pull or build verifier container
        TAG_VERIFIER="verifier_image"
        if [ -n "$VERIFIER_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $VERIFIER_IMAGE $TAG_VERIFIER"
        else
            rlRun "limeconPrepareImage ${VERIFIER_DOCKERFILE} ${TAG_VERIFIER}"
        fi

        # Pull or build registrar container
        TAG_REGISTRAR="registrar_image"
        if [ -n "$REGISTRAR_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $REGISTRAR_IMAGE $TAG_REGISTRAR"
        else
            rlRun "limeconPrepareImage ${REGISTRAR_DOCKERFILE} ${TAG_REGISTRAR}"
        fi

        #build tenant container
        TAG_TENANT="tenant_image"
        rlRun "limeconPrepareImage ${TENANT_DOCKERFILE} ${TAG_TENANT}"

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

        #run verifier container
        CONT_VERIFIER="verifier_container"
        rlRun "limeconRunVerifier $CONT_VERIFIER $TAG_VERIFIER $IP_VERIFIER $CONT_NETWORK_NAME keylime_verifier /etc/keylime"
        rlRun "limeWaitForVerifier 8881 $IP_VERIFIER"
        #wait for generating of certs
        sleep 5
        rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_ca/ ."

        #run registrar container
        CONT_REGISTRAR="registrar_container"
        rlRun "limeconRunRegistrar $CONT_REGISTRAR $TAG_REGISTRAR $IP_REGISTRAR $CONT_NETWORK_NAME keylime_registrar /etc/keylime $(realpath ./cv_ca)"
        rlRun "limeWaitForRegistrar 8891 $IP_REGISTRAR"

        CONT_TENANT="tenant_container"
        # define limeconKeylimeTenantCmd so that the keylime container can be used by limeWaitForAgentStatus etc.
        limeconKeylimeTenantCmd="limeconRunTenant $CONT_TENANT localhost/$TAG_TENANT $IP_TENANT $CONT_NETWORK_NAME"
        limeconTenantVolume="$PWD/:/workdir/:z"

        #setup of agent
        TAG_AGENT="agent_image"
        CONT_AGENT="agent_container"
        rlRun "limeconPrepareImage ${AGENT_DOCKERFILE} ${TAG_AGENT}"
        rlRun "limeUpdateConf agent registrar_ip '\"$IP_REGISTRAR\"'"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID $IP_AGENT confdir_$CONT_AGENT"

        # create some scripts
        TESTDIR=$(limeCreateTestDir)
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        rlRun "echo -e '#!/bin/bash\necho This is good-script2' > $TESTDIR/good-script2.sh && chmod a+x $TESTDIR/good-script2.sh"
        # create allowlist and excludelist and generate policy.json using tenant container
        rlRun "limeCreateTestPolicy --lists-only ${TESTDIR}/*"
        rlRun "podman run --rm --attach stdout -v $PWD:/root:z tenant_image /bin/bash -c 'cd /root && keylime_create_policy -a allowlist.txt -e excludelist.txt 2> /dev/null' > policy.json"

        rlRun "limeconRunAgent $CONT_AGENT $TAG_AGENT $IP_AGENT $CONT_NETWORK_NAME $TESTDIR keylime_agent $PWD/confdir_$CONT_AGENT $(realpath ./cv_ca)"
        rlRun -s "limeWaitForAgentRegistration $AGENT_ID"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "limeKeylimeTenant -v $IP_VERIFIER  -t $IP_AGENT -u $AGENT_ID --runtime-policy /workdir/policy.json -f /etc/hosts -c add"
        rlRun -s "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "limeKeylimeTenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Running allowed scripts should not affect attestation"
        rlRun "${TESTDIR}/good-script1.sh"
        rlRun "${TESTDIR}/good-script2.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script1.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep good-script2.sh"
        rlRun "sleep 5"
        rlRun -s "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "sleep 5"
        rlRun "podman logs verifier_container | grep \"keylime.verifier - WARNING - Agent d432fbb3-d2f1-4a97-9ef7-75bd81c00000 failed, stopping polling\""
        rlRun -s "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconStop registrar_container verifier_container agent_container"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeExtendNextExcludelist "$TESTDIR"
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
