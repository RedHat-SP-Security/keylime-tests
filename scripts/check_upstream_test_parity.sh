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
	tmt -c swtpm=yes test ls --filter 'enabled: true' 2>/dev/null | test_filter
}

function do_diff() {
	echo "Missing tests:"
	diff -w "$1" "$2" | grep '^<' && return 1
}

RESULT=0

echo "Getting a list of available tests..."
get_test_list > tests.txt
echo "Getting a list of tests used in keylime CI..."
get_upstream_tests "$KEYLIME_PLAN_URL" > keylime.txt
echo
do_diff tests.txt keylime.txt
RESULT=$(( RESULT+$? ))
echo
echo "Getting a list of tests used in rust-keylime CI..."
get_upstream_tests "$AGENT_PLAN_URL" > agent.txt
echo
do_diff tests.txt agent.txt
RESULT=$(( RESULT+$? ))
exit $RESULT
