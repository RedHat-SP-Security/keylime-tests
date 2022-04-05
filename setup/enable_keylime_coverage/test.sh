#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Install coverage script its dependencies"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'pip3 install coverage==5.5'
        rlRun "touch $__INTERNAL_limeCoverageDir/enabled"
    rlPhaseEnd

    rlPhaseStartTest "Check if the coverage script is installed"
        rlRun "coverage --help"
    rlPhaseEnd

    rlPhaseStartSetup "Modify keylime systemd unit files"
        id keylime && rlRun "chown -R keylime /var/tmp/limeLib && chmod -R g+w /var/tmp/limeLib"
        for F in agent verifier registrar; do
            rlRun "mkdir -p /etc/systemd/system/keylime_${F}.service.d"
            rlRun "cat > /etc/systemd/system/keylime_${F}.service.d/10-coverage.conf <<_EOF
[Service]
# set variable containing name of the currently running test
EnvironmentFile=/etc/systemd/limeLib.context
# we need to change WorkingDirectory since .coverage* files will be stored there
WorkingDirectory=/var/tmp/limeLib/coverage
ExecStart=
ExecStart=/usr/local/bin/coverage run /usr/local/bin/keylime_${F}
_EOF"
        done
	rlRun "systemctl daemon-reload"
    rlPhaseEnd

rlJournalEnd
