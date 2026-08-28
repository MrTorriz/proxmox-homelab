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

> **Status 2026-08-28: tier 2 is offline.** The backup disk dropped off the SATA bus
> during a host reboot on 2026-07-17 (`ata3: SATA link down`). After the next reboot on
> 2026-07-25 it enumerates with a capacity of 0 B (`detected capacity change from
> 1953525168 to 0`) — a dead drive, not a loose cable. `/mnt/vzbackup` is empty (fstab
> `nofail`), `pvesm status` reports the storage `inactive`, and the scheduled job has
> failed every Sunday since 2026-07-19 with `could not activate storage 'vzbackup'` —
> the first failure notified a dead `mail-to-root`, every one since 2026-07-26 went
> through ntfy. The last good images were on the dead disk. The only
> VM image on the host today is an emergency dump of VM 105 (77 MB, on `local`,
> 2026-07-25). **No image of VM 100 or 101 exists.**
>
> Tier 1 is unaffected: the nightly appdata run on 2026-08-28 completed (21 GB; offsite
> push finished 06:40 UTC with 0 errors). How the failure stayed unnoticed for eight days
> is [lesson #15](lessons.md#15-nofail--is_mountpoint-hide-a-dead-backup-target--alert-on-missing-successes-not-just-failures);
> bringing the tier back is in the [runbook](runbook.md#the-backup-hdd-dies).

Whole-VM images for fast "roll the box back" — convenience, not DR. If the backup disk
dies, nothing irreplaceable is lost. (It did. Nothing was.)

| | As designed | 2026-08-28 |
|---|---|---|
| Target | Dedicated 1 TB SATA HDD, ext4, mounted as a `dir` storage | Disk dead; storage `inactive` |
| Schedule | Sundays 02:00 (host time) | Still scheduled — runs, fails, notifies |
| VMs | 100 (workload) + 101 (Windows) + 105 (**vpn-gw**) | No image of 100 or 101; 105 has the 77 MB emergency dump on `local` |
| Mode | `snapshot` — live, no downtime | — |
| Compression | zstd | — |
| Retention | `keep-last=3` | Nothing to prune |

Details that matter:

- **`is_mountpoint=1` on the storage.** If the backup disk is absent, Proxmox refuses to
  write instead of silently filling the NVMe root with images. This is exactly what it
  did on 2026-07-19 and every Sunday since: a failed job and a notification, not a full
  root filesystem.
- **Passthrough disks are `backup=0`**, so images stay tens of GB instead of impossible
  (8 TB of raw disk).
- **The gateway VM is in the job.** Easy to forget because it's tiny — but it's the
  single point of failure for all VPN-LAN traffic, and a 4 GB image is cheap insurance.
- The backup disk was an old consumer drive — SMART-clean right up to the reboot it
  didn't survive. Acceptable *because* this tier is secondary; what "acceptable" did not
  cover was finding out eight days late ([lesson #15](lessons.md#15-nofail--is_mountpoint-hide-a-dead-backup-target--alert-on-missing-successes-not-just-failures)).

## Snapshots are not backups

`qm snapshot 100 pre-change` before any risky change — instant and free. But it lives in
the same thin pool as the VM disk; it is a short-term undo button, not a backup. Take it
anyway — and treat it as exactly that.

**While tier 2 is offline, risky work waits.** Anything that would need an image restore
to back out of (a major upgrade of the workload VM, storage or passthrough changes,
a host upgrade) is postponed until `vzbackup` is back and a fresh image of VM 100 exists.

## Manual image before risky work

```bash
# Fails while the vzdump storage is inactive (since 2026-07-17):
vzdump 100 --storage vzbackup --mode snapshot --compress zstd
```

Do **not** point this at `local` for VM 100: on 2026-08-28 `local` had 63 316 504 KiB
(~60 GiB) available and the last VM 100 image was ~78 GB — it does not fit, and a
half-written image on the root filesystem is worse than none. `local` is only an option
for a small guest (the 4 GB vpn-gw, whose 77 MB emergency dump lives there) and only
after an explicit `pvesm status` capacity check.
