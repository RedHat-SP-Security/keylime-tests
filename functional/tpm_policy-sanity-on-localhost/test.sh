#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        limeBackupConfig
        rlAssertRpm keylime
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
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        # configure TPM policy with PCR bank 23
        TPM_POLICY='{\"23\":[\"0000000000000000000000000000000000000000000000000000000000000000\"]}'
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --tpm_policy ${TPM_POLICY} --runtime-policy policy.json -f /etc/hostname -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "DATAFILE=\$( mktemp )"
        rlRun "echo 'foo' > ${DATAFILE}"
        rlRun "tpm2_pcrevent 23 ${DATAFILE}"
        rlRun -s "tpm2_pcrread sha256:23"
        rlAssertNotGrep "0000" $rlRun_LOG
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
	rlAssertGrep "keylime.tpm - ERROR - PCR #23: .* from quote.* does not match expected value" $(limeVerifierLogfile) -E
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
    rlPhaseEnd

    rlPhaseStartTest "Run keylime_tenant -c update, providing updated tpm_policy"
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        # prepare new policy with current PCR values
        SHA256=$( tpm2_pcrread sha256:23 | tail -1 | cut -d 'x' -f 2 )
        TPM_POLICY="{\"23\":[\"${SHA256}\"]}"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -f /etc/hostname --tpm_policy '${TPM_POLICY}' -c update"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
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
