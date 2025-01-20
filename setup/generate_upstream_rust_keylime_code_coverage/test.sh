#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Collect code coverage for rust components"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        #delete coverage script, in dir are mandatory only coverage files
        rlRun "pushd ${__INTERNAL_limeCoverageDir}"
        # export in format for user, gather code cover for all rust binaries
        rlRun "source /root/.cargo/env"
        FILES_COUNT=$( grcov . --binary-path /usr/bin/ -s /var/tmp/rust-keylime_sources -t files --ignore-not-existing | wc -l | cut -d ' ' -f 1 )
        rlAssertGreater "At least 50 files should have been measured ($FILES_COUNT)" $FILES_COUNT 50
        rlRun "grcov . --binary-path /usr/bin/ -s /var/tmp/rust-keylime_sources -t html --ignore-not-existing -o e2e_coverage.html"
        # export coverage report in format compatible for codecov, gather code cover for all rust binaries
        rlRun "grcov . --binary-path /usr/bin/ -s /var/tmp/rust-keylime_sources -t lcov --ignore-not-existing -o e2e_coverage.txt"
        # compress files for uploading
        [ -f e2e_coverage.html ] && \
                rlRun "tar -czf e2e_coverage.tar.gz e2e_coverage.html" && \
                rlFileSubmit e2e_coverage.tar.gz
        [ -f e2e_coverage.txt ] && \
                rlRun "tar -czf e2e_coverage.txt.tar.gz e2e_coverage.txt" && \
                rlFileSubmit e2e_coverage.txt.tar.gz
        [ -f upstream_coverage.xml ] && \
                rlRun "tar -czf upstream_coverage.xml.tar.gz upstream_coverage.xml" && \
                rlFileSubmit upstream_coverage.xml.tar.gz
        rlRun "popd"
    rlPhaseEnd

rlJournalEnd

