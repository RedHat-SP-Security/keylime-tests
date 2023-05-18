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
    #echo ${!UPLOAD_SERVICES[@]}
    echo oshi.at transfer.sh free.keep.sh
}

# returns URL for the given service domain
function uploadServiceURL() {
    echo ${UPLOAD_SERVICES[$1]}
}

# returns the first available (reachable) service
function uploadServiceFind() {
    local SERVICE
    local URL
    for SERVICE in `uploadServiceList`; do
        URL=$( uploadServiceURL $SERVICE )
        #ping -c 1 "$SERVICE" &> /dev/null && echo "$SERVICE" && return 0
        # turns out ping is not enough and better try to access port 443 directly
        curl -s $URL &> /dev/null && echo "$SERVICE" && return 0
    done
    return 1
}

# parse URL of the uploaded file from the output of a given service
function uploadServiceParseURL() {
    local FILENAME=$3
    local CAT
    local URL
    [ -z "$1" -o "$1" == "-" ] && CAT="cat" || CAT="cat $1"
    if [ "$2" == "oshi.at" ]; then
        # oshi.at will shorten URL but we can append required filename at the end of the download link
        URL=$( $CAT | grep ' \[Download\]' | grep -o 'https:[^" ]*' | head -1 )
	echo $URL/$FILENAME
    else
        $CAT | grep -o 'https:[^" ]*' | head -1
    fi
}

# uploads a file to the given service and prints URL to the downloaded file
function uploadServiceUpload() {
    local SERVICE="$1"
    local FILE="$2"
    local NAME=$( basename $FILE )
    local URL=$( uploadServiceURL $1 )
    curl -s --upload-file $FILE $URL | uploadServiceParseURL - $1 $NAME
}
