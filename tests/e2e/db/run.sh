#!/usr/bin/env bash
#
# End-to-end tests of the database dump and restore scripts against real
# database servers: one run per server version, each with servers of its own
# on a Docker network of its own, the tests in the e2e image next to them.
#
#   ./tests/e2e/db/run.sh                         # every server version
#   ./tests/e2e/db/run.sh postgres:17 mariadb:11.8 mongodb:8.2
#   ./tests/e2e/db/run.sh sqlite:bookworm
#
# Environment:
#   E2E_IMAGE      the image the tests run in (default k8s-borg:e2e, the test
#                  layer tests/e2e/run.sh builds on the agent image)
#   E2E_DB_JOBS    server versions tested at the same time (default 3)
#   E2E_DB_PREFIX  prefix of the containers and networks (default
#                  k8s-borg-e2e-db), so that runs side by side do not collide
#   E2E_DB_TIMEOUT seconds one server version may take (default 600; the
#                  slowest, MongoDB 7, takes under 3 minutes in CI). One that
#                  takes longer fails, with what its tests had printed, the
#                  processes they were running and its servers' logs.
#   E2E_DB_SCRIPTS_FROM_CHECKOUT=1
#                  bind-mount this checkout's dump and restore scripts and
#                  tests over the image's (bats is installed when missing).
#                  Tests script changes on a published image without building
#                  one, e.g. E2E_IMAGE=ghcr.io/ioanalytica/k8s-borg:<tag>.
#
# The server images come from Docker Hub: postgres:<version>-alpine,
# mariadb:<version>, mysql:<version>, percona/percona-server:<version> (for
# percona:<version>), mongo:<version>, redis:<version> and
# valkey/valkey:<version>. MySQL and Percona Server run with GTIDs on and share
# mysql.bats. Redis and Valkey run redis.bats, with a cluster of three
# primaries (c1-c3) next to `src`, and `dst` restarting on its own: its data
# directory is shared with the tests, which restore by placing dump.rdb there
# and shutting the server down without saving, so that it starts again on the
# file. SQLite has no server: its "version" is the
# image of the application that writes the databases, with the SQLite of its
# distribution (python:3.13-alpine, python:3.13-slim-bookworm,
# python:3.12-slim-bullseye).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
self="$PWD/tests/e2e/db/run.sh"

# MongoDB 8 as 8.2: 8.0.21+, 8.3 and 9.0 refuse to start on a Linux kernel
# 6.19 or newer (SERVER-121912, SERVER-136848); 8.2 and 7.0 start there.
DEFAULT_SERVERS="postgres:13 postgres:14 postgres:15 postgres:16 postgres:17 postgres:18 mariadb:10.11 mariadb:11.4 mariadb:11.8 mysql:8.4 percona:8.4 mongodb:7 mongodb:8.2 redis:7 redis:8 valkey:8 valkey:9 sqlite:alpine sqlite:bookworm sqlite:bullseye"
E2E_IMAGE="${E2E_IMAGE:-k8s-borg:e2e}"
PREFIX="${E2E_DB_PREFIX:-k8s-borg-e2e-db}"
JOBS="${E2E_DB_JOBS:-3}"
TIMEOUT="${E2E_DB_TIMEOUT:-600}"
# A password with the characters the chart's credentials resolver escapes:
# ':' and '\' in a pgpass line, '"' and '\' in a MariaDB/MySQL option file.
DB_PASSWORD='e2e:pa"ss\word'

# image_of ENGINE:VERSION — the server image of a server version (for SQLite
# the image of the application), nothing for one this script does not know.
image_of() {
  local engine=${1%%:*} version=${1#*:}
  case "$engine" in
    postgres) echo "postgres:${version}-alpine" ;;
    mariadb)  echo "mariadb:${version}" ;;
    mysql)    echo "mysql:${version}" ;;
    percona)  echo "percona/percona-server:${version}" ;;
    mongodb)  echo "mongo:${version}" ;;
    redis)    echo "redis:${version}" ;;
    valkey)   echo "valkey/valkey:${version}" ;;
    sqlite)
      case "$version" in
        alpine)   echo "python:3.13-alpine" ;;
        bookworm) echo "python:3.13-slim-bookworm" ;;
        bullseye) echo "python:3.12-slim-bullseye" ;;
      esac ;;
  esac
}

# --one ENGINE:VERSION LOG — one server version: start its servers, run its
# tests, remove everything again. Called by the main run below, in parallel.
if [ "${1:-}" = "--one" ]; then
  spec=$2 log=$3
  engine=${spec%%:*} version=${spec#*:}
  name="${PREFIX}-${engine}${version//./-}"
  # server_opts ROLE / server_args ROLE — docker run options before the
  # image and arguments after it for the server of ROLE, one per line.
  server_opts() { :; }
  server_args() { :; }
  # roles: the servers; tests: the bats file; tests_args: docker run options
  # of the test container.
  roles=(src dst dst2) tests=$engine tests_args=() tls_names=() tls_dir=""
  # The entrypoint of the MySQL and Percona images puts the root password into
  # SQL unescaped and fails on DB_PASSWORD; the servers start with this one
  # and the tests set DB_PASSWORD (helpers/mysql.bash).
  bootstrap_password=e2e-bootstrap
  server_image=$(image_of "$spec")
  case "$engine" in
    postgres) server_env=(-e "POSTGRES_PASSWORD=$DB_PASSWORD") ;;
    mariadb)  server_env=(-e "MARIADB_ROOT_PASSWORD=$DB_PASSWORD") ;;
    mysql|percona)
      server_env=(-e "MYSQL_ROOT_PASSWORD=$bootstrap_password")
      server_args() { printf '%s\n' --gtid-mode=ON --enforce-gtid-consistency=ON; }
      tests=mysql
      ;;
    mongodb)
      server_env=(-e MONGO_INITDB_ROOT_USERNAME=root -e "MONGO_INITDB_ROOT_PASSWORD=$DB_PASSWORD")
      # `src` and `dst` are single-member replica sets (the oplog case, with
      # authentication, which a replica set only has with a key file); `dst2`
      # is a standalone server. The tests initiate the replica sets.
      server_opts() {
        [ "$1" != dst2 ] || return 0
        printf '%s\n' --entrypoint bash
      }
      server_args() {
        [ "$1" != dst2 ] || return 0
        printf '%s\n' -c 'openssl rand -base64 48 >/tmp/keyfile && chmod 400 /tmp/keyfile && chown mongodb /tmp/keyfile && exec docker-entrypoint.sh mongod --replSet rs0 --bind_ip_all --keyFile /tmp/keyfile'
      }
      ;;
    redis|valkey)
      server_bin=redis-server
      [ "$engine" = redis ] || server_bin=valkey-server
      roles=(src dst c1 c2 c3) tests=redis server_env=()
      # The cluster speaks TLS only (certificates below), its nodes announce
      # their hostnames, and the certificate names them and nothing else.
      tls_names=(c1 c2 c3)
      tests_args=(-v "${name}-dst-data:/restore")
      server_opts() {
        case "$1" in
          dst) printf '%s\n' --restart always -v "${name}-dst-data:/data" ;;
          c?)  printf '%s\n' -v "$tls_dir:/tls:ro" ;;
        esac
      }
      server_args() {
        printf '%s\n' "$server_bin" --requirepass "$DB_PASSWORD"
        case "$1" in
          c?) printf '%s\n' --cluster-enabled yes --cluster-announce-hostname "$1" \
                --cluster-preferred-endpoint-type hostname --port 0 --tls-port 6379 \
                --tls-cluster yes --tls-auth-clients no --tls-ca-cert-file /tls/ca.crt \
                --tls-cert-file /tls/server.crt --tls-key-file /tls/server.key ;;
        esac
      }
      ;;
    sqlite)
      [ -n "$server_image" ] || { echo "unknown SQLite application image in $spec" >"$log"; exit 1; }
      # The application: a writer per journal mode on a volume of its own,
      # which the tests see read-only where a node sees a pod's volume, once
      # as a local volume and once as the kubelet's mount of a CSI volume.
      roles=(src) server_env=()
      server_opts() {
        printf '%s\n' -v "${name}-data:/data" -v "$PWD/tests/e2e/helpers/sqlite-writer.py:/writer.py:ro"
      }
      server_args() {
        printf '%s\n' sh -c 'mkdir -p /data/wal /data/delete; python3 /writer.py /data/wal/app.db wal /data/wal/ready & python3 /writer.py /data/delete/app.db delete /data/delete/ready & wait'
      }
      tests_args=(-e "SQLITE_APP_IMAGE=$server_image"
                  -v "${name}-data:/node/var/lib/rancher/k3s/storage/pvc-local_app_local-data:ro"
                  -v "${name}-data:/node/var/lib/kubelet/pods/e2e-pod/volumes/kubernetes.io~csi/pvc-csi/mount:ro")
      ;;
    *) echo "unknown engine in $spec" >"$log"; exit 1 ;;
  esac

  cleanup() {
    local role
    # A run that failed before its tests (set -e) still has its watchdog,
    # which would otherwise report the version stuck long after it is gone.
    [ -z "${watchdog:-}" ] || kill "$watchdog" 2>/dev/null || true
    # -v: the server images declare their data directory a volume, which
    # would otherwise outlive the container.
    for role in "${roles[@]}" tests; do docker rm -f -v "${name}-${role}" >/dev/null 2>&1 || true; done
    docker volume rm "${name}-data" "${name}-dst-data" >/dev/null 2>&1 || true
    docker network rm "$name" >/dev/null 2>&1 || true
    [ -z "${tls_dir:-}" ] || rm -rf "$tls_dir"
  }
  trap cleanup EXIT
  cleanup

  # tls_names: a CA and a server certificate for these DNS names (no IP
  # address) in $tls_dir, mounted at /tls into the test container.
  if [ -n "${tls_names[*]:-}" ]; then
    tls_dir=$(mktemp -d)
    san=$(printf 'DNS:%s,' "${tls_names[@]}")
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=e2e-ca \
      -keyout "$tls_dir/ca.key" -out "$tls_dir/ca.crt" 2>/dev/null
    openssl req -newkey rsa:2048 -nodes -subj "/CN=${tls_names[0]}" \
      -keyout "$tls_dir/server.key" -out "$tls_dir/server.csr" 2>/dev/null
    printf 'subjectAltName=%s\n' "${san%,}" >"$tls_dir/ext"
    openssl x509 -req -in "$tls_dir/server.csr" -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" \
      -CAcreateserial -days 2 -extfile "$tls_dir/ext" -out "$tls_dir/server.crt" 2>/dev/null
    # The servers run as an unprivileged user: mktemp -d makes the directory
    # 0700, which a Linux bind mount keeps (Docker Desktop does not show it).
    chmod 755 "$tls_dir"
    chmod 644 "$tls_dir"/*
    tests_args+=(-v "$tls_dir:/tls:ro")
  fi

  checkout=()
  if [ "${E2E_DB_SCRIPTS_FROM_CHECKOUT:-}" = "1" ]; then
    checkout=(-v "$PWD/tests/e2e:/tests/e2e:ro")
    for script in docker/rootfs/usr/local/bin/backup-* docker/rootfs/usr/local/bin/restore-* \
                  docker/rootfs/usr/local/bin/mongodb-admin \
                  docker/rootfs/usr/local/bin/sqlite-copy docker/rootfs/usr/local/bin/redis-rdb-sync; do
      checkout+=(-v "$PWD/$script:/usr/local/bin/${script##*/}:ro")
    done
    checkout+=(-v "$PWD/docker/rootfs/usr/local/lib/mysql-engine.sh:/usr/local/lib/mysql-engine.sh:ro")
  fi

  {
    echo "▶ $spec ($server_image)"
    # A server version that hangs would hold its slot, and the job, until
    # GitHub's limit without a line of output: its log is printed when it is
    # done. After E2E_DB_TIMEOUT seconds the watchdog says so, shows what the
    # test container is running and the output of the test that is stuck
    # (where bats keeps it while the test runs), and stops the test container,
    # which fails the run below with the servers' state and logs.
    (
      sleeper=""
      trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
      sleep "$TIMEOUT" & sleeper=$!
      wait "$sleeper"
      echo "✗ $spec: no result after ${TIMEOUT}s (E2E_DB_TIMEOUT), stopped"
      docker ps -a --filter "name=${name}-" --format '── {{.Names}}: {{.Status}}' 2>&1 || true
      if docker exec "${name}-tests" true 2>/dev/null; then
        echo "── running in ${name}-tests"
        docker exec "${name}-tests" sh -c '
          ps -o pid,ppid,etime,args
          for out in /tmp/bats-run-*/test/*.out; do
            [ -e "$out" ] || continue
            echo "── output so far of: $(cat "${out%.out}.name" 2>/dev/null)"
            tail -n 60 "$out"
          done' 2>&1 || true
        docker kill "${name}-tests" >/dev/null 2>&1 || true
      else
        # Stuck in a docker command of its own (a server image that does not
        # arrive): that command is ended, the run fails there and its EXIT
        # trap removes what it created. Ending the shell instead would leave
        # the command to create its container after the cleanup.
        self=$(exec sh -c 'echo "$PPID"')
        for pid in $(pgrep -P "$$"); do
          [ "$pid" = "$self" ] || kill -TERM "$pid" 2>/dev/null || true
        done
      fi
    ) &
    watchdog=$!
    # The phases in seconds, for the summary: the server image (pulled at the
    # start of the run; a version that gets there first waits for that pull),
    # starting the servers, and the tests, which note when the servers
    # answered (`# servers ready after Ns`, counted from their start).
    phase=$SECONDS
    docker image inspect "$server_image" >/dev/null 2>&1 || docker pull -q "$server_image" >/dev/null
    t_image=$((SECONDS - phase)) phase=$SECONDS
    docker network create "$name" >/dev/null
    for role in "${roles[@]}"; do
      opts=() args=()
      while IFS= read -r line; do opts+=("$line"); done < <(server_opts "$role")
      while IFS= read -r line; do args+=("$line"); done < <(server_args "$role")
      docker run -d -q --name "${name}-${role}" --network "$name" --network-alias "$role" \
        ${server_env[@]+"${server_env[@]}"} ${opts[@]+"${opts[@]}"} "$server_image" ${args[@]+"${args[@]}"} >/dev/null
    done
    t_servers=$((SECONDS - phase)) phase=$SECONDS
    rc=0
    # ${a[@]+…}: an empty array is "unbound" to set -u in bash 3.2 (macOS).
    # An image from before backup-redis has no valkey-cli: added here, as bats.
    docker run -q --name "${name}-tests" --network "$name" ${checkout[@]+"${checkout[@]}"} \
      ${tests_args[@]+"${tests_args[@]}"} \
      -e "DB_ENGINE=$engine" -e "DB_VERSION=$version" -e "DB_PASSWORD=$DB_PASSWORD" -e "DB_TESTS=$tests" \
      -e "DB_BOOTSTRAP_PASSWORD=$bootstrap_password" \
      -e "BATS_TEST_NAME_PREFIX=$spec: " \
      --entrypoint sh "$E2E_IMAGE" -c \
      'command -v bats >/dev/null || apk add -q --no-cache bats >/dev/null
       [ "$DB_TESTS" != redis ] || command -v valkey-cli >/dev/null || apk add -q --no-cache valkey-cli >/dev/null
       exec bats --print-output-on-failure "/tests/e2e/db/$DB_TESTS.bats"' || rc=$?
    t_tests=$((SECONDS - phase))
    # A failed run shows how its servers fared: a server that never became
    # ready leaves nothing in the bats output.
    if [ "$rc" -ne 0 ]; then
      for role in "${roles[@]}"; do
        echo "── server $role: $(docker inspect -f '{{.State.Status}}, exit code {{.State.ExitCode}}' "${name}-${role}" 2>&1)"
        docker logs --tail 25 "${name}-${role}" 2>&1 | cut -c1-400
      done
    fi
    ready=$(sed -n 's/^# servers ready after \([0-9][0-9]*\)s$/\1/p' "$log" | head -1)
    echo "${SECONDS}s: image ${t_image}s, servers ${t_servers}s, tests ${t_tests}s (servers ready after ${ready:-?}s)" >"$log.phases"
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
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
# The server images are pulled from the start, four at a time in the order the
# versions run, while the first versions run: otherwise each version pulls its
# image only when its turn comes. A version whose image is not in yet waits
# for that same pull. The summary lists each pull's time.
for spec in "${servers[@]}"; do image_of "$spec"; done | awk 'NF && !seen[$0]++' >"$logs/images"
xargs -P 4 -I{} sh -c '
  start=$(date +%s)
  if docker pull -q "$1" >/dev/null 2>&1; then result=pulled; else result=failed; fi
  echo "$1: $result in $(( $(date +%s) - start ))s" >>"$2/pulls"
' sh {} "$logs" <"$logs/images" &
pulls=$!
# Each server version logs to a file of its own and its result is printed in
# one piece when it is done, so that parallel runs do not interleave.
# The workers run as a process group of their own (set -m): an interrupted
# run hands the signal on to all of them and waits until each has removed
# its containers, volumes and network (their EXIT trap).
printf '%s\n' "${servers[@]}" >"$logs/servers"
set -m
xargs -P "$JOBS" -I{} sh -c '
  spec=$1 log="$2/$(echo "$1" | tr ":" "-").log"
  if "$0" --one "$spec" "$log"; then mark="✓"; else mark="✗"; fi
  phases=$(cat "$log.phases" 2>/dev/null || true)
  echo "$mark $spec${phases:+ $phases}" >>"$2/results"
  cat "$log"
' "$self" {} "$logs" <"$logs/servers" &
workers=$!
set +m
trap 'trap - INT TERM HUP; kill -TERM -- "-$workers" 2>/dev/null; kill "$pulls" 2>/dev/null; wait "$workers" || true; exit 130' INT TERM HUP
wait "$workers" || true
trap - INT TERM HUP
# Every version that ran had its image; a pull still going is of no use now.
kill "$pulls" 2>/dev/null || true

echo
echo "── database e2e summary: ${SECONDS}s, $JOBS at a time ──"
sort "$logs/results"
echo "── image pulls, from the start, four at a time ──"
cat "$logs/pulls" 2>/dev/null || true
if grep -q '^✗' "$logs/results"; then
  exit 1
fi
[ "$(wc -l <"$logs/results")" -eq "${#servers[@]}" ] || { echo "✗ not every server version reported a result" >&2; exit 1; }
