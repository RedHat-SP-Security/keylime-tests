#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# you can use BOOTC_BASE_IMAGE variable to override a base image in Containerfile
PODMAN_BUILD_ARGS=""
[ -n "${BOOTC_BASE_IMAGE}" ] && PODMAN_BUILD_ARGS="${PODMAN_BUILD_ARGS} --build-arg BOOTC_BASE_IMAGE='${BOOTC_BASE_IMAGE}'"
# you can use BOOTC_INSTALL_PACKAGES variable to override packages installed in Containerfile
[ -n "${BOOTC_INSTALL_PACKAGES}" ] && PODMAN_BUILD_ARGS="${PODMAN_BUILD_ARGS} --build-arg BOOTC_INSTALL_PACKAGES='${BOOTC_INSTALL_PACKAGES}'"

[ -z "${IMA_APPRAISE}" ] && IMA_APPRAISE="fix"
[ -z "${IMA_POLICY}" ] && IMA_POLICY="tcb"
[ -z "${IMA_TEMPLATE}" ] && IMA_TEMPLATE="ima-ng"
[ -z "${IMA_POLICY_FILE}" ] && IMA_POLICY_FILE="ima-policy-simple"

COOKIE=/var/tmp/configure-kernel-ima-module-rebooted

rlJournalStart

  if [ ! -e $COOKIE ]; then
    rlPhaseStartSetup "pre-reboot phase"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        # copy IMA policy file
        rlRun "cp ${limeLibraryDir}/${IMA_POLICY_FILE} ima-policy"
	# prepare extra kernel arguments
	rlRun "cat > 10-ima_kargs.toml <<EOF
kargs = [\"ima_appraise=${IMA_APPRAISE}, ima_canonical_fmt, ima_policy=${IMA_POLICY}, ima_template=${IMA_TEMPLATE}\"]
EOF"
        # copy dnf repos
	rlRun "cp -r /etc/yum.repos.d yum.repos.d"
        # download bootc image and build and install an update
	[ "${BOOTC_BASE_IMAGE}" == "localhost/bootc:latest" ] && rlRun "bootc image copy-to-storage"
	rlRun "podman build ${PODMAN_BUILD_ARGS} -t localhost/test ."
	rlRun "bootc switch --transport containers-storage localhost/test"
	# configure /keylime-tests mount point
        rlRun "dd if=/dev/zero of=/var/keylime-tests.img bs=1M count=100"
        rlRun "mkfs.ext4 /var/keylime-tests.img"
        rlRun "echo '/var/keylime-tests.img /keylime-tests ext4 loop' >> /etc/fstab"
	rlRun "touch $COOKIE"
    rlPhaseEnd

    tmt-reboot

  else
    rlPhaseStartTest "post-reboot phase"
        rlRun "uname -a"
        rlRun -s "cat /proc/cmdline"
        rlAssertGrep "ima_appraise=${IMA_APPRAISE}" $rlRun_LOG
        rlAssertGrep "ima_canonical_fmt" $rlRun_LOG
        rlAssertGrep "ima_policy=${IMA_POLICY}" $rlRun_LOG
        rlAssertGrep "ima_template=${IMA_TEMPLATE}" $rlRun_LOG
        rlRun "dmesg &> dmesg.log"
        rlFileSubmit dmesg.log
        rlRun "rm $COOKIE"
    rlPhaseEnd
  fi

rlJournalEnd
