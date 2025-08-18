#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# ============================================================================
# DATABASE CONNECTION LEAK REPRODUCER TEST
# ============================================================================
#
# This test reproduces database connection leak scenarios that were fixed in
# keylime commit 36590dc "Use context managers to close DB sessions".
#
# PROBLEM DESCRIPTION:
# Before the fix, keylime had several code paths that opened database sessions
# using get_session() but never properly closed them, causing connection leaks:
#
# 1. HTTP API Endpoints (AgentsHandler, AllowlistHandler, MbpolicyHandler):
#    - GET/POST/PUT/DELETE operations opened sessions but didn't close them
#    - Exception paths bypassed session cleanup
#
# 2. Agent Processing Pipeline (process_agent, update_agent_api_version):
#    - Multiple separate DB operations without session management
#    - Long-running processes holding sessions open
#
# 3. Notification System (notify_error):
#    - Querying agents for notifications without proper cleanup
#
# REPRODUCTION STRATEGY:
# - Configure a very small database connection pool (2 connections + 1 overflow)
# - Execute high-volume operations that would have leaked connections
# - Verify that services remain responsive and connections are properly released
#
# TEST PHASES:
# 1. Agent registration/deletion stress test
# 2. Policy CRUD operations stress test
# 3. Concurrent operations test
# 4. Resource exhaustion recovery test
# 5. File descriptor leak detection with timeout monitoring
#
# SUCCESS CRITERIA:
# - All services remain responsive throughout the test
# - Database remains accessible (no locks/busy states)
# - Connection pool doesn't get exhausted
# - File descriptor count for database file remains stable (key indicator)
# - Operations complete within reasonable timeouts (system remains responsive)
#
# KEY DETECTION METHODS:
# - File descriptor monitoring using lsof to track open FDs for cv_data.sqlite
# - Operation timeout monitoring (connection leaks can cause hangs/delays)
# - This provides direct evidence of connection leaks as unclosed DB connections
#   leave file descriptors open indefinitely and can cause system unresponsiveness
# ============================================================================

# Test configuration
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

# Small connection pool to make leaks more visible
DB_POOL_SIZE="2"
DB_MAX_OVERFLOW="1"

# Operation timeout for detecting connection leaks that cause hangs
OPERATION_TIMEOUT=15  # seconds per operation
timeout_count=0       # track timeouts as evidence of leaks

# Function to run keylime_tenant commands with timeout and track failures
# Connection leaks can cause operations to hang, so timing out is evidence of problems
run_with_timeout() {
    local cmd="$1"
    local description="$2"
    local suppress_output="${3:-false}"

    # Skip running if the test phase already detected a connection leak
    if ! rlGetPhaseState; then
        rlLogInfo "Skipping command as the test phase has already failed"
        return
    fi

    if [ "$suppress_output" = "true" ]; then
        if timeout $OPERATION_TIMEOUT bash -c "$cmd" >/dev/null 2>&1; then
            return 0
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                # Timeout occurred (exit code 124)
                timeout_count=$((timeout_count + 1))
                rlLogWarning "TIMEOUT: $description (${OPERATION_TIMEOUT}s) - potential connection leak symptom!"
                return 1
            else
                # Other error
                rlLogWarning "FAILED: $description (exit code: $exit_code)"
                return 1
            fi
        fi
    else
        # For rlRun wrapped calls, don't suppress output
        if timeout $OPERATION_TIMEOUT bash -c "$cmd"; then
            return 0
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                # Timeout occurred (exit code 124)
                timeout_count=$((timeout_count + 1))
                rlLogWarning "TIMEOUT: $description (${OPERATION_TIMEOUT}s) - potential connection leak symptom!"
                return 1
            else
                # Other error
                return $exit_code
            fi
        fi
    fi
}

# Function to monitor database file descriptors - the key indicator of connection leaks
monitor_db_file_descriptors() {
    local phase="$1"
    local db_file="/var/lib/keylime/cv_data.sqlite"

    rlLogInfo "File descriptor monitoring: $phase"

    if [ -f "$db_file" ]; then
        # Count open file descriptors for the database file
        local fd_count
        fd_count=$(lsof "$db_file" 2>/dev/null | grep -c -v COMMAND)
        rlLogInfo "[$phase] Open file descriptors for $db_file: $fd_count"

        # Store initial count for comparison
        if [ -z "$INITIAL_FD_COUNT" ]; then
            export INITIAL_FD_COUNT="$fd_count"
            rlLogInfo "[$phase] Initial FD count recorded: $INITIAL_FD_COUNT"
        else
            local fd_diff=$((fd_count - INITIAL_FD_COUNT))
            if [ $fd_diff -gt 10 ]; then
                rlFail "CRITICAL: File descriptor count increased by $fd_diff - definite connection leak detected!"
                # Show detailed FD information
                rlLogInfo "[$phase] Processes with open FDs:"
                lsof "$db_file" 2>/dev/null || rlLogInfo "No open file descriptors found"
                return 1
            elif [ $fd_diff -gt 5 ]; then
                rlLogWarning "[$phase] FD count increased by $fd_diff (from $INITIAL_FD_COUNT to $fd_count) - potential connection leak!"
                # Show which processes have the file open
                rlLogInfo "[$phase] Processes with open FDs:"
                lsof "$db_file" 2>/dev/null || rlLogInfo "No open file descriptors found"
                return 1
            elif [ $fd_diff -gt 0 ]; then
                rlLogInfo "[$phase] FD count increased by $fd_diff (acceptable)"
            else
                rlLogInfo "[$phase] FD count stable or decreased (good)"
            fi
        fi

        # Store current count for trend analysis
        export CURRENT_FD_COUNT="$fd_count"

    else
        rlLogInfo "[$phase] Database file not found - using non-SQLite configuration"
    fi
}

# Function to check database accessibility and log connection status
check_db_health() {
    local phase="$1"
    local db_file="/var/lib/keylime/cv_data.sqlite"

    rlLogInfo "Database health check: $phase"

    # Monitor file descriptors first - this is the key indicator
    monitor_db_file_descriptors "$phase"
    local fd_result=$?

    if [ -f "$db_file" ]; then
        # Check if database is accessible (no locks/busy states)
        if sqlite3 "$db_file" 'SELECT COUNT(*) FROM sqlite_master;' >/dev/null 2>&1; then
            rlLogInfo "[$phase] Database is accessible"

            # Check for agents table and count
            local agent_count
            agent_count=$(sqlite3 "$db_file" 'SELECT COUNT(*) FROM verifiermain WHERE agent_id IS NOT NULL;' 2>/dev/null || echo "0")
            rlLogInfo "[$phase] Agent count in DB: $agent_count"

            # Check for policies
            local policy_count
            policy_count=$(sqlite3 "$db_file" 'SELECT COUNT(*) FROM allowlists;' 2>/dev/null || echo "0")
            rlLogInfo "[$phase] Policy count in DB: $policy_count"

        else
            rlLogWarning "[$phase] Database is not accessible - potential connection issues"
            return 1
        fi
    else
        rlLogInfo "[$phase] Using non-SQLite database or database not yet created"
    fi

    # Check service responsiveness as a proxy for connection health
    if run_with_timeout "keylime_tenant -c cvlist" "Service responsiveness check" true; then
        rlLogInfo "[$phase] Verifier service is responsive"
    else
        rlLogWarning "[$phase] Verifier service is not responsive"
        return 1
    fi

    # Return the file descriptor monitoring result
    return $fd_result
}

ARCH=$( rlGetPrimaryArch )

rlJournalStart

    rlPhaseStartSetup "Setup keylime with small DB connection pool"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Backup and update configuration
        limeBackupConfig

        # Configure small database connection pool for verifier to make leaks visible
        rlRun "limeUpdateConf verifier database_pool_sz_ovfl '${DB_POOL_SIZE},${DB_MAX_OVERFLOW}'"

        # Configure for testing
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"

        # Set up TPM emulator if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        sleep 5

        # Start services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Initial database health check
        check_db_health "Initial setup"

        # Create test directory
        TESTDIR=$(limeCreateTestDir)
        rlRun "echo 'echo test payload executed' > $TESTDIR/autorun.sh && chmod +x $TESTDIR/autorun.sh"
        rlRun "cp ./binary_bios_measurements $TESTDIR/binary_bios_measurements"

        # Create test policies for policy operations
        rlRun "keylime-policy create runtime -o $TESTDIR/test-policy.json"
	# efivar not available on s390x and ppc64le
	if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
            rlRun "keylime-policy create measured-boot -e $TESTDIR/binary_bios_measurements -o $TESTDIR/test-mb-policy.json"
	fi
    rlPhaseEnd

    rlPhaseStartTest "Test 1: Agent operations stress test with single agent"
        rlLogInfo "Testing agent operations that previously could leak connections"

        # Start a single persistent agent for this test
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Test repeated agent operations with the same agent
        # This exercises the AgentsHandler GET/POST/DELETE endpoints repeatedly
        for i in {1..3}; do
            rlLogInfo "Testing agent operations cycle $i with agent $AGENT_ID"

            # Add agent to verifier (exercises POST /agents endpoint)
            rlRun "run_with_timeout 'keylime_tenant -c add --uuid $AGENT_ID --file $TESTDIR/autorun.sh' 'Agent add operation cycle $i'"

            # Verify agent is active (exercises GET /agents endpoint)
            rlRun "run_with_timeout 'keylime_tenant -c status --uuid $AGENT_ID' 'Agent status check cycle $i'"

            # Query agent multiple times to exercise GET endpoint
            for j in {1..3}; do
                rlRun "run_with_timeout 'keylime_tenant -c status --uuid $AGENT_ID' 'Agent GET query $j cycle $i'" 0
            done

            # Delete agent from verifier (exercises DELETE /agents endpoint)
            rlRun "run_with_timeout 'keylime_tenant -c delete --uuid $AGENT_ID' 'Agent delete operation cycle $i'"

            # Additional direct API calls to exercise endpoints that could leak connections
            # Query agents list (exercises GET /agents endpoint)
            rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Agent list query cycle $i'" 0

            # Check database health after each cycle
            check_db_health "Agent cycle $i"

            # Small delay between cycles
            sleep 1
        done

        # Additional stress test: rapid API calls without tenant operations
        rlLogInfo "Performing rapid API calls to stress database connections"
        pids=()
        for i in {1..3}; do
            # These API calls exercise the database without agent operations
            # Only start and track processes if the phase is still good
            if rlGetPhaseState; then
                timeout $OPERATION_TIMEOUT keylime_tenant -c cvlist >/dev/null 2>&1 &
                pids+=($!)
                timeout $OPERATION_TIMEOUT keylime_tenant -c listruntimepolicy >/dev/null 2>&1 &
                pids+=($!)
            fi
        done
        
        # Wait for background operations to complete, handling cases where they might have finished
        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true  # Suppress errors if process already finished
        done

        # Stop the agent
        rlRun "limeStopAgent"

        # Verify verifier is still responsive
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-agent-stress verifier check'" 0
        check_db_health "After agent stress test"
    rlPhaseEnd

    rlPhaseStartTest "Test 2: Policy management stress test"
        rlLogInfo "Testing policy CRUD operations that previously could leak connections"

        # Test allowlist/runtime policy operations (AllowlistHandler endpoints)
        for i in {1..3}; do
            POLICY_NAME="test-policy-$i"
            rlLogInfo "Testing policy operations cycle $i with policy $POLICY_NAME"

            # Create policy (addruntimepolicy command)
            rlRun "run_with_timeout 'keylime_tenant -c addruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $POLICY_NAME' 'Create policy $POLICY_NAME'" 0

            # Read policy (showruntimepolicy command)
            rlRun "run_with_timeout 'keylime_tenant -c showruntimepolicy --runtime-policy-name $POLICY_NAME' 'Read policy $POLICY_NAME'" 0

            # Update policy (updateruntimepolicy command)
            rlRun "run_with_timeout 'keylime_tenant -c updateruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $POLICY_NAME' 'Update policy $POLICY_NAME'" 0

            # Delete policy (deleteruntimepolicy command)
            rlRun "run_with_timeout 'keylime_tenant -c deleteruntimepolicy --runtime-policy-name $POLICY_NAME' 'Delete policy $POLICY_NAME'" 0

            # Check database health after policy operations
            check_db_health "Policy cycle $i" || break
        done

	# Test measured boot policy operations (MbpolicyHandler endpoints)
	# efivar not available on s390x and ppc64le
        if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
		for i in {1..3}; do
		    MB_POLICY_NAME="test-mb-policy-$i"
		    rlLogInfo "Testing MB policy operations cycle $i with policy $MB_POLICY_NAME"

		    # Create MB policy (addmbpolicy command)
		    rlRun "run_with_timeout 'keylime_tenant -c addmbpolicy --mb-policy $TESTDIR/test-mb-policy.json --mb-policy-name $MB_POLICY_NAME' 'Create MB policy $MB_POLICY_NAME'" 0

		    # Read MB policy (showmbpolicy command)
		    rlRun "run_with_timeout 'keylime_tenant -c showmbpolicy --mb-policy-name $MB_POLICY_NAME' 'Read MB policy $MB_POLICY_NAME'" 0

		    # Delete MB policy (deletembpolicy command)
		    rlRun "run_with_timeout 'keylime_tenant -c deletembpolicy --mb-policy-name $MB_POLICY_NAME' 'Delete MB policy $MB_POLICY_NAME'" 0

		    # Check database health after MB policy operations
		    check_db_health "MB Policy cycle $i" || break
		done
        fi

        # Verify verifier is still responsive
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-policy-stress verifier check'" 0
        check_db_health "After policy stress test"
    rlPhaseEnd

    rlPhaseStartTest "Test 3: Concurrent operations test"
        rlLogInfo "Testing concurrent database operations that could exhaust connection pool"

        # Start an agent for this test
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Function to perform API operations in background (simulates agent operations)
        perform_api_ops() {
            local suffix=$1
            # Exercise the endpoints that previously leaked connections
            run_with_timeout "keylime_tenant -c cvlist" "Concurrent cvlist $suffix" true
            sleep 0.1
            run_with_timeout "keylime_tenant -c status --uuid $AGENT_ID" "Concurrent status $suffix" true
            sleep 0.1
            # These would be actual agent operations but we simulate with API calls
            # since we can only have one agent running
        }

        # Function to perform policy operations in background
        perform_policy_ops() {
            local suffix=$1
            local policy_name="concurrent-policy-$suffix"
            run_with_timeout "keylime_tenant -c addruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $policy_name" "Concurrent policy create $suffix" true
            sleep 0.1
            run_with_timeout "keylime_tenant -c showruntimepolicy --runtime-policy-name $policy_name" "Concurrent policy read $suffix" true
            sleep 0.1
            run_with_timeout "keylime_tenant -c deleteruntimepolicy --runtime-policy-name $policy_name" "Concurrent policy delete $suffix" true
        }

        # Launch concurrent operations
        rlLogInfo "Starting concurrent API and policy operations"
        pids=()

        # Start concurrent API operations
        for i in {1..3}; do
            perform_api_ops "$i" &
            pids+=($!)
        done

        # Start concurrent policy operations
        for i in {1..3}; do
            perform_policy_ops "$i" &
            pids+=($!)
        done

        # Wait for all background operations to complete
        for pid in "${pids[@]}"; do
            wait "$pid"
        done

        sleep 1

        # Stop the agent
        rlRun "limeStopAgent"

        # Verify services are still responsive after concurrent load
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-concurrent verifier check'" 0
        rlRun "run_with_timeout 'keylime_tenant -c reglist' 'Post-concurrent registrar check'" 0
        check_db_health "After concurrent operations"
    rlPhaseEnd

    rlPhaseStartTest "Test 4: Resource exhaustion recovery test"
        rlLogInfo "Testing recovery from resource exhaustion scenarios"

        # Create many policies rapidly to test connection pool limits
        policy_names=()
        create_pids=()
        for i in {1..5}; do
            POLICY_NAME="exhaust-test-policy-$i"
            policy_names+=("$POLICY_NAME")

            # Create policies rapidly (may hit connection pool limits)
            if rlGetPhaseState; then
                timeout $OPERATION_TIMEOUT keylime_tenant -c addruntimepolicy --runtime-policy "$TESTDIR/test-policy.json" --runtime-policy-name "$POLICY_NAME" >/dev/null 2>&1 &
                create_pids+=($!)
            fi
        done

        # Wait for all creates to complete
        for pid in "${create_pids[@]}"; do
            wait "$pid" 2>/dev/null || true  # Suppress errors if process already finished
        done
        sleep 1

        # Verify service is still functional
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-exhaustion verifier check'" 0
        check_db_health "After resource exhaustion test"

        # Clean up policies
        cleanup_pids=()
        for policy_name in "${policy_names[@]}"; do
            if rlGetPhaseState; then
                timeout $OPERATION_TIMEOUT keylime_tenant -c deleteruntimepolicy --runtime-policy-name "$policy_name" >/dev/null 2>&1 &
                cleanup_pids+=($!)
            fi
        done
        
        # Wait for all cleanup operations to complete
        for pid in "${cleanup_pids[@]}"; do
            wait "$pid" 2>/dev/null || true  # Suppress errors if process already finished
        done

        sleep 1
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-cleanup verifier check'" 0
        check_db_health "After cleanup"
    rlPhaseEnd

    rlPhaseStartTest "Test 5: File descriptor leak detection test with timeouts"
        rlLogInfo "Intensive file descriptor monitoring to detect connection leaks"

        # Start an agent for this test
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Perform intensive operations that would have leaked connections before the fix
        rlLogInfo "Performing intensive operations to stress-test connection management (with ${OPERATION_TIMEOUT}s timeouts)"

        for cycle in {1..3}; do
            rlLogInfo "Intensive cycle $cycle/3"

            # Rapid agent operations with timeout monitoring
            for i in {1..3}; do
                run_with_timeout "keylime_tenant -c add --uuid $AGENT_ID --file $TESTDIR/autorun.sh" "Agent add operation $i" true
                run_with_timeout "keylime_tenant -c status --uuid $AGENT_ID" "Agent status check $i" true
                run_with_timeout "keylime_tenant -c delete --uuid $AGENT_ID" "Agent delete operation $i" true
                run_with_timeout "keylime_tenant -c cvlist" "Agent list operation $i" true
            done

            # Rapid policy operations with timeout monitoring
            for i in {1..3}; do
                test_policy="fd-test-policy-$cycle-$i"
                run_with_timeout "keylime_tenant -c addruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $test_policy" "Policy create $test_policy" true
                run_with_timeout "keylime_tenant -c showruntimepolicy --runtime-policy-name $test_policy" "Policy read $test_policy" true
                run_with_timeout "keylime_tenant -c deleteruntimepolicy --runtime-policy-name $test_policy" "Policy delete $test_policy" true
            done

            # Monitor FD count after each cycle
            check_db_health "After intensive cycle $cycle" || break

            # Report timeout statistics for this cycle
            rlLogInfo "Cycle $cycle completed - Timeouts so far: $timeout_count"

            # Check if we're getting too many timeouts (another leak indicator)
            if [ $timeout_count -gt 3 ]; then
                rlFail "CRITICAL: Too many operation timeouts ($timeout_count) - system becoming unresponsive!"
                break
            fi

            # Small delay between cycles
            sleep 1
        done

        # Final check
        check_db_health "Final check"

        # Stop agent
        rlRun "limeStopAgent"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        # Stop services (agents are already stopped in individual tests)
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
        limeExtendNextExcludelist "$TESTDIR"
    rlPhaseEnd

rlJournalEnd
