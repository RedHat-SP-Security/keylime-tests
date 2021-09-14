#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Install TPM emulator"
        # configure Sergio's copr repo providing necessary dependencies
        rlIsRHEL 9 && rlRun "dnf -y copr enable copr.devel.redhat.com/scorreia/keylime rhel-9.dev-$(arch)"
        rlRun "yum -y install ibmswtpm2 cfssl"
    rlPhaseEnd

    rlPhaseStartSetup "Start TPM emulator"
        export TPM2TOOLS_TCTI="tabrmd:bus_name=com.intel.tss2.Tabrmd"
        rlLogInfo "exported TPM2TOOLS_TCTI=$TPM2TOOLS_TCTI"
        rlServiceStart ibm-tpm-emulator
    rlPhaseEnd

    rlPhaseStartTest "Test TPM emulator"
        rlRun -s "tpm2_pcrread"
        rlAssertGrep "0 : 0x0000000000000000000000000000000000000000" $rlRun_LOG
        rlServiceStop ibm-tpm-emulator
    rlPhaseEnd

rlJournalEnd
