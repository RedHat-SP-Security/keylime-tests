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

[ "$limeIGNORE_SYSTEMD" == "1" -o "$limeIGNORE_SYSTEMD" == "true" ] && limeIGNORE_SYSTEMD=true || limeIGNORE_SYSTEMD=false

export __INTERNAL_limeCoverageContext

export __INTERNAL_limeIMADir
export __INTERNAL_limeIMAKeysDir="/etc/keys"
export __INTERNAL_limeTPMDetails="${__INTERNAL_limeTmpDir}/TPM_info.txt"
export limeIMAPrivateKey=${__INTERNAL_limeIMAKeysDir}/privkey_evm.pem
export limeIMAPublicKey=${__INTERNAL_limeIMAKeysDir}/x509_evm.pem
export limeIMACertificateDER=${__INTERNAL_limeIMAKeysDir}/x509_evm.der

[ -n "$limeTIMEOUT" ] || limeTIMEOUT=20
export limeTIMEOUT

export limeTestUser=limetester
export limeTestUserUID=11235

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Functions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

true <<'=cut'
=pod

=head1 FUNCTIONS

=head2 limeServiceUnitFileExists

Test if a service has systemd unit file.

    limeServiceUnitFileExists NAME

=over

=back

Return 0 if unit file exists, 1 if not.

=cut


limeServiceUnitFileExists() {

    if ${limeIGNORE_SYSTEMD}; then
        return 1
    fi

    systemctl is-enabled $1 2>/dev/null | grep -E -q '(enabled|disabled)'

}



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
    _emulator=$(limeTPMEmulator)
    rpm -q "${_emulator}" &> /dev/null
}


true <<'=cut'
=pod

=head2 limeUpdateConf

Updates respective [SECTION] in keylime config files,
replacing OPTION = .* with OPTION = VALUE.

    limeUpdateConf [-d CONF_DIR] SECTION OPTION VALUE

=over

=item

    -d CONF_DIR - Directory with keylime configuration (default /etc/keylime)

=back

Return success.

=cut


function limeUpdateConf() {

  local CONF_DIR=/etc/keylime

  if [ "$1" == "-d" ]; then
      CONF_DIR="$2"
      shift 2
  fi

  local SECTION=$1
  local KEY=$2
  local VALUE=$3
  local SED_OPTIONS=$4
  local FILES
  local MODIFIED

  FILES="$( find ${CONF_DIR} -name '*.conf' )"
  for FILE in ${FILES}; do
      MODIFIED=false
      if [ -f ${FILE} ]; then
          # if the option exists, modify it
          if sed -n "/^\[${SECTION}\]/,/^\[/ p" ${FILE} | grep -E -q "^${KEY} *="; then
              sed -i "/^\[${SECTION}\]/,/^\[/ s|^${KEY} *=.*|${KEY} = ${VALUE}|${SED_OPTIONS}" ${FILE}
              MODIFIED=true
          # else we will to add it at the top of the section if the section exists and it is not in *.conf.d/
          elif grep -q "\[${SECTION}\]" $FILE && [[ ! "${FILE}" =~ ".conf.d/" ]]; then
              sed -i "s|^\[${SECTION}\]|\[${SECTION}\]\n${KEY} = ${VALUE}|${SED_OPTIONS}" ${FILE}
              MODIFIED=true
          fi
          # print the modified configuration line
          if $MODIFIED; then
              echo -e "${FILE}:\n[${SECTION}]"
              sed -n "/^\[${SECTION}\]/,/^\[/ p" ${FILE} | grep -E "^${KEY} *="
          fi
      fi
  done
}


true <<'=cut'
=pod

=head2 limeIsPythonAgent

Checks if Python keylime_agent is present.

    limeIsPythonAgent

=over

=back

Return success if Python keylime_agent is present.

=cut

function limeIsPythonAgent() {

    if which keylime_agent &> /dev/null; then
        if file $( which keylime_agent ) | grep -qi python; then
            return 0
        fi
    fi
    return 1

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

    rlFileBackup --clean --namespace limeConf --missing-ok /etc/keylime/agent.conf /etc/keylime /etc/ima/ima-policy

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
    local ARGS

    # set sha256 as default hash for ima emulator
    if [ "$1" == "ima_emulator" ]; then
        ARGS="--hash_algs sha256 --ima-hash-alg sha1"
    fi

    # execute service using sytemd unit file
    if limeServiceUnitFileExists keylime_${NAME}; then
        systemctl start keylime_${NAME}

    # if there is no unit file, execute the process directly
    else
        # export RUST_LOG=keylime_agent=trace just in case we are using rust-keylime
        RUST_LOG=keylime_agent=trace
        keylime_${NAME} ${ARGS} >> ${LOGFILE} 2>&1 &
    fi

}

__limeWaitForProcessEnd() {
    local NAME=$1
    local TIMEOUT=10
    local RET=1

    [ -n "$2" ] && TIMEOUT=$2
    for I in $( seq $TIMEOUT ); do
        echo -n "."
        sleep 1
        # if process has already stopped
        if ! pgrep -f "${NAME}([[:space:]]|\$)" &> /dev/null; then
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

    # when there is a unit file, stop service using systemctl
    if limeServiceUnitFileExists keylime_${NAME}; then
        systemctl stop keylime_${NAME}
        __limeWaitForProcessEnd keylime_${NAME}

    # otherwise stop the process directly
    else
        # send SIGINT when measuring coverage to generate the report
        if $__INTERNAL_limeCoverageEnabled && pgrep -f "keylime_${NAME}([[:space:]]|\$)" &> /dev/null; then
            pkill -INT -f keylime_${NAME}
            __limeWaitForProcessEnd keylime_${NAME}
        fi
        # send SIGTERM if not stopped yet
        if pgrep -f "keylime_${NAME}([[:space:]]|\$)" &> /dev/null; then
            #if $__INTERNAL_limeCoverageEnabled; then
            #    echo "Process wasn't termnated after SIGINT, coverage data may not be correct"
            #    RET=1
            #fi
            pkill -f keylime_${NAME}
            __limeWaitForProcessEnd keylime_${NAME}
        fi
    fi

    # send SIGKILL if the process didn't stop yet
    if pgrep -f "keylime_${NAME}([[:space:]]|\$)" &> /dev/null; then
        pgrep -af "keylime_${NAME}([[:space:]]|\$)"
        echo "Process wasn't terminated with SIGTERM, sending SIGKILL signal..."
        RET=9
        pkill -KILL -f keylime_${NAME}
        __limeWaitForProcessEnd keylime_${NAME}
    fi

    # in case of an error print tail of service log
    if [ $RET -ne 0 ] && [ -f ${LOGFILE} ]; then
        echo "----- Tail of ${LOGFILE} -----"
        sed -n "$TAIL,\$ p" ${LOGFILE}
        echo "------------------------------"
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

    # save TPM details
    date >> ${__INTERNAL_limeTPMDetails}
    echo -e "\n# tpm2_getcap properties-fixed" >> ${__INTERNAL_limeTPMDetails}
    tpm2_getcap properties-fixed >> ${__INTERNAL_limeTPMDetails}
    echo -e "\n# tpm2_getcap algorithms" >> ${__INTERNAL_limeTPMDetails}
    tpm2_getcap algorithms >> ${__INTERNAL_limeTPMDetails}
    echo -e "\n# tpm2_getcap pcrs" >> ${__INTERNAL_limeTPMDetails}
    tpm2_getcap pcrs >> ${__INTERNAL_limeTPMDetails}
    echo >> ${__INTERNAL_limeTPMDetails}

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

=head2 limeTPMEmulator

Returns the name of the TPM emulator to use

    limeTPMEmulator

=over

=back

Returns 0 as exit status.

=cut

limeTPMEmulator() {
    # We use swtpm by default, unless in EL8 -- since tpm2-tss shipped
    # there does not support it, we will use ibmswtpm2 instead.
    _tpm_emulator=swtpm
    if rlIsRHEL 8 || rlIsCentOS 8; then
        _tpm_emulator=ibmswtpm2
    fi
    echo "${_tpm_emulator}"
}

true <<'=cut'
=pod

=head2 __limeStartTPMEmulator_swtpm

Start TPM emulator swtpm

    __limeStartTPMEmulator_swtpm

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

__limeStartTPMEmulator_swtpm() {

    __limeStopTPMEmulator_swtpm
    if rpm -q swtpm &> /dev/null; then
        mkdir -p /var/lib/tpm/swtpm
        rlServiceStart swtpm
    fi
}

true <<'=cut'
=pod

=head2 __limeStartTPMEmulator_ibmswtpm2

Start TPM emulator ibmswtpm2

    __limeStartTPMEmulator_ibmswtpm2

=over

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

__limeStartTPMEmulator_ibmswtpm2() {
    __limeStopTPMEmulator_ibmswtpm2
    if rpm -q ibmswtpm2 &> /dev/null; then
        rlServiceStart ibmswtpm2
    fi
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
    _emulator=$(limeTPMEmulator)

    case "${_emulator}" in
    swtpm)
        limeStopTPMEmulator
        __limeStartTPMEmulator_swtpm
        ;;
    ibmswtpm2)
        limeStopTPMEmulator
        __limeStartTPMEmulator_ibmswtpm2
        ;;
    *)
        rlLogWarning "Unsupported TPM emulator (${_emulator})"
        return 1
        ;;
    esac
}

true <<'=cut'
=pod

=head2 __limeStopTPMEmulator_swtpm

Stop swtpm TPM Emulator.

    __limeStopTPMEmulator_swtpm

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

__limeStopTPMEmulator_swtpm() {
    if rpm -q swtpm &> /dev/null; then
        rlServiceStop swtpm
    fi
}

true <<'=cut'
=pod

=head2 __limeStopTPMEmulator_ibmswtpm2

Stop ibmswtpm2 TPM Emulator.

    __limeStopTPMEmulator_ibmswtpm2

=over

=back

Returns 0 when the stop was successful, non-zero otherwise.

=cut

__limeStopTPMEmulator_ibmswtpm2() {
    if rpm -q ibmswtpm2 &> /dev/null; then
        rlServiceStop ibmswtpm2
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
    _emulator=$(limeTPMEmulator)

    case "${_emulator}" in
    swtpm)
        __limeStopTPMEmulator_swtpm
        ;;
    ibmswtpm2)
        __limeStopTPMEmulator_ibmswtpm2
        ;;
    *)
        rlLogWarning "Unsupported TPM emulator (${_emulator})"
        return 1
        ;;
    esac
}

true <<'=cut'
=pod

=head2 limeCheckRemotePort

Use limeCheckRemotePort to check port on specified ip adress.

    limeCheckRemotePort [LOGFILE] [PORT_NUMBER] [IP]

=over

=item

    PORT - Port number to check it.

=item

    IP - IP adress to specify host.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

function limeCheckRemotePort() {

    PORT=$1
    IP=$2

    echo $IP | grep -q "::" && NMAP_PARAMS="-6"

    nmap -p $PORT $IP $NMAP_PARAMS | grep -E -q "^${PORT}/(tcp|udp) open"
}

true <<'=cut'
=pod

=head2 limeWaitForKeylimeService

Use rlWaitForSocket to wait for the services to start or if it's remote,
use limeCheckRemotePort for check open ports.

    limeWaitForKeylimeService [LOGFILE] [PORT_NUMBER] [IP]

=over

=item

    LOGFILE - Filepath to a log file.

=item

    PORT - Port number to wait for.

=item

    IP - IP adress to wait for.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForKeylimeService() {

    local LOGFILE=$1
    local PORT=$2
    local IP=$3

    if [ -z "${IP}" ]; then
        if ! rlWaitForSocket $PORT -d 0.5 -t ${limeTIMEOUT}; then
            cat $LOGFILE
            return 1
        else
            return 0
        fi
    else
        rlWaitForCmd "limeCheckRemotePort ${PORT} ${IP}" -m 5 -t ${limeTIMEOUT} -d 1
    fi
}

true <<'=cut'
=pod

=head2 limeWaitForVerifier

Use rlWaitForSocket to wait for the verifier to start.

    limeWaitForVerifier [PORT_NUMBER] [IP]

=over

=item

    PORT_NUMBER - Port number to wait for, 8881 by default.

=item

    IP - IP adress to wait for, local by default.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForVerifier() {

    local PORT
    local IP=$2

    [ -n "$1" ] && PORT=$1 || PORT=8881

    limeWaitForKeylimeService $(limeVerifierLogfile) $PORT $IP
}

true <<'=cut'
=pod

=head2 limeWaitForRegistrar

Use rlWaitForSocket to wait for the registrar to start.

    limeWaitForRegistrar [PORT_NUMBER] [IP]

=over

=item

    PORT_NUMBER - Port number to wait for, 8891 by default.

=item

    IP - IP adress to wait for, local by default.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForRegistrar() {

    local PORT
    local IP=$2

    [ -n "$1" ] && PORT=$1 || PORT=8891

    limeWaitForKeylimeService $(limeRegistrarLogfile) $PORT $IP
}


true <<'=cut'
=pod

=head2 limeWaitForAgent

Use rlWaitForSocket to wait for the agent to start.

    limeWaitForAgent [PORT_NUMBER]

=over

=item

    PORT_NUMBER - Port number to wait for, 9002 by default.

=back

Returns 0 when the start was successful, non-zero otherwise.

=cut

limeWaitForAgent() {

    local PORT
    [ -n "$1" ] && PORT=$1 || PORT=9002

    limeWaitForKeylimeService $( limeAgentLogfile ) $PORT
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
    rlWaitForSocket $PORT -d 0.5 -t ${limeTIMEOUT}

}


true <<'=cut'
=pod

=head2 limeWaitForAgentStatus

Run 'keylime_tenant -c status' wrapper repeatedly up to TIMEOUT seconds
until the expected agent status is returned.

    limeWaitForAgentStatus UUID STATUS [TIMEOUT]

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

limeWaitForAgentStatus() {
    local TIMEOUT=${limeTIMEOUT}
    local UUID="$1"
    local STATUS="$2"
    local OUTPUT=`mktemp`
    [ -z "$1" ] && return 3
    [ -z "$2" ] && return 4
    [ -n "$3" ] && TIMEOUT=$3

    for I in `seq $TIMEOUT`; do
        keylime_tenant -c status -u $UUID &> $OUTPUT
	if grep -E -q "\"operational_state\": \"$STATUS\"" $OUTPUT; then
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


true <<'=cut'
=pod

=head2 limeWaitForAgentRegistration

Run 'keylime_tenant -c regstatus' wrapper repeatedly up to TIMEOUT seconds
until the expected agent is registered.

    limeWaitForAgentRegistration UUID [TIMEOUT]

=over

=item

    UUID - Agent UUID to query the status for.

=item

    TIMEOUT - Maximum time in seconds to wait (default 30)

=back

Returns 0 when the start was successful, 1 otherwise.

=cut

limeWaitForAgentRegistration() {
    local TIMEOUT=${limeTIMEOUT}
    local UUID="$1"
    local OUTPUT=`mktemp`
    [ -z "$1" ] && return 3
    [ -n "$2" ] && TIMEOUT=$2

    for I in `seq $TIMEOUT`; do
        keylime_tenant -c regstatus -u $UUID &> $OUTPUT
	if grep -q "Agent $UUID exists on registrar" $OUTPUT; then
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
    limeInstallIMAConfig default

=over

=item FILE

Path to a IMA configuration file that should be used.
Library default (ima-policy-simple) would be used if
not passed.

Without arguments, it will install the default policy,
unless IMA policy has been installed previously.

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeInstallIMAConfig() {

    local FILE
    local DEFAULT=ima-policy-simple

    #when no policy has been passed as an argument
    if [ -z "$1" ]; then
        # if IMA policy is already installed, do nothing
        if [ -f "${__INTERNAL_limeTmpDir}/installed-ima-policy" ]; then
            echo "IMA policy already installed, doing nothing."
        # otherwise going to install the default policy
        else
            FILE="${limeLibraryDir}/${DEFAULT}"
        fi
    # when policy has been passed
    else
        if [ "$1" == "default" ]; then
           FILE="${limeLibraryDir}/${DEFAULT}"
        elif [ -f "${limeLibraryDir}/$1" ]; then
            FILE="${limeLibraryDir}/$1"
        else
            echo "Cannot find file ${limeLibraryDir}/$1"
            exit 1
        fi
    fi

    # Install required policy
    if [ -n "${FILE}" ]; then
        echo "Installing IMA policy from ${FILE}"
        mkdir -p /etc/ima/
        cat ${FILE} > /etc/ima/ima-policy && cat ${FILE} > ${__INTERNAL_limeTmpDir}/installed-ima-policy
        if [ $(cat /sys/kernel/security/ima/policy | wc -l) -eq 0 ]; then
            cat ${FILE} > /sys/kernel/security/ima/policy
        else
            echo "Warning: IMA policy already configured in /sys/kernel/security/ima/policy"
        fi
    fi

    # print details about the installed policy
    if [ -n "$FILE" ]; then
        echo -e "~~~~~~~~~~~~~~~~~~~~\nRequired policy\n~~~~~~~~~~~~~~~~~~~~"
        cat ${FILE}
    fi
    echo -e "~~~~~~~~~~~~~~~~~~~~\nEffective policy\n~~~~~~~~~~~~~~~~~~~~"
    cat /sys/kernel/security/ima/policy
    echo -e "~~~~~~~~~~~~~~~~~~~~\nInstalled policy (will be used after next system reboot)\n~~~~~~~~~~~~~~~~~~~~"
    cat /etc/ima/ima-policy
    echo -e "~~~~~~~~~~~~~~~~~~~~"
}

true <<'=cut'
=pod

=head2 limeInstallIMAKeys

Generate and install IMA/EVM keys to /etc/keys/ or to the specified destination. 
The file name consists of a prefix and a suffix. The prefix depends on the key type 
and the suffix is specified by the SUFFIX parameter.

    limeInstallIMAKeys

=over

=item SUFFIX

Name of a keys and certificate file.

=item DEST

Destination directory where to copy a files (/etc/keys directory by default).

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeInstallIMAKeys() {

    local SUFFIX=$1
    local DEST=$2
    local IMAPrivateKey=${limeIMAPrivateKey}
    local IMAPublicKey=${limeIMAPublicKey}
    local IMACertificateDER=${limeIMACertificateDER}

    if [ -n "${SUFFIX}" ] && [ -z "${DEST}" ]; then
            IMAPrivateKey=/etc/keys/privkey_${SUFFIX}.pem
            IMAPublicKey=/etc/keys/x509_${SUFFIX}.pem
            IMACertificateDER=/etc/keys/x509_${SUFFIX}.der
    elif [ -n "${SUFFIX}" ] && [ -n "${DEST}" ]; then
            IMAPrivateKey=${DEST}/privkey_${SUFFIX}.pem
            IMAPublicKey=${DEST}/x509_${SUFFIX}.pem
            IMACertificateDER=${DEST}/x509_${SUFFIX}.der
    fi

    if ! [ -f ${IMAPrivateKey} ]; then
        local CONFIG=$( mktemp )
        cat <<END >${CONFIG}
[ req ]
default_bits = 2048
default_md = sha256
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = myexts

[ req_distinguished_name ]
O = IMAlimeLib
CN = Executable Signing Key
emailAddress = lime@no.body.com

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
END
        openssl req -x509 -new -nodes -utf8 -days 90 -batch -x509 -config ${CONFIG} -outform DER -out ${IMACertificateDER} -keyout ${IMAPrivateKey} && \
        openssl rsa -pubout -in ${IMAPrivateKey} -out ${IMAPublicKey} && \
        ls -l ${__INTERNAL_limeIMAKeysDir}
    fi
}

true <<'=cut'
=pod

=head2 limeCreateTestLists

Creates allowlist.txt and excludelist.txt to be used for testing purposes.
Allowlist will contain only initramdisk related content and files provided
as command line arguments.
Exclude list will contain all root dir / content except /keylime-tests plus
regular expressions specified on a command line.
This is based on an assumption that content used for testing purposes will
be created under /keylime-tests in a directory with an unique name.
See limeExtendNextExcludelist and limeCreateTestDir for more details.

    limeCreateTestLists [ -e REXEXP ] [FILE] ...

=over

=item -e

Append REGEXP to exclude list.

=back

Returns 0 when the initialization was successfull, non-zero otherwise.

=cut

limeCreateTestLists() {

    local ALLOW=""
    local EXCLUDE=""

    while [ $# -gt 0 ]; do
        if [ "$1" == "-e" ]; then
            EXCLUDE="$2\n${EXCLUDE}"
	    shift 2
        else
            ALLOW="$1 ${ALLOW}"
	    shift 1
        fi
    done

    # generate allowlist
    bash $limeLibraryDir/create_allowlist.sh allowlist.txt sha256sum -- ${ALLOW} && \
    # generate excludelist
    bash $limeLibraryDir/create_excludelist.sh excludelist.txt && \
    # make sure the file exists
    touch $__INTERNAL_limeBaseExcludeList && \
    cat $__INTERNAL_limeBaseExcludeList >> excludelist.txt
    echo -e "${EXCLUDE}" >> excludelist.txt

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

true <<'=cut'
=pod

=head2 limeGetRevocationScriptType

Prints to STDOUT a type of revocation scripts, either "module" or "script" (default).
Can be controlled globally by setting environment variable limeREVOCATION_SCRIPT_TYPE.

=over

=back

Returns 0, prints revocation script type to STDOUT.

=cut

limeGetRevocationScriptType() {

    local AGENT=$( which keylime_agent )

    # follow limeREVOCATION_SCRIPT_TYPE variable if set
    if [ "${limeREVOCATION_SCRIPT_TYPE}" == "module" -o "${limeREVOCATION_SCRIPT_TYPE}" == "script" ]; then
        echo ${limeREVOCATION_SCRIPT_TYPE}
    # for Python agent we use python modules
    elif file ${AGENT} | grep -qi python; then
        echo "module"
    # default is "script"
    else
        echo "script"
    fi

}

true <<'=cut'
=pod

=head2 limeCopyKeylimeFile

Copy keylime file identified by NAME to the specified DEST location. Eventually, downloads file from keylime Git repository.

    limeCopyKeylimeFile [--install|--source] NAME [DEST]

    E.g.

    limeCopyKeylimeFile --install scripts/create_mb_refstate .

=over

=item -i, --install

Locate file amongst keylime files installed on a system (/var/tmp/keylime_sources or /var/tmp/rust-keylime_sources).
This is the default behavior.

=item -s, --source

Locate file amongst keylime sources present on a system or copy from a Git repo. You should avoid using --source
unless it is really necessary (e.g. file you need is not being shipped/installed).

=item NAME

Name of a file to locate and copy. Can contain a directory prefix in order to better specify the required file.

=item DEST

Destination directory where to copy a file (current working directory by default)

=back

Returns 0 when the copy or download of file to actual dir is succesfull.

=cut

limeCopyKeylimeFile(){

    local OPTION="--install"

    if [ "$1" == "--install" -o "$1" == "--source" ]; then
        OPTION="$1"
        shift
    fi

    local NAME=$1
    local DEST=$2

    if [ -z "${NAME}" ]; then
        echo "Parameter NAME was not provided."
        return 1
    fi

    if [ -z "${DEST}" ]; then
        DEST=$PWD
    fi

    local FILEPATH=$(limeGetKeylimeFilepath ${OPTION} ${NAME})
    # get filepath to the variable and if file exist, copy file to specified dir
    if [ -n "${FILEPATH}" ]; then
        echo "Copying ${FILEPATH} to ${DEST}"
        cp ${FILEPATH} ${DEST}
    # source file that was not found on a system will be downloaded
    elif [ "${OPTION}" == "-s" -o "${OPTION}" == "--source" ]; then
        echo "Downloading https://raw.githubusercontent.com/keylime/keylime/master/${NAME} to ${DEST}"
        pushd ${DEST}
        curl -O https://raw.githubusercontent.com/keylime/keylime/master/${NAME}
        popd
    else
        echo "Could not find file matching ${NAME} on a local system"
        return 1
    fi
}

true <<'=cut'
=pod

=head2  limeGetKeylimeFilepath

Locates the specified keylime file identified by NAME on a system and prints its path on STDOUT.

    limeGetKeylimeFilepath {--source|--install} NAME

    E.g.

    limeGetKeylimeFilepath --install keylime/config.py

=over

=item -s. --source

Locate file amongst keylime sources present on a system (/var/tmp/keylime_sources or /var/tmp/rust-keylime_sources).

=item -i, --install

Locate file amongst keylime files installed on a system.

=item NAME

Name of a file to locate and copy. Can contain a directory prefix in order to better specify the required file.

=back

Write path of a located file to STDOUT or an empty string

=cut

limeGetKeylimeFilepath(){

    local OPTION=$1
    local FILENAME=$2

    if [ -z "${OPTION}" ] || [ -z "${FILENAME}" ]; then
        echo "Parameters are empty."
        return 1
    fi

    case $OPTION in

        --source | -s)
            WHERE="/var/tmp/keylime_sources /var/tmp/rust-keylime_sources"
            ;;
            
        --install | -i)
            WHERE="/usr/lib/python*/site-packages/keylime /usr/local/lib/python*/site-packages/keylime*/keylime"
            ;;
    
    esac

    find ${WHERE} -print 2> /dev/null | grep ${FILENAME} | head -1

}

# ~~~~~~~~~~~~~~~~~~~~
#   Logging
# ~~~~~~~~~~~~~~~~~~~~

__limeServiceLogfile() {

    local NAME=$1
    local LOGNAME=$( __limeGetLogName $NAME $2 )

    # for systemd service purge all logs since the beginning of the test
    if limeServiceUnitFileExists keylime_${NAME}; then
        local DATE=$( stat -c '%Y' $__INTERNAL_limeLogCurrentTest ) 2> /dev/null
        journalctl -u keylime_${NAME} --since "@${DATE}" &> $LOGNAME
    fi
    # print a path to the log
    echo $LOGNAME

}

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

    __limeServiceLogfile verifier

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

    __limeServiceLogfile registrar

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

    __limeServiceLogfile agent

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
    __limeServiceLogfile ima_emulator IMAEmulator

}

true <<'=cut'
=pod

=head2 limeLogfileSubmit

Wrapper around Beakerlib function rlFileSubmit that prints the provided file
to STDOUT if the test failed, i.e. $__INTERNAL_TEST_STATE > 0.

    limeLogfileSubmit [-s|--silent] FILE

=over

=item -s. --silent

Do not print log to STDOUT

=back

Returns 0.

=cut


limeLogfileSubmit() {

    local STATE=${__INTERNAL_TEST_STATE:-0}
    local SILENT=""


    if [ "$1" == "-s" -o "$1" == "--silent" ]; then
        SILENT="1"
        shift
    fi

    if [ ${STATE} -gt 0 -a -n "$1" -a -z "${SILENT}" ]; then
        cat $1
    fi
    rlFileSubmit $1

}


true <<'=cut'
=pod

=head2 limeSubmitCommonLogs

Uses rlFileSubmit to submit common logs. Currently these are:
  $limeVerifierLogfile
  $limeRegistrarLogfile
  $limeAgentLogfile
  $limeIMAEmulatorLogfile (if limeTPMEmulated)
  /sys/kernel/security/ima/ascii_runtime_measurements
  $__INTERNAL_limeTPMDetails

    limeSubmitCommonLogs

=over

=back

Returns 0.

=cut


limeSubmitCommonLogs() {

    [ -f $(limeVerifierLogfile) ] && limeLogfileSubmit $(limeVerifierLogfile)
    [ -f $(limeRegistrarLogfile) ] && limeLogfileSubmit $(limeRegistrarLogfile)
    [ -f $(limeAgentLogfile) ] && limeLogfileSubmit $(limeAgentLogfile)
    if limeTPMEmulated && [ -f $(limeIMAEmulatorLogfile) ]; then
            limeLogfileSubmit $(limeIMAEmulatorLogfile)
    fi
    cat /sys/kernel/security/ima/ascii_runtime_measurements > $__INTERNAL_limeTmpDir/ascii_runtime_measurements
    gzip -f $__INTERNAL_limeTmpDir/ascii_runtime_measurements
    limeLogfileSubmit --silent $__INTERNAL_limeTmpDir/ascii_runtime_measurements.gz
    cat /sys/kernel/security/ima/binary_runtime_measurements > $__INTERNAL_limeTmpDir/binary_runtime_measurements
    gzip -f $__INTERNAL_limeTmpDir/binary_runtime_measurements
    limeLogfileSubmit --silent $__INTERNAL_limeTmpDir/binary_runtime_measurements.gz
    [ -f ${__INTERNAL_limeTPMDetails} ] && limeLogfileSubmit ${__INTERNAL_limeTPMDetails}

}

true <<'=cut'
=pod

=head2 limeconCreateNetwork

Create container network.

    limeconCreateNetwork NAME SUBNET

=over

=item NAME

Name of container network.

=item SUBNET

Container network subnet in CIDR format, for example 172.18.0.0/16.

=back

Returns 0.

=cut

limeconCreateNetwork() {

    local NAME=$1
    local SUBNET=$2

    if [ -z "${NAME}" ] || [ -z "${SUBNET}" ]; then
        echo "Network name or network subnet was not specified!"
        echo "Usage: limeconCreateNetwork \"agent_network\" 172.18.0.0/16"
        return 1
    fi

    podman network create --subnet=$SUBNET $NAME
    podman network inspect $NAME
}

true <<'=cut'
=pod

=head2 limeconDeleteNetwork

Delete container network.

    limeconDeleteNetwork NAME

=over

=item NAME

Name of the container network.

=back

Returns 0.

=cut

limeconDeleteNetwork() {

    local NAME=$1

    podman network rm $NAME
}

true <<'=cut'
=pod

=head2 limeconPrepareAgentImage

Prepare podman image with keylime agent. Install keylime agent and
copy CA cert from the host into image and set needed permissions.

    limeconPrepareAgentImage [-f|--file DOCKER_FILE] TAG

=over

=item -f, --file DOCKER_FILE

Parameter specify use of non-default docker file.

=item TAG

Name of image tag.

=back

Returns 0.

=cut

limeconPrepareAgentImage() {

    if [ "$1" == "-f" -o "$1" == "--file" ]; then
        local DOCKER_FILE=$2
        shift 2
    else
        echo "Using default docker file: ${limeLibraryDir}/Dockerfile.agent"
        DOCKER_FILE="${limeLibraryDir}/Dockerfile.agent"
    fi

    local TAG=$1

    cp /var/lib/keylime/cv_ca/cacert.crt .    
    ls /root/.ssh/id_*.pub || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
    cp /root/.ssh/id_*.pub .
    cp ${limeLibraryDir}/lime_con_start.sh .
    podman build -t=$TAG --file $DOCKER_FILE .
}

true <<'=cut'
=pod

=head2 limeconPrepareRegistrarImage

Prepare podman image with keylime registrar. Install keylime registrar.

    limeconPrepareAgentImage [-f|--file DOCKER_FILE] TAG

=over

=item -f, --file DOCKER_FILE

Parameter specify use of non-default docker file.

=item TAG

Name of image tag.

=back

Returns 0.

=cut

limeconPrepareRegistrarImage() {

    if [ "$1" == "-f" -o "$1" == "--file" ]; then
        local DOCKER_FILE=$2
        shift 2
    else
        echo "Using default docker file: ${limeLibraryDir}/Dockerfile.registrar"
        DOCKER_FILE="${limeLibraryDir}/Dockerfile.registrar"
    fi

    local TAG=$1

    ls /root/.ssh/id_*.pub || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
    cp /root/.ssh/id_*.pub .
    cp ${limeLibraryDir}/lime_con_start.sh .
    podman build -t=$TAG --file $DOCKER_FILE .
}

true <<'=cut'
=pod

=head2 limeconPrepareVerifierImage

Prepare podman image with keylime verifier. Install keylime verifier.

    limeconPrepareAgentImage [-f|--file DOCKER_FILE] TAG

=over

=item -f, --file DOCKER_FILE

Parameter specify use of non-default docker file.

=item TAG

Name of image tag.

=back

Returns 0.

=cut

limeconPrepareVerifierImage() {

    if [ "$1" == "-f" -o "$1" == "--file" ]; then
        local DOCKER_FILE=$2
        shift 2
    else
        echo "Using default docker file: ${limeLibraryDir}/Dockerfile.verifier"
        DOCKER_FILE="${limeLibraryDir}/Dockerfile.verifier"
    fi

    local TAG=$1

    ls /root/.ssh/id_*.pub || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
    cp /root/.ssh/id_*.pub .
    cp ${limeLibraryDir}/lime_con_start.sh .
    podman build -t=$TAG --file $DOCKER_FILE .
}

true <<'=cut'
=pod

=head2 limeconRunAgent

Container run via podman with specified parameters.

    limeconRunAgent NAME TAG IP NETWORK AGENT_FILE TESTDIR 

=item NAME

Set name of container.

=item TAG

Name of image tag.

=item IP

IP address of container.

=item NETWORK

Name of used podman network.

=item AGENT_FILE

Mounted dir with configuration file.

=item TESTDIR

Mounted test dir.

=back

Returns 0.

=cut

limeconRunAgent() {

    local NAME=$1
    local TAG=$2
    local IP=$3
    local NETWORK=$4
    local AGENT_FILE=$5
    local TESTDIR=$6

    podman run -d --name $NAME --net $NETWORK --ip ${IP} --privileged --volume=${AGENT_FILE}:/etc/keylime/ --volume=/sys/kernel/security/:/sys/kernel/security/:ro --volume=${TESTDIR}:${TESTDIR}:rw --device=/dev/tpmrm0  localhost/$TAG /usr/local/bin/lime_con_start /usr/bin/keylime_agent
}

true <<'=cut'
=pod

=head2 limeconRunRegistrar

Container run via podman with specified parameters.

    limeconRunRegistrar NAME TAG IP NETWORK

=item NAME

Set name of container.

=item TAG

Name of image tag.

=item IP

IP address of container.

=item NETWORK

Name of used podman network.

=back

Returns 0.

=cut

limeconRunRegistrar() {

    local NAME=$1
    local TAG=$2
    local IP=$3
    local NETWORK=$4


    podman run -d --name $NAME --net $NETWORK --ip $IP --cap-add CAP_AUDIT_WRITE --cap-add CAP_SYS_CHROOT --volume=/etc/keylime/:/etc/keylime/ --volume=$PWD/cv_ca:/var/lib/keylime/cv_ca:z localhost/$TAG /usr/local/bin/lime_con_start /usr/bin/keylime_registrar
}

true <<'=cut'
=pod

=head2 limeconRunVerifier

Container run via podman with specified parameters.

    limeconRunVerifier NAME TAG IP NETWORK

=item NAME

Set name of container.

=item TAG

Name of image tag.

=item IP

IP address of container.

=item NETWORK

Name of used podman network.

=back

Returns 0.

=cut

limeconRunVerifier() {

    local NAME=$1
    local TAG=$2
    local IP=$3
    local NETWORK=$4

    podman run -d --name $NAME --net $NETWORK --ip $IP --cap-add CAP_AUDIT_WRITE --cap-add CAP_SYS_CHROOT --volume=/etc/keylime/:/etc/keylime/ localhost/$TAG /usr/local/bin/lime_con_start /usr/bin/keylime_verifier
}

true <<'=cut'
=pod

=head2 limeconPrepareAgentConfdir

Setup agent configuration files for container and copy to newly created confdir.

    limeconSetupAgent AGENT_ID AGENT_IP CONF_DIR

=over

=item AGENT_ID

ID of keylime agent.

=item AGENT_IP

Ip address of keylime agent in container.

=item CONF_DIR

Name of dir for agent config files.

=back

Returns 0.

=cut

limeconPrepareAgentConfdir() {

        local AGENT_ID=$1
        local AGENT_IP=$2
        local CONF_DIR=$3

        echo "Creating dir ${CONFIG_DIR}"
        mkdir -p $CONF_DIR

        cp -r /etc/keylime/* $CONF_DIR
        limeUpdateConf -d $CONF_DIR agent uuid \"$AGENT_ID\"
        limeUpdateConf -d $CONF_DIR agent ip \"$AGENT_IP\"
        limeUpdateConf -d $CONF_DIR agent contact_ip \"$AGENT_IP\"
}

true <<'=cut'
=pod

=head2 limeconStop

Stop container, delete container and set default permission 
for agent container if stopping agent container.

    limeconStop NAMES

=over

=item NAMES

Name of the container to be stopped, could be regular expression.

Returns 0.

=cut

limeconStop() {

        local NAMES=$1

        podman ps -a --format "{{.Names}}" | grep -e "^${NAMES}\$" | xargs podman stop -t 3 | xargs podman rm
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Initialization
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

#   Create $__INTERNAL_limeTmpDir directory

mkdir -p $__INTERNAL_limeTmpDir
mkdir -p $__INTERNAL_limeCoverageDir
mkdir -p $__INTERNAL_limeIMAKeysDir

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

# prepare coveragerc file
if rpm -q keylime-99 &> /dev/null; then
  KEYLIMESRC=$( ls -d /usr/local/lib/python*/site-packages/keylime-*/keylime 2> /dev/null )
else
  KEYLIMESRC=$( ls -d /usr/lib/python*/site-packages/keylime 2> /dev/null )
fi
cat > /var/tmp/limeLib/coverage/coveragerc <<_EOF
[run]
source = /usr/bin/,/usr/local/bin/,/usr/share/keylime/,$KEYLIMESRC
parallel = True
concurrency = multiprocessing,thread
context = foo
omit = test_*,*example*
_EOF
# set code coverage context depending on a test
# create context depending on the test directory by
# cuting-off the *keylime-tests* (git repo dir) part
__INTERNAL_limeCoverageContext=$( cat $__INTERNAL_limeLogCurrentTest | sed -e 's#.*keylime-tests[^/]*\(/.*\)#\1#' )
sed -i "s#context =.*#context = ${__INTERNAL_limeCoverageContext}#" /var/tmp/limeLib/coverage/coveragerc
# we need to save context to a place where systemd can access it without SELinux complaining
export COVERAGE_PROCESS_START=/var/tmp/limeLib/coverage/coveragerc

# create limeTestUser if it does not exists
if ! id ${limeTestUser}; then
    useradd -m --user-group ${limeTestUser} --uid ${limeTestUserUID}
fi

# delete previously existing TPM data
rm -f ${__INTERNAL_limeTPMDetails}

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
        # print keylime package versions
        echo -e "\nInstalled keylime RPMs"
        rpm -qa \*keylime\*
        return 0
    else
        rlLogError "Failed loading library keylime/test-helpers."
        return 1
    fi

    local PACKAGES="tpm2-tools openssl beakerlib podman nmap"

    echo -e "\nInstall packages required by the library when missing."
    rpm -q $PACKAGES || yum -y install $PACKAGES
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

