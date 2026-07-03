# Decisions — why this, and not that

The alternatives were real and the trade-offs were paid. Written down so the next
rebuild doesn't re-litigate them from scratch.

## Why virtualize a working bare-metal server at all

The Docker stack didn't need a hypervisor — the labs did. Windows, Kali, NixOS and
Arch needed real isolation, snapshots, and disposability, and none of that fits in a
container. Virtualizing put the labs *under* the workload instead of next to it, with
the blast radius pointing away from the services the LAN depends on.

**Rejected:** a second physical box (cost, power, space for machines that run hours
per week) · containers-as-labs (Windows and Kali don't containerize usefully, and a
`--privileged` pentest container is isolation theater).

## Why Proxmox VE — not plain libvirt, not ESXi, not XCP-ng

Debian underneath, stock KVM/QEMU inside, and the three things a headless single box
actually needs built in: scheduled `vzdump` backups, a web UI worth having, and a
`qm`/`pvesh` CLI that scripts cleanly. The no-subscription tier is fully functional
(the nag is a one-liner — [lesson #8](lessons.md#8-proxmoxs-subscription-nag-resurrects)).

**Rejected:** plain libvirt (no integrated backup or UI — this box must be boring to
operate) · ESXi (licensing and hardware support both moving in the wrong direction) ·
XCP-ng (capable, but the homelab ecosystem — recipes, passthrough lore, tooling — is
thinner).

## Why the workload stayed one big VM

The migration was restore-shaped: same compose stack, same IP, zero re-architecture.
Splitting services across VMs or moving to Kubernetes would have turned a zero-data-loss
weekend into a redesign project — on a 16 GB single node where k8s buys overhead
without buying HA. Compose already orchestrates the stack fine.

**Rejected:** one-VM-per-service (RAM budget says no) · single-node k8s (complexity
without failover).

## Why a 512 MB Alpine gateway — not pfSense/OPNsense

The job is WireGuard + NAT + dnsmasq + four iptables rules. A BSD firewall appliance
wants 1–2 GB of RAM and a web UI to do the same thing with more moving parts — and RAM
is [the actual bottleneck](architecture.md#ram-the-actual-bottleneck). The fail-closed
property comes from the `FORWARD DROP` policy, not from appliance features
([vpn-gateway](vpn-gateway.md#the-killswitch)).

**Rejected:** pfSense/OPNsense (weight without benefit at this scope) · per-guest VPN
clients (burns a Mullvad device slot per VM and trusts every guest to not misconfigure).

## Why VM 100 runs its own VPN client instead of sitting behind the gateway

It serves the LAN — DNS, reverse proxy, media. Putting it behind a full-tunnel gateway
would tunnel its LAN-facing traffic too and break what the LAN depends on. So the
workload VM keeps its own client in lockdown mode, and the gateway serves the lab VMs
([vpn-gateway](vpn-gateway.md#verifying-the-gateway)).

## Why raw passthrough for the data drives — not virtual disks

Zero-copy: the drives kept the filesystems they had on bare metal, and 6+ TB never
moved ([migration](migration.md)). The guest sees real drives, so SMART monitoring
works inside the VM. And a passthrough drive is one the hypervisor *can't* be tempted
to manage.

**Rejected:** imaging 8 TB into qcow2/LVM (days of copying to add a corruption layer).

## Why no cluster, no Ceph, no ZFS pool

Distributed storage wants three nodes and wants to initialize — wipe — its disks. This
is one host with irreplaceable data on passthrough drives
([lesson #12](lessons.md#12-single-host-means-no-cephzfs-pool)). LVM-thin (the installer
default) stayed for VM disks: ZFS's ARC would eat gigabytes of a 16 GB budget, and a
single SSD gives ZFS nothing to heal from anyway.

## Why two backup tiers

Because they answer different questions: tier 1 (encrypted offsite appdata) answers
"the building burned down", tier 2 (local vzdump images) answers "that upgrade was a
mistake". Mixing them up produces backups that restore the wrong thing
([backup](backup.md)).

## Why cloud-init for VM builds

A rebuild should be a runbook, not an adventure. Cloud-init pins the parts that are
easy to get subtly wrong by hand — UID/GID 1000 (container volume permissions depend
on it), SSH key, static IP ([migration](migration.md#rebuild-highlights)).
