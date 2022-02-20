#!/bin/bash
################################################################################
# SPDX-License-Identifier: Apache-2.0
# Copyright 2017 Massachusetts Institute of Technology.
################################################################################

# this matches the file available at
# https://github.com/keylime/keylime/blob/master/scripts/create_allowlist.sh
# with the exception of excluding root dir / content
# since it will be added to exclude list

# Configure the installer here
INITRAMFS_TOOLS_GIT=https://salsa.debian.org/kernel-team/initramfs-tools.git
INITRAMFS_TOOLS_VER="master"


# Grabs Debian's initramfs_tools from Git repo if no other options exist
if [[ ! `command -v unmkinitramfs` && ! -x "/usr/lib/dracut/skipcpio" ]] ; then
    # Create temp dir for pulling in initramfs-tools
    TMPDIR=`mktemp -d` || exit 1
    echo "INFO: Downloading initramfs-tools: $TMPDIR"

    # Clone initramfs-tools repo
    pushd $TMPDIR
    git clone $INITRAMFS_TOOLS_GIT initramfs-tools
    pushd initramfs-tools
    git checkout $INITRAMFS_TOOLS_VER
    popd # $TMPDIR
    popd

    shopt -s expand_aliases
    alias unmkinitramfs=$TMPDIR/initramfs-tools/unmkinitramfs
fi


if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

if [ $# -lt 1 ]
then
    echo "Usage:  `basename $0` list.txt [hash-algo]" >&2
    exit $NOARGS;
fi

# Where to look for initramfs image
INITRAMFS_LOC="/boot/"
if [ -d "/ostree" ]; then
    # If we are on an ostree system change where we look for initramfs image
    loc=$(grep -E "/ostree/[^/]([^/]*)" -o /proc/cmdline | head -n 1 | cut -d / -f 3)
    INITRAMFS_LOC="/boot/ostree/${loc}/"
fi

if [ $# -eq 2 ]
then
    ALGO=$2
else
    ALGO=sha1sum
fi

OUTPUT=$(readlink -f $1)
rm -f $OUTPUT


echo "Writing allowlist to $OUTPUT with $ALGO..."

# Add boot_aggregate from /sys/kernel/security/ima/ascii_runtime_measurements (IMA Log) file.
# The boot_aggregate measurement is always the first line in the IMA Log file.
# The format of the log lines is the following:
#     <PCR_ID> <PCR_Value> <IMA_Template> <File_Digest> <File_Name> <File_Signature>
# File_Digest may start with the digest algorithm specified (e.g "sha1:", "sha256:") depending on the template used.
head -n 1 /sys/kernel/security/ima/ascii_runtime_measurements | awk '{ print $4 "  boot_aggregate" }' | sed 's/.*://' >> $OUTPUT
