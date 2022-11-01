#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1


rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        #rlAssertRpm keylime

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
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # configure db for verifier using database_url
        rlRun "limeUpdateConf verifier database_url postgresql://verifier:fire@127.0.0.1/verifierdb"
        # configure db for registrar using other database_* options
        rlRun "limeUpdateConf registrar database_url postgresql://registrar:regi@127.0.0.1/registrardb"
    rlPhaseEnd

    rlPhaseStartTest "Test service start with updated configuration"
        # start keylime services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun -s "sudo -u postgres psql -c 'SELECT datname FROM pg_database;'"
        rlAssertGrep "verifierdb" $rlRun_LOG
        rlAssertGrep "registrardb" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test adding keylime agent"
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f /etc/hostname -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # stop services
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlServiceStop postgresql
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        limeSubmitCommonLogs
        # restore files and services
        limeClearData
        limeRestoreConfig
        rlFileRestore
        rlServiceRestore postgresql
    rlPhaseEnd

rlJournalEnd
