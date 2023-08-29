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

    rlPhaseStartTest "Compile old keylime agent"
        # Store a backup of the installed binary
        rlRun "rlFileBackup --namespace agent /usr/bin/keylime_agent"
        rlRun "git clone ${RUST_KEYLIME_UPSTREAM_URL} ${WORKDIR}/rust-keylime"
        rlRun "pushd ${WORKDIR}/rust-keylime"
        rlRun "git checkout v0.2.1"
        # Workaround regression on proc-macro2 build with nightly compiler:
        # See: https://github.com/rust-lang/rust/issues/113152
        rlRun "cargo update -p proc-macro2 --precise 1.0.66"
        # Replace agent binary
        rlRun "cargo build && cp ./target/debug/keylime_agent /usr/bin/keylime_agent"
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent with old API version"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
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
        rlRun "rlFileRestore --namespace agent"
        rlRun "limeStartAgent"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID API version updated\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Verify that API version downgrade is not allowed"
        rlRun "limeStopAgent"
        rlRun "rlFileBackup --namespace agent /usr/bin/keylime_agent"
        rlRun "cp ${WORKDIR}/rust-keylime/target/debug/keylime_agent /usr/bin/keylime_agent"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - Agent $AGENT_ID API version 2.0 is lower or equal to previous version" "$(limeVerifierLogfile)"
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" "$(limeVerifierLogfile)"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "rlFileRestore --namespace agent"
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
    rlPhaseEnd

rlJournalEnd
