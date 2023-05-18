#!/bin/bash

unset UPLOAD_SERVICES
# declare upload services (the last will be tried first)
declare -A UPLOAD_SERVICES=( \
    [free.keep.sh]="https://free.keep.sh" \
    [oshi.at]="https://oshi.at/?expire=1440" \
    [transfer.sh]="https://transfer.sh" \
)

# returns a list of known service domains
function uploadServiceList() {
    echo ${!UPLOAD_SERVICES[@]}
}

# returns URL for the given service domain
function uploadServiceURL() {
    echo ${UPLOAD_SERVICES[$1]}
}

# returns the first available (reachable) service
function uploadServiceFind() {
    local SERVICE
    for SERVICE in `uploadServiceList`; do
        ping -c 1 "$SERVICE" &> /dev/null && echo "$SERVICE" && return 0
    done
    return 1
}

# parse URL of the uploaded file from the output of a given service
function uploadServiceParseURL() {
    local CAT
    [ -z "$1" -o "$1" == "-" ] && CAT="cat" || CAT="cat $1"
    if [ "$2" == "oshi.at" ]; then
        $CAT | grep ' \[Download\]' | grep -o 'https:[^" ]*' | head -1
    else
        $CAT | grep -o 'https:[^" ]*' | head -1
    fi
}

# uploads a file to the given service and prints URL to the downloaded file
function uploadServiceUpload() {
    local SERVICE="$1"
    local FILE="$2"
    local URL=$( uploadServiceURL $1 )
    curl -s --upload-file $FILE $URL | uploadServiceParseURL - $1
}
