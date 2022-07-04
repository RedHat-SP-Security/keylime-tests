#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        if [ "${REVOCATION_NOTIFIER}" == "zeromq" ]; then
            rlRun "yum -y install python3-zmq"
        fi
        rlRun "limeUpdateConf cloud_verifier revocation_notifiers ${REVOCATION_NOTIFIER}"
        rlRun "cat > /etc/profile.d/export_REVOCATION_NOTIFIER.sh <<_EOF
export REVOCATION_NOTIFIER=${REVOCATION_NOTIFIER}
_EOF"
    rlPhaseEnd

rlJournalEnd
