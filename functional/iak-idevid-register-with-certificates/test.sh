#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
TPM2_OPENSSL="https://github.com/tpm2-software/tpm2-openssl/releases/download/1.2.0/tpm2-openssl-1.2.0.tar.gz"
CA_PWORD="keylimeca"
CERT_DIR="/var/lib/keylime"
TPM_CERTS="/var/lib/keylime/tpm_cert_store"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "TESTDIR=$(pwd)"
        rlRun "TMPDIR=\$(mktemp -d)"
        rlRun "pushd ${TMPDIR}"
        # tenant, set to true to verify ek on TPM
        rlRun "limeUpdateConf agent enable_iak_idevid true"
        rlRun "limeUpdateConf registrar tpm_identity iak_idevid"
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
        fi
    rlPhaseEnd

    rlPhaseStartSetup "Install tpm2-openssl to generate csrs with TPM keys"
        rlRun "dnf -y install autoconf automake libtool m4 autoconf-archive openssl-devel tpm2-tss-devel"
        rlRun "wget -c ${TPM2_OPENSSL} -q -O - | tar -xz"
        rlRun "cd tpm2-openssl-1.2.0"
        rlRun "./configure"
        rlRun "make"
        rlRun "make install"
        #rlRun "make check"
        rlRun "cd .."
    rlPhaseEnd

    rlPhaseStartSetup "Create CA"
        
        rlRun "mkdir -p ca/intermediate && cp ${TESTDIR}/root.cnf ca/ && cp ${TESTDIR}/intermediate.cnf ca/intermediate/"
        # Update config files with correct path
        rlRun "sed -i \"/dir               = ca/c dir = ${TMPDIR}/ca\" ca/root.cnf"
        rlRun "sed -i \"/dir               = ca/c dir = ${TMPDIR}/ca/intermediate\" ca/intermediate/intermediate.cnf"
        rlRun "cd ca && mkdir private certs newcerts crl && touch index.txt && echo 1000 > serial"
        rlRun "cd intermediate && mkdir private certs newcerts csr crl && touch index.txt && echo 1000 > serial"
        # Create private keys for CA
        rlRun "cd .. && openssl genrsa -aes256 -passout pass:${CA_PWORD} -out private/rootca.key.pem 4096"
        rlRun "openssl genrsa -aes256 -passout pass:${CA_PWORD} -out intermediate/private/intermediateca.key.pem 4096"
        # Create certs and cert chain for CA
        rlRun "openssl req -config root.cnf -key private/rootca.key.pem -passin pass:${CA_PWORD} \
            -new -x509 -days 9999 -sha384 -extensions v3_ca \
            -out certs/rootca.cert.pem"
        rlRun "openssl req -config intermediate/intermediate.cnf -key intermediate/private/intermediateca.key.pem \
            -passin pass:${CA_PWORD} -new -sha256 -out intermediate/csr/intermediate.csr.pem"
        rlRun "openssl ca -config root.cnf -extensions v3_intermediate_ca \
            -days 9998 -notext -md sha384 -batch \
            -in intermediate/csr/intermediate.csr.pem \
            -passin pass:${CA_PWORD} \
            -out intermediate/certs/intermediateca.cert.pem"
        rlRun "cat intermediate/certs/intermediateca.cert.pem certs/rootca.cert.pem \
            > certs/klca-chain.cert.pem"
        rlRun "cd .."
    rlPhaseEnd

# The templates used in order to regenerate the IDevID and IAK keys are taken from the TCG document "TPM 2.0 Keys for Device Identity and Attestation"
# https://trustedcomputinggroup.org/wp-content/uploads/TPM-2p0-Keys-for-Device-Identity-and-Attestation_v1_r12_pub10082021.pdf
# The template H-1 is used here
# The unique values piped in via xxd for the '-u -' parameter are IDevID and IAK in hex, as defined in section 7.3.1
# The attributes (-a) and algorithms (-g, -G) are specified in 7.3.4.1 Table 3 and 7.3.4.2 Table 4 respectively
# The policy values (-L) are specified in 7.3.6.6 Table 19
    rlPhaseStartSetup "Create keys, csrs, and import certificates"
        rlRun "mkdir ikeys && cd ikeys"
        # Regenerate IDevID within TPM
        rlRun "echo -n 494445564944 | xxd -r -p | tpm2_createprimary -C e \
            -g sha256 \
            -G rsa2048:null:null \
            -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|adminwithpolicy|sign' \
            -L 'ad6b3a2284fd698a0710bf5cc1b9bdf15e2532e3f601fa4b93a6a8fa8de579ea' \
            -u - \
            -c idevid.ctx -o idevidtpm2.pem"
        # Regenerate IAK within TPM
        rlRun "echo -n 49414b | xxd -r -p | tpm2_createprimary -C e \
            -g sha256 \
            -G rsa2048:rsapss-sha256:null \
            -a 'fixedtpm|fixedparent|sensitivedataorigin|userwithauth|adminwithpolicy|sign|restricted' \
            -L '5437182326e414fca797d5f174615a1641f61255797c3a2b22c21d120b2d1e07' \
            -u - \
            -c iak.ctx -o iaktpm2.pem"
        # Persist IDevID and IAK at the first two available handles and save handle indexes
        rlRun "tpm2_evictcontrol -c idevid.ctx | grep -o '0x.*$' > idevid.handle"
        rlRun "tpm2_evictcontrol -c iak.ctx | grep -o '0x.*$' > iak.handle"
        # Create CSRs for the IDevID and IAK and sign them with the CA
        rlRun "openssl req -config ../ca/intermediate/intermediate.cnf -provider tpm2 -provider default \
            -propquery '?provider=tpm2' -new -key handle:$(cat idevid.handle) -out ../ca/intermediate/csr/idevid.csr.pem"
        rlRun "openssl req -config ../ca/intermediate/intermediate.cnf -provider tpm2 -provider default \
            -propquery '?provider=tpm2' -new -key handle:$(cat iak.handle) -out ../ca/intermediate/csr/iak.csr.pem"
        rlRun "openssl ca -config ../ca/intermediate/intermediate.cnf -extensions server_cert -days 999 \
            -notext -passin pass:${CA_PWORD} -batch -md sha384 -in ../ca/intermediate/csr/idevid.csr.pem \
            -out ../ca/intermediate/certs/idevid.cert.pem"
        rlRun "openssl ca -config ../ca/intermediate/intermediate.cnf -extensions server_cert -days 999 \
            -notext -passin pass:${CA_PWORD} -batch -md sha384 -in ../ca/intermediate/csr/iak.csr.pem \
            -out ../ca/intermediate/certs/iak.cert.pem"
        # Convert certs to DER as per TPM spec
        rlRun "openssl x509 -inform PEM -in ../ca/intermediate/certs/idevid.cert.pem \
            -outform DER -out $CERT_DIR/idevid-cert.crt"
        rlRun "openssl x509 -inform PEM -in ../ca/intermediate/certs/iak.cert.pem \
            -outform DER -out $CERT_DIR/iak-cert.crt"
        # Evict the persisted keys using their handles
        rlRun "tpm2_evictcontrol -c $(cat idevid.handle)"
        rlRun "tpm2_evictcontrol -c $(cat iak.handle)"
        rlRun "cd .."
    rlPhaseEnd

    rlPhaseStartTest "Failed registration - agent submits IDevID and IAK but cert does not get verified"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        # Agent attempts to register and sends all the required information but the CA is not trusted
        # so registration fails at IDevID verification
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}" 1
        rlAssertGrep "ERROR - No Root CA matched IDevID Certificate" "$(limeRegistrarLogfile)"
        rlRun "limeStopAgent"
    rlPhaseEnd

    rlPhaseStartTest "Successful registration - IDevID and IAK certs verified, and IAK verifies AK"
        # Add CA to store
        rlRun "cp ./ca/certs/klca-chain.cert.pem $TPM_CERTS/"
        rlRun "limeStartAgent"
        # Agent can now register with IDevID and IAK getting verified
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlAssertGrep "IDevID created" "$(limeAgentLogfile)"
        rlAssertGrep "AK certified with IAK" "$(limeAgentLogfile)"
        # Check the registrar used the IDevID and IAK code block
        rlAssertGrep "INFO - IDevID and IAK received" "$(limeRegistrarLogfile)"
        # Check that the registrar verifies the registering AK against the IAK
        rlAssertGrep "Agent $AGENT_ID AIK verified with IAK" "$(limeRegistrarLogfile)"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        rlRun "popd"
        rlRun "rm -rf ${TMPDIR}"
    rlPhaseEnd

rlJournalEnd
