#!/usr/bin/env python3
"""
Relay server for Claude Code phone approval.

Serves the approve/deny page that brrr.now's open_url points to.
Writes decisions to .responses/ for notify.sh to poll.

Usage:
  ./relay.sh                        # port 9876
  RELAY_PORT=8080 ./relay.sh        # custom port

Listens on 0.0.0.0 so it's reachable via Tailscale IP.
"""

import http.server
import urllib.parse
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
RESPONSE_DIR = os.path.join(SCRIPT_DIR, ".responses")
PORT = int(os.environ.get("RELAY_PORT", 9876))

os.makedirs(RESPONSE_DIR, exist_ok=True)

APPROVE_HTML = """<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<title>Claude Code</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, system-ui, sans-serif;
    background: #0a0a0a; color: #e5e5e5;
    display: flex; flex-direction: column; align-items: center;
    justify-content: center; min-height: 100vh; padding: 24px;
  }
  .card {
    background: #1a1a1a; border: 1px solid #333; border-radius: 16px;
    padding: 32px 24px; max-width: 400px; width: 100%; text-align: center;
  }
  h1 { font-size: 20px; margin-bottom: 8px; }
  .tool { color: #a78bfa; font-family: monospace; font-size: 16px; margin: 12px 0; word-break: break-all; }
  .session { color: #666; font-size: 12px; margin-bottom: 24px; }
  .buttons { display: flex; gap: 12px; }
  button {
    flex: 1; padding: 16px; border: none; border-radius: 12px;
    font-size: 18px; font-weight: 600; cursor: pointer;
    transition: transform 0.1s;
  }
  button:active { transform: scale(0.95); }
  .allow { background: #22c55e; color: #000; }
  .deny { background: #ef4444; color: #fff; }
  .done { font-size: 48px; margin: 20px 0; }
  .input-section { margin: 16px 0; }
  textarea {
    width: 100%; padding: 12px; border-radius: 8px; border: 1px solid #333;
    background: #111; color: #e5e5e5; font-size: 14px; resize: vertical;
    min-height: 60px; font-family: inherit;
  }
  .send-btn {
    margin-top: 8px; background: #3b82f6; color: #fff;
    width: 100%; padding: 12px; border: none; border-radius: 8px;
    font-size: 16px; font-weight: 600; cursor: pointer;
  }
</style>
</head>
<body>
<div class="card" id="prompt">
  <h1>Permission Request</h1>
  <div class="tool">{{TOOL}}</div>
  <div class="session">Session: {{SESSION}}</div>
  <div class="buttons">
    <button class="deny" onclick="respond('deny')">Deny</button>
    <button class="allow" onclick="respond('allow')">Allow</button>
  </div>
  <div class="input-section">
    <textarea id="msg" placeholder="Optional message to Claude..."></textarea>
    <button class="send-btn" onclick="respond('message')">Send Message</button>
  </div>
</div>
<div class="card" id="result" style="display:none">
  <div class="done"></div>
  <p></p>
</div>
<script>
function respond(decision) {
  var msg = document.getElementById('msg').value;
  var body = decision === 'message' ? msg : decision;
  fetch('/respond?id={{REQUEST_ID}}', {
    method: 'POST',
    headers: {'Content-Type': 'text/plain'},
    body: body
  }).then(function() {
    document.getElementById('prompt').style.display = 'none';
    var r = document.getElementById('result');
    r.style.display = 'block';
    r.querySelector('.done').textContent = decision === 'allow' ? '\u2713' : decision === 'deny' ? '\u2717' : '\u2192';
    r.querySelector('p').textContent = decision === 'allow' ? 'Allowed' : decision === 'deny' ? 'Denied' : 'Sent';
  });
}
</script>
</body>
</html>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        params = dict(urllib.parse.parse_qsl(parsed.query))

        if parsed.path == "/approve":
            tool = params.get("tool", "unknown")
            session = params.get("session", "?")
            rid = params.get("id", "")
            html = (
                APPROVE_HTML.replace("{{TOOL}}", tool)
                .replace("{{SESSION}}", session)
                .replace("{{REQUEST_ID}}", rid)
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(html.encode())
        elif parsed.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        params = dict(urllib.parse.parse_qsl(parsed.query))
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode() if length else ""

        if parsed.path == "/respond":
            rid = params.get("id", "")
            if rid:
                with open(os.path.join(RESPONSE_DIR, rid), "w") as f:
                    f.write(body)
                print(f"  -> Decision for {rid}: {body}")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt, *args):
        print(f"  {self.address_string()} - {fmt % args}")


if __name__ == "__main__":
    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"Relay server listening on 0.0.0.0:{PORT}")
    print(f"Response dir: {RESPONSE_DIR}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()
