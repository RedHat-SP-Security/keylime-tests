#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart
    rlPhaseStartSetup "Setup push authentication environment"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Backup original configuration
        limeBackupConfig

        # Set the verifier to run in PUSH mode
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        rlRun "limeUpdateConf verifier session_lifetime 180"

        # Enable authentication
        rlRun "limeUpdateConf agent enable_authentication true"
        rlRun "limeUpdateConf agent tls_accept_invalid_certs true"
        rlRun "limeUpdateConf agent tls_accept_invalid_hostnames true"
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

    rlPhaseStartTest "Test token persistence across verifier restarts"
        rlLog "Testing that authentication tokens persist in database and survive verifier restarts"

        # Wait for agent to authenticate and get a fresh token
        # Use longer timeout (90s) as agent may retry authentication multiple times
        # before enrollment completes, adding delay to first successful authentication
        rlRun "rlWaitForCmd 'grep -q \"authorization: \\\"Bearer\" \$(limePushAgentLogfile)' -m 90 -d 1" \
            0 "Waiting for agent to authenticate"

        # Wait a bit more to ensure token is stable
        rlRun "sleep 5"

        # Capture the token from the running agent
        TOKEN_BEFORE=$(limePushAuthGetToken)
        rlLog "Token before restart: $TOKEN_BEFORE"

        # Verify agent can attest successfully with this token
        VERIFIER_LOG=$(limeVerifierLogfile)
        VERIFIER_LOG_MARK=$(wc -l < "$VERIFIER_LOG")
        rlRun "rlWaitForCmd 'tail -n +$VERIFIER_LOG_MARK \$(limeVerifierLogfile) | grep -qE \"Attestation [0-9]+ for agent .${AGENT_ID}. successfully passed verification\"' -m 30 -d 1" \
            0 "Agent can attest successfully before restart"

        # Mark log position before restart
        VERIFIER_LOG_MARK=$(wc -l < "$VERIFIER_LOG")

        # Restart ONLY the verifier (NOT the agent!) - this clears shared memory but NOT database
        rlRun "limeStopVerifier"
        rlLog "Verifier stopped - shared memory cleared, but database persists"

        # Set reasonable token lifetime and enable token extension
        rlRun "limeUpdateConf verifier session_lifetime 300"  # 5 minutes
        rlRun "limeUpdateConf verifier extend_token_on_attestation true"

        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlLog "Verifier restarted - testing if token still works"

        # Wait a bit for agent to attempt attestation with the existing token
        rlRun "sleep 10"

        # Verify that agent continues to attest successfully WITHOUT re-authentication
        rlRun "rlWaitForCmd 'tail -n +$VERIFIER_LOG_MARK \$(limeVerifierLogfile) | grep -qE \"Attestation [0-9]+ for agent .${AGENT_ID}. successfully passed verification\"' -m 30 -d 1" \
            0 "Agent can attest successfully after restart using persisted token"

        # Verify token extension message appears (token was restored from DB and extended)
        rlRun "rlWaitForCmd 'tail -n +$VERIFIER_LOG_MARK \$(limeVerifierLogfile) | grep -q \"Extended auth token for agent.*${AGENT_ID}\"' -m 30 -d 1" \
            0 "Verifier extended token from database after restart"

        # Verify no re-authentication occurred (token should be the same)
        TOKEN_AFTER=$(limePushAuthGetToken)
        rlLog "Token after restart: $TOKEN_AFTER"

        if [ "$TOKEN_BEFORE" = "$TOKEN_AFTER" ] && [ -n "$TOKEN_BEFORE" ]; then
            rlPass "Token persisted across verifier restart (token: $TOKEN_BEFORE) - no re-authentication needed"
        else
            rlFail "Token changed from '$TOKEN_BEFORE' to '$TOKEN_AFTER' - database persistence failed"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Test authentication token remains valid on failed attestations"
        rlLog "Testing that authentication tokens persist through attestation failures in push mode"

        # Verify token survived from previous phase
        TOKEN_INITIAL=$(limePushAuthGetToken)
        rlLog "Initial token: $TOKEN_INITIAL"

        # Wait for successful attestation first
        VERIFIER_LOG=$(limeVerifierLogfile)
        VERIFIER_LOG_MARK=$(wc -l < "$VERIFIER_LOG")
        rlRun "rlWaitForCmd 'tail -n +$VERIFIER_LOG_MARK \$(limeVerifierLogfile) | grep -qE \"Attestation [0-9]+ for agent .${AGENT_ID}. successfully passed verification\"' -m 30 -d 1" \
            0 "Agent can attest successfully before we break it"

        # Now cause an attestation failure by adding a file not in the allowlist
        rlLog "Creating a file not in allowlist to cause attestation failures"

        # Get a new test directory for the bad script
        BAD_TESTDIR=$(limeCreateTestDir)

        # Create a new file NOT in the allowlist
        rlRun "echo -e '#!/bin/bash\necho boom' > ${BAD_TESTDIR}/bad-script.sh && chmod a+x ${BAD_TESTDIR}/bad-script.sh"

        # Run it so IMA logs it (which will cause next attestation to fail)
        rlRun "${BAD_TESTDIR}/bad-script.sh"

        # Mark log position before failure
        VERIFIER_LOG_MARK=$(wc -l < "$VERIFIER_LOG")
        AGENT_LOG=$(limePushAgentLogfile)
        AGENT_LOG_MARK=$(wc -l < "$AGENT_LOG")

        # Wait for attestation to fail
        rlRun "rlWaitForCmd 'tail -n +$VERIFIER_LOG_MARK \$(limeVerifierLogfile) | grep -qE \"Attestation [0-9]+ for agent .${AGENT_ID}. failed verification\"' -m 60 -d 1" \
            0 "Attestation failure detected"

        # CRITICAL: Verify token was NOT invalidated (should still see Bearer token in subsequent requests)
        rlRun "sleep 10"  # Wait for a few more attestation attempts

        # Check that agent is still using the SAME token (not re-authenticating)
        TOKEN_AFTER=$(limePushAuthGetToken)
        rlLog "Token after attestation failure: $TOKEN_AFTER"

        if [ "$TOKEN_INITIAL" = "$TOKEN_AFTER" ] && [ -n "$TOKEN_INITIAL" ]; then
            rlPass "Token remained valid after failed attestation (token: $TOKEN_INITIAL)"
        else
            rlFail "Token changed from '$TOKEN_INITIAL' to '$TOKEN_AFTER' - session was incorrectly invalidated"
        fi

        # Verify agent did NOT get 401 (which would indicate session was deleted)
        if tail -n +$AGENT_LOG_MARK "$AGENT_LOG" | grep -q "Received 401"; then
            rlFail "Agent received 401 - authentication session was incorrectly deleted on attestation failure"
        else
            rlPass "Agent did not receive 401 - authentication session was preserved"
        fi

        # Verify token was NOT extended (should only extend on successful attestations)
        if tail -n +$VERIFIER_LOG_MARK "$VERIFIER_LOG" | grep -q "Extended auth token for agent.*${AGENT_ID}"; then
            rlFail "Token was extended on failed attestation - should only extend on success"
        else
            rlPass "Token was not extended on failed attestation (correct behavior)"
        fi

        # Verify agent can still submit attestations (accept_attestations should remain true in push mode)
        VERIFIER_LOG_MARK=$(wc -l < "$VERIFIER_LOG")
        rlRun "sleep 10"  # Wait for more attestation attempts
        if tail -n +$VERIFIER_LOG_MARK "$VERIFIER_LOG" | grep -qE "Attestation [0-9]+ for agent .${AGENT_ID}. failed verification"; then
            rlPass "Agent continued to submit attestations after failure (push mode allows retry)"
        else
            rlFail "Agent stopped submitting attestations - accept_attestations may have been set to False"
        fi

        # Restore working policy
        # First exclude the bad test directory from verification
        limeExtendNextExcludelist $BAD_TESTDIR
        TESTDIR2=$(limeCreateTestDir)
        rlRun "touch ${TESTDIR2}/dummy.txt"
        rlRun "limeCreateTestPolicy ${TESTDIR2}/*"
        rlRun "keylime_tenant -v 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c update --push-model"

        # Restart agent to clear exponential backoff state from repeated attestation failures
        # Without restart, agent may wait up to 60+ seconds before retrying
        rlRun "limeStopPushAgent"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Verify agent recovers and attestations pass again
        VERIFIER_LOG_MARK=$(wc -l < "$VERIFIER_LOG")
        rlRun "rlWaitForCmd 'tail -n +$VERIFIER_LOG_MARK \$(limeVerifierLogfile) | grep -qE \"Attestation [0-9]+ for agent .${AGENT_ID}. successfully passed verification\"' -m 30 -d 1" \
            0 "Agent recovered - attestations passing again"
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
        limeExtendNextExcludelist $TESTDIR2
        limeExtendNextExcludelist $BAD_TESTDIR
    rlPhaseEnd
rlJournalEnd
