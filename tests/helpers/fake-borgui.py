#!/usr/bin/env python3
"""A stand-in for the parts of the Borg UI API that reconcile-borgui talks to.

Serves /health, GET /api/auth/me (200 for the PAT in FAKE_PAT) and the
notification CRUD routes, keeping the channels in memory like the server does.

  FAKE_DIR            directory for the port file, the request log and the
                      final channel state
  FAKE_PAT            the only bearer token that authenticates
  FAKE_CHANNELS       JSON list of channels present at start
  FAKE_FAIL           comma-separated "METHOD path" routes that answer 422 and
                      echo the request body back, as FastAPI's validation
                      errors do (e.g. "POST /api/notifications")

Every request is appended to FAKE_DIR/requests as one JSON line
{method, path, body}; the channel list is written to FAKE_DIR/channels.json
after every change.
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ["FAKE_DIR"]
PAT = os.environ.get("FAKE_PAT", "good-pat")
FAIL = {r.strip() for r in os.environ.get("FAKE_FAIL", "").split(",") if r.strip()}

DEFAULTS = {
    "enabled": True,
    "title_prefix": None,
    "include_job_name_in_title": False,
    "notify_on_backup_start": False,
    "notify_on_backup_success": False,
    "notify_on_backup_warning": False,
    "notify_on_backup_failure": True,
    "notify_on_restore_success": False,
    "notify_on_restore_failure": True,
    "notify_on_check_success": False,
    "notify_on_check_failure": True,
    "notify_on_restore_check_success": False,
    "notify_on_restore_check_failure": True,
    "notify_on_schedule_failure": True,
    "notify_on_stale_backup": True,
    "notify_on_backup_report": True,
    "monitor_all_repositories": True,
}

channels = []
for i, c in enumerate(json.loads(os.environ.get("FAKE_CHANNELS") or "[]"), start=1):
    channels.append({"id": c.get("id", i), **DEFAULTS, "repositories": [], **c})


def save():
    with open(os.path.join(DIR, "channels.json"), "w") as f:
        json.dump(channels, f)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, payload=None):
        body = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        body = json.loads(raw) if raw else None
        path = self.path.split("?", 1)[0]
        with open(os.path.join(DIR, "requests"), "a") as f:
            f.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")

        if path == "/health":
            return self.reply(200, {"status": "ok"})
        if self.headers.get("Authorization") != "Bearer " + PAT:
            return self.reply(401, {"detail": "unauthorized"})
        if path == "/api/auth/me":
            return self.reply(200, {"username": "admin"})

        route = method + " " + ("/api/notifications" if path == "/api/notifications" else
                                "/api/notifications/{id}" if path.startswith("/api/notifications/") else path)
        if route in FAIL or (method + " " + path) in FAIL:
            return self.reply(422, {"detail": [{"msg": "invalid", "input": body}]})

        if route == "GET /api/notifications":
            return self.reply(200, channels)
        if route == "POST /api/notifications":
            new = {"id": max([c["id"] for c in channels] or [0]) + 1, **DEFAULTS,
                   "repositories": [], **{k: v for k, v in body.items() if k != "repository_ids"}}
            channels.append(new)
            save()
            return self.reply(201, new)
        if route == "PUT /api/notifications/{id}":
            cid = int(path.rsplit("/", 1)[1])
            for c in channels:
                if c["id"] == cid:
                    c.update({k: v for k, v in body.items() if k != "repository_ids"})
                    save()
                    return self.reply(200, c)
            return self.reply(404, {"detail": "not found"})
        return self.reply(404, {"detail": "no such route"})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
save()
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
