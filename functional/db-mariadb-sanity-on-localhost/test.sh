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
            # workaround for https://github.com/keylime/rust-keylime/pull/286
            export PATH=/usr/bin:$PATH
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        else
            rlServiceStart tpm2-abrmd
        fi

        # backup and configure mariadb
        rlServiceStop mariadb
        rlFileBackup --clean --missing-ok /var/lib/mysql
        rlRun "rm -rf /var/lib/mysql/*"
        rlServiceStart mariadb
        sleep 3
        rlRun "cat setup.sql | mysql -u root"
        # configure keylime
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # configure db for verifier using database_* options
        rlRun "limeUpdateConf cloud_verifier database_url ''"  # this must be empty
        rlRun "limeUpdateConf cloud_verifier database_drivername mysql"
        rlRun "limeUpdateConf cloud_verifier database_username verifier"
        rlRun "limeUpdateConf cloud_verifier database_password fire"
        rlRun "limeUpdateConf cloud_verifier database_host 127.0.0.1"
        rlRun "limeUpdateConf cloud_verifier database_name verifierdb"
        # configure db for registrar using database_url
        rlRun "limeUpdateConf registrar database_url mysql://registrar:regi@127.0.0.1/registrardb"
    rlPhaseEnd

    rlPhaseStartTest "Test service start with updated configuration"
        # start keylime services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
	rlRun -s "echo 'show databases;' | mysql -u root"
	rlAssertGrep "verifierdb" $rlRun_LOG
	rlAssertGrep "registrardb" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Test adding keylime tenant"
        rlRun "limeStartAgent"
        sleep 5
        # create allowlist and excludelist
        limeCreateTestLists
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlRun "lime_keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f /etc/hostname -c add"
        rlRun "limeWaitForTenantStatus $AGENT_ID 'Get Quote'"
        rlRun -s "lime_keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # stop services
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlServiceStop mariadb
        # submit log files
        rlFileSubmit $(limeVerifierLogfile)
        rlFileSubmit $(limeRegistrarLogfile)
        rlFileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlFileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
        fi
        # restore files and services
        rlServiceRestore tpm2-abrmd
        limeClearData
        limeRestoreConfig
        rlFileRestore
        rlServiceRestore mariadb
    rlPhaseEnd

rlJournalEnd
