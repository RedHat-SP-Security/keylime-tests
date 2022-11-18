#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "${REVOCATION_NOTIFIER}" ] || REVOCATION_NOTIFIER=agent
SSL_SERVER_PORT=8980
CERT_DIR="/var/lib/keylime/ca"
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
MY_IP=127.0.0.1
HOSTNAME=$( hostname )

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "certgen/certgen"' || rlDie "cannot import openssl/certgen library"
        rlAssertRpm keylime

        # generate TLS certificates for all
        # we are going to use 4 certificates
        # verifier = webserver cert used for the verifier server
        # verifier-client = webclient cert used for the verifier's connection to registrar server
        # registrar = webserver cert used for the registrar server
        # tenant = webclient cert used (twice) by the tenant, running on AGENT server
        # btw, we could live with just one key instead of generating multiple keys.. but that's just how openssl/certgen works
        rlRun "x509KeyGen ca" 0 "Preparing RSA CA certificate"
        rlRun "x509KeyGen verifier" 0 "Preparing RSA verifier certificate"
        rlRun "x509KeyGen verifier-client" 0 "Preparing RSA verifier-client certificate"
        rlRun "x509KeyGen registrar" 0 "Preparing RSA registrar certificate"
        rlRun "x509KeyGen tenant" 0 "Preparing RSA tenant certificate"
        #rlRun "x509KeyGen agent" 0 "Preparing RSA tenant certificate"
        rlRun "x509SelfSign ca" 0 "Selfsigning CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' verifier" 0 "Signing verifier certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' verifier-client" 0 "Signing verifier-client certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' registrar" 0 "Signing registrar certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' tenant" 0 "Signing tenant certificate with our CA"
        #rlRun "x509SelfSign --DN 'CN = ${HOSTNAME}' -t webserver agent" 0 "Self-signing agent certificate"

        # copy verifier certificates to proper location
        CERTDIR=/var/lib/keylime/certs
        rlRun "mkdir -p $CERTDIR"
        rlRun "cp $(x509Cert ca) $CERTDIR/cacert.pem"
        rlRun "cp $(x509Cert verifier) $CERTDIR/verifier-cert.pem"
        rlRun "cp $(x509Key verifier) $CERTDIR/verifier-key.pem"
        rlRun "cp $(x509Cert verifier-client) $CERTDIR/verifier-client-cert.pem"
        rlRun "cp $(x509Key verifier-client) $CERTDIR/verifier-client-key.pem"
        rlRun "cp $(x509Cert registrar) $CERTDIR/registrar-cert.pem"
        rlRun "cp $(x509Key registrar) $CERTDIR/registrar-key.pem"
        rlRun "cp $(x509Cert tenant) $CERTDIR/tenant-cert.pem"
        rlRun "cp $(x509Key tenant) $CERTDIR/tenant-key.pem"
        #rlRun "cp $(x509Cert agent) $CERTDIR/agent-cert.pem"
        #rlRun "cp $(x509Key agent) $CERTDIR/agent-key.pem"
        # assign cert ownership to keylime user if it exists
        id keylime && rlRun "chown -R keylime:keylime $CERTDIR"

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf verifier check_client_cert True"
        rlRun "limeUpdateConf verifier tls_dir $CERTDIR"
        rlRun "limeUpdateConf verifier trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf verifier trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf verifier server_cert verifier-cert.pem"
        rlRun "limeUpdateConf verifier server_key verifier-key.pem"
        rlRun "limeUpdateConf verifier client_cert ${CERTDIR}/verifier-client-cert.pem"
        rlRun "limeUpdateConf verifier client_key ${CERTDIR}/verifier-client-key.pem"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\",\"webhook\"]'"
        rlRun "limeUpdateConf agent enable_revocation_notifications true"
        rlRun "limeUpdateConf revocations webhook_url https://localhost:${SSL_SERVER_PORT}"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant tls_dir $CERTDIR"
        rlRun "limeUpdateConf tenant trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf tenant client_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant client_key tenant-key.pem"
        # registrar
        rlRun "limeUpdateConf registrar check_client_cert True"
        rlRun "limeUpdateConf registrar tls_dir $CERTDIR"
        rlRun "limeUpdateConf registrar trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf registrar server_cert registrar-cert.pem"
        rlRun "limeUpdateConf registrar server_key registrar-key.pem"
        # agent
        if limeIsPythonAgent; then
            rlRun "limeUpdateConf agent trusted_client_ca '[\"${CERTDIR}/cacert.pem\"]'"
            rlRun "limeUpdateConf agent server_key agent-key.pem"
            rlRun "limeUpdateConf agent server_cert agent-cert.pem"
        else
            rlRun "limeUpdateConf agent trusted_client_ca '\"${CERTDIR}/cacert.pem\"'"
            rlRun "limeUpdateConf agent server_key '\"agent-key.pem\"'"
            rlRun "limeUpdateConf agent server_cert '\"agent-cert.pem\"'"
        fi
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
            rlRun "limeUpdateConf agent enable_revocation_notifications false"
        fi
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
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
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
        # generate certificate for the SSL SERVER
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_ca -c init -d /var/lib/keylime/ca
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlAssertExists ${CERT_DIR}/cacert.crt
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_ca -c create -n localhost -d /var/lib/keylime/ca
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlAssertExists ${CERT_DIR}/localhost-cert.crt
        # add cacert.crt to system-wide trust store
        rlRun "cp $CERT_DIR/cacert.crt /etc/pki/ca-trust/source/anchors/keylime-ca.crt"
        rlRun "update-ca-trust"
        SSL_SERVER_LOG=$( mktemp )
        # start revocation notifier webhook server using openssl s_server
        # alternatively, we can start ncat --ssl as server, though it didn't work reliably
        # we also need to feed it with sleep so that stdin won't be closed for s_server
        rlRun "sleep 500 | openssl s_server -cert ${CERT_DIR}/localhost-cert.crt -key ${CERT_DIR}/localhost-private.pem -port ${SSL_SERVER_PORT} &> ${SSL_SERVER_LOG} &"
        #rlRun "ncat --ssl --ssl-cert ${CERT_DIR}/localhost-cert.crt --ssl-key ${CERT_DIR}/localhost-private.pem --no-shutdown -k -l ${SSL_SERVER_PORT} -c '/usr/bin/sleep 3 && echo HTTP/1.1 200 OK' -o ${SSL_SERVER_LOG} &"
        SSL_SERVER_PID=$!
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
        ls -l /var/tmp/test_payload_file
        rlAssertExists /var/tmp/test_payload_file
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        TESTDIR=`limeCreateTestDir`
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/keylime-bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: 127.0.0.1\"' -m 10 -d 1 -t 10"
            rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: 127.0.0.1'"
            rlAssertNotExists /var/tmp/test_payload_file
            cat ${SSL_SERVER_LOG}
            rlAssertGrep '\\"type\\": \\"revocation\\", \\"ip\\": \\"127.0.0.1\\", \\"agent_id\\": \\"d432fbb3-d2f1-4a97-9ef7-75bd81c00000\\"' ${SSL_SERVER_LOG} -i
            rlAssertNotGrep ERROR ${SSL_SERVER_LOG} -i
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "kill ${SSL_SERVER_PID}"
        rlRun "pkill -f 'sleep 500'"
        rlRun "rm ${SSL_SERVER_LOG}"
        rlRun "rm -f /var/tmp/test_payload_file"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        limeSubmitCommonLogs
        rlRun "rm /etc/pki/ca-trust/source/anchors/keylime-ca.crt"
        rlRun "update-ca-trust"
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
