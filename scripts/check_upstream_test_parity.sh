#!/bin/bash

KEYLIME_PLAN_URL="https://raw.githubusercontent.com/keylime/keylime/refs/heads/master/packit-ci.fmf"
AGENT_PLAN_URL="https://raw.githubusercontent.com/keylime/rust-keylime/refs/heads/master/packit-ci.fmf"

function test_filter() {
	sed 's#^[^/]*##g' | grep -E "^/(functional|compatibility|regression)" | sort -u
}

function get_upstream_tests() {
	curl -s "$1" | test_filter
}

function get_test_list() {
	tmt -c swtpm=yes test ls --filter 'enabled: true' --filter 'tag: -not-keylime-upstream-CI' 2>/dev/null | test_filter
}

function get_agent_test_list() {
	tmt -c swtpm=yes test ls --filter 'enabled: true' --filter 'tag: -not-agent-upstream-CI' 2>/dev/null | test_filter
}

function do_diff() {
	echo "Missing tests:"
	diff -w "$1" "$2" > diff.txt
        ! grep '^<' diff.txt
}

RESULT=0

echo "Getting a list of available tests..."
get_test_list > tests.txt
get_agent_test_list > agent_tests.txt
wc -l tests.txt agent_tests.txt
echo "Getting a list of tests used in keylime CI..."
get_upstream_tests "$KEYLIME_PLAN_URL" > keylime.txt
wc -l keylime.txt
echo
do_diff agent_tests.txt keylime.txt
RESULT=$(( RESULT+$? ))
echo
echo "Getting a list of tests used in rust-keylime CI..."
get_upstream_tests "$AGENT_PLAN_URL" > agent.txt
wc -l agent.txt
echo
do_diff agent_tests.txt agent.txt
RESULT=$(( RESULT+$? ))
exit $RESULT
