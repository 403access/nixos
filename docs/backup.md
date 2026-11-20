# Backup status for `/mnt/tank`

Current state of the 5.92 TB pool and what is still missing.

Last reviewed: **2026-11-20**.

## What exists now

| Layer | Status |
|---|---|
| ZFS mirror (2x 8 TB HDD) | ✅ survives one disk failure |
| Monthly scrub | ✅ `zfs-scrub.timer`, last 2026-11-02, 0 errors |
| Local snapshots | ✅ sanoid: 30 daily, 8 weekly, 12 monthly (`zfs.nix`) |
| Offsite copy | ❌ **not configured** |
| Encryption at rest | ❌ pool unencrypted (see `SECURITY.md`) |

Snapshots recover from deletion, overwrites and application corruption:

```bash
ls /mnt/tank/.zfs/snapshot
sudo zfs diff tank@autosnap_2026-11-20_00:00:00_monthy | head
```

They do **not** survive disk loss, theft, fire, ransomware with root, or a
mistaken `zfs destroy`. A mirror plus snapshots on the same two disks is still
a single failure domain.

## Decision

Offsite backup is deferred for now (user decision, 2026-11-20). This file
records the options so the work can resume without rediscovery.

## Candidate targets

| Target | Notes |
|---|---|
| Jottacloud (`jotta-cli` is installed) | Unlimited personal storage; check client version and bandwidth. `jotta-cli status` |
| rclone remote | Any S3/B2/Drive/SFTP backend. `rclone listremotes` |
| restic to the 465 GB `sdc` SSD | Enough for critical directories only, not the full 5.92 TB |
| External USB disk | Cheapest per TB, but needs a rotation schedule |

Do not put the backup on `tank` itself. A snapshot is not a backup.

## Before implementing

1. Confirm the account and quota:

   ```bash
   jotta-cli status
   rclone listremotes
   ```

2. Measure the real change rate; snapshot deltas are the honest number, not
   the 5.92 TB total:

   ```bash
   zfs list -t snapshot -o name,used -s creation | tail -5
   ```

3. Decide encryption of the backup (restic encrypts; `rclone crypt` wraps a
   remote; Jottacloud encrypts at rest but you hold the account).

## Suggested shape

One systemd timer, not a shell loop in a login session:

```nix
systemd.services.tank-backup = {
  serviceConfig = {
    Type = "oneshot";
    User = "root";
    # restic example, repository on an external disk or rclone remote
    ExecStart = "${pkgs.restic}/bin/restic backup /mnt/tank --exclude-caches";
  };
};
systemd.timers.tank-backup = {
  wantedBy = [ "timers.target" ];
  timerConfig.OnCalendar = "daily";
};
```

Rules that prevent the classic disasters:

- Never `rclone sync` a source into a target that is also your backup: a
  local deletion propagates. Use `copy` or a versioned backend.
- Keep at least one backup **offline** or append-only (ransomware).
- Verify restores, not just job exit codes: restore one random directory
  monthly.
- Alert on failure. A backup that silently stopped is worse than none,
  because it is trusted.
- Keep the ZFS snapshots even after offsite is working; they are the fast
  undo, the offsite copy is the disaster recovery.

## See also

- [`../zfs.nix`](../zfs.nix) — sanoid retention and ARC cap
- [`../SECURITY.md`](../SECURITY.md) — Samba, SSH, encryption
- [`../scripts/zfs-audit.sh`](../scripts/zfs-audit.sh) — current pool state