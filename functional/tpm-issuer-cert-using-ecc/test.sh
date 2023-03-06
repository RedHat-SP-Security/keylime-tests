#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
KEYLIME_CERT_DIR=/var/lib/keylime/tpm_certs
SWTPM_CERT_DIR=/var/lib/swtpm-localca

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        # if TPM emulator is present
        if ! limeTPMEmulated; then
            rlDie "Test work only when TPM is emulated."
        fi
        # generate issuer's cert using ECC
        rlRun "cat > issuer.config <<_EOF
[req]
encrypt_key = yes
prompt = no
utf8 = yes
string_mask = utf8only
distinguished_name = dn
x509_extensions = v3_ca
[v3_ca]
#authorityKeyIdentifier = keyid,issuer
subjectKeyIdentifier = hash
basicConstraints = CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
[dn]
CN = TPM cert issuer
_EOF"
        rlRun "openssl genpkey -algorithm ec -pkeyopt ec_paramgen_curve:prime256v1 > issuer_key.pem"
        rlRun "openssl req -config issuer.config -verbose -new -sha256 -key issuer_key.pem -out issuer.csr"
        rlRun "openssl x509 -req -in issuer.csr -extensions v3_ca -extfile issuer.config -CA /var/lib/swtpm-localca/swtpm-localca-rootca-cert.pem -CAkey /var/lib/swtpm-localca/swtpm-localca-rootca-privkey.pem -out issuer_public.pem -days 365 -sha256 -CAcreateserial"
        rlRun "openssl x509 -in issuer_public.pem -noout -text"
        # configure SWTPM
        rlFileBackup --clean ${SWTPM_CERT_DIR}
        rlRun "cat issuer_public.pem > ${SWTPM_CERT_DIR}/issuercert.pem"
        rlRun "cat issuer_key.pem > ${SWTPM_CERT_DIR}/signkey.pem"
        rlRun "cat ${SWTPM_CERT_DIR}/{issuercert.pem,swtpm-localca-rootca-cert.pem} > ${SWTPM_CERT_DIR}/bundle.pem"
        rlRun "mkdir -p ${KEYLIME_CERT_DIR}"
        rlRun "cp ${SWTPM_CERT_DIR}/{issuercert.pem,swtpm-localca-rootca-cert.pem,bundle.pem} ${KEYLIME_CERT_DIR}"
        # start tpm emulator
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        # make sure tpm2-abrmd is running
        rlServiceStart tpm2-abrmd
        sleep 5
        # print EK cert details
        rlRun "tpm2_nvread 0x1c00002 > ekcert-rsa.der"
        rlRun "openssl x509 -inform der -in ekcert-rsa.der -noout -text"
        # clear old data about TPM
        rlRun "rm -f /var/lib/keylime/tpmdata.yml"
        # tenant, set to true to verify ek on TPM
        rlRun "limeUpdateConf tenant require_ek_cert true"
        rlRun "limeUpdateConf tenant tpm_cert_store ${KEYLIME_CERT_DIR}"
        # start ima emulator
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"
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

    rlPhaseStartTest "Add keylime agent and verify genuine of TPM via EK cert"
        # cp CA cert to dir, where keylime verify genuine of TPM
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --runtime-policy policy.json -f /etc/hostname -c update"
        rlRun "limeWaitForAgentStatus ${AGENT_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT_ID}'" ${rlRun_LOG} -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        limeLogfileSubmit $(limeVerifierLogfile)
        limeLogfileSubmit $(limeRegistrarLogfile)
        limeLogfileSubmit $(limeAgentLogfile)
        rlRun "limeStopIMAEmulator"
        limeLogfileSubmit $(limeIMAEmulatorLogfile)
        rlRun "limeStopTPMEmulator"
        rlServiceRestore tpm2-abrmd
        rlRun "rm -rf ${KEYLIME_CERT_DIR}"
        limeClearData
        limeRestoreConfig
        rlFileRestore
    rlPhaseEnd

rlJournalEnd
