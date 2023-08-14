#!/bin/bash

MY_UUID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

if [ ! -f "$1" ]; then
    echo "Input JSON file \"$1\" not found"
    exit 1
fi

TYPE=$(grep -o "\"type\":[ ]*\"\([^\"]*\)\"" "$1" | sed -e 's/\"type\":[ ]*\"\([^\"]*\)\"/\1/g')

if [ "$TYPE" != "revocation" ]; then
    echo "Input JSON type is not revocation"
    exit 1
fi

EVENT_UUID=$(grep -o "\"agent_id\":[ ]*\"\([^\"]*\)\"" "$1" | sed -e 's/\"agent_id\":[ ]*\"\([^\"]*\)\"/\1/g')
EVENT_IP=$(grep -o "\"ip\":[ ]*\"\([^\"]*\)\"" "$1" | sed -e 's/\"ip\":[ ]*\"\([^\"]*\)\"/\1/g')

echo "A node in the network has been compromised: $EVENT_IP"
echo "my UUID: $MY_UUID, event UUID: $EVENT_UUID"

# is this revocation meant for me?
if [[ "$MY_UUID" == "$EVENT_UUID" ]]; then
    rm /var/lib/keylime/test_payload_file
fi
