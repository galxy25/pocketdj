"""PocketDJ inbound mail forwarder.

SES receives mail for pocket-dj.com, writes the raw MIME to S3, then invokes this
function. We re-send the message to FORWARD_TO via SES.

Why the From header is rewritten: we cannot send as the original sender. SES will
only send From an identity we own, and even if it would, SPF/DKIM for the sender's
domain do not authorise our servers — the forward would fail authentication and land
in spam. So we send From MAIL_FROM (a pocket-dj.com address, DKIM-signed by us) and
set Reply-To to the original sender, so replying reaches the right person.

The original From is preserved in the subject prefix and an X-Original-From header
so nothing is lost.
"""

import os
import boto3
from email import message_from_bytes
from email.utils import parseaddr

s3 = boto3.client("s3")
ses = boto3.client("ses")

BUCKET = os.environ["MAIL_BUCKET"]
FORWARD_TO = os.environ["FORWARD_TO"]
MAIL_FROM = os.environ["MAIL_FROM"]

# Headers that must not survive the re-send: they either identify the old envelope
# or would make the forwarded copy fail DKIM verification against our signature.
STRIP = {
    "return-path", "sender", "message-id", "dkim-signature",
    "domainkey-signature", "authentication-results",
    "received-spf", "arc-authentication-results", "arc-message-signature", "arc-seal",
    "from", "reply-to", "to", "cc", "bcc",
}


def lambda_handler(event, context):
    results = []
    for record in event.get("Records", []):
        ses_data = record.get("ses", {})
        message_id = ses_data.get("mail", {}).get("messageId")
        if not message_id:
            continue

        receipt = ses_data.get("receipt", {})
        verdicts = {
            k: receipt.get(f"{k}Verdict", {}).get("status")
            for k in ("spam", "virus", "spf", "dkim", "dmarc")
        }

        # Drop mail SES flagged as spam or carrying a virus. Forwarding it would
        # relay it under our own DKIM signature, which harms domain reputation.
        if verdicts.get("spam") == "FAIL" or verdicts.get("virus") == "FAIL":
            results.append({"messageId": message_id, "action": "dropped", "verdicts": verdicts})
            continue

        key = f"inbound/{message_id}"
        raw = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        msg = message_from_bytes(raw)

        original_from = msg.get("From", "unknown sender")
        original_to = msg.get("To", "")
        _, sender_addr = parseaddr(original_from)
        subject = msg.get("Subject", "(no subject)")

        for header in list(msg.keys()):
            if header.lower() in STRIP:
                del msg[header]

        msg["From"] = MAIL_FROM
        msg["To"] = FORWARD_TO
        # Reply goes to whoever actually wrote in, not to our forwarder address.
        if sender_addr:
            msg["Reply-To"] = sender_addr
        msg["X-Original-From"] = original_from
        msg["X-Original-To"] = original_to
        msg["X-SES-Verdicts"] = ", ".join(f"{k}={v}" for k, v in verdicts.items())

        del msg["Subject"]
        # Keep the destination alias visible — it says which address was written to
        # (dmca@, abuse@, privacy@), which is the whole point of having several.
        msg["Subject"] = f"[{original_to or 'pocket-dj'}] {subject}"

        ses.send_raw_email(
            Source=MAIL_FROM,
            Destinations=[FORWARD_TO],
            RawMessage={"Data": msg.as_bytes()},
        )
        results.append({"messageId": message_id, "action": "forwarded", "to": FORWARD_TO})

    return {"results": results}
