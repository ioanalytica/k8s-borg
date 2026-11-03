# Environment variables

Core settings (standalone mode), supplied via env / mounted secrets:

| Env var | Purpose |
| --- | --- |
| `BORG_MODE` | `cluster` (default) or `node` — selects the workload's backup flow |
| `NODE_NAME` | Node identity (archive naming; injected from the Downward API) |
| `BORG_REPO` | The Borg repository this pod owns |
| `BORG_PASSPHRASE` | Repository passphrase. Mandatory for Borg 2: every command needs it from 2.0.0b25 on |
| `BORG_ENCRYPTION` | Mode of a repository `borg-init` creates, by Borg UI's name for it; `register-repo` records the same mode. Borg 1: default `repokey-blake2`. Borg 2: default `repokey-aes-ocb`; `authenticated` stands for `authenticated-sha256`; there is no `none`, and `authenticated-blake3` is refused (Borg UI has no name for it) |
| `BORG_REMOTE_PATH` | Name or path of the borg executable on an `ssh://` server |
| `DB_BACKUP_LOCATION` | Where logical DB dumps are written before archiving |
| `S3_ENDPOINT`, `S3_MOUNTPOINT`, `AWS_KEY`, `AWS_SECRET_KEY` | S3 sources (cluster/app jobs; never mounted for node backups) |
| `S3_REGION` | SigV4 region of the S3 endpoint (s3fs `endpoint=`). Empty keeps s3fs's `us-east-1`; servers that check the region, such as Garage, need it |
| `S3_PROBE_TIMEOUT` | Seconds a freshly mounted bucket may take to answer a listing (default 30). A bucket that fails or does not answer is unmounted again and handled by `S3_ON_MOUNT_FAILURE`; s3fs itself reports success in that case and leaves a mount that blocks its first reader |
| `S3_ON_MOUNT_FAILURE` | `skip` (default) or `fail`. With `skip`, a bucket that cannot be mounted is skipped with a warning, the start stops only when no listed bucket can be mounted, and `borg-backup` ends with a warning while a listed bucket is not mounted (an error when none is). With `fail`, one bucket that cannot be mounted stops the start and fails the backup |
| `S3_VERIFY_LISTING` | `true` (default) or `false`. Before `borg create`, `s3-verify-listing` compares each mounted bucket with its listing through the S3 API; a bucket whose mount misses objects, or that is not mounted, is mounted again, and one that still misses them fails the run after archiving |

Mounted files the standalone flow expects: `/root/.borg/{cluster,node}-{include,exclude}.patterns`,
`/root/.borg/cluster-s3-buckets`, and SSH material in `/root/.ssh/`
(`id_ed25519`, `id_ed25519.pub`, `known_hosts`).

Borg UI managed-agent mode (`BORG_UI_AGENT=true`) additionally uses:

| Env var | Purpose |
| --- | --- |
| `BORG_UI_SERVER` | Server URL, e.g. `http://k8s-borg-ui.borg.svc.cluster.local:8081` |
| `BORG_UI_AGENT_NAME` | Agent name at the server (default: hostname) |
| `BORG_UI_ADMIN_USER`, `BORG_UI_ADMIN_PASS` | Admin credentials — only for the one-time enrollment |
| `BORG_UI_CONFIG` | Agent config path (default `/etc/borg-ui-agent/config.toml`; persist it to avoid re-enrolling) |
