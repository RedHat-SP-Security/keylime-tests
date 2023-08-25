#!/bin/bash
################################################################################
# SPDX-License-Identifier: Apache-2.0
# Copyright 2017 Massachusetts Institute of Technology.
################################################################################

if [ $# -lt 1 -o "$1" == "-h" -o "$1" == "--help" ]; then
    echo "Usage:  `basename $0` LISTNAME [hash-algo] [-- FILE1 FILE2 ...]" >&2
    exit 1;
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

if [ "$2" != "--" ]; then
    ALGO=$2
else
    ALGO=sha256sum
fi

OUTPUT=$(readlink -f $1)
rm -f $OUTPUT

# now process additional arguments after "--"
while [ $# -gt 0 -a "$1" != "--" ]; do
    shift
done
if [ "$1" == "--" ]; then
    shift;
fi

echo "Writing allowlist to $OUTPUT with $ALGO..."

# process individual files
while [ $# -gt 0 ]; do
    if test -f "$1"; then
        $ALGO "$1" >> $OUTPUT
    else
        echo "Error: $1 is not a regular file" >&2
        exit 1
    fi
    shift
done

# Add boot_aggregate from /sys/kernel/security/ima/ascii_runtime_measurements (IMA Log) file.
# The boot_aggregate measurement is always the first line in the IMA Log file.
# The format of the log lines is the following:
#     <PCR_ID> <PCR_Value> <IMA_Template> <File_Digest> <File_Name> <File_Signature>
# File_Digest may start with the digest algorithm specified (e.g "sha256:") depending on the template used.
head -n 1 /sys/kernel/security/ima/ascii_runtime_measurements | awk '{ print $4 "  boot_aggregate" }' | sed 's/.*://' >> $OUTPUT
