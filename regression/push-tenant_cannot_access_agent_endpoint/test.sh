#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
VERIFIER_PORT=8881
CERTDIR="/var/lib/keylime/cv_ca"

rlJournalStart

    rlPhaseStartSetup "Setup Keylime in push mode"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # Backup and configure keylime
        limeBackupConfig
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # Configure push mode for verifier
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        rlRun "limeUpdateConf verifier quote_interval 30"
        rlRun "limeUpdateConf agent attestation_interval_seconds 30"
        # Start TPM emulator if present
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        # Start Keylime services in push mode
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Tenant CANNOT access agent-only attestation endpoint"
        # The agent-only endpoint is POST /agents/:agent_id/attestations
        # This is where agents submit their attestations in push mode
        # Tenant certificate should be rejected when trying to access this
        # Try to submit attestation using tenant certificates
        # Use -k to bypass SSL validation and test actual authorization rejection
        rlRun -s "curl -k --cert ${CERTDIR}/client-cert.crt \
                       --key ${CERTDIR}/client-private.pem \
                       --cacert ${CERTDIR}/cacert.crt \
                       -X POST https://127.0.0.1:${VERIFIER_PORT}/v3/agents/${AGENT_ID}/attestations \
                       -H 'Content-Type: application/json' \
                       -d '{
                             \"quote\": \"fake_quote_data\",
                             \"hash_alg\": \"sha256\",
                             \"enc_alg\": \"rsa\",
                             \"sign_alg\": \"rsassa\"
                           }'" 0
        # Tenant certificate should be rejected 403 Forbidden
        rlAssertGrep "403.*Forbidden.*Action submit_attestation requires agent authentication (PoP token)" $rlRun_LOG 
        rlLog "Verified: Tenant cannot access agent attestation endpoint"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup Keylime"
        rlRun "limeStopPushAgent"
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