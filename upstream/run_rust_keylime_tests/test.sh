#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        if [ -d /var/tmp/rust-keylime_sources ]; then
            rlLogInfo "Missing upstream rust keylime sources."
        else
            rlDie "Upstream keylime sources must be already downloaded."
        fi
        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        rlRun "pushd /var/tmp/rust-keylime_sources"
        # install for measuring code coverage
        if [ "${KEYLIME_RUST_CODE_COVERAGE}" == "1" -o "${KEYLIME_RUST_CODE_COVERAGE}" == "true" ]; then
            rlRun "cargo install cargo-tarpaulin"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Run cargo tests"
        rlRun "MOCKOON=1 cargo test --features testing -- --nocapture"
    rlPhaseEnd

    if [ "${KEYLIME_RUST_CODE_COVERAGE}" == "1" -o "${KEYLIME_RUST_CODE_COVERAGE}" == "true" ]; then
        rlPhaseStartTest "Run cargo tests and measure code coverage"
            #run cargo tarpaulin code coverage
            rlRun "MOCKOON=1 cargo tarpaulin --verbose --target-dir target/tarpaulin --workspace --exclude-files 'target/*' --ignore-panics --ignore-tests --out Xml --out Html --all-features -- --test-threads=1"
            rlRun "tar -czf upstream_coverage.tar.gz tarpaulin-report.html"
            rlRun "mv cobertura.xml upstream_coverage.xml"
            rlFileSubmit upstream_coverage.xml
            rlFileSubmit upstream_coverage.tar.gz
            rlRun "mv upstream_coverage.xml upstream_coverage.tar.gz ${__INTERNAL_limeCoverageDir}"
        rlPhaseEnd
    fi

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "popd"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
    rlPhaseEnd

rlJournalEnd
