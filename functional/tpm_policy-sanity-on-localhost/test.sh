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
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5
        # update /etc/keylime.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # configure TPM policy with PCR bank 23
        TPM_POLICY='{\"23\":[\"0000000000000000000000000000000000000000\",\"0000000000000000000000000000000000000000000000000000000000000000\"]}'
        rlRun "limeUpdateConf tenant tpm_policy '${TPM_POLICY}'"
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "lime_keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f /etc/hostname -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "lime_keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        rlRun "DATAFILE=\$( mktemp )"
        rlRun "echo 'foo' > ${DATAFILE}"
        rlRun "tpm2_pcrevent 23 ${DATAFILE}"
        rlRun -s "tpm2_pcrread sha1:23+sha256:23"
        rlAssertNotGrep "0000" $rlRun_LOG
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "keylime.tpm - ERROR - PCR #23: .* from quote does not match expected value" $(limeVerifierLogfile) -E
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
    rlPhaseEnd

    rlPhaseStartTest "Run keylime_tenant -c update, overriding tpm_policy from keylime.conf"
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        # prepare new policy with current PCR values
        SHA1=$( tpm2_pcrread sha1:23 | tail -1 | cut -d 'x' -f 2 )
        SHA256=$( tpm2_pcrread sha256:23 | tail -1 | cut -d 'x' -f 2 )
        TPM_POLICY="{\"23\":[\"${SHA1}\",\"${SHA256}\"]}"
        rlRun "lime_keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f /etc/hostname --tpm_policy '${TPM_POLICY}' -c update"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "lime_keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        limeLogfileSubmit $(limeVerifierLogfile)
        limeLogfileSubmit $(limeRegistrarLogfile)
        limeLogfileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
