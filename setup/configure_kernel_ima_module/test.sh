#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -z "$IMA_APPRAISE" ] && IMA_APPRAISE="fix"
[ -z "$IMA_POLICY" ] && IMA_POLICY="tcb"
[ -z "$IMA_TEMPLATE" ] && IMA_TEMPLATE="ima-sig"

COOKIE=/var/tmp/configure-kernel-ima-module-rebooted
TESTFILE=/var/tmp/configure-kernel-ima-module-test$$

rlJournalStart

  if [ ! -e $COOKIE ]; then
    rlPhaseStartSetup "pre-reboot phase"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "grubby --info DEFAULT | grep '^args'"
        rlRun "grubby --update-kernel DEFAULT --args 'ima_appraise=${IMA_APPRAISE} ima_policy=${IMA_POLICY} ima_template=${IMA_TEMPLATE}'"
        rlRun -s "grubby --info DEFAULT | grep '^args'"
        rlAssertGrep "ima_appraise=${IMA_APPRAISE}" $rlRun_LOG
        rlAssertGrep "ima_policy=${IMA_POLICY}" $rlRun_LOG
        rlAssertGrep "ima_template=${IMA_TEMPLATE}" $rlRun_LOG
        rlRun "touch $COOKIE"
        # generate key and certificate for IMA
        rlRun "limeInstallIMAKeys"
        # install IMA policy
        rlRun "limeInstallIMAConfig"
        # clear TPM
        rlRun "tpm2_clear"
    rlPhaseEnd

    rhts-reboot

  else
    rlPhaseStartTest "post-reboot IMA test"
        rlRun -s "cat /proc/cmdline"
        rlAssertGrep "ima_appraise=${IMA_APPRAISE}" $rlRun_LOG
        rlAssertGrep "ima_policy=${IMA_POLICY}" $rlRun_LOG
        rlAssertGrep "ima_template=${IMA_TEMPLATE}" $rlRun_LOG
        rlRun "rm $COOKIE"

        if [ "$IMA_STATE" == "on" -o "$IMA_STATE" == "1" ]; then
            rlRun "touch $TESTFILE && cat $TESTFILE && rm $TESTFILE"
            rlRun "grep $TESTFILE /sys/kernel/security/ima/ascii_runtime_measurements"
        fi
    rlPhaseEnd
  fi

rlJournalEnd
