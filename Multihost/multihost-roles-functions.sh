#!/bin/bash

function assign_server_roles() {
    if [ -n "${TMT_TOPOLOGY_BASH}" ] && [ -f ${TMT_TOPOLOGY_BASH} ]; then
        # assign roles based on tmt topology data
        cat ${TMT_TOPOLOGY_BASH}
        . ${TMT_TOPOLOGY_BASH}

        export VERIFIER=${TMT_GUESTS["verifier.hostname"]}
        export REGISTRAR=${TMT_GUESTS["registrar.hostname"]}
        export AGENT=${TMT_GUESTS["agent.hostname"]}
        # AGENT2 may not be defined
        if [ -n "${TMT_GUESTS["agent2.hostname"]}" ]; then
            export AGENT2=${TMT_GUESTS["agent2.hostname"]}
        fi
        MY_IP="${TMT_GUEST['hostname']}"
    elif [ -n "$SERVERS" ]; then
        # assign roles using SERVERS and CLIENTS variables
        export VERIFIER=$( echo "$SERVERS $CLIENTS" | awk '{ print $1 }')
        export REGISTRAR=$( echo "$SERVERS $CLIENTS" | awk '{ print $2 }')
        export AGENT=$( echo "$SERVERS $CLIENTS" | awk '{ print $3 }')
        export AGENT2=$( echo "$SERVERS $CLIENTS" | awk '{ print $4 }')
    fi

    [ -z "$MY_IP" ] && MY_IP=$( hostname -I | awk '{ print $1 }' )
    [ -n "$VERIFIER" ] && export VERIFIER_IP=$( get_IP $VERIFIER )
    [ -n "$REGISTRAR" ] && export REGISTRAR_IP=$( get_IP $REGISTRAR )
    [ -n "${AGENT}" ] && export AGENT_IP=$( get_IP ${AGENT} )
    [ -n "${AGENT2}" ] && export AGENT2_IP=$( get_IP ${AGENT2} )
}

function get_IP() {
    if echo $1 | grep -E -q '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
        echo $1
    else
        host $1 | sed -n -e 's/.*has address //p' | head -n 1
    fi
}
