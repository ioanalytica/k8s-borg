# shellcheck shell=bash
#
# MariaDB side of the database tests: defaults files as the chart renders
# them, the seeded content, and fingerprints of an instance and of a
# database to compare a restore with its source.

# write_conf FILE HOST [USER [PASSWORD]] — a defaults file in the chart's
# format, the password in double quotes with '\' and '"' escaped (what the
# chart's credentials resolver writes). The client of the image asks for TLS
# by default; a server before 11.4 has no certificate of its own, so its file
# turns TLS off as the resolver does for an instance with `tls: false`.
write_conf() {
  local p=${4:-$DB_PASSWORD}
  p=${p//\\/\\\\}
  p=${p//\"/\\\"}
  mkdir -p "$(dirname "$1")"
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword="%s"\n' "$2" 3306 "${3:-root}" "$p" >"$1"
  case "$DB_VERSION" in
    10.*|11.[0-3]) echo skip-ssl >>"$1" ;;
  esac
  chmod 600 "$1"
}

# my HOST [DATABASE] — the mariadb client as root: batch, no column names,
# raw values. SQL from stdin or -e.
my() {
  local host=$1 db=${2:-}
  shift 2 || shift
  mariadb --defaults-file="$E2E_TMP/admin-$host.cnf" -N -B -r ${db:+"$db"} "$@"
}

my_setup_admin() {
  local host
  for host in src dst dst2; do
    write_conf "$E2E_TMP/admin-$host.cnf" "$host"
  done
}

my_ready() { my "$1" -e 'SELECT 1'; }

# my_seed HOST — users with passwords, a role, global, database, table and
# column grants; databases with their own character sets; a table with
# non-ASCII text, binary data and an AUTO_INCREMENT counter, a view, a
# procedure, a function, a trigger and an event.
my_seed() {
  my "$1" <<'SQL'
CREATE DATABASE appdb CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE shop CHARACTER SET latin1;
CREATE USER 'app'@'%' IDENTIFIED BY 'app-pw';
CREATE USER 'reader'@'%' IDENTIFIED BY 'reader-pw';
CREATE ROLE app_role;
GRANT SELECT ON shop.* TO app_role;
GRANT app_role TO 'app'@'%';
GRANT SELECT, INSERT, UPDATE ON appdb.* TO 'app'@'%';
GRANT PROCESS ON *.* TO 'reader'@'%';

USE appdb;
CREATE TABLE items (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  payload BLOB
) ENGINE=InnoDB;
CREATE TABLE audit (id INT AUTO_INCREMENT PRIMARY KEY, item_id INT, action VARCHAR(20)) ENGINE=InnoDB;
CREATE TRIGGER items_ai AFTER INSERT ON items FOR EACH ROW INSERT INTO audit (item_id, action) VALUES (NEW.id, 'insert');
INSERT INTO items (name, payload) VALUES
  ('Grüße aus Köln', 0x00FF7F80),
  ('日本語のテキスト', REPEAT(0x00FF, 64)),
  ('emoji 🐘 and a ''quote''', NULL);
INSERT INTO items (name, payload) SELECT CONCAT('row ', seq), UNHEX(REPEAT(MD5(seq), 4)) FROM seq_1_to_2000;
GRANT SELECT (id, name) ON appdb.items TO 'reader'@'%';
CREATE VIEW item_names AS SELECT id, name FROM items;
CREATE PROCEDURE add_item(IN n VARCHAR(100)) INSERT INTO items (name) VALUES (n);
CREATE FUNCTION item_count() RETURNS INT READS SQL DATA RETURN (SELECT COUNT(*) FROM items);
CREATE EVENT purge_audit ON SCHEDULE EVERY 1 DAY STARTS '2030-01-01 00:00:00' DISABLE DO DELETE FROM audit WHERE id < 0;
-- Bulk for the deduplication test: a dump of a few MB, many Borg chunks.
CREATE TABLE bulk (id INT PRIMARY KEY, filler VARCHAR(255)) ENGINE=InnoDB;
INSERT INTO bulk SELECT seq, CONCAT(MD5(seq), REPEAT(MD5(seq * 7), 6)) FROM seq_1_to_200000;

USE shop;
CREATE TABLE products (id INT PRIMARY KEY, name VARCHAR(50)) ENGINE=InnoDB;
INSERT INTO products VALUES (1, 'Käse'), (2, 'Brötchen');
SQL
}

# my_db_fingerprint HOST DATABASE — what a restore of the database must
# bring back: its character set, tables with their counters, the content of
# every table, views, routines, triggers and events with their definers. The
# database's own name is taken out of the definitions, so that a copy
# restored under another name compares equal only when it refers to itself.
my_db_fingerprint() {
  local table
  my "$1" <<SQL
SET @db = '$2';
SELECT 'schema', DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = @db;
SELECT 'table', TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_COLLATION, AUTO_INCREMENT
  FROM information_schema.TABLES WHERE TABLE_SCHEMA = @db ORDER BY TABLE_NAME;
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

# my_fingerprint HOST — the whole instance: users with their password hashes
# and options, roles and their grantees, database, table and column grants,
# and every database's my_db_fingerprint but the mysql schema's own (its
# tables are compared above, as far as they say who may do what).
my_fingerprint() {
  local db
  my "$1" <<'SQL'
SELECT 'user', User, Host, Priv FROM mysql.global_priv ORDER BY User, Host;
SELECT 'role', Host, User, Role, Admin_option FROM mysql.roles_mapping ORDER BY Host, User, Role;
SELECT 'db grant', Host, Db, User, Select_priv, Insert_priv, Update_priv, Delete_priv FROM mysql.db ORDER BY Host, Db, User;
SELECT 'table grant', Host, Db, User, Table_name, Table_priv, Column_priv FROM mysql.tables_priv ORDER BY Host, Db, User, Table_name;
SELECT 'column grant', Host, Db, User, Table_name, Column_name, Column_priv FROM mysql.columns_priv ORDER BY Host, Db, User, Table_name, Column_name;
SQL
  while IFS= read -r db; do
    echo "== $db"
    my_db_fingerprint "$1" "$db"
  done < <(my "$1" -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'sys', 'mysql') ORDER BY 1")
}
