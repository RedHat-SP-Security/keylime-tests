#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

COOKIE=/var/tmp/configure-kernel-ima-module-rebooted

rlJournalStart

  if [ ! -e $COOKIE ]; then
    rlPhaseStartSetup "pre-reboot phase"
        rlRun "grubby --info ALL"
        rlRun "grubby --update-kernel DEFAULT --args 'rd.shell rd.debug log_buf_len=1M' --remove-args='quiet'"
        rlRun "grubby --info ALL"
        rlRun "touch $COOKIE"
    rlPhaseEnd

    rhts-reboot

  else
    rlPhaseStartTest "post-reboot IMA test"
        rlRun "grubby --info ALL"
        rlRun "rm $COOKIE"
	rlRun "sleep 60"
    rlPhaseEnd
  fi

rlJournalEnd
