# Metrics — the numbers, with receipts

Every figure has a command; the column says whether it was re-run. The table was
refreshed on 2026-08-28 from the live host. Rows marked ✘ still carry the value from the
previous pass (2026-07-03) and say why.

## Measured 2026-08-28

| Figure | Value | Re-measured? | Command / source |
|---|---|---|---|
| VMs on the host | 6 (2 running) | ✔ | `qm list` ([recreation](img/qm-list.png)) |
| Running containers in VM 100 | 44 (0 privileged) | ✔ | `docker ps -q \| wc -l` inside the guest |
| Raw disk passed through | 8 TB (2 × 4 TB) | ✔ | `qm config 100` → `scsi1`/`scsi2`, `backup=0` |
| Inbound WAN ports | none configured on purpose — external access is an outbound Cloudflare Tunnel from VM 100 | ✘ — the router's port-forward table was not re-verified | [architecture](architecture.md#network-two-bridges-two-trust-zones) |
| Power | last 2026-07-03: ~17 W CPU / ~15–18 W GPU / ~35 W total | ✘ — Scaphandre was removed from the host 2026-07-04; not re-measured since 2026-07-03 | `scaph_host_power_microwatts` (RAPL, host) · `nvidia-smi --query-gpu=power.draw --format=csv` (guest) |
| VM boot-disk pool | `local-lvm` 349 GiB, 30.08 % used | ✔ | `pvesm status` ([recreation](img/pvesm-status.png)) |
| Host root | `local` 94 GiB, 30.59 % used | ✔ | `pvesm status` |
| vzdump target | `vzbackup` **inactive** since 2026-07-17 (backup disk dead) | ✔ | `pvesm status` — see [backup](backup.md#tier-2--vm-images-vzdump-local-scheduled) |
| VM 100 RAM cap | 10 GB | ✔ | `qm config 100` → `memory: 10240` |
| Proxmox VE | 8.4.21, kernel 6.8.12-42-pve | ✔ | `pveversion` |
| pve-firewall | enabled, running, `policy_in DROP` | ✔ | `pve-firewall status` · `/etc/pve/firewall/cluster.fw` |
| Host IPv6 | off — `all` + `default` disabled, zero global v6 addresses | ✔ | `sysctl net.ipv6.conf.all.disable_ipv6` · `ip -6 addr` |

Two honesty notes:

- **Container count drifts.** Services get added and pruned; the docs carry the dated
  count, not a rounded one. Re-run the command, don't trust a README.
- **Power is history until a meter is back.** The 2026-07-03 figures were idle-workload
  (transcodes and ML jobs spike the GPU well past its idle draw). The exporter left the
  host the next day, so nothing has been measured since.
