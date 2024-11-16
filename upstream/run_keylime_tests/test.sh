#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# set REVOCATION_NOTIFIER=zeromq to use the zeromq notifier
[ -n "$REVOCATION_NOTIFIER" ] || REVOCATION_NOTIFIER=agent

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        if rlIsRHEL 8 || rlIsCentOS 8; then
            # need to use pip version of packaging module since we need v20 at minimum
            # https://github.com/keylime/keylime/issues/970
            rpm -q python3-packaging && rlRun "rpm -e python3-packaging" 0 "Removing python3-packaging as it is old and we need v20+"
            rlRun "pip3 install packaging"
        fi
        # backup keylime
        rlRun "rlFileBackup --missing-ok /var/lib/keylime"
        limeBackupConfig
        # update keylime configuration
        rlRun "limeUpdateConf agent run_as root:root"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"${REVOCATION_NOTIFIER}\"]'"
        # need to adjust file permissions since we are running keylime as root (for now)
        rlRun "rm -f /var/log/keylime/*"
        rlRun "chown -R root:root /var/lib/keylime"
        # install required python modules
        rlRun "pip3 install pytest-asyncio pyaml"
        # if keylime sources are not available, download SRPM rpm and extract it
        if ! test -e /var/tmp/keylime_sources; then
            rlFetchSrcForInstalled keylime
            rlAssertExists keylime*.src.rpm
            rlRun "rpm -i keylime*.src.rpm"
            rlRun "rpmbuild -bp --nodeps ~/rpmbuild/SPECS/keylime.spec"
            rlRun "ln -s ~/rpmbuild/BUILD/keylime* /var/tmp/keylime_sources"
        fi
        rlRun "TmpDir=\$( mktemp -d )"
        rlRun "cp -r /var/tmp/keylime_sources/* $TmpDir"
        pushd $TmpDir/test

	# Let's define PYTHONPATH to the keylime source, which will make it
	# so that we will use primarily the code from the keylime sources
	# tree under testing, instead of the installed (rpm) modules.
	rlRun "export PYTHONPATH=\"\${TmpDir}\""

        # if TPM emulator is present
        if limeTPMEmulated; then
            # start tpm emulator
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            # start ima emulator
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        # prepare /var/lib/keylime/secure tmpfs if note present
        SECDIR=/var/lib/keylime/secure
        if ! mount | grep -q ${SECDIR}; then
            rlRun "mkdir -p ${SECDIR}"
            rlRun "mount -t tmpfs -o size=1024k,mode=700 tmpfs ${SECDIR}"
        fi
        sleep 5
    rlPhaseEnd

    rlPhaseStartTest "Run unit tests"
        if ${__INTERNAL_limeCoverageEnabled}; then
            rlRun "/usr/local/bin/coverage run -m unittest discover -s keylime -p '*_test.py' -v"

            # generate separate XML report for unit tests
            ls -a .coverage*
            rlRun "coverage combine"
            rlRun "coverage xml --include '*keylime*' --omit '/var/lib/keylime/secure/unzipped/*'"
            rlRun "mv coverage.xml ${__INTERNAL_limeCoverageDir}/coverage.unittests.xml"
            rlRun "mv .coverage ${__INTERNAL_limeCoverageDir}/coverage.unittests"
        else
            rlRun "python3 -m unittest discover -s keylime -p '*_test.py' -v"
        fi
    rlPhaseEnd

    for TEST in `ls test_*.py`; do
        rlPhaseStartTest "Run $TEST"
            if [ "${TEST}" == "test_restful.py" ] && ( rlIsRHEL 8 || rlIsCentOS 8); then
                rlLogInfo "Skipping test_restful.py on RHEL-8/CentOS Stream 8 as the test is not stable"
            else
                if ${__INTERNAL_limeCoverageEnabled}; then
                    # update coverage context to this particular test
                    rlRun "sed -i 's#context =.*#context = ${TEST}#' /var/tmp/limeLib/coverage/coveragerc"
                    rlRun "/usr/local/bin/coverage run -m unittest ${PWD}/${TEST} -v"
                else
                    rlRun "python3 -m unittest ${PWD}/${TEST} -v"
                fi
            fi
        rlPhaseEnd
    done

    rlPhaseStartCleanup "Do the keylime cleanup"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
        fi

        if ${__INTERNAL_limeCoverageEnabled}; then
            # generate separate XML report for upstream tests
            ls -al .coverage*
            rlRun "coverage combine"
            rlRun "coverage xml --include '*keylime*' --omit '/var/lib/keylime/secure/unzipped/*'"
            rlRun "mv coverage.xml ${__INTERNAL_limeCoverageDir}/coverage.testsuite.xml"
            rlRun "mv .coverage ${__INTERNAL_limeCoverageDir}/coverage.testsuite"
        fi
 
        popd
        limeClearData
        limeRestoreConfig
        rlRun "rlFileRestore"
        rlRun "limeCondStopAbrmd"
        rlRun "rm -rf $TmpDir"
    rlPhaseEnd

rlJournalEnd
