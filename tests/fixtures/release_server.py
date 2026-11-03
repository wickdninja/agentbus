#!/usr/bin/env python3
"""A local stand-in for GitHub's releases endpoint, for tests/test_update*.sh and tests/test_no_network.sh.

  python3 release_server.py DIR

DIR holds cert.pem and key.pem (the test mints them with openssl: one self-signed leaf, IP SAN 127.0.0.1,
CA:TRUE). The server listens on 127.0.0.1 over HTTPS on a free port, writes the port to DIR/port, and for
every request appends one JSON line to DIR/requests.log: {"path", "headers"}. It answers from DIR/answer.json
(re-read on every request, so a test swaps the answer between runs):

  {"status": 200, "type": "application/json", "body": "{...}", "headers": {"Name": "value"},
   "delay": 0.0, "wait_for": "/path/to/file", "repeat": ["[", 200000], "location": "/trap"}

wait_for holds the answer back until that file exists (at most 60 s): a test proves a command does not wait for
the server without measuring time. body is sent as given; repeat sends string*count instead (a huge or deeply nested body). Anything not set
defaults to status 200, type application/json, body "{}". Nothing here reaches a network beyond loopback.
"""
import json
import os
import ssl
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def main():
    d = os.path.abspath(sys.argv[1])

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            with open(os.path.join(d, "requests.log"), "a") as f:
                f.write(json.dumps({"path": self.path, "headers": {k: v for k, v in self.headers.items()}}) + "\n")
            try:
                a = json.load(open(os.path.join(d, "answer.json")))
            except (OSError, ValueError):
                a = {}
            if a.get("delay"):
                time.sleep(float(a["delay"]))
            if a.get("wait_for"):
                end = time.time() + 60
                while not os.path.exists(a["wait_for"]) and time.time() < end:
                    time.sleep(0.05)
            body = a["repeat"][0] * int(a["repeat"][1]) if a.get("repeat") else a.get("body", "{}")
            data = body.encode("utf-8")
            self.send_response(int(a.get("status", 200)))
            self.send_header("Content-Type", a.get("type", "application/json"))
            if a.get("location"):
                self.send_header("Location", a["location"])
            for k, v in (a.get("headers") or {}).items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(data)
            except OSError:
                pass

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(d, "cert.pem"), os.path.join(d, "key.pem"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    with open(os.path.join(d, "port.tmp"), "w") as f:
        f.write(str(server.server_address[1]))
    os.replace(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
    server.serve_forever()


if __name__ == "__main__":
    main()
