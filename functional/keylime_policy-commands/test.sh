#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

BASE_POLICY="base_policy.json"
ALLOW_LIST="allowlist.txt"
EXCLUDE_LIST="excludelist.txt"
IMA_LOG="ima_log.txt"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "certgen/certgen"' || rlDie "cannot import openssl/certgen library"
        rlAssertRpm keylime
        rlAssertRpm openssl
        limeBackupConfig
        # Make sure keylime_policy is installed
        rlRun 'which keylime_policy'
        rlRun "TMPDIR=\$(mktemp -d)"
        # Copy files
        rlRun "cp ${ALLOW_LIST} ${TMPDIR}"
        rlRun "cp ${EXCLUDE_LIST} ${TMPDIR}"
        rlRun "cp ${IMA_LOG} ${TMPDIR}"
        rlRun "cp ${BASE_POLICY} ${TMPDIR}"
        rlRun "cp -r rootfs ${TMPDIR}"
        rlRun "pushd ${TMPDIR}"
        # Prepare rpm repo
        rlRun "mkdir rpm"
        rlRun "mkdir boot"
        rlRun "limeCopyKeylimeFile --source test/data/create-runtime-policy/setup-rpm-tests"
        rlRun "limeCopyKeylimeFile --source test/data/create-runtime-policy/setup-initrd-tests"
        rlRun "chmod +x setup-rpm-tests"
        rlRun "chmod +x setup-initrd-tests"
        rlRun "./setup-rpm-tests ${TMPDIR}/rpm"
        rlRun "./setup-initrd-tests ${TMPDIR}/boot"
        # Generate keypair
        rlRun "x509KeyGen ca" 0 "Generating Root CA key pair"
        rlRun "x509SelfSign ca" 0 "Selfsigning Root CA certificate"
        rlRun "x509KeyGen cert" 0 "Generating test RSA key pair for certificate"
        rlRun "x509KeyGen der" 0 "Generating test RSA key pair for DER test"
        rlRun "x509KeyGen pem" 0 "Generating test RSA key pair for PEM test"
        rlRun "x509CertSign --CA ca --DN 'CN = Test' -t webserver cert" 0 "Signing test certificate with CA key"
    rlPhaseEnd

    rlPhaseStartTest "Test printing help with --help/-h"
        rlRun "keylime_policy -h"
        rlRun "keylime_policy --help"
        rlRun "keylime_policy create -h"
        rlRun "keylime_policy create --help"
        rlRun "keylime_policy create runtime -h"
        rlRun "keylime_policy create runtime --help"
    rlPhaseEnd

    # Generate runtime policy from filesystem

    rlPhaseStartTest "Include the IMA log with --use-ima-measurement-list"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --use-ima-measurement-list | jq '.digests'"
        rlRun "keylime_policy create runtime --use-ima-measurement-list -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "boot_aggregate" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test creating a policy by extending a base policy with --base-policy"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --use-ima-measurement-list --base-policy ${BASE_POLICY} | jq '.digests.test'"
        rlRun "keylime_policy create runtime --use-ima-measurement-list --base-policy ${BASE_POLICY} -o policy.json"
        rlRun -s "jq '.digests.test' policy.json"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test creating a policy by converting an allowlist with --allowlist"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --allowlist ${ALLOW_LIST} | jq '.digests.test'"
        rlRun "keylime_policy create runtime --allowlist ${ALLOW_LIST} -o policy.json"
        rlRun -s "jq '.digests.test' policy.json"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test creating a policy by converting an exclude list with --exclude-list"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --exclude-list ${EXCLUDE_LIST} | jq '.excludes'"
        rlRun "keylime_policy create runtime --exclude-list ${EXCLUDE_LIST} -o policy.json"
        rlRun -s "jq '.excludes' policy.json"
        rlAssertGrep "test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Set IMA log file with --use-ima-measurement-list -m IMA_MEASUREMENT_LIST"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --use-ima-measurement-list -m ${IMA_LOG} | jq '.digests'"
        rlRun "keylime_policy create runtime --use-ima-measurement-list -m ${IMA_LOG} -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Output legacy format with --show-legacy-allowlist"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --show-legacy-allowlist --allowlist ${ALLOW_LIST}"
        rlRun -s "keylime_policy create runtime --show-legacy-allowlist --allowlist ${ALLOW_LIST}"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2  test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Add signature verification key with --add-ima-signature-verification-key"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime -A $(x509Cert cert) -A $(x509Key pem) -A $(x509Key --der der) | jq '.\"verification-keys\"'"
        rlAssertExists "$(x509Cert cert)"
        rlAssertExists "$(x509Key pem)"
        rlAssertExists "$(x509Key --der der)"
        rlRun "keylime_policy create runtime -A $(x509Cert cert) -A $(x509Key pem) -A $(x509Key --der der) -o policy.json"
        rlRun -s "jq '.\"verification-keys\"' policy.json"
        for key in cert pem der; do
            rlRun "PUBKEY=$(openssl pkey -in "$(x509Key "${key}")" -pubout | sed 's/----.*//g' | tr -d '\n')"
            rlRun "[ -n \"${PUBKEY}\" ]"
            rlAssertGrep "${PUBKEY}" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Include files from a rootfs using --rootfs ROOTFS"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --rootfs rootfs | jq '.digests'"
        rlRun "keylime_policy create runtime --rootfs rootfs -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "test" "$rlRun_LOG"
        rlAssertGrep "nested/nested" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test setting hash algorithm with --algo ALGORITHM"
        for algo in sha1 sha256 sha384 sha512; do
            rlRun "${algo}sum rootfs/test | awk '{print \$1}' > test.${algo}"
            rlRun "${algo}sum rootfs/nested/nested | awk '{print \$1}' > nested.${algo}"
            rlRun -s "keylime_policy create runtime --rootfs rootfs --algo ${algo}"
            rlAssertGrep "$(cat test.${algo})" "$rlRun_LOG"
            rlAssertGrep "$(cat nested.${algo})" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Include files from initrd ramdisks with --ramdisk-dir RAMDISK_DIR"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --ramdisk-dir \"boot/initrd\" | jq '.digests'"
        rlRun "keylime_policy create runtime --ramdisk-dir \"boot/initrd\" -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "18eb0ba043d6fc5b06b6f785b4a411fa0d6d695c4a08d2497e8b07c4043048f7" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Include ima-buf entries with --ima-buf"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --ima-buf --use-ima-measurement-list -m \"${IMA_LOG}\" | jq '.ima-buf'"
        rlRun -s "keylime_policy create runtime --ima-buf --use-ima-measurement-list -m \"${IMA_LOG}\""
        rlAssertGrep "571016c9f57363c80e08dd4346391c4e70227e41b0247b8a3aa2240a178d3d14" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Get keyrings from IMA measurement list with --keyrings"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --use-ima-measurement-list -m \"${IMA_LOG}\" --keyrings | jq '.keyrings'"
        rlRun "keylime_policy create runtime --use-ima-measurement-list -m \"${IMA_LOG}\" --keyrings -o policy.json"
        rlRun -s "jq '.keyrings' policy.json"
        rlAssertGrep "\.ima" "$rlRun_LOG"
        rlAssertGrep "a7d52aaa18c23d2d9bb2abb4308c0eeee67387a42259f4a6b1a42257065f3d5a" "$rlRun_LOG"
        rlAssertGrep "\.test" "$rlRun_LOG"
        rlAssertGrep "68b0115a1ccce90691f62df3053bd6601ad258e02ee6b5cee07f2a19144f253f" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Ignore keyrings from IMA measurement list with --ignored-keyrings"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime_policy create runtime --use-ima-measurement-list -m \"${IMA_LOG}\" --keyrings | jq '.keyrings'"
        rlRun "keylime_policy create runtime --use-ima-measurement-list -m \"${IMA_LOG}\" --keyrings --ignored-keyrings \".ima\" -o policy.json"
        rlRun -s "jq '.ima.ignored_keyrings' policy.json"
        rlAssertGrep "\.ima" "$rlRun_LOG"
        rlRun -s "jq '.keyrings' policy.json"
        rlAssertGrep "\.test" "$rlRun_LOG"
        rlAssertGrep "68b0115a1ccce90691f62df3053bd6601ad258e02ee6b5cee07f2a19144f253f" "$rlRun_LOG"
        rlAssertNotGrep "\.ima" "$rlRun_LOG"
        rlAssertNotGrep "a7d52aaa18c23d2d9bb2abb4308c0eeee67387a42259f4a6b1a42257065f3d5a" "$rlRun_LOG"
    rlPhaseEnd

    # Generate runtime policy from RPM repository

    rlPhaseStartTest "Generate runtime policy from local RPM repo with --local-rpm-repo REPO"
        for repo in signed-rsa signed-ecc; do
            # TODO: Currently, the output is not parseable as JSON directly with a pipe.
            # Possibly related to https://github.com/keylime/keylime/issues/1613
            # rlRun -s "keylime_policy create runtime --local-rpm-repo \"rpm/repo/${repo}\" | jq '.digests.\"/etc/dummy-foobar.conf\"'"
            rlRun "keylime_policy create runtime --local-rpm-repo \"rpm/repo/${repo}\" -o policy.json"
            rlRun -s "jq '.digests.\"/etc/dummy-foobar.conf\"' policy.json"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Generate runtime policy from remote RPM repo with --remote-rpm-repo REPO"
        for repo in signed-rsa signed-ecc; do
            rlRun "python3 -m http.server -b 127.0.0.1 -d \"rpm/repo/${repo}\" 8080 &"
            SERVER_PID=$!
            rlRun "keylime_policy create runtime --remote-rpm-repo http://localhost:8080"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
            rlRun "kill ${SERVER_PID}"
        done
    rlPhaseEnd

    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "rm -rf ${TMPDIR}"
    rlPhaseEnd

rlJournalEnd
