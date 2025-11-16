#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun "limeUpdateConf logger_root level INFO"
        rlRun "limeUpdateConf logger_keylime level INFO"
        rlRun "limeUpdateConf handler_consoleHandler level INFO"
        for AGENT in keylime_agent keylime_push_model_agent; do
            _f="/etc/systemd/system/${AGENT}.service.d/20-rust_log_trace.conf"
            [ -e "${_f}" ] && rm -f "${_f}"
        done
        rlRun "systemctl daemon-reload"
    rlPhaseEnd

rlJournalEnd
