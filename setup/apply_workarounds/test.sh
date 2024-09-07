#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1


rlJournalStart

    rlPhaseStartTest "Apply SELinux policy workarounds"
        MODULE=keylime_tests_workarounds
        if semodule -l | grep -q $MODULE; then
            rlRun "semodule -r $MODULE"
        fi
	DIST=$( rpm -E '%dist' )
	# try to use distro specific policy, it is OK if it doesn't exist
	rlRun "mv ${MODULE}.te${DIST} ${MODULE}.te" 0,1
	rlRun "mv ${MODULE}.fc${DIST} ${MODULE}.fc" 0,1
        if [ -f ${MODULE}.te ]; then
            rlRun "yum -y install selinux-policy-devel"
            rlRun "make -f /usr/share/selinux/devel/Makefile $MODULE.pp"
            rlAssertExists $MODULE.pp
            rlRun "semodule -i $MODULE.pp"
        else
            rlLogInfo "No ${MODULE}.te available, skipping"
	fi
    rlPhaseEnd

    rlPhaseStartTest "Apply workaround bz#2297942"
        [ -f /usr/sbin/tpm2-abrmd ] && rlRun "restorecon -v /usr/sbin/tpm2-abrmd"
        rlPass
    rlPhaseEnd
rlJournalEnd
