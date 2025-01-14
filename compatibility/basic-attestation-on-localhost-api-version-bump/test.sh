#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

[ -n "${RUST_KEYLIME_UPSTREAM_URL}" ] || RUST_KEYLIME_UPSTREAM_URL="https://github.com/keylime/rust-keylime.git"
[ -n "${RUST_KEYLIME_UPSTREAM_BRANCH}" ] || RUST_KEYLIME_UPSTREAM_BRANCH="master"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
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
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy"

        WORKDIR=$( mktemp -d -p "/var/tmp" )
    rlPhaseEnd

    rlPhaseStartTest "Get agent supported versions"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        mapfile -t SUPPORTED_VERSIONS< <(grep -ohE '> Starting server with API version.*' "$(limeAgentLogfile)" | grep -ohE '[0-9]+\.[0-9]+' | sort -V)
        if [[ "${#SUPPORTED_VERSIONS[@]}" -lt 2 ]]; then
            rlFail "Agent supports only one API version: ${SUPPORTED_VERSIONS[*]}"
        fi
        rlLog "Agent supported versions: ${SUPPORTED_VERSIONS[*]}"
        OLD_VERSION=${SUPPORTED_VERSIONS[0]}
        LATEST_VERSION=${SUPPORTED_VERSIONS[${#SUPPORTED_VERSIONS[@]} -1]}
        rlRun "limeStopAgent"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent with old API version"
        rlRun "limeUpdateConf agent api_versions \"\\\"${OLD_VERSION}\\\"\""
        rlRun "limeStartAgent"
        rlAssertGrep "Starting server with API versions: ${OLD_VERSION}$" "$(limeAgentLogfile)" -E
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd


    rlPhaseStartTest "Verify that API version is automatically bumped"
        rlRun "limeStopAgent"
        rlRun "limeUpdateConf agent api_versions \"\\\"${LATEST_VERSION}\\\"\""
        rlRun "limeStartAgent"
        rlAssertGrep "Starting server with API versions: ${LATEST_VERSION}$" "$(limeAgentLogfile)" -E
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID API version updated\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Verify that API version downgrade is not allowed"
        rlRun "limeStopAgent"
        rlRun "limeUpdateConf agent api_versions \"\\\"${OLD_VERSION}\\\"\""
        rlRun "limeStartAgent"
        rlAssertGrep "Starting server with API versions: ${OLD_VERSION}$" "$(limeAgentLogfile)" -E
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - Agent $AGENT_ID API version $OLD_VERSION is lower or equal to previous version" "$(limeVerifierLogfile)"
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" "$(limeVerifierLogfile)"
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
        limeExtendNextExcludelist "$WORKDIR"
	# remove recommend packages
        [ -n "$INSTALL_PKGS" ] && rlRun "yum -y remove $INSTALL_PKGS"
    rlPhaseEnd

rlJournalEnd
