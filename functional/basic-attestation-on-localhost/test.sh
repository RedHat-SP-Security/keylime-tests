#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent
HTTP_SERVER_PORT=8080
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\",\"webhook\"]'"
        rlRun "limeUpdateConf revocations webhook_url http://localhost:${HTTP_SERVER_PORT}"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        fi
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf agent enable_revocation_notifications false"
        fi
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
	rlRun "systemctl status network.target"
	rlRun "cat > /etc/systemd/system/keylime_verifier.service <<_EOF
[Unit]
Description=The Keylime verifier
After=network.target
Before=keylime_registrar.service
StartLimitInterval=10s
StartLimitBurst=5

[Service]
Group=keylime
User=keylime
ExecStart=/usr/bin/strace -f --timestamps=time -o /var/tmp/strace.log /usr/bin/keylime_verifier
Restart=on-failure
TimeoutSec=60s
RestartSec=120s

[Install]
WantedBy=default.target
_EOF"
        rlRun "systemctl daemon-reload"
        # start keylime_verifier
	rlFileBackup /var/lib/keylime
          rlRun "limeStartVerifier"
          rlRun "limeWaitForVerifier"
	  rlRun "journalctl -u keylime_verifier"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
	rlFileSubmit /var/tmp/strace.log
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        #rlRun "rm -f $TESTDIR/*"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
