#!/usr/bin/env python3
"""A local stand-in for GitHub's releases endpoint, for tests/test_update*.sh and tests/test_no_network.sh.

  python3 release_server.py DIR

DIR holds cert.pem and key.pem (the test mints them with openssl: one self-signed leaf, IP SAN 127.0.0.1,
CA:TRUE) and the named pipe DIR/ready, which the test holds open. The server listens on 127.0.0.1 over HTTPS on a
free port, writes the port and a newline to DIR/ready once it is listening (the test blocks on that read; there is no
polling), and for
every request appends one JSON line to DIR/requests.log: {"path", "headers"}. It answers from DIR/answer.json
(re-read on every request, so a test swaps the answer between runs):

  {"status": 200, "type": "application/json", "body": "{...}", "headers": {"Name": "value"},
   "delay": 0.0, "wait_for": "/path/to/file", "repeat": ["[", 200000], "location": "/trap"}

wait_for holds the answer back until that file exists (at most 60 s): a test proves a command does not wait for
the server without measuring time. body is sent as given; repeat sends string*count instead (a huge or deeply nested body). Anything not set
defaults to status 200, type application/json, body "{}". Nothing here reaches a network beyond loopback.

A path under /download/ is a release asset: the file DIR/download/<the rest of the path> (404 when there is none),
type application/octet-stream, unless DIR/download-answer.json exists, which has the same keys as answer.json and
replaces the answer for every /download/ request (a redirect, a 500, a held or oversized body).
"""
import faulthandler
import json
import os
import ssl
import sys
import time
import socketserver
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # http.server's own server_bind asks socket.getfqdn() for the host's name, a reverse DNS lookup that can take
        # many seconds on a CI runner with no resolver for it: the fixture binds without ever asking.
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name, self.server_port = host, port


def main():
    d = os.path.abspath(sys.argv[1])
    # If startup ever stalls (a lookup, a handshake, a lock), the test's failure output shows where: every thread's stack,
    # written to this process's stderr (DIR/server.out) 15 s in, cancelled once the server is listening.
    faulthandler.dump_traceback_later(15, exit=False)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args):
            pass

        def do_GET(self):
            with open(os.path.join(d, "requests.log"), "a") as f:
                f.write(json.dumps({"path": self.path, "headers": {k: v for k, v in self.headers.items()}}) + "\n")
            asset = self.path.startswith("/download/")
            try:
                a = json.load(open(os.path.join(d, "download-answer.json" if asset and os.path.exists(os.path.join(d, "download-answer.json")) else "answer.json")))
            except (OSError, ValueError):
                a = {}
            if asset and not os.path.exists(os.path.join(d, "download-answer.json")):
                rel = os.path.normpath(self.path[len("/download/"):].split("?")[0])
                f = os.path.join(d, "download", rel)
                if rel.startswith("..") or not os.path.isfile(f):
                    a = {"status": 404, "type": "text/plain", "body": "not found"}
                else:
                    a = {"status": 200, "type": "application/octet-stream", "file": f}
            if a.get("delay"):
                time.sleep(float(a["delay"]))
            if a.get("wait_for"):
                end = time.time() + 60
                while not os.path.exists(a["wait_for"]) and time.time() < end:
                    time.sleep(0.05)
            if a.get("file"):
                data = open(a["file"], "rb").read()
            else:
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
    server = Server(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    faulthandler.cancel_dump_traceback_later()
    with open(os.path.join(d, "ready"), "w") as f:  # the test opened the pipe's other end already: this never blocks
        f.write(str(server.server_address[1]) + "\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
