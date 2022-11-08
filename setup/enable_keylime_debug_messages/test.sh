#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
            # print keylime package versions
        echo cat /proc/swaps
        cat /proc/swaps
        echo cat /proc/meminfo
        grep '^Commit' /proc/meminfo
        echo cat /proc/sys/vm/overcommit_ratio
        cat /proc/sys/vm/overcommit_ratio
        echo cat /proc/sys/vm/overcommit_memory
        cat /proc/sys/vm/overcommit_memory

        rlRun "dmesg"
        rlRun "journalctl"


        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "limeUpdateConf logger_root level DEBUG"
        rlRun "limeUpdateConf logger_keylime level DEBUG"
        rlRun "limeUpdateConf handler_consoleHandler level DEBUG"
    rlPhaseEnd

rlJournalEnd
