#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
	# update /etc/keylime.conf
        rlFileBackup /etc/keylime.conf
        rlRun "sed -i 's/^require_ek_cert.*/require_ek_cert = False/' /etc/keylime.conf"
        rlRun "sed -i 's/^ca_implementation.*/ca_implementation = openssl/' /etc/keylime.conf"
        # if IBM TPM emulator is present
        if rpm -q ibmswtpm2; then
            # start tpm emulator
            rlServiceStart ibm-tpm-emulator
            # make sure tpm2-abrmd is running
            pidof tpm2-abrmd || rlServiceStart tpm2-abrmd
            # start ima emulator
            PID_TEMP=$( pgrep keylime_ima_emulator ) && rlRun "kill $PID_TEMP"
            #rlRun "mkdir -p /etc/ima && cp ./ima-policy /etc/ima/ima-policy"
            rlRun "cat ./ima-policy > /sys/kernel/security/ima/policy"
            export TPM2TOOLS_TCTI=tabrmd:bus_name=com.intel.tss2.Tabrmd
            rlRun "keylime_ima_emulator &> ima_emulator.log &"
        else
            rlServiceStart tpm2-abrmd
        fi
        sleep 5
        # start keylime_verifier
        rlRun "keylime_verifier &> verifier.log &"
        sleep 5
        rlRun "keylime_registrar &> registrar.log &"
        sleep 5
        rlRun "keylime_agent &> agent.log &"
        sleep 5
        # create allowlist
        rlRun "curl -s 'https://raw.githubusercontent.com/keylime/keylime/master/scripts/create_allowlist.sh' -o create_allowlist.sh"
        rlRun "bash create_allowlist.sh allowlist.txt sha256sum"
        # create rejectlist excluding all current content
        rlRun 'for DIR in /*; do echo "$DIR/.*" >> excludes.txt; done'
        cat excludes.txt
    rlPhaseEnd

    rlPhaseStartSetup "Add keylime tenant"
        AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID -f excludes.txt --allowlist allowlist.txt --exclude excludes.txt -c add"
        sleep 5
        rlRun -s "keylime_tenant -c list"
        rlAssertGrep "{'agent_id': '$AGENT_ID'}" $rlRun_LOG
        rlRun -s "keylime_tenant -c status -u $AGENT_ID"
        rlAssertGrep 'Agent Status: "Get Quote"' $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartSetup "Fail keylime tenant"
        rlRun "echo -e '#!/bin/bash\necho boom' > /keylime-bad-script.sh && chmod a+x /keylime-bad-script.sh"
        rlRun "/keylime-bad-script.sh"
        sleep 5
        rlAssertGrep "WARNING - File not found in allowlist: /keylime-bad-script.sh" verifier.log
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" verifier.log
        rlRun -s "keylime_tenant -c status -u $AGENT_ID"
        rlAssertGrep 'Agent Status: "(Failed|Invalid Quote)"' $rlRun_LOG -E
    rlPhaseEnd

rlJournalEnd
