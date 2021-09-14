#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# required service state can be passed via RUNNING variable
# 1 = services running
# 0 = services stop
# by default the status of tpm2-abrmd service is preserved

if [ "$RUNNING" != "0" -a "$RUNNING" != "1" ]; then
    systemctl is-active --quiet tpm2-abrmd && RUNNING=1 || RUNNING=0
fi

rlJournalStart

    rlPhaseStartSetup "Install TPM emulator"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        # configure Sergio's copr repo providing necessary dependencies
        rlRun 'cat > /etc/yum.repos.d/keylime.repo <<_EOF
[copr:copr.fedorainfracloud.org:scorreia:keylime-c9s]
name=Copr repo for keylime-c9s owned by scorreia
baseurl=https://download.copr.fedorainfracloud.org/results/scorreia/keylime-c9s/centos-stream-9-\$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/scorreia/keylime-c9s/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
_EOF'
        rlRun "yum -y install ibmswtpm2 cfssl"
        # update tpm2-abrmd unit file
        rlRun "cat > /etc/systemd/system/tpm2-abrmd.service <<_EOF
[Unit]
Description=TPM2 Access Broker and Resource Management Daemon
# These settings are needed when using the device TCTI. If the
# TCP mssim is used then the settings should be commented out.
#After=dev-tpm0.device
#Requires=dev-tpm0.device
ConditionPathExistsGlob=

[Service]
Type=dbus
BusName=com.intel.tss2.Tabrmd
ExecStart=/usr/sbin/tpm2-abrmd --tcti=mssim
User=tss

[Install]
WantedBy=multi-user.target
_EOF"
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rlPhaseStartSetup "Start TPM emulator"
        export TPM2TOOLS_TCTI="tabrmd:bus_name=com.intel.tss2.Tabrmd"
        rlLogInfo "exported TPM2TOOLS_TCTI=$TPM2TOOLS_TCTI"
        rlServiceStop tpm2-abrmd
        rlServiceStart ibm-tpm-emulator
        rlServiceStart tpm2-abrmd
        rlRun "limeWaitForTPMEmulator"
    rlPhaseEnd

    rlPhaseStartTest "Test TPM emulator"
        rlRun -s "tpm2_pcrread"
        rlAssertGrep "0 : 0x0000000000000000000000000000000000000000" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartCleanup
        if [ "$RUNNING" == "0" ]; then
            rlServiceStop ibm-tpm-emulator
            rlServiceStop tpm2-abrmd
        fi
    rlPhaseEnd

rlJournalEnd
