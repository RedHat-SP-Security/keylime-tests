# Contribution To The Project

Pull Requests and Issues have four possible Labels:
* WIP - Work In Progress, it is not ready for review/merge
* Functional - Proposed change changes the test behaviour
* Metadata - Only Metadata is about to change
* Scope - Big scope, a commit changes multiple test scenarios

Rules:
* A commit introduces one logical change and this may require changes to multiple test cases
* Do not merge Pull Request without review


Workflow(the following steps require public key authentication set on GitHub):
* Create a fork
* Clone a fork
* Add this repository as a remote of your fork, call it upstream
```
$ git remote add upstream git@github.com:RedHat-SP-Security/tests.git
```
* Check remote
```
$ git remote -v
# it should print 4 entries e.g.
origin	git@github.com:radosroka/tests.git (fetch)
origin	git@github.com:radosroka/tests.git (push)
upstream	git@github.com:RedHat-SP-Security/tests.git (fetch)
upstream	git@github.com:RedHat-SP-Security/tests.git (push)
```
* Pull changes from upstream
```
# this will rebase your master with upstream master
# both masters should be even right now
$ git pull --rebase upstream master
```
* Push pulled changes to your fork master
```
# if they are even nothing happens
$ git push origin master
```
* Create a branch
```
# last arg is optional
# if provided, new branch will be tied with your master
$ git checkout -b name_of_the_branch origin/master
```
* Add changes
```
# provide list of files 
$ git add ...
```
* Check changes
```
# should print added files as green
# other changed but not added files are red
$ git status

# show added content as a diff
$ git diff --cached
```
* Commit changes
```
# provide commit message
$ git commit 
```
* Push changes
```
$ git push origin name_of_the_branch
```
* Create a Pull Request
* Wait for review
* If changes are requested
  * Add changes
  * Check changes
  * Commit changes
    * Add ```--amend``` to the commit command
    * You will add your changes to the last commit
  * Push changes
    * Add ```--force``` after push
    * You will replace old commit on github with your new one
    * ```--force``` will replace whole history of the remote branch with yours
* [optional] Delete created branch

