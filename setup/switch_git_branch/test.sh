#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartTest
        rlAssertRpm git
        rpm -q redhat-release || rlDie "Not running on RHEL!"
        rlLogInfo "Current working directory: ${PWD}"
        rlRun "git status"
        if [ -z "${SWITCH_TMT_TESTS_BRANCH}" ]; then
            rlLogInfo "No branch provided using SWITCH_TMT_TESTS_BRANCH variable, using autodetection"
            VERSION=$(rpm -q --qf "%{VERSION}" redhat-release)
            SWITCH_TMT_TESTS_BRANCH=$( git branch | grep "rhel-${VERSION}" | head -1)
            [ -z "$SWITCH_TMT_TESTS_BRANCH" ] && SWITCH_TMT_TESTS_BRANCH="rhel-9-main"
            rlLogInfo "Autodetected branch: $SWITCH_TMT_TESTS_BRANCH"
        fi
        rlLogInfo "Switching to branch ${SWITCH_TMT_TESTS_BRANCH}"
        rlRun "git checkout ${SWITCH_TMT_TESTS_BRANCH}"
        rlRun "git status"
    rlPhaseEnd

rlJournalEnd
