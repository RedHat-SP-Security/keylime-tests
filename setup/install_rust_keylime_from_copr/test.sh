#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartTest "Enable repo and install rust keylime RPMs"
        rpm -q keylime-agent-rust && rlRun "yum -y remove --noautoremove keylime-agent-rust"
        # backup previous config file
        [ -f /etc/keylime/agent.conf ] && rlRun "mv /etc/keylime/agent.conf /etc/keylime/agent.conf.backup$$"
        rlIsFedora && rlRun "dnf -y copr enable packit/keylime-rust-keylime-master-fedora"
        if rlIsRHELLike; then
            _ARCH=$( rlGetPrimaryArch )
            _MAJOR=$( rlGetDistroRelease )
            rlRun "dnf -y copr enable packit/keylime-rust-keylime-master-centos centos-stream-${_MAJOR}-${_ARCH}"
        fi
        rlRun "echo 'priority=1' >> /etc/yum.repos.d/*keylime-rust-keylime-master*.repo"
        rlRun "cat /etc/yum.repos.d/*keylime-rust-keylime-master*.repo"
        rlRun "yum -y install keylime-agent-rust keylime-agent-rust-push"
        rlAssertRpm keylime-agent-rust
        rlAssertExists /etc/keylime/agent.conf
        # prepare directory for drop-in adjustments
        rlRun "mkdir -p /etc/systemd/system/keylime_agent.service.d /etc/systemd/system/keylime_push_model_agent.service.d/"
        rlRun "mkdir -p /etc/keylime/agent.conf.d"
        # If the TPM_BINARY_MEASUREMENTS env var is set, set the binary
        # measurements location for the service
        if [ -n "${TPM_BINARY_MEASUREMENTS}" ]; then
            rlRun "cat > /etc/systemd/system/keylime_agent.service.d/30-measured_boot_location.conf <<_EOF
[Service]
Environment=\"TPM_BINARY_MEASUREMENTS=${TPM_BINARY_MEASUREMENTS}\"
_EOF"
            rlRun "cat > /etc/systemd/system/keylime_push_model_agent.service.d/30-measured_boot_location.conf <<_EOF
[Service]
Environment=\"KEYLIME_AGENT_MEASUREDBOOT_ML_PATH=${TPM_BINARY_MEASUREMENTS}\"
_EOF"

        fi
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rlPhaseStartTest "Test installed binaries"
        rlRun "keylime_agent --help" 0,1
    rlPhaseEnd

rlJournalEnd
