#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

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
        rlRun "x509KeyGen agent" 0 "Preparing RSA tenant certificate"
        rlRun "x509SelfSign ca" 0 "Selfsigning CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' verifier" 0 "Signing verifier certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' verifier-client" 0 "Signing verifier-client certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' registrar" 0 "Signing registrar certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' tenant" 0 "Signing tenant certificate with our CA"
        rlRun "x509SelfSign --DN 'CN = ${HOSTNAME}' -t webserver agent" 0 "Self-signing agent certificate"

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
        rlRun "cp $(x509Cert agent) $CERTDIR/agent-cert.pem"
        rlRun "cp $(x509Key agent) $CERTDIR/agent-key.pem"
        # assign cert ownership to keylime user if it exists
        id keylime && rlRun "chown -R keylime.keylime $CERTDIR"

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf cloud_verifier check_client_cert True"
        rlRun "limeUpdateConf cloud_verifier tls_dir $CERTDIR"
        rlRun "limeUpdateConf cloud_verifier ca_cert cacert.pem"
        rlRun "limeUpdateConf cloud_verifier my_cert verifier-cert.pem"
        rlRun "limeUpdateConf cloud_verifier private_key verifier-key.pem"
        rlRun "limeUpdateConf cloud_verifier private_key_pw ''"
        rlRun "limeUpdateConf cloud_verifier registrar_tls_dir $CERTDIR"
        rlRun "limeUpdateConf cloud_verifier registrar_ca_cert cacert.pem"
        rlRun "limeUpdateConf cloud_verifier registrar_my_cert verifier-client-cert.pem"
        rlRun "limeUpdateConf cloud_verifier registrar_private_key verifier-client-key.pem"
        rlRun "limeUpdateConf cloud_verifier registrar_private_key_pw ''"
        rlRun "limeUpdateConf cloud_verifier agent_mtls_cert ${CERTDIR}/verifier-client-cert.pem"
        rlRun "limeUpdateConf cloud_verifier agent_mtls_private_key ${CERTDIR}/verifier-client-key.pem"
        # FIXME: this option is deprecated; migrate to revocation_notifiers once
        # https://github.com/keylime/keylime/pull/795 is merged
        rlRun "limeUpdateConf cloud_verifier revocation_notifier_webhook yes"
        ###
        rlRun "limeUpdateConf cloud_verifier revocation_notifiers zeromq,webhook"
        rlRun "limeUpdateConf cloud_verifier webhook_url https://localhost:${SSL_SERVER_PORT}"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf cloud_verifier revocation_notifiers ''"
            # FIXME: this option is deprecated; remove it once
            # https://github.com/keylime/keylime/pull/795 is merged
            rlRun "limeUpdateConf cloud_verifier revocation_notifier False"
        fi
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant tls_dir $CERTDIR"
        rlRun "limeUpdateConf tenant ca_cert cacert.pem"
        rlRun "limeUpdateConf tenant my_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant private_key tenant-key.pem"
        rlRun "limeUpdateConf tenant private_key_pw ''"
        rlRun "limeUpdateConf tenant registrar_tls_dir $CERTDIR"
        # for tenant registrar_* TLS options we can use save values as above
        rlRun "limeUpdateConf tenant registrar_ca_cert cacert.pem"
        rlRun "limeUpdateConf tenant registrar_my_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant registrar_private_key tenant-key.pem"
        rlRun "limeUpdateConf tenant registrar_private_key_pw ''"
        rlRun "limeUpdateConf tenant agent_mtls_cert ${CERTDIR}/tenant-cert.pem"
        rlRun "limeUpdateConf tenant agent_mtls_private_key ${CERTDIR}/tenant-key.pem"
        # registrar
        rlRun "limeUpdateConf registrar check_client_cert True"
        rlRun "limeUpdateConf registrar tls_dir $CERTDIR"
        rlRun "limeUpdateConf registrar ca_cert cacert.pem"
        rlRun "limeUpdateConf registrar my_cert registrar-cert.pem"
        rlRun "limeUpdateConf registrar private_key registrar-key.pem"
        rlRun "limeUpdateConf registrar private_key_pw ''"
        # agent
        rlRun "limeUpdateConf cloud_agent keylime_ca ${CERTDIR}/cacert.pem"
        rlRun "limeUpdateConf cloud_agent rsa_keyname agent-key.pem"
        rlRun "limeUpdateConf cloud_agent mtls_cert agent-cert.pem"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf cloud_agent listen_notifications False"
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
        limeCreateTestLists
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
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --allowlist allowlist.txt --exclude excludelist.txt --include payload --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlWaitForFile /var/tmp/test_payload_file -t 30 -d 1  # we may need to wait for it to appear a bit
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
        fi
        cat ${SSL_SERVER_LOG}
        rlAssertGrep '\\"type\\": \\"revocation\\", \\"ip\\": \\"127.0.0.1\\", \\"agent_id\\": \\"d432fbb3-d2f1-4a97-9ef7-75bd81c00000\\"' ${SSL_SERVER_LOG} -i
        rlAssertNotGrep ERROR ${SSL_SERVER_LOG} -i
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "kill ${SSL_SERVER_PID}"
        rlRun "pkill -f 'sleep 500'"
        rlRun "rm ${SSL_SERVER_LOG}"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        limeLogfileSubmit $(limeVerifierLogfile)
        limeLogfileSubmit $(limeRegistrarLogfile)
        limeLogfileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        rlRun "rm /etc/pki/ca-trust/source/anchors/keylime-ca.crt"
        rlRun "update-ca-trust"
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
        #rlRun "rm -f $TESTDIR/keylime-bad-script.sh"  # possible but not really necessary
    rlPhaseEnd

rlJournalEnd
