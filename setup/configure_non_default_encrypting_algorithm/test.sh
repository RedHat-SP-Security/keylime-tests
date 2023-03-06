#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "cat > /etc/profile.d/export_KEYLIME_TEST_USE_NON_DEFAULT_ALGORITHM.sh <<_EOF
export KEYLIME_TEST_USE_NON_DEFAULT_ALGORITHM=TRUE
_EOF"
    rlPhaseEnd

rlJournalEnd
