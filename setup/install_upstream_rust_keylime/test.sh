#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -n "${RUST_KEYLIME_UPSTREAM_URL}" ] || RUST_KEYLIME_UPSTREAM_URL="https://github.com/keylime/rust-keylime.git"
[ -n "${RUST_KEYLIME_UPSTREAM_BRANCH}" ] || RUST_KEYLIME_UPSTREAM_BRANCH="master"

rlJournalStart

    rlPhaseStartSetup "Build and install rust-keylime bits"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"

        if [ "${RPM_AGENT_COVERAGE}" == "1" ] && rpm -qa | grep keylime-agent-rust; then
            rlFetchSrcForInstalled "keylime-agent-rust"
            rlRun "rpm -i keylime-agent-rust*.src.rpm"
            rlRun "rpmbuild -bp ~/rpmbuild/SPECS/keylime-agent-rust.spec"
            rlRun "rm -f /var/tmp/rust_keylime_sources && ln -s ~/rpmbuild/BUILD/rust-keylime-* /var/tmp/rust_keylime_sources"
        fi

        if [ -d /var/tmp/rust-keylime_sources ]; then
            rlLogInfo "Compiling rust-keylime bits from /var/tmp/rust-keylime_sources"
        else
            rlLogInfo "Compiling rust-keylime from cloned upstream repo"
            rlRun "git clone -b ${RUST_KEYLIME_UPSTREAM_BRANCH} ${RUST_KEYLIME_UPSTREAM_URL} /var/tmp/rust-keylime_sources"
        fi
        rlRun "pushd /var/tmp/rust-keylime_sources"

        # backup previously created files
        [ -f /usr/bin/keylime_agent ] && rlRun "mv /usr/bin/keylime_agent /usr/bin/keylime_agent.backup"
        [ -f /etc/keylime/agent.conf ] && rlRun "mv /etc/keylime/agent.conf /etc/keylime/agent.conf.backup$$"

        # when TPM_BINARY_MEASUREMENTS is defined, compile with testing feature
        # to allow setting the binary measurements file location
        if [ -n "${TPM_BINARY_MEASUREMENTS}" ]; then
            CARGO_FLAGS="--features=testing"
        fi

        if [ "${KEYLIME_RUST_CODE_COVERAGE}" == "1" -o "${KEYLIME_RUST_CODE_COVERAGE}" == "true" ]; then
            rlRun "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --default-toolchain stable -y"
            rlRun "source /root/.cargo/env"
            rlRun "rustup component add llvm-tools-preview"
            #install parser for code coverage files
            rlRun "cargo install grcov"
            # -Z is deprecated, use -C
            RUSTFLAGS='-Cinstrument-coverage'
        fi

        #build
        rlRun "RUSTFLAGS='$RUSTFLAGS' cargo build ${CARGO_FLAGS}"
        rlRun "make install"

        # configure TPM to use sha256
        rlRun "mkdir -p /etc/keylime/agent.conf.d"
        rlRun 'cat > /etc/keylime/agent.conf.d/tpm_hash_alg.conf <<_EOF
[agent]
tpm_hash_alg = "sha256"
_EOF'

        # Install shim.py to allow running python actions
        # This should be removed once https://github.com/keylime/rust-keylime/issues/325 is fixed
        rlAssertExists tests/actions/shim.py
        rlRun "mkdir -p /usr/libexec/keylime"
        rlRun "cp tests/actions/shim.py /usr/libexec/keylime"
        rlRun "popd"

        # Add drop-in unit file updates
        rlRun "mkdir -p /etc/systemd/system/keylime_agent.service.d"
        rlRun "cat > /etc/systemd/system/keylime_agent.service.d/20-rust_log_trace.conf <<_EOF
[Service]
Environment=\"RUST_LOG=keylime_agent=trace\"
_EOF"

        # If the TPM_BINARY_MEASUREMENTS env var is set, set the binary
        # measurements location for the service
        if [ -n "${TPM_BINARY_MEASUREMENTS}" ]; then
            rlRun "cat > /etc/systemd/system/keylime_agent.service.d/30-measured_boot_location.conf <<_EOF
[Service]
Environment=\"TPM_BINARY_MEASUREMENTS=${TPM_BINARY_MEASUREMENTS}\"
_EOF"
        fi

        if [ "${KEYLIME_RUST_CODE_COVERAGE}" == "1" -o "${KEYLIME_RUST_CODE_COVERAGE}" == "true" ]; then
            rlRun "touch ${__INTERNAL_limeCoverageDir}/rust_keylime_codecoverage.profraw"
            id keylime && rlRun "chown -R keylime /var/tmp/limeLib && chmod -R g+w /var/tmp/limeLib"
            rlRun 'cat > ${__INTERNAL_limeCoverageDir}/coverage-script-stop.sh <<_EOF
#!/bin/sh
pushd ${__INTERNAL_limeCoverageDir}
COV_FILE=\$(mktemp rust_keylime_codecoverage-XXXXX  --suffix=.profraw)
cp rust_keylime_codecoverage.profraw \${COV_FILE}
popd
_EOF'
            rlRun "cat > /etc/systemd/system/keylime_agent.service.d/15-coverage.conf <<_EOF
[Service]
# set variable containing name of the currently running test
Environment=\"LLVM_PROFILE_FILE=${__INTERNAL_limeCoverageDir}/rust_keylime_codecoverage.profraw\"
# we need to change WorkingDirectory since .profraw* files will be stored there
WorkingDirectory=${__INTERNAL_limeCoverageDir}/
ExecStopPost=sh ${__INTERNAL_limeCoverageDir}/coverage-script-stop.sh
_EOF"
            #IMA emulator coverage, graceful shutdown of IMA emulator, allow SIGINT kill
            rlRun "touch $__INTERNAL_limeCoverageDir/enabled"
        fi
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_agent --help" 0,1
    rlPhaseEnd

rlJournalEnd
