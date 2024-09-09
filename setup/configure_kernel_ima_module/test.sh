#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -z "${IMA_APPRAISE}" ] && IMA_APPRAISE="fix"
[ -z "${IMA_POLICY}" ] && IMA_POLICY="tcb"
[ -z "${IMA_TEMPLATE}" ] && IMA_TEMPLATE="ima-ng"
[ -z "${IMA_POLICY_FILE}" ] && IMA_POLICY_FILE="ima-policy-simple"

COOKIE=/var/tmp/configure-kernel-ima-module-rebooted
TESTFILE=/var/tmp/configure-kernel-ima-module-test$$
SECUREBOOT=false

rlJournalStart

  if [ ! -e $COOKIE ]; then
    rlPhaseStartSetup "pre-reboot phase"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"

	# when in secure boot, install only when IMA CA key has been imported to MOK
	rlRun -s "mokutil --sb-state" 0,1,127
	grep -q 'enabled' $rlRun_LOG && SECUREBOOT=true

        if $SECUREBOOT; then
	    rlRun -s "keyctl show %:.machine"
	    grep -q 'keylime-tests-IMA-CA' $rlRun_LOG || rlDie "keylime-tests IMA CA is not present in MOK"
	fi
        # generate key and certificate for IMA
        rlRun "limeInstallIMAKeys"
	rlRun "openssl x509 -in ${limeIMACertificateDER} -text"
        # try to import keys into ima keyring - this doesn't work
        #rlRun "evmctl import ${limeIMACertificateDER} .ima"
        #rlRun "keyctl show %keyring:.ima"
        # regenerate initramfs to incorporate ima keys
        if $SECUREBOOT; then
            rlRun "cp ${limeIMACertificateDER} /etc/keys/ima/"
            rlRun "dracut --kver $(uname -r) --force --add integrity"
        fi
        # install IMA policy
        rlRun "limeInstallIMAConfig ${IMA_POLICY_FILE}"
        # sign policy file
        rlRun "evmctl ima_sign --hashalgo sha256 --key ${limeIMAPrivateKey} /etc/ima/ima-policy"
        rlRun "getfattr -m - -e hex -d /etc/ima/ima-policy"
        rlRun "grubby --info ALL"
        rlRun "grubby --default-index"
        if $SECUREBOOT; then
            rlRun "grubby --update-kernel DEFAULT --args 'ima_appraise=${IMA_APPRAISE} ima_canonical_fmt ima_policy=secure_boot ima_policy=${IMA_POLICY} ima_template=${IMA_TEMPLATE}'"
        else
            rlRun "grubby --update-kernel DEFAULT --args 'ima_appraise=${IMA_APPRAISE} ima_canonical_fmt ima_policy=${IMA_POLICY} ima_template=${IMA_TEMPLATE}'"
        fi
        rlRun -s "grubby --info DEFAULT | grep '^args'"
        rlAssertGrep "ima_appraise=${IMA_APPRAISE}" $rlRun_LOG
        rlAssertGrep "ima_canonical_fmt" $rlRun_LOG
        rlAssertGrep "ima_policy=${IMA_POLICY}" $rlRun_LOG
        rlAssertGrep "ima_template=${IMA_TEMPLATE}" $rlRun_LOG
        # on s390x run zipl to make change done through grubby effective
        [ "$(rlGetPrimaryArch)" == "s390x" ] && rlRun "zipl -V"
        rlRun "touch $COOKIE"
        # clear TPM
        if ! limeTPMEmulated && [ -c /dev/tpmrm0 ]; then
            rlRun "tpm2_clear"
        fi
        # FIXME: workaround for issue https://github.com/keylime/keylime/issues/1025
        rlRun "echo 'd /var/run/keylime 0700 keylime keylime' > /usr/lib/tmpfiles.d/keylime.conf"
        # ensure debugfs won't be mounted
        rlRun "rm -f /{lib,etc}/systemd/system/sysinit.target.wants/sys-kernel-debug.mount"
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

    rhts-reboot

  else
    rlPhaseStartTest "post-reboot IMA test"
        rlRun -s "cat /proc/cmdline"
        rlAssertGrep "ima_appraise=${IMA_APPRAISE}" $rlRun_LOG
        rlAssertGrep "ima_canonical_fmt" $rlRun_LOG
        rlAssertGrep "ima_policy=${IMA_POLICY}" $rlRun_LOG
        rlAssertGrep "ima_template=${IMA_TEMPLATE}" $rlRun_LOG
        rlRun "keyctl show %keyring:.ima"
        rlRun "grubby --info ALL"
        rlRun "grubby --default-index"
        rlRun "rm $COOKIE"

        if [ "${IMA_STATE}" == "on" -o "${IMA_STATE}" == "1" ]; then
            rlRun "touch ${TESTFILE} && cat ${TESTFILE} && rm ${TESTFILE}"
            rlRun "grep ${TESTFILE} /sys/kernel/security/ima/ascii_runtime_measurements"
        fi
        # wait 1 minute to let system load to settle down a bit
	SEC=60
        rlRun "sleep $SEC" 0 "Wait $SEC seconds to let system load to settle down"
    rlPhaseEnd
  fi

rlJournalEnd
