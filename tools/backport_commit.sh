#!/bin/bash

# A script to automate backporting commits to multiple branches
# and opening a browser to create a pull request.
#
# written by gemini
# slightly adjusted by ksrot@redhat.com
#
# I am frequently backporting specific commits from the main branch
# to other branches. Write a bash script that will do the work
# automatically. It should be given commit hashes as cmdline arguments
# as well as target branches and it should create branches that will be
# pushed upstream and pull-request to the target branch created.
# For example, when pushing to rhel-10-main branch it should create
# local branch that has rhel-10-main as a suffix, 
# e.g. "some-prefix_rhel-10-main", push it to upstream and at the same
# time open a pull-request from some-prefix_rhel-10-main to rhel-10-main. 
# Do not use gh but rather open the respective URL for PR creation in
# the default browser. 

# Exit immediately if a command exits with a non-zero status.
set -eo pipefail

# --- Configuration ---
BRANCH_PREFIX="backport"
REMOTE="origin"

# --- Colors for output ---
COLOR_GREEN='\033[0;32m'
COLOR_RED='\033[0;31m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_NC='\033[0m' # No Color

# --- Usage Function ---
usage() {
  echo -e "${COLOR_YELLOW}Usage: $0 <commit-hash-1> [commit-hash-2...] -- <target-branch-1> [target-branch-2...]${COLOR_NC}"
  echo
  echo "Example:"
  echo "  $0 2a4c3f7e a9b1d8f0 -- rhel-9-main rhel-10-main"
  echo
  echo "This script will:"
  echo "  1. Create a new local branch for each target branch (e.g., 'backport/20250915_rhel-9-main')."
  echo "  2. Cherry-pick the specified commits onto the new branch."
  echo "  3. Push the new branch to the remote ('$REMOTE')."
  echo "  4. Open the 'Create Pull Request' page in your default web browser."
}

# --- Helper Functions ---
check_deps() {
  if ! command -v git &> /dev/null; then
    echo -e "${COLOR_RED}Error: 'git' is not installed or not in your PATH.${COLOR_NC}"
    exit 1
  fi
}

# Function to get the repository path (e.g., "owner/repo") from the remote URL
get_repo_path() {
    local url
    url=$(git config --get "remote.${REMOTE}.url")
    if [[ -z "$url" ]]; then
        echo -e "${COLOR_RED}Error: Could not find URL for remote '$REMOTE'.${COLOR_NC}" >&2
        return 1
    fi
    if [[ "$url" != *"github.com"* ]]; then
        echo -e "${COLOR_RED}Error: Remote '$REMOTE' URL does not appear to be a GitHub URL: $url${COLOR_NC}" >&2
        echo -e "${COLOR_RED}This script only supports GitHub repositories.${COLOR_NC}" >&2
        return 1
    fi
    # Works for both SSH (git@github.com:owner/repo.git) and HTTPS (https://github.com/owner/repo.git)
    echo "$url" | sed -E -e 's/.*github\.com[:\/]//' -e 's/\.git$//'
}

# Function to open a URL in the default browser across different OS
open_url() {
    local url=$1
    echo -e "Opening URL in your browser: ${COLOR_BLUE}$url${COLOR_NC}"
    case "$OSTYPE" in
      linux-gnu*) xdg-open "$url" ;;
      darwin*)    open "$url" ;;
      cygwin|msys|win32) explorer.exe "$url" ;;
      *)          echo -e "${COLOR_YELLOW}Could not detect OS. Please open the URL manually.${COLOR_NC}" ;;
    esac
}

# --- Argument Parsing ---
if [[ "$#" -lt 3 ]] || ! [[ "$@" =~ " -- " ]]; then
  usage
  exit 1
fi

COMMITS=()
BRANCHES=()
parsing_commits=true

for arg in "$@"; do
  if [[ "$arg" == "--" ]]; then
    parsing_commits=false
    continue
  fi

  if $parsing_commits; then
    COMMITS+=("$arg")
  else
    BRANCHES+=("$arg")
  fi
done

if [ ${#COMMITS[@]} -eq 0 ] || [ ${#BRANCHES[@]} -eq 0 ]; then
  echo -e "${COLOR_RED}Error: You must provide at least one commit hash and one target branch.${COLOR_NC}"
  usage
  exit 1
fi

# --- Main Logic ---
check_deps
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
REPO_PATH=$(get_repo_path)
if [ -z "$REPO_PATH" ]; then
    exit 1
fi

echo -e "${COLOR_BLUE}Fetching latest changes from remote '$REMOTE'...${COLOR_NC}"
git fetch "$REMOTE" --prune

for target_branch in "${BRANCHES[@]}"; do
  echo -e "\n${COLOR_BLUE}=======================================================${COLOR_NC}"
  echo -e "${COLOR_BLUE}Processing backport to branch: ${COLOR_YELLOW}$target_branch${COLOR_NC}"
  echo -e "${COLOR_BLUE}=======================================================${COLOR_NC}"

  sanitized_target_branch=${target_branch//\//-}
  # use branch name in the format of YYMMDDHHMMSS_TARGETBRANCH (portable across GNU/BSD date)
  BACKPORT_BRANCH_NAME="${BRANCH_PREFIX}/$(date +%Y%m%d%H%M%S)_${sanitized_target_branch}"

  echo "Creating new branch '$BACKPORT_BRANCH_NAME' from '$REMOTE/$target_branch'..."
  git checkout -b "$BACKPORT_BRANCH_NAME" "$REMOTE/$target_branch"
  if [ $? -ne 0 ]; then
      echo -e "${COLOR_RED}Error: Failed to create branch for '$target_branch'. Does it exist on remote '$REMOTE'? Skipping.${COLOR_NC}"
      git checkout "$CURRENT_BRANCH" # Go back to original branch
      continue
  fi

  echo "Cherry-picking commits..."
  for commit in "${COMMITS[@]}"; do
    echo -e "  -> Applying commit ${COLOR_YELLOW}$commit${COLOR_NC}"
    if ! git cherry-pick "$commit"; then
      echo -e "${COLOR_RED}CHERRY-PICK FAILED for commit $commit.${COLOR_NC}"
      echo -e "${COLOR_YELLOW}Please resolve the conflicts in another terminal.${COLOR_NC}"
      echo "After resolving:"
      echo "  1. Run 'git add <resolved-files>'"
      echo "  2. Run 'git cherry-pick --continue'"
      echo "To abort the cherry-pick for this branch:"
      echo "  Run 'git cherry-pick --abort' and then re-run this script for the remaining branches."
      read -p "Press [Enter] here once you have resolved the conflict to continue the script..."
    fi
  done

  echo "Pushing branch '$BACKPORT_BRANCH_NAME' to '$REMOTE'..."
  git push "$REMOTE" "$BACKPORT_BRANCH_NAME"

  # Prepare PR details and URL
  FIRST_COMMIT_SUBJECT=$(git log -1 --pretty=%s "${COMMITS[0]}")
  PR_TITLE="Backport: ${FIRST_COMMIT_SUBJECT} to ${target_branch}"
  
  PR_BODY="This PR backports the following commits to the \`$target_branch\` branch:"
  PR_BODY+=$'\n\n'
  for c in "${COMMITS[@]}"; do
      short_hash=$(git rev-parse --short "$c")
      subject=$(git log -1 --pretty=%s "$c")
      PR_BODY+="* \`$short_hash\`: $subject"$'\n'
  done

  PR_URL="https://github.com/${REPO_PATH}/compare/${target_branch}...${BACKPORT_BRANCH_NAME}?expand=1"

  echo -e "\n${COLOR_GREEN}Ready to create Pull Request. Please use the details below:${COLOR_NC}"
  echo -e "----------------------------------------------------------------"
  echo -e "${COLOR_YELLOW}Suggested Title:${COLOR_NC}"
  echo "$PR_TITLE"
  echo
  echo -e "${COLOR_YELLOW}Suggested Body:${COLOR_NC}"
  echo -e "$PR_BODY"
  echo -e "----------------------------------------------------------------\n"

  open_url "$PR_URL"
  
  # Return to the original branch to start clean for the next loop
  echo "Cleaning up..."
  git checkout "$CURRENT_BRANCH"

done

echo -e "\n${COLOR_GREEN}✅ All backporting tasks complete!${COLOR_NC}"
