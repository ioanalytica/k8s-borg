# shellcheck shell=bash
#
# MySQL side of the database tests (MySQL and Percona Server): defaults files
# as the chart renders them, the seeded content, and fingerprints of an
# instance and of a database to compare a restore with its source. The
# client is MySQL's own, the one backup-mysql and restore-mysql use.

MYSQL=${MYSQL_CLIENT_DIR:-/opt/mysql/bin}/mysql

# write_conf FILE HOST [USER [PASSWORD [OPTION…]]] — a defaults file in the
# chart's format, every value in double quotes with '\' and '"' escaped (what
# the chart's credentials resolver writes), each OPTION on a line of its own. Without options TLS is left to the client: used when the server offers
# it, the certificate unchecked.
write_conf() {
  local file=$1 host=$2 user=${3:-root} p=${4:-$DB_PASSWORD}
  shift 4 2>/dev/null || shift $#
  p=${p//\\/\\\\}
  p=${p//\"/\\\"}
  mkdir -p "$(dirname "$file")"
  printf '[client]\nhost="%s"\nport="%s"\nuser="%s"\npassword="%s"\n' "$host" 3306 "$user" "$p" >"$file"
  [ $# -eq 0 ] || printf '%s\n' "$@" >>"$file"
  chmod 600 "$file"
}

# my HOST [DATABASE] — the mysql client as root: batch, no column names, raw
# values. SQL from stdin or -e.
my() {
  local host=$1 db=${2:-}
  shift 2 || shift
  "$MYSQL" --defaults-file="$E2E_TMP/admin-$host.cnf" -N -B -r ${db:+"$db"} "$@"
}

# my_setup_admin — wait for each server and give its root DB_PASSWORD (the
# servers start with DB_BOOTSTRAP_PASSWORD, see run.sh), then the defaults
# files `my` uses.
my_setup_admin() {
  local host p=${DB_PASSWORD//\\/\\\\}
  p=${p//\'/\'\'}
  for host in src dst dst2; do
    write_conf "$E2E_TMP/boot-$host.cnf" "$host" root "$DB_BOOTSTRAP_PASSWORD"
    wait_for 180 "$MYSQL" --defaults-file="$E2E_TMP/boot-$host.cnf" -e 'SELECT 1'
    "$MYSQL" --defaults-file="$E2E_TMP/boot-$host.cnf" \
      -e "ALTER USER 'root'@'%' IDENTIFIED BY '$p'; ALTER USER 'root'@'localhost' IDENTIFIED BY '$p'"
    write_conf "$E2E_TMP/admin-$host.cnf" "$host"
  done
}

my_ready() { my "$1" -e 'SELECT 1'; }

# my_seed HOST — users with passwords (caching_sha2_password, MySQL's
# default) and a password policy, roles with a default role, global,
# database, table and column grants; databases with their own character
# sets; what mariadb-dump cannot bring back into MySQL: stored and virtual
# generated columns, next to an invisible column, a JSON column, a functional
# index and a CHECK constraint; non-ASCII text, binary data and an
# AUTO_INCREMENT counter, a view, a procedure, a function, a trigger and an
# event, each with a DEFINER.
my_seed() {
  my "$1" <<'SQL'
SET SESSION cte_max_recursion_depth = 1000000;
CREATE DATABASE appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE shop CHARACTER SET latin1;
CREATE USER 'app'@'%' IDENTIFIED BY 'app-pw' PASSWORD EXPIRE INTERVAL 90 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 1;
CREATE USER 'reader'@'%' IDENTIFIED BY 'reader-pw';
CREATE USER 'owner'@'localhost' IDENTIFIED BY 'owner-pw';
CREATE ROLE app_role;
GRANT SELECT ON shop.* TO app_role;
GRANT app_role TO 'app'@'%';
SET DEFAULT ROLE app_role TO 'app'@'%';
GRANT SELECT, INSERT, UPDATE ON appdb.* TO 'app'@'%';
GRANT PROCESS ON *.* TO 'reader'@'%';
-- The definer of the database's objects, also for a copy restored with --as.
GRANT ALL ON `appdb%`.* TO 'owner'@'localhost';

USE appdb;
CREATE TABLE items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  price DECIMAL(10,2) NOT NULL DEFAULT 1.00,
  qty INT NOT NULL DEFAULT 1,
  total DECIMAL(12,2) GENERATED ALWAYS AS (price * qty) STORED,
  label VARCHAR(120) GENERATED ALWAYS AS (CONCAT(name, ' x', qty)) VIRTUAL,
  doc JSON,
  note VARCHAR(20) INVISIBLE DEFAULT 'hidden',
  payload BLOB,
  CHECK (qty >= 0),
  INDEX idx_tag ((CAST(doc->>'$.tag' AS CHAR(20) CHARSET utf8mb4) COLLATE utf8mb4_bin))
) ENGINE=InnoDB;
CREATE TABLE audit (id INT AUTO_INCREMENT PRIMARY KEY, item_id INT, action VARCHAR(20)) ENGINE=InnoDB;
CREATE DEFINER='owner'@'localhost' TRIGGER items_ai AFTER INSERT ON items FOR EACH ROW INSERT INTO audit (item_id, action) VALUES (NEW.id, 'insert');
INSERT INTO items (name, qty, doc, payload) VALUES
  ('Grüße aus Köln', 3, '{"tag": "greeting", "n": [1, 2]}', 0x00FF7F80),
  ('日本語のテキスト', 7, '{"tag": "text"}', REPEAT(0x00FF, 64)),
  ('emoji 🐘 and a ''quote''', 0, NULL, NULL);
INSERT INTO items (name, qty, payload)
  WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 2000)
  SELECT CONCAT('row ', n), n % 10, UNHEX(REPEAT(MD5(n), 4)) FROM seq;
UPDATE items SET note = 'visible' WHERE id = 2;
GRANT SELECT (id, name) ON appdb.items TO 'reader'@'%';
CREATE DEFINER='owner'@'localhost' SQL SECURITY DEFINER VIEW item_names AS SELECT id, name, total FROM items;
CREATE DEFINER='owner'@'localhost' PROCEDURE add_item(IN n VARCHAR(100)) INSERT INTO items (name) VALUES (n);
CREATE DEFINER='owner'@'localhost' FUNCTION item_count() RETURNS INT READS SQL DATA RETURN (SELECT COUNT(*) FROM items);
CREATE DEFINER='owner'@'localhost' EVENT purge_audit ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 00:00:00' DISABLE DO DELETE FROM audit WHERE id < 0;
-- Bulk for the deduplication test: a dump of a few MB, many Borg chunks.
CREATE TABLE bulk (id INT PRIMARY KEY, filler VARCHAR(255)) ENGINE=InnoDB;
INSERT INTO bulk
  WITH RECURSIVE seq (n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200000)
  SELECT n, CONCAT(MD5(n), REPEAT(MD5(n * 7), 6)) FROM seq;

USE shop;
CREATE TABLE products (id INT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB;
INSERT INTO products VALUES (1, 'Käse'), (2, 'Brötchen');
SQL
}

# my_db_fingerprint HOST DATABASE — what a restore of the database must
# bring back: its character set, tables with their counters, columns with
# their generation expressions and invisibility, indexes with their
# expressions, the content of every table (its stored columns, the invisible
# one included), views, routines, triggers and events with their definers. The database's
# own name is taken out of the definitions, so that a copy restored under
# another name compares equal only when it refers to itself.
my_db_fingerprint() {
  local table
  my "$1" <<SQL
SET SESSION information_schema_stats_expiry = 0;
SET @db = '$2';
SELECT 'schema', DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = @db;
SELECT 'table', TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_COLLATION, AUTO_INCREMENT
  FROM information_schema.TABLES WHERE TABLE_SCHEMA = @db ORDER BY TABLE_NAME;
SELECT 'column', TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, EXTRA, GENERATION_EXPRESSION, COLLATION_NAME
  FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = @db ORDER BY TABLE_NAME, ORDINAL_POSITION;
SELECT 'index', TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX, COLUMN_NAME, EXPRESSION
  FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = @db ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX;
SELECT 'check', CONSTRAINT_NAME, CHECK_CLAUSE FROM information_schema.CHECK_CONSTRAINTS WHERE CONSTRAINT_SCHEMA = @db ORDER BY 2;
SELECT 'view', TABLE_NAME, DEFINER, MD5(REPLACE(VIEW_DEFINITION, CONCAT('\`', @db, '\`.'), ''))
  FROM information_schema.VIEWS WHERE TABLE_SCHEMA = @db ORDER BY TABLE_NAME;
SELECT 'routine', ROUTINE_TYPE, ROUTINE_NAME, DEFINER, MD5(ROUTINE_DEFINITION)
  FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = @db ORDER BY ROUTINE_TYPE, ROUTINE_NAME;
SELECT 'trigger', TRIGGER_NAME, EVENT_MANIPULATION, EVENT_OBJECT_TABLE, ACTION_TIMING, DEFINER, MD5(ACTION_STATEMENT)
  FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA = @db ORDER BY TRIGGER_NAME;
SELECT 'event', EVENT_NAME, DEFINER, STATUS, INTERVAL_VALUE, INTERVAL_FIELD, STARTS, MD5(EVENT_DEFINITION)
  FROM information_schema.EVENTS WHERE EVENT_SCHEMA = @db ORDER BY EVENT_NAME;
SQL
  while IFS= read -r table; do
    my "$1" "$2" -e "CHECKSUM TABLE \`$table\` EXTENDED" | cut -f2 | sed "s/^/content	$table	/"
  done < <(my "$1" -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$2' AND TABLE_TYPE = 'BASE TABLE' ORDER BY 1")
}

# my_fingerprint HOST — the whole instance: users with their password hashes,
# plugins and options, roles, their grantees and default roles, global,
# dynamic, database, table and column grants, and every database's
# my_db_fingerprint but the system schemas' own (the mysql schema's tables
# are compared above, as far as they say who may do what).
my_fingerprint() {
  local db
  my "$1" <<'SQL'
SELECT 'user', User, Host, plugin, HEX(authentication_string), account_locked, password_lifetime, User_attributes,
       Select_priv, Process_priv, Super_priv FROM mysql.user ORDER BY User, Host;
SELECT 'role', FROM_HOST, FROM_USER, TO_HOST, TO_USER, WITH_ADMIN_OPTION FROM mysql.role_edges ORDER BY 2, 3, 4, 5;
SELECT 'default role', HOST, USER, DEFAULT_ROLE_HOST, DEFAULT_ROLE_USER FROM mysql.default_roles ORDER BY 2, 3, 4, 5;
SELECT 'dynamic grant', USER, HOST, PRIV, WITH_GRANT_OPTION FROM mysql.global_grants ORDER BY 2, 3, 4;
SELECT 'db grant', Host, Db, User, Select_priv, Insert_priv, Update_priv, Delete_priv FROM mysql.db ORDER BY Host, Db, User;
SELECT 'table grant', Host, Db, User, Table_name, Table_priv, Column_priv FROM mysql.tables_priv ORDER BY Host, Db, User, Table_name;
SELECT 'column grant', Host, Db, User, Table_name, Column_name, Column_priv FROM mysql.columns_priv ORDER BY Host, Db, User, Table_name, Column_name;
SQL
  while IFS= read -r db; do
    echo "== $db"
    my_db_fingerprint "$1" "$db"
  done < <(my "$1" -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'sys', 'mysql') ORDER BY 1")
}
