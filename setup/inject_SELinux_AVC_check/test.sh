#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

BEAKERLIB_SCRIPT=/usr/share/beakerlib/logging.sh

rlJournalStart

    rlPhaseStartTest
        rlLogInfo "Injecting the test code into rlPhaseStartTest"
        rlRun "cp $BEAKERLIB_SCRIPT $BEAKERLIB_SCRIPT.pre_injection_backup.$$" 0 "Making backup of $BEAKERLIB_SCRIPT"

        if grep -q "__INTERNAL_TIMESTAMP_AVC" $BEAKERLIB_SCRIPT; then
            rlRun "echo 'AVC check has been already injected into' $BEAKERLIB_SCRIPT"
        else

            # modify rlPhaseStart()
            CODE=$(cat <<_EOF
__INTERNAL_TIMESTAMP_AVC=\`LC_ALL=en_US.UTF-8 date \"+%x %T\"\`; \
export __INTERNAL_TIMESTAMP_AVC;
_EOF
)
            rlRun "sed -i '/rlPhaseStart()/a\ ${CODE}' $BEAKERLIB_SCRIPT"
            grep -A 3 '^rlPhaseStart()' $BEAKERLIB_SCRIPT

            # modify rlPhaseEnd()
            CODE=$(cat <<_EOF
if [[ \${AVC_ERROR} != *"no_avc_check"* ]]; then \
echo ":: Test phase SELinux AVC denials since test phase start:: \${__INTERNAL_TIMESTAMP_AVC}:"; \
ausearch -m AVC -ts \${__INTERNAL_TIMESTAMP_AVC} --input-logs && rlFail "Found SELinux AVC denials within a test phase!"; \
fi
_EOF
)
            rlRun "sed -i '/^rlPhaseEnd()/a\ ${CODE}' $BEAKERLIB_SCRIPT"
            grep -A 5 '^rlPhaseEnd()' $BEAKERLIB_SCRIPT
        fi

        #check status of the SELinux policy
        rlRun "sestatus"
    rlPhaseEnd

rlJournalEnd
