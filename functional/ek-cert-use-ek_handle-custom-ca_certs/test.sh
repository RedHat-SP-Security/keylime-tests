#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
CERTDIR=/var/lib/keylime/tpm_cert_store
CACERTDIR=/var/lib/swtpm-localca
PASSWORD_TPM=abc123

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
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
        else
            rlDie "Test work only when TPM is emulated."
        fi
        #show persistent ek
        rlRun "tpm2_getcap handles-persistent"
        # changes authorization values for TPM objects
        rlRun "tpm2_changeauth -c o $PASSWORD_TPM"
        rlRun "tpm2_changeauth -c e $PASSWORD_TPM"
        #flush previous endorsement key
        rlRun "tpm2_evictcontrol -C o -c 0x81010001 -P $PASSWORD_TPM"
        #manually create endorsement key from cryptographic primitives on TPM
        rlRun "tpm2_createek -P $PASSWORD_TPM -w $PASSWORD_TPM -c 0x81010001 -G rsa"
        # tenant, set to true to verify ek on TPM
        rlRun "limeUpdateConf tenant require_ek_cert true" 
        # set address to which ek use
        if limeIsPythonAgent; then
            rlRun "limeUpdateConf agent ek_handle 0x81010001"
            rlRun "limeUpdateConf agent tpm_ownerpassword $PASSWORD_TPM"
        else
            rlRun "limeUpdateConf agent ek_handle '\"0x81010001\"'"
            rlRun "limeUpdateConf agent tpm_ownerpassword '\"$PASSWORD_TPM\"'"
        fi
        #configure tpm_ownerpassword
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
        # creating dir, where will be store CA cert for veryfi genuine of TPM 
        rlRun "mkdir -p $CERTDIR"
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent and verify fail of checking EK cert"
        # create empty CA, which fail the checking of EK cert
        rlRun "touch $CERTDIR/swtpm-localca-rootca-cert.pem $CERTDIR/issuercert.pem $CERTDIR/bundle.pem"
        # expected to fail
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c update" 1 
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent and verify genuine of TPM via EK cert"
        rlRun "rm -rf $CERTDIR/*"
        # how to obtain local CA cert and how setup https://github-wiki-see.page/m/stefanberger/swtpm/wiki/Certificates-created-by-swtpm_setup
        # cp CA cert to dir, where keylime verify genuine of TPM
        rlRun "cp $CACERTDIR/swtpm-localca-rootca-cert.pem $CERTDIR"
        rlRun "cp $CACERTDIR/issuercert.pem $CERTDIR"
        rlRun "cat $CACERTDIR/issuercert.pem $CACERTDIR/swtpm-localca-rootca-cert.pem > bundle.pem"
        rlRun "cp bundle.pem $CERTDIR"
        rlRun -s "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c update"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'" 
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
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
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd

