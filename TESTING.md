## Running tests on a local test system

### Using tmt (Test Metadata Tool)

Install [`tmt`](https://tmt.readthedocs.io/en/latest/overview.html) and clone tests repository

```
# yum -y install tmt
# git clone https://github.com/RedHat-SP-Security/keylime-tests.git
# cd keylime-tests
```

With `tmt` you can easily run whole test plan. Currently, there is one
plan store in the `plans/keylime-tests-github-ci` file.
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

### Running CI tests from the upstream keylime project

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
    reference: main
```

Then you can run tests using the `tmt` tool as described in the section above.
