#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Build and install rust-keylime bits"
        if [ -d /var/tmp/rust-keylime_sources ]; then
            rlLogInfo "Compiling rust-keylime bits from /var/tmp/rust-keylime_sources"
            rlRun "pushd /var/tmp/rust-keylime_sources"
        else
            rlLogInfo "Compiling rust-keylime from cloned upstream repo"
            rlRun "rm -rf rust-keylime && git clone https://github.com/keylime/rust-keylime.git"
            rlRun "pushd rust-keylime"
        fi
        rlRun "cargo build"
        rlAssertExists target/debug/keylime_agent
        [ -f /usr/local/bin/keylime_agent ] && rlRun "mv /usr/local/bin/keylime_agent /usr/local/bin/keylime_agent.backup"
	rlRun "cp target/debug/keylime_agent /usr/local/bin/keylime_agent"
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "TCTI=tabrmd keylime_agent --help" 0,1
    rlPhaseEnd

rlJournalEnd
