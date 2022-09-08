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
        rlRun "grcov . --binary-path /usr/local/bin/ -s . -t html --branch --ignore-not-existing -o e2e_coverage.html"
        # export coverage report in format compatible for codecov, gather code cover for all rust binaries
        rlRun "grcov . --binary-path /usr/local/bin/ -s . -t lcov --branch --ignore-not-existing -o e2e_coverage.txt"
        # create tar file for uploading coverage file
        rlRun "tar --create --file e2e_coverage.tar e2e_coverage.html"
        rlFileSubmit  e2e_coverage.tar
        rlFileSubmit e2e_coverage.txt
        if [ -f "e2e_coverage.tar" ]; then
            # upload e2e report in tar.gz
            rlRun -s "curl --upload-file e2e_coverage.tar $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "HTML code coverage report is available as GZIP archive at $URL"
        fi
        if [ -f "e2e_coverage.txt" ]; then
            #upload e2e report in .txt format
            rlRun -s "curl --upload-file e2e_coverage.txt $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "e2e_coverage.txt report is available at $URL"
        fi
        if [ -f "upstream_coverage.tar" ]; then
            #upload upstream report in .tar
            rlRun -s "curl --upload-file upstream_coverage.tar $UPLOAD_URL"
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

