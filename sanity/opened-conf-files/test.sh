#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
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
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration '${AGENT_ID}'"
        rlRun "limeCreateTestPolicy"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u '$AGENT_ID' --verify --runtime-policy policy.json --file /etc/hosts -c add"
        rlRun "cp '$rlRun_LOG' tenant.log"
        rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'"
    rlPhaseEnd

function check_for_opened_conf_files() {
    SERVICE_LOG=$1
    shift
    PRESENT=1  #PRESENT=0 means absent
    while [[ "$1" != "" ]]; do
        if [[ "$1" == "-e" ]]; then
            PRESENT=0
        elif [[ "$PRESENT" == "1" ]]; then
            rlAssertGrep "Reading configuration from.*/$1" "$SERVICE_LOG" -E
        else
            rlAssertNotGrep "Reading configuration from.*/$1" "$SERVICE_LOG" -E
        fi
	shift
    done
}

    rlPhaseStartTest "Check opened configuration files"
        # test tenant
	check_for_opened_conf_files tenant.log tenant.conf logging.conf -e verifier.conf registrar.conf ca.conf agent.conf
	check_for_opened_conf_files "$(limeVerifierLogfile)" verifier.conf ca.conf logging.conf -e tenant.conf registrar.conf agent.conf
	check_for_opened_conf_files "$(limeRegistrarLogfile)" registrar.conf logging.conf -e tenant.conf verifier.conf ca.conf agent.conf
	# not checking agent as it doesn't say which logs it opens
	# this should be functionally exercised by the multi-host test anyway
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
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
