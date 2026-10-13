#!/usr/bin/env python3
"""A read-only stand-in for the Kubernetes API: GET answers with the JSON
file FAKE_DIR/objects/<request path>.json, 404 when there is none.

  FAKE_DIR       directory for the objects, the port file and the request log
  FAKE_SA_TOKEN  the only bearer token that authenticates (default "sa-token");
                 any other request gets 401

The port it listens on (127.0.0.1) is written to FAKE_DIR/port once it is up;
every request is appended to FAKE_DIR/requests as "METHOD path".
"""
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ["FAKE_DIR"]
TOKEN = os.environ.get("FAKE_SA_TOKEN", "sa-token")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        with open(os.path.join(DIR, "requests"), "a") as log:
            log.write("GET %s\n" % self.path)
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            return self.answer(401, '{"kind":"Status","code":401}')
        path = os.path.normpath(self.path.split("?", 1)[0]).lstrip("/")
        file = os.path.join(DIR, "objects", path + ".json")
        if ".." in path.split("/") or not os.path.isfile(file):
            return self.answer(404, '{"kind":"Status","code":404}')
        with open(file) as f:
            self.answer(200, f.read())


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
