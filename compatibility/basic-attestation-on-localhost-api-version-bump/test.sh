#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

[ -n "${RUST_KEYLIME_UPSTREAM_URL}" ] || RUST_KEYLIME_UPSTREAM_URL="https://github.com/keylime/rust-keylime.git"
[ -n "${RUST_KEYLIME_UPSTREAM_BRANCH}" ] || RUST_KEYLIME_UPSTREAM_BRANCH="master"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        # install recommend devel packages from CRB if missing
        rpm -q tpm2-tss-devel 2> /dev/null || INSTALL_PKGS="$INSTALL_PKGS tpm2-tss-devel"
        rpm -q libarchive-devel 2> /dev/null || INSTALL_PKGS="$INSTALL_PKGS libarchive-devel"
        if ! rpm -q zeromq-devel 2> /dev/null; then
            rlIsRHEL '<10' && INSTALL_PKGS="$INSTALL_PKGS zeromq-devel"
        fi
        rlIsRHEL '<10' && EPEL_ARG="--enablerepo epel" || EPEL_ARG=""
        [ -n "$INSTALL_PKGS" ] && rlRun "dnf --enablerepo \*CRB $EPEL_ARG -y install $INSTALL_PKGS"
        rlAssertRpm keylime

        # update /etc/keylime.conf
        limeBackupConfig
        # verifier
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        # tenant
        rlRun "limeUpdateConf tenant require_ek_cert False"
        # agent
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
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
        sleep 5
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        # create allowlist and excludelist
        rlRun "limeCreateTestPolicy"

        WORKDIR=$( mktemp -d -p "/var/tmp" )
    rlPhaseEnd

    rlPhaseStartTest "Compile keylime agent with old API version"
        # Store a backup of the installed binary
        rlRun "rlFileBackup --namespace agent /usr/bin/keylime_agent"
        # check if I am running agent from RPM file, i.e. not the upstream one
        # in this case I am going to use sources from RPM file because
        # I need to use the right version and extra patches from SRPM may
        # be necessary
        if rpm -q keylime-agent-rust && rpm -q --qf '%{VENDOR}' keylime-agent-rust | grep -qv 'Fedora Copr - user packit'; then
            rlLogInfo "Will use agent sources from SRPM"
            rlFetchSrcForInstalled keylime-agent-rust
            rlRun "rpm -i keylime-agent-rust*.src.rpm"
            rlRun "dnf -y builddep ~/rpmbuild/SPECS/keylime-agent-rust.spec"
            rlRun "rpmbuild -bp ~/rpmbuild/SPECS/keylime-agent-rust.spec --nodeps --define '_builddir $PWD'" 0,1
            if ls -d keylime-agent-rust*build; then
                rlRun "pushd keylime-agent-rust*build/rust-keylime*"
            else
                rlRun "rm -rf rust-keylime-*SPECPARTS"
                rlRun "pushd rust-keylime*"
            fi
        else
            rlLogInfo "Will use agent sources from upstream repo"
            rlRun "git clone ${RUST_KEYLIME_UPSTREAM_URL} ${WORKDIR}/rust-keylime"
            rlRun "pushd ${WORKDIR}/rust-keylime"
        fi
        # Get a supported version older than the current
        CURRENT_VERSION="$(grep -E '(^.*API_VERSION.*v)([0-9]+\.[0-9]+)' keylime-agent/src/common.rs | grep -o -E '[0-9]+\.[0-9]+')"
        OLD_VERSION="$(grep -o -E "Supported older API versions: .*" "$(limeVerifierLogfile)" | grep -o -E '[0-9]+\.[0-9]+' | sed -n "1,/^$CURRENT_VERSION\$/ p" | grep -v "^$CURRENT_VERSION\$" | tail -1)"

        # Replace the API version to fake an older version
        rlRun "cp keylime-agent/src/common.rs keylime-agent/src/common.rs.backup"
        rlRun "sed -i -E \"s/(^.*API_VERSION.*v)([0-9]+\.[0-9]+)/\1$OLD_VERSION/\" keylime-agent/src/common.rs"
        rlRun "diff keylime-agent/src/common.rs.backup keylime-agent/src/common.rs" 1
        # Replace agent binary
        rlRun "cargo build"
        rlRun "limeStopAgent"
        BUILDDIR=$PWD
        rlRun "cp ${BUILDDIR}/target/debug/keylime_agent /usr/bin/keylime_agent"
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Add keylime agent with old API version"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        rlAssertGrep "Starting server with API version v${OLD_VERSION}" "$(limeAgentLogfile)" -E
        rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json --cert default -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
        rlRun "expect script.expect"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd


    rlPhaseStartTest "Verify that API version is automatically bumped"
        rlRun "limeStopAgent"
        rlRun "rlFileRestore --namespace agent"
        rlRun "limeStartAgent"
        rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID API version updated\"' -m 10 -d 1 -t 10"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "Verify that API version downgrade is not allowed"
        rlRun "limeStopAgent"
        rlRun "cp ${BUILDDIR}/target/debug/keylime_agent /usr/bin/keylime_agent"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
        rlAssertGrep "WARNING - Agent $AGENT_ID API version $OLD_VERSION is lower or equal to previous version" "$(limeVerifierLogfile)"
        rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" "$(limeVerifierLogfile)"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "rlFileRestore --namespace agent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist "$WORKDIR"
	# remove recommend packages
        [ -n "$INSTALL_PKGS" ] && rlRun "yum -y remove $INSTALL_PKGS"
    rlPhaseEnd

rlJournalEnd
