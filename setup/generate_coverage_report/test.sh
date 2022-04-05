#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# the script expects these env variables to be set from the outside
# PACKIT_SOURCE_URL - repo URL from which PR comes from
# PACKIT_SOURCE_BRANCH - branch from which PR comes from
# PACKIT_TARGET_URL - repo URL which PR targets
# PACKIT_TARGET_BRANCH - branch which PR targets
# PACKIT_SOURCE_SHA - last commit in the PACKIT_SOURCE_BRANCH

[ -n "${PATCH_COVERAGE_TRESHOLD}" ] || PATCH_COVERAGE_TRESHOLD=0

#export PACKIT_TARGET_BRANCH=master
#export PACKIT_SOURCE_BRANCH=quote_before_register
#export PACKIT_TARGET_URL=https://github.com/keylime/keylime
#export PACKIT_SOURCE_URL=https://github.com/ansasaki/keylime
#export PACKIT_SOURCE_SHA=a79b05642bbe04af0ef0a356afd4f5af276898bb

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
        # for PRs upload the archive to transfer.sh
        if [ -n "${PACKIT_SOURCE_URL}" ]; then
            rlRun -s "curl --upload-file coverage.tar.gz https://transfer.sh"
            URL=$( grep -o 'https:[^"]*' $rlRun_LOG )
            rlLogInfo "HTML code coverage report is available as GZIP archive at $URL"
        fi
        rlRun "popd"
    rlPhaseEnd

# generate patch coverage report only if PACKIT variables were populated and we are targeting keylime repo
if [ -d /var/tmp/keylime_sources ] && [ -n "${PACKIT_SOURCE_URL}" ] && [ -n "${PACKIT_SOURCE_BRANCH}" ] && \
  [ "${PACKIT_TARGET_URL}" == "https://github.com/keylime/keylime" ] && [ -n "${PACKIT_TARGET_BRANCH}" ] && \
  [ -n "${PACKIT_SOURCE_SHA}" ]; then

    rlPhaseStartTest "Generate patch coverage report"
        # log env variables exported by Packit CI
        rlRun "env | grep PACKIT_"
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

fi

rlJournalEnd
