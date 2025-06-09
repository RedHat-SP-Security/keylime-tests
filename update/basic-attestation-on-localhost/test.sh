#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

REVOCATION_NOTIFIER=agent
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

[ -z "${PHASES}" ] && PHASES=all

    rlPhaseStartSetup "Import test library"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
    rlPhaseEnd


# setup phase
if echo ${PHASES} | grep -E -qi '(setup|all)'; then

    rlPhaseStartSetup "Do the keylime setup"

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\"]'"
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
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create some script
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho This is good-script1' > $TESTDIR/good-script1.sh && chmod a+x $TESTDIR/good-script1.sh"
        # create test policy
        rlRun "limeCreateTestPolicy ${TESTDIR}/*"
    rlPhaseEnd

    rlPhaseStartSetup "Add keylime agent"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --file /etc/hostname -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E

        # submit logs if we won't do it during the test or cleanup phase
	echo ${PHASES} | grep -E -qi '(cleanup|test)' || limeSubmitCommonLogs

    rlPhaseEnd

fi

# test phase
if echo ${PHASES} | grep -E -qi '(test|all)'; then

    rlPhaseStartTest "Running allowed scripts should not affect attestation"
        # Ensure keylime services are running
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
	sleep 5
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        limeSubmitCommonLogs
    rlPhaseEnd

fi

# cleanup phase
if echo ${PHASES} | grep -E -qi '(cleanup|all)'; then

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
        limeExtendNextExcludelist $TESTDIR
        #rlRun "rm -f $TESTDIR/*"  # possible but not really necessary
    rlPhaseEnd

fi

rlJournalEnd
