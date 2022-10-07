#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"

        rlRun "cat /proc/cmdline"
        rlRun "sestatus"
        rlRun "rpm -qa | grep selinux-policy"
        rlRun "systemctl status auditd"
        rlRun "id -Z"
        rlRun "> /var/log/audit/audit.log"
        rlRun "passwd --help > /root/file.txt" 
        rlRun "cat /root/file.txt"

        rlRun "cat /var/log/audit/audit.log"
        rlRun "ausearch -m avc --input-logs"
    rlPhaseEnd

rlJournalEnd
