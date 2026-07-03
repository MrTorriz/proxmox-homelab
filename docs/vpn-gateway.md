# The VPN gateway VM

A 512 MB Alpine Linux router (VM 105, `vpn-gw`) that puts every lab VM behind Mullvad
WireGuard with a fail-closed killswitch. One Mullvad device slot serves an unlimited
number of VMs behind it.

## Why a gateway VM instead of a client per VM

- **Device slots.** Mullvad allows 5 devices per account. A gateway consumes one slot
  regardless of how many VMs sit behind it.
- **No per-guest setup.** A new VM gets VPN coverage by being attached to the right
  bridge — nothing to install or configure in the guest. Works identically for Windows,
  Kali, NixOS, Arch.
- **Killswitch enforced outside the guest.** The guest can't leak by misconfiguration,
  because the guest never has a non-VPN path to begin with.

## Architecture

```text
              ┌─ net0 (eth0) → vmbr0 → router → ISP     [WireGuard exits here]
 vpn-gw (105) ┤    wg0 = Mullvad, full tunnel (AllowedIPs 0.0.0.0/0)
 Alpine Linux └─ net1 (eth1) → vmbr1 = VPN LAN 10.10.10.1/24   [dnsmasq DHCP]
                     │
     VMs on vmbr1 (Windows 11 / Kali / NixOS / Arch)
     → DHCP 10.10.10.x, gateway 10.10.10.1
     → ALL their traffic is NATed out through Mullvad.
       Tunnel down ⇒ traffic dropped, not leaked.
```

`vmbr1` is an internal bridge with no physical port — defined on the host, invisible to
the LAN. The *only* route from `vmbr1` to anywhere is through `wg0`.

## VM spec

| | |
|---|---|
| OS | Alpine Linux (sys install) |
| CPU / RAM | 2 cores / 512 MB (balloon 256) — always-on infra should be lean |
| Disk | 4 GB on the NVMe thin pool |
| net0 | virtio → `vmbr0` (WAN side, DHCP) |
| net1 | virtio → `vmbr1` (10.10.10.1/24) |
| onboot | **1** — other VMs depend on it |
| BIOS | SeaBIOS, no GPU, no TPM |

## The killswitch

NAT plus three forward rules, persisted in `/etc/iptables/rules-save`:

```text
iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o wg0 -j MASQUERADE
iptables -A FORWARD -i eth1 -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o eth1 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -P FORWARD DROP
```

The last line is the killswitch: forwarding is only ever allowed **into the tunnel**.
There is no `eth1 → eth0` rule, so client traffic can't fall back to the raw WAN path —
if `wg0` disappears, packets hit the `DROP` policy. Fail-closed by construction, not by a
watchdog.

Supporting pieces:

- **WireGuard** — `/etc/wireguard/wg0.conf` (Mullvad config, full tunnel), started by the
  `wg-quick.wg0` OpenRC service. The private key lives only on the VM — never in this or
  any repo. Disaster recovery = generate a fresh config at mullvad.net.
- **dnsmasq** — `/etc/dnsmasq.d/vpn-lan.conf`: DHCP range 10.10.10.100–200, gateway/DNS
  10.10.10.1, upstream DNS = Mullvad's in-tunnel resolver (`10.64.0.1`), so DNS can't
  leak either.
- **sysctl** — `net.ipv4.ip_forward=1`, IPv6 disabled entirely (the ISP provides no
  routable v6; a half-configured v6 stack is just a leak vector).

## Putting a VM behind the VPN

Move its NIC from the LAN bridge to the VPN bridge:

```bash
qm set <vmid> --net0 virtio,bridge=vmbr1     # add =<MAC> to keep the guest's MAC
# bounce the VM (or its NIC) → it picks up 10.10.10.x from dnsmasq
```

Verify from inside the guest: `https://am.i.mullvad.net` must report a Mullvad exit.
Moving back to the LAN is the same command with `bridge=vmbr0`.

## Verifying the gateway

```bash
ssh root@<vpn-gw> 'wg show wg0'                            # handshake recent?
ssh root@<vpn-gw> 'curl -s https://am.i.mullvad.net/json'  # "mullvad_exit_ip": true
ssh root@<vpn-gw> 'iptables -L FORWARD -n | head -3'       # policy DROP
```

The workload VM (100) does **not** route through this gateway — it stays on `vmbr0` with
its own Mullvad client in lockdown mode, because it also has to serve the LAN (DNS,
reverse proxy, media) and a full-tunnel gateway would break that.

## Bootstrap tip: SSH into a fresh Alpine VM

Fresh Alpine defaults to `PermitRootLogin prohibit-password` — keys work, passwords
don't, and the serial console may not be set up yet. Chicken-and-egg. Fix from the host
by mounting the VM disk offline and planting a key:

```bash
qm stop <vmid>
partx --show /dev/pve/vm-<vmid>-disk-0            # note the root partition offset
mount -o loop,offset=$((START*512)) /dev/pve/vm-<vmid>-disk-0 /mnt
mkdir -p /mnt/root/.ssh && cat pubkey >> /mnt/root/.ssh/authorized_keys
umount /mnt && qm start <vmid>
```

(`kpartx` isn't installed on a stock Proxmox host; the offset-mount trick needs nothing
extra.)
