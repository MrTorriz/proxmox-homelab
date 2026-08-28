# Runbook — when things break

Scenarios ordered by likelihood × pain. Everything here leans on the
[backup strategy](backup.md): **tier 1** = encrypted offsite appdata (nightly),
**tier 2** = local vzdump images (weekly by design — **offline since 2026-07-17**, the
backup disk died; see [backup.md](backup.md#tier-2--vm-images-vzdump-local-scheduled)).
The full-rebuild path isn't theoretical — it's exactly what [the migration](migration.md)
executed, in one evening.

## VM 100 (workload) won't boot or is corrupt

**Fast path — roll back the VM (~30 min):** *Not available while tier 2 is offline — no
image of VM 100 exists. Go to the slow path.* Once the backup disk is replaced and the
job has reseeded, the fast path is:

1. `qmrestore` the latest vzdump image from the backup HDD.
2. Appdata inside the image is up to a week old — pull anything newer from tier 1
   (rclone config from the password manager → fetch → unpack the changed service's
   appdata).
3. Passthrough survives in the VM config; verify the disks and GPU came back.

**Slow path — image unusable, full rebuild (an evening, proven):**

1. Fresh cloud-init VM on the old IP — UID/GID 1000 pinned, SSH key injected
   ([migration](migration.md#rebuild-highlights)).
2. rclone config from the password manager → pull the three archives → verify →
   unpack (as root — tar ownership [gotcha](migration.md#gotchas-worth-stealing)).
3. `docker network create` (exact subnet), then `docker compose up -d`.
4. Re-attach hardware: `qm set 100 -scsi1/-scsi2 /dev/disk/by-id/... ,backup=0` and
   the GPU per the [vfio recipe](passthrough.md).

**Verify:** container count ≈ [metrics](metrics.md) · LAN DNS answers · `nvidia-smi`
in the VM *and* in a container · VPN exit is Mullvad (`am.i.mullvad.net/json`).

## The host's SSD dies

1. Install Proxmox VE on a new SSD; restore the host's static IP and both bridges —
   `vmbr0` on the NIC, `vmbr1` with **no physical port**.
2. Redo the vfio host config: IOMMU on the kernel cmdline, vfio-pci ids + softdeps
   ([passthrough](passthrough.md#host-side)).
3. Mount the backup HDD, re-add it as `dir` storage with `is_mountpoint=1`, then
   `qmrestore` VM 100, 105, and 101. **While tier 2 is offline there is nothing to
   restore from:** VM 100 takes the slow path above, VM 105 is rebuilt from the
   [gateway recipe](vpn-gateway.md) (its emergency dump lives on `local`, i.e. on the
   SSD that just died), VM 101 is recreated.
4. Lab VMs are not backed up on purpose — recreate from the
   [recipe](vms.md#recipe-a-new-gpu-less-guest-vm); nothing persistent lives in them.

The data drives don't enter this scenario at all — they pass through untouched.

## vpn-gw (VM 105) dies

- **Fast:** `qmrestore` the emergency dump taken 2026-07-25 (77 MB, storage `local`) —
  minutes to restore. The dump is from 2026-07-25 — re-verify the killswitch rules
  after restoring, don't assume.
- **Rebuild:** [vpn-gateway.md](vpn-gateway.md) is the recipe. The WireGuard private
  key is *not* in any backup by design — generate a fresh config at mullvad.net.
- **Meanwhile:** lab VMs have no egress at all. That's the killswitch working, not an
  extra incident.
- **Verify:** `wg show wg0` handshake · `curl https://am.i.mullvad.net/json` ·
  `iptables -L FORWARD -n` shows policy `DROP`.

## The backup HDD dies

**This happened 2026-07-17.** The disk dropped off the bus during a host reboot; the
job failed on the following Sunday and every Sunday since. Nothing irreplaceable was
lost — tier 2 is convenience by design — but the failure went unnoticed for eight days
because the alert path had been broken the same day
([lesson #15](lessons.md#15-nofail--is_mountpoint-hide-a-dead-backup-target--alert-on-missing-successes-not-just-failures)).

To bring tier 2 back: replace the disk, recreate the `dir` storage (**`is_mountpoint=1`**,
or Proxmox will happily fill the NVMe root instead), leave the job as it is — it never
stopped trying — and run one manual `vzdump` of 100, 101 and 105 to reseed. Then confirm
the *success* notification arrives, not just the failures.

## A notification didn't arrive

Silence from the host is not good news until proven ([lesson #15](lessons.md#15-nofail--is_mountpoint-hide-a-dead-backup-target--alert-on-missing-successes-not-just-failures)).

```bash
pvesh create /cluster/notifications/targets/ntfy/test   # a test message must land on the phone
pvesh get /cluster/notifications/matchers               # default-matcher → ntfy, not mail-to-root
systemctl status pve-healthcheck.timer                  # the 5-minute watchdog: active (waiting)
```

If the test lands but a job's notification didn't, read the job's log — a failed vzdump
ends with `notified via target ntfy`; if that line is missing, the matcher is the problem.

## A 4 TB data drive dies

Bulk media on the dead drive is gone by design — 6+ TB doesn't fit an offsite budget.
The irreplaceable subset (photos, documents) restores from tier 1. Replace the drive,
pass it through by `/dev/disk/by-id`, restore the folder layout, let the services
re-scan their libraries.

## Before any risky change (do this every time)

```bash
qm snapshot <vmid> pre-<change>        # instant undo button — not a backup
vzdump <vmid> --mode snapshot --compress zstd   # when "risky" means "really risky"
```

## RPO / RTO, honestly

Corrected for the state on 2026-08-28 — tier 2 offline, no image of VM 100 or 101.

| Failure | Data loss | Time to running | 2026-08-28 |
|---|---|---|---|
| VM 100, fast path | ≤ 7 days VM state, appdata patchable to ≤ 24 h | ~30 min | **n/a** — no image exists |
| VM 100, full rebuild | ≤ 24 h (tier 1 is nightly) | an evening (proven) | the only path today |
| Host SSD | ≤ 24 h for VM 100 (tier 1); lab VMs are disposable | host install + an evening | no images to `qmrestore` — VM 100 goes through the full rebuild |
| vpn-gw | none (stateless by design) | minutes | `qmrestore` the 77 MB dump from 2026-07-25, or rebuild from the recipe |
| Backup HDD | none irreplaceable | replace at leisure | happened 2026-07-17; disk not yet replaced |
| One data drive | bulk media on that drive | re-rip / re-download over time | — |
