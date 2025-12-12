#!/bin/bash
set -exo pipefail

# author: Karel Srot, ksrot@redhat.com
# inspired by https://github.com/henrywang/tmt-bootc-install-switch/blob/main/tests/bootc-install.sh

# you can use BOOTC_BASE_IMAGE variable to override a base image in Containerfile
# you can use BOOTC_INSTALL_PACKAGES variable to override packages installed in Containerfile
# you can use BOOTC_DEBUGINFO_INSTALL_PACKAGES variable to add -debuginfo packages installed in Containerfile
# you can use BOOTC_RUN_CMD to add custom RUN command to Containerfile
# you can use BOOTC_ENV to export or add custom ENV to Containerfile (required due to RHEL-112366)
# you can use BOOTC_DNF_UPDATE set to '1' or 'true' perform dnf update during the build
# you can use BOOTC_KERNEL_ARGS variable to configure kernel cmdline parameters in the bootc-install-config format
#   Example: BOOTC_KERNEL_ARGS='["nosmt", "console=tty0"]'

SHORT_IMAGE_NAME=bootc_setup_image
IMPORTED_IMAGE_NAME="localhost/${SHORT_IMAGE_NAME}"
# set the default base image based on what's available on the system
if [ -z "${BOOTC_BASE_IMAGE}" ]; then
    if podman images | grep -q "${IMPORTED_IMAGE_NAME}"; then
        BOOTC_BASE_IMAGE="${IMPORTED_IMAGE_NAME}"
    else
        BOOTC_BASE_IMAGE="localhost/bootc:latest"
    fi
fi
BOOTC_INSTALL_PACKAGES="rsync bootc cloud-init ${BOOTC_INSTALL_PACKAGES}"

COOKIE=/var/tmp/bootc_test_prepare-rebooted

if [ ! -e $COOKIE ]; then
    echo "PHASE: pre-reboot phase"
    # install bootc and podman just in case it's missing and we are in package mode
    rpm -q bootc podman || dnf -y install bootc cloud-init podman system-reinstall-bootc

    # detect image mode
    if bootc status --format yaml | grep -qi 'ostree'; then
        IMAGE_MODE=true
    else
        IMAGE_MODE=false
    fi

    TMPDIR=$( mktemp -d -p /var/tmp)
    pushd "$TMPDIR"

    # prepare content to include into an image
    cp -r /etc/yum.repos.d .
    cp -r /root/.ssh .
    cp /etc/resolv.conf .
    TMT_SCRIPTS_DIR="$( dirname $( which tmt-reboot ) )"
    cp -r "$TMT_SCRIPTS_DIR" tmt_scripts
    # Copying NetworkManager connection profiles
    if ls /etc/NetworkManager/system-connections/* &> /dev/null; then
        mkdir -p NetworkManager/system-connections
        cp /etc/NetworkManager/system-connections/* NetworkManager/system-connections/
    fi

    # preserve special scripts when present
    mkdir local_bin
    for SCRIPT in /usr/local/bin/nvr-check-script.sh; do
        [ -f $SCRIPT ] && cp -p $SCRIPT local_bin
    done
	
    # download bootc image and build and install an update
    if [ "${BOOTC_BASE_IMAGE}" == "localhost/bootc:latest" ]; then
        #bootc image copy-to-storage
        # workaround for https://github.com/containers/bootc/issues/1134
        BOOTC_BASE_IMAGE=$( bootc status --booted --format json | jq '.spec.image.image' | tr -d '"' )
	if [ ${BOOTC_BASE_IMAGE} == "null" ]; then
            echo "Unable to identify base image, define BOOTC_BASE_IMAGE variable"
	    exit 1
	fi
    fi

    # prepare Containerfile
    cat > Containerfile <<_EOF
FROM ${BOOTC_BASE_IMAGE}
RUN mkdir -p -m 0700 /var/roothome && mkdir -p /usr/lib/bootc/kargs.d
COPY .ssh /var/roothome/.ssh
COPY tmt_scripts ${TMT_SCRIPTS_DIR}
COPY local_bin /usr/local/bin
COPY resolv.conf /etc/resolv.conf
RUN chmod -R a+x ${TMT_SCRIPTS_DIR} /usr/local/bin
_EOF

    # copy /var/tmp/brew-build-repo* and /var/tmp/opt-brew-build-repo* repos when present,
    # as well as /var/share/test-artifacts (repository of all downloaded artifacts)
    # https://docs.testing-farm.io/Testing%20Farm/0.1/test-environment.html#test-artifacts-repository
    REPODIRS=$( ls -d /var/tmp/{,opt-}brew-build-repo-* /var/share/test-artifacts || : )
    for REPODIR in $REPODIRS; do
	cp -r ${REPODIR} .
	echo "COPY $( basename $REPODIR ) $REPODIR" >> Containerfile
    done

    # copy repository configurations
    echo 'COPY yum.repos.d/* /etc/yum.repos.d' >> Containerfile

    # preserve NetworkManager connections config
    if [ -d NetworkManager ]; then
        echo 'COPY NetworkManager/system-connections/* /etc/NetworkManager/system-connections/' >> Containerfile
        echo 'RUN chmod 600 /etc/NetworkManager/system-connections/*' >> Containerfile
    fi

    # add installation of required packages
    cat >> Containerfile <<_EOF
RUN touch $COOKIE && \
    dnf -y install --nogpgcheck ${BOOTC_INSTALL_PACKAGES} && \
    ( [ -z "${BOOTC_DEBUGINFO_INSTALL_PACKAGES}" ] || dnf -y debuginfo-install --nogpgcheck ${BOOTC_DEBUGINFO_INSTALL_PACKAGES} ) && \
    (ln -s ../cloud-init.target /usr/lib/systemd/system/default.target.wants || true )
_EOF

    # include dnf update if requested
    if [ "${BOOTC_DNF_UPDATE}" == 'true' ] || [ "${BOOTC_DNF_UPDATE}" == '1' ] || [ "${BOOTC_DNF_UPDATE}" == 'y' ]; then
	# prepare script for performing dnf update
        cat > bootc_dnf_update.sh <<_EOF
#!/bin/bash
dnf -y update --exclude kernel\\*
echo "Checking for kernel updates..."
rpm -q kernel
dnf check-update kernel
if [ \$? -eq 100 ]; then
    echo "kernel update available, applying..."
    dnf remove -y kernel{,-core,-modules,-modules-core}
    dnf install -y kernel{,-core,-modules,-modules-core}
fi
_EOF
        cp bootc_dnf_update.sh local_bin
        echo "RUN /usr/local/bin/bootc_dnf_update.sh && rm /usr/local/bin/bootc_dnf_update.sh" >> Containerfile
    fi

    # prepare kargs file
    if [ -n "${BOOTC_KERNEL_ARGS}" ]; then
        cat >> 10-bootc_kernel_args.toml <<_EOF
kargs = ${BOOTC_KERNEL_ARGS}
_EOF
        echo 'COPY 10-bootc_kernel_args.toml /usr/lib/bootc/kargs.d/10-bootc_kernel_args.toml' >> Containerfile
    fi

    # copy tmt run dir
    if ! $IMAGE_MODE; then
        if [ -d /var/ARTIFACTS ]; then
	    cp -r /var/ARTIFACTS .
	    echo 'COPY ARTIFACTS /var/ARTIFACTS' >> Containerfile
	fi
        if [ -d /var/tmp/tmt ]; then
	    cp -r /var/tmp/tmt .
	    echo 'COPY tmt /var/tmp/tmt' >> Containerfile
        fi
    fi

    # BaseOS CI Workaround
    # Jenkins use /WORKDIR as tmt workdir root, but in bootc this is a readonly path.
    # Using a symlink won't work because tmt does cleanup of the symlink first,
    # therefore a symlink in / is still readonly and the workdir push would fail.
    # The solution is to create a systemd mount unit to bind /var/WORKDIR to /WORKDIR.
    if [ "${BASEOS_CI}" = "true" ] && [ -d /WORKDIR ]; then
        cp -r /WORKDIR .
        cat >> WORKDIR.mount << _EOF
[Unit]
Before=local-fs.target
[Mount]
What=/var/WORKDIR
Where=/WORKDIR
Type=none
Options=bind
[Install]
WantedBy=local-fs.target
_EOF
        cat >> Containerfile <<_EOF
COPY WORKDIR /var/WORKDIR
RUN mkdir /WORKDIR
COPY WORKDIR.mount  /etc/systemd/system/WORKDIR.mount
RUN systemctl enable WORKDIR.mount
_EOF
    fi

    # check for beakerlib injections and preserve them eventually
    if rpm -q beakerlib && ! rpm -V beakerlib; then
        cp -r /usr/share/beakerlib .
        cat >> Containerfile <<_EOF
COPY beakerlib /var/tmp/beakerlib
RUN rpm -q beakerlib && cp -r /var/tmp/beakerlib /usr/share/
_EOF
    fi

    # preserve /var/tmp/verify-nvr-installed
    if [ -f /var/tmp/verify-nvr-installed ]; then
        cp /var/tmp/verify-nvr-installed .
	echo 'COPY verify-nvr-installed /var/tmp/verify-nvr-installed' >> Containerfile
    fi

    # preserve /var/tmp/disable-nvr-check if  present
    if [ -f /var/tmp/disable-nvr-check ]; then
        cp /var/tmp/disable-nvr-check .
	echo 'COPY disable-nvr-check /var/tmp/disable-nvr-check' >> Containerfile
    fi

    # preserve sync-* scripts from https://github.com/RedHat-SP-Security/keylime-tests/blob/main/Library/sync/
    for SYNC_SCRIPT in sync-set sync-block sync-save; do
        [ -e /usr/local/bin/${SYNC_SCRIPT} ] && cp /usr/local/bin/${SYNC_SCRIPT} local_bin
    done

    # export or include ENV if defined
    if [ -n "${BOOTC_ENV}" ]; then
        if ${IMAGE_MODE}; then
            export ${BOOTC_ENV}
        else
            echo "ENV ${BOOTC_ENV}" >> Containerfile
        fi
    fi

    # include RUN cmd if requested
    if [ -n "${BOOTC_RUN_CMD}" ]; then
        echo "RUN ${BOOTC_RUN_CMD}" >> Containerfile
    fi

    # fix selinux context
    echo "RUN restorecon -Rv /usr /etc || true" >> Containerfile

    # add bootc container lint
    echo "RUN bootc container lint" >> Containerfile

    echo "Using the following Containerfile:"
    echo -n "---------------------------------"
    cat Containerfile
    echo -n "---------------------------------"

    podman build --layers=false -t ${IMPORTED_IMAGE_NAME} .

    # for image mode do an update
    if ${IMAGE_MODE}; then
        bootc switch --transport containers-storage ${IMPORTED_IMAGE_NAME}
    # if not in image mode
    else
        # now, this is a bit ugly but there doesn't seem to be a better way of doing this locally
        # We are going to build one more image that would contain a copy of the previously built one
        # so that we can import it to a local registry after the installation and use it
        # as a base image for future updates.
        podman save "${IMPORTED_IMAGE_NAME}" -o "${SHORT_IMAGE_NAME}.tar"
        cat > Containerfile <<_EOF
FROM ${IMPORTED_IMAGE_NAME}
COPY ${SHORT_IMAGE_NAME}.tar /var/tmp/${SHORT_IMAGE_NAME}.tar
_EOF
        podman build --layers=false -t ${IMPORTED_IMAGE_NAME} .

        # do the installation
        podman run --rm --tls-verify=false --privileged --pid=host -v /:/target -v /dev:/dev -v /var/lib/containers:/var/lib/containers -v /root/.ssh:/output --security-opt label=type:unconfined_t ${IMPORTED_IMAGE_NAME}:latest bootc install to-existing-root --target-transport containers-storage
    fi

    touch $COOKIE
    popd
    rm -rf $TMPDIR

    # from https://gitlab.com/fedora/bootc/tests/bootc-workflow-test/-/merge_requests/619
    # Keep PXE as first boot for beaker UEFI bare metal server
    # PXE first boot should start from the second one
    # Only beaker UEFI server has /root/EFI_BOOT_ENTRY.TXT file
    if [[ -f /root/EFI_BOOT_ENTRY.TXT ]] && efibootmgr &>/dev/null; then
        # bootupd added a new boot options and configured as first boot
        BOOTC_BOOT=$(efibootmgr | awk '/BootOrder/ { print $2 }' | cut -d, -f1)
        # tmt-reboot will read this file and get next boot
        echo "$BOOTC_BOOT" > /root/EFI_BOOT_ENTRY.TXT
        PXE_FIRST_BOOT_ORDER=$(efibootmgr | awk '/BootOrder/ { print $2 }' | cut -d, -f2-)
        # PXE as first boot and append bootc boot option
        efibootmgr -o "${PXE_FIRST_BOOT_ORDER},${BOOTC_BOOT}"

        echo "EFI boot info"
        efibootmgr
        echo "Next boot"
        cat /root/EFI_BOOT_ENTRY.TXT
    fi

    tmt-reboot

  else
    echo "PHASE: post-reboot phase"
    [ -n "${PACKAGE}" ] && rpm -q "${PACKAGE}"
    uname -a
    uptime
    cat /proc/cmdline
    rm $COOKIE
    # import built image into a registry
    if [ -f "/var/tmp/${SHORT_IMAGE_NAME}.tar" ]; then
      podman load -i "/var/tmp/${SHORT_IMAGE_NAME}.tar"
      rm -f "/var/tmp/${SHORT_IMAGE_NAME}.tar"
      podman images
    fi
  fi
