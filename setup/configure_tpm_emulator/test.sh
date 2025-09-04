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

# Packages list based on the TPM emulator.
# We use ibmswtpm2 for EL8 and swtpm for the other platforms.
TPM_PKGS_SWTPM="swtpm swtpm-tools"
TPM_PKGS_IBMSWTPM="ibmswtpm2"
TPM_RUNTIME_TOPDIR="/var/lib/swtpm"
SETUP_MALFORMED_EK=false

rlJournalStart

    rlPhaseStartSetup "Install TPM emulator"

        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "echo socket > $__INTERNAL_limeTmpDir/swtpm_setup"

        TPM_EMULATOR="$(limeTPMEmulator)"
        [ "${TPM_EMULATOR}" == "ibmswtpm2" ] && TPM_PKGS="${TPM_PKGS_IBMSWTPM}" || TPM_PKGS="${TPM_PKGS_SWTPM}"

        export TPM2TOOLS_TCTI="tabrmd:bus_name=com.intel.tss2.Tabrmd"
        rlLogInfo "exported TPM2TOOLS_TCTI=$TPM2TOOLS_TCTI"
        # configure global environment variables
        rlRun "cat > /etc/profile.d/limeLib_tcti.sh <<_EOF
export TPM2TOOLS_TCTI=${TPM2TOOLS_TCTI}
export TCTI=${TPM2TOOLS_TCTI}
_EOF"

        # for RHEL and CentOS Stream configure Sergio's copr repo providing
        # necessary dependencies.
        if rlIsRHEL 8 || rlIsCentOS 8; then
            rlRun 'cat > /etc/yum.repos.d/keylime.repo <<_EOF
[copr:copr.fedorainfracloud.org:scorreia:keylime]
name=Copr repo for keylime owned by scorreia
baseurl=https://download.copr.fedorainfracloud.org/results/scorreia/keylime/centos-stream-\$releasever-\$basearch/
type=rpm-md
skip_if_unavailable=True
gpgcheck=1
gpgkey=https://download.copr.fedorainfracloud.org/results/scorreia/keylime/pubkey.gpg
repo_gpgcheck=0
enabled=1
enabled_metadata=1
priority=999
_EOF'
        fi

        rlRun "yum -y install ${TPM_PKGS} tpm2-tss selinux-policy-devel tpm2-abrmd tpm2-tools"
        # create swtpm unit file as it doesn't exist
        rlRun "cat > /etc/systemd/system/swtpm.service <<_EOF
[Unit]
Description=swtpm TPM Software emulator

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p ${TPM_RUNTIME_TOPDIR}/swtpm
ExecStartPre=/usr/bin/swtpm_setup --tpm-state ${TPM_RUNTIME_TOPDIR}/swtpm --createek --decryption --create-ek-cert --create-platform-cert --lock-nvram --overwrite --display --tpm2 --pcr-banks sha256
ExecStart=/usr/bin/swtpm socket --tpmstate dir=${TPM_RUNTIME_TOPDIR}/swtpm --log level=1 --ctrl type=tcp,port=2322 --server type=tcp,port=2321 --flags startup-clear --tpm2

[Install]
WantedBy=multi-user.target
_EOF"

        # we won't be doing TPM setup with malformed EK in some cases
        if [ -e /run/ostree-booted ]; then
            rlLogInfo "We are in RHEL Image mode, not doing setup of TPM with malformed EK"
        elif [ "$(rlGetPrimaryArch)" == "ppc64le" ]; then
            # we don't have all the tools available for ppc64le
            rlLogInfo "We are on ppc64le, not doing setup of TPM with malformed EK"
        elif [ "$(rlGetPrimaryArch)" == "s390x" ]; then
            # EK extraction fails on s390x
            rlLogInfo "We are on s390x, not doing setup of TPM with malformed EK"
        else
            SETUP_MALFORMED_EK=true
        fi

        # create also swtpm-malformed-ek unit file as it doesn't exist.
        if ${SETUP_MALFORMED_EK}; then
            rlRun "yum copr enable scorreia/keylime -y"
            rlRun "yum install -y swtpm-cert-manager"
            rlRun "cat > /etc/systemd/system/swtpm-malformed-ek.service <<_EOF
[Unit]
Description=swtpm TPM Software emulator with a malformed EK certificate

[Service]
Type=simple
ExecStartPre=/usr/bin/mkdir -p ${TPM_RUNTIME_TOPDIR}/swtpm-malformed-ek
ExecStartPre=/usr/bin/swtpm_setup --config /usr/share/swtpm-cert-manager/swtpm_setup_malformed.conf --tpm-state ${TPM_RUNTIME_TOPDIR}/swtpm-malformed-ek --createek --decryption --create-ek-cert --create-platform-cert --lock-nvram --overwrite --display --tpm2 --pcr-banks sha256
ExecStart=/usr/bin/swtpm socket --tpmstate dir=${TPM_RUNTIME_TOPDIR}/swtpm-malformed-ek --log level=1 --ctrl type=tcp,port=2322 --server type=tcp,port=2321 --flags startup-clear --tpm2

[Install]
WantedBy=multi-user.target
_EOF"
        fi


        # update tpm2-abrmd unit file
        _tcti=swtpm
        [ "${TPM_EMULATOR}" = "ibmswtpm2" ] && _tcti=mssim
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
ExecStart=/usr/sbin/tpm2-abrmd --tcti=${_tcti}
User=tss

[Install]
WantedBy=multi-user.target
_EOF"
        # also add drop-in update for eventual keylime_agent unit file
        rlRun "mkdir -p /etc/systemd/system/keylime_agent.service.d"
        rlRun "cat > /etc/systemd/system/keylime_agent.service.d/10-tcti.conf <<_EOF
[Unit]
# we want to unset this since there is no /dev/tmp0
ConditionPathExistsGlob=
[Service]
Environment=\"TPM2TOOLS_TCTI=${TPM2TOOLS_TCTI}\"
Environment=\"TCTI=${TPM2TOOLS_TCTI}\"
_EOF"
        rlRun "systemctl daemon-reload"

        if [ "${TPM_EMULATOR}" = "swtpm" ]; then
            # now we need to build custom selinux module making swtpm_t a permissive domain
            # since the policy module shipped with swtpm package doesn't seem to work
            # see https://github.com/stefanberger/swtpm/issues/632 for more details
            if semodule -l | grep -q swtpm_permissive; then
                rlRun "semodule -r swtpm_permissive"
            fi
            rlRun "make -f /usr/share/selinux/devel/Makefile swtpm_permissive.pp"
            rlAssertExists swtpm_permissive.pp
            rlRun "semodule -i swtpm_permissive.pp"
        fi
        # allow tpm2-abrmd to connect to swtpm port
        rlRun "setsebool -P tabrmd_connect_all_unreserved on"
        rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
    rlPhaseEnd

    rlPhaseStartSetup "Start TPM emulator"
        rlServiceStop tpm2-abrmd
        rlServiceStart $TPM_EMULATOR
        rlRun "limeWaitForTPMEmulator"
        rlServiceStart tpm2-abrmd
    rlPhaseEnd

    rlPhaseStartTest "Test TPM emulator"
        rlRun -s "tpm2_pcrread"
        rlAssertGrep "0 : 0x0000000000000000000000000000000000000000" $rlRun_LOG
        if ${SETUP_MALFORMED_EK}; then
            ek="${TmpDir}/ek.der"
            rlRun "tpm2_getekcertificate -o ${ek}"
            rlRun "limeValidateDERCertificateOpenSSL ${ek}" 0 "Validating EK certificate (${ek}) with OpenSSL"
            rlRun "limeValidateDERCertificatePyCrypto ${ek}" 0 "Validating EK certificate (${ek}) with python-cryptography"
        fi
        [ "$RUNNING" == "0" ] && rlServiceStop $TPM_EMULATOR
    rlPhaseEnd

    if [ "${TPM_EMULATOR}" = "swtpm" ]; then
        if ${SETUP_MALFORMED_EK}; then
            rlPhaseStartSetup "Start also TPM emulator with malformed EK"
                rlServiceStop tpm2-abrmd
                rlServiceStart swtpm-malformed-ek
                rlRun "limeWaitForTPMEmulator"
                rlServiceStart tpm2-abrmd
            rlPhaseEnd

            rlPhaseStartTest "Test also TPM emulator with malformed EK"
                rlRun -s "tpm2_pcrread"
                rlAssertGrep "0 : 0x0000000000000000000000000000000000000000" $rlRun_LOG
                ek="${TmpDir}"/swtpm-malformed-ek.der
                rlRun "tpm2_getekcertificate -o ${ek}"
                [ "$RUNNING" == "0" ] && rlServiceStop swtpm-malformed-ek

                # python-cryptography 35 changed its parsing of x509 certificates
                # and it became more strict, failing validation for some certificates
                # openssl would consider OK.
                # Let's adjust our expectation for the test based on the version
                # of python-cryptography we have available.
                _pyc_expected=0
                rlRun "pycrypto_version=\$(rpm -q python3-cryptography --qf '%{version}\n')"
                rlTestVersion "${pycrypto_version}" ">=" 35 && _pyc_expected=1

                rlRun "limeValidateDERCertificateOpenSSL ${ek}" 0 "Validating EK certificate (${ek}) with OpenSSL"
                # Recent versions of python-cryptography will consider this certificate invalid.
                rlRun "limeValidateDERCertificatePyCrypto ${ek}" "${_pyc_expected}" "Validating EK certificate (${ek}) with python-cryptography"
            rlPhaseEnd
        fi
    fi

    rlPhaseStartCleanup
        if [ "$RUNNING" == "0" ]; then
            rlServiceStop $TPM_EMULATOR
            rlServiceStop tpm2-abrmd
            [ "${TPM_EMULATOR}" = "swtpm" ] && ${SETUP_MALFORMED_EK} && rlServiceStop swtpm-malformed-ek
        fi
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalEnd
