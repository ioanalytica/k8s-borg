# Borg 1 and Borg 2

<!--@include: ../../README.md#borg2-warning-->

`borg.version` (`1` or `2`) selects the borg **binary** used by the scripts. The
**transport** is the URL scheme in `borg.repoBase` and is independent of the
version: `ssh://` (server has borg installed, works with 1 and 2) or `sftp://`
(plain SFTP target with no server-side borg — borg 2 only).

The two majors read the same `ssh://` URL differently:

| | relative to the login directory | absolute |
| --- | --- | --- |
| Borg 1 | `ssh://user@host:22/./cluster` | `ssh://user@host:22/srv/cluster` |
| Borg 2 | `ssh://user@host:22/cluster` | `ssh://user@host:22//srv/cluster` |

| | Borg 1 | Borg 2 |
| --- | --- | --- |
| `borg.remotePath` (`BORG_REMOTE_PATH`) | the `borg` wrapper adds `--remote-path=<value>` to every call | read by Borg itself; the option no longer exists (removed in 2.0.0b22) |
| `borg.encryption` (`BORG_ENCRYPTION`, read by `borg-init` and `register-repo`; empty = the default) | `repokey-blake2` (default), `repokey`, `keyfile-blake2`, `keyfile`, `authenticated-blake2`, `authenticated`, `none` | `repokey-aes-ocb` (default), `repokey-chacha20-poly1305`, `keyfile-aes-ocb`, `keyfile-chacha20-poly1305`, `authenticated` (= `authenticated-sha256`). No `none`, no `authenticated-blake3` (Borg UI has no name for it) |
| `borg.passphrase` | needed for the modes with a key | mandatory: from 2.0.0b25 on there is no repository without a key, and every command needs it, `break-lock` and `repo-delete` included |
| port | taken from the URL | taken from the URL, unless a remote shell command is set (`BORG_RSH`, `BORGSTORE_RSH`): that command is used as it is and has to name the port, `ssh -p 2222`. The chart sets neither |
| `rest://` | never a repository URL | the name of `ssh://` up to 2.0.0b24; refused from 2.0.0b25 on |

`borg.encryption` sets the mode of the repositories the pods create. A mode the
chosen `borg.version` does not have fails the render with the list of valid
ones. It never changes a repository that exists: `borg-init` only creates one
where there is none, and `register-repo` sends the mode only when it records a
repository for the first time. A record it moves to a changed base keeps its
mode, so `register-repo` moves it only when that mode is the one `borg-init`
created the new repository with. Otherwise the pod stops and names both modes
and both paths: change `borg.repoBase` and `borg.encryption` in the same
upgrade, and you remove the record in Borg UI (without deleting data) so that
the pod registers the repository anew, with its mode.

## Both majors in one image {#wrappers}

Both Borg majors ship so a repository can be served by either — the server (or
your config) chooses per repo:

| Command (PATH) | Version | Real binary run by the wrapper |
| --- | --- | --- |
| `borg`  | 1.x (compiled venv)      | `/opt/borg-ui-agent/borg1/current/borg` |
| `borg2` | 2.x beta (compiled venv) | `/opt/borg-ui-agent/borg2/current/borg` |

`borg2`'s borgstore carries every repository backend — sftp, s3, rclone and
rest. It can use plain **SFTP** repositories with **no server-side Borg**, e.g.
a Hetzner Storage Box, which only ships server-side Borg 1.x, as well as S3
buckets and rclone remotes. Borg 2's repo format is incompatible with Borg 1
(migrate with `borg transfer`), and Borg 2 is beta — its on-disk format can
change between betas, so use the same `borg2` build everywhere, and do not use
it for real backups yet.

Borg 2 and borgstore are installed as a pair: Borg 2 at the version of the
`borg-ui` manifest, borgstore at exactly the version
`borg-ui/docker/runtime-base.env` states, with the `blake3` extra. A borgstore
version that does not fit the Borg 2 being built fails the build.

The image runs as **root**, so backups can read any source path with no
privilege juggling. On `PATH`, `borg` and `borg2` (`docker/rootfs/usr/local/bin/`)
are thin wrappers that inject default params and exec the real binary. SSH config
and credentials live in `/root/.ssh` (e.g. mounted by an initContainer from a
Secret). Each wrapper injects default common params:

| Env var | Default | Purpose |
| --- | --- | --- |
| `BORG1_DEFAULT_PARAMS` | (empty) | Borg 1; set e.g. `--remote-path=borg-1.4` for a Hetzner Storage Box over `ssh://` |
| `BORG2_DEFAULT_PARAMS` | (empty) | Borg 2; reaches a Storage Box over `sftp://`. Borg 2 has no `--remote-path` |

Server-provided flags override them (borg's argparse lets the last `--remote-path` win).

`BORG_REMOTE_PATH` becomes `--remote-path=<value>` in the `borg` wrapper. Borg 2
dropped that option in 2.0.0b22 and reads the variable itself, so the `borg2`
wrapper adds nothing.

The `borg2` wrapper refuses a `rest://` repository (`BORG_REPO`, `-r`, `--repo`)
when its binary is Borg 2.0.0b25 or later. That Borg has no such scheme and
would read the URL as a local directory; the repository is an `ssh://` one now.
With an earlier Borg 2 in the image the wrapper lets a `rest://` repository
pass. See [Upgrading to Borg 2.0.0b25](/operations/upgrading).

## Keyfile modes and where the keys live {#keyfile-modes}

The keyfile modes (`keyfile`, `keyfile-blake2` for Borg 1, `keyfile-aes-ocb`,
`keyfile-chacha20-poly1305` for Borg 2) keep the repository's key outside the
repository, in a file of the client. The passphrase does not replace that
file: a repository without its key cannot be read.

Every backup workload sets `BORG_KEYS_DIR=/etc/borg-ui-agent/borg-keys`, in
every mode, so Borg writes its key files to the `persistence.uiAgent` volume,
next to the agent's `config.toml`. That volume is mounted per node
(`<volume>/<node>/borg-keys`), and the cluster CronJob and the console pod
share the cluster's directory, so both read the key the first of them wrote.
The volume is kept on `helm uninstall` (`persistence.uiAgent.retain`). Borg
finds a key by the repository id inside the file, not by the file name.

- **Export the key after the first backup** and keep it apart from the
  cluster: a lost volume means repositories nobody can read.

  ```sh
  # Borg 1
  kubectl -n <namespace> exec <pod> -- sh -c 'borg key export "$BORG_REPO"' > <node>.borg-key
  # Borg 2
  kubectl -n <namespace> exec <pod> -- sh -c 'borg2 key export' > <node>.borg-key
  ```

  Import brings it back into `BORG_KEYS_DIR` of a pod of the same node:

  ```sh
  # Borg 1
  kubectl -n <namespace> exec -i <pod> -- sh -c 'borg key import "$BORG_REPO" -' < <node>.borg-key
  # Borg 2
  kubectl -n <namespace> exec -i <pod> -- sh -c 'borg2 key import --key-location=keyfile -' < <node>.borg-key
  ```

  Borg 2 needs `--key-location=keyfile`: without it, the imported key is stored
  in the repository as a repokey key, not in `BORG_KEYS_DIR`.

  A key the chart took from a Secret could only serve such a restore: Borg
  creates the key when it creates the repository, so it cannot be supplied in
  advance.
- **An agent reset removes `config.toml` only.** Wiping the node's whole
  directory on that volume deletes `borg-keys/` with it.
- **Borg UI never gets the key**, just as it never gets the agent's SSH key:
  `register-repo` records the repository without it, and Borg UI is meant to
  run every operation on an agent's repository through the agent, which reads
  the key in the pod. An operation Borg UI still runs on its own server for
  such a repository fails for a keyfile repository.
