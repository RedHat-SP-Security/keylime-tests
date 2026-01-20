#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -n "${AGENT_SERVICE}" ] || AGENT_SERVICE=Agent  # or PushAgent
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
TENANT_ARGS=""
[ "${AGENT_SERVICE}" == "PushAgent" ] && TENANT_ARGS="--push-model"
VERIFIER_PORT=8881

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
            rlRun "limeUpdateConf agent tls_accept_invalid_hostnames true"
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
        rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID PASS"
    rlPhaseEnd

    rlPhaseStartTest "Try to open TLS connection to the verifier using agent's mTLS cert"
        GOOD_CERTS="-cert /var/lib/keylime/cv_ca/client-cert.crt -key /var/lib/keylime/cv_ca/client-private.pem -CAfile /var/lib/keylime/cv_ca/cacert.crt"
        rlRun "openssl x509 -text -in /var/lib/keylime/cv_ca/client-cert.crt"
        # use sleep to ensure that it won't be client closing the connection too early
        rlRun "sleep 1 | openssl s_client -connect 127.0.0.1:${VERIFIER_PORT} ${GOOD_CERTS} -verify_return_error" 0
        # keylime agent uses /var/lib/keylime/server-cert.crt which is what we are going to try
        BAD_CERTS="-cert /var/lib/keylime/server-cert.crt -key /var/lib/keylime/server-private.pem -CAfile /var/lib/keylime/cv_ca/cacert.crt"
        rlRun "openssl x509 -text -in /var/lib/keylime/server-cert.crt"
        rlRun -s "sleep 1 | openssl s_client -connect 127.0.0.1:${VERIFIER_PORT} ${BAD_CERTS} -verify_return_error" 1
        rlAssertGrep "SSL alert number 48" "${rlRun_LOG}"
    rlPhaseEnd

    rlPhaseStartTest "Try to use tenant with agent's self-signed mTLS certs"
        rlRun "limeUpdateConf tenant tls_dir /var/lib/keylime"
        rlRun "limeUpdateConf tenant client_key server-private.pem"
        rlRun "limeUpdateConf tenant client_cert server-cert.crt"
	rlRun "keylime_tenant -c delete --uuid ${AGENT_ID}" 1
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
