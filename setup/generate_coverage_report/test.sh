#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "which coverage"
        rlRun "pushd $__INTERNAL_limeCoverageDir"
    rlPhaseEnd

    rlPhaseStartTest
        rlRun "coverage combine"
        rlAssertExists .coverage
        rlRun "coverage html --include '*keylime*' --show-contexts"
        rlRun "coverage report --include '*keylime*'"
        rlRun "cd .."
        rlRun "tar -czf coverage.tar.gz coverage"
    rlPhaseEnd

    rlPhaseStartCleanup
        rlFileSubmit coverage.tar.gz
        rlRun "popd"
    rlPhaseEnd
 
rlJournalEnd
