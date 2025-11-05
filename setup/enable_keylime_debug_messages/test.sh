#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "limeUpdateConf logger_root level DEBUG"
        rlRun "limeUpdateConf logger_keylime level DEBUG"
        rlRun "limeUpdateConf handler_consoleHandler level DEBUG"
        for AGENT in keylime_agent keylime_push_model_agent; do
            rlRun "mkdir -p /etc/systemd/system/${AGENT}.service.d"
	    rlRun "cat > /etc/systemd/system/${AGENT}.service.d/20-rust_log_trace.conf <<_EOF
[Service]
Environment=\"RUST_LOG=keylime_agent=trace,keylime=trace\"
_EOF"
        done
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

rlJournalEnd
