#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

function set_api_versions() {
    local current="$1"
    local versions="$2"
    local latest="$3"
    local deprecated="$4"

    sed -i "s/^CURRENT_VERSION.*/CURRENT_VERSION = \"$current\"/" "$SRCFILE"
    sed -i "s/^VERSIONS.*/VERSIONS = $versions/" "$SRCFILE"
    sed -i "s/^LATEST_VERSIONS.*/LATEST_VERSIONS = $latest/" "$SRCFILE"
    sed -i "s/^DEPRECATED_VERSIONS.*/DEPRECATED_VERSIONS = $deprecated/" "$SRCFILE"

    # print new configuration
    grep -E '^(CURRENT_VERSION|VERSIONS|LATEST_VERSIONS|DEPRECATED_VERSIONS)' "$SRCFILE"
}

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        limeEnableDebugLog
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
        # find source file where API versions are configured
        SRCFILE=$( find /usr -wholename '*/keylime/api_version.py' )
	rlFileBackup "$SRCFILE"
        # configure and start verifier
	rlRun "set_api_versions 2.1 '[\"2.0\", \"2.1\"]' '{\"2\": \"2.1\"}' '[]'"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        # configure and start registrar, use different versions than verifier
        rlRun "set_api_versions 2.3 '[\"2.2\", \"2.3\"]' '{\"2\": \"2.3\"}' '[]'"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        # configure tenant, use one common (not current/latest) version with verifier and registrar
        rlRun "set_api_versions 2.5 '[\"2.1\", \"2.3\", \"2.5\"]' '{\"2\": \"2.5\"}' '[]'"
        # configure and start agent, use one common version with tenant
        rlRun "limeUpdateConf agent api_versions '\"2.1, 2.2\"'"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Test common API version negotiation with verifier and registrar"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "Using API version 2.1 for verifier communication" "$rlRun_LOG"
        rlAssertGrep "https://127.0.0.1:8881 .*GET /v2.1/agents" "$rlRun_LOG" -E
        rlRun -s "keylime_tenant -c reglist"
        rlAssertGrep "Using API version 2.3 for registrar communication" "$rlRun_LOG"
        rlAssertGrep "https://127.0.0.1:8891 .*GET /v2.3/agents" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Test common API version negotiation with the agent"
        rlRun "limeCreateTestPolicy"
        rlRun -s "keylime_tenant -c add -u $AGENT_ID --verify --runtime-policy policy.json -f /etc/hostname"
        rlAssertGrep "Using API version 2.1 for agent communication" "$rlRun_LOG"
        rlAssertGrep "https://127.0.0.1:9002 .*GET /v2.1/keys/verify" "$rlRun_LOG" -E
        rlRun -s "keylime_tenant -c delete -u $AGENT_ID"
    rlPhaseEnd

    rlPhaseStartTest "Test incorrect API version verifier and registrar"
        # set API versions incompatible with verifier and registrar
        rlRun "set_api_versions 2.4 '[\"2.4\"]' '{\"2\": \"2.4\"}' '[]'"
        rlRun -s "keylime_tenant -c cvlist" 1
        rlAssertNotGrep "Traceback" "$rlRun_LOG"
        # TODO: add rlAssertGrep for some reasonable error message
        rlRun -s "keylime_tenant -c reglist" 1
        rlAssertNotGrep "Traceback" "$rlRun_LOG"
        # TODO: add rlAssertGrep for some reasonable error message
    rlPhaseEnd

    rlPhaseStartTest "Test incorrect API version for the agent"
        # first check the agent since we need to be able to talk with verifier and registrar
        rlRun "set_api_versions 2.3 '[\"2.0\", \"2.3\"]' '{\"2\": \"2.3\"}' '[]'"
        rlRun -s "keylime_tenant -c add -u $AGENT_ID --verify --runtime-policy policy.json -f /etc/hostname" 1
        rlAssertNotGrep "Traceback" "$rlRun_LOG"
        rlAssertGrep "Agent.*has no compatible API" "$rlRun_LOG" -E
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
	rlFileRestore
        limeRestoreConfig
    rlPhaseEnd

rlJournalEnd
