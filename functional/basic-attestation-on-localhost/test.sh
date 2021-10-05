#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
	# update /etc/keylime.conf
	rlRun 'rlImport "keylime-tests/test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        limeBackupConfig
        rlRun "sed -i 's/^require_ek_cert.*/require_ek_cert = False/' /etc/keylime.conf"
        rlRun "sed -i 's/^ca_implementation.*/ca_implementation = openssl/' /etc/keylime.conf"
        # if IBM TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlServiceStart ibm-tpm-emulator
            # make sure tpm2-abrmd is running
            pidof tpm2-abrmd || rlServiceStart tpm2-abrmd
            # start ima emulator
            export TPM2TOOLS_TCTI=tabrmd:bus_name=com.intel.tss2.Tabrmd
            limeInstallIMAConfig
            limeStartIMAEmulator
        else
            rlServiceStart tpm2-abrmd
        fi
        sleep 5
        # start keylime_verifier
        limeStartVerifier
        sleep 5
        limeStartRegistrar
        sleep 5
        limeStartAgent
        sleep 5
        # create allowlist
        rlRun "curl -s 'https://raw.githubusercontent.com/keylime/keylime/master/scripts/create_allowlist.sh' -o create_allowlist.sh"
        rlRun "bash create_allowlist.sh allowlist.txt sha256sum"
        # create rejectlist excluding all current content
        rlRun 'for DIR in /*; do echo "$DIR/.*" >> excludes.txt; done'
        rlRun 'echo -e "/sysroot/etc/fstab\n/dracut-state.sh" >> excludes.txt'  # may not be present on FS
        cat excludes.txt
    rlPhaseEnd

    rlPhaseStartTest "Add keylime tenant"
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID -f excludes.txt --allowlist allowlist.txt --exclude excludes.txt -c add"
        sleep 5
        rlRun -s "keylime_tenant -c list"
        rlAssertGrep "{'agent_id': '$AGENT_ID'}" $rlRun_LOG
        rlRun -s "keylime_tenant -c status -u $AGENT_ID"
        rlAssertGrep 'Agent Status: "Get Quote"' $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime tenant"
        rlRun "echo -e '#!/bin/bash\necho boom' > /keylime-bad-script.sh && chmod a+x /keylime-bad-script.sh"
        rlRun "/keylime-bad-script.sh"
        sleep 5
        rlAssertGrep "WARNING - File not found in allowlist: /keylime-bad-script.sh" $(limeVerifierLogfile)
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
        rlRun -s "keylime_tenant -c status -u $AGENT_ID"
        rlAssertGrep 'Agent Status: "(Failed|Invalid Quote)"' $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeStopAgent
        limeStopRegistrar
        limeStopVerifier
        rlFileSubmit $(limeVerifierLogfile)
        rlFileSubmit $(limeRegistrarLogfile)
        rlFileSubmit $(limeAgentLogfile)
        if limeTPMEmulated; then
            limeStopIMAEmulator
            rlFileSubmit $(limeIMAEmulatorLogfile)
        fi
        limeClearData
        limeRestoreConfig
        rlRun "rm -f /keylime-bad-script.sh"
    rlPhaseEnd

rlJournalEnd
