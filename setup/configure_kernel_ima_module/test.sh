#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -z "$IMA_STATE" ] && IMA_STATE="on"
[ -z "$IMA_POLICY" ] && IMA_POLICY="tcb"

COOKIE=/var/tmp/configure-kernel-ima-module-rebooted
TESTFILE=/var/tmp/configure-kernel-ima-module-test$$

rlJournalStart

  if [ ! -e $COOKIE ]; then
    rlPhaseStartSetup "pre-reboot phase"
        rlRun "grubby --info DEFAULT | grep '^args'"
        rlRun "grubby --update-kernel DEFAULT --args 'ima=$IMA_STATE ima_policy=$IMA_POLICY'"
        rlRun -s "grubby --info DEFAULT | grep '^args'"
        rlAssertGrep "ima=$IMA_STATE" $rlRun_LOG
        rlAssertGrep "ima_policy=$IMA_POLICY" $rlRun_LOG
        rlRun "touch $COOKIE"

        # clear TPM
        rlRun "tpm2_clear"
        rhts-reboot
    rlPhaseEnd

  else
    rlPhaseStartTest "post-reboot IMA test"
        rlRun -s "cat /proc/cmdline"
        rlAssertGrep "ima=$IMA_STATE" $rlRun_LOG
        rlAssertGrep "ima_policy=$IMA_POLICY" $rlRun_LOG
        rlRun "rm $COOKIE"

        if [ "$IMA_STATE" == "on" -o "$IMA_STATE" == "1" ]; then
            rlRun "touch $TESTFILE && cat $TESTFILE && rm $TESTFILE"
            rlRun "grep $TESTFILE /sys/kernel/security/ima/ascii_runtime_measurements"
        fi
    rlPhaseEnd
  fi

rlJournalEnd
