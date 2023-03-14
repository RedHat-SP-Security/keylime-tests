#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlAssertRpm keylime
    rlPhaseEnd

    rlPhaseStartTest "test1: No input"
        rlRun "keylime_create_policy -m /dev/null -o $TESTDIR/test1-output1.json"
        rlRun "diff $TESTDIR/test1-output1.json test1/output1.json"
    rlPhaseEnd

    rlPhaseStartTest "test2: Measurement log with ima-sig entries and merge-in various ima-buf entries ima-buf"
        rlRun "keylime_create_policy -m test2/ascii_runtime_measurements-1 -o $TESTDIR/test2-output1.json"
        rlRun "diff $TESTDIR/test2-output1.json test2/output1.json"
        # without --ima-buf the ima-buf entries won't get merged
        rlRun "keylime_create_policy -B $TESTDIR/test2-output1.json -m test2/ascii_runtime_measurements-2 -o $TESTDIR/test2-output2.json"
        rlRun "diff $TESTDIR/test2-output2.json test2/output1.json"
        # with --ima-buf entries get merged
        rlRun "keylime_create_policy -B $TESTDIR/test2-output1.json -m test2/ascii_runtime_measurements-2 --ima-buf -o $TESTDIR/test2-output3.json"
        rlRun "diff <(jq < $TESTDIR/test2-output3.json) test2/output3.json"
        # with --ima-buf entries get merged and -i enables ignoring given keyrings
        rlRun "keylime_create_policy -B $TESTDIR/test2-output1.json -m test2/ascii_runtime_measurements-2 -i .builtin_trusted_keys --ima-buf -o $TESTDIR/test2-output4.json"
        rlRun "diff <(jq < $TESTDIR/test2-output4.json) test2/output4.json"
        # with --keyrings entries get merged and -i enables ignoring given keyrings
        rlRun "keylime_create_policy -B $TESTDIR/test2-output1.json -m test2/ascii_runtime_measurements-2 -i .builtin_trusted_keys --keyrings -o $TESTDIR/test2-output5.json"
        rlRun "diff <(jq < $TESTDIR/test2-output5.json) test2/output5.json"
        # with --keyrings entries get merged and -i enables ignoring given keyrings and --ima-buf creates ima-buf enetires
        rlRun "keylime_create_policy -B $TESTDIR/test2-output1.json -m test2/ascii_runtime_measurements-2 -i .builtin_trusted_keys --keyrings --ima-buf -o $TESTDIR/test2-output6.json"
        rlRun "diff <(jq < $TESTDIR/test2-output6.json) test2/output6.json"
    rlPhaseEnd

    rlPhaseStartTest "test3: Add exclude list file contents and signature verification keys and ignore a few keyrings"
        rlRun "keylime_create_policy -m test3/ascii_runtime_measurements-1 -e test3/exclude-list-1 -o $TESTDIR/test3-output1.json"
        rlRun "diff <(jq < $TESTDIR/test3-output1.json) test3/output1.json"
        # -i adds keyrings to ignore
        rlRun "keylime_create_policy -B $TESTDIR/test3-output1.json -m /dev/null -i .builtin_trusted_keys -i test123 -o $TESTDIR/test3-output2.json"
        rlRun "diff <(jq < $TESTDIR/test3-output2.json) test3/output2.json"
        # -A to add an IMA signature verification key;
        rlRun "keylime_create_policy -B $TESTDIR/test3-output2.json -m /dev/null -A test3/eckey-ecdsa.pem -o $TESTDIR/test3-output3.json"
        rlRun "diff <(jq < $TESTDIR/test3-output3.json) test3/output3.json"
    rlPhaseEnd

    rlPhaseStartTest "test4: Use an allowlist as input"
        rlRun "keylime_create_policy -m /dev/null -a test4/allowlist-1 -o $TESTDIR/test4-output1.json"
        rlRun "diff $TESTDIR/test4-output1.json test4/output1.json"
    rlPhaseEnd

rlJournalEnd
