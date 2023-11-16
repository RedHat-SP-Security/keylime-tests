# Test failure troubleshooting guide

This should help you to troubleshoot keylime failures more efficiently by providing hints on how to read test logs more efficiently.
Still, log reading alone may not be sufficient to successfully troubleshoot the issue so it is highly recommended to read also [TESTING.md](TESTING.md)
and learn how to schedule keylime tests using the `tmt` tool.

## First steps

### Asking for help

Do not afraid to ask for help on #keylime Slack channel on cloud-native.slack.com.

### Searching for service logs

When a test fails, keylime service logs are typically printed during the CleanUp phase of the test when services are being stopped. 

Another option to access service logs (but also other test related logs) is to click on the "log_dir" link at the end of the test and from there navigate to "data" directory.

### Enable logging of DEBUG messages

To speed up testing and improve test stability we have disabled logging on a DEBUG level. Due to that you may be missing some useful messages. To enable DEBUG logging you can modify the respective `tmt` test plan in your PR (keylime project plan is stored in the `packit_ci.fmf` file ) and include a new test /setup/enable_keylime_debug_messages right between tasks installing keylime bits and the first `/functional` test.

### Checking if the failure is new

You may check other recently opened and closed keylime PRs to find out whether the failure is present there. If so, it is likely that the issue has been already discussed in comments.

### Checking test log for the first failure

When investigating a test failure in a test log provided by Testing Farm the quickest way how to search for errors is to search for "[   FAIL   ]" string using your browser and also for preceding lines containing string " ERROR ". These FAIL and ERRORs should either point out to the root cause or at least present how the root cause manifests itself in the test scenario. Once you know this error you may find additional related hints in the text below.

### Looking for a package update causing a regression

Keylime tests are typically run using the upstream keylime code on multiple Fedora releases. Despite having the same keylime version, these releases differ in other packages installed on a test system. If you spot an unknown test failure on a single Fedora release (typically Rawhide) it is very likely that the failure is caused by a package update. If you are able to reproduce the issue on your test system (e.g. virtual one) you can check which packages have been updated recently.

To list packages installed on the system sorted by the build date (the most recent ones last) run:
```
$ rpm -qa --qf '%{BUILDTIME} %{NVR}\n' | sort -n
```
Then check wheter "usual suspects" are near the end of the list. These are: tpm2-tools, tpm2-tss, edk2-ovmf, swtpm, coreutils, kernel,

Also, you can check for specific package builds directly in [Koji](https://koji.fedoraproject.org/koji/search).

## Agent registration failures

TBD

## Agent startup failures

TBD

## Measured boot related test scenarios

### keylime.tenant - ERROR - Failed key derivation for Agent

This is most likely caused by some updated update (tpm2-tools, tpm2-tss, edk2-ovmf). Check the verifier log for details, typically there is a agent status message with more details. For example:
```
keylime_verifier[76390]: 2023-11-15 12:39:16.726 - keylime.measured_boot - ERROR - Boot attestation failed for agent d432fbb3-d2f1-4a97-9ef7-75bd81c00000,
policy example, refstate={"has_secureboot": true, ....
... 'EventSize': 8, 'Event': {'String': 'MokList\x00'}} [Event String is not 'MokList', Event String is not 'MokListX', Event String is not 'MokListTrusted']
```
which points out the actual problem.

### libefivar.so.1: cannot open shared object file: No such file or directory

Here the efivar-libs package has been accidentally uninstalled. We believe that the issue has been addressed with [PR#515](https://github.com/RedHat-SP-Security/keylime-tests/pull/515) but if you were doing some system setup manually it is possible that the package is missing.
