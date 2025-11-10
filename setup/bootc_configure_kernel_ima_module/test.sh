#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# you can use KEYLIME_BOOTC_BASE_IMAGE variable to override a base image in Containerfile
KEYLIME_PODMAN_BUILD_ARGS=""

SHORT_IMAGE_NAME=bootc_setup_image
IMPORTED_IMAGE_NAME="localhost/${SHORT_IMAGE_NAME}"
# set the default base image based on what's available on the system
if [ -z "${KEYLIME_BOOTC_BASE_IMAGE}" ]; then
    if podman images | grep -q "${IMPORTED_IMAGE_NAME}"; then
        KEYLIME_BOOTC_BASE_IMAGE="${IMPORTED_IMAGE_NAME}"
    else
        KEYLIME_BOOTC_BASE_IMAGE="localhost/bootc:latest"
    fi
fi

KEYLIME_PODMAN_BUILD_ARGS="${KEYLIME_PODMAN_BUILD_ARGS} --build-arg KEYLIME_BOOTC_BASE_IMAGE='${KEYLIME_BOOTC_BASE_IMAGE}'"
# you can use KEYLIME_BOOTC_INSTALL_PACKAGES variable to override packages installed in Containerfile
[ -n "${KEYLIME_BOOTC_INSTALL_PACKAGES}" ] && KEYLIME_PODMAN_BUILD_ARGS="${KEYLIME_PODMAN_BUILD_ARGS} --build-arg KEYLIME_BOOTC_INSTALL_PACKAGES='${KEYLIME_BOOTC_INSTALL_PACKAGES}'"

[ -z "${IMA_APPRAISE}" ] && IMA_APPRAISE="log"
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
        # copy various data to CWD so we can add them to the image
        rlRun "cp -r /root/.ssh ."
        rlRun "cp /etc/resolv.conf ."
	rlRun "cp -r /etc/yum.repos.d yum.repos.d"
        # download bootc image and build and install an update
	[ "${KEYLIME_BOOTC_BASE_IMAGE}" == "localhost/bootc:latest" ] && rlRun "bootc image copy-to-storage"
	rlRun "podman build ${KEYLIME_PODMAN_BUILD_ARGS} -t localhost/keylime_test_setup ."
	rlRun "bootc switch --transport containers-storage localhost/keylime_test_setup"
	# configure /keylime-tests mount point
        rlRun "dd if=/dev/zero of=/var/keylime-tests.img bs=1M count=100"
        rlRun "mkfs.ext4 /var/keylime-tests.img"
        rlRun "echo '/var/keylime-tests.img /keylime-tests ext4 loop' >> /etc/fstab"
        if rpm -q keylime-base || rpm -q keylime-agent-rust; then
            rlRun "ls -ld /etc/keylime /var/lib/keylime"
            rlRun "ls -lR /etc/keylime /var/lib/keylime"
        fi
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
        rlRun "ls -ld /etc/keylime /var/lib/keylime"
        rlRun "ls -lR /etc/keylime /var/lib/keylime"
        rlRun "rm $COOKIE"
    rlPhaseEnd
  fi

rlJournalEnd
