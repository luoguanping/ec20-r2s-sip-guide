import base64
import json
import hashlib
import hmac
import re
import os
import socket
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

PEER = "10.77.38.2"
BIND = "10.77.38.1"
PORT = 8765
STATE = Path("/var/lib/sip-sms-relay")
SECRET = (Path(os.environ["CREDENTIALS_DIRECTORY"]) / "ami.secret").read_text().strip()

def registered():
    result = subprocess.run(
        ["/usr/sbin/asterisk", "-rx", "pjsip show contacts"],
        capture_output=True, text=True, timeout=3, check=True,
    )
    return any(line.strip().startswith("Contact:  7001/") for line in result.stdout.splitlines())

def send_message(body):
    encoded = base64.b64encode(body.encode()).decode("ascii")
    with socket.create_connection(("127.0.0.1", 5038), timeout=4) as conn:
        with conn.makefile("rb") as stream:
            if not stream.readline().startswith(b"Asterisk Call Manager/"):
                raise OSError("AMI unavailable")
            def action(headers):
                conn.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())
                result = []
                for line in stream:
                    if line == b"\r\n":
                        break
                    result.append(line.rstrip(b"\r\n"))
                if b"Response: Success" not in result:
                    raise OSError("AMI rejected request")
            action(("Action: Login", "Username: sms-relay", "Secret: " + SECRET, "Events: off"))
            action(("Action: MessageSend", "Destination: pjsip:7001",
                    "From: R2S SMS <sip:sms@sip.example.net>", "Base64Body: " + encoded))

def decode_sms(data):
    if not isinstance(data, dict) or not isinstance(data.get("sender"), str):
        raise ValueError("No SMS sender")
    if "ucs-2" in data:
        text = bytes.fromhex(data["ucs-2"]).decode("utf-16-be")
    else:
        text = data["text"]
    if not isinstance(text, str) or not text.strip() or "\x00" in text:
        raise ValueError("Invalid message content")
    sender = " ".join(data["sender"].split())[:64]
    stamp = str(data.get("timestamp", ""))[:40]
    return f"SIM 短信来自 {sender}\n{stamp}\n\n{text}"

class Relay(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(8)
        super().setup()

    def log_message(self, format, *args):
        pass

    def reply(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.client_address[0] != PEER:
            return self.reply(403)
        match = re.fullmatch(r"/ack/([0-9a-f]{64})", self.path)
        if match:
            return self.reply(204 if (STATE / "confirmed" / match[1]).is_file() else 404)
        if self.path != "/ready":
            return self.reply(404)
        try:
            self.reply(204 if registered() else 503)
        except (OSError, subprocess.SubprocessError):
            self.reply(503)

    def do_POST(self):
        if self.client_address[0] != PEER:
            return self.reply(403)
        if self.path != "/sms":
            return self.reply(404)
        try:
            size = int(self.headers.get("Content-Length", "0"))
            if not 1 <= size <= 4096:
                return self.reply(413)
            data = self.rfile.read(size)
            sms = decode_sms(json.loads(data))
            message_id = hashlib.sha256(data).hexdigest()
            token = hmac.new(SECRET.encode(), data, hashlib.sha256).hexdigest()[:16]
        except (ValueError, TypeError, KeyError):
            return self.reply(422)
        try:
            if not registered():
                return self.reply(503)
            (STATE / "pending" / token).write_text(message_id + "\n")
            send_message(sms + "\n\n确认收到请回复：ACK " + token)
        except (OSError, subprocess.SubprocessError):
            return self.reply(503)
        self.reply(204)

HTTPServer((BIND, PORT), Relay).serve_forever()
