"""Independent URLSession PUT receiver: python LFSUploadServer.py [ready-file].

Uses only Python's standard library; no NIO or Swift HTTP implementation.
Returns the wire headers, body count and digest for transport assertions.
"""

import hashlib
import http.server
import json
import pathlib
import socket
import sys


class PutHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_expect_100(self):
        return super().handle_expect_100()

    def do_GET(self):
        self.respond(dict((key.lower(), value) for key, value in self.headers.items()),
                     0, hashlib.sha256(), 200)

    def do_PUT(self):
        headers = dict((key.lower(), value) for key, value in self.headers.items())
        self.connection.settimeout(5)
        received = 0
        digest = hashlib.sha256()

        def read_body(count):
            nonlocal received
            while count:
                chunk = self.rfile.read1(min(count, 64 * 1024))
                if not chunk:
                    raise EOFError("connection ended before request body")
                count -= len(chunk)
                received += len(chunk)
                digest.update(chunk)

        status = 200
        try:
            if "transfer-encoding" in headers:
                if headers["transfer-encoding"].lower() != "chunked" or "content-length" in headers:
                    raise ValueError("conflicting or unsupported request framing")
                while True:
                    line = self.rfile.readline()
                    size = int(line.split(b";", 1)[0], 16)
                    if size == 0:
                        while True:
                            trailer = self.rfile.readline()
                            if not trailer:
                                raise EOFError("connection ended before trailers")
                            if trailer == b"\r\n":
                                break
                        break
                    read_body(size)
                    if self.rfile.read(2) != b"\r\n":
                        raise ValueError("invalid chunk terminator")
            else:
                read_body(int(headers["content-length"]))
        except (socket.timeout, EOFError, ValueError, KeyError):
            status = 408
        self.respond(headers, received, digest, status)

    def respond(self, headers, received, digest, status):
        response = json.dumps({"headers": headers, "received": received, "sha256": digest.hexdigest(),
                               "method": self.command}).encode()
        if self.path in ("/redirect307", "/redirect303"):
            status = int(self.path[-3:])
        self.send_response(status)
        if status in (303, 307):
            self.send_header("Location", "/target")
        self.send_header("Content-Length", str(len(response)))
        self.send_header("Content-Type", "application/json")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(response)
        self.close_connection = True


with http.server.ThreadingHTTPServer(("127.0.0.1", 0), PutHandler) as server:
    endpoint = "http://127.0.0.1:" + str(server.server_port)
    if len(sys.argv) > 1:
        pathlib.Path(sys.argv[1]).write_text(endpoint, encoding="utf-8")
    print(endpoint, flush=True)
    server.serve_forever()
