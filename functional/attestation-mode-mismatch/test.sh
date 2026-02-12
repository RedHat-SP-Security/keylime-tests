#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/keylime/Functional/attestation-mode-mismatch
#   Description: Test attestation mode mismatch between Agent and Verifier
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2025 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beakerlib environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Agent UUID for testing (both agent types use the same UUID)
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
ATTESTATION_INTERVAL=5
TIMEOUT=$((ATTESTATION_INTERVAL * 5))

rlJournalStart

    rlPhaseStartSetup "Setup_Test_Environment"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Backup original configuration
        limeBackupConfig

        # Configure basic settings
        rlRun "limeUpdateConf verifier max_retries 1"
        rlRun "limeUpdateConf verifier request_timeout 3"
        rlRun "limeUpdateConf verifier exponential_backoff False"
        rlRun "limeUpdateConf verifier quote_interval ${ATTESTATION_INTERVAL}"
        rlRun "limeUpdateConf agent attestation_interval_seconds ${ATTESTATION_INTERVAL}"
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Configure TPM if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        sleep 5

        # Create test policy
        rlRun "limeCreateTestPolicy"
    rlPhaseEnd

    rlPhaseStartTest "Push Verifier vs. Pull Agent (Mismatch)"
        # Configure Verifier for agent-driven (push-model) attestation
        rlRun "limeUpdateConf verifier mode 'push'"
        rlRun "limeUpdateConf verifier challenge_lifetime 1800"
        rlLogInfo "Verifier configured for PUSH-MODEL (agent-driven) attestation"

        # Start Verifier FIRST (creates CA certificates)
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"

        # Start Registrar SECOND (uses existing CA certificates)
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Start PULL-mode agent (verifier-driven attestation)
        rlLogInfo "Starting PULL-based agent (verifier-driven attestation)"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Attempt to add pull-agent to push-verifier (mode mismatch)
        # Registration should succeed, but attestation must fail
        rlLogInfo "Attempting to add pull-based agent to push-model verifier..."
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add" 0

        # Registration succeeded, now wait and verify that attestation fails due to mode mismatch
        rlLogInfo "Checking if attestation is not performed due to mode mismatch..."
	rlRun "limeTIMEOUT=${TIMEOUT} limeWaitForAgentStatus --field attestation_status '$AGENT_ID' '(FAIL|PASS)'" 1 "Agent should not pass nor fail attestation"
	rlRun "limeWaitForAgentStatus --field attestation_status '$AGENT_ID' 'PENDING'"

        # Cleanup scenario 1
        # Stop agent first to ensure clean deletion from verifier
        rlRun "limeStopAgent"

        # Delete agent from verifier to ensure clean state for scenario 2
        rlRun "keylime_tenant -v 127.0.0.1 -u $AGENT_ID -c delete" 0-255
        rlRun "keylime_tenant -v 127.0.0.1 -u $AGENT_ID -c regdelete" 0-255

        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"

        # Clear agent data to ensure clean state for next scenario
        rlRun "rm -rf /var/lib/keylime/cv_ca" 0-255
        rlRun "rm -rf /var/lib/keylime/reg_ca" 0-255
    rlPhaseEnd

    rlPhaseStartTest "Pull Verifier vs. Push Agent (Mismatch)"
        # Configure Verifier for verifier-driven (pull-based) attestation
        rlRun "limeUpdateConf verifier mode 'pull'"
        rlLogInfo "Verifier configured for PULL-based (verifier-driven) attestation"

        # Start Verifier FIRST (creates/uses CA certificates)
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"

        # Start Registrar SECOND
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Start PUSH-mode agent (agent-driven attestation)
        rlLogInfo "Starting PUSH-MODEL agent (agent-driven attestation)"
        rlRun "limeStartPushAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Attempt to add push-agent to pull-verifier (mode mismatch)
        # Registration should succeed, but attestation must fail
        rlLogInfo "Attempting to add push-model agent to pull-based verifier..."
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --runtime-policy policy.json -c add --push-model" 1
        rlAssertGrep "400.*mTLS certificate for agent is required" "$rlRun_LOG" -E

        # Cleanup scenario 2
        rlRun "limeStopPushAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup_Test_Environment"
        rlLogInfo "Stopping all Keylime components and reverting configuration..."

        # Stop all components (in case any are still running)
        rlRun "limeStopPushAgent" 0-255
        rlRun "limeStopAgent" 0-255
        rlRun "limeStopRegistrar" 0-255
        rlRun "limeStopVerifier" 0-255

        # Stop TPM emulator if used
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi

        # Submit logs and cleanup data
        limeSubmitCommonLogs
        limeClearData

        # Restore original configuration
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
