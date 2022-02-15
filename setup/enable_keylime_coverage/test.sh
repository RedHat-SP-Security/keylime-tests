#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Install coverage script its dependencies"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'pip3 install coverage==5.5'
        rlRun "touch $__INTERNAL_limeCoverageDir/enabled"
    rlPhaseEnd

    rlPhaseStartTest "Check if the coverage script is installed"
        rlRun "coverage --help"
    rlPhaseEnd

rlJournalEnd
