TEST

# Special Project Upstream Testing Repository for the keylime package

There are multiple projects running tests from this repository.

## componnets
* [keylime](https://github.com/keylime/keylime)
* [rust-keylime](https://github.com/keylime/rust-keylime)
* [keylime_server](https://github.com/linux-system-roles/keylime_server/) Linux system role

The data are structured in the [Flexible metadata format](https://fmf.readthedocs.io/en/stable/).
Individual tests are supposed to be executed using the [Test management tool](https://tmt.readthedocs.io/en/stable/).

## Test execution and troubleshooting
Test execution and troubleshooting is described in detail in [TESTING](TESTING.md) and [TEST_TROUBLESHOOTING.md](TEST_TROUBLESHOOTING.md).

## Commit / merge policy

Every change to tests must be submited as a pull-request and undergo a review and testing.

#### new tests
It is recommended to push new tests via PR with review as well as a check for covering all the agreed acceptance criteria is more than welcome.

#### reviewer selection
The review can be done by any member of the team. However, it is recommended to ask the devel counterpart as they could judge the test expectations according to the actual code change. Asking another QE person, on the other hand, will ensure to keep the test coding style as consistent as possible.

#### PR merge
The merge itself should be done based on the accepted reviews. It is recommended to let the original requestor to merge the PR as they may want to do some refinements, e.g. squash some commits which were added during the review process.

It is also important to make sure that the _Nitrate_ references are resynced (`tmt tests export --nitrate .`) to update the reflect the change form the previous location (branch) to the final one.

