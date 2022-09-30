#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

BEAKERLIB_SCRIPT=/usr/share/beakerlib/logging.sh

rlJournalStart

    rlPhaseStartTest
        rlLogInfo "Injecting the test code into rlPhaseStartTest"
        rlRun "cp $BEAKERLIB_SCRIPT $BEAKERLIB_SCRIPT.pre_injection_backup.$$" 0 "Making backup of $BEAKERLIB_SCRIPT"
        if grep -q "__INTERNAL_TIMESTAMP_AVC" $BEAKERLIB_SCRIPT; then
            rlRun "echo 'It was already injected into' $BEAKERLIB_SCRIPT"
        else
            rlRun "sed -i '/rlPhaseStart()/a\    __INTERNAL_TIMESTAMP_AVC=\`LC_ALL=en_US.UTF-8 date \"+%x %T\"\`\n    export __INTERNAL_TIMESTAMP_AVC\n' $BEAKERLIB_SCRIPT"
            rlRun "sed -i '/^rlPhaseEnd()/a\    echo\n    echo \":: Test phase SELinux AVC denials since :: \$__INTERNAL_TIMESTAMP_AVC:\"\n    ausearch -m AVC -ts \$__INTERNAL_TIMESTAMP_AVC --input-logs && rlFail \"Found SELinux AVC denials within a test phase!\"' $BEAKERLIB_SCRIPT"
        fi
        #check status of the SELinux policy
        rlRun "sestatus"
    rlPhaseEnd

rlJournalEnd
