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
#   library-prefix = lime
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

true <<'=cut'
=pod

=head1 NAME

opencryptoki/test-helpers - provides shell function for keylime testing

=head1 DESCRIPTION

The library provides shell function to ease keylime test implementation.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 VARIABLES

Below is the list of global variables. 

=over

=item limeTmpDir

For internal purposes only.
Directory used to store various library related files.

=item limeLogVerifier

For internal purposes only.
Logfile path for the keylime verifier. Won't be used for systemd service.

=item limeLogRegistrar

For internal purposes only.
Logfile path for the keylime registrar. Won't be used for systemd service.

=item limeLogAgent

For internal purposes only.
Logfile path for the keylime agent. Won't be used for systemd service.

=item limeLogIMAEmulator

For internal purposes only.
Logfile path for the IMA Emulator.

=item limeLogCurrentTest

For internal purposes only.
Current working directory of the executed test.
We purge log files for a new test. It is therefore important to rlImport
the library before changing CWD to a different location.

=cut

# we are using hardcoded paths so they are preserved due to reboots
export limeTmpDir
[ -n "$limeTmpDir" ] || limeTmpDir="/var/tmp/limeLib"

export limeLogVerifier
[ -n "$limeLogVerifier" ] || limeLogVerifier="$limeTmpDir/limeLib-keylime-verifier.log"

export limeLogRegistrar
[ -n "$limeLogRegistrar" ] || limeLogRegistrar="$limeTmpDir/limeLib-keylime-registrar.log"

export limeLogAgent
[ -n "$limeLogAgent" ] || limeLogAgent="$limeTmpDir/limeLib-keylime-agent.log"

export limeLogIMAEmulator
[ -n "$limeLogIMAEmulator" ] || limeLogIMAEmulator="$limeTmpDir/limeLib-keylime-ima-emulator.log"

export limeLogCurrentTest
[ -n "$limeLogCurrentTest" ] || limeLogCurrentTest="$limeTmpDir/limeLib-current-test"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 limeTPMEmulated

Test if IBM TPM emulator is present

    limeTPMEmulated

=over

=back

Return success or failure depending on whether IBM TPM emulator is used.

=cut


limeTPMEmulated() {
    # naive approach, can be improved in the future
    rpm -q ibmswtpm2 &> /dev/null
}

# ~~~~~~~~~~~~~~~~~~~~
#   Backup/Restore
# ~~~~~~~~~~~~~~~~~~~~
true <<'=cut'
=pod

=head2 limeBackupConfig

Backup all keylime configuration files using rlFileBackup

    limeBackupConfig

=over

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeBackupConfig() {

    rlFileBackup --clean --namespace limeConf --missing-ok /etc/keylime.conf /etc/ima/ima-policy

}

true <<'=cut'
=pod

=head2 limeRestoreConfig

Restores previously backed up configuration files.

    limeRestoreConfig

=back

Returns 0 if the restore passed, non-zero otherwise.

=cut

limeRestoreConfig() {
    rlFileRestore --namespace limeConf
}

true <<'=cut'
=pod

=head2 limeBackupData

Backs up keylime data.

=back

Returns 0 if the backup restore passed.

=cut


limeBackupData() {
    rlFileBackup --clean --namespace limeData
}

true <<'=cut'
=pod

=head2 limeRestoreData

Restores keylime data.

=back

Returns 0 if the backup restore passed.

=cut

limeRestoreData() {
    rlFileRestore --namespace limeData
}

true <<'=cut'
=pod

=head2 limeClearData

Clears keylime data possibly used by previously running services.

=back

Returns 0 if the clean up passed.

=cut

limeClearData() {
    rm -f /var/lib/keylime/*.sqlite
}

# ~~~~~~~~~~~~~~~~~~~~
#   Start/Stop
# ~~~~~~~~~~~~~~~~~~~~
true <<'=cut'
=pod

=head2 limeStartVerifier

Start the keylime verifier, either using rlServiceStart or directly.

    limeStartVerifier

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeStartVerifier() {

    limeStopVerifier
    rlRun "keylime_verifier 2>&1 >> $limeLogVerifier &"

}

true <<'=cut'
=pod

=head2 limeStopVerifier

Stop the keylime verifier, either using rlServiceStart or directly.

    limeStopVerifier

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

limeStopVerifier() {

    pgrep -f keylime_verifier &> /dev/null && rlRun "pkill -f keylime_verifier"
    ! pgrep -f keylime_verifier

}

true <<'=cut'
=pod

=head2 limeStartRegistrar

Start the keylime registrar, either using rlServiceStart or directly.

    limeStartRegistrar

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeStartRegistrar() {

    limeStopRegistrar
    rlRun "keylime_registrar 2>&1 >> $limeLogRegistrar &"

}

true <<'=cut'
=pod

=head2 limeStopRegistrar

Stop the keylime registrar, either using rlServiceStart or directly.

    limeStopRegistrar

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

limeStopRegistrar() {

    pgrep -f keylime_registrar &> /dev/null && rlRun "pkill -f keylime_registrar"
    ! pgrep -f keylime_registrar

}

true <<'=cut'
=pod

=head2 limeStartAgent

Start the keylime agent, either using rlServiceStart or directly.

    limeStartAgent

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeStartAgent() {

    limeStopAgent
    rlRun "keylime_agent 2>&1 >> $limeLogAgent &"

}

true <<'=cut'
=pod

=head2 limeStopAgent

Stop the keylime agent, either using rlServiceStart or directly.

    limeStopAgent

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

limeStopAgent() {

    pgrep -f keylime_agent &> /dev/null && rlRun "pkill -f keylime_agent"
    ! pgrep -f keylime_agent

}

true <<'=cut'
=pod

=head2 limeStartIMAEmulator

Start the keylime IMA Emulator.

    limeStartIMAEmulator

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeStartIMAEmulator() {

    limeStopIMAEmulator
    rlRun "keylime_ima_emulator 2>&1 >> $limeLogIMAEmulator &"

}

true <<'=cut'
=pod

=head2 limeStopIMAEmulator

Stop the keylime IMA Emulator.

    limeStopIMAEmulator

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

limeStopIMAEmulator() {

    pgrep -f keylime_ima_emulator &> /dev/null && rlRun "pkill -f keylime_ima_emulator"
    ! pgrep -f keylime_ima_emulator

}

# ~~~~~~~~~~~~~~~~~~~~
#   Install
# ~~~~~~~~~~~~~~~~~~~~
true <<'=cut'
=pod

=head2 limeInstallIMAConfig

Install IMA policy configuration to /etc/ima/ima-policy
from a given file.

    limeInstallIMAConfig [FILE]

=over

=item FILE

Path to a IMA configuration file that should be used.
Library (keylime default) would be used if not passed.

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeInstallIMAConfig() {

    local FILE

    if [ -f "$1" ]; then
        FILE="$1"
    else
        FILE=$limeLibraryDir/ima-policy
    fi

    rlRun "mkdir -p /etc/ima/ && cat $FILE > /etc/ima/ima-policy"
    if [ $(cat /sys/kernel/security/ima/policy | wc -l) -eq 0 ]; then
        rlRun "cat $FILE > /sys/kernel/security/ima/policy"
    else
        rlLogWarning "IMA policy already configured in /sys/kernel/security/ima/policy"
        echo -e "Required policy\n~~~~~~~~~~~~~~~~~~~~"
        cat $FILE
        echo -e "~~~~~~~~~~~~~~~~~~~~\nInstalled policy\n~~~~~~~~~~~~~~~~~~~~"
        cat /sys/kernel/security/ima/policy
        echo -e "~~~~~~~~~~~~~~~~~~~~"
    fi
}

true <<'=cut'
=pod

=head2 limeCreateTestLists

Creates allowlist.txt and excludelist.txt to be used for testing purposes.
Allowlist would contain only initramdisk related content, all root dir / content
will be added to excludelist. This is based on an assumption that content
used for testing purposes will be created in / with an unique name later.
from a given file.

    limeCreateTestLists

=over

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeCreateTestLists() {

    # generate allowlist
    rlRun "bash $limeLibraryDir/create_allowlist.sh allowlist.txt sha256sum" && \
    # generate excludelist
    rlRun "bash $limeLibraryDir/create_excludelist.sh excludelist.txt"

}

# ~~~~~~~~~~~~~~~~~~~~
#   Logging
# ~~~~~~~~~~~~~~~~~~~~
true <<'=cut'
=pod

=head2 limeVerifierLogfile

Prints to STDOUT filepath to a log file containing Verifier logs

    limeVerifierLogfile

=over

=back

Returns 0.

=cut

limeVerifierLogfile() {

    # currently return the variable
    echo $limeLogVerifier

}

true <<'=cut'
=pod

=head2 limeRegistrarLogfile

Prints to STDOUT filepath to a log file containing Registrar logs

    limeRegistrarLogfile

=over

=back

Returns 0.

=cut

limeRegistrarLogfile() {

    # currently return the variable
    # in the future for systemd services we may extract relevant parts 
    # using journactl and store them in a file
    echo $limeLogRegistrar

}

true <<'=cut'
=pod

=head2 limeAgentrLogfile

Prints to STDOUT filepath to a log file containing Agent logs

    limeAgentLogfile

=over

=back

Returns 0.

=cut

limeAgentLogfile() {

    # currently return the variable
    echo $limeLogAgent

}

true <<'=cut'
=pod

=head2 limeIMAEmulatorLogfile

Prints to STDOUT filepath to a log file containing IMAEmulator logs

    limeIMAEmulatorLogfile

=over

=back

Returns 0.

=cut

limeIMAEmulatorLogfile() {

    # currently return the variable
    echo $limeLogIMAEmulator

}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Inicialization
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#   Create $limeTmpDir directory

mkdir -p $limeTmpDir

#   Purge log files for a new test. It is therefore important to rlImport
#   the library before changing CWD to a different location.

touch $limeLogCurrentTest
if ! grep -q "^$PWD\$" $limeLogCurrentTest; then
    echo "$PWD" > $limeLogCurrentTest
    [ -f $limeLogVerifier ]> $limeLogVerifier 
    [ -f $limeLogRegistrar ] > $limeLogRegistrar
    [ -f $limeLogAgent ] > $limeLogAgent
    [ -f $limeLogIMAEmulator ] && > $limeLogIMAEmulator
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

limeLibraryLoaded() {
    if true; then
        rlLogDebug "Library keylime/test-helpers loaded."
        return 0
    else
        rlLogError "Failed loading library keylime/test-helpers."
        return 1
    fi
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
