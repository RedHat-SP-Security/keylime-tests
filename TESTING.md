## Running tests on a local test system

The following distributions are supported and tested via Packit CI.
 * Stable Fedora distributions (Fedora-34, Fedora-35)
 * Fedora Rawhide
 * CentOS Stream 9 / RHEL-9

### Using tmt (Test Metadata Tool)

Install [`tmt`](https://tmt.readthedocs.io/en/latest/overview.html) and clone tests repository

```
# yum -y install tmt
$ git clone https://github.com/RedHat-SP-Security/keylime-tests.git
$ cd keylime-tests
```

With `tmt` you can easily run all test plans. Currently, there is one
test plan in the `plans/keylime-tests-github-ci` file.
You may want to update it to run only the required tasks.

```
$ tmt run -vvv prepare discover provision -h local execute
```

### Manual test execution

For troubleshooting purposes you may want to run particular test
manually. Remember that some setup tasks needs to be run on
a test system before tests.

Prior running a test make sure that all test requirements
listed in `main.fmf` file are installed.

```
# cd ../../functional/basic-attestation-on-localhost/
# ## make sure to install all requirements from main.fmf
# bash test.sh
```

## Running tests in a virtual system using tmt

`tmt` itself can start a virtual system for test execution, in fact it is the default behavior.
Below we will describe a basic use case. For advanced scenarios please visit [`tmt` documentation](https://tmt.readthedocs.io/en/latest/overview.html).

The procedure below assumes that you have libvirtd installed and running
(and functional) on your workstation.

First you need to install `tmt` tool and clone tests repository.

```
# yum -y install tmt tmt-provision-virtual
$ git clone https://github.com/RedHat-SP-Security/keylime-tests.git
```

Then you can run a test plan e.g. on F35 system.

```
$ cd keylime-tests
$ tmt run -vvv prepare discover provision -h virtual -i Fedora-35 -c system execute finish
```

The above command will download Fedora-35 image and use it for a newly created virtual
system. Also, due to `finish` command the system will be disposed when tests are executed.
However, for debugging purposes you may want to access test system once
tests are finished. The `tmt login` command used below will give you a shell after all tests are finished.

```
$ cd keylime-tests
$ tmt run -vvv prepare discover provision -h virtual -i Fedora-35 -c system execute login finish
```

You can use it to inspect test logs or even modify test sources and run your tests
manually following the method described above. For this purpose you can find test sources under `/var/tmp/tmt/run-*/packit-ci/discover/default/tests/`.

### Running multi-host tests

`tmt` cannot schedule multi-host tests yet. However, we can use `tmt` to do the necessary setup and then execute the test manually.

For `Multihost/basic-attestation` test we need at least 3 test systems that will be started using `tmt`. Please, make sure your workstation is properly configured as described in the section above.

Let's start with opening 3 terminals on your workstation.

On terminal 1:
```
$ git clone https://github.com/RedHat-SP-Security/keylime-tests.git
```

In the next step we will start 3 virtual systems using `tmt`.

In case you do not have Fedora-35 image already downloaded (in `/var/tmp/tmt/testcloud/images`) you may want to run commands below in the 1st terminal first to avoid simultaneous downloads.

On all terminals:
```
$ cd keylime-tests
$ tmt run -vvv prepare discover -h fmf -t 'configure_tpm_emulator' -t 'install_upstream_keylime' -t 'Multihost/basic-attestation' provision -h virtual -i Fedora-35 -c system execute login finish
```

Multihost test won't be run properly but at least tmt will install all test requirements and do the setup.

Once we have an interactive shell on every test system we can proceed with test execution.
Make sure to change directory using the absolute path provided below as the `tmt login` command will leave you in a different directory.

On every test system:
```
# cd /var/tmp/tmt/run-*/plans/keylime-tests-github-ci/discover/default/tests/Multihost/basic-attestation/
# ## find out hostname or IP of each test system, e.g. with "hostname -i"
# export SERVERS="$IP1 $IP2 $IP3"
# XTRA=1 ./test.sh
```

For the next test iteration make sure to change `XTRA` to a new value on each test system.
This variable is necessary for the proper functioning of a sync mechanism.

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

Then you can run tests using the `tmt` command as described in the section above.
E.g. with
```
$ tmt run -vvv prepare discover provision -h virtual -i Fedora-35 -c system execute finish
```
