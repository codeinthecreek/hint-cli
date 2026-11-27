#!/usr/bin/env python3
"""Stub of Ollama's /api/chat endpoint for testing `hint`.

  stub_ollama.py PORT_FILE REQUEST_FILE

Binds to a free port on 127.0.0.1 and writes the port number to PORT_FILE.
Each request body is saved to REQUEST_FILE (the last one wins). The reply
content is read from the file named by STUB_REPLY_FILE at request time, so a
test can change it between calls without restarting the server. A reply file
starting with "!error " makes the stub answer 404 with that error message, as
Ollama does for an unknown model. A reply file starting with "!sleep N" waits N
seconds before answering (for timeout tests). If STUB_THINKING_FILE names a
file, its text is sent as the reply's thinking (as a thinking model's is).
"""
import http.server
import json
import os
import sys
import time

port_file, request_file = sys.argv[1], sys.argv[2]


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(request_file, "wb") as f:
            f.write(raw)
        if self.path != "/api/chat":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b'{"error":"not found"}')
            return
        with open(os.environ["STUB_REPLY_FILE"]) as f:
            content = f.read()
        if content.startswith("!sleep "):
            time.sleep(float(content.split()[1]))
            content = ""
        if content.startswith("!error "):
            body = json.dumps({"error": content[7:].strip()}).encode()
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        message = {"role": "assistant", "content": content}
        tf = os.environ.get("STUB_THINKING_FILE")
        if tf and os.path.exists(tf):
            with open(tf) as f:
                message["thinking"] = f.read()
        body = json.dumps({"message": message, "done": True}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.replace(port_file + ".tmp", port_file)
server.serve_forever()
