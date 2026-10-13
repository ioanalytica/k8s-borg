# shellcheck shell=bash
#
# The client of the engine a MariaDB/MySQL script works for, sourced by
# backup-mariadb and restore-mariadb, which are backup-mysql and restore-mysql
# under those names. The caller sets $engine to mariadb or mysql.
#
#   mariadb  the image's MariaDB client (mariadb, mariadb-dump)
#   mysql    MySQL's own client from $MYSQL_CLIENT_DIR (default /opt/mysql/bin)
#
# The defaults file is the client's first option, as both clients require.

case "${engine:-}" in
  mariadb)
    sql_client() { mariadb --defaults-file="$1" "${@:2}"; }
    sql_dump() { mariadb-dump --defaults-file="$1" "${@:2}"; }
    ;;
  mysql)
    sql_client() { "${MYSQL_CLIENT_DIR:-/opt/mysql/bin}/mysql" --defaults-file="$1" "${@:2}"; }
    # No GTIDs in a dump: a restore brings back the data and must also work
    # into a server that has GTIDs of its own (or the dump's, a second
    # database from the same source).
    sql_dump() { "${MYSQL_CLIENT_DIR:-/opt/mysql/bin}/mysqldump" --defaults-file="$1" --set-gtid-purged=OFF "${@:2}"; }
    ;;
  *)
    echo "Error: unknown engine '${engine:-}' (called as ${0##*/}; mariadb or mysql)" >&2
    exit 2
    ;;
esac

# require_server DEFAULTS_FILE — fail with rc 2 unless the server is of this
# engine. mariadb-dump's dumps of a MySQL server do not restore (it writes the
# values of generated columns, which MySQL rejects), and MySQL's client is not
# made for MariaDB: either way the instance belongs to the other engine.
require_server() {
  local version
  version=$(sql_client "$1" -N -B -e "SELECT VERSION()")
  case "$engine:$version" in
    mariadb:*MariaDB*) return 0 ;;
    mariadb:*) echo "Error: ${1##*/} reaches MySQL $version, not MariaDB: configure the instance under databases.mysql" >&2 ;;
    mysql:*MariaDB*) echo "Error: ${1##*/} reaches MariaDB $version, not MySQL: configure the instance under databases.mariadb" >&2 ;;
    mysql:*) return 0 ;;
  esac
  exit 2
}
