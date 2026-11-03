# Upgrading

## Upgrading to Borg 2.0.0b25 {#borg-2-0-0b25}

This concerns releases with `borg.version: 2`. **Borg 1 repositories are not
affected.** Which Borg 2 an image carries: `borg2 --version` in a pod.

> **Borg 2 repositories are test beds, not backups to rely on.** Borg 2 is a
> beta. 2.0.0b25 cannot open a repository written by 2.0.0b22–b24 (exit 15,
> "is not a valid repository"), and there is no conversion in place: every
> Borg 2 repository is created anew, and the history in the old one ends.

What changes for the clients:

- **`rest://` becomes `ssh://`.** The path rules are the same. 2.0.0b25 does not
  reject the old scheme, it reads the URL as a local directory and would back up
  into the pod's own filesystem. The chart therefore refuses a
  `borg.repoBase.value` that starts with `rest://`, and the `borg2` wrapper
  refuses such a repository before Borg runs when the Borg 2 of the image is
  2.0.0b25 or later. A base from an existing Secret is only seen by the wrapper.
  The wrapper goes by the Borg 2 of the image, the chart cannot: a release that
  pins an image with an earlier Borg 2 takes its `rest://` base from an existing
  Secret.
- **`BORG_ENCRYPTION=none` is refused**, `authenticated` creates an
  `authenticated-sha256` repository.
- **The passphrase is needed for every command.**

Before the upgrade, with the release that is still running:

1. **Restore what you still need** from the Borg 2 repositories. Where the
   history itself matters, the only bridge is one archive at a time, with both
   Borg versions side by side: `borg export-tar --tar-format BORG` from the old
   repository into `borg import-tar` of the new one. The archives get new ids.

Then, in this order:

2. **Repository server first.** It has to run the borgstore that belongs to
   2.0.0b25 (0.7.0, with the `blake3` extra); clients up to 2.0.0b24 keep
   working against it. For the [repository server](/features/repository-server)
   of this chart that is the upgrade of the release that runs it.
3. Stop the backups of the Borg 2 repositories (suspend the CronJob, pause the
   plans and schedules in Borg UI) and wait for running jobs.
4. On the server, **move the old repository directories aside. Do not delete
   them.**
5. **Upgrade the release.** With the base in `borg.repoBase.value`, change it to
   `ssh://` in the same step; the chart does not render otherwise.
6. **Then the base URL**, where it comes from an existing Secret: change it to
   `ssh://` and restart the pods. Until then they refuse to run Borg 2 and say
   why; nothing is written anywhere.
7. The pods create the repositories (`borg-init`) and move their records in
   Borg UI to the new URL. Borg UI checks a changed URL from its own server:
   when that server cannot reach the repository, it refuses, and the pod stops
   with both URLs and Borg UI's answer. It also stops, naming both modes, when
   the record's encryption mode is not the one the pod created the repository
   with; a Borg 2 record that a pod of an earlier release registered carries
   the Borg 1 name `repokey-blake2`. Change the record there by hand, or remove it
   from Borg UI without deleting data, so that the pod registers it anew.
8. Check one repository: `borg-info` prints `Repository version: 5`. Run a
   backup and a restore into an empty directory, then resume the backups.
9. Delete the directories of step 4 once the new repositories hold backups you
   have verified.

**Rollback** is the previous release with the previous base URL and the
directories of step 4 moved back. It works only as long as those directories
exist. What 2.0.0b25 has written in between cannot be read by an earlier beta.
