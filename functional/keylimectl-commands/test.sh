#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test data files (shared with keylime-policy-commands)
POLICY_COMMANDS_DIR="../keylime-policy-commands"
BASE_POLICY="base_policy.json"
ALLOW_LIST="allowlist.txt"
EXCLUDE_LIST="excludelist.txt"
IMA_LOG="ima_log.txt"
MB_LOG="mb_log.bin"
MB_LOG_SECUREBOOT="mb_log_secureboot.bin"

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

[ -n "${AGENT_SERVICE}" ] || AGENT_SERVICE="Agent"
[ "${AGENT_SERVICE}" == "PushAgent" ] && PUSH_MODEL_FLAG="--push-model" || PUSH_MODEL_FLAG=""

rlJournalStart

    rlPhaseStartSetup "Environment setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlRun 'rlImport "certgen/certgen"' || rlDie "cannot import openssl/certgen library"
        [ "${AGENT_SERVICE}" != "Agent" ] && [ "${AGENT_SERVICE}" != "PushAgent" ] && rlDie "Error: AGENT_SERVICE must be 'Agent' or 'PushAgent', got '${AGENT_SERVICE}'"
        rlAssertRpm keylime
        rlAssertRpm openssl
        rlRun "which keylimectl" 0 "keylimectl must be installed" || rlDie "keylimectl not found"
        limeBackupConfig
        rlFileBackup /etc/keylime/keylimectl.conf
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Prepare working directory with test data
        rlRun "TMPDIR=\$(mktemp -d)"
        rlRun "cp ${POLICY_COMMANDS_DIR}/${ALLOW_LIST} ${TMPDIR}"
        rlRun "cp ${POLICY_COMMANDS_DIR}/${EXCLUDE_LIST} ${TMPDIR}"
        rlRun "cp ${POLICY_COMMANDS_DIR}/${IMA_LOG} ${TMPDIR}"
        rlRun "cp ${POLICY_COMMANDS_DIR}/${BASE_POLICY} ${TMPDIR}"
        rlRun "cp ${POLICY_COMMANDS_DIR}/${MB_LOG} ${TMPDIR}"
        rlRun "cp ${POLICY_COMMANDS_DIR}/${MB_LOG_SECUREBOOT} ${TMPDIR}"
        rlRun "cp -r ${POLICY_COMMANDS_DIR}/rootfs ${TMPDIR}"
        rlRun "pushd ${TMPDIR}"

        # Prepare rpm repo and initrd test data
        rlRun "mkdir rpm"
        rlRun "mkdir boot"
        rlRun "limeCopyKeylimeFile --source test/data/create-runtime-policy/setup-rpm-tests"
        rlRun "limeCopyKeylimeFile --source test/data/create-runtime-policy/setup-initrd-tests"
        rlRun "chmod +x setup-rpm-tests"
        rlRun "chmod +x setup-initrd-tests"
        rlRun "./setup-rpm-tests ${TMPDIR}/rpm"
        rlRun "./setup-initrd-tests ${TMPDIR}/boot"

        # Generate keypair for signing tests
        rlRun "x509KeyGen ca" 0 "Generating Root CA key pair"
        rlRun "x509SelfSign ca" 0 "Selfsigning Root CA certificate"
        rlRun "x509KeyGen cert" 0 "Generating test RSA key pair for certificate"
        rlRun "x509KeyGen der" 0 "Generating test RSA key pair for DER test"
        rlRun "x509KeyGen pem" 0 "Generating test RSA key pair for PEM test"
        rlRun "x509CertSign --CA ca --DN 'CN = Test' -t webserver cert" 0 "Signing test certificate with CA key"
    rlPhaseEnd

    # ── Help flags ──────────────────────────────────────

    rlPhaseStartTest "Test printing help with --help/-h"
        rlRun "keylimectl -h"
        rlRun "keylimectl --help"
        rlRun "keylimectl agent -h"
        rlRun "keylimectl agent --help"
        rlRun "keylimectl agent add -h"
        rlRun "keylimectl agent add --help"
        rlRun "keylimectl agent remove -h"
        rlRun "keylimectl agent remove --help"
        rlRun "keylimectl agent update -h"
        rlRun "keylimectl agent update --help"
        rlRun "keylimectl agent status -h"
        rlRun "keylimectl agent status --help"
        rlRun "keylimectl agent list -h"
        rlRun "keylimectl agent list --help"
        rlRun "keylimectl agent reactivate -h"
        rlRun "keylimectl agent reactivate --help"
        rlRun "keylimectl policy -h"
        rlRun "keylimectl policy --help"
        rlRun "keylimectl policy push -h"
        rlRun "keylimectl policy push --help"
        rlRun "keylimectl policy show -h"
        rlRun "keylimectl policy show --help"
        rlRun "keylimectl policy list -h"
        rlRun "keylimectl policy list --help"
        rlRun "keylimectl policy update -h"
        rlRun "keylimectl policy update --help"
        rlRun "keylimectl policy delete -h"
        rlRun "keylimectl policy delete --help"
        rlRun "keylimectl policy generate -h"
        rlRun "keylimectl policy generate --help"
        rlRun "keylimectl policy generate runtime -h"
        rlRun "keylimectl policy generate runtime --help"
        rlRun "keylimectl policy generate measured-boot -h"
        rlRun "keylimectl policy generate measured-boot --help"
        rlRun "keylimectl policy sign -h"
        rlRun "keylimectl policy sign --help"
        rlRun "keylimectl policy verify-signature -h"
        rlRun "keylimectl policy verify-signature --help"
        rlRun "keylimectl policy validate -h"
        rlRun "keylimectl policy validate --help"
        rlRun "keylimectl measured-boot -h"
        rlRun "keylimectl measured-boot --help"
        rlRun "keylimectl measured-boot push -h"
        rlRun "keylimectl measured-boot push --help"
        rlRun "keylimectl measured-boot show -h"
        rlRun "keylimectl measured-boot show --help"
        rlRun "keylimectl measured-boot list -h"
        rlRun "keylimectl measured-boot list --help"
        rlRun "keylimectl measured-boot update -h"
        rlRun "keylimectl measured-boot update --help"
        rlRun "keylimectl measured-boot delete -h"
        rlRun "keylimectl measured-boot delete --help"
        rlRun "keylimectl info -h"
        rlRun "keylimectl info --help"
        rlRun "keylimectl configure -h"
        rlRun "keylimectl configure --help"
    rlPhaseEnd

    # ── Policy generation (local, no services needed) ───

    rlPhaseStartTest "policy generate runtime from IMA measurement list"
        rlRun "keylimectl policy generate runtime --ima-measurement-list -o policy-ima.json"
        rlRun -s "jq '.digests' policy-ima.json"
        rlAssertGrep "boot_aggregate" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime from IMA log file with -m"
        rlRun "keylimectl policy generate runtime -m ${IMA_LOG} -o policy-imalog.json"
        rlRun -s "jq '.digests' policy-imalog.json"
        rlAssertGrep "test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --base-policy"
        rlRun "keylimectl policy generate runtime --ima-measurement-list --base-policy ${BASE_POLICY} -o policy-base.json"
        rlRun -s "jq '.digests.test' policy-base.json"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime from allowlist with --allowlist"
        rlRun "keylimectl policy generate runtime --allowlist ${ALLOW_LIST} -o policy-al.json"
        rlRun -s "jq '.digests.test' policy-al.json"
        rlAssertGrep "f2ca1bb6c7e907d06dafe4687e579fce76b37e4e93b7605022da52e6ccc26fd2" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --excludelist"
        rlRun "keylimectl policy generate runtime --excludelist ${EXCLUDE_LIST} -o policy-excl.json"
        rlRun -s "jq '.excludes' policy-excl.json"
        rlAssertGrep "test" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime from rootfs with --rootfs"
        rlRun "keylimectl policy generate runtime --rootfs rootfs -o policy-rootfs.json"
        rlRun -s "jq '.digests' policy-rootfs.json"
        rlAssertGrep "test" "$rlRun_LOG"
        rlAssertGrep "nested/nested" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --hash-alg"
        for algo in sha1 sha256 sha384 sha512; do
            rlRun "${algo}sum rootfs/test | awk '{print \$1}' > test.${algo}"
            rlRun "${algo}sum rootfs/nested/nested | awk '{print \$1}' > nested.${algo}"
            rlRun -s "keylimectl policy generate runtime --rootfs rootfs --hash-alg ${algo}"
            rlAssertGrep "$(cat test.${algo})" "$rlRun_LOG"
            rlAssertGrep "$(cat nested.${algo})" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --ramdisk-dir"
        rlRun "keylimectl policy generate runtime --ramdisk-dir \"boot/initrd\" -o policy-ramdisk.json"
        rlRun -s "jq '.digests' policy-ramdisk.json"
        rlAssertGrep "18eb0ba043d6fc5b06b6f785b4a411fa0d6d695c4a08d2497e8b07c4043048f7" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --ima-buf"
        rlRun -s "keylimectl policy generate runtime --ima-buf -m \"${IMA_LOG}\""
        rlAssertGrep "571016c9f57363c80e08dd4346391c4e70227e41b0247b8a3aa2240a178d3d14" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --keyrings"
        rlRun "keylimectl policy generate runtime -m \"${IMA_LOG}\" --keyrings -o policy-keyrings.json"
        rlRun -s "jq '.keyrings' policy-keyrings.json"
        rlAssertGrep "\.ima" "$rlRun_LOG"
        rlAssertGrep "a7d52aaa18c23d2d9bb2abb4308c0eeee67387a42259f4a6b1a42257065f3d5a" "$rlRun_LOG"
        rlAssertGrep "\.test" "$rlRun_LOG"
        rlAssertGrep "68b0115a1ccce90691f62df3053bd6601ad258e02ee6b5cee07f2a19144f253f" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime from default IMA measurement list with --keyrings"
        rlRun "keylimectl policy generate runtime --ima-measurement-list --keyrings -o policy-keyrings-default.json"
        rlRun -s "jq '.keyrings' policy-keyrings-default.json"
        rlAssertGrep "(\.ima|\{\})" "$rlRun_LOG" -E
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --ignored-keyrings"
        rlRun "keylimectl policy generate runtime -m \"${IMA_LOG}\" --keyrings --ignored-keyrings \".ima\" -o policy-ignored-kr.json"
        rlRun -s "jq '.ima.ignored_keyrings' policy-ignored-kr.json"
        rlAssertGrep "\.ima" "$rlRun_LOG"
        rlRun -s "jq '.keyrings' policy-ignored-kr.json"
        rlAssertGrep "\.test" "$rlRun_LOG"
        rlAssertGrep "68b0115a1ccce90691f62df3053bd6601ad258e02ee6b5cee07f2a19144f253f" "$rlRun_LOG"
        rlAssertNotGrep "\.ima" "$rlRun_LOG"
        rlAssertNotGrep "a7d52aaa18c23d2d9bb2abb4308c0eeee67387a42259f4a6b1a42257065f3d5a" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime with --add-ima-signature-verification-key"
        rlRun "mkdir -p sigkeys-test"
        rlRun "pushd sigkeys-test"
            # Generate a key pair and certificate for verification key tests
            rlRun "openssl ecparam -out privkey.pem -name prime256v1 -genkey" 0 "Create EC private key (PEM)"
            rlRun "openssl pkcs8 -topk8 -nocrypt -in privkey.pem -outform DER -out privkey.der" 0 "Convert private key to DER"
            rlRun "openssl pkey -in privkey.pem -pubout -out pubkey.pem" 0 "Extract public key (PEM)"
            rlRun "openssl pkey -in privkey.pem -pubout -outform DER -out pubkey.der" 0 "Extract public key (DER)"
            rlRun "openssl req -new -x509 -key privkey.pem -out cert.pem -days 1 -subj '/CN=IMA Verify'" 0 "Create self-signed certificate (PEM)"
            rlRun "openssl x509 -in cert.pem -outform DER -out cert.der" 0 "Convert certificate to DER"

            # Derive the expected public key content for verification
            rlRun "EXPECTED_PUBKEY=\$(openssl pkey -in privkey.pem -pubout | sed 's/----.*//g' | tr -d '\n')"
            rlRun "[ -n \"${EXPECTED_PUBKEY}\" ]"

            # Test each format individually
            for input in cert.pem cert.der pubkey.pem pubkey.der privkey.pem privkey.der; do
                OUTNAME="${input//\./-}"
                rlRun "keylimectl policy generate runtime --add-ima-signature-verification-key ${input} -o policy-sigkey-${OUTNAME}.json" 0 "Verification key from ${input}"
                rlRun -s "jq '.\"verification-keys\"' policy-sigkey-${OUTNAME}.json"
                rlAssertGrep "${EXPECTED_PUBKEY}" "$rlRun_LOG"
            done

            # Test all formats combined in a single invocation
            rlRun "keylimectl policy generate runtime --add-ima-signature-verification-key cert.pem --add-ima-signature-verification-key cert.der --add-ima-signature-verification-key pubkey.pem --add-ima-signature-verification-key pubkey.der --add-ima-signature-verification-key privkey.pem --add-ima-signature-verification-key privkey.der -o policy-sigkeys-all.json" 0 "All verification key formats combined"
            rlAssertExists policy-sigkeys-all.json
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime from local RPM repo with --local-rpm-repo"
        for repo in signed-rsa signed-ecc; do
            rlRun "keylimectl policy generate runtime --local-rpm-repo \"rpm/repo/${repo}\" -o policy-rpm-local.json"
            rlRun -s "jq '.digests.\"/etc/dummy-foobar.conf\"' policy-rpm-local.json"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
        done
    rlPhaseEnd

    rlPhaseStartTest "policy generate runtime from remote RPM repo with --remote-rpm-repo"
        HTTP_PORT=8080
        for repo in signed-rsa signed-ecc; do
            rlRun "python3 -m http.server -b 127.0.0.1 -d \"rpm/repo/${repo}\" ${HTTP_PORT} &> server.log &"
            SERVER_PID=$!
            rlRun "rlWaitForSocket ${HTTP_PORT} -t 5"
            rlRun -s "keylimectl policy generate runtime --remote-rpm-repo http://localhost:${HTTP_PORT}"
            rlAssertGrep "fcde2b2edba56bf408601fb721fe9b5c338d10ee429ea04fae5511b68fbf8fb9" "$rlRun_LOG"
            rlRun "kill ${SERVER_PID}" 0 "Stop HTTP server"
            rlRun "rlWaitForSocket ${HTTP_PORT} -t 5 --close"
            cat server.log
            HTTP_PORT=$(( HTTP_PORT + 1 ))
        done
    rlPhaseEnd

    # ── Policy signing ──────────────────────────────────

    rlPhaseStartTest "policy sign with ECDSA DSSE backend"
        rlRun "mkdir -p sign-ecdsa"
        rlRun "pushd sign-ecdsa"
            rlRun "keylimectl policy generate runtime -m ../\"${IMA_LOG}\" -o test-policy.json" 0 "Create a policy for signing tests"
            rlAssertExists test-policy.json

            # Bad input policy
            rlRun "echo foobar > bad-policy"
            rlRun "keylimectl policy sign bad-policy -b ecdsa -o signed-ecdsa-bad.json" 1
            rlAssertNotExists signed-ecdsa-bad.json

            # Non-existing policy
            rlRun "keylimectl policy sign NON-EXISTING -b ecdsa -o signed-ecdsa-non-existing.json" 1
            rlAssertNotExists signed-ecdsa-non-existing.json

            # No key specified: generates one with default name
            rlRun "keylimectl policy sign test-policy.json -b ecdsa -o signed-ecdsa-01.json"
            rlAssertExists signed-ecdsa-01.json
            rlRun "limeVerifyRuntimePolicySignature signed-ecdsa-01.json keylime-ecdsa-key.pem"

            # Non-existing key
            rlRun "keylimectl policy sign test-policy.json -b ecdsa -k NON-EXISTING -o signed-ecdsa-02.json" 1 "Attempting to use non-existing key"
            rlAssertNotExists signed-ecdsa-02.json

            # Specifying key path for generated key
            rlAssertNotExists new-key.pem
            rlRun "keylimectl policy sign test-policy.json -b ecdsa -p new-key.pem -o signed-ecdsa-03.json"
            rlAssertExists signed-ecdsa-03.json
            rlAssertExists new-key.pem
            rlRun "limeVerifyRuntimePolicySignature signed-ecdsa-03.json new-key.pem"

            # Attempt to use RSA key
            rlRun "openssl genrsa -out rsa2048-privkey.pem 2048" 0 "Creating RSA private key (2048)"
            rlRun "keylimectl policy sign test-policy.json -b ecdsa -k rsa2048-privkey.pem -o signed-ecdsa-04.json" 1 "Attempting to use RSA key"
            rlAssertNotExists signed-ecdsa-04.json

            # Use an EC key
            rlRun "openssl ecparam -out prime256v1-privkey.pem -name prime256v1 -genkey" 0 "Create EC private key (prime256v1)"
            rlRun "keylimectl policy sign test-policy.json -b ecdsa -k prime256v1-privkey.pem -o signed-ecdsa-05.json"
            rlAssertExists signed-ecdsa-05.json
            rlRun "limeVerifyRuntimePolicySignature signed-ecdsa-05.json prime256v1-privkey.pem"

            # Dummy data as key
            rlRun "echo foobar > dummy.key"
            rlRun "keylimectl policy sign test-policy.json -b ecdsa -k dummy.key -o signed-ecdsa-06.json" 1 "Attempting to use bad input file as key"
            rlAssertNotExists signed-ecdsa-06.json
        rlRun "popd"
    rlPhaseEnd

    rlPhaseStartTest "policy sign with X509 DSSE backend"
        rlRun "mkdir -p sign-x509"
        rlRun "pushd sign-x509"
            rlRun "keylimectl policy generate runtime -m ../\"${IMA_LOG}\" -o test-policy.json" 0 "Create a policy for signing tests"
            rlAssertExists test-policy.json

            # Bad input policy
            rlRun "echo foobar > bad-policy"
            rlRun "keylimectl policy sign bad-policy -b x509 -c x509-bad-policy -o signed-x509-bad.json" 1
            rlAssertNotExists signed-x509-bad.json

            # Non-existing policy
            rlRun "keylimectl policy sign NON-EXISTING -b x509 -c x509-non-existing -o signed-x509-non-existing.json" 1
            rlAssertNotExists signed-x509-non-existing.json

            # Not specifying certificate output file: keylimectl auto-generates it
            rlRun "keylimectl policy sign test-policy.json -b x509 -o signed-x509-01.json" 0 "Not specifying output certificate file"
            rlAssertExists signed-x509-01.json

            # No key specified: generates one with default name
            rlRun "keylimectl policy sign test-policy.json -b x509 -c x509-02 -o signed-x509-02.json"
            rlAssertExists signed-x509-02.json
            rlAssertExists keylime-ecdsa-key.pem
            rlAssertExists x509-02
            rlRun "limeVerifyRuntimePolicySignature signed-x509-02.json keylime-ecdsa-key.pem"
            rlRun "limeVerifyRuntimePolicySignature signed-x509-02.json x509-02"

            # Non-existing key
            rlRun "keylimectl policy sign test-policy.json -b x509 -c x509-03 -k NON-EXISTING -o signed-x509-03.json" 1 "Attempting to use non-existing key"
            rlAssertNotExists signed-x509-03.json
            rlAssertNotExists x509-03

            # Use an RSA key with a matching self-signed certificate
            rlRun "openssl genrsa -out rsa2048-privkey.pem 2048" 0 "Creating RSA private key (2048)"
            rlRun "openssl req -new -x509 -key rsa2048-privkey.pem -out rsa2048-cert.pem -days 1 -subj '/CN=Test'" 0 "Create self-signed certificate for RSA key"
            rlRun "keylimectl policy sign test-policy.json -b x509 -c rsa2048-cert.pem -k rsa2048-privkey.pem -o signed-x509-04.json" 0 "Sign with RSA key"
            rlAssertExists signed-x509-04.json

            # Use an EC key with a matching self-signed certificate
            # When -k is provided, -c is an INPUT certificate (not output)
            rlRun "openssl ecparam -out prime256v1-privkey.pem -name prime256v1 -genkey" 0 "Create EC private key (prime256v1)"
            rlRun "openssl req -new -x509 -key prime256v1-privkey.pem -out prime256v1-cert.pem -days 1 -subj '/CN=Test'" 0 "Create self-signed certificate for EC key"
            rlRun "keylimectl policy sign test-policy.json -b x509 -c prime256v1-cert.pem -k prime256v1-privkey.pem -o signed-x509-05.json"
            rlAssertExists signed-x509-05.json
            rlRun "limeVerifyRuntimePolicySignature signed-x509-05.json prime256v1-privkey.pem"
            rlRun "limeVerifyRuntimePolicySignature signed-x509-05.json prime256v1-cert.pem"

            # Providing -k without -c should fail (cert is required as input when key is given)
            rlRun "keylimectl policy sign test-policy.json -b x509 -k prime256v1-privkey.pem -o signed-x509-05b.json" 1 "Key without certificate"
            rlAssertNotExists signed-x509-05b.json

            # Dummy data as key
            rlRun "echo foobar > dummy.key"
            rlRun "keylimectl policy sign test-policy.json -b x509 -c x509-06 -k dummy.key -o signed-x509-06.json" 1 "Attempting to use bad input file as key"
            rlAssertNotExists signed-x509-06.json
            rlAssertNotExists x509-06
        rlRun "popd"
    rlPhaseEnd

    # ── Measured boot policy generation ─────────────────

  ARCH=$( rlGetPrimaryArch )
  if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
    rlPhaseStartTest "policy generate measured-boot"
        rlRun "mkdir -p measured-boot"
        rlRun "pushd measured-boot"
            rlRun "keylimectl policy generate measured-boot --eventlog-file \"../${MB_LOG_SECUREBOOT}\" -o mb-policy.json" 0 "Create a measured-boot policy"
            rlRun -s "jq '.has_secureboot' mb-policy.json"
            rlAssertGrep "true" "$rlRun_LOG"
            rlRun -s "jq '.kernels' mb-policy.json"
            rlAssertGrep "0xb7aa67ab83a8ebe76393e0cf8ba25f9e7b5dc734740cf87e68640f391c207732" "$rlRun_LOG"

            rlRun "keylimectl policy generate measured-boot --eventlog-file \"../${MB_LOG}\" --without-secureboot -o mb-policy.json" 0 "Create measured-boot without secure boot"
            rlRun -s "jq '.has_secureboot' mb-policy.json"
            rlAssertGrep "false" "$rlRun_LOG"
            rlRun -s "jq '.kernels' mb-policy.json"
            rlAssertGrep "0x5f5457bd9d68d9e1c6443c16b6c416be9531f3bca4754a30f5cfdf8038ce01a2" "$rlRun_LOG"

            # keylimectl honors --without-secureboot even when the event log
            # has secureboot enabled (differs from keylime-policy which ignores it)
            rlRun "keylimectl policy generate measured-boot --eventlog-file \"../${MB_LOG_SECUREBOOT}\" --without-secureboot -o mb-policy.json" 0 "Apply --without-secureboot to event log with secure boot"
            rlRun -s "jq '.has_secureboot' mb-policy.json"
            rlAssertGrep "false" "$rlRun_LOG"
        rlRun "popd"
    rlPhaseEnd
  fi

    # ── Start services for agent and verifier policy tests ─

    rlPhaseStartSetup "Start keylime services"
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeUpdateConf verifier mode 'push'"
            rlRun "limeUpdateConf verifier challenge_lifetime 1800"
            rlRun "limeUpdateConf verifier session_lifetime 180"
        fi
        sleep 5
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStart${AGENT_SERVICE}"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Configure keylimectl to use the auto-generated TLS certificates
        rlRun "cat > /etc/keylime/keylimectl.conf <<_EOF
[verifier]
ip = \"127.0.0.1\"
port = 8881

[registrar]
ip = \"127.0.0.1\"
port = 8891

[tls]
client_cert = \"/var/lib/keylime/cv_ca/client-cert.crt\"
client_key = \"/var/lib/keylime/cv_ca/client-private.pem\"
trusted_ca = [\"/var/lib/keylime/cv_ca/cacert.crt\"]
verify_server_cert = true
enable_agent_mtls = true
accept_invalid_hostnames = true
_EOF"

        # Generate a runtime policy from the current IMA state
        rlRun "keylimectl policy generate runtime --ima-measurement-list -o runtime-policy.json"
    rlPhaseEnd

    # ── Runtime policy CRUD on verifier ─────────────────

    rlPhaseStartTest "policy push"
        rlRun -s "keylimectl policy push testpolicy1 --file runtime-policy.json"
    rlPhaseEnd

    rlPhaseStartTest "policy show"
        rlRun -s "keylimectl policy show testpolicy1"
        rlAssertGrep "testpolicy1" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "policy list"
        rlRun -s "keylimectl policy list"
        rlAssertGrep "testpolicy1" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "policy update"
        rlRun -s "keylimectl policy update testpolicy1 --file runtime-policy.json"
    rlPhaseEnd

    rlPhaseStartTest "policy push duplicate name fails"
        rlRun -s "keylimectl policy push testpolicy1 --file runtime-policy.json" 1
    rlPhaseEnd

    rlPhaseStartTest "policy delete"
        rlRun -s "keylimectl policy delete testpolicy1"
        rlRun "keylimectl policy show testpolicy1" 1
    rlPhaseEnd

    rlPhaseStartTest "policy delete nonexistent fails"
        rlRun -s "keylimectl policy delete nosuchpolicy" 1
    rlPhaseEnd

    # ── MB policy CRUD on verifier ──────────────────────

  if [ "$ARCH" != "s390x" ] && [ "$ARCH" != "ppc64le" ]; then
    rlPhaseStartTest "measured-boot push"
        rlRun "keylimectl policy generate measured-boot --eventlog-file ${MB_LOG_SECUREBOOT} -o mb-verifier-policy.json"
        rlRun -s "keylimectl measured-boot push testmb1 --file mb-verifier-policy.json"
    rlPhaseEnd

    rlPhaseStartTest "measured-boot show"
        rlRun -s "keylimectl measured-boot show testmb1"
        rlAssertGrep "testmb1" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "measured-boot list"
        rlRun -s "keylimectl measured-boot list"
        rlAssertGrep "testmb1" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "measured-boot update"
        rlRun -s "keylimectl measured-boot update testmb1 --file mb-verifier-policy.json"
    rlPhaseEnd

    rlPhaseStartTest "measured-boot delete"
        rlRun -s "keylimectl measured-boot delete testmb1"
        rlRun "keylimectl measured-boot show testmb1" 1
    rlPhaseEnd
  fi

    # ── Agent lifecycle ─────────────────────────────────

    rlPhaseStartTest "agent add"
        rlRun "keylimectl agent add ${AGENT_ID} --runtime-policy runtime-policy.json ${PUSH_MODEL_FLAG}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        else
            rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        fi
    rlPhaseEnd

    rlPhaseStartTest "agent status"
        rlRun -s "keylimectl agent status ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "agent status --verifier"
        rlRun -s "keylimectl agent status ${AGENT_ID} --verifier"
    rlPhaseEnd

    rlPhaseStartTest "agent status --registrar"
        rlRun -s "keylimectl agent status ${AGENT_ID} --registrar"
    rlPhaseEnd

    rlPhaseStartTest "agent list"
        rlRun -s "keylimectl agent list"
        rlAssertGrep "${AGENT_ID}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "agent list --registrar"
        rlRun -s "keylimectl agent list --registrar"
        rlAssertGrep "${AGENT_ID}" $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "agent update"
        rlRun "keylimectl agent update ${AGENT_ID} --runtime-policy runtime-policy.json ${PUSH_MODEL_FLAG}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        else
            rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        fi
    rlPhaseEnd

    rlPhaseStartTest "Fail keylime agent"
        TESTDIR=$(limeCreateTestDir)
        rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/keylime-bad-script.sh && chmod a+x $TESTDIR/keylime-bad-script.sh"
        rlRun "$TESTDIR/keylime-bad-script.sh"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'FAIL'"
        else
            rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"
            rlRun "rlWaitForCmd 'tail -n 30 \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID failed\"' -m 10 -d 1 -t 10"
        fi
        limeExtendNextExcludelist $TESTDIR
    rlPhaseEnd

    rlPhaseStartTest "agent update after failure"
        # Regenerate policy with the bad script now excluded
        rlRun "keylimectl policy generate runtime --ima-measurement-list -o runtime-policy-updated.json"
        rlRun "keylimectl agent update ${AGENT_ID} --runtime-policy runtime-policy-updated.json ${PUSH_MODEL_FLAG}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        else
            rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        fi
    rlPhaseEnd

    rlPhaseStartTest "agent reactivate"
        rlRun -s "keylimectl agent reactivate ${AGENT_ID}"
        if [ "${AGENT_SERVICE}" == "PushAgent" ]; then
            rlRun "limeWaitForAgentStatus --field attestation_status $AGENT_ID 'PASS'"
        else
            rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        fi
    rlPhaseEnd

    rlPhaseStartTest "agent remove"
        rlRun -s "keylimectl agent remove ${AGENT_ID}"
        rlRun -s "keylimectl agent status ${AGENT_ID} --verifier" 0 "Status after removal returns not_found"
        rlAssertGrep "not_found" "$rlRun_LOG"
    rlPhaseEnd

    rlPhaseStartTest "agent add fails due to bad policy"
        rlRun "echo '{}' > bad-policy.json"
        rlRun -s "keylimectl agent add ${AGENT_ID} --runtime-policy bad-policy.json" 1
    rlPhaseEnd

    # ── Cleanup ─────────────────────────────────────────

    rlPhaseStartCleanup "Cleanup"
        rlRun "popd"
        rlRun "rm -rf ${TMPDIR}"
        rlFileRestore /etc/keylime/keylimectl.conf
        rlRun "limeStop${AGENT_SERVICE}"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
    rlPhaseEnd

rlJournalEnd
