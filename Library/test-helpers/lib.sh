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

keylime-tests/test-helpers - provides shell function for keylime testing

=head1 DESCRIPTION

The library provides shell function to ease keylime test implementation.

=cut

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Variables
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# we are using hardcoded paths so they are preserved due to reboots
export __INTERNAL_limeTmpDir
[ -n "$__INTERNAL_limeTmpDir" ] || __INTERNAL_limeTmpDir="/var/tmp/limeLib"

export __INTERNAL_limeLogVerifier
[ -n "$__INTERNAL_limeLogVerifier" ] || __INTERNAL_limeLogVerifier="$__INTERNAL_limeTmpDir/verifier.log"

export __INTERNAL_limeLogRegistrar
[ -n "$__INTERNAL_limeLogRegistrar" ] || __INTERNAL_limeLogRegistrar="$__INTERNAL_limeTmpDir/registrar.log"

export __INTERNAL_limeLogAgent
[ -n "$__INTERNAL_limeLogAgent" ] || __INTERNAL_limeLogAgent="$__INTERNAL_limeTmpDir/agent.log"

export __INTERNAL_limeLogIMAEmulator
[ -n "$__INTERNAL_limeLogIMAEmulator" ] || __INTERNAL_limeLogIMAEmulator="$__INTERNAL_limeTmpDir/ima-emulator.log"

export __INTERNAL_limeLogCurrentTest
[ -n "$__INTERNAL_limeLogCurrentTest" ] || __INTERNAL_limeLogCurrentTest="$__INTERNAL_limeTmpDir/limeLib-current-test"

export __INTERNAL_limeBaseExcludeList
[ -n "$__INTERNAL_limeBaseExcludeList" ] || __INTERNAL_limeBaseExcludeList="$__INTERNAL_limeTmpDir/limeLib-base-exludelist"

export __INTERNAL_limeCoverageDir
[ -n "$__INTERNAL_limeCoverageDir" ] || __INTERNAL_limeCoverageDir="$__INTERNAL_limeTmpDir/coverage"

export __INTERNAL_limeCoverageEnabled=false
[ -n "$COVERAGE" ] && __INTERNAL_limeCoverageEnabled=true
[ -f "$__INTERNAL_limeCoverageDir/enabled" ] && __INTERNAL_limeCoverageEnabled=true

export __INTERNAL_limeCoverageContext


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 limeTPMEmulated

Test if TPM emulator is present

    limeTPMEmulated

=over

=back

Return success or failure depending on whether TPM emulator is used.

=cut


limeTPMEmulated() {
    # naive approach, can be improved in future
    rpm -q swtpm &> /dev/null
}


true <<'=cut'
=pod

=head2 limeUpdateConf

Updates respective [SECTION] in /etc/keylime.conf file, 
replacing OPTION = .* with OPTION = VALUE.

    limeUpdateConf SECTION OPTION VALUE

=over

=back

Return success.

=cut


function limeUpdateConf() {
  sed -i "/^\[$1\]/,/^\[/ s@^$2 *=.*@$2 = $3@$4" /etc/keylime.conf
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
    rlFileBackup --clean --namespace limeData /var/lib/keylime/
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

__limeGetLogName() {
    local NAME=$1
    local LOGSUFFIX
    [ -n "$2" ] && LOGSUFFIX="$2" || LOGSUFFIX=$( echo "$NAME" | sed 's/.*/\u&/' )  # just uppercase first letter
    local LOGNAME=__INTERNAL_limeLog${LOGSUFFIX}
    echo ${!LOGNAME}
}

__limeStartKeylimeService() {

    local NAME=$1
    local LOGFILE=$( __limeGetLogName $1 $2 )

    if $__INTERNAL_limeCoverageEnabled && file $(which keylime_${NAME}) | grep -qi python; then
        coverage run -p --context $__INTERNAL_limeCoverageContext $(which keylime_${NAME}) >> ${LOGFILE} 2>&1 &
    else
        keylime_${NAME} >> ${LOGFILE} 2>&1 &
    fi

}

__limeWaitForProcessEnd() {
    local NAME=$1
    local TIMEOUT=15
    local RET=1

    [ -n "$2" ] && TIMEOUT=$2
    for I in $( seq $TIMEOUT ); do
        echo -n "."
        sleep 1
        # if process has already stopped
        if ! pgrep -f ${NAME} &> /dev/null; then
            RET=0
            break
        fi
    done
    echo
    return $RET
}

__limeStopKeylimeService() {

    local NAME=$1
    local LOGFILE=$( __limeGetLogName $1 $2 )
    local RET=0
    local TAIL=1

    # find the tail of the log file
    [ -f ${LOGFILE} ] && TAIL=$( cat ${LOGFILE} | wc -l )
    [ $TAIL -eq 0 ] && TAIL=1

    # send SIGINT when measuring coverage to generate the report
    if $__INTERNAL_limeCoverageEnabled && pgrep -f keylime_${NAME} &> /dev/null; then
        pkill -INT -f keylime_${NAME}
        __limeWaitForProcessEnd keylime_${NAME}
    fi
    # send SIGTERM if not stopped yet
    if pgrep -f keylime_${NAME} &> /dev/null; then
        #if $__INTERNAL_limeCoverageEnabled; then
        #    echo "Process wasn't termnated after SIGINT, coverage data may not be correct"
        #    RET=1
        #fi
        pkill -f keylime_${NAME}
        __limeWaitForProcessEnd keylime_${NAME}
    fi
    # check the log file if there was a Traceback and print it to the test log
    # (and set RET=2 eventually)
    if [ -f ${LOGFILE} ] && sed -n "$TAIL,\$ p" ${LOGFILE} | grep -q Traceback; then
        #RET=2
        # print the Traceback to the test log
        sed -n "$TAIL,\$ p" ${LOGFILE}
    fi
    # send SIGKILL if the process didn't stop yet
    if pgrep -f keylime_${NAME} &> /dev/null; then
        echo "Process wasn't terminated with SIGTERM, sending SIGKILL signal..."
        RET=9
        pkill -KILL -f keylime_${NAME}
        __limeWaitForProcessEnd keylime_${NAME}
    fi

    # copy .coverage* files to a persistent location
    $__INTERNAL_limeCoverageEnabled && cp -n .coverage* $__INTERNAL_limeCoverageDir &> /dev/null

    return $RET

}



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
    __limeStartKeylimeService verifier
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

    __limeStopKeylimeService verifier

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
    __limeStartKeylimeService registrar

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

    __limeStopKeylimeService registrar

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
    __limeStartKeylimeService agent

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

    __limeStopKeylimeService agent

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
    __limeStartKeylimeService ima_emulator IMAEmulator

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

    __limeStopKeylimeService ima_emulator IMAEmulator

}

true <<'=cut'
=pod

=head2 limeStartTPMEmulator

Start the availabe TPM emulator

    limeStartTPMEmulator

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeStartTPMEmulator() {

    limeStopTPMEmulator
    if rpm -q swtpm &> /dev/null; then
        #rm -rf /var/lib/tpm/swtpm
        mkdir -p /var/lib/tpm/swtpm
        rlServiceStart swtpm
    fi

}

true <<'=cut'
=pod

=head2 limeStopTPMEmulator

Stop the available TPM Emulator.

    limeStopTPMEmulator

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

limeStopTPMEmulator() {

    if rpm -q swtpm &> /dev/null; then
        rlServiceStop swtpm
    fi

}


true <<'=cut'
=pod

=head2 limeWaitForVerifier

Use rlWaitForSocket to wait for the verifier to start.

    limeWaitForVerifier [PORT_NUMBER]

=over

=item

    PORT_NUMBER - Port number to wait for, 8881 by default.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForVerifier() {

    local PORT
    [ -n "$1" ] && PORT=$1 || PORT=8881
    rlWaitForSocket $PORT -d 0.1
}

true <<'=cut'
=pod

=head2 limeWaitForRegistrar

Use rlWaitForSocket to wait for the registrar to start.

    limeWaitForRegistrar [PORT_NUMBER]

=over

=item

    PORT_NUMBER - Port number to wait for, 8891 by default.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForRegistrar() {

    local PORT
    [ -n "$1" ] && PORT=$1 || PORT=8891
    rlWaitForSocket $PORT -d 0.1

}

true <<'=cut'
=pod

=head2 limeWaitForTPMEmulator

Use rlWaitForSocket to wait for the registrar to start.

    limeWaitForTPMEmulator [PORT_NUMBER]

=over

=item

    PORT_NUMBER - Port number to wait for, 2322 by default.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForTPMEmulator() {

    local PORT
    [ -n "$1" ] && PORT=$1 || PORT=2322
    rlWaitForSocket $PORT -d 0.1

}


true <<'=cut'
=pod

=head2 limeWaitForTenantStatus

Run 'lime_keylime_tenant -c status' wrapper repeatedly up to TIMEOUT seconds
until the expected agent status is returned.

    limeWaitForTenantStatus UUID STATUS [TIMEOUT]

=over

=item

    UUID - Agent UUID to query the status for.

=item

    STATUS - Expected status.

=item

    TIMEOUT - Maximum time in seconds to wait (default 30).

=back

Returns 0 when the start was successful, 1 otherwise.

=cut

limeWaitForTenantStatus() {
    local TIMEOUT=30
    local UUID="$1"
    local STATUS="$2"
    local OUTPUT=`mktemp`
    [ -n "$3" ] && TIMEOUT=$3

    for I in `seq $TIMEOUT`; do
        lime_keylime_tenant -c status -u $UUID &> $OUTPUT
	if egrep -q "\"operational_state\": \"$STATUS\"" $OUTPUT; then
            cat $OUTPUT
	    rm $OUTPUT
	    return 0
	fi
        sleep 1
    done
    cat $OUTPUT
    rm $OUTPUT
    return 1
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

    mkdir -p /etc/ima/ && cat $FILE > /etc/ima/ima-policy && \
    if [ $(cat /sys/kernel/security/ima/policy | wc -l) -eq 0 ]; then
        cat $FILE > /sys/kernel/security/ima/policy
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
Allowlist will contain only initramdisk related content.
Exclude list will contain all root dir / content except /keylime-tests.
This is based on an assumption that content used for testing purposes will 
be created under /keylime-tests in a directory with an unique name.
See limeExtendNextExcludelist and limeCreateTestDir for more details.

    limeCreateTestLists

=over

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeCreateTestLists() {

    # generate allowlist
    bash $limeLibraryDir/create_allowlist.sh allowlist.txt sha256sum && \
    # generate excludelist
    bash $limeLibraryDir/create_excludelist.sh excludelist.txt && \
    # make sure the file exists
    touch $__INTERNAL_limeBaseExcludeList && \
    cat $__INTERNAL_limeBaseExcludeList >> excludelist.txt

}

true <<'=cut'
=pod

=head2 limeExtendNextExcludelist


Stores provided paths to a list which gets added to the excludelist generated using limeCreateTestLists.
Once a file not an a whitelist is measured by IMA it gets accounted until the next reboot.
From this reason any file created by the test (even if they are deleted later) must be added to the
exclude list to make sure that subsequent tests won't eventually fail attestation due to this file.

    limeExtendNextExcludelist PATH1 [PATH2...]

For test purposes it seems reasonable to store test files used for the attestation in a dedicated
directory undre the /keylime-tests directory.
You can generate unique directory e.g. using:

    mkdir -p /keylime-tests
    mktemp -d "/keylime-tests/test-name-XXXXX"

or simply use the function

    limeCreateTestDir

Due to reasons above it seems unnecessary to removing such test files in test clean up phase.
Keeping them in place would at least ensure unique directory name in subsequent test runs of
the same test (e.g. when the test is parametrized).

=over

=item

    PATH - path to be added to the future allowlist.

=back

Returns 0 when the execution was successfull, non-zero otherwise.

=cut

limeExtendNextExcludelist() {

    for F in $@; do
        echo "$F(/.*)?" >> $__INTERNAL_limeBaseExcludeList
    done

}

true <<'=cut'
=pod

=head2 limeCreateTestDir

Creates a directory under /keylime-tests directory with a unique name
prefixed by the test name. Path of the created directory is printed to STDOUT.

    limeCreateTestDir

=over

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeCreateTestDir() {

    local TESTNAME && \
    TESTNAME=$( basename $( cat $__INTERNAL_limeLogCurrentTest ) ) && \
    mkdir -p /keylime-tests && \
    mktemp -d "/keylime-tests/${TESTNAME}-XXXXX"

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
    echo $__INTERNAL_limeLogVerifier

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
    echo $__INTERNAL_limeLogRegistrar

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
    echo $__INTERNAL_limeLogAgent

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
    echo $__INTERNAL_limeLogIMAEmulator

}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Initialization
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#   Create $__INTERNAL_limeTmpDir directory

mkdir -p $__INTERNAL_limeTmpDir
mkdir -p $__INTERNAL_limeCoverageDir

# set monitor mode so we can kill the background process
# https://unix.stackexchange.com/questions/372541/why-doesnt-sigint-work-on-a-background-process-in-a-script
set -m


#   Purge log files for a new test. It is therefore important to rlImport
#   the library before changing CWD to a different location.

touch $__INTERNAL_limeLogCurrentTest
if ! grep -q "^$PWD\$" $__INTERNAL_limeLogCurrentTest; then
    echo "$PWD" > $__INTERNAL_limeLogCurrentTest
    [ -f $__INTERNAL_limeLogVerifier ] && > $__INTERNAL_limeLogVerifier
    [ -f $l__INTERNAL_imeLogRegistrar ] && > $__INTERNAL_limeLogRegistrar
    [ -f $__INTERNAL_limeLogAgent ] && > $__INTERNAL_limeLogAgent
    [ -f $__INTERNAL_limeLogIMAEmulator ] && > $__INTERNAL_limeLogIMAEmulator
fi

# set code coverage context depending on a test
# create context depending on the test directory by
# cuting-off the *keylime-tests* (git repo dir) part
__INTERNAL_limeCoverageContext=$( cat $__INTERNAL_limeLogCurrentTest | sed -e 's#.*keylime-tests[^/]*\(/.*\)#\1#' )

true <<'=cut'
=pod

=head2 lime_keylime_tenant

Wrapper around keylime_tenant command supporting execution via the coverage
script to messasure code coverage.

    lime_keylime_tenant ARGS

=over

=item

    ARGS - Regular keylime_tenant command line arguments.

=back

Returns 0.

=cut


# create like_keylime_tenant wrapper
cat > /usr/local/bin/lime_keylime_tenant <<EOF
#!/bin/bash

if $__INTERNAL_limeCoverageEnabled; then
    coverage run -p --context $__INTERNAL_limeCoverageContext \$( which keylime_tenant ) "\$@"
else
    keylime_tenant "\$@"
fi
EOF
# make it executable
chmod a+x /usr/local/bin/lime_keylime_tenant


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
    if [ -n "$__INTERNAL_limeTmpDir" ]; then
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
