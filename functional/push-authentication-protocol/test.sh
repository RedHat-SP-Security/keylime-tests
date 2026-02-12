#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart
    rlPhaseStartSetup "Setup push authentication environment"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Backup original configuration
        limeBackupConfig

        # The authentication tests rely on DEBUG-level logging.
        limeEnableDebugLog

        # Set the verifier to run in PUSH mode
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        rlRun "limeUpdateConf verifier session_lifetime 180"

        # Enable authentication
        rlRun "limeUpdateConf agent enable_authentication true"
        rlRun "limeUpdateConf verifier extend_token_on_attestation true"

        # Configure authentication rate limits
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_agent 15"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_agent 60"
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_ip 50"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_ip 60"

        # Disable EK certificate verification
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Configure TPM emulator if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        # Sync IMA log
        rlRun "limeSyncIMAExcludelist"

        # Start services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Start agent first so it can register with the registrar
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Enroll agent with verifier after it's registered
        rlRun "limeCreateTestPolicy"
        rlRun "keylime_tenant -v 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add --push-model"
    rlPhaseEnd

    rlPhaseStartTest "Validate POST /sessions response format"
        rlLog "Testing that POST /sessions response matches specification format"

        SESSION_RESPONSE=$(curl -s -k -X POST https://localhost:8881/v3.0/sessions \
            -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")

        # Validate POST response has required fields per spec
        echo "$SESSION_RESPONSE" | jq -e '.data.type == "session"' >/dev/null
        rlAssert0 "POST /sessions response has correct type" $?

        echo "$SESSION_RESPONSE" | jq -e '.data.id' >/dev/null
        rlAssert0 "POST /sessions response has session id" $?

        echo "$SESSION_RESPONSE" | jq -e '.data.attributes.agent_id' >/dev/null
        rlAssert0 "POST /sessions response has agent_id" $?

        echo "$SESSION_RESPONSE" | jq -e '.data.attributes.authentication_requested[0].authentication_type == "tpm_pop"' >/dev/null
        rlAssert0 "POST /sessions response has authentication_requested with tpm_pop" $?

        echo "$SESSION_RESPONSE" | jq -e '.data.attributes.authentication_requested[0].chosen_parameters.challenge' >/dev/null
        rlAssert0 "POST /sessions response has challenge" $?

        echo "$SESSION_RESPONSE" | jq -e '.data.attributes.created_at' >/dev/null
        rlAssert0 "POST /sessions response has created_at" $?

        echo "$SESSION_RESPONSE" | jq -e '.data.attributes.challenges_expire_at' >/dev/null
        rlAssert0 "POST /sessions response has challenges_expire_at" $?

        # Verify POST response does NOT have token (only on PATCH success)
        echo "$SESSION_RESPONSE" | jq -e '.data.attributes.token' >/dev/null 2>&1 && \
            rlFail "POST /sessions response should not have token" || \
            rlPass "POST /sessions response does not have token"
    rlPhaseEnd

    rlPhaseStartTest "Validate PATCH /sessions failure response format"
        rlLog "Testing that PATCH /sessions failure response matches specification format"

        # Create a session first
        FAIL_SESSION_RESPONSE=$(curl -s -k -X POST https://localhost:8881/v3.0/sessions \
            -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")

        FAIL_SESSION_ID=$(echo "$FAIL_SESSION_RESPONSE" | jq -r '.data.id')
        rlLog "Created session ID for failure test: $FAIL_SESSION_ID"

        # Submit invalid proof of possession (empty signatures)
        FAIL_PATCH_RESPONSE=$(curl -s -k -X PATCH "https://localhost:8881/v3.0/sessions/${FAIL_SESSION_ID}" \
            -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"session\",\"id\":\"${FAIL_SESSION_ID}\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_provided\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\",\"data\":{\"message\":\"\",\"signature\":\"\"}}]}}}")

        # Validate failure response has required fields per spec
        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.evaluation == "fail"' >/dev/null
        rlAssert0 "PATCH /sessions failure response has evaluation=fail" $?

        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.authentication[0].authentication_type == "tpm_pop"' >/dev/null
        rlAssert0 "PATCH /sessions failure response has authentication array" $?

        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.created_at' >/dev/null
        rlAssert0 "PATCH /sessions failure response has created_at" $?

        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.challenges_expire_at' >/dev/null
        rlAssert0 "PATCH /sessions failure response has challenges_expire_at" $?

        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.response_received_at' >/dev/null
        rlAssert0 "PATCH /sessions failure response has response_received_at" $?

        # Verify failure response does NOT have token or token_expires_at
        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.token' >/dev/null 2>&1 && \
            rlFail "PATCH /sessions failure response should not have token" || \
            rlPass "PATCH /sessions failure response does not have token"

        echo "$FAIL_PATCH_RESPONSE" | jq -e '.data.attributes.token_expires_at' >/dev/null 2>&1 && \
            rlFail "PATCH /sessions failure response should not have token_expires_at" || \
            rlPass "PATCH /sessions failure response does not have token_expires_at"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        # Stop services
        rlRun "limeStopPushAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"

        # Stop TPM emulator if used
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
