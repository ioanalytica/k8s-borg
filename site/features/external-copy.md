# External copy

`repoServer.offsite.enabled=true` adds a CronJob that copies every repository
below the data directory to an rclone remote: S3-compatible storage, an SFTP
target such as a Hetzner Storage Box, or any other remote rclone knows. It is
there for one case: the server's storage fails.

> **The copy is a mirror, not a second backup.** What a client deletes or
> compacts disappears from the copy with the next run. Against deletions by a
> client there is `no-delete` (see [Directories and permissions](/features/repository-server#directories-and-permissions)); against everything else — a
> compromised server included, which holds the credentials of the remote —
> only the remote itself helps: versioning or object lock on a bucket, snapshots
> of a Storage Box.

What the job does:

- **It reads the server's volume read-only**, as `repoServer.runAsUser`, on the
  server's node, without root or capabilities, like the server itself. The
  clients notice nothing and never see the remote's credentials.
- **One repository at a time, at the same path below `target` as below the data
  directory.** A repository that does not exist locally is never touched on the
  remote: a server that starts on a new, empty volume does not empty the copy.
  A repository a client deletes altogether stays on the remote until you remove
  it there.
- **No lock and no passphrase.** Borg 2 seals its locks with the repository key,
  and the server never holds one. Instead every repository is copied in the
  order Borg writes it — segments or packs first, then what refers to them, then
  the deletions — and the copy only counts if nothing in the repository changed
  meanwhile and no client held a lock at either end. Otherwise it is taken
  again, `retries` times at most. **Schedule it outside the backup windows**:
  a repository that keeps changing fails the run.
- **A failed run is a failed Job** (`backoffLimit: 0`); its log names every
  repository that was not copied. The others are copied all the same. A run
  by hand: `kubectl create job --from=cronjob/<release>-repo-server-offsite offsite-now`.

```yaml
repoServer:
  offsite:
    enabled: true
    target: offsite:k8s-borg        # <remote>:<path>, the remote from rclone.conf
    schedule: "0 4 * * *"
    bwlimit: "08:00,2M 20:00,off"   # rclone --bwlimit, optional
    rcloneConfig:
      existingSecret: k8s-borg-offsite   # key rclone.conf
```

`rcloneConfig`, `sshKey` and `knownHosts` each take a `value` or an existing
Secret (`existingSecret`, `existingSecretKey`), and are mounted as
`/etc/borg-offsite/rclone.conf`, `ssh_key` and `known_hosts`. Further rclone
options go to `extraArgs`; `transfers` (default 4) is how many files move in
parallel.

S3-compatible storage:

```ini
[offsite]
type = s3
provider = Other
endpoint = https://s3.example.com
region = eu-central-1
access_key_id = …
secret_access_key = …
# a key that may not create buckets:
no_check_bucket = true
```

A Hetzner Storage Box (or any SFTP server), with `sshKey` and `knownHosts`:

```ini
[offsite]
type = sftp
host = u123456.your-storagebox.de
port = 23
user = u123456
key_file = /etc/borg-offsite/ssh_key
known_hosts_file = /etc/borg-offsite/known_hosts
```

```sh
ssh-keyscan -p 23 u123456.your-storagebox.de   # the line for knownHosts
```

Without `known_hosts_file` rclone accepts any host key.

::: tip Restore
Rebuilding the server from the copy, and reading the copy without a server, are described under [Disaster recovery](/operations/disaster-recovery#repository-server).
:::
