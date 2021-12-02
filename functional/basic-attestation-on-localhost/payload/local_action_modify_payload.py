import os
import ast
import keylime.secure_mount as secure_mount
from keylime import keylime_logging
from keylime import ca_util

logger = keylime_logging.init_logging("local_action_rm_ssh")

async def execute(event):
    if event.get("type") != "revocation":
        return

    metadata = event.get("meta_data", {})
    if isinstance(metadata, str):
        metadata = ast.literal_eval(metadata)

    serial = metadata.get("cert_serial")
    if serial is None:
        logger.error("Unsupported revocation message: %s", event)

    # load up my own cert
    uuid = event.get("agent_id", "my")
    secdir = secure_mount.mount()
    cert = ca_util.load_cert_by_path(f"{secdir}/unzipped/{uuid}-cert.crt")
    logger.info("A node in the network has been compromised: %s", event["ip"])
    logger.info("my serial: %s, cert serial: %s" % (serial, cert.serial_number))
    # is this revocation meant for me?
    if serial == cert.serial_number:
        os.remove("/var/tmp/test_payload_file")
