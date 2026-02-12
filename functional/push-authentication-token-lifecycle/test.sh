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

    rlPhaseStartTest "Test token extension on successful attestations"
        rlLog "Testing that successful attestations extend token lifetime (no re-authentication needed)"

        # Stop services to reconfigure
        rlRun "limeStopPushAgent"
        rlRun "limeStopVerifier"

        # Set moderate session lifetime (60 seconds) and attestation interval (5 seconds)
        # Use 60 seconds to allow time for verifier restart without token expiring
        # With frequent attestations, the token should be extended each time
        rlRun "limeUpdateConf verifier session_lifetime 60"
        rlRun "limeUpdateConf agent attestation_interval_seconds 5"
        rlRun "limeUpdateConf verifier extend_token_on_attestation true"

        # Restart services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Wait for agent to authenticate and start using token
        rlRun "rlWaitForCmd 'grep -q \"authorization: \\\"Bearer\" \$(limePushAgentLogfile)' -m 30 -d 1" \
            0 "Waiting for agent to use authentication token"

        # Wait a bit to let agent do some attestations with the new token
        rlRun "sleep 5"

        # NOW capture the token (after agent has settled into steady state)
        INITIAL_TOKEN=$(limePushAuthGetToken)
        rlLog "Initial token: $INITIAL_TOKEN"

        # Mark the log position for checking re-authentication later
        AGENT_LOG=$(limePushAgentLogfile)
        LOG_MARK=$(wc -l < "$AGENT_LOG")

        # Restart ONLY the verifier (not the agent) to test token persistence
        rlLog "Restarting verifier to test if token persists from database..."
        rlRun "limeStopVerifier"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"

        # Wait for token to be used after restart (should persist from database)
        # With token extension enabled, attestations should keep extending the token
        # so NO re-authentication should occur even after verifier restart
        rlLog "Waiting for attestations to resume after verifier restart..."
        rlRun "sleep 15"

        # Verify NO re-authentication happened (no 401 received)
        if tail -n +$LOG_MARK "$(limePushAgentLogfile)" | grep -q "Received 401"; then
            rlFail "Token expired and re-authentication occurred - optimization not working"
        else
            rlPass "No re-authentication occurred - token was extended by successful attestations"
        fi

        # Get the current token being used
        CURRENT_TOKEN=$(limePushAuthGetToken)
        rlLog "Current token: $CURRENT_TOKEN"

        # Verify token is still the same (not replaced)
        if [ "$INITIAL_TOKEN" = "$CURRENT_TOKEN" ] && [ -n "$INITIAL_TOKEN" ]; then
            rlPass "Token remained the same ('$INITIAL_TOKEN') - successfully extended without re-authentication"
        else
            rlFail "Token changed from '$INITIAL_TOKEN' to '$CURRENT_TOKEN' - unexpected re-authentication"
        fi

        # Verify we see token extension messages in verifier log
        rlRun "grep -q 'Extended auth token for agent.*${AGENT_ID}' \$(limeVerifierLogfile)" \
            0 "Verifier log shows token extensions"

        # Restore config
        rlRun "limeStopPushAgent"
        rlRun "limeStopVerifier"
        rlRun "limeUpdateConf verifier session_lifetime 180"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Test automatic token re-authentication"
        rlLog "Testing that agent automatically re-authenticates when token expires"

        # Stop services to reconfigure
        rlRun "limeStopPushAgent"
        rlRun "limeStopVerifier"

        # Set very short session lifetime (15 seconds) and attestation interval (5 seconds)
        # Disable token extension so the token actually expires
        rlRun "limeUpdateConf verifier session_lifetime 15"
        rlRun "limeUpdateConf verifier extend_token_on_attestation False"
        rlRun "limeUpdateConf agent attestation_interval_seconds 5"

        # Restart services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Wait for agent to be using its authentication token
        rlRun "rlWaitForCmd 'grep -q \"authorization: \\\"Bearer\" \$(limePushAgentLogfile)' -m 30 -d 1" \
            0 "Waiting for agent to use authentication token"

        # Capture the current token being used
        INITIAL_TOKEN=$(limePushAuthGetToken)
        rlLog "Initial token: $INITIAL_TOKEN"

        # Mark the log position for checking re-authentication later
        AGENT_LOG=$(limePushAgentLogfile)
        LOG_MARK=$(wc -l < "$AGENT_LOG")

        # Wait for token to expire (15 seconds + some buffer)
        rlRun "sleep 18"

        # Verify re-authentication happened
        rlRun "rlWaitForCmd 'tail -n +$LOG_MARK \$(limePushAgentLogfile) | grep -q \"Received 401\"' -m 30 -d 1" \
            0 "Token expiration detected (401 from verifier) and re-authentication triggered"

        # Get the new token being used after re-authentication
        NEW_TOKEN=$(limePushAuthGetToken)
        rlLog "New token after re-auth: $NEW_TOKEN"

        # Verify token changed
        if [ "$INITIAL_TOKEN" != "$NEW_TOKEN" ] && [ -n "$INITIAL_TOKEN" ] && [ -n "$NEW_TOKEN" ]; then
            rlPass "Authentication token changed from '$INITIAL_TOKEN' to '$NEW_TOKEN' - re-authentication successful"
        else
            rlFail "Authentication token did not change or was not captured (initial: '$INITIAL_TOKEN', new: '$NEW_TOKEN')"
        fi
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
