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
            if [ $fd_diff -gt 5 ]; then
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
    if keylime_tenant -c cvlist   >/dev/null 2>&1; then
        rlLogInfo "[$phase] Verifier service is responsive"
    else
        rlLogWarning "[$phase] Verifier service is not responsive"
        return 1
    fi

    # Return the file descriptor monitoring result
    return $fd_result
}

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
        rlRun "keylime-policy create measured-boot -e $TESTDIR/binary_bios_measurements -o $TESTDIR/test-mb-policy.json"
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
            rlRun "keylime_tenant -c add --uuid $AGENT_ID --file $TESTDIR/autorun.sh"

            # Verify agent is active (exercises GET /agents endpoint)
            rlRun "keylime_tenant -c status --uuid $AGENT_ID"

            # Query agent multiple times to exercise GET endpoint
            for j in {1..3}; do
                rlRun "keylime_tenant -c status --uuid $AGENT_ID" 0 "GET agent $AGENT_ID (query $j)"
            done

            # Delete agent from verifier (exercises DELETE /agents endpoint)
            rlRun "keylime_tenant -c delete --uuid $AGENT_ID"

            # Additional direct API calls to exercise endpoints that could leak connections
            # Query agents list (exercises GET /agents endpoint)
            rlRun "keylime_tenant -c cvlist  " 0 "GET agents list"

            # Check database health after each cycle
            check_db_health "Agent cycle $i"

            # Small delay between cycles
            sleep 1
        done

        # Additional stress test: rapid API calls without tenant operations
        rlLogInfo "Performing rapid API calls to stress database connections"
        for i in {1..5}; do
            # These API calls exercise the database without agent operations
            keylime_tenant -c cvlist   >/dev/null 2>&1 &
            keylime_tenant -c listruntimepolicy   >/dev/null 2>&1 &
        done
        wait

        # Stop the agent
        rlRun "limeStopAgent"

        # Verify verifier is still responsive
        rlRun "keylime_tenant -c cvlist  " 0 "Verifier should still be responsive after agent stress test"
        check_db_health "After agent stress test"
    rlPhaseEnd

    rlPhaseStartTest "Test 2: Policy management stress test"
        rlLogInfo "Testing policy CRUD operations that previously could leak connections"

        # Test allowlist/runtime policy operations (AllowlistHandler endpoints)
        for i in {1..3}; do
            POLICY_NAME="test-policy-$i"
            rlLogInfo "Testing policy operations cycle $i with policy $POLICY_NAME"

                        # Create policy (addruntimepolicy command)
            rlRun "keylime_tenant -c addruntimepolicy   --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $POLICY_NAME" 0 "Create test policy $POLICY_NAME"

            # Read policy (showruntimepolicy command)
            rlRun "keylime_tenant -c showruntimepolicy   --runtime-policy-name $POLICY_NAME" 0 "Read test policy $POLICY_NAME"

            # Update policy (updateruntimepolicy command)
            rlRun "keylime_tenant -c updateruntimepolicy   --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $POLICY_NAME" 0 "Update test policy $POLICY_NAME"

            # Delete policy (deleteruntimepolicy command)
            rlRun "keylime_tenant -c deleteruntimepolicy   --runtime-policy-name $POLICY_NAME" 0 "Delete test policy $POLICY_NAME"

            # Check database health after policy operations
            check_db_health "Policy cycle $i"
        done

        # Test measured boot policy operations (MbpolicyHandler endpoints)
        for i in {1..3}; do
            MB_POLICY_NAME="test-mb-policy-$i"
            rlLogInfo "Testing MB policy operations cycle $i with policy $MB_POLICY_NAME"

                        # Create MB policy (addmbpolicy command)
            rlRun "keylime_tenant -c addmbpolicy   --mb-policy $TESTDIR/test-mb-policy.json --mb-policy-name $MB_POLICY_NAME" 0 "Create test MB policy $MB_POLICY_NAME"

            # Read MB policy (showmbpolicy command)
            rlRun "keylime_tenant -c showmbpolicy   --mb-policy-name $MB_POLICY_NAME" 0 "Read test MB policy $MB_POLICY_NAME"

            # Delete MB policy (deletembpolicy command)
            rlRun "keylime_tenant -c deletembpolicy   --mb-policy-name $MB_POLICY_NAME" 0 "Delete test MB policy $MB_POLICY_NAME"

            # Check database health after MB policy operations
            check_db_health "MB Policy cycle $i"
        done

        # Verify verifier is still responsive
        rlRun "keylime_tenant -c cvlist  " 0 "Verifier should still be responsive after policy stress test"
        check_db_health "After policy stress test"
    rlPhaseEnd

    rlPhaseStartTest "Test 3: Concurrent operations test"
        rlLogInfo "Testing concurrent database operations that could exhaust connection pool"

        # Start a persistent agent for this test
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Function to perform API operations in background (simulates agent operations)
        perform_api_ops() {
            local suffix=$1
            # Exercise the endpoints that previously leaked connections
            keylime_tenant -c cvlist   >/dev/null 2>&1
            sleep 0.1
            keylime_tenant -c status --uuid $AGENT_ID >/dev/null 2>&1
            sleep 0.1
            # These would be actual agent operations but we simulate with API calls
            # since we can only have one agent running
        }

        # Function to perform policy operations in background
        perform_policy_ops() {
            local suffix=$1
            local policy_name="concurrent-policy-$suffix"
            keylime_tenant -c addruntimepolicy   --runtime-policy "$TESTDIR/test-policy.json" --runtime-policy-name "$policy_name" >/dev/null 2>&1
            sleep 0.1
            keylime_tenant -c showruntimepolicy   --runtime-policy-name "$policy_name" >/dev/null 2>&1
            sleep 0.1
            keylime_tenant -c deleteruntimepolicy   --runtime-policy-name "$policy_name" >/dev/null 2>&1
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
        rlRun "keylime_tenant -c cvlist  " 0 "Verifier should still be responsive after concurrent operations"
        rlRun "keylime_tenant -c reglist  " 0 "Registrar should still be responsive after concurrent operations"
        check_db_health "After concurrent operations"
    rlPhaseEnd

    rlPhaseStartTest "Test 4: Resource exhaustion recovery test"
        rlLogInfo "Testing recovery from resource exhaustion scenarios"

        # Create many policies rapidly to test connection pool limits
        policy_names=()
        for i in {1..5}; do
            POLICY_NAME="exhaust-test-policy-$i"
            policy_names+=("$POLICY_NAME")

            # Create policies rapidly (may hit connection pool limits)
            keylime_tenant -c addruntimepolicy   --runtime-policy "$TESTDIR/test-policy.json" --runtime-policy-name "$POLICY_NAME" >/dev/null 2>&1 &
        done

        # Wait for all creates to complete
        wait
        sleep 1

        # Verify service is still functional
        rlRun "keylime_tenant -c cvlist  " 0 "Verifier should recover from resource exhaustion"
        check_db_health "After resource exhaustion test"

        # Clean up policies
        for policy_name in "${policy_names[@]}"; do
            keylime_tenant -c deleteruntimepolicy   --runtime-policy-name "$policy_name" >/dev/null 2>&1 &
        done
        wait

        sleep 1
        rlRun "keylime_tenant -c cvlist  " 0 "Verifier should remain responsive after cleanup"
        check_db_health "After cleanup"
    rlPhaseEnd

    rlPhaseStartTest "Test 5: File descriptor leak detection test with timeouts"
        rlLogInfo "Intensive file descriptor monitoring to detect connection leaks"

        # Start a fresh agent for this test
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Record baseline FD count
        monitor_db_file_descriptors "Baseline for leak detection"
        baseline_fd_count=$CURRENT_FD_COUNT

        # Timeout settings - connection leaks can cause operations to hang
        OPERATION_TIMEOUT=15  # seconds per operation
        timeout_count=0       # track timeouts as evidence of leaks

        # Function to run commands with timeout and track failures
        run_with_timeout() {
            local cmd="$1"
            local description="$2"

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
        }

        # Perform intensive operations that would have leaked connections before the fix
        rlLogInfo "Performing intensive operations to stress-test connection management (with ${OPERATION_TIMEOUT}s timeouts)"

        for cycle in {1..3}; do
            rlLogInfo "Intensive cycle $cycle/3"

            # Rapid agent operations with timeout monitoring
            for i in {1..3}; do
                run_with_timeout "keylime_tenant -c add --uuid $AGENT_ID --file $TESTDIR/autorun.sh" "Agent add operation $i"
                run_with_timeout "keylime_tenant -c status --uuid $AGENT_ID" "Agent status check $i"
                run_with_timeout "keylime_tenant -c delete --uuid $AGENT_ID" "Agent delete operation $i"
                run_with_timeout "keylime_tenant -c cvlist" "Agent list operation $i"
            done

            # Rapid policy operations with timeout monitoring
            for i in {1..3}; do
                test_policy="fd-test-policy-$cycle-$i"
                run_with_timeout "keylime_tenant -c addruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $test_policy" "Policy create $test_policy"
                run_with_timeout "keylime_tenant -c showruntimepolicy --runtime-policy-name $test_policy" "Policy read $test_policy"
                run_with_timeout "keylime_tenant -c deleteruntimepolicy --runtime-policy-name $test_policy" "Policy delete $test_policy"
            done

            # Monitor FD count after each cycle
            monitor_db_file_descriptors "After intensive cycle $cycle"
            current_fd_count=$CURRENT_FD_COUNT
            fd_increase=$((current_fd_count - baseline_fd_count))

            # Report timeout statistics for this cycle
            rlLogInfo "Cycle $cycle completed - Timeouts so far: $timeout_count"

            if [ $fd_increase -gt 10 ]; then
                rlFail "CRITICAL: File descriptor count increased by $fd_increase - definite connection leak detected!"
                # Show detailed FD information
                rlLogInfo "Detailed file descriptor information:"
                lsof /var/lib/keylime/cv_data.sqlite 2>/dev/null | head -20
                break
            elif [ $fd_increase -gt 3 ]; then
                rlLogWarning "File descriptor count increased by $fd_increase - monitoring closely"
            else
                rlLogInfo "File descriptor count acceptable (increase: $fd_increase)"
            fi

            # Check if we're getting too many timeouts (another leak indicator)
            if [ $timeout_count -gt 5 ]; then
                rlFail "CRITICAL: Too many operation timeouts ($timeout_count) - system becoming unresponsive!"
                break
            fi

            # Small delay between cycles
            sleep 1
        done

        # Final comprehensive check
        monitor_db_file_descriptors "Final FD leak check"
        final_fd_count=$CURRENT_FD_COUNT
        total_fd_increase=$((final_fd_count - baseline_fd_count))

        # Report final statistics
        rlLogInfo "=== FINAL LEAK DETECTION RESULTS ==="
        rlLogInfo "Total file descriptor increase: $total_fd_increase"
        rlLogInfo "Total operation timeouts: $timeout_count"
        rlLogInfo "Initial FD count: $baseline_fd_count"
        rlLogInfo "Final FD count: $final_fd_count"

        # Determine overall test result based on both FD count and timeouts
        if [ $total_fd_increase -le 5 ] && [ $timeout_count -le 2 ]; then
            rlPass "Connection leak test PASSED - FD increase: $total_fd_increase, timeouts: $timeout_count (both acceptable)"
        elif [ $total_fd_increase -gt 5 ] && [ $timeout_count -gt 2 ]; then
            rlFail "Connection leak test FAILED - FD increase: $total_fd_increase AND timeouts: $timeout_count (both indicate severe leaks)"
        elif [ $total_fd_increase -gt 5 ]; then
            rlFail "Connection leak test FAILED - FD increase: $total_fd_increase (indicates file descriptor leak)"
        elif [ $timeout_count -gt 2 ]; then
            rlFail "Connection leak test FAILED - timeouts: $timeout_count (indicates system unresponsiveness from leaks)"
        else
            rlPass "Connection leak test PASSED with minor issues - FD increase: $total_fd_increase, timeouts: $timeout_count"
        fi

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
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist "$TESTDIR"
    rlPhaseEnd

rlJournalEnd
