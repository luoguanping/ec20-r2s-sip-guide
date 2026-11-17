#!/usr/bin/python3
import re
import sys
from pathlib import Path

state = Path("/var/lib/sip-sms-relay")
for line in sys.stdin:
    if not line.strip():
        break
print('GET VARIABLE MESSAGE(body)', flush=True)
reply = sys.stdin.readline().strip()
match = re.fullmatch(r"200 result=1 \(ACK\s+([0-9a-f]{16})\s*\)", reply, flags=re.IGNORECASE)
if match:
    pending = state / "pending" / match[1].lower()
    try:
        message_id = pending.read_text().strip()
    except FileNotFoundError:
        sys.exit(0)
    if re.fullmatch(r"[0-9a-f]{64}", message_id):
        (state / "confirmed" / message_id).touch(mode=0o600)
