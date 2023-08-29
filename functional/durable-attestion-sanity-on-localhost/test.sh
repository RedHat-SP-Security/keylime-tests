#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

HTTP_SERVER_PORT=8080
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        
        # clean previous durable attestion artifacts stored on filesystem
        rlRun "rm -rf /var/lib/keylime/da/CI_*"

        # copy fake binary_bios_measurements into an alternative path (used to create refstate)
        rlRun "cp binary_bios_measurements /var/tmp"

        # update config.py to use our fake binary_bios_measurements
        # for the rust agent this is handled in the /setup/install_upstream_rust_keylime task
        CONFIG=$(limeGetKeylimeFilepath --install config.py)
        if [ -n "${CONFIG}" ]; then
            rlFileBackup ${CONFIG}
            rlRun "sed -i 's%^MEASUREDBOOT_ML =.*%MEASUREDBOOT_ML = \"/var/tmp/binary_bios_measurements\"%' ${CONFIG}"
        fi
        
        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "limeUpdateConf logger_root level INFO"        

        # disable the need for ek cert for tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # update registrar.conf to load the "flat file" backend for durable attestation
        rlRun "limeUpdateConf registrar durable_attestation_import keylime.da.examples.file"
        rlRun "limeUpdateConf registrar persistent_store_url file:///var/lib/keylime/da?prefix=CI"
        
        # update verifier.conf to load the "flat file" backend for durable attestation
        rlRun "limeUpdateConf verifier durable_attestation_import keylime.da.examples.file"
        rlRun "limeUpdateConf verifier persistent_store_url file:///var/lib/keylime/da?prefix=CI"

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

        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # create refstat from fake binary_bios_measurements
        rlRun "python3 /usr/share/keylime/scripts/create_mb_refstate /var/tmp/binary_bios_measurements mb_refstate.txt"

        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent with both measured boot and runtime policies"
        rlRun "TPM_INTERFACE_TYPE=socsim tsseventextend -tpm -if /var/tmp/binary_bios_measurements"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID  -f /etc/hostname --mb_refstate mb_refstate.txt --runtime-policy policy.json -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Run keylime offline (durable) attestation - asssuming success"
        rlRun "keylime_attest"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
        rlRun "$TESTDIR/bad-script.sh"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID failed\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
    rlPhaseEnd

    rlPhaseStartTest "Run keylime offline (durable) attestation - asssuming failure"
        rlRun -s "keylime_attest" 1
        rlAssertGrep "WARNING - File not found in allowlist: /bad-script.sh" $rlRun_LOG
        rlAssertGrep "ERROR - IMA ERRORS: Some entries couldn't be validated." $rlRun_LOG
        rlAssertGrep "keylime.durable_attestation_fetch_and_replay - INFO -.*Agent $AGENT_ID was NOT in \"attested\" state at.*" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
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
