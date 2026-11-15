# Morpheus Outpost integration

This directory provides two fixed, structured Outpost functions without changing the legacy scripts:

- `lvm-backup-check` returns `BACKUP_POSSIBLE` or `BACKUP_NOT_POSSIBLE`.
- `lvm-backup-run` repeats every check under an exclusive lock, creates the snapshot and returns
  `BACKUP_SUCCESSFUL` or `BACKUP_FAILED` with a bounded log tail.

Domain failures deliberately exit with code 0. Morpheus Outpost only extracts and validates JSON data for a
successful process exit; callers must therefore evaluate `data.status`. Exit codes other than zero are reserved for
an invalid installation or another failure that prevents a protocol result from being produced.

## Safety model

The check rejects a run when:

- any LVM logical volume on the host has an origin (an active classic or thin snapshot/clone);
- the configured backup filesystem is not mounted (so a missing disk cannot fill `/`);
- the volume group cannot accommodate the configured snapshot size;
- free archive space is smaller than the mean size of completed `.fsa` files from the configured history window,
  multiplied by the safety percentage, plus the fixed reserve.

Until history exists, `INITIAL_ESTIMATE_GIB` is used. Only final `.fsa` files count; partial or failed archives do
not distort the estimate. The run repeats all checks after taking `flock`, because the check and run are separate
Outpost jobs and conditions can change between them.

The archive is written as `.fsa.part`, verified with `fsarchiver archinfo`, checked for snapshot overflow, given a
SHA-256 sidecar and only then renamed to its final name. A trap removes the snapshot on success, failure, signal or
Outpost timeout. Backup data is read from the snapshot device, never from the live origin.

## Installation

Install dependencies (`lvm2`, `fsarchiver`, `jq`, `util-linux`, `coreutils`, `findutils`) and then, as root:

```bash
install -o root -g root -m 0755 outpost/scripts/*.sh /etc/morpheus-outpost/scripts/
install -o root -g root -m 0644 outpost/config.sh.example \
  /etc/morpheus-outpost/scripts/lvm-backup-config.sh
install -o root -g root -m 0644 outpost/functions/*.yaml /etc/morpheus-outpost/functions/
```

Edit `/etc/morpheus-outpost/scripts/lvm-backup-config.sh`, especially `VOLGRP`, `LOGVOL`, `BACKUP_MOUNT`,
`BACKDIR`, the initial size estimate and snapshot size. Keep the file root-owned and not group/world-writable.

Then refresh sudoers and validate both functions:

```bash
sudo morpheus-outpost function install-sudoers
sudo morpheus-outpost function validate lvm-backup-check
sudo morpheus-outpost function validate lvm-backup-run
sudo systemctl restart morpheus-outpost
```

The Outpost service runs in a systemd sandbox (`ProtectSystem=full`), and scripts started through sudo inherit it:
`/etc`, `/usr` and `/boot` are read-only. LVM writes metadata archives to `/etc/lvm/archive` and `/etc/lvm/backup`
before every change, so without a drop-in `lvcreate` fails with
`Cannot archive volume group metadata for <vg> to read-only filesystem`. Allow `/etc/lvm` plus the configured backup,
log and lock paths (`-` = ignore a path that does not exist, e.g. an unmounted backup disk):

```bash
sudo systemctl edit morpheus-outpost
```

```ini
[Service]
ReadWritePaths=-/etc/lvm -/media/backups -/var/log/lvm-backup-outpost -/run/lock
```

```bash
sudo systemctl restart morpheus-outpost
```

The unit also sets `ProtectKernelModules=yes`, so the service cannot load kernel modules. Make sure `dm-snapshot` is
loaded at boot (`lsmod | grep dm_snapshot`; otherwise `echo dm-snapshot | sudo tee /etc/modules-load.d/dm-snapshot.conf`).

The drop-in does not change any function hash; no new approval is needed.

After every script or manifest update, review and approve the new function hash in Morpheus.

Run the local precondition tests with `outpost/tests/test-check.sh`. They use mocked LVM/mount commands and sparse
archive files; they never access or change real logical volumes.

## Platform orchestration contract

1. Invoke `lvm-backup-check` and continue only when the Outpost job is `SUCCEEDED` and
   `data.status == "BACKUP_POSSIBLE"`.
2. Invoke `lvm-backup-run` asynchronously. The run does not trust the earlier check and checks again.
3. React to `outpost/<name>/job/lvm-backup-run`, load the job envelope and evaluate `data.status`.
4. Let the platform send mail from the structured result. No Outpost script sends notifications.

For `BACKUP_FAILED`, `data.reason` is a stable summary and `data.logTail` contains at most the configured number of
lines and 48 KiB, so JSON remains below the Outpost output limit. Full logs stay locally in `LOG_DIR`.
