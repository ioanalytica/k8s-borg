#!/usr/bin/env python3
"""A stand-in for the parts of the Borg UI API that reconcile-borgui talks to.

Serves /health, GET /api/auth/me (200 for the PAT in FAKE_PAT), the admin login
and PAT routes, the notification CRUD routes and, for the tests that point
K8S_API here, merge-patch and get of the reconcile-status ConfigMap and the PAT
Secret. Channels and k8s objects are kept in memory.

  FAKE_DIR            directory for the port file, the request log and the
                      final channel state
  FAKE_PAT            the only bearer token that authenticates
  FAKE_CHANNELS       JSON list of channels present at start
  FAKE_FAIL           comma-separated "METHOD path" routes that answer 422 and
                      echo the request body back, as FastAPI's validation
                      errors do (e.g. "POST /api/notifications")
  FAKE_FAIL_CODE      status of those answers instead of 422
  FAKE_FAIL_BODY      raw body of those answers instead of the echo
  FAKE_HEALTH         status /health answers (default 200)
  FAKE_ADMIN_PASS     the admin password the login accepts (default "admin-pw");
                      a login hands out the bearer token "jwt-1", and a minted
                      PAT is "new-pat"
  FAKE_SA_TOKEN       the bearer token the k8s routes accept (default "sa-token")

Every request is appended to FAKE_DIR/requests as one JSON line
{method, path, body}; the channel list is written to FAKE_DIR/channels.json
after every change, a k8s object to FAKE_DIR/k8s-<resource>-<name>.json.
"""
import json
import os
import re
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.environ["FAKE_DIR"]
PAT = os.environ.get("FAKE_PAT", "good-pat")
FAIL = {r.strip() for r in os.environ.get("FAKE_FAIL", "").split(",") if r.strip()}
FAIL_CODE = int(os.environ.get("FAKE_FAIL_CODE") or 422)
FAIL_BODY = os.environ.get("FAKE_FAIL_BODY")
HEALTH = int(os.environ.get("FAKE_HEALTH") or 200)
ADMIN_PASS = os.environ.get("FAKE_ADMIN_PASS", "admin-pw")
SA_TOKEN = os.environ.get("FAKE_SA_TOKEN", "sa-token")
K8S = re.compile(r"^/api/v1/namespaces/[^/]+/(configmaps|secrets)/([^/]+)$")
k8s = {}

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


def merge(target, patch):  # RFC 7386: null removes a key
    for k, v in patch.items():
        if v is None:
            target.pop(k, None)
        elif isinstance(v, dict):
            merge(target.setdefault(k, {}), v)
        else:
            target[k] = v


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

    def fail(self, body):
        if FAIL_BODY is not None:
            data = FAIL_BODY.encode()
            self.send_response(FAIL_CODE)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            return self.wfile.write(data)
        return self.reply(FAIL_CODE, {"detail": [{"msg": "invalid", "input": body}]})

    def handle_any(self, method):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode() if length else ""
        if self.headers.get("Content-Type") == "application/x-www-form-urlencoded":
            body = dict(urllib.parse.parse_qsl(raw))
        else:
            body = json.loads(raw) if raw else None
        path = self.path.split("?", 1)[0]
        with open(os.path.join(DIR, "requests"), "a") as f:
            f.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")

        if path == "/health":
            return self.reply(HEALTH, {"status": "ok"} if HEALTH == 200 else {"detail": "starting"})

        m = K8S.match(path)
        if m:
            if self.headers.get("Authorization") != "Bearer " + SA_TOKEN:
                return self.reply(401, {"kind": "Status", "message": "Unauthorized"})
            if (method + " " + path) in FAIL:
                return self.fail(body)
            key = "k8s-%s-%s.json" % m.groups()
            if method == "PATCH":
                merge(k8s.setdefault(key, {}), body)
                with open(os.path.join(DIR, key), "w") as f:
                    json.dump(k8s[key], f)
            if key not in k8s:
                return self.reply(404, {"kind": "Status", "message": "not found"})
            return self.reply(200, k8s[key])

        if path == "/api/auth/login" and method == "POST":
            if (method + " " + path) in FAIL:
                return self.fail(body)
            if body.get("password") == ADMIN_PASS:
                return self.reply(200, {"access_token": "jwt-1"})
            return self.reply(401, {"detail": {"key": "backend.errors.auth.invalidCredentials"}})
        if self.headers.get("Authorization") not in ("Bearer " + PAT, "Bearer jwt-1"):
            return self.reply(401, {"detail": "unauthorized"})
        if path == "/api/auth/me":
            return self.reply(200, {"username": "admin"})

        route = method + " " + ("/api/notifications" if path == "/api/notifications" else
                                "/api/notifications/{id}" if path.startswith("/api/notifications/") else path)
        if route in FAIL or (method + " " + path) in FAIL:
            return self.fail(body)

        if route == "GET /api/settings/tokens":
            return self.reply(200, [])
        if route == "POST /api/settings/tokens":
            return self.reply(200, {"token": "new-pat"})
        if route in ("POST /api/auth/password-setup/skip", "PUT /api/settings/system",
                     "PUT /api/settings/cache/settings"):
            return self.reply(200, {})

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

    def do_PATCH(self):
        self.handle_any("PATCH")


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
save()
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
