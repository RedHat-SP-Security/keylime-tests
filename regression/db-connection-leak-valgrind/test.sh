#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# ============================================================================
# DATABASE CONNECTION LEAK REPRODUCER TEST - VALGRIND VERSION
# ============================================================================
#
# This is a rewrite of test.sh using valgrind for reliable leak detection
# instead of unreliable lsof file descriptor counting.
#
# KEY IMPROVEMENTS:
# - Uses systemd unit keylime_verifier_valgrind.service to run verifier under valgrind
# - Restarts verifier between each test phase for isolated leak analysis
# - Phase-specific valgrind log directories for clear correlation
# - Analyzes valgrind output for definitive leak detection
#
# TEST STRATEGY:
# Each phase:
#   1. Configure valgrind log directory for this phase
#   2. Start verifier under valgrind
#   3. Run stress test operations
#   4. Stop verifier (triggers valgrind leak analysis)
#   5. Parse valgrind logs for leaked file descriptors
#   6. Report leaks specific to this phase
#
# ============================================================================

# Test configuration
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

# Small connection pool to make leaks more visible
DB_POOL_SIZE="2"
DB_MAX_OVERFLOW="1"

# Valgrind log base directory (timestamped for this test run)
VALGRIND_BASE_DIR="/var/tmp/limeLib/valgrind/test-run-$(date +%Y%m%d-%H%M%S)"

# Operation timeout - increased for valgrind's slower execution
# Tenant delete retries with exponential backoff (max_retries=10): 2s, 4s, 8s, 16s, 32s, 64s, 128s...
# First 7 retries sum to ~254s, so allow 5 minutes for operations
OPERATION_TIMEOUT=300

# Function to start verifier under valgrind for a specific phase
start_verifier_valgrind() {
    local phase_name="$1"
    local log_dir="${VALGRIND_BASE_DIR}/${phase_name}"

    rlLogInfo "Starting verifier under valgrind for phase: $phase_name"
    rlLogInfo "Valgrind logs will be in: $log_dir"

    # Create phase-specific log directory
    rlRun "mkdir -p '$log_dir'"
    rlRun "chown keylime:keylime '$log_dir'"

    # Find keylime_verifier path (works for both RPM and upstream installs)
    local verifier_path=$(command -v keylime_verifier)

    # Update systemd unit to use this phase's log directory via drop-in config
    rlRun "mkdir -p /etc/systemd/system/keylime_verifier_valgrind.service.d"
    cat > /etc/systemd/system/keylime_verifier_valgrind.service.d/logdir.conf <<EOF
[Service]
Environment="VALGRIND_LOG_DIR=${log_dir}"
ExecStart=
ExecStart=/usr/bin/valgrind \\
    --track-fds=yes \\
    --leak-check=full \\
    --show-leak-kinds=all \\
    --log-file=${log_dir}/verifier-%%p.log \\
    --trace-children=yes \\
    --child-silent-after-fork=no \\
    python3 ${verifier_path}
EOF

    rlRun "systemctl daemon-reload"
    rlRun "systemctl start keylime_verifier_valgrind.service"

    # Valgrind startup is slow - wait up to 60s instead of default 20s
    rlRun "rlWaitForSocket -t 60 8881" 0 "Waiting for verifier to start (valgrind is slow)"
}

# Function to stop verifier and prepare for valgrind analysis
stop_verifier_valgrind() {
    rlLogInfo "Stopping verifier to trigger valgrind analysis..."
    rlRun "systemctl stop keylime_verifier_valgrind.service"

    # Give valgrind time to write complete logs
    sleep 3
}

# Function to analyze valgrind logs for a phase
analyze_valgrind_logs() {
    local phase_name="$1"
    local log_dir="${VALGRIND_BASE_DIR}/${phase_name}"

    rlLogInfo "=== Analyzing valgrind logs for phase: $phase_name ==="

    if [ ! -d "$log_dir" ]; then
        rlFail "Log directory not found: $log_dir"
        return 1
    fi

    local log_files=$(find "$log_dir" -name "verifier-*.log" -type f)

    if [ -z "$log_files" ]; then
        rlFail "No valgrind log files found in $log_dir"
        return 1
    fi

    local leaked_fds=0
    local leaked_sqlite_fds=0
    local has_leaks=0
    local num_workers=0
    local workers_with_sqlite_leaks=0
    declare -A worker_sqlite_leaks

    # Analyze each log file
    for log_file in $log_files; do
        local pid=$(basename "$log_file" | sed 's/verifier-\(.*\)\.log/\1/')

        # Skip if not the main python process (filter out child processes)
        # Match keylime_verifier from any path (/usr/bin or /usr/local/bin)
        if ! grep -q "^==.*== Command: python3 .*/keylime_verifier" "$log_file"; then
            rlLogInfo "Skipping $log_file (not main keylime_verifier process)"
            continue
        fi

        num_workers=$((num_workers + 1))
        rlLogInfo "Analyzing worker process $pid (worker #$num_workers)"

        # Count open file descriptors at exit for this specific PID
        local open_fds=$(grep "^==${pid}== Open file descriptor" "$log_file" | wc -l)

        # Subtract 3 for stdin/stdout/stderr which are always open
        local leaked=$((open_fds - 3))

        if [ $leaked -gt 0 ]; then
            rlLogWarning "  Worker $pid: $leaked leaked file descriptors"
            leaked_fds=$((leaked_fds + leaked))

            # Check specifically for SQLite database FD leaks
            local sqlite_fds=$(grep "^==${pid}== Open file descriptor.*cv_data.sqlite" "$log_file" | wc -l)
            if [ $sqlite_fds -gt 0 ]; then
                rlLogWarning "  Worker $pid: $sqlite_fds leaked SQLite database connections!"
                leaked_sqlite_fds=$((leaked_sqlite_fds + sqlite_fds))
                workers_with_sqlite_leaks=$((workers_with_sqlite_leaks + 1))
                worker_sqlite_leaks[$pid]=$sqlite_fds
                has_leaks=1
            fi
        else
            rlLogInfo "  Worker $pid: No leaked file descriptors (good)"
        fi
    done

    # Summary for this phase
    rlLogInfo ""
    rlLogInfo "=== Phase $phase_name Summary ==="
    rlLogInfo "Workers analyzed: $num_workers"
    rlLogInfo "Total leaked FDs (across all workers): $leaked_fds"
    rlLogInfo "Total leaked SQLite connections (across all workers): $leaked_sqlite_fds"

    if [ $leaked_sqlite_fds -gt 0 ]; then
        rlLogInfo "SQLite leak distribution: $workers_with_sqlite_leaks out of $num_workers workers leaked connections"
        # Calculate average if all workers leaked the same amount
        if [ $workers_with_sqlite_leaks -gt 0 ]; then
            local avg=$((leaked_sqlite_fds / workers_with_sqlite_leaks))
            if [ $((avg * workers_with_sqlite_leaks)) -eq $leaked_sqlite_fds ]; then
                rlLogInfo "  → Each affected worker leaked $avg connection(s)"
            else
                rlLogInfo "  → Uneven distribution across workers"
            fi
        fi
        rlFail "CRITICAL: Phase $phase_name leaked $leaked_sqlite_fds database connections total!"
        return 1
    elif [ $leaked_fds -gt 10 ]; then
        rlLogWarning "Phase $phase_name leaked $leaked_fds file descriptors total (not database-related)"
        return 0
    else
        rlPass "Phase $phase_name: No significant leaks detected"
        return 0
    fi
}

# Function to run operations with timeout
run_with_timeout() {
    local cmd="$1"
    local description="$2"
    local suppress_output="${3:-false}"

    if [ "$suppress_output" = "true" ]; then
        if timeout $OPERATION_TIMEOUT bash -c "$cmd" >/dev/null 2>&1; then
            return 0
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                rlLogWarning "TIMEOUT: $description (${OPERATION_TIMEOUT}s)"
                return 1
            else
                rlLogWarning "FAILED: $description (exit code: $exit_code)"
                return 1
            fi
        fi
    else
        if timeout $OPERATION_TIMEOUT bash -c "$cmd"; then
            return 0
        else
            local exit_code=$?
            if [ $exit_code -eq 124 ]; then
                rlLogWarning "TIMEOUT: $description (${OPERATION_TIMEOUT}s)"
                return 1
            else
                return $exit_code
            fi
        fi
    fi
}

ARCH=$( rlGetPrimaryArch )

rlJournalStart

    rlPhaseStartSetup "Setup keylime with valgrind"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        rlAssertRpm valgrind

        # Find keylime_verifier path (works for both RPM and upstream installs)
        VERIFIER_PATH=$(command -v keylime_verifier)
        rlLogInfo "Found keylime_verifier at: $VERIFIER_PATH"

        # Create valgrind service unit inline (will be customized per phase)
        rlLogInfo "Creating keylime_verifier_valgrind systemd unit"
        cat > /etc/systemd/system/keylime_verifier_valgrind.service <<EOF
[Unit]
Description=The Keylime verifier (running under Valgrind for leak detection)
After=network.target
Before=keylime_registrar.service
StartLimitInterval=10s
StartLimitBurst=5

[Service]
Group=keylime
User=keylime
Type=simple
# Create log directory before starting
ExecStartPre=/usr/bin/mkdir -p /var/tmp/limeLib/valgrind
# Run verifier under valgrind with FD tracking and full leak detection
# Using python3 explicitly makes filtering valgrind logs easier
# Note: ExecStart will be overridden per phase via drop-in config
ExecStart=/usr/bin/valgrind \\
    --track-fds=yes \\
    --leak-check=full \\
    --show-leak-kinds=all \\
    --log-file=/var/tmp/limeLib/valgrind/verifier-%%p.log \\
    --trace-children=yes \\
    --child-silent-after-fork=no \\
    python3 ${VERIFIER_PATH}
# Valgrind needs more time to start and shutdown
TimeoutStartSec=120s
TimeoutStopSec=120s
# Use KillMode=process so only the main process receives SIGTERM.
# This allows the parent to gracefully shut down child workers before they
# are killed, preventing connection leaks from interrupted transactions.
KillMode=process
# Don't restart on failure during testing
Restart=no

[Install]
WantedBy=default.target
EOF

        rlRun "systemctl daemon-reload"

        # Backup and update configuration
        limeBackupConfig

        # Clean up additional files not covered by limeClearData
        rm -f /var/lib/keylime/*.sqlite-journal /var/lib/keylime/*.sqlite-wal /var/lib/keylime/*.sqlite-shm
        rm -f /var/lib/keylime/agent_data.json

        # Configure small database connection pool for verifier
        rlRun "limeUpdateConf verifier database_pool_sz_ovfl '${DB_POOL_SIZE},${DB_MAX_OVERFLOW}'"

        # Configure for testing
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"

        # Increase tenant retry settings for valgrind's slower execution
        # Agent delete operations need more retries because verifier state transitions are slow under valgrind
        rlRun "limeUpdateConf tenant max_retries 10"
        rlRun "limeUpdateConf tenant retry_interval 2"

        # Set up TPM emulator if needed
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        sleep 5

        # Create test directory
        TESTDIR=$(limeCreateTestDir)
        rlRun "echo 'echo test payload executed' > $TESTDIR/autorun.sh && chmod +x $TESTDIR/autorun.sh"
        rlRun "cp ./binary_bios_measurements $TESTDIR/binary_bios_measurements"

        # Create test policies
        rlRun "keylime-policy create runtime -o $TESTDIR/test-policy.json"
        if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
            rlRun "keylime-policy create measured-boot -e $TESTDIR/binary_bios_measurements -o $TESTDIR/test-mb-policy.json"
        fi

        # Start registrar (normal mode, not under valgrind)
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
    rlPhaseEnd

    rlPhaseStartTest "Test 1: Agent operations stress test"
        # Start verifier under valgrind for this phase
        start_verifier_valgrind "phase-1-agent-stress"

        rlLogInfo "Testing agent operations that previously could leak connections"

        # Start agent
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Test repeated agent operations
        for i in {1..3}; do
            rlLogInfo "Agent operations cycle $i"

            rlRun "run_with_timeout 'keylime_tenant -c add --uuid $AGENT_ID --file $TESTDIR/autorun.sh' 'Agent add cycle $i'"
            rlRun "run_with_timeout 'keylime_tenant -c status --uuid $AGENT_ID' 'Agent status cycle $i'"

            for j in {1..3}; do
                rlRun "run_with_timeout 'keylime_tenant -c status --uuid $AGENT_ID' 'Agent GET query $j cycle $i'" 0
            done

            rlRun "run_with_timeout 'keylime_tenant -c delete --uuid $AGENT_ID' 'Agent delete cycle $i'"
            rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Agent list cycle $i'" 0

            sleep 1
        done

        # Rapid API calls
        rlLogInfo "Performing rapid API calls"
        pids=()
        for i in {1..3}; do
            timeout $OPERATION_TIMEOUT keylime_tenant -c cvlist >/dev/null 2>&1 &
            pids+=($!)
            timeout $OPERATION_TIMEOUT keylime_tenant -c listruntimepolicy >/dev/null 2>&1 &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        # Stop agent
        rlRun "limeStopAgent"

        # Stop verifier and analyze
        stop_verifier_valgrind
        analyze_valgrind_logs "phase-1-agent-stress"
    rlPhaseEnd

    rlPhaseStartTest "Test 2: Policy management stress test"
        # Start fresh verifier instance for this phase
        start_verifier_valgrind "phase-2-policy-stress"

        rlLogInfo "Testing policy CRUD operations that previously could leak connections"

        # Test runtime policy operations
        for i in {1..3}; do
            POLICY_NAME="test-policy-$i"
            rlLogInfo "Policy operations cycle $i with $POLICY_NAME"

            rlRun "run_with_timeout 'keylime_tenant -c addruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $POLICY_NAME' 'Create policy $POLICY_NAME'" 0
            rlRun "run_with_timeout 'keylime_tenant -c showruntimepolicy --runtime-policy-name $POLICY_NAME' 'Read policy $POLICY_NAME'" 0
            rlRun "run_with_timeout 'keylime_tenant -c updateruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $POLICY_NAME' 'Update policy $POLICY_NAME'" 0
            rlRun "run_with_timeout 'keylime_tenant -c deleteruntimepolicy --runtime-policy-name $POLICY_NAME' 'Delete policy $POLICY_NAME'" 0
        done

        # Test measured boot policy operations
        if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
            for i in {1..3}; do
                MB_POLICY_NAME="test-mb-policy-$i"
                rlLogInfo "MB policy operations cycle $i with $MB_POLICY_NAME"

                rlRun "run_with_timeout 'keylime_tenant -c addmbpolicy --mb-policy $TESTDIR/test-mb-policy.json --mb-policy-name $MB_POLICY_NAME' 'Create MB policy $MB_POLICY_NAME'" 0
                rlRun "run_with_timeout 'keylime_tenant -c showmbpolicy --mb-policy-name $MB_POLICY_NAME' 'Read MB policy $MB_POLICY_NAME'" 0
                rlRun "run_with_timeout 'keylime_tenant -c deletembpolicy --mb-policy-name $MB_POLICY_NAME' 'Delete MB policy $MB_POLICY_NAME'" 0
            done
        fi

        # Stop verifier and analyze
        stop_verifier_valgrind
        analyze_valgrind_logs "phase-2-policy-stress"
    rlPhaseEnd

    rlPhaseStartTest "Test 3: Concurrent operations test"
        # Start fresh verifier instance for this phase
        start_verifier_valgrind "phase-3-concurrent-ops"

        rlLogInfo "Testing concurrent database operations"

        # Start agent
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Function to perform API operations
        perform_api_ops() {
            local suffix=$1
            run_with_timeout "keylime_tenant -c cvlist" "Concurrent cvlist $suffix" true
            sleep 0.1
            run_with_timeout "keylime_tenant -c status --uuid $AGENT_ID" "Concurrent status $suffix" true
        }

        # Function to perform policy operations
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
        rlLogInfo "Starting concurrent operations"
        pids=()

        for i in {1..3}; do
            perform_api_ops "$i" &
            pids+=($!)
        done

        for i in {1..3}; do
            perform_policy_ops "$i" &
            pids+=($!)
        done

        for pid in "${pids[@]}"; do
            wait "$pid"
        done

        sleep 1

        # Stop agent
        rlRun "limeStopAgent"

        # Stop verifier and analyze
        stop_verifier_valgrind
        analyze_valgrind_logs "phase-3-concurrent-ops"
    rlPhaseEnd

    rlPhaseStartTest "Test 4: Resource exhaustion recovery test"
        # Start fresh verifier instance for this phase
        start_verifier_valgrind "phase-4-resource-exhaustion"

        rlLogInfo "Testing recovery from resource exhaustion scenarios"

        # Create many policies rapidly
        policy_names=()
        create_pids=()
        for i in {1..5}; do
            POLICY_NAME="exhaust-test-policy-$i"
            policy_names+=("$POLICY_NAME")

            timeout $OPERATION_TIMEOUT keylime_tenant -c addruntimepolicy --runtime-policy "$TESTDIR/test-policy.json" --runtime-policy-name "$POLICY_NAME" >/dev/null 2>&1 &
            create_pids+=($!)
        done

        for pid in "${create_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        sleep 1

        # Verify service still functional
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-exhaustion check'" 0

        # Clean up policies
        cleanup_pids=()
        for policy_name in "${policy_names[@]}"; do
            timeout $OPERATION_TIMEOUT keylime_tenant -c deleteruntimepolicy --runtime-policy-name "$policy_name" >/dev/null 2>&1 &
            cleanup_pids+=($!)
        done

        for pid in "${cleanup_pids[@]}"; do
            wait "$pid" 2>/dev/null || true
        done

        sleep 1
        rlRun "run_with_timeout 'keylime_tenant -c cvlist' 'Post-cleanup check'" 0

        # Stop verifier and analyze
        stop_verifier_valgrind
        analyze_valgrind_logs "phase-4-resource-exhaustion"
    rlPhaseEnd

    rlPhaseStartTest "Test 5: Intensive operations test"
        # Start fresh verifier instance for this phase
        start_verifier_valgrind "phase-5-intensive-ops"

        rlLogInfo "Intensive operations to stress-test connection management"

        # Start agent
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration $AGENT_ID"

        # Intensive cycles
        for cycle in {1..3}; do
            rlLogInfo "Intensive cycle $cycle/3"

            # Rapid agent operations
            for i in {1..3}; do
                run_with_timeout "keylime_tenant -c add --uuid $AGENT_ID --file $TESTDIR/autorun.sh" "Agent add $i" true
                run_with_timeout "keylime_tenant -c status --uuid $AGENT_ID" "Agent status $i" true
                run_with_timeout "keylime_tenant -c delete --uuid $AGENT_ID" "Agent delete $i" true
                run_with_timeout "keylime_tenant -c cvlist" "Agent list $i" true
            done

            # Rapid policy operations
            for i in {1..3}; do
                test_policy="intensive-policy-$cycle-$i"
                run_with_timeout "keylime_tenant -c addruntimepolicy --runtime-policy $TESTDIR/test-policy.json --runtime-policy-name $test_policy" "Policy create $test_policy" true
                run_with_timeout "keylime_tenant -c showruntimepolicy --runtime-policy-name $test_policy" "Policy read $test_policy" true
                run_with_timeout "keylime_tenant -c deleteruntimepolicy --runtime-policy-name $test_policy" "Policy delete $test_policy" true
            done

            sleep 1
        done

        # Stop agent
        rlRun "limeStopAgent"

        # Stop verifier and analyze
        stop_verifier_valgrind
        analyze_valgrind_logs "phase-5-intensive-ops"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        # Stop services
        rlRun "limeStopRegistrar"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi

        # Final report
        rlLogInfo ""
        rlLogInfo "=== VALGRIND TEST COMPLETE ==="
        rlLogInfo "All valgrind logs saved to: $VALGRIND_BASE_DIR"
        rlLogInfo "Phases analyzed:"
        find "$VALGRIND_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | while read phase_dir; do
            rlLogInfo "  - $(basename $phase_dir)"
        done

        limeSubmitCommonLogs
        limeClearData
        # Kill any remaining valgrind processes to prevent interference with next test run
        pkill -9 -f "valgrind.*keylime_verifier" || true
        limeRestoreConfig
        limeExtendNextExcludelist "$TESTDIR"

        # Remove valgrind service unit
        rlRun "rm -f /etc/systemd/system/keylime_verifier_valgrind.service"
        rlRun "rm -rf /etc/systemd/system/keylime_verifier_valgrind.service.d"
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

rlJournalEnd
