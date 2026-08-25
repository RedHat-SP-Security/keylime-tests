#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# shellcheck disable=SC2154
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID_CONTROL="d432fbb3-d2f1-4a97-9ef7-75bd81c00003"
AGENT_ID_WRAPPED="d432fbb3-d2f1-4a97-9ef7-75bd81c00004"
REGISTRAR_HTTP_PORT="8890"

# Completes registration for an agent that was registered directly via curl
# (bypassing the real agent binary): decrypts the registrar's challenge
# using the shared EK/AK, computes the auth_tag and PUTs it back, exactly
# like a real agent would during activation.
complete_registration() {
    local agent_id="$1"
    local response_file="$2"

    local blob
    blob=$(jq -r '.results.blob' "${response_file}")
    [ "${blob}" != "null" ] && [ -n "${blob}" ] || rlDie "No challenge blob received for agent ${agent_id}"
    echo "${blob}" | base64 -d > "${agent_id}.blob"

    rlRun "tpm2_startauthsession --policy-session -S ${agent_id}.session"
    rlRun "tpm2_policysecret -S ${agent_id}.session -c 0x4000000B ''"
    rlRun "tpm2_activatecredential -c ak.ctx -C ek.handle -P session:${agent_id}.session -i ${agent_id}.blob -o ${agent_id}.secret"
    rlRun "tpm2_flushcontext ${agent_id}.session"

    local secret_raw secret_b64 auth_tag
    secret_raw=$(cat "${agent_id}.secret")
    secret_b64=$(echo -n "${secret_raw}" | base64)
    auth_tag=$(echo -n "${agent_id}" | openssl dgst -sha384 -hmac "${secret_b64}" | awk '{print $NF}')

    rlRun "jq -n --arg auth_tag \"${auth_tag}\" '{auth_tag: \$auth_tag}' > ${agent_id}_activate_payload.json"
    rlRun -s "curl -sS -w '\n%{http_code}' -X PUT http://127.0.0.1:${REGISTRAR_HTTP_PORT}/v2.1/agents/${agent_id}/activate \
        -H 'Content-Type: application/json' -d @${agent_id}_activate_payload.json"
    local activate_http_code
    activate_http_code=$(tail -n1 "$rlRun_LOG")
    rlAssertEquals "Activation PUT for ${agent_id} should return 200" "${activate_http_code}" "200"
}

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"

        limeBackupConfig
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"

        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
        fi
        sleep 5
        # Starting the verifier isn't needed for what this test checks, but
        # the registrar's mTLS setup requires the CA dir (/var/lib/keylime/cv_ca)
        # to already exist, which is created when the verifier first starts.
        # Without this, the registrar crashes on startup (tls_dir does not exist).
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
    rlPhaseEnd

    rlPhaseStartTest "Obtain real TPM identity material and craft the OCTET-STRING-wrapped EK cert"
        # Real EK certificate straight from the (emulated) TPM, in DER format.
        rlRun "tpm2_getekcertificate -o ek_cert.der"
        rlRun "tpm2_createek -c ek.handle -G rsa -u ek.pub"
        rlRun "tpm2_createak -C ek.handle -c ak.ctx -u ak.pub -n ak.name"

        # Wrap the DER EK cert in an ASN.1 OCTET STRING (tag 0x04). This is the
        # NV-RAM storage convention some hardware TPMs use (see keylime#1891)
        # that the registrar currently fails to unwrap before parsing.
        rlRun "python3 -c \"
from pyasn1.codec.der import encoder
from pyasn1.type import univ
data = open('ek_cert.der', 'rb').read()
open('ek_cert_wrapped.der', 'wb').write(encoder.encode(univ.OctetString(data)))
\""
        ORIG_SIZE=$(stat -c%s ek_cert.der)
        WRAPPED_SIZE=$(stat -c%s ek_cert_wrapped.der)
        rlRun "[ ${WRAPPED_SIZE} -gt ${ORIG_SIZE} ]" 0 "Wrapped cert (${WRAPPED_SIZE}B) should be larger than the original (${ORIG_SIZE}B)"

        rlRun "jq -n --arg ek_tpm \"\$(base64 -w0 ek.pub)\" --arg aik_tpm \"\$(base64 -w0 ak.pub)\" --arg ekcert \"\$(base64 -w0 ek_cert.der)\" \
            '{ek_tpm: \$ek_tpm, aik_tpm: \$aik_tpm, ekcert: \$ekcert}' > control_payload.json"
        rlRun "jq -n --arg ek_tpm \"\$(base64 -w0 ek.pub)\" --arg aik_tpm \"\$(base64 -w0 ak.pub)\" --arg ekcert \"\$(base64 -w0 ek_cert_wrapped.der)\" \
            '{ek_tpm: \$ek_tpm, aik_tpm: \$aik_tpm, ekcert: \$ekcert}' > wrapped_payload.json"
    rlPhaseEnd

    rlPhaseStartTest "Control: registrar accepts and completes registration for the EK cert as-is (not wrapped)"
        rlRun -s "curl -sS -w '\n%{http_code}' -X POST http://127.0.0.1:${REGISTRAR_HTTP_PORT}/v2.1/agents/${AGENT_ID_CONTROL} \
            -H 'Content-Type: application/json' -d @control_payload.json"
        CONTROL_HTTP_CODE=$(tail -n1 "$rlRun_LOG")
        head -n -1 "$rlRun_LOG" > control_register_response.json
        rlLogInfo "Control response body: $(cat control_register_response.json)"
        rlAssertEquals "Control: registrar should accept the properly-encoded EK cert" "${CONTROL_HTTP_CODE}" "200"

        complete_registration "${AGENT_ID_CONTROL}" control_register_response.json
        rlRun "limeWaitForAgentRegistration ${AGENT_ID_CONTROL}" 0 "Control agent should complete registration and reach the Registered state"
    rlPhaseEnd

    rlPhaseStartTest "Registrar should accept the OCTET-STRING-wrapped EK cert and complete registration (keylime#1891)"
        rlRun -s "curl -sS -w '\n%{http_code}' -X POST http://127.0.0.1:${REGISTRAR_HTTP_PORT}/v2.1/agents/${AGENT_ID_WRAPPED} \
            -H 'Content-Type: application/json' -d @wrapped_payload.json"
        WRAPPED_HTTP_CODE=$(tail -n1 "$rlRun_LOG")
        head -n -1 "$rlRun_LOG" > wrapped_register_response.json
        rlLogInfo "Wrapped response body: $(cat wrapped_register_response.json)"
        # This is the actual bug (keylime#1891): the registrar currently
        # rejects a cert that's validly stored per the TCG EK Credential
        # Profile NV RAM convention, just because it's OCTET-STRING-wrapped.
        # Once cert_utils.x509_der_cert() / certificate.py's _load_der_cert()
        # unwrap OCTET STRING before parsing, this should return 200, like
        # the control case above.
        rlAssertEquals "Registrar should accept OCTET-STRING-wrapped EK cert" "${WRAPPED_HTTP_CODE}" "200"

        complete_registration "${AGENT_ID_WRAPPED}" wrapped_register_response.json
        rlRun "limeWaitForAgentRegistration ${AGENT_ID_WRAPPED}" 0 "Registration should genuinely complete (not just the initial POST) for the OCTET-STRING-wrapped EK cert"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeCondStopAbrmd"
            rlRun "limeStopTPMEmulator"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalEnd
