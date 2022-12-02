#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# to upload code coverage define UPLOAD_COVERAGE=1
#UPLOAD_COVERAGE=0
UPLOAD_URL=https://transfer.sh
#UPLOAD_URL=https://free.keep.sh

# for proper patch code coverage functioning this script
# expects these env variables to be set from the outside
# PACKIT_SOURCE_URL - repo URL from which PR comes from
# PACKIT_SOURCE_BRANCH - branch from which PR comes from
# PACKIT_TARGET_URL - repo URL which PR targets
# PACKIT_TARGET_BRANCH - branch which PR targets
# PACKIT_SOURCE_SHA - last commit in the PACKIT_SOURCE_BRANCH

[ -n "${PATCH_COVERAGE_TRESHOLD}" ] || PATCH_COVERAGE_TRESHOLD=0

# for Packit PRs we would be uploading code coverage files unless forbidden
[ -n "${PACKIT_SOURCE_URL}" -a -z "${UPLOAD_COVERAGE}" ] && UPLOAD_COVERAGE=1

#export PACKIT_TARGET_BRANCH=master
#export PACKIT_SOURCE_BRANCH=quote_before_register
#export PACKIT_TARGET_URL=https://github.com/keylime/keylime
#export PACKIT_SOURCE_URL=https://github.com/ansasaki/keylime
#export PACKIT_SOURCE_SHA=a79b05642bbe04af0ef0a356afd4f5af276898bb

OMIT_FILES="--omit=/var/lib/keylime/secure/unzipped/*,*/keylime/backport_dataclasses.py"

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "which coverage"
    rlPhaseEnd

    rlPhaseStartTest "Generate overall coverage report"
        rlRun "pushd ${__INTERNAL_limeCoverageDir}"
        # first create combined report for Packit tests
        rlRun "chmod a+x *"
        ls -l .coverage*
        rlRun "coverage combine"
        ls -l .coverage*
        rlAssertExists .coverage
        # packit summary report
        rlLogInfo "keylime-tests code coverage summary report"
        rlRun "coverage report --include '*keylime*' $OMIT_FILES"
        rlRun "coverage xml --include '*keylime*' $OMIT_FILES"
        rlRun "mv coverage.xml coverage.packit.xml"
        rlRun "mv .coverage .coverage.packit"
        # testsuite summary report
        if [ -f coverage.testsuite ]; then
            rlLogInfo "keylime testsuite code coverage summary report"
            rlRun "cp coverage.testsuite .coverage"
            rlRun "coverage report --include '*keylime*' $OMIT_FILES"
        fi
        # unittests summary report
        if [ -f coverage.unittests ]; then
            rlLogInfo "keylime unittests code coverage summary report"
            rlRun "cp coverage.unittests .coverage"
            rlRun "coverage report --include '*keylime*' $OMIT_FILES"
        fi
        # now create overall report including upstream tests
        [ -f coverage.testsuite ] && rlRun "cp coverage.testsuite .coverage.testsuite"
        [ -f coverage.unittests ] && rlRun "cp coverage.unittests .coverage.unittests"
        rm -f .coverage
        ls -l .coverage*
        rlRun "coverage combine"
        ls -l .coverage*
        rlLogInfo "combined code coverage summary report"
        rlRun "coverage html --include '*keylime*' $OMIT_FILES --show-contexts"
        rlRun "coverage report --include '*keylime*' $OMIT_FILES"
        rlRun "cd .."
        rlRun "tar -czf coverage.tar.gz coverage"
        rlFileSubmit coverage.tar.gz
        # upload the archive to $UPLOAD_URL
        if [ "${UPLOAD_COVERAGE}" == "1" ]; then
            # upload coverage.tar.gz
            rlRun -s "curl --upload-file coverage.tar.gz $UPLOAD_URL"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "HTML code coverage report is available as GZIP archive at $URL"
            # upload coverage.xml reports
            for REPORT in coverage.packit.xml coverage.testsuite.xml coverage.unittests.xml; do
                ls coverage/$REPORT
                if [ -f coverage/$REPORT ]; then
                    rlRun -s "curl --upload-file coverage/$REPORT $UPLOAD_URL"
                    URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
                    rlLogInfo "$REPORT report is available at $URL"
                fi
            done
        fi
        rlRun "popd"
    rlPhaseEnd

    # log env variables exported by Packit CI
    env | grep PACKIT_

# generate patch coverage report when PACKIT variables were populated and we are targeting keylime repo
if [ -d /var/tmp/keylime_sources ] && [ -n "${PACKIT_SOURCE_URL}" ] && [ -n "${PACKIT_SOURCE_BRANCH}" ] && \
  [ "${PACKIT_TARGET_URL}" == "https://github.com/keylime/keylime" ] && [ -n "${PACKIT_TARGET_BRANCH}" ] && \
  [ -n "${PACKIT_SOURCE_SHA}" ]; then

    rlPhaseStartTest "Generate patch coverage report for upstream keylime"
        # from Packit CI / TMT we do not have the .git dir in /var/tmp/keylime_sources.. so we need to recreate the patch
        # using PACKIT_ variables
        rlRun "TmpDir=\$( mktemp -d )"
        rlRun "git clone --branch ${PACKIT_SOURCE_BRANCH} ${PACKIT_SOURCE_URL} ${TmpDir}"
        rlRun "pushd ${TmpDir}"
        rlRun "git remote add PR_TARGET ${PACKIT_TARGET_URL}"
        rlRun "git fetch PR_TARGET"
        rlRun "ANCESTOR_COMMIT=\$( git merge-base ${PACKIT_SOURCE_BRANCH} PR_TARGET/${PACKIT_TARGET_BRANCH} )"
        rlRun "git diff ${ANCESTOR_COMMIT}..${PACKIT_SOURCE_SHA} > $__INTERNAL_limeCoverageDir/patch.txt"
        rlRun "popd"
        rlRun "./patchcov.py ${__INTERNAL_limeCoverageDir}/patch.txt ${__INTERNAL_limeCoverageDir}/.coverage ${PATCH_COVERAGE_TRESHOLD}"
        rlRun "rm -rf ${TmpDir}"
    rlPhaseEnd

# generate patch coverage report when BASELINE_KEYLIME_RPM is defined, comparing against the installed RPM
elif [ -n "${BASELINE_KEYLIME_RPM}" ]; then

    rlPhaseStartTest "Generate patch coverage report for keylime RPM"
        rlLogInfo "Using ${BASELINE_KEYLIME_RPM} as a baseline RPM"
        rlRun "TmpDir=\$( mktemp -d )"
        rlRun "pushd ${TmpDir}"
        rlRun "mkdir sources"
        rlRpmDownload --source ${BASELINE_KEYLIME_RPM}
        rlRun "rpm -i keylime-*src.rpm"
        rlRun "rpmbuild --clean ~/rpmbuild/SPECS/keylime.spec"
        rlRun "rpmbuild -bp --nodeps ~/rpmbuild/SPECS/keylime.spec && rm -rf ~/rpmbuild/BUILD/keylime*/.git"
        rlRun "/usr/bin/cp -rf $(echo ~/rpmbuild/BUILD/keylime*)/* sources/"
        rlRun "pushd sources"
        rlRun "git init && git config user.email foo@bar.com && git config user.name 'Foo Bar'"
        rlRun "git add -A && git commit -m 'baseline'"
        rlRun "popd"
        rlRun "rpmbuild --clean ~/rpmbuild/SPECS/keylime.spec"
        rlRun "rm keylime-*src.rpm"
        rlFetchSrcForInstalled keylime
        rlRun "rpm -i keylime-*src.rpm"
        rlRun "rpmbuild --clean ~/rpmbuild/SPECS/keylime.spec"
        rlRun "rpmbuild -bp --nodeps ~/rpmbuild/SPECS/keylime.spec && rm -rf ~/rpmbuild/BUILD/keylime*/.git"
        rlRun "/usr/bin/cp -rf $(echo ~/rpmbuild/BUILD/keylime*)/* sources/"
        rlRun "pushd sources"
        rlRun "git diff > $__INTERNAL_limeCoverageDir/patch.txt"
        rlRun "popd"
        rlRun "popd"
        rlRun "./patchcov.py ${__INTERNAL_limeCoverageDir}/patch.txt ${__INTERNAL_limeCoverageDir}/.coverage ${PATCH_COVERAGE_TRESHOLD}"
        rlRun "rm -rf ${TmpDir}"
    rlPhaseEnd

fi

rlJournalEnd
