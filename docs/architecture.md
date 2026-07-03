# Architecture

How one 16 GB desktop-class box runs a full self-hosted stack, four lab VMs, and a VPN
gateway — without the layers stepping on each other.

## The one rule: the host does nothing

The hypervisor runs virtualization and hardware health. Nothing else.

| Layer | Machine | Responsibility |
|---|---|---|
| Hypervisor | `pve` (bare metal) | QEMU/KVM, vzdump backups, SMART monitoring, power metering (RAPL) |
| Workload | VM 100 (Ubuntu 24.04) | ~40 Docker containers — the entire [homelab stack](https://github.com/MrTorriz/homelab) |
| VPN edge | VM 105 (Alpine) | WireGuard gateway with fail-closed killswitch for the lab VMs |
| Lab | VMs 101–104 | Windows 11, Kali, NixOS, Arch — on demand, never always-on |

No Docker on the host. No DNS on the host. No packages beyond what virtualization needs.
The payoff: the host can be rebooted or upgraded at any time and the services come back on
their own (`onboot=1` — see [lessons](lessons.md#1-onboot1-on-every-production-vm)).

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

Design goal inherited from the bare-metal era: **zero unencrypted traffic to the ISP**.
Every lab VM is born behind the VPN — putting a machine on `vmbr0` is the exception that
needs a reason, not the default.

## Storage: three tiers, one hard line

| Device | Size | Role |
|---|---|---|
| NVMe SSD | 480 GB | Proxmox root + `local-lvm` thin pool (all VM boot disks) |
| 2 × WD Red Plus (CMR) | 4 TB each | **Raw passthrough to VM 100** — media + backup data, untouched by the hypervisor |
| SATA HDD | 1 TB | Dedicated `vzdump` target (weekly VM images, `keep-last=3`) |

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

16 GB total, no free slots. Budget:

| Consumer | Budget |
|---|---|
| VM 100 (workload) | 8 GB hard cap |
| One lab VM at a time | 4 GB |
| Host + kernel | ~2 GB |
| Slack | ~2 GB |

Two things made this budget real instead of aspirational:

1. **`memory=` is a cap the guest will grow into.** Linux fills free RAM with page cache,
   and ballooning does *not* hand host RSS back on a running VM. VM 100 originally had a
   13 GB cap and sat at 13 GB host-RSS while doing ~5 GB of real work. Lowering the cap
   (applies at VM restart) freed ~5 GB ([lesson #14](lessons.md#14-ballooning-does-not-return-host-ram-on-a-running-vm)).
2. **Lab VMs are `onboot=0` and started manually.** One heavy guest at a time. The
   scheduler shares 6 cores fine; RAM does not overcommit gracefully.

## GPU

The RTX 2060 is passed through to VM 100 (vfio-pci, all four PCI functions, clean IOMMU
group) where it serves Jellyfin NVENC transcodes and Immich ML. The CPU has no iGPU, so
the host runs headless — managed entirely over SSH and the web UI.
Full recipe and gotchas: [passthrough.md](passthrough.md).

## Power

~35 W total draw at idle workload (measured by scaphandre on the host — RAPL isn't
available inside a VM, so power metering is one of the few things that *must* live on the
hypervisor). CPU ~17 W, GPU ~18 W.
