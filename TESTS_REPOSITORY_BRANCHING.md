# Keylime-Tests Repository Branching and CI Configuration Guide

## Overview

The keylime-tests repository uses **tmt dynamic ref evaluation** to automatically select the appropriate test branch based on the system being tested. This allows different RHEL/Fedora versions to use different test branches while maintaining consistency.

**Key Principle:** With every minor release (recommended) or whenever the latest minor significantly diverges due to a rebase (necessary), we need to branch tests.

---

## Core Concepts

### 1. Dynamic Ref Mapping (`.tmt/dynamic_ref.fmf`)
- Located in the **main branch only**
- Maps distribution versions to test branches
- **Order matters**: First matching rule wins (most specific rules first)

### 2. CI Configuration (`.packit.yaml`)
- Each branch has its own configuration
- Defines which tests run for PRs targeting that branch

### 3. Test Plans (`plans/*.fmf`)
- Filter tests based on `target_PR_branch`
- Ensure tests only run on appropriate branches

### 4. Branch Switching (`setup/switch_git_branch/`)
- Runtime branch switching for RHEL systems
- Downloads latest script from main branch
- Auto-detects correct branch based on redhat-release RPM

---

## Scenario 1: Creating a New RHEL Minor Version Branch

**Use Case:** Before rebasing to a new RHEL minor version (e.g., RHEL-10.2), create a branch for the previous minor version (e.g., rhel-10.1) to preserve tests for that version.

### Step-by-Step Procedure

#### Step 1: Create the Minor Version Branch

```bash
cd keylime-tests
git checkout rhel-<MAJOR>-main    # e.g., rhel-10-main for RHEL-10
git pull
git checkout -b rhel-<MAJOR>.<MINOR>    # e.g., rhel-10.1
git push --set-upstream origin rhel-<MAJOR>.<MINOR>
```

**Example:**
```bash
git checkout rhel-10-main
git pull
git checkout -b rhel-10.1
git push --set-upstream origin rhel-10.1
```

**Commit location:** This creates a new branch (no commit needed yet)

---

#### Step 2: Update Dynamic Ref Mapping in Main Branch

Edit `.tmt/dynamic_ref.fmf` in the **main branch** to add mapping for the new minor version branch.

**Location:** `.tmt/dynamic_ref.fmf` in main branch

Add the new mapping **before** the major version mapping:

```yaml
adjust:
 - when: enforce_keylime_tests_branch is defined
   ref: $@enforce_keylime_tests_branch
   continue: false
 - when: distro == rhel-<MAJOR>.<MINOR> or distro == rhel-<MAJOR>.<MINOR-1>
   ref: rhel-<MAJOR>.<MINOR>
   continue: false
 - when: distro == rhel-<MAJOR> or distro == centos-stream-<MAJOR> or snapshot_name ~= rhel-<MAJOR>
   ref: rhel-<MAJOR>-main
   continue: false
```

**Example for rhel-10.1:**
```yaml
adjust:
 - when: enforce_keylime_tests_branch is defined
   ref: $@enforce_keylime_tests_branch
   continue: false
 - when: distro == rhel-10.0 or distro == rhel-10.1
   ref: rhel-10.1
   continue: false
 - when: distro == rhel-10 or distro == centos-stream-10 or snapshot_name ~= rhel-10
   ref: rhel-10-main
   continue: false
```

**Commit message:** `Update dynref mapping for RHEL-<MAJOR>.<MINOR>`

**Reference:** https://github.com/RedHat-SP-Security/keylime-tests/commit/0a9200dbfbdcd5f39eeaffee29a46dae24bd17b3

---

#### Step 3: Adjust CI Configuration in the New Branch

Edit `.packit.yaml` in the **new branch** (rhel-<MAJOR>.<MINOR>).

**Key changes:**
1. Update `branch:` field to match new branch name
2. Update `target_PR_branch:` in context to match new branch
3. Specify exact distro version in `distros:` field
4. Add `use_internal_tf: True` if needed
5. Remove or simplify unnecessary jobs (container tests, image mode tests may be problematic for older releases)

**Focus on:** singlehost and multihost tests

**Example for rhel-10.1:**

```yaml
jobs:
- job: tests
  trigger: pull_request
  identifier: singlehost
  branch: rhel-10.1
  targets:
    centos-stream-10-x86_64:
      distros: [RHEL-10.1-Nightly]
  use_internal_tf: True
  skip_build: true
  tf_extra_params:
    environments:
      - tmt:
          context:
            target_PR_branch: "rhel-10.1"
- job: tests
  trigger: pull_request
  identifier: multihost
  branch: rhel-10.1
  targets:
    centos-stream-10-x86_64:
      distros: [RHEL-10.1-Nightly]
  skip_build: true
  env:
    SYNC_DEBUG: "1"
  use_internal_tf: True
  tf_extra_params:
    test:
      tmt:
        name: "/plans/distribution-c10s-keylime-multihost.*"
    environments:
      - tmt:
          context:
            target_PR_branch: "rhel-10.1"
            multihost: "yes"
    settings:
      pipeline:
        type: tmt-multihost
```

**Commit message:** `Enable CI on rhel-<MAJOR>.<MINOR> branch`

**Reference:** https://github.com/RedHat-SP-Security/keylime-tests/commit/9692465c29c03f5d01e4ac04fc77f6890bd194a6

---

#### Step 4: Update Test Plans in the New Branch

Edit test plan files in the **new branch** to ensure they only run for this branch.

For each relevant plan (e.g., `plans/distribution-c10s-keylime-multihost.fmf`):

```yaml
adjust+:
  - when: target_PR_branch is defined and target_PR_branch != rhel-<MAJOR>.<MINOR>
    enabled: false
    because: we want to run this plan only for PRs targeting this branch
```

**Example:**
```yaml
adjust+:
  - when: target_PR_branch is defined and target_PR_branch != rhel-10.1
    enabled: false
    because: we want to run this plan only for PRs targeting the rhel-10.1 branch
```

**Remove unnecessary plans:**
```bash
git rm plans/distribution-c9s-*.fmf
git rm plans/upstream-*.fmf
git rm plans/distribution-fedora-*.fmf
# Keep only plans relevant to this RHEL version
```

---

#### Step 5: Update switch_git_branch in Main Branch (if needed)

If this is a new **major version**, update `setup/switch_git_branch/main.fmf` in the **main branch**.

**Current configuration supports:**
```yaml
adjust:
  - when: distro != rhel
    enabled: false
```

This enables the switch_git_branch test for all RHEL versions.

**If updating for a new major version:**

**Commit message:** `Enable switch_git_branch task for RHEL-<MAJOR>`

**Reference:** Commit 75f479b in main branch

---

## Scenario 2: RHEL/CentOS Stream Rebase

**Use Case:** When rebasing keylime to a new upstream version in RHEL or CentOS Stream, test against the main branch temporarily before rewriting the stable branch (e.g., rhel-10-main).

**Prerequisites:** You should have already created a minor version branch (Scenario 1) before starting the rebase.

### Phase 1: Preparation & Temporary Redirect

#### Step 1: Add Temporary Dynamic Ref Redirect in Main Branch

Edit `.tmt/dynamic_ref.fmf` in the **main branch**.

Add the redirect **at the top** of the adjust section (after the enforce_keylime_tests_branch rule):

```yaml
adjust:
 - when: enforce_keylime_tests_branch is defined
   ref: $@enforce_keylime_tests_branch
   continue: false
 # temporary redirection due to planned <VERSION> rebase
 - when: distro == <DISTRO_ID> and initiator == <CI_SYSTEM>
   ref: main
   continue: false
```

**Example for RHEL-10.2:**
```yaml
 # temporary redirection due to planned 10.2 rebase
 - when: distro == rhel-10.2 and initiator == rhel-ci
   ref: main
   continue: false
```

**Example for Fedora:**
```yaml
 # temporary redirection due to planned fedora rebase
 - when: distro == fedora and initiator == fedora-ci
   ref: main
   continue: false
```

**Commit message:** `Temporary dynamic_ref redirect for <VERSION> rebase`

**Reference:** Commit e9472aa

---

#### Step 2: Create and Test MR/PR

Create a merge/pull request in the keylime package repository with the rebased code.

Iterate on the MR/PR until CI tests pass and you're confident the rebase works correctly.

---

### Phase 2: Branch Rewrite

#### Step 3: Create Backup of Existing Branch

```bash
cd keylime-tests
git fetch
git checkout <BRANCH_NAME>    # e.g., rhel-10-main
git pull
git checkout -b <BRANCH_NAME>-backup_$(date +%Y-%m-%d)
git reset --hard <BRANCH_NAME>
git push --force --set-upstream origin <BRANCH_NAME>-backup_$(date +%Y-%m-%d)
```

**Example:**
```bash
git checkout rhel-10-main
git pull
git checkout -b rhel-10-main-backup_2026-04-09
git reset --hard rhel-10-main
git push --force --set-upstream origin rhel-10-main-backup_2026-04-09
```

---

#### Step 4: Temporarily Remove Branch Protection

Navigate to GitHub Settings → Branches → Edit protected branch pattern

**For rhel-10-main:**
- Change pattern from `rhel-10-main` to `rhel-10.*`
- This excludes rhel-10-main but protects rhel-10.1, rhel-10.2, etc.

**For rhel-9-main:**
- Change pattern from `rhel-9-main` to `rhel-9.*`

---

#### Step 5: Rewrite Target Branch with Main

```bash
git checkout <BRANCH_NAME>    # e.g., rhel-10-main
git reset --hard main
git push --force
```

**Example:**
```bash
git checkout rhel-10-main
git reset --hard main
git push --force
```

---

#### Step 6: Restore Branch Protection

Navigate to GitHub Settings → Branches → Edit protected branch pattern

Change the pattern back to the specific branch name:
- `rhel-10-main` or
- `rhel-9-main`

---

#### Step 7: Fix CI Setup in Rewritten Branch

After rewriting the branch, verify and adjust CI configuration in the **rewritten branch** (e.g., rhel-10-main).

**Check:**
- `.packit.yaml` - ensure `branch:` and `target_PR_branch:` are correct
- Test plans - ensure `target_PR_branch` filters are correct
- Dockerfiles in `Library/test-helpers/` - may need adjustments

**Note:** There's a chance it will work instantly due to templates in the main branch, but manual adjustments might be needed.

---

### Phase 3: Cleanup

#### Step 8: Remove Temporary Redirect from Main Branch

Edit `.tmt/dynamic_ref.fmf` in the **main branch**.

Remove the temporary redirect section added in Step 1.

**Commit message:** `Remove dynamic mapping for <VERSION>`

**Reference:** Commit 7abf525

---

#### Step 9: Merge Keylime MR/PR

Once all tests pass, merge the keylime package MR/PR.

---

## Scenario 3: Creating a New Fedora Version Branch

**Use Case:** When a new Fedora version is released, create a dedicated branch for testing.

### Step-by-Step Procedure

#### Step 1: Create New Branch

```bash
cd keylime-tests
git fetch
git checkout fedora-main  # or main if fedora-main doesn't exist
git pull
git checkout -b fedora-<VERSION>
git push --set-upstream origin fedora-<VERSION>
```

**Example:**
```bash
git checkout fedora-main
git pull
git checkout -b fedora-42
git push --set-upstream origin fedora-42
```

---

#### Step 2: Update .packit.yaml in the New Branch

Simplify the configuration to only target this Fedora version:

```yaml
jobs:
- job: tests
  trigger: pull_request
  identifier: singlehost
  branch: fedora-<VERSION>
  targets:
    - fedora-<VERSION>
  skip_build: true
  tf_extra_params:
    environments:
      - tmt:
          context:
            target_PR_branch: "fedora-<VERSION>"
            multihost: "no"
```

**Example:**
```yaml
jobs:
- job: tests
  trigger: pull_request
  identifier: singlehost
  branch: fedora-42
  targets:
    - fedora-42
  skip_build: true
  tf_extra_params:
    environments:
      - tmt:
          context:
            target_PR_branch: "fedora-42"
            multihost: "no"
```

**Commit message:** `Enable CI for fedora-<VERSION> branch`

**Reference:** Commit 2d966f1

---

#### Step 3: Update Test Plan in the New Branch

Edit `plans/distribution-fedora-keylime.fmf` in the **new branch**:

```yaml
adjust+:
 - when: target_PR_branch is defined and target_PR_branch != fedora-<VERSION>
   enabled: false
   because: we want to run this plan only for PRs targeting the respective Fedora branch
```

---

#### Step 4: Update Dynamic Ref Mapping in Main Branch

Edit `.tmt/dynamic_ref.fmf` in the **main branch**.

Add mapping for the new Fedora version (order matters - specific before general):

```yaml
 - when: distro == fedora-<VERSION>
   ref: fedora-<VERSION>
   continue: false
 - when: distro == fedora
   ref: fedora-main
   continue: false
```

**Example:**
```yaml
 - when: distro == fedora-42
   ref: fedora-42
   continue: false
 - when: distro == fedora
   ref: fedora-main
   continue: false
```

**Commit message:** `Update Fedora dynamic_ref mapping`

**Reference:** Commit def88a7

---

## Important Files and Their Purposes

### `.tmt/dynamic_ref.fmf` (main branch only)
- **Purpose:** Maps distribution versions to test branches
- **Updated:** Only in main branch
- **Rule order:** Specific rules first, general rules last
- **Key field:** `continue: false` ensures first match wins

### `.packit.yaml` (each branch)
- **Purpose:** CI configuration for pull requests
- **Updated:** In each branch independently
- **Key fields:**
  - `branch:` - The branch this config applies to
  - `target_PR_branch:` - Must match branch name
  - `targets:` - Which distros/versions to test
  - `distros:` - Specific version constraints (for minor releases)

### `plans/*.fmf` (each branch)
- **Purpose:** Test plan definitions
- **Key adjustment:** `target_PR_branch` filter to control where plans run

### `setup/switch_git_branch/` (main branch)
- **Purpose:** Runtime branch switching for RHEL systems
- **Mechanism:** Downloads latest script from main, switches based on redhat-release RPM
- **Files:**
  - `main.fmf` - Test definition with distro filter
  - `test.sh` - Wrapper that downloads autodetect.sh
  - `autodetect.sh` - Logic for branch detection and switching

---

## Checklists for AI Agent Automation

### Checklist: Create New RHEL Minor Version Branch

- [ ] **Step 1:** Create branch from rhel-<MAJOR>-main
  - `git checkout rhel-<MAJOR>-main && git pull`
  - `git checkout -b rhel-<MAJOR>.<MINOR>`
  - `git push --set-upstream origin rhel-<MAJOR>.<MINOR>`

- [ ] **Step 2:** Update `.tmt/dynamic_ref.fmf` in main branch
  - Add mapping before major version mapping
  - Commit: `Update dynref mapping for RHEL-<MAJOR>.<MINOR>`

- [ ] **Step 3:** Update `.packit.yaml` in new branch
  - Update `branch:` field
  - Update `target_PR_branch:` in context
  - Add `distros:` constraint
  - Remove unnecessary jobs (container, image mode)
  - Commit: `Enable CI on rhel-<MAJOR>.<MINOR> branch`

- [ ] **Step 4:** Update test plans in new branch
  - Update `target_PR_branch` filters
  - Remove plans for other distros

- [ ] **Step 5:** Update `setup/switch_git_branch/main.fmf` in main (if new major version)
  - Commit: `Enable switch_git_branch task for RHEL-<MAJOR>`

- [ ] **Verify:** Test CI runs successfully on new branch

---

### Checklist: RHEL/CentOS Stream Rebase

**Phase 1: Preparation**
- [ ] **Step 1:** Add temporary redirect in `.tmt/dynamic_ref.fmf` (main branch)
  - Commit: `Temporary dynamic_ref redirect for <VERSION> rebase`

- [ ] **Step 2:** Create and test keylime package MR/PR
  - Iterate until CI passes

**Phase 2: Branch Rewrite**
- [ ] **Step 3:** Create backup branch
  - `git checkout <BRANCH> && git pull`
  - `git checkout -b <BRANCH>-backup_$(date +%Y-%m-%d)`
  - `git push --force --set-upstream origin <BRANCH>-backup_$(date +%Y-%m-%d)`

- [ ] **Step 4:** Temporarily remove branch protection
  - Change pattern from `rhel-X-main` to `rhel-X.*`

- [ ] **Step 5:** Rewrite branch with main
  - `git checkout <BRANCH>`
  - `git reset --hard main`
  - `git push --force`

- [ ] **Step 6:** Restore branch protection
  - Change pattern back to `rhel-X-main`

- [ ] **Step 7:** Fix CI setup in rewritten branch (if needed)
  - Check `.packit.yaml`
  - Check test plans
  - Check Dockerfiles

**Phase 3: Cleanup**
- [ ] **Step 8:** Remove temporary redirect from main
  - Commit: `Remove dynamic mapping for <VERSION>`

- [ ] **Step 9:** Merge keylime package MR/PR

---

### Checklist: Create New Fedora Version Branch

- [ ] **Step 1:** Create branch from fedora-main
  - `git checkout fedora-main && git pull`
  - `git checkout -b fedora-<VERSION>`
  - `git push --set-upstream origin fedora-<VERSION>`

- [ ] **Step 2:** Update `.packit.yaml` in new branch
  - Simplify to single Fedora target
  - Commit: `Enable CI for fedora-<VERSION> branch`

- [ ] **Step 3:** Update `plans/distribution-fedora-keylime.fmf` in new branch
  - Update `target_PR_branch` filter

- [ ] **Step 4:** Update `.tmt/dynamic_ref.fmf` in main branch
  - Add Fedora version mapping
  - Commit: `Update Fedora dynamic_ref mapping`

- [ ] **Verify:** Test CI runs successfully on new branch

---

## Common Patterns and Best Practices

### 1. Dynamic Ref Rule Ordering
**Rule:** Most specific conditions first, most general last

**Good example:**
```yaml
- when: distro == rhel-10.0 or distro == rhel-10.1
  ref: rhel-10.1
  continue: false
- when: distro == rhel-10 or distro == centos-stream-10
  ref: rhel-10-main
  continue: false
```

**Bad example (reversed):**
```yaml
- when: distro == rhel-10 or distro == centos-stream-10
  ref: rhel-10-main
  continue: false
- when: distro == rhel-10.0 or distro == rhel-10.1  # This will never match!
  ref: rhel-10.1
  continue: false
```

---

### 2. Temporary Redirects Use Initiator Filtering

**Pattern:**
```yaml
- when: distro == <DISTRO> and initiator == <CI_SYSTEM>
  ref: main
  continue: false
```

**Purpose:** Prevents interference with other CI systems or manual testing

---

### 3. Branch Protection Management

**Always:**
1. Create backup before force push
2. Temporarily disable protection
3. Perform force push
4. Restore protection immediately

---

### 4. Standardized Commit Messages

| Action | Commit Message |
|--------|---------------|
| Temporary redirect | `Temporary dynamic_ref redirect for <VERSION> rebase` |
| Remove redirect | `Remove dynamic mapping for <VERSION>` |
| Update mapping | `Update dynref mapping for <VERSION>` |
| Enable CI (RHEL) | `Enable CI on rhel-<MAJOR>.<MINOR> branch` |
| Enable CI (Fedora) | `Enable CI for fedora-<VERSION> branch` |
| Fix mapping typo | `Fix dynamic_ref.fmf typo` |
| Update Fedora mapping | `Update Fedora dynamic_ref mapping` |

---

### 5. Minor Version Branches Simplify Over Time

When creating a minor version branch:
- **Remove** unrelated distribution plans
- **Simplify** CI configuration (focus on singlehost/multihost)
- **Avoid** complex setups (container tests, image mode tests may be problematic)

---

### 6. The switch_git_branch Mechanism

**How it works:**
1. Test runs on RHEL system
2. `test.sh` downloads latest `autodetect.sh` from main branch
3. `autodetect.sh` reads `redhat-release` RPM
4. Script checks for matching remote branch (version-specific first, then X-main)
5. Git switches to detected branch
6. Tests execute from the switched branch

**Key insight:** This provides fallback mechanism if dynamic_ref doesn't work or for manual test execution.

---

## Summary for AI Agents

When automating these processes, remember:

1. **Always work in the correct branch** - main for dynamic_ref updates, target branch for CI configs
2. **Follow the order** - Create minor version branch → Update dynamic_ref → Adjust CI → Then rebase
3. **Backup before rewrite** - Create dated backup branches before any force push
4. **Test incrementally** - Verify CI works after each major change
5. **Use standard commit messages** - Helps track changes and understand intent
6. **Mind the order in dynamic_ref** - Specific rules always before general rules

The typical workflow for a RHEL rebase is:
1. Create minor version branch (rhel-X.Y)
2. Update dynamic_ref mapping
3. Add temporary redirect for testing
4. Test rebase thoroughly
5. Backup and rewrite main branch
6. Remove temporary redirect
7. Merge keylime package
