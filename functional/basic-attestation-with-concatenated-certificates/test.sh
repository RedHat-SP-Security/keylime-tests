#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "${REVOCATION_NOTIFIER}" ] || REVOCATION_NOTIFIER=agent
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
        rlRun "x509KeyGen ca" 0 "Generating Root CA RSA key pair"
        rlRun "x509KeyGen intermediate-ca" 0 "Generating Intermediate CA RSA key pair"
        rlRun "x509KeyGen verifier" 0 "Generating verifier RSA key pair"
        rlRun "x509KeyGen verifier-client" 0 "Generating verifier-client RSA key pair"
        rlRun "x509KeyGen registrar" 0 "Generating registrar RSA key pair"
        rlRun "x509KeyGen tenant" 0 "Generating tenant RSA key pair"
        rlRun "x509SelfSign ca" 0 "Selfsigning Root CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = ${HOSTNAME}' -t CA --subjectAltName 'IP = ${MY_IP}' intermediate-ca" 0 "Signing intermediate CA certificate with our Root CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' verifier" 0 "Signing verifier certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' verifier-client" 0 "Signing verifier-client certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webserver --subjectAltName 'IP = ${MY_IP}' registrar" 0 "Signing registrar certificate with intermediate CA key"
        rlRun "x509CertSign --CA intermediate-ca --DN 'CN = ${HOSTNAME}' -t webclient --subjectAltName 'IP = ${MY_IP}' tenant" 0 "Signing tenant certificate with intermediate CA key"

        # copy verifier certificates to proper location
        CERTDIR=/var/lib/keylime/certs
        rlRun "mkdir -p $CERTDIR"
        #rlRun "cp $(x509Cert ca) $CERTDIR/cacert.pem"
        #rlRun "cp $(x509Cert intermediate-ca) $CERTDIR/intermediate-cacert.pem"
        rlRun "cat $(x509Cert ca) $(x509Cert intermediate-ca) > $CERTDIR/cacerts.pem"
        rlRun "cp $(x509Cert verifier) $CERTDIR/verifier-cert.pem"
        rlRun "cp $(x509Key verifier) $CERTDIR/verifier-key.pem"
        rlRun "cp $(x509Cert verifier-client) $CERTDIR/verifier-client-cert.pem"
        rlRun "cp $(x509Key verifier-client) $CERTDIR/verifier-client-key.pem"
        rlRun "cp $(x509Cert registrar) $CERTDIR/registrar-cert.pem"
        rlRun "cp $(x509Key registrar) $CERTDIR/registrar-key.pem"
        rlRun "cp $(x509Cert tenant) $CERTDIR/tenant-cert.pem"
        rlRun "cp $(x509Key tenant) $CERTDIR/tenant-key.pem"
        # assign cert ownership to keylime user if it exists
        id keylime && rlRun "chown -R keylime:keylime $CERTDIR"

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf verifier check_client_cert True"
        rlRun "limeUpdateConf verifier tls_dir $CERTDIR"
        rlRun "limeUpdateConf verifier trusted_server_ca '[\"cacerts.pem\"]'"
        rlRun "limeUpdateConf verifier trusted_client_ca '[\"cacerts.pem\"]'"
        rlRun "limeUpdateConf verifier server_cert verifier-cert.pem"
        rlRun "limeUpdateConf verifier server_key verifier-key.pem"
        rlRun "limeUpdateConf verifier client_cert ${CERTDIR}/verifier-client-cert.pem"
        rlRun "limeUpdateConf verifier client_key ${CERTDIR}/verifier-client-key.pem"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant tls_dir $CERTDIR"
        rlRun "limeUpdateConf tenant trusted_server_ca '[\"cacerts.pem\"]'"
        rlRun "limeUpdateConf tenant client_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant client_key tenant-key.pem"
        # registrar
        rlRun "limeUpdateConf registrar check_client_cert True"
        rlRun "limeUpdateConf registrar tls_dir $CERTDIR"
        rlRun "limeUpdateConf registrar trusted_client_ca '[\"cacerts.pem\"]'"
        rlRun "limeUpdateConf registrar server_cert registrar-cert.pem"
        rlRun "limeUpdateConf registrar server_key registrar-key.pem"
        # agent
        rlRun "limeUpdateConf agent trusted_client_ca '\"['${CERTDIR}/cacerts.pem']\"'"
        rlRun "limeUpdateConf agent server_key '\"agent-key.pem\"'"
        rlRun "limeUpdateConf agent server_cert '\"agent-cert.pem\"'"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
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
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestPolicy
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --file /etc/hostname -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
    rlPhaseEnd

rlJournalEnd
