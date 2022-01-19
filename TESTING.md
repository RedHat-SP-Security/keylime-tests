## Running tests on a local test system

The following distributions are supported and tested via Packit CI.
 * Stable Fedora distributions (Fedora-34, Fedora-35)
 * Fedora Rawhide
 * CentOS Stream 9 / RHEL-9

### Using tmt (Test Metadata Tool)

Install [`tmt`](https://tmt.readthedocs.io/en/latest/overview.html) and clone tests repository

```
# yum -y install tmt
# git clone https://github.com/RedHat-SP-Security/keylime-tests.git
# cd keylime-tests
```

With `tmt` you can easily run all test plans. Currently, there is one
test plan in the `plans/keylime-tests-github-ci` file.
You may want to update it to run only the required tasks.

```
# tmt run -vvv prepare discover provision -h local execute
```

### Manual test execution

For troubleshooting purposes you may want to run particular test
manually. Remember that some setup tasks needs to be run on
a test system before tests.

Prior running a test make sure that all package requires
listed in `main.fmf` file are installed.

```
# cd ../../functional/basic-attestation-on-localhost/
# ## make sure to install all requires from main.fmf
# bash test.sh
```

## Running tests in a virtual system using tmt

`tmt` itself can start a virtual system for test execution, in fact it is the default behavior.
Below we will describe a basic use case. For advanced scenarios please visit [`tmt` documentation](https://tmt.readthedocs.io/en/latest/overview.html).

First you need to install `tmt` tool and clone tests repository.

```
# yum -y install tmt tmt-provision-virtual
# git clone https://github.com/RedHat-SP-Security/keylime-tests.git
```

Then you can run a test plan e.g. on F35 system.

```
# cd keylime-tests
# tmt run -vvv prepare discover provision -h virtual -i Fedora-35 execute finish
```

The above command will dispose the system when tests are finished.
However for debugging purposes you may want to access test system once
tests are finished. The command below will give you a shell after all tests are finished.

```
# cd keylime-tests
# tmt run -vvv prepare discover provision -h virtual -i Fedora-35 execute login finish
```

You can use it to inspect test logs or even modify test sources and run your tests
manually following the method described above. For this purpose you can find test sources under `/var/tmp/tmt/run-*/packit-ci/discover/default/tests/`.

## Running CI tests from the upstream keylime project

Clone the upstream keylime bits (and change the branch if needed).

```
# git clone https://github.com/keylime/keylime.git
```

Test plan for functional CI tests is stored in `packit.yaml`.
You may want to edit the file e.g. to point to a different
tests repository and branch by modifying the section listed below.

```
discover:
    how: fmf
    url: https://github.com/RedHat-SP-Security/keylime-tests
    ref: main
```

Then you can run tests using the `tmt` tool as described in the section above.
