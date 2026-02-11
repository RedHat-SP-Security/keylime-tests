#!/bin/bash
# Standalone test for tpm_certify_simple program
#
# This test script:
# - Automatically starts and manages its own swtpm instance
# - Creates necessary TPM keys (EK and AK)
# - Tests the tpm_certify_simple C++ program
# - Runs error handling tests
# - Cleans up all resources automatically
#
# Code Organization:
# - Helper functions for TPM operations (tpm_*) encapsulate tpm2-tools commands
# - Helper functions for swtpm operations (swtpm_*) encapsulate swtpm commands
# - This makes maintenance easier when command-line tools update
# - See TEST_TPM_CERTIFY_README.md for details

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use /tmp for swtpm to avoid Unix socket path length limits
TEST_DIR="$(mktemp -d /tmp/tpm_certify_test.XXXXXX)"
PROGRAM="${SCRIPT_DIR}/tpm_certify_simple"
SWTPM_DIR="${TEST_DIR}/swtpm"
SWTPM_PID=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

cleanup() {
    # Stop swtpm if running
    if [[ -n "${SWTPM_PID}" ]] && kill -0 "${SWTPM_PID}" 2>/dev/null; then
        log_info "Stopping swtpm (PID: ${SWTPM_PID})..."
        kill "${SWTPM_PID}" 2>/dev/null || true
        wait "${SWTPM_PID}" 2>/dev/null || true
    fi

    # Clean up test directory
    if [[ -d "${TEST_DIR}" ]]; then
        rm -rf "${TEST_DIR}"
        log_info "Cleaned up test directory"
    fi
}

compile_program() {
    log_info "Compiling tpm_certify_simple..."
    cd "${SCRIPT_DIR}"
    if make clean &> /dev/null && make &> /dev/null; then
        log_info "Compilation successful"
    else
        log_error "Compilation failed"
        make clean &> /dev/null
        return 1
    fi
}

check_dependencies() {
    log_info "Checking dependencies..."

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
        log_error "Missing required dependencies: ${missing_deps[*]}"
        return 1
    fi

    log_info "All dependencies found"
    return 0
}

################################################################################
# TPM Operation Helper Functions
################################################################################
# These functions encapsulate tpm2-tools commands for easier maintenance.
# When tpm2-tools updates and command parameters change, only these functions
# need to be updated instead of modifying multiple places in the test code.
#
# Each function:
# - Has a clear, descriptive name indicating what TPM operation it performs
# - Takes explicit parameters rather than using global variables
# - Returns 0 on success, 1 on failure
# - Writes detailed logs to specified log files for debugging
################################################################################

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
            log_error "Unknown context type: ${context_type}"
            return 1
            ;;
    esac
}

tpm_startup() {
    local logfile="${1}"

    if ! tpm2_startup -c &> "${logfile}"; then
        return 1
    fi
    return 0
}

tpm_create_endorsement_key() {
    local ctx_file="${1}"
    local pub_file="${2}"
    local logfile="${3}"
    local algorithm="${4:-rsa}"  # rsa or ecc

    if ! tpm2_createek -c "${ctx_file}" -G "${algorithm}" -u "${pub_file}" \
        &> "${logfile}"; then
        return 1
    fi
    return 0
}

tpm_create_attestation_key() {
    local ek_ctx="${1}"
    local ak_ctx="${2}"
    local ak_pub="${3}"
    local ak_name="${4}"
    local logfile="${5}"
    local algorithm="${6:-rsa}"
    local hash="${7:-sha256}"
    local scheme="${8:-rsassa}"

    if ! tpm2_createak -C "${ek_ctx}" -c "${ak_ctx}" \
        -G "${algorithm}" -g "${hash}" -s "${scheme}" \
        -u "${ak_pub}" -n "${ak_name}" \
        &> "${logfile}"; then
        return 1
    fi
    return 0
}

tpm_make_persistent() {
    local context_file="${1}"
    local persistent_handle="${2}"
    local logfile="${3}"
    local hierarchy="${4:-o}"  # o=owner, p=platform, e=endorsement

    # First, try to clear the handle if it exists
    tpm2_evictcontrol -C "${hierarchy}" -c "${persistent_handle}" &> /dev/null || true

    if ! tpm2_evictcontrol -C "${hierarchy}" -c "${context_file}" "${persistent_handle}" \
        &> "${logfile}"; then
        return 1
    fi
    return 0
}

tpm_verify_persistent_handle() {
    local persistent_handle="${1}"
    local logfile="${2}"

    if ! tpm2_readpublic -c "${persistent_handle}" &> "${logfile}"; then
        return 1
    fi
    return 0
}

################################################################################
# SWTPM Operation Helper Functions
################################################################################
# These functions encapsulate swtpm/swtpm_setup commands for easier maintenance.
# When swtpm tools update, only these functions need to be modified.
################################################################################

swtpm_initialize_state() {
    local state_dir="${1}"
    local logfile="${2}"
    local pcr_banks="${3:-sha256}"

    if ! swtpm_setup --tpm2 \
        --tpmstate "${state_dir}" \
        --createek \
        --allow-signing \
        --decryption \
        --not-overwrite \
        --pcr-banks "${pcr_banks}" \
        --display &> "${logfile}"; then
        return 1
    fi
    return 0
}

swtpm_start_socket() {
    local state_dir="${1}"
    local socket_path="${2}"
    local logfile="${3}"
    local log_level="${4:-20}"
    local pid_var="${5}"  # Variable name to store PID

    swtpm socket \
        --tpm2 \
        --tpmstate "dir=${state_dir}" \
        --ctrl "type=unixio,path=${socket_path}.ctrl" \
        --server "type=unixio,path=${socket_path}" \
        --flags not-need-init \
        --log "file=${logfile},level=${log_level}" &

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
    log_info "Starting swtpm simulator..."

    # Create swtpm directory
    mkdir -p "${SWTPM_DIR}"

    # Initialize TPM state (skip cert creation to avoid permission issues)
    log_info "Initializing TPM state with swtpm_setup..."
    if ! swtpm_initialize_state \
        "${SWTPM_DIR}" \
        "${SWTPM_DIR}/setup.log" \
        "sha256"; then
        log_error "swtpm_setup failed. Log:"
        cat "${SWTPM_DIR}/setup.log"
        return 1
    fi

    # Start swtpm in socket mode
    log_info "Starting swtpm in socket mode..."
    if ! swtpm_start_socket \
        "${SWTPM_DIR}" \
        "${SWTPM_DIR}/swtpm.sock" \
        "${SWTPM_DIR}/swtpm.log" \
        "20" \
        "SWTPM_PID"; then
        log_error "swtpm failed to start. Log:"
        cat "${SWTPM_DIR}/swtpm.log" 2>/dev/null || echo "No log available"
        return 1
    fi

    # Export TCTI for tpm2-tools and our program
    export TPM2TOOLS_TCTI="swtpm:path=${SWTPM_DIR}/swtpm.sock"

    log_info "swtpm started successfully (PID: ${SWTPM_PID})"
    log_info "TPM2TOOLS_TCTI=${TPM2TOOLS_TCTI}"

    return 0
}

create_test_ak() {
    log_info "Creating test Attestation Key (AK)..."

    # Set the handle we'll use
    AK_HANDLE="0x81010002"

    # Initialize the TPM with startup
    log_info "Running TPM2_Startup..."
    if ! tpm_startup "${SWTPM_DIR}/startup.log"; then
        log_error "Failed to startup TPM. Log:"
        cat "${SWTPM_DIR}/startup.log"
        return 1
    fi

    # Create EK (Endorsement Key) first
    log_info "Creating Endorsement Key..."
    if ! tpm_create_endorsement_key \
        "${SWTPM_DIR}/ek.ctx" \
        "${SWTPM_DIR}/ek.pub" \
        "${SWTPM_DIR}/createek.log" \
        "rsa"; then
        log_error "Failed to create EK. Log:"
        cat "${SWTPM_DIR}/createek.log"
        return 1
    fi

    # Flush all contexts before creating AK to free memory
    log_info "Flushing all contexts..."
    tpm_flush_contexts "all"

    # Create AK (Attestation Key) as a child of EK
    log_info "Creating Attestation Key..."
    if ! tpm_create_attestation_key \
        "${SWTPM_DIR}/ek.ctx" \
        "${SWTPM_DIR}/ak.ctx" \
        "${SWTPM_DIR}/ak.pub" \
        "${SWTPM_DIR}/ak.name" \
        "${SWTPM_DIR}/createak.log" \
        "rsa" \
        "sha256" \
        "rsassa"; then
        log_error "Failed to create AK. Log:"
        cat "${SWTPM_DIR}/createak.log"
        return 1
    fi

    # Flush transient contexts before making persistent
    log_info "Flushing transient contexts..."
    tpm_flush_contexts "transient"

    # Make AK persistent at handle
    log_info "Making AK persistent at handle ${AK_HANDLE}..."
    if ! tpm_make_persistent \
        "${SWTPM_DIR}/ak.ctx" \
        "${AK_HANDLE}" \
        "${SWTPM_DIR}/evictcontrol.log" \
        "o"; then
        log_error "Failed to make AK persistent. Log:"
        cat "${SWTPM_DIR}/evictcontrol.log"
        return 1
    fi

    # Flush transient contexts to free up memory
    log_info "Flushing transient contexts..."
    tpm_flush_contexts "transient"

    # Verify the handle exists
    log_info "Verifying AK at handle ${AK_HANDLE}..."
    if ! tpm_verify_persistent_handle \
        "${AK_HANDLE}" \
        "${SWTPM_DIR}/readpublic.log"; then
        log_error "Failed to read AK public area. Log:"
        cat "${SWTPM_DIR}/readpublic.log"
        return 1
    fi

    log_info "AK created successfully at handle ${AK_HANDLE}"
    return 0
}

run_basic_test() {
    log_info "Running basic test..."

    # Create test directory
    mkdir -p "${TEST_DIR}"

    # Create a challenge file with random data
    CHALLENGE_FILE="${TEST_DIR}/challenge.bin"
    ATTEST_OUT="${TEST_DIR}/attest.bin"
    SIG_OUT="${TEST_DIR}/sig.bin"

    log_info "Creating challenge file..."
    dd if=/dev/urandom of="${CHALLENGE_FILE}" bs=32 count=1 2>/dev/null

    local challenge_size
    challenge_size=$(stat -c%s "${CHALLENGE_FILE}")
    log_info "Challenge file created: ${challenge_size} bytes"

    # Run the program
    log_info "Running tpm_certify_simple with handle ${AK_HANDLE}..."
    if "${PROGRAM}" "${AK_HANDLE}" "${CHALLENGE_FILE}" "${ATTEST_OUT}" "${SIG_OUT}"; then
        log_info "Program executed successfully"
    else
        log_error "Program execution failed"
        return 1
    fi

    # Verify outputs exist
    if [[ ! -f "${ATTEST_OUT}" ]]; then
        log_error "Attestation output file not created"
        return 1
    fi

    if [[ ! -f "${SIG_OUT}" ]]; then
        log_error "Signature output file not created"
        return 1
    fi

    local attest_size sig_size
    attest_size=$(stat -c%s "${ATTEST_OUT}")
    sig_size=$(stat -c%s "${SIG_OUT}")

    log_info "Attestation file: ${attest_size} bytes"
    log_info "Signature file: ${sig_size} bytes"

    # Basic sanity checks
    if [[ ${attest_size} -eq 0 ]]; then
        log_error "Attestation file is empty"
        return 1
    fi

    if [[ ${sig_size} -eq 0 ]]; then
        log_error "Signature file is empty"
        return 1
    fi

    # Attestation data should be reasonable size (typically 100-300 bytes)
    if [[ ${attest_size} -lt 50 ]] || [[ ${attest_size} -gt 1000 ]]; then
        log_warn "Attestation size seems unusual: ${attest_size} bytes"
    fi

    # Signature should be reasonable size (typically 100-400 bytes for RSA/ECC)
    if [[ ${sig_size} -lt 50 ]] || [[ ${sig_size} -gt 1000 ]]; then
        log_warn "Signature size seems unusual: ${sig_size} bytes"
    fi

    log_info "Output files look reasonable"
    return 0
}

run_error_test() {
    log_info "Running error handling tests..."

    mkdir -p "${TEST_DIR}"

    # Test 1: Invalid number of arguments
    log_info "Test: Invalid number of arguments..."
    if "${PROGRAM}" 2>/dev/null; then
        log_error "Should have failed with no arguments"
        return 1
    else
        log_info "Correctly rejected invalid arguments"
    fi

    # Test 2: Non-existent challenge file
    log_info "Test: Non-existent challenge file..."
    if "${PROGRAM}" "${AK_HANDLE}" "/nonexistent/file.bin" \
        "${TEST_DIR}/out1.bin" "${TEST_DIR}/out2.bin" 2>/dev/null; then
        log_error "Should have failed with non-existent file"
        return 1
    else
        log_info "Correctly rejected non-existent challenge file"
    fi

    # Test 3: Invalid handle
    log_info "Test: Invalid handle..."
    echo "test" > "${TEST_DIR}/challenge.bin"
    if "${PROGRAM}" "0x99999999" "${TEST_DIR}/challenge.bin" \
        "${TEST_DIR}/out1.bin" "${TEST_DIR}/out2.bin" 2>/dev/null; then
        log_error "Should have failed with invalid handle"
        return 1
    else
        log_info "Correctly rejected invalid handle"
    fi

    log_info "Error handling tests passed"
    return 0
}

main() {
    log_info "Starting tpm_certify_simple test suite"
    log_info "========================================"

    # Check dependencies
    if ! check_dependencies; then
        log_error "Test failed: missing dependencies"
        exit 1
    fi

    # Compile the program
    if ! compile_program; then
        log_error "Test failed: compilation error"
        exit 1
    fi

    # Start swtpm
    if ! start_swtpm; then
        log_error "Test failed: swtpm start failed"
        exit 1
    fi

    # Create test AK
    if ! create_test_ak; then
        log_error "Test failed: AK creation failed"
        exit 1
    fi

    # Run tests
    local test_failed=0

    if ! run_basic_test; then
        log_error "Basic test failed"
        test_failed=1
    fi

    if ! run_error_test; then
        log_error "Error handling test failed"
        test_failed=1
    fi

    # Cleanup
    cleanup

    if [[ ${test_failed} -eq 0 ]]; then
        log_info "========================================"
        log_info "All tests PASSED"
        exit 0
    else
        log_error "========================================"
        log_error "Some tests FAILED"
        exit 1
    fi
}

# Trap to ensure cleanup on exit
trap cleanup EXIT

main "$@"
