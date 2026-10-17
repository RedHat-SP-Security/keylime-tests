#!/bin/bash

dump_help() {
    local cmd="$1"
    echo "================================================================"
    echo "$ $cmd --help"
    echo "================================================================"
    $cmd --help 2>&1
    echo

    local subcmds
    subcmds=$($cmd --help 2>&1 | sed -n '/^Commands:/,/^$/p' | grep -oP '^\s+\K\S+' | grep -v '^help$')

    for sub in $subcmds; do
        dump_help "$cmd $sub"
    done
}

dump_help keylimectl
