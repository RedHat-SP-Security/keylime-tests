#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1


UPLOAD_URL=https://transfer.sh


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
        # create tar file for uploading coverage file
        rlRun "tar -czf e2e_coverage.tar.gz e2e_coverage.html"
        rlFileSubmit  e2e_coverage.tar.gz
        rlFileSubmit e2e_coverage.txt
        if [ -f "e2e_coverage.tar.gz" ]; then
            # upload e2e report in tar.gz
            rlRun -s "curl --upload-file e2e_coverage.tar.gz $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "HTML code coverage report is available as GZIP archive at $URL"
        fi
        if [ -f "e2e_coverage.txt" ]; then
            #upload e2e report in .txt format
            rlRun -s "curl --upload-file e2e_coverage.txt $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "e2e_coverage.txt report is available at $URL"
        fi
        if [ -f "upstream_coverage.tar.gz" ]; then
            #upload upstream report in .tar.gz
            rlRun -s "curl --upload-file upstream_coverage.tar.gz $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "HTML code coverage report is available as GZIP archive at $URL"
            fi
        if [ -f "upstream_coverage.xml" ]; then
            #upload
            rlRun -s "curl --upload-file upstream_coverage.xml $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "upstream_coverage.xml report is available at $URL"
        fi
        rlRun "popd"
    rlPhaseEnd

rlJournalEnd

