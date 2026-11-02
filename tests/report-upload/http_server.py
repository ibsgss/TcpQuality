"""Local report API fixture. Never contacts the public report service."""
import json
import socket
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

fixture = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        payload = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        (fixture / "received.csv").write_bytes(payload)
        if self.path == "/disconnect":
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        if self.path == "/timeout":
            time.sleep(1)
        status = 400 if self.path == "/http400" else 200
        if self.path == "/http400":
            response = {"error": "invalid CSV columns"}
        elif self.path == "/missing-url":
            response = {"id": "fixture"}
        else:
            response = {"id": "fixture", "url": "http://127.0.0.1/report/fixture"}
        body = json.dumps(response, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(fixture / "port").write_text(str(server.server_port))
server.serve_forever()
