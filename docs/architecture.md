# Architecture

How one 16 GB desktop-class box runs a full self-hosted stack, four lab VMs, and a VPN
gateway — without the layers stepping on each other.

## The one rule: the host does nothing

The hypervisor runs virtualization and hardware health. Nothing else.

| Layer | Machine | Responsibility |
|---|---|---|
| Hypervisor | `pve` (bare metal) | QEMU/KVM, vzdump backups (target failed 2026-07-17, not yet replaced), SMART monitoring, notifications |
| Workload | VM 100 (Ubuntu 24.04) | 44 Docker containers (2026-08-28) — the entire [homelab stack](https://github.com/MrTorriz/homelab) |
| VPN edge | VM 105 (Alpine) | WireGuard gateway with fail-closed killswitch for the lab VMs |
| Lab | VMs 101–104 | Windows 11, Kali, NixOS, Arch — on demand, never always-on |

No Docker on the host. No DNS on the host. No packages beyond what virtualization needs.
The payoff: the host can be rebooted or upgraded at any time and the services come back on
their own (`onboot=1` — see [lessons](lessons.md#1-onboot1-on-every-production-vm)).

## What the host does run

"Nothing" has a short list of exceptions, each with a reason. Verified 2026-08-28.

| Piece | What | Why |
|---|---|---|
| Notifications | A user-created Proxmox notification target `ntfy` (type **webhook**) posting to the ntfy server in VM 100; the single `default-matcher` routes everything to it. The token is a Proxmox secret in `/etc/pve/priv/notifications.cfg`. The stock `mail-to-root` target still exists but has been dead since 2026-07-17. | A failed job must reach a phone, not a mailbox nobody reads ([lesson #15](lessons.md#15-nofail--is_mountpoint-hide-a-dead-backup-target--alert-on-missing-successes-not-just-failures)). Every failed vzdump since logs `notified via target ntfy`. |
| `pve-healthcheck.timer` | Every 5 minutes: are the always-on VMs running, is every storage active → ntfy on deviation. | Alert on *missing successes*, not only on failures — the dead backup target was silent for eight days. |
| IPv6 off | `/etc/sysctl.d/99-disable-ipv6.conf` (`all` + `default` disabled) since 2026-06-26; zero global v6 addresses on the host. | The ISP provides no routable v6; a half-configured v6 stack is a leak vector, not a feature. |
| `unattended-upgrades` | On, origins limited to Debian security; the Proxmox repository is excluded; no automatic reboot. | Security patches land on their own. PVE upgrades and reboots stay a deliberate act — a host reboot is what took the backup disk with it. |
| `pve-firewall` | Enabled and running, `policy_in DROP`, `policy_out ACCEPT`. | The management plane is closed by default; the LAN gets an explicit allow. |

## Network: two bridges, two trust zones

```text
                       ISP router
                            │
             ┌── vmbr0 ─────┴────────────── LAN 192.168.1.0/24
             │      │                │
             │   VM 100          VM 105 vpn-gw ── wg0 ⇒ Mullvad (full tunnel)
             │  (workload,       (Alpine router)
             │   own Mullvad         │
             │   + lockdown)     vmbr1 ────────── VPN LAN 10.10.10.0/24
             │                       │            (no physical port)
          Proxmox            VMs 101–104: Windows 11 · Kali · NixOS · Arch
          host .4            DHCP from vpn-gw · ALL traffic exits via Mullvad
```

- **`vmbr0`** — the LAN bridge, attached to the physical NIC. Host management and VM 100
  live here. VM 100 runs its own Mullvad client in lockdown mode, so its container traffic
  is already tunneled.
- **`vmbr1`** — an internal bridge with **no physical port**. Everything on it can only
  reach the world through the gateway VM's WireGuard tunnel. If the tunnel is down, traffic
  is dropped, not leaked — the `FORWARD` policy is `DROP`
  ([details](vpn-gateway.md)).

Design goal inherited from the bare-metal era: **no unencrypted traffic to the ISP**.
Lab VMs land on `vmbr1` by default — putting a machine on `vmbr0` is the exception that
needs a reason.

## Storage: three tiers, one hard line

| Device | Size | Role |
|---|---|---|
| NVMe SSD | 480 GB | Proxmox root + `local-lvm` thin pool (all VM boot disks) |
| 2 × WD Red Plus (CMR) | 4 TB each | **Raw passthrough to VM 100** — media + backup data, untouched by the hypervisor |
| SATA HDD | 1 TB | Dedicated `vzdump` target (weekly VM images, `keep-last=3`) — **failed 2026-07-17, not yet replaced** ([backup](backup.md#tier-2--vm-images-vzdump-local-scheduled)) |

The two 4 TB drives are handed to VM 100 as whole-disk passthrough (`scsi1`/`scsi2`,
`backup=0`). The hypervisor never mounts, formats, or backs them up — they carry the same
filesystems they carried on bare metal, which is what made the
[migration](migration.md) a zero-copy move for 6+ TB of data.

The hard line: **no Ceph, no ZFS pool, no "let Proxmox manage the disks".** Distributed
storage wants to own (wipe) its disks and wants 3+ nodes; on a single 16 GB host with
irreplaceable data on passthrough drives it's a footgun, not a feature
([lesson #12](lessons.md#12-single-host-means-no-cephzfs-pool)).

Thin-provisioning note: the boot-disk caps add up to more than the pool (434 GB promised vs
349 GB real). That's fine — thin disks only consume written blocks — as long as you treat
disk size as a *cap*, not an allocation, and never let every VM fill up at once.

## RAM: the actual bottleneck

16 GB total, no free slots. Budget (2026-08-28):

| Consumer | Budget |
|---|---|
| VM 100 (workload) | 10 GB hard cap (`memory=10240`) |
| One lab VM at a time | 4 GB |
| Host + kernel | ~1.5 GB |
| vpn-gw | 0.5 GB |
| **Sum** | **16 GB** — the whole box |

The sum is the box. One lab VM at a time is a rule, not advice.

Two things made this budget real instead of aspirational:

1. **`memory=` is a cap the guest will grow into.** Linux fills free RAM with page cache,
   and ballooning does *not* hand host RSS back on a running VM. VM 100 originally had a
   13 GB cap and sat at 13 GB host-RSS while doing ~5 GB of real work. Lowering the cap
   (applies at VM restart) freed ~5 GB ([lesson #14](lessons.md#14-ballooning-does-not-return-host-ram-on-a-running-vm)).
   It went back up to 10 GB on 2026-07-04 after an ML + transcode spike pushed the guest
   into swap thrashing at 8 GB — the cap follows measured need in both directions, and
   the guest carries a 2 GB swapfile as a safety valve.
2. **Lab VMs are `onboot=0` and started manually.** One heavy guest at a time. The
   scheduler shares 6 cores fine; RAM does not overcommit gracefully.

## GPU

The RTX 2060 is passed through to VM 100 (vfio-pci, all four PCI functions, clean IOMMU
group) where it serves Jellyfin NVENC transcodes and Immich ML. The CPU has no iGPU, so
the host runs headless — managed entirely over SSH and the web UI.
Full recipe and gotchas: [passthrough.md](passthrough.md).

## Power

Not re-measured since 2026-07-03. The last figures — ~17 W CPU package, ~15–18 W GPU at
idle, ~35 W as the working total — came from Scaphandre on the host (RAPL isn't available
inside a VM, so power metering is one of the few things that *must* live on the
hypervisor). Scaphandre was removed from the host on 2026-07-04; until a meter is back
these numbers are history, not status ([metrics](metrics.md)).
