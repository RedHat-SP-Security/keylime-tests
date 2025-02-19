#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

SCRIPT_URL="https://raw.githubusercontent.com/RedHat-SP-Security/keylime-tests/refs/heads/main/setup/switch_git_branch/autodetect.sh"

rlJournalStart

    rlPhaseStartTest
        # always download the latest version of the script from main
        rlRun "curl -o autodetect.sh '${SCRIPT_URL}'"
        if grep -q rlRun autodetect.sh; then
            . autodetect.sh
        else
            rlFail "Failed to download autodetect.sh script"
        fi
    rlPhaseEnd

rlJournalEnd
