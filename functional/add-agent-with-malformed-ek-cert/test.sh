#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart
    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig

        # In this test, swtpm will provide a properly signed (by the
        # swtpm-local) EK certificate that happens to be considered
        # malformed by python-cryptoghraphy, due to its stricter ASN.1
        # parsing since version 35. OpenSSL considers this certificate
        # valid.
        # The test will check that we are still able to add such and
        # agent that has an EK certificate with these characteristics.

        # Copy the verification script to /var/lib/keylime/ek-openssl-verify.
        EK_CHECK_SCRIPT_SRC=/usr/share/keylime/scripts/ek-openssl-verify
        rlAssertExists "${EK_CHECK_SCRIPT_SRC}"

        EK_CHECK_SCRIPT=/var/lib/keylime/ek-openssl-verify
        rlRun "install -D -m 755 ${EK_CHECK_SCRIPT_SRC} ${EK_CHECK_SCRIPT}"

        # Copy also the swtpm-localca's issuercert.peme to the certstore,
        # so that we can perform the signature chain validation on the EK
        # cert.
        S_LOCALCA_ISSUERCERT_SRC=/var/lib/swtpm-localca/issuercert.pem
        rlAssertExists "${S_LOCALCA_ISSUERCERT_SRC}"

        S_LOCALCA_ISSUERCERT=/var/lib/keylime/tpm_cert_store/swtpm-localca-issuercert.pem
        rlRun "install -D -m400 -g keylime -o keylime ${S_LOCALCA_ISSUERCERT_SRC} ${S_LOCALCA_ISSUERCERT}"

        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant ek_check_script ${EK_CHECK_SCRIPT}"
        # agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator with malformed EK certificate.
            rlRun "limeStartTPMEmulatorMalformedEK"
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
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        rlRun "limeCreateTestPolicy"
    rlPhaseEnd

    rlPhaseStartTest "Make sure the registrar is storing the proper EK certificate"
        # Since this is a test with malformed EK certificate, we should
        # have stored it as-is (malformed) in the registrar database.
        REG_DB=/var/lib/keylime/reg_data.sqlite
        EKCERT_REG_DB_STORED="${TmpDir}/ekcert_reg_db.stored"
        rlRun "sqlite3 -noheader ${REG_DB} 'SELECT ekcert FROM registrarmain;' > ${EKCERT_REG_DB_STORED}"
        # It is stored in DER format, but base64, so let's decode it.
        rlRun "base64 -d ${EKCERT_REG_DB_STORED} > ${EKCERT_REG_DB_STORED}.der"
        rlRun "limeValidateDERCertificatePyCrypto ${EKCERT_REG_DB_STORED}.der" 1 "EK cert Validation with python cryptography should fail"
        rlRun "limeValidateDERCertificateOpenSSL ${EKCERT_REG_DB_STORED}.der" 0 "EK cert Validation with python OpenSSL should succeed"
        # Let's compare also the EK certificate obtained from the tpm directly.
        EKCERT_TPM="${TmpDir}/ek_cert_tpm.der"
        rlRun "tpm2_getekcertificate -o ${EKCERT_TPM}"
        rlAssertNotDiffer "${EKCERT_TPM}" "${EKCERT_REG_DB_STORED}.der"

        # Validate that EK certificate can be verified with the CA chain.
        # This is basically the check the EK_CHECK_SCRIPT will perform.
        EKCERT_TPM_PEM="${TmpDir}/ek_cert_tpm.pem"
        rlRun "openssl x509 -inform der -in ${EKCERT_TPM} -outform pem -out ${EKCERT_TPM_PEM}"
        rlRun "openssl verify -partial_chain -CAfile ${S_LOCALCA_ISSUERCERT} ${EKCERT_TPM_PEM}" 0 "Pre-test EK certificate validation"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent"
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun -s "expect script.expect"
        rlAssertNotGrep "EK signature did not match certificates from TPM cert store" $rlRun_LOG

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

        rlRun "rm -f ${EK_CHECK_SCRIPT}"
        rlRun "rm -f ${S_LOCALCA_ISSUERCERT}"
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd
rlJournalEnd
