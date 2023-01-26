#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

COOKIE=/var/tmp/configure-kernel-ima-module-rebooted

rlJournalStart

  if [ ! -e $COOKIE ]; then
    rlPhaseStartSetup "pre-reboot phase"
        rlRun "touch $COOKIE"
        rlRun "cat > policy<<EOF
dont_measure fsmagic=0x9fa0
dont_measure fsmagic=0x62656572
dont_measure fsmagic=0x64626720
dont_measure fsmagic=0x01021994
dont_measure fsmagic=0x858458f6
dont_measure fsmagic=0x73636673
measure func=BPRM_CHECK
measure func=FILE_MMAP mask=MAY_EXEC
measure func=MODULE_CHECK uid=0
EOF"
        rlRun "cat policy > /sys/kernel/security/ima/policy"
	rlRun "mkdir /etc/ima"
        rlRun "cat policy > /etc/ima/ima-policy"
        rlRun "restorecon -Rv /etc/ima"
    rlPhaseEnd

    rhts-reboot

  else
    rlPhaseStartTest "post-reboot IMA test"
        rlRun -s "cat /proc/cmdline"
        rlRun "rm $COOKIE"
    rlPhaseEnd
  fi

rlJournalEnd
