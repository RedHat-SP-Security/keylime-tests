#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -n "${AGENT_SERVICE}" ] || AGENT_SERVICE=Agent  # or PushAgent
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model"
VERIFIER_PORT=8881
REGISTRAR_HTTP_PORT="8890"
REGISTRAR_HTTPS_PORT="8891"
[ -n "${API_VERSION}" ] || API_VERSION=2.4

GOOD_CERTS="-cert /var/lib/keylime/cv_ca/client-cert.crt -key /var/lib/keylime/cv_ca/client-private.pem -CAfile /var/lib/keylime/cv_ca/cacert.crt"
BAD_CERTS="-cert /var/lib/keylime/server-cert.crt -key /var/lib/keylime/server-private.pem -CAfile /var/lib/keylime/cv_ca/cacert.crt"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
	# ca configuration
        rlRun "limeUpdateConf ca password keylime"
	rlRun "rm -f /var/lib/keylime/cv_ca/*"
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        # configure push attestation
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            # Set the verifier to run in PUSH mode
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier quote_interval 10"
            rlRun "limeUpdateConf agent attestation_interval_seconds 10"
        fi
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
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        rlRun "rm -f /var/lib/keylime/server-cert.crt /var/lib/keylime/server-private.pem"
        # just in case it would be ever needed, this way we can generate trusted certificates for the agent
        #rlRun "keylime_ca -c create -n '${AGENT_ID}' -d /var/lib/keylime/cv_ca"
        #rlRun "cp /var/lib/keylime/cv_ca/${AGENT_ID}-cert.crt /var/lib/keylime/server-cert.crt"
        #rlRun "cp /var/lib/keylime/cv_ca/${AGENT_ID}-private.pem /var/lib/keylime/server-private.pem"
        #rlRun "chown keylime:keylime /var/lib/keylime/server-{cert.crt,private.pem}"

        rlRun "limeStart${AGENT_SERVICE}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy"
        # Add keylime agent"
        rlRun "keylime_tenant -u $AGENT_ID --runtime-policy policy.json -c add --file /etc/hostname ${TENANT_ARGS}"
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID PASS" 0,1
        # push agent won't generate the cert so we need to do it on our own
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlAssertNotExists /var/lib/keylime/server-cert.crt
            rlAssertNotExists /var/lib/keylime/server-private.pem
            rlRun 'openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes -keyout /var/lib/keylime/server-private.pem -out /var/lib/keylime/server-cert.crt -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"'
        fi
    rlPhaseEnd

    rlPhaseStartTest "Try to open TLS connection to the verifier on port ${VERIFIER_PORT} using agent's self-signed mTLS cert"
        rlRun "openssl x509 -text -in /var/lib/keylime/cv_ca/client-cert.crt"
        # use sleep to ensure that it won't be client closing the connection too early
        rlRun "sleep 1 | openssl s_client -connect 127.0.0.1:${VERIFIER_PORT} ${GOOD_CERTS} -verify_return_error" 0
        # keylime agent uses /var/lib/keylime/server-cert.crt which is what we are going to try
        rlRun "openssl x509 -text -in /var/lib/keylime/server-cert.crt"
        rlRun -s "sleep 1 | openssl s_client -connect 127.0.0.1:${VERIFIER_PORT} ${BAD_CERTS} -verify_return_error" 1
        rlAssertGrep "SSL alert number 48" "${rlRun_LOG}"
    rlPhaseEnd

    rlPhaseStartTest "Try to use tenant with agent's self-signed mTLS certs against the verifier"
        rlRun "limeUpdateConf tenant tls_dir /var/lib/keylime"
        rlRun "limeUpdateConf tenant client_key server-private.pem"
        rlRun "limeUpdateConf tenant client_cert server-cert.crt"
	rlRun -s "keylime_tenant -c cvlist" 1
	rlAssertGrep "(TLSV1_ALERT_UNKNOWN_CA|Connection reset by peer|SSLError)" "$rlRun_LOG" -iE
	rlRun "keylime_tenant -c delete --uuid ${AGENT_ID}" 1
    rlPhaseEnd

    rlPhaseStartTest "Try to use verifier admin API endpoint using curl"
        rlRun -s "curl -kv https://127.0.0.1:${VERIFIER_PORT}/v${API_VERSION}/agents/"
        rlAssertNotGrep "${AGENT_ID}" "$rlRun_LOG"
        rlAssertGrep "403.*Forbidden.*Action list_agents requires admin authentication " "$rlRun_LOG" -iE
        rlRun -s "curl -kv -X DELETE  https://127.0.0.1:${VERIFIER_PORT}/v${API_VERSION}/agents/${AGENT_ID}"
        rlAssertNotGrep "(Accepted|Success)" "$rlRun_LOG" -iE
        rlAssertGrep "403.*Forbidden.*Action delete_agent requires admin authentication " "$rlRun_LOG" -iE
    rlPhaseEnd

    rlPhaseStartTest "Try to open TLS connection to the registrar on port ${REGISTRAR_HTTPS_PORT} using agent's self-signed mTLS cert"
        rlRun "openssl x509 -text -in /var/lib/keylime/cv_ca/client-cert.crt"
        # use sleep to ensure that it won't be client closing the connection too early
        rlRun "sleep 1 | openssl s_client -connect 127.0.0.1:${REGISTRAR_HTTPS_PORT} ${GOOD_CERTS} -verify_return_error" 0
        # keylime agent uses /var/lib/keylime/server-cert.crt which is what we are going to try
        rlRun "openssl x509 -text -in /var/lib/keylime/server-cert.crt"
        rlRun -s "sleep 1 | openssl s_client -connect 127.0.0.1:${REGISTRAR_HTTPS_PORT} ${BAD_CERTS} -verify_return_error" 1
        rlAssertGrep "SSL alert number 48" "${rlRun_LOG}"
    rlPhaseEnd

    rlPhaseStartTest "Try to use tenant with agent's self-signed mTLS certs against the registrar"
        # settings updated earlier while testing the verifier
        #rlRun "limeUpdateConf tenant tls_dir /var/lib/keylime"
        #rlRun "limeUpdateConf tenant client_key server-private.pem"
        #rlRun "limeUpdateConf tenant client_cert server-cert.crt"
	rlRun -s "keylime_tenant -c reglist" 1
	rlAssertGrep "(TLSV1_ALERT_UNKNOWN_CA|Connection reset by peer|SSLError)" "$rlRun_LOG" -iE
	rlRun "keylime_tenant -c regdelete --uuid ${AGENT_ID}" 1
    rlPhaseEnd

    rlPhaseStartTest "Try to use registrar admin API endpoint using curl on port ${REGISTRAR_HTTPS_PORT}"
        rlRun -s "curl -kv https://127.0.0.1:${REGISTRAR_HTTPS_PORT}/v${API_VERSION}/agents/"
        rlAssertNotGrep "${AGENT_ID}" "$rlRun_LOG"
        rlAssertGrep "403.*Forbidden.*Action list_registrations requires admin authentication " "$rlRun_LOG" -iE
        rlRun -s "curl -kv -X DELETE  https://127.0.0.1:${REGISTRAR_HTTPS_PORT}/v${API_VERSION}/agents/${AGENT_ID}"
        rlAssertNotGrep "(Accepted|Success)" "$rlRun_LOG" -iE
        rlAssertGrep "403.*Forbidden.*Action delete_registration requires admin authentication " "$rlRun_LOG" -iE
    rlPhaseEnd

    rlPhaseStartTest "Try to use registrar admin API endpoint using curl on port ${REGISTRAR_HTTP_PORT}"
        # this should not work neither for HTTP nor HTTPS
        rlRun -s "curl -kv --connect-timeout 3 http://127.0.0.1:${REGISTRAR_HTTP_PORT}/v${API_VERSION}/agents/" 0
	rlAssertGrep "400 Bad Request" "$rlRun_LOG" -i
        rlRun -s "curl -kv --connect-timeout 3 https://127.0.0.1:${REGISTRAR_HTTP_PORT}/v${API_VERSION}/agents/" 28,35
        rlAssertNotGrep "${AGENT_ID}" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlAssertNotGrep "Traceback" "$(limeRegistrarLogfile)"
        rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        rlRun "rm -f /var/lib/keylime/cv_ca/* /var/lib/keylime/server-cert.crt /var/lib/keylime/server-private.pem"
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
