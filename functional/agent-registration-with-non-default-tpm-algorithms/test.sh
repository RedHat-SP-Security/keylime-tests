#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# these 2 variables should be set from the outside
#TPM_ENCRYPTION_ALG=ecc
#TPM_SIGNING_ALG=ecschnorr
SKIP_ATTESTATION="${SKIP_ATTESTATION:-}"

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        [ -n "${TPM_ENCRYPTION_ALG}" ] || rlDie "TPM_ENCRYPTION_ALG variable is not set"
        [ -n "${TPM_SIGNING_ALG}" ] || rlDie "TPM_SIGNING_ALG variable is not set"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant accept_tpm_encryption_algs [\\'${TPM_ENCRYPTION_ALG}\\']"
        rlRun "limeUpdateConf tenant accept_tpm_signing_algs [\\'${TPM_SIGNING_ALG}\\']"
        # agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        rlRun "limeUpdateConf agent tpm_encryption_alg \\\"${TPM_ENCRYPTION_ALG}\\\""
        rlRun "limeUpdateConf agent tpm_signing_alg \\\"${TPM_SIGNING_ALG}\\\""
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
    rlPhaseEnd

    rlPhaseStartTest "Register keylime agent"
        rlRun "rm -f /var/lib/keylime/agent_data.json"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Attestation by the verifier"
        if [ -n "${SKIP_ATTESTATION}" ]; then
            rlLogInfo "Skipping attestation for combination of alg/sig (${TPM_ENCRYPTION_ALG} / ${TPM_SIGNING_ALG})"
        else
            rlRun "limeCreateTestPolicy"
            rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add"
            rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlAssertNotGrep "Traceback" "$(limeRegistrarLogfile)"
        rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"
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
