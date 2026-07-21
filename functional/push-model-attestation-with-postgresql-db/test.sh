#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
ATTESTATION_INTERVAL=30

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # backup and configure postgresql db
        rlServiceStop postgresql
        rlFileBackup --clean --missing-ok /var/lib/pgsql /etc/postgresql-setup
        rlRun "rm -rf /var/lib/pgsql/data"
        rlRun "postgresql-setup --initdb --unit postgresql"
        # configure user authentication with md5
        rlRun "sed -i '/host.*all.*all.*127.0.0.1.*ident/ s/ident/md5/' /var/lib/pgsql/data/pg_hba.conf"
        rlServiceStart postgresql
        sleep 3
        rlRun "sudo -u postgres psql -f setup.psql"

        # configure keylime
        limeBackupConfig
        # disable EK certificate verification on the tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # configure db for verifier and registrar
        rlRun "limeUpdateConf verifier database_url postgresql://verifier:fire@127.0.0.1/verifierdb"
        rlRun "limeUpdateConf registrar database_url postgresql://registrar:regi@127.0.0.1/registrardb"
        # configure push-model attestation
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        rlRun "limeUpdateConf verifier session_lifetime 180"
        rlRun "limeUpdateConf verifier quote_interval ${ATTESTATION_INTERVAL}"
        rlRun "limeUpdateConf agent attestation_interval_seconds ${ATTESTATION_INTERVAL}"
        rlRun "limeUpdateConf agent registrar_tls_enabled true"
        rlRun "limeUpdateConf agent enable_authentication true"

        # configure TPM emulator if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        sleep 5
    
        # Start keylime services with push support
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        
        rlRun -s "sudo -u postgres psql -c 'SELECT datname FROM pg_database;'"
        rlAssertGrep "verifierdb" $rlRun_LOG
        rlAssertGrep "registrardb" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Push attestation with PostgreSQL must succeed"

        # Enroll push-attestation agent
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlRun "limeCreateTestPolicy"
        
        # Wait for successful attestation
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add --push-model"
        rlRun "limeTIMEOUT=$((ATTESTATION_INTERVAL*6)) limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PASS'" 0 "Agent should pass attestation"
        
        # No column size error in PostgreSQL log (regression check for RHEL-189524)
        rlAssertNotGrep "StringDataRightTruncation" "$(limeVerifierLogfile)"

        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "$AGENT_ID" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopPushAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlServiceStop postgresql
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        rlFileRestore
        rlServiceRestore postgresql
    rlPhaseEnd

rlJournalEnd
