#!/usr/bin/env python3
"""A stand-in for the replication side of a Redis or Valkey server, for
redis-rdb-sync: AUTH, INFO server, REPLCONF and SYNC, one connection at a time.

  FAKE_DIR            directory for the port file and the command log
  FAKE_PAYLOAD        file whose bytes SYNC sends as the RDB file
  FAKE_FRAMING        "len" ($<size>, the default) or "eof" ($EOF:<mark>, as a
                      diskless sync sends it)
  FAKE_CHUNK          bytes per write of the payload (default: all at once);
                      small values split the EOF mark across reads
  FAKE_KEEPALIVES     bare newlines sent before the SYNC answer (default 0)
  FAKE_CUT            send only this many bytes of the payload, then close
  FAKE_SYNC_ERROR     answer SYNC with this error instead
  FAKE_PASSWORD       the password AUTH accepts (with FAKE_USER: that user's);
                      without it AUTH is refused as on a server without one
  FAKE_USER           the user AUTH accepts
  FAKE_VALKEY_VERSION valkey_version in INFO server; without it a Redis
  FAKE_NEEDS_VERSION  refuse SYNC unless REPLCONF version announced at least
                      this one (Valkey 9 with its new types)
  FAKE_TLS_CERT, FAKE_TLS_KEY
                      speak TLS with this certificate and key

Every command is appended to FAKE_DIR/commands as one JSON list per line, the
password replaced by "***".
"""
import json
import os
import socket
import ssl

DIR = os.environ["FAKE_DIR"]
PAYLOAD = open(os.environ["FAKE_PAYLOAD"], "rb").read() if os.environ.get("FAKE_PAYLOAD") else b""
FRAMING = os.environ.get("FAKE_FRAMING", "len")
CHUNK = int(os.environ.get("FAKE_CHUNK") or 0) or max(len(PAYLOAD), 1)
KEEPALIVES = int(os.environ.get("FAKE_KEEPALIVES") or 0)
CUT = os.environ.get("FAKE_CUT")
SYNC_ERROR = os.environ.get("FAKE_SYNC_ERROR")
PASSWORD = os.environ.get("FAKE_PASSWORD")
USER = os.environ.get("FAKE_USER")
VALKEY = os.environ.get("FAKE_VALKEY_VERSION")
NEEDS = os.environ.get("FAKE_NEEDS_VERSION")
MARK = b"0123456789abcdef0123456789abcdef01234567"


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def log(cmd):
    with open(os.path.join(DIR, "commands"), "a") as f:
        f.write(json.dumps(cmd) + "\n")


def read_command(f):
    line = f.readline()
    if not line:
        return None
    line = line.rstrip(b"\r\n")
    if not line.startswith(b"*"):
        return line.decode().split()   # inline: SYNC
    args = []
    for _ in range(int(line[1:])):
        n = int(f.readline()[1:])
        args.append(f.read(n + 2)[:n].decode())
    return args


def serve(conn):
    f = conn.makefile("rb")
    authed = PASSWORD is None
    announced = None
    while True:
        cmd = read_command(f)
        if cmd is None:
            return
        name = cmd[0].upper()
        log(["AUTH"] + cmd[1:-1] + ["***"] if name == "AUTH" else cmd)
        if name == "AUTH":
            user = cmd[1] if len(cmd) == 3 else "default"
            if PASSWORD is None:
                conn.sendall(b"-ERR AUTH <password> called without any password configured\r\n")
            elif cmd[-1] == PASSWORD and user == (USER or "default"):
                authed = True
                conn.sendall(b"+OK\r\n")
            else:
                conn.sendall(b"-WRONGPASS invalid username-password pair or user is disabled.\r\n")
        elif not authed:
            conn.sendall(b"-NOAUTH Authentication required.\r\n")
        elif name == "INFO":
            body = b"# Server\r\nredis_version:7.2.4\r\n"
            if VALKEY:
                body += b"valkey_version:%s\r\n" % VALKEY.encode()
            conn.sendall(b"$%d\r\n%s\r\n" % (len(body), body))
        elif name == "REPLCONF":
            if cmd[1].lower() == "version":
                announced = cmd[2]
            conn.sendall(b"+OK\r\n")
        elif name == "SYNC":
            if SYNC_ERROR:
                conn.sendall(b"-%s\r\n" % SYNC_ERROR.encode())
                continue
            if NEEDS and (announced is None or vtuple(announced) < vtuple(NEEDS)):
                conn.close()   # what Valkey 9 does: the fork fails, the link drops
                return
            conn.sendall(b"\n" * KEEPALIVES)
            data = PAYLOAD[:int(CUT)] if CUT else PAYLOAD
            if FRAMING == "eof":
                conn.sendall(b"$EOF:" + MARK + b"\r\n")
                data = data if CUT else data + MARK
            else:
                conn.sendall(b"$%d\r\n" % len(PAYLOAD))
            for i in range(0, len(data), CHUNK):
                conn.sendall(data[i:i + CHUNK])
            if CUT:
                conn.close()
                return
        else:
            conn.sendall(b"-ERR unknown command '%s'\r\n" % name.encode())


def main():
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    with open(os.path.join(DIR, "port.tmp"), "w") as f:
        f.write(str(srv.getsockname()[1]))
    os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
    tls = None
    if os.environ.get("FAKE_TLS_CERT"):
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(os.environ["FAKE_TLS_CERT"], os.environ["FAKE_TLS_KEY"])
    while True:
        conn, _ = srv.accept()
        try:
            if tls:
                conn = tls.wrap_socket(conn, server_side=True)
            serve(conn)
        except OSError:  # a client that refused the certificate included
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
