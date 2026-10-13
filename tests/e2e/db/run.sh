#!/usr/bin/env bash
#
# End-to-end tests of the database dump and restore scripts against real
# database servers: one run per server version, each with servers of its own
# on a Docker network of its own, the tests in the e2e image next to them.
#
#   ./tests/e2e/db/run.sh                         # every server version
#   ./tests/e2e/db/run.sh postgres:17 mariadb:11.8
#
# Environment:
#   E2E_IMAGE      the image the tests run in (default k8s-borg:e2e, the test
#                  layer tests/e2e/run.sh builds on the agent image)
#   E2E_DB_JOBS    server versions tested at the same time (default 3)
#   E2E_DB_PREFIX  prefix of the containers and networks (default
#                  k8s-borg-e2e-db), so that runs side by side do not collide
#   E2E_DB_SCRIPTS_FROM_CHECKOUT=1
#                  bind-mount this checkout's dump and restore scripts and
#                  tests over the image's (bats is installed when missing).
#                  Tests script changes on a published image without building
#                  one, e.g. E2E_IMAGE=ghcr.io/ioanalytica/k8s-borg:<tag>.
#
# The server images come from Docker Hub: postgres:<version>-alpine and
# mariadb:<version>.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
self="$PWD/tests/e2e/db/run.sh"

DEFAULT_SERVERS="postgres:13 postgres:14 postgres:15 postgres:16 postgres:17 postgres:18 mariadb:10.11 mariadb:11.4 mariadb:11.8"
E2E_IMAGE="${E2E_IMAGE:-k8s-borg:e2e}"
PREFIX="${E2E_DB_PREFIX:-k8s-borg-e2e-db}"
JOBS="${E2E_DB_JOBS:-3}"
# A password with the characters the chart's credentials resolver escapes:
# ':' and '\' in a pgpass line, '"' and '\' in a MariaDB option file.
DB_PASSWORD='e2e:pa"ss\word'

# --one ENGINE:VERSION LOG — one server version: start its servers, run its
# tests, remove everything again. Called by the main run below, in parallel.
if [ "${1:-}" = "--one" ]; then
  spec=$2 log=$3
  engine=${spec%%:*} version=${spec#*:}
  name="${PREFIX}-${engine}${version//./-}"
  case "$engine" in
    postgres) server_image="postgres:${version}-alpine"; server_env=(-e "POSTGRES_PASSWORD=$DB_PASSWORD") ;;
    mariadb)  server_image="mariadb:${version}";         server_env=(-e "MARIADB_ROOT_PASSWORD=$DB_PASSWORD") ;;
    *) echo "unknown engine in $spec" >"$log"; exit 1 ;;
  esac

  cleanup() {
    docker rm -f "${name}-src" "${name}-dst" "${name}-dst2" "${name}-tests" >/dev/null 2>&1 || true
    docker network rm "$name" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  cleanup

  checkout=()
  if [ "${E2E_DB_SCRIPTS_FROM_CHECKOUT:-}" = "1" ]; then
    checkout=(-v "$PWD/tests/e2e:/tests/e2e:ro")
    for script in docker/rootfs/usr/local/bin/backup-* docker/rootfs/usr/local/bin/restore-*; do
      checkout+=(-v "$PWD/$script:/usr/local/bin/${script##*/}:ro")
    done
  fi

  {
    echo "▶ $spec ($server_image)"
    docker network create "$name" >/dev/null
    for role in src dst dst2; do
      docker run -d -q --name "${name}-${role}" --network "$name" --network-alias "$role" \
        "${server_env[@]}" "$server_image" >/dev/null
    done
    rc=0
    # ${a[@]+…}: an empty array is "unbound" to set -u in bash 3.2 (macOS).
    docker run -q --name "${name}-tests" --network "$name" ${checkout[@]+"${checkout[@]}"} \
      -e "DB_ENGINE=$engine" -e "DB_VERSION=$version" -e "DB_PASSWORD=$DB_PASSWORD" \
      -e "BATS_TEST_NAME_PREFIX=$spec: " \
      --entrypoint sh "$E2E_IMAGE" -c \
      'command -v bats >/dev/null || apk add -q --no-cache bats >/dev/null
       exec bats --print-output-on-failure "/tests/e2e/db/$DB_ENGINE.bats"' || rc=$?
    exit "$rc"
  } >"$log" 2>&1
fi

read -r -a servers <<<"${*:-$DEFAULT_SERVERS}"

if ! docker info >/dev/null 2>&1; then
  echo "✗ docker is not available — start Docker and retry" >&2
  exit 1
fi

logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT

echo "▶ database e2e: ${servers[*]} (image $E2E_IMAGE, $JOBS at a time)"
# Each server version logs to a file of its own and its result is printed in
# one piece when it is done, so that parallel runs do not interleave.
printf '%s\n' "${servers[@]}" | xargs -P "$JOBS" -I{} sh -c '
  spec=$1 log="$2/$(echo "$1" | tr ":" "-").log"
  if "$0" --one "$spec" "$log"; then echo "✓ $spec" >>"$2/results"; else echo "✗ $spec" >>"$2/results"; fi
  cat "$log"
' "$self" {} "$logs" || true

echo
echo "── database e2e summary ──"
sort "$logs/results"
if grep -q '^✗' "$logs/results"; then
  exit 1
fi
[ "$(wc -l <"$logs/results")" -eq "${#servers[@]}" ] || { echo "✗ not every server version reported a result" >&2; exit 1; }
