#!/usr/bin/env python3
"""An application writing to a SQLite database under constant load.

  sqlite-writer.py DB MODE [READY]

MODE is the journal mode (wal or delete). Every transaction inserts 1–20 rows
of random size, drops the rows older than the last 5000 (so that pages are
freed and reused) and sets total.s to the sum of t.v and total.n to its own
number: a copy that is one consistent state of the database has
sum(t.v) == total.s and no row of a transaction after total.n. On an existing
database it goes on from its last transaction. READY is created once it has
committed 50 transactions. Runs until it is killed.
"""
import os
import random
import sqlite3
import sys

db, mode = sys.argv[1], sys.argv[2]
c = sqlite3.connect(db, isolation_level=None, timeout=60)
c.execute("PRAGMA journal_mode=%s" % mode)
c.execute("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, tx INTEGER, v INTEGER, pad BLOB)")
c.execute("CREATE TABLE IF NOT EXISTS total (id INTEGER PRIMARY KEY, s INTEGER, n INTEGER)")
c.execute("INSERT OR IGNORE INTO total VALUES (1, 0, 0)")
n = c.execute("SELECT n FROM total").fetchone()[0]
committed = 0
while True:
    n += 1
    c.execute("BEGIN IMMEDIATE")
    for _ in range(random.randint(1, 20)):
        c.execute("INSERT INTO t (tx, v, pad) VALUES (?, ?, ?)",
                  (n, random.randint(1, 1000), os.urandom(random.randint(100, 2000))))
    c.execute("DELETE FROM t WHERE id < (SELECT max(id) FROM t) - 5000")
    c.execute("UPDATE total SET s = (SELECT coalesce(sum(v), 0) FROM t), n = ? WHERE id = 1", (n,))
    c.execute("COMMIT")
    committed += 1
    if committed == 50 and len(sys.argv) > 3:
        open(sys.argv[3], "w").close()
