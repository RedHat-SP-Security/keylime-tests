#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# required swtpm service state can be passed via RUNNING variable
# 1 = services running
# 0 = services stop (default)

[ "$RUNNING" == "1" ] || RUNNING=0

# Packages list based on the TPM emulator.
# We use ibmswtpm2 for EL8 and swtpm for the other platforms.
TPM_EMULATOR=swtpm
TPM_EMULATOR_BAD_EK=swtpm-malformed-ek
TPM_RUNTIME_TOPDIR="/var/lib/swtpm"

rlJournalStart

    rlPhaseStartSetup "Install TPM emulator"

        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rpm -q swtpm swtpm-tools || rlRun 'dnf -y install swtpm swtpm-tools'
        rlRun "echo device > $__INTERNAL_limeTmpDir/swtpm_setup"

        # load the kernel module
	rlRun "modprobe tpm_vtpm_proxy"
        rlRun "cat > /etc/modules-load.d/tpm_vtpm_proxy.conf <<_EOF
tpm_vtpm_proxy
_EOF"

        export TPM2TOOLS_TCTI="device:/dev/tpmrm$limeTPMDevNo"
        rlLogInfo "exported TPM2TOOLS_TCTI=$TPM2TOOLS_TCTI"

        # configure global environment variables if not already configured
	if ! grep "device:/dev/tpm" /etc/profile.d/limeLib_tcti.sh &> /dev/null; then
            rlRun "cat > /etc/profile.d/limeLib_tcti.sh <<_EOF
export TPM2TOOLS_TCTI=${TPM2TOOLS_TCTI}
export TCTI=${TPM2TOOLS_TCTI}
_EOF"
        fi

        # also add drop-in update for eventual keylime_agent unit files
	for AGENT_DIR in keylime_agent.service.d keylime_push_model_agent.service.d; do
	    if ! grep "device:/dev/tpm" /etc/systemd/system/${AGENT_DIR}/10-tcti.conf &> /dev/null; then
                rlRun "mkdir -p /etc/systemd/system/${AGENT_DIR}"
                rlRun "cat > /etc/systemd/system/${AGENT_DIR}/10-tcti.conf <<_EOF
[Service]
Environment=\"TPM2TOOLS_TCTI=${TPM2TOOLS_TCTI}\"
Environment=\"TCTI=${TPM2TOOLS_TCTI}\"
_EOF"
            fi
        done

        # find suffix for a new unit file (just in case it already exists)
        if ls /etc/systemd/system/swtpm*.service 2> /dev/null; then
            SUFFIX=$(( $( find /etc/systemd/system -name "swtpm*.service" | grep -v malformed | wc -l ) ))
        else
            SUFFIX=""
        fi
        # create swtpm unit file as it doesn't exist
        rlRun "mkdir -p ${TPM_RUNTIME_TOPDIR}"
        rlRun "SWTPM_DIR=\$( mktemp -d -p ${TPM_RUNTIME_TOPDIR} XXX )"
        rlLogInfo "Creating unit file /etc/systemd/system/swtpm${SUFFIX}.service"
        rlRun "cat > /etc/systemd/system/swtpm${SUFFIX}.service <<_EOF
[Unit]
Description=swtpm TPM Software emulator

[Service]
Type=simple
ExecStartPre=/usr/bin/swtpm_setup --tpm-state ${SWTPM_DIR} --createek --decryption --create-ek-cert --create-platform-cert --lock-nvram --overwrite --display --tpm2 --pcr-banks sha256
ExecStart=/usr/bin/swtpm chardev --vtpm-proxy --tpmstate dir=${SWTPM_DIR} --tpm2

[Install]
WantedBy=multi-user.target
_EOF"

        # Now let's create also a unit that configures swtpm with
        # a malformed EK certificate as per recent versions of
        # python-cryptography, but that openssl is able to parse.
	# do not configure TPM with malformed EK on Image mode system
        if [[ ! -e /run/ostree-booted ]]; then
            rlRun "dnf copr enable scorreia/keylime -y"
            rlRun "dnf install -y swtpm-cert-manager"
            rlRun "BAD_EK_SWTPM_DIR=\$( mktemp -d -p ${TPM_RUNTIME_TOPDIR} XXX )"
            rlLogInfo "Creating unit file /etc/systemd/system/swtpm-malformed-ek${SUFFIX}.service"
            rlRun "cat > /etc/systemd/system/swtpm-malformed-ek${SUFFIX}.service <<_EOF
[Unit]
Description=swtpm TPM Software emulator with a malformed EK certificate

[Service]
Type=simple
ExecStartPre=/usr/bin/swtpm_setup --config /usr/share/swtpm-cert-manager/swtpm_setup_malformed.conf --tpm-state ${BAD_EK_SWTPM_DIR} --createek --decryption --create-ek-cert --create-platform-cert --lock-nvram --overwrite --display --tpm2 --pcr-banks sha256
ExecStart=/usr/bin/swtpm chardev --vtpm-proxy --tpmstate dir=${BAD_EK_SWTPM_DIR} --tpm2

[Install]
WantedBy=multi-user.target
_EOF"
        fi

        rlRun "systemctl daemon-reload"

        # now we need to build custom selinux module making swtpm_t a permissive domain
        # since the policy module shipped with swtpm package doesn't seem to work
        # see https://github.com/stefanberger/swtpm/issues/632 for more details
        if ! semodule -l | grep -q swtpm_permissive; then
            rlRun "make -f /usr/share/selinux/devel/Makefile swtpm_permissive.pp"
            rlAssertExists swtpm_permissive.pp
            rlRun "semodule -i swtpm_permissive.pp"
        fi

	rlRun "TmpDir=\$(mktemp -d)" 0 "Creating tmp directory"
    rlPhaseEnd

    if ls /dev/tpmrm* 2> /dev/null; then
        # /dev/tpmX numbering starts with 0
        NEW_TPM_DEV_NO=$( find /dev -name "tpmrm*" | wc -l )
    else
        NEW_TPM_DEV_NO=0
    fi

    rlPhaseStartSetup "Start TPM emulator"
        rlServiceStart ${TPM_EMULATOR}${SUFFIX}
        rlRun "limeTPMDevNo=${NEW_TPM_DEV_NO} limeWaitForTPMEmulator"
    rlPhaseEnd

    rlPhaseStartTest "Test TPM emulator"
        rlRun -s "TPM2TOOLS_TCTI=device:/dev/tpmrm${NEW_TPM_DEV_NO} tpm2_pcrread"
        rlAssertGrep "0 : 0x0000000000000000000000000000000000000000" $rlRun_LOG
        ek="${TmpDir}/swtpm${SUFFIX}-ek.der"
        rlRun "tpm2_getekcertificate -o ${ek}"
        rlRun "limeValidateDERCertificateOpenSSL ${ek}" 0 "Validating EK certificate (${ek}) with OpenSSL"
        rlRun "limeValidateDERCertificatePyCrypto ${ek}" 0 "Validating EK certificate (${ek}) with python-cryptography"
        [ "$RUNNING" == "0" ] && rlServiceStop $TPM_EMULATOR${SUFFIX}
    rlPhaseEnd

    rlPhaseStartSetup "Start TPM emulator with malformed EK"
        rlServiceStart ${TPM_EMULATOR_BAD_EK}${SUFFIX}
        rlRun "limeTPMDevNo=${NEW_TPM_DEV_NO} limeWaitForTPMEmulator"
    rlPhaseEnd

    # do not test TPM with malformed EK on Image mode system
    if [[ ! -e /run/ostree-booted ]]; then
        rlPhaseStartTest "Test TPM emulator with malformed EK"
            rlRun -s "TPM2TOOLS_TCTI=device:/dev/tpmrm${NEW_TPM_DEV_NO} tpm2_pcrread"
            rlAssertGrep "0 : 0x0000000000000000000000000000000000000000" $rlRun_LOG
            ek="${TmpDir}/swtpm-malformed${SUFFIX}"-ek.der
            rlRun "tpm2_getekcertificate -o ${ek}"

            # python-cryptography 35 changed its parsing of x509 certificates
            # and it became more strict, failing validation for some certificates
            # openssl would consider OK.
            # Let's adjust our expectation for the test based on the version
            # of python-cryptography we have available.
            _pyc_expected=0
            rlRun "pycrypto_version=\$(rpm -q python3-cryptography --qf '%{version}\n')"
            rlTestVersion "${pycrypto_version}" ">=" 35 && _pyc_expected=1

            rlRun "limeValidateDERCertificateOpenSSL ${ek}" 0 "Validating EK certificate (${ek}) with OpenSSL"
            # Recent versions of python-crypgraphy will consider this certificate invalid.
            rlRun "limeValidateDERCertificatePyCrypto ${ek}" "${_pyc_expected}" "Validating EK certificate (${ek}) with python-cryptography"
            [ "$RUNNING" == "0" ] && rlServiceStop $TPM_EMULATOR_BAD_EK${SUFFIX}
        rlPhaseEnd
    fi

    rlPhaseStartCleanup
        if [ "$RUNNING" == "0" ]; then
            rlServiceStop $TPM_EMULATOR${SUFFIX}
            rlServiceStop $TPM_EMULATOR_BAD_EK${SUFFIX}
        fi
        rlRun "rm -r ${TmpDir}" 0 "Removing tmp directory"
    rlPhaseEnd

rlJournalEnd
