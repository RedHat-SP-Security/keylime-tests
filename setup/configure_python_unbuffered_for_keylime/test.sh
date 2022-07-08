#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
        # for more info see
        # https://unix.stackexchange.com/questions/505146/getting-systemd-service-logs-faster-from-my-service
        for SERVICE in verifier registrar agent; do
            rlRun "mkdir -p /etc/systemd/system/keylime_${SERVICE}.service.d/"
            rlRun "cat > /etc/systemd/system/keylime_${SERVICE}.service.d/30-unbuffer.conf <<_EOF
[Service]
Environment=\"PYTHONUNBUFFERED=1\"
_EOF"
        done
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

rlJournalEnd
