#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# shellcheck disable=SC1091,SC2154
. /usr/share/beakerlib/beakerlib.sh || exit 1

# List of manpages to test
MANPAGES="keylime_tenant keylime_verifier keylime_registrar keylime-policy"

rlJournalStart

    rlPhaseStartSetup "Setup for manpages test"
        rlAssertRpm keylime
    rlPhaseEnd

    rlPhaseStartTest "Test if all manpages exist"
        for manpage in $MANPAGES; do
            rlRun "man -w $manpage" 0 "$manpage manpage exists"
        done
    rlPhaseEnd

    rlPhaseStartTest "Test manpages can be displayed"
        for manpage in $MANPAGES; do
            rlRun -s "man $manpage" 0 "Can display $manpage manpage"
            rlAssertGrep "NAME" "$rlRun_LOG" -i
            rlAssertGrep "SYNOPSIS" "$rlRun_LOG" -i
            rlAssertGrep "DESCRIPTION" "$rlRun_LOG" -i
            rlRun "rm -f $rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Test keylime_tenant manpage content"
        rlRun -s "man keylime_tenant"
        rlAssertGrep "OPTIONS" "$rlRun_LOG" -i
        rlAssertGrep "keylime_tenant" "$rlRun_LOG"
        rlAssertGrep "COMMANDS" "$rlRun_LOG" -i
        rlAssertGrep "EXAMPLES" "$rlRun_LOG" -i
        rlAssertGrep "--help" "$rlRun_LOG"
        rlRun "rm -f $rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test keylime_verifier manpage content"
        rlRun -s "man keylime_verifier"
        rlAssertGrep "keylime_verifier" "$rlRun_LOG"
        rlAssertGrep "CONFIGURATION" "$rlRun_LOG" -i
        rlAssertGrep "ENVIRONMENT" "$rlRun_LOG" -i
        rlRun "rm -f $rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test keylime_registrar manpage content"
        rlRun -s "man keylime_registrar"
        rlAssertGrep "keylime_registrar" "$rlRun_LOG"
        rlAssertGrep "CONFIGURATION" "$rlRun_LOG" -i
        rlAssertGrep "ENVIRONMENT" "$rlRun_LOG" -i
        rlRun "rm -f $rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test keylime-policy manpage content"
        rlRun -s "man keylime-policy"
        rlAssertGrep "keylime-policy" "$rlRun_LOG"
        rlAssertGrep "COMMANDS" "$rlRun_LOG" -i
        rlAssertGrep "EXAMPLES" "$rlRun_LOG" -i
        rlAssertGrep "--add-ima-signature-verification-key IMA_SIGNATURE_KEYS" "$rlRun_LOG"
        rlRun "rm -f $rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test manpages formatting and readability"
        for manpage in $MANPAGES; do
            rlRun -s "man $manpage"
            rlRun "! grep -q 'ROFF ERROR' '$rlRun_LOG'" 0 "No ROFF errors in $manpage"
            # WARNING check temporarily disabled due to known issue with pygments availability
            # on CentOS Stream 10 (singlehost). This causes rst2man warnings to be
            # embedded in generated manpage files. Re-enable once pygments dependency is resolved.
            # TODO uncomment
            # rlRun "! grep -q 'WARNING' '$rlRun_LOG'" 0 "No warnings in $manpage"
            rlRun "rm -f $rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Test manpages sections structure"
        for manpage in $MANPAGES; do
            rlRun -s "man $manpage"
            # Verify that NAME comes before SYNOPSIS
            NAME_LINE=$(grep -ni "^NAME" "$rlRun_LOG" | head -1 | cut -d: -f1)
            SYNOPSIS_LINE=$(grep -n "^SYNOPSIS" "$rlRun_LOG" | head -1 | cut -d: -f1)
            rlRun "[ -n \"$NAME_LINE\" ]" 0 "Section NAME must exist in $manpage"
            rlRun "[ -n \"$SYNOPSIS_LINE\" ]" 0 "Section SYNOPSIS must exist in $manpage"
            rlRun "[ $NAME_LINE -lt $SYNOPSIS_LINE ]" 0 "NAME comes before SYNOPSIS in $manpage"
            # Verify that SYNOPSIS comes before DESCRIPTION
            DESCRIPTION_LINE=$(grep -n "^DESCRIPTION" "$rlRun_LOG" | head -1 | cut -d: -f1)
            rlRun "[ -n \"$DESCRIPTION_LINE\" ]" 0 "Section DESCRIPTION must exist in $manpage"
            rlRun "[ $SYNOPSIS_LINE -lt $DESCRIPTION_LINE ]" 0 "SYNOPSIS comes before DESCRIPTION in $manpage"
            rlRun "rm -f $rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartCleanup "Cleanup"
        rlLog "Cleanup completed (no cleanup needed)"
    rlPhaseEnd

rlJournalEnd
