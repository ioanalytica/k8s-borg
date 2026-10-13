# shellcheck shell=bash
#
# PostgreSQL side of the database tests: credentials files as the chart
# renders them, the seeded content, and fingerprints of an instance and of a
# database to compare a restore with its source.

# pgpass_escape VALUE — ':' and '\' escaped as in a pgpass line (what the
# chart's credentials resolver writes).
pgpass_escape() {
  local v=${1//\\/\\\\}
  printf '%s' "${v//:/\\:}"
}

# write_conf FILE HOST [USER [PASSWORD]] — a credentials file in the chart's
# format: one pgpass line for every database of the server.
write_conf() {
  mkdir -p "$(dirname "$1")"
  printf '%s:5432:*:%s:%s\n' "$2" "$(pgpass_escape "${3:-postgres}")" "$(pgpass_escape "${4:-$DB_PASSWORD}")" >"$1"
  chmod 600 "$1"
}

# pg HOST [DATABASE] — psql as the server's administrator: unaligned, tuples
# only, stopping at the first error. SQL from stdin or -c.
pg() {
  local host=$1 db=${2:-postgres}
  shift 2 || shift
  PGPASSFILE="$E2E_TMP/admin.pgpass" psql -X -q -A -t -v ON_ERROR_STOP=1 -h "$host" -U postgres -d "$db" "$@"
}

pg_setup_admin() {
  printf '*:*:*:postgres:%s\n' "$(pgpass_escape "$DB_PASSWORD")" >"$E2E_TMP/admin.pgpass"
  chmod 600 "$E2E_TMP/admin.pgpass"
}

pg_ready() { pg "$1" postgres -c 'SELECT 1'; }

# pg_major HOST — the server's major version, e.g. 17.
pg_major() { pg "$1" postgres -c 'SHOW server_version_num' | cut -c1-2; }

# pg_seed HOST — roles with passwords, memberships and settings; databases
# with an owner, settings, grants and a comment, one with a non-ASCII name;
# schemas, tables, a view, a function, a sequence, grants on them; non-ASCII
# text, binary data and a large object; content in postgres and template1.
pg_seed() {
  pg "$1" postgres <<'SQL'
CREATE ROLE app_owner LOGIN PASSWORD 'owner-pw' CONNECTION LIMIT 5;
CREATE ROLE app_reader NOLOGIN;
CREATE ROLE app_user LOGIN PASSWORD 'user-pw' VALID UNTIL '2099-01-01' IN ROLE app_reader;
ALTER ROLE app_user SET search_path = app, public;
CREATE DATABASE appdb OWNER app_owner;
CREATE DATABASE "straße" OWNER app_user;
ALTER DATABASE appdb SET work_mem = '8MB';
ALTER ROLE app_user IN DATABASE appdb SET statement_timeout = '5min';
REVOKE ALL ON DATABASE appdb FROM PUBLIC;
GRANT CONNECT ON DATABASE appdb TO app_reader;
COMMENT ON DATABASE appdb IS 'e2e: Grüße';
CREATE TABLE public.postgres_marker (note text);
INSERT INTO public.postgres_marker VALUES ('in the postgres database');
SQL
  pg "$1" template1 <<'SQL'
CREATE EXTENSION hstore;
CREATE TABLE public.template_marker (note text);
INSERT INTO public.template_marker VALUES ('inherited by every new database');
SQL
  pg "$1" appdb <<'SQL'
SET ROLE app_owner;
CREATE SCHEMA app;
CREATE TABLE app.items (
  id serial PRIMARY KEY,
  name text NOT NULL,
  tags text[],
  payload bytea
);
INSERT INTO app.items (name, tags, payload) VALUES
  ('Grüße aus Köln', '{ä,ö,ü}', '\x00ff7f80'::bytea),
  ('日本語のテキスト', '{}', decode(repeat('00ff', 64), 'hex')),
  ('emoji 🐘 and a ''quote''', NULL, NULL);
INSERT INTO app.items (name, payload)
  SELECT 'row ' || g, decode(repeat(md5(g::text), 4), 'hex') FROM generate_series(1, 2000) g;
CREATE VIEW app.item_names AS SELECT id, name FROM app.items;
CREATE FUNCTION app.item_count() RETURNS bigint LANGUAGE sql AS 'SELECT count(*) FROM app.items';
GRANT USAGE ON SCHEMA app TO app_reader;
GRANT SELECT ON app.items, app.item_names TO app_reader;
SELECT lo_from_bytea(0, convert_to('a large object: Grüße', 'UTF8'));
-- Bulk for the deduplication test: a dump of a few MB, many Borg chunks.
CREATE TABLE app.bulk AS
  SELECT g AS id, md5(g::text) || repeat(md5((g * 7)::text), 6) AS filler
  FROM generate_series(1, 200000) g;
ALTER TABLE app.bulk ADD PRIMARY KEY (id);
SQL
  pg "$1" "straße" <<'SQL'
SET ROLE app_user;
CREATE TABLE "Größe" (id int PRIMARY KEY, wert text);
INSERT INTO "Größe" VALUES (1, 'groß'), (2, 'klein');
SQL
}

# pg_db_fingerprint HOST DATABASE — what a restore of the database must bring
# back: extensions, schemas, relations with owner and privileges, functions,
# the content of every table and sequence, the large objects. Database-level
# properties are in pg_fingerprint. ACLs are sorted, as their order follows
# the order of the grants.
pg_db_fingerprint() {
  pg "$1" "$2" <<'SQL'
SELECT 'extension', extname, extversion FROM pg_extension ORDER BY 2;
SELECT 'schema', nspname, pg_get_userbyid(nspowner),
       (SELECT string_agg(a::text, ',' ORDER BY a::text) FROM unnest(nspacl) a)
  FROM pg_namespace WHERE nspname !~ '^pg_' AND nspname <> 'information_schema' ORDER BY 2;
SELECT 'relation', n.nspname, c.relname, c.relkind, pg_get_userbyid(c.relowner),
       (SELECT string_agg(a::text, ',' ORDER BY a::text) FROM unnest(c.relacl) a)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  ORDER BY 2, 3;
SELECT 'function', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid), pg_get_userbyid(p.proowner), md5(p.prosrc)
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' ORDER BY 2, 3, 4;
SELECT format(CASE c.relkind
                WHEN 'S' THEN 'SELECT %L, %L, last_value, is_called FROM %I.%I'
                ELSE 'SELECT %L, %L, count(*), md5(coalesce(string_agg(t::text, E''\n'' ORDER BY t::text), '''')) FROM %I.%I t'
              END, 'content', n.nspname || '.' || c.relname, n.nspname, c.relname)
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND c.relkind IN ('r', 'm', 'S')
  ORDER BY n.nspname, c.relname
\gexec
SELECT 'large object', m.oid, pg_get_userbyid(m.lomowner), md5(lo_get(m.oid))
  FROM pg_largeobject_metadata m ORDER BY 2;
SQL
}

# pg_fingerprint HOST — the whole instance: roles with their attributes and
# password hashes, memberships, role settings, databases with owner,
# encoding, flags, sorted grants and comment, and every database's
# pg_db_fingerprint (template0 aside, which nothing restores).
pg_fingerprint() {
  local db
  pg "$1" postgres <<'SQL'
SELECT 'role', rolname, rolsuper, rolinherit, rolcreaterole, rolcreatedb, rolcanlogin, rolreplication,
       rolbypassrls, rolconnlimit, rolvaliduntil, rolpassword
  FROM pg_authid WHERE rolname !~ '^pg_' ORDER BY 2;
SELECT 'member', r.rolname, m.rolname, a.admin_option
  FROM pg_auth_members a JOIN pg_roles r ON r.oid = a.roleid JOIN pg_roles m ON m.oid = a.member
  WHERE r.rolname !~ '^pg_' ORDER BY 2, 3;
SELECT 'setting', coalesce(d.datname, '-'), coalesce(r.rolname, '-'), s.setconfig::text
  FROM pg_db_role_setting s LEFT JOIN pg_database d ON d.oid = s.setdatabase LEFT JOIN pg_roles r ON r.oid = s.setrole
  ORDER BY 2, 3;
SELECT 'database', datname, pg_get_userbyid(datdba), pg_encoding_to_char(encoding), datcollate, datctype,
       datistemplate, datallowconn, datconnlimit,
       (SELECT string_agg(a::text, ',' ORDER BY a::text) FROM unnest(datacl) a),
       shobj_description(oid, 'pg_database')
  FROM pg_database ORDER BY 2;
SQL
  while IFS= read -r db; do
    echo "== $db"
    pg_db_fingerprint "$1" "$db"
  done < <(pg "$1" postgres -c "SELECT datname FROM pg_database WHERE datname <> 'template0' ORDER BY 1")
}
