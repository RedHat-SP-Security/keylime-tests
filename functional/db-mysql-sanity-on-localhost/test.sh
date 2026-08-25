#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
MYSQL_VER=""

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        #rlAssertRpm keylime

        rlIsRHELLike 10 && MYSQL_VER=8.4
        rpm -q mysql${MYSQL_VER}-server && rlServiceStop mysqld
        rpm -q mariadb-server && rlServiceStop mariadb

        # backup and configure mysql/mariadb
        rlFileBackup --clean --missing-ok /var/lib/mysql
        rlRun "rm -rf /var/lib/mysql/*"

        # check if mariadb is installed and replace it with mysql-server
        PKGS=$( rpm -qa | grep 'mariadb' | xargs echo )
        if [ -n "$PKGS" ]; then
            rlRun "yum -y remove $PKGS"
        fi
        rlRun "yum -y install mysql${MYSQL_VER}-server"

        rlServiceStart mysqld
        sleep 3
        rlRun "cat setup.sql | mysql -u root"

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

        # configure keylime
        limeBackupConfig
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # configure db for verifier using database_* options
        rlRun "limeUpdateConf verifier database_url mysql+pymysql://verifier:fire@127.0.0.1/verifierdb"
        # configure db for registrar using database_url
        rlRun "limeUpdateConf registrar database_url mysql+pymysql://registrar:regi@127.0.0.1/registrardb"
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

    rlPhaseStartTest "Test adding keylime agent"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
        rlRun "limeCtl --verifier-ip 127.0.0.1 agent add $AGENT_ID --ip 127.0.0.1 --runtime-policy policy.json"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        rlRun -s "limeCtl agent list"
        rlRun "limeAssertJsonField $rlRun_LOG code=200 status=Success uuids=$AGENT_ID"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # stop services
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlServiceStop mysqld
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs

        # check if mariadb was installed and reinstall it
        if [ -n "$PKGS" ]; then
            rlRun "yum -y remove mysql${MYSQL_VER}-server"
            rlRun "yum -y install $PKGS"
            rlRun "rpm -q $PKGS"
        fi

        # restore files and services
        limeClearData
        limeRestoreConfig
        rlFileRestore
        rpm -q mysql${MYSQL_VER}-server && rlServiceRestore mysqld
        rpm -q mariadb-server && rlServiceRestore mariadb
    rlPhaseEnd

rlJournalEnd
