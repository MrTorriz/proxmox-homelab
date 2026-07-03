# The VM fleet

Six VMs on one 6-core / 16 GB host. Two always-on, four on demand — because RAM is the
bottleneck, not CPU ([budget](architecture.md#ram-the-actual-bottleneck)).

## Inventory

| VMID | Name | OS | RAM | Bridge | onboot | Role |
|---|---|---|---|---|---|---|
| 100 | docker-host | Ubuntu 24.04 | 8 GB cap | vmbr0 | ✅ | The workload: ~45 containers, GPU + 2×4 TB passthrough — the [homelab stack](https://github.com/MrTorriz/homelab) |
| 101 | win11 | Windows 11 24H2 | 4 GB | vmbr1 | — | Desktop things Linux won't do. q35 + OVMF + vTPM 2.0, no GPU |
| 102 | kali | Kali Linux | 4 GB | vmbr1 | — | Pentest lab |
| 103 | nixos | NixOS | 4 GB | vmbr1 | — | Declarative-config playground (runs its own flake) |
| 104 | arch | Arch Linux | 4 GB | vmbr1 | — | Rolling-release playground |
| 105 | vpn-gw | Alpine | 512 MB | vmbr0+vmbr1 | ✅ | [Mullvad WireGuard gateway](vpn-gateway.md), fail-closed killswitch |

Every lab VM (101–104) sits on `vmbr1` — born behind the VPN, no opt-in required.
The Windows VM's exit IP was verified as a Mullvad endpoint before first use.

## Recipe: a new (GPU-less) guest VM

```bash
qm create <vmid> --name <name> --machine q35 --bios ovmf --cpu host \
  --cores 4 --memory 4096 --balloon 2048 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr1 \
  --agent enabled=1 --onboot 0
qm set <vmid> --efidisk0 local-lvm:1,efitype=4m
qm set <vmid> --scsi0 local-lvm:40,ssd=1,discard=on
qm set <vmid> --ide2 local:iso/<installer>.iso,media=cdrom
qm set <vmid> --boot "order=ide2;scsi0"
```

Notes baked into that recipe:

- **`bridge=vmbr1`** — VPN LAN by default; `vmbr0` is the deliberate exception.
- **`discard=on,ssd=1`** from day one ([lesson #11](lessons.md#11-thin-disk-discard-must-be-enabled-on-both-ends)).
- **Boot disk always on the NVMe thin pool** — never on the passthrough drives.
- **`pre-enroll-keys=1` on the EFI disk is rejected by PVE 8.4** ("property not
  defined") — leave it out and enroll Secure Boot keys in the OVMF menu if the guest
  needs them (Windows does; the TPM comes from `qm set <vmid> --tpmstate0
  local-lvm:1,version=v2.0`).
- `balloon` on lab VMs gives some headroom elasticity, but remember
  [lesson #14](lessons.md#14-ballooning-does-not-return-host-ram-on-a-running-vm):
  the `memory` cap is what the host will actually pay.

## Finding a fresh VM's DHCP address

From the host — ping-sweep the pool, then read the neighbor table for the VM's MAC:

```bash
for ip in $(seq 64 254); do (ping -c1 -W1 192.168.1.$ip >/dev/null 2>&1 &); done
sleep 4; ip neigh | grep -i <net0-mac>
```

(On the VPN LAN it's easier: the gateway's dnsmasq leases file, or `ip neigh` on the
gateway.)

## Running commands inside guests without a console

With `qemu-guest-agent` installed in the guest:

```bash
qm guest cmd <vmid> network-get-interfaces      # the guest's real IPs
qm guest exec <vmid> --synchronous 0 -- <cmd>   # fire and forget
qm guest exec-status <vmid> <pid>               # collect result
```

## Before any risky change

```bash
qm snapshot <vmid> pre-<change>    # instant; an undo button, not a backup
```

See [backup.md](backup.md) for what an actual backup is.
