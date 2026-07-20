#!/usr/bin/env python3
"""Export a Borg UI instance's stored license as an importable entitlement document.

Borg UI keeps its plan in a signed entitlement in its own database and offers no
export path over the API (`/system/info` returns a summary without payload and
signature). This reads the three columns that make up the document straight from
`licensing_state` and prints them in the shape `POST /api/system/licensing/import`
expects — the same shape `borgUI.licensing.entitlement.existingSecret` holds.

Runs INSIDE the UI pod, where the database credentials already live; pipe it in:

    KUBECONFIG=~/.kube/config.styxnet kubectl -n borg exec -i deploy/k8s-borg-ui -c ui \
      -- python3 - < scripts/dump-entitlement.py > entitlement-styxnet.json

The identifying line goes to stderr, the document to stdout, so the redirect above
yields a clean file. Read-only; picks Postgres when DB_HOST is set, else the
SQLite file under DATA_DIR.

The document is bound to the instance_id it was issued for and will NOT import
into a different instance. It is also a secret in its own right — it activates
the license on any instance carrying that id, so keep it out of git.
"""

from __future__ import annotations

import json
import os
import sys

COLS = "instance_id, payload_json, signature, key_id, status, plan, expires_at"


def fetch_row():
    if os.environ.get("DB_HOST"):
        from sqlalchemy import create_engine, text

        env = os.environ
        url = "postgresql+psycopg://{}:{}@{}:{}/{}".format(
            env["DB_USER"],
            env["DB_PASSWORD"],
            env["DB_HOST"],
            env.get("DB_PORT", "5432"),
            env["DB_NAME"],
        )
        with create_engine(url).connect() as conn:
            return conn.execute(text(f"select {COLS} from licensing_state")).fetchone()

    import sqlite3

    path = os.path.join(os.environ.get("DATA_DIR", "/data"), "borg.db")
    return sqlite3.connect(path).execute(f"select {COLS} from licensing_state").fetchone()


def main() -> None:
    row = fetch_row()
    if row is None:
        sys.exit("no licensing_state row — this instance has never been licensed")

    instance_id, payload, signature, key_id, status, plan, expires_at = row
    if not payload or not signature:
        sys.exit(f"nothing to export: status={status}, plan={plan} (no signed entitlement stored)")

    # Postgres hands back a dict (JSON column), SQLite the raw text.
    if isinstance(payload, (str, bytes)):
        payload = json.loads(payload)

    document = {"payload": payload, "signature": signature}
    if key_id:
        document["key_id"] = key_id

    print(
        f"instance_id={instance_id} status={status} plan={plan} expires_at={expires_at}",
        file=sys.stderr,
    )
    print(json.dumps(document, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
