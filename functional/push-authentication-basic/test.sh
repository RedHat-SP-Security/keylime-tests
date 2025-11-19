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
        rlRun "limeUpdateConf agent tls_accept_invalid_hostnames true"
        rlRun "limeUpdateConf verifier extend_token_on_attestation true"

        # Configure authentication rate limits to handle retries and restarts
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_agent 15"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_agent 60"
        rlRun "limeUpdateConf verifier session_create_rate_limit_per_ip 50"
        rlRun "limeUpdateConf verifier session_create_rate_limit_window_ip 60"

        # Disable EK certificate verification on the tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Configure TPM emulator if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        # Sync IMA log with exclude list to handle leftover measurements from previous runs
        rlRun "limeSyncIMAExcludelist"

        # Start keylime services with push support
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
    rlPhaseEnd

    rlPhaseStartTest "Test authentication fails for unenrolled agent"
        rlLog "Testing that unenrolled agents cannot authenticate"

        # Start push-attestation agent WITHOUT enrolling it first
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Wait a bit for agent to attempt authentication
        rlRun "sleep 5"

        # Agent should NOT have a Bearer token since it's not enrolled
        if grep -q "authorization: \"Bearer" "$(limePushAgentLogfile)"; then
            rlFail "Unenrolled agent should not receive authentication token"
        else
            rlPass "Unenrolled agent correctly denied authentication token"
        fi

        # Verify agent log shows authentication failed
        # Per spec, verifier issues challenges even for unenrolled agents,
        # but authentication fails during proof submission (PATCH)
        rlRun "grep -q 'Authentication failed with evaluation: fail' $(limePushAgentLogfile)" \
            0 "Agent log shows authentication failed for unenrolled agent"

        # Stop agent for enrollment
        rlRun "limeStopPushAgent"
    rlPhaseEnd

    rlPhaseStartTest "Enroll agent and test initial authentication"
        rlLog "Enrolling agent and testing that it authenticates and receives token"

        # Create a simple policy that allows everything (for authentication testing)
        # We don't need actual files for authentication testing, just a valid policy
        rlRun "limeCreateTestPolicy"

        # Enroll the agent
        rlRun "keylime_tenant -v 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add --push-model"

        # Verify agent appears in verifier's agent list
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "$AGENT_ID" "$rlRun_LOG"

        # Start push-attestation agent (now enrolled)
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Wait for agent to authenticate and get token
        rlRun "rlWaitForCmd 'grep -q \"authorization: \\\"Bearer\" \$(limePushAgentLogfile)' -m 30 -d 1" \
            0 "Agent authenticated and received token"

        # Capture the token using helper function
        INITIAL_TOKEN=$(limePushAuthGetToken)
        rlLog "Initial authentication token: $INITIAL_TOKEN"

        # Verify token is not empty
        if [ -n "$INITIAL_TOKEN" ]; then
            rlPass "Agent received valid authentication token"
        else
            rlFail "Agent did not receive authentication token"
        fi

        # Verify verifier log shows authentication succeeded
        rlRun "grep -q 'Authentication token validated for agent.*${AGENT_ID}' \$(limeVerifierLogfile)" \
            0 "Verifier log shows successful authentication"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        # Stop push agent
        rlRun "limeStopPushAgent"

        # Stop keylime services
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
