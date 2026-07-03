# Backup strategy

Two independent tiers. Mixing them up is how you end up with backups that restore the
wrong thing — or nothing.

## Tier 1 — application data, offsite, encrypted (the real DR)

Container appdata, secrets (`.env`), and database dumps are packed and pushed encrypted
to cloud storage (rclone crypt remote) on a nightly cron **inside VM 100**. The rclone
config/key lives in a password manager — it's the chicken-and-egg secret: with it you can
decrypt the backup and pull everything else back.

This tier is what disaster recovery actually restores from. It rebuilt the entire
workload after the [bare-metal → VM migration](migration.md) — the same flow works if
VM 100 dies tomorrow: fresh cloud-init VM, pull archives, unpack, `docker compose up -d`.

Media on the passthrough drives is **not** in this tier — 6+ TB doesn't fit an offsite
budget. The drives themselves are the media store; the irreplaceable subset (photos,
documents) is what tier 1 covers.

## Tier 2 — VM images (`vzdump`), local, scheduled

Whole-VM images for fast "roll the box back" — convenience, not DR. If the backup disk
dies, nothing irreplaceable is lost.

| | |
|---|---|
| Target | Dedicated 1 TB SATA HDD, ext4, mounted as a `dir` storage |
| Schedule | Sundays 02:00 |
| VMs | 100 (workload) + 101 (Windows) + 105 (**vpn-gw**) |
| Mode | `snapshot` — live, no downtime |
| Compression | zstd |
| Retention | `keep-last=3` |

Details that matter:

- **`is_mountpoint=1` on the storage.** If the backup disk is absent, Proxmox refuses to
  write instead of silently filling the NVMe root with images.
- **Passthrough disks are `backup=0`**, so images stay ~40–60 GB instead of impossible
  (8 TB of raw disk).
- **The gateway VM is in the job.** Easy to forget because it's tiny — but it's the
  single point of failure for all VPN-LAN traffic, and a 4 GB image is cheap insurance.
- The backup disk is an old consumer drive (SMART-clean, but old). That's acceptable
  *because* this tier is secondary — check `smartctl -A` on it now and then.

## Snapshots are not backups

`qm snapshot 100 pre-change` before any risky change — instant and free. But it lives in
the same thin pool as the VM disk; it's an undo button, not a backup. Take it anyway.

## Manual image before risky work

```bash
vzdump 100 --storage <backup-storage> --mode snapshot --compress zstd
```
