#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Setup keylime services"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        limeBackupConfig
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # Generate a signing key pair for cross-tool signature verification tests
        rlRun "openssl ecparam -name prime256v1 -genkey -noout -out sign-key.pem"
        rlRun "openssl ec -in sign-key.pem -pubout -out sign-pubkey.pem"
    rlPhaseEnd

    # Verify both tools produce structurally valid policies

    rlPhaseStartTest "Both tools produce valid runtime policies"
        rlRun "keylime-policy create runtime --ima-measurement-list -o policy-from-kp.json" 0 \
            "keylime-policy create runtime produces valid output"
        rlRun "keylimectl policy generate runtime --ima-measurement-list -o policy-from-kctl.json" 0 \
            "keylimectl policy generate runtime produces valid output"
        rlRun "jq . policy-from-kp.json > /dev/null" 0 "keylime-policy output is valid JSON"
        rlRun "jq . policy-from-kctl.json > /dev/null" 0 "keylimectl output is valid JSON"
        rlRun -s "jq -r 'keys | sort | .[]' policy-from-kp.json"
        KP_KEYS="$rlRun_LOG"
        rlRun -s "jq -r 'keys | sort | .[]' policy-from-kctl.json"
        KCTL_KEYS="$rlRun_LOG"
        if diff <(echo "$KP_KEYS") <(echo "$KCTL_KEYS"); then
            rlLog "Policy top-level keys are equivalent between tools"
        else
            rlLogWarning "Policy top-level keys differ between tools"
        fi
    rlPhaseEnd

    # Cross-tool enrollment: policy from one tool used with the other's agent add command

    rlPhaseStartTest "keylime-policy runtime policy used with keylimectl agent add"
        # Verify the keylime-policy JSON format is accepted by keylimectl (format compatibility)
        rlRun "keylimectl agent add ${AGENT_ID} --runtime-policy policy-from-kp.json" 0 \
            "keylimectl accepts a policy created by keylime-policy"
        rlRun -s "keylimectl agent status ${AGENT_ID}"
        rlRun "keylimectl agent remove ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "keylimectl runtime policy used with keylime_tenant add"
        # Verify the keylimectl JSON format is accepted by keylime_tenant (format compatibility)
        rlRun "cat > /tmp/enroll.expect <<_EOF
set timeout 30
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u ${AGENT_ID} --verify --cert default --runtime-policy policy-from-kctl.json -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\\n\"
expect eof
_EOF"
        rlRun "expect /tmp/enroll.expect" 0 "keylime_tenant accepts a policy created by keylimectl"
        rlRun -s "keylime_tenant -c status -u ${AGENT_ID}"
        rlRun "keylime_tenant -c delete -u ${AGENT_ID}"
        rlRun "keylime_tenant -c regdelete -u ${AGENT_ID}"
    rlPhaseEnd

    # Cross-tool signature verification: sign with one tool, verify with the other

    rlPhaseStartTest "Sign with keylime-policy, verify signature with keylimectl"
        rlRun "keylime-policy sign runtime -b ecdsa -k sign-key.pem -r policy-from-kp.json -o signed-by-kp.json"
        rlRun "jq . signed-by-kp.json > /dev/null" 0 "Signed policy is valid JSON"
        rlRun "keylimectl policy verify-signature signed-by-kp.json --key sign-pubkey.pem" 0 \
            "keylimectl can verify a signature produced by keylime-policy"
    rlPhaseEnd

    rlPhaseStartTest "Sign with keylimectl, verify signature with keylimectl"
        rlRun "keylimectl policy sign policy-from-kctl.json -b ecdsa -k sign-key.pem -o signed-by-kctl.json"
        rlRun "jq . signed-by-kctl.json > /dev/null" 0 "Signed policy is valid JSON"
        rlRun "keylimectl policy verify-signature signed-by-kctl.json --key sign-pubkey.pem" 0 \
            "keylimectl can verify its own signature"
    rlPhaseEnd

    # Policy server operations: push keylime-policy-created policy via keylimectl

    rlPhaseStartTest "Push keylime-policy-created policy to server via keylimectl"
        rlRun "keylimectl policy push interop-test-policy --file policy-from-kp.json"
        rlRun -s "keylimectl policy list"
        rlAssertGrep "interop-test-policy" "$rlRun_LOG"
        rlRun -s "keylimectl policy show interop-test-policy"
        rlAssertGrep "interop-test-policy" "$rlRun_LOG"
        rlRun "keylimectl policy delete interop-test-policy"
        rlRun "keylimectl policy show interop-test-policy" 1 "Policy no longer exists after deletion"
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup keylime services"
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
    rlPhaseEnd

rlJournalEnd
