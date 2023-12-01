#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

SUBPACKAGES="base verifier registrar tenant agent-rust"
URL="https://odcs.stream.centos.org/development/latest-CentOS-Stream/compose/AppStream/x86_64/os/Packages/"

function extract_rpm() {
    local NAME="$1"
    local URL="$2"
    rlRun "curl -o $NAME.rpm $URL"
    rlRun "rpm2cpio $NAME.rpm | cpio -idmv"

}

rlJournalStart

    rlPhaseStartTest
        id keylime &> /dev/null || rlRun "useradd keylime"
        rlRun "TMPDIR=\$( mktemp -d )"
        rlRun "pushd $TMPDIR"
        rlRun "curl -o filelist '$URL'"
        # parse package NVR from filelist
        for PKG in $SUBPACKAGES; do
            SUFFIX=$( grep -Eo ">keylime-$PKG.*\.rpm" filelist | sed "s/>keylime-$PKG-//g" | head -1 )
            extract_rpm "keylime-$PKG" "$URL/keylime-$PKG-$SUFFIX"
        done
        rlRun "cp -r etc/keylime /etc"
        rlRun "chown -R keylime:keylime /etc/keylime"
        rlRun "chmod -R a+r /etc/keylime"
        rlRun "popd"
        rlRun "rm -rf $TMPDIR"
    rlPhaseEnd

rlJournalEnd
