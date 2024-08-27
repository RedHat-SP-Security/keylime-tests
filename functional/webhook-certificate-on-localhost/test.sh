#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
MY_IP=127.0.0.1
HOSTNAME=$( hostname )

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "certgen/certgen"' || rlDie "cannot import openssl/certgen library"
        rlAssertRpm keylime

        #seting keylime_port_t label for ssl ports
        if rlIsRHEL '>=9.3' || rlIsFedora '>=38' || rlIsCentOS '>=9';then
            for port in 8890 8891 8892 8980 8981 8982 8983; do
                rlRun "semanage port -a -t keylime_port_t -p tcp $port" 0,1
            done
        fi

        # Create directory to store certificates and keys
        CERTDIR=/var/lib/keylime/certs
        rlRun "mkdir -p $CERTDIR"

        # Generate keys for TLS certificates
        rlRun "x509KeyGen good-ca" 0 "Generating good CA RSA key pair"
        rlRun "x509KeyGen bad-ca" 0 "Generating bad CA RSA key pair"
        rlRun "x509KeyGen intermediate-ca" 0 "Generating Intermediate CA RSA key pair"
        rlRun "x509KeyGen verifier" 0 "Generating verifier RSA key pair"
        rlRun "x509KeyGen verifier-client" 0 "Generating verifier-client RSA key pair"
        rlRun "x509KeyGen registrar" 0 "Generating registrar RSA key pair"
        rlRun "x509KeyGen tenant" 0 "Generating tenant RSA key pair"
        rlRun "x509KeyGen good-webhook" 0 "Generating webhook RSA key pair"
        rlRun "x509KeyGen bad-webhook" 0 "Generating bad webhook RSA key pair"

        # Sign good certificates for each component and the webhook
        rlRun "x509SelfSign good-ca" 0 "Selfsigning good CA certificate"
        rlRun "x509CertSign --CA good-ca --DN 'CN = ${HOSTNAME}' -t CA --subjectAltName 'IP = ${MY_IP}' intermediate-ca" 0 "Signing intermediate CA certificate with our goot CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' verifier" 0 "Signing verifier certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' verifier-client" 0 "Signing verifier-client certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' registrar" 0 "Signing registrar certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' tenant" 0 "Signing tenant certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' good-webhook" 0 "Signing webhook certificate with intermediate CA key"

        # Sign bad certificate for the webhook
        rlRun "x509SelfSign bad-ca" 0 "Selfsigning bad CA certificate"
        rlRun "x509CertSign --CA bad-ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' bad-webhook" 0 "Signing bad webhook certificate with bad CA key"

        # Copy certificates to proper location
        rlRun "cp $(x509Cert good-ca) $CERTDIR/good-cacert.pem"
        rlRun "cp $(x509Cert bad-ca) $CERTDIR/bad-cacert.pem"
        rlRun "cp $(x509Cert intermediate-ca) $CERTDIR/intermediate-cacert.pem"
        rlRun "cp $(x509Cert verifier) $CERTDIR/verifier-cert.pem"
        rlRun "cp $(x509Key verifier) $CERTDIR/verifier-key.pem"
        rlRun "cp $(x509Cert verifier-client) $CERTDIR/verifier-client-cert.pem"
        rlRun "cp $(x509Key verifier-client) $CERTDIR/verifier-client-key.pem"
        rlRun "cp $(x509Cert registrar) $CERTDIR/registrar-cert.pem"
        rlRun "cp $(x509Key registrar) $CERTDIR/registrar-key.pem"
        rlRun "cp $(x509Cert tenant) $CERTDIR/tenant-cert.pem"
        rlRun "cp $(x509Key tenant) $CERTDIR/tenant-key.pem"
        rlRun "cp $(x509Cert good-webhook) $CERTDIR/good-webhook-cert.pem"
        rlRun "cp $(x509Key good-webhook) $CERTDIR/good-webhook-key.pem"
        rlRun "cp $(x509Cert bad-webhook) $CERTDIR/bad-webhook-cert.pem"
        rlRun "cp $(x509Key bad-webhook) $CERTDIR/bad-webhook-key.pem"
        # assign cert ownership to keylime user if it exists
        id keylime && rlRun "chown -R keylime:keylime $CERTDIR"

        # update /etc/keylime.conf
        limeBackupConfig

        # verifier
        rlRun "limeUpdateConf verifier check_client_cert True"
        rlRun "limeUpdateConf verifier tls_dir $CERTDIR"
        rlRun "limeUpdateConf verifier trusted_server_ca '[\"intermediate-cacert.pem\", \"good-cacert.pem\"]'"
        rlRun "limeUpdateConf verifier trusted_client_ca '[\"intermediate-cacert.pem\", \"good-cacert.pem\"]'"
        rlRun "limeUpdateConf verifier server_cert verifier-cert.pem"
        rlRun "limeUpdateConf verifier server_key verifier-key.pem"
        rlRun "limeUpdateConf verifier client_cert ${CERTDIR}/verifier-client-cert.pem"
        rlRun "limeUpdateConf verifier client_key ${CERTDIR}/verifier-client-key.pem"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"agent\", \"webhook\"]'"
        rlRun "limeUpdateConf agent enable_revocation_notifications true"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant tls_dir $CERTDIR"
        rlRun "limeUpdateConf tenant trusted_server_ca '[\"intermediate-cacert.pem\", \"good-cacert.pem\"]'"
        rlRun "limeUpdateConf tenant client_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant client_key tenant-key.pem"
        # registrar
        rlRun "limeUpdateConf registrar check_client_cert True"
        rlRun "limeUpdateConf registrar tls_dir $CERTDIR"
        rlRun "limeUpdateConf registrar trusted_client_ca '[\"intermediate-cacert.pem\", \"good-cacert.pem\"]'"
        rlRun "limeUpdateConf registrar server_cert registrar-cert.pem"
        rlRun "limeUpdateConf registrar server_key registrar-key.pem"
        # agent
        rlRun "limeUpdateConf agent trusted_client_ca '\"['${CERTDIR}/intermediate-cacert.pem', '${CERTDIR}/good-cacert.pem']\"'"
        rlRun "limeUpdateConf agent server_key '\"agent-key.pem\"'"
        rlRun "limeUpdateConf agent server_cert '\"agent-cert.pem\"'"
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    for i in "good-webhook good 8980 none" "bad-webhook bad 8981 CERTIFICATE_VERIFY_FAILED" "none bad 8982 SSLError" "installed good 8983 none"; do
        read -r WEBHOOK EXPECTED_RESULT WEBHOOK_SERVER_PORT EXPECTED_ERROR <<< "${i}"

        # This case is to test that the verifier is including the system-wide
        # installed certificates when verifying the revocation notification
        # webhook certificate
        if [ "${WEBHOOK}" = "installed" ]; then
            rlPhaseStartTest "Install CA certificate on system-wide store, and run on port ${WEBHOOK_SERVER_PORT}"
                rlRun "limeUpdateConf revocations webhook_url https://localhost:${WEBHOOK_SERVER_PORT}"
                # Install the "bad" CA certificate on system-wide trust store
                rlRun "cp $(x509Cert bad-ca) /etc/pki/ca-trust/source/anchors/webhook-ca.crt"
                rlRun "update-ca-trust"
                # Use the "bad" revocation notification webhook certificate
                WEBHOOK="bad-webhook"
            rlPhaseEnd
        fi

        rlPhaseStartTest "Start webhook with '${WEBHOOK}' certificate on port ${WEBHOOK_SERVER_PORT}"
            # Configure webhook URL and start verifier
            rlRun "limeUpdateConf revocations webhook_url https://localhost:${WEBHOOK_SERVER_PORT}"
            rlRun "limeStartVerifier"
            rlRun "limeWaitForVerifier"
            WEBHOOK_SERVER_LOG=$( mktemp )
            # Start revocation notifier webhook server using openssl s_server
            if [ "${WEBHOOK}" = "none" ]; then
                rlRun "sleep 500 | openssl s_server -debug -nocert -port ${WEBHOOK_SERVER_PORT} &> ${WEBHOOK_SERVER_LOG} &"
                WEBHOOK_SERVER_PID=$!
            else
                rlRun "sleep 500 | openssl s_server -debug -cert $(x509Cert "${WEBHOOK}") -key $(x509Key "${WEBHOOK}") -port ${WEBHOOK_SERVER_PORT} &> ${WEBHOOK_SERVER_LOG} &"
                WEBHOOK_SERVER_PID=$!
            fi
        rlPhaseEnd

        rlPhaseStartTest "Add keylime agent (WEBHOOK=${WEBHOOK})"
            rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --include payload-script --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
            rlRun "expect script.expect"
            rlRun "limeWaitForAgentStatus '$AGENT_ID' 'Get Quote'"
            rlRun -s "keylime_tenant -c cvlist"
            rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
            rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
            ls -l /var/tmp/test_payload_file
            rlAssertExists /var/tmp/test_payload_file
        rlPhaseEnd

        rlPhaseStartTest "Fail keylime agent (WEBHOOK=${WEBHOOK})"
            TESTDIR=$(limeCreateTestDir)
            rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
            rlRun "$TESTDIR/keylime-bad-script.sh"
            rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
            rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/keylime-bad-script.sh" "$(limeVerifierLogfile)"
            rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" "$(limeVerifierLogfile)"
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
            if [ "${EXPECTED_RESULT}" = "bad" ]; then
                # We expect the verifier was not successful to connect to the
                # webhook. The webhook should not receive the notification.
                rlAssertGrep "Sending revocation event via webhook to https://localhost:${WEBHOOK_SERVER_PORT}" "$(limeVerifierLogfile)"
                rlAssertGrep "requests.exceptions.SSLError: HTTPSConnectionPool\(host='localhost', port=${WEBHOOK_SERVER_PORT}.*${EXPECTED_ERROR}" "$(limeVerifierLogfile)" -E || (cat "$(limeVerifierLogfile)" && cat "${WEBHOOK_SERVER_LOG}")
                rlAssertNotGrep "\\\\\"type\\\\\": \\\\\"revocation\\\\\", \\\\\"ip\\\\\": \\\\\"127.0.0.1\\\\\", \\\\\"agent_id\\\\\": \\\\\"${AGENT_ID}\\\\\"" "${WEBHOOK_SERVER_LOG}" -i
            else
                # We expect the verifier was successful connecting to the
                # webhook
                rlAssertGrep "\\\\\"type\\\\\": \\\\\"revocation\\\\\", \\\\\"ip\\\\\": \\\\\"127.0.0.1\\\\\", \\\\\"agent_id\\\\\": \\\\\"${AGENT_ID}\\\\\"" "${WEBHOOK_SERVER_LOG}" -i
                rlAssertNotGrep ERROR "${WEBHOOK_SERVER_LOG}" -i
            fi
        rlPhaseEnd

        rlPhaseStartTest "Stop webhook server and cleanup agent (WEBHOOK=${WEBHOOK})"
            rlRun "keylime_tenant -u $AGENT_ID -c delete"
            sleep 3
            rlRun -s "keylime_tenant -c cvlist"
            rlAssertNotGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "${rlRun_LOG}" -E
            rlRun "kill ${WEBHOOK_SERVER_PID}"
            rlRun "pkill -f 'sleep 500'"
            rlRun "rm ${WEBHOOK_SERVER_LOG}"
            rlRun "limeStopVerifier"
            # Update the policy to exclude the generated files from this
            # iteration to not affect the next
            limeExtendNextExcludelist "$TESTDIR"
            limeCreateTestPolicy
        rlPhaseEnd
    done

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "rm -f /var/tmp/test_payload_file"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
	# gather more logs
	dmesg > dmesg.log
	journalctl -b > journalctl_b.log
	journalctl --header > journalctl_header.txt
	ls -l /run/log/journal > ls_l_run_log_journal.txt
	systemctl status systemd-journald.service > systemctl_status_journald.txt
	rlBundleLogs journal_logs dmesg.log journalctl_b.log journalctl_header.txt ls_l_run_log_journal.txt systemctl_status_journald.tx
        # Cleanup the trust store
        rlRun "rm /etc/pki/ca-trust/source/anchors/webhook-ca.crt"
        rlRun "update-ca-trust"
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
