#!/usr/bin/env python3
"""Check a copy of a database sqlite-writer.py writes: prints its last
transaction and journal mode ("n=… mode=…"), exits 1 when the copy is not one
consistent state (integrity_check, sum(t.v) == total.s, no row after total.n).

  sqlite-check.py COPY
"""
import sqlite3
import sys

c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
integrity = c.execute("PRAGMA integrity_check").fetchone()[0]
s, n = c.execute("SELECT s, n FROM total").fetchone()
total, last = c.execute("SELECT coalesce(sum(v), 0), coalesce(max(tx), 0) FROM t").fetchone()
mode = c.execute("PRAGMA journal_mode").fetchone()[0]
print("n=%d mode=%s" % (n, mode))
if integrity != "ok" or s != total or last > n:
    sys.exit("inconsistent: integrity %s, total.s %d, sum %d, last tx %d, n %d" % (integrity, s, total, last, n))
