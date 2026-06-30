# Test Development Guide for keylime-tests

This guide provides comprehensive instructions for implementing new tests in the keylime-tests repository. It is designed to help both human developers and AI agents create well-structured, consistent tests.

## Table of Contents

1. [Repository Structure](#repository-structure)
2. [Test Types](#test-types)
3. [Test Framework and Tools](#test-framework-and-tools)
4. [Creating a New Test](#creating-a-new-test)
5. [Test Helper Library](#test-helper-library)
6. [Test Metadata (FMF)](#test-metadata-fmf)
7. [Common Test Patterns](#common-test-patterns)
8. [Setup Tasks](#setup-tasks)
9. [Sanity Tests](#sanity-tests)
10. [Multi-host Tests](#multi-host-tests)
11. [Best Practices](#best-practices)
12. [Testing and Validation](#testing-and-validation)

## Repository Structure

The keylime-tests repository is organized as follows:

```
keylime-tests/
├── functional/          # Single-host functional tests
├── Multihost/          # Multi-host tests
├── setup/              # Setup tasks (prerequisites for tests)
├── regression/         # Regression tests
├── sanity/            # Basic sanity tests
├── compatibility/     # Compatibility tests
├── upstream/          # Upstream test suite integration
├── update/            # Update/upgrade tests
├── container/         # Container-based tests
├── Library/           # Shared libraries
│   ├── test-helpers/  # Main test helper library (lib.sh)
│   └── sync/          # Multi-host synchronization library
├── plans/             # TMT test plans
└── scripts/           # Utility scripts
```

## Test Types

### 1. Functional Tests (`/functional/`)
- Single-host end-to-end tests
- Test specific keylime features and scenarios
- Most common test type
- Include full attestation workflows and feature validation

### 2. Sanity Tests (`/sanity/`)
- Quick smoke tests that verify basic functionality
- Simpler than functional tests with minimal setup
- Focus on basic checks (services start, files exist, configuration is correct)
- Fast execution for rapid validation
- Examples: service startup, manpage availability, file ownership

### 3. Multi-host Tests (`/Multihost/`)
- Tests requiring multiple systems (verifier, registrar, agent)
- Simulate real-world distributed deployments
- Use role-based test functions

### 4. Setup Tasks (`/setup/`)
- Not actual tests but prerequisites
- Configure TPM emulator, IMA, install keylime, etc.
- Can be reused across multiple tests

### 5. Regression Tests (`/regression/`)
- Tests for specific bugs or issues
- Prevent regression of fixed issues

## Test Framework and Tools

### BeakerLib
All tests use the [BeakerLib](https://github.com/beakerlib/beakerlib) framework for test implementation.

**Key BeakerLib Functions:**
- `rlJournalStart` / `rlJournalEnd` - Test journal boundaries
- `rlPhaseStartSetup` / `rlPhaseEnd` - Setup phase
- `rlPhaseStartTest` / `rlPhaseEnd` - Test phase
- `rlPhaseStartCleanup` / `rlPhaseEnd` - Cleanup phase
- `rlRun` - Execute command with logging
- `rlAssertGrep` - Assert pattern in file
- `rlAssertExists` - Assert file exists
- `rlWaitForFile` - Wait for file to appear

### TMT (Test Management Tool)
Tests are executed using [TMT](https://tmt.readthedocs.io/), which provides:
- Test discovery
- Environment preparation
- Test execution
- Result reporting

### FMF (Flexible Metadata Format)
Test metadata is stored in `main.fmf` files using [FMF](https://fmf.readthedocs.io/).

## Creating a New Test

### Step 1: Choose Test Location

Determine where your test should be placed:
- **Single-host functional test**: `/functional/test-name/`
- **Sanity test**: `/sanity/test-name/`
- **Multi-host test**: `/Multihost/test-name/`
- **Regression test**: `/regression/test-name/`
- **Setup task**: `/setup/task-name/`

### Step 2: Create Test Directory

```bash
mkdir -p functional/my-new-test
cd functional/my-new-test
```

### Step 3: Create Test Script (`test.sh`)

Create `test.sh` with the following structure:

```bash
#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Test-specific variables
AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        # Import test-helpers library
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"

        # Verify keylime is installed
        rlAssertRpm keylime

        # Backup configuration
        limeBackupConfig

        # Update configuration
        rlRun "limeUpdateConf tenant require_ek_cert False"

        # Configure TPM emulator if present
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        # Start keylime services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

        # Create test directory and policy
        TESTDIR=`limeCreateTestDir`
        rlRun "limeCreateTestPolicy"
    rlPhaseEnd

    rlPhaseStartTest "Your test logic here"
        # Add agent
        rlRun "keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json -c add"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"

        # Your test steps
        # ...
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        # Stop services
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"

        # Check for errors
        rlAssertNotGrep "Traceback" "$(limeRegistrarLogfile)"
        rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"

        # Stop TPM emulator if used
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi

        # Submit logs and cleanup
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        limeExtendNextExcludelist $TESTDIR
    rlPhaseEnd

rlJournalEnd
```

### Step 4: Create Test Metadata (`main.fmf`)

Create `main.fmf` with test metadata:

```yaml
summary: Brief one-line test description
description: |
    Detailed multi-line description of what the test does.
    Explain the test scenario, steps, and expected outcomes.
contact: Your Name <your.email@example.com>
component:
  - keylime
test: ./test.sh
framework: beakerlib
tag:
  - CI-Tier-1
require:
  - yum
  - expect
recommend:
  - keylime
  - keylime-agent-rust
  - python3-tomli
duration: 5m
enabled: true
id: $(uuidgen)
```

### Step 5: Make Test Executable

```bash
chmod +x test.sh
```

## Test Helper Library

The test-helpers library (`Library/test-helpers/lib.sh`) provides essential functions for keylime testing.

### Key Helper Functions

#### Configuration Management
- `limeBackupConfig` - Backup keylime configuration files
- `limeRestoreConfig` - Restore original configuration
- `limeUpdateConf SECTION OPTION VALUE` - Update configuration options

#### Service Management
- `limeStartVerifier` - Start verifier service
- `limeStopVerifier` - Stop verifier service
- `limeStartRegistrar` - Start registrar service
- `limeStopRegistrar` - Stop registrar service
- `limeStartAgent` - Start agent service
- `limeStopAgent` - Stop agent service

#### Wait Functions
- `limeWaitForVerifier` - Wait for verifier to be ready
- `limeWaitForRegistrar` - Wait for registrar to be ready
- `limeWaitForAgent` - Wait for agent to be ready
- `limeWaitForAgentRegistration AGENT_ID` - Wait for agent registration
- `limeWaitForAgentStatus AGENT_ID STATUS` - Wait for specific agent status

#### TPM Emulator
- `limeTPMEmulated` - Check if TPM emulator is present
- `limeTPMEmulator` - Get TPM emulator name (swtpm or ibmswtpm2)
- `limeStartTPMEmulator` - Start TPM emulator
- `limeStopTPMEmulator` - Stop TPM emulator
- `limeWaitForTPMEmulator` - Wait for TPM emulator to be ready
- `limeCondStartAbrmd` - Conditionally start tpm2-abrmd
- `limeCondStopAbrmd` - Conditionally stop tpm2-abrmd

#### IMA Support
- `limeInstallIMAConfig [POLICY_FILE]` - Install IMA configuration
- `limeInstallIMAKeys` - Generate and install IMA signing keys
- `limeStartIMAEmulator` - Start IMA emulator
- `limeStopIMAEmulator` - Stop IMA emulator
- `limeCreateTestPolicy [FILES...]` - Create IMA policy (allowlist/excludelist)

#### Utility Functions
- `limeCreateTestDir` - Create test directory
- `limeExtendNextExcludelist DIR` - Add directory to next test excludelist
- `limeSubmitCommonLogs` - Submit common log files
- `limeClearData` - Clear keylime data directories
- `limeVerifierLogfile` - Get verifier log file path
- `limeRegistrarLogfile` - Get registrar log file path
- `limeAgentLogfile` - Get agent log file path
- `limeGetRevocationScriptType` - Get revocation script type (script/module)
- `limeIsPythonAgent` - Check if Python agent is being used

#### Important Environment Variables
- `limeTIMEOUT` - Default timeout for operations (default: 20)
- `limeIGNORE_SYSTEMD` - Set to "true" to not use systemd
- `KEYLIME_TEST_DISABLE_REVOCATION` - Disable revocation testing

## Test Metadata (FMF)

### Required Fields

```yaml
summary: Short one-line description
test: ./test.sh
framework: beakerlib
```

### Common Fields

```yaml
description: |
    Multi-line detailed description
contact: Maintainer Name <email@example.com>
component:
  - keylime
tag:
  - CI-Tier-1          # Runs in CI tier 1
  - CI-Tier-1-Multi    # Multi-host CI tier 1
  - multihost          # Multi-host test indicator
require:
  - package-name       # Required packages
  - library(lib/name)  # Required BeakerLib libraries
recommend:
  - keylime            # Recommended packages
  - keylime-agent-rust
duration: 5m           # Expected duration
enabled: true          # Enable/disable test
id: uuid               # Unique test identifier
```

### Environment Variables

Define test-specific environment variables:

```yaml
environment:
    AGENT_SERVICE: Agent
    KEYLIME_TEST_DISABLE_REVOCATION: 1
```

### Adjust Rules

Use `adjust` to conditionally modify test behavior:

```yaml
adjust:
  - when: distro == rhel-8
    enabled: false
    because: RHEL-8 has an old kernel
```

### Test Variants

Create multiple test variants:

```yaml
/variant1:
    environment:
        CRYPTO_ALG: rsa
    id: uuid-1

/variant2:
    environment:
        CRYPTO_ALG: ecdsa
    id: uuid-2
```

## Common Test Patterns

### Pattern 1: Basic Attestation Test

```bash
rlPhaseStartSetup "Setup"
    rlRun 'rlImport "./test-helpers"'
    rlAssertRpm keylime
    limeBackupConfig

    # Configure services
    if limeTPMEmulated; then
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        rlRun "limeCondStartAbrmd"
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"
    fi

    # Start services
    rlRun "limeStartVerifier"
    rlRun "limeWaitForVerifier"
    rlRun "limeStartRegistrar"
    rlRun "limeWaitForRegistrar"
    rlRun "limeStartAgent"
    rlRun "limeWaitForAgentRegistration ${AGENT_ID}"

    # Create policy
    TESTDIR=`limeCreateTestDir`
    rlRun "limeCreateTestPolicy"
rlPhaseEnd
```

### Pattern 2: Testing Attestation Failure

```bash
rlPhaseStartTest "Fail keylime agent"
    # Create a script not in the allowlist
    rlRun "echo -e '#!/bin/bash\necho boom' > $TESTDIR/bad-script.sh && chmod a+x $TESTDIR/bad-script.sh"
    rlRun "$TESTDIR/bad-script.sh"

    # Wait for agent to fail
    rlRun "rlWaitForCmd 'tail \$(limeVerifierLogfile) | grep -q \"Agent $AGENT_ID failed\"' -m 10 -d 1 -t 10"
    rlRun "limeWaitForAgentStatus $AGENT_ID '(Failed|Invalid Quote)'"

    # Check logs
    rlAssertGrep "WARNING - File not found in allowlist: $TESTDIR/bad-script.sh" $(limeVerifierLogfile)
    rlAssertGrep "WARNING - Agent $AGENT_ID failed, stopping polling" $(limeVerifierLogfile)
rlPhaseEnd
```

### Pattern 3: Configuration Updates

```bash
# Update verifier configuration
rlRun "limeUpdateConf revocations enabled_revocation_notifications '[\"agent\",\"webhook\"]'"
rlRun "limeUpdateConf verifier ip 127.0.0.1"

# Update tenant configuration
rlRun "limeUpdateConf tenant require_ek_cert False"

# Update agent configuration
rlRun "limeUpdateConf agent enable_revocation_notifications true"
```

### Pattern 4: Using expect for Interactive Commands

```bash
rlRun "cat > script.expect <<_EOF
set timeout 20
spawn keylime_tenant -v 127.0.0.1 -t 127.0.0.1 -u $AGENT_ID --verify --runtime-policy policy.json -c add
expect \"Please enter the password to decrypt your keystore:\"
send \"keylime\n\"
expect eof
_EOF"
rlRun "expect script.expect"
```

### Pattern 5: Proper Cleanup

```bash
rlPhaseStartCleanup "Cleanup"
    # Stop services in reverse order
    rlRun "limeStopAgent"
    rlRun "limeStopRegistrar"
    rlRun "limeStopVerifier"

    # Check for Python tracebacks (errors)
    rlAssertNotGrep "Traceback" "$(limeRegistrarLogfile)"
    rlAssertNotGrep "Traceback" "$(limeVerifierLogfile)"
    rlAssertNotGrep "Traceback" "$(limeAgentLogfile)"

    # Stop emulators if used
    if limeTPMEmulated; then
        rlRun "limeStopIMAEmulator"
        rlRun "limeStopTPMEmulator"
        rlRun "limeCondStopAbrmd"
    fi

    # Submit logs and restore state
    limeSubmitCommonLogs
    limeClearData
    limeRestoreConfig
    limeExtendNextExcludelist $TESTDIR
rlPhaseEnd
```

## Setup Tasks

Setup tasks are special tests that prepare the environment for actual tests.

### Common Setup Tasks

- `/setup/configure_tpm_emulator` - Install and configure TPM emulator
- `/setup/configure_kernel_ima_module` - Configure kernel IMA module (requires reboot)
- `/setup/install_upstream_keylime` - Install keylime from upstream sources
- `/setup/install_upstream_rust_keylime` - Install rust-keylime from upstream sources
- `/setup/enable_keylime_debug_messages` - Enable debug logging
- `/setup/enable_keylime_coverage` - Enable code coverage

### Creating a Setup Task

Setup tasks follow the same structure as tests but:
1. Focus on system configuration, not validation
2. May require system reboot (use `tmt-reboot`)
3. Should be idempotent when possible

Example with reboot:

```bash
#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

COOKIE=/var/tmp/my-setup-task-rebooted

rlJournalStart
    if [ ! -e $COOKIE ]; then
        rlPhaseStartSetup "pre-reboot phase"
            # Do configuration that requires reboot
            rlRun "grubby --update-kernel DEFAULT --args 'ima_appraise=log'"
            rlRun "touch $COOKIE"
        rlPhaseEnd

        tmt-reboot
    else
        rlPhaseStartTest "post-reboot verification"
            rlRun -s "cat /proc/cmdline"
            rlAssertGrep "ima_appraise=log" $rlRun_LOG
            rlRun "rm $COOKIE"
        rlPhaseEnd
    fi
rlJournalEnd
```

## Sanity Tests

Sanity tests are lightweight smoke tests that verify basic keylime functionality without running full attestation workflows. They are designed to be fast and simple.

### Characteristics of Sanity Tests

1. **Minimal setup**: No backup/restore, minimal configuration
2. **Single phase**: Usually just one test phase (no separate setup/cleanup)
3. **Quick execution**: Typically complete in under 1 minute
4. **Basic validation**: Focus on simple checks like service startup, file existence, configuration correctness
5. **No full attestation**: Don't run complete attestation workflows

### Common Sanity Test Patterns

#### Pattern 1: Service Startup Test

Tests that basic services can start with default configuration:

```bash
#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart
    rlPhaseStartTest
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Start services
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"

        # Stop services
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"

        # Submit logs and cleanup
        limeSubmitCommonLogs
        limeClearData
    rlPhaseEnd
rlJournalEnd
```

#### Pattern 2: Agent Startup Test

Tests that agent can start and contact registrar:

```bash
#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart
    rlPhaseStartTest
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime

        # Start TPM emulator if present
        if limeTPMEmulated; then
            rlRun "limeStartTPMEmulator"
            rlRun "limeWaitForTPMEmulator"
            rlRun "limeCondStartAbrmd"
            rlRun "limeInstallIMAConfig"
            rlRun "limeStartIMAEmulator"
        fi

        # Start agent (expect it to fail without registrar, but check it tries)
        rlRun "limeStartAgent"
        rlRun "rlWaitForCmd 'grep -q \"Requesting registrar API version\" \$(limeAgentLogfile)' -m 30 -d 1 -t 5"

        # Cleanup
        if limeTPMEmulated; then
            rlRun "limeStopIMAEmulator"
            rlRun "limeStopTPMEmulator"
            rlRun "limeCondStopAbrmd"
        fi
        limeSubmitCommonLogs
        limeClearData
    rlPhaseEnd
rlJournalEnd
```

#### Pattern 3: File/Resource Check Test

Tests for file existence, ownership, or other basic properties:

```bash
#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart
    rlPhaseStartTest
        rlAssertRpm keylime

        # Check manpages exist
        rlRun "man keylime_tenant" 0 "keylime_tenant manpage exists"
        rlRun "man keylime_verifier" 0 "keylime_verifier manpage exists"
        rlRun "man keylime_registrar" 0 "keylime_registrar manpage exists"
        rlRun "man keylime-policy" 0 "keylime-policy manpage exists"
    rlPhaseEnd
rlJournalEnd
```

### When to Create a Sanity Test vs Functional Test

**Use a Sanity Test when:**
- Testing basic service startup/shutdown
- Checking file existence or permissions
- Verifying configuration file parsing
- Testing command-line tools respond correctly
- Quick validation of package installation

**Use a Functional Test when:**
- Testing full attestation workflows
- Testing integration between components
- Testing specific features or scenarios
- Requiring custom configuration or policies
- Running end-to-end scenarios

### Sanity Test Metadata

Sanity tests typically have simpler metadata:

```yaml
summary: Brief description of what is being checked
description: |
    More detailed description of the sanity check
contact: Your Name <your.email@example.com>
component:
  - keylime
test: ./test.sh
framework: beakerlib
tag:
  - CI-Tier-1
recommend:
  - keylime
duration: 1m
enabled: true
id: $(uuidgen)
```

### Examples of Sanity Tests

- `/sanity/keylime-service-start/` - Verifier and registrar startup
- `/sanity/agent-service-start/` - Agent startup and registrar contact
- `/sanity/manpages/` - Manpage availability
- `/sanity/opened-conf-files/` - Configuration file handling
- `/sanity/keylime-file-ownership/` - File ownership validation
- `/sanity/keylime-secure_mount/` - Secure mount configuration

## Multi-host Tests

Multi-host tests require special handling for role assignment and synchronization.

### Test Structure

Multi-host tests use role-based functions:

```bash
#!/bin/bash
. /usr/share/beakerlib/beakerlib.sh || exit 1

# Load multihost helper functions
. ../multihost-roles-functions.sh

Verifier() {
    rlPhaseStartSetup "Verifier setup"
        # Verifier-specific setup
    rlPhaseEnd

    rlPhaseStartTest "Verifier test"
        # Verifier-specific tests
    rlPhaseEnd

    rlPhaseStartCleanup "Verifier cleanup"
        # Verifier cleanup
    rlPhaseEnd
}

Registrar() {
    rlPhaseStartSetup "Registrar setup"
        # Registrar-specific setup
    rlPhaseEnd

    rlPhaseStartCleanup "Registrar cleanup"
        # Registrar cleanup
    rlPhaseEnd
}

Agent() {
    rlPhaseStartSetup "Agent setup"
        # Agent-specific setup
    rlPhaseEnd

    rlPhaseStartTest "Agent test"
        # Agent-specific tests
    rlPhaseEnd

    rlPhaseStartCleanup "Agent cleanup"
        # Agent cleanup
    rlPhaseEnd
}

# Common initialization
rlJournalStart
    rlPhaseStartSetup
        rlRun 'rlImport "./test-helpers"'
        rlRun 'rlImport "./sync"'
        rlRun 'rlImport "openssl/certgen"'

        # Assign server roles
        assign_server_roles

        rlLog "VERIFIER: $VERIFIER ${VERIFIER_IP}"
        rlLog "REGISTRAR: $REGISTRAR ${REGISTRAR_IP}"
        rlLog "AGENT: ${AGENT} ${AGENT_IP}"

        # Common setup
        rlAssertRpm keylime
        limeBackupConfig
    rlPhaseEnd

    # Execute role-specific function
    if echo " $HOSTNAME $MY_IP " | grep -q " $VERIFIER "; then
        Verifier
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${REGISTRAR} "; then
        Registrar
    elif echo " $HOSTNAME $MY_IP " | grep -q " ${AGENT} "; then
        Agent
    else
        rlPhaseStartTest
            rlFail "Unknown role"
        rlPhaseEnd
    fi

    rlPhaseStartCleanup
        limeClearData
        limeRestoreConfig
    rlPhaseEnd
rlJournalEnd
```

### Synchronization

Use the sync library for multi-host coordination:

```bash
# Import sync library
rlRun 'rlImport "./sync"'

# Set a synchronization point
rlRun "sync-set VERIFIER_SETUP_DONE"

# Wait for synchronization point
rlRun "sync-block VERIFIER_SETUP_DONE ${VERIFIER_IP}" 0 "Waiting for the Verifier to finish setup"
```

### Multi-host Metadata

```yaml
summary: Multi-host test description
tag:
  - multihost
  - CI-Tier-1-Multi
require:
  - library(openssl/certgen)
  - yum
  - bind-utils
  - expect
  - wget
```

## Best Practices

### 1. Test Naming
- Use descriptive, kebab-case names
- Example: `basic-attestation-with-custom-certificates`

### 2. Always Import test-helpers
```bash
rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
```

### 3. Configuration Management
- Always backup configuration before modifying
- Always restore configuration in cleanup phase
- Use `limeBackupConfig` and `limeRestoreConfig`

### 4. Cleanup Phase
- Always include cleanup phase
- Stop services in reverse order of startup
- Check logs for errors (Traceback)
- Submit logs using `limeSubmitCommonLogs`
- Restore configuration and clear data

### 5. TPM Emulator Detection
```bash
if limeTPMEmulated; then
    # Use TPM emulator
else
    # Use physical TPM
fi
```

### 6. Error Checking
- Use `rlRun` for all commands to log execution
- Check service logs for errors
- Use `rlAssertNotGrep "Traceback"` to catch Python errors

### 7. Timeouts and Waits
- Always use wait functions instead of fixed sleeps
- Use `limeWaitForAgentStatus` instead of `sleep`
- Set appropriate timeouts

### 8. Test Independence
- Tests should be independent and not rely on other tests
- Clean up all test artifacts
- Use `limeExtendNextExcludelist` for IMA policy

### 9. Documentation
- Write clear `summary` and `description` in main.fmf
- Add comments in test.sh for complex logic
- Document test-specific environment variables

### 10. Physical TPM vs Emulator
- Design tests to work with both
- Use `limeTPMEmulated` to detect emulator
- Conditionally start/stop emulator services

## Testing and Validation

### Local Testing

Test your new test locally:

```bash
# Test on local system (not recommended)
cd /path/to/test
sudo bash test.sh

# Test in virtual machine (recommended)
cd keylime-tests
tmt run -vvv plan -n upstream-keylime-tests-github-ci \
    discover -h fmf -t 'configure_tpm_emulator' \
                   -t 'install_upstream_keylime' \
                   -t 'functional/my-new-test' \
    prepare provision -h virtual -i Fedora-39 -c system \
    execute login report finish
```

### Pre-commit Checks

Before submitting:

1. **Verify test.sh is executable**
   ```bash
   chmod +x test.sh
   ```

2. **Validate FMF metadata**
   ```bash
   fmf lint main.fmf
   ```

3. **Check test syntax**
   ```bash
   bash -n test.sh
   ```

4. **Run shellcheck (if available)**
   ```bash
   shellcheck test.sh
   ```

5. **Test execution**
   - Run test in virtual environment
   - Verify all phases complete successfully
   - Check logs are properly submitted

### Submitting Tests

1. Create a pull request
2. Tests will run automatically via Packit CI
3. Address any review comments
4. Wait for approval from reviewers

## AI Agent Guidelines

When implementing tests as an AI agent:

1. **Understand the requirement**: Carefully analyze what feature or scenario needs testing

2. **Study similar tests**: Look at existing tests in the same category

3. **Use helper functions**: Prefer test-helpers functions over custom implementations

4. **Follow patterns**: Use established patterns from existing tests

5. **Include all phases**: Setup, Test, Cleanup

6. **Proper error handling**: Check for failures and log errors

7. **Complete metadata**: Fill all required fields in main.fmf

8. **Test independence**: Ensure test can run standalone

9. **Documentation**: Add clear comments and descriptions

10. **Validation**: Mentally walk through the test execution flow

## Additional Resources

- [BeakerLib Documentation](https://github.com/beakerlib/beakerlib/wiki/man)
- [TMT Documentation](https://tmt.readthedocs.io/)
- [FMF Documentation](https://fmf.readthedocs.io/)
- [keylime-tests TESTING.md](TESTING.md)
- [keylime-tests CONTRIBUTION.md](CONTRIBUTION.md)
- [keylime Documentation](https://keylime.dev/)

## Examples

For reference examples, see:

**Functional Tests:**
- Simple test: `/functional/basic-attestation-on-localhost/`
- Certificate test: `/functional/basic-attestation-with-custom-certificates/`

**Sanity Tests:**
- Service startup: `/sanity/keylime-service-start/`
- Agent startup: `/sanity/agent-service-start/`
- Manpage test: `/sanity/manpages/`
- File checks: `/sanity/keylime-file-ownership/`

**Multi-host Tests:**
- Basic multi-host: `/Multihost/basic-attestation/`

**Setup Tasks:**
- Setup with reboot: `/setup/configure_kernel_ima_module/`
- Setup without reboot: `/setup/configure_tpm_emulator/`

## Getting Help

- Check existing tests for patterns
- Review [TEST_TROUBLESHOOTING.md](TEST_TROUBLESHOOTING.md)
- Ask on keylime project channels
- Submit issues to the repository
