#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

export KEYLIME_SRC
export KEYLIME_TEST_MODE
export KEYLIME_TEST_SRC

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        rlRun "TmpDir=\$( mktemp -d )"
        pushd "$TmpDir" || rlDie "Cannot enter temporary directory $TmpDir"
	# prepare variables
	if [ -d /var/tmp/keylime_sources ]; then
            # keylime installed from sources in /var/tmp/keylime_sources
            KEYLIME_SRC=$( ls -d /usr/local/lib/python3.14/site-packages/keylime )
	    KEYLIME_DIR=/var/tmp/keylime_sources
	else
            # keylime installed from RPM
            rlRun "dnf download --source keylime"
            rlRun "rpm -i keylime*.src.rpm"
	    rlRun "rpmbuild -bp --nodeps ~/rpmbuild/SPECS/keylime.spec"
	    rlRun "rm -rf ~/rpmbuild/BUILD/keylime-*-SPECPARTS"
            KEYLIME_SRC=$( ls -d /usr/lib/*/site-packages/keylime )
	    KEYLIME_DIR="~/rpmbuild/BUILD/keylime*"
	fi
	[ -n "$KEYLIME_SRC" ] && [ -d "$KEYLIME_SRC" ] || rlDie "Cannot locate installed keylime files"
	KEYLIME_TEST_MODE=installed
	KEYLIME_TEST_SRC=$TmpDir/test
	# copy and link various test resources
	rlRun "cp -r ${KEYLIME_DIR}/{test,test-data} ."
	# prepare symlink to keylime sources
	rlRun "ln -s $KEYLIME_SRC keylime"
	for RES in scripts templates tpm_cert_store; do
            rlRun "ln -s /usr/share/keylime/$RES $RES"
        done
	# replace run_tests.sh script with the upstream version
	rlFileBackup "$KEYLIME_TEST_SRC/run_tests.sh"
	rlRun "curl -s https://raw.githubusercontent.com/keylime/keylime/refs/heads/master/test/run_tests.sh > $KEYLIME_TEST_SRC/run_tests.sh"
	# install green
        rlRun "pip3 install green"
        # backup keylime
        rlRun "rlFileBackup --missing-ok /var/lib/keylime"
        limeBackupConfig
    rlPhaseEnd

    rlPhaseStartTest "Run unit tests"
        rlRun "$KEYLIME_TEST_SRC/run_tests.sh"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        limeClearData
        limeRestoreConfig
        rlFileRestore
        rlRun "rm -rf $TmpDir"
    rlPhaseEnd

rlJournalEnd
