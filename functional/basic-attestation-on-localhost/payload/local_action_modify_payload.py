import os
import ast
import keylime.secure_mount as secure_mount
from keylime import keylime_logging
from keylime import ca_util
from keylime import config

logger = keylime_logging.init_logging("local_action_rm_ssh")

async def execute(event):
    if event.get("type") != "revocation":
        return

    # load up my own cert
    event_uuid = event.get("agent_id", "my")
    my_uuid = config.get('cloud_agent', 'agent_uuid')
    logger.info("A node in the network has been compromised: %s", event["ip"])
    logger.info("my UUID: %s, event UUID: %s" % (my_uuid, event_uuid))
    # is this revocation meant for me?
    if my_uuid == event_uuid:
        os.remove("/var/tmp/test_payload_file")
