#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        rlFileBackup /etc/hosts
        limeBackupConfig
        if [ -d /var/log/keylime ]; then
            rlFileBackup --clean /var/log/keylime
        else
            rlRun "mkdir -p /var/log/keylime"
        fi
        rlServiceStart rsyslog
        systemctl status rsyslog
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
    rlPhaseEnd

    rlPhaseStartTest "Test logging to /var/log/messages"
        LINE_FROM=$( wc -l /var/log/messages | cut -d ' ' -f 1 )
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgent"
	rlRun "limeStopAgent"
	rlRun "limeStopRegistrar"
	rlRun "limeStopVerifier"
        sleep 1
        TMPFILE=$( mktemp )
        rlRun "sed -n '${LINE_FROM},\$ p' /var/log/messages > ${TMPFILE}"
        rlAssertGrep 'keylime_verifier.*Reading configuration from' ${TMPFILE} -E
        rlAssertGrep 'keylime_registrar.*Reading configuration from' ${TMPFILE} -E
        if limeIsPythonAgent; then
            rlAssertGrep 'keylime_agent.*Reading configuration from' ${TMPFILE} -E
        else
            rlAssertGrep 'keylime_agent.*Starting server with API version' ${TMPFILE} -E
        fi
        cat ${TMPFILE} | grep -v swtpm
        rlRun "rm -f ${TMPFILE}"
    rlPhaseEnd

    rlPhaseStartTest "Test logging to /var/log/keylime/ directory through rsyslog"
        rlRun "rm -f /var/log/keylime/*"
        #rlRun "chcon -t var_log_t /var/log/keylime"
	rlRun "chown root:root /var/log/keylime && chmod 700 /var/log/keylime"
        rlRun 'cat > /etc/rsyslog.d/10-keylime_logfile.conf <<_EOF
if (\$syslogtag contains "keylime_agent") then { Action (type="omfile" File="/var/log/keylime/agent.log") stop }
if (\$syslogtag contains "keylime_verifier") then { Action (type="omfile" File="/var/log/keylime/verifier.log") stop }
if (\$syslogtag contains "keylime_registrar") then { Action (type="omfile" File="/var/log/keylime/registrar.log") stop }
_EOF'
        rlRun "systemctl restart rsyslog"
        sleep 1
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgent"
	rlRun "limeStopAgent"
	rlRun "limeStopRegistrar"
	rlRun "limeStopVerifier"
        sleep 1
        rlAssertGrep 'keylime_verifier.*Reading configuration from' /var/log/keylime/verifier.log -E
	cat /var/log/keylime/verifier.log
        rlAssertGrep 'keylime_registrar.*Reading configuration from' /var/log/keylime/registrar.log -E
	cat /var/log/keylime/registrar.log
        if limeIsPythonAgent; then
            rlAssertGrep 'keylime_agent.*Reading configuration from' /var/log/keylime/agent.log -E
        else
            rlAssertGrep 'INFO  keylime_agent.*Starting server with API version' /var/log/keylime/agent.log -E
        fi
	cat /var/log/keylime/agent.log
        # cleanup
        rlRun "rm -f /etc/rsyslog.d/10-keylime_logfile.conf"
        rlRun "systemctl restart rsyslog"
    rlPhaseEnd

    rlPhaseStartTest "Test logging to /var/log/keylime/ directory through systemd"
        rlRun "rm -f /var/log/keylime/*"
        rlRun "chcon -t var_log_t /var/log/keylime"
        rlRun "chown keylime:keylime /var/log/keylime && chmod 700 /var/log/keylime"
        for SERVICE in verifier registrar agent; do
            rlRun "mkdir -p /etc/systemd/system/keylime_${SERVICE}.service.d"
            rlRun "cat > /etc/systemd/system/keylime_${SERVICE}.service.d/20-keylime_logfile.conf <<_EOF
[Service]
StandardOutput=append:/var/log/keylime/${SERVICE}.log
StandardError=inherit
[Journal]
ForwardToSyslog=no
_EOF"
        done
        rlRun "systemctl daemon-reload"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgent"
	rlRun "limeStopAgent"
	rlRun "limeStopRegistrar"
	rlRun "limeStopVerifier"
        sleep 1
        rlAssertGrep 'keylime.verifier - INFO' /var/log/keylime/verifier.log -E
	cat /var/log/keylime/verifier.log
        rlAssertGrep 'keylime.registrar - INFO' /var/log/keylime/registrar.log -E
	cat /var/log/keylime/registrar.log
        if limeIsPythonAgent; then
            rlAssertGrep 'keylime.cloudagent - INFO' /var/log/keylime/agent.log -E
        else
            rlAssertGrep 'INFO  keylime_agent' /var/log/keylime/agent.log -E
        fi
	cat /var/log/keylime/agent.log
        # cleanup
        for SERVICE in verifier registrar agent; do
            rlRun "rm -f /etc/systemd/system/keylime_${SERVICE}.service.d/20-keylime_logfile.conf"
        done
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rlPhaseStartCleanup
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        rlRun "rm -rf /var/log/keylime"
        rlFileRestore
        limeRestoreConfig
        rlServiceRestore rsyslog
    rlPhaseEnd

rlJournalEnd
