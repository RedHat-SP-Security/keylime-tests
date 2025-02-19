# this file is supposed to be loaded into test.sh

rlAssertRpm git
rpm -q redhat-release || rlDie "Not running on RHEL!"
rlLogInfo "Current working directory: ${PWD}"
rlRun "git status"
if [ -z "${SWITCH_TMT_TESTS_BRANCH}" ]; then
    rlLogInfo "No branch provided using SWITCH_TMT_TESTS_BRANCH variable, using autodetection"
    VERSION=$(rpm -q --qf "%{VERSION}" redhat-release)
    MAJOR=$( echo $VERSION | cut -d '.' -f 1 )
    rlLogInfo "VERSION=$VERSION"
    rlLogInfo "MAJOR=$MAJOR"
    rlRun -s "git branch -r"
    # try hardcoded exceptions first
    [ "$VERSION" == "9.3" ] && SWITCH_TMT_TESTS_BRANCH=rhel-9.5.0
    [ "$VERSION" == "9.4" ] && SWITCH_TMT_TESTS_BRANCH=rhel-9.5.0
    # otherwise try release specific branch
    [ -z "$SWITCH_TMT_TESTS_BRANCH" ] && SWITCH_TMT_TESTS_BRANCH=$( grep -m 1 "origin/rhel-${VERSION}" "$rlRun_LOG" )
    # otherwise try rhel-$MAJOR-main branch
    [ -z "$SWITCH_TMT_TESTS_BRANCH" ] && SWITCH_TMT_TESTS_BRANCH=$( grep -m 1 "origin/rhel-${MAJOR}-main" "$rlRun_LOG" )
fi
if [ -n "$SWITCH_TMT_TESTS_BRANCH" ]; then
    rlLogInfo "Switching to autodetected branch: $SWITCH_TMT_TESTS_BRANCH"
    rlRun "git checkout ${SWITCH_TMT_TESTS_BRANCH}"
else
    rlLogInfo "No matching branch detected, keeping the current branch."
fi
rlRun "git status"
