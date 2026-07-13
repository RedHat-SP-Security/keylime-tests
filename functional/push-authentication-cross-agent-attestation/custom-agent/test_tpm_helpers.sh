#!/bin/bash
# Test script for TPM helper functions
# Tests all tpm_* helper functions from setup_test_agent.sh
# Usage: ./test_tpm_helpers.sh [tmpdir]
#
# This script tests compatibility with tpm2-tools 5.2 and later versions.
# Each test function exercises one tpm_* helper and reports success/failure.

set -euo pipefail

SWTPM_PID=""

################################################################################
# TPM Operation Helper Functions (from setup_test_agent.sh)
################################################################################
# These functions encapsulate tpm2-tools commands for easier maintenance.
# When tpm2-tools updates and command parameters change, only these functions
# need to be updated instead of modifying multiple places in the script.

# Check if a persistent handle exists in the TPM
# Arguments:
#   $1 - persistent_handle (e.g., 0x81010001)
# Returns: 0 if exists, 1 if not
tpm_check_persistent_handle() {
    local persistent_handle="${1}"

    if tpm2_getcap handles-persistent 2>&1 | grep -q "${persistent_handle}"; then
        return 0
    else
        return 1
    fi
}

# Evict (remove) a persistent handle from TPM
# Arguments:
#   $1 - persistent_handle (e.g., 0x81010001)
#   $2 - hierarchy (default: o=owner)
# Returns: 0 on success or if handle doesn't exist, 1 on error
tpm_evict_handle() {
    local persistent_handle="${1}"
    local hierarchy="${2:-o}"

    # Only evict if the handle exists
    if tpm_check_persistent_handle "${persistent_handle}"; then
        if ! tpm2_evictcontrol -C "${hierarchy}" -c "${persistent_handle}" 2>&1; then
            return 1
        fi
    fi
    return 0
}

# Create an Endorsement Key (EK) using standard TCG template
# Arguments:
#   $1 - output_context_file (temporary context)
#   $2 - output_public_file (EK public key)
#   $3 - algorithm (rsa or ecc, default: rsa)
# Returns: 0 on success, 1 on failure
# Note: Creates a temporary context that must be made persistent separately
tpm_create_endorsement_key() {
    local ctx_file="${1}"
    local pub_file="${2}"
    local algorithm="${3:-rsa}"

    # tpm2-tools 5.2 and 5.7 both support the same syntax for tpm2_createek
    if ! tpm2_createek -c "${ctx_file}" -G "${algorithm}" -u "${pub_file}" 2>&1; then
        return 1
    fi
    return 0
}

# Create an Attestation Key (AK) under an Endorsement Key
# Arguments:
#   $1 - ek_context (can be persistent handle like 0x81010001 or context file)
#   $2 - output_ak_context (temporary context)
#   $3 - output_ak_public
#   $4 - output_ak_name
#   $5 - algorithm (default: rsa)
#   $6 - hash (default: sha256)
#   $7 - scheme (default: rsassa)
# Returns: 0 on success, 1 on failure
tpm_create_attestation_key() {
    local ek_ctx="${1}"
    local ak_ctx="${2}"
    local ak_pub="${3}"
    local ak_name="${4}"
    local algorithm="${5:-rsa}"
    local hash="${6:-sha256}"
    local scheme="${7:-rsassa}"

    # tpm2-tools 5.2 and 5.7 both support the same syntax
    if ! tpm2_createak -C "${ek_ctx}" -c "${ak_ctx}" \
        -G "${algorithm}" -g "${hash}" -s "${scheme}" \
        -u "${ak_pub}" -n "${ak_name}" 2>&1; then
        return 1
    fi
    return 0
}

# Make a transient key persistent at a given handle
# Arguments:
#   $1 - context_file (transient context to make persistent)
#   $2 - persistent_handle (e.g., 0x81010001)
#   $3 - hierarchy (default: o=owner)
# Returns: 0 on success, 1 on failure
tpm_make_persistent() {
    local context_file="${1}"
    local persistent_handle="${2}"
    local hierarchy="${3:-o}"

    # First, evict the handle if it already exists
    tpm_evict_handle "${persistent_handle}" "${hierarchy}" || return 1

    # Make the key persistent
    # Note: In tpm2-tools 5.2, the syntax is the same as 5.7
    if ! tpm2_evictcontrol -C "${hierarchy}" -c "${context_file}" "${persistent_handle}" 2>&1; then
        return 1
    fi
    return 0
}

# Start an authorization session
# Arguments:
#   $1 - session_context_file (output session context)
#   $2 - session_type (default: policy)
# Returns: 0 on success, 1 on failure
# Version note: tpm2-tools 5.2 uses -S, 5.7 may accept both -S and --session
tpm_start_auth_session() {
    local session_file="${1}"
    local session_type="${2:-policy}"

    case "${session_type}" in
        policy)
            # Use -S for maximum compatibility with both 5.2 and 5.7
            if ! tpm2_startauthsession --policy-session -S "${session_file}" 2>&1; then
                return 1
            fi
            ;;
        hmac)
            if ! tpm2_startauthsession -S "${session_file}" 2>&1; then
                return 1
            fi
            ;;
        *)
            echo "ERROR: Unknown session type: ${session_type}" >&2
            return 1
            ;;
    esac
    return 0
}

# Apply policy secret to a policy session
# Arguments:
#   $1 - session_context_file
#   $2 - object_handle (e.g., 0x4000000B for endorsement hierarchy)
#   $3 - authorization_value (default: empty "")
# Returns: 0 on success, 1 on failure
tpm_policy_secret() {
    local session_file="${1}"
    local object_handle="${2}"
    local auth_value="${3:-}"

    # Use -S for maximum compatibility
    if ! tpm2_policysecret -S "${session_file}" -c "${object_handle}" "${auth_value}" 2>&1; then
        return 1
    fi
    return 0
}

# Flush a session context
# Arguments:
#   $1 - session_context_file
# Returns: 0 on success, 1 on failure
tpm_flush_session() {
    local session_file="${1}"

    if ! tpm2_flushcontext "${session_file}" 2>&1; then
        return 1
    fi
    return 0
}

# Generate a TPM quote
# Arguments:
#   $1 - ak_handle (attestation key handle)
#   $2 - pcr_list (e.g., "sha256:0,1,2,3,10")
#   $3 - qualifying_data (nonce/challenge)
#   $4 - quote_message_file (output)
#   $5 - quote_signature_file (output)
#   $6 - quote_pcr_file (output)
# Returns: 0 on success, 1 on failure
tpm_quote() {
    local ak_handle="${1}"
    local pcr_list="${2}"
    local qual_data="${3}"
    local msg_file="${4}"
    local sig_file="${5}"
    local pcr_file="${6}"

    # Quote command syntax is consistent between 5.2 and 5.7
    if ! tpm2_quote -c "${ak_handle}" -l "${pcr_list}" -q "${qual_data}" \
        -m "${msg_file}" -s "${sig_file}" -o "${pcr_file}" 2>&1; then
        return 1
    fi
    return 0
}

################################################################################
# SWTPM Operation Helper Functions
################################################################################

swtpm_initialize_state() {
    local state_dir="${1}"
    local pcr_banks="${2:-sha256}"

    if ! swtpm_setup --tpm2 \
        --tpmstate "${state_dir}" \
        --createek \
        --allow-signing \
        --decryption \
        --not-overwrite \
        --pcr-banks "${pcr_banks}" \
        --display &> "${state_dir}/setup.log"; then
        return 1
    fi
    return 0
}

swtpm_start_socket() {
    local state_dir="${1}"
    local socket_path="${2}"
    local log_level="${3:-20}"
    local pid_var="${4}"  # Variable name to store PID

    swtpm socket \
        --tpm2 \
        --tpmstate "dir=${state_dir}" \
        --ctrl "type=unixio,path=${socket_path}.ctrl" \
        --server "type=unixio,path=${socket_path}" \
        --flags not-need-init \
        --log "file=${state_dir}/swtpm.log,level=${log_level}" &

    local pid=$!

    # Wait for swtpm to be ready
    sleep 1

    if ! kill -0 "${pid}" 2>/dev/null; then
        return 1
    fi

    # Store PID in the variable name passed as parameter
    eval "${pid_var}=${pid}"
    return 0
}

start_swtpm() {
    local swtpm_dir="${1}"

    # Create swtpm directory
    mkdir -p "${swtpm_dir}"

    # Initialize TPM state
    if ! swtpm_initialize_state "${swtpm_dir}" "sha256"; then
        echo "ERROR: swtpm_setup failed" >&2
        cat "${swtpm_dir}/setup.log" >&2
        return 1
    fi

    # Start swtpm in socket mode
    if ! swtpm_start_socket \
        "${swtpm_dir}" \
        "${swtpm_dir}/swtpm.sock" \
        "20" \
        "SWTPM_PID"; then
        echo "ERROR: swtpm failed to start" >&2
        cat "${swtpm_dir}/swtpm.log" 2>/dev/null >&2 || true
        return 1
    fi

    # Export TCTI for tpm2-tools
    export TPM2TOOLS_TCTI="swtpm:path=${swtpm_dir}/swtpm.sock"

    return 0
}

tpm_startup() {
    if ! tpm2_startup -c &> /dev/null; then
        return 1
    fi
    return 0
}

tpm_flush_contexts() {
    local context_type="${1:-all}"  # all, transient, saved, loaded

    case "${context_type}" in
        all)
            tpm2_flushcontext -t &> /dev/null || true
            tpm2_flushcontext -s &> /dev/null || true
            tpm2_flushcontext -l &> /dev/null || true
            ;;
        transient)
            tpm2_flushcontext -t &> /dev/null || true
            ;;
        saved)
            tpm2_flushcontext -s &> /dev/null || true
            ;;
        loaded)
            tpm2_flushcontext -l &> /dev/null || true
            ;;
        *)
            echo "ERROR: Unknown context type: ${context_type}" >&2
            return 1
            ;;
    esac
}

################################################################################
# Test Functions
################################################################################

# Color output for test results
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

test_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

test_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    return 1
}

test_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

check_dependencies() {
    local missing_deps=()

    if ! command -v swtpm &> /dev/null; then
        missing_deps+=("swtpm")
    fi

    if ! command -v swtpm_setup &> /dev/null; then
        missing_deps+=("swtpm_setup")
    fi

    if ! command -v tpm2_createprimary &> /dev/null; then
        missing_deps+=("tpm2-tools")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        test_fail "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi

    return 0
}

# Cleanup function
cleanup_test_handles() {
    test_info "Cleaning up test handles..."
    tpm_evict_handle "$TEST_EK_HANDLE" "o" >/dev/null 2>&1 || true
    tpm_evict_handle "$TEST_AK_HANDLE" "o" >/dev/null 2>&1 || true

    # Stop swtpm if running
    if [[ -n "${SWTPM_PID}" ]] && kill -0 "${SWTPM_PID}" 2>/dev/null; then
        test_info "Stopping swtpm (PID: ${SWTPM_PID})..."
        kill "${SWTPM_PID}" 2>/dev/null || true
        wait "${SWTPM_PID}" 2>/dev/null || true
    fi

    # Clean up test directory
    if [[ -d "${TMPDIR}" ]]; then
        rm -rf "${TMPDIR}"
    fi
}

################################################################################
# Main Test Execution
################################################################################

# Parse arguments
TMPDIR="${1:-$(mktemp -d /tmp/tpm_test.XXXXXX)}"
mkdir -p "$TMPDIR"

test_info "TPM Helper Functions Compatibility Test"
test_info "========================================="
test_info "Temporary directory: $TMPDIR"

# Check dependencies
if ! check_dependencies; then
    exit 1
fi

# Start swtpm
test_info "Starting swtpm simulator..."
SWTPM_DIR="${TMPDIR}/swtpm"
if ! start_swtpm "$SWTPM_DIR"; then
    test_fail "Failed to start swtpm"
    exit 1
fi
test_pass "swtpm started successfully (PID: ${SWTPM_PID})"
test_info "TPM2TOOLS_TCTI=${TPM2TOOLS_TCTI}"

# Get tpm2-tools version
TPM_VERSION=$(tpm2_getcap --version 2>&1 | head -1 || echo "Unknown")
test_info "TPM2-Tools version: $TPM_VERSION"

# Run TPM startup
test_info "Running TPM2_Startup..."
if ! tpm_startup; then
    test_fail "Failed to startup TPM"
    cleanup_test_handles
    exit 1
fi
test_pass "TPM started successfully"

# Define test handles
TEST_EK_HANDLE=0x81010003
TEST_AK_HANDLE=0x81010004

# Ensure cleanup on exit
trap cleanup_test_handles EXIT

# Test counter
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

################################################################################
# Test 1: tpm_check_persistent_handle and tpm_evict_handle
################################################################################
echo ""
test_info "Test 1: tpm_check_persistent_handle and tpm_evict_handle"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Clean up first
tpm_evict_handle "$TEST_EK_HANDLE" "o" >/dev/null 2>&1 || true

if ! tpm_check_persistent_handle "$TEST_EK_HANDLE"; then
    test_pass "Handle $TEST_EK_HANDLE does not exist (as expected)"
    PASSED_TESTS=$((PASSED_TESTS + 1))
else
    test_fail "Handle $TEST_EK_HANDLE exists when it shouldn't"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test 2: tpm_create_endorsement_key
################################################################################
echo ""
test_info "Test 2: tpm_create_endorsement_key"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if tpm_create_endorsement_key \
    "$TMPDIR/test_ek.ctx" \
    "$TMPDIR/test_ek.pub" \
    "rsa" >/dev/null 2>&1; then
    if [ -f "$TMPDIR/test_ek.ctx" ] && [ -f "$TMPDIR/test_ek.pub" ]; then
        test_pass "Created EK context and public key files"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "EK creation reported success but files missing"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_fail "Failed to create EK"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test 3: tpm_make_persistent
################################################################################
echo ""
test_info "Test 3: tpm_make_persistent"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if tpm_make_persistent \
    "$TMPDIR/test_ek.ctx" \
    "$TEST_EK_HANDLE" \
    "o" >/dev/null 2>&1; then
    if tpm_check_persistent_handle "$TEST_EK_HANDLE"; then
        test_pass "Made EK persistent at handle $TEST_EK_HANDLE"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "Make persistent reported success but handle not found"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_fail "Failed to make EK persistent"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test 4: tpm_create_attestation_key
################################################################################
echo ""
test_info "Test 4: tpm_create_attestation_key"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Flush contexts before creating AK (needed to free up TPM memory)
test_info "Flushing transient contexts before AK creation..."
tpm_flush_contexts "all"

if tpm_create_attestation_key \
    "$TEST_EK_HANDLE" \
    "$TMPDIR/test_ak.ctx" \
    "$TMPDIR/test_ak.pub" \
    "$TMPDIR/test_ak.name" \
    "rsa" \
    "sha256" \
    "rsassa" >/dev/null 2>&1; then
    if [ -f "$TMPDIR/test_ak.ctx" ] && [ -f "$TMPDIR/test_ak.pub" ] && [ -f "$TMPDIR/test_ak.name" ]; then
        test_pass "Created AK under EK"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "AK creation reported success but files missing"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_fail "Failed to create AK"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test 5: Make AK persistent
################################################################################
echo ""
test_info "Test 5: Make AK persistent"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Flush contexts before making persistent
test_info "Flushing transient contexts before making AK persistent..."
tpm_flush_contexts "transient"

if tpm_make_persistent \
    "$TMPDIR/test_ak.ctx" \
    "$TEST_AK_HANDLE" \
    "o" >/dev/null 2>&1; then
    if tpm_check_persistent_handle "$TEST_AK_HANDLE"; then
        test_pass "Made AK persistent at handle $TEST_AK_HANDLE"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "Make persistent reported success but handle not found"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_fail "Failed to make AK persistent"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test 6: tpm_start_auth_session (policy)
################################################################################
echo ""
test_info "Test 6: tpm_start_auth_session (policy)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if tpm_start_auth_session \
    "$TMPDIR/session.ctx" \
    "policy" >/dev/null 2>&1; then
    if [ -f "$TMPDIR/session.ctx" ]; then
        test_pass "Started policy session"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        SESSION_STARTED=true
    else
        test_fail "Session start reported success but context file missing"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        SESSION_STARTED=false
    fi
else
    test_fail "Failed to start policy session"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    SESSION_STARTED=false
fi

################################################################################
# Test 7: tpm_policy_secret
################################################################################
echo ""
test_info "Test 7: tpm_policy_secret"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if [ "$SESSION_STARTED" = true ]; then
    if tpm_policy_secret \
        "$TMPDIR/session.ctx" \
        "0x4000000B" \
        "" >/dev/null 2>&1; then
        test_pass "Applied policy secret to session"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "Failed to apply policy secret"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_info "Skipping (session not started)"
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
fi

################################################################################
# Test 8: tpm_flush_session
################################################################################
echo ""
test_info "Test 8: tpm_flush_session"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if [ "$SESSION_STARTED" = true ]; then
    if tpm_flush_session "$TMPDIR/session.ctx" >/dev/null 2>&1; then
        test_pass "Flushed session context"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "Failed to flush session"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_info "Skipping (session not started)"
    TOTAL_TESTS=$((TOTAL_TESTS - 1))
fi

################################################################################
# Test 9: tpm_quote
################################################################################
echo ""
test_info "Test 9: tpm_quote"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

# Flush contexts before quote
test_info "Flushing transient contexts before quote..."
tpm_flush_contexts "transient"

# Create qualifying data file (tpm2_quote expects file path or hex, not string)
echo -n "test_nonce_12345" > "$TMPDIR/qualifying_data.bin"

if tpm_quote \
    "$TEST_AK_HANDLE" \
    "sha256:0,1,2,3,10" \
    "$TMPDIR/qualifying_data.bin" \
    "$TMPDIR/quote.msg" \
    "$TMPDIR/quote.sig" \
    "$TMPDIR/quote.pcrs" >/dev/null 2>&1; then
    if [ -f "$TMPDIR/quote.msg" ] && [ -f "$TMPDIR/quote.sig" ] && [ -f "$TMPDIR/quote.pcrs" ]; then
        test_pass "Generated TPM quote"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        test_fail "Quote generation reported success but files missing"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_fail "Failed to generate TPM quote"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test 10: tpm_start_auth_session (hmac)
################################################################################
echo ""
test_info "Test 10: tpm_start_auth_session (hmac)"
TOTAL_TESTS=$((TOTAL_TESTS + 1))

if tpm_start_auth_session \
    "$TMPDIR/session_hmac.ctx" \
    "hmac" >/dev/null 2>&1; then
    if [ -f "$TMPDIR/session_hmac.ctx" ]; then
        test_pass "Started HMAC session"
        PASSED_TESTS=$((PASSED_TESTS + 1))
        # Clean up
        tpm_flush_session "$TMPDIR/session_hmac.ctx" >/dev/null 2>&1 || true
    else
        test_fail "HMAC session start reported success but context file missing"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
else
    test_fail "Failed to start HMAC session"
    FAILED_TESTS=$((FAILED_TESTS + 1))
fi

################################################################################
# Test Summary
################################################################################
echo ""
test_info "========================================="
test_info "Test Summary"
test_info "========================================="
test_info "Total tests: $TOTAL_TESTS"
test_info "Passed: $PASSED_TESTS"
test_info "Failed: $FAILED_TESTS"

if [ $FAILED_TESTS -eq 0 ]; then
    test_pass "All tests passed!"
    echo ""
    test_info "TPM helper functions are compatible with your tpm2-tools version."
    exit 0
else
    test_fail "Some tests failed"
    echo ""
    test_info "Review the failures above to identify compatibility issues."
    exit 1
fi
