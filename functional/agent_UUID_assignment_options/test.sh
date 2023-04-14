#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "limeUpdateConf logger_root level DEBUG"
        rlRun "limeUpdateConf logger_keylime level DEBUG"
        rlRun "limeUpdateConf handler_consoleHandler level DEBUG"

        rlRun "limeUpdateConf tenant require_ek_cert False"

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
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
    rlPhaseEnd
    
    rlPhaseStartTest "Hash_ek UUID"
        AGENT_ID="hash_ek"
        #obtain ek cert
        rlRun "tpm2_nvread 0x1c00002 > ekcert.der"
        #calculate hash for assert
        HASH_EK_UUID=$(openssl x509 -inform der -in ekcert.der -pubkey -noout | sha256sum | cut -d " " -f 1)
        rlLogInfo "HASH_EK_UUID=${HASH_EK_UUID}"
        #configure and start agent
        rlRun "limeUpdateConf agent  uuid '\"$AGENT_ID\"'"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${HASH_EK_UUID}"
        rlRun "limeStopAgent"
    rlPhaseEnd

    rlPhaseStartTest "Generate UUID"
        AGENT_ID="generate"
        rlRun "limeUpdateConf agent  uuid '\"$AGENT_ID\"'"
        rlRun "limeStartAgent"
        sleep 3
        GENERATE_UUID=$(systemctl status keylime_agent -all | tail -2 | head -1 | grep -oP '(?<=Agent )[^ ]*')
        rlRun "limeWaitForAgentRegistration ${GENERATE_UUID}"
        rlRun "limeStopAgent"
    rlPhaseEnd

    rlPhaseStartTest "Use ENV variable to set agent UUID"
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c01111"
        rlRun "mkdir -p /etc/systemd/system/keylime_agent.service.d"
        rlRun "cat > /etc/systemd/system/keylime_agent.service.d/15-uuid.conf <<_EOF
[Service]
Environment=\"KEYLIME_AGENT_UUID=\"$AGENT_ID\"\"
_EOF"
        rlRun "systemctl daemon-reload"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "rm -f /etc/systemd/system/keylime_agent.service.d/15-uuid.conf"
        rlRun "systemctl daemon-reload"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
