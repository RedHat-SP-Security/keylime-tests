#!/bin/bash
# Setup test agent - enroll agent and optionally get authentication token
# Uses TPM with persistent handles to avoid context loading errors
#
# Code Organization:
# - Helper functions for TPM operations (tpm_*) encapsulate tpm2-tools commands
# - This makes maintenance easier when tpm2-tools version changes (e.g., 5.2 vs 5.7)
# - See TEST_TPM_CERTIFY_README.md for rationale

set -e

################################################################################
# TPM Operation Helper Functions
################################################################################
# These functions encapsulate tpm2-tools commands for easier maintenance.
# When tpm2-tools updates and command parameters change, only these functions
# need to be updated instead of modifying multiple places in the script.
#
# Each function:
# - Has a clear, descriptive name indicating what TPM operation it performs
# - Takes explicit parameters rather than using global variables
# - Returns 0 on success, 1 on failure
# - Redirects stderr to caller or to /dev/null as appropriate
#
# Version compatibility notes (tpm2-tools 5.2 vs 5.7):
# - Most commands remain compatible between 5.2 and 5.7
# - Key differences may appear in:
#   * Session management (--session vs -S)
#   * Output format options (--format)
#   * Authorization syntax
################################################################################

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

# Activate credential using EK and AK
# Arguments:
#   $1 - ak_handle (attestation key handle)
#   $2 - ek_handle (endorsement key handle)
#   $3 - session_context (policy session for EK authorization)
#   $4 - credential_blob_file (input encrypted credential)
#   $5 - secret_output_file (output decrypted secret)
# Returns: 0 on success, 1 on failure
tpm_activate_credential() {
    local ak_handle="${1}"
    local ek_handle="${2}"
    local session_ctx="${3}"
    local cred_blob="${4}"
    local secret_out="${5}"

    # Session authorization syntax: session:<path>
    # This is consistent across tpm2-tools 5.2 and 5.7
    if ! tpm2_activatecredential -c "${ak_handle}" -C "${ek_handle}" \
        -P "session:${session_ctx}" \
        -i "${cred_blob}" -o "${secret_out}" 2>&1; then
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
#   $3 - qualifying_data_file (nonce/challenge file path or hex string)
#   $4 - quote_message_file (output)
#   $5 - quote_signature_file (output)
#   $6 - quote_pcr_file (output)
# Returns: 0 on success, 1 on failure
# Note: qualifying_data must be a file path or hex string (0x...), not plain text
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
# Main Script Logic
################################################################################

# Parse arguments
GET_TOKEN=false
DO_ATTESTATION=false
if [ $# -lt 4 ]; then
    echo "Usage: $0 <agent_id> <registrar_url> <verifier_url> <tmpdir> [--get-token] [--do-attestation]" >&2
    echo "Example: $0 test-agent-123 https://127.0.0.1:8891 https://127.0.0.1:8881 /tmp/test --get-token --do-attestation" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --get-token        Get authentication token (default: just enroll)" >&2
    echo "  --do-attestation   Trigger an attestation after enrollment (default: skip)" >&2
    exit 1
fi

AGENT_ID="$1"
REGISTRAR_URL="$2"
VERIFIER_URL="$3"
TMPDIR_BASE="$4"
shift 4

# Check for flags
for arg in "$@"; do
    if [ "$arg" = "--get-token" ]; then
        GET_TOKEN=true
    elif [ "$arg" = "--do-attestation" ]; then
        DO_ATTESTATION=true
    fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create agent-specific temporary directory
AGENT_TMPDIR="$TMPDIR_BASE/$AGENT_ID"
mkdir -p "$AGENT_TMPDIR"
echo "=== Agent temporary directory: $AGENT_TMPDIR ===" >&2

# Define persistent handles
EK_HANDLE=0x81010001
AK_HANDLE=0x81010002

if [ "$GET_TOKEN" = true ]; then
    echo "=== Mode: Full enrollment with authentication token ===" >&2
else
    echo "=== Mode: Enrollment without token ===" >&2
fi

echo "=== Creating EK/AK ===" >&2

# Check if handles are already in use and evict them
tpm_evict_handle "$EK_HANDLE" "o" >&2 || {
    echo "ERROR: Failed to evict EK handle" >&2
    exit 1
}

tpm_evict_handle "$AK_HANDLE" "o" >&2 || {
    echo "ERROR: Failed to evict AK handle" >&2
    exit 1
}

# Create EK using standard TCG template (temporary context)
tpm_create_endorsement_key \
    "$AGENT_TMPDIR/test_ek_tmp.ctx" \
    "$AGENT_TMPDIR/test_ek.pub" \
    "rsa" >&2 || {
    echo "ERROR: Failed to create EK" >&2
    exit 1
}

# Make EK persistent
tpm_make_persistent \
    "$AGENT_TMPDIR/test_ek_tmp.ctx" \
    "$EK_HANDLE" \
    "o" >&2 || {
    echo "ERROR: Failed to make EK persistent" >&2
    exit 1
}

# Create AK under EK (temporary context)
tpm_create_attestation_key \
    "$EK_HANDLE" \
    "$AGENT_TMPDIR/test_ak_tmp.ctx" \
    "$AGENT_TMPDIR/test_ak.pub" \
    "$AGENT_TMPDIR/test_ak.name" \
    "rsa" \
    "sha256" \
    "rsassa" >&2 || {
    echo "ERROR: Failed to create AK" >&2
    # Cleanup on failure
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    exit 1
}

# Make AK persistent
tpm_make_persistent \
    "$AGENT_TMPDIR/test_ak_tmp.ctx" \
    "$AK_HANDLE" \
    "o" >&2 || {
    echo "ERROR: Failed to make AK persistent" >&2
    # Cleanup on failure
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    exit 1
}

# Read public keys for registration
EK_PUB=$(base64 -w0 "$AGENT_TMPDIR/test_ek.pub")
AK_PUB=$(base64 -w0 "$AGENT_TMPDIR/test_ak.pub")

echo "=== Registering with registrar ===" >&2

# Register with registrar
REGISTER_RESPONSE=$(curl -sk -X POST "${REGISTRAR_URL}/v2.1/agents/${AGENT_ID}" \
    -H "Content-Type: application/json" \
    -d "{\"ek_tpm\":\"${EK_PUB}\",\"aik_tpm\":\"${AK_PUB}\"}")

# Extract challenge blob
CHALLENGE_BLOB=$(echo "$REGISTER_RESPONSE" | jq -r '.results.blob')

if [ "$CHALLENGE_BLOB" = "null" ] || [ -z "$CHALLENGE_BLOB" ]; then
    echo "ERROR: Failed to register - no challenge blob received" >&2
    echo "Response: $REGISTER_RESPONSE" >&2
    # Cleanup on failure
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
fi

echo "=== Activating credential ===" >&2

# Decode and activate credential
echo "$CHALLENGE_BLOB" | base64 -d > "$AGENT_TMPDIR/challenge.blob"

# Create policy session for EK (using persistent handle)
tpm_start_auth_session \
    "$AGENT_TMPDIR/session.ctx" \
    "policy" >&2 || {
    echo "ERROR: Failed to start auth session" >&2
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
}

# Apply policy secret for endorsement hierarchy (0x4000000B)
tpm_policy_secret \
    "$AGENT_TMPDIR/session.ctx" \
    "0x4000000B" \
    "" >&2 || {
    echo "ERROR: Failed to apply policy secret" >&2
    tpm_flush_session "$AGENT_TMPDIR/session.ctx" >&2 || true
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
}

# Activate credential using policy session for EK
tpm_activate_credential \
    "$AK_HANDLE" \
    "$EK_HANDLE" \
    "$AGENT_TMPDIR/session.ctx" \
    "$AGENT_TMPDIR/challenge.blob" \
    "$AGENT_TMPDIR/secret.txt" >&2 || {
    echo "ERROR: Failed to activate credential" >&2
    tpm_flush_session "$AGENT_TMPDIR/session.ctx" >&2 || true
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
}

# Flush session
tpm_flush_session "$AGENT_TMPDIR/session.ctx" >&2 || {
    echo "WARNING: Failed to flush session (non-fatal)" >&2
}

# Compute auth_tag as HMAC-SHA384(key=secret, message=agent_uuid)
# NOTE: The registrar stores the secret as base64 and uses that base64 string
# (not the decoded bytes) as the HMAC key. This is what crypto.do_hmac does:
#   h = hmac.new(key, msg=None, digestmod=hashlib.sha384)
# where key is self.key.encode(), and self.key is the base64 string
SECRET_RAW=$(cat "$AGENT_TMPDIR/secret.txt")
SECRET_B64=$(echo -n "$SECRET_RAW" | base64)
AUTH_TAG=$(echo -n "$AGENT_ID" | openssl dgst -sha384 -hmac "$SECRET_B64" -binary | xxd -p -c 256 | tr -d '\n')

echo "DEBUG: Secret (raw) = $SECRET_RAW" >&2
echo "DEBUG: Secret (b64) = $SECRET_B64" >&2
echo "DEBUG: Agent ID = $AGENT_ID" >&2
echo "DEBUG: AUTH_TAG = $AUTH_TAG" >&2

echo "=== Completing registration ===" >&2

# Complete registration
ACTIVATE_RESPONSE=$(curl -sk -X PUT "${REGISTRAR_URL}/v2.1/agents/${AGENT_ID}/activate" \
    -H "Content-Type: application/json" \
    -d "{\"auth_tag\":\"${AUTH_TAG}\"}")

# Check if activation succeeded (code should be 200)
ACTIVATE_CODE=$(echo "$ACTIVATE_RESPONSE" | jq -r '.code')
if [ "$ACTIVATE_CODE" != "200" ]; then
    echo "ERROR: Failed to activate credential (code: $ACTIVATE_CODE)" >&2
    echo "Response: $ACTIVATE_RESPONSE" >&2
    # Cleanup on failure
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
fi

echo "=== Enrolling agent with verifier ===" >&2

# Enroll the agent with the verifier (required for push mode)
# Extract just the hostname/IP from the VERIFIER_URL
VERIFIER_HOST=$(echo "$VERIFIER_URL" | sed -E 's|https?://([^:/]+).*|\1|')

# Use a simple accept-all policy for authentication testing
POLICY_FILE="$SCRIPT_DIR/policy.json"
if [ ! -f "$POLICY_FILE" ]; then
    echo "ERROR: Policy file not found: $POLICY_FILE" >&2
    # Cleanup on failure
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
fi

if ! keylime_tenant -v "$VERIFIER_HOST" -u "$AGENT_ID" --runtime-policy "$POLICY_FILE" -c add --push-model >&2; then
    echo "ERROR: Failed to enroll agent with verifier" >&2
    # Cleanup on failure
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
    exit 1
fi

# Only get authentication token if requested
if [ "$GET_TOKEN" = true ]; then
    echo "=== Requesting authentication challenge ===" >&2

    # Request authentication challenge
    AUTH_REQUEST=$(curl -sk -X POST "${VERIFIER_URL}/v3.0/sessions" \
        -H "Content-Type: application/vnd.api+json" \
        -d "{\"data\":{\"type\":\"session\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_supported\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\"}]}}}")

    SESSION_ID=$(echo "$AUTH_REQUEST" | jq -r '.data.id')
    CHALLENGE=$(echo "$AUTH_REQUEST" | jq -r '.data.attributes.authentication_requested[0].chosen_parameters.challenge')

    if [ "$CHALLENGE" = "null" ] || [ -z "$CHALLENGE" ]; then
        echo "ERROR: No challenge received from verifier" >&2
        echo "Response: $AUTH_REQUEST" >&2
        # Cleanup on failure
        tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
        tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
        exit 1
    fi

    echo "=== Generating TPM proof ===" >&2

    # Write challenge to file
    echo "$CHALLENGE" | base64 -d > "$AGENT_TMPDIR/auth_challenge.bin"

    # Call C++ helper - it writes raw binary files, we'll base64 encode them
    if [ ! -x "$SCRIPT_DIR/tpm_certify_simple" ]; then
        echo "ERROR: tpm_certify_simple not found or not executable" >&2
        echo "Please compile it first:" >&2
        echo "  g++ -o tpm_certify_simple tpm_certify_simple.cpp -ltss2-esys -ltss2-tctildr -ltss2-mu -std=c++11" >&2
        # Cleanup on failure
        tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
        tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
        exit 1
    fi

    # C++ writes raw binary attestation and signature to files
    if ! "$SCRIPT_DIR/tpm_certify_simple" $AK_HANDLE "$AGENT_TMPDIR/auth_challenge.bin" "$AGENT_TMPDIR/attest.bin" "$AGENT_TMPDIR/sig.bin" >&2; then
        echo "ERROR: Failed to generate TPM proof" >&2
        # Cleanup on failure
        tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
        tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
        exit 1
    fi

    # Use standard base64 command to encode the binary data
    PROOF_MESSAGE=$(base64 -w0 "$AGENT_TMPDIR/attest.bin")
    PROOF_SIGNATURE=$(base64 -w0 "$AGENT_TMPDIR/sig.bin")

    echo "=== Submitting proof and getting token ===" >&2

    # Submit proof
    AUTH_RESPONSE=$(curl -sk -X PATCH "${VERIFIER_URL}/v3.0/sessions/${SESSION_ID}" \
        -H "Content-Type: application/vnd.api+json" \
        -d "{\"data\":{\"type\":\"session\",\"id\":\"${SESSION_ID}\",\"attributes\":{\"agent_id\":\"${AGENT_ID}\",\"authentication_provided\":[{\"authentication_class\":\"pop\",\"authentication_type\":\"tpm_pop\",\"data\":{\"message\":\"${PROOF_MESSAGE}\",\"signature\":\"${PROOF_SIGNATURE}\"}}]}}}")

    EVALUATION=$(echo "$AUTH_RESPONSE" | jq -r '.data.attributes.evaluation')
    TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.data.attributes.token')

    if [ "$EVALUATION" != "pass" ]; then
        echo "ERROR: Authentication failed with evaluation: $EVALUATION" >&2
        echo "Response: $AUTH_RESPONSE" >&2
        # Cleanup on failure
        tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
        tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
        exit 1
    fi

    if [ "$TOKEN" = "null" ] || [ -z "$TOKEN" ]; then
        echo "ERROR: No token received despite passing evaluation" >&2
        echo "Response: $AUTH_RESPONSE" >&2
        # Cleanup on failure
        tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
        tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
        exit 1
    fi

    echo "=== Success! ===" >&2

    # Cleanup persistent handles
    echo "=== Cleaning up persistent handles ===" >&2
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true

    # Output token to stdout
    echo "$TOKEN"
else
    echo "=== Success (enrollment only, no token) ===" >&2

    # Cleanup persistent handles
    echo "=== Cleaning up persistent handles ===" >&2
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
fi

# Optionally generate local TPM attestation data files
# Note: This flag generates local quote files but doesn't POST them to the verifier.
# The test.sh script creates attestation records directly via curl POST to test
# cross-agent attestation access control. This flag is kept for potential future use.
if [ "$DO_ATTESTATION" = true ]; then
    echo "=== Generating local TPM quote files (not posted to verifier) ===" >&2

    # Create qualifying data file (tpm2_quote requires file path or hex)
    echo -n "test_nonce" > "$AGENT_TMPDIR/nonce.bin"

    # Generate a TPM quote (creates local files only)
    tpm_quote \
        "$AK_HANDLE" \
        "sha256:0,1,2,3,10" \
        "$AGENT_TMPDIR/nonce.bin" \
        "$AGENT_TMPDIR/quote.msg" \
        "$AGENT_TMPDIR/quote.sig" \
        "$AGENT_TMPDIR/quote.pcrs" >&2 || true

    echo "=== Local quote files generated in $AGENT_TMPDIR ===" >&2

    # Cleanup persistent handles
    tpm_evict_handle "$EK_HANDLE" "o" >&2 || true
    tpm_evict_handle "$AK_HANDLE" "o" >&2 || true
fi
