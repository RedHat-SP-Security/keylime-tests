#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
            [ -f /etc/profile.d/limeLib_tcti.sh ] && source /etc/profile.d/limeLib_tcti.sh
        fi
        sleep 5
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
    rlPhaseEnd

    rlPhaseStartTest "Start keylime agent"
        rlRun -s "RUST_LOG=debug KEYLIME_AGENT_REGISTRAR_IP=1.2.3.4 timeout 5 keylime_agent" 0-255
        rlAssertGrep "DEBUG keylime_agent::config > Environment configuration registrar_ip=1.2.3.4" $rlRun_LOG
        rlAssertGrep "connecting to 1.2.3.4" $rlRun_LOG
        rlAssertNotGrep "connecting to 127.0.0.1" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeClearData
    rlPhaseEnd

rlJournalEnd
