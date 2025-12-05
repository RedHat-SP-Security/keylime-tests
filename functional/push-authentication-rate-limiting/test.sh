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
        rlRun "limeUpdateConf agent tls_accept_invalid_certs true"
        rlRun "limeUpdateConf agent tls_accept_invalid_hostnames false"
        rlRun "limeUpdateConf verifier extend_token_on_attestation true"

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

        # Start services with low rate limits for testing
        # Configure low rate limits to trigger quickly in tests
        # Agent-based: 3 requests per 10 seconds
        # IP-based: 5 requests per 10 seconds
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_agent 3"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_agent 10"
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_ip 5"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_ip 10"

        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
    rlPhaseEnd

    rlPhaseStartTest "Test agent-based rate limiting"
        rlLog "Testing agent-based rate limiting (max 3 requests per 10 seconds)"

        # Make 3 requests - should all succeed
        for i in 1 2 3; do
            RESPONSE=$(curl -s -k -w "\n%{http_code}" -X POST https://localhost:8881/v3.0/sessions \
                -H "Content-Type: application/vnd.api+json" \
                -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")
            HTTP_CODE=$(echo "$RESPONSE" | tail -1)
            if [ "$HTTP_CODE" = "200" ]; then
                rlPass "Request $i: Got 200 OK (within rate limit)"
            else
                rlFail "Request $i: Got $HTTP_CODE instead of 200 (should be within rate limit)"
            fi
        done

        # 4th request should be rate limited
        RESPONSE=$(curl -s -k -i -X POST https://localhost:8881/v3.0/sessions \
            -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")
        HTTP_CODE=$(echo "$RESPONSE" | head -1 | grep -oP 'HTTP/[\d.]+ \K\d+')

        if [ "$HTTP_CODE" = "429" ]; then
            rlPass "Request 4: Got 429 Too Many Requests (rate limit working)"

            # Verify Retry-After header is present
            RETRY_AFTER=$(echo "$RESPONSE" | grep -i "^Retry-After:" | awk '{print $2}' | tr -d '\r')
            if [ -n "$RETRY_AFTER" ]; then
                rlPass "Response includes Retry-After header: $RETRY_AFTER seconds"
            else
                rlFail "Response missing Retry-After header"
            fi
        else
            rlFail "Request 4: Got $HTTP_CODE instead of 429 (rate limiting not working)"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Test IP-based rate limiting"
        rlLog "Testing IP-based rate limiting (max 5 requests per 10 seconds from same IP)"

        # Wait for agent rate limit to reset
        rlRun "sleep 11"

        # Make requests for different agents from same IP (localhost)
        # We already made 3 requests above (now expired), so make 5 more - all should succeed
        for i in 1 2 3 4 5; do
            TEST_AGENT_ID="test-agent-$(printf '%04d' $i)"
            RESPONSE=$(curl -s -k -w "\n%{http_code}" -X POST https://localhost:8881/v3.0/sessions \
                -H "Content-Type: application/vnd.api+json" \
                -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${TEST_AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")
            HTTP_CODE=$(echo "$RESPONSE" | tail -1)
            if [ "$HTTP_CODE" = "200" ]; then
                rlPass "IP limit test request $i (agent $TEST_AGENT_ID): Got 200 OK"
            else
                rlFail "IP limit test request $i (agent $TEST_AGENT_ID): Got $HTTP_CODE instead of 200"
            fi
        done

        # 6th request from same IP should be rate limited
        RESPONSE=$(curl -s -k -w "\n%{http_code}" -X POST https://localhost:8881/v3.0/sessions \
            -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"test-agent-0006\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -1)

        if [ "$HTTP_CODE" = "429" ]; then
            rlPass "IP limit test request 6: Got 429 Too Many Requests (IP-based rate limiting working)"
        else
            rlFail "IP limit test request 6: Got $HTTP_CODE instead of 429 (IP rate limiting not working)"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Test rate limit reset after block expires"
        rlLog "Testing that rate limits reset after block expiration"

        # The rate limiter uses exponential backoff, so we need to wait for the Retry-After time
        # First block is 60 seconds (60 * 2^0), not the window time (10 seconds)
        rlLog "Waiting for rate limit block to expire (60 seconds from exponential backoff)"
        rlRun "sleep 61"

        RESPONSE=$(curl -s -k -w "\n%{http_code}" -X POST https://localhost:8881/v3.0/sessions \
            -H "Content-Type: application/vnd.api+json" \
            -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -1)

        if [ "$HTTP_CODE" = "200" ]; then
            rlPass "Rate limit reset after block expired - request succeeded"
        else
            rlFail "Rate limit did not reset - got $HTTP_CODE instead of 200"
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        # Stop services
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
