#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

BASE_POLICY="base_policy.json"
ALLOW_LIST="allowlist.txt"
EXCLUDE_LIST="excludelist.txt"
IMA_LOG="ima_log.txt"
MB_LOG="mb_log.bin"
MB_LOG_SECUREBOOT="mb_log_secureboot.bin"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "certgen/certgen"' || rlDie "cannot import openssl/certgen library"
        rlAssertRpm keylime
        rlAssertRpm openssl
        limeBackupConfig
        # Make sure keylime-policy is installed
        rlRun 'which keylime-policy'
        rlRun "TMPDIR=\$(mktemp -d)"
        # Copy files
        rlRun "cp ${ALLOW_LIST} ${TMPDIR}"
        rlRun "cp ${EXCLUDE_LIST} ${TMPDIR}"
        rlRun "cp ${IMA_LOG} ${TMPDIR}"
        rlRun "cp ${BASE_POLICY} ${TMPDIR}"
        rlRun "cp ${MB_LOG} ${TMPDIR}"
        rlRun "cp ${MB_LOG_SECUREBOOT} ${TMPDIR}"
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
        rlRun "keylime-policy -h"
        rlRun "keylime-policy --help"
        rlRun "keylime-policy create -h"
        rlRun "keylime-policy create --help"
        rlRun "keylime-policy create runtime -h"
        rlRun "keylime-policy create runtime --help"
        rlRun "keylime-policy create measured-boot -h"
        rlRun "keylime-policy create measured-boot --help"
        rlRun "keylime-policy sign -h"
        rlRun "keylime-policy sign --help"
        rlRun "keylime-policy sign runtime -h"
        rlRun "keylime-policy sign runtime --help"
    rlPhaseEnd

    # Generate runtime policy from filesystem

    rlPhaseStartTest "Include the IMA log with --ima-measurement-list"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --ima-measurement-list | jq '.digests'"
        rlRun "keylime-policy create runtime --ima-measurement-list -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "boot_aggregate" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test creating a policy by extending a base policy with --base-policy"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --ima-measurement-list --base-policy ${BASE_POLICY} | jq '.digests.test'"
        rlRun "keylime-policy create runtime --ima-measurement-list --base-policy ${BASE_POLICY} -o policy.json"
        rlRun -s "jq '.digests.test' policy.json"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test creating a policy by converting an allowlist with --allowlist"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --allowlist ${ALLOW_LIST} | jq '.digests.test'"
        rlRun "keylime-policy create runtime --allowlist ${ALLOW_LIST} -o policy.json"
        rlRun -s "jq '.digests.test' policy.json"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test creating a policy by converting an exclude list with --excludelist"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --excludelist ${EXCLUDE_LIST} | jq '.excludes'"
        rlRun "keylime-policy create runtime --excludelist ${EXCLUDE_LIST} -o policy.json"
        rlRun -s "jq '.excludes' policy.json"
        rlAssertGrep "test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Set IMA log file with -m IMA_MEASUREMENT_LIST"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime -m ${IMA_LOG} | jq '.digests'"
        rlRun "keylime-policy create runtime -m ${IMA_LOG} -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Output legacy format with --show-legacy-allowlist"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --show-legacy-allowlist --allowlist ${ALLOW_LIST}"
        rlRun -s "keylime-policy create runtime --show-legacy-allowlist --allowlist ${ALLOW_LIST}"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2  test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Add signature verification key with --add-ima-signature-verification-key"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --add-ima-signature-verification-key $(x509Cert cert) --add-ima-signature-verification-key $(x509Key pem) --add-ima-signature-verification-key $(x509Key --der der) | jq '.\"verification-keys\"'"
        rlAssertExists "$(x509Cert cert)"
        rlAssertExists "$(x509Key pem)"
        rlAssertExists "$(x509Key --der der)"
        rlRun "keylime-policy create runtime --add-ima-signature-verification-key $(x509Cert cert) --add-ima-signature-verification-key $(x509Key pem) --add-ima-signature-verification-key $(x509Key --der der) -o policy.json"
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
        # rlRun -s "keylime-policy create runtime --rootfs rootfs | jq '.digests'"
        rlRun "keylime-policy create runtime --rootfs rootfs -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "test" "$rlRun_LOG"
        rlAssertGrep "nested/nested" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Test setting hash algorithm with --algo ALGORITHM"
        for algo in sha1 sha256 sha384 sha512; do
            rlRun "${algo}sum rootfs/test | awk '{print \$1}' > test.${algo}"
            rlRun "${algo}sum rootfs/nested/nested | awk '{print \$1}' > nested.${algo}"
            rlRun -s "keylime-policy create runtime --rootfs rootfs --algo ${algo}"
            rlAssertGrep "$(cat test.${algo})" "$rlRun_LOG"
            rlAssertGrep "$(cat nested.${algo})" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Include files from initrd ramdisks with --ramdisk-dir RAMDISK_DIR"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --ramdisk-dir \"boot/initrd\" | jq '.digests'"
        rlRun "keylime-policy create runtime --ramdisk-dir \"boot/initrd\" -o policy.json"
        rlRun -s "jq '.digests' policy.json"
        rlAssertGrep "18eb0ba043d6fc5b06b6f785b4a411fa0d6d695c4a08d2497e8b07c4043048f7" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Include ima-buf entries with --ima-buf"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime --ima-buf -m \"${IMA_LOG}\" | jq '.ima-buf'"
        rlRun -s "keylime-policy create runtime --ima-buf -m \"${IMA_LOG}\""
        rlAssertGrep "571016c9f57363c80e08dd4346391c4e70227e41b0247b8a3aa2240a178d3d14" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Get keyrings from IMA measurement list with --keyrings"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime -m \"${IMA_LOG}\" --keyrings | jq '.keyrings'"
        rlRun "keylime-policy create runtime -m \"${IMA_LOG}\" --keyrings -o policy.json"
        rlRun -s "jq '.keyrings' policy.json"
        rlAssertGrep "\.ima" "$rlRun_LOG"
        rlAssertGrep "a7d52aaa18c23d2d9bb2abb4308c0eeee67387a42259f4a6b1a42257065f3d5a" "$rlRun_LOG"
        rlAssertGrep "\.test" "$rlRun_LOG"
        rlAssertGrep "68b0115a1ccce90691f62df3053bd6601ad258e02ee6b5cee07f2a19144f253f" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "Get keyrings from IMA measurement list on a default location"
        # to test https://issues.redhat.com/browse/RHEL-130158
        rlRun "keylime-policy create runtime  --ima-measurement-list --keyrings -o policy.json"
        rlRun -s "jq '.keyrings' policy.json"
        # accept {} eventually since the default measurement list may not contain keyrings
        rlAssertGrep "(\.ima|\{\})" "$rlRun_LOG" -E
        rlAssertNotGrep Traceback "$rlRun_LOG" -i
    rlPhaseEnd

    rlPhaseStartTest "Ignore keyrings from IMA measurement list with --ignored-keyrings"
        # TODO: Currently, the output is not parseable as JSON directly with a pipe.
        # Possibly related to https://github.com/keylime/keylime/issues/1613
        # rlRun -s "keylime-policy create runtime -m \"${IMA_LOG}\" --keyrings | jq '.keyrings'"
        rlRun "keylime-policy create runtime -m \"${IMA_LOG}\" --keyrings --ignored-keyrings \".ima\" -o policy.json"
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
            # rlRun -s "keylime-policy create runtime --local-rpm-repo \"rpm/repo/${repo}\" | jq '.digests.\"/etc/dummy-foobar.conf\"'"
            rlRun "keylime-policy create runtime --local-rpm-repo \"rpm/repo/${repo}\" -o policy.json"
            rlRun -s "jq '.digests.\"/etc/dummy-foobar.conf\"' policy.json"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "Generate runtime policy from remote RPM repo with --remote-rpm-repo REPO"
        for repo in signed-rsa signed-ecc; do
            rlRun "python3 -m http.server -b 127.0.0.1 -d \"rpm/repo/${repo}\" 8080 &> server.log &"
            SERVER_PID=$!
            rlRun -s "keylime-policy create runtime --remote-rpm-repo http://localhost:8080"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
            # check that individual RPMs are downloaded
            rlAssertGrep "filelist-ext.xml not present in the repo" "$rlRun_LOG"
            rlRun "kill ${SERVER_PID}"
            cat server.log
            rlAssertGrep "GET /DUMMY-foo" server.log
            rlAssertGrep "GET /DUMMY-bar" server.log
            rlAssertGrep "GET /DUMMY-empty" server.log
        done
    rlPhaseEnd

    if [ -d rpm/repo/filelist-ext-match ]; then
        rlPhaseStartTest "Generate runtime policy from remote RPM repo containing filelist-ext.xml"
            rlRun "python3 -m http.server -b 127.0.0.1 -d \"rpm/repo/filelist-ext-match\" 8080 &> server.log &"
            SERVER_PID=$!
            rlRun -s "keylime-policy create runtime --remote-rpm-repo http://localhost:8080"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
            # check that filelist-ext was downloaded
            rlRun "kill ${SERVER_PID}"
            cat server.log
            rlAssertGrep "GET /repodata/.*filelists-ext.xml.gz" server.log -E
        rlPhaseEnd
    fi

    # Sign runtime policies.

    rlPhaseStartTest "Sign runtime policy with the ECDSA DSSE backend"
        rlRun "mkdir -p sign-ecdsa"
        rlRun "pushd sign-ecdsa"
            rlRun "keylime-policy create runtime -m ../\"${IMA_LOG}\" -o test-policy.json" 0 "Create a policy to use for the signing tests"
            rlAssertExists test-policy.json

            # Specifying a bad input policy to be signed.
            rlRun "echo foobar > bad-policy"
            rlRun "keylime-policy sign runtime -b ecdsa -r bad-policy -o signed-ecdsa-bad.json" 1
            rlAssertNotExists signed-ecdsa-bad.json

            # Specifying a non-existing policy to be signed.
            rlRun "keylime-policy sign runtime -b ecdsa -r NON-EXISTING -o signed-ecdsa-non-existing.json" 1
            rlAssertNotExists signed-ecdsa-non-existing.json

            # Not specifying a key, so it will create one with default name keylime-ecdsa-key.pem.
            rlRun "keylime-policy sign runtime -b ecdsa -r test-policy.json -o signed-ecdsa-01.json"
            rlAssertExists signed-ecdsa-01.json
            rlAssertExists keylime-ecdsa-key.pem
            # Check the policy was signed by the keylime-ecdsa-key.pem key.
            rlRun "limeVerifyRuntimePolicySignature signed-ecdsa-01.json keylime-ecdsa-key.pem"

            # Specifying a non existing key.
            rlRun "keylime-policy sign runtime -b ecdsa -k NON-EXISTING -r test-policy.json -o signed-ecdsa-02.json" 1 "Attempting to use non-existing key"
            rlAssertNotExists signed-ecdsa-02.json

            # Specifying a key path for the key to be created, since we are
            # not providng one. We first make sure it does not yet exist.
            rlAssertNotExists new-key.pem
            rlRun "keylime-policy sign runtime -b ecdsa -p new-key.pem -r test-policy.json -o signed-ecdsa-03.json"
            rlAssertExists signed-ecdsa-03.json
            rlAssertExists new-key.pem
            # Check the policy was signed by the new-key.pem.
            rlRun "limeVerifyRuntimePolicySignature signed-ecdsa-03.json new-key.pem"

            # Attempt to use RSA key.
            rlRun "openssl genrsa -out rsa2048-privkey.pem 2048" 0 "Creating RSA private key (2048)"
            rlRun "keylime-policy sign runtime -b ecdsa -k rsa2048-privkey.pem -r test-policy.json -o signed-ecdsa-04.json" 1 "Attempting to use RSA key"
            rlAssertNotExists signed-ecdsa-04.json

            # Now let's use an EC key.
            rlRun "openssl ecparam -out prime256v1-privkey.pem -name prime256v1 -genkey" 0 "Create EC private key (prime256v1)"
            rlRun "keylime-policy sign runtime -b ecdsa -k prime256v1-privkey.pem -r test-policy.json -o signed-ecdsa-05.json"
            rlAssertExists signed-ecdsa-05.json
            # Check the policy was signed by the proper key.
            rlRun "limeVerifyRuntimePolicySignature signed-ecdsa-05.json prime256v1-privkey.pem"

            # Finally, let's try to use some dummy data as a key.
            rlRun "echo foobar > dummy.key"
            rlRun "keylime-policy sign runtime -b ecdsa -k dummy.pem -r test-policy.json -o signed-ecdsa-06.json" 1 "Attempting to use bad input file as key"
            rlAssertNotExists signed-ecdsa-06.json
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "Sign runtime policy with the X509 DSSE backend"
        rlRun "mkdir -p sign-x509"
        rlRun "pushd sign-x509"
            rlRun "keylime-policy create runtime -m ../\"${IMA_LOG}\" -o test-policy.json" 0 "Create a policy to use for the signing tests"
            rlAssertExists test-policy.json

            # Specifying a bad input policy to be signed.
            rlRun "echo foobar > bad-policy"
            rlRun "keylime-policy sign runtime -b x509 -c x509-bad-policy -r bad-policy -o signed-x509-bad.json" 1
            rlAssertNotExists signed-x509-bad.json

            # Specifying a non-existing policy to be signed.
            rlRun "keylime-policy sign runtime -b x509 -c x509-non-existing -r NON-EXISTING -o signed-x509-non-existing.json" 1
            rlAssertNotExists signed-x509-non-existing.json

            # Not specifying a certificate output file, so it should fail.
            rlRun "keylime-policy sign runtime -b x509 -r test-policy.json -o signed-x509-01.json" 1 "Not specyfing output certificate file"
            rlAssertNotExists signed-x509-01.json

            # Not specifying a key, so it will create one with default name keylime-ecdsa-key.pem.
            rlRun "keylime-policy sign runtime -b x509 -c x509-02 -r test-policy.json -o signed-x509-02.json"
            rlAssertExists signed-x509-02.json
            rlAssertExists keylime-ecdsa-key.pem
            rlAssertExists x509-02
            rlRun "limeVerifyRuntimePolicySignature signed-x509-02.json keylime-ecdsa-key.pem"
            rlRun "limeVerifyRuntimePolicySignature signed-x509-02.json x509-02"

            # Specifying a non existing key.
            rlRun "keylime-policy sign runtime -b x509 -c x509-03 -k NON-EXISTING -r test-policy.json -o signed-x509-03.json" 1 "Attempting to use non-existing key"
            rlAssertNotExists signed-x509-03.json
            rlAssertNotExists x509-03

            # Attempt to use RSA key.
            rlRun "openssl genrsa -out rsa2048-privkey.pem 2048" 0 "Creating RSA private key (2048)"
            rlRun "keylime-policy sign runtime -b x509 -c x509-04 -k rsa2048-privkey.pem -r test-policy.json -o signed-x509-04.json" 1 "Attempting to use RSA key"
            rlAssertNotExists signed-x509-04.json
            rlAssertNotExists x509-04

            # Now let's use an EC key.
            rlRun "openssl ecparam -out prime256v1-privkey.pem -name prime256v1 -genkey" 0 "Create EC private key (prime256v1)"
            rlRun "keylime-policy sign runtime -b x509 -c x509-05 -k prime256v1-privkey.pem -r test-policy.json -o signed-x509-05.json"
            rlAssertExists signed-x509-05.json
            rlAssertExists x509-05
            # Check the policy was signed by both the key ands the cert.
            rlRun "limeVerifyRuntimePolicySignature signed-x509-05.json prime256v1-privkey.pem"
            rlRun "limeVerifyRuntimePolicySignature signed-x509-05.json x509-05"

            # Finally, let's try to use some dummy data as a key.
            rlRun "echo foobar > dummy.key"
            rlRun "keylime-policy sign runtime -b x509 -c x509-06 -k dummy.pem -r test-policy.json -o signed-x509-06.json" 1 "Attempting to use bad input file as key"
            rlAssertNotExists signed-x509-06.json
            rlAssertNotExists x509-06
        rlRun "popd"
    rlPhaseEnd

  # efivar not available on s390x and ppc64le
  ARCH=$( rlGetPrimaryArch )
  if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
    rlPhaseStartTest "Create measured boot policy"
        rlRun "mkdir -p measured-boot"
        rlRun "pushd measured-boot"
            rlRun "keylime-policy create measured-boot -e \"../${MB_LOG_SECUREBOOT}\" -o mb-policy.json" 0 "Create a measured-boot policy"
            rlRun -s "jq '.has_secureboot' mb-policy.json"
            rlAssertGrep "true" "$rlRun_LOG"
            rlRun -s "jq '.kernels' mb-policy.json"
            rlAssertGrep "0xb7aa67ab83a8ebe76393e0cf8ba25f9e7b5dc734740cf87e68640f391c207732" "$rlRun_LOG"
            rlAssertGrep "0xb7aa67ab83a8ebe76393e0cf8ba25f9e7b5dc734740cf87e68640f391c207732" "$rlRun_LOG"

            rlRun "keylime-policy create measured-boot -e \"../${MB_LOG}\" -i -o mb-policy.json" 0 "Create a measured-boot without secure boot"
            rlRun -s "jq '.has_secureboot' mb-policy.json"
            rlAssertGrep "false" "$rlRun_LOG"
            rlRun -s "jq '.kernels' mb-policy.json"
            rlAssertGrep "0x5f5457bd9d68d9e1c6443c16b6c416be9531f3bca4754a30f5cfdf8038ce01a2" "$rlRun_LOG"

            rlRun "keylime-policy create measured-boot -e \"../${MB_LOG_SECUREBOOT}\" -i -o mb-policy.json" 0 "Create a measured-boot with flag to ignore secure boot"
            # Check that the flag is ignored because the event log has secure
            # boot enabled
            rlRun -s "jq '.has_secureboot' mb-policy.json"
            rlAssertGrep "true" "$rlRun_LOG"
        rlRun "popd"
    rlPhaseEnd
  fi

    rlPhaseStartCleanup
        rlRun "popd"
        rlRun "rm -rf ${TMPDIR}"
    rlPhaseEnd

rlJournalEnd
