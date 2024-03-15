#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Description: provides basic function for token manipulation
#   Author: Karel Srot <ksrot@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 Red Hat, Inc.
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
#   library-prefix = sync
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1


true <<'=cut'
=pod

=head1 NAME

keylime-tests/sync - provides synchronization capabilities for multi-host testing

=head1 DESCRIPTION

The library provides sync-set and sync-block commands and also sync-get systemd
service. All these scripts are installed and service enabled and started during
the library load.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# we are using hardcoded paths so they are preserved due to reboots
export __INTERNAL_syncStatusFile=/var/tmp/sync-status
# limit the reported sync status to 100 lines by default
[ -n "${SYNC_STATUS_REPORT_SIZE}" ] || SYNC_STATUS_REPORT_SIZE=100

# for backvards compatibility define SERVERS and CLIENTS variables using tmt topology
if [ -n "${TMT_TOPOLOGY_BASH}" -a -f ${TMT_TOPOLOGY_BASH} ]; then
    . ${TMT_TOPOLOGY_BASH}
    cat ${TMT_TOPOLOGY_BASH}
    echo
else
    # declare empty associative array so that conditions are properly evaluated
    declare -A TMT_ROLES
    declare -A TMT_GUESTS
fi
# export SERVERS and CLIENTS variables when defined by tmt
if [ -z "${SERVERS}" -a -n "${TMT_ROLES[SERVERS]}" ]; then
    export SERVERS=""
    for SRV in ${TMT_ROLES[SERVERS]}; do
        SERVERS="$SERVERS ${TMT_GUESTS[${SRV}.hostname]}"
    done
    echo "SERVERS=${SERVERS}"
fi
if [ -z "${CLIENTS}" -a -n "${TMT_ROLES[CLIENTS]}" ]; then
    export CLIENTS=""
    for SRV in ${TMT_ROLES[CLIENTS]}; do
        CLIENTS="$CLIENTS ${TMT_GUESTS[${SRV}.hostname]}"
    done
    echo "CLIENTS=${CLIENTS}"
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Initialization / Installation
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# define XTRA variable if not defined but TMT variables are exposed
if [ -z "$XTRA" ] && [ -n "$TMT_TREE" ] && [ -n "$TMT_TEST_SERIAL_NUMBER" ]; then
    # tmt is using run-XXX while Testing Farm uses work-multihostXYZ
    # and TF through Packit uses something like work-upstream-keylime-multihostXYZ
    __INTERNAL_syncRunID=$( echo $TMT_TREE | sed 's#^.*/\(run-[0-9]*\)/.*#\1#' | sed 's#^.*/\(work-[^/]*\)/.*#\1#' )
    export XTRA="$__INTERNAL_syncRunID-$TMT_TEST_SERIAL_NUMBER"
fi
echo "XTRA=$XTRA"

# double check nmap is installed (requires are not installed with direct library load)
rpm -q nmap-ncat hostname &> /dev/null || yum -y install nmap-ncat hostname

#   Create status file
touch $__INTERNAL_syncStatusFile

# install sync-set and sync-block scripts to /usr/local/bin
which sync-set &> /dev/null || cp $syncLibraryDir/sync-set /usr/local/bin && chmod a+x /usr/local/bin/sync-set
which sync-block &> /dev/null || cp $syncLibraryDir/sync-block /usr/local/bin && chmod a+x /usr/local/bin/sync-block

# install and enable and start sync-get service
if ! systemctl is-active sync-get; then
    sed "s/SYNC_STATUS_REPORT_SIZE/${SYNC_STATUS_REPORT_SIZE}/g" "$syncLibraryDir/sync-get.service" > /etc/systemd/system/sync-get.service
    systemctl daemon-reload
    systemctl --now enable sync-get &> /dev/null
    sleep 1
fi


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Verification
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   This is a verification callback which will be called by
#   rlImport after sourcing the library to make sure everything is
#   all right. It makes sense to perform a basic sanity test and
#   check that all required packages are installed. The function
#   should return 0 only when the library is ready to serve.

syncLibraryLoaded() {
    which sync-set &> /dev/null && which sync-block &> /dev/null && systemctl is-active sync-get &> /dev/null
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Authors
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 AUTHORS

=over

=item *

Karel Srot <ksrot@redhat.com>

=back

=cut
