"""MongoDB side of the database tests, run with the image's pymongo (the
image has no MongoDB shell): as the server's root user, DB_PASSWORD.

  mongodb.py ready HOST              exit 0 once HOST answers
  mongodb.py initiate HOST           make HOST a single-member replica set
                                     (rs0) and wait for it to be primary
  mongodb.py seed HOST               the content a restore must bring back
  mongodb.py fingerprint HOST [DB]   what a restore of the instance (or of
                                     DB) must bring back
  mongodb.py run HOST [DB] CODE      exec CODE with `c` (the client) and `db`
  mongodb.py login HOST USER PW AUTHDB DB
                                     count DB.items as USER of AUTHDB
"""

import hashlib
import os
import sys
import time
import urllib.parse

import pymongo
from bson import Binary, Decimal128, json_util

PASSWORD = os.environ["DB_PASSWORD"]
SYSTEM_DATABASES = {"admin", "config", "local"}


def client(host, user="root", password=PASSWORD, auth_db="admin"):
    return pymongo.MongoClient(
        f"mongodb://{urllib.parse.quote(user, safe='')}:{urllib.parse.quote(password, safe='')}@{host}:27017/"
        f"?authSource={auth_db}&directConnection=true",
        serverSelectionTimeoutMS=5000,
    )


def canonical(doc):
    return json_util.dumps(doc, sort_keys=True, json_options=json_util.CANONICAL_JSON_OPTIONS)


def ready(host):
    client(host).admin.command("ping")


def initiate(host):
    c = client(host)
    try:
        c.admin.command("replSetInitiate", {"_id": "rs0", "members": [{"_id": 0, "host": f"{host}:27017"}]})
    except pymongo.errors.OperationFailure as e:
        if e.code != 23:  # AlreadyInitialized
            raise
    for _ in range(60):
        if c.admin.command("hello").get("isWritablePrimary"):
            return
        time.sleep(1)
    raise SystemExit(f"{host} did not become primary")


def seed(host):
    c = client(host)
    admin = c.admin
    # Users with passwords, a custom role, a user defined on a database.
    admin.command("createRole", "itemReader",
                  privileges=[{"resource": {"db": "appdb", "collection": "items"}, "actions": ["find"]}], roles=[])
    admin.command("createUser", "e2e_backup", pwd="backup-pw", roles=["backup"])
    admin.command("createUser", "e2e_restore", pwd="restore-pw", roles=["restore"])
    admin.command("createUser", "reader", pwd="reader-pw", roles=["itemReader"])
    app = c.appdb
    app.command("createUser", "app", pwd="app-pw", roles=[{"role": "readWrite", "db": "appdb"}])
    # Non-ASCII text and names, binary data, decimals, nested documents; a
    # unique, a compound, a partial and a TTL index; a validator, a capped
    # collection and a view.
    app.create_collection("items", validator={"$jsonSchema": {"required": ["name"]}})
    app.items.insert_many([
        {"_id": 1, "name": "Grüße aus Köln", "payload": Binary(b"\x00\xff\x7f\x80")},
        {"_id": 2, "name": "日本語のテキスト", "price": Decimal128("12.30"), "tags": ["a", "b"]},
        {"_id": 3, "name": "emoji 🐘 and a 'quote'", "nested": {"deep": {"er": [1, 2, {"x": None}]}}},
    ] + [{"_id": i, "name": f"row {i}", "n": i % 17} for i in range(4, 2004)])
    app.items.create_index("name", unique=True)
    app.items.create_index([("n", 1), ("_id", -1)], name="n_id")
    app.items.create_index("price", partialFilterExpression={"price": {"$exists": True}})
    app.create_collection("sessions")
    app.sessions.create_index("seen", expireAfterSeconds=3600)
    app.sessions.insert_one({"_id": "s1", "seen": 0})
    app.create_collection("log", capped=True, size=1 << 20)
    app.log.insert_many([{"_id": i, "line": f"line {i}"} for i in range(50)])
    app.command("create", "item_names", viewOn="items", pipeline=[{"$project": {"name": 1}}])
    # Bulk for the deduplication test: an archive of a few MB, many Borg
    # chunks.
    app.bulk.insert_many([{"_id": i, "filler": hashlib.md5(str(i).encode()).hexdigest() * 6}
                          for i in range(200000)])
    c.shop.products.insert_many([{"_id": 1, "name": "Käse"}, {"_id": 2, "name": "Brötchen"}])


def db_fingerprint(c, name):
    db = c[name]
    lines = []
    for info in sorted(db.list_collections(), key=lambda i: i["name"]):
        info.pop("info", None)  # the collection's UUID: new in a restore
        lines.append("collection " + canonical(info))
        # A view's definition is in its listCollections entry; system.views,
        # which holds them, no user may read.
        if info["type"] != "collection" or info["name"].startswith("system."):
            continue
        coll = db[info["name"]]
        for index in sorted(coll.list_indexes(), key=lambda i: i["name"]):
            lines.append(f"index {info['name']} " + canonical(index))
        digest = hashlib.sha256()
        for doc in coll.find().sort("_id", 1):
            digest.update(canonical(doc).encode())
        lines.append(f"content {info['name']} {coll.count_documents({})} {digest.hexdigest()}")
    return lines


def fingerprint(host, name=None):
    c = client(host)
    if name:
        return db_fingerprint(c, name)
    # The users with their credentials and the roles, as stored, then every
    # database but the server's own.
    lines = []
    for coll in ("system.users", "system.roles"):
        for doc in c.admin[coll].find().sort("_id", 1):
            lines.append(f"{coll} " + canonical(doc))
    for db in sorted(set(c.list_database_names()) - SYSTEM_DATABASES):
        lines.append(f"== {db}")
        lines += db_fingerprint(c, db)
    return lines


def main(argv):
    command, host = argv[1], argv[2]
    if command == "ready":
        ready(host)
    elif command == "initiate":
        initiate(host)
    elif command == "seed":
        seed(host)
    elif command == "fingerprint":
        print("\n".join(fingerprint(host, argv[3] if len(argv) > 3 else None)))
    elif command == "run":
        c = client(host)
        db = c[argv[3]] if len(argv) > 4 else None
        exec(argv[-1], {"c": c, "db": db})  # noqa: S102 - the tests' own code
    elif command == "login":
        user, password, auth_db, name = argv[3:7]
        print(client(host, user, password, auth_db)[name].items.count_documents({}))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
