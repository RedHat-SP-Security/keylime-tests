#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# the script expects these env variables to be set from the outside
# PACKIT_FULL_REPO_NAME - we run patchcov only for 'keylime/keylime'
# PACKIT_TARGET_SHA - this is set by Packit CI
# PATCH_COVERAGE_TRESHOLD - this is the treshhold for the coverage pass/fail test (default 0)

[ -n "${PATCH_COVERAGE_TRESHOLD}" ] || PATCH_COVERAGE_TRESHOLD=0
#PACKIT_TARGET_SHA=3590e21b7e4b48a2023aadf2486b116ef5be2375
#PACKIT_FULL_REPO_NAME="keylime/keylime"

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "which coverage"
    rlPhaseEnd

    rlPhaseStartTest "Generate overall coverage report"
        rlRun "pushd ${__INTERNAL_limeCoverageDir}"
        rlRun "coverage combine"
        rlAssertExists .coverage
        rlRun "coverage html --include '*keylime*' --omit '/var/lib/keylime/secure/unzipped/*' --show-contexts"
        rlRun "coverage report --include '*keylime*' --omit '/var/lib/keylime/secure/unzipped/*'"
        rlRun "cd .."
        rlRun "tar -czf coverage.tar.gz coverage"
        rlFileSubmit coverage.tar.gz
        rlRun "popd"
    rlPhaseEnd

# generate patch coverage report only if PACKIT_TARGET_SHA has been populated
if [ -d /var/tmp/keylime_sources ] && [ -n "${PACKIT_TARGET_SHA}" ] && [ "${PACKIT_FULL_REPO_NAME}" == "keylime/keylime" ]; then

    rlPhaseStartTest "Generate patch coverage report"
        # log env variables exported by Packit CI
        rlRun "PACKIT_COMMIT_SHA=${PACKIT_COMMIT_SHA}"
        rlRun "PACKIT_TARGET_SHA=${PACKIT_TARGET_SHA}"
        # from Packit CI / TMT we do not have the git repo, only files.. so we need to recreate the patch
        rlRun "TmpDir=\$( mktemp -d )"
        rlRun "git clone https://github.com/keylime/keylime.git ${TmpDir}"
        rlRun "pushd ${TmpDir}"
        rlRun "git checkout ${PACKIT_TARGET_SHA}"
        rlRun "popd"
        rlRun "cp -r /var/tmp/keylime_sources/* ${TmpDir}"
        rlRun "pushd ${TmpDir}"
        rlRun "git diff > $__INTERNAL_limeCoverageDir/patch.txt"
        rlRun "popd"
        rlRun "./patchcov.py ${__INTERNAL_limeCoverageDir}/patch.txt ${__INTERNAL_limeCoverageDir}/.coverage ${PATCH_COVERAGE_TRESHOLD}"
        rlRun "rm -rf ${TmpDir}"
    rlPhaseEnd

fi

rlJournalEnd
