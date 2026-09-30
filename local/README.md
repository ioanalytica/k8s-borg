# Local test stack

Borg UI and the agents from any borg-ui source tree, running in local Docker
containers: no tag, no chart version, no registry, no cluster.

| Service | What it is | Reachable from the host |
| --- | --- | --- |
| `server` | Borg UI, built from the source tree | `http://localhost:8081` (admin / `local-admin`) |
| `server-tls` | the same server behind a certificate of a private CA | `https://localhost:8443` |
| `postgres`, `redis` | the server's database and Redis | – |
| `repo-server` | the repository server of the agent image (sshd, `borg serve`) | `ssh://borg@localhost:2222` |
| `agent` | one managed agent from the agent image; enrolls itself and registers a repository on `repo-server` | – |
| `target` | optional: a bare Debian 12 with systemd, the target of the server's `install.sh` | – |

This tests Borg UI and the agents, not the chart: the agent is started by the
image's own `/run-agent.sh`, but without the chart's reconcile Job, schedules
and backup plan.

## Use

```sh
./stack.sh build                  # both images from ../borg-ui (the submodule)
./stack.sh build ~/src/borg-ui    # … or from any other checkout, e.g. a PR head
./stack.sh up                     # start (or restart on freshly built images)
./stack.sh status                 # what runs, built from which commit
./stack.sh logs agent
./stack.sh down                   # stop, keep the data
./stack.sh reset                  # stop and delete database, repositories, enrollment
```

The images are `k8s-borg-ui:local` and `k8s-borg:local`, built for the host
architecture only. They carry no registry name and are never pushed. The
server image needs the runtime base that belongs to the source tree's Borg
versions; it is pulled if it is not there.

After a `build`, `up` recreates the containers on the new images and keeps the
data. When the new source cannot read the old data (another Borg 2 beta, an
older database schema), `reset` first.

## Licence

Managed agents need a paid plan. The server is left as the image ships it: a
new instance asks the activation service for the full-access trial on its
first start. Every `reset` makes a new instance, which asks again.
`LICENSE_SYNC=false ./stack.sh up` keeps the server offline, on the community
plan.

## Testing the installer

```sh
./stack.sh target
token="$(./stack.sh token target-1)"
./stack.sh sh target
# inside, over plain http:
curl -fsSL http://server:8081/agent/install.sh \
  | bash -s -- --server http://server:8081 --token "<token>" --name target-1 --service-user borg-ui-agent
```

For the TLS endpoint use `https://server-tls:8443`; the CA is mounted at
`/local/ca.crt` (`cp` it to `/usr/local/share/ca-certificates/*.crt`, then
`update-ca-certificates`). `./stack.sh target` again gives a fresh machine.

The stack's own agent moves to the TLS endpoint with
`AGENT_SERVER_URL=https://server-tls:8443 ./stack.sh up` after a `reset`.

## An agent outside the stack

A machine that reaches this host — a VM, another computer — enrolls like
against any server. The ports listen on 127.0.0.1 only unless told otherwise:

```sh
BIND=0.0.0.0 PUBLIC_BASE_URL=http://<this-host>:8081 ./stack.sh up
./stack.sh token my-vm
```

`PUBLIC_BASE_URL` is what the server puts into the install commands it shows.
For TLS from outside, the certificate needs the name the machine uses for this
host: remove `.state/tls` and start with
`TLS_EXTRA_SAN=DNS:<this-host>,IP:<address>`. Repositories on the repository
server are `ssh://borg@<this-host>:2222/local/<name>` with the key
`.state/ssh/id_ed25519`.

## Settings

| Variable | Default | |
| --- | --- | --- |
| `BIND` | `127.0.0.1` | address the published ports listen on |
| `SERVER_PORT`, `SERVER_TLS_PORT`, `REPO_SERVER_PORT` | `8081`, `8443`, `2222` | published ports |
| `PUBLIC_BASE_URL` | `http://localhost:8081` | the server's own idea of its URL |
| `ADMIN_PASSWORD` | `local-admin` | initial admin password (first start only) |
| `AGENT_NAME` | `agent-1` | name of the stack's agent |
| `AGENT_BORG_VERSION` | `2` | Borg major of the agent's repository |
| `AGENT_SERVER_URL` | `http://server:8081` | server URL the stack's agent enrolls at |
| `LICENSE_SYNC` | `true` | contact the activation service |
| `BASE_IMAGE` | computed | runtime base for the server build |

Keys and certificates live in `.state/` (not in git) and survive a `reset`.
