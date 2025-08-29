#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

SECURE_DIR="/var/lib/keylime/secure"
KEYLIME_UNIT_FILE="/etc/systemd/system/keylime_agent.service"
if [ ! -f  "$KEYLIME_UNIT_FILE" ]; then
    KEYLIME_UNIT_FILE="/usr/lib/systemd/system/keylime_agent.service"
fi

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        rlFileBackup $KEYLIME_UNIT_FILE
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
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
    rlPhaseEnd

    rlPhaseStartTest "Verify that agent creates mount point when not present and mounts tmpfs."
        findmnt -M $SECURE_DIR && rlRun "umount $SECURE_DIR"
        rlRun "rm -rf $SECURE_DIR"
        sed -i '/var-lib-keylime-secure.mount/d' $KEYLIME_UNIT_FILE
        rlRun "systemctl daemon-reload"
        rlRun "limeStartAgent"
        sleep 3
        rlAssertGrep "INFO  keylime_agent::secure_mount > Directory \"$SECURE_DIR\" created" $(limeAgentLogfile)
        #verify that the mount point has been created and tmpfs mounted
        rlRun "findmnt -M \"$SECURE_DIR\" -t tmpfs"
        rlRun "limeStopAgent"
        rlRun "umount $SECURE_DIR"
    rlPhaseEnd

    rlPhaseStartTest "Manual mount dir with wrong fs, agent fail"
        rlRun "mount -t ramfs -o size=1m,mode=0700 ramfs $SECURE_DIR"
        rlRun "limeStartAgent"
        rlAssertGrep "ERROR keylime_agent::secure_mount > Secure mount error: Secure storage location $SECURE_DIR already mounted on wrong file system type:" $(limeAgentLogfile)
        rlRun "limeStopAgent"
        rlRun "umount $SECURE_DIR"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlFileRestore
        rlRun "systemctl daemon-reload"
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
