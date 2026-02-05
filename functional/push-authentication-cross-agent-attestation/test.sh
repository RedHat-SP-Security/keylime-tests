#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test: Verify one agent cannot send attestations on behalf of another agent
# Threat model: Malicious Agent B uses its OWN token to attack Agent A's endpoint
# Expected: Verifier rejects because Token B is for Agent B, not Agent A

AGENT_A_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00001"
AGENT_B_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00002"

rlJournalStart

    rlPhaseStartSetup "Initial environment setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Resolve path to custom-agent directory BEFORE changing to temp directory
        SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
        CUSTOM_AGENT_DIR="${SCRIPT_DIR}/custom-agent"

        # Compile custom agent helper tools for token acquisition
        # These tools use TPM proof-of-possession to get authentication tokens
        rlRun "pushd $CUSTOM_AGENT_DIR"
        rlRun "make clean" 0 "Clean previous custom agent builds"
        rlRun "make" 0 "Compile custom agent TPM certify helper"
        rlRun "make test" 0 "Test custom agent TPM certify helper"
        rlRun "test -x tpm_certify_simple" 0 "Verify TPM helper is executable"
        rlRun "test -x setup_test_agent.sh" 0 "Verify agent setup script is executable"
        rlRun "popd"

        # Create temporary directory
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"

        limeBackupConfig

        # Enable DEBUG logging
        limeEnableDebugLog

        # Configure verifier for push mode with authentication
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        rlRun "limeUpdateConf verifier session_lifetime 600"
        rlRun "limeUpdateConf agent enable_authentication true"
        rlRun "limeUpdateConf agent tls_accept_invalid_certs true"
        rlRun "limeUpdateConf agent tls_accept_invalid_hostnames true"
        rlRun "limeUpdateConf verifier extend_token_on_attestation true"
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Configure authentication rate limits
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_agent 15"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_agent 60"
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_ip 50"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_ip 60"

        # Start TPM emulator
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        rlServiceStart tpm2-abrmd
        sleep 5

        # Install IMA config and emulator
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"

        rlRun "limeSyncIMAExcludelist"

        # Start keylime services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Define URLs for custom agent setup
        VERIFIER_URL="https://127.0.0.1:8881"
        REGISTRAR_URL="https://127.0.0.1:8891"
    rlPhaseEnd

    rlPhaseStartSetup "Setup Agent A (victim)"
        # Configure and start Agent A
        rlRun "limeUpdateConf agent uuid '\"${AGENT_A_ID}\"'"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_A_ID}"

        # Create policy and enroll Agent A
        rlRun "limeCreateTestPolicy"
        rlRun "keylime_tenant -v 127.0.0.1 -u $AGENT_A_ID --runtime-policy policy.json -c add --push-model"

        # Wait for Agent A to authenticate
        rlRun "rlWaitForCmd 'grep -q \"authorization: \\\"Bearer\" \$(limePushAgentLogfile)' -m 60 -d 1" \
            0 "Agent A authenticated"

        # Stop Agent A - it's now enrolled, we just need it as a target
        rlRun "limeStopPushAgent"
    rlPhaseEnd

    rlPhaseStartSetup "Setup Agent B (attacker) with new TPM identity"
        # Restart TPM emulator to create fresh TPM identity for Agent B
        rlRun "limeStopTPMEmulator"
        rlServiceStop tpm2-abrmd
        sleep 3
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        rlServiceStart tpm2-abrmd
        sleep 5

        # Copy policy.json from Agent A to custom-agent directory
        # (setup_test_agent.sh looks for policy.json in its own directory)
        rlRun "cp policy.json ${CUSTOM_AGENT_DIR}/policy.json" 0 "Copy policy.json to custom-agent directory"

        # Use custom agent setup script to register Agent B and get authentication token
        # This simulates an attacker having access to their own agent's token
        # (attacker controls Agent B, so having its token is expected)
        # The script will:
        # 1. Register EK/AK with registrar using persistent handles
        # 2. Activate credential
        # 3. Enroll with verifier using policy.json (from Agent A)
        # 4. Authenticate via TPM proof-of-possession and get token
        rlLog "Setting up Agent B and obtaining authentication token via TPM proof-of-possession"
        rlRun "AGENT_B_TOKEN=\$(${CUSTOM_AGENT_DIR}/setup_test_agent.sh \"${AGENT_B_ID}\" \"${REGISTRAR_URL}\" \"${VERIFIER_URL}\" \"${TmpDir}\" --get-token)" 0 "Setup Agent B and get authentication token"

        rlLog "Agent B token captured (truncated): ${AGENT_B_TOKEN:0:20}..."
        rlRun "test -n \"$AGENT_B_TOKEN\"" 0 "Verify Agent B token was captured"
    rlPhaseEnd

    rlPhaseStartTest "Test cross-agent attestation is rejected"
        rlLog "=== ATTACK SCENARIO ==="
        rlLog "Agent B (attacker) attempts to submit attestation for Agent A (victim)"
        rlLog "Using Agent B's own valid token to attack Agent A's endpoint"

        # Create a valid attestation request payload that would be accepted if authorization is bypassed
        # This includes proper evidence_supported structure with TPM quote capabilities
        # Write payload to a file to avoid shell escaping issues
        # Use a recent boot time (1 minute ago) to simulate a fresh boot
        RECENT_BOOT_TIME=$(date -u -d "1 minute ago" +"%Y-%m-%dT%H:%M:%SZ")

        cat > attestation_payload.json << PAYLOAD_EOF
{
    "data": {
        "type": "attestation",
        "attributes": {
            "evidence_supported": [
                {
                    "evidence_class": "certification",
                    "evidence_type": "tpm_quote",
                    "capabilities": {
                        "component_version": "2.0",
                        "signature_schemes": ["rsassa"],
                        "hash_algorithms": ["sha256"],
                        "available_subjects": {
                            "sha256": [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
                        },
                        "certification_keys": [
                            {
                                "key_class": "asymmetric",
                                "key_algorithm": "rsa",
                                "key_size": 2048,
                                "server_identifier": "ak"
                            }
                        ]
                    }
                },
                {
                    "evidence_class": "log",
                    "evidence_type": "ima_log",
                    "capabilities": {
                        "supports_partial_access": true,
                        "appendable": true,
                        "entry_count": 1000,
                        "formats": ["text/plain"]
                    }
                }
            ],
            "system_info": {
                "boot_time": "${RECENT_BOOT_TIME}"
            }
        }
    }
}
PAYLOAD_EOF
        rlLog "Attestation payload:"
        cat attestation_payload.json

        # Agent B tries to create attestation for Agent A using Agent B's token
        HTTP_CODE=$(curl -s -k -o response.json -w "%{http_code}" \
            -X POST "https://localhost:8881/v3.0/agents/${AGENT_A_ID}/attestations" \
            -H "Content-Type: application/vnd.api+json" \
            -H "Authorization: Bearer ${AGENT_B_TOKEN}" \
            -d @attestation_payload.json)

        rlLog "HTTP Response Code: $HTTP_CODE"
        rlRun "cat response.json" 0 "Show response body"

        # The request SHOULD be rejected because Agent B's token cannot be used for Agent A
        # Expected: 401 (Unauthorized) or 403 (Forbidden)
        if [ "$HTTP_CODE" == "401" ] || [ "$HTTP_CODE" == "403" ]; then
            rlPass "Cross-agent attestation correctly REJECTED with HTTP $HTTP_CODE"
        elif [ "$HTTP_CODE" == "200" ] || [ "$HTTP_CODE" == "201" ] || [ "$HTTP_CODE" == "202" ]; then
            rlFail "CRITICAL SECURITY ISSUE: Cross-agent attestation was ACCEPTED (HTTP $HTTP_CODE)"
            rlLog "Agent B successfully created an attestation for Agent A!"
            rlLog "This means the authorization check is missing or bypassed."
        else
            rlFail "SECURITY ISSUE: Cross-agent attestation was not properly rejected (got HTTP $HTTP_CODE)"
            rlLog "Expected HTTP 401 or 403, but got $HTTP_CODE"
            rlLog "The request may have bypassed authorization and failed on a later validation step."
        fi

    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        rlRun "limeStopPushAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "limeStopIMAEmulator"
        rlRun "limeStopTPMEmulator"
        rlServiceRestore tpm2-abrmd

        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig

        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalEnd
