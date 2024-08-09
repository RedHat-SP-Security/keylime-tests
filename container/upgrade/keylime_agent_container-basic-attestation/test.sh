#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#How to run it
#tmt -c distro=rhel-9.1 -c agent=rust run plan --default discover -h fmf -t /setup/configure_kernel_ima_module/ima_policy_simple -t /functional/keylime_agent_container-basic-attestation -vv provision --how=connect --guest=testvm --user root prepare execute --how tmt --interactive login finish
#Machine should be configured to emulated /dev/tpm0 and /dev/tpm1 devices with swtpm

# If AGENT_IMAGE env var is defined, the test will pull the image from the
# registry set in REGISTRY (default quay.io). Otherwise, the test builds the
# agent image from the Dockerfile set in AGENT_DOCKERFILE.

[ -n "$AGENT_DOCKERFILE" ] || AGENT_DOCKERFILE=Dockerfile.agent

[ -n "$REGISTRY" ] || REGISTRY=quay.io


TESTDIR_FIRST=/keylime-tests/keylime-cont-upgrade-0000
CONT_NETWORK_NAME="agent_network"
TAG_AGENT="agent_image"
IP_AGENT_FIRST="172.18.0.4"
AGENT_ID_FIRST="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
CONT_AGENT_FIRST="agent_container_first"
export TCTI=device:/dev/tpmrm0 

function phaseSetup() {
    rlPhaseStartSetup "Do the keylime setup"
        # update /etc/keylime.conf
        limeBackupConfig

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $SERVER_IP"
        rlRun "limeUpdateConf tenant registrar_ip $SERVER_IP"

        #registrar
        rlRun "limeUpdateConf registrar ip $SERVER_IP"

        #verifier
        rlRun "limeUpdateConf verifier ip $SERVER_IP"

        # start tpm emulator
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        # start ima emulator
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"
 
        sleep 5

        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        rlRun "limeconCreateNetwork ${CONT_NETWORK_NAME} 172.18.0.0/16"
        rlRun "limeUpdateConf agent registrar_ip '\"$SERVER_IP\"'"

        rlRun "cp -r /var/lib/keylime/cv_ca ."
        rlAssertExists ./cv_ca/cacert.crt

        # Pull or build agent image
        if [ -n "$AGENT_IMAGE" ]; then
            rlRun "limeconPullImage $REGISTRY $AGENT_IMAGE $TAG_AGENT"
        else
            rlRun "limeconPrepareImage ${AGENT_DOCKERFILE} ${TAG_AGENT}"
        fi
        rlRun "mkdir -p $TESTDIR_FIRST"
        rlRun "echo -e '#!/bin/bash\necho ok' > $TESTDIR_FIRST/good-script.sh && chmod a+x $TESTDIR_FIRST/good-script.sh"

        #setup of first agent
        #possible could be automated setup as function together with building
        rlRun "limeconPrepareAgentConfdir $AGENT_ID_FIRST $IP_AGENT_FIRST confdir_$CONT_AGENT_FIRST"

        #run of first agent 
        rlRun "limeconRunAgent $CONT_AGENT_FIRST $TAG_AGENT $IP_AGENT_FIRST $CONT_NETWORK_NAME $TESTDIR_FIRST keylime_agent $PWD/confdir_$CONT_AGENT_FIRST $PWD/cv_ca"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID_FIRST}"

    rlPhaseEnd
}

function phaseTest() {

    # we are adding a new agent because emulated TPM certs have changed throughout the restart
    rlPhaseStartTest "Add keylime agent"
        # create allowlist and excludelist for each agent
        rlRun "limeCreateTestPolicy ${TESTDIR_FIRST}/*"
        rlRun "mv policy.json policy1.json"
        rlRun -s "keylime_tenant -v $SERVER_IP  -t $IP_AGENT_FIRST -u $AGENT_ID_FIRST --runtime-policy policy1.json -f /etc/hosts -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID_FIRST 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID_FIRST'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Execute good scripts"
        rlRun "$TESTDIR_FIRST/good-script.sh"
        sleep 10
        rlRun "limeWaitForAgentStatus $AGENT_ID_FIRST 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR_FIRST/bad-script.sh && chmod a+x $TESTDIR_FIRST/bad-script.sh"
	rlRun "$TESTDIR_FIRST/bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID_FIRST failed\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID_FIRST '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR_FIRST/bad-script.sh" "$(limeVerifierLogfile)"
        rlAssertGrep "WARNING - Agent $AGENT_ID_FIRST failed, stopping polling" "$(limeVerifierLogfile)"
	rlRun "rm -f /keylime-tests/keylime-cont-upgrade-0000/bad-script.sh"
    rlPhaseEnd

    rlPhaseStartTest "Delete agent"
        rlRun -s "keylime_tenant -v $SERVER_IP  -t $IP_AGENT_FIRST -u $AGENT_ID_FIRST -c delete"
        rlRun -s "keylime_tenant -v $SERVER_IP  -t $IP_AGENT_FIRST -u $AGENT_ID_FIRST -c regdelete"
    rlPhaseEnd
}

function phaseServiceStart() {
    rlPhaseStartTest "Start all services"
        # start tpm emulator
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        # start ima emulator
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"
        sleep 5
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "cp -r /var/lib/keylime/cv_ca ."
        rlAssertExists ./cv_ca/cacert.crt
	# re-create configuration for the agent container
        rlRun "limeconPrepareAgentConfdir $AGENT_ID_FIRST $IP_AGENT_FIRST confdir_$CONT_AGENT_FIRST"
        rlRun "limeconRunAgent $CONT_AGENT_FIRST $TAG_AGENT $IP_AGENT_FIRST $CONT_NETWORK_NAME $TESTDIR_FIRST keylime_agent $PWD/confdir_$CONT_AGENT_FIRST $PWD/cv_ca"
    rlPhaseEnd
}

function phaseServiceStop() {
    rlPhaseStartTest "Stop all services"
        rlRun "limeconStop 'agent_container.*'"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "limeStopTPMEmulator"
        rlRun "limeStopIMAEmulator"
    rlPhaseEnd
}

function phaseCleanup() {
    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        limeExtendNextExcludelist $TESTDIR_FIRST
        rlRun "rm -f $TESTDIR_FIRST/*"
        limeClearData
        limeRestoreConfig
    rlPhaseEnd
}


rlJournalStart

    rlPhaseStartSetup "init"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        rlAssertRpm keylime-agent-rust
        #getting ip of host
        SERVER_IP=$( hostname -I | awk '{ print $1 }' )
    rlPhaseEnd

    # clear $PHASES if IN_PLACE_UPGRADE is specified

    [ -n "$IN_PLACE_UPGRADE" ] && PHASES=""
    echo IN_PLACE_UPGRADE=$IN_PLACE_UPGRADE
    echo PHASES=$PHASES

    # run pre-reboot phase (setup), except when running post-upgrade phase
    if [ -n "$IN_PLACE_UPGRADE" -a "$IN_PLACE_UPGRADE" != "new" ] || echo "${PHASES}" | grep -Eqi '(setup|all)'; then
        phaseSetup
    else  # otherwise we need to start services
        phaseServiceStart
    fi

    # run post-reboot phase (test), except when running pre-upgrade phase
    #if [ -n "$IN_PLACE_UPGRADE" -a "$IN_PLACE_UPGRADE" != "old" ] || echo "${PHASES}" | grep -Eqi '(test|all)'; then
        phaseTest
    #fi

    # always stop services
    phaseServiceStop

    # run cleanup only when run as a standalone test
    if [ -z "$IN_PLACE_UPGRADE" ] && echo "${PHASES}" | grep -Eqi '(cleanup|all)'; then
        phaseCleanup
    fi

rlJournalPrintText

rlJournalEnd
