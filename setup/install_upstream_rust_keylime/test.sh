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
        # when TPM_BINARY_MEASUREMENTS is defined, change filepath in sources
        if [ -n "${TPM_BINARY_MEASUREMENTS}" ]; then
            rlRun "sed -i 's%/sys/kernel/security/tpm0/binary_bios_measurements%${TPM_BINARY_MEASUREMENTS}%' src/common.rs"
            rlRun "sed -i 's%/sys/kernel/security/tpm0/binary_bios_measurements%${TPM_BINARY_MEASUREMENTS}%' src/main.rs"
        fi
        rlRun "cargo build"
        rlAssertExists target/debug/keylime_agent
        [ -f /usr/local/bin/keylime_agent ] && rlRun "mv /usr/local/bin/keylime_agent /usr/local/bin/keylime_agent.backup"
        rlRun "cp target/debug/keylime_agent /usr/local/bin/keylime_agent"

        # Install shim.py to allow running python actions
        # This should be removed once https://github.com/keylime/rust-keylime/issues/325 is fixed
        rlAssertExists tests/actions/shim.py
        rlRun "mkdir -p /usr/libexec/keylime"
        rlRun "cp tests/actions/shim.py /usr/libexec/keylime"
        rlRun "popd"

        # Add drop-in update to enable logging output
        if [ -f /usr/lib/systemd/system/keylime_agent.service -o -f /etc/systemd/system/keylime_agent.service ]; then
            rlRun "mkdir -p /etc/systemd/system/keylime_agent.service.d"
            rlRun "cat > /etc/systemd/system/keylime_agent.service.d/20-rust_log_trace.conf <<_EOF
[Service]
Environment=\"RUST_LOG=keylime_agent=trace\"
_EOF"
            rlRun "systemctl daemon-reload"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_agent --help" 0,1
    rlPhaseEnd

rlJournalEnd
