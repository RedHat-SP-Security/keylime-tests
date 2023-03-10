#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
HTTP_SERVER_PORT=8080
# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        CONT_NETWORK_NAME="container_network"

        IP_VERIFIER="2001:db8:4000::"
        IP_REGISTRAR="2001:db8:6000::"
        IP_AGENT="[2001:db8:8000::]"
        #create network for containers
        rlRun "limeconCreateNetwork --ipv6 ${CONT_NETWORK_NAME} 2001:0db8:0000:0000:0000:0000:0000:0000/32"

        #prepare verifier container
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\",\"webhook\"]'"
        rlRun "limeUpdateConf revocations webhook_url http://[$IP_VERIFIER]:${HTTP_SERVER_PORT}"

        rlRun "limeUpdateConf verifier ip $IP_VERIFIER"
        rlRun "limeUpdateConf verifier registrar_ip $IP_REGISTRAR"
        #for log purposes, when agent fail, we need see verifier log, that attestation failed
        rlRun "limeUpdateConf verifier log_destination stream"

        # prepare registrar container
        rlRun "limeUpdateConf registrar ip $IP_REGISTRAR"

        #build verifier container
        TAG_VERIFIER="verifier_image"
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_VERIFIER} ${TAG_VERIFIER}"

        #build registrar container
        TAG_REGISTRAR="registrar_image"
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_REGISTRAR} ${TAG_REGISTRAR}"

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

        #mandatory for access agent containers to tpm
        rlRun "chmod o+rw /dev/tpmrm0"

        #run verifier container
        CONT_VERIFIER="verifier_container"
        rlRun "limeconRunVerifier $CONT_VERIFIER $TAG_VERIFIER $IP_VERIFIER $CONT_NETWORK_NAME"
        rlRun "limeWaitForVerifier 8881 $IP_VERIFIER"
        #wait for generating of certs
        sleep 5
        rlRun "podman cp $CONT_VERIFIER:/var/lib/keylime/cv_ca/ ."

        #tenant need certs
        rlRun "cp -r cv_ca/ /var/lib/keylime/"

        #run registrar container
        CONT_REGISTRAR="registrar_container"
        rlRun "limeconRunRegistrar $CONT_REGISTRAR $TAG_REGISTRAR $IP_REGISTRAR $CONT_NETWORK_NAME"
        rlRun "limeWaitForRegistrar 8891 $IP_REGISTRAR"

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip $IP_VERIFIER"
        rlRun "limeUpdateConf tenant registrar_ip $IP_REGISTRAR"

        #setup of agent
        TAG_AGENT="agent_image"
        CONT_AGENT="agent_container"
        rlRun "cp cv_ca/cacert.crt ."
        rlRun "limeconPrepareImage ${limeLibraryDir}/${DOCKERFILE_AGENT} ${TAG_AGENT}"
        rlRun "limeUpdateConf agent registrar_ip '\"[$IP_REGISTRAR]\"'"
        rlRun "limeconPrepareAgentConfdir $AGENT_ID $IP_AGENT confdir_$CONT_AGENT"

        # create some scripts
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        rlRun "echo -e '#!/bin/bash\necho This is good-script2' > $TESTDIR/good-script2.sh && chmod a+x $TESTDIR/good-script2.sh"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"

        rlRun "limeconRunAgent $CONT_AGENT $TAG_AGENT '2001:db8:8000::' $CONT_NETWORK_NAME $PWD/confdir_$CONT_AGENT $TESTDIR"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlRun "podman exec -t  $CONT_AGENT chmod a+r /etc/keylime/agent.conf" 
        rlRun "podman exec -t  $CONT_AGENT dnf install -y python3-toml"

        HTTP_SERVER_LOG="revocation_log"
        rlRun "podman exec -t  $CONT_VERIFIER dnf install -y nmap-ncat && touch $HTTP_SERVER_LOG"
        # start revocation notifier webhook server using ncat
        rlRun "podman exec -d  $CONT_VERIFIER ncat --no-shutdown -k -l ${HTTP_SERVER_PORT} -c '/usr/bin/sleep 3 && echo HTTP/1.1 200 OK' -o ${HTTP_SERVER_LOG}"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        rlRun "echo $REVOCATION_SCRIPT_TYPE"
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v $IP_VERIFIER -t \[2001:db8:8000::\] -u $AGENT_ID --verify --runtime-policy policy.json --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlRun "podman exec -t $CONT_AGENT ls /var/tmp/test_payload_file"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "sleep 5"
        rlRun "podman logs $CONT_VERIFIER | grep \"keylime.verifier - WARNING - Agent d432fbb3-d2f1-4a97-9ef7-75bd81c00000 failed, stopping polling\""
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlRun "podman logs $CONT_AGENT 2>&1 | grep 'Executing revocation action local_action_modify_payload'"
        rlRun "podman logs $CONT_AGENT 2>&1 | grep 'A node in the network has been compromised: \[2001:db8:8000::\]'"
        rlRun "podman exec -t $CONT_AGENT ls /var/tmp/test_payload_file" 2
        rlRun "podman exec -t  $CONT_VERIFIER cat ${HTTP_SERVER_LOG} | grep revocation "
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeconSubmitLogs
        rlRun "limeconStop registrar_container verifier_container agent_container"
        rlRun "limeconDeleteNetwork $CONT_NETWORK_NAME"
        #set tmp resource manager permission to default state
        rlRun "chmod o-rw /dev/tpmrm0"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeExtendNextExcludelist $TESTDIR
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd
rlJournalEnd

