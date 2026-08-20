#!/bin/bash
# shellcheck disable=SC2154
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Regression test for keylime/rust-keylime#1225 (see also keylime/keylime#1891).
#
# We make the swtpm emulator store an OCTET-STRING-wrapped EK certificate in
# TPM NV RAM (tag 0x04 instead of a raw DER SEQUENCE 0x30), reproducing the
# NV-RAM storage convention some hardware TPMs use. We then capture the
# registration payload the agent sends to the registrar and verify that the
# agent unwraps the OCTET STRING before sending (the ekcert on the wire must
# start with the SEQUENCE tag 0x30).

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
# The agent is pointed at PROXY_PORT; the ncat relay forwards to the real
# registrar on REGISTRAR_PORT while capturing the traffic.
PROXY_PORT="18890"
REGISTRAR_PORT="8890"

WRAPPER="/usr/local/bin/keylime-test-1225-wrap-ek-cert"
WRAPPED_CONF="/etc/swtpm_setup_wrapped_ek.conf"
SWTPM_UNIT="/etc/systemd/system/swtpm.service"

rlJournalStart

    rlPhaseStartSetup "Do the keylime and TPM setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # This test needs the swtpm emulator so that we can control how the EK
        # certificate is stored in TPM NV RAM.
        if ! limeTPMEmulated || [ "$(limeTPMEmulator)" != "swtpm" ]; then
            rlDie "This test requires the swtpm TPM emulator"
        fi
        rlAssertExists "$SWTPM_UNIT" || rlDie "swtpm systemd unit not found, run setup/configure_tpm_emulator first"

        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "pushd $TmpDir"
        CAPTURE_FILE="$TmpDir/registrar_traffic.log"
        SWTPM_UNIT_BACKUP="$TmpDir/swtpm.service.orig"

        limeBackupConfig
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        # Route agent -> registrar through our capturing ncat relay.
        rlRun "limeUpdateConf agent registrar_port ${PROXY_PORT}"
        # The (confined) agent may only connect to ports labeled keylime_port_t;
        # PROXY_PORT is non-default, so label it or SELinux blocks the agent.
        if rlIsRHEL '>=9.3' || rlIsFedora '>=38' || rlIsCentOS '>=9'; then
            rlRun "semanage port -a -t keylime_port_t -p tcp ${PROXY_PORT}"
        fi

        # --- create the create_certs_tool wrapper that OCTET-STRING-wraps ek.cert ---
        # swtpm_setup calls create_certs_tool to produce ek.cert (DER) in --dir and
        # then stores those bytes verbatim in the EK certificate NV index. Our
        # wrapper runs the real swtpm_localca and then re-encodes ek.cert wrapped
        # in an ASN.1 OCTET STRING (tag 0x04).
        cat > "$WRAPPER" <<'WRAP_EOF'
#!/bin/bash
# swtpm_setup create_certs_tool wrapper (keylime-tests rust-keylime#1225).
/usr/bin/swtpm_localca "$@"
rc=$?
[ $rc -eq 0 ] || exit $rc
dir=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
    [ "${args[i]}" = "--dir" ] && dir="${args[i+1]}"
done
cert="$dir/ek.cert"
if [ -f "$cert" ]; then
    python3 - "$cert" <<'PY'
import sys
c = sys.argv[1]
d = open(c, 'rb').read()
n = len(d)
if n < 0x80:
    length = bytes([n])
else:
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    length = bytes([0x80 | len(b)]) + b
open(c, 'wb').write(b'\x04' + length + d)
PY
fi
exit 0
WRAP_EOF
        rlRun "chmod +x $WRAPPER" 0 "Making the create_certs_tool wrapper executable"
        rlRun "restorecon -F $WRAPPER" 0,1 "Restoring SELinux context on the wrapper"
        rlAssertExists "$WRAPPER"

        # --- custom swtpm_setup config that uses our wrapper as create_certs_tool ---
        rlRun "cp /etc/swtpm_setup.conf $WRAPPED_CONF" 0 "Deriving swtpm_setup config from the system default"
        rlRun "sed -i 's#^create_certs_tool[[:space:]]*=.*#create_certs_tool = $WRAPPER#' $WRAPPED_CONF"
        if ! grep -q "^create_certs_tool = $WRAPPER" "$WRAPPED_CONF"; then
            echo "create_certs_tool = $WRAPPER" >> "$WRAPPED_CONF"
        fi
        rlAssertGrep "^create_certs_tool = $WRAPPER" "$WRAPPED_CONF"

        # --- back up and modify the swtpm systemd unit to use our config ---
        rlRun "cp $SWTPM_UNIT $SWTPM_UNIT_BACKUP" 0 "Backing up the swtpm unit file"
        rlRun "sed -i 's#/usr/bin/swtpm_setup #/usr/bin/swtpm_setup --config $WRAPPED_CONF #' $SWTPM_UNIT"
        rlAssertGrep "swtpm_setup --config $WRAPPED_CONF" "$SWTPM_UNIT"
        rlRun "systemctl daemon-reload"

        # --- (re)start the emulator so NV gets provisioned with the wrapped cert ---
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        rlRun "limeCondStartAbrmd"
        sleep 5

        # Confirm our setup worked: the EK cert now stored in NV must be
        # OCTET-STRING wrapped (starts with tag 0x04).
        rlRun "tpm2_getekcertificate -o ek_nv.der" 0 "Reading EK cert from TPM NV RAM"
        NV_FIRST_BYTE=$(od -An -tx1 -N1 ek_nv.der | tr -d ' \n')
        rlLogInfo "First byte of the EK cert stored in NV RAM: 0x${NV_FIRST_BYTE}"
        rlAssertEquals "EK cert in NV RAM must be OCTET-STRING wrapped (tag 0x04)" "$NV_FIRST_BYTE" "04"

        # The registrar's mTLS setup requires the CA dir (/var/lib/keylime/cv_ca),
        # which is created when the verifier first starts.
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Start the capturing relay in front of the registrar:
        #   agent -> ncat(PROXY_PORT) -> ncat -> registrar(REGISTRAR_PORT)
        # ncat -o records all traffic; the ekcert only ever appears in the
        # agent's registration request, so it is unambiguous to extract.
        ncat -l 127.0.0.1 "${PROXY_PORT}" --keep-open --sh-exec "ncat 127.0.0.1 ${REGISTRAR_PORT}" -o "${CAPTURE_FILE}" &
        NCAT_PID=$!
        rlRun "rlWaitForSocket ${PROXY_PORT} -t 10" 0 "Waiting for the capture relay to listen on ${PROXY_PORT}"
    rlPhaseEnd

    rlPhaseStartTest "Agent must send an unwrapped EK cert to the registrar"
        rlRun "limeStartAgent"
        # The agent should always be able to register (it does so even without
        # an EK certificate).
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # Give the captured registration payload a moment to be flushed to disk.
        rlRun "rlWaitForCmd 'grep -aq \"\\\"ekcert\\\"\" ${CAPTURE_FILE}' -m 15 -d 1 -t 3" "0,1"

        # PRIMARY CHECK (rust-keylime#1225): inspect the ekcert the agent actually
        # put on the wire. A fixed agent unwraps the OCTET STRING and sends a
        # plain X.509 certificate (SEQUENCE, tag 0x30). This single check covers
        # both known unfixed failure modes:
        #   - the agent forwards the wrapped bytes verbatim -> capture starts 0x04
        #   - the agent fails to parse the wrapped cert and sends "ekcert": null
        #     -> nothing is captured (observed with keylime-agent-rust 0.2.10)
        rlRun "grep -aoP '\"ekcert\"\s*:\s*\"\K[^\"]+' '${CAPTURE_FILE}' | head -1 > ek_sent_b64.txt" 0 "Extracting the ekcert from the captured traffic"
        if [ -s ek_sent_b64.txt ]; then
            rlLogInfo "Agent sent a non-null ekcert to the registrar"
            # remove BEGIN/END CERTIFICATE lines before doing base64 decoding
            # we could use openssl to do PEM -> DER conversion but we want to check agent payload so better
            # avoid using extra tools that could modify the content
            # First convert literal \n to actual newlines, then filter out CERTIFICATE marker lines
            rlRun "sed 's/\\\\n/\n/g' ek_sent_b64.txt | grep -v 'CERTIFICATE' | base64 -d > ek_sent.der" 0 "Decoding the ekcert sent by the agent"

            SENT_FIRST_BYTE=$(od -An -tx1 -N1 ek_sent.der | tr -d ' \n')
            rlLogInfo "First byte of the ekcert sent by the agent: 0x${SENT_FIRST_BYTE}"
            rlAssertEquals "Agent must send an unwrapped (SEQUENCE, 0x30) EK cert" "$SENT_FIRST_BYTE" "30"

            # The unwrapped cert the agent sent must be a valid X.509 certificate.
            rlRun "openssl x509 -in ek_sent.der -inform der -noout -subject" 0 "The ekcert sent by the agent is a valid X.509 certificate"
        else
            rlFail "Agent must send a (non-null) ekcert to the registrar"
        fi

        # SECONDARY DIAGNOSTIC: with the packaged agent (0.2.10) the parse failure
        # shows up as an ASN.1 "wrong tag" error in the agent log. This does not
        # apply to an agent that forwards the wrapped bytes verbatim, so it only
        # supplements the primary on-the-wire check above.
        rlAssertNotGrep "wrong tag" "$(limeAgentLogfile)" -i
        rlAssertNotGrep 'Failed to transform certificate chain' "$(limeAgentLogfile)"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        [ -n "${NCAT_PID}" ] && rlRun "kill ${NCAT_PID}" 0,1 "Stopping the capture relay"
        rlRun "pkill -f 'ncat 127.0.0.1 ${REGISTRAR_PORT}'" 0,1 "Stopping relay backend ncat processes"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"

        rlAssertNotGrep "Traceback" "$(limeRegistrarLogfile)"
        rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"

        # Restore the swtpm unit and remove our helper files so subsequent tests
        # get a normally-provisioned (non-wrapped) EK certificate again.
        if [ -f "${SWTPM_UNIT_BACKUP}" ]; then
            rlRun "cp ${SWTPM_UNIT_BACKUP} ${SWTPM_UNIT}" 0 "Restoring the original swtpm unit file"
            rlRun "systemctl daemon-reload"
        fi
        rlRun "rm -f ${WRAPPER} ${WRAPPED_CONF}"

        if rlIsRHEL '>=9.3' || rlIsFedora '>=38' || rlIsCentOS '>=9'; then
            rlRun "semanage port -d -t keylime_port_t -p tcp ${PROXY_PORT}" 0,1
        fi

        if limeTPMEmulated; then
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi

        rlFileSubmit "${CAPTURE_FILE}" registrar_traffic.log
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        rlRun "popd"
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalEnd
