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
            export TPM2TOOLS_TCTI=tabrmd:bus_name=com.intel.tss2.Tabrmd
            export TCTI=tabrmd:
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        else
            rlServiceStart tpm2-abrmd
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
        rlRun "limeUpdateConf cloud_verifier database_url postgresql://verifier:fire@127.0.0.1/verifierdb"
        # configure db for registrar using other database_* options
        rlRun "limeUpdateConf registrar database_url ''"  # this must be empty so other options take effect
        rlRun "limeUpdateConf registrar database_drivername postgresql"
        rlRun "limeUpdateConf registrar database_username registrar"
        rlRun "limeUpdateConf registrar database_password regi"
        rlRun "limeUpdateConf registrar database_host 127.0.0.1"
        rlRun "limeUpdateConf registrar database_name registrardb"
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
        rlRun "lime_keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f /etc/hostname -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "lime_keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # stop services
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlServiceStop postgresql
        # submit log files
        limeLogfileSubmit $(limeVerifierLogfile)
        limeLogfileSubmit $(limeRegistrarLogfile)
        limeLogfileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
        fi
        # restore files and services
        rlServiceRestore tpm2-abrmd
        limeClearData
        limeRestoreConfig
        rlFileRestore
        rlServiceRestore postgresql
    rlPhaseEnd

rlJournalEnd
