#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
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
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "limeCtl --verifier-ip 127.0.0.1 agent add $AGENT_ID --ip 127.0.0.1 --verify --runtime-policy policy.json"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        rlRun -s "limeCtl agent list"
        rlRun "limeAssertJsonField $rlRun_LOG code=200 status=Success uuids=$AGENT_ID"
        rlRun "limeCtl --verifier-ip 127.0.0.1 agent remove $AGENT_ID"
        rlRun "limeCtl --verifier-ip 127.0.0.1 agent add $AGENT_ID --ip 127.0.0.1 --verify --runtime-policy policy.json"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        rlRun -s "limeCtl agent list"
        rlRun "limeAssertJsonField $rlRun_LOG code=200 status=Success uuids=$AGENT_ID"
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
