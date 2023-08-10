#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

#How to run it
#tmt -c distro=rhel-9.1 -c agent=rust run plan --default discover -h fmf -t /setup/configure_kernel_ima_module/ima_policy_simple -t /functional/keylime_agent_container-basic-attestation -vv provision --how=connect --guest=testvm --user root prepare execute --how tmt --interactive login finish
#Machine should have /dev/tpm0 or /dev/tpmrm0 device

# If AGENT_IMAGE env var is defined, the test will pull the image from the
# registry set in REGISTRY (default quay.io). Otherwise, the test builds the
# agent image from the Dockerfile set in AGENT_DOCKERFILE.

[ -n "$AGENT_DOCKERFILE" ] || AGENT_DOCKERFILE=Dockerfile.upstream.c9s

[ -n "$REGISTRY" ] || REGISTRY=quay.io

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
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
        rlRun "limeUpdateConf verifier registrar_ip $SERVER_IP"

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
        TESTDIR_FIRST=$(limeCreateTestDir)
        TESTDIR_SECOND=$(limeCreateTestDir)
        rlRun "echo -e '#!/bin/bash\necho ok' > $TESTDIR_FIRST/good-script.sh && chmod a+x $TESTDIR_FIRST/good-script.sh"
        rlRun "echo -e '#!/bin/bash\necho ok' > $TESTDIR_SECOND/good-script.sh && chmod a+x $TESTDIR_SECOND/good-script.sh"

        #setup of first agent
        #possible could be automated setup as function together with building
        IP_AGENT_FIRST="172.18.0.4"
        AGENT_ID_FIRST="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        CONT_AGENT_FIRST="agent_container_first"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID_FIRST $IP_AGENT_FIRST confdir_$CONT_AGENT_FIRST"

        #run of first agent 
        rlRun "limeconRunAgent $CONT_AGENT_FIRST $TAG_AGENT $IP_AGENT_FIRST $CONT_NETWORK_NAME $TESTDIR_FIRST keylime_agent $PWD/confdir_$CONT_AGENT_FIRST $PWD/cv_ca"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID_FIRST}"

        #setup of second agent
        IP_AGENT_SECOND="172.18.0.8"
        AGENT_ID_SECOND="d432fbb3-d2f1-4a97-9ef7-75bd81c00001"
        CONT_AGENT_SECOND="agent_container_second"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID_SECOND $IP_AGENT_SECOND confdir_$CONT_AGENT_SECOND"

        #run of second agent
        rlRun "limeconRunAgent $CONT_AGENT_SECOND $TAG_AGENT $IP_AGENT_SECOND $CONT_NETWORK_NAME $TESTDIR_SECOND keylime_agent $PWD/confdir_$CONT_AGENT_SECOND $PWD/cv_ca"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID_SECOND}"

        # create allowlist and excludelist for each agent
        rlRun "limeCreateTestLists -e ${TESTDIR_SECOND} ${TESTDIR_FIRST}/*"
        rlRun "mv allowlist.txt allowlist-cont1.txt"
        rlRun "mv excludelist.txt excludelist-cont1.txt"
        rlRun "limeCreateTestLists -e ${TESTDIR_FIRST} ${TESTDIR_SECOND}/*"
        rlRun "mv allowlist.txt allowlist-cont2.txt"
        rlRun "mv excludelist.txt excludelist-cont2.txt"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agents"
        rlRun -s "keylime_tenant -v $SERVER_IP  -t $IP_AGENT_FIRST -u $AGENT_ID_FIRST --allowlist allowlist-cont1.txt --exclude excludelist-cont1.txt -f excludelist-cont1.txt -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID_FIRST 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID_FIRST'" $rlRun_LOG -E
        #check second agent
        rlRun -s "keylime_tenant -v $SERVER_IP  -t $IP_AGENT_SECOND -u $AGENT_ID_SECOND --allowlist allowlist-cont2.txt --exclude excludelist-cont2.txt -f excludelist-cont2.txt -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID_SECOND 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Execute good scripts"
        rlRun "$TESTDIR_FIRST/good-script.sh"
        rlRun "$TESTDIR_SECOND/good-script.sh"
        sleep 5
        rlRun "limeWaitForAgentStatus $AGENT_ID_FIRST 'Get Quote'"
        rlRun "limeWaitForAgentStatus $AGENT_ID_SECOND 'Get Quote'"
    rlPhaseEnd


    rlPhaseStartTest "Fail first keylime agent and check second"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR_FIRST/bad-script.sh && chmod a+x $TESTDIR_FIRST/bad-script.sh"
        rlRun "$TESTDIR_FIRST/bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID_FIRST failed\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID_FIRST '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR_FIRST/bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID_FIRST failed, stopping polling" $(limeVerifierLogfile)
        #check status of first agent
        rlRun "limeWaitForAgentStatus $AGENT_ID_SECOND 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartTest "Fail second keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR_SECOND/bad-script.sh && chmod a+x $TESTDIR_SECOND/bad-script.sh"
        rlRun "$TESTDIR_SECOND/bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID_SECOND failed\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID_SECOND '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR_SECOND/bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID_SECOND failed, stopping polling" $(limeVerifierLogfile)
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconStop 'agent_container.*'"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        #set tmp resource manager permission to default state
        rlRun "chmod o-rw /dev/tpmrm0"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeExtendNextExcludelist $TESTDIR_FIRST
        limeExtendNextExcludelist $TESTDIR_SECOND
        rlRun "rm -f $TESTDIR_FIRST/*"
        rlRun "rm -f $TESTDIR_SECOND/*" 
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd

