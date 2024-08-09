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
#   Copyright (c) 2024 Red Hat, Inc.
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


function assign_server_roles() {
    if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f ${TMT_TOPOLOGY_BASH} ]; then
        # assign roles based on tmt topology data
        cat ${TMT_TOPOLOGY_BASH}
        . ${TMT_TOPOLOGY_BASH}

        export KEYLIME=${TMT_GUESTS["keylime.hostname"]}
        export AGENT=${TMT_GUESTS["agent.hostname"]}
        MY_IP="${TMT_GUEST['hostname']}"
    elif [ -n "$SERVERS" ]; then
        # assign roles using SERVERS and CLIENTS variables
        export KEYLIME=$( echo "$SERVERS $CLIENTS" | awk '{ print $1 }')
        export AGENT=$( echo "$SERVERS $CLIENTS" | awk '{ print $2 }')
    fi

    [ -z "$MY_IP" ] && MY_IP=$( hostname -I | awk '{ print $1 }' )
    [ -n "$KEYLIME" ] && export KEYLIME_IP=$( get_IP $KEYLIME )
    [ -n "${AGENT}" ] && export AGENT_IP=$( get_IP ${AGENT} )
}

function get_IP() {
    if echo $1 | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo $1
    else
        host $1 | sed -n -e 's/.*has address //p' | head -n 1
    fi
}


KeylimeSetup() {
    rlPhaseStartSetup "Keylime setup"
        # generate TLS certificates for all
        # we are going to use 4 certificates
	# ca certificate
        # keylime = webserver cert used for the verifier and registrar server
        # keylime-client = webclient cert used for the verifier's connection to registrar server and tenant
	# agent certificate
        rlRun "x509KeyGen ca" 0 "Preparing RSA CA certificate"
        rlRun "x509KeyGen keylime" 0 "Preparing RSA verifier certificate"
        rlRun "x509KeyGen keylime-client" 0 "Preparing RSA verifier-client certificate"
        rlRun "x509KeyGen agent" 0 "Preparing RSA tenant certificate"
        rlRun "x509SelfSign ca" 0 "Selfsigning CA certificate"
        rlRun "x509CertSign --CA ca --DN 'CN = $KEYLIME_IP' -t webserver --subjectAltName 'IP = ${KEYLIME_IP}' keylime"
        rlRun "x509CertSign --CA ca --DN 'CN = $KEYLIME_IP' -t webclient --subjectAltName 'IP = ${KEYLIME_IP}' keylime-client"
        rlRun "x509SelfSign --DN 'CN = ${AGENT}' -t webserver agent" 0 "Self-signing agent certificate"

        # copy verifier certificates to proper location
        CERTDIR=/var/lib/keylime/certs
        rlRun "mkdir -p ${CERTDIR}"
        rlRun "cp $(x509Cert ca) ${CERTDIR}/cacert.pem"
        rlRun "cp $(x509Cert keylime) ${CERTDIR}/keylime-cert.pem"
        rlRun "cp $(x509Key keylime) ${CERTDIR}/keylime-key.pem"
        rlRun "cp $(x509Cert keylime-client) ${CERTDIR}/keylime-client-cert.pem"
        rlRun "cp $(x509Key keylime-client) ${CERTDIR}/keylime-client-key.pem"

	# weird!!!
        rlRun "cp $(x509Cert keylime-client) ${CERTDIR}/client-cert.pem"
        rlRun "cp $(x509Key keylime-client) ${CERTDIR}/client-key.pem"
        id keylime && rlRun "chown -R keylime:keylime ${CERTDIR}"

        # expose necessary certificates to clients
        rlRun "mkdir http"
        rlRun "cp $(x509Cert ca) http/cacert.pem"
        rlRun "cp $(x509Cert agent) http/agent-cert.pem"
        rlRun "cp $(x509Key agent) http/agent-key.pem"
        rlRun "pushd http"
        rlRun "python3 -m http.server 8000 &"
        HTTP_PID=$!
        rlRun "popd"

        # Verifier configuration
        rlRun "limeUpdateConf verifier ip ${KEYLIME_IP}"
        rlRun "limeUpdateConf verifier check_client_cert True"
        rlRun "limeUpdateConf verifier tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf verifier trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf verifier trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf verifier server_cert keylime-cert.pem"
        rlRun "limeUpdateConf verifier server_key keylime-key.pem"
        rlRun "limeUpdateConf verifier client_cert keylime-client-cert.pem"
        rlRun "limeUpdateConf verifier client_key keylime-client-key.pem"
        rlRun "limeUpdateConf revocations zmq_ip ${KEYLIME_IP}"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"

        # configure registrar
        rlRun "limeUpdateConf registrar ip ${KEYLIME_IP}"
        rlRun "limeUpdateConf registrar check_client_cert True"
        rlRun "limeUpdateConf registrar tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf registrar trusted_client_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf registrar server_cert keylime-cert.pem"
        rlRun "limeUpdateConf registrar server_key keylime-key.pem"
 
        # configure tenant
        rlRun "limeUpdateConf tenant registrar_ip ${KEYLIME_IP}"
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf tenant verifier_ip ${KEYLIME_IP}"
        rlRun "limeUpdateConf tenant tls_dir ${CERTDIR}"
        rlRun "limeUpdateConf tenant trusted_server_ca '[\"cacert.pem\"]'"
        rlRun "limeUpdateConf tenant client_cert keylime-client-cert.pem"
        rlRun "limeUpdateConf tenant client_key keylime-client-key.pem"
	cp /etc/keylime/tenant.conf /var/tmp

        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"

        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        rlRun "sync-set KEYLIME_SETUP_DONE"
        rlRun "sync-block AGENT_SETUP_DONE ${AGENT_IP}" 0 "Waiting for the Agent to finish setup"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Add Agent"
        # register AGENT and confirm it has passed validation
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlRun "wget -O policy.json 'http://${AGENT_IP}:8000/policy.json'"
        rlRun "cat policy.json"
        rlRun "keylime_tenant -t ${AGENT_IP} -u ${AGENT_ID} --runtime-policy policy.json --file /etc/hosts -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
        rlRun "sync-set AGENT_ADDED"
    rlPhaseEnd

    rlPhaseStartCleanup "Verifier cleanup"
        rlRun "kill $HTTP_PID"
        rlRun "limeStopVerifier"
        rlRun "limeStopRegistrar"
        limeSubmitCommonLogs
    rlPhaseEnd
}


AgentSetup() {
    rlPhaseStartSetup "Agent setup"

        # Agent and tenant setup goes here
        rlRun "sync-block KEYLIME_SETUP_DONE ${KEYLIME_IP}" 0 "Waiting for the keylime to finish setup"

        # download certificates from keylime server
        CERTDIR=/var/lib/keylime/certs
        SECUREDIR=/var/lib/keylime/secure
        rlRun "mkdir -p ${CERTDIR}"
        rlRun "mkdir -p $SECUREDIR"
        for F in cacert.pem agent-key.pem agent-cert.pem; do
            rlRun "wget -O ${CERTDIR}/$F 'http://$KEYLIME:8000/$F'"
        done
        id keylime && rlRun "chown -R keylime:keylime ${CERTDIR}"
        # agent mTLS certs are supposed to be in the SECUREDIR
        rlRun "mount -t tmpfs -o size=2m,mode=0700 tmpfs ${SECUREDIR}"
        rlRun "cp ${CERTDIR}/{agent-key.pem,agent-cert.pem} ${SECUREDIR}"
        id keylime && rlRun "chown -R keylime:keylime ${SECUREDIR}"

        # tls_dir not supported by the Rust agent, using /var/lib/keylime by default
        rlRun "limeUpdateConf agent ip '\"${AGENT_IP}\"'"
        rlRun "limeUpdateConf agent contact_ip '\"${AGENT_IP}\"'"
        rlRun "limeUpdateConf agent registrar_ip '\"${KEYLIME_IP}\"'"
        rlRun "limeUpdateConf agent trusted_client_ca '\"${CERTDIR}/cacert.pem\"'"
        rlRun "limeUpdateConf agent server_key '\"${CERTDIR}/agent-key.pem\"'"
        rlRun "limeUpdateConf agent server_cert '\"${CERTDIR}/agent-cert.pem\"'"
        rlRun "limeUpdateConf agent revocation_notification_ip '\"${KEYLIME_IP}\"'"

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            limeInstallIMAConfig
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5

        rlRun "limeStartAgent"
        # create allowlist and excludelist
        limeCreateTestPolicy

        # expose lists to Agent
        rlRun "mkdir http"
        rlRun "cp policy.json allowlist.txt excludelist.txt http"
        rlRun "pushd http"
        rlRun "python3 -m http.server 8000 &"
        HTTP_PID=$!
        rlRun "popd"

        rlRun "sync-set AGENT_SETUP_DONE"
        rlRun "sync-block AGENT_ADDED ${KEYLIME_IP}" 0 "Waiting for the keylime to add agent"
    rlPhaseEnd

    rlPhaseStartCleanup "Agent cleanup"
        rlRun "kill $HTTP_PID"
        rlRun "limeStopAgent"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
    rlPhaseEnd
}


####################
# Common script part
####################

export TESTSOURCEDIR=`pwd`

rlJournalStart
    rlPhaseStartSetup
        # import keylime library
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "./sync"' || rlDie "cannot import keylime-tests/sync library"
        rlRun 'rlImport "openssl/certgen"' || rlDie "cannot import openssl/certgen library"

        assign_server_roles

        rlLog "KEYLIME: $KEYLIME ${KEYLIME_IP}"
        rlLog "AGENT: ${AGENT} ${AGENT_IP}"
	rlLog "This system is: $(hostname) ${MY_IP}"

        ###############
        # common setup
        ###############

        # this is the default ID, we are not changing it
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

        rlAssertRpm keylime
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
        # backup files
        limeBackupConfig
        rlRun "pushd $TmpDir"
    rlPhaseEnd

    if echo " $HOSTNAME $MY_IP " | grep -q " ${KEYLIME_IP} "; then
        KeylimeSetup
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${AGENT_IP} "; then
        AgentSetup
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
