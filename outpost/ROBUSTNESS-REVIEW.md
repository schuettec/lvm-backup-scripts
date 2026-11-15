# Review of the legacy scripts

The existing scripts remain unchanged for compatibility. They should not be used as the implementation behind an
unattended Outpost job.

## Critical findings

1. `backup-lvm.sh` creates a snapshot but archives `/dev/$VOLGRP/$LOGVOL`, the live origin. The intended consistent
   snapshot is never read.
2. Failures of `mkdir`, `touch`, `lvcreate`, `lvremove`, checksum creation and pipeline stages are often printed but
   do not stop the run. A failed snapshot creation can therefore be followed by a reported successful live backup.
3. There is no trap. Cancellation, timeout, reboot or signal can leave snapshots and lock files behind.
4. `start-backup-lvm.sh` pipes through `tee` without `pipefail`/`PIPESTATUS`; its exit status can reflect `tee` rather
   than the backup. Callers may report success after `fsarchiver` failed.

## High-severity findings

- Archive-destination capacity is not checked, and a missing backup mount can redirect data onto the root filesystem.
- The lock is a racy marker file rather than a kernel lock. It neither prevents concurrent starts atomically nor
  proves that an owner is alive.
- Only one configured lock filename is considered; other LVM snapshots are not detected.
- Snapshot capacity is treated as both minimum free VG space and snapshot size, without overflow validation.
- Archives are written directly to their final names; consumers cannot distinguish incomplete files.
- MD5 detects accidental damage but is obsolete for integrity-sensitive workflows; checksum creation is unchecked.
- Variables and option strings are generally unquoted, allowing whitespace/globbing breakage and making config
  mistakes hazardous under root.

## Additional findings

- Dependencies are incomplete (`bc`, `md5sum`, `tee` and others are used but not consistently checked), while
  unrelated mail/gzip dependencies are required by the generic starter.
- Paths depend on the current working directory, so service execution from another directory breaks configuration.
- The timestamp has minute resolution, permitting filename collisions.
- `restore-lvm.sh` has hard-coded target LVs and performs no archive/checksum/target safety validation. Restore should
  remain an explicitly supervised, separately hardened workflow.
- Desktop notification discovery and `sudo -u` add session-dependent behavior inappropriate for a headless service.
- `sendmail.sh` hard-codes recipient and filesystem and mixes notification policy with backup execution.

The implementation in this directory addresses these findings for creation and orchestration. It intentionally does
not automate restore or retention/deletion; those require an explicit policy and separate authorization.
