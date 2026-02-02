#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Certificate SAN is "server", so we use that hostname and add /etc/hosts entry
VERIFIER_HOST="server"
VERIFIER_PORT="8881"

# Script location - upstream installed to /usr/share/keylime/scripts but not in PATH
# Check both locations for compatibility
if [ -x "/usr/bin/keylime_oneshot_attestation" ]; then
    ONESHOT_SCRIPT="/usr/bin/keylime_oneshot_attestation"
elif [ -x "/usr/share/keylime/scripts/keylime_oneshot_attestation" ]; then
    ONESHOT_SCRIPT="/usr/share/keylime/scripts/keylime_oneshot_attestation"
else
    ONESHOT_SCRIPT="keylime_oneshot_attestation"
fi

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup for one-shot attestation"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # Add hosts entry so "server" resolves to 127.0.0.1 (matches certificate SAN)
        rlFileBackup /etc/hosts
        rlRun "echo '127.0.0.1 server' >> /etc/hosts"

        # update /etc/keylime.conf
        limeBackupConfig
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # if TPM emulator is present
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        sleep 5
        # verify keylime_oneshot_attestation script exists and is executable
        rlLog "Using one-shot attestation script: ${ONESHOT_SCRIPT}"
        rlAssertExists "${ONESHOT_SCRIPT}"
        rlRun "test -x ${ONESHOT_SCRIPT}" 0 "Verify script is executable"
        # Backup script before modifications
        rlFileBackup "${ONESHOT_SCRIPT}"
        # Modify the oneshot script to point to our test bios measurements file instead of the default one.
        rlRun "sed -i 's%^MEASUREDBOOT_ML =.*%MEASUREDBOOT_ML = \"/var/tmp/binary_bios_measurements\"%' ${ONESHOT_SCRIPT}"
        rlRun "cp binary_bios_measurements /var/tmp"
        # Extend emulated TPM PCRs to match the boot event log
        if limeTPMEmulated; then
            rlRun "TPM_INTERFACE_TYPE=socsim tsseventextend -tpm -if /var/tmp/binary_bios_measurements"
        fi
        rlRun "keylime-policy create measured-boot -e /var/tmp/binary_bios_measurements -o mb_refstate.txt"

        # Create TPM policy with current PCR values (after extend so values are correct)
        rlRun "tpm2_pcrread sha256:0 -o pcr0.bin"
        PCR0_HASH=$(xxd -p pcr0.bin | tr -d '\n')
        rlLog "Current PCR 0 value: ${PCR0_HASH}"

        # Create valid TPM policy JSON with the current PCR value
        rlRun "cat > tpm_policy.json << EOF
{
    \"0\": [\"${PCR0_HASH}\"]
}
EOF"
        rlRun "cat tpm_policy.json"

        # Create invalid TPM policy with wrong PCR value (different from actual)
        WRONG_HASH="ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        rlRun "cat > tpm_policy_wrong.json << EOF
{
    \"0\": [\"${WRONG_HASH}\"]
}
EOF"

        # start keylime_verifier (no agent/registrar needed for one-shot)
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"

        # create test directory and scripts for IMA testing
        TESTDIR=$(limeCreateTestDir)
        rlRun "echo -e '#!/bin/bash\necho This is allowed-script' > $TESTDIR/allowed-script.sh && chmod a+x $TESTDIR/allowed-script.sh"
        rlRun "echo -e '#!/bin/bash\necho This is evil-script' > $TESTDIR/evil-script.sh && chmod a+x $TESTDIR/evil-script.sh"

        # create runtime policy (allowlist) that includes allowed-script and oneshot script
        # but not evil-script
        rlRun "limeCreateTestPolicy $TESTDIR/allowed-script.sh ${ONESHOT_SCRIPT}"

        # CA certificate for verifier TLS verification
        VERIFIER_CACERT="/var/lib/keylime/cv_ca/cacert.crt"
        rlAssertExists "${VERIFIER_CACERT}"
    rlPhaseEnd

    rlPhaseStartTest "Valid attestation with runtime and TPM policy"
        # execute the allowed script to get it into IMA log
        rlRun "${TESTDIR}/allowed-script.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep allowed-script.sh"
        # Test with both runtime policy (IMA allowlist), TPM policy (PCR values) and measured boot policy
        rlRun -st "${ONESHOT_SCRIPT} \
            --runtime-policy policy.json \
            --tpm-policy tpm_policy.json \
            --mb-policy mb_refstate.txt \
            --verifier-host ${VERIFIER_HOST} \
            --verifier-port ${VERIFIER_PORT} \
            --verifier-cacert ${VERIFIER_CACERT}" 0 "Run one-shot attestation with runtime and TPM policy"
        rlRun "grep -o \"'valid': True\" \"$rlRun_LOG\"" 0 "Attestation valid"
    rlPhaseEnd

    rlPhaseStartTest "Policy failure - TPM policy mismatch"
        # TPM policy with wrong PCR value should fail
        rlRun -s "${ONESHOT_SCRIPT} \
            --runtime-policy policy.json \
            --tpm-policy tpm_policy_wrong.json \
            --verifier-host ${VERIFIER_HOST} \
            --verifier-port ${VERIFIER_PORT} \
            --verifier-cacert ${VERIFIER_CACERT}" 0 "Run one-shot attestation with wrong TPM policy"

        rlAssertGrep "PCR value is not in allowlist" "$rlRun_LOG"
        rlAssertGrep "'valid': False" "$rlRun_LOG" -i
    rlPhaseEnd

    rlPhaseStartTest "Policy failure - file not in allowlist"
        # execute the evil script that is NOT in the allowlist
        rlRun "${TESTDIR}/evil-script.sh"
        rlRun "tail /sys/kernel/security/ima/ascii_runtime_measurements | grep evil-script.sh"

        rlRun -s "${ONESHOT_SCRIPT} \
            --runtime-policy policy.json \
            --verifier-host ${VERIFIER_HOST} \
            --verifier-port ${VERIFIER_PORT} \
            --verifier-cacert ${VERIFIER_CACERT}" 0 "Run one-shot attestation with policy violation"

        rlAssertGrep "'valid': False" "$rlRun_LOG" -i
        rlAssertGrep "ima.validation.ima-ng.not_in_allowlist" "$rlRun_LOG" -i
        rlAssertGrep "File not found in allowlist.*evil-script.sh" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Policy failure - file hash mismatch"
        # modify the allowed-script content after policy was created (changing its hash)
        rlRun "echo -e '#!/bin/bash\necho Modified content' > $TESTDIR/allowed-script.sh"

        # execute the modified script to get it into IMA log with its new hash
        rlRun "${TESTDIR}/allowed-script.sh"

        rlRun -s "${ONESHOT_SCRIPT} \
            --runtime-policy policy.json \
            --verifier-host ${VERIFIER_HOST} \
            --verifier-port ${VERIFIER_PORT} \
            --verifier-cacert ${VERIFIER_CACERT}" 0 "Run one-shot attestation with hash mismatch"

        rlAssertGrep "'valid': False" "$rlRun_LOG"
        rlAssertGrep "ima.validation.ima-ng.runtime_policy_hash" "$rlRun_LOG"
        rlAssertGrep "Hash not found in runtime policy" "$rlRun_LOG" -i
    rlPhaseEnd

    rlPhaseStartTest "Error handling - invalid policy file"
        # create an invalid JSON policy file
        rlRun "echo 'this is not valid json {{{' > invalid_policy.json"

        rlRun -s "${ONESHOT_SCRIPT} \
            --runtime-policy invalid_policy.json \
            --verifier-host ${VERIFIER_HOST} \
            --verifier-port ${VERIFIER_PORT} \
            --verifier-cacert ${VERIFIER_CACERT}" 1 "Run one-shot attestation with invalid policy"

        rlAssertGrep "Failure from verifier.*for oneshot data to verifier" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Error handling - untrusted CA certificate"
        # Create a self-signed CA certificate that is not trusted by the verifier
        rlRun "openssl req -x509 -newkey rsa:2048 -keyout untrusted_key.pem -out untrusted_ca.pem \
            -days 1 -nodes -subj '/CN=Untrusted CA' 2>/dev/null"

        rlRun -s "${ONESHOT_SCRIPT} \
            --runtime-policy policy.json \
            --verifier-host ${VERIFIER_HOST} \
            --verifier-port ${VERIFIER_PORT} \
            --verifier-cacert untrusted_ca.pem 2>&1" 1 "Run one-shot attestation with untrusted CA"

        rlAssertGrep "certificate verify failed: self-signed certificate in certificate chain" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Error handling - invalid verifier endpoint"
        rlRun -s "${ONESHOT_SCRIPT} \
            --runtime-policy policy.json \
            --verifier-host nonexistent.invalid \
            --verifier-port 9999 \
            --verifier-cacert ${VERIFIER_CACERT}" 1 "Run one-shot attestation with invalid verifier"

        rlAssertGrep "nonexistent.invalid" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # Restore original oneshot script if backup exists
        [ -f "${ONESHOT_SCRIPT}.backup" ] && rlRun "mv ${ONESHOT_SCRIPT}.backup ${ONESHOT_SCRIPT}"

        rlRun "limeStopVerifier"
        rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"

        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi

        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist "$TESTDIR"
        rlFileRestore
    rlPhaseEnd

rlJournalEnd
