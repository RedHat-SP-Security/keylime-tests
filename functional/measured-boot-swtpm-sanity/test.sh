#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # if TPM emulator is not present, terminate
        if ! limeTPMEmulated; then
            rlDie "This test requires TPM emulator"
        fi
        # start tpm emulator
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        rlRun "limeCondStartAbrmd"

        # update config.py to use our fake  binary_bios_measurements
        # for the rust agent this is handled in the /setup/install_upstream_rust_keylime task
        CONFIG=$(limeGetKeylimeFilepath --install config.py)
        if [ -n "${CONFIG}" ]; then
            rlFileBackup ${CONFIG}
            rlRun "sed -i 's%^MEASUREDBOOT_ML =.*%MEASUREDBOOT_ML = \"/var/tmp/binary_bios_measurements\"%' ${CONFIG}"
        fi
        rlRun "cp binary_bios_measurements /var/tmp"
        rlFileBackup /etc/hosts  # always backup something just to make rlFileRestore succeed

        # start ima emulator
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"

        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf verifier measured_boot_policy_name accept-all"
        # Reducing quote interval to speed up the test a bit.
        rlRun "limeUpdateConf verifier quote_interval 20"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"

        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier session_lifetime 180"
            rlRun "limeUpdateConf verifier quote_interval 10"
            rlRun "limeUpdateConf agent attestation_interval_seconds 10"
            rlRun "limeUpdateConf agent enable_authentication true"
        fi

        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStart${AGENT_SERVICE}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Try adding agent with PRC15 configured in tpm_policy"
        TPM_POLICY='{"15":["0000000000000000000000000000000000000000","0000000000000000000000000000000000000000000000000000000000000000","000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"]}'
        rlRun "echo '{}' > mb_refstate.txt"
        rlRun -s "keylime_tenant -u $AGENT_ID --tpm_policy '${TPM_POLICY}' --runtime-policy policy.json -f /etc/hostname -c add --mb-policy mb_refstate.txt ${TENANT_ARGS}" 1
        rlAssertGrep 'ERROR - WARNING: PCR 15 is specified in "tpm_policy", but will in fact be used by measured boot. Please remove it from policy' $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Add agent with empty tpm_policy"
        rlRun -s "keylime_tenant -u $AGENT_ID --tpm_policy '{}' --runtime-policy policy.json -f /etc/hostname -c add --mb-policy mb_refstate.txt ${TENANT_ARGS}"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Configure verifier to use elchecking/example measured boot policy, restart and re-register agent"
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        rlRun "keylime_tenant -u $AGENT_ID -c regdelete"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStopVerifier"
        sleep 5
        rlRun "limeUpdateConf verifier measured_boot_policy_name example"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStart${AGENT_SERVICE}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    MB_POLICIES=()
    rlPhaseStartTest "Create measured boot policy using different tools"
        # use installed create_mb_refstate from /usr/share/keylime/scripts
        rlRun "python3 /usr/share/keylime/scripts/create_mb_refstate /var/tmp/binary_bios_measurements mb_refstate2.txt"
        MB_POLICIES+=("mb_refstate2.txt")
        # Use keylime-policy to create the measured boot policy
        rlRun "keylime-policy create measured-boot -e /var/tmp/binary_bios_measurements -o mb_refstate3.txt"
        MB_POLICIES+=("mb_refstate3.txt")
    rlPhaseEnd

    rlPhaseStartTest "Add agent with tpm_policy generated by create_mb_refstate script and incorrect PCR banks"
        rlRun -s "keylime_tenant -u $AGENT_ID --tpm_policy '{}' --runtime-policy policy.json -f /etc/hostname -c add --mb-policy mb_refstate2.txt ${TENANT_ARGS}" 0
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'FAIL'"
        rlAssertGrep "keylime.tpm - ERROR - For PCR 0 and hash sha256 the boot event log has value '.*' but the agent .*returned '.*'" $(limeVerifierLogfile) -E
    rlPhaseEnd

    rlPhaseStartTest "Extend the PCRs with the events from the measured boot log"
        rlRun "TPM_INTERFACE_TYPE=socsim tsseventextend -tpm -if /var/tmp/binary_bios_measurements"
    rlPhaseEnd

    for mb_policy in "${MB_POLICIES[@]}"; do
        rlPhaseStartTest "Restart services and re-register agent"
            rlRun "keylime_tenant -u $AGENT_ID -c delete"
            rlRun "keylime_tenant -u $AGENT_ID -c regdelete"
            rlRun "limeStop${AGENT_SERVICE}"
            rlRun "limeStopVerifier"
            sleep 5
            rlRun "limeStartVerifier"
            rlRun "limeWaitForVerifier"
            rlRun "limeStart${AGENT_SERVICE}"
            rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlPhaseEnd

        rlPhaseStartTest "Add agent with tpm_policy generated by different tools and correct PCR banks"
            rlRun -s "keylime_tenant -u $AGENT_ID --tpm_policy '{}' --runtime-policy policy.json -f /etc/hostname -c add --mb-policy $mb_policy ${TENANT_ARGS}"
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        rlPhaseEnd
    done

    rlPhaseStartTest "Test addmbpolicy"
        rlRun -s "keylime_tenant -c addmbpolicy --mb-policy-name mypolicy --mb-policy mb_refstate.txt"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Try adding a mbpolicy with an existing name"
        rlRun -s "keylime_tenant -c addmbpolicy --mb-policy-name mypolicy --mb-policy mb_refstate2.txt" 1
        rlAssertGrep "{'code': 409, 'status': 'Measured boot policy with name mypolicy already exists', 'results': {}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test listmbpolicy"
        rlRun -s "keylime_tenant -c listmbpolicy"
        rlAssertGrep "mypolicy" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test showmbpolicy"
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name mypolicy"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'mypolicy', 'mb_policy': '{}'}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test updatembpolicy"
        rlRun -s "keylime_tenant -c updatembpolicy --mb-policy-name mypolicy --mb-policy mb_refstate2.txt"
        rlAssertGrep "{'code': 201, 'status': 'Created', 'results': {}}" "$rlRun_LOG"
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name mypolicy"
        rlAssertNotGrep "{'code': 200, 'status': 'Success', 'results': {'name': 'mypolicy', 'mb_policy': '{}'}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test deletembpolicy"
        rlRun "keylime_tenant -c deletembpolicy --mb-policy-name mypolicy"
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name mypolicy" 1
        rlAssertGrep "{'code': 404, 'status': 'Measured boot policy mypolicy not found', 'results': {}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Add an agent with a mbpolicy but without a name and verify UUID as the name of the policy in mbpolicy DB."
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        sleep 5
        rlRun -s "keylime_tenant -u $AGENT_ID -f /etc/hostname -c add --mb-policy mb_refstate.txt ${TENANT_ARGS}"
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name $AGENT_ID"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'name': '$AGENT_ID', 'mb_policy': '{}'}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Delete the above agent and verify the absence of UUID named policy in mbpolicy DB."
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        sleep 5
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name $AGENT_ID" 1
        rlAssertGrep "{'code': 404, 'status': 'Measured boot policy $AGENT_ID not found', 'results': {}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Add an agent with an existing named mbpolicy."
        rlRun -s "keylime_tenant -c addmbpolicy --mb-policy-name mypolicy --mb-policy mb_refstate.txt"
        rlRun -s "keylime_tenant -u $AGENT_ID -f /etc/hostname -c add --mb-policy-name mypolicy ${TENANT_ARGS}"
    rlPhaseEnd

    rlPhaseStartTest "Try to delete the mbpolicy associated with a running agent."
        rlRun -s "keylime_tenant -c deletembpolicy --mb-policy-name mypolicy" 1
        rlAssertGrep "{'code': 409, 'status': \"Can't delete mb_policy as it's currently in use by agent $AGENT_ID\", 'results': {}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Add an agent with a new named mbpolicy." 
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        sleep 5
        rlRun -s "keylime_tenant -u $AGENT_ID -f /etc/hostname -c add --mb-policy-name mypolicy2 --mb-policy mb_refstate.txt ${TENANT_ARGS}"
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name mypolicy2"
    rlPhaseEnd

    rlPhaseStartTest "Remove the above agent and verify the presence of the above mbpolicy in mbpolicy DB." 
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        sleep 5
        rlRun -s "keylime_tenant -c showmbpolicy --mb-policy-name mypolicy2"
    rlPhaseEnd

    rlPhaseStartTest "Add an agent with a non-existing named mbpolicy."
        rlRun -s "keylime_tenant -u $AGENT_ID -f /etc/hostname -c add --mb-policy-name non_existing_policy ${TENANT_ARGS}" 1
        rlAssertGrep "{\"code\": 404, \"status\": \"Could not find mb_policy with name non_existing_policy!\", \"results\": {}}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "limeStopIMAEmulator"
        rlRun "limeStopTPMEmulator"
        rlRun "limeCondStopAbrmd"
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        rlFileRestore
    rlPhaseEnd

rlJournalEnd
