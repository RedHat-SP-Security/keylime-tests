#!/usr/bin/python3

import os
import sys
import json
# need to do multiple attempts since we might be delivering
# payload scripts to old RHELs

mode = 'rb'
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        import toml as tomllib
        mode = 'r'

json_file = sys.argv[1]
with open(json_file, 'r') as f:
    input_json = json.load(f)

if input_json.get("type", "") != "revocation":
    sys.exit(0)

event_uuid = input_json.get("agent_id", "event_uuid")
event_ip = input_json.get("ip", "event_ip")
with open("/etc/keylime/agent.conf", mode) as f:
    my_uuid = tomllib.load(f)["agent"]["uuid"].strip('\"')

print("A node in the network has been compromised:", event_ip)
print("my UUID: %s, event UUID: %s" % (my_uuid, event_uuid))

# is this revocation meant for me?
if my_uuid == event_uuid:
    os.remove("/var/tmp/test_payload_file")
