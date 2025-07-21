#!/bin/bash
# vim: dict=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Author: Karel Srot <ksrot@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2025 Red Hat, Inc.
#
#   This copyrighted material is made available to anyone wishing
#   to use, modify, copy, or redistribute it subject to the terms
#   and conditions of the GNU General Public License version 2.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE. See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public
#   License along with this program; if not, write to the Free
#   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
#   Boston, MA 02110-1301, USA.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

TESTDIR=`pwd`

function checkFile() {
    MUSTEXIST=false
    if [ "$1" == "-e" ]; then
        MUSTEXIST=true
        shift
    fi
    FILEPATH=$1
    OWNER=$2
    GROUP=$3
    if "$MUSTEXIST" || [ -e "$FILEPATH" ]; then
        rlRun "ls -ld $FILEPATH | grep -qE '$OWNER[ ]*$GROUP'"
    fi
}

rlJournalStart
    rlPhaseStartTest "Check keylime-base"
        rlAssertRpm keylime-base
        checkFile -e /etc/keylime keylime keylime
        for F in ca.conf ca.conf.d logging.conf logging.conf.d; do
            checkFile -e /etc/keylime/$F keylime keylime
	done
	checkFile -e /run/keylime keylime keylime
        checkFile -e /usr/share/keylime root root
	[ -d /usr/share/keylime/tpm_cert_store ] && checkFile -e /usr/share/keylime/tpm_cert_store keylime keylime
	checkFile -e /var/lib/keylime keylime keylime
	checkFile -e /var/lib/keylime keylime keylime
	checkFile -e /var/lib/keylime/tpm_cert_store keylime keylime
	checkFile -e /var/lib/keylime/tpm_cert_store/Alibaba_Cloud_vTPM_EK.pem keylime keylime
        # verify user account
        rlRun -s "id keylime"
        rlRun "grep -E 'groups=.*keylime' $rlRun_LOG"
        rlRun "grep -E 'groups=.*tss' $rlRun_LOG"
    rlPhaseEnd

    for S in verifier registrar tenant; do
        if rpm -q keylime-$S; then
            rlPhaseStartTest "Check keylime-$S"
                rlAssertRpm keylime-$S
                checkFile -e /etc/keylime/$S.conf keylime keylime
                checkFile -e /etc/keylime/$S.conf.d keylime keylime
            rlPhaseEnd
        fi
    done
 
    if rpm -q keylime-agent-rust; then
        rlPhaseStartTest "Check keylime-agent-rust"
            rlAssertRpm keylime-agent-rust
            checkFile -e /etc/keylime/agent.conf keylime keylime
            checkFile -e /etc/keylime/agent.conf.d keylime keylime
            checkFile -e /usr/libexec/keylime keylime keylime
        rlPhaseEnd
    fi
 
rlJournalPrintText
rlJournalEnd
