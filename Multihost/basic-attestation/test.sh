#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/keylime/Multihost/basic-attestation
#   Description: tests basic keylime attestation scenario using multiple hosts
#   Author: Karel Srot <ksrot@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
#. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

# when manually troubleshooting multihost test in Restraint environment
# you may want to export XTRA variable to a unique number each team
# to make user that sync events have unique names and there are not
# collisions with former test runs

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent


function get_IP() {
    if echo $1 | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo $1
    else
        host $1 | sed -n -e 's/.*has address //p' | head -n 1
    fi
}


Verifier() {
    rlPhaseStartSetup "Verifier setup"
        # generate TLS certificates for all
        # we are going to use 4 certificates
        # verifier = webserver cert used for the verifier server
        # verifier-client = webclient cert used for the verifier's connection to registrar server
        # registrar = webserver cert used for the registrar server
        # tenant = webclient cert used (twice) by the tenant, running on AGENT server
        rlRun "x509KeyGen ca" 0 "Preparing RSA CA certificate"
        rlRun "x509KeyGen verifier" 0 "Preparing RSA verifier certificate"
        rlRun "x509KeyGen verifier-client" 0 "Preparing RSA verifier-client certificate"
        rlRun "x509KeyGen registrar" 0 "Preparing RSA registrar certificate"
        rlRun "x509KeyGen tenant" 0 "Preparing RSA tenant certificate"
        rlRun "x509KeyGen agent" 0 "Preparing RSA tenant certificate"
        [ -n "${AGENT2}" ] && rlRun "x509KeyGen agent2" 0 "Preparing RSA tenant certificate"
        rlRun "x509SelfSign ca" 0 "Selfsigning CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = $VERIFIER_IP' -t webserver --subjectAltName 'IP = ${VERIFIER_IP}' verifier" 0 "Signing verifier certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = $VERIFIER_IP' -t webclient --subjectAltName 'IP = ${VERIFIER_IP}' verifier-client" 0 "Signing verifier-client certificate with our CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = $REGISTRAR' -t webserver --subjectAltName 'IP = ${REGISTRAR_IP}' registrar" 0 "Signing registrar certificate with our CA certificate"
        # remember, we are running tenant on agent server
        rlRun "x509CertSign --CA ca --DN 'CN = ${AGENT}' -t webclient --subjectAltName 'IP = ${AGENT_IP}' tenant" 0 "Signing tenant certificate with our CA"
        rlRun "x509SelfSign --DN 'CN = ${AGENT}' -t webserver agent" 0 "Self-signing agent certificate"
        [ -n "${AGENT2}" ] && rlRun "x509SelfSign --DN 'CN = ${AGENT2}' -t webserver agent2" 0 "Self-signing agent2 certificate"

        # copy verifier certificates to proper location
        CERTDIR=/var/lib/keylime/certs
        rlRun "mkdir -p ${CERTDIR}"
        rlRun "cp $(x509Cert ca) ${CERTDIR}/cacert.pem"
        rlRun "cp $(x509Cert verifier) ${CERTDIR}/verifier-cert.pem"
        rlRun "cp $(x509Key verifier) ${CERTDIR}/verifier-key.pem"
        rlRun "cp $(x509Cert verifier-client) ${CERTDIR}/verifier-client-cert.pem"
        rlRun "cp $(x509Key verifier-client) ${CERTDIR}/verifier-client-key.pem"
        id keylime && rlRun "chown -R keylime.keylime ${CERTDIR}"

        # expose necessary certificates to clients
        rlRun "mkdir http"
        rlRun "cp $(x509Cert ca) http/cacert.pem"
        rlRun "cp $(x509Cert registrar) http/registrar-cert.pem"
        rlRun "cp $(x509Key registrar) http/registrar-key.pem"
        rlRun "cp $(x509Cert tenant) http/tenant-cert.pem"
        rlRun "cp $(x509Key tenant) http/tenant-key.pem"
        rlRun "cp $(x509Cert agent) http/agent-cert.pem"
        rlRun "cp $(x509Key agent) http/agent-key.pem"
        [ -n "${AGENT2}" ] && rlRun "cp $(x509Cert agent2) http/agent2-cert.pem"
        [ -n "${AGENT2}" ] && rlRun "cp $(x509Key agent2) http/agent2-key.pem"
        rlRun "pushd http"
        rlRun "python3 -m http.server 8000 &"
        HTTP_PID=$!
        rlRun "popd"

        # Verifier configuration
        rlRun "limeUpdateConf verifier ip ${VERIFIER_IP}"
        rlRun "limeUpdateConf verifier registrar_ip ${REGISTRAR_IP}"
        rlRun "limeUpdateConf verifier check_client_cert True"
        rlRun "limeUpdateConf verifier tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf verifier trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf verifier trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf verifier server_cert verifier-cert.pem"
        rlRun "limeUpdateConf verifier server_key verifier-key.pem"
        rlRun "limeUpdateConf verifier client_cert verifier-client-cert.pem"
        rlRun "limeUpdateConf verifier client_key verifier-client-key.pem"
        rlRun "limeUpdateConf revocations zmq_ip ${VERIFIER_IP}"
        rlRun "limeUpdateConf verifier client_key ${CERTDIR}/verifier-client-key.pem"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\"]'"
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        fi

        # change UUID just for sure so it is different from Agent
        rlRun "limeUpdateConf agent uuid d432fbb3-d2f1-4a97-9ef7-75bd81c22222"

        # Delete other components configuration files
        for comp in agent registrar tenant; do
            rlRun "rm -rf /etc/keylime/$comp.conf*"
        done

        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "sync-set VERIFIER_SETUP_DONE"
        rlRun "sync-block AGENT_ALL_TESTS_DONE ${AGENT_IP}" 0 "Waiting for the Agent to finish the test"
    rlPhaseEnd

    rlPhaseStartTest "Verifier test"
        # check that the AGENT failed verification
        rlAssertGrep "WARNING - File not found in allowlist: .*/keylime-bad-script.sh" $(limeVerifierLogfile) -E
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
    rlPhaseEnd

    rlPhaseStartCleanup "Verifier cleanup"
        rlRun "kill $HTTP_PID"
        rlRun "limeStopVerifier"
        limeLogfileSubmit $(limeVerifierLogfile)
    rlPhaseEnd
}


Registrar() {
    rlPhaseStartSetup "Registrar setup"
        # Registrar setup goes here
        rlRun "sync-block VERIFIER_SETUP_DONE ${VERIFIER_IP}" 0 "Waiting for the Verifier to start"

        # download certificates from the verifier
        CERTDIR=/var/lib/keylime/certs
        rlRun "mkdir -p ${CERTDIR}"
        for F in cacert.pem registrar-cert.pem registrar-key.pem; do
            rlRun "wget -O ${CERTDIR}/$F 'http://$VERIFIER:8000/$F'"
        done
        id keylime && rlRun "chown -R keylime.keylime ${CERTDIR}"

        # common configuration goes here
        rlRun "limeUpdateConf agent revocation_notification_ip ${VERIFIER_IP}"

        # configure registrar
        rlRun "limeUpdateConf registrar ip ${REGISTRAR_IP}"
        rlRun "limeUpdateConf registrar check_client_cert True"
        rlRun "limeUpdateConf registrar tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf registrar trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf registrar server_cert registrar-cert.pem"
        rlRun "limeUpdateConf registrar server_key registrar-key.pem"
        # registrar_* TLS options below seems not necessary
        # we can preserve default values

        # change UUID just for sure so it is different from Agent
        rlRun "limeUpdateConf agent uuid d432fbb3-d2f1-4a97-9ef7-75bd81c11111"

        # Delete other components configuration files
        for comp in agent verifier tenant; do
            rlRun "rm -rf /etc/keylime/$comp.conf*"
        done

        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        rlRun "sync-set REGISTRAR_SETUP_DONE"
        rlRun "sync-block AGENT_ALL_TESTS_DONE ${AGENT_IP}" 0 "Waiting for the Agent to finish the test"
    rlPhaseEnd

    rlPhaseStartCleanup "Registrar cleanup"
        rlRun "limeStopRegistrar"
        limeLogfileSubmit $(limeRegistrarLogfile)
    rlPhaseEnd
}


Agent() {
    rlPhaseStartSetup "Agent and tenant setup"

        # this is the default ID, we are not changing it
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

        # Agent and tenant setup goes here
        rlRun "sync-block REGISTRAR_SETUP_DONE ${REGISTRAR_IP}" 0 "Waiting for the Registrar finish to start"

        # download certificates from the verifier
        CERTDIR=/var/lib/keylime/certs
        SECUREDIR=/var/lib/keylime/secure
        rlRun "mkdir -p ${CERTDIR}"
        rlRun "mkdir -p $SECUREDIR"
        for F in cacert.pem tenant-cert.pem tenant-key.pem agent-key.pem agent-cert.pem; do
            rlRun "wget -O ${CERTDIR}/$F 'http://$VERIFIER:8000/$F'"
        done
        id keylime && rlRun "chown -R keylime.keylime ${CERTDIR}"
        # agent mTLS certs are supposed to be in the SECUREDIR
        rlRun "mount -t tmpfs -o size=2m,mode=0700 tmpfs ${SECUREDIR}"
        rlRun "cp ${CERTDIR}/{agent-key.pem,agent-cert.pem} ${SECUREDIR}"
        id keylime && rlRun "chown -R keylime.keylime ${SECUREDIR}"

        # configure tenant
        rlRun "limeUpdateConf tenant registrar_ip ${REGISTRAR_IP}"
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip ${VERIFIER_IP}"
        rlRun "limeUpdateConf tenant tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf tenant trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf tenant client_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant client_key tenant-key.pem"
        # for registrar_* TLS options we can use save values as above
        rlRun "limeUpdateConf tenant trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf tenant client_cert tenant-cert.pem"
        rlRun "limeUpdateConf tenant client_key tenant-key.pem"
        rlRun "limeUpdateConf tenant client_key ${CERTDIR}/tenant-key.pem"

        # configure agent
        rlRun "limeUpdateConf agent tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf agent ip ${AGENT_IP}"
        rlRun "limeUpdateConf agent contact_ip ${AGENT_IP}"
        rlRun "limeUpdateConf agent registrar_ip ${REGISTRAR_IP}"
        rlRun "limeUpdateConf agent trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf agent server_key agent-key.pem"
        rlRun "limeUpdateConf agent server_cert agent-cert.pem"
        rlRun "limeUpdateConf agent revocation_notification_ip ${VERIFIER_IP}"

        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf agent enable_revocation_notifications False"
        fi

        # Delete other components configuration files
        for comp in verifier registrar; do
            rlRun "rm -rf /etc/keylime/$comp.conf*"
        done

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
            # start ima emulator
            limeInstallIMAConfig
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5

        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
    rlPhaseEnd

if [ -n "${AGENT2}" ]; then
    rlPhaseStartTest "keylime attestation test: Add Agent2"
        # wait for Agent2 setup is done
        rlRun "sync-block AGENT2_SETUP_DONE ${AGENT2}" 0 "Waiting for the Agent2 setup to finish"

        # first register AGENT2 and confirm it has passed validation
        AGENT2_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c33333"
        # download Agent2 lists
        rlRun "wget -O allowlist2.txt 'http://${AGENT2_IP}:8000/allowlist.txt'"
        rlRun "wget -O excludelist2.txt 'http://${AGENT2_IP}:8000/excludelist.txt'"
        # register
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v ${VERIFIER_IP} -t ${AGENT2_IP} -u ${AGENT2_ID} --allowlist allowlist2.txt --exclude excludelist2.txt --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus ${AGENT2_ID} 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'${AGENT2_ID}'" $rlRun_LOG -E
        rlRun -s "keylime_tenant -c status -u ${AGENT2_ID}"
        rlAssertGrep '"operational_state": "Get Quote"' $rlRun_LOG
    rlPhaseEnd
fi

    rlPhaseStartTest "keylime attestation test: Add Agent"
        # register AGENT and confirm it has passed validation
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v ${VERIFIER_IP} -t ${AGENT_IP} -u ${AGENT_ID} --allowlist allowlist.txt --exclude excludelist.txt --include payload-${REVOCATION_SCRIPT_TYPE} --cert default -c add
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

    rlPhaseStartTest "Agent attestation test: Fail keylime agent"
        # fail AGENT and confirm it has failed validation
        TESTDIR=`limeCreateTestDir`
        limeExtendNextExcludelist $TESTDIR
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            # give the revocation notifier a bit more time to contact the agent
            rlRun "rlWaitForCmd 'tail \$(limeAgentLogfile) | grep -q \"A node in the network has been compromised: ${AGENT_IP}\"' -m 20 -d 1 -t 20"
            rlRun "tail $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "tail $(limeAgentLogfile) | grep 'A node in the network has been compromised: ${AGENT_IP}'"
            rlAssertNotExists /var/tmp/test_payload_file
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Agent cleanup"
        rlRun "sync-set AGENT_ALL_TESTS_DONE"
        rlRun "limeStopAgent"
        limeLogfileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
            rlRun "limeStopTPMEmulator"
            rlServiceRestore tpm2-abrmd
        fi
        rlRun "rm -f /var/tmp/test_payload_file"
    rlPhaseEnd
}

Agent2() {
    rlPhaseStartSetup "Agent2 setup"

        AGENT2_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c33333"

        # Agent setup goes here
        rlRun "sync-block REGISTRAR_SETUP_DONE ${REGISTRAR_IP}" 0 "Waiting for the Registrar finish to start"

        # download certificates from the verifier
        CERTDIR=/var/lib/keylime/certs
        SECUREDIR=/var/lib/keylime/secure
        rlRun "mkdir -p ${CERTDIR}"
        rlRun "mkdir -p $SECUREDIR"
        for F in cacert.pem agent2-key.pem agent2-cert.pem; do
            rlRun "wget -O ${CERTDIR}/$F 'http://$VERIFIER:8000/$F'"
        done
        id keylime && rlRun "chown -R keylime.keylime ${CERTDIR}"
        # agent mTLS certs are supposed to be in the SECUREDIR
        rlRun "mount -t tmpfs -o size=2m,mode=0700 tmpfs ${SECUREDIR}"
        rlRun "cp ${CERTDIR}/{agent2-key.pem,agent2-cert.pem} ${SECUREDIR}"
        id keylime && rlRun "chown -R keylime.keylime ${SECUREDIR}"

        # configure agent
        rlRun "limeUpdateConf agent tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf agent ip ${AGENT2_IP}"
        rlRun "limeUpdateConf agent contact_ip ${AGENT2_IP}"
        rlRun "limeUpdateConf agent registrar_ip ${REGISTRAR_IP}"
        rlRun "limeUpdateConf agent trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf agent revocation_notification_ip ${VERIFIER_IP}"

        # change UUID just for sure so it is different from Agent
        rlRun "limeUpdateConf agent uuid ${AGENT2_ID}"
        rlRun "limeUpdateConf agent server_key agent2-key.pem"
        rlRun "limeUpdateConf agent server_cert agent2-cert.pem"
 
        if [ -n "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            rlRun "limeUpdateConf agent enable_revocation_notifications False"
        fi

        # Delete other components configuration files
        for comp in verifier tenant registrar; do
            rlRun "rm -rf /etc/keylime/$comp.conf*"
        done

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            limeStartTPMEmulator
            rlRun "limeWaitForTPMEmulator"
            # make sure tpm2-abrmd is running
            rlServiceStart tpm2-abrmd
            sleep 5
            # start ima emulator
            limeInstallIMAConfig
            limeStartIMAEmulator
        fi
        sleep 5

        rlRun "limeStartAgent"
        # cannot use limeWaitForAgentRegistration as we do not have tenant configured
        # so let's just wait for 20 seconds
        rlRun "sleep 20"
        # create allowlist and excludelist
        limeCreateTestLists

        # expose lists to Agent
        rlRun "mkdir http"
        rlRun "cp excludelist.txt allowlist.txt http"
        rlRun "pushd http"
        rlRun "python3 -m http.server 8000 &"
        HTTP_PID=$!
        rlRun "popd"

        # find the end of my log
        LOG_END=$( cat $(limeAgentLogfile) | wc -l )
        rlRun "sync-set AGENT2_SETUP_DONE"
    rlPhaseEnd

    rlPhaseStartTest "Agent2 test: Verify Agent failed validation + revocation"
        # waif for Agent to finish his tests (including failed validation)
        rlRun "sync-block AGENT_ALL_TESTS_DONE ${AGENT_IP}"

        if [ -z "$KEYLIME_TEST_DISABLE_REVOCATION" ]; then
            # installed payload should not have been deleted for Agent2
            rlAssertExists /var/tmp/test_payload_file
            rlRun "sed -n '${LOG_END},\$ p' $(limeAgentLogfile) | grep 'Executing revocation action local_action_modify_payload'"
            rlRun "sed -n '${LOG_END},\$ p' $(limeAgentLogfile) | grep 'A node in the network has been compromised: ${AGENT_IP}'"
        fi
    rlPhaseEnd

    rlPhaseStartCleanup "Agent2 cleanup"
        rlRun "kill $HTTP_PID"
        rlRun "rm -f /var/tmp/test_payload_file"
        limeStopAgent
        limeLogfileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            limeStopIMAEmulator
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
            limeStopTPMEmulator
            rlServiceRestore tpm2-abrmd
        fi
    rlPhaseEnd
}



####################
# Common script part
####################

# assigne custom roles using SERVERS and CLIENTS variables
export VERIFIER=$( echo "$SERVERS $CLIENTS" | awk '{ print $1 }')
export REGISTRAR=$( echo "$SERVERS $CLIENTS" | awk '{ print $2 }')
export AGENT=$( echo "$SERVERS $CLIENTS" | awk '{ print $3 }')
export AGENT2=$( echo "$SERVERS $CLIENTS" | awk '{ print $4 }')

export TESTSOURCEDIR=`pwd`

rlJournalStart
    rlPhaseStartSetup
        [ -n "$VERIFIER" ] && export VERIFIER_IP=$( get_IP $VERIFIER )
        [ -n "$REGISTRAR" ] && export REGISTRAR_IP=$( get_IP $REGISTRAR )
        [ -n "${AGENT}" ] && export AGENT_IP=$( get_IP ${AGENT} )
        [ -n "${AGENT2}" ] && export AGENT2_IP=$( get_IP ${AGENT2} )
        rlLog "VERIFIER: $VERIFIER ${VERIFIER_IP}"
        rlLog "REGISTRAR: $REGISTRAR ${REGISTRAR_IP}"
        rlLog "AGENT: ${AGENT} ${AGENT_IP}"
        rlLog "AGENT2: ${AGENT2} ${AGENT2_IP}"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"

        ###############
        # common setup
        ###############

        # import keylime library
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "./sync"' || rlDie "cannot import keylime-tests/sync library"
        rlRun 'rlImport "openssl/certgen"' || rlDie "cannot import openssl/certgen library"
        rlAssertRpm keylime
        # backup files
        limeBackupConfig
        # load REVOCATION_SCRIPT_TYPE
        REVOCATION_SCRIPT_TYPE=$( limeGetRevocationScriptType )
        rlRun "cp -rf payload-${REVOCATION_SCRIPT_TYPE} $TmpDir"

        rlRun "pushd $TmpDir"
    rlPhaseEnd

    MY_IP=$( hostname -I | awk '{ print $1 }' )
    if echo " $HOSTNAME $MY_IP " | grep -q " $VERIFIER "; then
        Verifier
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${REGISTRAR} "; then
        Registrar
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${AGENT} "; then
        Agent
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${AGENT2} "; then
        Agent2
    else
        rlPhaseStartTest
            rlFail "Unknown role"
        rlPhaseEnd
    fi

    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "rm -r $TmpDir" 0 "Removing tmp directory"

        #################
        # common cleanup
        #################
        limeClearData
        limeRestoreConfig
    rlPhaseEnd

rlJournalPrintText
rlJournalEnd
