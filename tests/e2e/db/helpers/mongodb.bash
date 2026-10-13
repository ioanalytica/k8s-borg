# shellcheck shell=bash
#
# MongoDB side of the database tests: credentials files as the chart renders
# them, and mongodb.py (the seeded content, fingerprints of an instance and
# of a database, replica set setup), run with the image's pymongo.

MONGODB_PY="$(dirname "${BASH_SOURCE[0]}")/mongodb.py"

# mo COMMAND HOST [ARGS…] — mongodb.py as the server's root user.
mo() { /opt/mongodb-admin/venv/bin/python -I "$MONGODB_PY" "$@"; }

# write_conf FILE HOST [USER [PASSWORD]] — a credentials file in the chart's
# format: the URI with the user, the password a single-quoted YAML scalar
# (what the chart's credentials resolver writes).
write_conf() {
  local p=${4:-$DB_PASSWORD} q="'"
  p=${p//$q/$q$q}
  mkdir -p "$(dirname "$1")"
  printf "uri: 'mongodb://%s@%s:27017/?authSource=admin'\npassword: '%s'\n" "${3:-root}" "$2" "$p" >"$1"
  chmod 600 "$1"
}
