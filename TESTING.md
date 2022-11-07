This document describes running tests from the `keylime-tests` repository using the [`tmt`](https://tmt.readthedocs.io/en/latest/overview.html) tool.
It is focused primarily on running tests and testing changes in the `keylime-tests` repository. 
However, the content is relevant also when you want to test changes made in keylime itself. Also, there is a dedicated section [Running CI tests from the upstream keylime project] with more details.

## Running tests on a local test system

The following distributions are supported and tested via Packit CI.
 * Stable Fedora distributions (Fedora-34, Fedora-35)
 * Fedora Rawhide
 * CentOS Stream 9 / RHEL-9

### Using tmt (Test Metadata Tool)

Install `tmt` from default Fedora repositories or EPEL (if using RHEL-9/C9S case).

```
# yum -y install tmt-all
```
or
```
# yum -y install tmt-all --enablerepo=epel
```

Now clone a repository containing `tmt` test plans. Clone `keylime-tests` repository if you 
want to develop tests for that repository. All `tmt` plans are stored in the `plans` directory
and they are being used for CI testing of test updates using the Packit service.

```
$ git clone https://github.com/RedHat-SP-Security/keylime-tests.git
$ cd keylime-tests
```

Before running tests you may want to modify those plans in order to run only the required tests.

To list all the test plans and tests that would be executed you can run:
```
$ tmt -c distro=fedora-35 run -vvv discover
```

To execute all test plans against the local system one would run the following command:
```
$ tmt -c distro=fedora-35 run -vvv prepare discover provision -h local execute
```
However, this way of running tests is not recommended and you should rather use the `provision -h virtual` method to run tests in a virtual system (more on that below).

### Manual test execution

For troubleshooting purposes you may want to run particular test
manually. Remember that some setup tasks needs to be run on
a test system before the test itself.

Prior running a test make sure that all test requirements
listed in `main.fmf` file are installed.

```
# cd ../../functional/basic-attestation-on-localhost/
# ## make sure to install all requirements (`require:` and `recommend:`) from main.fmf
# bash test.sh
```

## Running tests in a virtual system using tmt

`tmt` itself can start a virtual system for test execution, in fact it is the default behavior.
Below we will describe a basic use case. For advanced scenarios please visit [`tmt` documentation](https://tmt.readthedocs.io/en/latest/overview.html).

The procedure below assumes that you have libvirtd installed and running
(and functional) on your workstation.

First you need to install `tmt` tool and clone tests repository.

```
# yum -y install tmt tmt-all
$ git clone https://github.com/RedHat-SP-Security/keylime-tests.git
```

Then you can run all test plans e.g. on F35 system.

```
$ cd keylime-tests
$ tmt -c distro=fedora=35 run -vvv discover prepare provision -h virtual -i Fedora-35 -c system execute report finish
```

The above command will download Fedora-35 image and use it for a newly created virtual
system. Also, due to `finish` command the system will be disposed when tests are executed.
However, for debugging purposes you may want to access test system once
tests are finished. The `login` command used below will give you a shell after all tests are finished.

```
$ cd keylime-tests
$ tmt run -vvv prepare discover provision -h virtual -i Fedora-35 -c system execute login report finish
```

You can use it to inspect test logs or even modify test sources and run your tests
manually following the method described above. For this purpose you can find test sources under `/var/tmp/tmt/run-*/packit-ci/discover/default/tests/`.

### Running tests on CentOS Stream

The above applies also to CentOS Stream, except that one has to define a `--context` so that the distribution
is properly detected and prepare step adjustment enabling EPEL gets run.

```
$ tmt -c distro=centos-stream-9 run -vvv discover prepare provision -h virtual -i centos-stream-9 -c system execute finish
```

## Running tests from a specific test plan or selected tests

In case you do not want to run tests from all plans the easiest option would be to instruct `tmt` to run only specific plan.
```
$ tmt run -vvv plan -n upstream-keylime-tests-github-ci discover prepare provision -h virtual -i Fedora-35 -c system execute report finish
```
Eventually, you can run only specific tests from the plan.
```
$ tmt run -vvv plan -n upstream-keylime-tests-github-ci discover -h fmf -t 'configure_tpm_emulator' -t 'install_upstream_keylime' -t 'functional/basic-attestation' prepare provision -h virtual -i Fedora-35 -c system execute report finish
```
This will run only tests whose names contains provided regexp patterns.

## Running multi-host tests

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

Clone the keylime source code from the upstream project (or your fork) and change the branch if necessary.

```
# git clone https://github.com/keylime/keylime.git
# cd keylime
# git checkout BRANCH
```

Test plans for functional CI tests are stored in `packit-ci.fmf`.
The `discover` section of a test plan instructs `tmt` to run tests from the `keylime-tests` repository.

```
discover:
    how: fmf
    url: https://github.com/RedHat-SP-Security/keylime-tests
    ref: main
```
If your keylime changes would require also changes in `keylime-tests`, you may want to
fork `keylime-tests` repository too and point the plan to your fork by updating the `discover` section.

Check what plans and tests are configured and modify them when necessary.
```
$ tmt -c distro=fedora-35 run -vvv discover
```

Now, you can run tests using the `tmt` command as described in the section above. E.g. using:
```
$ tmt -c distro=fedora-35 run -vvv plan -n e2e-with-revocation discover prepare provision -h virtual -i Fedora-35 -c system execute report finish
```
`tmt` will upload keylime sources from the (current) repository to the provisioned virtual system and the task/test `/setup/install_upstream_keylime` from a test plan takes care of installing keylime from those uploaded sources before proceeding with other tests.
